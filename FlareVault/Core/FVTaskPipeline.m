//
//  FVTaskPipeline.m
//  FlareVault
//

#import "FVTaskPipeline.h"
#import "FVArchiver.h"
#import "FVCryptoEngine.h"
#import "FVCloudflareUploader.h"
#import "FVSnapshotManager.h"

@interface FVTaskPipeline ()
@property (nonatomic, assign) BOOL isRunning;
@property (nonatomic, assign) BOOL isCancelled;
@property (nonatomic, strong, nullable) FVCloudflareUploader *activeUploader;
@property (nonatomic, copy, nullable) NSString *currentTempTar;
@property (nonatomic, copy, nullable) NSString *currentTempEnc;
@end

@implementation FVTaskPipeline

- (NSString *)sourceDirectoryPath {
    return self.sourceDirectoryPaths.firstObject ?: @"";
}

- (void)setSourceDirectoryPath:(NSString *)path {
    if (path.length > 0) {
        self.sourceDirectoryPaths = @[path];
    } else {
        self.sourceDirectoryPaths = @[];
    }
}

- (instancetype)initWithDirectoryPath:(NSString *)dirPath
                            publicKey:(SecKeyRef)publicKey
                     cloudflareConfig:(FVCloudflareConfig *)cfConfig
                      excludePatterns:(nullable NSArray<NSString *> *)excludePatterns
{
    return [self initWithDirectoryPaths:dirPath.length > 0 ? @[dirPath] : @[]
                              publicKey:publicKey
                       cloudflareConfig:cfConfig
                        excludePatterns:excludePatterns
                            incremental:NO];
}

- (instancetype)initWithDirectoryPath:(NSString *)dirPath
                            publicKey:(SecKeyRef)publicKey
                     cloudflareConfig:(FVCloudflareConfig *)cfConfig
                      excludePatterns:(nullable NSArray<NSString *> *)excludePatterns
                          incremental:(BOOL)incremental
{
    return [self initWithDirectoryPaths:dirPath.length > 0 ? @[dirPath] : @[]
                              publicKey:publicKey
                       cloudflareConfig:cfConfig
                        excludePatterns:excludePatterns
                            incremental:incremental];
}

