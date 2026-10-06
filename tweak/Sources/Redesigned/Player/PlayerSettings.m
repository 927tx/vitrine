// The redesign's Player page in Mod Settings (App/Pages.m opens it in place of the native look's).
//
// It leads with a card of the player as the now playing track shows on it: the background chosen on the
// page edge to edge, and over its foot the cover, the title, the artist and how far the track has played.
// The progress is where the track was when the page appeared.
//
// The background is the player's own: a field of the same kind (Still, Colours, Fluid), and for Animated
// the clip the player is playing (SGRPlayerMotionPreview) in place of the field, or Fluid while there is
// none, as in the player. It moves under the field's own conditions (in a window, Spotify in front, Reduce
// Motion and Low Power Mode off). Under the card a segmented control picks the background, all four of
// them: the names are one short word each, so they fit side by side at the narrowest iPhone width, and
// every choice stays one tap away with the card showing it at once. A note under the control says what the
// choice does; it is given the room of the longest note, so the rows under it hold still as it changes.
//
// Under the header: the rows that follow the choice (Animated's sources and its Low Data Mode switch;
// Fluid has no settings of its own), the Mini player section (Redesigned/NowPlayingBar/
// NowPlayingBarSettings.m), then the sections either look shares.
//
// Threading: main thread only.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Redesigned/NowPlayingBar/NowPlayingBar.h"
#import "Shared/AnimatedArtwork/AnimatedArtwork.h"
#import "Player.h"

// The card's height as a share of its width, kept between the two bounds.
static const CGFloat kCardAspect = 0.5, kCardMinHeight = 168, kCardMaxHeight = 220;
static const CGFloat kCardRadius = 26;   // continuous, the radius of the page's own cards and then some
static const CGFloat kCardPadding = 16, kCoverSide = 64;

// What each background does, in SGRPlayerBackgroundKind's order.
static NSArray<NSString *> *backgroundNotes(void) {
    return @[
        @"The cover, blurred and held still.",
        @"The cover's colours, drifting slowly.",
        @"The cover itself, blurred and slowly turning. It rests while a song is paused.",
        @"The song's Canvas or the album's moving cover, else Fluid. The player's ⋯ menu switches between the two.",
    ];
}

@interface SGRPlayerShowcase : UIView <SGPlayerStateObserver>
- (void)reloadTrack;
- (void)reloadBackgroundAnimated:(BOOL)animated;
@end

@implementation SGRPlayerShowcase {
    SGRArtworkField *_field;
    UIView *_motion;
    UIImageView *_cover;
    UILabel *_title, *_artist;
    UIView *_progress, *_progressFill;
    CGFloat _position;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.clipsToBounds = YES;
    self.layer.cornerRadius = kCardRadius;
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
    _cover.layer.cornerRadius = 8;
    _cover.layer.cornerCurve = kCACornerCurveContinuous;
    _cover.tintColor = SGRTertiary();
    _cover.backgroundColor = SGRSolidGlassFill();
    _cover.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightRegular];
    [self addSubview:_cover];

    _title = [UILabel new];
    _title.textColor = SGRPrimary();
    _title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [self addSubview:_title];
    _artist = [UILabel new];
    _artist.textColor = SGRSecondary();
    _artist.font = [UIFont systemFontOfSize:15];
    [self addSubview:_artist];

    // The player's slider as it is drawn at rest: a track, and in it a fill up to where the song is.
    _progress = [UIView new];
    _progress.backgroundColor = [UIColor colorWithWhite:1 alpha:0.2];
    _progress.clipsToBounds = YES;
    _progressFill = [UIView new];
    _progressFill.backgroundColor = SGRPrimary();
    [_progress addSubview:_progressFill];
    [self addSubview:_progress];

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

// The track, where it is and whether it plays, read again.
- (void)reloadTrack {
    SPTPlayerState *state = SGPlayerState();
    SPTPlayerTrack *track = state.track;
    _title.text = track.trackTitle.length ? track.trackTitle : @"Not Playing";
    _artist.text = track.artistName ?: @"";
    _position = state.duration > 0 ? MIN(1, MAX(0, state.position / state.duration)) : 0;
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

// The clip runs from the card's top at its width, as in the player, and its blur comes in from the
// seam under the controls, which on a card this short is over its foot, under the words.
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    CGFloat w = bounds.size.width, h = bounds.size.height;
    _field.frame = bounds;
    _field.backdropHeight = h;
    _motion.frame = bounds;

    _cover.frame = CGRectMake(kCardPadding, h - kCardPadding - kCoverSide, kCoverSide, kCoverSide);
    CGFloat x = CGRectGetMaxX(_cover.frame) + 12, width = w - kCardPadding - x;
    CGFloat line = 4, titleHeight = ceil(_title.font.lineHeight), artistHeight = ceil(_artist.font.lineHeight);
    CGFloat bottom = CGRectGetMaxY(_cover.frame);
    _progress.frame = CGRectMake(x, bottom - line - 2, width, line);
    _progress.layer.cornerRadius = line / 2;
    _progressFill.frame = CGRectMake(0, 0, round(width * _position), line);
    CGFloat textBottom = CGRectGetMinY(_progress.frame) - 10;
    _artist.frame = CGRectMake(x, textBottom - artistHeight, width, artistHeight);
    _title.frame = CGRectMake(x, CGRectGetMinY(_artist.frame) - titleHeight, width, titleHeight);
}

