// A font of the user's own for Fonts.x: a .ttf or .otf picked in Files is copied into Application Support,
// one file at a time, registered with Core Text for this process and named by the PostScript name read from
// it. Like every other font choice it takes over when Spotify starts again, and Fonts.x registers the file
// again on each launch.
#import <CoreText/CoreText.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "Shared/Fonts/Fonts.h"

static NSURL *fontFolder(void) {
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    return [[support URLByAppendingPathComponent:@"Vitrine" isDirectory:YES] URLByAppendingPathComponent:@"Font" isDirectory:YES];
}

static NSURL *storedFile(void) {
    NSString *file = [NSUserDefaults.standardUserDefaults stringForKey:SGKeyAppFontFile];
    return file.length ? [fontFolder() URLByAppendingPathComponent:file.lastPathComponent] : nil;
}

// The first face's PostScript name, or nil when Core Text finds no font in the file. A collection or a
// family in one file gives its first face.
static NSString *faceName(NSURL *url) {
    NSArray *faces = CFBridgingRelease(CTFontManagerCreateFontDescriptorsFromURL((__bridge CFURLRef)url));
    if (!faces.count) return nil;
    return CFBridgingRelease(CTFontDescriptorCopyAttribute((__bridge CTFontDescriptorRef)faces.firstObject, kCTFontNameAttribute));
}

// A face iOS already carries under the same name (Chalkduster, say) is refused as a duplicate and is there
// all the same, so what counts is whether the name makes a font afterwards.
static NSString *registerFile(NSURL *url) {
    NSString *name = url ? faceName(url) : nil;
    if (!name) return nil;
    CFErrorRef error = NULL;
    if (!CTFontManagerRegisterFontsForURL((__bridge CFURLRef)url, kCTFontManagerScopeProcess, &error)) {
        NSError *failure = CFBridgingRelease(error);
        SGLog(@"fonts: %@ not registered: %@", url.lastPathComponent, failure.localizedDescription);
    }
    return [UIFont fontWithName:name size:12] ? name : nil;
}

NSString *SGRegisterCustomFont(void) {
    NSString *name = registerFile(storedFile());
    if (name) [NSUserDefaults.standardUserDefaults setObject:name forKey:SGKeyAppFontName];
    return name;
}

static void tell(NSString *title, NSString *message, BOOL restart) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    if (restart) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Later" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Restart now" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { SGRestartSpotify(); }]];
    } else {
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    }
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

// The file is checked before the one in use is touched, so a file Core Text will not read changes nothing.
static void import(NSURL *picked) {
    BOOL scoped = [picked startAccessingSecurityScopedResource];
    NSString *name = faceName(picked);
    NSURL *folder = fontFolder(), *old = storedFile();
    NSString *file = [@"Custom" stringByAppendingPathExtension:picked.pathExtension.length ? picked.pathExtension.lowercaseString : @"ttf"];
    NSURL *target = [folder URLByAppendingPathComponent:file];
    NSFileManager *files = NSFileManager.defaultManager;
    BOOL copied = NO;
    if (name) {
        if (old) {
            CTFontManagerUnregisterFontsForURL((__bridge CFURLRef)old, kCTFontManagerScopeProcess, NULL);
            [files removeItemAtURL:old error:nil];
        }
        [files removeItemAtURL:target error:nil];
        [files createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];
        copied = [files copyItemAtURL:picked toURL:target error:nil];
    }
    if (scoped) [picked stopAccessingSecurityScopedResource];
    name = copied ? registerFile(target) : nil;
    if (!name) {
        tell(@"Font not imported", @"Choose a valid .ttf or .otf font file.", NO);
        return;
    }
    NSUserDefaults *store = NSUserDefaults.standardUserDefaults;
    [store setObject:file forKey:SGKeyAppFontFile];
    [store setObject:name forKey:SGKeyAppFontName];
    SGSetInt(SGKeyAppFont, SGAppFontCustom);
    tell(@"Font imported", [NSString stringWithFormat:@"%@ becomes the app's font when Spotify starts again.", name], YES);
}

@interface SGFontPicker : NSObject <UIDocumentPickerDelegate>
@end

@implementation SGFontPicker

- (void)documentPicker:(UIDocumentPickerViewController *)picker didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *picked = urls.firstObject;
    // The alert waits for the picker to be gone, or it has nothing to present over.
    dispatch_async(dispatch_get_main_queue(), ^{ if (picked) import(picked); });
}

@end

static void pickFont(void) {
    static SGFontPicker *delegate;
    if (!delegate) delegate = [SGFontPicker new];
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFont] asCopy:YES];
    picker.delegate = delegate;
    picker.allowsMultipleSelection = NO;
    [SGTopController() presentViewController:picker animated:YES completion:nil];
}

NSArray<SGModRow *> *SGAppFontRows(void) {
    SGModRow *font = SGChoiceRow(@"Font", nil, SGKeyAppFont, SGAppFontNames(), SGAppFontSpotify);
    NSString *(^choice)(void) = font.value;
    font.value = ^NSString *{
        NSString *name = [NSUserDefaults.standardUserDefaults stringForKey:SGKeyAppFontName];
        return SGAppFontChosen() == SGAppFontCustom && name.length ? name : choice();
    };
    font.choiceFooter = @"Custom font uses a .ttf or .otf file of your own, imported from Files. It has one weight, so bold text comes out regular, and text Spotify draws itself may keep its own font.";
    SGModRow *import = SGActionRow(@"Import custom font", nil, ^{ pickFont(); });
    import.visible = ^BOOL { return SGAppFontChosen() == SGAppFontCustom; };
    return @[SGWithSymbol(font, @"textformat"), SGWithSymbol(import, @"square.and.arrow.down")];
}
