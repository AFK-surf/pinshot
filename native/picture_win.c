// Pictures made over by Windows' own codecs (WIC) rather than in MoonBit: a JPEG written of a PNG, a pin's picture
// turned and flipped. WIC's decoders, its flip-rotator and encoders are native and run in a few tens of milliseconds
// where the same in MoonBit's pixel loops took seconds and hundreds of MB for a 4K picture (2026-11-21's audit).
// Only PNGs and JPEGs are taken here (what captures and pins are); anything else, or anything that fails, answers
// empty and the app does it its own way (pin.mbt, export.mbt), as a Mac's run does (platform_mac.m answers empty).
#define WIN32_LEAN_AND_MEAN
#define COBJMACROS
#include <windows.h>
#include <wincodec.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "moonbit.h"

#pragma comment(lib, "windowscodecs.lib")
#pragma comment(lib, "ole32.lib")

static moonbit_bytes_t pic_none(void) { return moonbit_make_bytes(0, 0); }

static moonbit_bytes_t pic_bytes(const void *p, size_t n) {
  moonbit_bytes_t b = moonbit_make_bytes((int32_t)n, 0);
  if (n) memcpy(b, p, n);
  return b;
}

static int is_png_or_jpeg(const uint8_t *b, size_t n) {
  if (n >= 8 && b[0] == 0x89 && b[1] == 'P' && b[2] == 'N' && b[3] == 'G') return 1;
  if (n >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return 1;
  return 0;
}

typedef struct {
  HRESULT co;
  IWICImagingFactory *f;
  IWICStream *in;
  IWICBitmapDecoder *dec;
  IWICBitmapFrameDecode *frame;
} Decoded;

static void decoded_let_go(Decoded *d) {
  if (d->frame) IWICBitmapFrameDecode_Release(d->frame);
  if (d->dec) IWICBitmapDecoder_Release(d->dec);
  if (d->in) IWICStream_Release(d->in);
  if (d->f) IWICImagingFactory_Release(d->f);
  if (SUCCEEDED(d->co)) CoUninitialize();
  memset(d, 0, sizeof *d);
}

static int decoded(const uint8_t *b, size_t n, Decoded *d) {
  memset(d, 0, sizeof *d);
  d->co = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
  if (!is_png_or_jpeg(b, n) || n > 0x7FFFFFFF) return 0;
  return SUCCEEDED(CoCreateInstance(&CLSID_WICImagingFactory, NULL, CLSCTX_INPROC_SERVER, &IID_IWICImagingFactory,
                                    (void **)&d->f)) &&
         SUCCEEDED(IWICImagingFactory_CreateStream(d->f, &d->in)) &&
         SUCCEEDED(IWICStream_InitializeFromMemory(d->in, (BYTE *)b, (DWORD)n)) &&
         SUCCEEDED(IWICImagingFactory_CreateDecoderFromStream(d->f, (IStream *)d->in, NULL,
                                                              WICDecodeMetadataCacheOnDemand, &d->dec)) &&
         SUCCEEDED(IWICBitmapDecoder_GetFrame(d->dec, 0, &d->frame));
}

// `src` (of `f`) encoded as `container` (PNG, or JPEG of quality q: 4:4:4, as the app's own encoder writes it) into
// bytes; empty where it failed.
static moonbit_bytes_t encoded(IWICImagingFactory *f, IWICBitmapSource *src, const GUID *container, int q) {
  moonbit_bytes_t out = pic_none();
  IStream *st = NULL;
  IWICBitmapEncoder *enc = NULL;
  IWICBitmapFrameEncode *fr = NULL;
  IPropertyBag2 *opts = NULL;
  UINT w = 0, h = 0;
  WICPixelFormatGUID fmt;
  IWICBitmapSource_GetPixelFormat(src, &fmt);
  IWICBitmapSource_GetSize(src, &w, &h);
  int ok = SUCCEEDED(CreateStreamOnHGlobal(NULL, TRUE, &st)) &&
           SUCCEEDED(IWICImagingFactory_CreateEncoder(f, container, NULL, &enc)) &&
           SUCCEEDED(IWICBitmapEncoder_Initialize(enc, st, WICBitmapEncoderNoCache)) &&
           SUCCEEDED(IWICBitmapEncoder_CreateNewFrame(enc, &fr, &opts));
  if (ok && q > 0 && opts) {
    PROPBAG2 p[2];
    VARIANT v[2];
    memset(p, 0, sizeof p);
    VariantInit(&v[0]);
    VariantInit(&v[1]);
    p[0].pstrName = L"ImageQuality";
    v[0].vt = VT_R4;
    v[0].fltVal = (float)q / 100.0f;
    p[1].pstrName = L"JpegYCrCbSubsampling";
    v[1].vt = VT_UI1;
    v[1].bVal = (BYTE)WICJpegYCrCbSubsampling444;
    IPropertyBag2_Write(opts, 2, p, v);
  }
  ok = ok && SUCCEEDED(IWICBitmapFrameEncode_Initialize(fr, opts)) && SUCCEEDED(IWICBitmapFrameEncode_SetSize(fr, w, h)) &&
       SUCCEEDED(IWICBitmapFrameEncode_SetPixelFormat(fr, &fmt)) &&
       SUCCEEDED(IWICBitmapFrameEncode_WriteSource(fr, src, NULL)) && SUCCEEDED(IWICBitmapFrameEncode_Commit(fr)) &&
       SUCCEEDED(IWICBitmapEncoder_Commit(enc));
  if (ok) {
    HGLOBAL g = NULL;
    STATSTG ss;
    if (SUCCEEDED(GetHGlobalFromStream(st, &g)) && SUCCEEDED(IStream_Stat(st, &ss, STATFLAG_NONAME))) {
      void *p = GlobalLock(g);
      if (p) {
        out = pic_bytes(p, (size_t)ss.cbSize.QuadPart);
        GlobalUnlock(g);
      }
    }
  }
  if (opts) IPropertyBag2_Release(opts);
  if (fr) IWICBitmapFrameEncode_Release(fr);
  if (enc) IWICBitmapEncoder_Release(enc);
  if (st) IStream_Release(st);
  return out;
}

// `src` converted to `fmt` (a converter of WIC's; NULL where it could not be).
static IWICBitmapSource *converted(IWICImagingFactory *f, IWICBitmapSource *src, REFWICPixelFormatGUID fmt) {
  IWICFormatConverter *c = NULL;
  if (FAILED(IWICImagingFactory_CreateFormatConverter(f, &c))) return NULL;
  if (FAILED(IWICFormatConverter_Initialize(c, src, fmt, WICBitmapDitherTypeNone, NULL, 0.0, WICBitmapPaletteTypeCustom))) {
    IWICFormatConverter_Release(c);
    return NULL;
  }
  return (IWICBitmapSource *)c;
}

// A picture (PNG or JPEG) as a JPEG of quality `quality` (its alpha not kept, as the app's own encoder does); empty
// where it is neither, or it failed.
moonbit_bytes_t ps_picture_jpeg(moonbit_bytes_t pic, int32_t quality) {
  Decoded d;
  moonbit_bytes_t out = pic_none();
  if (decoded((const uint8_t *)pic, (size_t)Moonbit_array_length(pic), &d)) {
    IWICBitmapSource *bgr = converted(d.f, (IWICBitmapSource *)d.frame, &GUID_WICPixelFormat24bppBGR);
    if (bgr) {
      out = encoded(d.f, bgr, &GUID_ContainerFormatJpeg, quality < 1 ? 1 : (quality > 100 ? 100 : quality));
      IWICBitmapSource_Release(bgr);
    }
  }
  decoded_let_go(&d);
  return out;
}

// A picture (PNG or JPEG) mirrored left to right first (`flipped`), then turned `turns` quarters clockwise, as the pin
// shows it: `shown` 1, a top-down 32-bit BMP where it is opaque (mbui's host makes its texture as it is), else a PNG;
// `shown` 0, a PNG (what is copied and saved). Empty where it is neither PNG nor JPEG, or it failed.
moonbit_bytes_t ps_picture_oriented(moonbit_bytes_t pic, int32_t turns, int32_t flipped, int32_t shown) {
  Decoded d;
  moonbit_bytes_t out = pic_none();
  IWICBitmapFlipRotator *rot = NULL;
  IWICBitmapSource *bgra = NULL;
  uint8_t *px = NULL;
  if (!decoded((const uint8_t *)pic, (size_t)Moonbit_array_length(pic), &d)) goto done;
  // (WIC's flip-rotator mirrors first, then turns: as the pin does; checked pixel for pixel against mirror-then-turn,
  // each of the four turns)
  turns = ((turns % 4) + 4) % 4;
  int wic_turns = turns;
  static const WICBitmapTransformOptions rots[4] = {WICBitmapTransformRotate0, WICBitmapTransformRotate90,
                                                    WICBitmapTransformRotate180, WICBitmapTransformRotate270};
  WICBitmapTransformOptions how = (WICBitmapTransformOptions)(rots[wic_turns] | (flipped ? WICBitmapTransformFlipHorizontal : 0));
  bgra = converted(d.f, (IWICBitmapSource *)d.frame, &GUID_WICPixelFormat32bppBGRA);
  if (!bgra || FAILED(IWICImagingFactory_CreateBitmapFlipRotator(d.f, &rot)) ||
      FAILED(IWICBitmapFlipRotator_Initialize(rot, bgra, how)))
    goto done;
  UINT w = 0, h = 0;
  IWICBitmapFlipRotator_GetSize(rot, &w, &h);
  if (!w || !h || (uint64_t)w * h > 0x10000000ULL) goto done;
  size_t n = (size_t)w * h;
  px = (uint8_t *)malloc(54 + n * 4);
  if (!px) goto done;
  uint8_t *bits = px + 54;
  if (FAILED(IWICBitmapFlipRotator_CopyPixels(rot, NULL, w * 4, (UINT)(n * 4), bits))) goto done;
  int opaque = 1;
  for (size_t i = 0; i < n && opaque; i++) opaque = bits[i * 4 + 3] == 0xFF;
  if (shown && opaque) {
    uint32_t size = (uint32_t)(54 + n * 4), off = 54, hs = 40, img = (uint32_t)(n * 4);
    int32_t bw = (int32_t)w, bh = -(int32_t)h;
    uint16_t planes = 1, bpp = 32;
    memset(px, 0, 54);
    px[0] = 'B', px[1] = 'M';
    memcpy(px + 2, &size, 4);
    memcpy(px + 10, &off, 4);
    memcpy(px + 14, &hs, 4);
    memcpy(px + 18, &bw, 4);
    memcpy(px + 22, &bh, 4);
    memcpy(px + 26, &planes, 2);
    memcpy(px + 28, &bpp, 2);
    memcpy(px + 34, &img, 4);
    out = pic_bytes(px, 54 + n * 4);
  } else {
    IWICBitmap *bm = NULL;
    if (SUCCEEDED(IWICImagingFactory_CreateBitmapFromMemory(d.f, w, h, &GUID_WICPixelFormat32bppBGRA, w * 4,
                                                            (UINT)(n * 4), bits, &bm))) {
      out = encoded(d.f, (IWICBitmapSource *)bm, &GUID_ContainerFormatPng, 0);
      IWICBitmap_Release(bm);
    }
  }
done:
  free(px);
  if (rot) IWICBitmapFlipRotator_Release(rot);
  if (bgra) IWICBitmapSource_Release(bgra);
  decoded_let_go(&d);
  return out;
}
