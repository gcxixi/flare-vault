//
//  FVKeyManager.m
//  FlareVault
//

#import "FVKeyManager.h"
#import <CommonCrypto/CommonDigest.h>

NSString * const FVKeyManagerErrorDomain = @"com.flarevault.keymanager";

@interface FVKeyManager ()
@property (nonatomic, assign, nullable) SecKeyRef currentPublicKey;
@property (nonatomic, copy, nullable) NSString *currentPublicKeyPEM;
@property (nonatomic, copy, nullable) NSString *currentKeyFingerprint;
@property (nonatomic, copy, nullable) NSString *currentKeySummary;
@end

@implementation FVKeyManager

+ (instancetype)sharedManager {
    static FVKeyManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[FVKeyManager alloc] init];
    });
    return instance;
}

- (void)dealloc {
    [self clearKey];
#if !__has_feature(objc_arc)
    [super dealloc];
#endif
}

- (void)clearKey {
    if (_currentPublicKey) {
        CFRelease(_currentPublicKey);
        _currentPublicKey = NULL;
    }
    _currentPublicKeyPEM = nil;
    _currentKeyFingerprint = nil;
    _currentKeySummary = nil;
}

- (BOOL)loadPublicKeyFromPEM:(NSString *)pemString error:(NSError * _Nullable * _Nullable)error {
    if (!pemString || pemString.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:FVKeyManagerErrorDomain
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: @"PEM string is empty."}];
        }
        return NO;
    }

    NSString *cleanPEM = pemString;
    BOOL isPKCS1 = NO;
    if ([cleanPEM containsString:@"BEGIN RSA PUBLIC KEY"]) {
        isPKCS1 = YES;
    }

    // Strip header, footer, whitespace and newlines
    NSArray *lines = [cleanPEM componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSMutableString *base64 = [NSMutableString string];
    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([trimmed hasPrefix:@"-----"]) continue;
        [base64 appendString:trimmed];
    }

    NSData *derData = [[NSData alloc] initWithBase64EncodedString:base64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (!derData || derData.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:FVKeyManagerErrorDomain
                                         code:-2
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to decode Base64 data from PEM."}];
        }
        return NO;
    }

    NSDictionary *attrs = @{
        (id)kSecAttrKeyType: (id)kSecAttrKeyTypeRSA,
        (id)kSecAttrKeyClass: (id)kSecAttrKeyClassPublic,
    };
    CFErrorRef cfError = NULL;
    SecKeyRef pubKey = SecKeyCreateWithData((__bridge CFDataRef)derData, (__bridge CFDictionaryRef)attrs, &cfError);
    if (!pubKey) {
        if (error) {
            *error = [NSError errorWithDomain:FVKeyManagerErrorDomain
                                         code:-3
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"SecKeyCreateWithData failed: %@", cfError]}];
        }
        if (cfError) CFRelease(cfError);
        return NO;
    }

    // Verify key can encrypt
    if (!SecKeyIsAlgorithmSupported(pubKey, kSecKeyOperationTypeEncrypt, kSecKeyAlgorithmRSAEncryptionOAEPSHA256)) {
        CFRelease(pubKey);
        if (error) {
            *error = [NSError errorWithDomain:FVKeyManagerErrorDomain
                                         code:-4
                                     userInfo:@{NSLocalizedDescriptionKey: @"Loaded key does not support RSA-OAEP-SHA256 encryption."}];
        }
        return NO;
    }

    [self clearKey];
    _currentPublicKey = pubKey;
    _currentPublicKeyPEM = [FVKeyManager pemStringFromDER:derData isPKCS1:isPKCS1];
    _currentKeyFingerprint = [FVKeyManager fingerprintForKey:pubKey];

    NSDictionary *keyAttrs = CFBridgingRelease(SecKeyCopyAttributes(pubKey));
    NSNumber *blockSize = keyAttrs[(id)kSecAttrKeySizeInBits];
    _currentKeySummary = [NSString stringWithFormat:@"RSA %@-bit (Public Only, Cannot Decrypt)", blockSize ?: @(2048)];

    return YES;
}

- (BOOL)loadPublicKeyFromFile:(NSString *)filePath error:(NSError * _Nullable * _Nullable)error {
    NSString *pem = [NSString stringWithContentsOfFile:filePath encoding:NSUTF8StringEncoding error:error];
    if (!pem) return NO;
    return [self loadPublicKeyFromPEM:pem error:error];
}

