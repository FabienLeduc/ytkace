#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static IMP YTKACEOriginalInlineSetLoopingController;
static IMP YTKACEOriginalLoopHandleBehavior;
static IMP YTKACEOriginalLoopIfNecessary;
static IMP YTKACEOriginalLoopSetBehavior;
static IMP YTKACEOriginalLoopSetEnabled;
static const void *YTKACEInlineShortsOwnerKey = &YTKACEInlineShortsOwnerKey;
static UILabel *YTKACEInlineDebugLabel;

static NSInteger YTKACEInlineTestMode(void) {
    id value = YTKACEPreferenceObject(@"YTKACE.Preference.Playback.InlineShortsTestMode");
    return [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : 0;
}

static BOOL YTKACEInlineDebugEnabled(void) {
    return [YTKACEPreferenceObject(@"YTKACE.Preference.Playback.InlineShortsDiagnosticOverlay") boolValue];
}

static id YTKACESafeValue(id object, NSString *key) {
    if (object == nil) return nil;
    @try { return [object valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static id YTKACEFirstValue(id object, NSArray<NSString *> *keys) {
    for (NSString *key in keys) {
        id value = YTKACESafeValue(object, key);
        if (value != nil) return value;
    }
    return nil;
}

static NSNumber *YTKACEFirstNumber(id object, NSArray<NSString *> *keys) {
    id value = YTKACEFirstValue(object, keys);
    return [value isKindOfClass:NSNumber.class] ? value : nil;
}

static id YTKACEInlineOwnerForLoopController(id controller) {
    NSValue *box = objc_getAssociatedObject(controller, YTKACEInlineShortsOwnerKey);
    return [box isKindOfClass:NSValue.class] ? box.nonretainedObjectValue : nil;
}

static id YTKACEPlaybackObject(id owner, id loopController) {
    NSArray<NSString *> *keys = @[@"player", @"videoPlayer", @"playbackController", @"activeVideo", @"playerViewController"];
    id candidate = YTKACEFirstValue(owner, keys);
    if (candidate == nil) candidate = YTKACEFirstValue(loopController, keys);
    return candidate ?: owner ?: loopController;
}

static NSString *YTKACEDesc(id object, NSString *key) {
    id value = YTKACESafeValue(object, key);
    return value ? [value description] : @"?";
}

static void YTKACEShowInlineDebug(id loopController, NSString *event) {
    if (!YTKACEInlineDebugEnabled()) {
        dispatch_async(dispatch_get_main_queue(), ^{ [YTKACEInlineDebugLabel removeFromSuperview]; });
        return;
    }

    id owner = YTKACEInlineOwnerForLoopController(loopController);
    id player = YTKACEPlaybackObject(owner, loopController);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (YTKACEInlineDebugLabel == nil) {
            YTKACEInlineDebugLabel = [[UILabel alloc] initWithFrame:CGRectZero];
            YTKACEInlineDebugLabel.numberOfLines = 0;
            YTKACEInlineDebugLabel.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightSemibold];
            YTKACEInlineDebugLabel.textColor = UIColor.whiteColor;
            YTKACEInlineDebugLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.82];
            YTKACEInlineDebugLabel.layer.cornerRadius = 8;
            YTKACEInlineDebugLabel.layer.masksToBounds = YES;
            YTKACEInlineDebugLabel.userInteractionEnabled = NO;
        }
        UIWindow *window = nil;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive || ![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
                if (candidate.isKeyWindow) { window = candidate; break; }
            }
            if (window) break;
        }
        if (!window) return;
        if (YTKACEInlineDebugLabel.superview != window) {
            [YTKACEInlineDebugLabel removeFromSuperview];
            [window addSubview:YTKACEInlineDebugLabel];
        }
        YTKACEInlineDebugLabel.text = [NSString stringWithFormat:
            @"INLINE SHORTS DEBUG\n%@\nmode=%ld behavior=%@ count=%@ enabled=%@\ntime=%@ duration=%@ seekable=%@",
            event ?: @"event", (long)YTKACEInlineTestMode(),
            YTKACEDesc(loopController, @"loopBehavior"), YTKACEDesc(loopController, @"loopCount"),
            YTKACEDesc(loopController, @"loopingEnabled"),
            YTKACEDesc(player, @"currentVideoMediaTime"), YTKACEDesc(player, @"mediaDuration"),
            YTKACEDesc(player, @"maximumSeekableTime")];
        CGFloat width = MIN(window.bounds.size.width - 24.0, 430.0);
        CGSize size = [YTKACEInlineDebugLabel sizeThatFits:CGSizeMake(width - 16.0, CGFLOAT_MAX)];
        YTKACEInlineDebugLabel.frame = CGRectMake(12.0, 58.0, width, size.height + 14.0);
        [window bringSubviewToFront:YTKACEInlineDebugLabel];
    });
}

static BOOL YTKACEShouldSuppressLoop(id controller) {
    if (YTKACEInlineOwnerForLoopController(controller) == nil) return NO;
    NSInteger mode = YTKACEInlineTestMode();
    if (mode == 1) return YES; // Block every loop callback for inline Shorts only.

    if (mode != 2 && mode != 3) return NO;
    id player = YTKACEPlaybackObject(YTKACEInlineOwnerForLoopController(controller), controller);
    NSNumber *timeValue = YTKACEFirstNumber(player, @[@"currentVideoMediaTime", @"currentMediaTime", @"currentTime"]);
    if (timeValue == nil) return NO;
    double time = timeValue.doubleValue;
    if (mode == 2) return time < 5.0;

    NSNumber *durationValue = YTKACEFirstNumber(player, @[@"mediaDuration", @"duration", @"maximumSeekableTime"]);
    if (durationValue == nil) return NO;
    double duration = durationValue.doubleValue;
    return duration > 0.0 && time + 0.35 < duration;
}

