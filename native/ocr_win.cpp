#include <windows.h>
#include <wincodec.h>
#include <roapi.h>
#include <wrl.h>
#include <wrl/wrappers/corewrappers.h>
#include <windows.foundation.h>
#include <windows.foundation.collections.h>
#include <windows.globalization.h>
#include <windows.graphics.imaging.h>
#include <windows.media.ocr.h>
#include <MemoryBuffer.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <string>
#include <memory>
#include "moonbit.h"

#pragma comment(lib, "runtimeobject.lib")
#pragma comment(lib, "windowscodecs.lib")
#pragma comment(lib, "ole32.lib")

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;
using Microsoft::WRL::Wrappers::HString;
using Microsoft::WRL::Wrappers::HStringReference;
namespace WF = ABI::Windows::Foundation;
namespace WFC = ABI::Windows::Foundation::Collections;
namespace WG = ABI::Windows::Globalization;
namespace WI = ABI::Windows::Graphics::Imaging;
namespace OCR = ABI::Windows::Media::Ocr;

extern "C" void mb_post(const char *channel, const char *json, size_t len, const uint8_t *bytes, size_t blen);

template <typename T, typename R>
static HRESULT ocr_wait(WF::IAsyncOperation<T> *op, R *out) {
  HANDLE raw = CreateEventW(NULL, TRUE, FALSE, NULL);
  if (!raw) return E_FAIL;
  std::shared_ptr<void> done(raw, CloseHandle);
  auto h = Callback<Microsoft::WRL::Implements<Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::ClassicCom>,
                                              WF::IAsyncOperationCompletedHandler<T>, Microsoft::WRL::FtmBase>>(
      [done](WF::IAsyncOperation<T> *, WF::AsyncStatus) -> HRESULT {
        SetEvent(done.get());
        return S_OK;
      });
  HRESULT hr = op->put_Completed(h.Get());
  if (SUCCEEDED(hr)) {
    if (WaitForSingleObject(done.get(), 20000) != WAIT_OBJECT_0) {
      ComPtr<WF::IAsyncInfo> info;
      if (SUCCEEDED(op->QueryInterface(IID_PPV_ARGS(&info))) && info) info->Cancel();
      hr = E_FAIL;
    } else {
      hr = op->GetResults(out);
    }
  }
  return hr;
}

static std::string utf8_of(HSTRING s) {
  UINT32 n = 0;
  const wchar_t *w = WindowsGetStringRawBuffer(s, &n);
  if (!w || n == 0) return std::string();
  int m = WideCharToMultiByte(CP_UTF8, 0, w, (int)n, NULL, 0, NULL, NULL);
  std::string out(m > 0 ? m : 0, '\0');
  if (m > 0) WideCharToMultiByte(CP_UTF8, 0, w, (int)n, &out[0], m, NULL, NULL);
  return out;
}

static int unspaced(wchar_t c) {
  return (c >= 0x2E80 && c <= 0x9FFF) || (c >= 0xF900 && c <= 0xFAFF) || (c >= 0xFE30 && c <= 0xFE4F) ||
         (c >= 0xFF00 && c <= 0xFFEF);
}

