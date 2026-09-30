//
//  FVCloudflareUploader.m
//  FlareVault
//

#import "FVCloudflareUploader.h"
#import <CommonCrypto/CommonCrypto.h>
#import <CommonCrypto/CommonHMAC.h>

NSString * const FVCloudflareErrorDomain = @"com.flarevault.cloudflare";

static const uint64_t kS3MinPartSize = 5 * 1024 * 1024; // 5 MB

@implementation FVCloudflareConfig

- (instancetype)init {
    self = [super init];
    if (self) {
        _remotePrefix = @"backups/";
        _lazyUploadEnabled = NO;
        _lazyMinIntervalSeconds = 2.0;
        _lazyMaxIntervalSeconds = 8.0;
        _lazyChunkJitter = YES;
        _lazyBurstProbability = 0.20;
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    FVCloudflareConfig *copy = [[[self class] allocWithZone:zone] init];
    copy.accountId = self.accountId;
    copy.bucketName = self.bucketName;
    copy.accessKeyId = self.accessKeyId;
    copy.secretAccessKey = self.secretAccessKey;
    copy.remotePrefix = self.remotePrefix;
    copy.customEndpoint = self.customEndpoint;
    copy.lazyUploadEnabled = self.lazyUploadEnabled;
    copy.lazyMinIntervalSeconds = self.lazyMinIntervalSeconds;
    copy.lazyMaxIntervalSeconds = self.lazyMaxIntervalSeconds;
    copy.lazyChunkJitter = self.lazyChunkJitter;
    copy.lazyBurstProbability = self.lazyBurstProbability;
    return copy;
}

@end

@interface FVCloudflareUploader () <NSURLSessionTaskDelegate>
@property (nonatomic, strong) FVCloudflareConfig *config;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong, nullable) NSURLSessionTask *currentTask;
@property (nonatomic, assign) BOOL isCancelled;
@property (nonatomic, copy, nullable) NSString *activeMultipartUploadId;
@property (nonatomic, copy, nullable) NSString *activeMultipartObjectKey;

@property (nonatomic, copy, nullable) FVUploadProgressBlock progressBlock;
@property (nonatomic, copy, nullable) FVUploadCompletionBlock completionBlock;
@end

@implementation FVCloudflareUploader

- (instancetype)initWithConfig:(FVCloudflareConfig *)config {
    self = [super init];
    if (self) {
        _config = [config copy];
        NSURLSessionConfiguration *sessionConfig = [NSURLSessionConfiguration defaultSessionConfiguration];
        sessionConfig.timeoutIntervalForRequest = 600;
        sessionConfig.timeoutIntervalForResource = 3600;
        _session = [NSURLSession sessionWithConfiguration:sessionConfig delegate:self delegateQueue:nil];
    }
    return self;
}

- (void)dealloc {
    [_session invalidateAndCancel];
}

#pragma mark - Helper Cryptographic Functions

static NSData *HmacSHA256(NSData *key, NSData *data) {
    uint8_t hmac[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, key.bytes, key.length, data.bytes, data.length, hmac);
    return [NSData dataWithBytes:hmac length:sizeof(hmac)];
}

static NSString *Sha256Hex(NSData *data) {
    uint8_t hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, hash);
    NSMutableString *hex = [NSMutableString stringWithCapacity:sizeof(hash) * 2];
    for (size_t i = 0; i < sizeof(hash); i++) {
        [hex appendFormat:@"%02x", hash[i]];
    }
    return hex;
}

static NSString *Sha256ForFile(NSString *filePath) {
    NSFileHandle *file = [NSFileHandle fileHandleForReadingAtPath:filePath];
    if (!file) return @"UNSIGNED-PAYLOAD";

    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    while (YES) {
        @autoreleasepool {
            NSData *chunk = [file readDataOfLength:1024 * 1024];
            if (chunk.length == 0) break;
            CC_SHA256_Update(&ctx, chunk.bytes, (CC_LONG)chunk.length);
        }
    }
    [file closeFile];

    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &ctx);
    NSMutableString *hex = [NSMutableString stringWithCapacity:sizeof(digest) * 2];
    for (size_t i = 0; i < sizeof(digest); i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return hex;
}

- (void)logStatus:(NSString *)msg {
    if (self.statusLogBlock) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.statusLogBlock(msg);
        });
    }
}