- (BOOL)generateKeypairWithBits:(int)keyBits
               passwordProtect:(nullable NSString *)password
             outPrivateKeyPEM:(NSString * _Nullable * _Nullable)outPrivateKeyPEM
                        error:(NSError * _Nullable * _Nullable)error
{
    // Generate RSA key pair using /usr/bin/openssl to ensure standard PEM format with optional password protection
    NSString *tempDir = NSTemporaryDirectory();
    NSString *privKeyPath = [tempDir stringByAppendingPathComponent:[NSString stringWithFormat:@"fv_priv_%u.pem", arc4random()]];
    NSString *pubKeyPath = [tempDir stringByAppendingPathComponent:[NSString stringWithFormat:@"fv_pub_%u.pem", arc4random()]];

    NSMutableArray<NSString *> *genArgs = [NSMutableArray arrayWithObjects:@"genrsa", nil];
    if (password && password.length > 0) {
        [genArgs addObjectsFromArray:@[@"-aes256", @"-passout", [NSString stringWithFormat:@"pass:%@", password]]];
    }
    [genArgs addObjectsFromArray:@[@"-out", privKeyPath, [NSString stringWithFormat:@"%d", keyBits]]];

    NSTask *genTask = [[NSTask alloc] init];
    genTask.executableURL = [NSURL fileURLWithPath:@"/usr/bin/openssl"];
    genTask.arguments = genArgs;
    NSPipe *errPipe1 = [NSPipe pipe];
    genTask.standardError = errPipe1;

    @try {
        [genTask launch];
        [genTask waitUntilExit];
    } @catch (NSException *ex) {
        if (error) {
            *error = [NSError errorWithDomain:FVKeyManagerErrorDomain
                                         code:-10
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to execute openssl: %@", ex.reason]}];
        }
        return NO;
    }

    if (genTask.terminationStatus != 0) {
        NSData *errData = [[errPipe1 fileHandleForReading] readDataToEndOfFile];
        NSString *errMsg = [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding];
        if (error) {
            *error = [NSError errorWithDomain:FVKeyManagerErrorDomain
                                         code:-11
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"openssl genrsa failed: %@", errMsg]}];
        }
        return NO;
    }

    // Extract public key
    NSMutableArray<NSString *> *pubArgs = [NSMutableArray arrayWithObjects:@"rsa", @"-in", privKeyPath, @"-pubout", @"-out", pubKeyPath, nil];
    if (password && password.length > 0) {
        [pubArgs addObjectsFromArray:@[@"-passin", [NSString stringWithFormat:@"pass:%@", password]]];
    }

    NSTask *pubTask = [[NSTask alloc] init];
    pubTask.executableURL = [NSURL fileURLWithPath:@"/usr/bin/openssl"];
    pubTask.arguments = pubArgs;
    NSPipe *errPipe2 = [NSPipe pipe];
    pubTask.standardError = errPipe2;

    @try {
        [pubTask launch];
        [pubTask waitUntilExit];
    } @catch (NSException *ex) {
        [[NSFileManager defaultManager] removeItemAtPath:privKeyPath error:nil];
        if (error) {
            *error = [NSError errorWithDomain:FVKeyManagerErrorDomain code:-12 userInfo:@{NSLocalizedDescriptionKey: ex.reason}];
        }
        return NO;
    }

    if (pubTask.terminationStatus != 0) {
        [[NSFileManager defaultManager] removeItemAtPath:privKeyPath error:nil];
        if (error) {
            *error = [NSError errorWithDomain:FVKeyManagerErrorDomain code:-13 userInfo:@{NSLocalizedDescriptionKey: @"Failed to extract public key."}];
        }
        return NO;
    }

    NSString *privPEM = [NSString stringWithContentsOfFile:privKeyPath encoding:NSUTF8StringEncoding error:nil];
    NSString *pubPEM = [NSString stringWithContentsOfFile:pubKeyPath encoding:NSUTF8StringEncoding error:nil];

    // Remove temporary files immediately
    [[NSFileManager defaultManager] removeItemAtPath:privKeyPath error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:pubKeyPath error:nil];

    if (outPrivateKeyPEM) {
        *outPrivateKeyPEM = privPEM;
    }

    // Load only the public key into this manager
    return [self loadPublicKeyFromPEM:pubPEM error:error];
}

