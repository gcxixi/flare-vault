//
//  FVSnapshotManager.h
//  FlareVault
//
//  Local snapshot ledger and differential engine for incremental backups.
//  Operates in Encrypt-Only environment (client has only public key).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface FVFileEntry : NSObject <NSSecureCoding>
@property (nonatomic, copy) NSString *relativePath;
@property (nonatomic, assign) NSTimeInterval mtime;
@property (nonatomic, assign) uint64_t size;

- (instancetype)initWithRelativePath:(NSString *)path mtime:(NSTimeInterval)mtime size:(uint64_t)size;
- (NSDictionary *)toDictionary;
+ (instancetype)fromDictionary:(NSDictionary *)dict relativePath:(NSString *)path;
@end

@interface FVDifferentialResult : NSObject
@property (nonatomic, assign) BOOL isFullBackup;
@property (nonatomic, assign) NSUInteger sequenceNumber;
@property (nonatomic, copy, nullable) NSString *baseBackupId;
@property (nonatomic, copy) NSArray<NSString *> *addedOrModifiedRelativePaths;
@property (nonatomic, copy) NSArray<NSString *> *deletedRelativePaths;
@property (nonatomic, assign) NSUInteger totalFilesCount;
@property (nonatomic, assign) uint64_t totalFilesBytes;
@property (nonatomic, assign) NSUInteger changedFilesCount;
@property (nonatomic, assign) uint64_t changedFilesBytes;
@property (nonatomic, assign) NSUInteger unchangedFilesCount;
@property (nonatomic, assign) NSUInteger deletedFilesCount;
@property (nonatomic, copy) NSDictionary<NSString *, FVFileEntry *> *currentScanMap;

@property (nonatomic, readonly) BOOL hasChanges;
@end

@interface FVSnapshotManager : NSObject

+ (instancetype)sharedManager;

/// Computes the differential between the current state of dirPath and the local ledger.
/// If forceFull is YES or no prior snapshot exists, marks isFullBackup = YES.
- (FVDifferentialResult *)computeDifferentialForDirectory:(NSString *)dirPath
                                          excludePatterns:(nullable NSArray<NSString *> *)excludePatterns
                                                forceFull:(BOOL)forceFull;

/// Commits the snapshot state after a successful backup.
- (BOOL)commitSnapshotForDirectory:(NSString *)dirPath
                      baseBackupId:(NSString *)baseBackupId
                    sequenceNumber:(NSUInteger)sequenceNumber
                           fileMap:(NSDictionary<NSString *, FVFileEntry *> *)fileMap
                             error:(NSError * _Nullable * _Nullable)error;

/// Checks if a valid snapshot ledger exists for the given directory.
- (BOOL)hasSnapshotForDirectory:(NSString *)dirPath;

/// Returns current snapshot metadata (baseBackupId, sequenceNumber, lastBackupTimestamp, fileCount) if exists.
- (nullable NSDictionary *)snapshotInfoForDirectory:(NSString *)dirPath;

/// Resets/removes the snapshot ledger for the directory so the next backup is guaranteed full.
- (void)resetSnapshotForDirectory:(NSString *)dirPath;

@end

NS_ASSUME_NONNULL_END
