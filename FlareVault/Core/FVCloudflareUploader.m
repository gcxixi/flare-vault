//
//  FVCloudflareUploader.m
//  FlareVault
//

#import "FVCloudflareUploader.h"
#import <CommonCrypto/CommonCrypto.h>
#import <CommonCrypto/CommonHMAC.h>

NSString * const FVCloudflareErrorDomain = @"com.flarevault.cloudflare";

@implementation FVCloudflareConfig
- (instancetype)init {
    self = [super init];
    if (self) {
        _remotePrefix = @"backups/";
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
    return copy;
}
@end

@interface FVCloudflareUploader () <NSURLSessionTaskDelegate>
@property (nonatomic, strong) FVCloudflareConfig *config;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURLSessionUploadTask *currentTask;
@property (nonatomic, copy, nullable) FVUploadProgressBlock progressBlock;
@property (nonatomic, copy, nullable) FVUploadCompletionBlock completionBlock;
@end

@implementation FVCloudflareUploader

- (instancetype)initWithConfig:(FVCloudflareConfig *)config {
    self = [super init];
    if (self) {
        _config = [config copy];
        NSURLSessionConfiguration *sessionConfig = [NSURLSessionConfiguration defaultSessionConfiguration];
        sessionConfig.timeoutIntervalForRequest = 600; // 10 minutes timeout for large backups
        sessionConfig.timeoutIntervalForResource = 3600;
        _session = [NSURLSession sessionWithConfiguration:sessionConfig delegate:self delegateQueue:[NSOperationQueue mainQueue]];
    }
    return self;
}

- (void)dealloc {
    [_session invalidateAndCancel];
}

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

- (void)uploadFileAtPath:(NSString *)localFilePath
         remoteObjectKey:(NSString *)remoteObjectKey
                progress:(nullable FVUploadProgressBlock)progress
              completion:(FVUploadCompletionBlock)completion
{
    self.progressBlock = progress;
    self.completionBlock = completion;

    if (![[NSFileManager defaultManager] fileExistsAtPath:localFilePath]) {
        NSError *err = [NSError errorWithDomain:FVCloudflareErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Upload file not found."}];
        completion(NO, nil, err);
        return;
    }

    if (self.config.accountId.length == 0 || self.config.bucketName.length == 0 ||
        self.config.accessKeyId.length == 0 || self.config.secretAccessKey.length == 0) {
        NSError *err = [NSError errorWithDomain:FVCloudflareErrorDomain code:-2 userInfo:@{NSLocalizedDescriptionKey: @"Cloudflare R2 configuration incomplete (Account ID, Bucket, Access Key and Secret Key required)."}];
        completion(NO, nil, err);
        return;
    }

    NSDictionary *fileAttrs = [[NSFileManager defaultManager] attributesOfItemAtPath:localFilePath error:nil];
    uint64_t fileSize = [fileAttrs fileSize];

    // 1. Calculate Host & Canonical URI
    NSString *host = nil;
    NSString *scheme = @"https";
    if (self.config.customEndpoint.length > 0) {
        NSURL *customURL = [NSURL URLWithString:self.config.customEndpoint];
        host = customURL.host ?: self.config.customEndpoint;
        if (customURL.scheme) scheme = customURL.scheme;
    } else {
        host = [NSString stringWithFormat:@"%@.r2.cloudflarestorage.com", self.config.accountId];
    }

    // Ensure remoteObjectKey is properly escaped
    NSMutableCharacterSet *allowedChars = [[NSCharacterSet URLPathAllowedCharacterSet] mutableCopy];
    [allowedChars removeCharactersInString:@"?#[]@!$&'()*+,;="];
    NSString *escapedKey = [remoteObjectKey stringByAddingPercentEncodingWithAllowedCharacters:allowedChars];
    if ([escapedKey hasPrefix:@"/"]) {
        escapedKey = [escapedKey substringFromIndex:1];
    }

    NSString *canonicalURI = [NSString stringWithFormat:@"/%@/%@", self.config.bucketName, escapedKey];
    NSURL *requestURL = [NSURL URLWithString:[NSString stringWithFormat:@"%@://%@%@", scheme, host, canonicalURI]];

    // 2. Prepare Timestamps (UTC)
    NSDate *now = [NSDate date];
    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    dateFormatter.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    dateFormatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    dateFormatter.dateFormat = @"yyyyMMdd'T'HHmmss'Z'";
    NSString *amzDate = [dateFormatter stringFromDate:now];

    dateFormatter.dateFormat = @"yyyyMMdd";
    NSString *dateStamp = [dateFormatter stringFromDate:now];

    // 3. Compute SHA256 of file
    NSString *payloadHash = Sha256ForFile(localFilePath);

    // 4. Construct Canonical Request
    NSString *canonicalHeaders = [NSString stringWithFormat:@"content-length:%llu\ncontent-type:application/octet-stream\nhost:%@\nx-amz-content-sha256:%@\nx-amz-date:%@\n",
                                  fileSize, host, payloadHash, amzDate];
    NSString *signedHeaders = @"content-length;content-type;host;x-amz-content-sha256;x-amz-date";

    NSString *canonicalRequest = [NSString stringWithFormat:@"PUT\n%@\n\n%@\n%@\n%@",
                                  canonicalURI, canonicalHeaders, signedHeaders, payloadHash];
    NSString *hashedCanonicalRequest = Sha256Hex([canonicalRequest dataUsingEncoding:NSUTF8StringEncoding]);

    // 5. String to Sign
    NSString *region = @"auto";
    NSString *service = @"s3";
    NSString *credentialScope = [NSString stringWithFormat:@"%@/%@/%@/aws4_request", dateStamp, region, service];
    NSString *stringToSign = [NSString stringWithFormat:@"AWS4-HMAC-SHA256\n%@\n%@\n%@", amzDate, credentialScope, hashedCanonicalRequest];

    // 6. Signature Derivation
    NSData *kSecret = [[NSString stringWithFormat:@"AWS4%@", self.config.secretAccessKey] dataUsingEncoding:NSUTF8StringEncoding];
    NSData *kDate = HmacSHA256(kSecret, [dateStamp dataUsingEncoding:NSUTF8StringEncoding]);
    NSData *kRegion = HmacSHA256(kDate, [region dataUsingEncoding:NSUTF8StringEncoding]);
    NSData *kService = HmacSHA256(kRegion, [service dataUsingEncoding:NSUTF8StringEncoding]);
    NSData *kSigning = HmacSHA256(kService, [@"aws4_request" dataUsingEncoding:NSUTF8StringEncoding]);

    NSData *signatureData = HmacSHA256(kSigning, [stringToSign dataUsingEncoding:NSUTF8StringEncoding]);
    NSMutableString *signatureHex = [NSMutableString stringWithCapacity:signatureData.length * 2];
    const uint8_t *sigBytes = signatureData.bytes;
    for (size_t i = 0; i < signatureData.length; i++) {
        [signatureHex appendFormat:@"%02x", sigBytes[i]];
    }

    NSString *authHeader = [NSString stringWithFormat:@"AWS4-HMAC-SHA256 Credential=%@/%@, SignedHeaders=%@, Signature=%@",
                            self.config.accessKeyId, credentialScope, signedHeaders, signatureHex];

    // 7. Build Request
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:requestURL];
    request.HTTPMethod = @"PUT";
    [request setValue:host forHTTPHeaderField:@"Host"];
    [request setValue:[NSString stringWithFormat:@"%llu", fileSize] forHTTPHeaderField:@"Content-Length"];
    [request setValue:@"application/octet-stream" forHTTPHeaderField:@"Content-Type"];
    [request setValue:amzDate forHTTPHeaderField:@"x-amz-date"];
    [request setValue:payloadHash forHTTPHeaderField:@"x-amz-content-sha256"];
    [request setValue:authHeader forHTTPHeaderField:@"Authorization"];

    // 8. Launch Upload Task
    NSURL *fileURL = [NSURL fileURLWithPath:localFilePath];
    self.currentTask = [self.session uploadTaskWithRequest:request fromFile:fileURL];
    [self.currentTask resume];
}

- (void)cancel {
    if (self.currentTask) {
        [self.currentTask cancel];
        self.currentTask = nil;
    }
}

- (void)testConnectionWithCompletion:(void (^)(BOOL reachable, NSString * _Nullable message, NSError * _Nullable error))completion {
    if (self.config.accountId.length == 0 || self.config.bucketName.length == 0 ||
        self.config.accessKeyId.length == 0 || self.config.secretAccessKey.length == 0) {
        NSError *err = [NSError errorWithDomain:FVCloudflareErrorDomain code:-2 userInfo:@{NSLocalizedDescriptionKey: @"Missing required Cloudflare credentials."}];
        completion(NO, nil, err);
        return;
    }

    NSString *host = [NSString stringWithFormat:@"%@.r2.cloudflarestorage.com", self.config.accountId];
    NSString *canonicalURI = [NSString stringWithFormat:@"/%@/", self.config.bucketName];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://%@%@?max-keys=1", host, canonicalURI]];

    NSDate *now = [NSDate date];
    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    dateFormatter.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    dateFormatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    dateFormatter.dateFormat = @"yyyyMMdd'T'HHmmss'Z'";
    NSString *amzDate = [dateFormatter stringFromDate:now];
    dateFormatter.dateFormat = @"yyyyMMdd";
    NSString *dateStamp = [dateFormatter stringFromDate:now];

    NSString *payloadHash = Sha256Hex([NSData data]);
    NSString *canonicalHeaders = [NSString stringWithFormat:@"host:%@\nx-amz-content-sha256:%@\nx-amz-date:%@\n", host, payloadHash, amzDate];
    NSString *signedHeaders = @"host;x-amz-content-sha256;x-amz-date";
    NSString *canonicalRequest = [NSString stringWithFormat:@"GET\n%@\nmax-keys=1\n%@\n%@\n%@", canonicalURI, canonicalHeaders, signedHeaders, payloadHash];
    NSString *hashedCanonicalRequest = Sha256Hex([canonicalRequest dataUsingEncoding:NSUTF8StringEncoding]);

    NSString *credentialScope = [NSString stringWithFormat:@"%@/auto/s3/aws4_request", dateStamp];
    NSString *stringToSign = [NSString stringWithFormat:@"AWS4-HMAC-SHA256\n%@\n%@\n%@", amzDate, credentialScope, hashedCanonicalRequest];

    NSData *kSecret = [[NSString stringWithFormat:@"AWS4%@", self.config.secretAccessKey] dataUsingEncoding:NSUTF8StringEncoding];
    NSData *kDate = HmacSHA256(kSecret, [dateStamp dataUsingEncoding:NSUTF8StringEncoding]);
    NSData *kRegion = HmacSHA256(kDate, [@"auto" dataUsingEncoding:NSUTF8StringEncoding]);
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

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"GET";
    [req setValue:host forHTTPHeaderField:@"Host"];
    [req setValue:amzDate forHTTPHeaderField:@"x-amz-date"];
    [req setValue:payloadHash forHTTPHeaderField:@"x-amz-content-sha256"];
    [req setValue:authHeader forHTTPHeaderField:@"Authorization"];

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
    if (self.progressBlock) {
        double p = totalBytesExpectedToSend > 0 ? ((double)totalBytesSent / (double)totalBytesExpectedToSend) : 1.0;
        self.progressBlock(p, totalBytesSent, totalBytesExpectedToSend);
    }
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(nullable NSError *)error
{
    (void)session;
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
