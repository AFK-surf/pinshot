// Lightweight area screen recorder & post-recording transcoder (Windows):
// 1. Live recording into a temp master MP4 via dedicated WGC session (with optional cursor & HDR FP16 -> sRGB GPU
//    conversion) + optional WASAPI Loopback system audio (48 kHz stereo AAC):
//      - Tier 1: Hardware HEVC (H.265) + D3D11 VideoProcessor GPU NV12 (patches 'hev1' -> 'hvc1')
//      - Tier 2: Hardware H.264 + D3D11 VideoProcessor GPU NV12
//      - Tier 3: Software H.264 + CPU BT.709 NV12
// 2. Optional click ripples and keys pressed (record_draw_win.cpp), a layered window captured natively by WGC.
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
#include <icodecapi.h>
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
#include <memory>

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

// Windows 11 24H2+ IGraphicsCaptureSession5 (SDK 10.0.26100+): default MinUpdateInterval is 16ms (~60Hz),
// which silently throttles WGC monitor capture to 60fps on 120/240Hz displays unless explicitly lowered.
MIDL_INTERFACE("67c0ea62-1f85-5061-925a-239be0ac09cb")
IPsGraphicsCaptureSession5 : public IInspectable {
public:
  virtual HRESULT STDMETHODCALLTYPE get_MinUpdateInterval(ABI::Windows::Foundation::TimeSpan *value) = 0;
  virtual HRESULT STDMETHODCALLTYPE put_MinUpdateInterval(ABI::Windows::Foundation::TimeSpan value) = 0;
};

extern "C" void mb_post(const char *channel, const char *json, size_t len, const uint8_t *bytes, size_t blen);
extern "C" void *mb_app_hwnd_of(int wid);
extern "C" int32_t ps_reduce_motion(void);
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

extern "C" void ps_update_region_frame(HWND hwnd, int rx, int ry, int rw, int rh, COLORREF color, int dashed, int handles);

static struct {
  int prepared;
  int x, y, w, h;          // clamped even region in virtual screen pixels
  HMONITOR mon;
  int mx, my, mw, mh;      // monitor bounds
  HWND frame;
  HWND veil;               // hardware DWM LWA_ALPHA outer scrim (0x72 -> 0 over 220ms on screenshot->record handoff)
  ULONGLONG veil_fade_ms;  // 0 while parked behind overlay waiting for handoff; >0 once fading out
  COLORREF frame_color;
  int frame_dashed;
  int frame_interactive;   // 1 in Ready phase (resizable border/corners), 0 once recording starts (100% click-through)
  int drag_hx, drag_hy;
  int drag_sx, drag_sy;
  int drag_rx, drag_ry, drag_rw, drag_rh;

  HANDLE rec_thread;
  HANDLE exp_thread;
  HANDLE wake_ev;          // made once, never closed: a worker of a session ended may still wait on it
  SRWLOCK lock;            // the master_* and preview_bmp below, written by the recording's worker as it ends
  LONG session;            // which recording panel this is: ps_rec_end begins another (a worker of the last keeps nothing)
  volatile LONG stop_req;  // 0 running, 1 finish, 2 cancel
  volatile LONG pause_req; // 0 running, 1 paused
  volatile LONG running;
  volatile LONG exporting;
  volatile LONG exp_gen;   // each export's number: one called off (or the panel ended) takes the next

  int fps;
  int cursor;
  int want_audio;

  // Master temp recording state (kept after Stop until panel closes so user can export MP4/Compressed/GIF).
  std::wstring master_path;
  uint64_t master_bytes;
  int64_t master_ms;
  int master_w, master_h, master_fps, master_audio;
  std::string master_codec;
  std::vector<uint8_t> preview_bmp;

  // Export job params
  std::wstring exp_dest;
  int exp_fmt;       // 0=MP4 H.265, 1=MP4 H.264, 2=GIF, 3=MP4 AV1
  int exp_quality;   // 0=Original, 1=High, 2=Balanced, 3=Compact
  int exp_max_side;  // 0=100% Original, 1..99=percent scale (75/50), >100=max long edge
  int exp_gif_fps;   // 10 / 15 / 20
} R;

static const GUID PS_MFVideoFormat_AV1 = {
    0x31305641, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}};

// Build a 2x cover-cropped 32-bit BGRX BMP (352x368 for the 176x184pt Studio HUD preview card)
// with a silky bottom dark vignette scrim composited directly into the pixels so white overlay metadata
// stays razor-sharp over any bright light-mode desktop capture.
static void build_preview_bmp(const uint8_t *px, int w, int h, int pitch, bool is_bgra, std::vector<uint8_t> &out) {
  out.clear();
  if (!px || w <= 0 || h <= 0 || pitch < w * 4) return;
  const int pw = 352, ph = 368;
  double src_asp = (double)w / (double)h;
  double dst_asp = (double)pw / (double)ph;
  int cx0 = 0, cy0 = 0, cw = w, ch = h;
  if (src_asp > dst_asp) {
    cw = std::max(1, std::min(w, (int)(h * dst_asp + 0.5)));
    cx0 = (w - cw) / 2;
  } else {
    ch = std::max(1, std::min(h, (int)(w / dst_asp + 0.5)));
    cy0 = (h - ch) / 2;
  }
  size_t pix_bytes = (size_t)pw * (size_t)ph * 4;
  out.resize(54 + pix_bytes, 0);
  uint8_t *hdr = out.data();
  uint32_t fsz = (uint32_t)out.size();
  uint32_t off = 54, hsize = 40;
  int32_t bw = pw, bh = -ph;
  uint16_t planes = 1, bits = 32;
  hdr[0] = 'B';
  hdr[1] = 'M';
  memcpy(hdr + 2, &fsz, 4);
  memcpy(hdr + 10, &off, 4);
  memcpy(hdr + 14, &hsize, 4);
  memcpy(hdr + 18, &bw, 4);
  memcpy(hdr + 22, &bh, 4);
  memcpy(hdr + 26, &planes, 2);
  memcpy(hdr + 28, &bits, 2);
  uint8_t *dst = hdr + 54;
  int bo = is_bgra ? 0 : 2, go = 1, ro = is_bgra ? 2 : 0;
  for (int y = 0; y < ph; y++) {
    double t = (double)y / (double)(ph - 1);
    double scrim = 0.0;
    if (t < 0.22) {
      scrim = 0.06 * (1.0 - t / 0.22);
    } else if (t > 0.42) {
      double u = (t - 0.42) / 0.58;
      scrim = 0.88 * u * u * (1.45 - 0.45 * u);
    }
    double keep = 1.0 - scrim;
    double add_b = 17.0 * scrim, add_g = 13.0 * scrim, add_r = 12.0 * scrim;
    int y0 = cy0 + y * ch / ph;
    int y1 = cy0 + (y + 1) * ch / ph;
    if (y1 <= y0) y1 = y0 + 1;
    if (y1 > h) y1 = h;
    uint8_t *d = dst + (size_t)y * (size_t)pw * 4;
    for (int x = 0; x < pw; x++) {
      int x0 = cx0 + x * cw / pw;
      int x1 = cx0 + (x + 1) * cw / pw;
      if (x1 <= x0) x1 = x0 + 1;
      if (x1 > w) x1 = w;
      uint32_t sb = 0, sg = 0, sr = 0, cnt = 0;
      for (int yy = y0; yy < y1; yy++) {
        const uint8_t *s = px + (size_t)yy * (size_t)pitch;
        for (int xx = x0; xx < x1; xx++) {
          sb += s[xx * 4 + bo];
          sg += s[xx * 4 + go];
          sr += s[xx * 4 + ro];
          cnt++;
        }
      }
      double b = (double)sb / (double)cnt;
      double g = (double)sg / (double)cnt;
      double r = (double)sr / (double)cnt;
      d[x * 4 + 0] = (uint8_t)(b * keep + add_b + 0.5);
      d[x * 4 + 1] = (uint8_t)(g * keep + add_g + 0.5);
      d[x * 4 + 2] = (uint8_t)(r * keep + add_r + 0.5);
      d[x * 4 + 3] = 255;
    }
  }
}

static void compute_scaled_dims(int src_w, int src_h, int scale_param, int &out_w, int &out_h) {
  out_w = src_w;
  out_h = src_h;
  if (scale_param > 0 && scale_param < 100) {
    double k = (double)scale_param / 100.0;
    out_w = std::max(16, std::min(src_w, ((int)(src_w * k + 0.5)) & ~1));
    out_h = std::max(16, std::min(src_h, ((int)(src_h * k + 0.5)) & ~1));
  } else if (scale_param > 100 && (src_w > scale_param || src_h > scale_param)) {
    double k = (double)scale_param / (double)(src_w > src_h ? src_w : src_h);
    out_w = std::max(16, ((int)(src_w * k + 0.5)) & ~1);
    out_h = std::max(16, ((int)(src_h * k + 0.5)) & ~1);
  }
}

static void rec_exclude_hwnd(HWND h) {
  if (!getenv("PINSHOT_REC_SHOW")) SetWindowDisplayAffinity(h, WDA_EXCLUDEFROMCAPTURE);
}

static int rec_frame_hit(HWND h, int sx, int sy, int *out_hx, int *out_hy) {
  UINT dpi = GetDpiForWindow(h);
  if (dpi < 96) dpi = 96;
  int reach = (int)roundf(10.0f * (float)dpi / 96.0f);
  int corner = (int)roundf(18.0f * (float)dpi / 96.0f);
  if (reach < 8) reach = 8;
  if (corner < 16) corner = 16;
  int x0 = R.x, y0 = R.y, x1 = R.x + R.w, y1 = R.y + R.h;
  if (sx < x0 - reach || sx > x1 + reach || sy < y0 - reach || sy > y1 + reach) return 0;
  if (sx > x0 + reach && sx < x1 - reach && sy > y0 + reach && sy < y1 - reach) return 0;
  int hx = 0, hy = 0;
  if (abs(sx - x0) <= reach) hx = -1;
  else if (abs(sx - x1) <= reach) hx = 1;
  if (abs(sy - y0) <= reach) hy = -1;
  else if (abs(sy - y1) <= reach) hy = 1;
  if (hx != 0 && hy == 0) {
    if (sy <= y0 + corner) hy = -1;
    else if (sy >= y1 - corner) hy = 1;
  } else if (hy != 0 && hx == 0) {
    if (sx <= x0 + corner) hx = -1;
    else if (sx >= x1 - corner) hx = 1;
  }
  if (hx == 0 && hy == 0) return 0;
  *out_hx = hx;
  *out_hy = hy;
  return 1;
}

static LPCTSTR rec_frame_cursor_for(int hx, int hy) {
  if (hx == 0 && hy != 0) return IDC_SIZENS;
  if (hy == 0 && hx != 0) return IDC_SIZEWE;
  if ((hx < 0 && hy < 0) || (hx > 0 && hy > 0)) return IDC_SIZENWSE;
  return IDC_SIZENESW;
}

static void rec_post_rect(void) {
  char buf[96];
  int n = snprintf(buf, sizeof buf, "{\"do\":\"rec-rect\",\"x\":%d,\"y\":%d,\"w\":%d,\"h\":%d}", R.x, R.y, R.w, R.h);
  if (n > 0) mb_post("ps", buf, (size_t)n, NULL, 0);
}

static void rec_veil_update_hole(HWND h);

static LRESULT CALLBACK rec_frame_proc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
  if (msg == WM_NCHITTEST) {
    if (!R.frame_interactive) return HTTRANSPARENT;
    int sx = (int)(short)LOWORD(lp), sy = (int)(short)HIWORD(lp);
    int hx = 0, hy = 0;
    return rec_frame_hit(h, sx, sy, &hx, &hy) ? HTCLIENT : HTTRANSPARENT;
  }
  if (msg == WM_SETCURSOR && R.frame_interactive && LOWORD(lp) == HTCLIENT) {
    int hx = R.drag_hx, hy = R.drag_hy;
    if (hx == 0 && hy == 0) {
      POINT pt;
      if (GetCursorPos(&pt)) rec_frame_hit(h, pt.x, pt.y, &hx, &hy);
    }
    if (hx != 0 || hy != 0) {
      SetCursor(LoadCursor(NULL, rec_frame_cursor_for(hx, hy)));
      return TRUE;
    }
  }
  if (msg == WM_LBUTTONDOWN && R.frame_interactive) {
    POINT pt;
    if (GetCursorPos(&pt)) {
      int hx = 0, hy = 0;
      if (rec_frame_hit(h, pt.x, pt.y, &hx, &hy)) {
        R.drag_hx = hx;
        R.drag_hy = hy;
        R.drag_sx = pt.x;
        R.drag_sy = pt.y;
        R.drag_rx = R.x;
        R.drag_ry = R.y;
        R.drag_rw = R.w;
        R.drag_rh = R.h;
        SetCapture(h);
        SetCursor(LoadCursor(NULL, rec_frame_cursor_for(hx, hy)));
        return 0;
      }
    }
  }
  if (msg == WM_MOUSEMOVE && (R.drag_hx != 0 || R.drag_hy != 0)) {
    POINT pt;
    if (GetCursorPos(&pt)) {
      int dx = pt.x - R.drag_sx;
      int dy = pt.y - R.drag_sy;
      int min_sz = 64;
      int ml = R.mx, mt = R.my, mr = R.mx + R.mw, mb = R.my + R.mh;
      int x0 = R.drag_rx, y0 = R.drag_ry;
      int x1 = R.drag_rx + R.drag_rw, y1 = R.drag_ry + R.drag_rh;
      if (R.drag_hx < 0) {
        x0 = std::max(ml, std::min(x1 - min_sz, x0 + dx));
      } else if (R.drag_hx > 0) {
        x1 = std::min(mr, std::max(x0 + min_sz, x1 + dx));
      }
      if (R.drag_hy < 0) {
        y0 = std::max(mt, std::min(y1 - min_sz, y0 + dy));
      } else if (R.drag_hy > 0) {
        y1 = std::min(mb, std::max(y0 + min_sz, y1 + dy));
      }
      int nw = (x1 - x0) & ~1;
      int nh = (y1 - y0) & ~1;
      if (nw < min_sz) nw = min_sz;
      if (nh < min_sz) nh = min_sz;
      int nx = R.drag_hx < 0 ? (x1 - nw) : x0;
      int ny = R.drag_hy < 0 ? (y1 - nh) : y0;
      if (nx < ml) nx = ml;
      if (ny < mt) ny = mt;
      if (nx + nw > mr) nw = (mr - nx) & ~1;
      if (ny + nh > mb) nh = (mb - ny) & ~1;
      if (nw >= min_sz && nh >= min_sz && (nx != R.x || ny != R.y || nw != R.w || nh != R.h)) {
        R.x = nx;
        R.y = ny;
        R.w = nw;
        R.h = nh;
        ps_update_region_frame(h, R.x, R.y, R.w, R.h, R.frame_color, 0, 1);
        if (R.veil) rec_veil_update_hole(R.veil);
        rec_post_rect();
      }
    }
    return 0;
  }
  if ((msg == WM_LBUTTONUP || msg == WM_CAPTURECHANGED) && (R.drag_hx != 0 || R.drag_hy != 0)) {
    R.drag_hx = 0;
    R.drag_hy = 0;
    if (msg == WM_LBUTTONUP && GetCapture() == h) ReleaseCapture();
    rec_draw_open(R.x, R.y, R.w, R.h);
    rec_post_rect();
    return 0;
  }
  return DefWindowProcW(h, msg, wp, lp);
}

