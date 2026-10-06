// The redesign's Player page in Mod Settings (App/Pages.m opens it in place of the native look's).
//
// It leads with a showcase of the player: a small copy of it in the player's own proportions, over the
// background chosen on the page, with the playing track's cover, title and artist, and above the artwork a
// glass sheet carrying the player's sliders, progress and volume, with previous, play and next between
// them. The progress is where the track was when the page appeared and the volume is the phone's.
//
// The background is the player's own: a field of the same kind (Still, Colours, Fluid), and for Animated
// the clip the player is playing (SGRPlayerMotionPreview) in place of the cover, or Fluid and the cover
// while there is none, as in the player. It moves under the field's own conditions (in a window, Spotify
// in front, Reduce Motion and Low Power Mode off). Picking another background changes the showcase at
// once; the player takes it after a restart, as the note under the showcase says.
//
// Under the showcase: the background and its Low Data Mode switch, the now playing bar's device button
// (Redesigned/NowPlayingBar/NowPlayingBarSettings.m), then the sections either look shares.
//
// Threading: main thread only.
#import <AVFoundation/AVFoundation.h>
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Redesigned/NowPlayingBar/NowPlayingBar.h"
#import "Shared/AnimatedArtwork/AnimatedArtwork.h"
#import "Player.h"

// The showcase's height on the page; its width follows the window's shape.
static const CGFloat kShowcaseHeight = 340;
// The player's layout on a 402 x 874 screen, as shares of the showcase's width (w) and height (h).
static const CGFloat kCoverTop = 0.14;      // h, the cover's top under the header
static const CGFloat kCoverSide = 0.88;     // w, 354 of 402
static const CGFloat kScreenRadius = 0.063; // h, a 55pt display corner

@interface SGRPlayerShowcase : UIView <SGPlayerStateObserver>
- (void)reloadTrack;
- (void)reloadBackgroundAnimated:(BOOL)animated;
@end

@implementation SGRPlayerShowcase {
    SGRArtworkField *_field;
    UIView *_motion;
    UIImageView *_cover;
    UILabel *_title, *_artist;
    UIVisualEffectView *_sheet;
    UIView *_progress, *_progressFill, *_volume, *_volumeFill;
    UIImageView *_previous, *_play, *_next, *_quiet, *_loud;
    CGFloat _position, _level;
}

// A slider of the player as it is drawn at rest: a track, and in it a fill up to the value (its only subview).
static UIView *bar(UIView *host) {
    UIView *track = [UIView new];
    track.backgroundColor = [UIColor colorWithWhite:1 alpha:0.2];
    track.layer.cornerCurve = kCACornerCurveContinuous;
    track.clipsToBounds = YES;
    UIView *fill = [UIView new];
    fill.backgroundColor = SGRPrimary();
    [track addSubview:fill];
    [host addSubview:track];
    return track;
}

static UIImageView *glyph(UIView *host, NSString *symbol, UIColor *color) {
    UIImageView *view = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
    view.tintColor = color;
    view.contentMode = UIViewContentModeCenter;
    [host addSubview:view];
    return view;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.clipsToBounds = YES;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.backgroundColor = SGRNeutralField();
    self.userInteractionEnabled = NO;
    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitImage;
    self.accessibilityLabel = @"Player preview";

    _field = [[SGRArtworkField alloc] initWithFrame:frame];
    _field.showsBackdrop = YES;
    [self addSubview:_field];

    _cover = [UIImageView new];
    _cover.contentMode = UIViewContentModeScaleAspectFill;
    _cover.clipsToBounds = YES;
    _cover.layer.cornerCurve = kCACornerCurveContinuous;
    _cover.tintColor = SGRTertiary();
    _cover.backgroundColor = SGRSolidGlassFill();
    [self addSubview:_cover];

    _title = [UILabel new];
    _title.textColor = SGRPrimary();
    [self addSubview:_title];
    _artist = [UILabel new];
    _artist.textColor = SGRSecondary();
    [self addSubview:_artist];

    // The sheet is the control layer, so it is glass; the artwork under it is content.
    _sheet = [[UIVisualEffectView alloc] initWithEffect:SGRReduceTransparency() ? nil : SGGlassEffect()];
    if (SGRReduceTransparency()) _sheet.backgroundColor = SGRSolidGlassFill();
    _sheet.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [self addSubview:_sheet];
    UIView *content = _sheet.contentView;
    _progress = bar(content);
    _progressFill = _progress.subviews.firstObject;
    _volume = bar(content);
    _volumeFill = _volume.subviews.firstObject;
    _previous = glyph(content, @"backward.fill", SGRPrimary());
    _play = glyph(content, @"play.fill", SGRPrimary());
    _next = glyph(content, @"forward.fill", SGRPrimary());
    _quiet = glyph(content, @"speaker.fill", SGRSecondary());
    _loud = glyph(content, @"speaker.wave.3.fill", SGRSecondary());

    SGAddPlayerStateObserver(self);
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(artworkChanged) name:SGRNowPlayingArtworkDidChangeNotification object:nil];
    [self reloadTrack];
    [self reloadBackgroundAnimated:NO];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)playerStateDidChange:(SPTPlayerState *)state {
    [self reloadTrack];
}

