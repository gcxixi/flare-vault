//
//  FVConfigManager.h
//  FlareVault
//
//  Persistent configuration and Keychain secret storage.
//

#import <Foundation/Foundation.h>
#import "FVCloudflareUploader.h"

NS_ASSUME_NONNULL_BEGIN

@interface FVConfigManager : NSObject

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

+ (instancetype)sharedManager;

- (void)loadSettings;
- (void)saveSettings;

- (FVCloudflareConfig *)cloudflareConfig;

@end

NS_ASSUME_NONNULL_END