static void rec_frame_show(COLORREF color, int dashed, int interactive) {
  const char *cl = getenv("PINSHOT_TEST_CLOAKED");
  if (cl && cl[0]) return;
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
  R.frame_dashed = dashed;
  R.frame_interactive = interactive ? 1 : 0;
  if (!interactive) {
    R.drag_hx = 0;
    R.drag_hy = 0;
  }
  DWORD ex = WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | (interactive ? 0 : WS_EX_TRANSPARENT);
  if (!R.frame) {
    R.frame = CreateWindowExW(ex, L"PinShot.RecFrame", L"", WS_POPUP, R.x, R.y, 16, 16, NULL, NULL, GetModuleHandleW(NULL), NULL);
    if (!R.frame) return;
    rec_exclude_hwnd(R.frame);
  } else {
    DWORD cur = (DWORD)GetWindowLongW(R.frame, GWL_EXSTYLE);
    if (((cur & WS_EX_TRANSPARENT) != 0) != (!interactive)) {
      SetWindowLongW(R.frame, GWL_EXSTYLE, (LONG)ex);
      SetWindowPos(R.frame, NULL, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
    }
  }
  ps_update_region_frame(R.frame, R.x, R.y, R.w, R.h, color, dashed, interactive);
  ShowWindow(R.frame, SW_SHOWNOACTIVATE);
}

static void rec_frame_hide(void) {
  if (R.frame) {
    DestroyWindow(R.frame);
    R.frame = NULL;
  }
}

// ---- hardware-composited DWM outer scrim fade-out (screenshot -> recording handoff) ----
// A single solid-black WS_EX_LAYERED | WS_EX_TRANSPARENT window with a SetWindowRgn cutout for the selected region.
// Parked directly behind the screenshot overlay at alpha 0x72 (exact match to overlay.pion's 0x00000072L scrim) so
// when the overlay cloaks on Frame 1 there is zero 1-frame flash or double-dimming, then dissolved via LWA_ALPHA
// (pure DWM scalar opacity blend: zero pixel upload, zero rasterization, WDA_EXCLUDEFROMCAPTURE) over 220ms and
// immediately destroyed so zero resources remain while Ready/Recording.
static const UINT_PTR REC_VEIL_TIMER_ID = 0x5256;
static const UINT_PTR REC_VEIL_GUARD_TIMER_ID = 0x5257;
static const BYTE REC_VEIL_ALPHA = 0x72;
static const DWORD REC_VEIL_FADE_MS = 220;

static void rec_veil_update_hole(HWND h) {
  if (!h || R.mw <= 0 || R.mh <= 0) return;
  HRGN outer = CreateRectRgn(0, 0, R.mw, R.mh);
  if (!outer) return;
  int hx0 = std::max(0, R.x - R.mx);
  int hy0 = std::max(0, R.y - R.my);
  int hx1 = std::min(R.mw, hx0 + R.w);
  int hy1 = std::min(R.mh, hy0 + R.h);
  if (hx1 > hx0 && hy1 > hy0) {
    HRGN hole = CreateRectRgn(hx0, hy0, hx1, hy1);
    if (hole) {
      CombineRgn(outer, outer, hole, RGN_DIFF);
      DeleteObject(hole);
    }
  }
  if (!SetWindowRgn(h, outer, FALSE)) DeleteObject(outer);
}

static void rec_veil_hide(void) {
  R.veil_fade_ms = 0;
  if (R.veil) {
    KillTimer(R.veil, REC_VEIL_TIMER_ID);
    KillTimer(R.veil, REC_VEIL_GUARD_TIMER_ID);
    DestroyWindow(R.veil);
    R.veil = NULL;
  }
}

static void rec_veil_start_fade(void) {
  if (!R.veil || R.veil_fade_ms != 0) return;
  KillTimer(R.veil, REC_VEIL_GUARD_TIMER_ID);
  R.veil_fade_ms = GetTickCount64();
  if (R.veil_fade_ms == 0) R.veil_fade_ms = 1;
  SetTimer(R.veil, REC_VEIL_TIMER_ID, 8, NULL);
}

static LRESULT CALLBACK rec_veil_proc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
  switch (msg) {
    case WM_ERASEBKGND: {
      RECT rc;
      GetClientRect(h, &rc);
      FillRect((HDC)wp, &rc, (HBRUSH)GetStockObject(BLACK_BRUSH));
      return 1;
    }
    case WM_PAINT: {
      PAINTSTRUCT ps;
      HDC dc = BeginPaint(h, &ps);
      FillRect(dc, &ps.rcPaint, (HBRUSH)GetStockObject(BLACK_BRUSH));
      EndPaint(h, &ps);
      return 0;
    }
    case WM_TIMER:
      if (wp == REC_VEIL_GUARD_TIMER_ID) {
        rec_veil_start_fade();
        return 0;
      }
      if (wp == REC_VEIL_TIMER_ID) {
        if (R.veil_fade_ms == 0) {
          KillTimer(h, REC_VEIL_TIMER_ID);
          return 0;
        }
        ULONGLONG now = GetTickCount64();
        ULONGLONG elapsed = (now >= R.veil_fade_ms) ? (now - R.veil_fade_ms) : 0;
        if (elapsed >= REC_VEIL_FADE_MS) {
          rec_veil_hide();
          return 0;
        }
        float t = (float)elapsed / (float)REC_VEIL_FADE_MS;
        float inv = 1.0f - t;
        // Quadratic ease-out keeps sRGB perceived brightness dropping smoothly across the full 220ms handoff.
        BYTE alpha = (BYTE)roundf((float)REC_VEIL_ALPHA * inv * inv);
        if (alpha == 0) {
          rec_veil_hide();
          return 0;
        }
        SetLayeredWindowAttributes(h, 0, alpha, LWA_ALPHA);
        return 0;
      }
      break;
    case WM_MOUSEACTIVATE: return MA_NOACTIVATE;
    case WM_NCHITTEST: return HTTRANSPARENT;
  }
  return DefWindowProcW(h, msg, wp, lp);
}

static void rec_veil_prepare(void) {
  rec_veil_hide();
  const char *cl = getenv("PINSHOT_TEST_CLOAKED");
  if ((cl && cl[0]) || ps_reduce_motion()) return;
  if (R.mw <= 0 || R.mh <= 0) return;
  // Whole monitor selected -> no outer veil exists around the selection.
  if (R.x <= R.mx && R.y <= R.my && R.x + R.w >= R.mx + R.mw && R.y + R.h >= R.my + R.mh) return;
  static int registered = 0;
  if (!registered) {
    WNDCLASSEXW wc = {};
    wc.cbSize = sizeof wc;
    wc.lpfnWndProc = rec_veil_proc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = L"PinShot.RecVeil";
    wc.hbrBackground = (HBRUSH)GetStockObject(BLACK_BRUSH);
    RegisterClassExW(&wc);
    registered = 1;
  }
  DWORD ex = WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE;
  R.veil = CreateWindowExW(ex, L"PinShot.RecVeil", L"", WS_POPUP, R.mx, R.my, R.mw, R.mh, NULL, NULL,
                           GetModuleHandleW(NULL), NULL);
  if (!R.veil) return;
  DWM_WINDOW_CORNER_PREFERENCE corner = DWMWCP_DONOTROUND;
  DwmSetWindowAttribute(R.veil, DWMWA_WINDOW_CORNER_PREFERENCE, &corner, sizeof corner);
  COLORREF no_border = 0xFFFFFFFEu;
  DwmSetWindowAttribute(R.veil, 34 /* DWMWA_BORDER_COLOR */, &no_border, sizeof no_border);
  DWMNCRENDERINGPOLICY ncrp = DWMNCRP_DISABLED;
  DwmSetWindowAttribute(R.veil, DWMWA_NCRENDERING_POLICY, &ncrp, sizeof ncrp);
  rec_exclude_hwnd(R.veil);
  rec_veil_update_hole(R.veil);
  SetLayeredWindowAttributes(R.veil, 0, REC_VEIL_ALPHA, LWA_ALPHA);
  HWND ov = (HWND)mb_app_hwnd_of(0);
  HWND after = (ov && IsWindowVisible(ov)) ? ov : HWND_TOPMOST;
  SetWindowPos(R.veil, after, R.mx, R.my, R.mw, R.mh, SWP_NOACTIVATE | SWP_SHOWWINDOW);
  UpdateWindow(R.veil);
  // Safety watchdog: never allow the veil to stay parked if handoff is interrupted.
  SetTimer(R.veil, REC_VEIL_GUARD_TIMER_ID, 600, NULL);
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
  uint64_t start;
  uint64_t payload;
  uint64_t end;
  uint32_t type;
};

// The box at `off` of the file (its header read, nothing else), within `limit`.
static bool read_mp4_box(HANDLE hf, uint64_t off, uint64_t limit, Mp4Box &out) {
  if (off + 8 > limit) return false;
  LARGE_INTEGER li;
  li.QuadPart = (LONGLONG)off;
  uint8_t hdr[16] = {};
  DWORD got = 0;
  if (!SetFilePointerEx(hf, li, NULL, FILE_BEGIN) ||
      !ReadFile(hf, hdr, (DWORD)std::min<uint64_t>(16, limit - off), &got, NULL) || got < 8)
    return false;
  uint64_t sz = read_be32(hdr);
  uint32_t ty = read_be32(hdr + 4);
  uint64_t head = 8;
  if (sz == 1) {
    if (got < 16) return false;
    sz = read_be64(hdr + 8);
    head = 16;
  } else if (sz == 0) {
    sz = limit - off;
  }
  if (sz < head || off + sz > limit) return false;
  out.start = off;
  out.payload = off + head;
  out.end = off + sz;
  out.type = ty;
  return true;
}

static bool find_mp4_child(HANDLE hf, uint64_t from, uint64_t limit, uint32_t type, Mp4Box &out) {
  Mp4Box b;
  for (uint64_t off = from; read_mp4_box(hf, off, limit, b); off = b.end) {
    if (b.type == type) {
      out = b;
      return true;
    }
  }
  return false;
}

// Each HEVC track's sample entry 'hev1' renamed 'hvc1' in place (what QuickTime and browsers play): the boxes walked
// by their headers alone and the four bytes written where they are, never the movie box read or written whole.
static void patch_mp4_hev1_to_hvc1(const std::wstring &path) {
  HANDLE hf = CreateFileW(path.c_str(), GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ, NULL, OPEN_EXISTING,
                          FILE_ATTRIBUTE_NORMAL, NULL);
  if (hf == INVALID_HANDLE_VALUE) return;
  LARGE_INTEGER fsz = {};
  Mp4Box moov;
  if (GetFileSizeEx(hf, &fsz) && fsz.QuadPart >= 16 &&
      find_mp4_child(hf, 0, (uint64_t)fsz.QuadPart, fourcc('m', 'o', 'o', 'v'), moov)) {
    Mp4Box trak;
    for (uint64_t off = moov.payload; read_mp4_box(hf, off, moov.end, trak); off = trak.end) {
      if (trak.type != fourcc('t', 'r', 'a', 'k')) continue;
      Mp4Box mdia, minf, stbl, stsd, entry;
      if (!find_mp4_child(hf, trak.payload, trak.end, fourcc('m', 'd', 'i', 'a'), mdia)) continue;
      if (!find_mp4_child(hf, mdia.payload, mdia.end, fourcc('m', 'i', 'n', 'f'), minf)) continue;
      if (!find_mp4_child(hf, minf.payload, minf.end, fourcc('s', 't', 'b', 'l'), stbl)) continue;
      if (!find_mp4_child(hf, stbl.payload, stbl.end, fourcc('s', 't', 's', 'd'), stsd)) continue;
      if (stsd.payload + 8 >= stsd.end) continue;
      if (!read_mp4_box(hf, stsd.payload + 8, stsd.end, entry)) continue;
      if (entry.type == fourcc('h', 'e', 'v', '1')) {
        LARGE_INTEGER at;
        at.QuadPart = (LONGLONG)(entry.start + 4);
        DWORD put = 0;
        if (SetFilePointerEx(hf, at, NULL, FILE_BEGIN)) WriteFile(hf, "hvc1", 4, &put, NULL);
      }
    }
  }
  CloseHandle(hf);
}

// NVIDIA's AV1 hardware MFT declares max_frame_width/height = 1920x1088 in its Sequence Header OBUs regardless of the
// actual frame size (coding each frame at its own size), and MF SinkWriter copies 1920x1088 into the MP4 'av01' sample
// entry while writing the real size into 'tkhd'. Players then compute a bogus non-square SAR (squishing/stretching the
// clip) or fail to decode/thumbnail it. Patch the 'av01' sample entry width/height and every Sequence Header OBU (in
// 'av1C' and each keyframe in 'mdat') in place to the real frame size without changing any bit lengths.
static bool mp4_read_at(HANDLE hf, uint64_t at, void *dst, DWORD n) {
  LARGE_INTEGER li;
  li.QuadPart = (LONGLONG)at;
  DWORD got = 0;
  return SetFilePointerEx(hf, li, NULL, FILE_BEGIN) && ReadFile(hf, dst, n, &got, NULL) && got == n;
}

static void mp4_write_at(HANDLE hf, uint64_t at, const void *src, DWORD n) {
  LARGE_INTEGER li;
  li.QuadPart = (LONGLONG)at;
  DWORD put = 0;
  if (SetFilePointerEx(hf, li, NULL, FILE_BEGIN)) WriteFile(hf, src, n, &put, NULL);
}

