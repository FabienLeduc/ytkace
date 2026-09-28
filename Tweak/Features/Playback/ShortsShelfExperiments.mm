#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>

/* Final Home-feed Shorts shelf experiment matrix.  All behavior changes are
 * restricted to YTSingleVideoController objects observed through the stock
 * inline-muted Shorts shelf overlay. */

static IMP OrigEarlyFinished, OrigFinished, OrigResetStartTimes, OrigStartPlayback;
static IMP OrigResumePlayback, OrigPausePlayback, OrigSetPlaybackItem;
static IMP OrigOverlaySetEntry, OrigOverlaySetPlayerResponse, OrigOverlaySetActiveVideo, OrigOverlayResetLoading;
static IMP OrigLoopBehavior, OrigSetLoopBehavior, OrigLoopingEnabled, OrigSetLoopingEnabled, OrigMaybeLoopPlayback;

static UILabel *gLabel;
static NSTimer *gTimer;
static NSString *gEvent = @"waiting for shelf", *gClass = @"-", *gDetail = @"-", *gCaller = @"-", *gVideoID = @"-";
static NSUInteger gStarts, gResumes, gPauses, gFinished, gEarly, gItems, gEntries, gResponses, gVideos, gResets;
static NSUInteger gBlockedVideo, gBlockedReset, gBlockedLoop;
static NSMutableSet<NSValue *> *gShelfVideos;
static NSMutableDictionary<NSValue *, NSValue *> *gHeldVideo;
static NSMutableDictionary<NSValue *, NSNumber *> *gHeldTime;

static NSInteger Mode(void) {
    id v = YTKACEPreferenceObject(@"YTKACE.Preference.Playback.ShortsShelfTestMode");
    return [v respondsToSelector:@selector(integerValue)] ? [v integerValue] : 0;
}
BOOL YTKACEShortsShelfBypassPlaybackFix(void) { return Mode() == 1; }
static BOOL Debug(void) { return [YTKACEPreferenceObject(@"YTKACE.Preference.Playback.ShortsShelfDebugOverlay") boolValue]; }
static NSValue *Key(id x) { return [NSValue valueWithPointer:(__bridge const void *)x]; }
static double Now(void) { return CACurrentMediaTime(); }

static NSString *ModeName(void) {
    switch (Mode()) {
        case 1: return @"PlaybackFix bypass (control)";
        case 2: return @"Hold first shelf video 3s";
        case 3: return @"Hold first shelf video 10s";
        case 4: return @"Block shelf reset/loading";
        case 5: return @"Force loopBehavior=0";
        case 6: return @"Force loopBehavior=1";
        case 7: return @"Force loopBehavior=2";
        case 8: return @"Force loopBehavior=3";
        case 9: return @"Force loopingEnabled=NO";
        case 10: return @"Block maybeLoopPlayback";
        case 11: return @"Hold 10s + no looping + no maybeLoop";
        default: return @"Trace / stock";
    }
}

static NSString *Callsite(void *p) {
    if (!p) return @"-";
    Dl_info i = {};
    if (dladdr(p, &i)) {
        uintptr_t off = i.dli_fbase ? (uintptr_t)p - (uintptr_t)i.dli_fbase : 0;
        NSString *image = i.dli_fname ? [[NSString stringWithUTF8String:i.dli_fname] lastPathComponent] : @"?";
        if (i.dli_sname) return [NSString stringWithFormat:@"%@!%s +0x%lx", image, i.dli_sname, (unsigned long)off];
        return [NSString stringWithFormat:@"%@+0x%lx", image, (unsigned long)off];
    }
    return [NSString stringWithFormat:@"%p", p];
}

