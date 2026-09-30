//
//  FVArchiver.m
//  FlareVault
//

#import "FVArchiver.h"
#import <fnmatch.h>

NSString * const FVArchiverErrorDomain = @"com.flarevault.archiver";

@implementation FVDirectoryStats
- (NSString *)formattedSize {
    return [NSByteCountFormatter stringFromByteCount:(long long)self.totalSize countStyle:NSByteCountFormatterCountStyleFile];
}
@end

@implementation FVArchiver

+ (NSArray<NSString *> *)defaultExcludePatterns {
    return @[
        @"node_modules",
        @"node_moudles", // support common typo gracefully
        @".venv",
        @"venv",
        @"env",
        @"__pycache__",
        @"*.pyc",
        @"*.pyo",
        @".DS_Store",
        @".git",
        @".svn",
        @".hg",
        @"build",
        @"dist",
        @".cache",
        @".next",
        @".nuxt",
        @"target",
        @"Pods",
        @"DerivedData"
    ];
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

+ (FVDirectoryStats *)inspectDirectoryAtPath:(NSString *)dirPath {
    return [self inspectDirectoryAtPath:dirPath excludePatterns:[self defaultExcludePatterns]];
}

+ (FVDirectoryStats *)inspectDirectoryAtPath:(NSString *)dirPath
                             excludePatterns:(nullable NSArray<NSString *> *)excludePatterns
{
    FVDirectoryStats *stats = [[FVDirectoryStats alloc] init];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *url = [NSURL fileURLWithPath:dirPath];

    NSDirectoryEnumerator *enumerator = [fm enumeratorAtURL:url
                                 includingPropertiesForKeys:@[NSURLFileSizeKey, NSURLIsDirectoryKey, NSURLNameKey]
                                                    options:0
                                               errorHandler:^BOOL(NSURL * _Nonnull url, NSError * _Nonnull error) {
        (void)url; (void)error;
        return YES;
    }];

    uint64_t totalSize = 0;
    NSUInteger fileCount = 0;
    NSUInteger dirCount = 0;
    NSUInteger excludedCount = 0;

    for (NSURL *fileURL in enumerator) {
        NSString *fileName = fileURL.lastPathComponent;
        NSNumber *isDir = nil;
        [fileURL getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];

        if (MatchesAnyPattern(fileName, excludePatterns)) {
            excludedCount++;
            if ([isDir boolValue]) {
                [enumerator skipDescendants];
            }
            continue;
        }

        if ([isDir boolValue]) {
            dirCount++;
        } else {
            fileCount++;
            NSNumber *fileSize = nil;
            [fileURL getResourceValue:&fileSize forKey:NSURLFileSizeKey error:nil];
            totalSize += [fileSize unsignedLongLongValue];
        }
    }

    stats.totalSize = totalSize;
    stats.fileCount = fileCount;
    stats.dirCount = dirCount;
    stats.excludedCount = excludedCount;
    return stats;
}

+ (BOOL)archiveDirectoryAtPath:(NSString *)sourceDirPath
             toDestinationPath:(NSString *)destinationTarGzPath
                         error:(NSError * _Nullable * _Nullable)error
{
    return [self archiveDirectoryAtPath:sourceDirPath
                      toDestinationPath:destinationTarGzPath
                        excludePatterns:[self defaultExcludePatterns]
                                  error:error];
}

+ (BOOL)archiveDirectoryAtPath:(NSString *)sourceDirPath
             toDestinationPath:(NSString *)destinationTarGzPath
               excludePatterns:(nullable NSArray<NSString *> *)excludePatterns
                         error:(NSError * _Nullable * _Nullable)error
{
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:sourceDirPath isDirectory:&isDir] || !isDir) {
        if (error) {
            *error = [NSError errorWithDomain:FVArchiverErrorDomain
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Source directory does not exist: %@", sourceDirPath]}];
        }
        return NO;
    }

    if ([fm fileExistsAtPath:destinationTarGzPath]) {
        [fm removeItemAtPath:destinationTarGzPath error:nil];
    }

    NSString *parentDir = [sourceDirPath stringByDeletingLastPathComponent];
    NSString *baseName = [sourceDirPath lastPathComponent];

    NSMutableArray<NSString *> *args = [NSMutableArray array];
    [args addObject:@"-czf"];
    [args addObject:destinationTarGzPath];

    if (excludePatterns && excludePatterns.count > 0) {
        for (NSString *pat in excludePatterns) {
            NSString *trimmed = [pat stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (trimmed.length > 0) {
                [args addObject:@"--exclude"];
                [args addObject:trimmed];
            }
        }
    }

    [args addObject:@"-C"];
    [args addObject:parentDir];
    [args addObject:baseName];

    NSTask *tarTask = [[NSTask alloc] init];
    tarTask.executableURL = [NSURL fileURLWithPath:@"/usr/bin/tar"];
    tarTask.arguments = args;

    NSPipe *errPipe = [NSPipe pipe];
    tarTask.standardError = errPipe;

    @try {
        [tarTask launch];
        [tarTask waitUntilExit];
    } @catch (NSException *ex) {
        if (error) {
            *error = [NSError errorWithDomain:FVArchiverErrorDomain
                                         code:-2
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to launch tar: %@", ex.reason]}];
        }
        return NO;
    }

    if (tarTask.terminationStatus != 0) {
        NSData *errData = [[errPipe fileHandleForReading] readDataToEndOfFile];
        NSString *errMsg = [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding];
        if (error) {
            *error = [NSError errorWithDomain:FVArchiverErrorDomain
                                         code:tarTask.terminationStatus
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"tar failed: %@", errMsg]}];
        }
        return NO;
    }

    return YES;
}

