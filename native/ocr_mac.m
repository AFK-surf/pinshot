#import "mac_platform.h"
#import <ImageIO/ImageIO.h>
#import <Vision/Vision.h>
#import <stdatomic.h>

extern void mb_post(const char *, const char *, size_t, const uint8_t *, size_t);

typedef struct {
  const char *why;
  NSString *lang;
  NSString *text;
  NSString *boxes;
  int lines;
  double ms;
} OcrOut;

static BOOL unspaced(unichar c) {
  return (c >= 0x2E80 && c <= 0x9FFF) || (c >= 0xF900 && c <= 0xFAFF) || (c >= 0xFE30 && c <= 0xFE4F) ||
         (c >= 0xFF00 && c <= 0xFFEF) || (c >= 0x3000 && c <= 0x303F);
}

static BOOL isWs(unichar c) {
  return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == 0x00A0 || c == 0x3000;
}

static double clamp01(double v) { return v < 0.0 ? 0.0 : (v > 1.0 ? 1.0 : v); }

static void ocrRun(NSData *png, OcrOut *o, BOOL wantBoxes) {
  double t0 = ps_now_ms();
  o->why = "bad-picture";
  o->lang = @"";
  o->text = @"";
  o->boxes = @"";
  o->lines = 0;
  o->ms = 0;
  CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)png, NULL);
  CGImageRef image = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
  if (src)
    CFRelease(src);
  if (!image)
    return;
  VNRecognizeTextRequest *req = [VNRecognizeTextRequest new];
  req.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
  req.usesLanguageCorrection = YES;
  req.recognitionLanguages = @[ @"zh-Hans", @"en-US" ];
  if (@available(macOS 13.0, *))
    req.automaticallyDetectsLanguage = NO;
  VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image options:@{}];
  NSError *err = nil;
  BOOL ok = [handler performRequests:@[ req ] error:&err];
  CGImageRelease(image);
  if (!ok) {
    o->why = "failed";
    return;
  }
  o->why = "";
  NSMutableArray<VNRecognizedTextObservation *> *obs = [NSMutableArray array];
  for (VNRecognizedTextObservation *r in req.results)
    if ([r topCandidates:1].firstObject.string.length)
      [obs addObject:r];
  [obs sortUsingComparator:^NSComparisonResult(VNRecognizedTextObservation *a, VNRecognizedTextObservation *b) {
    CGFloat ay = CGRectGetMidY(a.boundingBox), by = CGRectGetMidY(b.boundingBox);
    return ay > by ? NSOrderedAscending : ay < by ? NSOrderedDescending : NSOrderedSame;
  }];
  NSMutableString *all = [NSMutableString string];
  NSMutableString *boxes = wantBoxes ? [NSMutableString string] : nil;
  NSUInteger i = 0;
  BOOL cjk = NO;
  while (i < obs.count) {
    VNRecognizedTextObservation *first = obs[i];
    CGRect band = first.boundingBox;
    NSMutableArray<VNRecognizedTextObservation *> *row = [NSMutableArray arrayWithObject:first];
    NSUInteger j = i + 1;
    for (; j < obs.count; j++) {
      CGFloat mid = CGRectGetMidY(obs[j].boundingBox);
      if (mid < CGRectGetMinY(band) || mid > CGRectGetMaxY(band))
        break;
      [row addObject:obs[j]];
    }
    [row sortUsingComparator:^NSComparisonResult(VNRecognizedTextObservation *a, VNRecognizedTextObservation *b) {
      CGFloat ax = CGRectGetMinX(a.boundingBox), bx = CGRectGetMinX(b.boundingBox);
      return ax < bx ? NSOrderedAscending : ax > bx ? NSOrderedDescending : NSOrderedSame;
    }];
    NSMutableString *line = [NSMutableString string];
    int lineIdx = o->lines;
    for (VNRecognizedTextObservation *r in row) {
      VNRecognizedText *cand = [r topCandidates:1].firstObject;
      NSString *raw = cand.string;
      NSUInteger len = raw.length;
      if (!len)
        continue;
      if (!wantBoxes) {
        NSString *s = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!s.length)
          continue;
        if (line.length && !(unspaced([line characterAtIndex:line.length - 1]) && unspaced([s characterAtIndex:0])))
          [line appendString:@" "];
        [line appendString:s];
        continue;
      }
      NSUInteger pos = 0;
      BOOL firstInObs = YES;
      while (pos < len) {
        NSUInteger wsStart = pos;
        while (pos < len && isWs([raw characterAtIndex:pos]))
          pos++;
        BOOL hadWs = (pos > wsStart);
        if (pos >= len)
          break;
        NSRange tokRange;
        if (unspaced([raw characterAtIndex:pos])) {
          tokRange = [raw rangeOfComposedCharacterSequenceAtIndex:pos];
        } else {
          NSUInteger start = pos;
          while (pos < len) {
            unichar ch = [raw characterAtIndex:pos];
            if (isWs(ch) || unspaced(ch))
              break;
            NSRange seq = [raw rangeOfComposedCharacterSequenceAtIndex:pos];
            pos = NSMaxRange(seq);
          }
          tokRange = NSMakeRange(start, pos - start);
        }
        pos = NSMaxRange(tokRange);
        NSString *tok = [raw substringWithRange:tokRange];
        if (!tok.length)
          continue;
        BOOL bothUnspaced =
            line.length > 0 && unspaced([line characterAtIndex:line.length - 1]) && unspaced([tok characterAtIndex:0]);
        int space = (line.length > 0 && (hadWs || (firstInObs && !bothUnspaced))) ? 1 : 0;
        firstInObs = NO;
        if (space)
          [line appendString:@" "];
        [line appendString:tok];

        VNRectangleObservation *boxObs = [cand boundingBoxForRange:tokRange error:nil];
        CGRect bb = boxObs ? boxObs.boundingBox : r.boundingBox;
        double nx = clamp01(bb.origin.x);
        double ny = clamp01(1.0 - (bb.origin.y + bb.size.height));
        double bw = clamp01(bb.size.width);
        double bh = clamp01(bb.size.height);
        if (nx + bw > 1.0)
          bw = 1.0 - nx;
        if (ny + bh > 1.0)
          bh = 1.0 - ny;
        NSString *clean = [[[tok stringByReplacingOccurrencesOfString:@"\t" withString:@" "]
            stringByReplacingOccurrencesOfString:@"\r"
                                      withString:@" "] stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
        [boxes appendFormat:@"%d\t%d\t%.5f\t%.5f\t%.5f\t%.5f\t%@\n", lineIdx, space, nx, ny, bw, bh, clean];
      }
    }
    for (NSUInteger k = 0; !cjk && k < line.length; k++)
      cjk = unspaced([line characterAtIndex:k]);
    if (line.length) {
      if (all.length)
        [all appendString:@"\n"];
      [all appendString:line];
      o->lines++;
    }
    i = j;
  }
  o->text = all;
  o->boxes = boxes ?: @"";
  o->lang = o->lines ? (cjk ? @"zh-Hans" : @"en-US") : @"";
  o->ms = ps_now_ms() - t0;
}

