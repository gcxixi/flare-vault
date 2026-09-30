//
//  FVCloudflareUploader.h
//  FlareVault
//
//  Uploads archives to Cloudflare R2 using AWS Signature Version 4 (SigV4).
//  Supports Standard Fast Upload and Lazy/Stochastic Jitter Upload (惰性随机上传模式).
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

// Lazy / Stochastic Jitter Upload Settings (惰性随机调用模式)
@property (nonatomic, assign) BOOL lazyUploadEnabled;
@property (nonatomic, assign) NSTimeInterval lazyMinIntervalSeconds; // default: 2.0s
@property (nonatomic, assign) NSTimeInterval lazyMaxIntervalSeconds; // default: 8.0s
@property (nonatomic, assign) BOOL lazyChunkJitter;                  // default: YES (5MB-8MB variable chunk sizes)
@property (nonatomic, assign) double lazyBurstProbability;           // default: 0.20 (20% chance of double call burst)
@end

typedef void (^FVUploadProgressBlock)(double progress, int64_t bytesSent, int64_t totalBytes);
typedef void (^FVUploadStatusLogBlock)(NSString *logMessage);
typedef void (^FVUploadCompletionBlock)(BOOL success, NSString * _Nullable remoteUrl, NSError * _Nullable error);

@interface FVCloudflareUploader : NSObject

@property (nonatomic, strong, readonly) FVCloudflareConfig *config;
@property (nonatomic, copy, nullable) FVUploadStatusLogBlock statusLogBlock;

- (instancetype)initWithConfig:(FVCloudflareConfig *)config;

/// Uploads a file at localFilePath to Cloudflare R2 with object key remoteObjectKey.
/// Supports both standard streaming PUT and lazy randomized multipart upload.
///
/// @param localFilePath Path to the .flarevault file on local disk
/// @param remoteObjectKey S3 object key (e.g. "backups/2026-09-30_archive.flarevault")
/// @param progress Progress callback
/// @param completion Completion callback
- (void)uploadFileAtPath:(NSString *)localFilePath
         remoteObjectKey:(NSString *)remoteObjectKey
                progress:(nullable FVUploadProgressBlock)progress
              completion:(FVUploadCompletionBlock)completion;

/// Cancels an in-progress upload (and aborts multipart upload if active).
- (void)cancel;

/// Tests connectivity to Cloudflare R2 bucket.
- (void)testConnectionWithCompletion:(void (^)(BOOL reachable, NSString * _Nullable message, NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
