// PinShot's updates on macOS, what update_win.c is on Windows. latest.json names the release's PinShot-mac.zip by its
// SHA-256 (mac_sha256) and the release key's signature of that (mac_signature: packaging/publish.ps1 signs it as it
// signs the Windows file). The zip is fetched into the data folder and checked against that SHA-256; then it is opened
// next to the app installed, its app checked once more as signed by AFK AI's Developer ID, put in the installed app's
// place, and started with --updated once this run has ended.
#import "mac_platform.h"
#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>
#import <spawn.h>
#import <stdatomic.h>
#import <sys/stat.h>

extern char **environ;
extern void mb_post(const char *, const char *, size_t, const uint8_t *, size_t);

// (the Team ID of "Developer ID Application: AFK AI, Inc. (D9AAN3VJK8)", what scripts/sign-mac.sh signs with)
#define PS_TEAM "D9AAN3VJK8"

static BOOL testing(void) { return getenv("PINSHOT_TEST") != NULL; }

static NSString *str(moonbit_bytes_t s) { return [NSString stringWithUTF8String:(const char *)s] ?: @""; }

static void tell(NSString *json, NSData *body) {
  NSData *j = [json dataUsingEncoding:NSUTF8StringEncoding];
  dispatch_async(dispatch_get_main_queue(), ^{
    mb_post("ps", j.bytes, j.length, body.bytes, body.length);
  });
}

static void told_failed(NSString *why) {
  tell([NSString stringWithFormat:@"{\"do\":\"fetched\",\"ok\":false,\"error\":\"%@\"}", why], nil);
}

static NSURL *updateDir(void) {
  NSURL *dir = [ps_app_data() URLByAppendingPathComponent:@"update" isDirectory:YES];
  [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
  return dir;
}

// The app this run is, when it is one: a dev build run as a bare binary has nothing to update.
static NSString *installedApp(void) {
  NSString *path = NSBundle.mainBundle.bundlePath;
  return [path.pathExtension isEqualToString:@"app"] ? path : nil;
}

static SecRequirementRef ourSigner(void) {
  // (in a test run with PINSHOT_TEST_ANY_SIGNER, any valid signature: tests sign ad hoc)
  if (testing() && getenv("PINSHOT_TEST_ANY_SIGNER")) return NULL;
  SecRequirementRef req = NULL;
  SecRequirementCreateWithString(CFSTR("anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and "
                                       "certificate leaf[field.1.2.840.113635.100.6.1.13] and "
                                       "certificate leaf[subject.OU] = \"" PS_TEAM "\""),
                                 kSecCSDefaultFlags, &req);
  return req;
}

// The app at `path` signed by AFK AI's Developer ID, all of it.
static BOOL signedByUs(NSString *path) {
  SecStaticCodeRef code = NULL;
  SecRequirementRef req = ourSigner();
  BOOL ok = (req || (testing() && getenv("PINSHOT_TEST_ANY_SIGNER"))) &&
            SecStaticCodeCreateWithPath((__bridge CFURLRef)[NSURL fileURLWithPath:path], kSecCSDefaultFlags, &code) ==
                errSecSuccess &&
            SecStaticCodeCheckValidity(code, kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode,
                                       req) == errSecSuccess;
  if (req) CFRelease(req);
  if (code) CFRelease(code);
  return ok;
}

// 0 updates itself here, 3 not at all: a dev build, signed by no one or ad hoc, is not replaced by a release.
// (this run's own signature as the kernel checked it: no reading the bundle through again)
int32_t ps_install_kind(void) {
  if (!installedApp()) return 3;
  if (testing()) return getenv("PINSHOT_UPDATE_URL") ? 0 : 3;
  SecCodeRef me = NULL;
  SecRequirementRef req = ourSigner();
  BOOL ok = req && SecCodeCopySelf(kSecCSDefaultFlags, &me) == errSecSuccess &&
            SecCodeCheckValidity(me, kSecCSDefaultFlags, req) == errSecSuccess;
  if (req) CFRelease(req);
  if (me) CFRelease(me);
  return ok ? 0 : 3;
}

static NSString *stagingFor(NSString *app) {
  return [app.stringByDeletingLastPathComponent stringByAppendingPathComponent:@".PinShot-update"];
}

void ps_update_cleanup(void) {
  NSFileManager *fm = NSFileManager.defaultManager;
  [fm removeItemAtURL:[ps_app_data() URLByAppendingPathComponent:@"update" isDirectory:YES] error:nil];
  NSString *app = installedApp();
  if (app) [fm removeItemAtPath:stagingFor(app) error:nil];
}

moonbit_bytes_t ps_update_path(moonbit_bytes_t name) {
  NSString *n = str(name);
  if (!n.length || [n containsString:@"/"] || [n containsString:@".."] || [n hasPrefix:@"."]) return ps_data(nil);
  return ps_string([updateDir() URLByAppendingPathComponent:n].path);
}

double ps_epoch_s(void) { return NSDate.date.timeIntervalSince1970; }

int32_t ps_idle_ms(void) {
  double s = CGEventSourceSecondsSinceLastEventType(kCGEventSourceStateCombinedSessionState, kCGAnyInputEventType);
  if (!(s >= 0)) return 0;
  return s * 1000 >= 0x7FFFFFFF ? 0x7FFFFFFF : (int32_t)(s * 1000);
}

void ps_update_ticks(int32_t first_ms, int32_t every_ms) {
  static dispatch_source_t timer;
  if (every_ms <= 0) {
    if (timer) dispatch_source_cancel(timer);
    timer = nil;
    return;
  }
  if (timer) return;
  timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
  dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)first_ms * NSEC_PER_MSEC),
                            (uint64_t)every_ms * NSEC_PER_MSEC, NSEC_PER_SEC);
  dispatch_source_set_event_handler(timer, ^{
    mb_post("ps", "{\"do\":\"update-tick\"}", 20, NULL, 0);
  });
  dispatch_resume(timer);
}