- (BOOL)loadPublicKeyFromKeychainWithService:(NSString *)serviceName
                                     account:(nullable NSString *)accountName
                                       error:(NSError * _Nullable * _Nullable)error
{
    NSMutableDictionary *query = [NSMutableDictionary dictionaryWithDictionary:@{
        (id)kSecClass: (id)kSecClassGenericPassword,
        (id)kSecAttrService: serviceName ?: @"com.flarevault.publickey",
        (id)kSecReturnData: (id)kCFBooleanTrue,
        (id)kSecMatchLimit: (id)kSecMatchLimitOne
    }];
    if (accountName && accountName.length > 0) {
        query[(id)kSecAttrAccount] = accountName;
    }

    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status != errSecSuccess) {
        if (error) {
            *error = [NSError errorWithDomain:FVKeyManagerErrorDomain
                                         code:status
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Keychain lookup failed (status: %d)", (int)status]}];
        }
        return NO;
    }

    NSData *keyData = CFBridgingRelease(result);
    NSString *pemStr = [[NSString alloc] initWithData:keyData encoding:NSUTF8StringEncoding];
    return [self loadPublicKeyFromPEM:pemStr error:error];
}

- (BOOL)saveCurrentPublicKeyToKeychainWithService:(NSString *)serviceName
                                          account:(NSString *)accountName
                                            error:(NSError * _Nullable * _Nullable)error
{
    if (!_currentPublicKeyPEM) {
        if (error) {
            *error = [NSError errorWithDomain:FVKeyManagerErrorDomain
                                         code:-20
                                     userInfo:@{NSLocalizedDescriptionKey: @"No public key currently loaded to save."}];
        }
        return NO;
    }

    NSData *pemData = [_currentPublicKeyPEM dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *searchQuery = @{
        (id)kSecClass: (id)kSecClassGenericPassword,
        (id)kSecAttrService: serviceName ?: @"com.flarevault.publickey",
        (id)kSecAttrAccount: accountName ?: @"default"
    };

    NSDictionary *updateAttrs = @{
        (id)kSecValueData: pemData
    };

    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)searchQuery, (__bridge CFDictionaryRef)updateAttrs);
    if (status == errSecItemNotFound) {
        NSMutableDictionary *newQuery = [searchQuery mutableCopy];
        [newQuery addEntriesFromDictionary:updateAttrs];
        status = SecItemAdd((__bridge CFDictionaryRef)newQuery, NULL);
    }

    if (status != errSecSuccess) {
        if (error) {
            *error = [NSError errorWithDomain:FVKeyManagerErrorDomain
                                         code:status
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to save key to Keychain (status: %d)", (int)status]}];
        }
        return NO;
    }

    return YES;
}

+ (nullable NSString *)fingerprintForKey:(SecKeyRef)key {
    if (!key) return nil;
    CFErrorRef err = NULL;
    CFDataRef derData = SecKeyCopyExternalRepresentation(key, &err);
    if (!derData) {
        if (err) CFRelease(err);
        return nil;
    }

    uint8_t hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(CFDataGetBytePtr(derData), (CC_LONG)CFDataGetLength(derData), hash);
    CFRelease(derData);

    NSMutableString *hex = [NSMutableString stringWithCapacity:sizeof(hash) * 2];
    for (size_t i = 0; i < sizeof(hash); i++) {
        [hex appendFormat:@"%02X", hash[i]];
    }
    return [NSString stringWithFormat:@"SHA256:%@", hex];
}

+ (NSString *)pemStringFromDER:(NSData *)derData isPKCS1:(BOOL)isPKCS1 {
    NSString *base64 = [derData base64EncodedStringWithOptions:NSDataBase64Encoding64CharacterLineLength];
    NSString *header = isPKCS1 ? @"-----BEGIN RSA PUBLIC KEY-----" : @"-----BEGIN PUBLIC KEY-----";
    NSString *footer = isPKCS1 ? @"-----END RSA PUBLIC KEY-----" : @"-----END PUBLIC KEY-----";
    return [NSString stringWithFormat:@"%@\n%@\n%@\n", header, base64, footer];
}

@end
