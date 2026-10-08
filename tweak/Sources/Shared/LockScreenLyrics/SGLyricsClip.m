// SGLyricsClip.h says what this draws. The words are laid out once per clip and only the backdrop moves,
// so an animated clip costs a scaled image draw and an encode a frame.
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <CoreText/CoreText.h>
#import "SGLyricsClip.h"

// The lock screen fills the screen with a 3:4 clip, so a phone's taller screen cuts its sides off: the
// words keep to this middle share of the width. The center of the words sits this far down, clear of
// the clock above and the controls below.
// ponytail: guessed from the screen's shape, not measured on a lock screen; tune both on a device.
static const CGFloat kColumn = 0.56;
static const CGFloat kCentreY = 0.5;
// The words' size as a share of the width, made smaller down to kSmallest of it while they run taller
// than kTallest of the height.
static const CGFloat kFont = 0.05;
static const CGFloat kSmallest = 0.6;
static const CGFloat kTallest = 0.4;
static const CGFloat kNextAlpha = 0.4;
// A still is one frame held this long; an animated clip breathes once over kLoopSeconds, which is all it
// plays before the lock screen loops it.
static const int32_t kStillSeconds = 2;
static const int32_t kLoopSeconds = 4;
static const int32_t kFPS = 15;   // the breath is slow; at 24 a line took about 4 s to write on the CPU
static const CGFloat kBreath = 0.06;   // how much bigger the cover grows at the top of a breath

CGSize SGLyricsClipSize(CGFloat pixels) {
    CGFloat width = MAX(floor(pixels / 16) * 16, 16);
    return CGSizeMake(width, round(width * 4 / 3 / 16) * 16);
}

static CGContextRef newContext(CGSize size, void *data, size_t bytesPerRow) {
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(data, (size_t)size.width, (size_t)size.height, 8, bytesPerRow, space,
                                                 kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(space);
    return context;
}

// The width the cover is blurred at, before it is drawn at the clip's size.
static const CGFloat kBackdropWidth = 128;

CGImageRef SGLyricsClipBackdrop(CGImageRef cover, CGSize size) {
    CGContextRef context = newContext(size, NULL, 0);
    CGRect bounds = {CGPointZero, size};
    CGContextSetRGBFillColor(context, 0.11, 0.11, 0.12, 1);
    CGContextFillRect(context, bounds);
    if (cover) {
        static CIContext *renderer;
        static dispatch_once_t once;
        // On the CPU: the lock screen asks while Spotify is in the background, where GPU work gets it killed.
        dispatch_once(&once, ^{ renderer = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @YES}]; });
        // Blurred small and drawn large: a blur this wide looks the same either way, and on the CPU at full size it
        // took 12 to 20 s for a song's first line.
        CGSize small = CGSizeMake(kBackdropWidth, round(kBackdropWidth * size.height / size.width));
        // Filled the way the lock screen fills the screen, the square cover's sides overflowing.
        CIImage *image = [CIImage imageWithCGImage:cover];
        CGFloat scale = MAX(small.width / image.extent.size.width, small.height / image.extent.size.height);
        image = [image imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
        image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation((small.width - image.extent.size.width) / 2,
                                                                                 (small.height - image.extent.size.height) / 2)];
        // Clamped first, so the blur does not pull the dark in from past the edges.
        image = [[image imageByClampingToExtent] imageByApplyingGaussianBlurWithSigma:small.width * 0.05];
        CGImageRef blurred = [renderer createCGImage:image fromRect:(CGRect){CGPointZero, small}];
        CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
        if (blurred) CGContextDrawImage(context, bounds, blurred);
        CGImageRelease(blurred);
        // Darkened, so white words read over a light cover.
        CGContextSetRGBFillColor(context, 0, 0, 0, 0.45);
        CGContextFillRect(context, bounds);
    }
    CGImageRef backdrop = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return backdrop;
}

static NSAttributedString *wordsAt(NSString *line, NSString *next, CGFloat fontSize) {
    CTFontRef font = CTFontCreateUIFontForLanguage(kCTFontUIFontEmphasizedSystem, fontSize, NULL);
    CGFloat spacing = fontSize * 0.6;
    CTParagraphStyleSetting settings[] = {
        {kCTParagraphStyleSpecifierParagraphSpacingBefore, sizeof(spacing), &spacing},
    };
    CTParagraphStyleRef paragraph = CTParagraphStyleCreate(settings, 1);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGFloat white[] = {1, 1, 1, 1}, dim[] = {1, 1, 1, kNextAlpha};
    CGColorRef lit = CGColorCreate(space, white), unlit = CGColorCreate(space, dim);
    NSMutableAttributedString *words = [NSMutableAttributedString new];
    NSDictionary *base = @{(id)kCTFontAttributeName: (__bridge id)font, (id)kCTParagraphStyleAttributeName: (__bridge id)paragraph};
    if (line.length) {
        NSMutableDictionary *attributes = [base mutableCopy];
        attributes[(id)kCTForegroundColorAttributeName] = (__bridge id)lit;
        [words appendAttributedString:[[NSAttributedString alloc] initWithString:line attributes:attributes]];
    }
    if (next.length) {
        NSMutableDictionary *attributes = [base mutableCopy];
        attributes[(id)kCTForegroundColorAttributeName] = (__bridge id)unlit;
        NSString *text = words.length ? [@"\n" stringByAppendingString:next] : next;
        [words appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:attributes]];
    }
    CFRelease(font);
    CFRelease(paragraph);
    CGColorRelease(lit);
    CGColorRelease(unlit);
    CGColorSpaceRelease(space);
    return words;
}