- (void)artworkChanged {
    NSString *identity = nil;
    UIImage *image = SGRNowPlayingArtwork(NULL, &identity);
    if (!image) return;
    _cover.image = image;
    _cover.contentMode = UIViewContentModeScaleAspectFill;
    [_field setArtwork:image identity:identity animated:self.window != nil];
}

// The track, where it is, whether it plays, and the volume, read again.
- (void)reloadTrack {
    SPTPlayerState *state = SGPlayerState();
    SPTPlayerTrack *track = state.track;
    _title.text = track.trackTitle.length ? track.trackTitle : @"Not Playing";
    _artist.text = track.artistName ?: @"";
    _position = state.duration > 0 ? MIN(1, MAX(0, state.position / state.duration)) : 0;
    _level = AVAudioSession.sharedInstance.outputVolume;
    _play.image = [UIImage systemImageNamed:state.isPlaying && !state.isPaused ? @"pause.fill" : @"play.fill"];
    // The clip covers the field, which then holds still, as in the player (PlayerMotion.x).
    _field.motionHeld = state.isPaused || _motion != nil;
    if (SGRNowPlayingArtwork(NULL, NULL)) {
        [self artworkChanged];
    } else {
        _cover.image = [UIImage systemImageNamed:@"music.note"];
        _cover.contentMode = UIViewContentModeCenter;
    }
    [self setNeedsLayout];
}

// The background chosen, read again; a new one crosses over when animated. The clip is the one playing when
// this is called: a track changed while the page shows keeps the last one until the page appears again.
- (void)reloadBackgroundAnimated:(BOOL)animated {
    SGRPlayerBackgroundKind kind = SGRPlayerBackground();
    void (^apply)(void) = ^{
        self->_field.flows = kind == SGRPlayerBackgroundColours;
        self->_field.fluid = kind >= SGRPlayerBackgroundFluid;
        [self->_motion removeFromSuperview];
        self->_motion = kind == SGRPlayerBackgroundAnimated ? SGRPlayerMotionPreview() : nil;
        if (self->_motion) [self insertSubview:self->_motion aboveSubview:self->_field];
        self->_cover.hidden = self->_motion != nil;
        self->_field.motionHeld = SGPlayerState().isPaused || self->_motion != nil;
    };
    self.accessibilityValue = [SGRPlayerBackgroundNames()[(NSUInteger)kind] stringByAppendingString:@" background"];
    if (animated && self.window) {
        // A crossfade, which Reduce Motion keeps: nothing moves.
        [UIView transitionWithView:self duration:SGRCrossfade options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowAnimatedContent
                        animations:apply completion:nil];
    } else {
        apply();
    }
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    CGFloat w = bounds.size.width, h = bounds.size.height;
    self.layer.cornerRadius = round(h * kScreenRadius);
    _field.frame = bounds;
    _field.backdropHeight = h;
    _motion.frame = bounds;

    CGFloat side = round(w * kCoverSide), x = round((w - side) / 2);
    _cover.frame = CGRectMake(x, round(h * kCoverTop), side, side);
    _cover.layer.cornerRadius = side * SGRRadiusArtwork / 354;
    _cover.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:side * 0.3 weight:UIImageSymbolWeightRegular];

    _title.font = [UIFont systemFontOfSize:w * 0.055 weight:UIFontWeightBold];
    _artist.font = [UIFont systemFontOfSize:w * 0.045];
    CGFloat y = CGRectGetMaxY(_cover.frame) + round(h * 0.035);
    _title.frame = CGRectMake(x, y, side, ceil(_title.font.lineHeight));
    _artist.frame = CGRectMake(x, CGRectGetMaxY(_title.frame), side, ceil(_artist.font.lineHeight));

    CGFloat inset = round(w * 0.035), top = CGRectGetMaxY(_artist.frame) + round(h * 0.025);
    _sheet.frame = CGRectMake(inset, top, w - 2 * inset, h - inset - top);
    SGShapeGlass(_sheet, round(w * 0.075), NO);
    if (!_sheet.effect) {
        _sheet.layer.cornerRadius = round(w * 0.075);
        _sheet.layer.cornerCurve = kCACornerCurveContinuous;
        _sheet.clipsToBounds = YES;
    }

    CGSize sheet = _sheet.bounds.size;
    CGFloat pad = round(sheet.width * 0.07), line = MAX(2, round(w * 0.012));
    CGFloat width = sheet.width - 2 * pad;
    _progress.frame = CGRectMake(pad, round(sheet.height * 0.17), width, line);
    _progressFill.frame = CGRectMake(0, 0, round(width * _position), line);

    CGFloat speaker = round(w * 0.06), gap = round(w * 0.02);
    CGFloat volumeY = round(sheet.height * 0.83);
    _quiet.frame = CGRectMake(pad, volumeY - speaker / 2, speaker, speaker);
    _loud.frame = CGRectMake(sheet.width - pad - speaker, volumeY - speaker / 2, speaker, speaker);
    CGFloat volumeX = CGRectGetMaxX(_quiet.frame) + gap, volumeWidth = CGRectGetMinX(_loud.frame) - gap - volumeX;
    _volume.frame = CGRectMake(volumeX, volumeY - line / 2, volumeWidth, line);
    _volumeFill.frame = CGRectMake(0, 0, round(volumeWidth * _level), line);
    _progress.layer.cornerRadius = _volume.layer.cornerRadius = line / 2;

    CGFloat middle = round(sheet.height * 0.5), button = round(w * 0.16);
    _play.frame = CGRectMake(round((sheet.width - button) / 2), middle - button / 2, button, button);
    _previous.frame = CGRectOffset(_play.frame, -round(sheet.width * 0.28), 0);
    _next.frame = CGRectOffset(_play.frame, round(sheet.width * 0.28), 0);
    UIImageSymbolConfiguration *large = [UIImageSymbolConfiguration configurationWithPointSize:w * 0.1 weight:UIImageSymbolWeightBold];
    UIImageSymbolConfiguration *small = [UIImageSymbolConfiguration configurationWithPointSize:w * 0.07 weight:UIImageSymbolWeightBold];
    _play.preferredSymbolConfiguration = large;
    _previous.preferredSymbolConfiguration = _next.preferredSymbolConfiguration = small;
    _quiet.preferredSymbolConfiguration = _loud.preferredSymbolConfiguration =
        [UIImageSymbolConfiguration configurationWithPointSize:w * 0.032 weight:UIImageSymbolWeightSemibold];
}

