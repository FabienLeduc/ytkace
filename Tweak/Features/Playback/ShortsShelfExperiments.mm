#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <math.h>

/*
 * Home-feed Shorts shelf/grid experiments.
 *
 * These deliberately target the stock YouTube inline-muted playback path seen
 * in YouTube 21.38.3, rather than the full-screen Shorts player:
 *   YTInlineMutedPlaybackContainerController
 *   YTInlineMutedPlaybackShortsPlayerOverlayViewController
 *   YTColdConfig.shortsInlineMutedWatchRestartThresholdMs
 *   YTHotConfig.inlineMutedWatchRestartThreshold
 *   YTColdConfig.enableShortsInlineMutedWatchResumeFromCurrentTime
 */

static IMP OrigColdRestartThreshold;
static IMP OrigHotRestartThreshold;
static IMP OrigResumeCurrentTime;
static IMP OrigMaxPlaybackLength;
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
static NSUInteger gStarts, gResumes, gPauses, gFinished, gEarlyFinished;
static NSUInteger gItems, gEntries, gResponses, gVideos, gResets;
static double gLastMaxLength = -1.0;
static long long gColdThreshold = -1;
static double gHotThreshold = -1.0;
static BOOL gResumeFlag;

static NSInteger ShelfMode(void) {
    id v = YTKACEPreferenceObject(@"YTKACE.Preference.Playback.ShortsShelfTestMode");
    return [v respondsToSelector:@selector(integerValue)] ? [v integerValue] : 0;
}

BOOL YTKACEShortsShelfBypassPlaybackFix(void) {
    return ShelfMode() == 10;
}

static BOOL ShelfDebug(void) {
    return [YTKACEPreferenceObject(@"YTKACE.Preference.Playback.ShortsShelfDebugOverlay") boolValue];
}

static NSString *ModeName(void) {
    switch (ShelfMode()) {
        case 1: return @"Restart threshold 5s";
        case 2: return @"Restart threshold 60s";
        case 3: return @"Resume-current OFF";
        case 4: return @"Resume-current ON";
        case 5: return @"Max length 5s";
        case 6: return @"Max length 60s";
        case 7: return @"Ignore early-finished";
        case 8: return @"Ignore finished";
        case 9: return @"Block resetStartTimes";
        case 10: return @"Bypass YTKACE Playback Fix";
        default: return @"Observe / Stock";
    }
}

static void Event(NSString *event, id obj) {
    gLastEvent = event ?: @"?";
    gLastClass = obj ? NSStringFromClass([obj class]) : @"-";
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
        @"HOME SHORTS SHELF DEBUG\nmode: %@\nlast: %@\nclass: %@\nstart/resume/pause: %lu/%lu/%lu\nfinished/early: %lu/%lu\nitem/entry/response/video: %lu/%lu/%lu/%lu\nresetStartTimes: %lu\nmaxPlaybackLength: %.3f\nrestart threshold cold/hot: %lld / %.3f\nresume-current: %@",
        ModeName(), gLastEvent, gLastClass,
        (unsigned long)gStarts, (unsigned long)gResumes, (unsigned long)gPauses,
        (unsigned long)gFinished, (unsigned long)gEarlyFinished,
        (unsigned long)gItems, (unsigned long)gEntries, (unsigned long)gResponses,
        (unsigned long)gVideos, (unsigned long)gResets, gLastMaxLength,
        gColdThreshold, gHotThreshold, gResumeFlag ? @"YES" : @"NO"];
    CGFloat width = MIN(window.bounds.size.width - 20, 440.0);
    CGSize fit = [gShelfLabel sizeThatFits:CGSizeMake(width - 16, CGFLOAT_MAX)];
    gShelfLabel.frame = CGRectMake(10, 54, width, fit.height + 14);
    [window bringSubviewToFront:gShelfLabel];
}

static long long ColdThreshold(id self, SEL _cmd) {
    long long value = OrigColdRestartThreshold ? ((long long(*)(id,SEL))OrigColdRestartThreshold)(self,_cmd) : 0;
    NSInteger mode = ShelfMode();
    if (mode == 1) value = 5000;
    else if (mode == 2) value = 60000;
    gColdThreshold = value;
    Event(@"cold restart threshold read", self);
    return value;
}

