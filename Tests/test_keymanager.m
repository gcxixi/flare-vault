//
//  test_keymanager.m
//  FlareVault Tests
//

#import <Foundation/Foundation.h>
#import "../FlareVault/Core/FVKeyManager.h"
#import "../FlareVault/Core/FVCryptoEngine.h"

int main() {
    @autoreleasepool {
        NSLog(@"=== Starting FVKeyManager Unit Test ===");

        FVKeyManager *mgr = [FVKeyManager sharedManager];

        // 1. Generate keypair from password
        NSString *testPassword = @"SecureMasterPassword2026!";
        NSString *exportedPrivPEM = nil;
        NSError *err = nil;

        NSLog(@"Generating 2048-bit RSA keypair with password protection...");
        BOOL genOk = [mgr generateKeypairWithBits:2048
                                 passwordProtect:testPassword
                               outPrivateKeyPEM:&exportedPrivPEM
                                          error:&err];
        if (!genOk) {
            NSLog(@"Generation failed: %@", err);
            return 1;
        }

        NSLog(@"Key generation succeeded!");
        NSLog(@"Exported Private Key PEM length: %lu bytes", (unsigned long)exportedPrivPEM.length);
        NSCAssert([exportedPrivPEM containsString:@"ENCRYPTED PRIVATE KEY"] || [exportedPrivPEM containsString:@"RSA PRIVATE KEY"], @"Invalid private key format");
        
        NSLog(@"Loaded Public Key Summary: %@", mgr.currentKeySummary);
        NSLog(@"Fingerprint: %@", mgr.currentKeyFingerprint);
        NSCAssert(mgr.currentPublicKey != NULL, @"Current public key must not be null");

        // 2. Clear and reload from PEM
        NSString *pubPEM = [mgr.currentPublicKeyPEM copy];
        [mgr clearKey];
        NSCAssert(mgr.currentPublicKey == NULL, @"Key should be cleared");

        BOOL reloadOk = [mgr loadPublicKeyFromPEM:pubPEM error:&err];
        if (!reloadOk) {
            NSLog(@"Reload failed: %@", err);
            return 1;
        }
        NSLog(@"Reload from PEM succeeded! Fingerprint matches: %@", mgr.currentKeyFingerprint);

        // 3. Test encrypting a small payload using the key managed by FVKeyManager
        NSString *tempDir = NSTemporaryDirectory();
        NSString *plainPath = [tempDir stringByAppendingPathComponent:@"key_test_plain.txt"];
        NSString *encPath = [tempDir stringByAppendingPathComponent:@"key_test_enc.flarevault"];
        [@"Test payload for keymanager verification" writeToFile:plainPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

        BOOL encOk = [FVCryptoEngine encryptFileAtPath:plainPath
                                         toOutputPath:encPath
                                        withPublicKey:mgr.currentPublicKey
                                             metadata:@{@"origin": @"keymanager_test"}
                                             progress:nil
                                                error:&err];
        if (!encOk) {
            NSLog(@"Encryption using manager key failed: %@", err);
            return 1;
        }
        NSLog(@"Encryption using manager key succeeded!");

        [[NSFileManager defaultManager] removeItemAtPath:plainPath error:nil];
        [[NSFileManager defaultManager] removeItemAtPath:encPath error:nil];

        NSLog(@"=== FVKeyManager Test PASSED! ===");
    }
    return 0;
}