static HRESULT bitmap_of(const uint8_t *png, int len, double scale_up, UINT32 most, ComPtr<WI::ISoftwareBitmap> &out,
                         int *ow, int *oh) {
  ComPtr<IWICImagingFactory> wic;
  HRESULT hr = CoCreateInstance(CLSID_WICImagingFactory, NULL, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&wic));
  if (FAILED(hr)) return hr;
  ComPtr<IWICStream> stream;
  if (FAILED(hr = wic->CreateStream(&stream))) return hr;
  if (FAILED(hr = stream->InitializeFromMemory((BYTE *)png, (DWORD)len))) return hr;
  ComPtr<IWICBitmapDecoder> dec;
  if (FAILED(hr = wic->CreateDecoderFromStream(stream.Get(), NULL, WICDecodeMetadataCacheOnDemand, &dec))) return hr;
  ComPtr<IWICBitmapFrameDecode> frame;
  if (FAILED(hr = dec->GetFrame(0, &frame))) return hr;
  UINT w = 0, h = 0;
  frame->GetSize(&w, &h);
  if (w == 0 || h == 0) return E_FAIL;
  double s = (double)w * h * scale_up * scale_up > 4.0e6 ? 1.0 : scale_up;
  UINT big = w > h ? w : h;
  if (big * s > most) s = (double)most / big;
  if (s < 1.0 && big <= most) s = 1.0;
  UINT nw = (UINT)(w * s + 0.5), nh = (UINT)(h * s + 0.5);
  if (nw < 1) nw = 1;
  if (nh < 1) nh = 1;
  ComPtr<IWICBitmapSource> src = frame;
  if (nw != w || nh != h) {
    ComPtr<IWICBitmapScaler> scaler;
    if (FAILED(hr = wic->CreateBitmapScaler(&scaler))) return hr;
    if (FAILED(hr = scaler->Initialize(frame.Get(), nw, nh, WICBitmapInterpolationModeHighQualityCubic))) return hr;
    src = scaler;
  }
  ComPtr<IWICFormatConverter> conv;
  if (FAILED(hr = wic->CreateFormatConverter(&conv))) return hr;
  if (FAILED(hr = conv->Initialize(src.Get(), GUID_WICPixelFormat32bppPBGRA, WICBitmapDitherTypeNone, NULL, 0.0,
                                   WICBitmapPaletteTypeCustom)))
    return hr;

  ComPtr<WI::ISoftwareBitmapFactory> factory;
  if (FAILED(hr = RoGetActivationFactory(HStringReference(RuntimeClass_Windows_Graphics_Imaging_SoftwareBitmap).Get(),
                                         IID_PPV_ARGS(&factory))))
    return hr;
  ComPtr<WI::ISoftwareBitmap> bmp;
  if (FAILED(hr = factory->CreateWithAlpha(WI::BitmapPixelFormat_Bgra8, (INT32)nw, (INT32)nh,
                                           WI::BitmapAlphaMode_Premultiplied, &bmp)))
    return hr;
  {
    ComPtr<WI::IBitmapBuffer> buf;
    ComPtr<WF::IMemoryBufferReference> ref;
    auto close_all = [&](bool bitmap_too) {
      ComPtr<WF::IClosable> c;
      if (ref && SUCCEEDED(ref.As(&c))) c->Close();
      if (buf && SUCCEEDED(buf.As(&c))) c->Close();
      if (bitmap_too && bmp && SUCCEEDED(bmp.As(&c))) c->Close();
    };
    WI::BitmapPlaneDescription plane;
    ComPtr<WF::IMemoryBuffer> mem;
    ComPtr<::Windows::Foundation::IMemoryBufferByteAccess> access;
    BYTE *data = NULL;
    UINT32 cap = 0;
    if (FAILED(hr = bmp->LockBuffer(WI::BitmapBufferAccessMode_Write, &buf)) ||
        FAILED(hr = buf->GetPlaneDescription(0, &plane)) || FAILED(hr = buf.As(&mem)) ||
        FAILED(hr = mem->CreateReference(&ref)) || FAILED(hr = ref.As(&access)) ||
        FAILED(hr = access->GetBuffer(&data, &cap))) {
      close_all(true);
      return hr;
    }
    if ((UINT64)plane.StartIndex + (UINT64)plane.Stride * nh > cap) {
      close_all(true);
      return E_FAIL;
    }
    WICRect all = {0, 0, (INT)nw, (INT)nh};
    hr = conv->CopyPixels(&all, (UINT)plane.Stride, cap - plane.StartIndex, data + plane.StartIndex);
    close_all(FAILED(hr));
    if (FAILED(hr)) return hr;
  }
  out = bmp;
  *ow = (int)nw;
  *oh = (int)nh;
  return S_OK;
}

