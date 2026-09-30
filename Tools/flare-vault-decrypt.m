//
//  flare-vault-decrypt.m
//  FlareVault Companion Decryption CLI
//
//  Decodes and unpacks .flarevault archives using the Private Key.
//  Supports single-archive full restore and multi-generation incremental restore chains.
//

#import <Foundation/Foundation.h>
#import "../FlareVault/Core/FVCryptoEngine.h"
#import "../FlareVault/Core/FVArchiver.h"

static void printUsage(const char *progName) {
    fprintf(stderr, "FlareVault Decryption CLI (macOS / Linux)\n");
    fprintf(stderr, "Usage:\n");
    fprintf(stderr, "  %s -k <private_key.pem> -o <output_dir> -i <full.flarevault> [-i <inc1.flarevault> ...] [-p <password>]\n\n", progName);
    fprintf(stderr, "Options:\n");
    fprintf(stderr, "  -k, --key       Path to RSA Private Key PEM\n");
    fprintf(stderr, "  -i, --input     Path to encrypted .flarevault archive (can be specified multiple times for incremental chains)\n");
    fprintf(stderr, "  -o, --output    Destination directory to unpack restored files\n");
    fprintf(stderr, "  -p, --pass      Password for encrypted private key (if applicable)\n");
    fprintf(stderr, "  -h, --help      Show this help message\n");
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSString *keyPath = nil;
        NSMutableArray<NSString *> *inputPaths = [NSMutableArray array];
        NSString *outputDir = nil;
        NSString *password = nil;

        for (int i = 1; i < argc; i++) {
            NSString *arg = [NSString stringWithUTF8String:argv[i]];
            if (([arg isEqualToString:@"-k"] || [arg isEqualToString:@"--key"]) && i + 1 < argc) {
                keyPath = [NSString stringWithUTF8String:argv[++i]];
            } else if (([arg isEqualToString:@"-i"] || [arg isEqualToString:@"--input"]) && i + 1 < argc) {
                NSString *inVal = [NSString stringWithUTF8String:argv[++i]];
                NSArray *parts = [inVal componentsSeparatedByString:@","];
                for (NSString *p in parts) {
                    NSString *trimmed = [p stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    if (trimmed.length > 0) [inputPaths addObject:trimmed];
                }
            } else if (([arg isEqualToString:@"-o"] || [arg isEqualToString:@"--output"]) && i + 1 < argc) {
                outputDir = [NSString stringWithUTF8String:argv[++i]];
            } else if (([arg isEqualToString:@"-p"] || [arg isEqualToString:@"--pass"]) && i + 1 < argc) {
                password = [NSString stringWithUTF8String:argv[++i]];
            } else if ([arg isEqualToString:@"-h"] || [arg isEqualToString:@"--help"]) {
                printUsage(argv[0]);
                return 0;
            } else if (![arg hasPrefix:@"-"]) {
                [inputPaths addObject:arg];
            }
        }

        if (!keyPath || inputPaths.count == 0 || !outputDir) {
            printUsage(argv[0]);
            return 1;
        }

        printf("=== FlareVault Archive Decryption ===\n");
        printf("Private Key:       %s\n", [keyPath UTF8String]);
        printf("Output Directory:  %s\n", [outputDir UTF8String]);
        printf("Archive Count:     %lu\n", (unsigned long)inputPaths.count);

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

        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:outputDir]) {
            [fm createDirectoryAtPath:outputDir withIntermediateDirectories:YES attributes:nil error:nil];
        }

        // 2. Iterate through all archives in sequence
        for (NSUInteger idx = 0; idx < inputPaths.count; idx++) {
            NSString *archivePath = inputPaths[idx];
            printf("\n[%lu/%lu] Processing Archive: %s\n", (unsigned long)(idx + 1), (unsigned long)inputPaths.count, [archivePath.lastPathComponent UTF8String]);

            if (![fm fileExistsAtPath:archivePath]) {
                fprintf(stderr, "Error: Archive file not found: %s\n", [archivePath UTF8String]);
                CFRelease(privKey);
                return 1;
            }

            NSString *tempTarPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"flare_restored_%u_%lu.tar.gz", arc4random(), (unsigned long)idx]];
            NSDictionary *metadata = nil;
            NSError *err = nil;

            printf("  -> Authenticating HMAC and decrypting payload...\n");
            BOOL decOk = [FVCryptoEngine decryptFileAtPath:archivePath
                                             toOutputPath:tempTarPath
                                           withPrivateKey:privKey
                                                 metadata:&metadata
                                                 progress:^(double progress, uint64_t bytesProcessed, uint64_t totalBytes) {
                (void)bytesProcessed; (void)totalBytes;
                printf("\r  -> [Progress] %.1f%%", progress * 100.0);
                fflush(stdout);
            } error:&err];

            printf("\n");
            if (!decOk) {
                fprintf(stderr, "Error: Decryption failed for %s: %s\n", [archivePath.lastPathComponent UTF8String], [err.localizedDescription UTF8String]);
                [fm removeItemAtPath:tempTarPath error:nil];
                CFRelease(privKey);
                return 1;
            }

            NSString *bType = metadata[@"backup_type"] ?: @"full";
            NSNumber *seq = metadata[@"sequence"] ?: @(0);
            printf("  -> Type: %s (Sequence: #%d, Base: %s)\n",
                   [bType UTF8String],
                   [seq intValue],
                   [metadata[@"base_backup_id"] UTF8String] ?: "N/A");

            // Extract tar.gz into target directory
            printf("  -> Unpacking files into: %s...\n", [outputDir UTF8String]);
            BOOL extOk = [FVArchiver extractArchiveAtPath:tempTarPath toDestinationPath:outputDir error:&err];
            [fm removeItemAtPath:tempTarPath error:nil];

            if (!extOk) {
                fprintf(stderr, "Error: Unpacking failed: %s\n", [err.localizedDescription UTF8String]);
                CFRelease(privKey);
                return 1;
            }

            // Apply tombstones (deleted files) if present in metadata
            NSArray<NSString *> *deletedFiles = metadata[@"deleted_files"];
            if ([deletedFiles isKindOfClass:[NSArray class]] && deletedFiles.count > 0) {
                NSString *folderName = metadata[@"folder_name"] ?: @"";
                NSUInteger removedCount = 0;
                for (NSString *delPath in deletedFiles) {
                    NSString *targetDel = [outputDir stringByAppendingPathComponent:delPath];
                    if (![fm fileExistsAtPath:targetDel] && folderName.length > 0) {
                        targetDel = [[outputDir stringByAppendingPathComponent:folderName] stringByAppendingPathComponent:delPath];
                    }
                    if ([fm fileExistsAtPath:targetDel]) {
                        [fm removeItemAtPath:targetDel error:nil];
                        removedCount++;
                    }
                }
                printf("  -> Applied %lu file deletions (tombstones).\n", (unsigned long)removedCount);
            }

            if ([bType isEqualToString:@"incremental"]) {
                printf("  -> Applied incremental snapshot #%d successfully.\n", [seq intValue]);
            } else {
                printf("  -> Base full backup restored successfully.\n");
            }
        }

        CFRelease(privKey);

        printf("\n✅ Successfully restored complete directory snapshot (all archives applied) into: %s\n", [outputDir UTF8String]);
    }
    return 0;
}
