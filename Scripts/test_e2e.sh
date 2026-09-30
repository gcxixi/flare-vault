#!/usr/bin/env bash
#
# End-to-End Integration Test Suite for FlareVault
# Covers Full Backup, Incremental Backup, Tombstone Deletions, and Multi-Generation Restore.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

TEST_ROOT="$(mktemp -d -t fv_e2e_test)"
trap 'rm -rf "$TEST_ROOT"' EXIT

echo "=========================================================="
echo "         Starting FlareVault End-to-End Test Suite       "
echo "=========================================================="
echo "Test working directory: $TEST_ROOT"

# 1. Compile required tools if not already built
mkdir -p "$REPO_DIR/build"
if [ ! -f "$REPO_DIR/build/flare-vault-decrypt" ]; then
    echo "[*] Compiling flare-vault-decrypt CLI..."
    clang -Wall -Wextra -O2 -fobjc-arc -framework Cocoa -framework Security \
        "$REPO_DIR/Tools/flare-vault-decrypt.m" \
        "$REPO_DIR/FlareVault/Core/FVCryptoEngine.m" \
        "$REPO_DIR/FlareVault/Core/FVArchiver.m" \
        -o "$REPO_DIR/build/flare-vault-decrypt"
fi

# 2. Create synthetic test directory with multiple files and nested directories
SOURCE_DIR="$TEST_ROOT/source_data"
mkdir -p "$SOURCE_DIR/subdir/deep"
echo "Sample Text Document 1" > "$SOURCE_DIR/file1.txt"
echo "Configuration and JSON { 'key': 'value', 'number': 42 }" > "$SOURCE_DIR/subdir/config.json"
head -c 524288 /dev/urandom > "$SOURCE_DIR/subdir/deep/random_blob.bin"

ORIGINAL_HASH=$(shasum -a 256 "$SOURCE_DIR/subdir/deep/random_blob.bin" | awk '{print $1}')
echo "[*] Generated synthetic source folder ($SOURCE_DIR)"
echo "    Blob SHA256: $ORIGINAL_HASH"

# 3. Generate RSA Keypair
PRIV_KEY="$TEST_ROOT/private.pem"
PUB_KEY="$TEST_ROOT/public.pem"
openssl genrsa -out "$PRIV_KEY" 2048 2>/dev/null
openssl rsa -in "$PRIV_KEY" -pubout -out "$PUB_KEY" 2>/dev/null

echo "[*] Generated test RSA 2048-bit keypair"

