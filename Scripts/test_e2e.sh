#!/usr/bin/env bash
#
# End-to-End Integration Test Suite for FlareVault
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

# 4. Pack and Encrypt directory using standalone test runner
VAULT_FILE="$TEST_ROOT/backup.flarevault"

cat << 'EOF' > "$TEST_ROOT/run_pack_enc.m"
#import <Foundation/Foundation.h>
#import "FlareVault/Core/FVArchiver.h"
#import "FlareVault/Core/FVCryptoEngine.h"
#import "FlareVault/Core/FVKeyManager.h"

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 4) return 1;
        NSString *srcDir = [NSString stringWithUTF8String:argv[1]];
        NSString *pubKeyPath = [NSString stringWithUTF8String:argv[2]];
        NSString *outVault = [NSString stringWithUTF8String:argv[3]];

        NSError *err = nil;
        FVKeyManager *km = [FVKeyManager sharedManager];
        if (![km loadPublicKeyFromFile:pubKeyPath error:&err]) {
            NSLog(@"Failed to load pubkey: %@", err);
            return 1;
        }

        NSString *tmpTar = [NSTemporaryDirectory() stringByAppendingPathComponent:@"e2e_tmp.tar.gz"];
        if (![FVArchiver archiveDirectoryAtPath:srcDir toDestinationPath:tmpTar error:&err]) {
            NSLog(@"Failed to archive: %@", err);
            return 2;
        }

        NSDictionary *meta = @{@"test": @"e2e"};
        if (![FVCryptoEngine encryptFileAtPath:tmpTar toOutputPath:outVault withPublicKey:km.currentPublicKey metadata:meta progress:nil error:&err]) {
            NSLog(@"Failed to encrypt: %@", err);
            return 3;
        }
        [[NSFileManager defaultManager] removeItemAtPath:tmpTar error:nil];
        NSLog(@"Packing & Asymmetric Encryption Complete!");
    }
    return 0;
}
EOF

clang -fobjc-arc -framework Foundation -framework Security \
    -I "$REPO_DIR" \
    "$REPO_DIR/FlareVault/Core/FVArchiver.m" \
    "$REPO_DIR/FlareVault/Core/FVCryptoEngine.m" \
    "$REPO_DIR/FlareVault/Core/FVKeyManager.m" \
    "$TEST_ROOT/run_pack_enc.m" \
    -o "$TEST_ROOT/run_pack_enc"

"$TEST_ROOT/run_pack_enc" "$SOURCE_DIR" "$PUB_KEY" "$VAULT_FILE"
echo "[*] Encrypted archive created ($VAULT_FILE, $(wc -c < "$VAULT_FILE") bytes)"

# 5. Decrypt using native Objective-C CLI: flare-vault-decrypt
RESTORED_CLI="$TEST_ROOT/restored_cli"
mkdir -p "$RESTORED_CLI"
echo "[*] Testing decryption with native CLI tool (flare-vault-decrypt)..."
"$REPO_DIR/build/flare-vault-decrypt" -k "$PRIV_KEY" -i "$VAULT_FILE" -o "$RESTORED_CLI"

RESTORED_CLI_HASH=$(shasum -a 256 "$RESTORED_CLI/source_data/subdir/deep/random_blob.bin" | awk '{print $1}')
if [ "$ORIGINAL_HASH" != "$RESTORED_CLI_HASH" ]; then
    echo "[!] ERROR: Checksum mismatch in native CLI decryption!"
    exit 1
fi
echo "[+] SUCCESS: Native CLI decrypted and matched bit-for-bit!"

# 6. Decrypt using Python companion tool: Scripts/decrypt.py
RESTORED_PY="$TEST_ROOT/restored_py"
mkdir -p "$RESTORED_PY"
echo "[*] Testing decryption with Python companion tool (Scripts/decrypt.py)..."
python3 "$REPO_DIR/Scripts/decrypt.py" -k "$PRIV_KEY" -i "$VAULT_FILE" -o "$RESTORED_PY"

RESTORED_PY_HASH=$(shasum -a 256 "$RESTORED_PY/source_data/subdir/deep/random_blob.bin" | awk '{print $1}')
if [ "$ORIGINAL_HASH" != "$RESTORED_PY_HASH" ]; then
    echo "[!] ERROR: Checksum mismatch in Python decryption!"
    exit 1
fi
echo "[+] SUCCESS: Python tool decrypted and matched bit-for-bit!"

echo "=========================================================="
echo "    >>> ALL FLAREVAULT END-TO-END TESTS PASSED! <<<      "
echo "=========================================================="
