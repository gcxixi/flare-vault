//
//  FVArchiver.h
//  FlareVault
//
//  Handles directory packaging into tar.gz and unpacking.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const FVArchiverErrorDomain;

@interface FVDirectoryStats : NSObject
@property (nonatomic, assign) uint64_t totalSize;
@property (nonatomic, assign) NSUInteger fileCount;
@property (nonatomic, assign) NSUInteger dirCount;
@property (nonatomic, copy, readonly) NSString *formattedSize;
@end

@interface FVArchiver : NSObject

/// Analyzes a directory and returns statistics (file count, total size).
+ (FVDirectoryStats *)inspectDirectoryAtPath:(NSString *)dirPath;

/// Archives the specified directory into a compressed .tar.gz file.
///
/// @param sourceDirPath Absolute path to directory to pack
/// @param destinationTarGzPath Absolute path to destination .tar.gz
/// @param error Output error pointer
/// @return YES on success, NO on failure
+ (BOOL)archiveDirectoryAtPath:(NSString *)sourceDirPath
             toDestinationPath:(NSString *)destinationTarGzPath
                         error:(NSError * _Nullable * _Nullable)error;

/// Extracts a .tar.gz archive into a destination directory.
+ (BOOL)extractArchiveAtPath:(NSString *)tarGzPath
          toDestinationPath:(NSString *)destinationDirPath
                      error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