# 4. Compile helper runner for full and incremental packaging
cat << 'EOF' > "$TEST_ROOT/run_backup_runner.m"
#import <Foundation/Foundation.h>
#import "FlareVault/Core/FVArchiver.h"
#import "FlareVault/Core/FVCryptoEngine.h"
#import "FlareVault/Core/FVKeyManager.h"
#import "FlareVault/Core/FVSnapshotManager.h"

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 4) return 1;
        NSString *srcDir = [NSString stringWithUTF8String:argv[1]];
        NSString *pubKeyPath = [NSString stringWithUTF8String:argv[2]];
        NSString *outVault = [NSString stringWithUTF8String:argv[3]];
        BOOL isInc = (argc >= 5 && strcmp(argv[4], "--incremental") == 0);

        NSError *err = nil;
        FVKeyManager *km = [FVKeyManager sharedManager];
        if (![km loadPublicKeyFromFile:pubKeyPath error:&err]) {
            NSLog(@"Failed to load pubkey: %@", err);
            return 1;
        }

        FVSnapshotManager *snapMgr = [FVSnapshotManager sharedManager];
        FVDifferentialResult *diff = [snapMgr computeDifferentialForDirectory:srcDir excludePatterns:nil forceFull:!isInc];

        NSString *tmpTar = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"e2e_tar_%u.tar.gz", arc4random()]];
        if (diff.isFullBackup) {
            if (![FVArchiver archiveDirectoryAtPath:srcDir toDestinationPath:tmpTar error:&err]) {
                NSLog(@"Full archive failed: %@", err);
                return 2;
            }
        } else {
            if (![FVArchiver archiveDirectoryAtPath:srcDir relativeFiles:diff.addedOrModifiedRelativePaths toDestinationPath:tmpTar error:&err]) {
                NSLog(@"Incremental archive failed: %@", err);
                return 2;
            }
        }

        NSMutableDictionary *meta = [NSMutableDictionary dictionaryWithDictionary:@{
            @"backup_type": diff.isFullBackup ? @"full" : @"incremental",
            @"base_backup_id": diff.isFullBackup ? @"base_full_e2e" : (diff.baseBackupId ?: @"base_full_e2e"),
            @"sequence": @(diff.sequenceNumber),
            @"folder_name": [srcDir lastPathComponent]
        }];
        if (!diff.isFullBackup) {
            meta[@"deleted_files"] = diff.deletedRelativePaths ?: @[];
            meta[@"changed_files_count"] = @(diff.changedFilesCount);
            meta[@"deleted_files_count"] = @(diff.deletedFilesCount);
        }

        if (![FVCryptoEngine encryptFileAtPath:tmpTar toOutputPath:outVault withPublicKey:km.currentPublicKey metadata:meta progress:nil error:&err]) {
            NSLog(@"Failed to encrypt: %@", err);
            return 3;
        }

        [[NSFileManager defaultManager] removeItemAtPath:tmpTar error:nil];

        // Commit snapshot
        [snapMgr commitSnapshotForDirectory:srcDir
                               baseBackupId:meta[@"base_backup_id"]
                             sequenceNumber:diff.sequenceNumber
                                    fileMap:diff.currentScanMap
                                      error:nil];

        NSLog(@"[Runner] Backup successful! Mode: %@, Seq: %lu, Changed: %lu, Deleted: %lu",
              diff.isFullBackup ? @"Full" : @"Inc", (unsigned long)diff.sequenceNumber, (unsigned long)diff.changedFilesCount, (unsigned long)diff.deletedFilesCount);
    }
    return 0;
}
EOF

clang -fobjc-arc -framework Cocoa -framework Security \
    -I "$REPO_DIR" \
    "$REPO_DIR/FlareVault/Core/FVArchiver.m" \
    "$REPO_DIR/FlareVault/Core/FVCryptoEngine.m" \
    "$REPO_DIR/FlareVault/Core/FVKeyManager.m" \
    "$REPO_DIR/FlareVault/Core/FVSnapshotManager.m" \
    "$TEST_ROOT/run_backup_runner.m" \
    -o "$TEST_ROOT/run_backup_runner"

# 5. Execute Full Backup (Gen 0)
VAULT_FULL="$TEST_ROOT/backup_full.flarevault"
"$TEST_ROOT/run_backup_runner" "$SOURCE_DIR" "$PUB_KEY" "$VAULT_FULL"
echo "[*] Base Full Encrypted Archive created: $VAULT_FULL ($(wc -c < "$VAULT_FULL") bytes)"

# 6. Test Single Full Restore with native CLI and Python tool
RESTORED_CLI="$TEST_ROOT/restored_full_cli"
mkdir -p "$RESTORED_CLI"
"$REPO_DIR/build/flare-vault-decrypt" -k "$PRIV_KEY" -i "$VAULT_FULL" -o "$RESTORED_CLI"
RESTORED_CLI_HASH=$(shasum -a 256 "$RESTORED_CLI/source_data/subdir/deep/random_blob.bin" | awk '{print $1}')
[ "$ORIGINAL_HASH" == "$RESTORED_CLI_HASH" ] || { echo "[!] Full CLI restore hash mismatch"; exit 1; }
echo "[+] SUCCESS: Base Full Backup decrypted by native CLI!"

RESTORED_PY="$TEST_ROOT/restored_full_py"
mkdir -p "$RESTORED_PY"
python3 "$REPO_DIR/Scripts/decrypt.py" -k "$PRIV_KEY" -i "$VAULT_FULL" -o "$RESTORED_PY"
RESTORED_PY_HASH=$(shasum -a 256 "$RESTORED_PY/source_data/subdir/deep/random_blob.bin" | awk '{print $1}')
[ "$ORIGINAL_HASH" == "$RESTORED_PY_HASH" ] || { echo "[!] Full Python restore hash mismatch"; exit 1; }
echo "[+] SUCCESS: Base Full Backup decrypted by Python tool!"

