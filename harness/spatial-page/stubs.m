// What the Sing page and the Spatial voice page call outside their own files: Sing.x's and SGSingModel.m's state,
// a model on the phone and Sing off, and Shared/HeadGestures' motion, played from a script of the head's yaw
// at 25 motions a second, as AirPods send them, while the preview listens.
#import <CoreMotion/CoreMotion.h>
#import <objc/runtime.h>
#import "Core/SGCore.h"
#import "Shared/Sing/Sing.h"

#pragma mark - Sing

NSString *const SGSingChangedNotification = @"SGSingChangedNotification";
NSString *SGSingStatusText(void) { return SGSingOn() ? @"Singing" : @"Off"; }
NSString *SGSingStatusDetail(void) { return nil; }
NSString *SGSingMissing(void) { return nil; }
BOOL SGSingOn(void) { return SGHidden(SGKeySing); }
void SGSetSingOn(BOOL on) { SGSetEnabled(SGKeySing, on); }
float SGSingLevel(void) { return 0.15f; }
void SGSetSingLevel(float level) {}
void SGSetSingIgnoresHeat(BOOL ignores) {}
BOOL SGSingSpatialAvailable(void) { return YES; }
BOOL SGSingSpatial(void) { return SGHidden(SGKeySingSpatial); }
void SGSetSingSpatial(BOOL on) {
    SGSetEnabled(SGKeySingSpatial, on);
    NSLog(@"[harness] spatial voice %@", on ? @"on" : @"off");
}
void SGSingComputeUnitsChanged(void) {}
SGSingModelState SGSingModelCurrentState(void) { return SGSingModelReady; }
double SGSingModelProgress(void) { return 1; }
BOOL SGSingModelWaitingForNetwork(void) { return NO; }
NSString *SGSingModelError(void) { return nil; }
NSString *SGSingModelSizeText(void) { return @"190 MB"; }
void SGSingDownloadModel(void) {}
void SGSingCancelModelDownload(void) {}
void SGSingDeleteModel(void) {}
NSArray<NSString *> *SGSingComputeUnitNames(void) { return @[@"GPU and Neural Engine", @"GPU", @"Neural Engine"]; }
BOOL SGSingOSSupported(void) { return YES; }
BOOL SGSingDeviceSupported(void) { return YES; }

#pragma mark - the head

@interface FakeAttitude : NSObject
@property (nonatomic) double yaw;
@end
@implementation FakeAttitude
@end

@interface FakeMotion : NSObject
@property (nonatomic) NSTimeInterval timestamp;
@property (nonatomic, strong) FakeAttitude *attitude;
@end
@implementation FakeMotion
@end

// From main.m's launch line: what Motion & Fitness answers, and the head's yaw at a time since launch (NAN: no
// headphones, so no motion).
CMAuthorizationStatus sg_motionAllowed = CMAuthorizationStatusNotDetermined;
double (^sg_headYaw)(double seconds);

static CMAuthorizationStatus fakeAuthorization(id self, SEL _cmd) { return sg_motionAllowed; }

__attribute__((constructor)) static void sg_takeOverPermission(void) {
    method_setImplementation(class_getClassMethod(CMHeadphoneMotionManager.class, @selector(authorizationStatus)), (IMP)fakeAuthorization);
}

static NSMutableDictionary<NSString *, void (^)(CMDeviceMotion *)> *sg_listeners;
static dispatch_queue_t sg_queue;
static dispatch_source_t sg_timer;

void SGHeadMotionListen(NSString *name, void (^handler)(CMDeviceMotion *motion)) {
    if (!sg_listeners) {
        sg_listeners = [NSMutableDictionary dictionary];
        sg_queue = dispatch_queue_create("harness.motion", DISPATCH_QUEUE_SERIAL);
    }
    void (^old)(CMDeviceMotion *) = sg_listeners[name];
    sg_listeners[name] = [handler copy];
    NSLog(@"[harness] %@ %@ the head", name, handler ? @"listens to" : @"stops listening to");
    if (old && !handler) dispatch_async(sg_queue, ^{ old(nil); });
    NSArray *handlers = sg_listeners.allValues;
    if (handlers.count && !sg_timer && sg_headYaw) {
        static CFTimeInterval launched;
        if (!launched) launched = CACurrentMediaTime();
        sg_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, sg_queue);
        dispatch_source_set_timer(sg_timer, DISPATCH_TIME_NOW, NSEC_PER_SEC / 25, 0);
        dispatch_source_set_event_handler(sg_timer, ^{
            double now = CACurrentMediaTime() - launched, yaw = sg_headYaw(now);
            if (isnan(yaw)) return;
            FakeMotion *motion = [FakeMotion new];
            motion.timestamp = CACurrentMediaTime();
            motion.attitude = [FakeAttitude new];
            motion.attitude.yaw = yaw;
            for (void (^each)(CMDeviceMotion *) in handlers) each((CMDeviceMotion *)motion);
        });
        dispatch_resume(sg_timer);
    } else if (!handlers.count && sg_timer) {
        dispatch_source_cancel(sg_timer);
        sg_timer = nil;
    }
}

void SGHeadMotionAskPermission(void) {
    NSLog(@"[harness] Motion & Fitness asked for");
}
