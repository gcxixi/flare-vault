//
//  FVConfigManager.m
//  FlareVault
//

#import "FVConfigManager.h"
#import <Security/Security.h>

static NSString * const kFVPrefLastDir = @"FVLastDirectoryPath";
static NSString * const kFVPrefLastPubKey = @"FVLastPublicKeyPEM";
static NSString * const kFVPrefAccountId = @"FVCloudflareAccountId";
static NSString * const kFVPrefBucket = @"FVCloudflareBucketName";
static NSString * const kFVPrefPrefix = @"FVCloudflareRemotePrefix";
static NSString * const kFVPrefCustomEndpoint = @"FVCloudflareCustomEndpoint";
static NSString * const kFVPrefRememberKeychain = @"FVRememberCredentialsInKeychain";

static NSString * const kFVKeychainService = @"com.flarevault.r2credentials";

@implementation FVConfigManager

+ (instancetype)sharedManager {
    static FVConfigManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[FVConfigManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _cloudflareRemotePrefix = @"backups/";
        _rememberCredentialsInKeychain = YES;
        [self loadSettings];
    }
    return self;
}

- (void)loadSettings {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    _lastDirectoryPath = [defaults stringForKey:kFVPrefLastDir];
    _lastPublicKeyPEM = [defaults stringForKey:kFVPrefLastPubKey];
    _cloudflareAccountId = [defaults stringForKey:kFVPrefAccountId];
    _cloudflareBucketName = [defaults stringForKey:kFVPrefBucket];
    _cloudflareRemotePrefix = [defaults stringForKey:kFVPrefPrefix] ?: @"backups/";
    _cloudflareCustomEndpoint = [defaults stringForKey:kFVPrefCustomEndpoint];

    if ([defaults objectForKey:kFVPrefRememberKeychain]) {
        _rememberCredentialsInKeychain = [defaults boolForKey:kFVPrefRememberKeychain];
    }

    if (_rememberCredentialsInKeychain) {
        [self loadSecretsFromKeychain];
    }
}

- (void)saveSettings {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (_lastDirectoryPath) [defaults setObject:_lastDirectoryPath forKey:kFVPrefLastDir];
    if (_lastPublicKeyPEM) [defaults setObject:_lastPublicKeyPEM forKey:kFVPrefLastPubKey];
    if (_cloudflareAccountId) [defaults setObject:_cloudflareAccountId forKey:kFVPrefAccountId];
    if (_cloudflareBucketName) [defaults setObject:_cloudflareBucketName forKey:kFVPrefBucket];
    if (_cloudflareRemotePrefix) [defaults setObject:_cloudflareRemotePrefix forKey:kFVPrefPrefix];
    if (_cloudflareCustomEndpoint) [defaults setObject:_cloudflareCustomEndpoint forKey:kFVPrefCustomEndpoint];
    [defaults setBool:_rememberCredentialsInKeychain forKey:kFVPrefRememberKeychain];
    [defaults synchronize];

    if (_rememberCredentialsInKeychain) {
        [self saveSecretsToKeychain];
    }
}

- (void)loadSecretsFromKeychain {
    NSDictionary *query = @{
        (id)kSecClass: (id)kSecClassGenericPassword,
        (id)kSecAttrService: kFVKeychainService,
        (id)kSecReturnData: (id)kCFBooleanTrue,
        (id)kSecMatchLimit: (id)kSecMatchLimitOne
    };

    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status == errSecSuccess && result) {
        NSData *data = CFBridgingRelease(result);
        NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([dict isKindOfClass:[NSDictionary class]]) {
            _cloudflareAccessKeyId = dict[@"accessKeyId"];
            _cloudflareSecretAccessKey = dict[@"secretAccessKey"];
        }
    }
}

- (void)saveSecretsToKeychain {
    if (!_cloudflareAccessKeyId && !_cloudflareSecretAccessKey) return;

    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    if (_cloudflareAccessKeyId) dict[@"accessKeyId"] = _cloudflareAccessKeyId;
    if (_cloudflareSecretAccessKey) dict[@"secretAccessKey"] = _cloudflareSecretAccessKey;

    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
    if (!data) return;

    NSDictionary *searchQuery = @{
        (id)kSecClass: (id)kSecClassGenericPassword,
        (id)kSecAttrService: kFVKeychainService
    };

    NSDictionary *updateAttrs = @{
        (id)kSecValueData: data
    };

    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)searchQuery, (__bridge CFDictionaryRef)updateAttrs);
    if (status == errSecItemNotFound) {
        NSMutableDictionary *newQuery = [searchQuery mutableCopy];
        [newQuery addEntriesFromDictionary:updateAttrs];
        SecItemAdd((__bridge CFDictionaryRef)newQuery, NULL);
    }
}

- (FVCloudflareConfig *)cloudflareConfig {
    FVCloudflareConfig *cfg = [[FVCloudflareConfig alloc] init];
    cfg.accountId = self.cloudflareAccountId ?: @"";
    cfg.bucketName = self.cloudflareBucketName ?: @"";
    cfg.accessKeyId = self.cloudflareAccessKeyId ?: @"";
    cfg.secretAccessKey = self.cloudflareSecretAccessKey ?: @"";
    cfg.remotePrefix = self.cloudflareRemotePrefix ?: @"backups/";
    cfg.customEndpoint = self.cloudflareCustomEndpoint;
    return cfg;
}

@end
