//
//  FVArchiver.m
//  FlareVault
//

#import "FVArchiver.h"

NSString * const FVArchiverErrorDomain = @"com.flarevault.archiver";

@implementation FVDirectoryStats
- (NSString *)formattedSize {
    return [NSByteCountFormatter stringFromByteCount:(long long)self.totalSize countStyle:NSByteCountFormatterCountStyleFile];
}
@end

@implementation FVArchiver

+ (FVDirectoryStats *)inspectDirectoryAtPath:(NSString *)dirPath {
    FVDirectoryStats *stats = [[FVDirectoryStats alloc] init];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *url = [NSURL fileURLWithPath:dirPath];

    NSDirectoryEnumerator *enumerator = [fm enumeratorAtURL:url
                                 includingPropertiesForKeys:@[NSURLFileSizeKey, NSURLIsDirectoryKey]
                                                    options:0
                                               errorHandler:^BOOL(NSURL * _Nonnull url, NSError * _Nonnull error) {
        (void)url; (void)error;
        return YES;
    }];

    uint64_t totalSize = 0;
    NSUInteger fileCount = 0;
    NSUInteger dirCount = 0;

    for (NSURL *fileURL in enumerator) {
        NSNumber *isDir = nil;
        [fileURL getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
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
    return stats;
}

+ (BOOL)archiveDirectoryAtPath:(NSString *)sourceDirPath
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

    NSTask *tarTask = [[NSTask alloc] init];
    tarTask.executableURL = [NSURL fileURLWithPath:@"/usr/bin/tar"];
    tarTask.arguments = @[@"-czf", destinationTarGzPath, @"-C", parentDir, baseName];

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