static int hexDigit(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

static BOOL fromHex(const char *hex, uint8_t *out, size_t n) {
  if (strlen(hex) != n * 2) return NO;
  for (size_t i = 0; i < n; i++) {
    int a = hexDigit(hex[i * 2]), b = hexDigit(hex[i * 2 + 1]);
    if (a < 0 || b < 0) return NO;
    out[i] = (uint8_t)(a * 16 + b);
  }
  return YES;
}

static NSString *hexOf(const uint8_t *d, size_t n) {
  NSMutableString *s = [NSMutableString stringWithCapacity:n * 2];
  for (size_t i = 0; i < n; i++) [s appendFormat:@"%02x", d[i]];
  return s;
}

// The release key (ECDSA P-256), update_win.c's release_key_x and _y: 04 || x || y.
static const uint8_t release_key[65] = {
    0x04, 0x5d, 0x53, 0x16, 0xca, 0x6a, 0xab, 0xf5, 0xd9, 0x01, 0x26, 0x5a, 0x15, 0xbe, 0x52, 0xf4, 0x80,
    0xa7, 0x64, 0x54, 0xc0, 0x52, 0x0f, 0xad, 0x96, 0xb1, 0x75, 0x01, 0x82, 0xb7, 0x72, 0xd3, 0x5e,
    0xcd, 0x71, 0xe3, 0xc7, 0xfe, 0x26, 0xb5, 0xf7, 0xa6, 0x11, 0xbe, 0xd0, 0xb7, 0xbb, 0xa7, 0x48,
    0xf3, 0x09, 0x8d, 0x3c, 0xae, 0x9d, 0xd0, 0xb8, 0x29, 0xe2, 0x5c, 0x18, 0x58, 0x86, 0x6b, 0xbc};

static void derInt(NSMutableData *out, const uint8_t *v) {
  size_t i = 0;
  while (i < 31 && v[i] == 0) i++;
  size_t n = 32 - i;
  BOOL pad = v[i] & 0x80;
  uint8_t head[3] = {0x02, (uint8_t)(n + (pad ? 1 : 0)), 0x00};
  [out appendBytes:head length:pad ? 3 : 2];
  [out appendBytes:v + i length:n];
}

// Whether `sig` (hex, r then s) is the release key's signature of "pinshot-update\n<version>\n<setup_sha256>\n
// <exe_sha256>\n", as update_win.c checks it. A test run may name a key of its own (PINSHOT_TEST_RELEASE_KEY, hex of
// 04 || x || y): its runs are the tester's, started with what environment it chose.
int32_t ps_release_signed(moonbit_bytes_t version, moonbit_bytes_t setup_sha, moonbit_bytes_t exe_sha, moonbit_bytes_t sig) {
  uint8_t rs[64], test_key[65];
  if (!fromHex((const char *)sig, rs, 64)) return 0;
  const uint8_t *key_bytes = release_key;
  const char *t = testing() ? getenv("PINSHOT_TEST_RELEASE_KEY") : NULL;
  if (t) {
    if (!fromHex(t, test_key, 65)) return 0;
    key_bytes = test_key;
  }
  NSString *msg = [NSString stringWithFormat:@"pinshot-update\n%@\n%@\n%@\n", str(version), str(setup_sha), str(exe_sha)];
  NSMutableData *body = [NSMutableData data];
  derInt(body, rs);
  derInt(body, rs + 32);
  NSMutableData *der = [NSMutableData data];
  uint8_t head[2] = {0x30, (uint8_t)body.length};
  [der appendBytes:head length:2];
  [der appendData:body];
  NSDictionary *attrs = @{
    (id)kSecAttrKeyType : (id)kSecAttrKeyTypeECSECPrimeRandom,
    (id)kSecAttrKeyClass : (id)kSecAttrKeyClassPublic,
    (id)kSecAttrKeySizeInBits : @256,
  };
  SecKeyRef key = SecKeyCreateWithData((__bridge CFDataRef)[NSData dataWithBytes:key_bytes length:65],
                                       (__bridge CFDictionaryRef)attrs, NULL);
  if (!key) return 0;
  BOOL ok = SecKeyVerifySignature(key, kSecKeyAlgorithmECDSASignatureMessageX962SHA256,
                                  (__bridge CFDataRef)[msg dataUsingEncoding:NSUTF8StringEncoding],
                                  (__bridge CFDataRef)der, NULL);
  CFRelease(key);
  return ok ? 1 : 0;
}

static NSString *fileSha(NSString *path) {
  NSFileHandle *f = [NSFileHandle fileHandleForReadingAtPath:path];
  if (!f) return nil;
  CC_SHA256_CTX ctx;
  CC_SHA256_Init(&ctx);
  for (;;) {
    @autoreleasepool {
      NSData *d = [f readDataUpToLength:1 << 20 error:nil];
      if (!d.length) break;
      CC_SHA256_Update(&ctx, d.bytes, (CC_LONG)d.length);
    }
  }
  [f closeFile];
  uint8_t digest[32];
  CC_SHA256_Final(digest, &ctx);
  return hexOf(digest, 32);
}

#define SMALL_MOST (1024 * 1024)

static atomic_int fetch_busy;

@interface PSFetch : NSObject <NSURLSessionDataDelegate>
@property(copy) NSString *path, *sha;
@property NSFileHandle *out;
@property NSMutableData *body;
@property(copy) NSString *why;
@property int64_t got, total;
@property double lastTold;
@property CC_SHA256_CTX digestCtx;
@end

@implementation PSFetch
- (void)URLSession:(NSURLSession *)session
              dataTask:(NSURLSessionDataTask *)task
    didReceiveResponse:(NSURLResponse *)response
     completionHandler:(void (^)(NSURLSessionResponseDisposition))done {
  NSInteger status = [(NSHTTPURLResponse *)response statusCode];
  if (status != 200) {
    self.why = [NSString stringWithFormat:@"http %ld", (long)status];
    done(NSURLSessionResponseCancel);
    return;
  }
  self.total = response.expectedContentLength > 0 ? response.expectedContentLength : 0;
  if (self.path) {
    NSString *part = [self.path stringByAppendingString:@".part"];
    [NSFileManager.defaultManager removeItemAtPath:part error:nil];
    if (![NSFileManager.defaultManager createFileAtPath:part contents:nil attributes:nil] ||
        !(self.out = [NSFileHandle fileHandleForWritingAtPath:part])) {
      self.why = @"cannot write";
      done(NSURLSessionResponseCancel);
      return;
    }
    CC_SHA256_CTX h;
    CC_SHA256_Init(&h);
    self.digestCtx = h;
  } else {
    self.body = [NSMutableData data];
  }
  done(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
  if (self.why) return;
  self.got += data.length;
  if (self.path) {
    if (![self.out writeData:data error:nil]) {
      self.why = @"cannot write";
      [task cancel];
      return;
    }
    CC_SHA256_CTX h = self.digestCtx;
    CC_SHA256_Update(&h, data.bytes, (CC_LONG)data.length);
    self.digestCtx = h;
    double now = ps_now_ms();
    if (now - self.lastTold >= 200) {
      self.lastTold = now;
      tell([NSString stringWithFormat:@"{\"do\":\"fetching\",\"got\":%lld,\"total\":%lld}", self.got, self.total], nil);
    }
  } else {
    if (self.body.length + data.length > SMALL_MOST) {
      self.why = @"too large";
      [task cancel];
      return;
    }
    [self.body appendData:data];
  }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
  NSString *why = self.why;
  if (!why && error) why = @"network unavailable";
  if (!why && self.total && self.got != self.total) why = @"network unavailable";
  NSString *part = self.path ? [self.path stringByAppendingString:@".part"] : nil;
  if (self.out) [self.out closeFile];
  if (!why && self.path) {
    uint8_t digest[32];
    CC_SHA256_CTX h = self.digestCtx;
    CC_SHA256_Final(digest, &h);
    if ([hexOf(digest, 32) caseInsensitiveCompare:self.sha] != NSOrderedSame) why = @"checksum";
    else {
      [NSFileManager.defaultManager removeItemAtPath:self.path error:nil];
      if (![NSFileManager.defaultManager moveItemAtPath:part toPath:self.path error:nil]) why = @"cannot write";
    }
  }
  if (why && part) [NSFileManager.defaultManager removeItemAtPath:part error:nil];
  [session finishTasksAndInvalidate];
  atomic_store(&fetch_busy, 0);
  if (why) told_failed(why);
  else if (self.path) tell(@"{\"do\":\"fetched\",\"ok\":true,\"file\":true}", nil);
  else tell(@"{\"do\":\"fetched\",\"ok\":true,\"status\":200}", self.body);
}
@end

static BOOL urlAllowed(NSURL *u) {
  if ([u.scheme isEqualToString:@"https"]) return YES;
  return testing() && [u.scheme isEqualToString:@"http"] && [u.host isEqualToString:@"127.0.0.1"];
}

int32_t ps_fetch(moonbit_bytes_t url, moonbit_bytes_t path, moonbit_bytes_t sha256, moonbit_bytes_t agent) {
  uint8_t sha_bytes[32];
  NSString *p = str(path);
  if (p.length && !fromHex((const char *)sha256, sha_bytes, 32)) return 0;
  NSURL *u = [NSURL URLWithString:str(url)];
  if (!u || !urlAllowed(u)) return 0;
  int idle = 0;
  if (!atomic_compare_exchange_strong(&fetch_busy, &idle, 1)) return 0;
  PSFetch *f = [PSFetch new];
  f.path = p.length ? p : nil;
  f.sha = str(sha256);
  NSURLSessionConfiguration *c = NSURLSessionConfiguration.ephemeralSessionConfiguration;
  c.timeoutIntervalForRequest = 30;
  c.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
  c.HTTPAdditionalHeaders = @{@"User-Agent" : str(agent)};
  NSOperationQueue *q = [NSOperationQueue new];
  q.maxConcurrentOperationCount = 1;
  NSURLSession *s = [NSURLSession sessionWithConfiguration:c delegate:f delegateQueue:q];
  [[s dataTaskWithURL:u] resume];
  return 1;
}

static int runTool(NSString *tool, NSArray<NSString *> *args) {
  NSTask *t = [NSTask new];
  t.executableURL = [NSURL fileURLWithPath:tool];
  t.arguments = args;
  t.standardOutput = NSFileHandle.fileHandleWithNullDevice;
  t.standardError = NSFileHandle.fileHandleWithNullDevice;
  if (![t launchAndReturnError:nil]) return -1;
  [t waitUntilExit];
  return t.terminationStatus;
}

// Puts the release at `path` (a zip: PinShot.app) in the installed app's place, and ends this run for it: 1 done (not
// returned: this run has ended), -1 not the release signed (its SHA-256, or its app's code signature), 0 it could not.
int32_t ps_swap_exe(moonbit_bytes_t path, moonbit_bytes_t sha256) {
  NSFileManager *fm = NSFileManager.defaultManager;
  NSString *zip = str(path), *app = installedApp();
  NSString *sha = fileSha(zip);
  if (!sha || [sha caseInsensitiveCompare:str(sha256)] != NSOrderedSame) {
    [fm removeItemAtPath:zip error:nil];
    return -1;
  }
  if (!app || access(app.stringByDeletingLastPathComponent.fileSystemRepresentation, W_OK) != 0) return 0;
  // (opened next to the app installed: the same volume, so each move below is a rename)
  NSString *staging = stagingFor(app);
  [fm removeItemAtPath:staging error:nil];
  if (![fm createDirectoryAtPath:staging withIntermediateDirectories:NO attributes:nil error:nil]) return 0;
  NSString *fresh = [staging stringByAppendingPathComponent:@"PinShot.app"];
  if (runTool(@"/usr/bin/ditto", @[ @"-x", @"-k", zip, staging ]) != 0 || ![fm fileExistsAtPath:fresh]) {
    [fm removeItemAtPath:staging error:nil];
    return 0;
  }
  NSString *id_now = NSBundle.mainBundle.bundleIdentifier;
  NSString *id_fresh = [NSBundle bundleWithPath:fresh].bundleIdentifier;
  if (!signedByUs(fresh) || !id_fresh || (id_now && ![id_now isEqualToString:id_fresh])) {
    [fm removeItemAtPath:staging error:nil];
    [fm removeItemAtPath:zip error:nil];
    return -1;
  }
  NSString *old = [staging stringByAppendingPathComponent:@"PinShot-old.app"];
  if (rename(app.fileSystemRepresentation, old.fileSystemRepresentation) != 0) {
    [fm removeItemAtPath:staging error:nil];
    return 0;
  }
  if (rename(fresh.fileSystemRepresentation, app.fileSystemRepresentation) != 0) {
    rename(old.fileSystemRepresentation, app.fileSystemRepresentation);
    [fm removeItemAtPath:staging error:nil];
    return 0;
  }
  [fm removeItemAtPath:zip error:nil];
  // (started once this run has ended: before, it would find this run's session lock and only hand it a capture)
  // (a test run's next run is started as itself, with its environment: open would start it as anyone's)
  NSString *script = testing() ? @"while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; rm -rf \"$3\"; "
                                 @"exec \"$2/Contents/MacOS/PinShot\" --updated"
                               : @"while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; rm -rf \"$3\"; "
                                 @"/usr/bin/open -n \"$2\" --args --updated";
  NSString *pid = [NSString stringWithFormat:@"%d", getpid()];
  const char *argv[] = {"/bin/sh", "-c", script.UTF8String, "pinshot-update", pid.UTF8String, app.fileSystemRepresentation,
                        staging.fileSystemRepresentation, NULL};
  posix_spawnattr_t attr;
  posix_spawnattr_init(&attr);
  posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID);
  pid_t child;
  int r = posix_spawn(&child, "/bin/sh", NULL, &attr, (char *const *)argv, environ);
  posix_spawnattr_destroy(&attr);
  if (r != 0) {
    // (the new app is in place either way: started by hand if this fails, it is what runs)
    runTool(@"/usr/bin/open", @[ @"-n", app, @"--args", @"--updated" ]);
  }
  exit(0);
  return 1;
}
