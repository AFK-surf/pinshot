// Lightweight area screen recorder (Windows): captures a selected monitor region via a dedicated
// Windows.Graphics.Capture session (with optional cursor and HDR FP16 -> sRGB GPU conversion) on a worker thread,
// encoding either:
//   - MP4 via Media Foundation IMFSinkWriter with optimal automatic cascade:
//       1) Hardware HEVC (H.265) + D3D11 VideoProcessor GPU NV12 (zero CPU pixel copy; patches 'hev1' -> 'hvc1' for
//          Apple/browser compatibility)
//       2) Hardware H.264 + D3D11 VideoProcessor GPU NV12 (zero CPU pixel copy)
//       3) Software H.264 + CPU BT.709 NV12 (handles tiny regions or systems without hardware MFT)
//   - Animated GIF via streaming GIF89a with adaptive 15-bit Median-Cut 255-color palette, dirty-rect differencing,
//     static-frame delay merging, and LZW compression (zero external libraries).
//
// Zero idle overhead: no thread, no D3D11 device, and no Media Foundation state exist when not recording.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <shellapi.h>
#include <shlobj.h>
#include <dwmapi.h>
#include <d3d11.h>
#include <d3d11_1.h>
#include <dxgi1_3.h>
#include <d3dcompiler.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mferror.h>
#include <codecapi.h>
#include <mmsystem.h>
#include <roapi.h>
#include <wrl.h>
#include <wrl/wrappers/corewrappers.h>
#include <windows.foundation.h>
#include <windows.graphics.capture.h>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.h>
#include <windows.graphics.directx.direct3d11.interop.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <algorithm>
#include <string>
#include <vector>

extern "C" {
#include "moonbit.h"
}

#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "d3dcompiler.lib")
#pragma comment(lib, "runtimeobject.lib")
#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfreadwrite.lib")
#pragma comment(lib, "mfuuid.lib")
#pragma comment(lib, "dwmapi.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "winmm.lib")

#ifndef WDA_EXCLUDEFROMCAPTURE
#define WDA_EXCLUDEFROMCAPTURE 0x11
#endif

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;
using Microsoft::WRL::Wrappers::HStringReference;
namespace WGC = ABI::Windows::Graphics::Capture;
namespace WD3D = ABI::Windows::Graphics::DirectX::Direct3D11;
using ABI::Windows::Foundation::ITypedEventHandler;

extern "C" void mb_post(const char *channel, const char *json, size_t len, const uint8_t *bytes, size_t blen);
extern "C" void *mb_app_hwnd_of(int wid);
extern "C" int ps_wgc_mon_hdr(HMONITOR mon, float *white);
extern "C" int ps_wgc_borderless_ok(void);

// ---- helpers ----

static moonbit_bytes_t rec_bytes_of(const void *p, size_t n) {
  moonbit_bytes_t b = moonbit_make_bytes((int32_t)n, 0);
  if (n) memcpy(b, p, n);
  return b;
}

static std::wstring utf8_to_wide(const char *s, int len) {
  if (!s || len <= 0) return L"";
  int n = MultiByteToWideChar(CP_UTF8, 0, s, len, NULL, 0);
  if (n <= 0) return L"";
  std::wstring out((size_t)n, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s, len, &out[0], n);
  while (!out.empty() && out.back() == L'\0') out.pop_back();
  return out;
}

static std::string wide_to_utf8(const std::wstring &w) {
  if (w.empty()) return "";
  int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), NULL, 0, NULL, NULL);
  if (n <= 0) return "";
  std::string out((size_t)n, '\0');
  WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), &out[0], n, NULL, NULL);
  return out;
}

static std::string json_escape(const std::string &s) {
  std::string out;
  out.reserve(s.size() + 16);
  for (unsigned char c : s) {
    if (c == '\\') out += "\\\\";
    else if (c == '"') out += "\\\"";
    else if (c == '\n') out += "\\n";
    else if (c == '\r') out += "\\r";
    else if (c == '\t') out += "\\t";
    else if (c >= 0x20) out.push_back((char)c);
  }
  return out;
}

static void rec_make_dirs(const std::wstring &path) {
  size_t pos = path.find_last_of(L"\\/");
  if (pos == std::wstring::npos || pos == 0) return;
  std::wstring dir = path.substr(0, pos);
  SHCreateDirectoryExW(NULL, dir.c_str(), NULL);
}

static void rec_post(const char *state, int64_t ms, int frames, uint64_t bytes, const char *codec,
                     const std::wstring &path, const char *err) {
  std::string p_esc = json_escape(wide_to_utf8(path));
  std::string e_esc = err ? json_escape(err) : "";
  std::string c_esc = codec ? json_escape(codec) : "";
  char buf[1536];
  int n = snprintf(buf, sizeof buf,
                   "{\"do\":\"rec\",\"state\":\"%s\",\"ms\":%lld,\"frames\":%d,\"bytes\":%llu,"
                   "\"codec\":\"%s\",\"path\":\"%s\",\"err\":\"%s\"}",
                   state, (long long)ms, frames, (unsigned long long)bytes,
                   c_esc.c_str(), p_esc.c_str(), e_esc.c_str());
  if (n > 0) {
    size_t len = (size_t)n < sizeof buf ? (size_t)n : sizeof buf - 1;
    mb_post("ps", buf, len, NULL, 0);
  }
}

static int copy_file_to_clipboard(const std::wstring &path) {
  if (path.empty()) return 0;
  // In automated tests, write the output path to PINSHOT_TEST_COPY if set, and never clobber the user's clipboard.
  const char *test_copy = getenv("PINSHOT_TEST_COPY");
  if (test_copy && test_copy[0]) {
    FILE *f = NULL;
    if (fopen_s(&f, test_copy, "wb") == 0 && f) {
      std::string u = wide_to_utf8(path);
      fwrite(u.data(), 1, u.size(), f);
      fclose(f);
    }
    return 1;
  }
  const char *test_run = getenv("PINSHOT_TEST");
  if (test_run && test_run[0] && strcmp(test_run, "0") != 0) return 1;

  size_t bytes = sizeof(DROPFILES) + (path.size() + 2) * sizeof(wchar_t);
  HGLOBAL hMem = GlobalAlloc(GHND | GMEM_SHARE, bytes);
  if (!hMem) return 0;
  DROPFILES *df = (DROPFILES *)GlobalLock(hMem);
  if (!df) {
    GlobalFree(hMem);
    return 0;
  }
  df->pFiles = sizeof(DROPFILES);
  df->fWide = TRUE;
  wchar_t *dst = (wchar_t *)((uint8_t *)df + sizeof(DROPFILES));
  memcpy(dst, path.c_str(), path.size() * sizeof(wchar_t));
  dst[path.size()] = L'\0';
  dst[path.size() + 1] = L'\0';
  GlobalUnlock(hMem);

  HGLOBAL hEff = GlobalAlloc(GHND | GMEM_SHARE, sizeof(DWORD));
  if (hEff) {
    DWORD *eff = (DWORD *)GlobalLock(hEff);
    if (eff) {
      *eff = DROPEFFECT_COPY;
      GlobalUnlock(hEff);
    }
  }

  int ok = 0;
  for (int tries = 0; tries < 5; tries++) {
    if (OpenClipboard(NULL)) {
      EmptyClipboard();
      if (SetClipboardData(CF_HDROP, hMem)) {
        ok = 1;
        hMem = NULL;
        if (hEff) {
          UINT cf_eff = RegisterClipboardFormatW(L"Preferred DropEffect");
          if (cf_eff && SetClipboardData(cf_eff, hEff)) hEff = NULL;
        }
      }
      CloseClipboard();
      break;
    }
    Sleep(10);
  }
  if (hMem) GlobalFree(hMem);
  if (hEff) GlobalFree(hEff);
  return ok;
}

// ---- recording border frame (UI thread) ----

#define REC_FRAME_LINE 2
#define REC_FRAME_KEY RGB(1, 2, 3)

static struct {
  int prepared;
  int x, y, w, h;          // clamped even region in virtual screen pixels
  HMONITOR mon;
  int mx, my, mw, mh;      // monitor bounds
  HWND frame;
  COLORREF frame_color;

  HANDLE thread;
  HANDLE wake_ev;
  volatile LONG stop_req;  // 0 running, 1 finish & save, 2 cancel & discard
  volatile LONG pause_req; // 0 running, 1 paused
  volatile LONG running;

  std::wstring out_path;
  int fmt;                 // 0 = MP4, 1 = GIF
  int fps;
  int cursor;
} R;

static void rec_exclude_hwnd(HWND h) {
  if (!getenv("PINSHOT_REC_SHOW")) SetWindowDisplayAffinity(h, WDA_EXCLUDEFROMCAPTURE);
}

static LRESULT CALLBACK rec_frame_proc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
  if (msg == WM_PAINT) {
    PAINTSTRUCT ps;
    HDC dc = BeginPaint(h, &ps);
    RECT r;
    GetClientRect(h, &r);
    HBRUSH key = CreateSolidBrush(REC_FRAME_KEY);
    HBRUSH line = CreateSolidBrush(R.frame_color ? R.frame_color : RGB(0x2F, 0x9B, 0xFF));
    FillRect(dc, &r, line);
    RECT in = {REC_FRAME_LINE, REC_FRAME_LINE, r.right - REC_FRAME_LINE, r.bottom - REC_FRAME_LINE};
    FillRect(dc, &in, key);
    DeleteObject(key);
    DeleteObject(line);
    EndPaint(h, &ps);
    return 0;
  }
  return DefWindowProcW(h, msg, wp, lp);
}

static void rec_frame_show(COLORREF color) {
  static int registered = 0;
  if (!registered) {
    WNDCLASSEXW wc = {};
    wc.cbSize = sizeof wc;
    wc.lpfnWndProc = rec_frame_proc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = L"PinShot.RecFrame";
    wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    RegisterClassExW(&wc);
    registered = 1;
  }
  R.frame_color = color;
  if (R.frame) {
    InvalidateRect(R.frame, NULL, FALSE);
    return;
  }
  int fx = R.x - REC_FRAME_LINE, fy = R.y - REC_FRAME_LINE;
  int fw = R.w + REC_FRAME_LINE * 2, fh = R.h + REC_FRAME_LINE * 2;
  R.frame = CreateWindowExW(WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
                            L"PinShot.RecFrame", L"", WS_POPUP, fx, fy, fw, fh, NULL, NULL, GetModuleHandleW(NULL), NULL);
  if (!R.frame) return;
  SetLayeredWindowAttributes(R.frame, REC_FRAME_KEY, 255, LWA_COLORKEY);
  rec_exclude_hwnd(R.frame);
  ShowWindow(R.frame, SW_SHOWNOACTIVATE);
}