static NSData *nextPng;
static int nextId;
static BOOL running;

static void ocrLoop(void) {
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    for (;;) {
      NSData *png;
      int id;
      @synchronized([NSProcessInfo class]) {
        png = nextPng;
        id = nextId;
        nextPng = nil;
        if (!png) {
          running = NO;
          return;
        }
      }
      @autoreleasepool {
        OcrOut o;
        ocrRun(png, &o, YES);
        NSDictionary *head = @{
          @"do" : @"ocr",
          @"id" : @(id),
          @"why" : @(o.why),
          @"lang" : o.lang,
          @"lines" : @(o.lines),
          @"ms" : @(round(o.ms)),
          @"fmt" : @"boxes"
        };
        NSData *json = [NSJSONSerialization dataWithJSONObject:head options:0 error:nil];
        NSData *payload = [o.boxes dataUsingEncoding:NSUTF8StringEncoding];
        mb_post("ps", json.bytes, json.length, payload.bytes, payload.length);
      }
    }
  });
}

int32_t ps_ocr(int32_t id, moonbit_bytes_t png) {
  int len = (int)Moonbit_array_length(png);
  if (len <= 0)
    return 0;
  NSData *data = [NSData dataWithBytes:png length:len];
  BOOL start;
  @synchronized([NSProcessInfo class]) {
    nextPng = data;
    nextId = id;
    start = !running;
    running = YES;
  }
  if (start)
    ocrLoop();
  return 1;
}

moonbit_bytes_t ps_ocr_now(moonbit_bytes_t png) {
  int len = (int)Moonbit_array_length(png);
  OcrOut o = {"bad-picture", @"", @"", @"", 0, 0};
  if (len > 0) {
    @autoreleasepool {
      ocrRun([NSData dataWithBytesNoCopy:png length:len freeWhenDone:NO], &o, NO);
    }
  }
  return ps_string([NSString stringWithFormat:@"%s\t%@\t%.0f\n%@", o.why, o.lang, o.ms, o.text]);
}
