// The system Settings app's look, for every page of the mod's, in its dark appearance: cards of #1C1C1E on
// black, 17pt titles over 15pt grey subtitles, 13pt uppercase section headers and notes, a white symbol on a
// coloured rounded square leading a row, switches in the look's accent colour. The text follows Dynamic Type
// up to the largest size before the accessibility ones, and the app font of Shared/Fonts.
#import <UIKit/UIKit.h>

UIColor *SGGrey(void);   // the secondary label's grey
UIColor *SGGreen(void);
UIColor *SGRed(void);
UIColor *SGPageBackground(void);
UIColor *SGCardBackground(void);
UIFont *SGTitleFont(void);      // a row's title and value, Settings' body
UIFont *SGSubtitleFont(void);   // section headers, footers and notes, Settings' footnote
// Takes the 13pt title font off Spotify's own settings list, once, for the Mod Settings row the mod adds to it
// (App/ModSettings.x), which reads as one of Spotify's rows; SGSpotifyListFont hands it out.
void SGAdoptFonts(UIView *list, UIView *exclude);
UIFont *SGSpotifyListFont(void);

UIImageView *SGSymbolView(NSString *name, CGFloat size, UIImageSymbolWeight weight, CGFloat box);
// A white symbol on a rounded square of `color`, the leading icon of a row; SGTileImage's square is grey.
UIImage *SGTileImageTinted(NSString *symbol, UIColor *color);
UIImage *SGTileImage(NSString *symbol);
// The chevron of a row that opens a page, in the tertiary label's grey.
UIImageView *SGChevronView(void);
// The separator inset of a row led by a tile, so the hairline starts under the title as in Settings.
extern const CGFloat SGTileRowInset;
// A grey note in a wrapper view, for a table header or footer; SGFitNote sizes it to its text.
UIView *SGNote(NSString *text);
void SGFitNote(UITableView *table, UIView *wrapper, CGFloat top, CGFloat bottom);
// The now playing bar and the tab bar float over the content, so a page insets itself under them.
void SGInsetForBars(UITableView *table);

extern const CGFloat SGSectionHeaderHeight;
extern const CGFloat SGSectionGap;   // above a section with no header, so its card does not touch the one before
void SGFillCell(UITableViewCell *cell, NSString *title, NSString *subtitle, UIColor *color, NSString *symbolName);
UIView *SGSectionHeader(UITableView *table, NSString *title);
UIView *SGSectionFooter(UITableView *table, NSString *text);
CGFloat SGSectionFooterHeight(UITableView *table, NSString *text);
UITableViewCell *SGDequeueCell(UITableView *table, NSString *identifier);

void SGOpenURL(NSString *url);
extern NSString *const SGRepoURL;
// The controller on top of the key window, through whatever is presented over it.
UIViewController *SGTopController(void);
