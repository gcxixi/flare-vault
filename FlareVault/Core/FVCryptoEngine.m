//
//  FVCryptoEngine.m
//  FlareVault
//

#import "FVCryptoEngine.h"
#import <CommonCrypto/CommonCrypto.h>
#import <CommonCrypto/CommonHMAC.h>

NSString * const FVCryptoErrorDomain = @"com.flarevault.crypto";

static const uint8_t kFlareMagic[4] = {'F', 'L', 'A', 'R'};
static const uint8_t kFlareVersion = 1;
static const uint8_t kFlareAlgoRSA = 1;
#define kAESKeySize 32      // AES-256
#define kHMACKeySize 32     // SHA-256
#define kAESBlockSize 16
#define kChunkSize (1024 * 1024) // 1MB buffer

@implementation FVCryptoEngine

+ (BOOL)encryptFileAtPath:(NSString *)inputPath
             toOutputPath:(NSString *)outputPath
            withPublicKey:(SecKeyRef)publicKey
                 metadata:(nullable NSDictionary<NSString *, id> *)metadata
                 progress:(nullable FVCryptoProgressBlock)progress
                    error:(NSError * _Nullable * _Nullable)error
{
    if (!publicKey) {
        if (error) {
            *error = [NSError errorWithDomain:FVCryptoErrorDomain
                                         code:FVCryptoErrorInvalidKey
                                     userInfo:@{NSLocalizedDescriptionKey: @"Public key is nil."}];
        }
        return NO;
    }

    // Verify that the provided key is capable of encryption
    if (!SecKeyIsAlgorithmSupported(publicKey, kSecKeyOperationTypeEncrypt, kSecKeyAlgorithmRSAEncryptionOAEPSHA256)) {
        if (error) {
            *error = [NSError errorWithDomain:FVCryptoErrorDomain
                                         code:FVCryptoErrorInvalidKey
                                     userInfo:@{NSLocalizedDescriptionKey: @"The provided key does not support RSA-OAEP-SHA256 encryption."}];
        }
        return NO;
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSDictionary *inAttrs = [fileManager attributesOfItemAtPath:inputPath error:error];
    if (!inAttrs) {
        return NO;
    }
    uint64_t totalBytes = [inAttrs fileSize];

    NSFileHandle *inFile = [NSFileHandle fileHandleForReadingAtPath:inputPath];
    if (!inFile) {
        if (error) {
            *error = [NSError errorWithDomain:FVCryptoErrorDomain
                                         code:FVCryptoErrorFileIO
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Cannot open input file: %@", inputPath]}];
        }
        return NO;
    }

    if ([fileManager fileExistsAtPath:outputPath]) {
        [fileManager removeItemAtPath:outputPath error:nil];
    }
    [fileManager createFileAtPath:outputPath contents:nil attributes:nil];
    NSFileHandle *outFile = [NSFileHandle fileHandleForWritingAtPath:outputPath];
    if (!outFile) {
        [inFile closeFile];
        if (error) {
            *error = [NSError errorWithDomain:FVCryptoErrorDomain
                                         code:FVCryptoErrorFileIO
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Cannot open output file: %@", outputPath]}];
        }
        return NO;
    }

    // 1. Generate ephemeral session keys and IV
    uint8_t aesKey[kAESKeySize];
    uint8_t hmacKey[kHMACKeySize];
    uint8_t iv[kAESBlockSize];
    if (SecRandomCopyBytes(kSecRandomDefault, kAESKeySize, aesKey) != errSecSuccess ||
        SecRandomCopyBytes(kSecRandomDefault, kHMACKeySize, hmacKey) != errSecSuccess ||
        SecRandomCopyBytes(kSecRandomDefault, kAESBlockSize, iv) != errSecSuccess) {
        [inFile closeFile];
        [outFile closeFile];
        if (error) {
            *error = [NSError errorWithDomain:FVCryptoErrorDomain
                                         code:FVCryptoErrorEncryptionFailed
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to generate random cryptographic session keys."}];
        }
        return NO;
    }

    // 2. Encrypt session bundle (AES key + HMAC key = 64 bytes) using Public Key
    NSMutableData *sessionBundle = [NSMutableData dataWithBytes:aesKey length:kAESKeySize];
    [sessionBundle appendBytes:hmacKey length:kHMACKeySize];

    CFErrorRef secError = NULL;
    CFDataRef encKeyData = SecKeyCreateEncryptedData(publicKey,
                                                     kSecKeyAlgorithmRSAEncryptionOAEPSHA256,
                                                     (__bridge CFDataRef)sessionBundle,
                                                     &secError);
    if (!encKeyData) {
        [inFile closeFile];
        [outFile closeFile];
        if (error) {
            *error = [NSError errorWithDomain:FVCryptoErrorDomain
                                         code:FVCryptoErrorEncryptionFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"RSA session key encryption failed: %@", secError]}];
        }
        if (secError) CFRelease(secError);
        return NO;
    }

    // 3. Serialize metadata to JSON
    NSData *metaData = [NSData data];
    if (metadata && metadata.count > 0) {
        metaData = [NSJSONSerialization dataWithJSONObject:metadata options:0 error:nil] ?: [NSData data];
    }
    uint16_t metaLen = CFSwapInt16HostToBig((uint16_t)metaData.length);

    // 4. Construct Header
    // Magic (4) + Version (1) + Algo (1) + EncKeyLen (2) + EncKeyData (N) + IV (16) + Placeholder HMAC Tag (32) + MetaLen (2) + MetaData (M)
    NSMutableData *header = [NSMutableData dataWithBytes:kFlareMagic length:4];
    [header appendBytes:&kFlareVersion length:1];
    [header appendBytes:&kFlareAlgoRSA length:1];

    uint16_t encKeyLenBig = CFSwapInt16HostToBig((uint16_t)CFDataGetLength(encKeyData));
    [header appendBytes:&encKeyLenBig length:sizeof(encKeyLenBig)];
    [header appendData:(__bridge NSData *)encKeyData];
    [header appendBytes:iv length:kAESBlockSize];

    // Record the byte offset where the 32-byte HMAC tag will be stored
    uint64_t hmacOffset = (uint64_t)[header length];
    uint8_t zeroTag[CC_SHA256_DIGEST_LENGTH] = {0};
    [header appendBytes:zeroTag length:sizeof(zeroTag)];

    [header appendBytes:&metaLen length:sizeof(metaLen)];
    [header appendData:metaData];

    // Write preliminary header
    [outFile writeData:header];

    // 5. Initialize HMAC context (HMAC covers Header prefix + IV + Meta + Ciphertext)
    CCHmacContext hmacCtx;
    CCHmacInit(&hmacCtx, kCCHmacAlgSHA256, hmacKey, kHMACKeySize);

    // Feed header bytes excluding the HMAC tag placeholder
    NSData *preTag = [header subdataWithRange:NSMakeRange(0, (NSUInteger)hmacOffset)];
    NSData *postTag = [header subdataWithRange:NSMakeRange((NSUInteger)(hmacOffset + sizeof(zeroTag)),
                                                           header.length - (NSUInteger)(hmacOffset + sizeof(zeroTag)))];
    CCHmacUpdate(&hmacCtx, preTag.bytes, preTag.length);
    CCHmacUpdate(&hmacCtx, postTag.bytes, postTag.length);

    // 6. Initialize AES-256-CBC Cryptor
    CCCryptorRef cryptor = NULL;
    CCCryptorStatus cryptStatus = CCCryptorCreate(kCCEncrypt,
                                                  kCCAlgorithmAES,
                                                  kCCOptionPKCS7Padding,
                                                  aesKey, kAESKeySize,
                                                  iv,
                                                  &cryptor);
    if (cryptStatus != kCCSuccess) {
        CFRelease(encKeyData);
        [inFile closeFile];
        [outFile closeFile];
        if (error) {
            *error = [NSError errorWithDomain:FVCryptoErrorDomain
                                         code:FVCryptoErrorEncryptionFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to create AES cryptor (status: %d)", cryptStatus]}];
        }
        return NO;
    }

    // 7. Streaming chunk encryption
    NSMutableData *outBuffer = [NSMutableData dataWithLength:kChunkSize + kAESBlockSize];
    uint64_t bytesProcessed = 0;

    while (YES) {
        @autoreleasepool {
            NSData *chunk = [inFile readDataOfLength:kChunkSize];
            if (chunk.length == 0) {
                break;
            }

            size_t bytesEncrypted = 0;
            cryptStatus = CCCryptorUpdate(cryptor,
                                          chunk.bytes, chunk.length,
                                          outBuffer.mutableBytes, outBuffer.length,
                                          &bytesEncrypted);
            if (cryptStatus != kCCSuccess) {
                break;
            }

            if (bytesEncrypted > 0) {
                [outFile writeData:[NSData dataWithBytesNoCopy:outBuffer.mutableBytes length:bytesEncrypted freeWhenDone:NO]];
                CCHmacUpdate(&hmacCtx, outBuffer.mutableBytes, bytesEncrypted);
            }

            bytesProcessed += chunk.length;
            if (progress) {
                double p = totalBytes > 0 ? ((double)bytesProcessed / (double)totalBytes) : 1.0;
                progress(p, bytesProcessed, totalBytes);
            }
        }
    }

    if (cryptStatus == kCCSuccess) {
        // Finalize AES cryptor (PKCS#7 padding block)
        size_t finalEncrypted = 0;
        cryptStatus = CCCryptorFinal(cryptor,
                                     outBuffer.mutableBytes, outBuffer.length,
                                     &finalEncrypted);
        if (cryptStatus == kCCSuccess && finalEncrypted > 0) {
            [outFile writeData:[NSData dataWithBytesNoCopy:outBuffer.mutableBytes length:finalEncrypted freeWhenDone:NO]];
            CCHmacUpdate(&hmacCtx, outBuffer.mutableBytes, finalEncrypted);
        }
    }

    CCCryptorRelease(cryptor);
    CFRelease(encKeyData);
    [inFile closeFile];

    if (cryptStatus != kCCSuccess) {
        [outFile closeFile];
        if (error) {
            *error = [NSError errorWithDomain:FVCryptoErrorDomain
                                         code:FVCryptoErrorEncryptionFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"AES encryption failed with status: %d", cryptStatus]}];
        }
        return NO;
    }

    // 8. Compute final HMAC tag and overwrite placeholder in file header
    uint8_t finalTag[CC_SHA256_DIGEST_LENGTH];
    CCHmacFinal(&hmacCtx, finalTag);

    [outFile seekToFileOffset:hmacOffset];
    [outFile writeData:[NSData dataWithBytes:finalTag length:sizeof(finalTag)]];
    [outFile closeFile];

    // Wipe sensitive keys from memory
    memset(aesKey, 0, sizeof(aesKey));
    memset(hmacKey, 0, sizeof(hmacKey));

    if (progress) {
        progress(1.0, totalBytes, totalBytes);
    }

    return YES;
}

+ (BOOL)decryptFileAtPath:(NSString *)inputPath
             toOutputPath:(NSString *)outputPath
           withPrivateKey:(SecKeyRef)privateKey
                 metadata:(NSDictionary<NSString *, id> * _Nullable * _Nullable)outMetadata
                 progress:(nullable FVCryptoProgressBlock)progress
                    error:(NSError * _Nullable * _Nullable)error
{
    if (!privateKey) {
        if (error) {
            *error = [NSError errorWithDomain:FVCryptoErrorDomain
                                         code:FVCryptoErrorPrivateKeyRequired
                                     userInfo:@{NSLocalizedDescriptionKey: @"Private key is required to decrypt this archive. (The macOS App only holds the public key)."}] ;
        }
        return NO;
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSDictionary *inAttrs = [fileManager attributesOfItemAtPath:inputPath error:error];
    if (!inAttrs) {
        return NO;
    }
    uint64_t totalFileSize = [inAttrs fileSize];

    NSFileHandle *inFile = [NSFileHandle fileHandleForReadingAtPath:inputPath];
    if (!inFile) {
        if (error) {
            *error = [NSError errorWithDomain:FVCryptoErrorDomain
                                         code:FVCryptoErrorFileIO
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Cannot open file: %@", inputPath]}];
        }
        return NO;
    }

    // 1. Read and validate Magic
    NSData *magicData = [inFile readDataOfLength:4];
    if (magicData.length < 4 || memcmp(magicData.bytes, kFlareMagic, 4) != 0) {
        [inFile closeFile];
        if (error) {
            *error = [NSError errorWithDomain:FVCryptoErrorDomain
                                         code:FVCryptoErrorInvalidFormat
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid container format: magic header mismatch."}];
        }
        return NO;
    }

    // 2. Read Version and Algo
    NSData *verAlgoData = [inFile readDataOfLength:2];
    if (verAlgoData.length < 2) {
        [inFile closeFile];
        return NO;
    }
    const uint8_t *verAlgo = verAlgoData.bytes;
    if (verAlgo[0] != kFlareVersion || verAlgo[1] != kFlareAlgoRSA) {
        [inFile closeFile];
        if (error) {
            *error = [NSError errorWithDomain:FVCryptoErrorDomain
                                         code:FVCryptoErrorInvalidFormat
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Unsupported format version (%d) or algorithm (%d).", verAlgo[0], verAlgo[1]]}];
        }
        return NO;
    }

    // 3. Read Encrypted Key
    NSData *keyLenData = [inFile readDataOfLength:2];
    uint16_t encKeyLen = CFSwapInt16BigToHost(*(const uint16_t *)keyLenData.bytes);
    NSData *encKeyData = [inFile readDataOfLength:encKeyLen];

    // 4. Read IV
    NSData *ivData = [inFile readDataOfLength:kAESBlockSize];

    // 5. Read Expected HMAC Tag
    uint64_t hmacOffset = 4 + 2 + 2 + encKeyLen + kAESBlockSize;
    NSData *expectedTagData = [inFile readDataOfLength:CC_SHA256_DIGEST_LENGTH];

    // 6. Read Metadata
    NSData *metaLenData = [inFile readDataOfLength:2];
    uint16_t metaLen = CFSwapInt16BigToHost(*(const uint16_t *)metaLenData.bytes);
    NSData *metaData = [inFile readDataOfLength:metaLen];
    if (outMetadata && metaData.length > 0) {
        NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:metaData options:0 error:nil];
        if ([dict isKindOfClass:[NSDictionary class]]) {
            *outMetadata = dict;
        }
    }

    uint64_t ciphertextOffset = [inFile offsetInFile];
    uint64_t ciphertextSize = totalFileSize - ciphertextOffset;

    // 7. Decrypt Session Key Bundle (AES key + HMAC key) using Private Key
    CFErrorRef secError = NULL;
    CFDataRef sessionBundleData = SecKeyCreateDecryptedData(privateKey,
                                                           kSecKeyAlgorithmRSAEncryptionOAEPSHA256,
                                                           (__bridge CFDataRef)encKeyData,
                                                           &secError);
    if (!sessionBundleData || CFDataGetLength(sessionBundleData) < (kAESKeySize + kHMACKeySize)) {
        [inFile closeFile];
        if (error) {
            *error = [NSError errorWithDomain:FVCryptoErrorDomain
                                         code:FVCryptoErrorDecryptionFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"RSA private key decryption failed: %@", secError]}];
        }
        if (secError) CFRelease(secError);
        return NO;
    }

    const uint8_t *sessionBytes = CFDataGetBytePtr(sessionBundleData);
    uint8_t aesKey[kAESKeySize];
    uint8_t hmacKey[kHMACKeySize];
    memcpy(aesKey, sessionBytes, kAESKeySize);
    memcpy(hmacKey, sessionBytes + kAESKeySize, kHMACKeySize);
    CFRelease(sessionBundleData);

    // 8. Authenticate with HMAC before decryption
    CCHmacContext hmacCtx;
    CCHmacInit(&hmacCtx, kCCHmacAlgSHA256, hmacKey, kHMACKeySize);

    // Reconstruct preTag and postTag from file
    [inFile seekToFileOffset:0];
    NSData *preTag = [inFile readDataOfLength:(NSUInteger)hmacOffset];
    CCHmacUpdate(&hmacCtx, preTag.bytes, preTag.length);

    [inFile seekToFileOffset:hmacOffset + CC_SHA256_DIGEST_LENGTH];
    NSUInteger postTagLen = (NSUInteger)(ciphertextOffset - (hmacOffset + CC_SHA256_DIGEST_LENGTH));
    NSData *postTag = [inFile readDataOfLength:postTagLen];
    CCHmacUpdate(&hmacCtx, postTag.bytes, postTag.length);

    // Stream ciphertext to calculate HMAC
    while (YES) {
        @autoreleasepool {
            NSData *chunk = [inFile readDataOfLength:kChunkSize];
            if (chunk.length == 0) break;
            CCHmacUpdate(&hmacCtx, chunk.bytes, chunk.length);
        }
    }

    uint8_t computedTag[CC_SHA256_DIGEST_LENGTH];
    CCHmacFinal(&hmacCtx, computedTag);

    if (timingsafe_bcmp(computedTag, expectedTagData.bytes, CC_SHA256_DIGEST_LENGTH) != 0) {
        [inFile closeFile];
        memset(aesKey, 0, sizeof(aesKey));
        memset(hmacKey, 0, sizeof(hmacKey));
        if (error) {
            *error = [NSError errorWithDomain:FVCryptoErrorDomain
                                         code:FVCryptoErrorHMACMismatch
                                     userInfo:@{NSLocalizedDescriptionKey: @"HMAC signature mismatch! The archive is corrupted or has been tampered with."}];
        }
        return NO;
    }

    // 9. Now decrypt ciphertext with verified integrity
    [inFile seekToFileOffset:ciphertextOffset];

    if ([fileManager fileExistsAtPath:outputPath]) {
        [fileManager removeItemAtPath:outputPath error:nil];
    }
    [fileManager createFileAtPath:outputPath contents:nil attributes:nil];
    NSFileHandle *outFile = [NSFileHandle fileHandleForWritingAtPath:outputPath];
    if (!outFile) {
        [inFile closeFile];
        memset(aesKey, 0, sizeof(aesKey));
        memset(hmacKey, 0, sizeof(hmacKey));
        return NO;
    }

    CCCryptorRef cryptor = NULL;
    CCCryptorStatus cryptStatus = CCCryptorCreate(kCCDecrypt,
                                                  kCCAlgorithmAES,
                                                  kCCOptionPKCS7Padding,
                                                  aesKey, kAESKeySize,
                                                  ivData.bytes,
                                                  &cryptor);
    if (cryptStatus != kCCSuccess) {
        [inFile closeFile];
        [outFile closeFile];
        memset(aesKey, 0, sizeof(aesKey));
        memset(hmacKey, 0, sizeof(hmacKey));
        return NO;
    }

    NSMutableData *outBuffer = [NSMutableData dataWithLength:kChunkSize + kAESBlockSize];
    uint64_t bytesDecrypted = 0;

    while (YES) {
        @autoreleasepool {
            NSData *chunk = [inFile readDataOfLength:kChunkSize];
            if (chunk.length == 0) break;

            size_t numDec = 0;
            cryptStatus = CCCryptorUpdate(cryptor,
                                          chunk.bytes, chunk.length,
                                          outBuffer.mutableBytes, outBuffer.length,
                                          &numDec);
            if (cryptStatus != kCCSuccess) break;
            if (numDec > 0) {
                [outFile writeData:[NSData dataWithBytesNoCopy:outBuffer.mutableBytes length:numDec freeWhenDone:NO]];
            }

            bytesDecrypted += chunk.length;
            if (progress) {
                double p = ciphertextSize > 0 ? ((double)bytesDecrypted / (double)ciphertextSize) : 1.0;
                progress(p, bytesDecrypted, ciphertextSize);
            }
        }
    }

    if (cryptStatus == kCCSuccess) {
        size_t finalDec = 0;
        cryptStatus = CCCryptorFinal(cryptor,
                                     outBuffer.mutableBytes, outBuffer.length,
                                     &finalDec);
        if (cryptStatus == kCCSuccess && finalDec > 0) {
            [outFile writeData:[NSData dataWithBytesNoCopy:outBuffer.mutableBytes length:finalDec freeWhenDone:NO]];
        }
    }

    CCCryptorRelease(cryptor);
    [inFile closeFile];
    [outFile closeFile];

    memset(aesKey, 0, sizeof(aesKey));
    memset(hmacKey, 0, sizeof(hmacKey));

    if (cryptStatus != kCCSuccess) {
        if (error) {
            *error = [NSError errorWithDomain:FVCryptoErrorDomain
                                         code:FVCryptoErrorDecryptionFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"AES decryption failed with status: %d", cryptStatus]}];
        }
        return NO;
    }

    if (progress) {
        progress(1.0, ciphertextSize, ciphertextSize);
    }

    return YES;
}

+ (nullable NSString *)sha256ForFileAtPath:(NSString *)filePath error:(NSError * _Nullable * _Nullable)error {
    NSFileHandle *file = [NSFileHandle fileHandleForReadingAtPath:filePath];
    if (!file) {
        if (error) {
            *error = [NSError errorWithDomain:FVCryptoErrorDomain
                                         code:FVCryptoErrorFileIO
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Cannot read file: %@", filePath]}];
        }
        return nil;
    }

    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);

    while (YES) {
        @autoreleasepool {
            NSData *data = [file readDataOfLength:kChunkSize];
            if (data.length == 0) break;
            CC_SHA256_Update(&ctx, data.bytes, (CC_LONG)data.length);
        }
    }
    [file closeFile];

    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &ctx);

    NSMutableString *hex = [NSMutableString stringWithCapacity:sizeof(digest) * 2];
    for (size_t i = 0; i < sizeof(digest); i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return hex;
}

@end
