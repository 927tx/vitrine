// AirPods gestures: CMHeadphoneMotionManager's attitudes fed to SGHeadDetector while the switch is on and
// Spotify plays, or while the page learns a gesture, and each gesture done to Spotify's player. The same
// manager's motion goes to the features listening through SGHeadMotionListen (Sing's spatial voice), and keeps
// running for them with the switch off; the detector is fed only while the gestures want it.
//
// Skip is the player's own skipToNextTrackWithOptions: (Headers/SPTPlayer.h). Like adds the playing track to
// the collection, which for a track is Liked Songs, through -addURL:showUIConfirmation:completion: of
// Spotify's collection platform. Spotify 9.1.78 has four classes with that selector and with -stateProvider
// (SPTCollectionPlatformImplementation, Collection_PlatformImpl's CollectionPlatformImpl and
// CollectionPlatformMigration, AlignedCuration's ACUCollectionPlatform); whichever the app last reached
// for is kept, weakly, the way Redesigned/Artist/ArtistFollow.x keeps its state provider. The lock
// screen's like (LockScreenBaseRemoteControlPolicy's likeButtonPressedWithCompletion:identifier:) is not
// used: it toggles, and a second nod would take the song out again.
//
// The cue is a tone played through Spotify's own playback session, mixed into the music in the AirPods:
// a system sound would follow the Ring/Silent switch, and a phone in a pocket is often on silent. A rising
// pair says the gesture was done, one low tone that it failed. A haptic comes with it while Spotify is in
// front, and Spotify's own "Added to Liked Songs" toast shows only then too.
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMotion/CoreMotion.h>
#import "Core/SGCore.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/Player/PlayerState.h"
#import "HeadGestures.h"

@protocol SGCollectionPlatform <NSObject>
- (void)addURL:(NSURL *)url showUIConfirmation:(BOOL)show completion:(id)completion;
@end

// Tink, the passcode key's, should the cue's player not load.
static const SystemSoundID kCueSound = 1057;
// Each of the cue's tones, and how loud, of the most a sample holds; the player plays at the system volume.
static const double kToneSeconds = 0.09;
static const double kToneLevel = 0.5;
static const double kMilli = 1000;

static CMHeadphoneMotionManager *sg_manager;
static NSOperationQueue *sg_queue;   // serial: the detector, the learning buffer and the queue's copies live on it alone
static SGHeadDetector sg_detector;
static NSMutableData *sg_learned;    // learning's samples, three doubles each
static BOOL sg_learning;
static BOOL sg_listening;            // started with the handler, by updateListening
static BOOL sg_detecting;            // the gestures want the motion: learning, or the switch on and Spotify playing
static BOOL sg_queueDetecting;       // sg_detecting, on sg_queue
static NSMutableDictionary<NSString *, void (^)(CMDeviceMotion *)> *sg_listeners;   // other features', by name
static NSArray<void (^)(CMDeviceMotion *)> *sg_queueListeners;                     // their handlers, on sg_queue
static __weak id sg_platform;

#pragma mark - the collection platform

// Spotify's platforms wrap one another, so the one kept can change often: logged once per class.
static void keepPlatform(id platform) {
    if (platform == sg_platform || ![platform respondsToSelector:@selector(addURL:showUIConfirmation:completion:)]) return;
    NSString *name = NSStringFromClass([platform class]);
    static NSMutableSet<NSString *> *logged;
    // Spotify asks for its state provider from any thread.
    @synchronized (NSObject.class) {
        sg_platform = platform;
        if (!logged) logged = [NSMutableSet set];
        if ([logged containsObject:name]) return;
        [logged addObject:name];
    }
    SGLog(@"head gestures: collection platform %@", name);
}

%hook SPTCollectionPlatformImplementation
- (id)stateProvider {
    keepPlatform(self);
    return %orig;
}
%end

%hook _TtC23Collection_PlatformImpl22CollectionPlatformImpl
- (id)stateProvider {
    keepPlatform(self);
    return %orig;
}
%end

%hook _TtC23Collection_PlatformImpl27CollectionPlatformMigration
- (id)stateProvider {
    keepPlatform(self);
    return %orig;
}
%end