static bool patch_av1_seq_hdr_obu(uint8_t *b, size_t n, int w, int h) {
  size_t at = 0;
  auto f = [&](int bits) -> uint32_t {
    uint32_t v = 0;
    for (int i = 0; i < bits; i++, at++) {
      v = (v << 1) | (at < n * 8 ? ((b[at >> 3] >> (7 - (at & 7))) & 1u) : 0u);
    }
    return v;
  };
  f(3);  // seq_profile
  f(1);  // still_picture
  if (f(1)) {  // reduced_still_picture_header
    f(5);      // seq_level_idx[0]
  } else {
    bool model = false;
    int delay_bits = 0;
    if (f(1)) {  // timing_info_present_flag
      f(32);     // num_units_in_display_tick
      f(32);     // time_scale
      if (f(1)) {  // equal_picture_interval -> uvlc num_ticks_per_picture_minus_1
        int zeros = 0;
        while (!f(1) && zeros < 32) zeros++;
        f(zeros);
      }
      model = f(1) != 0;  // decoder_model_info_present_flag
      if (model) {
        delay_bits = (int)f(5) + 1;
        f(32);
        f(5);
        f(5);
      }
    }
    bool display = f(1) != 0;  // initial_display_delay_present_flag
    int points = (int)f(5) + 1;
    for (int i = 0; i < points; i++) {
      f(12);               // operating_point_idc
      if (f(5) > 7) f(1);  // seq_level_idx + optional seq_tier
      if (model && f(1)) {
        f(delay_bits);
        f(delay_bits);
        f(1);
      }
      if (display && f(1)) f(4);
    }
  }
  int wb = (int)f(4) + 1;
  int hb = (int)f(4) + 1;
  if (at + (size_t)wb + (size_t)hb > n * 8) return false;
  uint32_t want_w = (uint32_t)(w - 1);
  uint32_t want_h = (uint32_t)(h - 1);
  if (want_w >= (1u << wb) || want_h >= (1u << hb)) return false;
  size_t pos_wh = at;
  uint32_t cur_w = f(wb);
  uint32_t cur_h = f(hb);
  if (cur_w == want_w && cur_h == want_h) return false;
  at = pos_wh;
  auto put = [&](int bits, uint32_t v) {
    for (int i = bits - 1; i >= 0; i--, at++) {
      uint8_t m = (uint8_t)(1u << (7 - (at & 7)));
      if ((v >> i) & 1u) b[at >> 3] |= m;
      else b[at >> 3] &= (uint8_t)~m;
    }
  };
  put(wb, want_w);
  put(hb, want_h);
  return true;
}

static void patch_av1_obus_in_place(HANDLE hf, uint64_t at, uint64_t n, int w, int h) {
  if (n == 0 || n > (64u << 20)) return;
  std::vector<uint8_t> buf((size_t)n);
  if (!mp4_read_at(hf, at, buf.data(), (DWORD)n)) return;
  bool changed = false;
  for (size_t p = 0; p < buf.size();) {
    uint8_t hdr = buf[p];
    int obu_type = (hdr >> 3) & 15;
    int ext = (hdr >> 2) & 1;
    int has_size = (hdr >> 1) & 1;
    size_t q = p + 1 + (size_t)ext;
    size_t len = 0;
    if (has_size) {
      for (int i = 0; q < buf.size() && i < 8; i++) {
        uint8_t x = buf[q++];
        len |= (size_t)(x & 0x7Fu) << (7 * i);
        if (!(x & 0x80u)) break;
      }
    } else {
      len = q < buf.size() ? (buf.size() - q) : 0;
    }
    if (q + len > buf.size()) break;
    if (obu_type == 1) changed |= patch_av1_seq_hdr_obu(buf.data() + q, len, w, h);
    p = q + len;
  }
  if (changed) mp4_write_at(hf, at, buf.data(), (DWORD)n);
}

