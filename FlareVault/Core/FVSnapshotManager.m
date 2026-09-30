//
//  FVSnapshotManager.m
//  FlareVault
//
//  Local snapshot ledger and differential engine for incremental backups.
//

#import "FVSnapshotManager.h"
#import "FVArchiver.h"
#import <CommonCrypto/CommonDigest.h>
#import <fnmatch.h>

@implementation FVFileEntry

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (instancetype)initWithRelativePath:(NSString *)path mtime:(NSTimeInterval)mtime size:(uint64_t)size {
    self = [super init];
    if (self) {
        _relativePath = [path copy];
        _mtime = mtime;
        _size = size;
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.relativePath forKey:@"path"];
    [coder encodeDouble:self.mtime forKey:@"mtime"];
    [coder encodeInt64:(int64_t)self.size forKey:@"size"];
}

- (nullable instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) {
        _relativePath = [coder decodeObjectOfClass:[NSString class] forKey:@"path"];
        _mtime = [coder decodeDoubleForKey:@"mtime"];
        _size = (uint64_t)[coder decodeInt64ForKey:@"size"];
    }
    return self;
}

- (NSDictionary *)toDictionary {
    return @{
        @"mtime": @(self.mtime),
        @"size": @(self.size)
    };
}

+ (instancetype)fromDictionary:(NSDictionary *)dict relativePath:(NSString *)path {
    NSTimeInterval mtime = [dict[@"mtime"] doubleValue];
    uint64_t size = [dict[@"size"] unsignedLongLongValue];
    return [[FVFileEntry alloc] initWithRelativePath:path mtime:mtime size:size];
}

@end

@implementation FVDifferentialResult

- (BOOL)hasChanges {
    return self.isFullBackup || (self.addedOrModifiedRelativePaths.count > 0) || (self.deletedRelativePaths.count > 0);
}

@end

@implementation FVSnapshotManager

+ (instancetype)sharedManager {
    static FVSnapshotManager *mgr = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mgr = [[FVSnapshotManager alloc] init];
    });
    return mgr;
}