static SRWLOCK chosen_lock = SRWLOCK_INIT;
static std::wstring chosen;
static HRESULT engine_found(ComPtr<OCR::IOcrEngineStatics> &st, ComPtr<OCR::IOcrEngine> &engine);
static HRESULT engine_of(ComPtr<OCR::IOcrEngineStatics> &st, ComPtr<OCR::IOcrEngine> &engine) {
  AcquireSRWLockShared(&chosen_lock);
  std::wstring tag = chosen;
  ReleaseSRWLockShared(&chosen_lock);
  if (!tag.empty()) {
    ComPtr<WG::ILanguageFactory> lf;
    ComPtr<WG::ILanguage> lang;
    if (SUCCEEDED(RoGetActivationFactory(HStringReference(RuntimeClass_Windows_Globalization_Language).Get(),
                                         IID_PPV_ARGS(&lf))) &&
        SUCCEEDED(lf->CreateLanguage(HStringReference(tag.c_str(), (unsigned)tag.size()).Get(), &lang)) &&
        SUCCEEDED(st->TryCreateFromLanguage(lang.Get(), &engine)) && engine)
      return S_OK;
    engine.Reset();
  }
  HRESULT hr = engine_found(st, engine);
  if (hr == S_OK && engine) {
    ComPtr<WG::ILanguage> lang;
    HString t;
    if (SUCCEEDED(engine->get_RecognizerLanguage(&lang)) && lang && SUCCEEDED(lang->get_LanguageTag(t.GetAddressOf()))) {
      UINT32 n = 0;
      const wchar_t *s = WindowsGetStringRawBuffer(t.Get(), &n);
      AcquireSRWLockExclusive(&chosen_lock);
      if (s && n) chosen.assign(s, n);
      ReleaseSRWLockExclusive(&chosen_lock);
    }
  }
  return hr;
}

static HRESULT engine_found(ComPtr<OCR::IOcrEngineStatics> &st, ComPtr<OCR::IOcrEngine> &engine) {
  ComPtr<WFC::IVectorView<WG::Language *>> langs;
  HRESULT hr = st->get_AvailableRecognizerLanguages(&langs);
  if (FAILED(hr)) return hr;
  UINT32 n = 0;
  langs->get_Size(&n);
  if (n == 0) return S_FALSE;
  ComPtr<OCR::IOcrEngine> prof;
  if (SUCCEEDED(st->TryCreateFromUserProfileLanguages(&prof)) && prof) {
    ComPtr<WG::ILanguage> plang;
    HString ptag;
    UINT32 ptl = 0;
    const wchar_t *pt = NULL;
    if (SUCCEEDED(prof->get_RecognizerLanguage(&plang)) && plang &&
        SUCCEEDED(plang->get_LanguageTag(ptag.GetAddressOf())))
      pt = WindowsGetStringRawBuffer(ptag.Get(), &ptl);
    bool is_en = pt && ptl >= 2 && _wcsnicmp(pt, L"en", 2) == 0 && (ptl == 2 || pt[2] == L'-');
    if (!is_en) {
      engine = prof;
      return S_OK;
    }
  }
  static const wchar_t *firsts[] = {L"zh-Hans", L"zh-Hant", L"zh", L"ja", L"ko"};
  for (const wchar_t *want : firsts) {
    size_t wl = wcslen(want);
    for (UINT32 i = 0; i < n; i++) {
      ComPtr<WG::ILanguage> lang;
      HString tag;
      if (FAILED(langs->GetAt(i, &lang)) || FAILED(lang->get_LanguageTag(tag.GetAddressOf()))) continue;
      UINT32 tl = 0;
      const wchar_t *t = WindowsGetStringRawBuffer(tag.Get(), &tl);
      if (t && tl >= wl && _wcsnicmp(t, want, wl) == 0 && (tl == wl || t[wl] == L'-')) {
        if (SUCCEEDED(st->TryCreateFromLanguage(lang.Get(), &engine)) && engine) return S_OK;
      }
    }
  }
  if (prof) {
    engine = prof;
    return S_OK;
  }
  ComPtr<WG::ILanguage> lang;
  if (FAILED(hr = langs->GetAt(0, &lang))) return hr;
  hr = st->TryCreateFromLanguage(lang.Get(), &engine);
  return SUCCEEDED(hr) && engine ? S_OK : S_FALSE;
}