static void rec_frame_hide(void) {
  if (R.frame) {
    DestroyWindow(R.frame);
    R.frame = NULL;
  }
}

// ---- MP4 HEVC 'hev1' -> 'hvc1' in-place box patcher (for Apple/Safari/iOS compatibility) ----

static uint32_t read_be32(const uint8_t *p) {
  return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static uint64_t read_be64(const uint8_t *p) {
  return ((uint64_t)read_be32(p) << 32) | (uint64_t)read_be32(p + 4);
}

static uint32_t fourcc(char a, char b, char c, char d) {
  return ((uint32_t)(uint8_t)a << 24) | ((uint32_t)(uint8_t)b << 16) | ((uint32_t)(uint8_t)c << 8) | (uint32_t)(uint8_t)d;
}

struct Mp4Box {
  size_t start;
  size_t payload;
  size_t end;
  uint32_t type;
};

static bool read_mp4_box(const std::vector<uint8_t> &buf, size_t off, size_t limit, Mp4Box &out) {
  if (off + 8 > limit) return false;
  uint64_t sz = read_be32(&buf[off]);
  uint32_t ty = read_be32(&buf[off + 4]);
  size_t hdr = 8;
  if (sz == 1) {
    if (off + 16 > limit) return false;
    sz = read_be64(&buf[off + 8]);
    hdr = 16;
  } else if (sz == 0) {
    sz = limit - off;
  }
  if (sz < hdr || off + sz > limit) return false;
  out.start = off;
  out.payload = off + hdr;
  out.end = (size_t)(off + sz);
  out.type = ty;
  return true;
}

static bool find_mp4_child(const std::vector<uint8_t> &buf, size_t from, size_t limit, uint32_t type, Mp4Box &out) {
  Mp4Box b;
  for (size_t off = from; read_mp4_box(buf, off, limit, b); off = b.end) {
    if (b.type == type) {
      out = b;
      return true;
    }
  }
  return false;
}

static void patch_mp4_hev1_to_hvc1(const std::wstring &path) {
  HANDLE hf = CreateFileW(path.c_str(), GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ, NULL, OPEN_EXISTING,
                          FILE_ATTRIBUTE_NORMAL, NULL);
  if (hf == INVALID_HANDLE_VALUE) return;
  LARGE_INTEGER fsz = {};
  if (!GetFileSizeEx(hf, &fsz) || fsz.QuadPart < 16) {
    CloseHandle(hf);
    return;
  }
  uint64_t total = (uint64_t)fsz.QuadPart;
  uint64_t pos = 0;
  uint64_t moov_off = 0, moov_sz = 0;
  while (pos + 8 <= total) {
    LARGE_INTEGER li;
    li.QuadPart = (LONGLONG)pos;
    if (!SetFilePointerEx(hf, li, NULL, FILE_BEGIN)) break;
    uint8_t hdr[16] = {};
    DWORD got = 0;
    if (!ReadFile(hf, hdr, (DWORD)std::min<uint64_t>(16, total - pos), &got, NULL) || got < 8) break;
    uint64_t sz = read_be32(hdr);
    uint32_t ty = read_be32(hdr + 4);
    if (sz == 1) {
      if (got < 16) break;
      sz = read_be64(hdr + 8);
    } else if (sz == 0) {
      sz = total - pos;
    }
    if (sz < 8 || pos + sz > total) break;
    if (ty == fourcc('m', 'o', 'o', 'v')) {
      moov_off = pos;
      moov_sz = sz;
      break;
    }
    pos += sz;
  }
  if (moov_sz == 0 || moov_sz > 32ULL * 1024ULL * 1024ULL) {
    CloseHandle(hf);
    return;
  }
  std::vector<uint8_t> moov((size_t)moov_sz);
  LARGE_INTEGER li;
  li.QuadPart = (LONGLONG)moov_off;
  DWORD got = 0;
  if (!SetFilePointerEx(hf, li, NULL, FILE_BEGIN) || !ReadFile(hf, moov.data(), (DWORD)moov_sz, &got, NULL) ||
      got != moov_sz) {
    CloseHandle(hf);
    return;
  }
  Mp4Box moov_box;
  if (!read_mp4_box(moov, 0, moov.size(), moov_box)) {
    CloseHandle(hf);
    return;
  }
  bool changed = false;
  Mp4Box trak;
  for (size_t off = moov_box.payload; read_mp4_box(moov, off, moov_box.end, trak); off = trak.end) {
    if (trak.type != fourcc('t', 'r', 'a', 'k')) continue;
    Mp4Box mdia, minf, stbl, stsd, entry;
    if (!find_mp4_child(moov, trak.payload, trak.end, fourcc('m', 'd', 'i', 'a'), mdia)) continue;
    if (!find_mp4_child(moov, mdia.payload, mdia.end, fourcc('m', 'i', 'n', 'f'), minf)) continue;
    if (!find_mp4_child(moov, minf.payload, minf.end, fourcc('s', 't', 'b', 'l'), stbl)) continue;
    if (!find_mp4_child(moov, stbl.payload, stbl.end, fourcc('s', 't', 's', 'd'), stsd)) continue;
    if (stsd.payload + 8 >= stsd.end) continue;
    if (!read_mp4_box(moov, stsd.payload + 8, stsd.end, entry)) continue;
    if (entry.type == fourcc('h', 'e', 'v', '1')) {
      moov[entry.start + 4] = 'h';
      moov[entry.start + 5] = 'v';
      moov[entry.start + 6] = 'c';
      moov[entry.start + 7] = '1';
      changed = true;
    }
  }
  if (changed) {
    DWORD written = 0;
    if (SetFilePointerEx(hf, li, NULL, FILE_BEGIN)) {
      WriteFile(hf, moov.data(), (DWORD)moov.size(), &written, NULL);
    }
  }
  CloseHandle(hf);
}

// ---- Streaming GIF89a encoder (15-bit Median-Cut + dirty-rect + static-frame merge + LZW) ----

struct GifWriter {
  FILE *fp = NULL;
  int w = 0, h = 0;
  bool header_written = false;
  uint8_t global_pal[256 * 3];
  uint8_t global_lut[32768];

  std::vector<uint8_t> prev_rgb;        // w * h * 3 (last committed canvas RGB)
  bool has_pending = false;
  int pend_x = 0, pend_y = 0, pend_w = 0, pend_h = 0;
  int pend_delay_cs = 0;
  bool pend_local_pal = false;
  uint8_t pend_pal[256 * 3];
  std::vector<uint8_t> pend_idx;        // pend_w * pend_h
  int frames_written = 0;

  // Build 255-color adaptive palette (index 255 reserved for transparent) via 15-bit Median Cut.
  static void build_palette(const uint8_t *rgb, int n_pixels, const uint8_t *mask, uint8_t pal[256 * 3],
                            uint8_t lut[32768]) {
    static const int MAX_COLORS = 255;
    std::vector<uint32_t> hist(32768, 0);
    for (int i = 0; i < n_pixels; i++) {
      if (mask && !mask[i]) continue;
      uint32_t r = rgb[i * 3 + 0] >> 3;
      uint32_t g = rgb[i * 3 + 1] >> 3;
      uint32_t b = rgb[i * 3 + 2] >> 3;
      hist[(r << 10) | (g << 5) | b]++;
    }
    struct Entry {
      uint16_t key;
      uint32_t cnt;
    };
    std::vector<Entry> entries;
    entries.reserve(2048);
    for (uint32_t k = 0; k < 32768; k++) {
      if (hist[k]) entries.push_back({(uint16_t)k, hist[k]});
    }
    memset(pal, 0, 256 * 3);
    if (entries.empty()) {
      memset(lut, 0, 32768);
      return;
    }
    struct Box {
      size_t lo, hi;
      uint8_t r0, r1, g0, g1, b0, b1;
      uint64_t pop;
    };
    auto fit_box = [&](Box &bx) {
      bx.r0 = bx.g0 = bx.b0 = 31;
      bx.r1 = bx.g1 = bx.b1 = 0;
      bx.pop = 0;
      for (size_t i = bx.lo; i < bx.hi; i++) {
        uint16_t k = entries[i].key;
        uint8_t r = (uint8_t)((k >> 10) & 31);
        uint8_t g = (uint8_t)((k >> 5) & 31);
        uint8_t b = (uint8_t)(k & 31);
        if (r < bx.r0) bx.r0 = r;
        if (r > bx.r1) bx.r1 = r;
        if (g < bx.g0) bx.g0 = g;
        if (g > bx.g1) bx.g1 = g;
        if (b < bx.b0) bx.b0 = b;
        if (b > bx.b1) bx.b1 = b;
        bx.pop += entries[i].cnt;
      }
    };
    std::vector<Box> boxes;
    boxes.reserve(MAX_COLORS);
    Box root = {0, entries.size(), 0, 31, 0, 31, 0, 31, 0};
    fit_box(root);
    boxes.push_back(root);

    while ((int)boxes.size() < MAX_COLORS) {
      int best = -1;
      uint64_t best_score = 0;
      for (int i = 0; i < (int)boxes.size(); i++) {
        const Box &bx = boxes[i];
        if (bx.hi - bx.lo < 2) continue;
        int dr = bx.r1 - bx.r0, dg = bx.g1 - bx.g0, db = bx.b1 - bx.b0;
        int span = std::max({dr, dg, db});
        if (span == 0) continue;
        uint64_t score = (uint64_t)span * bx.pop;
        if (score > best_score) {
          best_score = score;
          best = i;
        }
      }
      if (best < 0) break;
      Box bx = boxes[best];
      int dr = bx.r1 - bx.r0, dg = bx.g1 - bx.g0, db = bx.b1 - bx.b0;
      int shift = (dg >= dr && dg >= db) ? 5 : (dr >= db ? 10 : 0);
      std::sort(entries.begin() + (ptrdiff_t)bx.lo, entries.begin() + (ptrdiff_t)bx.hi,
                [shift](const Entry &a, const Entry &b) {
                  return ((a.key >> shift) & 31) < ((b.key >> shift) & 31);
                });
      uint64_t half = bx.pop / 2, acc = 0;
      size_t mid = bx.lo + 1;
      for (size_t i = bx.lo; i + 1 < bx.hi; i++) {
        acc += entries[i].cnt;
        mid = i + 1;
        if (acc >= half) break;
      }
      Box b1 = {bx.lo, mid, 0, 0, 0, 0, 0, 0, 0};
      Box b2 = {mid, bx.hi, 0, 0, 0, 0, 0, 0, 0};
      fit_box(b1);
      fit_box(b2);
      boxes[best] = b1;
      boxes.push_back(b2);
    }

    int ncols = (int)boxes.size();
    for (int i = 0; i < ncols; i++) {
      uint64_t sr = 0, sg = 0, sb = 0, cnt = 0;
      for (size_t j = boxes[i].lo; j < boxes[i].hi; j++) {
        uint16_t k = entries[j].key;
        uint64_t c = entries[j].cnt;
        uint32_t r = ((k >> 10) & 31) * 255 / 31;
        uint32_t g = ((k >> 5) & 31) * 255 / 31;
        uint32_t b = (k & 31) * 255 / 31;
        sr += r * c;
        sg += g * c;
        sb += b * c;
        cnt += c;
      }
      pal[i * 3 + 0] = (uint8_t)(cnt ? sr / cnt : 0);
      pal[i * 3 + 1] = (uint8_t)(cnt ? sg / cnt : 0);
      pal[i * 3 + 2] = (uint8_t)(cnt ? sb / cnt : 0);
    }
    // Fill direct mapping for observed 15-bit buckets + nearest match for any other bucket.
    memset(lut, 0xFF, 32768);
    for (int i = 0; i < ncols; i++) {
      for (size_t j = boxes[i].lo; j < boxes[i].hi; j++) {
        lut[entries[j].key] = (uint8_t)i;
      }
    }
    for (int k = 0; k < 32768; k++) {
      if (lut[k] != 0xFF) continue;
      int r = ((k >> 10) & 31) * 255 / 31;
      int g = ((k >> 5) & 31) * 255 / 31;
      int b = (k & 31) * 255 / 31;
      int best_i = 0, best_d = 1 << 30;
      for (int i = 0; i < ncols; i++) {
        int dr = r - (int)pal[i * 3 + 0];
        int dg = g - (int)pal[i * 3 + 1];
        int db = b - (int)pal[i * 3 + 2];
        int d = dr * dr * 2 + dg * dg * 4 + db * db;
        if (d < best_d) {
          best_d = d;
          best_i = i;
        }
      }
      lut[k] = (uint8_t)best_i;
    }
  }

  bool open(const std::wstring &path, int width, int height) {
    if (_wfopen_s(&fp, path.c_str(), L"wb") != 0 || !fp) return false;
    w = width;
    h = height;
    prev_rgb.assign((size_t)w * h * 3, 0);
    header_written = false;
    has_pending = false;
    frames_written = 0;
    return true;
  }

  void write_u16(uint16_t v) {
    uint8_t b[2] = {(uint8_t)(v & 0xFF), (uint8_t)((v >> 8) & 0xFF)};
    fwrite(b, 1, 2, fp);
  }

  void write_header() {
    fwrite("GIF89a", 1, 6, fp);
    write_u16((uint16_t)w);
    write_u16((uint16_t)h);
    uint8_t packed = 0xF7;  // GCT flag=1, color res=7 (8-bit), sort=0, size=7 (256 entries)
    fputc(packed, fp);
    fputc(0, fp);           // bg index
    fputc(0, fp);           // pixel aspect
    fwrite(global_pal, 1, 256 * 3, fp);
    // NETSCAPE2.0 infinite loop extension
    static const uint8_t netscape[] = {0x21, 0xFF, 0x0B, 'N', 'E', 'T', 'S', 'C', 'A', 'P', 'E', '2', '.', '0',
                                       0x03, 0x01, 0x00, 0x00, 0x00};
    fwrite(netscape, 1, sizeof netscape, fp);
    header_written = true;
  }

  void write_lzw(const uint8_t *indices, size_t count) {
    const int min_code_size = 8;
    const int clear_code = 256;
    const int eoi_code = 257;
    fputc(min_code_size, fp);

    // Open-addressed hash table for (prefix << 8 | ch) -> code (size 8192 power of two, fast reset).
    static const int HT_SIZE = 8192;
    std::vector<int32_t> ht_key(HT_SIZE, -1);
    std::vector<uint16_t> ht_val(HT_SIZE, 0);

    uint8_t sub[256];
    int sub_len = 0;
    uint32_t bit_buf = 0;
    int bit_cnt = 0;

    auto flush_sub = [&]() {
      if (sub_len > 0) {
        fputc(sub_len, fp);
        fwrite(sub, 1, (size_t)sub_len, fp);
        sub_len = 0;
      }
    };
    auto emit_code = [&](int code, int bits) {
      bit_buf |= ((uint32_t)code << bit_cnt);
      bit_cnt += bits;
      while (bit_cnt >= 8) {
        sub[sub_len++] = (uint8_t)(bit_buf & 0xFF);
        bit_buf >>= 8;
        bit_cnt -= 8;
        if (sub_len == 255) flush_sub();
      }
    };

    int next_code = eoi_code + 1;
    int code_bits = min_code_size + 1;
    emit_code(clear_code, code_bits);

    if (count > 0) {
      int prefix = indices[0];
      for (size_t i = 1; i < count; i++) {
        int ch = indices[i];
        int32_t key = (prefix << 8) | ch;
        int slot = ((key * 2654435761u) >> 19) & (HT_SIZE - 1);
        int found = -1;
        while (ht_key[slot] != -1) {
          if (ht_key[slot] == key) {
            found = ht_val[slot];
            break;
          }
          slot = (slot + 1) & (HT_SIZE - 1);
        }
        if (found >= 0) {
          prefix = found;
        } else {
          emit_code(prefix, code_bits);
          if (next_code < 4096) {
            ht_key[slot] = key;
            ht_val[slot] = (uint16_t)next_code++;
            if (next_code > (1 << code_bits) && code_bits < 12) code_bits++;
          } else {
            emit_code(clear_code, code_bits);
            std::fill(ht_key.begin(), ht_key.end(), -1);
            next_code = eoi_code + 1;
            code_bits = min_code_size + 1;
          }
          prefix = ch;
        }
      }
      emit_code(prefix, code_bits);
    }

    emit_code(eoi_code, code_bits);
    if (bit_cnt > 0) {
      sub[sub_len++] = (uint8_t)(bit_buf & 0xFF);
      if (sub_len == 255) flush_sub();
    }
    flush_sub();
    fputc(0, fp);  // block terminator
  }

  void flush_pending() {
    if (!has_pending || !fp) return;
    if (!header_written) write_header();
    uint16_t delay = (uint16_t)(pend_delay_cs < 2 ? 2 : (pend_delay_cs > 65535 ? 65535 : pend_delay_cs));
    // Graphic Control Extension: disposal=1 (keep canvas), transparent=1 (index 255)
    uint8_t gce[8] = {0x21, 0xF9, 0x04, 0x05, (uint8_t)(delay & 0xFF), (uint8_t)((delay >> 8) & 0xFF), 255, 0x00};
    fwrite(gce, 1, sizeof gce, fp);
    // Image Descriptor
    fputc(0x2C, fp);
    write_u16((uint16_t)pend_x);
    write_u16((uint16_t)pend_y);
    write_u16((uint16_t)pend_w);
    write_u16((uint16_t)pend_h);
    fputc(pend_local_pal ? 0x87 : 0x00, fp);
    if (pend_local_pal) fwrite(pend_pal, 1, 256 * 3, fp);
    write_lzw(pend_idx.data(), pend_idx.size());
    has_pending = false;
    frames_written++;
  }

  void add_frame(const uint8_t *rgb, int delay_cs) {
    if (!fp) return;
    const int n = w * h;
    if (!header_written && !has_pending) {
      build_palette(rgb, n, NULL, global_pal, global_lut);
      pend_x = 0;
      pend_y = 0;
      pend_w = w;
      pend_h = h;
      pend_delay_cs = delay_cs;
      pend_local_pal = false;
      pend_idx.resize((size_t)n);
      for (int i = 0; i < n; i++) {
        uint32_t k = (((uint32_t)rgb[i * 3 + 0] >> 3) << 10) | (((uint32_t)rgb[i * 3 + 1] >> 3) << 5) |
                     ((uint32_t)rgb[i * 3 + 2] >> 3);
        uint8_t idx = global_lut[k];
        pend_idx[i] = idx;
        prev_rgb[i * 3 + 0] = global_pal[idx * 3 + 0];
        prev_rgb[i * 3 + 1] = global_pal[idx * 3 + 1];
        prev_rgb[i * 3 + 2] = global_pal[idx * 3 + 2];
      }
      has_pending = true;
      return;
    }

    // Find dirty bounding box compared against committed canvas (tolerance ignores tiny noise).
    int x0 = w, y0 = h, x1 = -1, y1 = -1;
    int changed = 0;
    for (int y = 0; y < h; y++) {
      const uint8_t *cur = rgb + (size_t)y * w * 3;
      const uint8_t *prv = prev_rgb.data() + (size_t)y * w * 3;
      for (int x = 0; x < w; x++) {
        int dr = abs((int)cur[x * 3 + 0] - (int)prv[x * 3 + 0]);
        int dg = abs((int)cur[x * 3 + 1] - (int)prv[x * 3 + 1]);
        int db = abs((int)cur[x * 3 + 2] - (int)prv[x * 3 + 2]);
        if (dr + dg + db > 12) {
          if (x < x0) x0 = x;
          if (x > x1) x1 = x;
          if (y < y0) y0 = y;
          if (y > y1) y1 = y;
          changed++;
        }
      }
    }

    if (changed == 0 && has_pending && pend_delay_cs + delay_cs <= 500) {
      pend_delay_cs += delay_cs;
      return;
    }
    flush_pending();
    if (changed == 0) {
      // Static screen exceeded 5s cap: emit a 1x1 transparent frame to carry delay.
      pend_x = 0;
      pend_y = 0;
      pend_w = 1;
      pend_h = 1;
      pend_delay_cs = delay_cs;
      pend_local_pal = false;
      pend_idx.assign(1, 255);
      has_pending = true;
      return;
    }

    int dw = x1 - x0 + 1;
    int dh = y1 - y0 + 1;
    // Check average quantization error of changed pixels against the global palette.
    uint64_t err_sum = 0;
    for (int y = y0; y <= y1; y++) {
      const uint8_t *cur = rgb + (size_t)y * w * 3;
      const uint8_t *prv = prev_rgb.data() + (size_t)y * w * 3;
      for (int x = x0; x <= x1; x++) {
        int dr0 = abs((int)cur[x * 3 + 0] - (int)prv[x * 3 + 0]);
        int dg0 = abs((int)cur[x * 3 + 1] - (int)prv[x * 3 + 1]);
        int db0 = abs((int)cur[x * 3 + 2] - (int)prv[x * 3 + 2]);
        if (dr0 + dg0 + db0 <= 12) continue;
        uint32_t k = (((uint32_t)cur[x * 3 + 0] >> 3) << 10) | (((uint32_t)cur[x * 3 + 1] >> 3) << 5) |
                     ((uint32_t)cur[x * 3 + 2] >> 3);
        uint8_t idx = global_lut[k];
        err_sum += (uint64_t)(abs((int)cur[x * 3 + 0] - (int)global_pal[idx * 3 + 0]) +
                              abs((int)cur[x * 3 + 1] - (int)global_pal[idx * 3 + 1]) +
                              abs((int)cur[x * 3 + 2] - (int)global_pal[idx * 3 + 2]));
      }
    }
    bool use_local = (changed > 256 && (err_sum / (uint64_t)changed) > 24);
    uint8_t local_lut[32768];
    const uint8_t *pal = global_pal;
    const uint8_t *lut = global_lut;
    if (use_local) {
      std::vector<uint8_t> crop((size_t)dw * dh * 3);
      std::vector<uint8_t> mask((size_t)dw * dh, 0);
      for (int y = 0; y < dh; y++) {
        const uint8_t *cur = rgb + ((size_t)(y0 + y) * w + x0) * 3;
        const uint8_t *prv = prev_rgb.data() + ((size_t)(y0 + y) * w + x0) * 3;
        memcpy(crop.data() + (size_t)y * dw * 3, cur, (size_t)dw * 3);
        for (int x = 0; x < dw; x++) {
          int d = abs((int)cur[x * 3 + 0] - (int)prv[x * 3 + 0]) + abs((int)cur[x * 3 + 1] - (int)prv[x * 3 + 1]) +
                  abs((int)cur[x * 3 + 2] - (int)prv[x * 3 + 2]);
          mask[(size_t)y * dw + x] = d > 12 ? 1 : 0;
        }
      }
      build_palette(crop.data(), dw * dh, mask.data(), pend_pal, local_lut);
      pal = pend_pal;
      lut = local_lut;
    }

    pend_x = x0;
    pend_y = y0;
    pend_w = dw;
    pend_h = dh;
    pend_delay_cs = delay_cs;
    pend_local_pal = use_local;
    pend_idx.resize((size_t)dw * dh);
    for (int y = 0; y < dh; y++) {
      const uint8_t *cur = rgb + ((size_t)(y0 + y) * w + x0) * 3;
      uint8_t *prv = prev_rgb.data() + ((size_t)(y0 + y) * w + x0) * 3;
      for (int x = 0; x < dw; x++) {
        int d = abs((int)cur[x * 3 + 0] - (int)prv[x * 3 + 0]) + abs((int)cur[x * 3 + 1] - (int)prv[x * 3 + 1]) +
                abs((int)cur[x * 3 + 2] - (int)prv[x * 3 + 2]);
        if (d <= 12) {
          pend_idx[(size_t)y * dw + x] = 255;
        } else {
          uint32_t k = (((uint32_t)cur[x * 3 + 0] >> 3) << 10) | (((uint32_t)cur[x * 3 + 1] >> 3) << 5) |
                       ((uint32_t)cur[x * 3 + 2] >> 3);
          uint8_t idx = lut[k];
          pend_idx[(size_t)y * dw + x] = idx;
          prv[x * 3 + 0] = pal[idx * 3 + 0];
          prv[x * 3 + 1] = pal[idx * 3 + 1];
          prv[x * 3 + 2] = pal[idx * 3 + 2];
        }
      }
    }
    has_pending = true;
  }

  uint64_t finish() {
    if (!fp) return 0;
    flush_pending();
    if (header_written) fputc(0x3B, fp);
    fflush(fp);
    int64_t sz = _ftelli64(fp);
    fclose(fp);
    fp = NULL;
    return sz > 0 ? (uint64_t)sz : 0;
  }

  void abort() {
    if (fp) {
      fclose(fp);
      fp = NULL;
    }
  }
};

// ---- CPU BT.709 BGRA/RGBA -> NV12 (studio range 16..235 / 16..240) for software fallback ----

static void rgb_to_nv12(const uint8_t *src, int pitch, bool is_bgra, int w, int h, uint8_t *dst_y, uint8_t *dst_uv) {
  int ro = is_bgra ? 2 : 0;
  int go = 1;
  int bo = is_bgra ? 0 : 2;
  for (int y = 0; y < h; y++) {
    const uint8_t *row = src + (size_t)y * pitch;
    uint8_t *dy = dst_y + (size_t)y * w;
    for (int x = 0; x < w; x++) {
      int r = row[x * 4 + ro], g = row[x * 4 + go], b = row[x * 4 + bo];
      int Y = ((47 * r + 157 * g + 16 * b + 128) >> 8) + 16;
      dy[x] = (uint8_t)(Y < 16 ? 16 : (Y > 235 ? 235 : Y));
    }
  }
  for (int y = 0; y < h; y += 2) {
    const uint8_t *r0 = src + (size_t)y * pitch;
    const uint8_t *r1 = src + (size_t)(y + 1) * pitch;
    uint8_t *duv = dst_uv + (size_t)(y / 2) * w;
    for (int x = 0; x < w; x += 2) {
      int r = (r0[x * 4 + ro] + r0[(x + 1) * 4 + ro] + r1[x * 4 + ro] + r1[(x + 1) * 4 + ro] + 2) >> 2;
      int g = (r0[x * 4 + go] + r0[(x + 1) * 4 + go] + r1[x * 4 + go] + r1[(x + 1) * 4 + go] + 2) >> 2;
      int b = (r0[x * 4 + bo] + r0[(x + 1) * 4 + bo] + r1[x * 4 + bo] + r1[(x + 1) * 4 + bo] + 2) >> 2;
      int U = ((-26 * r - 86 * g + 112 * b + 128) >> 8) + 128;
      int V = ((112 * r - 102 * g - 10 * b + 128) >> 8) + 128;
      duv[x + 0] = (uint8_t)(U < 16 ? 16 : (U > 240 ? 240 : U));
      duv[x + 1] = (uint8_t)(V < 16 ? 16 : (V > 240 ? 240 : V));
    }
  }
}

// ---- MP4 Encoder (Optimal Cascade: HW HEVC -> HW H.264 -> SW H.264) ----

struct Mp4Encoder {
  bool mf_up = false;
  bool gpu_path = false;
  bool is_hevc = false;
  std::string codec_name;
  int out_w = 0, out_h = 0, fps = 30;
  std::wstring out_path;

  ComPtr<IMFDXGIDeviceManager> dev_mgr;
  ComPtr<IMFSinkWriter> writer;
  DWORD stream_idx = 0;

  ComPtr<ID3D11VideoDevice> vdev;
  ComPtr<ID3D11VideoContext> vctx;
  ComPtr<ID3D11VideoProcessorEnumerator> vpenum;
  ComPtr<ID3D11VideoProcessor> vp;
  int vp_in_w = 0, vp_in_h = 0;

  static void set_sdr_color(IMFMediaType *mt) {
    mt->SetUINT32(MF_MT_VIDEO_PRIMARIES, MFVideoPrimaries_BT709);
    mt->SetUINT32(MF_MT_TRANSFER_FUNCTION, MFVideoTransFunc_sRGB);
    mt->SetUINT32(MF_MT_YUV_MATRIX, MFVideoTransferMatrix_BT709);
    mt->SetUINT32(MF_MT_VIDEO_NOMINAL_RANGE, MFNominalRange_16_235);
  }

  static UINT32 pick_bitrate(int w, int h, int fps, bool hevc) {
    double bpp = hevc ? 0.095 : 0.14;
    double raw = (double)w * (double)h * (double)fps * bpp;
    double lo = hevc ? 1200000.0 : 1500000.0;
    double hi = hevc ? 22000000.0 : 30000000.0;
    if (raw < lo) raw = lo;
    if (raw > hi) raw = hi;
    return (UINT32)raw;
  }

  bool try_open_tier(ID3D11Device *dev, bool try_hevc, bool try_hw) {
    writer.Reset();
    dev_mgr.Reset();
    vdev.Reset();
    vctx.Reset();
    vpenum.Reset();
    vp.Reset();

    ComPtr<IMFAttributes> attr;
    if (FAILED(MFCreateAttributes(&attr, 4))) return false;
    attr->SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, try_hw ? TRUE : FALSE);
    attr->SetUINT32(MF_SINK_WRITER_DISABLE_THROTTLING, TRUE);
    if (try_hw) {
      if (!dev) return false;
      UINT reset_token = 0;
      if (FAILED(MFCreateDXGIDeviceManager(&reset_token, &dev_mgr))) return false;
      if (FAILED(dev_mgr->ResetDevice(dev, reset_token))) return false;
      if (FAILED(attr->SetUnknown(MF_SINK_WRITER_D3D_MANAGER, dev_mgr.Get()))) return false;
    }

    if (FAILED(MFCreateSinkWriterFromURL(out_path.c_str(), NULL, attr.Get(), &writer))) {
      writer.Reset();
      return false;
    }

    ComPtr<IMFMediaType> out_mt;
    if (FAILED(MFCreateMediaType(&out_mt))) return false;
    out_mt->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    out_mt->SetGUID(MF_MT_SUBTYPE, try_hevc ? MFVideoFormat_HEVC : MFVideoFormat_H264);
    out_mt->SetUINT32(MF_MT_AVG_BITRATE, pick_bitrate(out_w, out_h, fps, try_hevc));
    out_mt->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
    MFSetAttributeSize(out_mt.Get(), MF_MT_FRAME_SIZE, (UINT32)out_w, (UINT32)out_h);
    MFSetAttributeRatio(out_mt.Get(), MF_MT_FRAME_RATE, (UINT32)fps, 1);
    MFSetAttributeRatio(out_mt.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
    if (try_hevc) {
      out_mt->SetUINT32(MF_MT_MPEG2_PROFILE, eAVEncH265VProfile_Main_420_8);
    } else {
      out_mt->SetUINT32(MF_MT_MPEG2_PROFILE, eAVEncH264VProfile_High);
    }
    set_sdr_color(out_mt.Get());

    if (FAILED(writer->AddStream(out_mt.Get(), &stream_idx))) {
      writer.Reset();
      return false;
    }

    ComPtr<IMFMediaType> in_mt;
    if (FAILED(MFCreateMediaType(&in_mt))) return false;
    in_mt->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    in_mt->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
    in_mt->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
    MFSetAttributeSize(in_mt.Get(), MF_MT_FRAME_SIZE, (UINT32)out_w, (UINT32)out_h);
    MFSetAttributeRatio(in_mt.Get(), MF_MT_FRAME_RATE, (UINT32)fps, 1);
    MFSetAttributeRatio(in_mt.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
    set_sdr_color(in_mt.Get());

    ComPtr<IMFAttributes> enc_params;
    if (SUCCEEDED(MFCreateAttributes(&enc_params, 2))) {
      enc_params->SetUINT32(CODECAPI_AVEncMPVGOPSize, (UINT32)(fps * 2));
      enc_params->SetUINT32(CODECAPI_AVEncMPVDefaultBPictureCount, 0);
    }
    if (FAILED(writer->SetInputMediaType(stream_idx, in_mt.Get(), enc_params.Get()))) {
      // Retry without optional enc_params (some MFTs reject CODECAPI attributes on SetInputMediaType).
      if (FAILED(writer->SetInputMediaType(stream_idx, in_mt.Get(), NULL))) {
        writer.Reset();
        return false;
      }
    }

    if (FAILED(writer->BeginWriting())) {
      writer.Reset();
      return false;
    }

    gpu_path = try_hw;
    is_hevc = try_hevc;
    if (try_hevc && try_hw) codec_name = "HEVC (HW)";
    else if (try_hw) codec_name = "H.264 (HW)";
    else codec_name = "H.264 (SW)";
    return true;
  }

  bool ensure_vp(ID3D11Device *dev, ID3D11DeviceContext *ctx, int in_w, int in_h) {
    if (vp && vp_in_w == in_w && vp_in_h == in_h) return true;
    vp.Reset();
    vpenum.Reset();
    if (!vdev && FAILED(dev->QueryInterface(IID_PPV_ARGS(&vdev)))) return false;
    if (!vctx && FAILED(ctx->QueryInterface(IID_PPV_ARGS(&vctx)))) return false;

    D3D11_VIDEO_PROCESSOR_CONTENT_DESC desc = {};
    desc.InputFrameFormat = D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE;
    desc.InputFrameRate = {(UINT)fps, 1};
    desc.InputWidth = (UINT)in_w;
    desc.InputHeight = (UINT)in_h;
    desc.OutputFrameRate = {(UINT)fps, 1};
    desc.OutputWidth = (UINT)out_w;
    desc.OutputHeight = (UINT)out_h;
    desc.Usage = D3D11_VIDEO_USAGE_PLAYBACK_NORMAL;
    if (FAILED(vdev->CreateVideoProcessorEnumerator(&desc, &vpenum))) return false;
    if (FAILED(vdev->CreateVideoProcessor(vpenum.Get(), 0, &vp))) return false;

    ComPtr<ID3D11VideoContext1> vctx1;
    if (SUCCEEDED(vctx.As(&vctx1))) {
      vctx1->VideoProcessorSetStreamColorSpace1(vp.Get(), 0, DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709);
      vctx1->VideoProcessorSetOutputColorSpace1(vp.Get(), DXGI_COLOR_SPACE_YCBCR_STUDIO_G22_LEFT_P709);
    }
    vp_in_w = in_w;
    vp_in_h = in_h;
    return true;
  }

  bool open(ID3D11Device *dev, const std::wstring &path, int w, int h, int target_fps) {
    if (FAILED(MFStartup(MF_VERSION, MFSTARTUP_LITE))) return false;
    mf_up = true;
    out_path = path;
    out_w = w;
    out_h = h;
    fps = target_fps;

    const char *force = getenv("PINSHOT_REC_CODEC");
    bool allow_hevc = !force || !force[0] || strcmp(force, "hevc") == 0;
    bool allow_hw = !force || !force[0] || strcmp(force, "sw") != 0;

    // Tier 1: Hardware HEVC (H.265)
    if (dev && allow_hw && allow_hevc && try_open_tier(dev, true, true)) return true;
    DeleteFileW(out_path.c_str());
    // Tier 2: Hardware H.264
    if (dev && allow_hw && try_open_tier(dev, false, true)) return true;
    DeleteFileW(out_path.c_str());
    // Tier 3: Software H.264
    if (try_open_tier(NULL, false, false)) return true;
    DeleteFileW(out_path.c_str());
    return false;
  }

  bool write_gpu_frame(ID3D11Device *dev, ID3D11DeviceContext *ctx, ID3D11Texture2D *src_rgb, int sx, int sy, int sw,
                       int sh, LONGLONG pts, LONGLONG dur) {
    D3D11_TEXTURE2D_DESC sd = {};
    src_rgb->GetDesc(&sd);
    if (!ensure_vp(dev, ctx, (int)sd.Width, (int)sd.Height)) return false;

    // Each sample owns a dedicated NV12 surface so async hardware encoder never races with the next frame.
    D3D11_TEXTURE2D_DESC nd = {};
    nd.Width = (UINT)out_w;
    nd.Height = (UINT)out_h;
    nd.MipLevels = 1;
    nd.ArraySize = 1;
    nd.Format = DXGI_FORMAT_NV12;
    nd.SampleDesc.Count = 1;
    nd.Usage = D3D11_USAGE_DEFAULT;
    nd.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    ComPtr<ID3D11Texture2D> nv12;
    if (FAILED(dev->CreateTexture2D(&nd, NULL, &nv12))) return false;

    D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC ivd = {};
    ivd.ViewDimension = D3D11_VPIV_DIMENSION_TEXTURE2D;
    ComPtr<ID3D11VideoProcessorInputView> in_view;
    if (FAILED(vdev->CreateVideoProcessorInputView(src_rgb, vpenum.Get(), &ivd, &in_view))) return false;

    D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC ovd = {};
    ovd.ViewDimension = D3D11_VPOV_DIMENSION_TEXTURE2D;
    ComPtr<ID3D11VideoProcessorOutputView> out_view;
    if (FAILED(vdev->CreateVideoProcessorOutputView(nv12.Get(), vpenum.Get(), &ovd, &out_view))) return false;

    RECT srect = {sx, sy, sx + sw, sy + sh};
    RECT drect = {0, 0, out_w, out_h};
    vctx->VideoProcessorSetStreamSourceRect(vp.Get(), 0, TRUE, &srect);
    vctx->VideoProcessorSetStreamDestRect(vp.Get(), 0, TRUE, &drect);
    vctx->VideoProcessorSetOutputTargetRect(vp.Get(), TRUE, &drect);

    D3D11_VIDEO_PROCESSOR_STREAM stream = {};
    stream.Enable = TRUE;
    stream.pInputSurface = in_view.Get();
    HRESULT hr = vctx->VideoProcessorBlt(vp.Get(), out_view.Get(), 0, 1, &stream);
    in_view.Reset();
    out_view.Reset();
    if (FAILED(hr)) return false;
    ctx->Flush();

    ComPtr<IMFMediaBuffer> buf;
    if (FAILED(MFCreateDXGISurfaceBuffer(__uuidof(ID3D11Texture2D), nv12.Get(), 0, FALSE, &buf))) return false;
    ComPtr<IMF2DBuffer> buf2d;
    DWORD len = (DWORD)((size_t)out_w * out_h * 3 / 2);
    if (SUCCEEDED(buf.As(&buf2d))) buf2d->GetContiguousLength(&len);
    buf->SetCurrentLength(len);

    ComPtr<IMFSample> sample;
    if (FAILED(MFCreateSample(&sample))) return false;
    sample->AddBuffer(buf.Get());
    sample->SetSampleTime(pts);
    sample->SetSampleDuration(dur);
    return SUCCEEDED(writer->WriteSample(stream_idx, sample.Get()));
  }

  bool write_cpu_frame(const uint8_t *rgb, int pitch, bool is_bgra, LONGLONG pts, LONGLONG dur) {
    DWORD nv12_len = (DWORD)((size_t)out_w * out_h * 3 / 2);
    ComPtr<IMFMediaBuffer> buf;
    if (FAILED(MFCreateMemoryBuffer(nv12_len, &buf))) return false;
    BYTE *dst = NULL;
    if (FAILED(buf->Lock(&dst, NULL, NULL))) return false;
    rgb_to_nv12(rgb, pitch, is_bgra, out_w, out_h, dst, dst + (size_t)out_w * out_h);
    buf->Unlock();
    buf->SetCurrentLength(nv12_len);

    ComPtr<IMFSample> sample;
    if (FAILED(MFCreateSample(&sample))) return false;
    sample->AddBuffer(buf.Get());
    sample->SetSampleTime(pts);
    sample->SetSampleDuration(dur);
    return SUCCEEDED(writer->WriteSample(stream_idx, sample.Get()));
  }

  uint64_t finish(bool cancel) {
    HRESULT hr = E_FAIL;
    if (writer) {
      if (!cancel) hr = writer->Finalize();
      writer.Reset();
    }
    vp.Reset();
    vpenum.Reset();
    vctx.Reset();
    vdev.Reset();
    dev_mgr.Reset();
    if (mf_up) {
      MFShutdown();
      mf_up = false;
    }
    if (cancel || FAILED(hr)) {
      DeleteFileW(out_path.c_str());
      return 0;
    }
    if (is_hevc) patch_mp4_hev1_to_hvc1(out_path);
    WIN32_FILE_ATTRIBUTE_DATA fad = {};
    if (GetFileAttributesExW(out_path.c_str(), GetFileExInfoStandard, &fad)) {
      return ((uint64_t)fad.nFileSizeHigh << 32) | (uint64_t)fad.nFileSizeLow;
    }
    return 0;
  }
};

// ---- Recording Worker Thread ----

struct RecWorkerState {
  CRITICAL_SECTION lock;
  ComPtr<WGC::IDirect3D11CaptureFrame> last_frame;
  HANDLE first_frame_ev = NULL;
  bool got_frame = false;
};

static DWORD WINAPI rec_worker(LPVOID) {
  HRESULT ro_hr = RoInitialize(RO_INIT_MULTITHREADED);
  timeBeginPeriod(1);

  int rx = R.x - R.mx;
  int ry = R.y - R.my;
  int rw = R.w;
  int rh = R.h;
  int mw = R.mw;
  int mh = R.mh;
  HMONITOR mon = R.mon;
  std::wstring out_path = R.out_path;
  int fmt = R.fmt;
  int fps = R.fps;
  int cursor = R.cursor;

  rec_make_dirs(out_path);

  // Create dedicated D3D11 device (with video support) for recording; released cleanly on exit.
  ComPtr<ID3D11Device> dev;
  ComPtr<ID3D11DeviceContext> ctx;
  ComPtr<WD3D::IDirect3DDevice> rt_dev;
  ComPtr<ID3D11ComputeShader> to_srgb;
  ComPtr<ID3D11Buffer> to_srgb_k;
  bool srgb_is_bgra = true;

  D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1};
  HRESULT dhr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL,
                                  D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_VIDEO_SUPPORT, levels, 3,
                                  D3D11_SDK_VERSION, &dev, NULL, &ctx);
  if (FAILED(dhr)) {
    dhr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, D3D11_CREATE_DEVICE_BGRA_SUPPORT, levels, 3,
                            D3D11_SDK_VERSION, &dev, NULL, &ctx);
  }

  float sdr_white = 1.0f;
  bool is_hdr = false;
  ComPtr<WGC::IDirect3D11CaptureFramePool> pool;
  ComPtr<WGC::IGraphicsCaptureSession> session;
  EventRegistrationToken token = {};
  bool wgc_ok = false;

  RecWorkerState ws = {};
  InitializeCriticalSection(&ws.lock);
  ws.first_frame_ev = CreateEventW(NULL, TRUE, FALSE, NULL);

  if (dev && ctx) {
    ComPtr<ID3D10Multithread> mt;
    if (SUCCEEDED(dev.As(&mt))) mt->SetMultithreadProtected(TRUE);

    UINT bgra_supp = 0;
    dev->CheckFormatSupport(DXGI_FORMAT_B8G8R8A8_UNORM, &bgra_supp);
    srgb_is_bgra = (bgra_supp & D3D11_FORMAT_SUPPORT_TYPED_UNORDERED_ACCESS_VIEW) != 0;

    // HDR scRGB FP16 -> sRGB compute shader (outputs true RGBA channels so DXGI_FORMAT_B8G8R8A8_UNORM UAV swizzles
    // automatically to BGRA in memory, and DXGI_FORMAT_R8G8B8A8_UNORM UAV stays RGBA).
    static const char hlsl[] =
        "Texture2D<float4> src : register(t0);"
        "RWTexture2D<unorm float4> dst : register(u0);"
        "cbuffer K : register(b0) { float inv_white; uint ox; uint oy; uint pad; };"
        "float enc(float v) { v = saturate(v); return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1.0 / 2.4) - 0.055; }"
        "[numthreads(16, 16, 1)] void main(uint3 id : SV_DispatchThreadID) {"
        "  uint dw, dh; dst.GetDimensions(dw, dh); if (id.x >= dw || id.y >= dh) return;"
        "  float3 c = src[uint2(id.x + ox, id.y + oy)].rgb * inv_white;"
        "  dst[id.xy] = float4(enc(c.r), enc(c.g), enc(c.b), 1.0); }";
    ComPtr<ID3DBlob> code, errs;
    if (SUCCEEDED(D3DCompile(hlsl, sizeof hlsl - 1, "rec_srgb", NULL, NULL, "main", "cs_5_0",
                             D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, &code, &errs))) {
      dev->CreateComputeShader(code->GetBufferPointer(), code->GetBufferSize(), NULL, &to_srgb);
    }
    D3D11_BUFFER_DESC bd = {16, D3D11_USAGE_DYNAMIC, D3D11_BIND_CONSTANT_BUFFER, D3D11_CPU_ACCESS_WRITE, 0, 0};
    dev->CreateBuffer(&bd, NULL, &to_srgb_k);

    is_hdr = to_srgb && to_srgb_k && ps_wgc_mon_hdr(mon, &sdr_white) != 0;

    ComPtr<IDXGIDevice> xdev;
    ComPtr<IInspectable> insp;
    ComPtr<IGraphicsCaptureItemInterop> item_interop;
    ComPtr<WGC::IDirect3D11CaptureFramePoolStatics2> pool_statics;
    ComPtr<WGC::IGraphicsCaptureItem> item;

    if (ps_wgc_borderless_ok() && SUCCEEDED(dev.As(&xdev)) &&
        SUCCEEDED(CreateDirect3D11DeviceFromDXGIDevice(xdev.Get(), &insp)) && SUCCEEDED(insp.As(&rt_dev)) &&
        SUCCEEDED(RoGetActivationFactory(HStringReference(RuntimeClass_Windows_Graphics_Capture_GraphicsCaptureItem).Get(),
                                         IID_PPV_ARGS(&item_interop))) &&
        SUCCEEDED(RoGetActivationFactory(
            HStringReference(RuntimeClass_Windows_Graphics_Capture_Direct3D11CaptureFramePool).Get(),
            IID_PPV_ARGS(&pool_statics))) &&
        SUCCEEDED(item_interop->CreateForMonitor(mon, IID_PPV_ARGS(&item)))) {
      ABI::Windows::Graphics::SizeInt32 sz = {mw, mh};
      auto pix_fmt = is_hdr ? ABI::Windows::Graphics::DirectX::DirectXPixelFormat_R16G16B16A16Float
                            : ABI::Windows::Graphics::DirectX::DirectXPixelFormat_B8G8R8A8UIntNormalized;
      if (SUCCEEDED(pool_statics->CreateFreeThreaded(rt_dev.Get(), pix_fmt, 2, sz, &pool))) {
        auto arrived = Callback<Microsoft::WRL::Implements<Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::ClassicCom>,
                                                           ITypedEventHandler<WGC::Direct3D11CaptureFramePool *, IInspectable *>,
                                                           Microsoft::WRL::FtmBase>>(
            [&ws](WGC::IDirect3D11CaptureFramePool *sender, IInspectable *) -> HRESULT {
              ComPtr<WGC::IDirect3D11CaptureFrame> f;
              if (SUCCEEDED(sender->TryGetNextFrame(&f)) && f) {
                ComPtr<WGC::IDirect3D11CaptureFrame> old;
                EnterCriticalSection(&ws.lock);
                old = ws.last_frame;
                ws.last_frame = f;
                ws.got_frame = true;
                LeaveCriticalSection(&ws.lock);
                SetEvent(ws.first_frame_ev);
                ComPtr<ABI::Windows::Foundation::IClosable> c;
                if (old && SUCCEEDED(old.As(&c))) c->Close();
              }
              return S_OK;
            });
        if (SUCCEEDED(pool->add_FrameArrived(arrived.Get(), &token)) &&
            SUCCEEDED(pool->CreateCaptureSession(item.Get(), &session))) {
          ComPtr<WGC::IGraphicsCaptureSession2> s2;
          if (SUCCEEDED(session.As(&s2))) s2->put_IsCursorCaptureEnabled(cursor ? TRUE : FALSE);
          ComPtr<WGC::IGraphicsCaptureSession3> s3;
          if (SUCCEEDED(session.As(&s3)) && SUCCEEDED(s3->put_IsBorderRequired(FALSE)) &&
              SUCCEEDED(session->StartCapture())) {
            wgc_ok = true;
          }
        }
      }
    }
  }

  if (wgc_ok) {
    WaitForSingleObject(ws.first_frame_ev, 500);
  }

  // Reusable GPU textures for HDR sRGB conversion and CPU staging (allocated once per recording, freed on exit).
  ComPtr<ID3D11Texture2D> hdr_srgb_tex;
  ComPtr<ID3D11UnorderedAccessView> hdr_srgb_uav;
  ComPtr<ID3D11Texture2D> hdr_half_copy;
  ComPtr<ID3D11Texture2D> staging_tex;

  auto prepare_hdr_srgb = [&](ID3D11Texture2D *src_fp16) -> ID3D11Texture2D * {
    if (!hdr_srgb_tex) {
      D3D11_TEXTURE2D_DESC od = {};
      od.Width = (UINT)rw;
      od.Height = (UINT)rh;
      od.MipLevels = 1;
      od.ArraySize = 1;
      od.Format = srgb_is_bgra ? DXGI_FORMAT_B8G8R8A8_UNORM : DXGI_FORMAT_R8G8B8A8_UNORM;
      od.SampleDesc.Count = 1;
      od.Usage = D3D11_USAGE_DEFAULT;
      od.BindFlags = D3D11_BIND_UNORDERED_ACCESS | D3D11_BIND_SHADER_RESOURCE;
      if (FAILED(dev->CreateTexture2D(&od, NULL, &hdr_srgb_tex)) ||
          FAILED(dev->CreateUnorderedAccessView(hdr_srgb_tex.Get(), NULL, &hdr_srgb_uav))) {
        hdr_srgb_tex.Reset();
        hdr_srgb_uav.Reset();
        return NULL;
      }
    }
    ComPtr<ID3D11ShaderResourceView> srv;
    uint32_t ox = (uint32_t)rx, oy = (uint32_t)ry;
    if (FAILED(dev->CreateShaderResourceView(src_fp16, NULL, &srv))) {
      if (!hdr_half_copy) {
        D3D11_TEXTURE2D_DESC sd = {};
        src_fp16->GetDesc(&sd);
        D3D11_TEXTURE2D_DESC hd = {};
        hd.Width = (UINT)rw;
        hd.Height = (UINT)rh;
        hd.MipLevels = 1;
        hd.ArraySize = 1;
        hd.Format = sd.Format;
        hd.SampleDesc.Count = 1;
        hd.Usage = D3D11_USAGE_DEFAULT;
        hd.BindFlags = D3D11_BIND_SHADER_RESOURCE;
        if (FAILED(dev->CreateTexture2D(&hd, NULL, &hdr_half_copy))) return NULL;
      }
      D3D11_BOX box = {(UINT)rx, (UINT)ry, 0, (UINT)(rx + rw), (UINT)(ry + rh), 1};
      ctx->CopySubresourceRegion(hdr_half_copy.Get(), 0, 0, 0, 0, src_fp16, 0, &box);
      ox = oy = 0;
      if (FAILED(dev->CreateShaderResourceView(hdr_half_copy.Get(), NULL, &srv))) return NULL;
    }
    D3D11_MAPPED_SUBRESOURCE kp = {};
    if (FAILED(ctx->Map(to_srgb_k.Get(), 0, D3D11_MAP_WRITE_DISCARD, 0, &kp))) return NULL;
    struct {
      float inv_white;
      uint32_t ox;
      uint32_t oy;
      uint32_t pad;
    } k = {1.0f / sdr_white, ox, oy, 0};
    memcpy(kp.pData, &k, sizeof k);
    ctx->Unmap(to_srgb_k.Get(), 0);

    ID3D11ShaderResourceView *srvs[1] = {srv.Get()};
    ID3D11UnorderedAccessView *uavs[1] = {hdr_srgb_uav.Get()};
    ID3D11Buffer *ks[1] = {to_srgb_k.Get()};
    ctx->CSSetShader(to_srgb.Get(), NULL, 0);
    ctx->CSSetShaderResources(0, 1, srvs);
    ctx->CSSetUnorderedAccessViews(0, 1, uavs, NULL);
    ctx->CSSetConstantBuffers(0, 1, ks);
    ctx->Dispatch(((UINT)rw + 15) / 16, ((UINT)rh + 15) / 16, 1);
    ID3D11ShaderResourceView *no_srv[1] = {NULL};
    ID3D11UnorderedAccessView *no_uav[1] = {NULL};
    ctx->CSSetShaderResources(0, 1, no_srv);
    ctx->CSSetUnorderedAccessViews(0, 1, no_uav, NULL);
    ctx->CSSetShader(NULL, NULL, 0);
    return hdr_srgb_tex.Get();
  };

  auto read_cpu_srgb = [&](ID3D11Texture2D *tex, int sx, int sy, std::vector<uint8_t> &out_buf, int &out_pitch,
                           bool &out_bgra) -> bool {
    D3D11_TEXTURE2D_DESC sd = {};
    tex->GetDesc(&sd);
    if (!staging_tex) {
      D3D11_TEXTURE2D_DESC td = {};
      td.Width = (UINT)rw;
      td.Height = (UINT)rh;
      td.MipLevels = 1;
      td.ArraySize = 1;
      td.Format = sd.Format;
      td.SampleDesc.Count = 1;
      td.Usage = D3D11_USAGE_STAGING;
      td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
      if (FAILED(dev->CreateTexture2D(&td, NULL, &staging_tex))) return false;
    }
    if (sx == 0 && sy == 0 && (int)sd.Width == rw && (int)sd.Height == rh) {
      ctx->CopyResource(staging_tex.Get(), tex);
    } else {
      D3D11_BOX box = {(UINT)sx, (UINT)sy, 0, (UINT)(sx + rw), (UINT)(sy + rh), 1};
      ctx->CopySubresourceRegion(staging_tex.Get(), 0, 0, 0, 0, tex, 0, &box);
    }
    D3D11_MAPPED_SUBRESOURCE mp = {};
    if (FAILED(ctx->Map(staging_tex.Get(), 0, D3D11_MAP_READ, 0, &mp))) return false;
    out_pitch = rw * 4;
    out_buf.resize((size_t)out_pitch * rh);
    for (int y = 0; y < rh; y++) {
      memcpy(out_buf.data() + (size_t)y * out_pitch, (const uint8_t *)mp.pData + (size_t)y * mp.RowPitch, (size_t)out_pitch);
    }
    ctx->Unmap(staging_tex.Get(), 0);
    out_bgra = (sd.Format == DXGI_FORMAT_B8G8R8A8_UNORM);
    return true;
  };

  // GDI fallback capture when WGC is unavailable
  auto capture_gdi = [&](std::vector<uint8_t> &out_buf, int &out_pitch, bool &out_bgra) -> bool {
    HDC screen = GetDC(NULL);
    if (!screen) return false;
    HDC mem = CreateCompatibleDC(screen);
    BITMAPINFO bi = {};
    bi.bmiHeader.biSize = sizeof bi.bmiHeader;
    bi.bmiHeader.biWidth = rw;
    bi.bmiHeader.biHeight = -rh;
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = BI_RGB;
    void *bits = NULL;
    HBITMAP bmp = CreateDIBSection(screen, &bi, DIB_RGB_COLORS, &bits, NULL, 0);
    bool ok = false;
    if (bmp && bits) {
      HGDIOBJ old = SelectObject(mem, bmp);
      if (BitBlt(mem, 0, 0, rw, rh, screen, R.x, R.y, SRCCOPY)) {
        if (cursor) {
          CURSORINFO ci = {};
          ci.cbSize = sizeof ci;
          if (GetCursorInfo(&ci) && (ci.flags & CURSOR_SHOWING)) {
            ICONINFO ii = {};
            if (GetIconInfo(ci.hCursor, &ii)) {
              DrawIconEx(mem, ci.ptScreenPos.x - R.x - (int)ii.xHotspot, ci.ptScreenPos.y - R.y - (int)ii.yHotspot,
                         ci.hCursor, 0, 0, 0, NULL, DI_NORMAL);
              if (ii.hbmMask) DeleteObject(ii.hbmMask);
              if (ii.hbmColor) DeleteObject(ii.hbmColor);
            }
          }
        }
        out_pitch = rw * 4;
        out_buf.resize((size_t)out_pitch * rh);
        memcpy(out_buf.data(), bits, out_buf.size());
        out_bgra = true;
        ok = true;
      }
      SelectObject(mem, old);
      DeleteObject(bmp);
    }
    DeleteDC(mem);
    ReleaseDC(NULL, screen);
    return ok;
  };

  // Initialize encoder
  Mp4Encoder mp4;
  GifWriter gif;
  int gif_w = rw, gif_h = rh;
  std::string codec_label = "GIF";
  bool enc_ok = false;

  if (fmt == 0) {
    enc_ok = mp4.open(wgc_ok ? dev.Get() : NULL, out_path, rw, rh, fps);
    if (enc_ok) codec_label = mp4.codec_name;
  } else {
    const int GIF_MAX_SIDE = 1280;
    if (rw > GIF_MAX_SIDE || rh > GIF_MAX_SIDE) {
      double k = (double)GIF_MAX_SIDE / (double)(rw > rh ? rw : rh);
      gif_w = std::max(16, ((int)(rw * k + 0.5)) & ~1);
      gif_h = std::max(16, ((int)(rh * k + 0.5)) & ~1);
    }
    enc_ok = gif.open(out_path, gif_w, gif_h);
  }

  if (!enc_ok) {
    if (pool) pool->remove_FrameArrived(token);
    ComPtr<ABI::Windows::Foundation::IClosable> c;
    if (session && SUCCEEDED(session.As(&c))) c->Close();
    if (pool && SUCCEEDED(pool.As(&c))) c->Close();
    EnterCriticalSection(&ws.lock);
    if (ws.last_frame && SUCCEEDED(ws.last_frame.As(&c))) c->Close();
    ws.last_frame.Reset();
    LeaveCriticalSection(&ws.lock);
    DeleteCriticalSection(&ws.lock);
    CloseHandle(ws.first_frame_ev);
    timeEndPeriod(1);
    if (SUCCEEDED(ro_hr)) RoUninitialize();
    InterlockedExchange(&R.running, 0);
    rec_post("error", 0, 0, 0, "", out_path, fmt == 0 ? "无法初始化视频编码器" : "无法创建 GIF 文件");
    return 0;
  }

  LARGE_INTEGER qpf, t_start, t_now;
  QueryPerformanceFrequency(&qpf);
  QueryPerformanceCounter(&t_start);
  LONGLONG paused_ticks = 0;
  LONGLONG pause_began = 0;
  bool was_paused = false;

  int64_t slot = 0;
  int frames = 0;
  int64_t last_report_ms = -1000;
  int64_t last_elapsed_ms = 0;
  std::vector<uint8_t> cpu_bgra;
  std::vector<uint8_t> gif_rgb((size_t)gif_w * gif_h * 3);
  int gif_step_cs = std::max(2, (100 + fps / 2) / fps);

  rec_post("recording", 0, 0, 0, codec_label.c_str(), out_path, "");

  while (InterlockedCompareExchange(&R.stop_req, 0, 0) == 0) {
    bool paused = InterlockedCompareExchange(&R.pause_req, 0, 0) != 0;
    QueryPerformanceCounter(&t_now);
    if (paused) {
      if (!was_paused) {
        was_paused = true;
        pause_began = t_now.QuadPart;
        rec_post("paused", last_elapsed_ms, frames, 0, codec_label.c_str(), out_path, "");
      }
      WaitForSingleObject(R.wake_ev, 60);
      continue;
    } else if (was_paused) {
      was_paused = false;
      paused_ticks += (t_now.QuadPart - pause_began);
      rec_post("recording", last_elapsed_ms, frames, 0, codec_label.c_str(), out_path, "");
    }

    LONGLONG elapsed_ticks = t_now.QuadPart - t_start.QuadPart - paused_ticks;
    if (elapsed_ticks < 0) elapsed_ticks = 0;
    int64_t elapsed_ms = (elapsed_ticks * 1000LL) / qpf.QuadPart;
    int64_t elapsed_hns = (elapsed_ticks * 10000000LL) / qpf.QuadPart;
    last_elapsed_ms = elapsed_ms;

    LONGLONG next_slot_hns = (slot * 10000000LL) / fps;
    if (elapsed_hns < next_slot_hns) {
      DWORD wait_ms = (DWORD)((next_slot_hns - elapsed_hns) / 10000LL);
      if (wait_ms < 1) wait_ms = 1;
      if (wait_ms > 50) wait_ms = 50;
      WaitForSingleObject(R.wake_ev, wait_ms);
      continue;
    }

    // Grab latest WGC frame texture (or fallback to GDI).
    ComPtr<WGC::IDirect3D11CaptureFrame> fr;
    ComPtr<ID3D11Texture2D> src_tex;
    if (wgc_ok) {
      EnterCriticalSection(&ws.lock);
      fr = ws.last_frame;
      LeaveCriticalSection(&ws.lock);
      if (fr) {
        ComPtr<WD3D::IDirect3DSurface> surf;
        ComPtr<Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess> acc;
        if (SUCCEEDED(fr->get_Surface(&surf)) && SUCCEEDED(surf.As(&acc))) {
          acc->GetInterface(IID_PPV_ARGS(&src_tex));
        }
      }
    }

    LONGLONG dur_hns = 10000000LL / fps;
    bool wrote = false;
    if (fmt == 0) {
      if (mp4.gpu_path && src_tex) {
        ID3D11Texture2D *rgb_tex = src_tex.Get();
        int sx = rx, sy = ry;
        if (is_hdr) {
          rgb_tex = prepare_hdr_srgb(src_tex.Get());
          sx = 0;
          sy = 0;
        }
        if (rgb_tex) {
          wrote = mp4.write_gpu_frame(dev.Get(), ctx.Get(), rgb_tex, sx, sy, rw, rh, next_slot_hns, dur_hns);
        }
      } else {
        int pitch = 0;
        bool is_bgra = true;
        bool got = false;
        if (src_tex) {
          ID3D11Texture2D *rgb_tex = is_hdr ? prepare_hdr_srgb(src_tex.Get()) : src_tex.Get();
          if (rgb_tex) got = read_cpu_srgb(rgb_tex, is_hdr ? 0 : rx, is_hdr ? 0 : ry, cpu_bgra, pitch, is_bgra);
        } else {
          got = capture_gdi(cpu_bgra, pitch, is_bgra);
        }
        if (got) {
          wrote = mp4.write_cpu_frame(cpu_bgra.data(), pitch, is_bgra, next_slot_hns, dur_hns);
        }
      }
    } else {
      int pitch = 0;
      bool is_bgra = true;
      bool got = false;
      if (src_tex) {
        ID3D11Texture2D *rgb_tex = is_hdr ? prepare_hdr_srgb(src_tex.Get()) : src_tex.Get();
        if (rgb_tex) got = read_cpu_srgb(rgb_tex, is_hdr ? 0 : rx, is_hdr ? 0 : ry, cpu_bgra, pitch, is_bgra);
      } else {
        got = capture_gdi(cpu_bgra, pitch, is_bgra);
      }
      if (got) {
        int ro = is_bgra ? 2 : 0, go = 1, bo = is_bgra ? 0 : 2;
        if (gif_w == rw && gif_h == rh) {
          for (int y = 0; y < rh; y++) {
            const uint8_t *s = cpu_bgra.data() + (size_t)y * pitch;
            uint8_t *d = gif_rgb.data() + (size_t)y * gif_w * 3;
            for (int x = 0; x < rw; x++) {
              d[x * 3 + 0] = s[x * 4 + ro];
              d[x * 3 + 1] = s[x * 4 + go];
              d[x * 3 + 2] = s[x * 4 + bo];
            }
          }
        } else {
          // Box-averaged downsample for sharp text on scaled GIFs
          for (int y = 0; y < gif_h; y++) {
            int y0 = y * rh / gif_h, y1 = std::max(y0 + 1, (y + 1) * rh / gif_h);
            if (y1 > rh) y1 = rh;
            uint8_t *d = gif_rgb.data() + (size_t)y * gif_w * 3;
            for (int x = 0; x < gif_w; x++) {
              int x0 = x * rw / gif_w, x1 = std::max(x0 + 1, (x + 1) * rw / gif_w);
              if (x1 > rw) x1 = rw;
              uint32_t sr = 0, sg = 0, sb = 0, cnt = 0;
              for (int yy = y0; yy < y1; yy++) {
                const uint8_t *s = cpu_bgra.data() + (size_t)yy * pitch;
                for (int xx = x0; xx < x1; xx++) {
                  sr += s[xx * 4 + ro];
                  sg += s[xx * 4 + go];
                  sb += s[xx * 4 + bo];
                  cnt++;
                }
              }
              d[x * 3 + 0] = (uint8_t)(sr / cnt);
              d[x * 3 + 1] = (uint8_t)(sg / cnt);
              d[x * 3 + 2] = (uint8_t)(sb / cnt);
            }
          }
        }
        gif.add_frame(gif_rgb.data(), gif_step_cs);
        wrote = true;
      }
    }

    if (wrote) {
      frames++;
      slot++;
      // If system lagged far behind, skip ahead cleanly instead of flooding duplicate frames.
      int64_t behind_slots = (elapsed_hns - (slot * 10000000LL) / fps) * fps / 10000000LL;
      if (behind_slots > 3) slot += behind_slots - 1;
    } else {
      WaitForSingleObject(R.wake_ev, 5);
    }

    if (elapsed_ms - last_report_ms >= 100) {
      last_report_ms = elapsed_ms;
      rec_post("recording", elapsed_ms, frames, 0, codec_label.c_str(), out_path, "");
    }
  }

  bool cancel = InterlockedCompareExchange(&R.stop_req, 0, 0) == 2;
  if (!cancel) rec_post("saving", last_elapsed_ms, frames, 0, codec_label.c_str(), out_path, "");

  uint64_t final_bytes = 0;
  if (fmt == 0) {
    final_bytes = mp4.finish(cancel || frames == 0);
  } else {
    if (cancel || frames == 0) {
      gif.abort();
      DeleteFileW(out_path.c_str());
    } else {
      final_bytes = gif.finish();
    }
  }

  // Release all WGC and D3D11 objects and trim driver pools so idle VRAM returns to zero.
  if (pool) pool->remove_FrameArrived(token);
  ComPtr<ABI::Windows::Foundation::IClosable> closable;
  if (session && SUCCEEDED(session.As(&closable))) closable->Close();
  if (pool && SUCCEEDED(pool.As(&closable))) closable->Close();
  session.Reset();
  pool.Reset();
  EnterCriticalSection(&ws.lock);
  if (ws.last_frame && SUCCEEDED(ws.last_frame.As(&closable))) closable->Close();
  ws.last_frame.Reset();
  LeaveCriticalSection(&ws.lock);
  DeleteCriticalSection(&ws.lock);
  CloseHandle(ws.first_frame_ev);

  staging_tex.Reset();
  hdr_half_copy.Reset();
  hdr_srgb_uav.Reset();
  hdr_srgb_tex.Reset();
  to_srgb_k.Reset();
  to_srgb.Reset();
  rt_dev.Reset();
  if (ctx) {
    ctx->ClearState();
    ctx->Flush();
  }
  if (dev) {
    ComPtr<IDXGIDevice3> d3;
    if (SUCCEEDED(dev.As(&d3))) d3->Trim();
  }
  ctx.Reset();
  dev.Reset();

  timeEndPeriod(1);
  if (SUCCEEDED(ro_hr)) RoUninitialize();
  InterlockedExchange(&R.running, 0);

  if (cancel) {
    rec_post("cancelled", last_elapsed_ms, frames, 0, codec_label.c_str(), L"", "");
  } else if (final_bytes > 0) {
    copy_file_to_clipboard(out_path);
    rec_post("done", last_elapsed_ms, frames, final_bytes, codec_label.c_str(), out_path, "");
  } else {
    rec_post("error", last_elapsed_ms, frames, 0, codec_label.c_str(), out_path, "保存录屏文件失败");
  }
  return 0;
}

