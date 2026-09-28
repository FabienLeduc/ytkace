#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <math.h>
#import <dlfcn.h>

/*
 * Home-feed Shorts shelf/grid experiments.
 *
 * These deliberately target the stock YouTube inline-muted playback path seen
 * in YouTube 21.38.3, rather than the full-screen Shorts player:
 *   YTInlineMutedPlaybackContainerController
 *   YTInlineMutedPlaybackShortsPlayerOverlayViewController
 */

static IMP OrigEarlyFinished;
static IMP OrigFinished;
static IMP OrigResetStartTimes;
static IMP OrigStartPlayback;
static IMP OrigResumePlayback;
static IMP OrigPausePlayback;
static IMP OrigSetPlaybackItem;
static IMP OrigOverlaySetEntry;
static IMP OrigOverlaySetPlayerResponse;
static IMP OrigOverlaySetActiveVideo;
static IMP OrigOverlayResetLoading;

static UILabel *gShelfLabel;
static NSTimer *gShelfTimer;
static NSString *gLastEvent = @"waiting for shelf";
static NSString *gLastClass = @"-";
static NSString *gLastCaller = @"-";
static NSString *gLastDetail = @"-";
static NSUInteger gStarts, gResumes, gPauses, gFinished, gEarlyFinished;
static NSUInteger gItems, gEntries, gResponses, gVideos, gResets;
static NSUInteger gBlockedStarts, gBlockedResponses, gBlockedVideos;
static CFTimeInterval gEpoch;
static NSMutableDictionary<NSValue *, NSNumber *> *gLastStartByContainer;
static NSMutableDictionary<NSValue *, NSValue *> *gLastResponseByOverlay;
static NSMutableDictionary<NSValue *, NSNumber *> *gLastResponseTimeByOverlay;
static NSMutableDictionary<NSValue *, NSValue *> *gLastVideoByOverlay;
static NSMutableDictionary<NSValue *, NSNumber *> *gLastVideoTimeByOverlay;

static NSInteger ShelfMode(void) {
    id v = YTKACEPreferenceObject(@"YTKACE.Preference.Playback.ShortsShelfTestMode");
    return [v respondsToSelector:@selector(integerValue)] ? [v integerValue] : 0;
}

BOOL YTKACEShortsShelfBypassPlaybackFix(void) {
    return NO; /* Playback Fix was ruled out by the previous test build. */
}

static BOOL ShelfDebug(void) {
    return [YTKACEPreferenceObject(@"YTKACE.Preference.Playback.ShortsShelfDebugOverlay") boolValue];
}

static NSString *ModeName(void) {
    switch (ShelfMode()) {
        case 1: return @"Block repeat start 5s";
        case 2: return @"Block repeat start 60s";
        case 3: return @"Block duplicate response 5s";
        case 4: return @"Block duplicate video 5s";
        case 5: return @"Block duplicate response+video 5s";
        default: return @"Trace only";
    }
}

static NSString *Caller(void *address) {
    Dl_info info;
    if (address && dladdr(address, &info) && info.dli_sname) {
        return [NSString stringWithUTF8String:info.dli_sname] ?: @"?";
    }
    return address ? [NSString stringWithFormat:@"%p", address] : @"-";
}

static void EventDetail(NSString *event, id obj, NSString *detail, void *caller) {
    gLastEvent = event ?: @"?";
    gLastClass = obj ? NSStringFromClass([obj class]) : @"-";
    gLastDetail = detail ?: @"-";
    gLastCaller = Caller(caller);
}

static void Event(NSString *event, id obj) {
    EventDetail(event, obj, @"-", __builtin_return_address(0));
}

static NSValue *PtrKey(id obj) {
    return [NSValue valueWithPointer:(__bridge const void *)obj];
}

static CFTimeInterval Now(void) {
    return CACurrentMediaTime();
}

static UIWindow *KeyWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) if (window.isKeyWindow) return window;
    }
    return nil;
}