// An English engine, where one is installed and `engine` is not one: a picture of English read by a Chinese engine
// splits and mangles its words ("1,549 posts" as "1, 549 p OST"), so English is read again by an English one.
static bool english_engine(ComPtr<OCR::IOcrEngineStatics> &st, ComPtr<OCR::IOcrEngine> &engine, ComPtr<OCR::IOcrEngine> &en) {
  ComPtr<WG::ILanguage> cur;
  HString ct;
  if (SUCCEEDED(engine->get_RecognizerLanguage(&cur)) && cur && SUCCEEDED(cur->get_LanguageTag(ct.GetAddressOf()))) {
    UINT32 n = 0;
    const wchar_t *c = WindowsGetStringRawBuffer(ct.Get(), &n);
    if (c && n >= 2 && _wcsnicmp(c, L"en", 2) == 0) return false;
  }
  ComPtr<WFC::IVectorView<WG::Language *>> langs;
  if (FAILED(st->get_AvailableRecognizerLanguages(&langs))) return false;
  UINT32 n = 0;
  langs->get_Size(&n);
  for (UINT32 i = 0; i < n; i++) {
    ComPtr<WG::ILanguage> lang;
    HString tag;
    if (FAILED(langs->GetAt(i, &lang)) || FAILED(lang->get_LanguageTag(tag.GetAddressOf()))) continue;
    UINT32 tl = 0;
    const wchar_t *t = WindowsGetStringRawBuffer(tag.Get(), &tl);
    if (t && tl >= 2 && _wcsnicmp(t, L"en", 2) == 0 && (tl == 2 || t[2] == L'-'))
      if (SUCCEEDED(st->TryCreateFromLanguage(lang.Get(), &en)) && en) return true;
  }
  return false;
}

// Whether what `res` read is mostly Latin letters (few CJK ones among them).
static bool mostly_latin(OCR::IOcrResult *res) {
  HString t;
  if (FAILED(res->get_Text(t.GetAddressOf()))) return false;
  UINT32 n = 0;
  const wchar_t *s = WindowsGetStringRawBuffer(t.Get(), &n);
  int latin = 0, cjk = 0;
  for (UINT32 i = 0; s && i < n; i++) {
    wchar_t c = s[i];
    if ((c >= L'A' && c <= L'Z') || (c >= L'a' && c <= L'z')) latin++;
    else if ((c >= 0x3040 && c <= 0x30FF) || (c >= 0x3400 && c <= 0x9FFF) || (c >= 0xAC00 && c <= 0xD7AF)) cjk++;
  }
  return latin >= 8 && cjk * 12 < latin;
}

struct OcrOut {
  std::string text;
  std::string boxes;
  std::string lang;
  const char *why;
  int lines;
  double ms;
};

static double clamp01(double v) { return v < 0.0 ? 0.0 : (v > 1.0 ? 1.0 : v); }

