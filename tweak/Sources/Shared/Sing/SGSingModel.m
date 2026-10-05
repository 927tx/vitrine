// The voice model on the phone (Sing.h): the five files of its compiled separator.mlmodelc, downloaded one by one
// from the Hugging Face repo, each kept only once its size and SHA-256 are the ones pinned here, then moved
// together into Application Support/Vitrine/Sing/separator.mlmodelc, which backups leave out (489 MB that can
// be downloaded again). A dropped connection carries on from where it stopped, three times per file, and a stopped
// download keeps the file it was in the middle of (NSURLSession's resume data, kept beside the staging folder)
// for the next one to carry on from. A resumed request is answered 206, with the whole file handed over all the same.
//
// Threading: main thread; the session's delegate runs on a queue of its own and hands back to the main thread.
#import <CommonCrypto/CommonDigest.h>
#import "Core/SGCore.h"
#import "Sing.h"

static NSString *const kRepo = @"https://huggingface.co/My-Name-Is-Jeff/vitrine-sing/resolve/main/";
static const int kRetries = 3;
// Bytes a stopped download has kept, for the row that offers to carry on with it or remove it.
static NSString *const kPausedKey = @"spotifyglass.sing.downloadPaused";
// Room the download leaves on the disk besides itself.
static const long long kSpareSpace = 64ll * 1000 * 1000;

typedef struct {
    NSString *__unsafe_unretained path;
    long long size;
    const char *sha256;
} SGSingFile;

// The model card's table (huggingface.co/My-Name-Is-Jeff/vitrine-sing, a mirror of Darkkos/spoti-sing), the weights last so the small files fail first.
static const SGSingFile kFiles[] = {
    {@"metadata.json", 2431, "52a8d5e3f09e33236d495dbed5bbce1c75bac6f2a6b6097637cf214f37c1de53"},
    {@"coremldata.bin", 507, "2090acaf7a6df72ec83857cb88d101654023a6baad222a25d0173827d3347e28"},
    {@"analytics/coremldata.bin", 243, "f7ee4ec9b5cc1c97171bd5aad93af61e183aa0db1451ef3b775bd4e77f0b7cfd"},
    {@"model.mil", 669061, "966560ed5125174a98f19b94f5de04450a7112ade0e731f2236c202c0280a623"},
    {@"weights/weight.bin", 488986336, "970a99fb4b15724bf76d2918ceb177df592c69265d3e2fabaab6e5ba72738e62"},
};
enum { kFileCount = sizeof kFiles / sizeof kFiles[0] };

NSString *const SGSingChangedNotification = @"SGSingChangedNotification";

// Counts the changes to the model's folder, so SGSingModelURL checks it again only after one.
static NSUInteger sg_modelGeneration;

static long long totalBytes(void) {
    long long total = 0;
    for (int i = 0; i < kFileCount; i++) total += kFiles[i].size;
    return total;
}

static NSURL *singFolder(void) {
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    return [[support URLByAppendingPathComponent:@"Vitrine" isDirectory:YES] URLByAppendingPathComponent:@"Sing" isDirectory:YES];
}

static NSURL *modelFolder(void) {
    return [singFolder() URLByAppendingPathComponent:@"separator.mlmodelc" isDirectory:YES];
}

static NSURL *stagingFolder(void) {
    return [singFolder() URLByAppendingPathComponent:@"download" isDirectory:YES];
}

// A stopped download's resume data for file `index`, beside the staging folder: everything in that folder is moved
// into the model.
static NSURL *resumeFile(int index) {
    return [singFolder() URLByAppendingPathComponent:[NSString stringWithFormat:@"download-%d.resume", index]];
}

static long long sizeOf(NSURL *url) {
    return [[NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil][NSFileSize] longLongValue];
}

// Whether every file is in `folder` at its size; the hashes were checked as each came in.
static BOOL complete(NSURL *folder, int upTo) {
    for (int i = 0; i < upTo; i++) {
        if (sizeOf([folder URLByAppendingPathComponent:kFiles[i].path]) != kFiles[i].size) return NO;
    }
    return YES;
}

// The file's SHA-256, read a megabyte at a time: the weights are too big to read whole.
static NSString *sha256Of(NSURL *url) {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingFromURL:url error:nil];
    if (!handle) return nil;
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    for (;;) {
        @autoreleasepool {
            NSData *chunk = [handle readDataUpToLength:1 << 20 error:nil];
            if (!chunk.length) break;
            CC_SHA256_Update(&context, chunk.bytes, (CC_LONG)chunk.length);
        }
    }
    [handle closeFile];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &context);
    NSMutableString *hex = [NSMutableString stringWithCapacity:2 * CC_SHA256_DIGEST_LENGTH];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