static id SafeObjectSelector(id obj, const char *name) {
    if (!obj) return nil;
    SEL s = sel_registerName(name);
    if (![obj respondsToSelector:s]) return nil;
    return ((id(*)(id,SEL))objc_msgSend)(obj,s);
}
static NSString *StringValue(id x) {
    if ([x isKindOfClass:NSString.class] && [x length]) return x;
    if ([x respondsToSelector:@selector(stringValue)]) return [x stringValue];
    return nil;
}
static NSString *FindVideoID(id obj) {
    if (!obj) return nil;
    const char *direct[] = {"videoId", "videoID", "externalVideoId", "externalVideoID"};
    for (unsigned i=0;i<sizeof(direct)/sizeof(direct[0]);i++) {
        NSString *s = StringValue(SafeObjectSelector(obj,direct[i]));
        if (s.length) return s;
    }
    const char *nested[] = {"video", "videoData", "playerResponse", "playbackData", "metadata"};
    for (unsigned i=0;i<sizeof(nested)/sizeof(nested[0]);i++) {
        id child = SafeObjectSelector(obj,nested[i]);
        if (!child || child == obj) continue;
        for (unsigned j=0;j<sizeof(direct)/sizeof(direct[0]);j++) {
            NSString *s = StringValue(SafeObjectSelector(child,direct[j]));
            if (s.length) return s;
        }
    }
    return nil;
}
static void Record(NSString *event, id obj, NSString *detail, void *caller) {
    gEvent = event ?: @"?";
    gClass = obj ? NSStringFromClass([obj class]) : @"-";
    gDetail = detail ?: @"-";
    gCaller = Callsite(caller);
    NSString *vid = FindVideoID(obj);
    if (vid.length) gVideoID = vid;
}
static BOOL IsShelfVideo(id obj) { return obj && [gShelfVideos containsObject:Key(obj)]; }

static UIWindow *KeyWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) if (w.isKeyWindow) return w;
    }
    return nil;
}
static void Refresh(void) {
    if (!Debug()) { [gLabel removeFromSuperview]; return; }
    UIWindow *w = KeyWindow(); if (!w) return;
    if (!gLabel) {
        gLabel=[UILabel new]; gLabel.numberOfLines=0;
        gLabel.font=[UIFont monospacedSystemFontOfSize:8.5 weight:UIFontWeightSemibold];
        gLabel.textColor=UIColor.whiteColor; gLabel.backgroundColor=[UIColor colorWithWhite:0 alpha:.86];
        gLabel.layer.cornerRadius=8; gLabel.layer.masksToBounds=YES; gLabel.userInteractionEnabled=NO;
    }
    if (gLabel.superview != w) { [gLabel removeFromSuperview]; [w addSubview:gLabel]; }
    gLabel.text=[NSString stringWithFormat:@"HOME SHORTS FINAL TEST\nmode: %@\nlast: %@\nclass: %@\nvideoId: %@\ndetail: %@\ncaller: %@\nstart/resume/pause: %lu/%lu/%lu\nfinished/early/item: %lu/%lu/%lu\nentry/response/video/reset: %lu/%lu/%lu/%lu\nBLOCKED video/reset/loop: %lu/%lu/%lu",
        ModeName(),gEvent,gClass,gVideoID,gDetail,gCaller,
        (unsigned long)gStarts,(unsigned long)gResumes,(unsigned long)gPauses,
        (unsigned long)gFinished,(unsigned long)gEarly,(unsigned long)gItems,
        (unsigned long)gEntries,(unsigned long)gResponses,(unsigned long)gVideos,(unsigned long)gResets,
        (unsigned long)gBlockedVideo,(unsigned long)gBlockedReset,(unsigned long)gBlockedLoop];
    CGFloat width=MIN(w.bounds.size.width-20,440.0); CGSize fit=[gLabel sizeThatFits:CGSizeMake(width-16,CGFLOAT_MAX)];
    gLabel.frame=CGRectMake(10,54,width,fit.height+14); [w bringSubviewToFront:gLabel];
}

static void EarlyFinished(id self,SEL c){gEarly++;Record(@"EARLY FINISHED",self,@"-",__builtin_return_address(0));if(OrigEarlyFinished)((void(*)(id,SEL))OrigEarlyFinished)(self,c);}
static void Finished(id self,SEL c){gFinished++;Record(@"FINISHED",self,@"-",__builtin_return_address(0));if(OrigFinished)((void(*)(id,SEL))OrigFinished)(self,c);}
static void ResetStartTimes(id self,SEL c){gResets++;Record(@"resetStartTimes",self,@"-",__builtin_return_address(0));if(OrigResetStartTimes)((void(*)(id,SEL))OrigResetStartTimes)(self,c);}
static void StartPlayback(id self,SEL c){gStarts++;Record(@"startPlayback",self,[NSString stringWithFormat:@"container=%p",self],__builtin_return_address(0));if(OrigStartPlayback)((void(*)(id,SEL))OrigStartPlayback)(self,c);}
static void ResumePlayback(id self,SEL c){gResumes++;Record(@"resumeInlinePlayback",self,@"-",__builtin_return_address(0));if(OrigResumePlayback)((void(*)(id,SEL))OrigResumePlayback)(self,c);}
static void PausePlayback(id self,SEL c){gPauses++;Record(@"pauseInlinePlayback",self,@"-",__builtin_return_address(0));if(OrigPausePlayback)((void(*)(id,SEL))OrigPausePlayback)(self,c);}
static void SetPlaybackItem(id self,SEL c,id x){gItems++;Record(@"setPlaybackItem",x?:self,@"-",__builtin_return_address(0));if(OrigSetPlaybackItem)((void(*)(id,SEL,id))OrigSetPlaybackItem)(self,c,x);}
static void OverlaySetEntry(id self,SEL c,id x){gEntries++;Record(@"setEntry",x?:self,[NSString stringWithFormat:@"overlay=%p entry=%p",self,x],__builtin_return_address(0));if(OrigOverlaySetEntry)((void(*)(id,SEL,id))OrigOverlaySetEntry)(self,c,x);}
static void OverlaySetResponse(id self,SEL c,id x,id cpn){gResponses++;NSString *v=FindVideoID(x);if(v.length)gVideoID=v;Record(@"setPlayerResponse",x?:self,[NSString stringWithFormat:@"overlay=%p response=%p id=%@",self,x,v?:@"?"],__builtin_return_address(0));if(OrigOverlaySetPlayerResponse)((void(*)(id,SEL,id,id))OrigOverlaySetPlayerResponse)(self,c,x,cpn);}