static void ocr_run(const uint8_t *png, int len, OcrOut *o, bool want_boxes) {
  LARGE_INTEGER f, t0, t1;
  QueryPerformanceFrequency(&f);
  QueryPerformanceCounter(&t0);
  o->why = "";
  o->lines = 0;
  o->ms = 0.0;
  ComPtr<OCR::IOcrEngineStatics> st;
  if (FAILED(RoGetActivationFactory(HStringReference(RuntimeClass_Windows_Media_Ocr_OcrEngine).Get(),
                                    IID_PPV_ARGS(&st)))) {
    o->why = "no-ocr";
    return;
  }
  ComPtr<OCR::IOcrEngine> engine;
  if (engine_of(st, engine) != S_OK || !engine) {
    o->why = "no-language";
    return;
  }
  {
    ComPtr<WG::ILanguage> lang;
    HString tag;
    if (SUCCEEDED(engine->get_RecognizerLanguage(&lang)) && lang &&
        SUCCEEDED(lang->get_LanguageTag(tag.GetAddressOf())))
      o->lang = utf8_of(tag.Get());
  }
  UINT32 most = 0;
  st->get_MaxImageDimension(&most);
  if (most < 256) most = 2600;
  ComPtr<WI::ISoftwareBitmap> bmp;
  int w = 0, h = 0;
  if (FAILED(bitmap_of(png, len, 2.0, most, bmp, &w, &h))) {
    o->why = "bad-picture";
    return;
  }
  ComPtr<WF::IAsyncOperation<OCR::OcrResult *>> op;
  ComPtr<OCR::IOcrResult> res;
  HRESULT rhr = engine->RecognizeAsync(bmp.Get(), &op);
  HRESULT whr = SUCCEEDED(rhr) ? ocr_wait(op.Get(), res.GetAddressOf()) : rhr;
  ComPtr<OCR::IOcrEngine> en;
  if (SUCCEEDED(whr) && res && mostly_latin(res.Get()) && english_engine(st, engine, en)) {
    ComPtr<WF::IAsyncOperation<OCR::OcrResult *>> op2;
    ComPtr<OCR::IOcrResult> res2;
    if (SUCCEEDED(en->RecognizeAsync(bmp.Get(), &op2)) && SUCCEEDED(ocr_wait(op2.Get(), res2.GetAddressOf())) && res2) {
      res = res2;
      ComPtr<WG::ILanguage> lang;
      HString tag;
      if (SUCCEEDED(en->get_RecognizerLanguage(&lang)) && lang && SUCCEEDED(lang->get_LanguageTag(tag.GetAddressOf())))
        o->lang = utf8_of(tag.Get());
    }
  }
  ComPtr<WF::IClosable> bc;
  if (bmp && SUCCEEDED(bmp.As(&bc))) bc->Close();
  bmp.Reset();
  if (FAILED(whr) || !res) {
    o->why = "failed";
    return;
  }
  ComPtr<WFC::IVectorView<OCR::OcrLine *>> lines;
  if (FAILED(res->get_Lines(&lines))) {
    o->why = "failed";
    return;
  }
  UINT32 nl = 0;
  lines->get_Size(&nl);
  double inv_w = w > 0 ? 1.0 / (double)w : 0.0;
  double inv_h = h > 0 ? 1.0 / (double)h : 0.0;
  std::wstring all;
  for (UINT32 i = 0; i < nl; i++) {
    ComPtr<OCR::IOcrLine> line;
    ComPtr<WFC::IVectorView<OCR::OcrWord *>> words;
    if (FAILED(lines->GetAt(i, &line)) || FAILED(line->get_Words(&words))) continue;
    UINT32 nw = 0;
    words->get_Size(&nw);
    std::wstring l;
    int line_idx = o->lines;
    for (UINT32 j = 0; j < nw; j++) {
      ComPtr<OCR::IOcrWord> word;
      HString t;
      if (FAILED(words->GetAt(j, &word)) || FAILED(word->get_Text(t.GetAddressOf()))) continue;
      UINT32 n = 0;
      const wchar_t *s = WindowsGetStringRawBuffer(t.Get(), &n);
      if (!s || n == 0) continue;
      int space = !l.empty() && !(unspaced(l.back()) && unspaced(s[0]));
      if (space) l.push_back(L' ');
      l.append(s, n);
      if (want_boxes && inv_w > 0.0 && inv_h > 0.0) {
        WF::Rect rc = {0, 0, 0, 0};
        if (SUCCEEDED(word->get_BoundingRect(&rc))) {
          double nx = clamp01((double)rc.X * inv_w);
          double ny = clamp01((double)rc.Y * inv_h);
          double bw = clamp01((double)rc.Width * inv_w);
          double bh = clamp01((double)rc.Height * inv_h);
          if (nx + bw > 1.0) bw = 1.0 - nx;
          if (ny + bh > 1.0) bh = 1.0 - ny;
          std::string u = utf8_of(t.Get());
          for (char &c : u) {
            if (c == '\t' || c == '\r' || c == '\n') c = ' ';
          }
          char row[96];
          int rn = snprintf(row, sizeof row, "%d\t%d\t%.5f\t%.5f\t%.5f\t%.5f\t", line_idx, space, nx, ny, bw, bh);
          if (rn > 0 && rn < (int)sizeof row) {
            o->boxes.append(row, (size_t)rn);
            o->boxes.append(u);
            o->boxes.push_back('\n');
          }
        }
      }
    }
    if (l.empty()) continue;
    if (!all.empty()) all.push_back(L'\n');
    all += l;
    o->lines++;
  }
  if (!want_boxes && !all.empty()) {
    int m = WideCharToMultiByte(CP_UTF8, 0, all.data(), (int)all.size(), NULL, 0, NULL, NULL);
    o->text.assign(m > 0 ? m : 0, '\0');
    if (m > 0) WideCharToMultiByte(CP_UTF8, 0, all.data(), (int)all.size(), &o->text[0], m, NULL, NULL);
  }
  QueryPerformanceCounter(&t1);
  o->ms = (double)(t1.QuadPart - t0.QuadPart) * 1000.0 / f.QuadPart;
}

