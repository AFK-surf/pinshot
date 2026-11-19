// The words in a picture read by Windows' own OCR (Windows.Media.Ocr: on the machine, offline, in the languages whose
// OCR is installed: Chinese, English, Japanese, Korean told apart by themselves, `engines_of` and `which_of`). The picture (a PNG: a part taken, a pin) is read on a thread of
// its own, the UI going on meanwhile; what it says comes back on the channel "ps" as {"do":"ocr","id":N,...}, its
// words as UTF-8 bytes beside the JSON (main.mbt). `pinshot.exe --ocr <file> [lang|*]` reads one at once and prints it.
//
// What the engine is given: the picture in BGRA, brought up to twice its size where that keeps it under 4 million
// pixels (small screen text is read better so: 12-14 px UI text, its digits and Latin letters split and misread at
// its own size by the older engine some Windows still have), down to the engine's largest where it is over it. What it
// gives: lines of words; a line is put back together with a space between words but between two of Chinese or
// Japanese (it gives each such character as a word), the lines one under the other.
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
#include <vector>
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

// `op` waited for (it ends on the system's threads: an agile handler sets an event), 20 s at most.
template <typename T, typename R>
static HRESULT ocr_wait(WF::IAsyncOperation<T> *op, R *out) {
  HANDLE done = CreateEventW(NULL, TRUE, FALSE, NULL);
  if (!done) return E_FAIL;
  auto h = Callback<Microsoft::WRL::Implements<Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::ClassicCom>,
                                              WF::IAsyncOperationCompletedHandler<T>, Microsoft::WRL::FtmBase>>(
      [done](WF::IAsyncOperation<T> *, WF::AsyncStatus) -> HRESULT {
        SetEvent(done);
        return S_OK;
      });
  HRESULT hr = op->put_Completed(h.Get());
  if (SUCCEEDED(hr)) {
    if (WaitForSingleObject(done, 20000) != WAIT_OBJECT_0) hr = E_FAIL;
    else hr = op->GetResults(out);
  }
  CloseHandle(done);
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

// A character written without spaces round it: Chinese, Japanese, their punctuation and full-width forms (not Korean,
// which has spaces between its words).
static int unspaced(wchar_t c) {
  return (c >= 0x2E80 && c <= 0x9FFF) || (c >= 0xF900 && c <= 0xFAFF) || (c >= 0xFE30 && c <= 0xFE4F) ||
         (c >= 0xFF00 && c <= 0xFFEF);
}

// The picture decoded and made the engine's: BGRA, `scale` times its size.
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
    if (FAILED(hr = bmp->LockBuffer(WI::BitmapBufferAccessMode_Write, &buf))) return hr;
    WI::BitmapPlaneDescription plane;
    if (FAILED(hr = buf->GetPlaneDescription(0, &plane))) return hr;
    ComPtr<WF::IMemoryBuffer> mem;
    if (FAILED(hr = buf.As(&mem))) return hr;
    ComPtr<WF::IMemoryBufferReference> ref;
    if (FAILED(hr = mem->CreateReference(&ref))) return hr;
    ComPtr<::Windows::Foundation::IMemoryBufferByteAccess> access;
    if (FAILED(hr = ref.As(&access))) return hr;
    BYTE *data = NULL;
    UINT32 cap = 0;
    if (FAILED(hr = access->GetBuffer(&data, &cap))) return hr;
    if ((UINT64)plane.StartIndex + (UINT64)plane.Stride * nh > cap) return E_FAIL;
    WICRect all = {0, 0, (INT)nw, (INT)nh};
    hr = conv->CopyPixels(&all, (UINT)plane.Stride, cap - plane.StartIndex, data + plane.StartIndex);
    ComPtr<WF::IClosable> c;
    if (SUCCEEDED(ref.As(&c))) c->Close();
    if (SUCCEEDED(buf.As(&c))) c->Close();
    if (FAILED(hr)) return hr;
  }
  out = bmp;
  *ow = (int)nw;
  *oh = (int)nh;
  return S_OK;
}

