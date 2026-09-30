//
//  test_archiver.m
//  FlareVault Tests
//

#import <Foundation/Foundation.h>
#import "../FlareVault/Core/FVArchiver.h"

int main() {
    @autoreleasepool {
        NSLog(@"=== Starting FVArchiver Unit Test ===");

        NSString *tempDir = NSTemporaryDirectory();
        NSString *testDir = [tempDir stringByAppendingPathComponent:@"test_folder_to_archive"];
        NSString *subDir = [testDir stringByAppendingPathComponent:@"nested_sub"];
        [[NSFileManager defaultManager] createDirectoryAtPath:subDir withIntermediateDirectories:YES attributes:nil error:nil];

        // Create some sample files
        [@"File A Content" writeToFile:[testDir stringByAppendingPathComponent:@"a.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [@"File B Nested Content" writeToFile:[subDir stringByAppendingPathComponent:@"b.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];

        // 1. Inspect
        FVDirectoryStats *stats = [FVArchiver inspectDirectoryAtPath:testDir];
        NSLog(@"Directory stats: %lu files, %lu dirs, size: %@", (unsigned long)stats.fileCount, (unsigned long)stats.dirCount, stats.formattedSize);
        NSCAssert(stats.fileCount == 2, @"File count should be 2");

        // 2. Archive
        NSString *tarPath = [tempDir stringByAppendingPathComponent:@"test_archive.tar.gz"];
        NSError *err = nil;
        BOOL archOk = [FVArchiver archiveDirectoryAtPath:testDir toDestinationPath:tarPath error:&err];
        if (!archOk) {
            NSLog(@"Archiving failed: %@", err);
            return 1;
        }
        NSLog(@"Archived successfully to %@", tarPath);

        // 3. Extract to new folder
        NSString *extractDir = [tempDir stringByAppendingPathComponent:@"test_extracted"];
        BOOL extOk = [FVArchiver extractArchiveAtPath:tarPath toDestinationPath:extractDir error:&err];
        if (!extOk) {
            NSLog(@"Extraction failed: %@", err);
            return 1;
        }
        NSLog(@"Extracted successfully to %@", extractDir);

        // Verify extracted files exist
        NSString *checkA = [extractDir stringByAppendingPathComponent:@"test_folder_to_archive/a.txt"];
        NSString *contentA = [NSString stringWithContentsOfFile:checkA encoding:NSUTF8StringEncoding error:nil];
        NSCAssert([contentA isEqualToString:@"File A Content"], @"File content must match");
        NSLog(@"Verification matched! Content: %@", contentA);

        // Cleanup
        [[NSFileManager defaultManager] removeItemAtPath:testDir error:nil];
        [[NSFileManager defaultManager] removeItemAtPath:tarPath error:nil];
        [[NSFileManager defaultManager] removeItemAtPath:extractDir error:nil];

        NSLog(@"=== FVArchiver Test PASSED! ===");
    }
    return 0;
}
