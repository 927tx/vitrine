#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "Appearance.h"

// Apple Music's red is one tap away, unless it is the colour already. Going back to Spotify's green is
// offered only once a colour of the mod's is set, so a stray tap cannot wipe it.
static void chooseAccent(void) {
    UIViewController *top = SGTopController();
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Accent colour" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    if (SGInt(SGKeyAccent, -1) != SGAppleMusicRed)
        [sheet addAction:[UIAlertAction actionWithTitle:@"Apple Music red" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { SGSetInt(SGKeyAccent, SGAppleMusicRed); }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Pick a colour" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { SGPickAccent(); }]];
    if (SGAccentColor()) [sheet addAction:[UIAlertAction actionWithTitle:@"Spotify green" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { SGSetInt(SGKeyAccent, -1); }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = top.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(top.view.bounds), CGRectGetMidY(top.view.bounds), 0, 0);
    sheet.popoverPresentationController.permittedArrowDirections = 0;
    [top presentViewController:sheet animated:YES completion:nil];
}

// The native look's rows of the Appearance card (App/Pages.m).
NSArray<SGModRow *> *SGNativeAppearanceRows(void) {
    return @[
        SGWithSymbol(SGOptionRow(@"AMOLED background", nil, SGKeyAmoled), @"moon"),
        SGWithSymbol(SGStatActionRow(@"Accent colour", nil, ^NSString *{ return SGAccentLabel(); }, ^{ chooseAccent(); }), @"paintpalette"),
    ];
}
