// Lightweight area screen recorder & post-recording transcoder (Windows):
// 1. Live recording into a temp master MP4 via dedicated WGC session (with optional cursor & HDR FP16 -> sRGB GPU
//    conversion) + optional WASAPI Loopback system audio (48 kHz stereo AAC):
//      - Tier 1: Hardware HEVC (H.265) + D3D11 VideoProcessor GPU NV12 (patches 'hev1' -> 'hvc1')
//      - Tier 2: Hardware H.264 + D3D11 VideoProcessor GPU NV12
//      - Tier 3: Software H.264 + CPU BT.709 NV12
// 2. Live transparent GDI+ annotation overlay (record_draw_win.cpp) captured natively by WGC.
// 3. Post-recording export & compression (ps_rec_export):
//      - Mode 0: MP4 Original (instant copy, preserves audio & original quality)
//      - Mode 1: MP4 Compressed Standard (GPU D3D11VA decode + VideoProcessor resize <=1920 + HW HEVC/H.264 + AAC)
//      - Mode 2: MP4 Compressed Compact  (GPU D3D11VA decode + VideoProcessor resize <=1280 + low bitrate + AAC)
//      - Mode 3: Animated GIF 15fps (<=1080px, adaptive 15-bit Median-Cut palette + dirty-rect delta + LZW)
//      - Mode 4: Animated GIF 10fps Compact (<=720px)
//
// Zero idle overhead: no worker thread, D3D11 device, WASAPI client, or Media Foundation state exists when idle.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <shellapi.h>
#include <shlobj.h>
#include <dwmapi.h>
#include <d3d11.h>
#include <d3d11_1.h>
#include <dxgi1_4.h>
#include <d3dcompiler.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mferror.h>
#include <codecapi.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <mmreg.h>
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

// From record_draw_win.cpp
void rec_draw_open(int x, int y, int w, int h);
void rec_draw_set_recording(int on);
void rec_draw_close(void);

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

static uint64_t file_size_of(const std::wstring &path) {
  WIN32_FILE_ATTRIBUTE_DATA fad = {};
  if (GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &fad)) {
    return ((uint64_t)fad.nFileSizeHigh << 32) | (uint64_t)fad.nFileSizeLow;
  }
  return 0;
}

static void rec_post(const char *state, int64_t ms, int frames, uint64_t bytes, uint64_t orig_bytes, int pct,
                     int has_audio, const char *codec, const std::wstring &path, const char *err) {
  std::string p_esc = json_escape(wide_to_utf8(path));
  std::string e_esc = err ? json_escape(err) : "";
  std::string c_esc = codec ? json_escape(codec) : "";
  char buf[1600];
  int n = snprintf(buf, sizeof buf,
                   "{\"do\":\"rec\",\"state\":\"%s\",\"ms\":%lld,\"frames\":%d,\"bytes\":%llu,"
                   "\"orig\":%llu,\"pct\":%d,\"audio\":%d,\"codec\":\"%s\",\"path\":\"%s\",\"err\":\"%s\"}",
                   state, (long long)ms, frames, (unsigned long long)bytes, (unsigned long long)orig_bytes,
                   pct, has_audio, c_esc.c_str(), p_esc.c_str(), e_esc.c_str());
  if (n > 0) {
    size_t len = (size_t)n < sizeof buf ? (size_t)n : sizeof buf - 1;
    mb_post("ps", buf, len, NULL, 0);
  }
}

