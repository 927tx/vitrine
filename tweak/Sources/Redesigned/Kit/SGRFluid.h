// Fluid artwork: the cover itself, blurred and slowly warped behind the player. Four copies of a
// blurred, saturated cover, each far larger than the screen, turn about different centers at different
// speeds, two each way; where they overlap the picture seems to flow. A shade over the bottom keeps the
// controls legible.
//
// Like SGRFlow.h it is all Core Animation: repeating rotations the render server plays, nothing drawn
// per frame by the app. Stopping holds every copy where it is, and starting again carries on from there.
//
// Threading: main thread only; the blur runs off it.
#import <UIKit/UIKit.h>

@interface SGRFluidLayer : CALayer
// The cover, blurred off the main thread and crossfaded in. The same image again is a no-op.
- (void)setArtwork:(UIImage *)image animated:(BOOL)animated;
// Turning, or held still where it is. Off to begin with.
@property (nonatomic) BOOL moving;
// The part of the layer on screen, in its own coordinates: the copies turn about points in it and the
// shade darkens its bottom, whatever the layer bleeds past it. The whole layer while empty.
@property (nonatomic) CGRect visibleRect;
@end
