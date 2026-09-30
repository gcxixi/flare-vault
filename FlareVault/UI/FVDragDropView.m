//
//  FVDragDropView.m
//  FlareVault
//

#import "FVDragDropView.h"

@implementation FVDragDropView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        [self registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
        self.wantsLayer = YES;
        self.layer.cornerRadius = 8.0;
        self.layer.borderWidth = 1.5;
        [self updateAppearance];
    }
    return self;
}

- (void)updateAppearance {
    if (self.isHighlighted) {
        self.layer.borderColor = [NSColor systemBlueColor].CGColor;
        self.layer.backgroundColor = [[NSColor systemBlueColor] colorWithAlphaComponent:0.1].CGColor;
    } else {
        self.layer.borderColor = [NSColor separatorColor].CGColor;
        self.layer.backgroundColor = [[NSColor controlBackgroundColor] colorWithAlphaComponent:0.5].CGColor;
    }
    [self setNeedsDisplay:YES];
}

- (void)setIsHighlighted:(BOOL)isHighlighted {
    _isHighlighted = isHighlighted;
    [self updateAppearance];
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    NSPasteboard *pboard = [sender draggingPasteboard];
    if ([pboard.types containsObject:NSPasteboardTypeFileURL]) {
        self.isHighlighted = YES;
        return NSDragOperationCopy;
    }
    return NSDragOperationNone;
}

- (void)draggingExited:(id<NSDraggingInfo>)sender {
    (void)sender;
    self.isHighlighted = NO;
}

- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)sender {
    (void)sender;
    return YES;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    self.isHighlighted = NO;
    NSPasteboard *pboard = [sender draggingPasteboard];
    if ([pboard.types containsObject:NSPasteboardTypeFileURL]) {
        NSArray *classes = @[[NSURL class]];
        NSDictionary *options = @{NSPasteboardURLReadingFileURLsOnlyKey: @YES};
        NSArray *urls = [pboard readObjectsForClasses:classes options:options];

        for (NSURL *url in urls) {
            NSNumber *isDir = nil;
            [url getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
            if ([isDir boolValue]) {
                if (self.onDirectoryDropped) {
                    self.onDirectoryDropped(url.path);
                }
                if ([self.delegate respondsToSelector:@selector(dragDropViewDidAcceptDirectoryPath:)]) {
                    [self.delegate dragDropViewDidAcceptDirectoryPath:url.path];
                }
                return YES;
            }
        }
    }
    return NO;
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    NSString *prompt = @"拖拽待备份目录至此区域，或点击上方“浏览...”选择";
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: [NSColor secondaryLabelColor]
    };
    NSSize strSize = [prompt sizeWithAttributes:attrs];
    NSRect textRect = NSMakeRect((self.bounds.size.width - strSize.width) / 2.0,
                                 (self.bounds.size.height - strSize.height) / 2.0,
                                 strSize.width, strSize.height);
    [prompt drawInRect:textRect withAttributes:attrs];
}

@end