static int copy_file_to_clipboard(const std::wstring &path) {
  if (path.empty()) return 0;
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

  HANDLE rec_thread;
  HANDLE exp_thread;
  HANDLE wake_ev;
  volatile LONG stop_req;  // 0 running, 1 finish, 2 cancel
  volatile LONG pause_req; // 0 running, 1 paused
  volatile LONG running;
  volatile LONG exporting;
  volatile LONG exp_cancel;

  int fps;
  int cursor;
  int want_audio;

  // Master temp recording state (kept after Stop until panel closes so user can export MP4/Compressed/GIF).
  std::wstring master_path;
  uint64_t master_bytes;
  int64_t master_ms;
  int master_w, master_h, master_fps, master_audio;
  std::string master_codec;

  // Export job params
  std::wstring exp_dest;
  int exp_fmt;       // 0=MP4 H.265, 1=MP4 H.264, 2=GIF
  int exp_quality;   // 0=Original, 1=High, 2=Balanced, 3=Compact
  int exp_max_side;  // 0=Original, else max long edge (1920/1280/854)
  int exp_gif_fps;   // 10 / 15 / 20
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

// ---- MP4 HEVC 'hev1' -> 'hvc1' in-place box patcher ----

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

  std::vector<uint8_t> prev_rgb;
  bool has_pending = false;
  int pend_x = 0, pend_y = 0, pend_w = 0, pend_h = 0;
  int pend_delay_cs = 0;
  bool pend_local_pal = false;
  uint8_t pend_pal[256 * 3];
  std::vector<uint8_t> pend_idx;
  int frames_written = 0;

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
    memset(lut, 0xFF, 32768);
    for (int i = 0; i < ncols; i++) {
      for (size_t j = boxes[i].lo; j < boxes[i].hi; j++) lut[entries[j].key] = (uint8_t)i;
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
    fputc(0xF7, fp);
    fputc(0, fp);
    fputc(0, fp);
    fwrite(global_pal, 1, 256 * 3, fp);
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
    fputc(0, fp);
  }

  void flush_pending() {
    if (!has_pending || !fp) return;
    if (!header_written) write_header();
    uint16_t delay = (uint16_t)(pend_delay_cs < 2 ? 2 : (pend_delay_cs > 65535 ? 65535 : pend_delay_cs));
    uint8_t gce[8] = {0x21, 0xF9, 0x04, 0x05, (uint8_t)(delay & 0xFF), (uint8_t)((delay >> 8) & 0xFF), 255, 0x00};
    fwrite(gce, 1, sizeof gce, fp);
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

// ---- CPU BT.709 BGRA/RGBA -> NV12 (studio range 16..235 / 16..240) ----

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

// ---- One-time Media Foundation startup (avoids Windows mfplat.dll work-queue handle leaks on 0->1->0 cycles) ----

static INIT_ONCE g_mf_once = INIT_ONCE_STATIC_INIT;
static BOOL g_mf_ok = FALSE;

static BOOL CALLBACK mf_init_cb(PINIT_ONCE, PVOID, PVOID *) {
  g_mf_ok = SUCCEEDED(MFStartup(MF_VERSION, MFSTARTUP_LITE)) ? TRUE : FALSE;
  return TRUE;
}

static bool ensure_mf_started() {
  InitOnceExecuteOnce(&g_mf_once, mf_init_cb, NULL, NULL);
  return g_mf_ok != FALSE;
}

// ---- MP4 Encoder (Optimal Cascade: HW HEVC -> HW H.264 -> SW H.264, optional AAC audio stream) ----

struct Mp4Encoder {
  bool gpu_path = false;
  bool is_hevc = false;
  bool has_audio = false;
  bool audio_passthrough = false;
  std::string codec_name;
  int out_w = 0, out_h = 0, fps = 30;
  UINT32 custom_bps_hevc = 0, custom_bps_h264 = 0;
  std::wstring out_path;

  ComPtr<IMFDXGIDeviceManager> dev_mgr;
  ComPtr<IMFSinkWriter> writer;
  DWORD video_stream = 0;
  DWORD audio_stream = 0;

  ComPtr<ID3D11VideoDevice> vdev;
  ComPtr<ID3D11VideoContext> vctx;
  ComPtr<ID3D11VideoProcessorEnumerator> vpenum;
  ComPtr<ID3D11VideoProcessor> vp;
  int vp_in_w = 0, vp_in_h = 0;
  bool vp_in_yuv = false;

  CRITICAL_SECTION write_lock = {};
  bool lock_init = false;

  static void set_sdr_color(IMFMediaType *mt) {
    mt->SetUINT32(MF_MT_VIDEO_PRIMARIES, MFVideoPrimaries_BT709);
    mt->SetUINT32(MF_MT_TRANSFER_FUNCTION, MFVideoTransFunc_sRGB);
    mt->SetUINT32(MF_MT_YUV_MATRIX, MFVideoTransferMatrix_BT709);
    mt->SetUINT32(MF_MT_VIDEO_NOMINAL_RANGE, MFNominalRange_16_235);
  }

  UINT32 pick_bitrate(bool hevc) const {
    if (hevc && custom_bps_hevc > 0) return custom_bps_hevc;
    if (!hevc && custom_bps_h264 > 0) return custom_bps_h264;
    double bpp = hevc ? 0.095 : 0.14;
    double raw = (double)out_w * (double)out_h * (double)fps * bpp;
    double lo = hevc ? 1200000.0 : 1500000.0;
    double hi = hevc ? 22000000.0 : 30000000.0;
    if (raw < lo) raw = lo;
    if (raw > hi) raw = hi;
    return (UINT32)raw;
  }

  bool add_aac_stream(IMFMediaType *passthrough_mt) {
    if (passthrough_mt) {
      if (SUCCEEDED(writer->AddStream(passthrough_mt, &audio_stream)) &&
          SUCCEEDED(writer->SetInputMediaType(audio_stream, passthrough_mt, NULL))) {
        has_audio = true;
        audio_passthrough = true;
        return true;
      }
    }
    ComPtr<IMFMediaType> a_out;
    if (FAILED(MFCreateMediaType(&a_out))) return false;
    a_out->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
    a_out->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_AAC);
    a_out->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
    a_out->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, 48000);
    a_out->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, 2);
    a_out->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, 16000);  // 128 kbps
    a_out->SetUINT32(MF_MT_AAC_PAYLOAD_TYPE, 0);
    if (FAILED(writer->AddStream(a_out.Get(), &audio_stream))) return false;

    ComPtr<IMFMediaType> a_in;
    if (FAILED(MFCreateMediaType(&a_in))) return false;
    a_in->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
    a_in->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
    a_in->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
    a_in->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, 48000);
    a_in->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, 2);
    a_in->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, 4);
    a_in->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, 48000 * 4);
    if (FAILED(writer->SetInputMediaType(audio_stream, a_in.Get(), NULL))) return false;
    has_audio = true;
    audio_passthrough = false;
    return true;
  }

  bool try_open_tier(ID3D11Device *dev, IMFDXGIDeviceManager *shared_mgr, bool try_hevc, bool try_hw,
                     bool want_audio, IMFMediaType *passthrough_audio) {
    writer.Reset();
    dev_mgr.Reset();
    vdev.Reset();
    vctx.Reset();
    vpenum.Reset();
    vp.Reset();
    has_audio = false;
    audio_passthrough = false;

    ComPtr<IMFAttributes> attr;
    if (FAILED(MFCreateAttributes(&attr, 4))) return false;
    attr->SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, try_hw ? TRUE : FALSE);
    attr->SetUINT32(MF_SINK_WRITER_DISABLE_THROTTLING, TRUE);
    if (try_hw) {
      if (shared_mgr) {
        dev_mgr = shared_mgr;
      } else {
        if (!dev) return false;
        UINT reset_token = 0;
        if (FAILED(MFCreateDXGIDeviceManager(&reset_token, &dev_mgr))) return false;
        if (FAILED(dev_mgr->ResetDevice(dev, reset_token))) return false;
      }
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
    out_mt->SetUINT32(MF_MT_AVG_BITRATE, pick_bitrate(try_hevc));
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

    if (FAILED(writer->AddStream(out_mt.Get(), &video_stream))) {
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

    // Same PeakConstrainedVBR + GOP policy proven in ScreenReplay (replay_export.cpp):
    // quiet screens use minimal bits while motion stays bounded by the target bitrate.
    UINT32 bps = pick_bitrate(try_hevc);
    ComPtr<IMFAttributes> enc_params;
    if (SUCCEEDED(MFCreateAttributes(&enc_params, 7))) {
      enc_params->SetUINT32(CODECAPI_AVEncCommonMeanBitRate, bps);
      enc_params->SetUINT32(CODECAPI_AVEncMPVGOPSize, (UINT32)(fps * 2));
      enc_params->SetUINT32(CODECAPI_AVEncMPVDefaultBPictureCount, 0);
      enc_params->SetUINT32(CODECAPI_AVEncCommonRateControlMode, eAVEncCommonRateControlMode_PeakConstrainedVBR);
      enc_params->SetUINT32(CODECAPI_AVEncCommonMaxBitRate, bps);
      enc_params->SetUINT32(CODECAPI_AVEncCommonBufferSize, (UINT32)((uint64_t)bps * 250ULL / 1000ULL));
      enc_params->SetUINT32(CODECAPI_AVEncCommonQualityVsSpeed, 70);
    }
    if (FAILED(writer->SetInputMediaType(video_stream, in_mt.Get(), enc_params.Get()))) {
      ComPtr<IMFAttributes> basic_params;
      if (SUCCEEDED(MFCreateAttributes(&basic_params, 2))) {
        basic_params->SetUINT32(CODECAPI_AVEncMPVGOPSize, (UINT32)(fps * 2));
        basic_params->SetUINT32(CODECAPI_AVEncMPVDefaultBPictureCount, 0);
      }
      if (FAILED(writer->SetInputMediaType(video_stream, in_mt.Get(), basic_params.Get())) &&
          FAILED(writer->SetInputMediaType(video_stream, in_mt.Get(), NULL))) {
        writer.Reset();
        return false;
      }
    }

    if (want_audio) add_aac_stream(passthrough_audio);

    if (FAILED(writer->BeginWriting())) {
      writer.Reset();
      has_audio = false;
      return false;
    }

    gpu_path = try_hw;
    is_hevc = try_hevc;
    if (try_hevc && try_hw) codec_name = "HEVC (HW)";
    else if (try_hw) codec_name = "H.264 (HW)";
    else codec_name = "H.264 (SW)";
    return true;
  }

  bool ensure_vp(ID3D11Device *dev, ID3D11DeviceContext *ctx, int in_w, int in_h, bool in_yuv) {
    if (vp && vp_in_w == in_w && vp_in_h == in_h && vp_in_yuv == in_yuv) return true;
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
      vctx1->VideoProcessorSetStreamColorSpace1(
          vp.Get(), 0, in_yuv ? DXGI_COLOR_SPACE_YCBCR_STUDIO_G22_LEFT_P709 : DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709);
      vctx1->VideoProcessorSetOutputColorSpace1(vp.Get(), DXGI_COLOR_SPACE_YCBCR_STUDIO_G22_LEFT_P709);
    }
    vp_in_w = in_w;
    vp_in_h = in_h;
    vp_in_yuv = in_yuv;
    return true;
  }

  bool open(ID3D11Device *dev, IMFDXGIDeviceManager *shared_mgr, const std::wstring &path, int w, int h,
            int target_fps, bool want_audio, IMFMediaType *passthrough_audio = NULL, bool prefer_hevc = true) {
    if (!ensure_mf_started()) return false;
    if (!lock_init) {
      InitializeCriticalSection(&write_lock);
      lock_init = true;
    }
    out_path = path;
    out_w = w;
    out_h = h;
    fps = target_fps;

    const char *force = getenv("PINSHOT_REC_CODEC");
    bool allow_hevc = prefer_hevc && (!force || !force[0] || strcmp(force, "hevc") == 0);
    bool allow_hw = !force || !force[0] || strcmp(force, "sw") != 0;

    if ((dev || shared_mgr) && allow_hw && allow_hevc &&
        try_open_tier(dev, shared_mgr, true, true, want_audio, passthrough_audio))
      return true;
    DeleteFileW(out_path.c_str());
    if ((dev || shared_mgr) && allow_hw &&
        try_open_tier(dev, shared_mgr, false, true, want_audio, passthrough_audio))
      return true;
    DeleteFileW(out_path.c_str());
    if (try_open_tier(NULL, NULL, false, false, want_audio, passthrough_audio)) return true;
    DeleteFileW(out_path.c_str());
    if (lock_init) {
      DeleteCriticalSection(&write_lock);
      lock_init = false;
    }
    return false;
  }

  bool write_gpu_frame(ID3D11Device *dev, ID3D11DeviceContext *ctx, ID3D11Texture2D *src_tex, UINT src_sub,
                       bool src_is_yuv, int sx, int sy, int sw, int sh, LONGLONG pts, LONGLONG dur) {
    D3D11_TEXTURE2D_DESC sd = {};
    src_tex->GetDesc(&sd);
    if (!ensure_vp(dev, ctx, (int)sd.Width, (int)sd.Height, src_is_yuv)) return false;

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
    ivd.Texture2D.ArraySlice = src_sub;
    ComPtr<ID3D11VideoProcessorInputView> in_view;
    if (FAILED(vdev->CreateVideoProcessorInputView(src_tex, vpenum.Get(), &ivd, &in_view))) return false;

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
    EnterCriticalSection(&write_lock);
    HRESULT whr = writer->WriteSample(video_stream, sample.Get());
    LeaveCriticalSection(&write_lock);
    return SUCCEEDED(whr);
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
    EnterCriticalSection(&write_lock);
    HRESULT whr = writer->WriteSample(video_stream, sample.Get());
    LeaveCriticalSection(&write_lock);
    return SUCCEEDED(whr);
  }

  bool write_pcm_audio(const int16_t *pcm, int frames_48k, LONGLONG pts, LONGLONG dur) {
    if (!has_audio || frames_48k <= 0) return true;
    DWORD bytes = (DWORD)(frames_48k * 4);
    ComPtr<IMFMediaBuffer> buf;
    if (FAILED(MFCreateMemoryBuffer(bytes, &buf))) return false;
    BYTE *dst = NULL;
    if (FAILED(buf->Lock(&dst, NULL, NULL))) return false;
    memcpy(dst, pcm, bytes);
    buf->Unlock();
    buf->SetCurrentLength(bytes);

    ComPtr<IMFSample> sample;
    if (FAILED(MFCreateSample(&sample))) return false;
    sample->AddBuffer(buf.Get());
    sample->SetSampleTime(pts);
    sample->SetSampleDuration(dur);
    EnterCriticalSection(&write_lock);
    HRESULT whr = writer->WriteSample(audio_stream, sample.Get());
    LeaveCriticalSection(&write_lock);
    return SUCCEEDED(whr);
  }

  bool write_audio_sample(IMFSample *sample) {
    if (!has_audio || !sample) return true;
    EnterCriticalSection(&write_lock);
    HRESULT whr = writer->WriteSample(audio_stream, sample);
    LeaveCriticalSection(&write_lock);
    return SUCCEEDED(whr);
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
    if (lock_init) {
      DeleteCriticalSection(&write_lock);
      lock_init = false;
    }
    if (cancel || FAILED(hr)) {
      DeleteFileW(out_path.c_str());
      return 0;
    }
    if (is_hevc) patch_mp4_hev1_to_hvc1(out_path);
    return file_size_of(out_path);
  }
};

