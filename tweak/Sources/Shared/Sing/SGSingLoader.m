#import <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <os/proc.h>
#endif
#import "Core/SGLog.h"
#import "SGSingLoader.h"
#import "SGSingSeparator.h"

// The CPU copy loaded in 0.9-5 s on an M4 and the Neural Engine's in 44.6 s on an iPhone 15 Pro; a GPU load there
// never came back in 14 min. The CPU copy is what Sing waits on, the faster one runs beside a working Sing.
double SGSingLoaderCPUDeadline = 120, SGSingLoaderFastDeadline = 180, SGSingLoaderKeepSeconds = 60;
// A second copy took 1.07-1.15 GB more of the process's footprint on an M4, so it loads only with this much left.
static const unsigned long long kFastRoom = 1600ull * 1000 * 1000;
static const int kStillEvery = 30;

// One load of one copy.
@interface SGSingLoad : NSObject
@property (nonatomic) unsigned number;
@property (nonatomic) MLComputeUnits units;
@property (nonatomic) CFAbsoluteTime began;
@property (nonatomic) BOOL finished, abandoned;
@property (nonatomic) BOOL stayedActive;   // Spotify was active from its start to its end or deadline
@end

@implementation SGSingLoad
@end

static void (^sg_changed)(void);
static SGSingLoaderState sg_state;
static NSString *sg_error;
static SGSingSeparator *sg_separator;
static SGSingLoad *sg_cpuLoad, *sg_fastLoad;   // the loads that count; abandoned ones are let go
static unsigned sg_outstanding;                 // loads not come back yet, abandoned ones with them
static unsigned sg_attempts;
static NSURL *sg_url;
static MLComputeUnits sg_fastUnits = MLComputeUnitsCPUOnly;
static SGSingFastState sg_fastState;
static BOOL sg_fastTimedOutActive;
static BOOL sg_foreground;
static NSUInteger sg_keepToken;                 // counts the mic's releases and wants, so a stale minute drops nothing
static BOOL sg_wanted;                          // the mic is on: a faster copy is worth loading

// Run after the caller returns, so a listener that wants or purges again does not run inside it.
static void changed(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (sg_changed) sg_changed();
    });
}

NSString *SGSingUnitsName(MLComputeUnits units) {
    switch (units) {
        case MLComputeUnitsCPUAndGPU: return @"GPU";
        case MLComputeUnitsCPUAndNeuralEngine: return @"Neural Engine";
        case MLComputeUnitsAll: return @"GPU and Neural Engine";
        default: return @"CPU";
    }
}

// The memory the process has left before iOS closes it; 0 where the OS does not say (the Mac).
static unsigned long long memoryLeft(void) {
#if TARGET_OS_IPHONE
    return os_proc_available_memory();
#else
    return 0;
#endif
}

static NSString *memoryText(void) {
    unsigned long long left = memoryLeft();
    return left ? [NSString stringWithFormat:@"%.2f GB left to the process", left / 1e9] : @"memory left unknown";
}

// Whether a copy can load beside what is already in memory or still loading.
static BOOL roomForAnother(void) {
    unsigned long long left = memoryLeft();
    return !left || left >= kFastRoom;
}

static void still(SGSingLoad *load, int seconds) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kStillEvery * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (load.finished || load.abandoned) return;
        SGLog(@"sing: still loading the %@ copy (load %u), %d s", SGSingUnitsName(load.units), load.number, seconds + kStillEvery);
        still(load, seconds + kStillEvery);
    });
}