static void announce(void) {
    [NSNotificationCenter.defaultCenter postNotificationName:SGSingChangedNotification object:nil];
}

#pragma mark - the download

@interface SGSingDownloader : NSObject <NSURLSessionDownloadDelegate>
@property (nonatomic) int file;               // the index of the file coming in
@property (nonatomic) long long received;     // its bytes so far
@property (nonatomic, copy) NSString *error;
@property (atomic, strong) NSURLSessionDownloadTask *task;   // the one running, so a stop (on the main thread) can keep what it has
@end

static SGSingDownloader *sg_downloader;   // while a download runs
static NSString *sg_lastError;
static double sg_progress;
static BOOL sg_waitingForNetwork;   // offline, or on cellular unless allowed: the session holds the request
static BOOL sg_cellular;            // the download may use cellular and Low Data Mode networks
static BOOL sg_checking;            // the weights' checksum is being read

@implementation SGSingDownloader {
    NSURLSession *_session;
    BOOL _resumed;                     // it carries on from resume data
    BOOL _restart;                     // resume data the server no longer takes: the file again from the start
    int _attempts;
    BOOL _cancelled;
}

- (void)start {
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.defaultSessionConfiguration;
    configuration.timeoutIntervalForRequest = 60;
    // Offline, a request (a retry too) waits for the network rather than failing at once; and so it does on cellular
    // or a Low Data Mode network, 489 MB being a lot of a plan, until the user says it may use them.
    configuration.waitsForConnectivity = YES;
    configuration.allowsExpensiveNetworkAccess = sg_cellular;
    configuration.allowsConstrainedNetworkAccess = sg_cellular;
    NSOperationQueue *queue = [NSOperationQueue new];
    queue.maxConcurrentOperationCount = 1;
    _session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:queue];
    NSError *error;
    [NSFileManager.defaultManager createDirectoryAtURL:stagingFolder() withIntermediateDirectories:YES attributes:nil error:&error];
    NSURL *folder = singFolder();
    [folder setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    [queue addOperationWithBlock:^{ [self next]; }];
}

// Stopped, the file coming in is kept as resume data for the next download; the session goes once it is written.
- (void)cancel {
    _cancelled = YES;
    NSURLSession *session = _session;
    NSURLSessionDownloadTask *task = self.task;
    if (!task) {
        [session invalidateAndCancel];
        return;
    }
    NSURL *resume = resumeFile(self.file);
    [task cancelByProducingResumeData:^(NSData *data) {
        if (data) [data writeToURL:resume atomically:YES];
        SGLog(@"sing: the download is stopped%@", data ? @", what came in is kept" : @"");
        [session invalidateAndCancel];
    }];
}

- (void)download:(NSURL *)url resumeData:(NSData *)resume {
    _resumed = resume != nil;
    NSURLSessionDownloadTask *task = resume ? [_session downloadTaskWithResumeData:resume] : [_session downloadTaskWithURL:url];
    self.task = task;
    [task resume];
}

- (NSURL *)fileURL {
    return [NSURL URLWithString:[kRepo stringByAppendingString:kFiles[self.file].path]];
}

// The first file not already in the staging folder from an earlier try, or the move into place.
- (void)next {
    if (_cancelled) return;
    while (self.file < kFileCount && sizeOf([stagingFolder() URLByAppendingPathComponent:kFiles[self.file].path]) == kFiles[self.file].size) self.file++;
    self.received = 0;
    _attempts = 0;
    [self report];
    if (self.file == kFileCount) {
        [self finish];
        return;
    }
    // A stop's resume data is used once: if it fails, the file starts over.
    NSData *resume = [NSData dataWithContentsOfURL:resumeFile(self.file)];
    [NSFileManager.defaultManager removeItemAtURL:resumeFile(self.file) error:nil];
    [self download:[self fileURL] resumeData:resume];
    SGLog(@"sing: downloading %@%@", kFiles[self.file].path, resume ? @", carrying on from the last download" : @"");
}

- (void)finish {
    NSFileManager *files = NSFileManager.defaultManager;
    // Resume data a stop wrote after the next download had already looked for it.
    for (int i = 0; i < kFileCount; i++) [files removeItemAtURL:resumeFile(i) error:nil];
    [files removeItemAtURL:modelFolder() error:nil];
    NSError *error;
    BOOL moved = [files moveItemAtURL:stagingFolder() toURL:modelFolder() error:&error];
    [self endWithError:moved ? nil : [NSString stringWithFormat:@"The model could not be put in place (%@)", error.localizedDescription]];
}