#pragma mark - SigV4 Request Construction

- (NSMutableURLRequest *)buildSigV4RequestWithMethod:(NSString *)httpMethod
                                        canonicalURI:(NSString *)canonicalURI
                                      canonicalQuery:(NSString *)canonicalQuery
                                                host:(NSString *)host
                                              scheme:(NSString *)scheme
                                         payloadData:(NSData *)payloadData
                                         contentType:(NSString *)contentType
{
    NSDate *now = [NSDate date];
    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    dateFormatter.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    dateFormatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    dateFormatter.dateFormat = @"yyyyMMdd'T'HHmmss'Z'";
    NSString *amzDate = [dateFormatter stringFromDate:now];

    dateFormatter.dateFormat = @"yyyyMMdd";
    NSString *dateStamp = [dateFormatter stringFromDate:now];

    NSString *payloadHash = Sha256Hex(payloadData ?: [NSData data]);
    uint64_t payloadLen = payloadData ? payloadData.length : 0;

    NSString *canonicalHeaders = nil;
    NSString *signedHeaders = nil;
    if ([httpMethod isEqualToString:@"PUT"] || [httpMethod isEqualToString:@"POST"]) {
        canonicalHeaders = [NSString stringWithFormat:@"content-length:%llu\ncontent-type:%@\nhost:%@\nx-amz-content-sha256:%@\nx-amz-date:%@\n",
                            payloadLen, contentType, host, payloadHash, amzDate];
        signedHeaders = @"content-length;content-type;host;x-amz-content-sha256;x-amz-date";
    } else {
        canonicalHeaders = [NSString stringWithFormat:@"host:%@\nx-amz-content-sha256:%@\nx-amz-date:%@\n",
                            host, payloadHash, amzDate];
        signedHeaders = @"host;x-amz-content-sha256;x-amz-date";
    }

    NSString *canonicalRequest = [NSString stringWithFormat:@"%@\n%@\n%@\n%@\n%@\n%@",
                                  httpMethod, canonicalURI, canonicalQuery ?: @"", canonicalHeaders, signedHeaders, payloadHash];
    NSString *hashedCanonicalRequest = Sha256Hex([canonicalRequest dataUsingEncoding:NSUTF8StringEncoding]);

    NSString *region = @"auto";
    NSString *service = @"s3";
    NSString *credentialScope = [NSString stringWithFormat:@"%@/%@/%@/aws4_request", dateStamp, region, service];
    NSString *stringToSign = [NSString stringWithFormat:@"AWS4-HMAC-SHA256\n%@\n%@\n%@", amzDate, credentialScope, hashedCanonicalRequest];

    NSData *kSecret = [[NSString stringWithFormat:@"AWS4%@", self.config.secretAccessKey] dataUsingEncoding:NSUTF8StringEncoding];
    NSData *kDate = HmacSHA256(kSecret, [dateStamp dataUsingEncoding:NSUTF8StringEncoding]);
    NSData *kRegion = HmacSHA256(kDate, [region dataUsingEncoding:NSUTF8StringEncoding]);
    NSData *kService = HmacSHA256(kRegion, [@"s3" dataUsingEncoding:NSUTF8StringEncoding]);
    NSData *kSigning = HmacSHA256(kService, [@"aws4_request" dataUsingEncoding:NSUTF8StringEncoding]);

    NSData *signatureData = HmacSHA256(kSigning, [stringToSign dataUsingEncoding:NSUTF8StringEncoding]);
    NSMutableString *signatureHex = [NSMutableString stringWithCapacity:signatureData.length * 2];
    const uint8_t *sigBytes = signatureData.bytes;
    for (size_t i = 0; i < signatureData.length; i++) {
        [signatureHex appendFormat:@"%02x", sigBytes[i]];
    }

    NSString *authHeader = [NSString stringWithFormat:@"AWS4-HMAC-SHA256 Credential=%@/%@, SignedHeaders=%@, Signature=%@",
                            self.config.accessKeyId, credentialScope, signedHeaders, signatureHex];

    NSString *urlString = [NSString stringWithFormat:@"%@://%@%@", scheme, host, canonicalURI];
    if (canonicalQuery.length > 0) {
        urlString = [urlString stringByAppendingFormat:@"?%@", canonicalQuery];
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    req.HTTPMethod = httpMethod;
    [req setValue:host forHTTPHeaderField:@"Host"];
    if ([httpMethod isEqualToString:@"PUT"] || [httpMethod isEqualToString:@"POST"]) {
        [req setValue:[NSString stringWithFormat:@"%llu", payloadLen] forHTTPHeaderField:@"Content-Length"];
        [req setValue:contentType forHTTPHeaderField:@"Content-Type"];
    }
    [req setValue:amzDate forHTTPHeaderField:@"x-amz-date"];
    [req setValue:payloadHash forHTTPHeaderField:@"x-amz-content-sha256"];
    [req setValue:authHeader forHTTPHeaderField:@"Authorization"];
    if (payloadData && payloadData.length > 0) {
        req.HTTPBody = payloadData;
    }

    return req;
}

#pragma mark - Main Upload Entry

- (void)uploadFileAtPath:(NSString *)localFilePath
         remoteObjectKey:(NSString *)remoteObjectKey
                progress:(nullable FVUploadProgressBlock)progress
              completion:(FVUploadCompletionBlock)completion
{
    self.isCancelled = NO;
    self.progressBlock = progress;
    self.completionBlock = completion;

    if (![[NSFileManager defaultManager] fileExistsAtPath:localFilePath]) {
        NSError *err = [NSError errorWithDomain:FVCloudflareErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Upload file not found."}];
        completion(NO, nil, err);
        return;
    }

    if (self.config.accountId.length == 0 || self.config.bucketName.length == 0 ||
        self.config.accessKeyId.length == 0 || self.config.secretAccessKey.length == 0) {
        NSError *err = [NSError errorWithDomain:FVCloudflareErrorDomain code:-2 userInfo:@{NSLocalizedDescriptionKey: @"Cloudflare R2 configuration incomplete."}];
        completion(NO, nil, err);
        return;
    }

    NSDictionary *fileAttrs = [[NSFileManager defaultManager] attributesOfItemAtPath:localFilePath error:nil];
    uint64_t fileSize = [fileAttrs fileSize];

    if (self.config.lazyUploadEnabled && fileSize >= kS3MinPartSize) {
        // Run Lazy / Stochastic Multipart Upload
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            [self executeLazyMultipartUploadForFile:localFilePath
                                           fileSize:fileSize
                                    remoteObjectKey:remoteObjectKey];
        });
    } else {
        // Run Standard Single PUT (or small file lazy jitter)
        if (self.config.lazyUploadEnabled) {
            double initialJitter = 1.0 + (arc4random_uniform(2000) / 1000.0); // 1.0s - 3.0s
            [self logStatus:[NSString stringWithFormat:@"[惰性上传] 小体积文件 (<5MB)，随机延迟 %.2f 秒后发起调用...", initialJitter]];
            [NSThread sleepForTimeInterval:initialJitter];
        }
        [self executeStandardSinglePutForFile:localFilePath
                                     fileSize:fileSize
                              remoteObjectKey:remoteObjectKey];
    }
}