static void YTKACEApplyModeToController(id controller) {
    if (controller == nil) return;
    NSInteger mode = YTKACEInlineTestMode();
    // Values follow the ReelLoopBehavior enum ordering embedded in YouTube 21.38.3:
    // Unknown=0, SinglePlay=1, Repeat=2, EndScreen=3, AutoAdvance=4...
    if (mode == 4 && [controller respondsToSelector:NSSelectorFromString(@"setLoopBehavior:")]) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(controller, NSSelectorFromString(@"setLoopBehavior:"), 1);
    } else if (mode == 5 && [controller respondsToSelector:NSSelectorFromString(@"setLoopBehavior:")]) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(controller, NSSelectorFromString(@"setLoopBehavior:"), 2);
    } else if (mode == 6 && [controller respondsToSelector:NSSelectorFromString(@"setLoopingEnabled:")]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(controller, NSSelectorFromString(@"setLoopingEnabled:"), NO);
    }
}

static void YTKACEInlineSetLoopingController(id receiver, SEL selector, id controller) {
    if (YTKACEOriginalInlineSetLoopingController) {
        ((void (*)(id, SEL, id))YTKACEOriginalInlineSetLoopingController)(receiver, selector, controller);
    }
    if (controller != nil) {
        objc_setAssociatedObject(controller, YTKACEInlineShortsOwnerKey,
                                 [NSValue valueWithNonretainedObject:receiver], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        YTKACEApplyModeToController(controller);
        YTKACEShowInlineDebug(controller, @"attached inline Shorts loop controller");
    }
}

static void YTKACELoopHandleBehavior(id receiver, SEL selector) {
    BOOL inlineShorts = YTKACEInlineOwnerForLoopController(receiver) != nil;
    if (inlineShorts) {
        YTKACEApplyModeToController(receiver);
        YTKACEShowInlineDebug(receiver, @"EVENT: handleLoopBehavior");
        if (YTKACEShouldSuppressLoop(receiver)) {
            YTKACEShowInlineDebug(receiver, @"ACTION: loop suppressed");
            return;
        }
    }
    if (YTKACEOriginalLoopHandleBehavior) ((void (*)(id, SEL))YTKACEOriginalLoopHandleBehavior)(receiver, selector);
}

static void YTKACELoopIfNecessary(id receiver, SEL selector, NSInteger status) {
    BOOL inlineShorts = YTKACEInlineOwnerForLoopController(receiver) != nil;
    if (inlineShorts) {
        YTKACEApplyModeToController(receiver);
        YTKACEShowInlineDebug(receiver, [NSString stringWithFormat:@"EVENT: loopIfNecessary status=%ld", (long)status]);
        if (YTKACEShouldSuppressLoop(receiver)) {
            YTKACEShowInlineDebug(receiver, @"ACTION: loopIfNecessary suppressed");
            return;
        }
    }
    if (YTKACEOriginalLoopIfNecessary) ((void (*)(id, SEL, NSInteger))YTKACEOriginalLoopIfNecessary)(receiver, selector, status);
}

static void YTKACELoopSetBehavior(id receiver, SEL selector, NSInteger behavior) {
    if (YTKACEInlineOwnerForLoopController(receiver) != nil) {
        NSInteger mode = YTKACEInlineTestMode();
        if (mode == 4) behavior = 1;
        else if (mode == 5) behavior = 2;
        YTKACEShowInlineDebug(receiver, [NSString stringWithFormat:@"EVENT: setLoopBehavior=%ld", (long)behavior]);
    }
    if (YTKACEOriginalLoopSetBehavior) ((void (*)(id, SEL, NSInteger))YTKACEOriginalLoopSetBehavior)(receiver, selector, behavior);
}

static void YTKACELoopSetEnabled(id receiver, SEL selector, BOOL enabled) {
    if (YTKACEInlineOwnerForLoopController(receiver) != nil) {
        if (YTKACEInlineTestMode() == 6) enabled = NO;
        YTKACEShowInlineDebug(receiver, [NSString stringWithFormat:@"EVENT: setLoopingEnabled=%@", enabled ? @"YES" : @"NO"]);
    }
    if (YTKACEOriginalLoopSetEnabled) ((void (*)(id, SEL, BOOL))YTKACEOriginalLoopSetEnabled)(receiver, selector, enabled);
}

void YTKACEInstallInlineShortsDiagnosticHooks(void) {
    // The association is established only by the dedicated Home-feed Shorts overlay.
    YTKACEInstallInstanceHook(@"YTInlineMutedPlaybackShortsPlayerOverlayViewController",
                             @"setLoopingPlaybackController:", (IMP)YTKACEInlineSetLoopingController,
                             &YTKACEOriginalInlineSetLoopingController);
    YTKACEInstallInstanceHook(@"YTLoopingPlaybackController", @"handleLoopBehavior",
                             (IMP)YTKACELoopHandleBehavior, &YTKACEOriginalLoopHandleBehavior);
    YTKACEInstallInstanceHook(@"YTLoopingPlaybackController", @"loopIfNecessaryForChangeToPlayerStatus:",
                             (IMP)YTKACELoopIfNecessary, &YTKACEOriginalLoopIfNecessary);
    YTKACEInstallInstanceHook(@"YTLoopingPlaybackController", @"setLoopBehavior:",
                             (IMP)YTKACELoopSetBehavior, &YTKACEOriginalLoopSetBehavior);
    YTKACEInstallInstanceHook(@"YTLoopingPlaybackController", @"setLoopingEnabled:",
                             (IMP)YTKACELoopSetEnabled, &YTKACEOriginalLoopSetEnabled);
}