// ---- WASAPI System Audio Loopback Capture Thread ----

struct SysAudioPump {
  Mp4Encoder *enc = NULL;
  HANDLE thread = NULL;
  HANDLE stop_ev = NULL;
  volatile LONG *pause_flag = NULL;
  bool active = false;

  static int16_t clamp_s16(float v) {
    if (v > 1.0f) v = 1.0f;
    if (v < -1.0f) v = -1.0f;
    return (int16_t)(v * 32767.0f);
  }

  static DWORD WINAPI audio_proc(LPVOID arg) {
    SysAudioPump *self = (SysAudioPump *)arg;
    HRESULT co = CoInitializeEx(NULL, COINIT_MULTITHREADED);

    ComPtr<IMMDeviceEnumerator> enumerator;
    ComPtr<IMMDevice> dev;
    ComPtr<IAudioClient> cap_client;
    ComPtr<IAudioCaptureClient> cap;
    ComPtr<IAudioClient> sil_client;
    ComPtr<IAudioRenderClient> sil_render;
    WAVEFORMATEX *mix = NULL;

    auto cleanup = [&]() {
      if (cap_client) {
        cap_client->Stop();
        cap_client->Reset();
      }
      if (sil_client) {
        sil_client->Stop();
        sil_client->Reset();
      }
      if (mix) CoTaskMemFree(mix);
      cap.Reset();
      cap_client.Reset();
      sil_render.Reset();
      sil_client.Reset();
      dev.Reset();
      enumerator.Reset();
      if (SUCCEEDED(co)) CoUninitialize();
    };

    if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), NULL, CLSCTX_ALL, IID_PPV_ARGS(&enumerator))) ||
        FAILED(enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &dev)) ||
        FAILED(dev->Activate(__uuidof(IAudioClient), CLSCTX_ALL, NULL, (void **)&cap_client)) ||
        FAILED(cap_client->GetMixFormat(&mix)) || !mix) {
      cleanup();
      return 0;
    }

    // Silent render client keeps WASAPI loopback pumping continuous packets even during desktop silence.
    UINT32 sil_buf_frames = 0;
    if (SUCCEEDED(dev->Activate(__uuidof(IAudioClient), CLSCTX_ALL, NULL, (void **)&sil_client)) &&
        SUCCEEDED(sil_client->Initialize(AUDCLNT_SHAREMODE_SHARED, 0, 1000000, 0, mix, NULL)) &&
        SUCCEEDED(sil_client->GetBufferSize(&sil_buf_frames)) &&
        SUCCEEDED(sil_client->GetService(IID_PPV_ARGS(&sil_render)))) {
      BYTE *sil_data = NULL;
      if (SUCCEEDED(sil_render->GetBuffer(sil_buf_frames, &sil_data))) {
        sil_render->ReleaseBuffer(sil_buf_frames, AUDCLNT_BUFFERFLAGS_SILENT);
      }
      sil_client->Start();
    }

    if (FAILED(cap_client->Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK, 1000000, 0, mix, NULL)) ||
        FAILED(cap_client->GetService(IID_PPV_ARGS(&cap))) || FAILED(cap_client->Start())) {
      cleanup();
      return 0;
    }

    bool is_float = (mix->wFormatTag == WAVE_FORMAT_IEEE_FLOAT);
    if (mix->wFormatTag == WAVE_FORMAT_EXTENSIBLE && mix->cbSize >= 22) {
      const WAVEFORMATEXTENSIBLE *ex = (const WAVEFORMATEXTENSIBLE *)mix;
      is_float = (ex->SubFormat == KSDATAFORMAT_SUBTYPE_IEEE_FLOAT);
    }
    int src_rate = (int)mix->nSamplesPerSec;
    int src_ch = (int)mix->nChannels;
    int src_bits = (int)mix->wBitsPerSample;

    int64_t total_out_frames = 0;
    double resamp_pos = 0.0;
    std::vector<float> stereo_in;
    std::vector<int16_t> pcm_out;
    float prev_l = 0.0f, prev_r = 0.0f;

    while (WaitForSingleObject(self->stop_ev, 10) == WAIT_TIMEOUT) {
      // Keep silent render buffer topped up so the audio engine never underflows/stops.
      if (sil_client && sil_render && sil_buf_frames > 0) {
        UINT32 pad = 0;
        if (SUCCEEDED(sil_client->GetCurrentPadding(&pad)) && pad < sil_buf_frames) {
          UINT32 avail = sil_buf_frames - pad;
          BYTE *sd = NULL;
          if (avail > 0 && SUCCEEDED(sil_render->GetBuffer(avail, &sd))) {
            sil_render->ReleaseBuffer(avail, AUDCLNT_BUFFERFLAGS_SILENT);
          }
        }
      }

      UINT32 pkt_len = 0;
      while (SUCCEEDED(cap->GetNextPacketSize(&pkt_len)) && pkt_len > 0) {
        BYTE *data = NULL;
        UINT32 num_frames = 0;
        DWORD flags = 0;
        if (FAILED(cap->GetBuffer(&data, &num_frames, &flags, NULL, NULL))) break;

        bool paused = self->pause_flag && InterlockedCompareExchange(self->pause_flag, 0, 0) != 0;
        if (!paused && num_frames > 0) {
          stereo_in.resize((size_t)num_frames * 2);
          if ((flags & AUDCLNT_BUFFERFLAGS_SILENT) || !data) {
            std::fill(stereo_in.begin(), stereo_in.end(), 0.0f);
          } else if (is_float && src_bits == 32) {
            const float *fp = (const float *)data;
            for (UINT32 i = 0; i < num_frames; i++) {
              float l = fp[i * src_ch + 0];
              float r = (src_ch >= 2) ? fp[i * src_ch + 1] : l;
              if (src_ch >= 6) {
                float c = fp[i * src_ch + 2] * 0.707f;
                l += c;
                r += c;
              }
              stereo_in[i * 2 + 0] = l;
              stereo_in[i * 2 + 1] = r;
            }
          } else if (src_bits == 16) {
            const int16_t *sp = (const int16_t *)data;
            for (UINT32 i = 0; i < num_frames; i++) {
              float l = sp[i * src_ch + 0] / 32768.0f;
              float r = (src_ch >= 2) ? (sp[i * src_ch + 1] / 32768.0f) : l;
              stereo_in[i * 2 + 0] = l;
              stereo_in[i * 2 + 1] = r;
            }
          } else {
            std::fill(stereo_in.begin(), stereo_in.end(), 0.0f);
          }

          pcm_out.clear();
          if (src_rate == 48000) {
            pcm_out.resize((size_t)num_frames * 2);
            for (UINT32 i = 0; i < num_frames; i++) {
              pcm_out[i * 2 + 0] = clamp_s16(stereo_in[i * 2 + 0]);
              pcm_out[i * 2 + 1] = clamp_s16(stereo_in[i * 2 + 1]);
            }
          } else {
            double step = (double)src_rate / 48000.0;
            while (resamp_pos < (double)num_frames) {
              int idx = (int)floor(resamp_pos);
              float frac = (float)(resamp_pos - (double)idx);
              float l0 = (idx < 0) ? prev_l : stereo_in[(size_t)idx * 2 + 0];
              float r0 = (idx < 0) ? prev_r : stereo_in[(size_t)idx * 2 + 1];
              int idx1 = (idx + 1 < (int)num_frames) ? (idx + 1) : ((int)num_frames - 1);
              float l1 = stereo_in[(size_t)idx1 * 2 + 0];
              float r1 = stereo_in[(size_t)idx1 * 2 + 1];
              pcm_out.push_back(clamp_s16(l0 + (l1 - l0) * frac));
              pcm_out.push_back(clamp_s16(r0 + (r1 - r0) * frac));
              resamp_pos += step;
            }
            resamp_pos -= (double)num_frames;
            prev_l = stereo_in[(size_t)(num_frames - 1) * 2 + 0];
            prev_r = stereo_in[(size_t)(num_frames - 1) * 2 + 1];
          }

          int out_n = (int)(pcm_out.size() / 2);
          if (out_n > 0) {
            LONGLONG pts = (total_out_frames * 10000000LL) / 48000LL;
            LONGLONG dur = ((int64_t)out_n * 10000000LL) / 48000LL;
            self->enc->write_pcm_audio(pcm_out.data(), out_n, pts, dur);
            total_out_frames += out_n;
          }
        }
        cap->ReleaseBuffer(num_frames);
      }
    }

    cleanup();
    return 0;
  }

  void start(Mp4Encoder *encoder, volatile LONG *pause_ptr) {
    enc = encoder;
    pause_flag = pause_ptr;
    stop_ev = CreateEventW(NULL, TRUE, FALSE, NULL);
    thread = CreateThread(NULL, 0, audio_proc, this, 0, NULL);
    active = (thread != NULL);
  }

  void stop() {
    if (stop_ev) SetEvent(stop_ev);
    if (thread) {
      WaitForSingleObject(thread, 3000);
      CloseHandle(thread);
      thread = NULL;
    }
    if (stop_ev) {
      CloseHandle(stop_ev);
      stop_ev = NULL;
    }
    active = false;
  }
};

