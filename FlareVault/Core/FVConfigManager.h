//
//  FVConfigManager.h
//  FlareVault
//
//  Persistent configuration and Keychain secret storage.
//  Supports multiple configured directories.
//

#import <Foundation/Foundation.h>
#import "FVCloudflareUploader.h"

NS_ASSUME_NONNULL_BEGIN

@interface FVDirectoryConfig : NSObject <NSSecureCoding>
@property (nonatomic, copy) NSString *path;
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, copy, readonly) NSString *displayName;

- (instancetype)initWithPath:(NSString *)path enabled:(BOOL)enabled;
- (NSDictionary *)toDictionary;
+ (instancetype)fromDictionary:(NSDictionary *)dict;
@end

@interface FVConfigManager : NSObject

/// Configured backup directories
@property (nonatomic, copy) NSArray<FVDirectoryConfig *> *directoryConfigs;

/// Legacy single directory accessor for backwards compatibility
@property (nonatomic, copy, nullable) NSString *lastDirectoryPath;

@property (nonatomic, copy, nullable) NSString *lastPublicKeyPEM;
@property (nonatomic, copy, nullable) NSString *cloudflareAccountId;
@property (nonatomic, copy, nullable) NSString *cloudflareBucketName;
@property (nonatomic, copy, nullable) NSString *cloudflareRemotePrefix;
@property (nonatomic, copy, nullable) NSString *cloudflareCustomEndpoint;
@property (nonatomic, copy, nullable) NSString *cloudflareAccessKeyId;
@property (nonatomic, copy, nullable) NSString *cloudflareSecretAccessKey;
@property (nonatomic, assign) BOOL rememberCredentialsInKeychain;

// Lazy Upload Settings
@property (nonatomic, assign) BOOL lazyUploadEnabled;
@property (nonatomic, assign) NSTimeInterval lazyMinIntervalSeconds;
@property (nonatomic, assign) NSTimeInterval lazyMaxIntervalSeconds;
@property (nonatomic, assign) BOOL lazyChunkJitter;

// Exclude Settings (rsync style)
@property (nonatomic, assign) BOOL useDefaultExcludes;
@property (nonatomic, copy, nullable) NSString *customExcludeString;

// Incremental Backup Settings
@property (nonatomic, assign) BOOL incrementalBackupEnabled;

/// Returns the effective array of exclude patterns combining default and custom.
- (NSArray<NSString *> *)effectiveExcludePatterns;

/// Multi-directory helper methods
- (void)addDirectoryPath:(NSString *)path;
- (void)removeDirectoryPath:(NSString *)path;
- (void)setDirectoryPath:(NSString *)path enabled:(BOOL)enabled;
- (void)clearDirectories;
- (NSArray<NSString *> *)enabledDirectoryPaths;

+ (instancetype)sharedManager;

- (void)loadSettings;
- (void)saveSettings;

- (FVCloudflareConfig *)cloudflareConfig;

@end

NS_ASSUME_NONNULL_END
