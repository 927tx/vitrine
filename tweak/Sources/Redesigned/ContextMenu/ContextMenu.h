// The redesign's ⋯ opens the system menu instead of Spotify's sheet, the way the Music app's does: the
// player's ⋯ and the ⋯ every redesigned entity page pins to its corner (playlist, album, artist and the
// pages that share their templates). Always on in the redesign; no setting.
//
//     ContextMenu.x   the takeover: Spotify's sheet presented unseen, its rows read into a UIMenu shown from
//                     the ⋯, a pick fired on the sheet, and the sheet itself as the fallback
//
// Spotify's rows come from Swift item factories with nothing to read them from but the cells they fill, so
// the sheet is still Spotify's and still made: it is presented without animation inside a container at alpha
// 0, from its first frame (no dark flash), and the menu opens at once over it from an invisible anchor button
// inside the ⋯. On a page's ⋯, Spotify's rows are a deferred element of the menu, which shows the system's
// loading row until the sheet has them, however long that is. The player's menu waits on nothing: Share, Add
// to playlist and Add to queue, found among Spotify's rows by title, are a row of three at its top, then come
// the player's own items, then More, a submenu holding the rest of Spotify's rows and the only deferred element.
// A quick item picked before the sheet has its rows waits up to 2 s for them, else the sheet is shown.
//
// A pick closes the menu and then selects that row on the sheet, so what it does stays Spotify's; a pick that
// leaves the sheet up (a row opening a page of its own) shows the sheet. Rows the mod puts in the sheet's
// header or footer (Sort and Mix on a playlist, Edit info for a local file) are read the same way and fired the
// same way. Closing the menu without a pick dismisses the sheet.
//
// The anchor takes touches only while its menu is up, so every other tap reaches the ⋯ under it, and the menu
// is opened with -[UIControl performPrimaryAction] (iOS 17.4), else UIContextMenuInteraction's private
// _presentMenuAtLocation:, each checked with respondsToSelector:. When neither is there, or the menu does not
// come up, Spotify's sheet shows at once instead, with nothing waited out.
//
// Threading: main thread only.
#import <UIKit/UIKit.h>

// Items of the mod's own for the menu `button` opens, built afresh every time it opens.
typedef NSArray<UIMenuElement *> *(^SGRMenuItems)(void);
// What the sheet the ⋯ opens now is for ("track", "episode"...). The menu remembers which quick items the last
// sheet of each kind had, so the quick row is right before this sheet has its rows.
typedef NSString *(^SGRMenuKind)(void);

// Marks the next context menu sheet Spotify presents within a few seconds of a touch on `button` as this
// button's: it is shown as the system menu from `button`. With `items` (the player's ⋯), the menu is the quick
// row, `items`, then More; with nil it is Spotify's rows alone. `kind` may be nil. Watching the same button
// again only replaces `items` and `kind`. The pinned ⋯ of the entity pages needs no call: the Kit records its
// taps (SGRPinnedMoreRecentButton).
void SGRSystemMenuWatch(UIView *button, SGRMenuItems items, SGRMenuKind kind);