#pragma mark - Standard Single PUT Upload

- (void)executeStandardSinglePutForFile:(NSString *)localFilePath
                               fileSize:(uint64_t)fileSize
                        remoteObjectKey:(NSString *)remoteObjectKey
{
    NSString *host = nil;
    NSString *scheme = @"https";
    if (self.config.customEndpoint.length > 0) {
        NSURL *customURL = [NSURL URLWithString:self.config.customEndpoint];
        host = customURL.host ?: self.config.customEndpoint;
        if (customURL.scheme) scheme = customURL.scheme;
    } else {
        host = [NSString stringWithFormat:@"%@.r2.cloudflarestorage.com", self.config.accountId];
    }

    NSMutableCharacterSet *allowedChars = [[NSCharacterSet URLPathAllowedCharacterSet] mutableCopy];
    [allowedChars removeCharactersInString:@"?#[]@!$&'()*+,;="];
    NSString *escapedKey = [remoteObjectKey stringByAddingPercentEncodingWithAllowedCharacters:allowedChars];
    if ([escapedKey hasPrefix:@"/"]) escapedKey = [escapedKey substringFromIndex:1];

    NSString *canonicalURI = [NSString stringWithFormat:@"/%@/%@", self.config.bucketName, escapedKey];

    NSDate *now = [NSDate date];
    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    dateFormatter.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    dateFormatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    dateFormatter.dateFormat = @"yyyyMMdd'T'HHmmss'Z'";
    NSString *amzDate = [dateFormatter stringFromDate:now];
    dateFormatter.dateFormat = @"yyyyMMdd";
    NSString *dateStamp = [dateFormatter stringFromDate:now];

    NSString *payloadHash = Sha256ForFile(localFilePath);

    NSString *canonicalHeaders = [NSString stringWithFormat:@"content-length:%llu\ncontent-type:application/octet-stream\nhost:%@\nx-amz-content-sha256:%@\nx-amz-date:%@\n",
                                  fileSize, host, payloadHash, amzDate];
    NSString *signedHeaders = @"content-length;content-type;host;x-amz-content-sha256;x-amz-date";

    NSString *canonicalRequest = [NSString stringWithFormat:@"PUT\n%@\n\n%@\n%@\n%@",
                                  canonicalURI, canonicalHeaders, signedHeaders, payloadHash];
    NSString *hashedCanonicalRequest = Sha256Hex([canonicalRequest dataUsingEncoding:NSUTF8StringEncoding]);

    NSString *region = @"auto";
    NSString *service = @"s3";
    NSString *credentialScope = [NSString stringWithFormat:@"%@/%@/%@/aws4_request", dateStamp, region, service];
    NSString *stringToSign = [NSString stringWithFormat:@"AWS4-HMAC-SHA256\n%@\n%@\n%@", amzDate, credentialScope, hashedCanonicalRequest];

    NSData *kSecret = [[NSString stringWithFormat:@"AWS4%@", self.config.secretAccessKey] dataUsingEncoding:NSUTF8StringEncoding];
    NSData *kDate = HmacSHA256(kSecret, [dateStamp dataUsingEncoding:NSUTF8StringEncoding]);
    NSData *kRegion = HmacSHA256(kDate, [region dataUsingEncoding:NSUTF8StringEncoding]);
    NSData *kService = HmacSHA256(kRegion, [@"s3" dataUsingEncoding:NSUTF8StringEncoding]);
    NSData *kSigning = HmacSHA256(kService, [@"aws4_request" dataUsingEncoding:NSUTF8StringEncoding]);

    NSData *signatureData = HmacSHA256(kSigning, [stringToSign dataUsingEncoding:NSUTF8StringEncoding]);
    NSMutableString *signatureHex = [NSMutableString stringWithCapacity:signatureData.length * 2];
    const uint8_t *sigBytes = signatureData.bytes;
    for (size_t i = 0; i < signatureData.length; i++) {
        [signatureHex appendFormat:@"%02x", sigBytes[i]];
    }

    NSString *authHeader = [NSString stringWithFormat:@"AWS4-HMAC-SHA256 Credential=%@/%@, SignedHeaders=%@, Signature=%@",
                            self.config.accessKeyId, credentialScope, signedHeaders, signatureHex];

    NSURL *requestURL = [NSURL URLWithString:[NSString stringWithFormat:@"%@://%@%@", scheme, host, canonicalURI]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:requestURL];
    request.HTTPMethod = @"PUT";
    [request setValue:host forHTTPHeaderField:@"Host"];
    [request setValue:[NSString stringWithFormat:@"%llu", fileSize] forHTTPHeaderField:@"Content-Length"];
    [request setValue:@"application/octet-stream" forHTTPHeaderField:@"Content-Type"];
    [request setValue:amzDate forHTTPHeaderField:@"x-amz-date"];
    [request setValue:payloadHash forHTTPHeaderField:@"x-amz-content-sha256"];
    [request setValue:authHeader forHTTPHeaderField:@"Authorization"];

    NSURL *fileURL = [NSURL fileURLWithPath:localFilePath];
    self.currentTask = [self.session uploadTaskWithRequest:request fromFile:fileURL];
    [self.currentTask resume];
}