@end

#pragma mark - the page

@interface SGRPlayerPage : SGModPage
@property (nonatomic, strong) SGRPlayerShowcase *showcase;
@property (nonatomic, strong) UISegmentedControl *backgrounds;
@end

@implementation SGRPlayerPage {
    UIView *_header;
    UILabel *_note;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _header = [UIView new];
    [_header addSubview:self.showcase];
    [_header addSubview:self.backgrounds];
    _note = [UILabel new];
    _note.font = SGSubtitleFont();
    _note.textColor = SGGrey();
    _note.numberOfLines = 0;
    [_header addSubview:_note];
    [self showNote];
    self.tableView.tableHeaderView = _header;
}

- (void)showNote {
    _note.text = backgroundNotes()[(NSUInteger)SGRPlayerBackground()];
    [self.view setNeedsLayout];
}

// The header keeps the height it is given, so it is sized here and given back to the table only when that
// changes (a table header set on every pass lays the table out again forever). The note's room is that of
// the longest note at this width, so picking a background never moves the rows.
- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    UITableView *table = self.tableView;
    CGFloat width = table.bounds.size.width, inset = table.layoutMargins.left;
    CGFloat cardWidth = width - 2 * inset;
    CGFloat cardHeight = round(MIN(kCardMaxHeight, MAX(kCardMinHeight, cardWidth * kCardAspect)));
    self.showcase.frame = CGRectMake(inset, 16, cardWidth, cardHeight);
    CGFloat controlHeight = MAX(32, ceil([self.backgrounds sizeThatFits:CGSizeMake(cardWidth, CGFLOAT_MAX)].height));
    self.backgrounds.frame = CGRectMake(inset, CGRectGetMaxY(self.showcase.frame) + 12, cardWidth, controlHeight);

    CGFloat noteWidth = cardWidth - 2 * 4, room = 0;
    UILabel *measure = [UILabel new];
    measure.font = _note.font;
    measure.numberOfLines = 0;
    for (NSString *text in backgroundNotes()) {
        measure.text = text;
        room = MAX(room, ceil([measure sizeThatFits:CGSizeMake(noteWidth, CGFLOAT_MAX)].height));
    }
    CGFloat noteHeight = ceil([_note sizeThatFits:CGSizeMake(noteWidth, CGFLOAT_MAX)].height);
    CGFloat noteTop = CGRectGetMaxY(self.backgrounds.frame) + 8;
    _note.frame = CGRectMake(inset + 4, noteTop, noteWidth, noteHeight);
    CGSize size = CGSizeMake(width, noteTop + room);
    if (CGSizeEqualToSize(_header.bounds.size, size)) return;
    _header.frame = (CGRect){CGPointZero, size};
    table.tableHeaderView = _header;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // The player's ⋯ menu can switch Animated and Fluid while the page is away.
    self.backgrounds.selectedSegmentIndex = SGRPlayerBackground();
    [self showNote];
    [self.showcase reloadTrack];
    [self.showcase reloadBackgroundAnimated:NO];
}

- (void)backgroundPicked {
    SGSetInt(SGRKeyPlayerBackground, self.backgrounds.selectedSegmentIndex);
    [self.showcase reloadBackgroundAnimated:YES];
    [self showNote];
    [self refreshVisibility];
}

@end

UIViewController *SGRPlayerSettingsPage(NSArray *more) {
    SGRPlayerShowcase *showcase = [[SGRPlayerShowcase alloc] initWithFrame:CGRectMake(0, 0, 320, kCardMinHeight)];
    UISegmentedControl *backgrounds = [[UISegmentedControl alloc] initWithItems:SGRPlayerBackgroundNames()];
    backgrounds.selectedSegmentIndex = SGRPlayerBackground();
    backgrounds.accessibilityLabel = @"Background";

    SGModRow *lowData = SGOptionRow(@"Download in Low Data Mode", @"Up to about 7 MB a song", SGKeyMotionLowData);
    lowData.visible = ^BOOL { return SGRPlayerBackground() == SGRPlayerBackgroundAnimated; };
    SGModRow *sources = SGMotionSourcesRow();
    sources.visible = lowData.visible;

    NSMutableArray<SGModSection *> *sections = [NSMutableArray arrayWithObjects:
        SGSection(nil, @[sources, lowData]),
        SGNotedSection(@"Mini player", SGRNowPlayingBarRows(),
                       @"Apple Music style shrinks the tab bar to two tabs as a page scrolls down and puts the now "
                       "playing bar between them; scrolling back up undoes it. There the bar keeps its cover, title "
                       "and play button, and the device button too when it is on. Apple Music style applies at once, the device button "
                       "the next time the bar shrinks."), nil];
    [sections addObjectsFromArray:more];
    SGRPlayerPage *page = [[SGRPlayerPage alloc] initWithTitle:@"Player" intro:nil sections:sections footer:SGRestartNote];
    page.showcase = showcase;
    page.backgrounds = backgrounds;
    [backgrounds addTarget:page action:@selector(backgroundPicked) forControlEvents:UIControlEventValueChanged];
    return page;
}
