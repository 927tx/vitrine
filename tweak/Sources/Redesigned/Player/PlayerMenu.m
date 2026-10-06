// Player redesign: the ⋯ opens the system menu (Redesigned/ContextMenu): Share, Add to playlist and Add to
// queue in a row at its top, then the player's own items here, then More with the rest of Spotify's rows. The
// player's items take over what Speed and pitch's block is on Spotify's sheet:
//
//     Speed, Pitch & Reverb   a submenu of three:
//         Playback Speed      0.5× to 2× in the steps Podcasts offers, the current one checked
//         Pitch               Pitch Follows Speed, then three semitones down to three up, Original between them
//         Reverb              Off and a quarter at a time up to 100%, the audio effects' reverb
//     Show Animated Artwork   or Show Fluid Artwork: a button that switches the background between the two,
//                             while it is one of them, named for what it switches to
//
// Each submenu says what it is set to under its name, so the menu reads as a settings summary without opening
// anything. A public menu has no sliders, so the steps stand in for them: the sheet's block, with its finer
// steps, is still what shows when the menu cannot open (ContextMenu.h). What the speed or the pitch is set to
// outside the steps (from that block) is kept, said under the name, and checked nowhere.
#import "Core/SGCore.h"
#import "Redesigned/ContextMenu/ContextMenu.h"
#import "Shared/Player/PlayerState.h"
#import "Shared/Player/SpeedPitch.h"
#import "Player.h"

static const float kSemitonesShown = 3;

static UIImage *symbol(NSString *name) {
    return [UIImage systemImageNamed:name];
}

static NSString *speedText(double speed) {
    NSString *text = [NSString stringWithFormat:@"%.2f", speed];
    while ([text hasSuffix:@"0"]) text = [text substringToIndex:text.length - 1];
    if ([text hasSuffix:@"."]) text = [text substringToIndex:text.length - 1];
    return [text stringByAppendingString:@"×"];
}

static NSString *semitonesText(float semitones) {
    if (semitones == 0) return @"Original";
    return [NSString stringWithFormat:@"%@%.0f %@", semitones > 0 ? @"+" : @"−", fabsf(semitones), fabsf(semitones) == 1 ? @"Semitone" : @"Semitones"];
}

// While pitch follows a speed that is not normal, the speed sets the pitch and the semitones are not played
// (SGTimePitch.h), so they stand aside, as on the sheet.
static BOOL pitchFollowing(void) {
    return SGPlayerSpeedAllowed() && SGPlayerPitchFollowsSpeed() && SGPlayerSpeed() != 1;
}

static UIMenu *speedMenu(void) {
    BOOL allowed = SGPlayerSpeedAllowed();
    double current = SGPlayerSpeed();
    NSMutableArray<UIMenuElement *> *choices = [NSMutableArray array];
    for (NSNumber *step in @[@0.5, @0.75, @1, @1.25, @1.5, @1.75, @2]) {
        UIAction *choice = [UIAction actionWithTitle:speedText(step.doubleValue) image:nil identifier:nil handler:^(UIAction *action) {
            SGSetPlayerSpeed(step.doubleValue);
        }];
        choice.state = fabs(current - step.doubleValue) < 0.01 ? UIMenuElementStateOn : UIMenuElementStateOff;
        if (!allowed) choice.attributes = UIMenuElementAttributesDisabled;
        [choices addObject:choice];
    }
    UIMenu *menu = [UIMenu menuWithTitle:@"Playback Speed" image:symbol(@"gauge.with.dots.needle.67percent") identifier:nil options:0 children:choices];
    menu.subtitle = allowed ? speedText(current) : @"Unavailable";
    return menu;
}

