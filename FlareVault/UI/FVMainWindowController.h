//
//  FVMainWindowController.h
//  FlareVault
//
//  Main window controller implemented completely in native AppKit (Objective-C).
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface FVMainWindowController : NSWindowController

+ (instancetype)sharedController;

@end

NS_ASSUME_NONNULL_END
