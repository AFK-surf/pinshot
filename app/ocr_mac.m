// The words in a picture read by the Mac's own OCR (Vision's VNRecognizeTextRequest: on the machine, offline, Chinese
// and English), the Mac side of ocr_win.cpp with the same calls and the same answers. The picture (a PNG: a part
// taken, a pin) is read on a queue of its own, the UI going on meanwhile; what it says comes back on the channel "ps"
// as {"do":"ocr","id":N,"why":"","lang":"zh-Hans","lines":3,"ms":120}, its words as UTF-8 bytes beside the JSON.
//
// What it gives: Vision's lines, put in reading order (top to bottom; those side by side on one line joined left to
// right, with a space between them but between two of Chinese or Japanese).
#import "mac_platform.h"
#import <ImageIO/ImageIO.h>
#import <Vision/Vision.h>
#import <stdatomic.h>

extern void mb_post(const char *, const char *, size_t, const uint8_t *, size_t);

typedef struct {
  const char *why;
  NSString *lang;
  NSString *text;
  int lines;
  double ms;
} OcrOut;

static BOOL unspaced(unichar c) {
  return (c >= 0x2E80 && c <= 0x9FFF) || (c >= 0xF900 && c <= 0xFAFF) || (c >= 0xFF00 && c <= 0xFFEF) ||
         (c >= 0x3000 && c <= 0x303F);
}

static void ocrRun(NSData *png, OcrOut *o) {
  double t0 = ps_now_ms();
  o->why = "bad-picture";
  o->lang = @"";
  o->text = @"";
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
  // (Vision's boxes are 0..1 with y up: a line is those whose middles fall within each other's height)
  NSMutableArray<VNRecognizedTextObservation *> *obs = [NSMutableArray array];
  for (VNRecognizedTextObservation *r in req.results)
    if ([r topCandidates:1].firstObject.string.length)
      [obs addObject:r];
  [obs sortUsingComparator:^NSComparisonResult(VNRecognizedTextObservation *a, VNRecognizedTextObservation *b) {
    CGFloat ay = CGRectGetMidY(a.boundingBox), by = CGRectGetMidY(b.boundingBox);
    return ay > by ? NSOrderedAscending : ay < by ? NSOrderedDescending : NSOrderedSame;
  }];
  NSMutableString *all = [NSMutableString string];
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
    for (VNRecognizedTextObservation *r in row) {
      NSString *s = [[r topCandidates:1].firstObject.string
          stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
      if (!s.length)
        continue;
      if (line.length && !(unspaced([line characterAtIndex:line.length - 1]) && unspaced([s characterAtIndex:0])))
        [line appendString:@" "];
      [line appendString:s];
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
  o->lang = o->lines ? (cjk ? @"zh-Hans" : @"en-US") : @"";
  o->ms = ps_now_ms() - t0;
}

// One reading at a time, as on Windows: asked for while one goes, the new one waits (one at most: a newer one takes its
// place, the app wants only the last it asked for). No readings pile up.
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
        ocrRun(png, &o);
        NSDictionary *head = @{
          @"do" : @"ocr",
          @"id" : @(id),
          @"why" : @(o.why),
          @"lang" : o.lang,
          @"lines" : @(o.lines),
          @"ms" : @(round(o.ms))
        };
        NSData *json = [NSJSONSerialization dataWithJSONObject:head options:0 error:nil];
        NSData *words = [o.text dataUsingEncoding:NSUTF8StringEncoding];
        mb_post("ps", json.bytes, json.length, words.bytes, words.length);
      }
    }
  });
}

// The words in `png` read on a queue of their own, told back as {"do":"ocr","id":id,...} with them: 1 it is begun.
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

// The words in `png` read now (the command line's --ocr): "why\tlang\tms\n" then them.
moonbit_bytes_t ps_ocr_now(moonbit_bytes_t png) {
  int len = (int)Moonbit_array_length(png);
  OcrOut o = {"bad-picture", @"", @"", 0, 0};
  if (len > 0) {
    @autoreleasepool {
      ocrRun([NSData dataWithBytesNoCopy:png length:len freeWhenDone:NO], &o);
    }
  }
  return ps_string([NSString stringWithFormat:@"%s\t%@\t%.0f\n%@", o.why, o.lang, o.ms, o.text]);
}