static void RefreshOverlay(void) {
    if (!ShelfDebug()) {
        [gShelfLabel removeFromSuperview];
        return;
    }
    UIWindow *window = KeyWindow();
    if (!window) return;
    if (!gShelfLabel) {
        gShelfLabel = [UILabel new];
        gShelfLabel.numberOfLines = 0;
        gShelfLabel.font = [UIFont monospacedSystemFontOfSize:9.0 weight:UIFontWeightSemibold];
        gShelfLabel.textColor = UIColor.whiteColor;
        gShelfLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.86];
        gShelfLabel.layer.cornerRadius = 8;
        gShelfLabel.layer.masksToBounds = YES;
        gShelfLabel.userInteractionEnabled = NO;
    }
    if (gShelfLabel.superview != window) {
        [gShelfLabel removeFromSuperview];
        [window addSubview:gShelfLabel];
    }
    gShelfLabel.text = [NSString stringWithFormat:
        @"HOME SHORTS SHELF TRACE\nmode: %@\nlast: %@\nclass: %@\ndetail: %@\ncaller: %@\nstart/resume/pause: %lu/%lu/%lu\nfinished/early/item: %lu/%lu/%lu\nentry/response/video/reset: %lu/%lu/%lu/%lu\nBLOCKED start/response/video: %lu/%lu/%lu",
        ModeName(), gLastEvent, gLastClass, gLastDetail, gLastCaller,
        (unsigned long)gStarts, (unsigned long)gResumes, (unsigned long)gPauses,
        (unsigned long)gFinished, (unsigned long)gEarlyFinished, (unsigned long)gItems,
        (unsigned long)gEntries, (unsigned long)gResponses, (unsigned long)gVideos, (unsigned long)gResets,
        (unsigned long)gBlockedStarts, (unsigned long)gBlockedResponses, (unsigned long)gBlockedVideos];
    CGFloat width = MIN(window.bounds.size.width - 20, 440.0);
    CGSize fit = [gShelfLabel sizeThatFits:CGSizeMake(width - 16, CGFLOAT_MAX)];
    gShelfLabel.frame = CGRectMake(10, 54, width, fit.height + 14);
    [window bringSubviewToFront:gShelfLabel];
}

static void EarlyFinished(id self, SEL _cmd) {
    gEarlyFinished++;
    Event(@"EARLY FINISHED", self);
    if (OrigEarlyFinished) ((void(*)(id,SEL))OrigEarlyFinished)(self,_cmd);
}

static void Finished(id self, SEL _cmd) {
    gFinished++;
    Event(@"FINISHED", self);
    if (OrigFinished) ((void(*)(id,SEL))OrigFinished)(self,_cmd);
}

static void ResetStartTimes(id self, SEL _cmd) {
    gResets++;
    Event(@"resetStartTimes", self);
    if (OrigResetStartTimes) ((void(*)(id,SEL))OrigResetStartTimes)(self,_cmd);
}

static void StartPlayback(id self, SEL _cmd) {
    gStarts++;
    CFTimeInterval now = Now();
    NSValue *key = PtrKey(self);
    CFTimeInterval previous = [gLastStartByContainer[key] doubleValue];
    double dt = previous > 0 ? now - previous : -1.0;
    NSInteger mode = ShelfMode();
    double window = mode == 2 ? 60.0 : 5.0;
    BOOL block = (mode == 1 || mode == 2) && previous > 0 && dt < window;
    EventDetail(block ? @"BLOCKED startPlayback" : @"startPlayback", self,
                [NSString stringWithFormat:@"self=%p dt=%.3fs", self, dt],
                __builtin_return_address(0));
    if (block) { gBlockedStarts++; return; }
    gLastStartByContainer[key] = @(now);
    if (OrigStartPlayback) ((void(*)(id,SEL))OrigStartPlayback)(self,_cmd);
}
static void ResumePlayback(id self, SEL _cmd) {
    gResumes++; Event(@"resumeInlinePlayback", self);
    if (OrigResumePlayback) ((void(*)(id,SEL))OrigResumePlayback)(self,_cmd);
}
static void PausePlayback(id self, SEL _cmd) {
    gPauses++; Event(@"pauseInlinePlayback", self);
    if (OrigPausePlayback) ((void(*)(id,SEL))OrigPausePlayback)(self,_cmd);
}
static void SetPlaybackItem(id self, SEL _cmd, id item) {
    gItems++; Event(@"setPlaybackItem", item ?: self);
    if (OrigSetPlaybackItem) ((void(*)(id,SEL,id))OrigSetPlaybackItem)(self,_cmd,item);
}
static void OverlaySetEntry(id self, SEL _cmd, id entry) {
    gEntries++; Event(@"shorts overlay setEntry", entry ?: self);
    if (OrigOverlaySetEntry) ((void(*)(id,SEL,id))OrigOverlaySetEntry)(self,_cmd,entry);
}
static void OverlaySetResponse(id self, SEL _cmd, id response, id cpn) {
    gResponses++;
    CFTimeInterval now = Now();
    NSValue *key = PtrKey(self);
    NSValue *arg = response ? PtrKey(response) : nil;
    NSValue *last = gLastResponseByOverlay[key];
    CFTimeInterval previous = [gLastResponseTimeByOverlay[key] doubleValue];
    double dt = previous > 0 ? now - previous : -1.0;
    BOOL same = arg && last && [arg isEqual:last];
    NSInteger mode = ShelfMode();
    BOOL block = (mode == 3 || mode == 5) && same && previous > 0 && dt < 5.0;
    EventDetail(block ? @"BLOCKED setPlayerResponse" : @"setPlayerResponse", response ?: self,
                [NSString stringWithFormat:@"overlay=%p arg=%p same=%@ dt=%.3fs", self, response, same ? @"Y" : @"N", dt],
                __builtin_return_address(0));
    if (block) { gBlockedResponses++; return; }
    if (arg) gLastResponseByOverlay[key] = arg;
    gLastResponseTimeByOverlay[key] = @(now);
    if (OrigOverlaySetPlayerResponse) ((void(*)(id,SEL,id,id))OrigOverlaySetPlayerResponse)(self,_cmd,response,cpn);
}
static void OverlaySetVideo(id self, SEL _cmd, id video) {
    gVideos++;
    CFTimeInterval now = Now();
    NSValue *key = PtrKey(self);
    NSValue *arg = video ? PtrKey(video) : nil;
    NSValue *last = gLastVideoByOverlay[key];
    CFTimeInterval previous = [gLastVideoTimeByOverlay[key] doubleValue];
    double dt = previous > 0 ? now - previous : -1.0;
    BOOL same = arg && last && [arg isEqual:last];
    NSInteger mode = ShelfMode();
    BOOL block = (mode == 4 || mode == 5) && same && previous > 0 && dt < 5.0;
    EventDetail(block ? @"BLOCKED setActiveSingleVideo" : @"setActiveSingleVideo", video ?: self,
                [NSString stringWithFormat:@"overlay=%p arg=%p same=%@ dt=%.3fs", self, video, same ? @"Y" : @"N", dt],
                __builtin_return_address(0));
    if (block) { gBlockedVideos++; return; }
    if (arg) gLastVideoByOverlay[key] = arg;
    gLastVideoTimeByOverlay[key] = @(now);
    if (OrigOverlaySetActiveVideo) ((void(*)(id,SEL,id))OrigOverlaySetActiveVideo)(self,_cmd,video);
}
static void OverlayReset(id self, SEL _cmd, BOOL loading) {
    Event(loading ? @"shorts overlay reset/loading YES" : @"shorts overlay reset/loading NO", self);
    if (OrigOverlayResetLoading) ((void(*)(id,SEL,BOOL))OrigOverlayResetLoading)(self,_cmd,loading);
}

