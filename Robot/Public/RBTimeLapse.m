#import "RBTimeLapse.h"
#import "NSObject+RBSwizzle.h"
#import <pthread/pthread.h>

typedef struct __CFRuntimeBase {
    uintptr_t _cfisa;
    uint8_t _cfinfo[4];
#if __LP64__
    uint32_t _rc;
#endif
} CFRuntimeBase;

typedef struct __CFRunLoopMode *CFRunLoopModeRef;

struct __CFRunLoopMode {
    CFRuntimeBase _base;
    pthread_mutex_t _lock;	/* must have the run loop locked before locking this */
    CFStringRef _name;
    Boolean _stopped;
    char _padding[3];
    CFMutableSetRef _sources0;
    CFMutableSetRef _sources1;
    CFMutableArrayRef _observers;
    CFMutableArrayRef _timers;
    CFMutableDictionaryRef _portToV1SourceMap;
    mach_port_t _portSet;
    CFIndex _observerMask;
    // more fields here, but we don't care.
};

typedef struct __CFRunLoop *CFRunLoopRef;

struct __CFRunLoop {
    CFRuntimeBase _base;
    pthread_mutex_t _lock;			/* locked for accessing mode list */
    mach_port_t _wakeUpPort;			// used for CFRunLoopWakeUp
    Boolean _unused;
    void *_perRunData;              // reset for runs of the run loop
    pthread_t _pthread;
    uint32_t _winthread;
    CFMutableSetRef _commonModes;
    CFMutableSetRef _commonModeItems;
    CFRunLoopModeRef _currentMode;
    CFMutableSetRef _modes;
    void *_blocks_head;
    void *_blocks_tail;
    CFTypeRef _counterpart;
};

extern void _CFRuntimeSetInstanceTypeID(CFTypeRef cf, CFTypeID newTypeID);

static CFRunLoopModeRef CFRunLoopFindMode(CFRunLoopRef rl, CFStringRef modeName) {
    NSSet *set = (__bridge NSSet *)(rl->_modes);
    id modeObj = [[set objectsPassingTest:^BOOL(id obj, BOOL *stop) {
        CFRunLoopModeRef rlm = (__bridge CFRunLoopModeRef)(obj);
        return CFStringCompare(rlm->_name, modeName, 0) == kCFCompareEqualTo;
    }] anyObject];
    if (modeObj) {
        return (__bridge CFRunLoopModeRef)modeObj;
    }
    return NULL;
}

static bool CFRunLoopIsWaitingForDelayedPerform(CFRunLoopRef runLoop) {
    NSString *description = [(__bridge id)runLoop description];
    return [description containsString:@"callout = (Delayed Perform)"];
}

static bool CFRunLoopIsWaitingWithoutDelayedPerforms(CFRunLoopRef runLoop) {
    return CFRunLoopIsWaiting(runLoop)
        || CFRunLoopIsWaitingForDelayedPerform(runLoop);
}

static void CFRunLoopTruncateTimers(CFRunLoopRef runLoop, CFStringRef runLoopMode) {
    CFRunLoopModeRef mode = CFRunLoopFindMode(runLoop, kCFRunLoopDefaultMode);
    for (NSUInteger i = 0; i < CFArrayGetCount(mode->_timers); i++) {
        CFRunLoopTimerRef timer = (CFRunLoopTimerRef)CFArrayGetValueAtIndex(mode->_timers, i);
        if (CFRunLoopTimerIsValid(timer)) {
            CFRunLoopTimerSetNextFireDate(timer, [NSDate timeIntervalSinceReferenceDate]);
        }
    }
}

static void CFRunLoopInvalidateTimers(CFRunLoopRef runLoop, CFStringRef runLoopMode) {
    CFRunLoopModeRef mode = CFRunLoopFindMode(runLoop, kCFRunLoopDefaultMode);
    for (NSUInteger i = 0; i < CFArrayGetCount(mode->_timers); i++) {
        CFRunLoopTimerRef timer = (CFRunLoopTimerRef)CFArrayGetValueAtIndex(mode->_timers, i);
        CFRunLoopTimerInvalidate(timer);
    }
}

@implementation RBTimeLapse

+ (void)disableAnimationsInBlock:(void(^)())block
{
    // Disabling animations isn't the difficult part. It's properly invoking all executed
    // animation callbacks to ensure they work in a synchronous fashion.
    //
    // For example, UIAlertView's animation is a series of animations and callbacks like:
    //
    //  0. Tell delegate "will" show
    //  1. In Parallel: Fade In, Grow
    //  2. After #1, slowed growth            -
    //  3. After #2, small shrinking          | - "Pop" animation
    //  4. After #3, small growth             |
    //  5. After #4, small shrinking          -
    //  6. After #5, tell delegate "did" show
    //     using performSelector:
    //
    // We want both delegate methods to fire, so we need to figure out how to trigger this.
    //
    // Since CoreAnimation's callbacks attach to the runloop to run on the next iteration,
    // we must advance the run loop to advance.

    // Disable UIView animations
    [UIView setAnimationsEnabled:NO];
    {
        // this UIView transaction will finish after all animation completion callbacks fire
        [UIView beginAnimations:@"net.jeffhui.robot.animationless" context:0];
        {
            [UIView setAnimationDuration:0];
            [UIView setAnimationDelay:0];
            [UIView setAnimationDelegate:self];
            [UIView setAnimationWillStartSelector:@selector(advanceMainRunLoop)];
            [UIView setAnimationDidStopSelector:@selector(advanceMainRunLoop)];

            // Disable CoreAnimation
            [CATransaction begin];
            {
                // attach callbacks to core animations to run the runloops
                [CATransaction setCompletionBlock:^{
                    [self advanceMainRunLoop];
                }];
                [CATransaction setAnimationDuration:0];
                block();
            }
            [CATransaction commit];
        }
        [UIView commitAnimations];
    }
    [UIView setAnimationsEnabled:YES];

    // trigger animation callbacks
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate date]];
}

+ (void)advanceMainRunLoop
{
    [self advanceRunLoop:[NSRunLoop mainRunLoop]];
}

+ (void)advanceRunLoop:(NSRunLoop *)nsRunLoop
{
    CFRunLoopRef runLoop = [nsRunLoop getCFRunLoop];
    do {
        CFRunLoopTruncateTimers(runLoop, kCFRunLoopDefaultMode);
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate date]];
    } while (CFRunLoopIsWaitingWithoutDelayedPerforms(runLoop));

}

// TODO: delete this?
+ (void)invalidateTimersForRunLoop:(NSRunLoop *)runLoop
{
    CFRunLoopInvalidateTimers([runLoop getCFRunLoop], kCFRunLoopDefaultMode);
    CFRunLoopInvalidateTimers([runLoop getCFRunLoop], kCFRunLoopCommonModes);
}

@end