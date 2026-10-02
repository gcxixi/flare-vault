//
//  FVArchiver.m
//  FlareVault
//
//  Native in-process TAR+GZIP packaging and extraction engine.
//  Zero subprocess creation: executes entirely within process memory
//  using zlib and POSIX I/O without invoking /usr/bin/tar or NSTask.
//

#import "FVArchiver.h"
#import <zlib.h>
#import <fnmatch.h>
#import <sys/stat.h>
#import <sys/time.h>
#import <unistd.h>
#import <fcntl.h>

NSString * const FVArchiverErrorDomain = @"com.flarevault.archiver";

@implementation FVDirectoryStats
- (NSString *)formattedSize {
    return [NSByteCountFormatter stringFromByteCount:(long long)self.totalSize countStyle:NSByteCountFormatterCountStyleFile];
}
@end

#pragma pack(push, 1)
struct tar_header {
    char name[100];
    char mode[8];
    char uid[8];
    char gid[8];
    char size[12];
    char mtime[12];
    char chksum[8];
    char typeflag;
    char linkname[100];
    char magic[6];
    char version[2];
    char uname[32];
    char gname[32];
    char devmajor[8];
    char devminor[8];
    char prefix[155];
    char padding[12];
};
#pragma pack(pop)

static void tar_calc_checksum(struct tar_header *hdr) {
    memset(hdr->chksum, ' ', 8);
    unsigned int sum = 0;
    const unsigned char *p = (const unsigned char *)hdr;
    for (int i = 0; i < 512; i++) {
        sum += p[i];
    }
    snprintf(hdr->chksum, 8, "%06o", sum);
    hdr->chksum[6] = '\0';
    hdr->chksum[7] = ' ';
}