static void patch_mp4_av1_size(const std::wstring &path, int w, int h) {
  if (w <= 0 || h <= 0 || w > 65535 || h > 65535) return;
  HANDLE hf = CreateFileW(path.c_str(), GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ, NULL, OPEN_EXISTING,
                          FILE_ATTRIBUTE_NORMAL, NULL);
  if (hf == INVALID_HANDLE_VALUE) return;
  LARGE_INTEGER fsz = {};
  Mp4Box moov;
  if (GetFileSizeEx(hf, &fsz) && fsz.QuadPart >= 16 &&
      find_mp4_child(hf, 0, (uint64_t)fsz.QuadPart, fourcc('m', 'o', 'o', 'v'), moov)) {
    Mp4Box trak;
    for (uint64_t off = moov.payload; read_mp4_box(hf, off, moov.end, trak); off = trak.end) {
      if (trak.type != fourcc('t', 'r', 'a', 'k')) continue;
      Mp4Box mdia, minf, stbl, stsd, entry;
      if (!find_mp4_child(hf, trak.payload, trak.end, fourcc('m', 'd', 'i', 'a'), mdia)) continue;
      if (!find_mp4_child(hf, mdia.payload, mdia.end, fourcc('m', 'i', 'n', 'f'), minf)) continue;
      if (!find_mp4_child(hf, minf.payload, minf.end, fourcc('s', 't', 'b', 'l'), stbl)) continue;
      if (!find_mp4_child(hf, stbl.payload, stbl.end, fourcc('s', 't', 's', 'd'), stsd)) continue;
      if (stsd.payload + 8 >= stsd.end) continue;
      if (!read_mp4_box(hf, stsd.payload + 8, stsd.end, entry)) continue;
      if (entry.type != fourcc('a', 'v', '0', '1')) continue;
      if (entry.payload + 28 > entry.end) continue;

      uint8_t wh[4] = {(uint8_t)(w >> 8), (uint8_t)w, (uint8_t)(h >> 8), (uint8_t)h};
      mp4_write_at(hf, entry.payload + 24, wh, 4);

      if (entry.payload + 78 < entry.end) {
        Mp4Box av1c;
        if (find_mp4_child(hf, entry.payload + 78, entry.end, fourcc('a', 'v', '1', 'C'), av1c) &&
            av1c.payload + 4 < av1c.end) {
          patch_av1_obus_in_place(hf, av1c.payload + 4, av1c.end - (av1c.payload + 4), w, h);
        }
      }

      Mp4Box stsz, stsc, stss, chunk_box;
      bool has_stco = find_mp4_child(hf, stbl.payload, stbl.end, fourcc('s', 't', 'c', 'o'), chunk_box);
      bool has_co64 = !has_stco && find_mp4_child(hf, stbl.payload, stbl.end, fourcc('c', 'o', '6', '4'), chunk_box);
      if (!find_mp4_child(hf, stbl.payload, stbl.end, fourcc('s', 't', 's', 'z'), stsz) ||
          !find_mp4_child(hf, stbl.payload, stbl.end, fourcc('s', 't', 's', 'c'), stsc) ||
          !(has_stco || has_co64))
        continue;
      bool has_stss = find_mp4_child(hf, stbl.payload, stbl.end, fourcc('s', 't', 's', 's'), stss);
      if (stsz.end - stsz.payload < 12 || stsc.end - stsc.payload < 8 || chunk_box.end - chunk_box.payload < 8)
        continue;
      if (stsz.end - stsz.payload > (32u << 20) || stsc.end - stsc.payload > (32u << 20) ||
          chunk_box.end - chunk_box.payload > (32u << 20))
        continue;
      std::vector<uint8_t> z((size_t)(stsz.end - stsz.payload));
      std::vector<uint8_t> r((size_t)(stsc.end - stsc.payload));
      std::vector<uint8_t> c((size_t)(chunk_box.end - chunk_box.payload));
      if (!mp4_read_at(hf, stsz.payload, z.data(), (DWORD)z.size()) ||
          !mp4_read_at(hf, stsc.payload, r.data(), (DWORD)r.size()) ||
          !mp4_read_at(hf, chunk_box.payload, c.data(), (DWORD)c.size()))
        continue;

      uint32_t fixed = read_be32(&z[4]);
      uint32_t count = read_be32(&z[8]);
      uint32_t chunks = read_be32(&c[4]);
      uint32_t runs = read_be32(&r[4]);
      if (count == 0 || count > (16u << 20)) continue;
      std::vector<uint32_t> szs(count, fixed);
      if (!fixed) {
        for (uint32_t i = 0; i < count && 12 + 4 * (size_t)i + 4 <= z.size(); i++)
          szs[i] = read_be32(&z[12 + 4 * i]);
      }
      std::vector<uint64_t> offs(count, 0);
      uint32_t n = 0;
      for (uint32_t i = 0; i < runs && 8 + 12 * (size_t)i + 12 <= r.size(); i++) {
        uint32_t first_1 = read_be32(&r[8 + 12 * i]);
        uint32_t per = read_be32(&r[12 + 12 * i]);
        if (first_1 == 0) continue;
        uint32_t first = first_1 - 1;
        uint32_t last = chunks;
        if (i + 1 < runs && 8 + 12 * (size_t)(i + 1) + 4 <= r.size()) {
          uint32_t next_1 = read_be32(&r[8 + 12 * (i + 1)]);
          if (next_1 > 0 && next_1 - 1 < last) last = next_1 - 1;
        }
        for (uint32_t ch = first; ch < last && ch < chunks; ch++) {
          uint64_t place = 0;
          if (has_stco) {
            if (8 + 4 * (size_t)ch + 4 > c.size()) break;
            place = read_be32(&c[8 + 4 * ch]);
          } else {
            if (8 + 8 * (size_t)ch + 8 > c.size()) break;
            place = read_be64(&c[8 + 8 * ch]);
          }
          for (uint32_t j = 0; j < per && n < count; j++, n++) {
            offs[n] = place;
            place += szs[n];
          }
        }
      }
      if (has_stss && stss.end - stss.payload >= 8 && stss.end - stss.payload <= (32u << 20)) {
        std::vector<uint8_t> k((size_t)(stss.end - stss.payload));
        if (mp4_read_at(hf, stss.payload, k.data(), (DWORD)k.size())) {
          uint32_t keys = read_be32(&k[4]);
          for (uint32_t i = 0; i < keys && 8 + 4 * (size_t)i + 4 <= k.size(); i++) {
            uint32_t s1 = read_be32(&k[8 + 4 * i]);
            if (s1 > 0 && s1 - 1 < n) patch_av1_obus_in_place(hf, offs[s1 - 1], szs[s1 - 1], w, h);
          }
        }
      } else if (n > 0) {
        patch_av1_obus_in_place(hf, offs[0], szs[0], w, h);
      }
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
  std::vector<uint8_t> prev_idx;
  bool has_pending = false;
  int pend_x = 0, pend_y = 0, pend_w = 0, pend_h = 0;
  int pend_delay_cs = 0;
  bool pend_local_pal = false;
  uint8_t pend_pal[256 * 3];
  std::vector<uint8_t> pend_idx;
  int frames_written = 0;

  int global_ncols = 0;
  std::vector<int32_t> ht_key;   // LZW's table, kept between frames
  std::vector<uint16_t> ht_val;
  std::vector<uint8_t> crop, mask;  // a local palette's pixels, kept between frames

  // The palette index of 15-bit colour `k`: the LUT's where the palette was built of it, else the nearest colour,
  // found the first time it is asked and kept (only colours a frame has are ever looked for, not all 32768).
  static uint8_t lut_of(uint8_t lut[32768], const uint8_t pal[256 * 3], int ncols, uint32_t k) {
    uint8_t v = lut[k];
    if (v != 0xFF) return v;
    int r = (int)((k >> 10) & 31) * 255 / 31;
    int g = (int)((k >> 5) & 31) * 255 / 31;
    int b = (int)(k & 31) * 255 / 31;
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
    return (uint8_t)best_i;
  }

  // The palette of `rgb` (its masked pixels): its colours' LUT entries set, the rest 0xFF (lut_of finds them).
  // The number of colours (at most 255: 255 is the transparent index).
  static int build_palette(const uint8_t *rgb, int n_pixels, const uint8_t *mask, uint8_t pal[256 * 3],
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
      return 1;
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
    return ncols;
  }

  bool open(const std::wstring &path, int width, int height) {
    if (_wfopen_s(&fp, path.c_str(), L"wb") != 0 || !fp) return false;
    w = width;
    h = height;
    prev_rgb.assign((size_t)w * h * 3, 0);
    prev_idx.assign((size_t)w * h, 255);
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
    ht_key.assign(HT_SIZE, -1);
    ht_val.resize(HT_SIZE);

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

  void extend_pending_delay(int extra_cs) {
    if (has_pending && extra_cs > 0) {
      int total = pend_delay_cs + extra_cs;
      pend_delay_cs = total > 65535 ? 65535 : total;
    }
  }

  void add_frame(const uint8_t *rgb, int delay_cs) {
    if (!fp) return;
    static const int DIFF_THRESH = 18;
    const int n = w * h;
    if (!header_written && !has_pending) {
      global_ncols = build_palette(rgb, n, NULL, global_pal, global_lut);
      pend_x = 0;
      pend_y = 0;
      pend_w = w;
      pend_h = h;
      pend_delay_cs = delay_cs;
      pend_local_pal = false;
      pend_idx.resize((size_t)n);
      memcpy(prev_rgb.data(), rgb, (size_t)n * 3);
      for (int i = 0; i < n; i++) {
        uint32_t k = (((uint32_t)rgb[i * 3 + 0] >> 3) << 10) | (((uint32_t)rgb[i * 3 + 1] >> 3) << 5) |
                     ((uint32_t)rgb[i * 3 + 2] >> 3);
        uint8_t idx = lut_of(global_lut, global_pal, global_ncols, k);
        pend_idx[i] = idx;
        prev_idx[i] = idx;
      }
      has_pending = true;
      return;
    }

    int x0 = w, y0 = h, x1 = -1, y1 = -1;
    int changed = 0;
    uint64_t err_sum = 0;
    for (int y = 0; y < h; y++) {
      const uint8_t *cur = rgb + (size_t)y * w * 3;
      const uint8_t *prv = prev_rgb.data() + (size_t)y * w * 3;
      const uint8_t *pidx = prev_idx.data() + (size_t)y * w;
      for (int x = 0; x < w; x++) {
        int dr = abs((int)cur[x * 3 + 0] - (int)prv[x * 3 + 0]);
        int dg = abs((int)cur[x * 3 + 1] - (int)prv[x * 3 + 1]);
        int db = abs((int)cur[x * 3 + 2] - (int)prv[x * 3 + 2]);
        if (dr + dg + db <= DIFF_THRESH) continue;
        uint32_t k = (((uint32_t)cur[x * 3 + 0] >> 3) << 10) | (((uint32_t)cur[x * 3 + 1] >> 3) << 5) |
                     ((uint32_t)cur[x * 3 + 2] >> 3);
        uint8_t gidx = lut_of(global_lut, global_pal, global_ncols, k);
        int gerr = abs((int)cur[x * 3 + 0] - (int)global_pal[gidx * 3 + 0]) +
                   abs((int)cur[x * 3 + 1] - (int)global_pal[gidx * 3 + 1]) +
                   abs((int)cur[x * 3 + 2] - (int)global_pal[gidx * 3 + 2]);
        if (pidx[x] == gidx && gerr <= 24) continue;
        if (x < x0) x0 = x;
        if (x > x1) x1 = x;
        if (y < y0) y0 = y;
        if (y > y1) y1 = y;
        changed++;
        err_sum += (uint64_t)gerr;
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
    bool use_local = (changed > 256 && (err_sum / (uint64_t)changed) > 26);
    uint8_t local_lut[32768];
    uint8_t *lut = global_lut;
    const uint8_t *lut_pal = global_pal;
    int lut_n = global_ncols;
    if (use_local) {
      crop.resize((size_t)dw * dh * 3);
      mask.assign((size_t)dw * dh, 0);
      for (int y = 0; y < dh; y++) {
        const uint8_t *cur = rgb + ((size_t)(y0 + y) * w + x0) * 3;
        const uint8_t *prv = prev_rgb.data() + ((size_t)(y0 + y) * w + x0) * 3;
        memcpy(crop.data() + (size_t)y * dw * 3, cur, (size_t)dw * 3);
        for (int x = 0; x < dw; x++) {
          int d = abs((int)cur[x * 3 + 0] - (int)prv[x * 3 + 0]) + abs((int)cur[x * 3 + 1] - (int)prv[x * 3 + 1]) +
                  abs((int)cur[x * 3 + 2] - (int)prv[x * 3 + 2]);
          mask[(size_t)y * dw + x] = d > DIFF_THRESH ? 1 : 0;
        }
      }
      lut_n = build_palette(crop.data(), dw * dh, mask.data(), pend_pal, local_lut);
      lut = local_lut;
      lut_pal = pend_pal;
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
      uint8_t *pidx = prev_idx.data() + ((size_t)(y0 + y) * w + x0);
      for (int x = 0; x < dw; x++) {
        int d = abs((int)cur[x * 3 + 0] - (int)prv[x * 3 + 0]) + abs((int)cur[x * 3 + 1] - (int)prv[x * 3 + 1]) +
                abs((int)cur[x * 3 + 2] - (int)prv[x * 3 + 2]);
        if (d <= DIFF_THRESH) {
          pend_idx[(size_t)y * dw + x] = 255;
        } else {
          uint32_t k = (((uint32_t)cur[x * 3 + 0] >> 3) << 10) | (((uint32_t)cur[x * 3 + 1] >> 3) << 5) |
                       ((uint32_t)cur[x * 3 + 2] >> 3);
          uint8_t idx = lut_of(lut, lut_pal, lut_n, k);
          if (!use_local && pidx[x] == idx) {
            int gerr = abs((int)cur[x * 3 + 0] - (int)global_pal[idx * 3 + 0]) +
                       abs((int)cur[x * 3 + 1] - (int)global_pal[idx * 3 + 1]) +
                       abs((int)cur[x * 3 + 2] - (int)global_pal[idx * 3 + 2]);
            if (gerr <= 24) {
              pend_idx[(size_t)y * dw + x] = 255;
              continue;
            }
          }
          pend_idx[(size_t)y * dw + x] = idx;
          prv[x * 3 + 0] = cur[x * 3 + 0];
          prv[x * 3 + 1] = cur[x * 3 + 1];
          prv[x * 3 + 2] = cur[x * 3 + 2];
          pidx[x] = use_local ? 255 : idx;
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

// ---- Media Foundation, held only while a recording, an export or a probe runs ----
//
// Each worker thread starts it as it first needs it and shuts its own start down as it ends (MF counts them), so with
// nothing running its work queues' threads and the encoders' state are gone (measured, 2026-11-21: 8 cycles of
// start, a sink writer, shut down, no handle or thread kept past the first; kept started instead, 7 threads more).

static thread_local bool t_mf_on = false;

static bool mf_begin() {
  if (!t_mf_on) t_mf_on = SUCCEEDED(MFStartup(MF_VERSION, MFSTARTUP_LITE));
  return t_mf_on;
}

static void mf_end() {
  if (t_mf_on) MFShutdown();
  t_mf_on = false;
}

// ---- MP4 Encoder (Optimal Cascade: HW HEVC -> HW H.264 -> SW H.264, optional AAC audio stream) ----

struct Mp4Encoder {
  bool gpu_path = false;
  bool is_hevc = false;
  bool is_av1 = false;
  bool has_audio = false;
  bool audio_passthrough = false;
  std::string codec_name;
  int out_w = 0, out_h = 0, fps = 30;
  UINT32 custom_bps_hevc = 0, custom_bps_h264 = 0, custom_bps_av1 = 0;
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
  int gop_secs = 2;
  bool export_mode = false;

  ComPtr<ID3D11VideoProcessorInputView> in_view_kept;
  ComPtr<ID3D11Texture2D> in_view_tex;
  UINT in_view_sub = 0;

  // Most recent rendered NV12 pool texture and its WGC sequence number: when the desktop is static (same seq),
  // we skip VideoProcessorBlt and copy this NV12 surface directly, zero extra copy or allocation on moving frames.
  ComPtr<ID3D11Texture2D> last_vp_nv12;
  uint64_t last_vp_seq = 0;

  // NV12 surfaces handed to the encoder: 8 at first, grown one at a time (to 24 at most) only where the encoder holds
  // them all for a while, then reused
  static const int POOL_MAX = 24;
  ComPtr<ID3D11Texture2D> nv12_pool[POOL_MAX];
  ComPtr<ID3D11VideoProcessorOutputView> ov_pool[POOL_MAX];
  int pool_n = 8;
  int pool_cursor = 0;

  CRITICAL_SECTION write_lock = {};
  bool lock_init = false;

  static void set_sdr_color(IMFMediaType *mt) {
    mt->SetUINT32(MF_MT_VIDEO_PRIMARIES, MFVideoPrimaries_BT709);
    mt->SetUINT32(MF_MT_TRANSFER_FUNCTION, MFVideoTransFunc_sRGB);
    mt->SetUINT32(MF_MT_YUV_MATRIX, MFVideoTransferMatrix_BT709);
    mt->SetUINT32(MF_MT_VIDEO_NOMINAL_RANGE, MFNominalRange_16_235);
  }

  static double eff_fps(int f) {
    return (f > 30) ? (30.0 + (double)(f - 30) * 0.35) : (double)f;
  }

  // codec_mode: 0=HEVC, 1=H.264, 3=AV1
  UINT32 pick_bitrate(int codec_mode) const {
    if (codec_mode == 3 && custom_bps_av1 > 0) return custom_bps_av1;
    if (codec_mode == 0 && custom_bps_hevc > 0) return custom_bps_hevc;
    if (codec_mode == 1 && custom_bps_h264 > 0) return custom_bps_h264;
    double bpp = codec_mode == 3 ? 0.056 : (codec_mode == 0 ? 0.075 : 0.115);
    double raw = (double)out_w * (double)out_h * eff_fps(fps) * bpp;
    double lo = codec_mode == 3 ? 650000.0 : (codec_mode == 0 ? 1000000.0 : 1400000.0);
    double hi = codec_mode == 3 ? 12000000.0 : (codec_mode == 0 ? 18000000.0 : 26000000.0);
    if (fps > 60) hi *= 1.5;
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

  bool try_open_tier(ID3D11Device *dev, IMFDXGIDeviceManager *shared_mgr, int codec_mode, bool try_hw,
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
    out_mt->SetGUID(MF_MT_SUBTYPE,
                    codec_mode == 3 ? PS_MFVideoFormat_AV1 : (codec_mode == 0 ? MFVideoFormat_HEVC : MFVideoFormat_H264));
    out_mt->SetUINT32(MF_MT_AVG_BITRATE, pick_bitrate(codec_mode));
    out_mt->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
    MFSetAttributeSize(out_mt.Get(), MF_MT_FRAME_SIZE, (UINT32)out_w, (UINT32)out_h);
    MFSetAttributeRatio(out_mt.Get(), MF_MT_FRAME_RATE, (UINT32)fps, 1);
    MFSetAttributeRatio(out_mt.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
    if (codec_mode == 0) {
      out_mt->SetUINT32(MF_MT_MPEG2_PROFILE, eAVEncH265VProfile_Main_420_8);
    } else if (codec_mode == 1) {
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

    // High-efficiency PeakConstrainedVBR: 1s VBV buffer + tight peak cap lets quiet screen frames compress to
    // near-zero bits while keeping scrolling/motion crisp at high hardware NVENC/QSV/AMF throughput.
    UINT32 bps = pick_bitrate(codec_mode);
    UINT32 max_bps = (UINT32)std::min<uint64_t>((uint64_t)bps * (export_mode ? 125ULL : 140ULL) / 100ULL, 40000000ULL);
    UINT32 gop = (UINT32)(fps * (gop_secs > 0 ? gop_secs : 2));
    UINT32 qvs = export_mode ? (codec_mode == 3 ? 20 : 35) : 25;
    ComPtr<IMFAttributes> enc_params;
    if (SUCCEEDED(MFCreateAttributes(&enc_params, 8))) {
      enc_params->SetUINT32(CODECAPI_AVEncCommonMeanBitRate, bps);
      enc_params->SetUINT32(CODECAPI_AVEncMPVGOPSize, gop);
      enc_params->SetUINT32(CODECAPI_AVEncMPVDefaultBPictureCount, 0);
      enc_params->SetUINT32(CODECAPI_AVEncCommonRateControlMode, eAVEncCommonRateControlMode_PeakConstrainedVBR);
      enc_params->SetUINT32(CODECAPI_AVEncCommonMaxBitRate, max_bps);
      enc_params->SetUINT32(CODECAPI_AVEncCommonBufferSize, max_bps);
      enc_params->SetUINT32(CODECAPI_AVEncCommonQualityVsSpeed, qvs);
      // NVIDIA AV1 MFT pads static frames up to target bitrate unless a MinQP floor is set (ScreenReplay RTX 5080
      // calibration: MinQP=14 shrinks 30s still desktop from ~15 MB to ~2.2 MB at 51 dB with dynamic scenes unchanged).
      if (codec_mode == 3) enc_params->SetUINT32(CODECAPI_AVEncVideoMinQP, 14);
    }
    if (FAILED(writer->SetInputMediaType(video_stream, in_mt.Get(), enc_params.Get()))) {
      ComPtr<IMFAttributes> basic_params;
      if (SUCCEEDED(MFCreateAttributes(&basic_params, 2))) {
        basic_params->SetUINT32(CODECAPI_AVEncMPVGOPSize, gop);
        basic_params->SetUINT32(CODECAPI_AVEncMPVDefaultBPictureCount, 0);
      }
      if (FAILED(writer->SetInputMediaType(video_stream, in_mt.Get(), basic_params.Get())) &&
          FAILED(writer->SetInputMediaType(video_stream, in_mt.Get(), NULL))) {
        writer.Reset();
        return false;
      }
    }

    // Apply rate control & quality/speed parameters directly on the hardware MFT's ICodecAPI so NVENC/QSV/AMF
    // enforce the target bitrate and GOP size reliably.
    ComPtr<ICodecAPI> codec_api;
    if (SUCCEEDED(writer->GetServiceForStream(video_stream, GUID_NULL, IID_PPV_ARGS(&codec_api)))) {
      auto set_u32 = [&](const GUID &key, UINT32 val) {
        VARIANT v;
        VariantInit(&v);
        v.vt = VT_UI4;
        v.ulVal = val;
        codec_api->SetValue(&key, &v);
      };
      set_u32(CODECAPI_AVEncCommonRateControlMode, eAVEncCommonRateControlMode_PeakConstrainedVBR);
      set_u32(CODECAPI_AVEncCommonMeanBitRate, bps);
      set_u32(CODECAPI_AVEncCommonMaxBitRate, max_bps);
      set_u32(CODECAPI_AVEncCommonBufferSize, max_bps);
      set_u32(CODECAPI_AVEncMPVGOPSize, gop);
      set_u32(CODECAPI_AVEncCommonQualityVsSpeed, qvs);
      if (codec_mode == 3) set_u32(CODECAPI_AVEncVideoMinQP, 14);
    }

    if (want_audio) add_aac_stream(passthrough_audio);

    if (FAILED(writer->BeginWriting())) {
      writer.Reset();
      has_audio = false;
      return false;
    }

    gpu_path = try_hw;
    is_hevc = (codec_mode == 0);
    is_av1 = (codec_mode == 3);
    if (codec_mode == 3) codec_name = "AV1 (HW)";
    else if (codec_mode == 0 && try_hw) codec_name = "HEVC (HW)";
    else if (try_hw) codec_name = "H.264 (HW)";
    else codec_name = "H.264 (SW)";
    return true;
  }

  bool ensure_vp(ID3D11Device *dev, ID3D11DeviceContext *ctx, int in_w, int in_h, bool in_yuv) {
    if (vp && vp_in_w == in_w && vp_in_h == in_h && vp_in_yuv == in_yuv) return true;
    last_vp_nv12.Reset();
    last_vp_seq = 0;
    for (int i = 0; i < POOL_MAX; i++) {
      ov_pool[i].Reset();
      nv12_pool[i].Reset();
    }
    in_view_kept.Reset();
    in_view_tex.Reset();
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

  // want_codec: 0=HEVC preferred, 1=H.264, 3=AV1 (HW)
  bool open(ID3D11Device *dev, IMFDXGIDeviceManager *shared_mgr, const std::wstring &path, int w, int h,
            int target_fps, bool want_audio, IMFMediaType *passthrough_audio = NULL, int want_codec = 0) {
    if (!mf_begin()) return false;
    if (!lock_init) {
      InitializeCriticalSection(&write_lock);
      lock_init = true;
    }
    out_path = path;
    out_w = w;
    out_h = h;
    fps = target_fps;

    const char *force = getenv("PINSHOT_REC_CODEC");
    bool allow_hw = !force || !force[0] || strcmp(force, "sw") != 0;

    if (want_codec == 3) {
      if ((dev || shared_mgr) && allow_hw && try_open_tier(dev, shared_mgr, 3, true, want_audio, passthrough_audio))
        return true;
      DeleteFileW(out_path.c_str());
      if (lock_init) {
        DeleteCriticalSection(&write_lock);
        lock_init = false;
      }
      return false;
    }

    bool allow_hevc = (want_codec == 0) && (!force || !force[0] || strcmp(force, "hevc") == 0);

    if ((dev || shared_mgr) && allow_hw && allow_hevc &&
        try_open_tier(dev, shared_mgr, 0, true, want_audio, passthrough_audio))
      return true;
    DeleteFileW(out_path.c_str());
    if ((dev || shared_mgr) && allow_hw &&
        try_open_tier(dev, shared_mgr, 1, true, want_audio, passthrough_audio))
      return true;
    DeleteFileW(out_path.c_str());
    // Older hardware MFTs may reject 120fps on large regions; retry hardware tiers at 60fps before falling back to SW.
    if (fps > 60 && (dev || shared_mgr) && allow_hw) {
      fps = 60;
      if (allow_hevc && try_open_tier(dev, shared_mgr, 0, true, want_audio, passthrough_audio)) return true;
      DeleteFileW(out_path.c_str());
      if (try_open_tier(dev, shared_mgr, 1, true, want_audio, passthrough_audio)) return true;
      DeleteFileW(out_path.c_str());
    }
    if (fps > 60) fps = 60;
    if (try_open_tier(NULL, NULL, 1, false, want_audio, passthrough_audio)) return true;
    DeleteFileW(out_path.c_str());
    if (lock_init) {
      DeleteCriticalSection(&write_lock);
      lock_init = false;
    }
    return false;
  }

  bool acquire_nv12(ID3D11Device *dev, bool need_ov, ComPtr<ID3D11Texture2D> &out_tex,
                    ComPtr<ID3D11VideoProcessorOutputView> &out_ov) {
    D3D11_TEXTURE2D_DESC nd = {};
    nd.Width = (UINT)out_w;
    nd.Height = (UINT)out_h;
    nd.MipLevels = 1;
    nd.ArraySize = 1;
    nd.Format = DXGI_FORMAT_NV12;
    nd.SampleDesc.Count = 1;
    nd.Usage = D3D11_USAGE_DEFAULT;
    nd.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;

    // A pooled surface the encoder holds no more (only the pool's reference left). All of them still in flight:
    // waited for a moment (an export decodes far faster than it encodes, so it waits on the encoder: a texture made
    // for each such frame was gigabytes of video memory, 2026-11-21's audit), the pool grown by one where that is not
    // enough (an encoder that keeps more frames than 8 before it gives any back), up to POOL_MAX; past that a
    // recording drops the frame after a frame's time (its slot is caught up by the next), an export waits 10 s.
    DWORD waited = 0, yields = 0, grow_after = export_mode ? 4 : 2;
    DWORD most = export_mode ? 10000 : (DWORD)std::max(1, 1000 / std::max(1, fps));
    for (;;) {
      for (int k = 0; k < pool_n; k++) {
        int idx = (pool_cursor + k) % pool_n;
        if (!nv12_pool[idx]) {
          if (FAILED(dev->CreateTexture2D(&nd, NULL, &nv12_pool[idx]))) return false;
        }
        ID3D11Texture2D *raw = nv12_pool[idx].Get();
        raw->AddRef();
        ULONG rc = raw->Release();
        if (rc == 1) {
          pool_cursor = (idx + 1) % pool_n;
          out_tex = nv12_pool[idx];
          if (need_ov) {
            if (!ov_pool[idx]) {
              D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC ovd = {};
              ovd.ViewDimension = D3D11_VPOV_DIMENSION_TEXTURE2D;
              if (FAILED(vdev->CreateVideoProcessorOutputView(raw, vpenum.Get(), &ovd, &ov_pool[idx]))) return false;
            }
            out_ov = ov_pool[idx];
          }
          return true;
        }
      }
      if (waited >= grow_after && pool_n < POOL_MAX) {
        pool_cursor = pool_n++;
        waited = 0;
        yields = 0;
        continue;
      }
      if (waited >= most) return false;
      if (yields < 4) {
        SwitchToThread();
        yields++;
      } else {
        Sleep(1);
        waited++;
        yields = 0;
      }
    }
  }

  bool submit_nv12_sample(ID3D11Texture2D *nv12, LONGLONG pts, LONGLONG dur) {
    ComPtr<IMFMediaBuffer> buf;
    if (FAILED(MFCreateDXGISurfaceBuffer(__uuidof(ID3D11Texture2D), nv12, 0, FALSE, &buf))) return false;
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

  bool write_gpu_nv12_direct(ID3D11Device *dev, ID3D11DeviceContext *ctx, ID3D11Texture2D *src_nv12, UINT src_sub,
                             LONGLONG pts, LONGLONG dur) {
    ComPtr<ID3D11Texture2D> nv12;
    ComPtr<ID3D11VideoProcessorOutputView> unused_ov;
    if (!acquire_nv12(dev, false, nv12, unused_ov)) return false;
    D3D11_BOX cbox = {0, 0, 0, (UINT)out_w, (UINT)out_h, 1};
    ctx->CopySubresourceRegion(nv12.Get(), 0, 0, 0, 0, src_nv12, src_sub, &cbox);
    return submit_nv12_sample(nv12.Get(), pts, dur);
  }

  bool write_gpu_frame(ID3D11Device *dev, ID3D11DeviceContext *ctx, ID3D11Texture2D *src_tex, UINT src_sub,
                       bool src_is_yuv, int sx, int sy, int sw, int sh, LONGLONG pts, LONGLONG dur,
                       bool keep_view = false, uint64_t cache_seq = 0) {
    if (cache_seq != 0 && cache_seq == last_vp_seq && last_vp_nv12) {
      // Static frame fast path: reuse the previously converted NV12 surface via pure GPU DMA copy, skipping
      // VideoProcessorBlt + BT.709 RGB->NV12 conversion while keeping 100% CFR compatibility.
      return write_gpu_nv12_direct(dev, ctx, last_vp_nv12.Get(), 0, pts, dur);
    }
    D3D11_TEXTURE2D_DESC sd = {};
    src_tex->GetDesc(&sd);
    if (!ensure_vp(dev, ctx, (int)sd.Width, (int)sd.Height, src_is_yuv)) return false;

    ComPtr<ID3D11Texture2D> nv12;
    ComPtr<ID3D11VideoProcessorOutputView> out_view;
    if (!acquire_nv12(dev, true, nv12, out_view)) return false;

    // (the input's view kept while it is the same texture of ours, as an export's or HDR's single surface is; a
    // capture's own surfaces, the pool's, are never held past the frame)
    ComPtr<ID3D11VideoProcessorInputView> in_view;
    if (keep_view && in_view_kept && in_view_tex.Get() == src_tex && in_view_sub == src_sub) {
      in_view = in_view_kept;
    } else {
      D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC ivd = {};
      ivd.ViewDimension = D3D11_VPIV_DIMENSION_TEXTURE2D;
      ivd.Texture2D.ArraySlice = src_sub;
      if (FAILED(vdev->CreateVideoProcessorInputView(src_tex, vpenum.Get(), &ivd, &in_view))) return false;
      in_view_kept.Reset();
      in_view_tex.Reset();
      if (keep_view) {
        in_view_kept = in_view;
        in_view_tex = src_tex;
        in_view_sub = src_sub;
      }
    }

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
    if (cache_seq != 0) {
      last_vp_nv12 = nv12;
      last_vp_seq = cache_seq;
    }
    return submit_nv12_sample(nv12.Get(), pts, dur);
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
    last_vp_nv12.Reset();
    last_vp_seq = 0;
    for (int i = 0; i < POOL_MAX; i++) {
      ov_pool[i].Reset();
      nv12_pool[i].Reset();
    }
    in_view_kept.Reset();
    in_view_tex.Reset();
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
    else if (is_av1) patch_mp4_av1_size(out_path, out_w, out_h);
    return file_size_of(out_path);
  }
};

// ---- MMCSS real-time scheduling guard (loaded dynamically only while recording; zero idle DLL footprint) ----

struct MmcssGuard {
  typedef HANDLE(WINAPI *SetFn)(LPCWSTR, LPDWORD);
  typedef BOOL(WINAPI *RevertFn)(HANDLE);
  HMODULE mod = NULL;
  HANDLE task = NULL;
  RevertFn revert_fn = NULL;

  explicit MmcssGuard(const wchar_t *name) {
    mod = LoadLibraryW(L"avrt.dll");
    if (!mod) return;
    SetFn set_fn = (SetFn)GetProcAddress(mod, "AvSetMmThreadCharacteristicsW");
    revert_fn = (RevertFn)GetProcAddress(mod, "AvRevertMmThreadCharacteristics");
    if (set_fn && revert_fn) {
      DWORD idx = 0;
      task = set_fn(name, &idx);
    }
  }
  ~MmcssGuard() {
    if (task && revert_fn) revert_fn(task);
    if (mod) FreeLibrary(mod);
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
    MmcssGuard mmcss(L"Audio");
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
      // (waited for whole: it writes into the encoder, and the event, which are let go after; this is the
      // recording's worker waiting, never the UI thread, and the loop sees the event within 10 ms)
      WaitForSingleObject(thread, INFINITE);
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

// Ref-counted owner of a WGC capture frame: calls IClosable::Close() only when BOTH FrameArrived and rec_worker
// have finished with the surface, preventing premature surface reclamation mid-encode on high-Hz monitors.
struct WgcFrameHold {
  ComPtr<WGC::IDirect3D11CaptureFrame> frame;
  explicit WgcFrameHold(const ComPtr<WGC::IDirect3D11CaptureFrame> &f) : frame(f) {}
  ~WgcFrameHold() {
    ComPtr<ABI::Windows::Foundation::IClosable> c;
    if (frame && SUCCEEDED(frame.As(&c))) c->Close();
  }
};

// What the free-threaded pool's FrameArrived shares with the worker: held by both (the handler's own reference keeps it
// alive past the worker's return, as a frame may still be arriving on the pool's thread when the worker lets go), and
// told when the worker is done with it, after which an arriving frame is closed at once and kept nowhere.
struct RecWorkerState {
  SRWLOCK lock = SRWLOCK_INIT;
  std::shared_ptr<WgcFrameHold> last_frame;
  HANDLE first_frame_ev = NULL;
  HANDLE new_frame_ev = NULL;
  uint64_t frame_seq = 0;
  bool got_frame = false;
  bool stopped = false;
  RecWorkerState() {
    first_frame_ev = CreateEventW(NULL, TRUE, FALSE, NULL);
    new_frame_ev = CreateEventW(NULL, FALSE, FALSE, NULL);
  }
  ~RecWorkerState() {
    if (first_frame_ev) CloseHandle(first_frame_ev);
    if (new_frame_ev) CloseHandle(new_frame_ev);
  }
  // The last frame let go (closed once no worker holds it) and no other kept from now.
  void stop() {
    std::shared_ptr<WgcFrameHold> old;
    AcquireSRWLockExclusive(&lock);
    stopped = true;
    old.swap(last_frame);
    ReleaseSRWLockExclusive(&lock);
  }
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

static DWORD WINAPI rec_worker(LPVOID arg) {
  LONG my_session = (LONG)(intptr_t)arg;
  MmcssGuard mmcss(L"Capture");
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

  std::shared_ptr<RecWorkerState> ws = std::make_shared<RecWorkerState>();

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
    // (the shader compiled only where the monitor is HDR: an SDR one's frames are BGRA8 as they are, and the compiler
    // is never loaded for it)
    if (ps_wgc_mon_hdr(mon, &sdr_white) != 0) {
      ComPtr<ID3DBlob> code, errs;
      if (SUCCEEDED(D3DCompile(hlsl, sizeof hlsl - 1, "rec_srgb", NULL, NULL, "main", "cs_5_0",
                               D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, &code, &errs))) {
        dev->CreateComputeShader(code->GetBufferPointer(), code->GetBufferSize(), NULL, &to_srgb);
      }
      D3D11_BUFFER_DESC bd = {16, D3D11_USAGE_DYNAMIC, D3D11_BIND_CONSTANT_BUFFER, D3D11_CPU_ACCESS_WRITE, 0, 0};
      dev->CreateBuffer(&bd, NULL, &to_srgb_k);
    }
    is_hdr = to_srgb && to_srgb_k;
    if (!is_hdr) sdr_white = 1.0f;

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
      // Elevate GPU scheduling priority (best-effort) so 100%-GPU games do not starve HDR tonemap / VideoProcessorBlt.
      xdev->SetGPUThreadPriority(7);
      ABI::Windows::Graphics::SizeInt32 sz = {mw, mh};
      auto pix_fmt = is_hdr ? ABI::Windows::Graphics::DirectX::DirectXPixelFormat_R16G16B16A16Float
                            : ABI::Windows::Graphics::DirectX::DirectXPixelFormat_B8G8R8A8UIntNormalized;
      // 4-buffer pool prevents DWM capture stalls on 120/240Hz monitors while rec_worker encodes the active surface.
      if (SUCCEEDED(pool_statics->CreateFreeThreaded(rt_dev.Get(), pix_fmt, 4, sz, &pool))) {
        auto arrived = Callback<Microsoft::WRL::Implements<Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::ClassicCom>,
                                                           ITypedEventHandler<WGC::Direct3D11CaptureFramePool *, IInspectable *>,
                                                           Microsoft::WRL::FtmBase>>(
            [ws](WGC::IDirect3D11CaptureFramePool *sender, IInspectable *) -> HRESULT {
              // Drain all queued frames so we always publish the freshest surface and return older buffers immediately.
              ComPtr<WGC::IDirect3D11CaptureFrame> latest;
              for (;;) {
                ComPtr<WGC::IDirect3D11CaptureFrame> next;
                if (FAILED(sender->TryGetNextFrame(&next)) || !next) break;
                if (latest) {
                  ComPtr<ABI::Windows::Foundation::IClosable> c;
                  if (SUCCEEDED(latest.As(&c))) c->Close();
                }
                latest = next;
              }
              if (latest) {
                auto hold = std::make_shared<WgcFrameHold>(latest);
                std::shared_ptr<WgcFrameHold> old;
                AcquireSRWLockExclusive(&ws->lock);
                if (!ws->stopped) {
                  old.swap(ws->last_frame);
                  ws->last_frame = hold;
                  ws->frame_seq++;
                  ws->got_frame = true;
                }
                ReleaseSRWLockExclusive(&ws->lock);
                SetEvent(ws->first_frame_ev);
                SetEvent(ws->new_frame_ev);
              }
              return S_OK;
            });
        if (SUCCEEDED(pool->add_FrameArrived(arrived.Get(), &token)) &&
            SUCCEEDED(pool->CreateCaptureSession(item.Get(), &session))) {
          ComPtr<WGC::IGraphicsCaptureSession2> s2;
          if (SUCCEEDED(session.As(&s2))) s2->put_IsCursorCaptureEnabled(cursor ? TRUE : FALSE);
          ComPtr<IPsGraphicsCaptureSession5> s5;
          if (fps > 30 && SUCCEEDED(session.As(&s5))) {
            // Unlock Win11 24H2+'s 16ms (60Hz) default WGC throttle: 1ms for >60fps (90/120fps), 7ms for 60fps.
            ABI::Windows::Foundation::TimeSpan min_iv = {fps > 60 ? 10000LL : 70000LL};
            s5->put_MinUpdateInterval(min_iv);
          }
          ComPtr<WGC::IGraphicsCaptureSession3> s3;
          if (SUCCEEDED(session.As(&s3)) && SUCCEEDED(s3->put_IsBorderRequired(FALSE)) &&
              SUCCEEDED(session->StartCapture())) {
            wgc_ok = true;
          }
        }
      }
    }
  }

  if (wgc_ok) WaitForSingleObject(ws->first_frame_ev, 500);

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

  // GDI's taking (no WGC session): one DC and DIB section for the whole recording, the pixels read from it in place
  HDC gdi_mem = NULL;
  HBITMAP gdi_bmp = NULL;
  HGDIOBJ gdi_old = NULL;
  void *gdi_bits = NULL;
  auto capture_gdi = [&](const uint8_t *&out_px, int &out_pitch, bool &out_bgra) -> bool {
    HDC screen = GetDC(NULL);
    if (!screen) return false;
    if (!gdi_mem) {
      gdi_mem = CreateCompatibleDC(screen);
      BITMAPINFO bi = {};
      bi.bmiHeader.biSize = sizeof bi.bmiHeader;
      bi.bmiHeader.biWidth = rw;
      bi.bmiHeader.biHeight = -rh;
      bi.bmiHeader.biPlanes = 1;
      bi.bmiHeader.biBitCount = 32;
      bi.bmiHeader.biCompression = BI_RGB;
      gdi_bmp = gdi_mem ? CreateDIBSection(screen, &bi, DIB_RGB_COLORS, &gdi_bits, NULL, 0) : NULL;
      if (gdi_bmp && gdi_bits) gdi_old = SelectObject(gdi_mem, gdi_bmp);
    }
    bool ok = false;
    if (gdi_old && BitBlt(gdi_mem, 0, 0, rw, rh, screen, R.x, R.y, SRCCOPY)) {
      if (cursor) {
        CURSORINFO ci = {};
        ci.cbSize = sizeof ci;
        if (GetCursorInfo(&ci) && (ci.flags & CURSOR_SHOWING)) {
          ICONINFO ii = {};
          if (GetIconInfo(ci.hCursor, &ii)) {
            DrawIconEx(gdi_mem, ci.ptScreenPos.x - R.x - (int)ii.xHotspot, ci.ptScreenPos.y - R.y - (int)ii.yHotspot,
                       ci.hCursor, 0, 0, 0, NULL, DI_NORMAL);
            if (ii.hbmMask) DeleteObject(ii.hbmMask);
            if (ii.hbmColor) DeleteObject(ii.hbmColor);
          }
        }
      }
      GdiFlush();
      out_px = (const uint8_t *)gdi_bits;
      out_pitch = rw * 4;
      out_bgra = true;
      ok = true;
    }
    ReleaseDC(NULL, screen);
    return ok;
  };
  auto free_gdi = [&]() {
    if (gdi_mem && gdi_old) SelectObject(gdi_mem, gdi_old);
    if (gdi_bmp) DeleteObject(gdi_bmp);
    if (gdi_mem) DeleteDC(gdi_mem);
    gdi_mem = NULL;
    gdi_bmp = NULL;
    gdi_old = NULL;
    gdi_bits = NULL;
  };

  // (the first frame's card built here, handed over with the recording as it is kept: R's own is the UI thread's)
  std::vector<uint8_t> preview;
  bool preview_captured = false;
  Mp4Encoder mp4;
  bool enc_ok = mp4.open(wgc_ok ? dev.Get() : NULL, NULL, master_path, rw, rh, fps, want_audio);
  if (enc_ok && mp4.fps > 0) fps = mp4.fps;
  if (!enc_ok) {
    if (pool) pool->remove_FrameArrived(token);
    ComPtr<ABI::Windows::Foundation::IClosable> c;
    if (session && SUCCEEDED(session.As(&c))) c->Close();
    if (pool && SUCCEEDED(pool.As(&c))) c->Close();
    ws->stop();
    timeEndPeriod(1);
    mf_end();
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
  uint64_t last_encoded_seq = 0;
  ID3D11Texture2D *cached_hdr_srgb = NULL;

  // Sub-millisecond waitable timer keeps 60fps (16.67ms) and 120fps (8.33ms) pacing locked without Sleep jitter.
  HANDLE pace_timer = CreateWaitableTimerExW(NULL, NULL, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS);
  HANDLE wait_handles[2] = {R.wake_ev, pace_timer};
  HANDLE grace_handles[2] = {R.wake_ev, ws->new_frame_ev};

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
      LONGLONG rem_hns = next_slot_hns - elapsed_hns;
      if (pace_timer && rem_hns >= 4000LL) {
        LARGE_INTEGER due;
        due.QuadPart = -(rem_hns > 500000LL ? 500000LL : rem_hns);
        if (SetWaitableTimer(pace_timer, &due, 0, NULL, NULL, FALSE)) {
          WaitForMultipleObjects(2, wait_handles, FALSE, 50);
        } else {
          WaitForSingleObject(R.wake_ev, 1);
        }
      } else if (rem_hns >= 10000LL) {
        DWORD wait_ms = (DWORD)(rem_hns / 10000LL);
        if (wait_ms > 50) wait_ms = 50;
        WaitForSingleObject(R.wake_ev, wait_ms);
      } else {
        SwitchToThread();
      }
      continue;
    }

    std::shared_ptr<WgcFrameHold> fr;
    ComPtr<ID3D11Texture2D> src_tex;
    uint64_t fr_seq = 0;
    if (wgc_ok) {
      AcquireSRWLockShared(&ws->lock);
      fr = ws->last_frame;
      fr_seq = ws->frame_seq;
      ReleaseSRWLockShared(&ws->lock);
      // Phase-lock grace wait: if no fresh WGC frame has arrived since the last slot and we are still on time,
      // wait briefly (2-3ms) for the imminent frame instead of duplicating the previous frame on CFR/VSync beat drift.
      if (fr_seq == last_encoded_seq && ws->new_frame_ev && elapsed_hns - next_slot_hns < 20000LL) {
        ResetEvent(ws->new_frame_ev);
        AcquireSRWLockShared(&ws->lock);
        fr = ws->last_frame;
        fr_seq = ws->frame_seq;
        ReleaseSRWLockShared(&ws->lock);
        if (fr_seq == last_encoded_seq) {
          WaitForMultipleObjects(2, grace_handles, FALSE, fps > 60 ? 2 : 3);
          AcquireSRWLockShared(&ws->lock);
          fr = ws->last_frame;
          fr_seq = ws->frame_seq;
          ReleaseSRWLockShared(&ws->lock);
        }
      }
      if (fr && fr->frame) {
        ComPtr<WD3D::IDirect3DSurface> surf;
        ComPtr<Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess> acc;
        if (SUCCEEDED(fr->frame->get_Surface(&surf)) && SUCCEEDED(surf.As(&acc))) {
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
        if (!preview_captured) {
          int pp = 0;
          bool pbgra = true;
          std::vector<uint8_t> pbuf;
          if (read_cpu_srgb(rgb_tex, sx, sy, pbuf, pp, pbgra)) {
            build_preview_bmp(pbuf.data(), rw, rh, pp, pbgra, preview);
            preview_captured = true;
          }
          // (the GPU's path reads nothing back after the card: its staging copy let go now, not at the end)
          staging_tex.Reset();
        }
        wrote = mp4.write_gpu_frame(dev.Get(), ctx.Get(), rgb_tex, 0, false, sx, sy, rw, rh, next_slot_hns, dur_hns,
                                    is_hdr, fr_seq);
      }
    } else {
      int pitch = 0;
      bool is_bgra = true;
      bool got = false;
      const uint8_t *px = NULL;
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
        px = cpu_bgra.data();
      } else {
        got = capture_gdi(px, pitch, is_bgra);
      }
      if (got && px) {
        if (!preview_captured) {
          build_preview_bmp(px, rw, rh, pitch, is_bgra, preview);
          preview_captured = true;
        }
        wrote = mp4.write_cpu_frame(px, pitch, is_bgra, next_slot_hns, dur_hns);
      }
    }

    if (wrote) {
      last_encoded_seq = fr_seq;
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

  if (pace_timer) CloseHandle(pace_timer);
  bool cancel = InterlockedCompareExchange(&R.stop_req, 0, 0) == 2;
  if (audio_pump.active) audio_pump.stop();
  if (!cancel) rec_post("saving", last_elapsed_ms, frames, 0, 0, 0, mp4.has_audio ? 1 : 0, mp4.codec_name.c_str(), L"", "");

  bool had_audio = mp4.has_audio;
  std::string codec_used = mp4.codec_name;
  uint64_t final_bytes = mp4.finish(cancel || frames == 0);

  // Release all WGC and D3D11 objects and trim driver pools immediately. (a frame arriving after this, on the pool's
  // thread, finds the state told it is over: closed there, kept nowhere)
  if (pool) pool->remove_FrameArrived(token);
  ComPtr<ABI::Windows::Foundation::IClosable> closable;
  if (session && SUCCEEDED(session.As(&closable))) closable->Close();
  if (pool && SUCCEEDED(pool.As(&closable))) closable->Close();
  session.Reset();
  pool.Reset();
  ws->stop();
  ws.reset();
  free_gdi();

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
  mf_end();
  if (SUCCEEDED(ro_hr)) RoUninitialize();

  // (kept only for the session it was made in: one ended meanwhile (ps_rec_end) had its file let go here)
  bool kept = false;
  if (!cancel && final_bytes > 0) {
    AcquireSRWLockExclusive(&R.lock);
    if (R.session == my_session) {
      if (!R.master_path.empty() && R.master_path != master_path) DeleteFileW(R.master_path.c_str());
      R.master_path = master_path;
      R.master_bytes = final_bytes;
      R.master_ms = last_elapsed_ms;
      R.master_w = rw;
      R.master_h = rh;
      R.master_fps = fps;
      R.master_audio = had_audio ? 1 : 0;
      R.master_codec = codec_used;
      R.preview_bmp.swap(preview);
      kept = true;
    }
    ReleaseSRWLockExclusive(&R.lock);
  }
  InterlockedExchange(&R.running, 0);

  if (cancel) {
    DeleteFileW(master_path.c_str());
    rec_post("cancelled", last_elapsed_ms, frames, 0, 0, 0, 0, codec_used.c_str(), L"", "");
  } else if (kept) {
    rec_post("recorded", last_elapsed_ms, frames, final_bytes, final_bytes, 100, had_audio ? 1 : 0, codec_used.c_str(),
             master_path, "");
  } else {
    DeleteFileW(master_path.c_str());
    if (final_bytes == 0)
      rec_post("error", last_elapsed_ms, frames, 0, 0, 0, 0, codec_used.c_str(), L"", "保存录屏文件失败");
  }
  return 0;
}

// ---- Post-Recording Export / Compression Worker Thread ----

// What an export is of and what it is asked to make: taken as it is begun (ps_rec_export, the UI thread's), so the
// worker reads nothing of R's that the UI thread may change meanwhile.
struct ExportJob {
  std::wstring src, dst;
  std::string master_codec;
  int fmt, quality, max_side, gif_fps;
  uint64_t orig_bytes;
  int64_t total_ms;
  int src_w, src_h, src_fps;
  bool src_audio;
  LONG gen;  // R.exp_gen as it was begun: another since, it is called off
};

static bool export_called_off(const ExportJob &job) { return InterlockedCompareExchange(&R.exp_gen, 0, 0) != job.gen; }

static DWORD export_work(const ExportJob &job);

static DWORD WINAPI export_worker(LPVOID arg) {
  ExportJob *job = (ExportJob *)arg;
  // High-res 1ms timer prevents Sleep(1) in acquire_nv12 from stalling 15.6ms per full-pool wait during HW transcode.
  timeBeginPeriod(1);
  DWORD r = export_work(*job);
  timeEndPeriod(1);
  delete job;
  mf_end();
  return r;
}

static DWORD export_work(const ExportJob &job) {
  HRESULT co = CoInitializeEx(NULL, COINIT_MULTITHREADED);
  const std::wstring &src = job.src;
  const std::wstring &dst = job.dst;
  int fmt = job.fmt;             // 0=MP4 H.265, 1=MP4 H.264, 2=GIF, 3=AV1
  int quality = job.quality;     // 0=Original, 1=High, 2=Balanced, 3=Compact
  int max_side = job.max_side;   // 0=Original, else percent / long edge
  int gif_fps = job.gif_fps > 0 ? job.gif_fps : 15;
  uint64_t orig_bytes = job.orig_bytes;
  int64_t total_ms = job.total_ms > 0 ? job.total_ms : 1;
  int src_w = job.src_w;
  int src_h = job.src_h;
  int src_fps = job.src_fps > 0 ? job.src_fps : 30;
  bool src_audio = job.src_audio;

  rec_make_dirs(dst);

  int out_w = src_w, out_h = src_h;
  compute_scaled_dims(src_w, src_h, max_side, out_w, out_h);
  bool need_resize = (out_w != src_w || out_h != src_h);
  bool master_is_hevc = (job.master_codec.rfind("HEVC", 0) == 0);
  bool want_hevc = (fmt == 0);
  bool direct_copy = (fmt == 0 || fmt == 1) && quality == 0 && !need_resize && (want_hevc == master_is_hevc);

  // Zero re-encode instant copy when codec, quality=Original, and size all match master
  if (direct_copy) {
    if (CopyFileW(src.c_str(), dst.c_str(), FALSE)) {
      uint64_t sz = file_size_of(dst);
      copy_file_to_clipboard(dst);
      InterlockedExchange(&R.exporting, 0);
      if (SUCCEEDED(co)) CoUninitialize();
      rec_post("exported", total_ms, 0, sz, orig_bytes, 100, src_audio ? 1 : 0, job.master_codec.c_str(), dst, "");
      return 0;
    }
    InterlockedExchange(&R.exporting, 0);
    if (SUCCEEDED(co)) CoUninitialize();
    rec_post("export-error", total_ms, 0, 0, orig_bytes, 0, 0, "", dst, "保存文件失败");
    return 0;
  }

  if (!mf_begin()) {
    InterlockedExchange(&R.exporting, 0);
    if (SUCCEEDED(co)) CoUninitialize();
    rec_post("export-error", total_ms, 0, 0, orig_bytes, 0, 0, "", dst, "初始化转码失败");
    return 0;
  }

  // MP4 transcode / compress (fmt 0 = H.265 preferred, fmt 1 = H.264, fmt 3 = AV1)
  if (fmt == 0 || fmt == 1 || fmt == 3) {

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
    enc.gop_secs = 5;  // 5s GOP + 2 B-frames on offline export: cuts keyframe overhead & improves HEVC/H.264 efficiency
    enc.export_mode = true;
    // Quality tiers: 0=Original (high-bitrate transcode), 1=High, 2=Balanced, 3=Compact
    static const double kBppHevc[4] = {0.075, 0.048, 0.024, 0.011};
    static const double kBppH264[4] = {0.115, 0.072, 0.038, 0.018};
    static const double kBppAv1[4]  = {0.056, 0.036, 0.018, 0.0085};
    static const double kLoHevc[4]  = {900000.0, 550000.0, 280000.0, 150000.0};
    static const double kHiHevc[4]  = {16000000.0, 8000000.0, 3500000.0, 1500000.0};
    static const double kLoH264[4]  = {1300000.0, 800000.0, 420000.0, 220000.0};
    static const double kHiH264[4]  = {24000000.0, 12000000.0, 5200000.0, 2200000.0};
    static const double kLoAv1[4]   = {650000.0, 400000.0, 200000.0, 110000.0};
    static const double kHiAv1[4]   = {12000000.0, 6000000.0, 2600000.0, 1100000.0};
    int qi = quality < 0 ? 2 : (quality > 3 ? 3 : quality);
    double ef = Mp4Encoder::eff_fps(src_fps);
    double hi_mul = src_fps > 60 ? 1.5 : 1.0;
    double r_hevc = (double)out_w * out_h * ef * kBppHevc[qi];
    double r_h264 = (double)out_w * out_h * ef * kBppH264[qi];
    double r_av1  = (double)out_w * out_h * ef * kBppAv1[qi];
    enc.custom_bps_hevc = (UINT32)(r_hevc < kLoHevc[qi] ? kLoHevc[qi] : (r_hevc > kHiHevc[qi] * hi_mul ? kHiHevc[qi] * hi_mul : r_hevc));
    enc.custom_bps_h264 = (UINT32)(r_h264 < kLoH264[qi] ? kLoH264[qi] : (r_h264 > kHiH264[qi] * hi_mul ? kHiH264[qi] * hi_mul : r_h264));
    enc.custom_bps_av1  = (UINT32)(r_av1  < kLoAv1[qi]  ? kLoAv1[qi]  : (r_av1  > kHiAv1[qi]  * hi_mul ? kHiAv1[qi]  * hi_mul : r_av1));

    if (!enc.open(gpu_dec ? dev.Get() : NULL, gpu_dec ? mgr.Get() : NULL, dst, out_w, out_h, src_fps, has_src_audio,
                  NULL, fmt)) {
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
    uint8_t stream_kind[8] = {0};  // 1 video, 2 other, 0 not asked yet

    while (!(video_done && audio_done) && !export_called_off(job)) {
      DWORD sidx = 0, flags = 0;
      LONGLONG ts = 0;
      ComPtr<IMFSample> sample;
      HRESULT hr = reader->ReadSample((DWORD)MF_SOURCE_READER_ANY_STREAM, 0, &sidx, &flags, &ts, &sample);
      if (FAILED(hr)) break;

      // (each stream's kind asked once, not of every sample)
      if (sidx >= 8) continue;
      if (!stream_kind[sidx]) {
        ComPtr<IMFMediaType> cur_mt;
        reader->GetCurrentMediaType(sidx, &cur_mt);
        GUID major = GUID_NULL;
        if (cur_mt) cur_mt->GetGUID(MF_MT_MAJOR_TYPE, &major);
        stream_kind[sidx] = major == MFMediaType_Video ? 1 : 2;
      }
      bool is_video = stream_kind[sidx] == 1;

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
            if (out_w == src_w && out_h == src_h && (int)sd.Width >= out_w && (int)sd.Height >= out_h) {
              // Zero-VideoProcessor fast path: direct GPU copy from decoder slice to pooled NV12 encoder surface.
              enc.write_gpu_nv12_direct(dev.Get(), ctx.Get(), dtex.Get(), sub, ts, dur);
            } else {
              // Scaled export: copy decoder array slice into single-slice NV12 texture, then GPU VideoProcessor resize.
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
                enc.write_gpu_frame(dev.Get(), ctx.Get(), single_nv12.Get(), 0, true, 0, 0, src_w, src_h, ts, dur, true);
              }
            }
          }
        } else {
          // (its rows as the buffer has them: IMF2DBuffer's first row and signed pitch where it has one, a decoder's
          // padded or bottom-up rows read right; else contiguous, top-down; unlocked however it went)
          ComPtr<IMFMediaBuffer> buf;
          ComPtr<IMF2DBuffer> buf2d;
          BYTE *scan0 = NULL;
          LONG pitch = 0;
          bool locked_2d = false, locked_1d = false;
          DWORD bufs = 0;
          if (SUCCEEDED(sample->GetBufferCount(&bufs)) && bufs == 1 && SUCCEEDED(sample->GetBufferByIndex(0, &buf)) &&
              SUCCEEDED(buf.As(&buf2d)) && SUCCEEDED(buf2d->Lock2D(&scan0, &pitch))) {
            locked_2d = true;
            if ((pitch < 0 ? -pitch : pitch) < (LONG)src_w * 4) {
              buf2d->Unlock2D();
              locked_2d = false;
            }
          }
          if (!locked_2d) {
            buf.Reset();
            BYTE *p = NULL;
            DWORD len = 0;
            if (SUCCEEDED(sample->ConvertToContiguousBuffer(&buf)) && SUCCEEDED(buf->Lock(&p, NULL, &len))) {
              if (len >= (DWORD)((size_t)src_w * src_h * 4)) {
                scan0 = p;
                pitch = (LONG)src_w * 4;
                locked_1d = true;
              } else {
                buf->Unlock();
              }
            }
          }
          if (locked_2d || locked_1d) {
            if (out_w == src_w && out_h == src_h && pitch > 0) {
              enc.write_cpu_frame(scan0, (int)pitch, true, ts, dur);
            } else {
              scaled_rgb.resize((size_t)out_w * out_h * 4);
              for (int y = 0; y < out_h; y++) {
                int sy = y * src_h / out_h;
                const uint8_t *sr = scan0 + (ptrdiff_t)sy * pitch;
                uint8_t *dr = scaled_rgb.data() + (size_t)y * out_w * 4;
                for (int x = 0; x < out_w; x++) {
                  int sx = x * src_w / out_w;
                  memcpy(dr + (size_t)x * 4, sr + (size_t)sx * 4, 4);
                }
              }
              enc.write_cpu_frame(scaled_rgb.data(), out_w * 4, true, ts, dur);
            }
            if (locked_2d) buf2d->Unlock2D();
            else buf->Unlock();
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

    bool cancelled = export_called_off(job);
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

    if (cancelled) {
      rec_post("export-cancelled", total_ms, 0, 0, orig_bytes, 0, 0, "", dst, "");
      return 0;
    }
    if (out_bytes > 0) {
      copy_file_to_clipboard(dst);
      rec_post("exported", total_ms, 0, out_bytes, orig_bytes, 100, out_audio ? 1 : 0, cname.c_str(), dst, "");
    } else {
      rec_post("export-error", total_ms, 0, 0, orig_bytes, 0, 0, "", dst, "压缩编码失败");
    }
    return 0;
  }

  // GIF export (fmt == 2)
  int gif_w = out_w, gif_h = out_h;

  ComPtr<IMFAttributes> rattr;
  MFCreateAttributes(&rattr, 2);
  rattr->SetUINT32(MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, TRUE);
  rattr->SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, TRUE);
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

  UINT32 dec_w = (UINT32)src_w, dec_h = (UINT32)src_h;
  LONG def_stride = (LONG)(dec_w * 4);
  auto refresh_gif_mt = [&]() {
    ComPtr<IMFMediaType> cur_mt;
    if (SUCCEEDED(reader->GetCurrentMediaType((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, &cur_mt)) && cur_mt) {
      UINT32 fw = 0, fh = 0;
      if (SUCCEEDED(MFGetAttributeSize(cur_mt.Get(), MF_MT_FRAME_SIZE, &fw, &fh)) && fw > 0 && fh > 0) {
        dec_w = fw;
        dec_h = fh;
      }
      UINT32 raw_st = 0;
      if (SUCCEEDED(cur_mt->GetUINT32(MF_MT_DEFAULT_STRIDE, &raw_st)) && raw_st != 0) {
        def_stride = (LONG)raw_st;
      } else {
        LONG st = (LONG)(dec_w * 4);
        MFGetStrideForBitmapInfoHeader(MFVideoFormat_RGB32.Data1, dec_w, &st);
        def_stride = st;
      }
    }
  };
  refresh_gif_mt();

  LONGLONG step_hns = 10000000LL / gif_fps;
  int step_cs = std::max(2, (100 + gif_fps / 2) / gif_fps);
  LONGLONG next_want = 0;
  LONGLONG prev_ts = -1;
  LONGLONG total_hns = total_ms * 10000LL;
  int last_pct = -1;
  std::vector<uint8_t> rgb_frame((size_t)gif_w * gif_h * 3);

  while (!export_called_off(job)) {
    DWORD sidx = 0, flags = 0;
    LONGLONG ts = 0;
    ComPtr<IMFSample> sample;
    HRESULT hr = reader->ReadSample((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, &sidx, &flags, &ts, &sample);
    if (FAILED(hr) || (flags & MF_SOURCE_READERF_ENDOFSTREAM)) break;
    if (flags & MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED) refresh_gif_mt();
    if (!sample || ts < next_want) continue;

    while (next_want <= ts) next_want += step_hns;

    BYTE *scan0 = NULL;
    LONG pitch = 0;
    ComPtr<IMFMediaBuffer> raw_buf;
    ComPtr<IMF2DBuffer> buf2d;
    bool locked_2d = false;
    bool locked_1d = false;
    DWORD buf_count = 0;
    if (SUCCEEDED(sample->GetBufferCount(&buf_count)) && buf_count == 1 &&
        SUCCEEDED(sample->GetBufferByIndex(0, &raw_buf)) && SUCCEEDED(raw_buf.As(&buf2d)) &&
        SUCCEEDED(buf2d->Lock2D(&scan0, &pitch))) {
      locked_2d = true;
    } else {
      raw_buf.Reset();
      if (SUCCEEDED(sample->ConvertToContiguousBuffer(&raw_buf))) {
        BYTE *p = NULL;
        DWORD len = 0;
        if (SUCCEEDED(raw_buf->Lock(&p, NULL, &len))) {
          LONG abs_st = def_stride < 0 ? -def_stride : def_stride;
          if (abs_st >= (LONG)(src_w * 4) && len >= (DWORD)((size_t)abs_st * (size_t)std::min(src_h, (int)dec_h))) {
            scan0 = def_stride < 0 ? (p + (size_t)(dec_h - 1) * (size_t)abs_st) : p;
            pitch = def_stride;
            locked_1d = true;
          } else {
            raw_buf->Unlock();
          }
        }
      }
    }

    if (locked_2d || locked_1d) {
      int copy_w = std::min(src_w, (int)dec_w);
      int copy_h = std::min(src_h, (int)dec_h);
      if (gif_w == copy_w && gif_h == copy_h) {
        for (int y = 0; y < gif_h; y++) {
          const uint8_t *s = scan0 + (ptrdiff_t)y * pitch;
          uint8_t *d = rgb_frame.data() + (size_t)y * gif_w * 3;
          for (int x = 0; x < gif_w; x++) {
            d[x * 3 + 0] = s[x * 4 + 2];
            d[x * 3 + 1] = s[x * 4 + 1];
            d[x * 3 + 2] = s[x * 4 + 0];
          }
        }
      } else {
        // Bilinear/area downsample respecting actual signed row pitch
        for (int y = 0; y < gif_h; y++) {
          int y0 = y * copy_h / gif_h, y1 = std::max(y0 + 1, (y + 1) * copy_h / gif_h);
          if (y1 > copy_h) y1 = copy_h;
          uint8_t *d = rgb_frame.data() + (size_t)y * gif_w * 3;
          for (int x = 0; x < gif_w; x++) {
            int x0 = x * copy_w / gif_w, x1 = std::max(x0 + 1, (x + 1) * copy_w / gif_w);
            if (x1 > copy_w) x1 = copy_w;
            uint32_t sr = 0, sg = 0, sb = 0, cnt = 0;
            for (int yy = y0; yy < y1; yy++) {
              const uint8_t *s = scan0 + (ptrdiff_t)yy * pitch;
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
      if (prev_ts >= 0 && ts > prev_ts) {
        int real_cs = (int)((ts - prev_ts + 50000LL) / 100000LL);
        if (real_cs > step_cs) gif.extend_pending_delay(std::min(real_cs - step_cs, 500));
      }
      prev_ts = ts;
      gif.add_frame(rgb_frame.data(), step_cs);
      if (locked_2d) buf2d->Unlock2D();
      else raw_buf->Unlock();
    }

    int pct = total_hns > 0 ? (int)((ts * 98LL) / total_hns) : 50;
    if (pct > 98) pct = 98;
    if (pct < 0) pct = 0;
    if (pct - last_pct >= 5) {
      last_pct = pct;
      rec_post("exporting", total_ms, 0, 0, orig_bytes, pct, 0, "GIF", dst, "");
    }
  }

  bool cancelled = export_called_off(job);
  uint64_t out_bytes = 0;
  if (cancelled) {
    gif.abort();
    DeleteFileW(dst.c_str());
  } else {
    if (prev_ts >= 0 && total_hns > prev_ts) {
      int tail_cs = (int)((total_hns - prev_ts + 50000LL) / 100000LL);
      if (tail_cs > step_cs) gif.extend_pending_delay(std::min(tail_cs - step_cs, 300));
    }
    out_bytes = gif.finish();
  }
  reader.Reset();
  InterlockedExchange(&R.exporting, 0);
  if (SUCCEEDED(co)) CoUninitialize();

  if (cancelled) {
    rec_post("export-cancelled", total_ms, 0, 0, orig_bytes, 0, 0, "GIF", dst, "");
    return 0;
  }
  if (out_bytes > 0) {
    copy_file_to_clipboard(dst);
    rec_post("exported", total_ms, 0, out_bytes, orig_bytes, 100, 0, "GIF", dst, "");
  } else {
    DeleteFileW(dst.c_str());  // (a GIF begun and not finished: no half file left)
    rec_post("export-error", total_ms, 0, 0, orig_bytes, 0, 0, "GIF", dst, "生成 GIF 失败");
  }
  return 0;
}

// ---- MoonBit FFI exports ----

extern "C" {

int32_t ps_rec_prepare(int32_t x, int32_t y, int32_t w, int32_t h) {
  if (InterlockedCompareExchange(&R.running, 0, 0) != 0 || InterlockedCompareExchange(&R.exporting, 0, 0) != 0) return 0;
  rec_veil_hide();
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
  // (the clicks' and keys' overlay only told where: nothing of it is made until a recording asks for it)
  rec_draw_open(x, y, w, h);
  if (!getenv("PINSHOT_TEST_CLOAKED") || !getenv("PINSHOT_TEST_CLOAKED")[0]) {
    rec_veil_prepare();
    rec_frame_show(RGB(0x2F, 0x9B, 0xFF), 0, 1);
  }
  return 1;
}

void ps_rec_veil_fade(void) { rec_veil_start_fade(); }

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
  R.fps = fps < 10 ? 10 : (fps > 120 ? 120 : fps);
  R.cursor = cursor ? 1 : 0;
  R.want_audio = audio ? 1 : 0;
  InterlockedExchange(&R.stop_req, 0);
  InterlockedExchange(&R.pause_req, 0);
  if (!R.wake_ev) R.wake_ev = CreateEventW(NULL, FALSE, FALSE, NULL);
  ResetEvent(R.wake_ev);
  InterlockedExchange(&R.running, 1);
  LONG session = InterlockedCompareExchange(&R.session, 0, 0);
  R.rec_thread = CreateThread(NULL, 0, rec_worker, (LPVOID)(intptr_t)session, 0, NULL);
  if (!R.rec_thread) {
    InterlockedExchange(&R.running, 0);
    return 0;
  }
  // (the red frame and the overlay's hooks only once the worker is there: none left behind where it is not)
  rec_veil_start_fade();
  rec_frame_show(RGB(0xEF, 0x44, 0x44), 0, 0);
  rec_draw_set_recording(1);
  return 1;
}

void ps_rec_pause(int32_t on) {
  if (InterlockedCompareExchange(&R.running, 0, 0) == 0) return;
  int p = on ? 1 : 0;
  InterlockedExchange(&R.pause_req, p);
  if (R.wake_ev) SetEvent(R.wake_ev);
  rec_draw_set_recording(p ? 0 : 1);
  rec_frame_show(p ? RGB(0xF5, 0xA5, 0x24) : RGB(0xEF, 0x44, 0x44), p, 0);
}

void ps_rec_stop(int32_t cancel) {
  rec_veil_hide();
  rec_frame_hide();
  rec_draw_close();
  if (InterlockedCompareExchange(&R.running, 0, 0) == 0) return;
  InterlockedExchange(&R.stop_req, cancel ? 2 : 1);
  if (R.wake_ev) SetEvent(R.wake_ev);
}

int32_t ps_rec_export(moonbit_bytes_t dest_path, int32_t fmt, int32_t quality, int32_t max_side, int32_t gif_fps) {
  // (one called off a moment ago may still be letting go of its encoder: waited for, briefly)
  if (InterlockedCompareExchange(&R.exporting, 0, 0) != 0 && R.exp_thread &&
      WaitForSingleObject(R.exp_thread, 3000) != WAIT_OBJECT_0)
    return 0;
  if (InterlockedCompareExchange(&R.exporting, 0, 0) != 0) return 0;
  if (R.exp_thread) {
    CloseHandle(R.exp_thread);
    R.exp_thread = NULL;
  }
  int len = (int)Moonbit_array_length(dest_path);
  ExportJob *job = new ExportJob();
  job->dst = utf8_to_wide((const char *)dest_path, len);
  AcquireSRWLockShared(&R.lock);
  job->src = R.master_path;
  job->master_codec = R.master_codec;
  job->orig_bytes = R.master_bytes;
  job->total_ms = R.master_ms;
  job->src_w = R.master_w;
  job->src_h = R.master_h;
  job->src_fps = R.master_fps;
  job->src_audio = R.master_audio != 0;
  ReleaseSRWLockShared(&R.lock);
  if (job->src.empty() || job->dst.empty()) {
    delete job;
    return 0;
  }
  job->fmt = fmt;
  job->quality = quality;
  job->max_side = max_side;
  job->gif_fps = gif_fps;
  job->gen = InterlockedIncrement(&R.exp_gen);
  InterlockedExchange(&R.exporting, 1);
  R.exp_thread = CreateThread(NULL, 0, export_worker, job, 0, NULL);
  if (!R.exp_thread) {
    delete job;
    InterlockedExchange(&R.exporting, 0);
    return 0;
  }
  return 1;
}

// The export under way called off: its half file deleted by its worker, the recording kept ({"state":
// "export-cancelled"} told once it has stopped).
void ps_rec_export_cancel(void) { InterlockedIncrement(&R.exp_gen); }

int32_t ps_rec_reuse(moonbit_bytes_t src_path, moonbit_bytes_t dst_path) {
  int slen = (int)Moonbit_array_length(src_path);
  int dlen = (int)Moonbit_array_length(dst_path);
  std::wstring src = utf8_to_wide((const char *)src_path, slen);
  if (src.empty()) return 0;
  DWORD attr = GetFileAttributesW(src.c_str());
  if (attr == INVALID_FILE_ATTRIBUTES || (attr & FILE_ATTRIBUTE_DIRECTORY) || file_size_of(src) == 0)
    return 0;
  std::wstring dst = dlen > 0 ? utf8_to_wide((const char *)dst_path, dlen) : std::wstring();
  if (dst.empty() || _wcsicmp(src.c_str(), dst.c_str()) == 0) {
    copy_file_to_clipboard(src);
    return 1;
  }
  rec_make_dirs(dst);
  if (!CopyFileW(src.c_str(), dst.c_str(), FALSE)) return -1;
  copy_file_to_clipboard(dst);
  return 1;
}

// Whether a hardware AV1 encoder is here: -1 not known yet (asked now, on a thread of its own: its answer told as
// {"do":"rec-av1","on":0|1}), else 0 or 1. Never on the UI thread: Media Foundation's start and an MFT enumeration.
static volatile LONG g_av1 = -1;    // -1 not asked, -2 being asked, 0 / 1 known
static DWORD WINAPI av1_probe(LPVOID) {
  int here = 0;
  HRESULT co = CoInitializeEx(NULL, COINIT_MULTITHREADED);
  if (mf_begin()) {
    MFT_REGISTER_TYPE_INFO ot = {MFMediaType_Video, PS_MFVideoFormat_AV1};
    IMFActivate **acts = NULL;
    UINT32 cnt = 0;
    HRESULT hr = MFTEnumEx(MFT_CATEGORY_VIDEO_ENCODER,
                           MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_LOCALMFT | MFT_ENUM_FLAG_SORTANDFILTER, NULL, &ot,
                           &acts, &cnt);
    if (SUCCEEDED(hr) && acts) {
      for (UINT32 i = 0; i < cnt; i++)
        if (acts[i]) acts[i]->Release();
      CoTaskMemFree(acts);
    }
    here = (SUCCEEDED(hr) && cnt > 0) ? 1 : 0;
    mf_end();
  }
  if (SUCCEEDED(co)) CoUninitialize();
  InterlockedExchange(&g_av1, here);
  char buf[48];
  int n = snprintf(buf, sizeof buf, "{\"do\":\"rec-av1\",\"on\":%d}", here);
  if (n > 0) mb_post("ps", buf, (size_t)n, NULL, 0);
  return 0;
}

int32_t ps_rec_has_av1(void) {
  LONG v = InterlockedCompareExchange(&g_av1, 0, 0);
  if (v >= 0) return v;
  if (v == -1 && InterlockedCompareExchange(&g_av1, -2, -1) == -1) {
    HANDLE t = CreateThread(NULL, 0, av1_probe, NULL, 0, NULL);
    if (t) CloseHandle(t);
    else InterlockedExchange(&g_av1, 0);
  }
  return -1;
}

moonbit_bytes_t ps_rec_preview(void) {
  AcquireSRWLockShared(&R.lock);
  moonbit_bytes_t b = R.preview_bmp.empty() ? moonbit_make_bytes(0, 0)
                                            : rec_bytes_of(R.preview_bmp.data(), R.preview_bmp.size());
  ReleaseSRWLockShared(&R.lock);
  return b;
}

// What a panel ended leaves to let go once its workers are through: their threads waited for here, on a thread of
// its own (the UI thread never waits on an encoder's finishing), then the recording's file deleted.
struct EndedRec {
  HANDLE rec_thread, exp_thread;
  std::wstring master_path;
};

static DWORD WINAPI rec_reaper(LPVOID arg) {
  EndedRec *e = (EndedRec *)arg;
  if (e->rec_thread) {
    WaitForSingleObject(e->rec_thread, INFINITE);
    CloseHandle(e->rec_thread);
  }
  if (e->exp_thread) {
    WaitForSingleObject(e->exp_thread, INFINITE);
    CloseHandle(e->exp_thread);
  }
  if (!e->master_path.empty()) DeleteFileW(e->master_path.c_str());
  delete e;
  return 0;
}

void ps_rec_end(void) {
  rec_veil_hide();
  rec_frame_hide();
  rec_draw_close();
  // (another session from now: a recording still finishing keeps nothing of this one, an export is called off)
  AcquireSRWLockExclusive(&R.lock);
  InterlockedIncrement(&R.session);
  EndedRec *e = new EndedRec();
  e->master_path.swap(R.master_path);
  R.master_bytes = 0;
  R.preview_bmp.clear();
  R.preview_bmp.shrink_to_fit();
  ReleaseSRWLockExclusive(&R.lock);
  if (InterlockedCompareExchange(&R.running, 0, 0) != 0) {
    InterlockedExchange(&R.stop_req, 2);
    if (R.wake_ev) SetEvent(R.wake_ev);
  }
  InterlockedIncrement(&R.exp_gen);
  e->rec_thread = R.rec_thread;
  e->exp_thread = R.exp_thread;
  R.rec_thread = NULL;
  R.exp_thread = NULL;
  R.prepared = 0;
  if (!e->rec_thread && !e->exp_thread) {
    if (!e->master_path.empty()) DeleteFileW(e->master_path.c_str());
    delete e;
    return;
  }
  HANDLE t = CreateThread(NULL, 0, rec_reaper, e, 0, NULL);
  if (t) {
    CloseHandle(t);
  } else {
    rec_reaper(e);
  }
}

// The recordings' temporary files of runs no longer here (a run ended while it recorded, or killed): deleted as the
// run starts, on a thread of its own, never on the UI thread. "PinShot_rec_<pid>_<tick>.mp4": a pid that is not a
// running process is gone; one that is (this run's, or a test run's beside it) is left alone.
static DWORD WINAPI rec_sweep_work(LPVOID) {
  wchar_t tmp[MAX_PATH] = {}, pat[MAX_PATH + 32] = {};
  DWORD n = GetTempPathW(MAX_PATH, tmp);
  if (n == 0 || n >= MAX_PATH) return 0;
  swprintf_s(pat, L"%lsPinShot_rec_*.mp4", tmp);
  WIN32_FIND_DATAW fd;
  HANDLE f = FindFirstFileW(pat, &fd);
  if (f == INVALID_HANDLE_VALUE) return 0;
  do {
    unsigned long pid = wcstoul(fd.cFileName + wcslen(L"PinShot_rec_"), NULL, 10);
    bool alive = false;
    if (pid != 0) {
      HANDLE p = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, FALSE, (DWORD)pid);
      if (p) {
        alive = WaitForSingleObject(p, 0) == WAIT_TIMEOUT;
        CloseHandle(p);
      } else {
        alive = GetLastError() == ERROR_ACCESS_DENIED;  // (there, another user's: not ours to judge)
      }
    }
    if (!alive) {
      wchar_t full[MAX_PATH * 2];
      swprintf_s(full, L"%ls%ls", tmp, fd.cFileName);
      DeleteFileW(full);
    }
  } while (FindNextFileW(f, &fd));
  FindClose(f);
  return 0;
}

void ps_rec_sweep_temp(void) {
  // (a thread of its own that ends with it: no pool's thread kept waiting after)
  HANDLE t = CreateThread(NULL, 64 * 1024, rec_sweep_work, NULL, STACK_SIZE_PARAM_IS_A_RESERVATION, NULL);
  if (t) CloseHandle(t);
}

// The run ending (ps_quit): the recording kept for export deleted (a worker still writing one leaves it to the next
// run's sweep).
void ps_rec_quit(void) {
  AcquireSRWLockShared(&R.lock);
  std::wstring p = R.master_path;
  ReleaseSRWLockShared(&R.lock);
  if (!p.empty()) DeleteFileW(p.c_str());
}

extern void mb_app_next_clear(void);

void ps_next_win_clear(void) {
  mb_app_next_clear();
}

extern void mb_render_set_clear(int wid, int on);

void ps_rec_exclude(int32_t wid) {
  HWND h = (HWND)mb_app_hwnd_of(wid);
  if (!h) return;
  mb_render_set_clear(wid, 1);
  DWM_WINDOW_CORNER_PREFERENCE corner = DWMWCP_DONOTROUND;
  DwmSetWindowAttribute(h, DWMWA_WINDOW_CORNER_PREFERENCE, &corner, sizeof corner);
  COLORREF no_border = 0xFFFFFFFEu;  // DWMWA_COLOR_NONE
  DwmSetWindowAttribute(h, 34 /* DWMWA_BORDER_COLOR */, &no_border, sizeof no_border);
  const char *cl = getenv("PINSHOT_TEST_CLOAKED");
  if (!cl || !cl[0]) rec_exclude_hwnd(h);
}

}  // extern "C"
