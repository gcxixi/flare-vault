//
//  FVTaskPipeline.h
//  FlareVault
//
//  End-to-End Orchestrator: Packaging -> Asymmetric Encryption -> Cloudflare Upload
//

#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import "FVCloudflareUploader.h"

NS_ASSUME_NONNULL_BEGIN

typedef void (^FVTaskLogBlock)(NSString *message, BOOL isError);
typedef void (^FVTaskProgressBlock)(NSString *stage, double progress, NSString *statusText);
typedef void (^FVTaskCompletionBlock)(BOOL success, NSString * _Nullable remoteUrl, NSError * _Nullable error);

@interface FVTaskPipeline : NSObject

@property (nonatomic, copy) NSString *sourceDirectoryPath;
@property (nonatomic, assign) SecKeyRef publicKey;
@property (nonatomic, strong) FVCloudflareConfig *cloudflareConfig;
@property (nonatomic, copy, nullable) NSArray<NSString *> *excludePatterns;
@property (nonatomic, assign, readonly) BOOL isRunning;

- (instancetype)initWithDirectoryPath:(NSString *)dirPath
                            publicKey:(SecKeyRef)publicKey
                     cloudflareConfig:(FVCloudflareConfig *)cfConfig
                      excludePatterns:(nullable NSArray<NSString *> *)excludePatterns;

- (void)startWithLogHandler:(nullable FVTaskLogBlock)logHandler
            progressHandler:(nullable FVTaskProgressBlock)progressHandler
                 completion:(FVTaskCompletionBlock)completion;

- (void)cancel;

@end

NS_ASSUME_NONNULL_END
