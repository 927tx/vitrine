// Where a track's moving artwork comes from, in the user's order: the Canvas Spotify gives the track and
// Apple Music's animated album cover. Either can be switched off. The player and the lock screen walk the
// order (SGMotionClipFor); the album page's animated cover asks only whether Apple Music is on.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGSourcesPage.h"
#import "AnimatedArtwork.h"

static NSString *const kCanvas = @"canvas", *const kAppleMusic = @"applemusic";

static NSArray<SGSource *> *allSources(void) {
    return @[
        [SGSource sourceWithKey:kCanvas name:@"Spotify Canvas" detail:@"The track's own looping video"],
        [SGSource sourceWithKey:kAppleMusic name:@"Apple Music" detail:@"The album's animated cover"],
    ];
}

NSArray<NSString *> *SGMotionSourceOrder(void) {
    id stored = [NSUserDefaults.standardUserDefaults arrayForKey:SGKeyMotionSources];
    NSArray *keys = [stored isKindOfClass:NSArray.class] ? stored : @[kCanvas, kAppleMusic];
    NSMutableArray<NSString *> *order = [NSMutableArray array];
    for (id key in keys) {
        if (([key isEqual:kCanvas] || [key isEqual:kAppleMusic]) && ![order containsObject:key]) [order addObject:key];
    }
    return order;
}

BOOL SGMotionAppleMusicOn(void) {
    return [SGMotionSourceOrder() containsObject:kAppleMusic];
}

void SGMotionClipFor(NSURL *canvas, NSString *artist, NSString *album, SGMotionShape shape, CGFloat pixels,
                     void (^done)(NSURL *file)) {
    NSArray<NSString *> *order = SGMotionSourceOrder();
    // The walk holds itself until it ends, when it lets go.
    __block void (^ask)(NSUInteger) = nil;
    void (^finish)(NSURL *) = ^(NSURL *file) {
        ask = nil;
        done(file);
    };
    void (^step)(NSUInteger) = ^(NSUInteger index) {
        if (index >= order.count) {
            finish(nil);
            return;
        }
        void (^next)(NSURL *) = ^(NSURL *file) {
            if (file) finish(file);
            else ask(index + 1);
        };
        if ([order[index] isEqualToString:kCanvas]) {
            if (canvas) SGMotionFile(canvas, next);
            else next(nil);
        } else {
            SGMotionAlbumCover(artist, album, shape, pixels, next);
        }
    };
    ask = step;
    step(0);
}

SGModRow *SGMotionSourcesRow(void) {
    SGModRow *row = SGPageRow(@"Artwork sources", ^UIViewController *{
        return SGSourcesPageMake(@"Artwork sources", @"Asked top to bottom until one has a clip for the track. Apple Music is "
                                                     @"asked for the album by its name; it never sees your account.",
                                 allSources(), ^NSArray<NSString *> * { return SGMotionSourceOrder(); },
                                 ^(NSArray<NSString *> *keys) { [NSUserDefaults.standardUserDefaults setObject:keys forKey:SGKeyMotionSources]; });
    });
    row.value = ^NSString * {
        NSArray<NSString *> *order = SGMotionSourceOrder();
        if (!order.count) return @"Off";
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        for (NSString *key in order) [names addObject:[key isEqualToString:kCanvas] ? @"Canvas" : @"Apple Music"];
        return [names componentsJoinedByString:@", "];
    };
    return SGWithSymbol(row, @"square.stack.3d.down.right");
}