static void OverlaySetVideo(id self,SEL c,id video) {
    gVideos++; double now=Now(); NSValue *ok=Key(self); NSValue *vk=video?Key(video):nil;
    if (video) [gShelfVideos addObject:vk];
    NSString *vid=FindVideoID(video); if(vid.length)gVideoID=vid;
    NSInteger m=Mode(); double hold=(m==2?3.0:((m==3||m==11)?10.0:0.0));
    NSValue *held=gHeldVideo[ok]; double since=[gHeldTime[ok] doubleValue];
    BOOL replacement=held && vk && ![held isEqual:vk];
    BOOL block=hold>0 && replacement && since>0 && now-since<hold;
    Record(block?@"BLOCKED replacement":@"setActiveSingleVideo",video?:self,
           [NSString stringWithFormat:@"overlay=%p video=%p id=%@ replacement=%@ age=%.3f",self,video,vid?:@"?",replacement?@"Y":@"N",since?now-since:-1.0],
           __builtin_return_address(0));
    if(block){gBlockedVideo++;return;}
    if(vk){gHeldVideo[ok]=vk;gHeldTime[ok]=@(now);}
    if(OrigOverlaySetActiveVideo)((void(*)(id,SEL,id))OrigOverlaySetActiveVideo)(self,c,video);
}
static void OverlayReset(id self,SEL c,BOOL loading){
    gResets++; BOOL block=(Mode()==4) && loading;
    Record(block?@"BLOCKED reset/loading":@"resetAndShowLoading",self,[NSString stringWithFormat:@"loading=%@",loading?@"YES":@"NO"],__builtin_return_address(0));
    if(block){gBlockedReset++;return;} if(OrigOverlayResetLoading)((void(*)(id,SEL,BOOL))OrigOverlayResetLoading)(self,c,loading);
}

static NSInteger LoopBehavior(id self,SEL c){
    NSInteger stock=OrigLoopBehavior?((NSInteger(*)(id,SEL))OrigLoopBehavior)(self,c):0;
    if(!IsShelfVideo(self))return stock; NSInteger m=Mode(); NSInteger out=stock;
    if(m>=5&&m<=8)out=m-5;
    Record(@"loopBehavior",self,[NSString stringWithFormat:@"stock=%ld -> %ld",(long)stock,(long)out],__builtin_return_address(0)); return out;
}
static void SetLoopBehavior(id self,SEL c,NSInteger value){
    NSInteger out=value; NSInteger m=Mode(); if(IsShelfVideo(self)&&m>=5&&m<=8)out=m-5;
    if(IsShelfVideo(self))Record(@"setLoopBehavior",self,[NSString stringWithFormat:@"asked=%ld -> %ld",(long)value,(long)out],__builtin_return_address(0));
    if(OrigSetLoopBehavior)((void(*)(id,SEL,NSInteger))OrigSetLoopBehavior)(self,c,out);
}
static BOOL LoopingEnabled(id self,SEL c){
    BOOL stock=OrigLoopingEnabled?((BOOL(*)(id,SEL))OrigLoopingEnabled)(self,c):NO;
    if(IsShelfVideo(self)&&(Mode()==9||Mode()==11)){Record(@"loopingEnabled forced NO",self,[NSString stringWithFormat:@"stock=%@",stock?@"YES":@"NO"],__builtin_return_address(0));return NO;} return stock;
}
static void SetLoopingEnabled(id self,SEL c,BOOL value){
    BOOL out=value;if(IsShelfVideo(self)&&(Mode()==9||Mode()==11))out=NO;
    if(IsShelfVideo(self))Record(@"setLoopingEnabled",self,[NSString stringWithFormat:@"asked=%@ -> %@",value?@"YES":@"NO",out?@"YES":@"NO"],__builtin_return_address(0));
    if(OrigSetLoopingEnabled)((void(*)(id,SEL,BOOL))OrigSetLoopingEnabled)(self,c,out);
}
static void MaybeLoopPlayback(id self,SEL c){
    if(IsShelfVideo(self)&&(Mode()==10||Mode()==11)){gBlockedLoop++;Record(@"BLOCKED maybeLoopPlayback",self,@"shelf video",__builtin_return_address(0));return;}
    if(OrigMaybeLoopPlayback)((void(*)(id,SEL))OrigMaybeLoopPlayback)(self,c);
}

