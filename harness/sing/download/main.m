// The voice model's download (SGSingModel.m) as the tweak compiles it, run on the Mac against Hugging Face: the
// four small files and part of the weights come in, the download is stopped, and the next one carries the weights
// on from where the stop left them (a 206 from the server) through to the move into place.
//
//     ./build.sh && CFFIXED_USER_HOME=<empty dir> ../build/download [stop at, 0 to 1 of the weights]
#import <Foundation/Foundation.h>
#import "Shared/Sing/Sing.h"

static int failures;
#define CHECK(ok, ...) do { BOOL _ok = (ok); if (!_ok) failures++; printf("%s %s\n", _ok ? "PASS" : "FAIL", [NSString stringWithFormat:__VA_ARGS__].UTF8String); } while (0)

static void runUntil(BOOL (^done)(void), NSTimeInterval limit) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:limit];
    while (!done() && end.timeIntervalSinceNow > 0) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.25, false);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        double stopAt = argc > 1 ? atof(argv[1]) : 0.2;
        NSURL *sing = [[[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject
            URLByAppendingPathComponent:@"Vitrine"] URLByAppendingPathComponent:@"Sing"];
        printf("the model goes to %s\n", sing.path.UTF8String);
        CHECK(SGSingModelCurrentState() == SGSingModelMissing, @"no model to start with");

        // The small files are 0.14% of the bytes, so the progress is nearly the weights' own.
        SGSingDownloadModel();
        runUntil(^BOOL { return SGSingModelProgress() >= stopAt || SGSingModelCurrentState() != SGSingModelDownloading; }, 900);
        double stopped = SGSingModelProgress();
        CHECK(SGSingModelCurrentState() == SGSingModelDownloading, @"the download runs into the weights (%.0f%%)", stopped * 100);
        SGSingCancelModelDownload();
        NSURL *resume = [sing URLByAppendingPathComponent:@"download-4.resume"];
        runUntil(^BOOL { return [NSFileManager.defaultManager fileExistsAtPath:resume.path]; }, 10);
        CHECK([NSFileManager.defaultManager fileExistsAtPath:resume.path], @"the stop keeps the weights' resume data");
        CHECK(SGSingModelCurrentState() == SGSingModelMissing, @"stopped, the model is still missing");

        // Started over, the first bytes read well under 1%; carried on, the stop's share.
        SGSingDownloadModel();
        __block double first = -1;
        runUntil(^BOOL {
            if (first < 0 && SGSingModelProgress() > 0.005) first = SGSingModelProgress();
            return SGSingModelCurrentState() != SGSingModelDownloading;
        }, 1800);
        CHECK(first >= stopped - 0.01, @"the next download carries on from %.0f%%, not from the start", first * 100);
        CHECK(![NSFileManager.defaultManager fileExistsAtPath:resume.path], @"the resume data is used once");
        CHECK(SGSingModelCurrentState() == SGSingModelReady, @"the model is in place and checked (%@)", SGSingModelError() ?: @"no error");
        NSArray *inside = [NSFileManager.defaultManager contentsOfDirectoryAtPath:SGSingModelURL().path error:nil];
        CHECK(inside && ![[inside componentsJoinedByString:@" "] containsString:@"resume"], @"nothing but the model in its folder (%@)",
              [inside componentsJoinedByString:@", "]);
        printf("%s\n", failures ? "FAILED" : "all passed");
        return failures ? 1 : 0;
    }
}
