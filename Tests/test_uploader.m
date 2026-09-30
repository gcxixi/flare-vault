//
//  test_uploader.m
//  FlareVault Tests
//

#import <Foundation/Foundation.h>
#import "../FlareVault/Core/FVCloudflareUploader.h"

int main() {
    @autoreleasepool {
        NSLog(@"=== Starting FVCloudflareUploader Unit Test ===");

        FVCloudflareConfig *cfg = [[FVCloudflareConfig alloc] init];
        cfg.accountId = @"a1b2c3d4e5f678901234567890abcdef";
        cfg.bucketName = @"test-bucket";
        cfg.accessKeyId = @"mock_access_key_12345";
        cfg.secretAccessKey = @"mock_secret_key_67890";
        cfg.remotePrefix = @"backups/monthly/";
        cfg.lazyUploadEnabled = YES;
        cfg.lazyMinIntervalSeconds = 1.5;
        cfg.lazyMaxIntervalSeconds = 5.5;
        cfg.lazyChunkJitter = YES;

        FVCloudflareUploader *uploader = [[FVCloudflareUploader alloc] initWithConfig:cfg];
        NSCAssert([uploader.config.remotePrefix isEqualToString:@"backups/monthly/"], @"Config prefix match");
        NSCAssert([uploader.config.bucketName isEqualToString:@"test-bucket"], @"Config bucket match");
        NSCAssert(uploader.config.lazyUploadEnabled == YES, @"Lazy upload enabled match");
        NSCAssert(uploader.config.lazyMinIntervalSeconds == 1.5, @"Lazy min match");
        NSCAssert(uploader.config.lazyMaxIntervalSeconds == 5.5, @"Lazy max match");

        // Verify config copying
        FVCloudflareConfig *copy = [cfg copy];
        NSCAssert([copy.accountId isEqualToString:cfg.accountId], @"Config copy match");
        NSCAssert(copy.lazyUploadEnabled == cfg.lazyUploadEnabled, @"Copy lazy match");
        NSCAssert(copy.lazyMinIntervalSeconds == cfg.lazyMinIntervalSeconds, @"Copy lazy min match");

        NSLog(@"FVCloudflareUploader initialized cleanly.");
        NSLog(@"=== FVCloudflareUploader Test PASSED! ===");
    }
    return 0;
}