- (NSString *)snapshotsDirectory {
    NSString *appSupport = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
    NSString *dir = [appSupport stringByAppendingPathComponent:@"FlareVault/snapshots"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

- (NSString *)hashForDirectoryPath:(NSString *)dirPath {
    NSString *std = [dirPath stringByStandardizingPath];
    const char *str = [std UTF8String];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(str, (CC_LONG)strlen(str), digest);

    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return [hex copy];
}

- (NSString *)snapshotPathForDirectory:(NSString *)dirPath {
    NSString *hash = [self hashForDirectoryPath:dirPath];
    return [[self snapshotsDirectory] stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.json", hash]];
}

- (BOOL)hasSnapshotForDirectory:(NSString *)dirPath {
    NSString *path = [self snapshotPathForDirectory:dirPath];
    return [[NSFileManager defaultManager] fileExistsAtPath:path];
}

- (nullable NSDictionary *)snapshotInfoForDirectory:(NSString *)dirPath {
    NSString *path = [self snapshotPathForDirectory:dirPath];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) return nil;

    NSDictionary *files = json[@"files"];
    return @{
        @"baseBackupId": json[@"baseBackupId"] ?: @"",
        @"sequenceNumber": json[@"sequenceNumber"] ?: @(0),
        @"lastBackupTimestamp": json[@"lastBackupTimestamp"] ?: @(0),
        @"fileCount": @(files.count)
    };
}

- (void)resetSnapshotForDirectory:(NSString *)dirPath {
    NSString *path = [self snapshotPathForDirectory:dirPath];
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
}

static BOOL MatchesAnyPattern(NSString *name, NSArray<NSString *> *patterns) {
    if (!patterns || patterns.count == 0) return NO;
    const char *cName = [name UTF8String];
    for (NSString *pat in patterns) {
        NSString *trimmed = [pat stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length == 0) continue;
        if ([name isEqualToString:trimmed]) return YES;
        if (fnmatch(trimmed.UTF8String, cName, 0) == 0) return YES;
    }
    return NO;
}

- (FVDifferentialResult *)computeDifferentialForDirectory:(NSString *)dirPath
                                          excludePatterns:(nullable NSArray<NSString *> *)excludePatterns
                                                forceFull:(BOOL)forceFull
{
    FVDifferentialResult *result = [[FVDifferentialResult alloc] init];
    NSURL *baseURL = [[NSURL fileURLWithPath:dirPath] URLByResolvingSymlinksInPath];
    NSString *basePath = baseURL.path;
    if (![basePath hasSuffix:@"/"]) {
        basePath = [basePath stringByAppendingString:@"/"];
    }
    NSUInteger prefixLen = basePath.length;

    // 1. Scan current directory
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtURL:baseURL
                                 includingPropertiesForKeys:@[NSURLContentModificationDateKey, NSURLFileSizeKey, NSURLIsDirectoryKey]
                                                    options:0
                                               errorHandler:^BOOL(NSURL * _Nonnull errUrl, NSError * _Nonnull error) {
        (void)errUrl; (void)error;
        return YES;
    }];

    NSMutableDictionary<NSString *, FVFileEntry *> *currentScanMap = [NSMutableDictionary dictionary];
    uint64_t totalBytes = 0;
    NSUInteger totalFiles = 0;

    for (NSURL *fileURL in enumerator) {
        NSString *fileName = fileURL.lastPathComponent;
        NSNumber *isDir = nil;
        [fileURL getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];

        if (MatchesAnyPattern(fileName, excludePatterns)) {
            if ([isDir boolValue]) {
                [enumerator skipDescendants];
            }
            continue;
        }

        if ([isDir boolValue]) {
            continue;
        }

        NSString *filePath = [fileURL URLByResolvingSymlinksInPath].path;
        if (![filePath hasPrefix:basePath]) continue;
        NSString *relPath = [filePath substringFromIndex:prefixLen];

        NSDate *mdate = nil;
        NSNumber *fsize = nil;
        [fileURL getResourceValue:&mdate forKey:NSURLContentModificationDateKey error:nil];
        [fileURL getResourceValue:&fsize forKey:NSURLFileSizeKey error:nil];

        NSTimeInterval mtime = [mdate timeIntervalSince1970];
        uint64_t size = [fsize unsignedLongLongValue];

        FVFileEntry *entry = [[FVFileEntry alloc] initWithRelativePath:relPath mtime:mtime size:size];
        currentScanMap[relPath] = entry;

        totalFiles++;
        totalBytes += size;
    }

    result.currentScanMap = currentScanMap;
    result.totalFilesCount = totalFiles;
    result.totalFilesBytes = totalBytes;

    // 2. Check existing ledger
    NSString *ledgerPath = [self snapshotPathForDirectory:dirPath];
    NSData *ledgerData = (!forceFull) ? [NSData dataWithContentsOfFile:ledgerPath] : nil;
    NSDictionary *ledgerJson = nil;
    if (ledgerData) {
        ledgerJson = [NSJSONSerialization JSONObjectWithData:ledgerData options:0 error:nil];
    }

    if (!ledgerJson || forceFull) {
        // Full backup
        result.isFullBackup = YES;
        result.sequenceNumber = 0;
        result.baseBackupId = nil;
        result.addedOrModifiedRelativePaths = [currentScanMap allKeys];
        result.deletedRelativePaths = @[];
        result.changedFilesCount = totalFiles;
        result.changedFilesBytes = totalBytes;
        result.unchangedFilesCount = 0;
        result.deletedFilesCount = 0;
        return result;
    }

    // Incremental calculation
    result.isFullBackup = NO;
    result.baseBackupId = ledgerJson[@"baseBackupId"] ?: @"";
    NSUInteger lastSeq = [ledgerJson[@"sequenceNumber"] unsignedIntegerValue];
    result.sequenceNumber = lastSeq + 1;

    NSDictionary *priorFilesDict = ledgerJson[@"files"];
    NSMutableDictionary<NSString *, FVFileEntry *> *priorMap = [NSMutableDictionary dictionary];
    for (NSString *pRelPath in priorFilesDict) {
        priorMap[pRelPath] = [FVFileEntry fromDictionary:priorFilesDict[pRelPath] relativePath:pRelPath];
    }

    NSMutableArray<NSString *> *addedOrModified = [NSMutableArray array];
    uint64_t changedBytes = 0;
    NSUInteger unchanged = 0;

    for (NSString *relPath in currentScanMap) {
        FVFileEntry *current = currentScanMap[relPath];
        FVFileEntry *prior = priorMap[relPath];

        if (!prior) {
            // New file
            [addedOrModified addObject:relPath];
            changedBytes += current.size;
        } else if (current.size != prior.size || fabs(current.mtime - prior.mtime) > 0.001) {
            // Modified file
            [addedOrModified addObject:relPath];
            changedBytes += current.size;
        } else {
            // Unchanged
            unchanged++;
        }
    }

    NSMutableArray<NSString *> *deleted = [NSMutableArray array];
    for (NSString *relPath in priorMap) {
        if (!currentScanMap[relPath]) {
            [deleted addObject:relPath];
        }
    }

    // Sort paths deterministically
    [addedOrModified sortUsingSelector:@selector(compare:)];
    [deleted sortUsingSelector:@selector(compare:)];

    result.addedOrModifiedRelativePaths = [addedOrModified copy];
    result.deletedRelativePaths = [deleted copy];
    result.changedFilesCount = addedOrModified.count;
    result.changedFilesBytes = changedBytes;
    result.unchangedFilesCount = unchanged;
    result.deletedFilesCount = deleted.count;

    return result;
}

- (BOOL)commitSnapshotForDirectory:(NSString *)dirPath
                      baseBackupId:(NSString *)baseBackupId
                    sequenceNumber:(NSUInteger)sequenceNumber
                           fileMap:(NSDictionary<NSString *, FVFileEntry *> *)fileMap
                             error:(NSError * _Nullable * _Nullable)error
{
    NSMutableDictionary *filesDict = [NSMutableDictionary dictionaryWithCapacity:fileMap.count];
    for (NSString *relPath in fileMap) {
        filesDict[relPath] = [fileMap[relPath] toDictionary];
    }

    NSDictionary *ledger = @{
        @"version": @(1),
        @"sourcePath": [dirPath stringByStandardizingPath],
        @"baseBackupId": baseBackupId,
        @"sequenceNumber": @(sequenceNumber),
        @"lastBackupTimestamp": @([[NSDate date] timeIntervalSince1970]),
        @"files": filesDict
    };

    NSData *data = [NSJSONSerialization dataWithJSONObject:ledger options:NSJSONWritingPrettyPrinted error:error];
    if (!data) return NO;

    NSString *filePath = [self snapshotPathForDirectory:dirPath];
    return [data writeToFile:filePath options:NSDataWritingAtomic error:error];
}

@end