// The engines a picture is read with. `want` a language ("zh", "en", "ja", "ko", or a whole tag): its engine alone (none
// where its OCR is not installed). "" (auto): one of each of Chinese, Japanese, Korean and English that is installed,
// and the person's own language where it is another (French, German...), the reading of the script it is kept (which_of).
// Each language is a family of its own: Chinese reads the Latin letters and digits among Chinese as well, the English
// reads Chinese as nonsense, the Chinese reads kana and Hangul as nonsense.
struct OcrEng {
  ComPtr<OCR::IOcrEngine> e;
  std::string tag;
  char fam;  // z j k e, o another
};

static std::string tag_of(OCR::IOcrEngine *e) {
  ComPtr<WG::ILanguage> lang;
  HString tag;
  if (SUCCEEDED(e->get_RecognizerLanguage(&lang)) && lang && SUCCEEDED(lang->get_LanguageTag(tag.GetAddressOf())))
    return utf8_of(tag.Get());
  return std::string();
}

static char fam_of(const std::string &t) {
  if (t.compare(0, 2, "zh") == 0) return 'z';
  if (t.compare(0, 2, "ja") == 0) return 'j';
  if (t.compare(0, 2, "ko") == 0) return 'k';
  if (t.compare(0, 2, "en") == 0) return 'e';
  return 'o';
}

static int tag_is(const std::string &t, const char *want) {
  size_t wl = strlen(want);
  return t.size() >= wl && _strnicmp(t.c_str(), want, wl) == 0 && (t.size() == wl || t[wl] == '-');
}

static void engines_of(ComPtr<OCR::IOcrEngineStatics> &st, const char *want, std::vector<OcrEng> &out,
                       std::string &have) {
  ComPtr<WFC::IVectorView<WG::Language *>> langs;
  if (FAILED(st->get_AvailableRecognizerLanguages(&langs))) return;
  UINT32 n = 0;
  langs->get_Size(&n);
  std::vector<ComPtr<WG::ILanguage>> ls;
  std::vector<std::string> tags;
  for (UINT32 i = 0; i < n; i++) {
    ComPtr<WG::ILanguage> lang;
    HString tag;
    if (FAILED(langs->GetAt(i, &lang)) || FAILED(lang->get_LanguageTag(tag.GetAddressOf()))) continue;
    ls.push_back(lang);
    tags.push_back(utf8_of(tag.Get()));
    if (!have.empty()) have += ' ';
    have += tags.back();
  }
  auto add = [&](size_t i) {
    for (auto &o : out)
      if (o.tag == tags[i]) return;
    OcrEng g;
    if (SUCCEEDED(st->TryCreateFromLanguage(ls[i].Get(), &g.e)) && g.e) {
      g.tag = tags[i];
      g.fam = fam_of(g.tag);
      out.push_back(g);
    }
  };
  auto first = [&](const char *w) -> int {
    for (size_t i = 0; i < tags.size(); i++)
      if (tag_is(tags[i], w)) return (int)i;
    return -1;
  };
  if (want && *want) {
    int i = first(want);
    if (i >= 0) add((size_t)i);
    return;
  }
  int zh = first("zh-Hans");
  if (zh < 0) zh = first("zh");
  if (zh >= 0) add((size_t)zh);
  for (const char *w : {"ja", "ko", "en"}) {
    int i = first(w);
    if (i >= 0) add((size_t)i);
  }
  OcrEng mine;
  if (SUCCEEDED(st->TryCreateFromUserProfileLanguages(&mine.e)) && mine.e) {
    mine.tag = tag_of(mine.e.Get());
    mine.fam = fam_of(mine.tag);
    int had = 0;
    for (auto &o : out) had |= o.fam == mine.fam && mine.fam != 'o';
    if (!had) out.push_back(mine);
  }
  if (out.empty() && !tags.empty()) add(0);
}

