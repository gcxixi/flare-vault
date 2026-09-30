//
//  test_crypto.m
//  FlareVault Tests
//

#import <Foundation/Foundation.h>
#import "../FlareVault/Core/FVCryptoEngine.h"

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSLog(@"=== Starting FVCryptoEngine Unit Test ===");

        // 1. Generate an RSA Keypair for testing
        NSDictionary *attrs = @{
            (id)kSecAttrKeyType: (id)kSecAttrKeyTypeRSA,
            (id)kSecAttrKeySizeInBits: @2048,
        };
        CFErrorRef error = NULL;
        SecKeyRef privateKey = SecKeyCreateRandomKey((CFDictionaryRef)attrs, &error);
        NSCAssert(privateKey != NULL, @"Failed to generate RSA private key");
        
        SecKeyRef publicKey = SecKeyCopyPublicKey(privateKey);
        NSCAssert(publicKey != NULL, @"Failed to derive RSA public key");

        // 2. Create a dummy test file with arbitrary binary data
        NSString *tempDir = NSTemporaryDirectory();
        NSString *plainPath = [tempDir stringByAppendingPathComponent:@"test_plain.bin"];
        NSString *encPath = [tempDir stringByAppendingPathComponent:@"test_enc.flarevault"];
        NSString *decPath = [tempDir stringByAppendingPathComponent:@"test_dec.bin"];

        NSMutableData *testData = [NSMutableData dataWithLength:2 * 1024 * 1024 + 777]; // ~2MB
        arc4random_buf(testData.mutableBytes, testData.length);
        [testData writeToFile:plainPath atomically:YES];

        NSError *err = nil;
        NSString *originalSha = [FVCryptoEngine sha256ForFileAtPath:plainPath error:&err];
        NSLog(@"Original file SHA256: %@", originalSha);

        // 3. Encrypt file using ONLY the public key
        NSDictionary *metadata = @{
            @"test_name": @"unit_test",
            @"original_size": @(testData.length),
            @"timestamp": @([[NSDate date] timeIntervalSince1970])
        };

        NSLog(@"Encrypting with Public Key...");
        BOOL encSuccess = [FVCryptoEngine encryptFileAtPath:plainPath
                                               toOutputPath:encPath
                                              withPublicKey:publicKey
                                                   metadata:metadata
                                                   progress:^(double progress, uint64_t bytesProcessed, uint64_t totalBytes) {
            NSLog(@"[Encryption Progress] %.1f%% (%llu / %llu bytes)", progress * 100.0, bytesProcessed, totalBytes);
        } error:&err];

        if (!encSuccess) {
            NSLog(@"Encryption failed: %@", err);
            return 1;
        }
        NSLog(@"Encryption succeeded! Encrypted file created at: %@", encPath);

        // 4. Verify that attempting to decrypt with the PUBLIC key FAILS
        NSLog(@"Verifying that Public Key CANNOT decrypt...");
        BOOL pubDecSuccess = [FVCryptoEngine decryptFileAtPath:encPath
                                                  toOutputPath:decPath
                                                withPrivateKey:publicKey
                                                      metadata:nil
                                                      progress:nil
                                                         error:&err];
        if (pubDecSuccess) {
            NSLog(@"CRITICAL SECURITY FLAW: Public key was able to decrypt!");
            return 1;
        } else {
            NSLog(@"Security verified: Public key cannot decrypt! Expected error: %@", err.localizedDescription);
        }

        // 5. Decrypt using the PRIVATE key (recipient side)
        NSLog(@"Decrypting with Private Key...");
        NSDictionary *restoredMeta = nil;
        BOOL decSuccess = [FVCryptoEngine decryptFileAtPath:encPath
                                               toOutputPath:decPath
                                             withPrivateKey:privateKey
                                                   metadata:&restoredMeta
                                                   progress:^(double progress, uint64_t bytesProcessed, uint64_t totalBytes) {
            NSLog(@"[Decryption Progress] %.1f%% (%llu / %llu bytes)", progress * 100.0, bytesProcessed, totalBytes);
        } error:&err];

        if (!decSuccess) {
            NSLog(@"Decryption failed: %@", err);
            return 1;
        }
        NSLog(@"Decryption succeeded! Restored metadata: %@", restoredMeta);

        // 6. Verify SHA256 checksum matches bit-for-bit
        NSString *restoredSha = [FVCryptoEngine sha256ForFileAtPath:decPath error:&err];
        NSLog(@"Restored file SHA256: %@", restoredSha);

        if ([originalSha isEqualToString:restoredSha]) {
            NSLog(@"SUCCESS: Checksums match perfectly!");
        } else {
            NSLog(@"FAILURE: Checksum mismatch!");
            return 1;
        }

        // Cleanup
        [[NSFileManager defaultManager] removeItemAtPath:plainPath error:nil];
        [[NSFileManager defaultManager] removeItemAtPath:encPath error:nil];
        [[NSFileManager defaultManager] removeItemAtPath:decPath error:nil];

        NSLog(@"=== FVCryptoEngine Test PASSED! ===");
    }
    return 0;
}
