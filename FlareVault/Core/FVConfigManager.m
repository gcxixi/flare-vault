//
//  FVConfigManager.m
//  FlareVault
//

#import "FVConfigManager.h"
#import "FVArchiver.h"
#import <Security/Security.h>

static NSString * const kFVPrefDirectoryConfigs = @"FVDirectoryConfigs";
static NSString * const kFVPrefLastDir = @"FVLastDirectoryPath";
static NSString * const kFVPrefLastPubKey = @"FVLastPublicKeyPEM";
static NSString * const kFVPrefAccountId = @"FVCloudflareAccountId";
static NSString * const kFVPrefBucket = @"FVCloudflareBucketName";
static NSString * const kFVPrefPrefix = @"FVCloudflareRemotePrefix";
static NSString * const kFVPrefCustomEndpoint = @"FVCloudflareCustomEndpoint";
static NSString * const kFVPrefRememberKeychain = @"FVRememberCredentialsInKeychain";

static NSString * const kFVPrefLazyUploadEnabled = @"FVLazyUploadEnabled";
static NSString * const kFVPrefLazyMinInterval = @"FVLazyMinInterval";
static NSString * const kFVPrefLazyMaxInterval = @"FVLazyMaxInterval";
static NSString * const kFVPrefLazyChunkJitter = @"FVLazyChunkJitter";

static NSString * const kFVPrefUseDefaultExcludes = @"FVUseDefaultExcludes";
static NSString * const kFVPrefCustomExcludeString = @"FVCustomExcludeString";
static NSString * const kFVPrefIncrementalBackupEnabled = @"FVIncrementalBackupEnabled";

static NSString * const kFVKeychainService = @"com.flarevault.r2credentials";

@implementation FVDirectoryConfig

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (instancetype)initWithPath:(NSString *)path enabled:(BOOL)enabled {
    self = [super init];
    if (self) {
        _path = [path copy];
        _enabled = enabled;
    }
    return self;
}

- (NSString *)displayName {
    return [_path lastPathComponent] ?: _path;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.path forKey:@"path"];
    [coder encodeBool:self.enabled forKey:@"enabled"];
}

- (nullable instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) {
        _path = [coder decodeObjectOfClass:[NSString class] forKey:@"path"];
        _enabled = [coder decodeBoolForKey:@"enabled"];
    }
    return self;
}

- (NSDictionary *)toDictionary {
    return @{
        @"path": self.path ?: @"",
        @"enabled": @(self.enabled)
    };
}

+ (instancetype)fromDictionary:(NSDictionary *)dict {
    NSString *p = dict[@"path"] ?: @"";
    BOOL en = dict[@"enabled"] ? [dict[@"enabled"] boolValue] : YES;
    return [[FVDirectoryConfig alloc] initWithPath:p enabled:en];
}

@end

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
        _directoryConfigs = @[];
        _cloudflareRemotePrefix = @"backups/";
        _rememberCredentialsInKeychain = YES;
        _lazyUploadEnabled = NO;
        _lazyMinIntervalSeconds = 2.0;
        _lazyMaxIntervalSeconds = 8.0;
        _lazyChunkJitter = YES;
        _useDefaultExcludes = YES;
        _customExcludeString = @"";
        _incrementalBackupEnabled = YES;
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

    // Load multi-directory configs
    NSArray *savedDirs = [defaults arrayForKey:kFVPrefDirectoryConfigs];
    NSMutableArray<FVDirectoryConfig *> *dirs = [NSMutableArray array];
    if ([savedDirs isKindOfClass:[NSArray class]] && savedDirs.count > 0) {
        for (id item in savedDirs) {
            if ([item isKindOfClass:[NSDictionary class]]) {
                [dirs addObject:[FVDirectoryConfig fromDictionary:item]];
            } else if ([item isKindOfClass:[NSString class]]) {
                [dirs addObject:[[FVDirectoryConfig alloc] initWithPath:item enabled:YES]];
            }
        }
    } else if (_lastDirectoryPath.length > 0) {
        [dirs addObject:[[FVDirectoryConfig alloc] initWithPath:_lastDirectoryPath enabled:YES]];
    }
    _directoryConfigs = [dirs copy];

    if ([defaults objectForKey:kFVPrefRememberKeychain]) {
        _rememberCredentialsInKeychain = [defaults boolForKey:kFVPrefRememberKeychain];
    }
    if ([defaults objectForKey:kFVPrefLazyUploadEnabled]) {
        _lazyUploadEnabled = [defaults boolForKey:kFVPrefLazyUploadEnabled];
    }
    if ([defaults objectForKey:kFVPrefLazyMinInterval]) {
        _lazyMinIntervalSeconds = [defaults doubleForKey:kFVPrefLazyMinInterval];
    }
    if ([defaults objectForKey:kFVPrefLazyMaxInterval]) {
        _lazyMaxIntervalSeconds = [defaults doubleForKey:kFVPrefLazyMaxInterval];
    }
    if ([defaults objectForKey:kFVPrefLazyChunkJitter]) {
        _lazyChunkJitter = [defaults boolForKey:kFVPrefLazyChunkJitter];
    }
    if ([defaults objectForKey:kFVPrefUseDefaultExcludes]) {
        _useDefaultExcludes = [defaults boolForKey:kFVPrefUseDefaultExcludes];
    }
    _customExcludeString = [defaults stringForKey:kFVPrefCustomExcludeString] ?: @"";

    if ([defaults objectForKey:kFVPrefIncrementalBackupEnabled]) {
        _incrementalBackupEnabled = [defaults boolForKey:kFVPrefIncrementalBackupEnabled];
    } else {
        _incrementalBackupEnabled = YES;
    }

    if (_rememberCredentialsInKeychain) {
        [self loadSecretsFromKeychain];
    }
}

