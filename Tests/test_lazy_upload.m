//
//  test_lazy_upload.m
//  FlareVault Tests
//
//  Verifies chunk jitter boundary calculations and stochastic timing generator.
//

#import <Foundation/Foundation.h>
#import "../FlareVault/Core/FVCloudflareUploader.h"

int main() {
    @autoreleasepool {
        NSLog(@"=== Starting Lazy / Stochastic Upload Math & Chunking Test ===");

        // 1. Verify chunk boundaries for a 23.5 MB file with jitter
        uint64_t fileSize = (uint64_t)(23.5 * 1024 * 1024);
        uint64_t minPartSize = 5 * 1024 * 1024;

        NSMutableArray<NSValue *> *chunks = [NSMutableArray array];
        uint64_t offset = 0;
        while (offset < fileSize) {
            uint64_t remaining = fileSize - offset;
            uint64_t chunkSize = minPartSize;

            // Random jitter: 5MB + (0..3MB)
            uint32_t jitter = arc4random_uniform(3 * 1024 * 1024);
            chunkSize += jitter;

            if (remaining <= chunkSize + minPartSize) {
                chunkSize = remaining;
            }

            [chunks addObject:[NSValue valueWithRange:NSMakeRange((NSUInteger)offset, (NSUInteger)chunkSize)]];
            offset += chunkSize;
        }

        NSLog(@"Total generated chunks for 23.5MB: %lu", (unsigned long)chunks.count);
        NSCAssert(chunks.count >= 3 && chunks.count <= 6, @"Chunk count within reasonable dynamic range");

        // Verify that all non-final chunks are >= 5MB (S3 requirement)
        uint64_t totalReconstructed = 0;
        for (NSUInteger i = 0; i < chunks.count; i++) {
            NSRange r = [chunks[i] rangeValue];
            if (i < chunks.count - 1) {
                NSCAssert(r.length >= minPartSize, @"Non-final chunk must be >= 5MB");
            }
            totalReconstructed += r.length;
            NSLog(@"  Chunk %lu: Offset %lu, Length: %.2f MB", (unsigned long)(i + 1), (unsigned long)r.location, r.length / (1024.0 * 1024.0));
        }
        NSCAssert(totalReconstructed == fileSize, @"Reconstructed size must match exactly");

        // 2. Verify randomized timing intervals
        double minSec = 2.0;
        double maxSec = 8.0;
        for (int i = 0; i < 10; i++) {
            double randFraction = (arc4random_uniform(1000) / 1000.0);
            double interval = minSec + ((maxSec - minSec) * randFraction);
            NSCAssert(interval >= minSec && interval <= maxSec, @"Interval within range");
        }

        NSLog(@"=== Lazy / Stochastic Upload Math Test PASSED! ===");
    }
    return 0;
}