%hook _TtC26AlignedCuration_CommonImpl21ACUCollectionPlatform
- (id)stateProvider {
    keepPlatform(self);
    return %orig;
}
%end

#pragma mark - the gestures

// A WAV in memory of short tones one after the other, each faded in and out so it does not click.
static NSData *tones(NSArray<NSNumber *> *hertz) {
    const uint32_t rate = 44100, perTone = (uint32_t)(rate * kToneSeconds), frames = perTone * (uint32_t)hertz.count;
    NSMutableData *wav = [NSMutableData dataWithLength:44 + frames * sizeof(int16_t)];
    uint8_t *header = wav.mutableBytes;
    // RIFF, then the format chunk (PCM, one channel, 16-bit) and the data chunk; arm64 is little-endian, as WAV is.
    uint32_t words[] = {0x46464952, 36 + frames * 2, 0x45564157, 0x20746d66, 16, 1 | 1 << 16, rate, rate * 2, 2 | 16 << 16,
                        0x61746164, frames * 2};
    memcpy(header, words, sizeof words);
    int16_t *samples = (int16_t *)(header + 44);
    for (NSUInteger tone = 0; tone < hertz.count; tone++) {
        for (uint32_t i = 0; i < perTone; i++) {
            double envelope = sin(M_PI * i / perTone);
            samples[tone * perTone + i] = (int16_t)(kToneLevel * INT16_MAX * envelope * sin(2 * M_PI * hertz[tone].doubleValue * i / rate));
        }
    }
    return wav;
}

// The cue's players live on a queue of their own: loading and starting one goes through the audio
// session, which can hold the main thread up for a moment.
static dispatch_queue_t cueQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("spotifyglass.headgestures.cue", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

// A rising pair for a gesture done, one low tone for one that failed. On cueQueue only.
static AVAudioPlayer *cuePlayer(BOOL worked) {
    static AVAudioPlayer *done, *failed;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSError *error = nil;
        done = [[AVAudioPlayer alloc] initWithData:tones(@[@880, @1320]) error:&error];
        failed = [[AVAudioPlayer alloc] initWithData:tones(@[@330]) error:&error];
        if (!done || !failed) SGLog(@"head gestures: no cue player, the system sound instead: %@", error);
        [done prepareToPlay];
        [failed prepareToPlay];
    });
    return worked ? done : failed;
}

static void cue(BOOL worked) {
    dispatch_async(cueQueue(), ^{
        AVAudioPlayer *player = cuePlayer(worked);
        player.currentTime = 0;
        if (![player play]) AudioServicesPlaySystemSound(kCueSound);
    });
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    UINotificationFeedbackGenerator *generator = [UINotificationFeedbackGenerator new];
    [generator notificationOccurred:worked ? UINotificationFeedbackTypeSuccess : UINotificationFeedbackTypeError];
}

static void like(void) {
    NSString *uri = SGURIString(SGPlayerState().track.URI);
    id platform = sg_platform;
    // Only a track: an episode is saved another way, and an ad is nothing to save.
    if (![uri hasPrefix:@"spotify:track:"] || !platform) {
        SGLog(@"head gestures: no like for %@, platform %@", uri, platform);
        cue(NO);
        return;
    }
    BOOL inFront = UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    // A block that reads no arguments: whatever the completion is called with, it is safe to ignore.
    [(id<SGCollectionPlatform>)platform addURL:[NSURL URLWithString:uri] showUIConfirmation:inFront completion:^{
        SGLog(@"head gestures: liked %@", uri);
    }];
    cue(YES);
}

static void skip(void) {
    id player = SGKaraokePlayer();
    if (![player respondsToSelector:@selector(skipToNextTrackWithOptions:)]) {
        cue(NO);
        return;
    }
    [(id<SPTPlayer>)player skipToNextTrackWithOptions:nil];
    cue(YES);
}

// What learning stored for `key`, or the detector's default.
static double learnedOr(NSString *key, double fallback) {
    NSInteger learned = SGInt(key, 0);
    return learned > 0 ? learned / kMilli : fallback;
}

