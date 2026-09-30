//
//  FVDragDropView.h
//  FlareVault
//
//  Drag & Drop target view for folders.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@protocol FVDragDropViewDelegate <NSObject>
- (void)dragDropViewDidAcceptDirectoryPath:(NSString *)dirPath;
@end

@interface FVDragDropView : NSView

@property (nonatomic, weak) id<FVDragDropViewDelegate> delegate;
@property (nonatomic, copy, nullable) void (^onDirectoryDropped)(NSString *dirPath);
@property (nonatomic, assign) BOOL isHighlighted;

@end

NS_ASSUME_NONNULL_END
