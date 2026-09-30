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

+ (instancetype)sharedManager;

- (void)loadSettings;
- (void)saveSettings;

- (FVCloudflareConfig *)cloudflareConfig;

@end

NS_ASSUME_NONNULL_END