static double threshold(NSString *key, double fallback) {
    double sensitivity = MAX(SGHeadSensitivityMin, MIN(SGHeadSensitivityMax, SGInt(SGKeyHeadSensitivity, 100))) / 100.0;
    return learnedOr(key, fallback) / sensitivity;
}

#pragma mark - listening

// Nil to the other features' handlers: the motion has stopped. On sg_queue.
static void motionStopped(void) {
    for (void (^handler)(CMDeviceMotion *) in sg_queueListeners) handler(nil);
}

static void sample(CMDeviceMotion *motion) {
    for (void (^handler)(CMDeviceMotion *) in sg_queueListeners) handler(motion);
    double time = motion.timestamp, pitch = motion.attitude.pitch, yaw = motion.attitude.yaw;
    if (sg_learned) {
        double values[3] = {time, pitch, yaw};
        [sg_learned appendBytes:values length:sizeof values];
        return;
    }
    // Running for another feature alone, the gestures off or Spotify paused: no gestures.
    if (!sg_queueDetecting) return;
    SGHeadGesture gesture = SGHeadDetectorFeed(&sg_detector, time, pitch, yaw);
    if (gesture == SGHeadGestureNone) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        SGLog(@"head gestures: %@", gesture == SGHeadGestureDoubleNod ? @"double nod" : @"shake");
        if (sg_learning || !SGFlag(SGKeyHeadGestures, NO)) return;
        if (gesture == SGHeadGestureDoubleNod) like();
        else skip();
    });
}

// The headphones taken out or off: the listeners hear that their motion stopped. Called on the queue the motion
// comes on.
@interface SGHeadMotionDelegate : NSObject <CMHeadphoneMotionManagerDelegate>
@end

@implementation SGHeadMotionDelegate
- (void)headphoneMotionManagerDidDisconnect:(CMHeadphoneMotionManager *)manager {
    [sg_queue addOperationWithBlock:^{ motionStopped(); }];
}
@end

static CMHeadphoneMotionManager *manager(void) {
    static SGHeadMotionDelegate *delegate;   // the manager holds its delegate weakly
    if (!sg_manager) {
        sg_manager = [CMHeadphoneMotionManager new];
        sg_queue = [NSOperationQueue new];
        sg_queue.maxConcurrentOperationCount = 1;
        sg_queue.qualityOfService = NSQualityOfServiceUserInitiated;
        delegate = [SGHeadMotionDelegate new];
        sg_manager.delegate = delegate;
    }
    return sg_manager;
}

// A fresh detector at the thresholds set now.
static void resetDetector(void) {
    double nod = threshold(SGKeyHeadNod, SGHeadDefaultNod), shake = threshold(SGKeyHeadShake, SGHeadDefaultShake);
    [sg_queue addOperationWithBlock:^{ SGHeadDetectorReset(&sg_detector, nod, shake); }];
}

// The gestures want the motion while learning, or while the switch is on and Spotify plays; the manager runs
// then and while another feature listens. It sends nothing until headphones that track motion are in, so
// starting it with none costs nothing.
static void updateListening(void) {
    // isPlaying stays on while a track is loaded and paused; isPaused is what tells.
    SPTPlayerState *state = SGPlayerState();
    BOOL detect = sg_learning || (SGFlag(SGKeyHeadGestures, NO) && state.isPlaying && !state.isPaused);
    if (detect != sg_detecting) {
        sg_detecting = detect;
        manager();
        if (detect) {
            resetDetector();
            // Loaded now rather than with the first gesture's cue, which then plays on time.
            dispatch_async(cueQueue(), ^{ cuePlayer(YES); });
        }
        [sg_queue addOperationWithBlock:^{ sg_queueDetecting = detect; }];
    }
    BOOL listen = detect || sg_listeners.count;
    if (listen == sg_listening) return;
    sg_listening = listen;
    SGLog(@"head gestures: %@", listen ? @"listening" : @"stopped");
    if (!listen) {
        [sg_manager stopDeviceMotionUpdates];
        return;
    }
    [sg_manager startDeviceMotionUpdatesToQueue:sg_queue withHandler:^(CMDeviceMotion *motion, NSError *error) {
        if (motion) sample(motion);
    }];
}

