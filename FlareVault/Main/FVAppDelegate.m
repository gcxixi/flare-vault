//
//  FVAppDelegate.m
//  FlareVault
//

#import "FVAppDelegate.h"
#import "../UI/FVMainWindowController.h"

@implementation FVAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    (void)aNotification;

    // Set activation policy to regular GUI app
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

    // Build standard macOS application menus programmatically
    [self setupMainMenu];

    // Show main window
    FVMainWindowController *mainController = [FVMainWindowController sharedController];
    [mainController.window center];
    [mainController.window makeKeyAndOrderFront:nil];

    [NSApp activateIgnoringOtherApps:YES];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return YES;
}

- (void)setupMainMenu {
    NSMenu *menubar = [[NSMenu alloc] init];

    // --- App Menu ---
    NSMenuItem *appMenuItem = [[NSMenuItem alloc] init];
    [menubar addItem:appMenuItem];

    NSMenu *appMenu = [[NSMenu alloc] init];
    NSString *appName = @"FlareVault";
    [appMenu addItemWithTitle:[NSString stringWithFormat:@"About %@", appName]
                       action:@selector(orderFrontStandardAboutPanel:)
                keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:[NSString stringWithFormat:@"Hide %@", appName]
                       action:@selector(hide:)
                keyEquivalent:@"h"];
    NSMenuItem *hideOthers = [appMenu addItemWithTitle:@"Hide Others"
                                                action:@selector(hideOtherApplications:)
                                         keyEquivalent:@"h"];
    hideOthers.keyEquivalentModifierMask = NSEventModifierFlagOption | NSEventModifierFlagCommand;
    [appMenu addItemWithTitle:@"Show All"
                       action:@selector(unhideAllApplications:)
                keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:[NSString stringWithFormat:@"Quit %@", appName]
                       action:@selector(terminate:)
                keyEquivalent:@"q"];
    appMenuItem.submenu = appMenu;

    // --- File Menu ---
    NSMenuItem *fileMenuItem = [[NSMenuItem alloc] init];
    [menubar addItem:fileMenuItem];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    [fileMenu addItemWithTitle:@"Close Window"
                        action:@selector(performClose:)
                 keyEquivalent:@"w"];
    fileMenuItem.submenu = fileMenu;

    // --- Edit Menu (for Copy/Paste in Text Fields) ---
    NSMenuItem *editMenuItem = [[NSMenuItem alloc] init];
    [menubar addItem:editMenuItem];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editMenu addItemWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
    [editMenu addItemWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"Z"];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    editMenuItem.submenu = editMenu;

    // --- Window Menu ---
    NSMenuItem *windowMenuItem = [[NSMenuItem alloc] init];
    [menubar addItem:windowMenuItem];
    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
    [windowMenu addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    [windowMenu addItemWithTitle:@"Zoom" action:@selector(performZoom:) keyEquivalent:@""];
    windowMenuItem.submenu = windowMenu;

    NSApp.mainMenu = menubar;
}

@end