// How the characters of a reading fall: Chinese characters, kana, Hangul, Latin letters, digits, others (punctuation,
// symbols: what an engine reading a script not its own makes much of).
struct OcrCount {
  int han, kana, hangul, latin, digit, other;
};

static void count_of(const std::wstring &s, OcrCount &c) {
  memset(&c, 0, sizeof c);
  for (wchar_t ch : s) {
    if (ch == L' ' || ch == L'\n') continue;
    if ((ch >= 0x4E00 && ch <= 0x9FFF) || (ch >= 0x3400 && ch <= 0x4DBF) || (ch >= 0xF900 && ch <= 0xFAFF)) c.han++;
    else if ((ch >= 0x3040 && ch <= 0x30FF) || (ch >= 0x31F0 && ch <= 0x31FF) || (ch >= 0xFF66 && ch <= 0xFF9F)) c.kana++;
    else if ((ch >= 0xAC00 && ch <= 0xD7AF) || (ch >= 0x1100 && ch <= 0x11FF) || (ch >= 0x3130 && ch <= 0x318F)) c.hangul++;
    else if ((ch >= L'A' && ch <= L'Z') || (ch >= L'a' && ch <= L'z') || (ch >= 0xC0 && ch <= 0x24F) || (ch >= 0xFF21 && ch <= 0xFF5A)) c.latin++;
    else if ((ch >= L'0' && ch <= L'9') || (ch >= 0xFF10 && ch <= 0xFF19)) c.digit++;
    else c.other++;
  }
}

// What came of a reading: its words (UTF-8), the language read in, why it failed ("" it did not), the languages there
// are; with `all`, every engine's reading (the command line's, to see how they are told apart).
struct OcrOut {
  std::string text;
  std::string lang;
  std::string have;
  std::string all;
  const char *why;
  int lines;
  int tried;
  double ms;
};

static std::string utf8_of(const std::wstring &w) {
  std::string o;
  int m = WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(), NULL, 0, NULL, NULL);
  o.assign(m > 0 ? m : 0, '\0');
  if (m > 0) WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(), &o[0], m, NULL, NULL);
  return o;
}

// One engine's reading of `bmp`, its lines put back together. False: it failed.
static bool read_with(OCR::IOcrEngine *engine, WI::ISoftwareBitmap *bmp, std::wstring &all, int *nlines) {
  ComPtr<WF::IAsyncOperation<OCR::OcrResult *>> op;
  ComPtr<OCR::IOcrResult> res;
  if (FAILED(engine->RecognizeAsync(bmp, &op)) || FAILED(ocr_wait(op.Get(), res.GetAddressOf())) || !res) return false;
  ComPtr<WFC::IVectorView<OCR::OcrLine *>> lines;
  if (FAILED(res->get_Lines(&lines))) return false;
  UINT32 nl = 0;
  lines->get_Size(&nl);
  *nlines = 0;
  for (UINT32 i = 0; i < nl; i++) {
    ComPtr<OCR::IOcrLine> line;
    ComPtr<WFC::IVectorView<OCR::OcrWord *>> ws;
    if (FAILED(lines->GetAt(i, &line)) || FAILED(line->get_Words(&ws))) continue;
    UINT32 nw = 0;
    ws->get_Size(&nw);
    std::wstring l;
    for (UINT32 j = 0; j < nw; j++) {
      ComPtr<OCR::IOcrWord> word;
      HString t;
      if (FAILED(ws->GetAt(j, &word)) || FAILED(word->get_Text(t.GetAddressOf()))) continue;
      UINT32 n = 0;
      const wchar_t *s = WindowsGetStringRawBuffer(t.Get(), &n);
      if (!s || n == 0) continue;
      int space = !l.empty() && !(unspaced(l.back()) && unspaced(s[0]));
      if (space) l.push_back(L' ');
      l.append(s, n);
    }
    if (l.empty()) continue;
    if (!all.empty()) all.push_back(L'\n');
    all += l;
    (*nlines)++;
  }
  return true;
}