// Loads and warms a copy on a queue of its own; `done` runs on the main thread unless the load was abandoned
// first, and `late` when its deadline passes before it comes back.
static SGSingLoad *startLoad(NSURL *url, MLComputeUnits units, double deadline, void (^done)(MLModel *model, NSError *error),
                             void (^late)(SGSingLoad *load)) {
    SGSingLoad *load = [SGSingLoad new];
    load.number = ++sg_attempts;
    load.units = units;
    load.began = CFAbsoluteTimeGetCurrent();
    load.stayedActive = sg_foreground;
    sg_outstanding++;
    SGLog(@"sing: load %u, the %@ copy, starts (Spotify %@, thermal state %s, %@, %u loads out)", load.number, SGSingUnitsName(units),
          sg_foreground ? @"active" : @"not active", SGSingThermalName(), memoryText(), sg_outstanding);
    NSString *name = [NSString stringWithFormat:@"spotifyglass.sing.load.%u", load.number];
    dispatch_queue_t queue = dispatch_queue_create(name.UTF8String, dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
    dispatch_async(queue, ^{
        MLModelConfiguration *configuration = [MLModelConfiguration new];
        configuration.computeUnits = units;
        NSError *error;
        MLModel *model = [MLModel modelWithContentsOfURL:url configuration:configuration error:&error];
        double loaded = CFAbsoluteTimeGetCurrent() - load.began;
        double warm = model ? [SGSingSeparator warmUp:model error:&error] : -1;
        dispatch_async(dispatch_get_main_queue(), ^{
            sg_outstanding--;
            load.finished = YES;
            NSString *outcome = !model ? [NSString stringWithFormat:@"did not load after %.1f s: %@", loaded, error.localizedDescription]
                              : warm < 0 ? [NSString stringWithFormat:@"loaded in %.1f s, and its warm-up failed: %@", loaded, error.localizedDescription]
                                         : [NSString stringWithFormat:@"loaded in %.1f s, and its warm-up window of silence took %.1f s", loaded, warm];
            SGLog(@"sing: load %u, the %@ copy, %@%@", load.number, SGSingUnitsName(units), outcome,
                  load.abandoned ? @"; it was abandoned before, so it is let go" : @"");
            if (load.abandoned) return;
            done(warm >= 0 ? model : nil, error);
        });
    });
    still(load, 0);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(deadline * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (load.finished || load.abandoned) return;
        load.abandoned = YES;
        SGLog(@"sing: load %u, the %@ copy, has not come back in %.0f s (Spotify %@ throughout): abandoned", load.number, SGSingUnitsName(units),
              deadline, load.stayedActive ? @"active" : @"not always active");
        late(load);
    });
    return load;
}

static void startFast(void) {
    if (!sg_wanted || sg_state != SGSingLoaderReady || !sg_foreground || sg_fastUnits == MLComputeUnitsCPUOnly || sg_fastState != SGSingFastNone) return;
    if (!roomForAnother()) {
        sg_fastState = SGSingFastSkipped;
        SGLog(@"sing: no %@ copy: %@, a copy wants %.1f GB, so Sing stays on the CPU", SGSingUnitsName(sg_fastUnits), memoryText(), kFastRoom / 1e9);
        changed();
        return;
    }
    sg_fastState = SGSingFastLoading;
    sg_fastTimedOutActive = NO;
    sg_fastLoad = startLoad(sg_url, sg_fastUnits, SGSingLoaderFastDeadline, ^(MLModel *model, NSError *error) {
        sg_fastLoad = nil;
        sg_fastState = model ? SGSingFastReady : SGSingFastFailed;
        if (model) [sg_separator setFastModel:model named:SGSingUnitsName(sg_fastUnits)];
        changed();
    }, ^(SGSingLoad *load) {
        sg_fastLoad = nil;
        sg_fastState = SGSingFastTimedOut;
        sg_fastTimedOutActive = load.stayedActive;
        changed();
    });
    changed();
}

static void startCPU(void) {
    if (sg_outstanding && !roomForAnother()) {
        sg_state = SGSingLoaderFailed;
        sg_error = [NSString stringWithFormat:@"A load abandoned earlier still holds memory, and %@. Close Spotify and open it again to load the voice model.", memoryText()];
        SGLog(@"sing: no new load: %@", sg_error);
        changed();
        return;
    }
    sg_state = SGSingLoaderLoading;
    sg_error = nil;
    sg_cpuLoad = startLoad(sg_url, MLComputeUnitsCPUOnly, SGSingLoaderCPUDeadline, ^(MLModel *model, NSError *error) {
        sg_cpuLoad = nil;
        sg_separator = model ? [[SGSingSeparator alloc] initWithModel:model] : nil;
        if (sg_separator) {
            sg_state = SGSingLoaderReady;
        } else {
            sg_state = SGSingLoaderFailed;
            sg_error = model ? @"Sing could not set aside memory for the voice model."
                             : [NSString stringWithFormat:@"The voice model did not load: %@", error.localizedDescription ?: @"Core ML gave no reason."];
        }
        changed();
        startFast();
    }, ^(SGSingLoad *load) {
        sg_cpuLoad = nil;
        sg_state = SGSingLoaderFailed;
        sg_error = [NSString stringWithFormat:@"The voice model did not load in %.0f s, so that load was given up.", SGSingLoaderCPUDeadline];
        changed();
    });
    changed();
}

