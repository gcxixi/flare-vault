//
//  FVTaskPipeline.m
//  FlareVault
//

#import "FVTaskPipeline.h"
#import "FVArchiver.h"
#import "FVCryptoEngine.h"
#import "FVCloudflareUploader.h"

@interface FVTaskPipeline ()
@property (nonatomic, assign) BOOL isRunning;
@property (nonatomic, assign) BOOL isCancelled;
@property (nonatomic, strong, nullable) FVCloudflareUploader *activeUploader;
@property (nonatomic, copy, nullable) NSString *currentTempTar;
@property (nonatomic, copy, nullable) NSString *currentTempEnc;
@end

@implementation FVTaskPipeline

- (instancetype)initWithDirectoryPath:(NSString *)dirPath
                            publicKey:(SecKeyRef)publicKey
                     cloudflareConfig:(FVCloudflareConfig *)cfConfig
                      excludePatterns:(nullable NSArray<NSString *> *)excludePatterns
{
    self = [super init];
    if (self) {
        _sourceDirectoryPath = [dirPath copy];
        _publicKey = publicKey;
        _cloudflareConfig = cfConfig;
        _excludePatterns = [excludePatterns copy];
    }
    return self;
}

- (void)cancel {
    self.isCancelled = YES;
    if (self.activeUploader) {
        [self.activeUploader cancel];
    }
    [self cleanupTempFiles];
}

- (void)cleanupTempFiles {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (self.currentTempTar && [fm fileExistsAtPath:self.currentTempTar]) {
        [fm removeItemAtPath:self.currentTempTar error:nil];
    }
    if (self.currentTempEnc && [fm fileExistsAtPath:self.currentTempEnc]) {
        [fm removeItemAtPath:self.currentTempEnc error:nil];
    }
}

