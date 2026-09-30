//
//  FVArchiver.h
//  FlareVault
//
//  Handles directory packaging into tar.gz and unpacking.
//  Supports rsync-style exclusion patterns (e.g. node_modules, .venv, etc.).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const FVArchiverErrorDomain;

@interface FVDirectoryStats : NSObject
@property (nonatomic, assign) uint64_t totalSize;
@property (nonatomic, assign) NSUInteger fileCount;
@property (nonatomic, assign) NSUInteger dirCount;
@property (nonatomic, assign) NSUInteger excludedCount;
@property (nonatomic, copy, readonly) NSString *formattedSize;
@end

@interface FVArchiver : NSObject

/// Default built-in exclusion patterns for common development, cache, and buffer directories.
/// (node_modules, .venv, venv, __pycache__, .git, build, dist, etc.)
+ (NSArray<NSString *> *)defaultExcludePatterns;

/// Analyzes a directory using default exclusion patterns.
+ (FVDirectoryStats *)inspectDirectoryAtPath:(NSString *)dirPath;

/// Analyzes a directory and returns statistics (file count, total size), respecting exclusion patterns.
+ (FVDirectoryStats *)inspectDirectoryAtPath:(NSString *)dirPath
                             excludePatterns:(nullable NSArray<NSString *> *)excludePatterns;

/// Archives the specified directory into a compressed .tar.gz file using default exclusion patterns.
+ (BOOL)archiveDirectoryAtPath:(NSString *)sourceDirPath
             toDestinationPath:(NSString *)destinationTarGzPath
                         error:(NSError * _Nullable * _Nullable)error;

/// Archives the specified directory into a compressed .tar.gz file, skipping excludePatterns.
///
/// @param sourceDirPath Absolute path to directory to pack
/// @param destinationTarGzPath Absolute path to destination .tar.gz
/// @param excludePatterns Array of pattern strings (e.g. "node_modules", ".venv", "*.log")
/// @param error Output error pointer
/// @return YES on success, NO on failure
+ (BOOL)archiveDirectoryAtPath:(NSString *)sourceDirPath
             toDestinationPath:(NSString *)destinationTarGzPath
               excludePatterns:(nullable NSArray<NSString *> *)excludePatterns
                         error:(NSError * _Nullable * _Nullable)error;

/// Archives only a specific list of relative file paths from sourceDirPath into a .tar.gz archive.
/// Each path in relativeFiles is relative to sourceDirPath (e.g. "subdir/a.txt").
/// Inside the archive, files are packaged prefixed with [sourceDirPath lastPathComponent].
+ (BOOL)archiveDirectoryAtPath:(NSString *)sourceDirPath
                 relativeFiles:(NSArray<NSString *> *)relativePaths
             toDestinationPath:(NSString *)destinationTarGzPath
                         error:(NSError * _Nullable * _Nullable)error;

/// Extracts a .tar.gz archive into a destination directory.
+ (BOOL)extractArchiveAtPath:(NSString *)tarGzPath
          toDestinationPath:(NSString *)destinationDirPath
                      error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