+ (BOOL)archiveDirectoryAtPath:(NSString *)sourceDirPath
                 relativeFiles:(NSArray<NSString *> *)relativePaths
             toDestinationPath:(NSString *)destinationTarGzPath
                         error:(NSError * _Nullable * _Nullable)error
{
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:sourceDirPath isDirectory:&isDir] || !isDir) {
        if (error) {
            *error = [NSError errorWithDomain:FVArchiverErrorDomain
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Source directory does not exist: %@", sourceDirPath]}];
        }
        return NO;
    }

    if ([fm fileExistsAtPath:destinationTarGzPath]) {
        [fm removeItemAtPath:destinationTarGzPath error:nil];
    }

    NSString *parentDir = [sourceDirPath stringByDeletingLastPathComponent];
    NSString *baseName = [sourceDirPath lastPathComponent];

    NSString *fileListPath = nil;
    if (relativePaths.count == 0) {
        fileListPath = @"/dev/null";
    } else {
        fileListPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"fv_tar_files_%u.txt", arc4random()]];
        NSMutableString *fileListContent = [NSMutableString string];
        for (NSString *relPath in relativePaths) {
            NSString *trimmed = [relPath stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (trimmed.length > 0) {
                [fileListContent appendFormat:@"%@/%@\n", baseName, trimmed];
            }
        }
        [fileListContent writeToFile:fileListPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }

    NSMutableArray<NSString *> *args = [NSMutableArray arrayWithObjects:@"-czf", destinationTarGzPath, @"-C", parentDir, @"-T", fileListPath, nil];

    NSTask *tarTask = [[NSTask alloc] init];
    tarTask.executableURL = [NSURL fileURLWithPath:@"/usr/bin/tar"];
    tarTask.arguments = args;

    NSPipe *errPipe = [NSPipe pipe];
    tarTask.standardError = errPipe;

    @try {
        [tarTask launch];
        [tarTask waitUntilExit];
    } @catch (NSException *ex) {
        if (![fileListPath isEqualToString:@"/dev/null"]) {
            [fm removeItemAtPath:fileListPath error:nil];
        }
        if (error) {
            *error = [NSError errorWithDomain:FVArchiverErrorDomain
                                         code:-2
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to launch tar: %@", ex.reason]}];
        }
        return NO;
    }

    if (![fileListPath isEqualToString:@"/dev/null"]) {
        [fm removeItemAtPath:fileListPath error:nil];
    }

    if (tarTask.terminationStatus != 0) {
        NSData *errData = [[errPipe fileHandleForReading] readDataToEndOfFile];
        NSString *errMsg = [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding];
        if (error) {
            *error = [NSError errorWithDomain:FVArchiverErrorDomain
                                         code:tarTask.terminationStatus
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"tar failed: %@", errMsg]}];
        }
        return NO;
    }

    return YES;
}

+ (BOOL)extractArchiveAtPath:(NSString *)tarGzPath
          toDestinationPath:(NSString *)destinationDirPath
                      error:(NSError * _Nullable * _Nullable)error
{
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:tarGzPath]) {
        if (error) {
            *error = [NSError errorWithDomain:FVArchiverErrorDomain
                                         code:-3
                                     userInfo:@{NSLocalizedDescriptionKey: @"Tar file does not exist."}];
        }
        return NO;
    }

    if (![fm fileExistsAtPath:destinationDirPath]) {
        [fm createDirectoryAtPath:destinationDirPath withIntermediateDirectories:YES attributes:nil error:nil];
    }

    NSTask *tarTask = [[NSTask alloc] init];
    tarTask.executableURL = [NSURL fileURLWithPath:@"/usr/bin/tar"];
    tarTask.arguments = @[@"-xzf", tarGzPath, @"-C", destinationDirPath];

    NSPipe *errPipe = [NSPipe pipe];
    tarTask.standardError = errPipe;

    @try {
        [tarTask launch];
        [tarTask waitUntilExit];
    } @catch (NSException *ex) {
        if (error) {
            *error = [NSError errorWithDomain:FVArchiverErrorDomain
                                         code:-4
                                     userInfo:@{NSLocalizedDescriptionKey: ex.reason}];
        }
        return NO;
    }

    if (tarTask.terminationStatus != 0) {
        NSData *errData = [[errPipe fileHandleForReading] readDataToEndOfFile];
        NSString *errMsg = [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding];
        if (error) {
            *error = [NSError errorWithDomain:FVArchiverErrorDomain
                                         code:tarTask.terminationStatus
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"tar extraction failed: %@", errMsg]}];
        }
        return NO;
    }

    return YES;
}

@end