@end

#pragma mark - the page

@interface SGRPlayerPage : SGModPage
@property (nonatomic, strong) SGRPlayerShowcase *showcase;
@end

@implementation SGRPlayerPage {
    UIView *_header;
    UILabel *_note;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _header = [UIView new];
    [_header addSubview:self.showcase];
    _note = [UILabel new];
    _note.text = SGRestartNote;
    _note.font = SGSubtitleFont();
    _note.textColor = SGGrey();
    _note.numberOfLines = 0;
    [_header addSubview:_note];
    self.tableView.tableHeaderView = _header;
}

// The header keeps the height it is given, so it is sized here and given back to the table only when that
// changes (a table header set on every pass lays the table out again forever).
- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    UITableView *table = self.tableView;
    CGFloat width = table.bounds.size.width, inset = table.layoutMargins.left;
    CGSize window = table.window.bounds.size;
    CGFloat aspect = window.height > 0 ? window.width / window.height : 402.0 / 874.0;
    CGFloat showcaseWidth = round(kShowcaseHeight * aspect);
    self.showcase.frame = CGRectMake(round((width - showcaseWidth) / 2), 16, showcaseWidth, kShowcaseHeight);
    CGFloat noteWidth = width - 2 * inset;
    CGFloat noteHeight = ceil([_note sizeThatFits:CGSizeMake(noteWidth, CGFLOAT_MAX)].height);
    _note.frame = CGRectMake(inset, CGRectGetMaxY(self.showcase.frame) + 16, noteWidth, noteHeight);
    CGSize size = CGSizeMake(width, CGRectGetMaxY(_note.frame));
    if (CGSizeEqualToSize(_header.bounds.size, size)) return;
    _header.frame = (CGRect){CGPointZero, size};
    table.tableHeaderView = _header;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.showcase reloadTrack];
    [self.showcase reloadBackgroundAnimated:NO];
}

@end

UIViewController *SGRPlayerSettingsPage(NSArray *more) {
    SGRPlayerShowcase *showcase = [[SGRPlayerShowcase alloc] initWithFrame:CGRectMake(0, 0, 160, kShowcaseHeight)];
    __block __weak SGRPlayerPage *weakPage;
    NSArray<NSString *> *names = SGRPlayerBackgroundNames();
    // A pull-down rather than a list of its own, so the showcase changes in front of you.
    SGModRow *background = SGMenuRow(@"Background", names, ^NSString *{ return names[(NSUInteger)SGRPlayerBackground()]; }, ^(NSInteger index) {
        SGSetInt(SGRKeyPlayerBackground, index);
        [showcase reloadBackgroundAnimated:YES];
        [weakPage refreshVisibility];
    });
    SGModRow *lowData = SGOptionRow(@"Download in Low Data Mode", @"Animated artwork, up to about 7 MB a song", SGKeyMotionLowData);
    lowData.visible = ^BOOL { return SGRPlayerBackground() == SGRPlayerBackgroundAnimated; };

    NSMutableArray<SGModSection *> *sections = [NSMutableArray arrayWithObjects:
        SGNotedSection(nil, @[background, lowData],
                       @"Animated plays the Canvas or Apple Music's animated cover over Fluid, and the player's ⋯ menu switches between the two."),
        SGSection(nil, SGRNowPlayingBarRows()), nil];
    [sections addObjectsFromArray:more];
    SGRPlayerPage *page = [[SGRPlayerPage alloc] initWithTitle:@"Player" intro:nil sections:sections footer:nil];
    page.showcase = showcase;
    weakPage = page;
    return page;
}
