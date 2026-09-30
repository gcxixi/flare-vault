//
//  flare-vault-decrypt.m
//  FlareVault Companion Decryption CLI
//
//  Decodes and unpacks .flarevault archives using the Private Key.
//

#import <Foundation/Foundation.h>
#import "../FlareVault/Core/FVCryptoEngine.h"
#import "../FlareVault/Core/FVArchiver.h"

static void printUsage(const char *progName) {
    fprintf(stderr, "FlareVault Decryption CLI (macOS / Linux)\n");
    fprintf(stderr, "Usage:\n");
    fprintf(stderr, "  %s -k <private_key.pem> -i <input.flarevault> -o <output_dir> [-p <password>]\n\n", progName);
    fprintf(stderr, "Options:\n");
    fprintf(stderr, "  -k, --key       Path to RSA Private Key PEM\n");
    fprintf(stderr, "  -i, --input     Path to encrypted .flarevault archive\n");
    fprintf(stderr, "  -o, --output    Destination directory to unpack restored files\n");
    fprintf(stderr, "  -p, --pass      Password for encrypted private key (if applicable)\n");
    fprintf(stderr, "  -h, --help      Show this help message\n");
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSString *keyPath = nil;
        NSString *inputPath = nil;
        NSString *outputDir = nil;
        NSString *password = nil;

        for (int i = 1; i < argc; i++) {
            NSString *arg = [NSString stringWithUTF8String:argv[i]];
            if (([arg isEqualToString:@"-k"] || [arg isEqualToString:@"--key"]) && i + 1 < argc) {
                keyPath = [NSString stringWithUTF8String:argv[++i]];
            } else if (([arg isEqualToString:@"-i"] || [arg isEqualToString:@"--input"]) && i + 1 < argc) {
                inputPath = [NSString stringWithUTF8String:argv[++i]];
            } else if (([arg isEqualToString:@"-o"] || [arg isEqualToString:@"--output"]) && i + 1 < argc) {
                outputDir = [NSString stringWithUTF8String:argv[++i]];
            } else if (([arg isEqualToString:@"-p"] || [arg isEqualToString:@"--pass"]) && i + 1 < argc) {
                password = [NSString stringWithUTF8String:argv[++i]];
            } else if ([arg isEqualToString:@"-h"] || [arg isEqualToString:@"--help"]) {
                printUsage(argv[0]);
                return 0;
            }
        }

        if (!keyPath || !inputPath || !outputDir) {
            printUsage(argv[0]);
            return 1;
        }

        printf("=== FlareVault Archive Decryption ===\n");
        printf("Encrypted Archive: %s\n", [inputPath UTF8String]);
        printf("Private Key:       %s\n", [keyPath UTF8String]);
        printf("Output Directory:  %s\n", [outputDir UTF8String]);

        // 1. Load private key
        NSString *privKeyPEM = [NSString stringWithContentsOfFile:keyPath encoding:NSUTF8StringEncoding error:nil];
        if (!privKeyPEM) {
            fprintf(stderr, "Error: Cannot read private key file: %s\n", [keyPath UTF8String]);
            return 1;
        }

        NSString *tempDecKeyPath = nil;
        if (password.length > 0 || [privKeyPEM containsString:@"ENCRYPTED"]) {
            tempDecKeyPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"dec_key_%u.pem", arc4random()]];
            NSMutableArray *args = [NSMutableArray arrayWithObjects:@"rsa", @"-in", keyPath, @"-out", tempDecKeyPath, nil];
            if (password.length > 0) {
                [args addObjectsFromArray:@[@"-passin", [NSString stringWithFormat:@"pass:%@", password]]];
            }
            NSTask *task = [[NSTask alloc] init];
            task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/openssl"];
            task.arguments = args;
            [task launch];
            [task waitUntilExit];
            if (task.terminationStatus != 0) {
                fprintf(stderr, "Error: Failed to decrypt private key. Incorrect password?\n");
                return 1;
            }
            privKeyPEM = [NSString stringWithContentsOfFile:tempDecKeyPath encoding:NSUTF8StringEncoding error:nil];
        }

        // Parse PEM to SecKeyRef
        NSArray *lines = [privKeyPEM componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
        NSMutableString *base64 = [NSMutableString string];
        for (NSString *line in lines) {
            NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if ([trimmed hasPrefix:@"-----"]) continue;
            [base64 appendString:trimmed];
        }

        NSData *der = [[NSData alloc] initWithBase64EncodedString:base64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
        if (tempDecKeyPath) {
            [[NSFileManager defaultManager] removeItemAtPath:tempDecKeyPath error:nil];
        }

        if (!der) {
            fprintf(stderr, "Error: Failed to base64-decode private key PEM.\n");
            return 1;
        }

        CFErrorRef cfErr = NULL;
        NSDictionary *attrs = @{
            (id)kSecAttrKeyType: (id)kSecAttrKeyTypeRSA,
            (id)kSecAttrKeyClass: (id)kSecAttrKeyClassPrivate,
        };
        SecKeyRef privKey = SecKeyCreateWithData((__bridge CFDataRef)der, (__bridge CFDictionaryRef)attrs, &cfErr);
        if (!privKey) {
            fprintf(stderr, "Error: SecKeyCreateWithData failed for private key.\n");
            return 1;
        }

        // 2. Decrypt .flarevault container to temporary .tar.gz
        NSString *tempTarPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"flare_restored_%u.tar.gz", arc4random()]];
        NSDictionary *metadata = nil;
        NSError *err = nil;

        printf("Authenticating HMAC and decrypting archive payload...\n");
        BOOL decOk = [FVCryptoEngine decryptFileAtPath:inputPath
                                         toOutputPath:tempTarPath
                                       withPrivateKey:privKey
                                             metadata:&metadata
                                             progress:^(double progress, uint64_t bytesProcessed, uint64_t totalBytes) {
            (void)bytesProcessed; (void)totalBytes;
            printf("\r[Decrypt Progress] %.1f%%", progress * 100.0);
            fflush(stdout);
        } error:&err];

        CFRelease(privKey);
        printf("\n");

        if (!decOk) {
            fprintf(stderr, "Error: Decryption failed: %s\n", [err.localizedDescription UTF8String]);
            [[NSFileManager defaultManager] removeItemAtPath:tempTarPath error:nil];
            return 1;
        }

        if (metadata) {
            printf("Container Metadata: %s (Original size: %llu bytes, Files: %lu)\n",
                   [metadata[@"folder_name"] UTF8String] ?: "Unknown",
                   [metadata[@"original_bytes"] unsignedLongLongValue],
                   [metadata[@"file_count"] unsignedLongValue]);
        }

        // 3. Extract tar.gz into target directory
        printf("Unpacking restored tar.gz into: %s...\n", [outputDir UTF8String]);
        BOOL extOk = [FVArchiver extractArchiveAtPath:tempTarPath toDestinationPath:outputDir error:&err];
        [[NSFileManager defaultManager] removeItemAtPath:tempTarPath error:nil];

        if (!extOk) {
            fprintf(stderr, "Error: Unpacking failed: %s\n", [err.localizedDescription UTF8String]);
            return 1;
        }

        printf("✅ Successfully restored and unpacked archive into: %s\n", [outputDir UTF8String]);
    }
    return 0;
}
