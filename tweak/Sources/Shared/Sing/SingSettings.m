// The Sing page (Sing on Mod Settings' main page, and Lyrics > Karaoke), under either look: Sing's switch, which
// turns the mic on and off at once, what Sing is doing, the vocals' level, and the voice model.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "Sing.h"

static void tell(NSString *title, NSString *message) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

static void ask(NSString *title, NSString *message, NSString *action, BOOL destructive, void (^then)(void)) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:action style:destructive ? UIAlertActionStyleDestructive : UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) { then(); }]];
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

NSString *SGSingLevelText(double level) {
    if (level <= 0.001) return @"Gone";
    if (level < 0.999) return [NSString stringWithFormat:@"%.0f%%", level * 100];
    if (level <= 1.001) return @"As sung";
    if (level >= 1.999) return @"Vocals only";
    return [NSString stringWithFormat:@"Backing %.0f%%", (2 - level) * 100];
}

static NSString *modelValue(void) {
    if (!SGSingOSSupported() || !SGSingDeviceSupported()) return @"Unavailable";
    switch (SGSingModelCurrentState()) {
        case SGSingModelDownloading:
            return SGSingModelWaitingForNetwork() ? @"Waiting for the network" : [NSString stringWithFormat:@"%.0f%%", SGSingModelProgress() * 100];
        case SGSingModelReady: return @"On the iPhone";
        case SGSingModelMissing: return SGSingModelError() ? @"Failed, try again" : [NSString stringWithFormat:@"Download, %@", SGSingModelSizeText()];
    }
    return @"";
}

static void modelTapped(UITableViewController *page) {
    if (!SGSingOSSupported() || !SGSingDeviceSupported()) {
        tell(@"Voice model", SGSingMissing());
        return;
    }
    switch (SGSingModelCurrentState()) {
        case SGSingModelMissing: {
            NSString *message = [NSString stringWithFormat:@"%@%@ from Hugging Face, best over Wi-Fi. It stays on this iPhone, and no audio leaves it.",
                                 SGSingModelError() ? [NSString stringWithFormat:@"The last try failed: %@\n\n", SGSingModelError()] : @"", SGSingModelSizeText()];
            ask(@"Download the voice model?", message, @"Download", NO, ^{ SGSingDownloadModel(); });
            break;
        }
        case SGSingModelDownloading:
            ask(@"Stop the download?", @"What has come in is kept, so the next download carries on from it.", @"Stop", YES, ^{ SGSingCancelModelDownload(); });
            break;
        case SGSingModelReady:
            ask(@"Delete the voice model?", [NSString stringWithFormat:@"It frees %@. Sing needs it again to turn the vocals down.", SGSingModelSizeText()],
                @"Delete", YES, ^{
                    SGSetSingOn(NO);
                    SGSingDeleteModel();
                    // Sing's switch goes off with it.
                    [page.tableView reloadData];
                });
            break;
    }
}

UIViewController *SGSingSettingsPage(void) {
    SGModRow *sing = SGOptionRow(@"Sing", @"Turns the vocals down as the song plays, like the mic on the lyrics", SGKeySing);
    sing.changed = ^(BOOL on) { SGSetSingOn(on); };
    SGModRow *status = SGStatActionRow(@"Status", nil, ^NSString *{ return SGSingStatusText(); }, ^{
        NSString *detail = SGSingStatusDetail();
        if (detail) tell(@"Sing", detail);
    });
    SGModRow *level = SGSliderRow(@"Vocals", @"From gone, through the song as sung, to the vocals alone", 0, 2, 0.05,
        ^double { return SGSingLevel(); }, ^(double value) { SGSetSingLevel((float)value); }, ^NSString *(double value) { return SGSingLevelText(value); });
    __block __weak SGModPage *page;
    SGModRow *model = SGStatActionRow(@"Voice model", @"Mel-Band RoFormer, run on the iPhone", ^NSString *{ return modelValue(); }, ^{ modelTapped(page); });
    SGModRow *units = SGChoiceRow(@"Runs on", @"Read as the model loads", SGKeySingComputeUnits, SGSingComputeUnitNames(), 0);
    units.chosen = ^(NSInteger index) { SGSingComputeUnitsChanged(); };
    SGModRow *heat = SGOptionRow(@"Ignore heat warnings", @"Keeps Sing going on a hot iPhone, which then gets hotter", SGKeySingIgnoreHeat);
    heat.changed = ^(BOOL on) { SGSetSingIgnoresHeat(on); };
    SGModPage *made = [[SGModPage alloc] initWithTitle:@"Sing" intro:nil sections:@[
        SGSection(nil, @[SGWithSymbol(sing, @"music.mic"), status, level]),
        SGNotedSection(@"Voice model", @[model, units, heat],
                       @"Sing listens a few seconds ahead of what plays and separates the vocals there, so a song takes a few seconds to "
                       @"turn its vocals down after it starts or after a seek. Everything runs on the iPhone; no audio leaves it."),
    ] footer:nil];
    page = made;
    return made;
}
