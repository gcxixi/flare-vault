//
//  FVCryptoEngine.h
//  FlareVault
//
//  Hybrid Asymmetric Encryption Engine (RSA-OAEP-SHA256 + AES-256-CBC + HMAC-SHA256)
//  The application only holds the Public Key and can ONLY encrypt.
//

#import <Foundation/Foundation.h>
#import <Security/Security.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const FVCryptoErrorDomain;

typedef NS_ENUM(NSInteger, FVCryptoErrorCode) {
    FVCryptoErrorInvalidKey = 1001,
    FVCryptoErrorEncryptionFailed = 1002,
    FVCryptoErrorDecryptionFailed = 1003,
    FVCryptoErrorFileIO = 1004,
    FVCryptoErrorInvalidFormat = 1005,
    FVCryptoErrorHMACMismatch = 1006,
    FVCryptoErrorPrivateKeyRequired = 1007
};

typedef void (^FVCryptoProgressBlock)(double progress, uint64_t bytesProcessed, uint64_t totalBytes);

@interface FVCryptoEngine : NSObject

/// Encrypts an input file (such as a tar.gz archive) using the provided Public Key.
/// Chunked streaming is used to keep memory usage minimal (< 10MB) even for gigabyte-scale archives.
///
/// @param inputPath Path to the plaintext file (e.g. .tar.gz)
/// @param outputPath Destination path for the .flarevault encrypted package
/// @param publicKey SecKeyRef representing the RSA Public Key (Must be public key)
/// @param metadata Optional metadata dictionary (will be stored as JSON header)
/// @param progress Optional progress reporting callback
/// @param error Output error pointer
/// @return YES on success, NO on failure
+ (BOOL)encryptFileAtPath:(NSString *)inputPath
             toOutputPath:(NSString *)outputPath
            withPublicKey:(SecKeyRef)publicKey
                 metadata:(nullable NSDictionary<NSString *, id> *)metadata
                 progress:(nullable FVCryptoProgressBlock)progress
                    error:(NSError * _Nullable * _Nullable)error;

/// Decrypts a .flarevault package using a Private Key.
/// NOTE: The macOS application itself does NOT keep or use private keys.
/// This method is provided for verification, test suites, and companion decryption tools.
///
/// @param inputPath Path to the .flarevault encrypted package
/// @param outputPath Destination path for the decrypted plaintext file
/// @param privateKey SecKeyRef representing the RSA Private Key
/// @param outMetadata Output pointer to retrieve container metadata dictionary
/// @param progress Optional progress reporting callback
/// @param error Output error pointer
/// @return YES on success, NO on failure
+ (BOOL)decryptFileAtPath:(NSString *)inputPath
             toOutputPath:(NSString *)outputPath
           withPrivateKey:(SecKeyRef)privateKey
                 metadata:(NSDictionary<NSString *, id> * _Nullable * _Nullable)outMetadata
                 progress:(nullable FVCryptoProgressBlock)progress
                    error:(NSError * _Nullable * _Nullable)error;

/// Calculates SHA-256 hex digest of a file.
+ (nullable NSString *)sha256ForFileAtPath:(NSString *)filePath error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