void SGHeadMotionListen(NSString *name, void (^handler)(CMDeviceMotion *motion)) {
    if (!sg_listeners) sg_listeners = [NSMutableDictionary dictionary];
    void (^old)(CMDeviceMotion *) = sg_listeners[name];
    if (!old && !handler) return;
    sg_listeners[name] = [handler copy];
    manager();
    NSArray<void (^)(CMDeviceMotion *)> *handlers = sg_listeners.allValues;
    [sg_queue addOperationWithBlock:^{
        sg_queueListeners = handlers;
        if (old) old(nil);
    }];
    updateListening();
}

void SGHeadMotionAskPermission(void) {
    // Motion's permission is asked the first time the manager starts. With nothing playing that would be the
    // first song, maybe from the lock screen, so a page asks while it is in front.
    if (sg_listening || CMHeadphoneMotionManager.authorizationStatus != CMAuthorizationStatusNotDetermined) return;
    [manager() startDeviceMotionUpdates];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (!sg_listening) [sg_manager stopDeviceMotionUpdates];
    });
}

void SGHeadGesturesSettingsChanged(void) {
    if (sg_manager) resetDetector();
    updateListening();
    if (SGFlag(SGKeyHeadGestures, NO)) SGHeadMotionAskPermission();
}

BOOL SGHeadGesturesAvailable(void) {
    return manager().deviceMotionAvailable;
}

void SGHeadGesturesLearn(SGHeadAxis axis, double seconds, void (^done)(double threshold, NSInteger samples)) {
    if (sg_learning) {
        done(0, 0);
        return;
    }
    sg_learning = YES;
    manager();
    // The check after learning runs with the other gesture as it is set now, at a sensitivity of 100%.
    double other = axis == SGHeadAxisPitch ? learnedOr(SGKeyHeadShake, SGHeadDefaultShake) : learnedOr(SGKeyHeadNod, SGHeadDefaultNod);
    [sg_queue addOperationWithBlock:^{ sg_learned = [NSMutableData data]; }];
    SGHeadGesturesSettingsChanged();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [sg_queue addOperationWithBlock:^{
            NSData *data = sg_learned;
            sg_learned = nil;
            const double *values = data.bytes;
            int count = (int)(data.length / (3 * sizeof(double)));
            double *time = malloc(sizeof(double) * MAX(count, 1)), *pitch = malloc(sizeof(double) * MAX(count, 1)), *yaw = malloc(sizeof(double) * MAX(count, 1));
            for (int i = 0; i < count; i++) {
                time[i] = values[3 * i];
                pitch[i] = values[3 * i + 1];
                yaw[i] = values[3 * i + 2];
            }
            double learned = SGHeadLearn(time, pitch, yaw, count, axis, other);
            free(time);
            free(pitch);
            free(yaw);
            dispatch_async(dispatch_get_main_queue(), ^{
                SGLog(@"head gestures: learned %.2f rad/s for %@ from %d samples", learned, axis == SGHeadAxisPitch ? @"nod" : @"shake", count);
                if (learned > 0) SGSetInt(axis == SGHeadAxisPitch ? SGKeyHeadNod : SGKeyHeadShake, lround(learned * kMilli));
                sg_learning = NO;
                SGHeadGesturesSettingsChanged();
                done(learned, count);
            });
        }];
    });
}

// Playing or not, from the one player hook every feature shares.
@interface SGHeadGesturesObserver : NSObject <SGPlayerStateObserver>
@end

@implementation SGHeadGesturesObserver
- (void)playerStateDidChange:(SPTPlayerState *)state {
    updateListening();
}
@end

%ctor {
    %init;
    SGRequireClasses(@[@"SPTCollectionPlatformImplementation", @"_TtC23Collection_PlatformImpl22CollectionPlatformImpl"]);
    static SGHeadGesturesObserver *observer;
    observer = [SGHeadGesturesObserver new];
    SGAddPlayerStateObserver(observer);
}