// The words alone on a clear image the size of the clip, nil when there are none.
static CGImageRef newWords(NSString *line, NSString *next, CGSize size) CF_RETURNS_RETAINED {
    if (!line.length && !next.length) return NULL;
    CGFloat width = round(size.width * kColumn);
    CGFloat fontSize = size.width * kFont;
    CTFramesetterRef setter = NULL;
    CGSize fits = CGSizeZero;
    // A long line is set smaller until the two lines fit; past the smallest size it runs taller.
    for (CGFloat scale = 1; scale >= kSmallest - 0.01; scale -= 0.1) {
        if (setter) CFRelease(setter);
        setter = CTFramesetterCreateWithAttributedString((__bridge CFAttributedStringRef)wordsAt(line, next, fontSize * scale));
        fits = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRangeMake(0, 0), NULL, CGSizeMake(width, CGFLOAT_MAX), NULL);
        if (fits.height <= size.height * kTallest) break;
    }
    CGFloat height = ceil(fits.height) + 1;
    // Core Graphics counts up from the bottom.
    CGRect box = CGRectMake(round((size.width - width) / 2), round(size.height * (1 - kCentreY) - height / 2), width, height);
    CGPathRef path = CGPathCreateWithRect(box, NULL);
    CTFrameRef frame = CTFramesetterCreateFrame(setter, CFRangeMake(0, 0), path, NULL);
    CGContextRef context = newContext(size, NULL, 0);
    CTFrameDraw(frame, context);
    CGImageRef words = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    CFRelease(frame);
    CGPathRelease(path);
    CFRelease(setter);
    return words;
}

// A frame `phase` of the way through the loop, 0 to 1, into `context`.
static void drawFrame(CGContextRef context, CGImageRef backdrop, CGImageRef words, CGSize size, double phase) {
    CGFloat grow = kBreath * (1 - cos(2 * M_PI * phase)) / 2;
    CGRect bounds = {CGPointZero, size};
    CGContextDrawImage(context, CGRectInset(bounds, -size.width * grow / 2, -size.height * grow / 2), backdrop);
    if (words) CGContextDrawImage(context, bounds, words);
}

CGImageRef SGLyricsClipFrame(CGImageRef backdrop, NSString *line, NSString *next, CGSize size) {
    CGImageRef words = newWords(line, next, size);
    CGContextRef context = newContext(size, NULL, 0);
    drawFrame(context, backdrop, words, size, 0);
    CGImageRef frame = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    CGImageRelease(words);
    return frame;
}

BOOL SGLyricsClipWrite(NSURL *file, CGImageRef backdrop, NSString *line, NSString *next, CGSize size, SGLyricsClipStyle style) {
    // Written beside the file and moved over it once whole, so a clip cut off halfway is never found.
    NSURL *partial = [file URLByAppendingPathExtension:@"partial"];
    [NSFileManager.defaultManager removeItemAtURL:partial error:nil];
    AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:partial fileType:AVFileTypeMPEG4 error:nil];
    if (!writer) return NO;
    int32_t frames = style == SGLyricsClipAnimated ? kLoopSeconds * kFPS : 1;
    CMTime length = CMTimeMake(style == SGLyricsClipAnimated ? kLoopSeconds : kStillSeconds, 1);
    AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:@{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @(size.width),
        AVVideoHeightKey: @(size.height),
        AVVideoCompressionPropertiesKey: @{AVVideoAverageBitRateKey: @(2000000), AVVideoMaxKeyFrameIntervalKey: @(kFPS)},
    }];
    AVAssetWriterInputPixelBufferAdaptor *adaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input
        sourcePixelBufferAttributes:@{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey: @(size.width),
            (id)kCVPixelBufferHeightKey: @(size.height),
        }];
    if (![writer canAddInput:input]) return NO;
    [writer addInput:input];
    if (![writer startWriting]) return NO;
    [writer startSessionAtSourceTime:kCMTimeZero];
    CGImageRef words = newWords(line, next, size);
    BOOL ok = YES;
    for (int32_t i = 0; i < frames && ok; i++) {
        while (!input.readyForMoreMediaData && writer.status == AVAssetWriterStatusWriting) [NSThread sleepForTimeInterval:0.002];
        CVPixelBufferRef buffer = NULL;
        ok = writer.status == AVAssetWriterStatusWriting && adaptor.pixelBufferPool
            && CVPixelBufferPoolCreatePixelBuffer(NULL, adaptor.pixelBufferPool, &buffer) == kCVReturnSuccess;
        if (!ok) break;
        CVPixelBufferLockBaseAddress(buffer, 0);
        CGContextRef context = newContext(size, CVPixelBufferGetBaseAddress(buffer), CVPixelBufferGetBytesPerRow(buffer));
        drawFrame(context, backdrop, words, size, (double)i / frames);
        CGContextRelease(context);
        CVPixelBufferUnlockBaseAddress(buffer, 0);
        ok = [adaptor appendPixelBuffer:buffer withPresentationTime:CMTimeMake(i, kFPS)];
        CVPixelBufferRelease(buffer);
    }
    CGImageRelease(words);
    if (!ok) {
        [writer cancelWriting];
        return NO;
    }
    [input markAsFinished];
    // The last frame, or a still's only one, is held to the end of the loop.
    [writer endSessionAtSourceTime:length];
    dispatch_semaphore_t written = dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(written); }];
    dispatch_semaphore_wait(written, DISPATCH_TIME_FOREVER);
    if (writer.status != AVAssetWriterStatusCompleted) return NO;
    [NSFileManager.defaultManager removeItemAtURL:file error:nil];
    return [NSFileManager.defaultManager moveItemAtURL:partial toURL:file error:nil];
}