# 7. Simulate directory changes: Update file1, delete config.json, add new_feature.md
sleep 0.1
echo "Sample Text Document 1 - UPDATED TO VERSION 2" > "$SOURCE_DIR/file1.txt"
rm "$SOURCE_DIR/subdir/config.json"
echo "# New Feature Documentation" > "$SOURCE_DIR/new_feature.md"

# 8. Execute Incremental Backup (Gen 1)
VAULT_INC1="$TEST_ROOT/backup_inc1.flarevault"
"$TEST_ROOT/run_backup_runner" "$SOURCE_DIR" "$PUB_KEY" "$VAULT_INC1" --incremental
echo "[*] Incremental Encrypted Archive created: $VAULT_INC1 ($(wc -c < "$VAULT_INC1") bytes)"

# Verify incremental package is lightweight (large blob is not duplicated)
INC1_SIZE=$(wc -c < "$VAULT_INC1" | tr -d ' ')
if [ "$INC1_SIZE" -gt 50000 ]; then
    echo "[!] ERROR: Incremental archive size ($INC1_SIZE bytes) unexpectedly large!"
    exit 1
fi
echo "[+] Incremental size verified: only $INC1_SIZE bytes (random_blob.bin was skipped)!"

# 9. Test Multi-Generation Chain Restore using native CLI
RESTORED_INC_CLI="$TEST_ROOT/restored_inc_cli"
mkdir -p "$RESTORED_INC_CLI"
echo "[*] Restoring multi-generation chain via native CLI (flare-vault-decrypt)..."
"$REPO_DIR/build/flare-vault-decrypt" -k "$PRIV_KEY" -o "$RESTORED_INC_CLI" -i "$VAULT_FULL" -i "$VAULT_INC1"

# Assertions on restored directory
[ -f "$RESTORED_INC_CLI/source_data/new_feature.md" ] || { echo "[!] missing new_feature.md"; exit 1; }
grep -q "UPDATED TO VERSION 2" "$RESTORED_INC_CLI/source_data/file1.txt" || { echo "[!] file1.txt not updated"; exit 1; }
[ ! -f "$RESTORED_INC_CLI/source_data/subdir/config.json" ] || { echo "[!] config.json was not deleted by tombstone"; exit 1; }
RESTORED_INC_HASH=$(shasum -a 256 "$RESTORED_INC_CLI/source_data/subdir/deep/random_blob.bin" | awk '{print $1}')
[ "$ORIGINAL_HASH" == "$RESTORED_INC_HASH" ] || { echo "[!] random_blob.bin mismatch"; exit 1; }
echo "[+] SUCCESS: Native CLI verified multi-generation incremental restore with tombstones!"

# 10. Test Multi-Generation Chain Restore using Python tool
RESTORED_INC_PY="$TEST_ROOT/restored_inc_py"
mkdir -p "$RESTORED_INC_PY"
echo "[*] Restoring multi-generation chain via Python tool (Scripts/decrypt.py)..."
python3 "$REPO_DIR/Scripts/decrypt.py" -k "$PRIV_KEY" -o "$RESTORED_INC_PY" -i "$VAULT_FULL" "$VAULT_INC1"

[ -f "$RESTORED_INC_PY/source_data/new_feature.md" ] || { echo "[!] python missing new_feature.md"; exit 1; }
grep -q "UPDATED TO VERSION 2" "$RESTORED_INC_PY/source_data/file1.txt" || { echo "[!] python file1.txt not updated"; exit 1; }
[ ! -f "$RESTORED_INC_PY/source_data/subdir/config.json" ] || { echo "[!] python config.json was not deleted"; exit 1; }
RESTORED_INC_PY_HASH=$(shasum -a 256 "$RESTORED_INC_PY/source_data/subdir/deep/random_blob.bin" | awk '{print $1}')
[ "$ORIGINAL_HASH" == "$RESTORED_INC_PY_HASH" ] || { echo "[!] python random_blob.bin mismatch"; exit 1; }
echo "[+] SUCCESS: Python tool verified multi-generation incremental restore with tombstones!"

echo "=========================================================="
echo "    >>> ALL FULL & INCREMENTAL E2E TESTS PASSED! <<<      "
echo "=========================================================="