static BOOL write_tar_entry(gzFile gz, NSString *entryPath, NSString *diskPath, struct stat *st) {
    NSData *pathData = [entryPath dataUsingEncoding:NSUTF8StringEncoding];

    // GNU LongLink for entry paths >= 100 bytes ('L')
    if (pathData.length >= 100) {
        struct tar_header lhdr;
        memset(&lhdr, 0, sizeof(lhdr));
        strncpy(lhdr.name, "././@LongLink", 99);
        snprintf(lhdr.mode, 8, "%07o", 0);
        snprintf(lhdr.uid, 8, "%07o", 0);
        snprintf(lhdr.gid, 8, "%07o", 0);
        snprintf(lhdr.size, 12, "%011llo", (unsigned long long)(pathData.length + 1));
        snprintf(lhdr.mtime, 12, "%011lo", 0UL);
        lhdr.typeflag = 'L';
        memcpy(lhdr.magic, "ustar  ", 6);
        memcpy(lhdr.version, " ", 2);
        tar_calc_checksum(&lhdr);
        if (gzwrite(gz, &lhdr, 512) != 512) return NO;

        NSMutableData *nameBlock = [NSMutableData dataWithData:pathData];
        char zero = '\0';
        [nameBlock appendBytes:&zero length:1];
        NSUInteger padLen = (512 - (nameBlock.length % 512)) % 512;
        if (padLen > 0) {
            char padBuf[512] = {0};
            [nameBlock appendBytes:padBuf length:padLen];
        }
        if (gzwrite(gz, nameBlock.bytes, (unsigned int)nameBlock.length) != (int)nameBlock.length) return NO;
    }

    struct tar_header hdr;
    memset(&hdr, 0, sizeof(hdr));
    strncpy(hdr.name, [entryPath UTF8String], 99);
    snprintf(hdr.mode, 8, "%07o", (unsigned int)(st->st_mode & 0777));
    snprintf(hdr.uid, 8, "%07o", (unsigned int)st->st_uid);
    snprintf(hdr.gid, 8, "%07o", (unsigned int)st->st_gid);
    snprintf(hdr.mtime, 12, "%011lo", (unsigned long)st->st_mtime);
    memcpy(hdr.magic, "ustar\0", 6);
    memcpy(hdr.version, "00", 2);
    strncpy(hdr.uname, "staff", 31);
    strncpy(hdr.gname, "staff", 31);

    if (S_ISDIR(st->st_mode)) {
        if (![entryPath hasSuffix:@"/"]) {
            strncpy(hdr.name, [[entryPath stringByAppendingString:@"/"] UTF8String], 99);
        }
        hdr.typeflag = '5';
        snprintf(hdr.size, 12, "%011llo", 0ULL);
        tar_calc_checksum(&hdr);
        if (gzwrite(gz, &hdr, 512) != 512) return NO;
        return YES;
    } else if (S_ISLNK(st->st_mode)) {
        hdr.typeflag = '2';
        snprintf(hdr.size, 12, "%011llo", 0ULL);
        char linkBuf[1024] = {0};
        ssize_t linkLen = readlink([diskPath UTF8String], linkBuf, sizeof(linkBuf) - 1);
        if (linkLen > 0) {
            if (linkLen >= 100) {
                // GNU LongLink for link target ('K')
                struct tar_header khdr;
                memset(&khdr, 0, sizeof(khdr));
                strncpy(khdr.name, "././@LongLink", 99);
                snprintf(khdr.mode, 8, "%07o", 0);
                snprintf(khdr.size, 12, "%011llo", (unsigned long long)(linkLen + 1));
                khdr.typeflag = 'K';
                memcpy(khdr.magic, "ustar  ", 6);
                memcpy(khdr.version, " ", 2);
                tar_calc_checksum(&khdr);
                gzwrite(gz, &khdr, 512);

                NSMutableData *linkBlock = [NSMutableData dataWithBytes:linkBuf length:linkLen + 1];
                NSUInteger padLen = (512 - (linkBlock.length % 512)) % 512;
                if (padLen > 0) {
                    char padBuf[512] = {0};
                    [linkBlock appendBytes:padBuf length:padLen];
                }
                gzwrite(gz, linkBlock.bytes, (unsigned int)linkBlock.length);
            }
            strncpy(hdr.linkname, linkBuf, 99);
        }
        tar_calc_checksum(&hdr);
        if (gzwrite(gz, &hdr, 512) != 512) return NO;
        return YES;
    } else {
        // Regular file
        hdr.typeflag = '0';
        uint64_t fileSize = (uint64_t)st->st_size;
        snprintf(hdr.size, 12, "%011llo", (unsigned long long)fileSize);
        tar_calc_checksum(&hdr);
        if (gzwrite(gz, &hdr, 512) != 512) return NO;

        int fd = open([diskPath UTF8String], O_RDONLY);
        if (fd >= 0) {
            char chunk[65536];
            ssize_t nRead = 0;
            while ((nRead = read(fd, chunk, sizeof(chunk))) > 0) {
                if (gzwrite(gz, chunk, (unsigned int)nRead) != (int)nRead) {
                    close(fd);
                    return NO;
                }
            }
            close(fd);
        } else {
            // Cannot open file; pad empty bytes according to size
            char zeros[512] = {0};
            uint64_t remaining = fileSize;
            while (remaining > 0) {
                unsigned int toWrite = remaining > 512 ? 512 : (unsigned int)remaining;
                gzwrite(gz, zeros, toWrite);
                remaining -= toWrite;
            }
        }

        // Pad to 512-byte boundary
        NSUInteger padLen = (512 - (fileSize % 512)) % 512;
        if (padLen > 0) {
            char zeros[512] = {0};
            if (gzwrite(gz, zeros, (unsigned int)padLen) != (int)padLen) return NO;
        }
        return YES;
    }
}

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

