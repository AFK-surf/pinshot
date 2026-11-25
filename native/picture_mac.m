#import "mac_platform.h"
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static int isPngOrJpeg(const uint8_t *b, size_t n) {
  if (n >= 8 && b[0] == 0x89 && b[1] == 'P' && b[2] == 'N' && b[3] == 'G')
    return 1;
  return n >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF;
}

static CGImageRef decodedImage(moonbit_bytes_t pic) {
  size_t n = (size_t)Moonbit_array_length(pic);
  if (!isPngOrJpeg(pic, n))
    return NULL;
  NSData *data = [NSData dataWithBytesNoCopy:pic length:n freeWhenDone:NO];
  CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
  if (!src)
    return NULL;
  CGImageRef img = CGImageSourceCreateImageAtIndex(
      src, 0, (__bridge CFDictionaryRef) @{(id)kCGImageSourceShouldCacheImmediately : @YES});
  CFRelease(src);
  return img;
}

static moonbit_bytes_t encodedAs(CGImageRef img, NSString *type, NSDictionary *opts) {
  NSMutableData *out = [NSMutableData data];
  CGImageDestinationRef dst =
      CGImageDestinationCreateWithData((__bridge CFMutableDataRef)out, (__bridge CFStringRef)type, 1, NULL);
  if (!dst)
    return moonbit_make_bytes(0, 0);
  CGImageDestinationAddImage(dst, img, (__bridge CFDictionaryRef)opts);
  BOOL ok = CGImageDestinationFinalize(dst);
  CFRelease(dst);
  return ok ? ps_data(out) : moonbit_make_bytes(0, 0);
}

moonbit_bytes_t ps_picture_jpeg(moonbit_bytes_t pic, int32_t quality) {
  @autoreleasepool {
    CGImageRef img = decodedImage(pic);
    if (!img)
      return moonbit_make_bytes(0, 0);
    double q = (quality < 1 ? 1 : quality > 100 ? 100 : quality) / 100.0;
    moonbit_bytes_t out = encodedAs(img, UTTypeJPEG.identifier,
                                    @{(id)kCGImageDestinationLossyCompressionQuality : @(q)});
    CGImageRelease(img);
    return out;
  }
}

moonbit_bytes_t ps_picture_oriented(moonbit_bytes_t pic, int32_t turns, int32_t flipped, int32_t shown) {
  @autoreleasepool {
    CGImageRef img = decodedImage(pic);
    if (!img)
      return moonbit_make_bytes(0, 0);
    size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
    if (!w || !h || (uint64_t)w * h > 0x10000000ULL) {
      CGImageRelease(img);
      return moonbit_make_bytes(0, 0);
    }
    CGBitmapInfo info = kCGBitmapByteOrder32Little | (CGBitmapInfo)kCGImageAlphaPremultipliedFirst;
    CGColorSpaceRef own = CGImageGetColorSpace(img);
    CGColorSpaceRef space = own && CGColorSpaceGetModel(own) == kCGColorSpaceModelRGB
                                ? CGColorSpaceRetain(own)
                                : CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    uint32_t *src = calloc(w * h, 4);
    CGContextRef c = src ? CGBitmapContextCreate(src, w, h, 8, w * 4, space, info) : NULL;
    BOOL opaque = CGImageGetAlphaInfo(img) == kCGImageAlphaNone ||
                  CGImageGetAlphaInfo(img) == kCGImageAlphaNoneSkipFirst ||
                  CGImageGetAlphaInfo(img) == kCGImageAlphaNoneSkipLast;
    if (c) {
      CGContextSetBlendMode(c, kCGBlendModeCopy);
      CGContextDrawImage(c, CGRectMake(0, 0, w, h), img);
      CGContextRelease(c);
    }
    CGImageRelease(img);
    if (!c) {
      free(src);
      CGColorSpaceRelease(space);
      return moonbit_make_bytes(0, 0);
    }
    if (!opaque) {
      opaque = YES;
      for (size_t i = 0; i < w * h && opaque; i++)
        opaque = (src[i] >> 24) == 0xFF;
    }
    turns = ((turns % 4) + 4) % 4;
    size_t ow = turns % 2 ? h : w, oh = turns % 2 ? w : h;
    size_t head = shown && opaque ? 54 : 0;
    uint8_t *buf = malloc(head + ow * oh * 4);
    if (!buf) {
      free(src);
      CGColorSpaceRelease(space);
      return moonbit_make_bytes(0, 0);
    }
    uint32_t *dst = (uint32_t *)(buf + head);
    for (size_t y = 0; y < oh; y++) {
      uint32_t *row = dst + y * ow;
      for (size_t x = 0; x < ow; x++) {
        size_t mx, my;
        switch (turns) {
        case 1: mx = y, my = h - 1 - x; break;
        case 2: mx = w - 1 - x, my = h - 1 - y; break;
        case 3: mx = w - 1 - y, my = x; break;
        default: mx = x, my = y;
        }
        row[x] = src[my * w + (flipped ? w - 1 - mx : mx)];
      }
    }
    free(src);
    moonbit_bytes_t out;
    if (head) {
      uint32_t size = (uint32_t)(54 + ow * oh * 4), off = 54, hs = 40, imgsz = (uint32_t)(ow * oh * 4);
      int32_t bw = (int32_t)ow, bh = -(int32_t)oh;
      uint16_t planes = 1, bpp = 32;
      memset(buf, 0, 54);
      buf[0] = 'B', buf[1] = 'M';
      memcpy(buf + 2, &size, 4);
      memcpy(buf + 10, &off, 4);
      memcpy(buf + 14, &hs, 4);
      memcpy(buf + 18, &bw, 4);
      memcpy(buf + 22, &bh, 4);
      memcpy(buf + 26, &planes, 2);
      memcpy(buf + 28, &bpp, 2);
      memcpy(buf + 34, &imgsz, 4);
      out = moonbit_make_bytes((int32_t)size, 0);
      memcpy(out, buf, size);
    } else {
      CGContextRef oc = CGBitmapContextCreate(dst, ow, oh, 8, ow * 4, space,
                                              opaque ? kCGBitmapByteOrder32Little | (CGBitmapInfo)kCGImageAlphaNoneSkipFirst
                                                     : info);
      CGImageRef oimg = oc ? CGBitmapContextCreateImage(oc) : NULL;
      out = oimg ? encodedAs(oimg, UTTypePNG.identifier, @{}) : moonbit_make_bytes(0, 0);
      if (oimg)
        CGImageRelease(oimg);
      if (oc)
        CGContextRelease(oc);
    }
    free(buf);
    CGColorSpaceRelease(space);
    return out;
  }
}