void YTKACEInstallShortsShelfExperimentHooks(void) {
    gShelfVideos=[NSMutableSet set]; gHeldVideo=[NSMutableDictionary dictionary]; gHeldTime=[NSMutableDictionary dictionary];
    YTKACEInstallInstanceHook(@"YTInlineMutedPlaybackContainerController",@"handleEarlyFinishedPlayback",(IMP)EarlyFinished,&OrigEarlyFinished);
    YTKACEInstallInstanceHook(@"YTInlineMutedPlaybackContainerController",@"handleFinishedPlayback",(IMP)Finished,&OrigFinished);
    YTKACEInstallInstanceHook(@"YTInlineMutedPlaybackContainerController",@"resetStartTimes",(IMP)ResetStartTimes,&OrigResetStartTimes);
    YTKACEInstallInstanceHook(@"YTInlineMutedPlaybackContainerController",@"startPlayback",(IMP)StartPlayback,&OrigStartPlayback);
    YTKACEInstallInstanceHook(@"YTInlineMutedPlaybackContainerController",@"resumeInlinePlayback",(IMP)ResumePlayback,&OrigResumePlayback);
    YTKACEInstallInstanceHook(@"YTInlineMutedPlaybackContainerController",@"pauseInlinePlayback",(IMP)PausePlayback,&OrigPausePlayback);
    YTKACEInstallInstanceHook(@"YTInlineMutedPlaybackContainerController",@"setPlaybackItem:",(IMP)SetPlaybackItem,&OrigSetPlaybackItem);
    YTKACEInstallInstanceHook(@"YTInlineMutedPlaybackShortsPlayerOverlayViewController",@"setEntry:",(IMP)OverlaySetEntry,&OrigOverlaySetEntry);
    YTKACEInstallInstanceHook(@"YTInlineMutedPlaybackShortsPlayerOverlayViewController",@"setPlayerResponse:CPN:",(IMP)OverlaySetResponse,&OrigOverlaySetPlayerResponse);
    YTKACEInstallInstanceHook(@"YTInlineMutedPlaybackShortsPlayerOverlayViewController",@"setActiveSingleVideo:",(IMP)OverlaySetVideo,&OrigOverlaySetActiveVideo);
    YTKACEInstallInstanceHook(@"YTInlineMutedPlaybackShortsPlayerOverlayViewController",@"resetAndShowLoading:",(IMP)OverlayReset,&OrigOverlayResetLoading);
    YTKACEInstallInstanceHook(@"YTSingleVideoController",@"loopBehavior",(IMP)LoopBehavior,&OrigLoopBehavior);
    YTKACEInstallInstanceHook(@"YTSingleVideoController",@"setLoopBehavior:",(IMP)SetLoopBehavior,&OrigSetLoopBehavior);
    YTKACEInstallInstanceHook(@"YTSingleVideoController",@"loopingEnabled",(IMP)LoopingEnabled,&OrigLoopingEnabled);
    YTKACEInstallInstanceHook(@"YTSingleVideoController",@"setLoopingEnabled:",(IMP)SetLoopingEnabled,&OrigSetLoopingEnabled);
    YTKACEInstallInstanceHook(@"YTSingleVideoController",@"maybeLoopPlayback",(IMP)MaybeLoopPlayback,&OrigMaybeLoopPlayback);
    dispatch_async(dispatch_get_main_queue(),^{gTimer=[NSTimer scheduledTimerWithTimeInterval:.20 repeats:YES block:^(__unused NSTimer *t){Refresh();}];});
}