- (void)startWithLogHandler:(nullable FVTaskLogBlock)logHandler
            progressHandler:(nullable FVTaskProgressBlock)progressHandler
                 completion:(FVTaskCompletionBlock)completion
{
    self.isRunning = YES;
    self.isCancelled = NO;

    void (^safeLog)(NSString *, BOOL) = ^(NSString *msg, BOOL isErr) {
        if (logHandler) {
            dispatch_async(dispatch_get_main_queue(), ^{
                logHandler(msg, isErr);
            });
        }
    };

    void (^safeProgress)(NSString *, double, NSString *) = ^(NSString *stage, double p, NSString *txt) {
        if (progressHandler) {
            dispatch_async(dispatch_get_main_queue(), ^{
                progressHandler(stage, p, txt);
            });
        }
    };

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // 0. Validate preconditions
        if (!self.publicKey) {
            safeLog(@"[错误] 未配置非对称公钥，无法加密。", YES);
            dispatch_async(dispatch_get_main_queue(), ^{
                self.isRunning = NO;
                completion(NO, nil, [NSError errorWithDomain:FVCryptoErrorDomain code:1001 userInfo:@{NSLocalizedDescriptionKey: @"Missing public key"}]);
            });
            return;
        }

        BOOL isDir = NO;
        if (![[NSFileManager defaultManager] fileExistsAtPath:self.sourceDirectoryPath isDirectory:&isDir] || !isDir) {
            safeLog(@"[错误] 指定的目录不存在或不是文件夹。", YES);
            dispatch_async(dispatch_get_main_queue(), ^{
                self.isRunning = NO;
                completion(NO, nil, [NSError errorWithDomain:FVArchiverErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Source directory invalid"}]);
            });
            return;
        }

        NSString *folderName = [self.sourceDirectoryPath lastPathComponent];
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"yyyyMMdd_HHmmss";
        NSString *timestamp = [df stringFromDate:[NSDate date]];
        NSString *baseFileName = [NSString stringWithFormat:@"%@_%@", folderName, timestamp];

        NSString *tempDir = NSTemporaryDirectory();
        self.currentTempTar = [tempDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.tar.gz", baseFileName]];
        self.currentTempEnc = [tempDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.flarevault", baseFileName]];

        // STAGE 1: Inspect & Pack Directory
        safeLog([NSString stringWithFormat:@"[INFO] 开始分析目录: '%@'", folderName], NO);
        safeProgress(@"打包目录", 0.05, @"正在统计目录文件...");

        FVDirectoryStats *stats = [FVArchiver inspectDirectoryAtPath:self.sourceDirectoryPath excludePatterns:self.excludePatterns];
        if (stats.excludedCount > 0) {
            safeLog([NSString stringWithFormat:@"[INFO] 待打包 %lu 个文件 (%@)，已排除 %lu 项开发缓存/匹配项",
                     (unsigned long)stats.fileCount, stats.formattedSize, (unsigned long)stats.excludedCount], NO);
        } else {
            safeLog([NSString stringWithFormat:@"[INFO] 目录共 %lu 个文件，体积: %@", (unsigned long)stats.fileCount, stats.formattedSize], NO);
        }

        safeProgress(@"打包目录", 0.15, @"正在压缩打包为 tar.gz...");
        safeLog(@"[STAGE 1/3] 执行 tar 归档与 gzip 压缩 (应用排除规则)...", NO);

        NSError *archiveErr = nil;
        BOOL packOk = [FVArchiver archiveDirectoryAtPath:self.sourceDirectoryPath
                                       toDestinationPath:self.currentTempTar
                                         excludePatterns:self.excludePatterns
                                                   error:&archiveErr];
        if (!packOk || self.isCancelled) {
            safeLog([NSString stringWithFormat:@"[ERROR] 打包失败: %@", archiveErr.localizedDescription], YES);
            [self cleanupTempFiles];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.isRunning = NO;
                completion(NO, nil, archiveErr);
            });
            return;
        }

        NSDictionary *tarAttrs = [[NSFileManager defaultManager] attributesOfItemAtPath:self.currentTempTar error:nil];
        NSString *tarSizeStr = [NSByteCountFormatter stringFromByteCount:[tarAttrs fileSize] countStyle:NSByteCountFormatterCountStyleFile];
        safeLog([NSString stringWithFormat:@"[STAGE 1/3] 打包完成，压缩体积: %@", tarSizeStr], NO);
        safeProgress(@"打包目录", 0.33, @"打包完成");

        // STAGE 2: Asymmetric Hybrid Encryption
        safeLog(@"[STAGE 2/3] 执行非对称流式加密 (RSA-OAEP + AES-256-CBC + HMAC-SHA256)...", NO);

        NSDictionary *metadata = @{
            @"folder_name": folderName,
            @"file_count": @(stats.fileCount),
            @"original_bytes": @(stats.totalSize),
            @"timestamp": @([[NSDate date] timeIntervalSince1970]),
            @"client": @"FlareVault macOS AppKit"
        };

        NSError *encErr = nil;
        BOOL encOk = [FVCryptoEngine encryptFileAtPath:self.currentTempTar
                                          toOutputPath:self.currentTempEnc
                                         withPublicKey:self.publicKey
                                              metadata:metadata
                                              progress:^(double progress, uint64_t bytesProcessed, uint64_t totalBytes) {
            double overall = 0.33 + (progress * 0.33);
            NSString *statusText = [NSString stringWithFormat:@"正在加密: %.0f%% (%@ / %@)",
                                    progress * 100.0,
                                    [NSByteCountFormatter stringFromByteCount:bytesProcessed countStyle:NSByteCountFormatterCountStyleFile],
                                    [NSByteCountFormatter stringFromByteCount:totalBytes countStyle:NSByteCountFormatterCountStyleFile]];
            safeProgress(@"加密归档", overall, statusText);
        } error:&encErr];

        if (!encOk || self.isCancelled) {
            safeLog([NSString stringWithFormat:@"[ERROR] 加密失败: %@", encErr.localizedDescription], YES);
            [self cleanupTempFiles];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.isRunning = NO;
                completion(NO, nil, encErr);
            });
            return;
        }

        NSDictionary *encAttrs = [[NSFileManager defaultManager] attributesOfItemAtPath:self.currentTempEnc error:nil];
        NSString *encSizeStr = [NSByteCountFormatter stringFromByteCount:[encAttrs fileSize] countStyle:NSByteCountFormatterCountStyleFile];
        NSString *encSha = [FVCryptoEngine sha256ForFileAtPath:self.currentTempEnc error:nil];
        safeLog([NSString stringWithFormat:@"[STAGE 2/3] 加密完成，密文体积: %@ (SHA256: %@)", encSizeStr, encSha], NO);
        safeProgress(@"加密归档", 0.66, @"加密完成");

        // Remove intermediate unencrypted tar.gz
        [[NSFileManager defaultManager] removeItemAtPath:self.currentTempTar error:nil];
        self.currentTempTar = nil;

        // STAGE 3: Cloudflare R2 Upload
        safeLog(@"[STAGE 3/3] 上传至 Cloudflare R2...", NO);
        safeProgress(@"传输到 Cloudflare", 0.70, @"正在计算 SigV4 授权并建立连接...");

        NSString *prefix = self.cloudflareConfig.remotePrefix ?: @"backups/";
        if (![prefix hasSuffix:@"/"] && prefix.length > 0) {
            prefix = [prefix stringByAppendingString:@"/"];
        }
        NSString *remoteObjectKey = [NSString stringWithFormat:@"%@%@.flarevault", prefix, baseFileName];
        safeLog([NSString stringWithFormat:@"[INFO] 目标 Bucket: '%@', 对象键: '%@'", self.cloudflareConfig.bucketName, remoteObjectKey], NO);

        self.activeUploader = [[FVCloudflareUploader alloc] initWithConfig:self.cloudflareConfig];
        self.activeUploader.statusLogBlock = ^(NSString *logMsg) {
            safeLog(logMsg, NO);
        };
        [self.activeUploader uploadFileAtPath:self.currentTempEnc
                             remoteObjectKey:remoteObjectKey
                                    progress:^(double progress, int64_t bytesSent, int64_t totalBytes) {
            double overall = 0.66 + (progress * 0.34);
            NSString *statusText = [NSString stringWithFormat:@"上传中: %.1f%% (%@ / %@)",
                                    progress * 100.0,
                                    [NSByteCountFormatter stringFromByteCount:bytesSent countStyle:NSByteCountFormatterCountStyleFile],
                                    [NSByteCountFormatter stringFromByteCount:totalBytes countStyle:NSByteCountFormatterCountStyleFile]];
            safeProgress(@"传输到 Cloudflare", overall, statusText);
        } completion:^(BOOL success, NSString * _Nullable remoteUrl, NSError * _Nullable error) {
            if (success) {
                safeLog(@"[OK] 数据打包、非对称加密并上传 Cloudflare 成功", NO);
                safeLog([NSString stringWithFormat:@"[OK] 远程资源地址: %@", remoteUrl], NO);
                safeProgress(@"全部完成", 1.0, @"已成功上传到 Cloudflare R2");
            } else {
                safeLog([NSString stringWithFormat:@"[ERROR] 上传 Cloudflare 失败: %@", error.localizedDescription], YES);
            }

            [self cleanupTempFiles];
            self.isRunning = NO;
            self.activeUploader = nil;
            completion(success, remoteUrl, error);
        }];
    });
}

@end