static UIMenu *pitchMenu(void) {
    BOOL available = SGPlayerPitchAvailable(), speedAllowed = SGPlayerSpeedAllowed(), follows = SGPlayerPitchFollowsSpeed();
    BOOL following = pitchFollowing();
    float current = SGPlayerPitch();

    UIAction *follow = [UIAction actionWithTitle:@"Pitch Follows Speed" image:nil identifier:nil handler:^(UIAction *action) {
        SGSetPlayerPitchFollowsSpeed(!follows);
    }];
    follow.state = follows ? UIMenuElementStateOn : UIMenuElementStateOff;
    // Following needs the speed's unit, which the in place fallback does not have.
    if (!speedAllowed) follow.attributes = UIMenuElementAttributesDisabled;

    NSMutableArray<UIMenuElement *> *steps = [NSMutableArray array];
    for (float semitones = kSemitonesShown; semitones >= -kSemitonesShown; semitones--) {
        float chosen = semitones;
        UIAction *step = [UIAction actionWithTitle:semitonesText(chosen) image:nil identifier:nil handler:^(UIAction *action) {
            SGSetPlayerPitch(chosen);
        }];
        step.state = !following && current == chosen ? UIMenuElementStateOn : UIMenuElementStateOff;
        if (!available || following) step.attributes = UIMenuElementAttributesDisabled;
        [steps addObject:step];
    }
    UIMenu *menu = [UIMenu menuWithTitle:@"Pitch" image:symbol(@"tuningfork") identifier:nil options:0 children:@[
        [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[follow]],
        [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:steps],
    ]];
    menu.subtitle = !available ? @"Unavailable" : following ? @"Follows Speed" : semitonesText(current);
    return menu;
}

static UIMenu *reverbMenu(void) {
    float current = SGPlayerReverb();
    NSMutableArray<UIMenuElement *> *choices = [NSMutableArray array];
    for (NSNumber *amount in @[@0, @25, @50, @75, @100]) {
        UIAction *choice = [UIAction actionWithTitle:amount.floatValue ? [NSString stringWithFormat:@"%@%%", amount] : @"Off" image:nil identifier:nil
                                             handler:^(UIAction *action) { SGPlayerSetReverb(amount.floatValue); }];
        choice.state = current == amount.floatValue ? UIMenuElementStateOn : UIMenuElementStateOff;
        [choices addObject:choice];
    }
    UIMenu *menu = [UIMenu menuWithTitle:@"Reverb" image:symbol(@"building.columns") identifier:nil options:0 children:choices];
    menu.subtitle = current > 0 ? [NSString stringWithFormat:@"%.0f%%", current] : @"Off";
    return menu;
}

// The three under one item, which says what is not as Spotify plays it, or Normal.
static UIMenu *soundMenu(void) {
    NSMutableArray<NSString *> *changed = [NSMutableArray array];
    if (SGPlayerSpeedAllowed() && fabs(SGPlayerSpeed() - 1) >= 0.01) [changed addObject:speedText(SGPlayerSpeed())];
    if (SGPlayerPitchAvailable() && !pitchFollowing() && SGPlayerPitch() != 0) [changed addObject:semitonesText(SGPlayerPitch())];
    if (SGPlayerReverb() > 0) [changed addObject:[NSString stringWithFormat:@"Reverb %.0f%%", SGPlayerReverb()]];
    UIMenu *menu = [UIMenu menuWithTitle:@"Speed, Pitch & Reverb" image:symbol(@"slider.horizontal.3") identifier:nil options:0
                                children:@[speedMenu(), pitchMenu(), reverbMenu()]];
    menu.subtitle = changed.count ? [changed componentsJoinedByString:@", "] : @"Normal";
    return menu;
}

static NSArray<UIMenuElement *> *playerItems(void) {
    NSMutableArray<UIMenuElement *> *items = [NSMutableArray arrayWithObject:soundMenu()];
    if (SGPlayerMenuOffersAnimatedArtwork()) {
        // A button named for what it does, not a checkmark: the HIG's changeable label for a toggled item.
        BOOL on = SGPlayerMenuAnimatedArtwork();
        UIAction *animated = [UIAction actionWithTitle:on ? @"Show Fluid Artwork" : @"Show Animated Artwork"
                                                 image:symbol(on ? @"drop" : @"play.rectangle.on.rectangle") identifier:nil
                                               handler:^(UIAction *action) { SGPlayerMenuSetAnimatedArtwork(!on); }];
        [items addObject:animated];
    }
    return items;
}

// What the player is playing, from its URI (spotify:track:…, spotify:episode:…, spotify:local:…): a podcast's
// sheet has other rows than a song's.
static NSString *sheetKind(void) {
    NSArray<NSString *> *parts = [SGURIString(SGPlayerState().track.URI) componentsSeparatedByString:@":"];
    return parts.count > 2 ? parts[1] : @"";
}

void SGRPlayerMenuWatch(UIView *button) {
    SGRSystemMenuWatch(button, ^NSArray<UIMenuElement *> *{ return playerItems(); }, ^NSString *{ return sheetKind(); });
}