// ---- Live Recording Worker Thread (always records temp high-quality MP4) ----

struct RecWorkerState {
  CRITICAL_SECTION lock;
  ComPtr<WGC::IDirect3D11CaptureFrame> last_frame;
  HANDLE first_frame_ev = NULL;
  uint64_t frame_seq = 0;
  bool got_frame = false;
};

static void rec_trace_vram(const char *tag, ID3D11Device *dev) {
  if (!getenv("PINSHOT_REC_MEM")) return;
  ComPtr<IDXGIFactory4> fac;
  ComPtr<IDXGIAdapter3> adp;
  if (dev) {
    ComPtr<IDXGIDevice> xd;
    ComPtr<IDXGIAdapter> a;
    if (SUCCEEDED(dev->QueryInterface(IID_PPV_ARGS(&xd))) && SUCCEEDED(xd->GetAdapter(&a))) a.As(&adp);
  }
  if (!adp && SUCCEEDED(CreateDXGIFactory1(IID_PPV_ARGS(&fac)))) {
    ComPtr<IDXGIAdapter1> a1;
    if (SUCCEEDED(fac->EnumAdapters1(0, &a1))) a1.As(&adp);
  }
  if (adp) {
    DXGI_QUERY_VIDEO_MEMORY_INFO loc = {}, non = {};
    adp->QueryVideoMemoryInfo(0, DXGI_MEMORY_SEGMENT_GROUP_LOCAL, &loc);
    adp->QueryVideoMemoryInfo(0, DXGI_MEMORY_SEGMENT_GROUP_NON_LOCAL, &non);
    fprintf(stderr, "REC_VRAM %-20s local=%.1f MB  nonlocal=%.1f MB\n", tag,
            (double)loc.CurrentUsage / (1024.0 * 1024.0), (double)non.CurrentUsage / (1024.0 * 1024.0));
    fflush(stderr);
  }
}