- (instancetype)initWithDirectoryPaths:(NSArray<NSString *> *)dirPaths
                             publicKey:(SecKeyRef)publicKey
                      cloudflareConfig:(FVCloudflareConfig *)cfConfig
                       excludePatterns:(nullable NSArray<NSString *> *)excludePatterns
                           incremental:(BOOL)incremental
{
    self = [super init];
    if (self) {
        _sourceDirectoryPaths = [dirPaths copy];
        _publicKey = publicKey;
        _cloudflareConfig = cfConfig;
        _excludePatterns = [excludePatterns copy];
        _isIncremental = incremental;
        _forceFull = NO;
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
            safeLog(@"[ERROR] 未配置非对称公钥，无法加密。", YES);
            dispatch_async(dispatch_get_main_queue(), ^{
                self.isRunning = NO;
                completion(NO, nil, [NSError errorWithDomain:FVCryptoErrorDomain code:1001 userInfo:@{NSLocalizedDescriptionKey: @"Missing public key"}]);
            });
            return;
        }

        NSFileManager *fm = [NSFileManager defaultManager];
        NSMutableArray<NSString *> *validDirs = [NSMutableArray array];
        for (NSString *p in self.sourceDirectoryPaths) {
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:p isDirectory:&isDir] && isDir) {
                [validDirs addObject:p];
            } else {
                safeLog([NSString stringWithFormat:@"[WARN] 目录不存在或无效，已跳过: %@", p], YES);
            }
        }

        if (validDirs.count == 0) {
            safeLog(@"[ERROR] 未配置任何有效待备份目录。", YES);
            dispatch_async(dispatch_get_main_queue(), ^{
                self.isRunning = NO;
                completion(NO, nil, [NSError errorWithDomain:FVArchiverErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey: @"No valid directories specified"}]);
            });
            return;
        }

        NSUInteger totalDirs = validDirs.count;
        safeLog([NSString stringWithFormat:@"[INFO] 任务启动: 共 %lu 个待备份目录", (unsigned long)totalDirs], NO);

        FVSnapshotManager *snapMgr = [FVSnapshotManager sharedManager];
        NSString *lastRemoteUrl = nil;
        BOOL allSuccess = YES;
        NSError *lastError = nil;

        for (NSUInteger dirIdx = 0; dirIdx < totalDirs; dirIdx++) {
            if (self.isCancelled) {
                break;
            }

            NSString *currentDir = validDirs[dirIdx];
            NSString *folderName = [currentDir lastPathComponent];
            double dirBase = (double)dirIdx / (double)totalDirs;
            double dirWeight = 1.0 / (double)totalDirs;

            void (^stepProgress)(NSString *, double, NSString *) = ^(NSString *stage, double p, NSString *txt) {
                double overall = dirBase + (p * dirWeight);
                NSString *prefixed = [NSString stringWithFormat:@"[%lu/%lu %@] %@", (unsigned long)(dirIdx + 1), (unsigned long)totalDirs, folderName, txt];
                safeProgress(stage, overall, prefixed);
            };

            safeLog([NSString stringWithFormat:@"\n[STAGE] =========================================="], NO);
            safeLog([NSString stringWithFormat:@"[STAGE] >>> 正在处理目录 [%lu/%lu]: '%@'", (unsigned long)(dirIdx + 1), (unsigned long)totalDirs, folderName], NO);
            safeLog([NSString stringWithFormat:@"[INFO] 绝对路径: %@", currentDir], NO);
            stepProgress(@"分析目录", 0.05, @"正在进行快照差异比对...");

            BOOL forceFull = !self.isIncremental || self.forceFull;
            FVDifferentialResult *diff = [snapMgr computeDifferentialForDirectory:currentDir
                                                                  excludePatterns:self.excludePatterns
                                                                        forceFull:forceFull];

            if (self.isCancelled) {
                [self cleanupTempFiles];
                break;
            }

            // Check if directory has no changes
            if (!diff.hasChanges) {
                safeLog([NSString stringWithFormat:@"[INFO] 目录 '%@' 未发生任何变更 (共 %lu 个文件)，跳过上传。", folderName, (unsigned long)diff.totalFilesCount], NO);
                stepProgress(@"就绪", 1.0, @"已是最新，跳过上传");
                continue;
            }

            NSDateFormatter *df = [[NSDateFormatter alloc] init];
            df.dateFormat = @"yyyyMMdd_HHmmss";
            NSString *timestamp = [df stringFromDate:[NSDate date]];

            NSString *baseFileName = nil;
            NSString *backupTypeStr = diff.isFullBackup ? @"full" : @"incremental";
            NSUInteger sequence = diff.sequenceNumber;

            if (diff.isFullBackup) {
                baseFileName = [NSString stringWithFormat:@"%@_%@_full", folderName, timestamp];
                safeLog([NSString stringWithFormat:@"[INFO] 备份模式: 全量基线 (共 %lu 个文件，%@)",
                         (unsigned long)diff.totalFilesCount,
                         [NSByteCountFormatter stringFromByteCount:(long long)diff.totalFilesBytes countStyle:NSByteCountFormatterCountStyleFile]], NO);
            } else {
                baseFileName = [NSString stringWithFormat:@"%@_inc%lu_%@", diff.baseBackupId ?: folderName, (unsigned long)sequence, timestamp];
                safeLog([NSString stringWithFormat:@"[INFO] 备份模式: 增量快照 (基于基线: %@, 序列: #%lu)",
                         diff.baseBackupId ?: @"未知", (unsigned long)sequence], NO);
                safeLog([NSString stringWithFormat:@"[INFO] 差异统计: %lu 个新增/修改文件 (%@)，%lu 个已删除，%lu 个未变更",
                         (unsigned long)diff.changedFilesCount,
                         [NSByteCountFormatter stringFromByteCount:(long long)diff.changedFilesBytes countStyle:NSByteCountFormatterCountStyleFile],
                         (unsigned long)diff.deletedFilesCount,
                         (unsigned long)diff.unchangedFilesCount], NO);
            }

            NSString *tempDir = NSTemporaryDirectory();
            self.currentTempTar = [tempDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.tar.gz", baseFileName]];
            self.currentTempEnc = [tempDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.flarevault", baseFileName]];

            stepProgress(@"打包归档", 0.15, diff.isFullBackup ? @"正在打包全量文件..." : @"正在归档增量变更文件...");
            safeLog(diff.isFullBackup ? @"[STAGE 1/3] 执行全量 tar 归档与 gzip 压缩..." : @"[STAGE 1/3] 执行差异打包 (仅归档变更文件)...", NO);

            NSError *archiveErr = nil;
            BOOL packOk = NO;
            if (diff.isFullBackup) {
                packOk = [FVArchiver archiveDirectoryAtPath:currentDir
                                          toDestinationPath:self.currentTempTar
                                            excludePatterns:self.excludePatterns
                                                      error:&archiveErr];
            } else {
                packOk = [FVArchiver archiveDirectoryAtPath:currentDir
                                              relativeFiles:diff.addedOrModifiedRelativePaths
                                          toDestinationPath:self.currentTempTar
                                                      error:&archiveErr];
            }

            if (!packOk || self.isCancelled) {
                safeLog([NSString stringWithFormat:@"[ERROR] 打包失败: %@", archiveErr.localizedDescription], YES);
                [self cleanupTempFiles];
                allSuccess = NO;
                lastError = archiveErr;
                break;
            }

            NSDictionary *tarAttrs = [fm attributesOfItemAtPath:self.currentTempTar error:nil];
            NSString *tarSizeStr = [NSByteCountFormatter stringFromByteCount:[tarAttrs fileSize] countStyle:NSByteCountFormatterCountStyleFile];
            safeLog([NSString stringWithFormat:@"[STAGE 1/3] 打包完成，压缩体积: %@", tarSizeStr], NO);
            stepProgress(@"打包归档", 0.33, @"打包完成");

            // STAGE 2: Asymmetric Hybrid Encryption
            safeLog(@"[STAGE 2/3] 执行非对称流式加密 (RSA-OAEP + AES-256-CBC + HMAC-SHA256)...", NO);

            NSMutableDictionary *metadata = [NSMutableDictionary dictionaryWithDictionary:@{
                @"backup_type": backupTypeStr,
                @"base_backup_id": diff.isFullBackup ? baseFileName : (diff.baseBackupId ?: @""),
                @"sequence": @(sequence),
                @"folder_name": folderName,
                @"timestamp": @([[NSDate date] timeIntervalSince1970]),
                @"client": @"FlareVault macOS AppKit"
            }];

            if (diff.isFullBackup) {
                metadata[@"file_count"] = @(diff.totalFilesCount);
                metadata[@"original_bytes"] = @(diff.totalFilesBytes);
            } else {
                metadata[@"changed_files_count"] = @(diff.changedFilesCount);
                metadata[@"deleted_files_count"] = @(diff.deletedFilesCount);
                metadata[@"deleted_files"] = diff.deletedRelativePaths ?: @[];
                metadata[@"changed_bytes"] = @(diff.changedFilesBytes);
                metadata[@"total_folder_files"] = @(diff.totalFilesCount);
            }

            NSError *encErr = nil;
            BOOL encOk = [FVCryptoEngine encryptFileAtPath:self.currentTempTar
                                              toOutputPath:self.currentTempEnc
                                             withPublicKey:self.publicKey
                                                  metadata:metadata
                                                  progress:^(double progress, uint64_t bytesProcessed, uint64_t totalBytes) {
                double subOverall = 0.33 + (progress * 0.33);
                NSString *statusText = [NSString stringWithFormat:@"正在加密: %.0f%% (%@ / %@)",
                                        progress * 100.0,
                                        [NSByteCountFormatter stringFromByteCount:bytesProcessed countStyle:NSByteCountFormatterCountStyleFile],
                                        [NSByteCountFormatter stringFromByteCount:totalBytes countStyle:NSByteCountFormatterCountStyleFile]];
                stepProgress(@"加密归档", subOverall, statusText);
            } error:&encErr];

            if (!encOk || self.isCancelled) {
                safeLog([NSString stringWithFormat:@"[ERROR] 加密失败: %@", encErr.localizedDescription], YES);
                [self cleanupTempFiles];
                allSuccess = NO;
                lastError = encErr;
                break;
            }

            NSDictionary *encAttrs = [fm attributesOfItemAtPath:self.currentTempEnc error:nil];
            NSString *encSizeStr = [NSByteCountFormatter stringFromByteCount:[encAttrs fileSize] countStyle:NSByteCountFormatterCountStyleFile];
            NSString *encSha = [FVCryptoEngine sha256ForFileAtPath:self.currentTempEnc error:nil];
            safeLog([NSString stringWithFormat:@"[STAGE 2/3] 加密完成，密文体积: %@ (SHA256: %@)", encSizeStr, encSha], NO);
            stepProgress(@"加密归档", 0.66, @"加密完成");

            [fm removeItemAtPath:self.currentTempTar error:nil];
            self.currentTempTar = nil;

            // STAGE 3: Cloudflare R2 Upload (Synchronous per-directory to preserve stochastic intervals)
            safeLog(@"[STAGE 3/3] 上传至 Cloudflare R2...", NO);
            stepProgress(@"传输到 Cloudflare", 0.70, @"正在建立连接并计算授权...");

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

            dispatch_semaphore_t uploadSem = dispatch_semaphore_create(0);
            __block BOOL currentUploadSuccess = NO;
            __block NSString *currentRemoteUrl = nil;
            __block NSError *currentUploadErr = nil;

            [self.activeUploader uploadFileAtPath:self.currentTempEnc
                                 remoteObjectKey:remoteObjectKey
                                        progress:^(double progress, int64_t bytesSent, int64_t totalBytes) {
                double subOverall = 0.66 + (progress * 0.34);
                NSString *statusText = [NSString stringWithFormat:@"上传中: %.1f%% (%@ / %@)",
                                        progress * 100.0,
                                        [NSByteCountFormatter stringFromByteCount:bytesSent countStyle:NSByteCountFormatterCountStyleFile],
                                        [NSByteCountFormatter stringFromByteCount:totalBytes countStyle:NSByteCountFormatterCountStyleFile]];
                stepProgress(@"传输到 Cloudflare", subOverall, statusText);
            } completion:^(BOOL success, NSString * _Nullable remoteUrl, NSError * _Nullable error) {
                currentUploadSuccess = success;
                currentRemoteUrl = remoteUrl;
                currentUploadErr = error;
                dispatch_semaphore_signal(uploadSem);
            }];

            dispatch_semaphore_wait(uploadSem, DISPATCH_TIME_FOREVER);

            if (currentUploadSuccess) {
                lastRemoteUrl = currentRemoteUrl;
                safeLog([NSString stringWithFormat:@"[OK] 目录 '%@' 打包、加密并上传成功", folderName], NO);
                safeLog([NSString stringWithFormat:@"[OK] 远程对象: %@", currentRemoteUrl], NO);

                // Commit local snapshot ledger for this directory
                NSString *targetBaseId = diff.isFullBackup ? baseFileName : diff.baseBackupId;
                NSError *commitErr = nil;
                BOOL committed = [snapMgr commitSnapshotForDirectory:currentDir
                                                        baseBackupId:targetBaseId
                                                      sequenceNumber:sequence
                                                             fileMap:diff.currentScanMap
                                                               error:&commitErr];
                if (committed) {
                    safeLog([NSString stringWithFormat:@"[OK] 本地快照账本已更新 (Base: %@, Sequence: #%lu)", targetBaseId, (unsigned long)sequence], NO);
                } else {
                    safeLog([NSString stringWithFormat:@"[WARN] 本地快照写入失败: %@", commitErr.localizedDescription], YES);
                }
                stepProgress(@"完成", 1.0, @"已成功上传至 Cloudflare R2");
            } else {
                safeLog([NSString stringWithFormat:@"[ERROR] 目录 '%@' 上传失败: %@", folderName, currentUploadErr.localizedDescription], YES);
                allSuccess = NO;
                lastError = currentUploadErr;
                [self cleanupTempFiles];
                break;
            }

            [self cleanupTempFiles];
            self.activeUploader = nil;
        }

        [self cleanupTempFiles];
        self.isRunning = NO;

        if (self.isCancelled) {
            safeLog(@"[INFO] 任务已被用户取消。", NO);
            safeProgress(@"已取消", 0.0, @"用户已取消任务");
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, nil, [NSError errorWithDomain:@"com.flarevault.pipeline" code:999 userInfo:@{NSLocalizedDescriptionKey: @"Task cancelled by user"}]);
            });
            return;
        }

        if (allSuccess) {
            safeLog(@"\n[OK] ==========================================", NO);
            safeLog([NSString stringWithFormat:@"[OK] 所有配置目录 (%lu 个) 均已成功完成加密备份！", (unsigned long)totalDirs], NO);
            safeProgress(@"全部完成", 1.0, [NSString stringWithFormat:@"已完成 %lu 个目录的加密备份", (unsigned long)totalDirs]);
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(YES, lastRemoteUrl, nil);
            });
        } else {
            safeLog(@"[ERROR] 任务执行过程中出现错误，已中止后续操作。", YES);
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, nil, lastError);
            });
        }
    });
}

@end