#pragma mark - Lazy / Stochastic Multipart Upload (惰性随机多段上传)

- (void)executeLazyMultipartUploadForFile:(NSString *)localFilePath
                                 fileSize:(uint64_t)fileSize
                          remoteObjectKey:(NSString *)remoteObjectKey
{
    [self logStatus:@"[惰性上传] 正在初始化 Cloudflare R2 多段随机调用会话..."];

    NSString *host = [NSString stringWithFormat:@"%@.r2.cloudflarestorage.com", self.config.accountId];
    NSString *scheme = @"https";
    if (self.config.customEndpoint.length > 0) {
        NSURL *u = [NSURL URLWithString:self.config.customEndpoint];
        host = u.host ?: self.config.customEndpoint;
        if (u.scheme) scheme = u.scheme;
    }

    NSMutableCharacterSet *allowedChars = [[NSCharacterSet URLPathAllowedCharacterSet] mutableCopy];
    [allowedChars removeCharactersInString:@"?#[]@!$&'()*+,;="];
    NSString *escapedKey = [remoteObjectKey stringByAddingPercentEncodingWithAllowedCharacters:allowedChars];
    if ([escapedKey hasPrefix:@"/"]) escapedKey = [escapedKey substringFromIndex:1];
    NSString *canonicalURI = [NSString stringWithFormat:@"/%@/%@", self.config.bucketName, escapedKey];

    // 1. Initiate Multipart Upload: POST /bucket/key?uploads
    NSMutableURLRequest *initReq = [self buildSigV4RequestWithMethod:@"POST"
                                                        canonicalURI:canonicalURI
                                                      canonicalQuery:@"uploads="
                                                                host:host
                                                              scheme:scheme
                                                         payloadData:[NSData data]
                                                         contentType:@"application/octet-stream"];

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSString *uploadId = nil;
    __block NSError *initErr = nil;

    self.currentTask = [self.session dataTaskWithRequest:initReq completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            initErr = error;
        } else {
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
            if (http.statusCode >= 200 && http.statusCode < 300) {
                NSString *xml = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"<UploadId>([^<]+)</UploadId>" options:0 error:nil];
                NSTextCheckingResult *m = [re firstMatchInString:xml options:0 range:NSMakeRange(0, xml.length)];
                if (m && m.numberOfRanges > 1) {
                    uploadId = [xml substringWithRange:[m rangeAtIndex:1]];
                }
            } else {
                initErr = [NSError errorWithDomain:FVCloudflareErrorDomain code:http.statusCode
                                          userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Initiate multipart failed: HTTP %ld", (long)http.statusCode]}];
            }
        }
        dispatch_semaphore_signal(sem);
    }];
    [self.currentTask resume];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

    if (self.isCancelled) return;
    if (!uploadId || initErr) {
        [self logStatus:[NSString stringWithFormat:@"[错误] 初始化多段上传失败: %@", initErr.localizedDescription]];
        if (self.completionBlock) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.completionBlock(NO, nil, initErr);
            });
        }
        return;
    }

    self.activeMultipartUploadId = uploadId;
    self.activeMultipartObjectKey = remoteObjectKey;
    [self logStatus:[NSString stringWithFormat:@"[惰性上传] 成功创建会话 (UploadId: %@)", [uploadId substringToIndex:MIN((NSUInteger)12, uploadId.length)]]];

    // 2. Compute dynamic chunk boundaries
    NSMutableArray<NSValue *> *chunkRanges = [NSMutableArray array];
    uint64_t offset = 0;
    while (offset < fileSize) {
        uint64_t remaining = fileSize - offset;
        uint64_t chunkSize = kS3MinPartSize; // base 5MB

        if (self.config.lazyChunkJitter && remaining > kS3MinPartSize * 2) {
            // Random variation: 5MB + 0~3MB
            uint32_t jitter = arc4random_uniform(3 * 1024 * 1024);
            chunkSize += jitter;
        }

        if (remaining - chunkSize < kS3MinPartSize) {
            // Avoid leaving a tail part smaller than 5MB
            chunkSize = remaining;
        }

        [chunkRanges addObject:[NSValue valueWithRange:NSMakeRange((NSUInteger)offset, (NSUInteger)chunkSize)]];
        offset += chunkSize;
    }

    NSUInteger totalParts = chunkRanges.count;
    [self logStatus:[NSString stringWithFormat:@"[惰性上传] 数据已拆解为 %lu 个随机长度分块，开始离散时序上传...", (unsigned long)totalParts]];

    NSFileHandle *fileHandle = [NSFileHandle fileHandleForReadingAtPath:localFilePath];
    NSMutableArray<NSDictionary *> *completedParts = [NSMutableArray array];
    uint64_t totalBytesUploaded = 0;

    for (NSUInteger idx = 0; idx < totalParts; idx++) {
        if (self.isCancelled) break;

        NSRange range = [chunkRanges[idx] rangeValue];
        [fileHandle seekToFileOffset:range.location];
        NSData *chunkData = [fileHandle readDataOfLength:range.length];
        int partNumber = (int)(idx + 1);

        NSString *partSizeStr = [NSByteCountFormatter stringFromByteCount:chunkData.length countStyle:NSByteCountFormatterCountStyleFile];
        [self logStatus:[NSString stringWithFormat:@"[惰性上传] 正在调用上传分块 %d/%lu (体积: %@)...", partNumber, (unsigned long)totalParts, partSizeStr]];

        // Query params in alphabetical order: partNumber before uploadId
        NSString *canonicalQuery = [NSString stringWithFormat:@"partNumber=%d&uploadId=%@", partNumber, uploadId];
        NSMutableURLRequest *partReq = [self buildSigV4RequestWithMethod:@"PUT"
                                                            canonicalURI:canonicalURI
                                                          canonicalQuery:canonicalQuery
                                                                    host:host
                                                                  scheme:scheme
                                                             payloadData:chunkData
                                                             contentType:@"application/octet-stream"];

        dispatch_semaphore_t partSem = dispatch_semaphore_create(0);
        __block NSString *etag = nil;
        __block NSError *partErr = nil;

        self.currentTask = [self.session dataTaskWithRequest:partReq completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            (void)data;
            if (error) {
                partErr = error;
            } else {
                NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
                if (http.statusCode >= 200 && http.statusCode < 300) {
                    etag = http.allHeaderFields[@"ETag"] ?: http.allHeaderFields[@"etag"];
                } else {
                    partErr = [NSError errorWithDomain:FVCloudflareErrorDomain code:http.statusCode
                                              userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Upload part %d failed: HTTP %ld", partNumber, (long)http.statusCode]}];
                }
            }
            dispatch_semaphore_signal(partSem);
        }];
        [self.currentTask resume];
        dispatch_semaphore_wait(partSem, DISPATCH_TIME_FOREVER);

        if (self.isCancelled) break;

        if (!etag || partErr) {
            [fileHandle closeFile];
            [self abortMultipartUpload:uploadId canonicalURI:canonicalURI host:host scheme:scheme];
            [self logStatus:[NSString stringWithFormat:@"[错误] 分块 %d 上传失败: %@", partNumber, partErr.localizedDescription]];
            if (self.completionBlock) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.completionBlock(NO, nil, partErr);
                });
            }
            return;
        }

        [completedParts addObject:@{@"part": @(partNumber), @"etag": etag}];
        totalBytesUploaded += chunkData.length;

        if (self.progressBlock) {
            double p = (double)totalBytesUploaded / (double)fileSize;
            dispatch_async(dispatch_get_main_queue(), ^{
                self.progressBlock(p, totalBytesUploaded, fileSize);
            });
        }

        // If not last part, apply Stochastic Jitter / Randomized Silence Interval
        if (idx < totalParts - 1 && !self.isCancelled) {
            // Check for burst probability (e.g. 20% burst)
            BOOL isBurst = (arc4random_uniform(100) < (uint32_t)(self.config.lazyBurstProbability * 100));
            double sleepSeconds = 0.0;

            if (isBurst) {
                sleepSeconds = 0.2 + (arc4random_uniform(400) / 1000.0); // 0.2s - 0.6s micro pause
                [self logStatus:[NSString stringWithFormat:@"[惰性上传] 块 %d/%lu 上传完成 (ETag: %@)，触发模拟突发调用，迅速连接下一块...", partNumber, (unsigned long)totalParts, etag]];
            } else {
                double minSec = MAX(0.5, self.config.lazyMinIntervalSeconds);
                double maxSec = MAX(minSec, self.config.lazyMaxIntervalSeconds);
                double diff = maxSec - minSec;
                double randFraction = (arc4random_uniform(1000) / 1000.0);
                sleepSeconds = minSec + (diff * randFraction);

                [self logStatus:[NSString stringWithFormat:@"[惰性上传] 块 %d/%lu 上传完成，呈现随机间歇，静默休眠 %.2f 秒...", partNumber, (unsigned long)totalParts, sleepSeconds]];
            }

            // Interruptible sleep loop checking cancellation every 100ms
            int loops = (int)(sleepSeconds / 0.1);
            for (int l = 0; l < loops; l++) {
                if (self.isCancelled) break;
                [NSThread sleepForTimeInterval:0.1];
            }
        }
    }

    [fileHandle closeFile];

    if (self.isCancelled) {
        [self abortMultipartUpload:uploadId canonicalURI:canonicalURI host:host scheme:scheme];
        [self logStatus:@"[惰性上传] 任务已取消，已安全中止并清理远端多段缓存。"];
        return;
    }

    // 3. Complete Multipart Upload: POST /bucket/key?uploadId=xyz
    [self logStatus:[NSString stringWithFormat:@"[惰性上传] 全部 %lu 个随机分块传输完毕，正在发起多段完整性合并...", (unsigned long)totalParts]];

    NSMutableString *xmlBody = [NSMutableString stringWithString:@"<CompleteMultipartUpload>\n"];
    for (NSDictionary *d in completedParts) {
        [xmlBody appendFormat:@"  <Part>\n    <PartNumber>%@</PartNumber>\n    <ETag>%@</ETag>\n  </Part>\n", d[@"part"], d[@"etag"]];
    }
    [xmlBody appendString:@"</CompleteMultipartUpload>"];
    NSData *completePayload = [xmlBody dataUsingEncoding:NSUTF8StringEncoding];

    NSString *completeQuery = [NSString stringWithFormat:@"uploadId=%@", uploadId];
    NSMutableURLRequest *completeReq = [self buildSigV4RequestWithMethod:@"POST"
                                                            canonicalURI:canonicalURI
                                                          canonicalQuery:completeQuery
                                                                    host:host
                                                                  scheme:scheme
                                                             payloadData:completePayload
                                                             contentType:@"application/xml"];

    dispatch_semaphore_t compSem = dispatch_semaphore_create(0);
    __block BOOL compSuccess = NO;
    __block NSError *compErr = nil;

    self.currentTask = [self.session dataTaskWithRequest:completeReq completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        (void)data;
        if (error) {
            compErr = error;
        } else {
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
            if (http.statusCode >= 200 && http.statusCode < 300) {
                compSuccess = YES;
            } else {
                compErr = [NSError errorWithDomain:FVCloudflareErrorDomain code:http.statusCode
                                          userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Complete multipart failed: HTTP %ld", (long)http.statusCode]}];
            }
        }
        dispatch_semaphore_signal(compSem);
    }];
    [self.currentTask resume];
    dispatch_semaphore_wait(compSem, DISPATCH_TIME_FOREVER);

    self.activeMultipartUploadId = nil;
    self.activeMultipartObjectKey = nil;

    if (compSuccess) {
        NSString *remoteUrl = [NSString stringWithFormat:@"%@://%@%@", scheme, host, canonicalURI];
        [self logStatus:@"[惰性上传] 🎉 远端多段合并成功！所有分块已组装为完整加密归档。"];
        if (self.completionBlock) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.completionBlock(YES, remoteUrl, nil);
            });
        }
    } else {
        [self logStatus:[NSString stringWithFormat:@"[错误] 多段合并失败: %@", compErr.localizedDescription]];
        if (self.completionBlock) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.completionBlock(NO, nil, compErr);
            });
        }
    }
}