static std::wstring make_temp_master_path() {
  wchar_t tmp[MAX_PATH] = {};
  GetTempPathW(MAX_PATH, tmp);
  wchar_t out[MAX_PATH] = {};
  swprintf_s(out, L"%lsPinShot_rec_%lu_%llu.mp4", tmp, (unsigned long)GetCurrentProcessId(),
             (unsigned long long)GetTickCount64());
  return out;
}

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
  int fps = R.fps;
  int cursor = R.cursor;
  bool want_audio = (R.want_audio != 0);
  std::wstring master_path = make_temp_master_path();

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
                ws.frame_seq++;
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

  if (wgc_ok) WaitForSingleObject(ws.first_frame_ev, 500);

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

  Mp4Encoder mp4;
  bool enc_ok = mp4.open(wgc_ok ? dev.Get() : NULL, NULL, master_path, rw, rh, fps, want_audio);
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
    rec_post("error", 0, 0, 0, 0, 0, 0, "", L"", "无法初始化视频编码器");
    return 0;
  }

  SysAudioPump audio_pump;
  if (mp4.has_audio) {
    audio_pump.start(&mp4, &R.pause_req);
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
  uint64_t last_shaded_seq = 0;
  ID3D11Texture2D *cached_hdr_srgb = NULL;

  rec_trace_vram("rec_start", dev.Get());
  rec_post("recording", 0, 0, 0, 0, 0, mp4.has_audio ? 1 : 0, mp4.codec_name.c_str(), L"", "");

  while (InterlockedCompareExchange(&R.stop_req, 0, 0) == 0) {
    bool paused = InterlockedCompareExchange(&R.pause_req, 0, 0) != 0;
    QueryPerformanceCounter(&t_now);
    if (paused) {
      if (!was_paused) {
        was_paused = true;
        pause_began = t_now.QuadPart;
        rec_post("paused", last_elapsed_ms, frames, 0, 0, 0, mp4.has_audio ? 1 : 0, mp4.codec_name.c_str(), L"", "");
      }
      WaitForSingleObject(R.wake_ev, 60);
      continue;
    } else if (was_paused) {
      was_paused = false;
      paused_ticks += (t_now.QuadPart - pause_began);
      rec_post("recording", last_elapsed_ms, frames, 0, 0, 0, mp4.has_audio ? 1 : 0, mp4.codec_name.c_str(), L"", "");
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

    ComPtr<WGC::IDirect3D11CaptureFrame> fr;
    ComPtr<ID3D11Texture2D> src_tex;
    uint64_t fr_seq = 0;
    if (wgc_ok) {
      EnterCriticalSection(&ws.lock);
      fr = ws.last_frame;
      fr_seq = ws.frame_seq;
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
    if (mp4.gpu_path && src_tex) {
      ID3D11Texture2D *rgb_tex = src_tex.Get();
      int sx = rx, sy = ry;
      if (is_hdr) {
        if (fr_seq != last_shaded_seq || !cached_hdr_srgb) {
          cached_hdr_srgb = prepare_hdr_srgb(src_tex.Get());
          last_shaded_seq = fr_seq;
        }
        rgb_tex = cached_hdr_srgb;
        sx = 0;
        sy = 0;
      }
      if (rgb_tex) {
        wrote = mp4.write_gpu_frame(dev.Get(), ctx.Get(), rgb_tex, 0, false, sx, sy, rw, rh, next_slot_hns, dur_hns);
      }
    } else {
      int pitch = 0;
      bool is_bgra = true;
      bool got = false;
      if (src_tex) {
        ID3D11Texture2D *rgb_tex = src_tex.Get();
        if (is_hdr) {
          if (fr_seq != last_shaded_seq || !cached_hdr_srgb) {
            cached_hdr_srgb = prepare_hdr_srgb(src_tex.Get());
            last_shaded_seq = fr_seq;
          }
          rgb_tex = cached_hdr_srgb;
        }
        if (rgb_tex) got = read_cpu_srgb(rgb_tex, is_hdr ? 0 : rx, is_hdr ? 0 : ry, cpu_bgra, pitch, is_bgra);
      } else {
        got = capture_gdi(cpu_bgra, pitch, is_bgra);
      }
      if (got) wrote = mp4.write_cpu_frame(cpu_bgra.data(), pitch, is_bgra, next_slot_hns, dur_hns);
    }

    if (wrote) {
      frames++;
      slot++;
      int64_t behind_slots = (elapsed_hns - (slot * 10000000LL) / fps) * fps / 10000000LL;
      if (behind_slots > 3) slot += behind_slots - 1;
    } else {
      WaitForSingleObject(R.wake_ev, 5);
    }

    if (elapsed_ms - last_report_ms >= 100) {
      last_report_ms = elapsed_ms;
      rec_post("recording", elapsed_ms, frames, 0, 0, 0, mp4.has_audio ? 1 : 0, mp4.codec_name.c_str(), L"", "");
    }
  }

  bool cancel = InterlockedCompareExchange(&R.stop_req, 0, 0) == 2;
  if (audio_pump.active) audio_pump.stop();
  if (!cancel) rec_post("saving", last_elapsed_ms, frames, 0, 0, 0, mp4.has_audio ? 1 : 0, mp4.codec_name.c_str(), L"", "");

  bool had_audio = mp4.has_audio;
  std::string codec_used = mp4.codec_name;
  uint64_t final_bytes = mp4.finish(cancel || frames == 0);

  // Release all WGC and D3D11 objects and trim driver pools immediately.
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
  rec_trace_vram("rec_after_trim", NULL);

  timeEndPeriod(1);
  if (SUCCEEDED(ro_hr)) RoUninitialize();
  InterlockedExchange(&R.running, 0);

  if (cancel) {
    DeleteFileW(master_path.c_str());
    rec_post("cancelled", last_elapsed_ms, frames, 0, 0, 0, 0, codec_used.c_str(), L"", "");
  } else if (final_bytes > 0) {
    if (!R.master_path.empty() && R.master_path != master_path) DeleteFileW(R.master_path.c_str());
    R.master_path = master_path;
    R.master_bytes = final_bytes;
    R.master_ms = last_elapsed_ms;
    R.master_w = rw;
    R.master_h = rh;
    R.master_fps = fps;
    R.master_audio = had_audio ? 1 : 0;
    R.master_codec = codec_used;
    rec_post("recorded", last_elapsed_ms, frames, final_bytes, final_bytes, 100, had_audio ? 1 : 0, codec_used.c_str(),
             master_path, "");
  } else {
    DeleteFileW(master_path.c_str());
    rec_post("error", last_elapsed_ms, frames, 0, 0, 0, 0, codec_used.c_str(), L"", "保存录屏文件失败");
  }
  return 0;
}

// ---- Post-Recording Export / Compression Worker Thread ----

static DWORD WINAPI export_worker(LPVOID) {
  HRESULT co = CoInitializeEx(NULL, COINIT_MULTITHREADED);
  std::wstring src = R.master_path;
  std::wstring dst = R.exp_dest;
  int fmt = R.exp_fmt;           // 0=MP4 H.265, 1=MP4 H.264, 2=GIF
  int quality = R.exp_quality;   // 0=Original, 1=High, 2=Balanced, 3=Compact
  int max_side = R.exp_max_side; // 0=Original, else 1920/1280/854
  int gif_fps = R.exp_gif_fps > 0 ? R.exp_gif_fps : 15;
  uint64_t orig_bytes = R.master_bytes;
  int64_t total_ms = R.master_ms > 0 ? R.master_ms : 1;
  int src_w = R.master_w;
  int src_h = R.master_h;
  int src_fps = R.master_fps > 0 ? R.master_fps : 30;
  bool src_audio = (R.master_audio != 0);

  rec_make_dirs(dst);

  bool need_resize = (max_side > 0) && (src_w > max_side || src_h > max_side);
  bool master_is_hevc = (R.master_codec.rfind("HEVC", 0) == 0);
  bool want_hevc = (fmt == 0);
  bool direct_copy = (fmt == 0 || fmt == 1) && quality == 0 && !need_resize && (want_hevc == master_is_hevc);

  // Zero re-encode instant copy when codec, quality=Original, and size all match master
  if (direct_copy) {
    if (CopyFileW(src.c_str(), dst.c_str(), FALSE)) {
      uint64_t sz = file_size_of(dst);
      copy_file_to_clipboard(dst);
      InterlockedExchange(&R.exporting, 0);
      if (SUCCEEDED(co)) CoUninitialize();
      rec_post("exported", total_ms, 0, sz, orig_bytes, 100, src_audio ? 1 : 0, R.master_codec.c_str(), dst, "");
      return 0;
    }
    InterlockedExchange(&R.exporting, 0);
    if (SUCCEEDED(co)) CoUninitialize();
    rec_post("export-error", total_ms, 0, 0, orig_bytes, 0, 0, "", dst, "保存文件失败");
    return 0;
  }

  if (!ensure_mf_started()) {
    InterlockedExchange(&R.exporting, 0);
    if (SUCCEEDED(co)) CoUninitialize();
    rec_post("export-error", total_ms, 0, 0, orig_bytes, 0, 0, "", dst, "初始化转码失败");
    return 0;
  }

  // MP4 transcode / compress (fmt 0 = H.265 preferred, fmt 1 = H.264)
  if (fmt == 0 || fmt == 1) {
    int out_w = src_w, out_h = src_h;
    if (need_resize) {
      double k = (double)max_side / (double)(out_w > out_h ? out_w : out_h);
      out_w = std::max(16, ((int)(out_w * k + 0.5)) & ~1);
      out_h = std::max(16, ((int)(out_h * k + 0.5)) & ~1);
    }

    ComPtr<ID3D11Device> dev;
    ComPtr<ID3D11DeviceContext> ctx;
    ComPtr<IMFDXGIDeviceManager> mgr;
    bool gpu_dec = false;
    D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0};
    if (SUCCEEDED(D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL,
                                    D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_VIDEO_SUPPORT, levels, 2,
                                    D3D11_SDK_VERSION, &dev, NULL, &ctx))) {
      ComPtr<ID3D10Multithread> mt;
      if (SUCCEEDED(dev.As(&mt))) mt->SetMultithreadProtected(TRUE);
      UINT tok = 0;
      if (SUCCEEDED(MFCreateDXGIDeviceManager(&tok, &mgr)) && SUCCEEDED(mgr->ResetDevice(dev.Get(), tok))) {
        gpu_dec = true;
      }
    }

    ComPtr<IMFAttributes> rattr;
    MFCreateAttributes(&rattr, 3);
    if (gpu_dec) {
      rattr->SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, TRUE);
      rattr->SetUINT32(MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING, TRUE);
      rattr->SetUnknown(MF_SOURCE_READER_D3D_MANAGER, mgr.Get());
    } else {
      rattr->SetUINT32(MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, TRUE);
    }

    ComPtr<IMFSourceReader> reader;
    if (FAILED(MFCreateSourceReaderFromURL(src.c_str(), rattr.Get(), &reader))) {
      InterlockedExchange(&R.exporting, 0);
      if (SUCCEEDED(co)) CoUninitialize();
      rec_post("export-error", total_ms, 0, 0, orig_bytes, 0, 0, "", dst, "读取源视频失败");
      return 0;
    }

    reader->SetStreamSelection((DWORD)MF_SOURCE_READER_ALL_STREAMS, FALSE);
    reader->SetStreamSelection((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, TRUE);

    ComPtr<IMFMediaType> vdec;
    MFCreateMediaType(&vdec);
    vdec->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    vdec->SetGUID(MF_MT_SUBTYPE, gpu_dec ? MFVideoFormat_NV12 : MFVideoFormat_RGB32);
    if (FAILED(reader->SetCurrentMediaType((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, NULL, vdec.Get()))) {
      gpu_dec = false;
      reader.Reset();
      ComPtr<IMFAttributes> sattr;
      MFCreateAttributes(&sattr, 1);
      sattr->SetUINT32(MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, TRUE);
      if (FAILED(MFCreateSourceReaderFromURL(src.c_str(), sattr.Get(), &reader))) {
        InterlockedExchange(&R.exporting, 0);
        if (SUCCEEDED(co)) CoUninitialize();
        rec_post("export-error", total_ms, 0, 0, orig_bytes, 0, 0, "", dst, "解码源视频失败");
        return 0;
      }
      reader->SetStreamSelection((DWORD)MF_SOURCE_READER_ALL_STREAMS, FALSE);
      reader->SetStreamSelection((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, TRUE);
      vdec->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
      reader->SetCurrentMediaType((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, NULL, vdec.Get());
    }

    // Decode audio to 48 kHz stereo 16-bit PCM (exact ScreenReplay replay_export.cpp pattern: avoids raw AAC
    // passthrough stalls in IMFSinkWriter).
    bool has_src_audio = false;
    if (src_audio) {
      ComPtr<IMFMediaType> pcm_mt;
      MFCreateMediaType(&pcm_mt);
      pcm_mt->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
      pcm_mt->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
      pcm_mt->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
      pcm_mt->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, 48000);
      pcm_mt->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, 2);
      pcm_mt->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, 4);
      pcm_mt->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, 48000 * 4);
      if (SUCCEEDED(reader->SetStreamSelection((DWORD)MF_SOURCE_READER_FIRST_AUDIO_STREAM, TRUE)) &&
          SUCCEEDED(reader->SetCurrentMediaType((DWORD)MF_SOURCE_READER_FIRST_AUDIO_STREAM, NULL, pcm_mt.Get()))) {
        has_src_audio = true;
      } else {
        reader->SetStreamSelection((DWORD)MF_SOURCE_READER_FIRST_AUDIO_STREAM, FALSE);
      }
    }

    Mp4Encoder enc;
    // Quality tiers: 0=Original (high-bitrate transcode), 1=High, 2=Balanced, 3=Compact
    static const double kBppHevc[4] = {0.095, 0.068, 0.040, 0.020};
    static const double kBppH264[4] = {0.140, 0.100, 0.060, 0.032};
    static const double kLoHevc[4]  = {1200000.0, 800000.0, 450000.0, 250000.0};
    static const double kHiHevc[4]  = {22000000.0, 12000000.0, 5500000.0, 2200000.0};
    static const double kLoH264[4]  = {1500000.0, 1000000.0, 650000.0, 350000.0};
    static const double kHiH264[4]  = {30000000.0, 16000000.0, 7500000.0, 3200000.0};
    int qi = quality < 0 ? 2 : (quality > 3 ? 3 : quality);
    double r_hevc = (double)out_w * out_h * src_fps * kBppHevc[qi];
    double r_h264 = (double)out_w * out_h * src_fps * kBppH264[qi];
    enc.custom_bps_hevc = (UINT32)(r_hevc < kLoHevc[qi] ? kLoHevc[qi] : (r_hevc > kHiHevc[qi] ? kHiHevc[qi] : r_hevc));
    enc.custom_bps_h264 = (UINT32)(r_h264 < kLoH264[qi] ? kLoH264[qi] : (r_h264 > kHiH264[qi] ? kHiH264[qi] : r_h264));

    if (!enc.open(gpu_dec ? dev.Get() : NULL, gpu_dec ? mgr.Get() : NULL, dst, out_w, out_h, src_fps, has_src_audio,
                  NULL, want_hevc)) {
      reader.Reset();
      InterlockedExchange(&R.exporting, 0);
      if (SUCCEEDED(co)) CoUninitialize();
      rec_post("export-error", total_ms, 0, 0, orig_bytes, 0, 0, "", dst, "无法启动压缩编码");
      return 0;
    }

    int last_pct = -1;
    LONGLONG total_hns = total_ms * 10000LL;
    std::vector<uint8_t> scaled_rgb;
    ComPtr<ID3D11Texture2D> single_nv12;
    UINT single_w = 0, single_h = 0;

    bool video_done = false;
    bool audio_done = !(has_src_audio && enc.has_audio);

    while (!(video_done && audio_done) && InterlockedCompareExchange(&R.exp_cancel, 0, 0) == 0) {
      DWORD sidx = 0, flags = 0;
      LONGLONG ts = 0;
      ComPtr<IMFSample> sample;
      HRESULT hr = reader->ReadSample((DWORD)MF_SOURCE_READER_ANY_STREAM, 0, &sidx, &flags, &ts, &sample);
      if (FAILED(hr)) break;

      ComPtr<IMFMediaType> cur_mt;
      reader->GetCurrentMediaType(sidx, &cur_mt);
      GUID major = GUID_NULL;
      if (cur_mt) cur_mt->GetGUID(MF_MT_MAJOR_TYPE, &major);
      bool is_video = (major == MFMediaType_Video);

      if (flags & MF_SOURCE_READERF_ENDOFSTREAM) {
        if (is_video) video_done = true;
        else audio_done = true;
        continue;
      }
      if (!sample) continue;

      if (is_video) {
        LONGLONG dur = 10000000LL / src_fps;
        sample->GetSampleDuration(&dur);
        if (dur <= 0) dur = 10000000LL / src_fps;

        if (gpu_dec && enc.gpu_path) {
          ComPtr<IMFMediaBuffer> buf;
          ComPtr<IMFDXGIBuffer> dxgi_buf;
          ComPtr<ID3D11Texture2D> dtex;
          UINT sub = 0;
          if (SUCCEEDED(sample->GetBufferByIndex(0, &buf)) && SUCCEEDED(buf.As(&dxgi_buf)) &&
              SUCCEEDED(dxgi_buf->GetResource(IID_PPV_ARGS(&dtex)))) {
            dxgi_buf->GetSubresourceIndex(&sub);
            D3D11_TEXTURE2D_DESC sd = {};
            dtex->GetDesc(&sd);
            // Copy decoder array slice into a single-slice NV12 texture (exact ScreenReplay replay_export.cpp pattern).
            if (!single_nv12 || single_w != sd.Width || single_h != sd.Height) {
              single_nv12.Reset();
              D3D11_TEXTURE2D_DESC td = {};
              td.Width = sd.Width;
              td.Height = sd.Height;
              td.MipLevels = 1;
              td.ArraySize = 1;
              td.Format = DXGI_FORMAT_NV12;
              td.SampleDesc.Count = 1;
              td.Usage = D3D11_USAGE_DEFAULT;
              td.BindFlags = D3D11_BIND_DECODER;
              if (SUCCEEDED(dev->CreateTexture2D(&td, NULL, &single_nv12))) {
                single_w = sd.Width;
                single_h = sd.Height;
              }
            }
            if (single_nv12) {
              D3D11_BOX cbox = {0, 0, 0, sd.Width, sd.Height, 1};
              ctx->CopySubresourceRegion(single_nv12.Get(), 0, 0, 0, 0, dtex.Get(), sub, &cbox);
              enc.write_gpu_frame(dev.Get(), ctx.Get(), single_nv12.Get(), 0, true, 0, 0, src_w, src_h, ts, dur);
            }
          }
        } else {
          ComPtr<IMFMediaBuffer> buf;
          if (SUCCEEDED(sample->ConvertToContiguousBuffer(&buf))) {
            BYTE *p = NULL;
            DWORD len = 0;
            if (SUCCEEDED(buf->Lock(&p, NULL, &len)) && len >= (DWORD)((size_t)src_w * src_h * 4)) {
              if (out_w == src_w && out_h == src_h) {
                enc.write_cpu_frame(p, src_w * 4, true, ts, dur);
              } else {
                scaled_rgb.resize((size_t)out_w * out_h * 4);
                for (int y = 0; y < out_h; y++) {
                  int sy = y * src_h / out_h;
                  const uint8_t *sr = p + (size_t)sy * src_w * 4;
                  uint8_t *dr = scaled_rgb.data() + (size_t)y * out_w * 4;
                  for (int x = 0; x < out_w; x++) {
                    int sx = x * src_w / out_w;
                    memcpy(dr + (size_t)x * 4, sr + (size_t)sx * 4, 4);
                  }
                }
                enc.write_cpu_frame(scaled_rgb.data(), out_w * 4, true, ts, dur);
              }
              buf->Unlock();
            }
          }
        }

        int pct = total_hns > 0 ? (int)((ts * 98LL) / total_hns) : 50;
        if (pct > 98) pct = 98;
        if (pct < 0) pct = 0;
        if (pct - last_pct >= 5) {
          last_pct = pct;
          rec_post("exporting", total_ms, 0, 0, orig_bytes, pct, enc.has_audio ? 1 : 0, enc.codec_name.c_str(), dst, "");
        }
      } else if (enc.has_audio) {
        enc.write_audio_sample(sample.Get());
      }
    }
    single_nv12.Reset();

    bool cancelled = InterlockedCompareExchange(&R.exp_cancel, 0, 0) != 0;
    std::string cname = enc.codec_name;
    bool out_audio = enc.has_audio;
    uint64_t out_bytes = enc.finish(cancelled);
    reader.Reset();
    mgr.Reset();
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
    rec_trace_vram("exp_after_trim", NULL);
    InterlockedExchange(&R.exporting, 0);
    if (SUCCEEDED(co)) CoUninitialize();

    if (cancelled) return 0;
    if (out_bytes > 0) {
      copy_file_to_clipboard(dst);
      rec_post("exported", total_ms, 0, out_bytes, orig_bytes, 100, out_audio ? 1 : 0, cname.c_str(), dst, "");
    } else {
      rec_post("export-error", total_ms, 0, 0, orig_bytes, 0, 0, "", dst, "压缩编码失败");
    }
    return 0;
  }

  // GIF export (fmt == 2)
  int gif_w = src_w, gif_h = src_h;
  if (max_side > 0 && (gif_w > max_side || gif_h > max_side)) {
    double k = (double)max_side / (double)(gif_w > gif_h ? gif_w : gif_h);
    gif_w = std::max(16, ((int)(gif_w * k + 0.5)) & ~1);
    gif_h = std::max(16, ((int)(gif_h * k + 0.5)) & ~1);
  }

  ComPtr<IMFAttributes> rattr;
  MFCreateAttributes(&rattr, 1);
  rattr->SetUINT32(MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, TRUE);
  ComPtr<IMFSourceReader> reader;
  if (FAILED(MFCreateSourceReaderFromURL(src.c_str(), rattr.Get(), &reader))) {
    InterlockedExchange(&R.exporting, 0);
    if (SUCCEEDED(co)) CoUninitialize();
    rec_post("export-error", total_ms, 0, 0, orig_bytes, 0, 0, "GIF", dst, "读取源视频失败");
    return 0;
  }
  reader->SetStreamSelection((DWORD)MF_SOURCE_READER_ALL_STREAMS, FALSE);
  reader->SetStreamSelection((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, TRUE);
  ComPtr<IMFMediaType> rgb_mt;
  MFCreateMediaType(&rgb_mt);
  rgb_mt->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  rgb_mt->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
  if (FAILED(reader->SetCurrentMediaType((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, NULL, rgb_mt.Get()))) {
    reader.Reset();
    InterlockedExchange(&R.exporting, 0);
    if (SUCCEEDED(co)) CoUninitialize();
    rec_post("export-error", total_ms, 0, 0, orig_bytes, 0, 0, "GIF", dst, "解码源视频失败");
    return 0;
  }

  GifWriter gif;
  if (!gif.open(dst, gif_w, gif_h)) {
    reader.Reset();
    InterlockedExchange(&R.exporting, 0);
    if (SUCCEEDED(co)) CoUninitialize();
    rec_post("export-error", total_ms, 0, 0, orig_bytes, 0, 0, "GIF", dst, "无法创建 GIF 文件");
    return 0;
  }

  LONGLONG step_hns = 10000000LL / gif_fps;
  int step_cs = std::max(2, (100 + gif_fps / 2) / gif_fps);
  LONGLONG next_want = 0;
  LONGLONG total_hns = total_ms * 10000LL;
  int last_pct = -1;
  std::vector<uint8_t> rgb_frame((size_t)gif_w * gif_h * 3);

  while (InterlockedCompareExchange(&R.exp_cancel, 0, 0) == 0) {
    DWORD sidx = 0, flags = 0;
    LONGLONG ts = 0;
    ComPtr<IMFSample> sample;
    HRESULT hr = reader->ReadSample((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, &sidx, &flags, &ts, &sample);
    if (FAILED(hr) || (flags & MF_SOURCE_READERF_ENDOFSTREAM)) break;
    if (!sample || ts < next_want) continue;

    while (next_want <= ts) next_want += step_hns;

    ComPtr<IMFMediaBuffer> buf;
    if (SUCCEEDED(sample->ConvertToContiguousBuffer(&buf))) {
      BYTE *p = NULL;
      DWORD len = 0;
      if (SUCCEEDED(buf->Lock(&p, NULL, &len)) && len >= (DWORD)((size_t)src_w * src_h * 4)) {
        if (gif_w == src_w && gif_h == src_h) {
          for (int y = 0; y < gif_h; y++) {
            const uint8_t *s = p + (size_t)y * src_w * 4;
            uint8_t *d = rgb_frame.data() + (size_t)y * gif_w * 3;
            for (int x = 0; x < gif_w; x++) {
              d[x * 3 + 0] = s[x * 4 + 2];
              d[x * 3 + 1] = s[x * 4 + 1];
              d[x * 3 + 2] = s[x * 4 + 0];
            }
          }
        } else {
          for (int y = 0; y < gif_h; y++) {
            int y0 = y * src_h / gif_h, y1 = std::max(y0 + 1, (y + 1) * src_h / gif_h);
            if (y1 > src_h) y1 = src_h;
            uint8_t *d = rgb_frame.data() + (size_t)y * gif_w * 3;
            for (int x = 0; x < gif_w; x++) {
              int x0 = x * src_w / gif_w, x1 = std::max(x0 + 1, (x + 1) * src_w / gif_w);
              if (x1 > src_w) x1 = src_w;
              uint32_t sr = 0, sg = 0, sb = 0, cnt = 0;
              for (int yy = y0; yy < y1; yy++) {
                const uint8_t *s = p + (size_t)yy * src_w * 4;
                for (int xx = x0; xx < x1; xx++) {
                  sr += s[xx * 4 + 2];
                  sg += s[xx * 4 + 1];
                  sb += s[xx * 4 + 0];
                  cnt++;
                }
              }
              d[x * 3 + 0] = (uint8_t)(sr / cnt);
              d[x * 3 + 1] = (uint8_t)(sg / cnt);
              d[x * 3 + 2] = (uint8_t)(sb / cnt);
            }
          }
        }
        gif.add_frame(rgb_frame.data(), step_cs);
        buf->Unlock();
      }
    }

    int pct = total_hns > 0 ? (int)((ts * 98LL) / total_hns) : 50;
    if (pct > 98) pct = 98;
    if (pct < 0) pct = 0;
    if (pct - last_pct >= 5) {
      last_pct = pct;
      rec_post("exporting", total_ms, 0, 0, orig_bytes, pct, 0, "GIF", dst, "");
    }
  }

  bool cancelled = InterlockedCompareExchange(&R.exp_cancel, 0, 0) != 0;
  uint64_t out_bytes = 0;
  if (cancelled) {
    gif.abort();
    DeleteFileW(dst.c_str());
  } else {
    out_bytes = gif.finish();
  }
  reader.Reset();
  InterlockedExchange(&R.exporting, 0);
  if (SUCCEEDED(co)) CoUninitialize();

  if (cancelled) return 0;
  if (out_bytes > 0) {
    copy_file_to_clipboard(dst);
    rec_post("exported", total_ms, 0, out_bytes, orig_bytes, 100, 0, "GIF", dst, "");
  } else {
    rec_post("export-error", total_ms, 0, 0, orig_bytes, 0, 0, "GIF", dst, "生成 GIF 失败");
  }
  return 0;
}

// ---- MoonBit FFI exports ----

extern "C" {

int32_t ps_rec_prepare(int32_t x, int32_t y, int32_t w, int32_t h) {
  if (InterlockedCompareExchange(&R.running, 0, 0) != 0 || InterlockedCompareExchange(&R.exporting, 0, 0) != 0) return 0;
  rec_frame_hide();
  rec_draw_close();
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
  rec_draw_open(x, y, w, h);
  return 1;
}

moonbit_bytes_t ps_rec_rect(void) {
  if (!R.prepared) return moonbit_make_bytes(0, 0);
  char s[64];
  int n = snprintf(s, sizeof s, "%d,%d,%d,%d", R.x, R.y, R.w, R.h);
  return rec_bytes_of(s, (size_t)n);
}

int32_t ps_rec_start(int32_t fps, int32_t cursor, int32_t audio) {
  if (!R.prepared || InterlockedCompareExchange(&R.running, 0, 0) != 0) return 0;
  if (R.rec_thread) {
    WaitForSingleObject(R.rec_thread, 3000);
    CloseHandle(R.rec_thread);
    R.rec_thread = NULL;
  }
  R.fps = fps < 10 ? 10 : (fps > 60 ? 60 : fps);
  R.cursor = cursor ? 1 : 0;
  R.want_audio = audio ? 1 : 0;
  InterlockedExchange(&R.stop_req, 0);
  InterlockedExchange(&R.pause_req, 0);
  if (!R.wake_ev) R.wake_ev = CreateEventW(NULL, FALSE, FALSE, NULL);
  ResetEvent(R.wake_ev);
  InterlockedExchange(&R.running, 1);
  rec_frame_show(RGB(0xEF, 0x44, 0x44));
  rec_draw_set_recording(1);
  R.rec_thread = CreateThread(NULL, 0, rec_worker, NULL, 0, NULL);
  if (!R.rec_thread) {
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
  rec_draw_set_recording(p ? 0 : 1);
  rec_frame_show(p ? RGB(0xF5, 0xA5, 0x24) : RGB(0xEF, 0x44, 0x44));
}

void ps_rec_stop(int32_t cancel) {
  rec_frame_hide();
  rec_draw_close();
  if (InterlockedCompareExchange(&R.running, 0, 0) == 0) return;
  InterlockedExchange(&R.stop_req, cancel ? 2 : 1);
  if (R.wake_ev) SetEvent(R.wake_ev);
}

int32_t ps_rec_export(moonbit_bytes_t dest_path, int32_t fmt, int32_t quality, int32_t max_side, int32_t gif_fps) {
  if (R.master_path.empty() || InterlockedCompareExchange(&R.exporting, 0, 0) != 0) return 0;
  if (R.exp_thread) {
    WaitForSingleObject(R.exp_thread, 3000);
    CloseHandle(R.exp_thread);
    R.exp_thread = NULL;
  }
  int len = (int)Moonbit_array_length(dest_path);
  R.exp_dest = utf8_to_wide((const char *)dest_path, len);
  if (R.exp_dest.empty()) return 0;
  R.exp_fmt = fmt;
  R.exp_quality = quality;
  R.exp_max_side = max_side;
  R.exp_gif_fps = gif_fps;
  InterlockedExchange(&R.exp_cancel, 0);
  InterlockedExchange(&R.exporting, 1);
  R.exp_thread = CreateThread(NULL, 0, export_worker, NULL, 0, NULL);
  if (!R.exp_thread) {
    InterlockedExchange(&R.exporting, 0);
    return 0;
  }
  return 1;
}

void ps_rec_end(void) {
  rec_frame_hide();
  rec_draw_close();
  if (InterlockedCompareExchange(&R.running, 0, 0) != 0) {
    InterlockedExchange(&R.stop_req, 2);
    if (R.wake_ev) SetEvent(R.wake_ev);
  }
  if (R.rec_thread) {
    WaitForSingleObject(R.rec_thread, 5000);
    CloseHandle(R.rec_thread);
    R.rec_thread = NULL;
  }
  if (InterlockedCompareExchange(&R.exporting, 0, 0) != 0) {
    InterlockedExchange(&R.exp_cancel, 1);
  }
  if (R.exp_thread) {
    WaitForSingleObject(R.exp_thread, 5000);
    CloseHandle(R.exp_thread);
    R.exp_thread = NULL;
  }
  if (R.wake_ev) {
    CloseHandle(R.wake_ev);
    R.wake_ev = NULL;
  }
  if (!R.master_path.empty()) {
    DeleteFileW(R.master_path.c_str());
    R.master_path.clear();
  }
  R.master_bytes = 0;
  R.prepared = 0;
}

void ps_rec_exclude(int32_t wid) {
  HWND h = (HWND)mb_app_hwnd_of(wid);
  if (!h) return;
  DWM_WINDOW_CORNER_PREFERENCE corner = DWMWCP_ROUND;
  DwmSetWindowAttribute(h, DWMWA_WINDOW_CORNER_PREFERENCE, &corner, sizeof corner);
  rec_exclude_hwnd(h);
}

}  // extern "C"