// Which of the readings (one by each engine, of one picture) to keep. Each engine gives only its own script, and
// reads a script not its own as nonsense of its own script (the Korean reads Chinese characters and Latin too), so it is
// told by what the engines of the scripts that are not alike see (tried on the four languages and their mixes with
// English, at 13 and 18 px, with the older engine some Windows have):
// - Korean: the Korean engine's reading is mostly Hangul beside its Chinese characters (Korean ones 0.95-1, others'
//   at most 0.41);
// - else Japanese: the Japanese engine's reading has kana, many beside its Chinese characters (Japanese ones
//   0.68-0.7, Chinese ones 0.03-0.09: a kana made of a stroke now and then);
// - else Chinese where the Chinese engine reads Chinese characters (it reads the Latin among them as well);
// - else Latin: the person's own language where it is another (French...), else English, else what there is.
struct OcrGot {
  std::wstring text;
  OcrCount c;
  int lines;
  char fam;
  const std::string *tag;
};

static int which_of(const std::vector<OcrGot> &got) {
  int n = (int)got.size();
  auto find = [&](char f) {
    for (int i = 0; i < n; i++)
      if (got[i].fam == f) return i;
    return -1;
  };
  int k = find('k'), j = find('j'), z = find('z'), e = find('e'), x = find('o');
  if (k >= 0) {
    const OcrCount &c = got[k].c;
    if (c.hangul >= 2 && c.hangul >= 0.7 * (c.hangul + c.han)) return k;
  }
  if (j >= 0) {
    const OcrCount &c = got[j].c;
    if (c.kana >= 3 && c.kana >= 0.3 * (c.kana + c.han)) return j;
  }
  if (z >= 0 && got[z].c.han >= 2) return z;
  auto letters = [&](int i) {
    const OcrCount &c = got[i].c;
    return c.latin + c.digit;
  };
  if (x >= 0 && letters(x) > 0) return x;
  if (e >= 0 && letters(e) > 0) return e;
  // (nothing like any: the one that read the most)
  int best = -1, most = -1;
  for (int i = 0; i < n; i++) {
    const OcrCount &c = got[i].c;
    int m = c.han + c.kana + c.hangul + c.latin + c.digit;
    if (m > most) most = m, best = i;
  }
  return best;
}

