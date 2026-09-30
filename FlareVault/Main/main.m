//
//  main.m
//  FlareVault
//
//  Native AppKit entry point (Objective-C).
//

#import <Cocoa/Cocoa.h>
#import "FVAppDelegate.h"

int main(int argc, const char * argv[]) {
    (void)argc; (void)argv;
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        FVAppDelegate *delegate = [[FVAppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