void YTKACEInstallShortsShelfExperimentHooks(void) {
    gEpoch = Now();
    gLastStartByContainer = [NSMutableDictionary dictionary];
    gLastResponseByOverlay = [NSMutableDictionary dictionary];
    gLastResponseTimeByOverlay = [NSMutableDictionary dictionary];
    gLastVideoByOverlay = [NSMutableDictionary dictionary];
    gLastVideoTimeByOverlay = [NSMutableDictionary dictionary];

    YTKACEInstallInstanceHook(@"YTInlineMutedPlaybackContainerController", @"handleEarlyFinishedPlayback", (IMP)EarlyFinished, &OrigEarlyFinished);
    YTKACEInstallInstanceHook(@"YTInlineMutedPlaybackContainerController", @"handleFinishedPlayback", (IMP)Finished, &OrigFinished);
    YTKACEInstallInstanceHook(@"YTInlineMutedPlaybackContainerController", @"resetStartTimes", (IMP)ResetStartTimes, &OrigResetStartTimes);
    YTKACEInstallInstanceHook(@"YTInlineMutedPlaybackContainerController", @"startPlayback", (IMP)StartPlayback, &OrigStartPlayback);
    YTKACEInstallInstanceHook(@"YTInlineMutedPlaybackContainerController", @"resumeInlinePlayback", (IMP)ResumePlayback, &OrigResumePlayback);
    YTKACEInstallInstanceHook(@"YTInlineMutedPlaybackContainerController", @"pauseInlinePlayback", (IMP)PausePlayback, &OrigPausePlayback);
    YTKACEInstallInstanceHook(@"YTInlineMutedPlaybackContainerController", @"setPlaybackItem:", (IMP)SetPlaybackItem, &OrigSetPlaybackItem);

    YTKACEInstallInstanceHook(@"YTInlineMutedPlaybackShortsPlayerOverlayViewController", @"setEntry:", (IMP)OverlaySetEntry, &OrigOverlaySetEntry);
    YTKACEInstallInstanceHook(@"YTInlineMutedPlaybackShortsPlayerOverlayViewController", @"setPlayerResponse:CPN:", (IMP)OverlaySetResponse, &OrigOverlaySetPlayerResponse);
    YTKACEInstallInstanceHook(@"YTInlineMutedPlaybackShortsPlayerOverlayViewController", @"setActiveSingleVideo:", (IMP)OverlaySetVideo, &OrigOverlaySetActiveVideo);
    YTKACEInstallInstanceHook(@"YTInlineMutedPlaybackShortsPlayerOverlayViewController", @"resetAndShowLoading:", (IMP)OverlayReset, &OrigOverlayResetLoading);

    dispatch_async(dispatch_get_main_queue(), ^{
        gShelfTimer = [NSTimer scheduledTimerWithTimeInterval:0.20 repeats:YES block:^(__unused NSTimer *timer) {
            RefreshOverlay();
        }];
    });
}
