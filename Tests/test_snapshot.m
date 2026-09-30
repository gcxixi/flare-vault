//
//  test_snapshot.m
//  FlareVault Tests
//

#import <Foundation/Foundation.h>
#import "../FlareVault/Core/FVSnapshotManager.h"
#import "../FlareVault/Core/FVArchiver.h"
#import <assert.h>

int main(void) {
    @autoreleasepool {
        NSLog(@"=== Starting FVSnapshotManager Differential Unit Test ===");

        NSString *tempBase = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"fv_snap_test_%u", arc4random()]];
        NSString *testDir = [tempBase stringByAppendingPathComponent:@"my_test_dir"];
        [[NSFileManager defaultManager] createDirectoryAtPath:testDir withIntermediateDirectories:YES attributes:nil error:nil];

        // 1. Initial files
        NSString *fileA = [testDir stringByAppendingPathComponent:@"fileA.txt"];
        [@"Content A version 1" writeToFile:fileA atomically:YES encoding:NSUTF8StringEncoding error:nil];

        NSString *subDir = [testDir stringByAppendingPathComponent:@"sub"];
        [[NSFileManager defaultManager] createDirectoryAtPath:subDir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *fileB = [subDir stringByAppendingPathComponent:@"fileB.txt"];
        [@"Content B version 1" writeToFile:fileB atomically:YES encoding:NSUTF8StringEncoding error:nil];

        FVSnapshotManager *mgr = [FVSnapshotManager sharedManager];
        [mgr resetSnapshotForDirectory:testDir];

        // 2. Initial Differential -> Should be Full Backup
        FVDifferentialResult *diff1 = [mgr computeDifferentialForDirectory:testDir excludePatterns:nil forceFull:NO];
        assert(diff1.isFullBackup == YES);
        assert(diff1.sequenceNumber == 0);
        assert(diff1.totalFilesCount == 2);
        assert(diff1.hasChanges == YES);
        NSLog(@"[+] Diff 1 verified: Full backup, 2 files.");

        // Commit snapshot 1
        BOOL ok1 = [mgr commitSnapshotForDirectory:testDir
                                      baseBackupId:@"base_test_001"
                                    sequenceNumber:0
                                           fileMap:diff1.currentScanMap
                                             error:nil];
        assert(ok1 == YES);
        assert([mgr hasSnapshotForDirectory:testDir] == YES);

        // 3. Differential with NO changes
        FVDifferentialResult *diffNoChange = [mgr computeDifferentialForDirectory:testDir excludePatterns:nil forceFull:NO];
        assert(diffNoChange.isFullBackup == NO);
        assert(diffNoChange.hasChanges == NO);
        assert(diffNoChange.changedFilesCount == 0);
        assert(diffNoChange.deletedFilesCount == 0);
        assert(diffNoChange.unchangedFilesCount == 2);
        NSLog(@"[+] Diff NoChange verified: 0 changes detected, hasChanges == NO.");

        // 4. Modify fileA, delete fileB, add fileC
        [NSThread sleepForTimeInterval:0.05]; // ensure mtime differs
        [@"Content A version 2 - modified!" writeToFile:fileA atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [[NSFileManager defaultManager] removeItemAtPath:fileB error:nil];

        NSString *fileC = [testDir stringByAppendingPathComponent:@"fileC.log"];
        [@"Content C new file" writeToFile:fileC atomically:YES encoding:NSUTF8StringEncoding error:nil];

        FVDifferentialResult *diff2 = [mgr computeDifferentialForDirectory:testDir excludePatterns:nil forceFull:NO];
        assert(diff2.isFullBackup == NO);
        assert(diff2.sequenceNumber == 1);
        assert([diff2.baseBackupId isEqualToString:@"base_test_001"]);
        assert(diff2.hasChanges == YES);
        assert(diff2.changedFilesCount == 2); // fileA modified, fileC added
        assert(diff2.deletedFilesCount == 1); // fileB deleted
        assert(diff2.unchangedFilesCount == 0);
        assert([diff2.deletedRelativePaths containsObject:@"sub/fileB.txt"]);
        assert([diff2.addedOrModifiedRelativePaths containsObject:@"fileA.txt"]);
        assert([diff2.addedOrModifiedRelativePaths containsObject:@"fileC.log"]);
        NSLog(@"[+] Diff 2 verified: 2 changed, 1 deleted, sequence 1.");

        // 5. Test archiving incremental package
        NSString *incTarPath = [tempBase stringByAppendingPathComponent:@"incremental_pack.tar.gz"];
        NSError *archErr = nil;
        BOOL packOk = [FVArchiver archiveDirectoryAtPath:testDir
                                           relativeFiles:diff2.addedOrModifiedRelativePaths
                                       toDestinationPath:incTarPath
                                                   error:&archErr];
        assert(packOk == YES);
        assert([[NSFileManager defaultManager] fileExistsAtPath:incTarPath]);

        // Commit snapshot 2
        BOOL ok2 = [mgr commitSnapshotForDirectory:testDir
                                      baseBackupId:diff2.baseBackupId
                                    sequenceNumber:diff2.sequenceNumber
                                           fileMap:diff2.currentScanMap
                                             error:nil];
        assert(ok2 == YES);

        // 6. Test reset
        [mgr resetSnapshotForDirectory:testDir];
        assert([mgr hasSnapshotForDirectory:testDir] == NO);

        FVDifferentialResult *diffAfterReset = [mgr computeDifferentialForDirectory:testDir excludePatterns:nil forceFull:NO];
        assert(diffAfterReset.isFullBackup == YES);
        assert(diffAfterReset.sequenceNumber == 0);
        NSLog(@"[+] Reset snapshot verified: reverted cleanly to full backup mode.");

        // Cleanup
        [[NSFileManager defaultManager] removeItemAtPath:tempBase error:nil];

        NSLog(@"=== FVSnapshotManager Unit Test PASSED! ===");
    }
    return 0;
}