- (void)endWithError:(NSString *)error {
    [_session finishTasksAndInvalidate];
    if (error) SGLog(@"sing: the model's download failed: %@", error);
    else SGLog(@"sing: the model is downloaded and checked");
    dispatch_async(dispatch_get_main_queue(), ^{
        if (sg_downloader != self) return;
        sg_downloader = nil;
        sg_waitingForNetwork = NO;
        sg_lastError = error;
        if (!error) [NSUserDefaults.standardUserDefaults removeObjectForKey:kPausedKey];
        sg_modelGeneration++;
        announce();
    });
}

- (void)report {
    long long done = self.received;
    for (int i = 0; i < self.file && i < kFileCount; i++) done += kFiles[i].size;
    double progress = (double)done / totalBytes();
    // A few times a second is enough for the row and the button.
    static CFAbsoluteTime reported;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - reported < 0.25 && progress < 1) return;
    reported = now;
    dispatch_async(dispatch_get_main_queue(), ^{
        sg_progress = progress;
        sg_waitingForNetwork = NO;
        announce();
    });
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didWriteData:(int64_t)written
 totalBytesWritten:(int64_t)totalWritten totalBytesExpectedToWrite:(int64_t)expected {
    self.received = MIN(totalWritten, kFiles[self.file].size);
    [self report];
}

- (void)URLSession:(NSURLSession *)session taskIsWaitingForConnectivity:(NSURLSessionTask *)task {
    SGLog(@"sing: waiting for the network to download %@", kFiles[self.file].path);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (sg_downloader != self) return;
        sg_waitingForNetwork = YES;
        announce();
    });
}

// The file is checked here, before the session deletes it, and kept in the staging folder if it is the one
// pinned.
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didFinishDownloadingToURL:(NSURL *)location {
    SGSingFile file = kFiles[self.file];
    NSInteger status = [task.response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)task.response).statusCode : 0;
    BOOL answered = status == 200 || status == 206;
    if (!answered && _resumed) {
        // Resume data the server no longer takes, its signed address run out after a day: the file again.
        SGLog(@"sing: the server answered %ld to carrying on %@, so it starts over", (long)status, file.path);
        _restart = YES;
        return;
    }
    long long size = sizeOf(location);
    BOOL big = file.size > 1000 * 1000;
    if (big) dispatch_async(dispatch_get_main_queue(), ^{ sg_checking = YES; announce(); });
    NSString *hash = size == file.size ? sha256Of(location) : nil;
    if (big) dispatch_async(dispatch_get_main_queue(), ^{ sg_checking = NO; announce(); });
    SGLog(@"sing: %@ came in, %ld, %lld bytes", file.path, (long)status, size);
    if (!answered || size != file.size || ![hash isEqualToString:@(file.sha256)]) {
        self.error = !answered ? [NSString stringWithFormat:@"The server answered %ld for %@", (long)status, file.path]
                                 : [NSString stringWithFormat:@"%@ is not the file Sing expects (%lld bytes%@)", file.path, size, hash ? @", another checksum" : @""];
        return;
    }
    NSURL *target = [stagingFolder() URLByAppendingPathComponent:file.path];
    [NSFileManager.defaultManager createDirectoryAtURL:target.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    [NSFileManager.defaultManager removeItemAtURL:target error:nil];
    NSError *error;
    if (![NSFileManager.defaultManager moveItemAtURL:location toURL:target error:&error]) {
        self.error = [NSString stringWithFormat:@"%@ could not be kept (%@)", file.path, error.localizedDescription];
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (_cancelled) return;
    if (_restart) {
        _restart = NO;
        [self download:[self fileURL] resumeData:nil];
        return;
    }
    if (self.error) {
        NSString *message = self.error;
        self.error = nil;
        [self endWithError:message];
        return;
    }
    if (!error) {
        self.file++;
        [self next];
        return;
    }
    NSData *resume = error.userInfo[NSURLSessionDownloadTaskResumeData];
    if (++_attempts <= kRetries) {
        SGLog(@"sing: %@ stopped (%@), trying again%@", kFiles[self.file].path, error.localizedDescription, resume ? @" from where it was" : @"");
        [self download:[self fileURL] resumeData:resume];
        return;
    }
    [self endWithError:error.localizedDescription];
}

@end

#pragma mark - what Sing asks

SGSingModelState SGSingModelCurrentState(void) {
    if (sg_downloader) return SGSingModelDownloading;
    return SGSingModelURL() ? SGSingModelReady : SGSingModelMissing;
}

NSURL *SGSingModelURL(void) {
    // Checked by size once a launch, and again after a download or a delete changes it.
    static int known = -1;
    static NSUInteger knownGeneration = NSUIntegerMax;
    if (knownGeneration != sg_modelGeneration) {
        knownGeneration = sg_modelGeneration;
        known = complete(modelFolder(), kFileCount);
    }
    return known ? modelFolder() : nil;
}

double SGSingModelProgress(void) {
    return sg_downloader ? sg_progress : SGSingModelURL() ? 1 : 0;
}

BOOL SGSingModelWaitingForNetwork(void) {
    return sg_downloader && sg_waitingForNetwork;
}

NSString *SGSingModelError(void) {
    return sg_lastError;
}

NSString *SGSingModelSizeText(void) {
    return [NSByteCountFormatter stringFromByteCount:totalBytes() countStyle:NSByteCountFormatterCountStyleFile];
}

// What is still to come: the files not in the staging folder yet.
static long long bytesToCome(void) {
    long long left = 0;
    for (int i = 0; i < kFileCount; i++) {
        if (sizeOf([stagingFolder() URLByAppendingPathComponent:kFiles[i].path]) != kFiles[i].size) left += kFiles[i].size;
    }
    return left;
}

void SGSingDownloadModel(void) {
    if (sg_downloader || SGSingModelURL()) return;
    // The volume Application Support is on, which the staging folder's parent may not exist on yet.
    NSURL *support = singFolder().URLByDeletingLastPathComponent.URLByDeletingLastPathComponent;
    NSNumber *free = [support resourceValuesForKeys:@[NSURLVolumeAvailableCapacityForImportantUsageKey] error:nil][NSURLVolumeAvailableCapacityForImportantUsageKey];
    long long wanted = bytesToCome() + kSpareSpace;
    if (free && free.longLongValue < wanted) {
        NSByteCountFormatterCountStyle style = NSByteCountFormatterCountStyleFile;
        sg_lastError = [NSString stringWithFormat:@"The iPhone has %@ free, and the voice model needs %@ more.",
                        [NSByteCountFormatter stringFromByteCount:free.longLongValue countStyle:style],
                        [NSByteCountFormatter stringFromByteCount:wanted - free.longLongValue countStyle:style]];
        SGLog(@"sing: the download does not start: %@", sg_lastError);
        announce();
        return;
    }
    sg_lastError = nil;
    sg_progress = 0;
    sg_waitingForNetwork = NO;
    sg_downloader = [SGSingDownloader new];
    [sg_downloader start];
    announce();
}

void SGSingDownloadModelOverCellular(void) {
    if (!sg_downloader) {
        sg_cellular = YES;
        SGSingDownloadModel();
        return;
    }
    if (sg_cellular) return;
    // The running download's session forbids cellular: it stops keeping what it has, and starts again allowed.
    SGSingCancelModelDownload();
    sg_cellular = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ SGSingDownloadModel(); });
}