static void ocr_run(const uint8_t *png, int len, const char *want, bool every, OcrOut *o) {
  LARGE_INTEGER f, t0, t1;
  QueryPerformanceFrequency(&f);
  QueryPerformanceCounter(&t0);
  o->why = "";
  o->lines = 0;
  o->tried = 0;
  o->ms = 0;
  ComPtr<OCR::IOcrEngineStatics> st;
  if (FAILED(RoGetActivationFactory(HStringReference(RuntimeClass_Windows_Media_Ocr_OcrEngine).Get(),
                                    IID_PPV_ARGS(&st)))) {
    o->why = "no-ocr";
    return;
  }
  std::vector<OcrEng> engines;
  engines_of(st, want, engines, o->have);
  if (engines.empty()) {
    o->why = want && *want ? "missing" : "no-language";
    if (want && *want) o->lang = want;
    return;
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
  std::vector<OcrGot> got;
  for (auto &g : engines) {
    OcrGot r;
    r.lines = 0;
    if (!read_with(g.e.Get(), bmp.Get(), r.text, &r.lines)) continue;
    count_of(r.text, r.c);
    r.fam = g.fam;
    r.tag = &g.tag;
    got.push_back(r);
    if (every) {
      char head[200];
      snprintf(head, sizeof head, "---- %s han %d kana %d hangul %d latin %d digit %d other %d\n", g.tag.c_str(),
               r.c.han, r.c.kana, r.c.hangul, r.c.latin, r.c.digit, r.c.other);
      o->all += head;
      o->all += utf8_of(r.text);
      o->all += "\n";
    }
  }
  o->tried = (int)got.size();
  int pick = which_of(got);
  if (pick >= 0) {
    o->text = utf8_of(got[pick].text);
    o->lang = *got[pick].tag;
    o->lines = got[pick].lines;
  } else {
    o->why = "failed";
  }
  QueryPerformanceCounter(&t1);
  o->ms = (double)(t1.QuadPart - t0.QuadPart) * 1000.0 / f.QuadPart;
}

struct OcrJob {
  int id;
  int len;
  char want[24];
  uint8_t png[1];
};

static DWORD WINAPI ocr_thread(LPVOID p) {
  OcrJob *job = (OcrJob *)p;
  RoInitialize(RO_INIT_MULTITHREADED);
  OcrOut o;
  ocr_run(job->png, job->len, job->want, false, &o);
  char json[512];
  int n = snprintf(json, sizeof json,
                   "{\"do\":\"ocr\",\"id\":%d,\"why\":\"%s\",\"lang\":\"%.40s\",\"have\":\"%.300s\",\"lines\":%d,"
                   "\"tried\":%d,\"ms\":%.0f}",
                   job->id, o.why, o.lang.c_str(), o.have.c_str(), o.lines, o.tried, o.ms);
  if (n < 0 || n >= (int)sizeof json) n = 0;
  mb_post("ps", json, (size_t)n, (const uint8_t *)o.text.data(), o.text.size());
  free(job);
  RoUninitialize();
  return 0;
}

static void want_of(moonbit_bytes_t want, char *out, size_t cap) {
  size_t wl = want ? (size_t)Moonbit_array_length(want) : 0;
  size_t k = 0;
  for (size_t i = 0; i < wl && k + 1 < cap; i++) {
    char ch = (char)want[i];
    if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || ch == '-') out[k++] = ch;
  }
  out[k] = 0;
}

// The words in `png` read on a thread of their own, in language `want` ("" the one that reads best), told back as
// {"do":"ocr","id":id,...} with them: 1 it is begun.
extern "C" int ps_ocr(int id, moonbit_bytes_t png, moonbit_bytes_t want) {
  int len = (int)Moonbit_array_length(png);
  if (len <= 0) return 0;
  OcrJob *job = (OcrJob *)malloc(sizeof(OcrJob) + len);
  if (!job) return 0;
  job->id = id;
  job->len = len;
  want_of(want, job->want, sizeof job->want);
  memcpy(job->png, png, len);
  HANDLE t = CreateThread(NULL, 0, ocr_thread, job, 0, NULL);
  if (!t) {
    free(job);
    return 0;
  }
  CloseHandle(t);
  return 1;
}

// The words in `png` read now (the command line's --ocr): "why\tlang\tms\thave\n" then them; `want` "*": every
// engine's reading, counted, before.
extern "C" moonbit_bytes_t ps_ocr_now(moonbit_bytes_t png, moonbit_bytes_t want) {
  int len = (int)Moonbit_array_length(png);
  char w[24];
  want_of(want, w, sizeof w);
  bool every = want && Moonbit_array_length(want) == 1 && want[0] == '*';
  OcrOut o;
  o.why = "bad-picture";
  o.lines = 0;
  o.tried = 0;
  o.ms = 0;
  if (len > 0) {
    HRESULT ro = RoInitialize(RO_INIT_MULTITHREADED);
    ocr_run(png, len, w, every, &o);
    if (SUCCEEDED(ro)) RoUninitialize();
  }
  char head[512];
  snprintf(head, sizeof head, "%s\t%.40s\t%.0f\t%.300s\n", o.why, o.lang.c_str(), o.ms, o.have.c_str());
  std::string all = (every ? o.all + "==== " : std::string()) + std::string(head) + o.text;
  moonbit_bytes_t b = moonbit_make_bytes((int32_t)all.size(), 0);
  if (!all.empty()) memcpy(b, all.data(), all.size());
  return b;
}