- (void)abortMultipartUpload:(NSString *)uploadId
                canonicalURI:(NSString *)canonicalURI
                        host:(NSString *)host
                      scheme:(NSString *)scheme
{
    if (!uploadId) return;
    NSString *abortQuery = [NSString stringWithFormat:@"uploadId=%@", uploadId];
    NSMutableURLRequest *abortReq = [self buildSigV4RequestWithMethod:@"DELETE"
                                                         canonicalURI:canonicalURI
                                                       canonicalQuery:abortQuery
                                                                 host:host
                                                               scheme:scheme
                                                          payloadData:[NSData data]
                                                          contentType:@"application/octet-stream"];
    [[self.session dataTaskWithRequest:abortReq] resume];
}

- (void)cancel {
    self.isCancelled = YES;
    if (self.currentTask) {
        [self.currentTask cancel];
        self.currentTask = nil;
    }
    if (self.activeMultipartUploadId && self.activeMultipartObjectKey) {
        NSString *host = [NSString stringWithFormat:@"%@.r2.cloudflarestorage.com", self.config.accountId];
        NSString *canonicalURI = [NSString stringWithFormat:@"/%@/%@", self.config.bucketName, self.activeMultipartObjectKey];
        [self abortMultipartUpload:self.activeMultipartUploadId canonicalURI:canonicalURI host:host scheme:@"https"];
        self.activeMultipartUploadId = nil;
        self.activeMultipartObjectKey = nil;
    }
}