struct OcrJob {
  int id;
  int len;
  uint8_t png[1];
};

static SRWLOCK jobs_lock = SRWLOCK_INIT;
static OcrJob *job_next;
static bool job_running;

static DWORD WINAPI ocr_thread(LPVOID p) {
  OcrJob *job = (OcrJob *)p;
  HRESULT ro = RoInitialize(RO_INIT_MULTITHREADED);
  while (job) {
    OcrOut o = {"", "", "", "", 0, 0.0};
    ocr_run(job->png, job->len, &o, true);
    char json[256];
    int n = snprintf(json, sizeof json,
                     "{\"do\":\"ocr\",\"id\":%d,\"why\":\"%s\",\"lang\":\"%.40s\",\"lines\":%d,\"ms\":%.0f,\"fmt\":\"boxes\"}",
                     job->id, o.why, o.lang.c_str(), o.lines, o.ms);
    if (n < 0) n = 0;
    else if (n >= (int)sizeof json) n = (int)sizeof json - 1;
    mb_post("ps", json, (size_t)n, (const uint8_t *)o.boxes.data(), o.boxes.size());
    free(job);
    AcquireSRWLockExclusive(&jobs_lock);
    job = job_next;
    job_next = NULL;
    if (!job) job_running = false;
    ReleaseSRWLockExclusive(&jobs_lock);
  }
  CoFreeUnusedLibraries();
  if (SUCCEEDED(ro)) RoUninitialize();
  return 0;
}

extern "C" int ps_ocr(int id, moonbit_bytes_t png) {
  int len = (int)Moonbit_array_length(png);
  if (len <= 0) return 0;
  OcrJob *job = (OcrJob *)malloc(sizeof(OcrJob) + len);
  if (!job) return 0;
  job->id = id;
  job->len = len;
  memcpy(job->png, png, len);
  AcquireSRWLockExclusive(&jobs_lock);
  if (job_running) {
    free(job_next);
    job_next = job;
    ReleaseSRWLockExclusive(&jobs_lock);
    return 1;
  }
  job_running = true;
  ReleaseSRWLockExclusive(&jobs_lock);
  HANDLE t = CreateThread(NULL, 0, ocr_thread, job, 0, NULL);
  if (!t) {
    AcquireSRWLockExclusive(&jobs_lock);
    job_running = false;
    ReleaseSRWLockExclusive(&jobs_lock);
    free(job);
    return 0;
  }
  CloseHandle(t);
  return 1;
}

extern "C" moonbit_bytes_t ps_ocr_now(moonbit_bytes_t png) {
  int len = (int)Moonbit_array_length(png);
  OcrOut o;
  o.why = "bad-picture";
  o.lines = 0;
  o.ms = 0;
  if (len > 0) {
    HRESULT ro = RoInitialize(RO_INIT_MULTITHREADED);
    ocr_run(png, len, &o, false);
    if (SUCCEEDED(ro)) RoUninitialize();
  }
  char head[128];
  snprintf(head, sizeof head, "%s\t%.40s\t%.0f\n", o.why, o.lang.c_str(), o.ms);
  std::string all = std::string(head) + o.text;
  moonbit_bytes_t b = moonbit_make_bytes((int32_t)all.size(), 0);
  if (!all.empty()) memcpy(b, all.data(), all.size());
  return b;
}
