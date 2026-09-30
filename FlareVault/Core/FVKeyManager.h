//
//  FVKeyManager.h
//  FlareVault
//
//  Manages Asymmetric Public Keys (Encrypt-Only).
//  Supports:
//  - Loading RSA Public Keys from PEM string or file.
//  - Generating keypairs with password protection (saving private key offline, keeping only public key).
//  - Retrieving / Storing Public Keys in macOS Keychain.
//  - Deriving Public Key Fingerprints (SHA-256).
//

#import <Foundation/Foundation.h>
#import <Security/Security.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const FVKeyManagerErrorDomain;

@interface FVKeyManager : NSObject

/// Currently active RSA Public Key (Encrypted-only, no private key).
@property (nonatomic, assign, readonly, nullable) SecKeyRef currentPublicKey;

/// PEM representation of the current public key.
@property (nonatomic, copy, readonly, nullable) NSString *currentPublicKeyPEM;

/// SHA-256 fingerprint of the current public key.
@property (nonatomic, copy, readonly, nullable) NSString *currentKeyFingerprint;

/// Human-readable key info (e.g. "RSA 2048-bit (Public Only)").
@property (nonatomic, copy, readonly, nullable) NSString *currentKeySummary;

+ (instancetype)sharedManager;

/// Clears the currently loaded public key from memory.
- (void)clearKey;

/// Sets and validates a public key from a PEM string (SubjectPublicKeyInfo or PKCS#1).
///
/// @param pemString The PEM encoded public key string
/// @param error Output error pointer
/// @return YES on success, NO on failure
- (BOOL)loadPublicKeyFromPEM:(NSString *)pemString error:(NSError * _Nullable * _Nullable)error;

/// Loads a public key directly from a .pem / .pub file on disk.
- (BOOL)loadPublicKeyFromFile:(NSString *)filePath error:(NSError * _Nullable * _Nullable)error;

/// Generates a new RSA keypair (2048 or 4096 bit).
/// The private key is exported as PEM (optionally encrypted with the provided password)
/// and returned so the user can save it offline.
/// ONLY the Public Key is retained in this manager and memory.
///
/// @param keyBits 2048 or 4096
/// @param password Optional password to encrypt the exported private key PEM
/// @param outPrivateKeyPEM Output pointer for the generated private key PEM
/// @param error Output error pointer
/// @return YES on success, NO on failure
- (BOOL)generateKeypairWithBits:(int)keyBits
               passwordProtect:(nullable NSString *)password
             outPrivateKeyPEM:(NSString * _Nullable * _Nullable)outPrivateKeyPEM
                        error:(NSError * _Nullable * _Nullable)error;

/// Reads the public key stored in macOS Keychain under Generic Password.
///
/// @param serviceName Keychain service identifier (default is "com.flarevault.publickey")
/// @param accountName Keychain account identifier (e.g. "default" or email)
/// @param error Output error pointer
/// @return YES on success, NO on failure
- (BOOL)loadPublicKeyFromKeychainWithService:(NSString *)serviceName
                                     account:(nullable NSString *)accountName
                                       error:(NSError * _Nullable * _Nullable)error;

/// Saves the current public key into macOS Keychain.
///
/// @param serviceName Keychain service identifier
/// @param accountName Keychain account identifier
/// @param error Output error pointer
/// @return YES on success, NO on failure
- (BOOL)saveCurrentPublicKeyToKeychainWithService:(NSString *)serviceName
                                          account:(NSString *)accountName
                                            error:(NSError * _Nullable * _Nullable)error;

/// Calculates the SHA-256 fingerprint for a given SecKeyRef.
+ (nullable NSString *)fingerprintForKey:(SecKeyRef)key;

/// Converts a DER-encoded public key to PEM string.
+ (NSString *)pemStringFromDER:(NSData *)derData isPKCS1:(BOOL)isPKCS1;

@end

NS_ASSUME_NONNULL_END