#pragma mark - Connectivity Test

- (void)testConnectionWithCompletion:(void (^)(BOOL reachable, NSString * _Nullable message, NSError * _Nullable error))completion {
    if (self.config.accountId.length == 0 || self.config.bucketName.length == 0 ||
        self.config.accessKeyId.length == 0 || self.config.secretAccessKey.length == 0) {
        NSError *err = [NSError errorWithDomain:FVCloudflareErrorDomain code:-2 userInfo:@{NSLocalizedDescriptionKey: @"Missing required Cloudflare credentials."}];
        completion(NO, nil, err);
        return;
    }

    NSString *host = [NSString stringWithFormat:@"%@.r2.cloudflarestorage.com", self.config.accountId];
    NSString *canonicalURI = [NSString stringWithFormat:@"/%@/", self.config.bucketName];
    NSMutableURLRequest *req = [self buildSigV4RequestWithMethod:@"GET"
                                                    canonicalURI:canonicalURI
                                                  canonicalQuery:@"max-keys=1"
                                                            host:host
                                                          scheme:@"https"
                                                     payloadData:[NSData data]
                                                     contentType:@"application/octet-stream"];

    [[self.session dataTaskWithRequest:req completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        if (error) {
            completion(NO, nil, error);
            return;
        }
        NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
        if (httpResp.statusCode >= 200 && httpResp.statusCode < 300) {
            completion(YES, [NSString stringWithFormat:@"Connected to bucket '%@' successfully!", self.config.bucketName], nil);
        } else {
            NSString *errBody = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
            NSString *msg = [NSString stringWithFormat:@"HTTP %ld: %@", (long)httpResp.statusCode, errBody];
            NSError *httpErr = [NSError errorWithDomain:FVCloudflareErrorDomain code:httpResp.statusCode userInfo:@{NSLocalizedDescriptionKey: msg}];
            completion(NO, msg, httpErr);
        }
    }] resume];
}

