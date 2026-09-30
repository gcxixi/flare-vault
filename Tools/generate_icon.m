//
//  generate_icon.m
//  Generates FlareVault high-resolution macOS application icon (.icns)
//

#import <Cocoa/Cocoa.h>

static void drawFlareVaultIcon(CGContextRef ctx, CGFloat size) {
    // 1. Draw rounded squircle background with gradient (Cloudflare Orange & Deep Navy)
    CGFloat cornerRadius = size * 0.22;
    CGRect rect = CGRectMake(0, 0, size, size);
    CGPathRef path = CGPathCreateWithRoundedRect(rect, cornerRadius, cornerRadius, NULL);
    CGContextAddPath(ctx, path);
    CGContextClip(ctx);

    // Background gradient: Deep Indigo to Slate
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGFloat bgComponents[] = {
        0.08, 0.12, 0.24, 1.0, // Dark navy
        0.14, 0.20, 0.35, 1.0  // Deep blue
    };
    CGFloat locations[] = {0.0, 1.0};
    CGGradientRef bgGradient = CGGradientCreateWithColorComponents(colorSpace, bgComponents, locations, 2);
    CGContextDrawLinearGradient(ctx, bgGradient, CGPointMake(0, size), CGPointMake(size, 0), 0);
    CGGradientRelease(bgGradient);

    // 2. Draw outer glowing ring
    CGContextSetStrokeColorWithColor(ctx, [NSColor colorWithRed:0.98 green:0.55 blue:0.18 alpha:0.9].CGColor);
    CGContextSetLineWidth(ctx, size * 0.03);
    CGFloat ringInset = size * 0.18;
    CGRect ringRect = CGRectInset(rect, ringInset, ringInset);
    CGContextStrokeEllipseInRect(ctx, ringRect);

    // 3. Draw Vault Body (Shield / Safe)
    CGFloat centerX = size * 0.5;
    CGFloat centerY = size * 0.46;
    CGFloat vaultW = size * 0.38;
    CGFloat vaultH = size * 0.34;
    CGRect vaultRect = CGRectMake(centerX - vaultW/2, centerY - vaultH/2, vaultW, vaultH);

    CGContextSetFillColorWithColor(ctx, [NSColor colorWithRed:0.98 green:0.55 blue:0.18 alpha:1.0].CGColor);
    CGPathRef vaultPath = CGPathCreateWithRoundedRect(vaultRect, size * 0.06, size * 0.06, NULL);
    CGContextAddPath(ctx, vaultPath);
    CGContextFillPath(ctx);
    CGPathRelease(vaultPath);

    // 4. Draw Shackle (Lock top)
    CGFloat shackleW = vaultW * 0.6;
    CGFloat shackleH = size * 0.20;
    CGRect shackleRect = CGRectMake(centerX - shackleW/2, centerY + vaultH/2 - size * 0.04, shackleW, shackleH);
    CGContextSetStrokeColorWithColor(ctx, [NSColor colorWithWhite:0.95 alpha:1.0].CGColor);
    CGContextSetLineWidth(ctx, size * 0.05);
    CGContextSetLineCap(ctx, kCGLineCapRound);

    CGMutablePathRef shacklePath = CGPathCreateMutable();
    CGPathAddArc(shacklePath, NULL, centerX, shackleRect.origin.y + shackleH/2, shackleW/2, M_PI, 0, YES);
    CGContextAddPath(ctx, shacklePath);
    CGContextStrokePath(ctx);
    CGPathRelease(shacklePath);

    // 5. Draw Keyhole & Asymmetric Radiating Rays
    CGContextSetFillColorWithColor(ctx, [NSColor colorWithRed:0.08 green:0.12 blue:0.24 alpha:1.0].CGColor);
    CGFloat keyRadius = size * 0.045;
    CGContextFillEllipseInRect(ctx, CGRectMake(centerX - keyRadius, centerY + size*0.01 - keyRadius, keyRadius*2, keyRadius*2));

    CGRect keyStem = CGRectMake(centerX - size*0.018, centerY - size*0.06, size*0.036, size*0.06);
    CGContextFillRect(ctx, keyStem);

    // 6. Draw Small Cloud Flare Accent at Bottom Right
    CGFloat cloudX = size * 0.72;
    CGFloat cloudY = size * 0.24;
    CGFloat cloudR = size * 0.08;
    CGContextSetFillColorWithColor(ctx, [NSColor colorWithRed:1.0 green:0.75 blue:0.2 alpha:0.9].CGColor);
    CGContextFillEllipseInRect(ctx, CGRectMake(cloudX - cloudR, cloudY - cloudR, cloudR*2, cloudR*2));

    CGColorSpaceRelease(colorSpace);
    CGPathRelease(path);
}

int main() {
    @autoreleasepool {
        NSString *iconsetDir = @"/tmp/FlareVault.iconset";
        [[NSFileManager defaultManager] removeItemAtPath:iconsetDir error:nil];
        [[NSFileManager defaultManager] createDirectoryAtPath:iconsetDir withIntermediateDirectories:YES attributes:nil error:nil];

        int sizes[] = {16, 32, 64, 128, 256, 512, 1024};
        int count = sizeof(sizes) / sizeof(sizes[0]);

        for (int i = 0; i < count; i++) {
            int s = sizes[i];
            // 1x
            {
                NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                                               pixelsWide:s
                                                                               pixelsHigh:s
                                                                            bitsPerSample:8
                                                                          samplesPerPixel:4
                                                                                 hasAlpha:YES
                                                                                 isPlanar:NO
                                                                           colorSpaceName:NSDeviceRGBColorSpace
                                                                              bytesPerRow:0
                                                                             bitsPerPixel:0];
                NSGraphicsContext *gc = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
                [NSGraphicsContext setCurrentContext:gc];
                drawFlareVaultIcon(gc.CGContext, (CGFloat)s);

                NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                NSString *path = [iconsetDir stringByAppendingPathComponent:[NSString stringWithFormat:@"icon_%dx%d.png", s, s]];
                [png writeToFile:path atomically:YES];
            }
            // 2x (retina)
            if (s <= 512) {
                int s2 = s * 2;
                NSBitmapImageRep *rep2 = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                                                pixelsWide:s2
                                                                                pixelsHigh:s2
                                                                             bitsPerSample:8
                                                                           samplesPerPixel:4
                                                                                  hasAlpha:YES
                                                                                  isPlanar:NO
                                                                            colorSpaceName:NSDeviceRGBColorSpace
                                                                               bytesPerRow:0
                                                                              bitsPerPixel:0];
                NSGraphicsContext *gc2 = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep2];
                [NSGraphicsContext setCurrentContext:gc2];
                drawFlareVaultIcon(gc2.CGContext, (CGFloat)s2);

                NSData *png2 = [rep2 representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                NSString *path2 = [iconsetDir stringByAppendingPathComponent:[NSString stringWithFormat:@"icon_%dx%d@2x.png", s, s]];
                [png2 writeToFile:path2 atomically:YES];
            }
        }

        printf("Iconset generated in %s\n", [iconsetDir UTF8String]);
    }
    return 0;
}