- (void)saveSettings {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    
    NSMutableArray *dicts = [NSMutableArray arrayWithCapacity:_directoryConfigs.count];
    for (FVDirectoryConfig *cfg in _directoryConfigs) {
        [dicts addObject:[cfg toDictionary]];
    }
    [defaults setObject:dicts forKey:kFVPrefDirectoryConfigs];

    if (_directoryConfigs.count > 0) {
        _lastDirectoryPath = _directoryConfigs.firstObject.path;
        [defaults setObject:_lastDirectoryPath forKey:kFVPrefLastDir];
    } else {
        _lastDirectoryPath = nil;
        [defaults removeObjectForKey:kFVPrefLastDir];
    }

    if (_lastPublicKeyPEM) [defaults setObject:_lastPublicKeyPEM forKey:kFVPrefLastPubKey];
    if (_cloudflareAccountId) [defaults setObject:_cloudflareAccountId forKey:kFVPrefAccountId];
    if (_cloudflareBucketName) [defaults setObject:_cloudflareBucketName forKey:kFVPrefBucket];
    if (_cloudflareRemotePrefix) [defaults setObject:_cloudflareRemotePrefix forKey:kFVPrefPrefix];
    if (_cloudflareCustomEndpoint) [defaults setObject:_cloudflareCustomEndpoint forKey:kFVPrefCustomEndpoint];
    [defaults setBool:_rememberCredentialsInKeychain forKey:kFVPrefRememberKeychain];
    [defaults setBool:_lazyUploadEnabled forKey:kFVPrefLazyUploadEnabled];
    [defaults setDouble:_lazyMinIntervalSeconds forKey:kFVPrefLazyMinInterval];
    [defaults setDouble:_lazyMaxIntervalSeconds forKey:kFVPrefLazyMaxInterval];
    [defaults setBool:_lazyChunkJitter forKey:kFVPrefLazyChunkJitter];
    [defaults setBool:_useDefaultExcludes forKey:kFVPrefUseDefaultExcludes];
    if (_customExcludeString) [defaults setObject:_customExcludeString forKey:kFVPrefCustomExcludeString];
    [defaults setBool:_incrementalBackupEnabled forKey:kFVPrefIncrementalBackupEnabled];
    [defaults synchronize];

    if (_rememberCredentialsInKeychain) {
        [self saveSecretsToKeychain];
    }
}

- (void)addDirectoryPath:(NSString *)path {
    if (!path || path.length == 0) return;
    NSString *stdPath = [path stringByStandardizingPath];
    for (FVDirectoryConfig *cfg in self.directoryConfigs) {
        if ([[cfg.path stringByStandardizingPath] isEqualToString:stdPath]) {
            return;
        }
    }
    NSMutableArray *arr = [self.directoryConfigs mutableCopy];
    [arr addObject:[[FVDirectoryConfig alloc] initWithPath:stdPath enabled:YES]];
    self.directoryConfigs = [arr copy];
    [self saveSettings];
}