// ---- MoonBit FFI exports ----

extern "C" {

int32_t ps_rec_prepare(int32_t x, int32_t y, int32_t w, int32_t h) {
  if (InterlockedCompareExchange(&R.running, 0, 0) != 0) return 0;
  rec_frame_hide();
  if (w < 16 || h < 16) return 0;
  POINT c = {x + w / 2, y + h / 2};
  HMONITOR mon = MonitorFromPoint(c, MONITOR_DEFAULTTONEAREST);
  MONITORINFO mi = {};
  mi.cbSize = sizeof mi;
  if (!GetMonitorInfoW(mon, &mi)) return 0;
  if (x < mi.rcMonitor.left) {
    w -= mi.rcMonitor.left - x;
    x = mi.rcMonitor.left;
  }
  if (y < mi.rcMonitor.top) {
    h -= mi.rcMonitor.top - y;
    y = mi.rcMonitor.top;
  }
  if (x + w > mi.rcMonitor.right) w = mi.rcMonitor.right - x;
  if (y + h > mi.rcMonitor.bottom) h = mi.rcMonitor.bottom - y;
  // H.264 / HEVC / NV12 require even dimensions.
  w &= ~1;
  h &= ~1;
  if (w < 16 || h < 16) return 0;
  R.prepared = 1;
  R.x = x;
  R.y = y;
  R.w = w;
  R.h = h;
  R.mon = mon;
  R.mx = mi.rcMonitor.left;
  R.my = mi.rcMonitor.top;
  R.mw = mi.rcMonitor.right - mi.rcMonitor.left;
  R.mh = mi.rcMonitor.bottom - mi.rcMonitor.top;
  rec_frame_show(RGB(0x2F, 0x9B, 0xFF));
  return 1;
}

moonbit_bytes_t ps_rec_rect(void) {
  if (!R.prepared) return moonbit_make_bytes(0, 0);
  char s[64];
  int n = snprintf(s, sizeof s, "%d,%d,%d,%d", R.x, R.y, R.w, R.h);
  return rec_bytes_of(s, (size_t)n);
}

int32_t ps_rec_start(moonbit_bytes_t path, int32_t fmt, int32_t fps, int32_t cursor) {
  if (!R.prepared || InterlockedCompareExchange(&R.running, 0, 0) != 0) return 0;
  if (R.thread) {
    WaitForSingleObject(R.thread, 3000);
    CloseHandle(R.thread);
    R.thread = NULL;
  }
  int len = (int)Moonbit_array_length(path);
  R.out_path = utf8_to_wide((const char *)path, len);
  if (R.out_path.empty()) return 0;
  R.fmt = fmt ? 1 : 0;
  R.fps = fps < 5 ? 5 : (fps > 60 ? 60 : fps);
  R.cursor = cursor ? 1 : 0;
  InterlockedExchange(&R.stop_req, 0);
  InterlockedExchange(&R.pause_req, 0);
  if (!R.wake_ev) R.wake_ev = CreateEventW(NULL, FALSE, FALSE, NULL);
  ResetEvent(R.wake_ev);
  InterlockedExchange(&R.running, 1);
  rec_frame_show(RGB(0xEF, 0x44, 0x44));
  R.thread = CreateThread(NULL, 0, rec_worker, NULL, 0, NULL);
  if (!R.thread) {
    InterlockedExchange(&R.running, 0);
    return 0;
  }
  return 1;
}

void ps_rec_pause(int32_t on) {
  if (InterlockedCompareExchange(&R.running, 0, 0) == 0) return;
  int p = on ? 1 : 0;
  InterlockedExchange(&R.pause_req, p);
  if (R.wake_ev) SetEvent(R.wake_ev);
  rec_frame_show(p ? RGB(0xF5, 0xA5, 0x24) : RGB(0xEF, 0x44, 0x44));
}

void ps_rec_stop(int32_t cancel) {
  rec_frame_hide();
  if (InterlockedCompareExchange(&R.running, 0, 0) == 0) return;
  InterlockedExchange(&R.stop_req, cancel ? 2 : 1);
  if (R.wake_ev) SetEvent(R.wake_ev);
}

void ps_rec_end(void) {
  rec_frame_hide();
  if (InterlockedCompareExchange(&R.running, 0, 0) != 0) {
    InterlockedExchange(&R.stop_req, 2);
    if (R.wake_ev) SetEvent(R.wake_ev);
  }
  if (R.thread) {
    WaitForSingleObject(R.thread, 5000);
    CloseHandle(R.thread);
    R.thread = NULL;
  }
  if (R.wake_ev) {
    CloseHandle(R.wake_ev);
    R.wake_ev = NULL;
  }
  R.prepared = 0;
}

void ps_rec_exclude(int32_t wid) {
  HWND h = (HWND)mb_app_hwnd_of(wid);
  if (!h) return;
  DWM_WINDOW_CORNER_PREFERENCE corner = DWMWCP_ROUND;
  DwmSetWindowAttribute(h, DWMWA_WINDOW_CORNER_PREFERENCE, &corner, sizeof corner);
  rec_exclude_hwnd(h);
}

int32_t ps_rec_copy_file(moonbit_bytes_t path) {
  int len = (int)Moonbit_array_length(path);
  std::wstring wp = utf8_to_wide((const char *)path, len);
  return copy_file_to_clipboard(wp);
}

}  // extern "C"