static BOOL MatchesAnyPattern(NSString *name, NSString * _Nullable relPath, NSArray<NSString *> *patterns) {
    if (!patterns || patterns.count == 0) return NO;
    const char *cName = [name UTF8String];
    const char *cRel = relPath ? [relPath UTF8String] : cName;

    for (NSString *pat in patterns) {
        NSString *trimmed = [pat stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length == 0) continue;

        // Exact component match
        if ([name isEqualToString:trimmed]) return YES;
        if (relPath && [relPath isEqualToString:trimmed]) return YES;

        // Wildcard match
        if (fnmatch(trimmed.UTF8String, cName, 0) == 0) return YES;
        if (relPath && fnmatch(trimmed.UTF8String, cRel, 0) == 0) return YES;

        // Directory pattern with trailing slash (e.g. "cache/")
        if ([trimmed hasSuffix:@"/"]) {
            NSString *noSlash = [trimmed substringToIndex:trimmed.length - 1];
            if ([name isEqualToString:noSlash]) return YES;
            if (fnmatch(noSlash.UTF8String, cName, 0) == 0) return YES;
        }
    }
    return NO;
}

static NSString *RelativePathFromBase(NSString *fullPath, NSString *resolvedBase, NSString *rawBase) {
    NSString *resolvedFull = [fullPath stringByResolvingSymlinksInPath];
    NSString *rel = nil;
    if ([resolvedFull hasPrefix:resolvedBase]) {
        rel = [resolvedFull substringFromIndex:resolvedBase.length];
    } else if ([fullPath hasPrefix:rawBase]) {
        rel = [fullPath substringFromIndex:rawBase.length];
    } else {
        rel = fullPath.lastPathComponent;
    }
    if ([rel hasPrefix:@"/"]) {
        rel = [rel substringFromIndex:1];
    }
    return rel;
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
                                               errorHandler:^BOOL(NSURL * _Nonnull errUrl, NSError * _Nonnull err) {
        (void)errUrl; (void)err;
        return YES;
    }];

    uint64_t totalSize = 0;
    NSUInteger fileCount = 0;
    NSUInteger dirCount = 0;
    NSUInteger excludedCount = 0;
    NSString *resolvedDir = [dirPath stringByResolvingSymlinksInPath];

    for (NSURL *fileURL in enumerator) {
        NSString *fileName = fileURL.lastPathComponent;
        NSString *fullPath = fileURL.path;
        NSString *relPath = RelativePathFromBase(fullPath, resolvedDir, dirPath);
        if (relPath.length == 0) continue;

        NSNumber *isDir = nil;
        [fileURL getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];

        if (MatchesAnyPattern(fileName, relPath, excludePatterns)) {
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

    NSString *parentDest = [destinationTarGzPath stringByDeletingLastPathComponent];
    if (![fm fileExistsAtPath:parentDest]) {
        [fm createDirectoryAtPath:parentDest withIntermediateDirectories:YES attributes:nil error:nil];
    }

    gzFile gz = gzopen([destinationTarGzPath UTF8String], "wb");
    if (!gz) {
        if (error) {
            *error = [NSError errorWithDomain:FVArchiverErrorDomain
                                         code:-2
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to create archive file: %@", destinationTarGzPath]}];
        }
        return NO;
    }
    gzbuffer(gz, 65536);

    NSString *baseName = [sourceDirPath lastPathComponent];

    // 1. Write root directory entry
    struct stat rootSt;
    if (lstat([sourceDirPath UTF8String], &rootSt) == 0) {
        write_tar_entry(gz, baseName, sourceDirPath, &rootSt);
    }

    // 2. Enumerate items
    NSURL *rootURL = [NSURL fileURLWithPath:sourceDirPath];
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtURL:rootURL
                                 includingPropertiesForKeys:@[NSURLIsDirectoryKey, NSURLNameKey]
                                                    options:0
                                               errorHandler:^BOOL(NSURL * _Nonnull errUrl, NSError * _Nonnull err) {
        (void)errUrl; (void)err;
        return YES;
    }];

    NSString *resolvedSource = [sourceDirPath stringByResolvingSymlinksInPath];
    for (NSURL *fileURL in enumerator) {
        NSString *fileName = fileURL.lastPathComponent;
        NSString *fullPath = fileURL.path;
        NSString *relPath = RelativePathFromBase(fullPath, resolvedSource, sourceDirPath);
        if (relPath.length == 0) continue;

        NSNumber *isDirNum = nil;
        [fileURL getResourceValue:&isDirNum forKey:NSURLIsDirectoryKey error:nil];
        BOOL itemIsDir = [isDirNum boolValue];

        if (MatchesAnyPattern(fileName, relPath, excludePatterns)) {
            if (itemIsDir) {
                [enumerator skipDescendants];
            }
            continue;
        }

        struct stat st;
        if (lstat([fullPath UTF8String], &st) == 0) {
            NSString *entryName = [NSString stringWithFormat:@"%@/%@", baseName, relPath];
            if (!write_tar_entry(gz, entryName, fullPath, &st)) {
                gzclose(gz);
                [fm removeItemAtPath:destinationTarGzPath error:nil];
                if (error) {
                    *error = [NSError errorWithDomain:FVArchiverErrorDomain
                                                 code:-3
                                             userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed writing tar entry: %@", relPath]}];
                }
                return NO;
            }
        }
    }

    // 3. Write end of archive marker (1024 bytes of zeros)
    char endBuf[1024] = {0};
    gzwrite(gz, endBuf, 1024);
    gzclose(gz);

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

    NSString *parentDest = [destinationTarGzPath stringByDeletingLastPathComponent];
    if (![fm fileExistsAtPath:parentDest]) {
        [fm createDirectoryAtPath:parentDest withIntermediateDirectories:YES attributes:nil error:nil];
    }

    gzFile gz = gzopen([destinationTarGzPath UTF8String], "wb");
    if (!gz) {
        if (error) {
            *error = [NSError errorWithDomain:FVArchiverErrorDomain
                                         code:-2
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to create archive file: %@", destinationTarGzPath]}];
        }
        return NO;
    }
    gzbuffer(gz, 65536);

    NSString *baseName = [sourceDirPath lastPathComponent];

    // 1. Write root directory entry
    struct stat rootSt;
    if (lstat([sourceDirPath UTF8String], &rootSt) == 0) {
        write_tar_entry(gz, baseName, sourceDirPath, &rootSt);
    }

    // 2. Write each specified relative file
    for (NSString *relPath in relativePaths) {
        NSString *trimmed = [relPath stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length == 0) continue;

        NSString *fullPath = [sourceDirPath stringByAppendingPathComponent:trimmed];
        struct stat st;
        if (lstat([fullPath UTF8String], &st) == 0) {
            NSString *entryName = [NSString stringWithFormat:@"%@/%@", baseName, trimmed];
            if (!write_tar_entry(gz, entryName, fullPath, &st)) {
                gzclose(gz);
                [fm removeItemAtPath:destinationTarGzPath error:nil];
                if (error) {
                    *error = [NSError errorWithDomain:FVArchiverErrorDomain
                                                 code:-3
                                             userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed writing tar entry: %@", trimmed]}];
                }
                return NO;
            }
        }
    }

    // 3. Write end of archive marker (1024 bytes of zeros)
    char endBuf[1024] = {0};
    gzwrite(gz, endBuf, 1024);
    gzclose(gz);

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

    gzFile gz = gzopen([tarGzPath UTF8String], "rb");
    if (!gz) {
        if (error) {
            *error = [NSError errorWithDomain:FVArchiverErrorDomain
                                         code:-4
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to open archive: %@", tarGzPath]}];
        }
        return NO;
    }
    gzbuffer(gz, 65536);

    NSString *pendingLongName = nil;

    while (YES) {
        struct tar_header hdr;
        int nRead = gzread(gz, &hdr, 512);
        if (nRead == 0) break; // EOF reached cleanly
        if (nRead != 512) {
            gzclose(gz);
            if (error) {
                *error = [NSError errorWithDomain:FVArchiverErrorDomain
                                             code:-5
                                         userInfo:@{NSLocalizedDescriptionKey: @"Archive is corrupted or truncated."}];
            }
            return NO;
        }

        // Check for all-zero block
        BOOL allZero = YES;
        const char *raw = (const char *)&hdr;
        for (int i = 0; i < 512; i++) {
            if (raw[i] != 0) { allZero = NO; break; }
        }
        if (allZero) {
            // End of archive trailer block
            break;
        }

        if (hdr.typeflag == 'L') {
            // GNU LongLink
            uint64_t longSize = strtoull(hdr.size, NULL, 8);
            NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)longSize];
            if (gzread(gz, data.mutableBytes, (unsigned int)longSize) != (int)longSize) {
                gzclose(gz);
                if (error) {
                    *error = [NSError errorWithDomain:FVArchiverErrorDomain code:-6 userInfo:@{NSLocalizedDescriptionKey: @"Truncated long filename block."}];
                }
                return NO;
            }
            NSUInteger padLen = (512 - (longSize % 512)) % 512;
            if (padLen > 0) {
                char padBuf[512];
                gzread(gz, padBuf, (unsigned int)padLen);
            }
            const char *bytes = (const char *)data.bytes;
            pendingLongName = [NSString stringWithUTF8String:bytes];
            continue;
        }

        NSString *entryName = nil;
        if (pendingLongName.length > 0) {
            entryName = pendingLongName;
            pendingLongName = nil;
        } else {
            if (hdr.prefix[0] != '\0') {
                char prefixBuf[156] = {0};
                memcpy(prefixBuf, hdr.prefix, 155);
                char nameBuf[101] = {0};
                memcpy(nameBuf, hdr.name, 100);
                entryName = [NSString stringWithFormat:@"%s/%s", prefixBuf, nameBuf];
            } else {
                char nameBuf[101] = {0};
                memcpy(nameBuf, hdr.name, 100);
                entryName = [NSString stringWithUTF8String:nameBuf];
            }
        }

        if (!entryName || entryName.length == 0) continue;

        // Path safety check: prevent zip slip / relative traversal escaping destinationDirPath
        entryName = [entryName stringByStandardizingPath];
        if ([entryName hasPrefix:@"/"] || [entryName hasPrefix:@".."] || [entryName containsString:@"/../"]) {
            continue; // Skip dangerous paths
        }

        NSString *targetPath = [destinationDirPath stringByAppendingPathComponent:entryName];
        mode_t mode = (mode_t)strtoul(hdr.mode, NULL, 8);
        time_t mtime = (time_t)strtoul(hdr.mtime, NULL, 8);
        uint64_t fileSize = strtoull(hdr.size, NULL, 8);

        if (hdr.typeflag == '5' || [entryName hasSuffix:@"/"]) {
            [fm createDirectoryAtPath:targetPath withIntermediateDirectories:YES attributes:nil error:nil];
            chmod([targetPath UTF8String], mode ?: 0755);
        } else if (hdr.typeflag == '2') {
            unlink([targetPath UTF8String]);
            char linkBuf[101] = {0};
            memcpy(linkBuf, hdr.linkname, 100);
            symlink(linkBuf, [targetPath UTF8String]);
        } else {
            // Regular file
            NSString *parent = [targetPath stringByDeletingLastPathComponent];
            [fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:nil];

            int fd = open([targetPath UTF8String], O_WRONLY | O_CREAT | O_TRUNC, mode ?: 0644);
            if (fd >= 0) {
                uint64_t remaining = fileSize;
                char chunk[65536];
                while (remaining > 0) {
                    unsigned int toRead = remaining > sizeof(chunk) ? sizeof(chunk) : (unsigned int)remaining;
                    int n = gzread(gz, chunk, toRead);
                    if (n <= 0) break;
                    write(fd, chunk, n);
                    remaining -= (uint64_t)n;
                }
                close(fd);
            }

            NSUInteger padLen = (512 - (fileSize % 512)) % 512;
            if (padLen > 0) {
                char padBuf[512];
                gzread(gz, padBuf, (unsigned int)padLen);
            }

            if (mtime > 0) {
                struct timeval times[2];
                times[0].tv_sec = mtime;
                times[0].tv_usec = 0;
                times[1].tv_sec = mtime;
                times[1].tv_usec = 0;
                utimes([targetPath UTF8String], times);
            }
        }
    }

    gzclose(gz);
    return YES;
}

@end