static double HotThreshold(id self, SEL _cmd) {
    double value = OrigHotRestartThreshold ? ((double(*)(id,SEL))OrigHotRestartThreshold)(self,_cmd) : 0;
    NSInteger mode = ShelfMode();
    /* Hot config is exposed as seconds in this build; preserve that unit. */
    if (mode == 1) value = 5.0;
    else if (mode == 2) value = 60.0;
    gHotThreshold = value;
    Event(@"hot restart threshold read", self);
    return value;
}

static BOOL ResumeCurrent(id self, SEL _cmd) {
    BOOL value = OrigResumeCurrentTime ? ((BOOL(*)(id,SEL))OrigResumeCurrentTime)(self,_cmd) : NO;
    if (ShelfMode() == 3) value = NO;
    else if (ShelfMode() == 4) value = YES;
    gResumeFlag = value;
    Event(@"resume-current flag read", self);
    return value;
}

static double MaxLength(id self, SEL _cmd) {
    double value = OrigMaxPlaybackLength ? ((double(*)(id,SEL))OrigMaxPlaybackLength)(self,_cmd) : 0;
    if (ShelfMode() == 5) value = 5.0;
    else if (ShelfMode() == 6) value = 60.0;
    gLastMaxLength = value;
    Event(@"maxPlaybackLength", self);
    return value;
}

static void EarlyFinished(id self, SEL _cmd) {
    gEarlyFinished++;
    Event(@"EARLY FINISHED", self);
    if (ShelfMode() == 7) return;
    if (OrigEarlyFinished) ((void(*)(id,SEL))OrigEarlyFinished)(self,_cmd);
}

static void Finished(id self, SEL _cmd) {
    gFinished++;
    Event(@"FINISHED", self);
    if (ShelfMode() == 8) return;
    if (OrigFinished) ((void(*)(id,SEL))OrigFinished)(self,_cmd);
}

static void ResetStartTimes(id self, SEL _cmd) {
    gResets++;
    Event(@"resetStartTimes", self);
    if (ShelfMode() == 9) return;
    if (OrigResetStartTimes) ((void(*)(id,SEL))OrigResetStartTimes)(self,_cmd);
}

static void StartPlayback(id self, SEL _cmd) {
    gStarts++; Event(@"startPlayback", self);
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
    gResponses++; Event(@"shorts overlay setPlayerResponse", response ?: self);
    if (OrigOverlaySetPlayerResponse) ((void(*)(id,SEL,id,id))OrigOverlaySetPlayerResponse)(self,_cmd,response,cpn);
}
static void OverlaySetVideo(id self, SEL _cmd, id video) {
    gVideos++; Event(@"shorts overlay setActiveSingleVideo", video ?: self);
    if (OrigOverlaySetActiveVideo) ((void(*)(id,SEL,id))OrigOverlaySetActiveVideo)(self,_cmd,video);
}
static void OverlayReset(id self, SEL _cmd, BOOL loading) {
    Event(loading ? @"shorts overlay reset/loading YES" : @"shorts overlay reset/loading NO", self);
    if (OrigOverlayResetLoading) ((void(*)(id,SEL,BOOL))OrigOverlayResetLoading)(self,_cmd,loading);
}

void YTKACEInstallShortsShelfExperimentHooks(void) {
    YTKACEInstallInstanceHook(@"YTColdConfig", @"shortsInlineMutedWatchRestartThresholdMs", (IMP)ColdThreshold, &OrigColdRestartThreshold);
    YTKACEInstallInstanceHook(@"YTHotConfig", @"inlineMutedWatchRestartThreshold", (IMP)HotThreshold, &OrigHotRestartThreshold);
    YTKACEInstallInstanceHook(@"YTColdConfig", @"enableShortsInlineMutedWatchResumeFromCurrentTime", (IMP)ResumeCurrent, &OrigResumeCurrentTime);

    YTKACEInstallInstanceHook(@"YTInlineMutedPlaybackContainerController", @"maxPlaybackLength", (IMP)MaxLength, &OrigMaxPlaybackLength);
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