static void abandon(SGSingLoad *load) {
    if (load && !load.finished) load.abandoned = YES;
}

void SGSingLoaderSetChanged(void (^block)(void)) {
    sg_changed = block;
}

void SGSingLoaderDropFast(NSString *why) {
    BOOL had = sg_fastState == SGSingFastLoading || sg_fastState == SGSingFastReady;
    abandon(sg_fastLoad);
    sg_fastLoad = nil;
    [sg_separator setFastModel:nil named:nil];
    sg_fastState = SGSingFastNone;
    sg_fastTimedOutActive = NO;
    if (!had) return;
    if (why) SGLog(@"sing: the %@ copy is dropped: %@", SGSingUnitsName(sg_fastUnits), why);
    changed();
}

void SGSingLoaderWant(NSURL *url, MLComputeUnits fast) {
    sg_keepToken++;
    sg_wanted = YES;
    sg_url = url;
    if (fast != sg_fastUnits) {
        SGSingLoaderDropFast(@"Runs on changed");
        sg_fastUnits = fast;
    }
    if (sg_state == SGSingLoaderIdle) startCPU();
    else startFast();
}

void SGSingLoaderPurge(NSString *why) {
    sg_keepToken++;
    sg_wanted = NO;
    BOOL had = sg_separator || sg_cpuLoad || sg_fastLoad;
    abandon(sg_cpuLoad);
    sg_cpuLoad = nil;
    SGSingLoaderDropFast(nil);
    sg_separator = nil;
    if (!had) return;
    sg_state = SGSingLoaderIdle;
    SGLog(@"sing: the voice model is dropped: %@", why);
    changed();
}

void SGSingLoaderRelease(void) {
    NSUInteger token = ++sg_keepToken;
    sg_wanted = NO;
    if (sg_state == SGSingLoaderFailed) {
        sg_state = SGSingLoaderIdle;
        sg_error = nil;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SGSingLoaderKeepSeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (token == sg_keepToken) SGSingLoaderPurge([NSString stringWithFormat:@"the mic has been off for %.0f s", SGSingLoaderKeepSeconds]);
    });
}

void SGSingLoaderSetForeground(BOOL foreground) {
    sg_foreground = foreground;
    SGSingSeparatorSetForeground(foreground);
    if (!foreground) sg_fastLoad.stayedActive = NO;
    else startFast();
}

BOOL SGSingLoaderHasRoom(void) {
    return roomForAnother();
}

SGSingLoaderState SGSingLoaderCurrentState(void) {
    return sg_state;
}

SGSingSeparator *SGSingLoaderSeparator(void) {
    return sg_state == SGSingLoaderReady ? sg_separator : nil;
}

NSString *SGSingLoaderError(void) {
    return sg_state == SGSingLoaderFailed ? sg_error : nil;
}

NSTimeInterval SGSingLoaderSeconds(void) {
    return sg_cpuLoad ? CFAbsoluteTimeGetCurrent() - sg_cpuLoad.began : 0;
}

SGSingFastState SGSingLoaderFastState(void) {
    return sg_fastState;
}

BOOL SGSingLoaderFastTimedOutActive(void) {
    return sg_fastTimedOutActive;
}

MLComputeUnits SGSingLoaderFastUnits(void) {
    return sg_fastUnits;
}

unsigned SGSingLoaderAttempts(void) {
    return sg_attempts;
}

unsigned SGSingLoaderOutstanding(void) {
    return sg_outstanding;
}