#pragma mark - NSURLSessionTaskDelegate

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
   didSendBodyData:(int64_t)bytesSent
    totalBytesSent:(int64_t)totalBytesSent
totalBytesExpectedToSend:(int64_t)totalBytesExpectedToSend
{
    (void)session; (void)task; (void)bytesSent;
    if (self.progressBlock && !self.config.lazyUploadEnabled) {
        double p = totalBytesExpectedToSend > 0 ? ((double)totalBytesSent / (double)totalBytesExpectedToSend) : 1.0;
        self.progressBlock(p, totalBytesSent, totalBytesExpectedToSend);
    }
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(nullable NSError *)error
{
    (void)session;
    if (self.config.lazyUploadEnabled) {
        // Handled by synchronous multipart coordinator
        return;
    }

    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)task.response;
    if (error) {
        if (self.completionBlock) {
            self.completionBlock(NO, nil, error);
            self.completionBlock = nil;
        }
        return;
    }

    if (httpResponse.statusCode >= 200 && httpResponse.statusCode < 300) {
        NSString *remoteUrl = task.originalRequest.URL.absoluteString;
        if (self.completionBlock) {
            self.completionBlock(YES, remoteUrl, nil);
            self.completionBlock = nil;
        }
    } else {
        NSString *errMsg = [NSString stringWithFormat:@"Upload failed with HTTP status %ld", (long)httpResponse.statusCode];
        NSError *statusError = [NSError errorWithDomain:FVCloudflareErrorDomain code:httpResponse.statusCode userInfo:@{NSLocalizedDescriptionKey: errMsg}];
        if (self.completionBlock) {
            self.completionBlock(NO, nil, statusError);
            self.completionBlock = nil;
        }
    }
}

@end
