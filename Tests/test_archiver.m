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

        // Cleanup basic test
        [[NSFileManager defaultManager] removeItemAtPath:testDir error:nil];
        [[NSFileManager defaultManager] removeItemAtPath:tarPath error:nil];
        [[NSFileManager defaultManager] removeItemAtPath:extractDir error:nil];

        // 4. Test Exclusion Functionality (node_modules, .venv, custom patterns)
        NSLog(@"=== Testing FVArchiver Exclusion Patterns ===");
        NSString *exTestDir = [tempDir stringByAppendingPathComponent:@"test_exclude_workspace"];
        NSString *nodeModulesDir = [exTestDir stringByAppendingPathComponent:@"node_modules/express"];
        NSString *venvDir = [exTestDir stringByAppendingPathComponent:@".venv/bin"];
        NSString *srcDir = [exTestDir stringByAppendingPathComponent:@"src"];

        [[NSFileManager defaultManager] createDirectoryAtPath:nodeModulesDir withIntermediateDirectories:YES attributes:nil error:nil];
        [[NSFileManager defaultManager] createDirectoryAtPath:venvDir withIntermediateDirectories:YES attributes:nil error:nil];
        [[NSFileManager defaultManager] createDirectoryAtPath:srcDir withIntermediateDirectories:YES attributes:nil error:nil];

        // Valid source files
        [@"console.log('main');" writeToFile:[srcDir stringByAppendingPathComponent:@"index.js"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [@"print('hello')" writeToFile:[srcDir stringByAppendingPathComponent:@"app.py"] atomically:YES encoding:NSUTF8StringEncoding error:nil];

        // Excluded files
        [@"module.exports = {}" writeToFile:[nodeModulesDir stringByAppendingPathComponent:@"index.js"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [@"python binary" writeToFile:[venvDir stringByAppendingPathComponent:@"python"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [@"temp secret log" writeToFile:[exTestDir stringByAppendingPathComponent:@"build.log"] atomically:YES encoding:NSUTF8StringEncoding error:nil];

        NSArray *excludes = @[@"node_modules", @".venv", @"*.log"];
        FVDirectoryStats *exStats = [FVArchiver inspectDirectoryAtPath:exTestDir excludePatterns:excludes];
        NSLog(@"Excluded inspect stats: %lu files, %lu excluded, size: %@", (unsigned long)exStats.fileCount, (unsigned long)exStats.excludedCount, exStats.formattedSize);
        NSCAssert(exStats.fileCount == 2, @"Only 2 source files in src/ should be counted");
        NSCAssert(exStats.excludedCount >= 3, @"At least 3 excluded items (node_modules, .venv, build.log)");

        NSString *exTarPath = [tempDir stringByAppendingPathComponent:@"test_exclude.tar.gz"];
        BOOL exArchOk = [FVArchiver archiveDirectoryAtPath:exTestDir toDestinationPath:exTarPath excludePatterns:excludes error:&err];
        NSCAssert(exArchOk, @"Archiving with excludes should succeed");

        NSString *exExtractDir = [tempDir stringByAppendingPathComponent:@"test_exclude_extracted"];
        BOOL exExtOk = [FVArchiver extractArchiveAtPath:exTarPath toDestinationPath:exExtractDir error:&err];
        NSCAssert(exExtOk, @"Extracting exclude archive should succeed");

        // Verify valid files exist
        NSString *restoredApp = [exExtractDir stringByAppendingPathComponent:@"test_exclude_workspace/src/app.py"];
        NSCAssert([[NSFileManager defaultManager] fileExistsAtPath:restoredApp], @"app.py must be present");

        // Verify excluded files DO NOT exist
        NSString *restoredNodeModules = [exExtractDir stringByAppendingPathComponent:@"test_exclude_workspace/node_modules"];
        NSString *restoredVenv = [exExtractDir stringByAppendingPathComponent:@"test_exclude_workspace/.venv"];
        NSString *restoredLog = [exExtractDir stringByAppendingPathComponent:@"test_exclude_workspace/build.log"];

        NSCAssert(![[NSFileManager defaultManager] fileExistsAtPath:restoredNodeModules], @"node_modules MUST be excluded!");
        NSCAssert(![[NSFileManager defaultManager] fileExistsAtPath:restoredVenv], @".venv MUST be excluded!");
        NSCAssert(![[NSFileManager defaultManager] fileExistsAtPath:restoredLog], @"build.log MUST be excluded!");
        NSLog(@"[+] All exclusions (node_modules, .venv, *.log) verified successfully!");

        // Cleanup exclude test
        [[NSFileManager defaultManager] removeItemAtPath:exTestDir error:nil];
        [[NSFileManager defaultManager] removeItemAtPath:exTarPath error:nil];
        [[NSFileManager defaultManager] removeItemAtPath:exExtractDir error:nil];

        NSLog(@"=== FVArchiver Test PASSED! ===");
    }
    return 0;
}