- (void)removeDirectoryPath:(NSString *)path {
    if (!path) return;
    NSString *stdPath = [path stringByStandardizingPath];
    NSMutableArray *arr = [NSMutableArray array];
    for (FVDirectoryConfig *cfg in self.directoryConfigs) {
        if (![[cfg.path stringByStandardizingPath] isEqualToString:stdPath]) {
            [arr addObject:cfg];
        }
    }
    self.directoryConfigs = [arr copy];
    [self saveSettings];
}

- (void)setDirectoryPath:(NSString *)path enabled:(BOOL)enabled {
    if (!path) return;
    NSString *stdPath = [path stringByStandardizingPath];
    NSMutableArray *arr = [NSMutableArray array];
    for (FVDirectoryConfig *cfg in self.directoryConfigs) {
        if ([[cfg.path stringByStandardizingPath] isEqualToString:stdPath]) {
            [arr addObject:[[FVDirectoryConfig alloc] initWithPath:cfg.path enabled:enabled]];
        } else {
            [arr addObject:cfg];
        }
    }
    self.directoryConfigs = [arr copy];
    [self saveSettings];
}

- (void)clearDirectories {
    self.directoryConfigs = @[];
    [self saveSettings];
}

- (NSArray<NSString *> *)enabledDirectoryPaths {
    NSMutableArray<NSString *> *res = [NSMutableArray array];
    for (FVDirectoryConfig *cfg in self.directoryConfigs) {
        if (cfg.enabled && cfg.path.length > 0) {
            [res addObject:cfg.path];
        }
    }
    return [res copy];
}

- (NSArray<NSString *> *)effectiveExcludePatterns {
    NSMutableArray<NSString *> *patterns = [NSMutableArray array];
    if (self.useDefaultExcludes) {
        [patterns addObjectsFromArray:[FVArchiver defaultExcludePatterns]];
    }
    if (self.customExcludeString.length > 0) {
        NSArray *components = [self.customExcludeString componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@", "]];
        for (NSString *item in components) {
            NSString *trimmed = [item stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (trimmed.length > 0) {
                [patterns addObject:trimmed];
            }
        }
    }
    return [patterns copy];
}

- (FVCloudflareConfig *)cloudflareConfig {
    FVCloudflareConfig *cfg = [[FVCloudflareConfig alloc] init];
    cfg.accountId = self.cloudflareAccountId ?: @"";
    cfg.bucketName = self.cloudflareBucketName ?: @"";
    cfg.remotePrefix = self.cloudflareRemotePrefix ?: @"backups/";
    cfg.customEndpoint = self.cloudflareCustomEndpoint;
    cfg.accessKeyId = self.cloudflareAccessKeyId ?: @"";
    cfg.secretAccessKey = self.cloudflareSecretAccessKey ?: @"";
    cfg.lazyUploadEnabled = self.lazyUploadEnabled;
    cfg.lazyMinIntervalSeconds = self.lazyMinIntervalSeconds;
    cfg.lazyMaxIntervalSeconds = self.lazyMaxIntervalSeconds;
    cfg.lazyChunkJitter = self.lazyChunkJitter;
    return cfg;
}

- (void)saveSecretsToKeychain {
    if (self.cloudflareAccessKeyId.length == 0 && self.cloudflareSecretAccessKey.length == 0) return;

    NSDictionary *creds = @{
        @"accessKeyId": self.cloudflareAccessKeyId ?: @"",
        @"secretAccessKey": self.cloudflareSecretAccessKey ?: @""
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:creds options:0 error:nil];
    if (!data) return;

    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kFVKeychainService,
        (__bridge id)kSecAttrAccount: @"cloudflare_r2",
    };
    SecItemDelete((__bridge CFDictionaryRef)query);

    NSMutableDictionary *addQuery = [query mutableCopy];
    addQuery[(__bridge id)kSecValueData] = data;
    SecItemAdd((__bridge CFDictionaryRef)addQuery, NULL);
}

- (void)loadSecretsFromKeychain {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kFVKeychainService,
        (__bridge id)kSecAttrAccount: @"cloudflare_r2",
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne
    };
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status == errSecSuccess && result) {
        NSData *data = (__bridge_transfer NSData *)result;
        NSDictionary *creds = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([creds isKindOfClass:[NSDictionary class]]) {
            _cloudflareAccessKeyId = creds[@"accessKeyId"];
            _cloudflareSecretAccessKey = creds[@"secretAccessKey"];
        }
    }
}

@end