BOOL SGSingModelOverCellular(void) {
    return sg_cellular;
}

BOOL SGSingModelChecking(void) {
    return sg_downloader && sg_checking;
}

long long SGSingModelPausedBytes(void) {
    return sg_downloader || SGSingModelURL() ? 0 : [NSUserDefaults.standardUserDefaults integerForKey:kPausedKey];
}

void SGSingCancelModelDownload(void) {
    if (sg_downloader) [NSUserDefaults.standardUserDefaults setInteger:(NSInteger)(sg_progress * totalBytes()) forKey:kPausedKey];
    [sg_downloader cancel];
    sg_downloader = nil;
    sg_modelGeneration++;
    announce();
}

void SGSingDeleteModel(void) {
    SGSingCancelModelDownload();
    [NSFileManager.defaultManager removeItemAtURL:singFolder() error:nil];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kPausedKey];
    sg_modelGeneration++;
    announce();
}

NSArray<NSString *> *SGSingComputeUnitNames(void) {
    return @[@"Automatic", @"CPU only", @"GPU", @"Neural Engine", @"GPU and Neural Engine"];
}

BOOL SGSingOSSupported(void) {
    if (@available(iOS 18.0, *)) return YES;
    return NO;
}

// The model is 489 MB of weights, held while Sing is on beside Spotify's own memory: an iPhone with less than
// 6 GB (which report a little under 6) would have Spotify closed under it.
// ponytail: a memory floor stands in for a list of phones; measure on a 6 GB phone and a 4 GB one to place it.
BOOL SGSingDeviceSupported(void) {
    return NSProcessInfo.processInfo.physicalMemory >= 5ull * 1000 * 1000 * 1000;
}
