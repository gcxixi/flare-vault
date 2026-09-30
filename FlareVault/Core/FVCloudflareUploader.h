//
//  FVCloudflareUploader.h
//  FlareVault
//
//  Uploads archives to Cloudflare R2 using AWS Signature Version 4 (SigV4).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const FVCloudflareErrorDomain;

@interface FVCloudflareConfig : NSObject <NSCopying>
@property (nonatomic, copy) NSString *accountId;
@property (nonatomic, copy) NSString *bucketName;
@property (nonatomic, copy) NSString *accessKeyId;
@property (nonatomic, copy) NSString *secretAccessKey;
@property (nonatomic, copy) NSString *remotePrefix; // e.g. "backups/"
@property (nonatomic, copy, nullable) NSString *customEndpoint; // Optional custom endpoint
@end

typedef void (^FVUploadProgressBlock)(double progress, int64_t bytesSent, int64_t totalBytes);
typedef void (^FVUploadCompletionBlock)(BOOL success, NSString * _Nullable remoteUrl, NSError * _Nullable error);

@interface FVCloudflareUploader : NSObject

@property (nonatomic, strong, readonly) FVCloudflareConfig *config;

- (instancetype)initWithConfig:(FVCloudflareConfig *)config;

/// Uploads a file at localFilePath to Cloudflare R2 with object key remoteObjectKey.
///
/// @param localFilePath Path to the .flarevault file on local disk
/// @param remoteObjectKey S3 object key (e.g. "backups/2026-09-30_archive.flarevault")
/// @param progress Progress callback
/// @param completion Completion callback
- (void)uploadFileAtPath:(NSString *)localFilePath
         remoteObjectKey:(NSString *)remoteObjectKey
                progress:(nullable FVUploadProgressBlock)progress
              completion:(FVUploadCompletionBlock)completion;

/// Cancels an in-progress upload.
- (void)cancel;

/// Tests connectivity to Cloudflare R2 bucket (performs a HEAD/GET bucket or dry run).
- (void)testConnectionWithCompletion:(void (^)(BOOL reachable, NSString * _Nullable message, NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
