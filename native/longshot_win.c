#define WIN32_LEAN_AND_MEAN
#define COBJMACROS
#include <windows.h>
#include <wincodec.h>
#include <dwmapi.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "moonbit.h"
#include "longshot_algo.h"

#pragma comment(lib, "windowscodecs.lib")
#pragma comment(lib, "dwmapi.lib")

#ifndef WDA_EXCLUDEFROMCAPTURE
#define WDA_EXCLUDEFROMCAPTURE 0x11
#endif

extern void mb_post(const char *channel, const char *json, size_t len, const uint8_t *bytes, size_t blen);
int ps_wgc_long_prime(HMONITOR mon, int w, int h);
int ps_wgc_long_take_dd(HMONITOR mon, int w, int h, int rx, int ry, int rw, int rh, int need_first,
                        uint8_t **bits, int *pitch, void **out_taken);
int ps_wgc_long_take(HMONITOR mon, int w, int h, int rx, int ry, int rw, int rh, int need_first,
                     uint64_t *seq, uint8_t **bits, int *pitch, void **out_taken);
void ps_wgc_release(void *taken);
void ps_wgc_long_hold(int on);
int ps_wgc_mon_hdr(HMONITOR mon, float *white);
int ps_wgc_borderless_ok(void);
int ps_capture_keep_on(void);
extern void ps_update_region_frame(HWND hwnd, int rx, int ry, int rw, int rh, COLORREF color, int dashed, int handles);
void ps_bmp_header(uint8_t h[54], int32_t w, int32_t hh);
extern void *mb_app_hwnd_of(int wid);
extern void mb_render_set_clear(int wid, int on);

typedef struct {
  int32_t ok;
  int32_t w, h, pitch;
  double take_ms;
  double white;
  int32_t said_half;
  int32_t need_first;
} LongWgcShmHeader;

typedef struct {
  uint8_t *base;
  int w;
  int lo, hi;
  volatile LONG refs;
} LongCanvas;

typedef struct {
  LongCanvas *canvas;
  size_t off;
  int w, h;
  int32_t req_id;
} LongExportJob;

#define TICK_MS 16
#define SETTLE_MS 180

static struct {
  int on;
  int x, y;
  HMONITOR mon;
  int mx, my, mw, mh;
  LongCanvas *canvas;
  LongCore core;
  HDC gdi_dc;
  HBITMAP gdi_bmp;
  HGDIOBJ gdi_old;
  void *gdi_bits;
  int use_gdi_only;
  int use_dd_only;
  int use_helper;
  int helper_first;
  int helper_fails;
  uint64_t take_seq;
  HANDLE h_shm, h_req, h_rsp, h_stop, h_proc;
  void *h_view;
  int paused;
  UINT_PTR timer;
  HWND frame;
  COLORREF frame_color;
  int frame_dashed;
  int told_h, told_lost, told_full, told_paused, told_pics, told_at, told_dir;
  ULONGLONG begun;
} L;

static UINT mon_dpi(HMONITOR mon) {
  UINT dx = 96, dy = 96;
  typedef HRESULT(WINAPI * GetDpiForMonitorFn)(HMONITOR, int, UINT *, UINT *);
  static GetDpiForMonitorFn dpi_of;
  static int tried;
  if (!tried) {
    tried = 1;
    HMODULE sh = LoadLibraryW(L"shcore.dll");
    if (sh) dpi_of = (GetDpiForMonitorFn)GetProcAddress(sh, "GetDpiForMonitor");
  }
  if (dpi_of) dpi_of(mon, 0, &dx, &dy);
  return dx ? dx : 96;
}

static LongCanvas *canvas_alloc(int w) {
  LongCanvas *cv = (LongCanvas *)calloc(1, sizeof *cv);
  if (!cv) return NULL;
  cv->base = (uint8_t *)VirtualAlloc(NULL, (size_t)LS_MOST_ROWS * 2 * (size_t)w * 4, MEM_RESERVE, PAGE_READWRITE);
  if (!cv->base) {
    free(cv);
    return NULL;
  }
  cv->w = w;
  cv->refs = 1;
  return cv;
}

static void canvas_release(LongCanvas *cv) {
  if (!cv) return;
  if (InterlockedDecrement(&cv->refs) == 0) {
    if (cv->base) VirtualFree(cv->base, 0, MEM_RELEASE);
    free(cv);
  }
}

static int win_commit(void *ctx, int lo, int hi) {
  (void)ctx;
  LongCanvas *cv = L.canvas;
  if (!cv || lo < 0 || hi > LS_MOST_ROWS * 2 || hi - lo > LS_MOST_ROWS) return 0;
  if (cv->hi > cv->lo && lo >= cv->lo && hi <= cv->hi) return 1;
  int nlo = cv->hi > cv->lo && cv->lo < lo ? cv->lo : lo - 1024;
  int nhi = cv->hi > cv->lo && cv->hi > hi ? cv->hi : hi + 1024;
  if (nlo < 0) nlo = 0;
  if (nhi > LS_MOST_ROWS * 2) nhi = LS_MOST_ROWS * 2;
  size_t row = (size_t)cv->w * 4;
  if (!VirtualAlloc(cv->base + (size_t)nlo * row, (size_t)(nhi - nlo) * row, MEM_COMMIT, PAGE_READWRITE)) return 0;
  cv->lo = nlo;
  cv->hi = nhi;
  return 1;
}

static COLORREF frame_want_color(void) {
  if (L.paused) return RGB(0x9E, 0xA4, 0xB2);
  if (L.core.full || L.core.lost) return RGB(0xF5, 0xA5, 0x24);
  return RGB(0x2F, 0x9B, 0xFF);
}

static void frame_sync_color(void) {
  COLORREF c = frame_want_color();
  int d = L.paused ? 1 : 0;
  if (c != L.frame_color || d != L.frame_dashed) {
    L.frame_color = c;
    L.frame_dashed = d;
    if (L.frame) ps_update_region_frame(L.frame, L.x, L.y, L.core.w, L.core.h, c, d, 0);
  }
}

static void tell(void) {
  frame_sync_color();
  int live_at = L.core.head_h + L.core.at;
  if (L.told_h == L.core.out_h && L.told_lost == L.core.lost && L.told_full == L.core.full &&
      L.told_paused == L.paused && L.told_pics == L.core.pictures && L.told_at == live_at &&
      L.told_dir == L.core.last_dir && L.core.pending_top == 0)
    return;
  L.told_h = L.core.out_h;
  L.told_lost = L.core.lost;
  L.told_full = L.core.full;
  L.told_paused = L.paused;
  L.told_pics = L.core.pictures;
  L.told_at = live_at;
  L.told_dir = L.core.last_dir;
  int top = L.core.pending_top;
  L.core.pending_top = 0;
  char json[192];
  int n = snprintf(json, sizeof json,
                   "{\"do\":\"long\",\"h\":%d,\"lost\":%d,\"full\":%d,\"paused\":%d,\"pics\":%d,\"dir\":%d,\"at\":%d,\"top\":%d}",
                   L.core.out_h, L.core.lost, L.core.full, L.paused, L.core.pictures, L.core.last_dir, live_at, top);
  mb_post("ps", json, (size_t)n, NULL, 0);
}

static moonbit_bytes_t bytes_of(const void *p, size_t n) {
  moonbit_bytes_t b = moonbit_make_bytes((int32_t)n, 0);
  if (n) memcpy(b, p, n);
  return b;
}

static LONG long_helper_seq;

static void long_helper_stop(void) {
  if (L.h_stop) SetEvent(L.h_stop);
  if (L.h_proc) {
    if (WaitForSingleObject(L.h_proc, 400) == WAIT_TIMEOUT) {
      TerminateProcess(L.h_proc, 1);
      WaitForSingleObject(L.h_proc, 100);
    }
    CloseHandle(L.h_proc);
    L.h_proc = NULL;
  }
  if (L.h_view) UnmapViewOfFile(L.h_view), L.h_view = NULL;
  if (L.h_shm) CloseHandle(L.h_shm), L.h_shm = NULL;
  if (L.h_req) CloseHandle(L.h_req), L.h_req = NULL;
  if (L.h_rsp) CloseHandle(L.h_rsp), L.h_rsp = NULL;
  if (L.h_stop) CloseHandle(L.h_stop), L.h_stop = NULL;
  L.use_helper = 0;
  L.helper_first = 0;
  L.helper_fails = 0;
}

static int long_helper_start(void) {
  long_helper_stop();
  size_t need = sizeof(LongWgcShmHeader) + (size_t)L.core.w * (size_t)L.core.h * 4;
  DWORD pid = GetCurrentProcessId();
  LONG seq = InterlockedIncrement(&long_helper_seq);
  wchar_t shm_n[64], req_n[64], rsp_n[64], stop_n[64];
  _snwprintf(shm_n, 63, L"Local\\PinShot.LongShm.%lu.%ld", pid, seq);
  _snwprintf(req_n, 63, L"Local\\PinShot.LongReq.%lu.%ld", pid, seq);
  _snwprintf(rsp_n, 63, L"Local\\PinShot.LongRsp.%lu.%ld", pid, seq);
  _snwprintf(stop_n, 63, L"Local\\PinShot.LongStop.%lu.%ld", pid, seq);
  shm_n[63] = req_n[63] = rsp_n[63] = stop_n[63] = 0;

  L.h_shm = CreateFileMappingW(INVALID_HANDLE_VALUE, NULL, PAGE_READWRITE, (DWORD)(need >> 32), (DWORD)need, shm_n);
  if (L.h_shm) L.h_view = MapViewOfFile(L.h_shm, FILE_MAP_ALL_ACCESS, 0, 0, need);
  L.h_req = CreateEventW(NULL, FALSE, FALSE, req_n);
  L.h_rsp = CreateEventW(NULL, FALSE, FALSE, rsp_n);
  L.h_stop = CreateEventW(NULL, TRUE, FALSE, stop_n);
  wchar_t exe[MAX_PATH * 2];
  if (!L.h_view || !L.h_req || !L.h_rsp || !L.h_stop || GetModuleFileNameW(NULL, exe, MAX_PATH * 2) == 0) {
    long_helper_stop();
    return 0;
  }
  wchar_t cmd[MAX_PATH * 2 + 320];
  _snwprintf(cmd, MAX_PATH * 2 + 319, L"\"%ls\" --wgc-long %ls %ls %ls %ls %lu %d %d %d %d %d %d %d %d", exe, shm_n,
             req_n, rsp_n, stop_n, (unsigned long)pid, L.mx, L.my, L.mw, L.mh, L.x - L.mx, L.y - L.my, L.core.w, L.core.h);
  cmd[MAX_PATH * 2 + 319] = 0;
  STARTUPINFOW si;
  PROCESS_INFORMATION pi;
  memset(&si, 0, sizeof si);
  memset(&pi, 0, sizeof pi);
  si.cb = sizeof si;
  if (!CreateProcessW(exe, cmd, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, NULL, &si, &pi)) {
    long_helper_stop();
    return 0;
  }
  CloseHandle(pi.hThread);
  L.h_proc = pi.hProcess;
  L.use_helper = 1;
  L.helper_first = 1;
  L.helper_fails = 0;
  return 1;
}

static void long_capture_fallback_low_vram(void) {
  float white = 1.0f;
  if (ps_wgc_mon_hdr(L.mon, &white) && ps_wgc_borderless_ok()) {
    if (long_helper_start()) return;
  }
  L.use_gdi_only = 1;
}

static void long_capture_begin(void) {
  L.use_gdi_only = 0;
  L.use_dd_only = 0;
  L.take_seq = 0;
  if (ps_capture_keep_on()) {
    ps_wgc_long_hold(1);
    ps_wgc_long_prime(L.mon, L.mw, L.mh);
    return;
  }
  ps_wgc_long_hold(1);
  if (ps_wgc_long_prime(L.mon, L.mw, L.mh)) {
    L.use_dd_only = 1;
    return;
  }
  ps_wgc_long_hold(0);
  long_capture_fallback_low_vram();
}

static void long_capture_end(void) {
  if (L.use_helper) long_helper_stop();
  else if (L.on && !L.use_gdi_only) ps_wgc_long_hold(0);
  L.use_gdi_only = 0;
  L.use_dd_only = 0;
  L.take_seq = 0;
}

static int take_now(void) {
  int need_first = L.core.pictures == 0 ? 1 : 0;
  if (L.use_helper && L.h_view && L.h_req && L.h_rsp && L.h_proc) {
    LongWgcShmHeader *hdr = (LongWgcShmHeader *)L.h_view;
    hdr->ok = 0;
    hdr->need_first = need_first;
    ResetEvent(L.h_rsp);
    SetEvent(L.h_req);
    HANDLE waits[2] = {L.h_rsp, L.h_proc};
    DWORD ms = L.helper_first ? 1200 : 350;
    L.helper_first = 0;
    DWORD wr = WaitForMultipleObjects(2, waits, FALSE, ms);
    if (wr == WAIT_OBJECT_0) {
      if (hdr->ok == 2) {
        L.helper_fails = 0;
        return 0;
      }
      if (hdr->ok == 1 && hdr->w == L.core.w && hdr->h == L.core.h && hdr->pitch >= L.core.w * 4) {
        const uint8_t *src = (const uint8_t *)hdr + sizeof(LongWgcShmHeader);
        if (hdr->pitch == L.core.w * 4) {
          memcpy(L.core.now, src, (size_t)L.core.w * (size_t)L.core.h * 4);
        } else {
          for (int y = 0; y < L.core.h; y++)
            memcpy(L.core.now + (size_t)y * (size_t)L.core.w * 4, src + (size_t)y * (size_t)hdr->pitch,
                   (size_t)L.core.w * 4);
        }
        L.helper_fails = 0;
        return 1;
      }
      if (++L.helper_fails < 3) return 0;
    }
    long_helper_stop();
    L.use_gdi_only = 1;
    return 0;
  }
  if (L.use_dd_only) {
    uint8_t *bits = NULL;
    int pitch = 0;
    void *t = NULL;
    int rc = ps_wgc_long_take_dd(L.mon, L.mw, L.mh, L.x - L.mx, L.y - L.my, L.core.w, L.core.h, need_first,
                                 &bits, &pitch, &t);
    if (rc == 1 && t) {
      for (int y = 0; y < L.core.h; y++)
        memcpy(L.core.now + (size_t)y * (size_t)L.core.w * 4, bits + (size_t)y * (size_t)pitch, (size_t)L.core.w * 4);
      ps_wgc_release(t);
      return 1;
    }
    if (rc == 0) return 0;
    L.use_dd_only = 0;
    ps_wgc_long_hold(0);
    long_capture_fallback_low_vram();
    return 0;
  }
  if (!L.use_gdi_only) {
    uint8_t *bits = NULL;
    int pitch = 0;
    void *t = NULL;
    int rc = ps_wgc_long_take(L.mon, L.mw, L.mh, L.x - L.mx, L.y - L.my, L.core.w, L.core.h, need_first,
                              &L.take_seq, &bits, &pitch, &t);
    if (rc == 1 && t) {
      for (int y = 0; y < L.core.h; y++)
        memcpy(L.core.now + (size_t)y * (size_t)L.core.w * 4, bits + (size_t)y * (size_t)pitch, (size_t)L.core.w * 4);
      ps_wgc_release(t);
      return 1;
    }
    if (rc == 0) return 0;
  }
  HDC screen = GetDC(NULL);
  if (!L.gdi_dc) {
    BITMAPINFO bi;
    memset(&bi, 0, sizeof bi);
    bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bi.bmiHeader.biWidth = L.core.w;
    bi.bmiHeader.biHeight = -L.core.h;
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = BI_RGB;
    L.gdi_dc = CreateCompatibleDC(screen);
    L.gdi_bmp = L.gdi_dc ? CreateDIBSection(screen, &bi, DIB_RGB_COLORS, &L.gdi_bits, NULL, 0) : NULL;
    if (L.gdi_bmp && L.gdi_bits) L.gdi_old = SelectObject(L.gdi_dc, L.gdi_bmp);
  }
  int ok = 0;
  if (L.gdi_old) {
    ok = BitBlt(L.gdi_dc, 0, 0, L.core.w, L.core.h, screen, L.x, L.y, SRCCOPY) != 0;
    GdiFlush();
    if (ok) memcpy(L.core.now, L.gdi_bits, (size_t)L.core.w * (size_t)L.core.h * 4);
  }
  ReleaseDC(NULL, screen);
  return ok;
}

static void gdi_let_go(void) {
  if (L.gdi_dc && L.gdi_old) SelectObject(L.gdi_dc, L.gdi_old);
  if (L.gdi_bmp) DeleteObject(L.gdi_bmp);
  if (L.gdi_dc) DeleteDC(L.gdi_dc);
  L.gdi_dc = NULL, L.gdi_bmp = NULL, L.gdi_old = NULL, L.gdi_bits = NULL;
}

static FILE *dump_log;
static int dumped;
static uint64_t dumped_hash;
static void win_dump(void *ctx, const char *what, int a, int b, int c, int d) {
  (void)ctx;
  const char *dir = getenv("PINSHOT_LONG_DUMP");
  if (!dir) return;
  char path[MAX_PATH];
  if (!dump_log) {
    snprintf(path, sizeof path, "%s\\long.log", dir);
    dump_log = fopen(path, "w");
  }
  uint64_t hv = 0;
  for (int y = 0; y < L.core.h; y++) hv = hv * 31 + L.core.now_hash[y];
  if (dump_log) {
    fprintf(dump_log, "%llu %s %d %d %d %d (picture %d, h %d)\n", GetTickCount64() - L.begun, what, a, b, c, d,
            hv == dumped_hash ? dumped - 1 : dumped, L.core.out_h);
    fflush(dump_log);
  }
  if (hv == dumped_hash || dumped >= 80) return;
  dumped_hash = hv;
  snprintf(path, sizeof path, "%s\\%03d.bmp", dir, dumped++);
  FILE *f = fopen(path, "wb");
  if (!f) return;
  BITMAPFILEHEADER fh = {0x4D42, (DWORD)(54 + (size_t)L.core.w * (size_t)L.core.h * 4), 0, 0, 54};
  BITMAPINFOHEADER ih = {sizeof ih, L.core.w, -L.core.h, 1, 32, BI_RGB, 0, 0, 0, 0, 0};
  fwrite(&fh, sizeof fh, 1, f);
  fwrite(&ih, sizeof ih, 1, f);
  fwrite(L.core.now, (size_t)L.core.w * (size_t)L.core.h * 4, 1, f);
  fclose(f);
}

static void tick(void) {
  if (!L.on || L.paused || L.core.full) return;
  if (GetTickCount64() - L.begun < SETTLE_MS) return;
  if (!take_now()) return;
  if (ls_step(&L.core)) tell();
}

static void CALLBACK tick_timer(HWND h, UINT msg, UINT_PTR id, DWORD t) {
  (void)h, (void)msg, (void)id, (void)t;
  tick();
}

static LRESULT CALLBACK frame_proc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
  if (msg == WM_NCHITTEST) return HTTRANSPARENT;
  return DefWindowProcW(h, msg, wp, lp);
}

static void exclude(HWND h) {
  if (!getenv("PINSHOT_LONG_SHOW")) SetWindowDisplayAffinity(h, WDA_EXCLUDEFROMCAPTURE);
}

static void frame_show(void) {
  if (getenv("PINSHOT_TEST") && getenv("PINSHOT_TEST_CLOAKED")) return;
  static int made;
  if (!made) {
    WNDCLASSEXW wc = {sizeof wc};
    wc.lpfnWndProc = frame_proc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = L"PinShot.LongFrame";
    wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    RegisterClassExW(&wc);
    made = 1;
  }
  L.frame = CreateWindowExW(WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
                            L"PinShot.LongFrame", L"", WS_POPUP, L.x, L.y, 16, 16, NULL, NULL, GetModuleHandleW(NULL), NULL);
  if (!L.frame) return;
  exclude(L.frame);
  ps_update_region_frame(L.frame, L.x, L.y, L.core.w, L.core.h, L.frame_color ? L.frame_color : RGB(0x2F, 0x9B, 0xFF),
                         L.frame_dashed, 0);
  ShowWindow(L.frame, SW_SHOWNOACTIVATE);
}

static void let_go(void) {
  long_capture_end();
  if (dump_log) fclose(dump_log);
  dump_log = NULL, dumped = 0, dumped_hash = 0;
  if (L.timer) KillTimer(NULL, L.timer);
  if (L.frame) DestroyWindow(L.frame);
  canvas_release(L.canvas);
  ls_work_free(&L.core);
  gdi_let_go();
  memset(&L, 0, sizeof L);
}

int32_t ps_long_begin(int32_t x, int32_t y, int32_t w, int32_t h) {
  let_go();
  if (w < 16 || h < LS_LEAST_OVERLAP * 3) return 0;
  POINT c = {x + w / 2, y + h / 2};
  HMONITOR mon = MonitorFromPoint(c, MONITOR_DEFAULTTONEAREST);
  MONITORINFO mi = {sizeof mi};
  if (!GetMonitorInfoW(mon, &mi)) return 0;
  if (x < mi.rcMonitor.left) w -= mi.rcMonitor.left - x, x = mi.rcMonitor.left;
  if (y < mi.rcMonitor.top) h -= mi.rcMonitor.top - y, y = mi.rcMonitor.top;
  if (x + w > mi.rcMonitor.right) w = mi.rcMonitor.right - x;
  if (y + h > mi.rcMonitor.bottom) h = mi.rcMonitor.bottom - y;
  if (w < 16 || h < LS_LEAST_OVERLAP * 3) return 0;
  L.x = x, L.y = y;
  L.mon = mon;
  L.mx = mi.rcMonitor.left, L.my = mi.rcMonitor.top;
  L.mw = mi.rcMonitor.right - mi.rcMonitor.left, L.mh = mi.rcMonitor.bottom - mi.rcMonitor.top;
  int gutter = (int)(18.0 * (double)mon_dpi(mon) / 96.0 + 0.5);
  L.core.w = w;
  L.core.h = h;
  L.core.hw = ls_compute_hw(w, gutter);
  L.core.strips = ls_compute_strips(L.core.hw);
  L.core.commit_fn = win_commit;
  L.core.dump_fn = win_dump;
  L.canvas = canvas_alloc(w);
  if (!L.canvas || !ls_work_alloc(&L.core)) {
    let_go();
    return 0;
  }
  L.core.base = L.canvas->base;
  ls_reset_state(&L.core);
  L.on = 1;
  L.told_h = -1;
  L.frame_color = RGB(0x2F, 0x9B, 0xFF);
  long_capture_begin();
  L.begun = GetTickCount64();
  frame_show();
  L.timer = SetTimer(NULL, 0, TICK_MS, tick_timer);
  return 1;
}

void ps_long_pause(int32_t on) {
  if (!L.on) return;
  int p = on ? 1 : 0;
  if (L.paused == p) return;
  L.paused = p;
  if (L.paused) {
    if (L.timer) KillTimer(NULL, L.timer);
    L.timer = 0;
  } else {
    if (!L.timer && !L.core.full) L.timer = SetTimer(NULL, 0, TICK_MS, tick_timer);
  }
  tell();
}

void ps_long_reset(void) {
  if (!L.canvas || !ls_work_alloc(&L.core)) return;
  if (InterlockedCompareExchange(&L.canvas->refs, 1, 1) > 1) {
    LongCanvas *fresh = canvas_alloc(L.core.w);
    if (!fresh) return;
    canvas_release(L.canvas);
    L.canvas = fresh;
    L.core.base = fresh->base;
  } else if (L.canvas->hi > L.canvas->lo) {
    VirtualFree(L.canvas->base + (size_t)L.canvas->lo * (size_t)L.core.w * 4,
                (size_t)(L.canvas->hi - L.canvas->lo) * (size_t)L.core.w * 4, MEM_DECOMMIT);
    L.canvas->lo = L.canvas->hi = 0;
  }
  ls_reset_state(&L.core);
  L.paused = 0;
  L.told_h = -1;
  L.take_seq = 0;
  L.helper_fails = 0;
  if (!L.on) {
    L.on = 1;
    long_capture_begin();
  }
  if (!L.frame) frame_show();
  L.begun = GetTickCount64() - SETTLE_MS;
  if (!L.timer) L.timer = SetTimer(NULL, 0, TICK_MS, tick_timer);
  tell();
}

void ps_long_stop(void) {
  long_capture_end();
  L.on = 0;
  if (L.timer) KillTimer(NULL, L.timer);
  L.timer = 0;
  if (L.frame) DestroyWindow(L.frame);
  L.frame = NULL;
  ls_work_free(&L.core);
  gdi_let_go();
}

void ps_long_exclude(int32_t wid) {
  HWND h = (HWND)mb_app_hwnd_of(wid);
  if (!h) return;
  mb_render_set_clear(wid, 1);
  DWM_WINDOW_CORNER_PREFERENCE corner = DWMWCP_DONOTROUND;
  DwmSetWindowAttribute(h, DWMWA_WINDOW_CORNER_PREFERENCE, &corner, sizeof corner);
  COLORREF no_border = 0xFFFFFFFEu;
  DwmSetWindowAttribute(h, 34, &no_border, sizeof no_border);
  exclude(h);
}

void ps_long_end(void) { let_go(); }

moonbit_bytes_t ps_long_info(void) {
  if (!L.core.out_h) return moonbit_make_bytes(0, 0);
  char s[96];
  int n = snprintf(s, sizeof s, "%d,%d,%d,%d,%d", L.core.w, L.core.out_h, L.core.pictures, L.core.lost, L.core.full);
  return bytes_of(s, (size_t)n);
}

void ps_long_preview_free(void) {}

moonbit_bytes_t ps_long_preview(int32_t box_w, int32_t box_h, int32_t from_row) {
  int from = 0, src_h = 0, pw = 0, ph = 0;
  if (!ls_preview_dims(&L.core, box_w, box_h, from_row, &from, &src_h, &pw, &ph)) return moonbit_make_bytes(0, 0);
  moonbit_bytes_t out = moonbit_make_bytes((int32_t)(54 + (size_t)pw * (size_t)ph * 4), 0);
  ps_bmp_header(out, pw, ph);
  ls_preview_render(&L.core, from, src_h, pw, ph, out + 54);
  return out;
}

static int encode_png_bgra(uint8_t *px, int w, int h, uint8_t **out_buf, size_t *out_len) {
  *out_buf = NULL;
  *out_len = 0;
  if (!px || w <= 0 || h <= 0) return 0;
  for (size_t i = 0; i < (size_t)w * (size_t)h; i++) px[i * 4 + 3] = 255;
  HRESULT co = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
  IWICImagingFactory *f = NULL;
  IStream *st = NULL;
  IWICBitmapEncoder *enc = NULL;
  IWICBitmapFrameEncode *fr = NULL;
  int ok = 0;
  WICPixelFormatGUID fmt = GUID_WICPixelFormat32bppBGRA;
  if (SUCCEEDED(CoCreateInstance(&CLSID_WICImagingFactory, NULL, CLSCTX_INPROC_SERVER, &IID_IWICImagingFactory,
                                 (void **)&f)) &&
      SUCCEEDED(CreateStreamOnHGlobal(NULL, TRUE, &st)) &&
      SUCCEEDED(IWICImagingFactory_CreateEncoder(f, &GUID_ContainerFormatPng, NULL, &enc)) &&
      SUCCEEDED(IWICBitmapEncoder_Initialize(enc, st, WICBitmapEncoderNoCache)) &&
      SUCCEEDED(IWICBitmapEncoder_CreateNewFrame(enc, &fr, NULL)) && SUCCEEDED(IWICBitmapFrameEncode_Initialize(fr, NULL)) &&
      SUCCEEDED(IWICBitmapFrameEncode_SetSize(fr, (UINT)w, (UINT)h)) &&
      SUCCEEDED(IWICBitmapFrameEncode_SetPixelFormat(fr, &fmt)) &&
      SUCCEEDED(IWICBitmapFrameEncode_WritePixels(fr, (UINT)h, (UINT)w * 4, (UINT)((size_t)w * (size_t)h * 4), px)) &&
      SUCCEEDED(IWICBitmapFrameEncode_Commit(fr)) && SUCCEEDED(IWICBitmapEncoder_Commit(enc))) {
    HGLOBAL g = NULL;
    if (SUCCEEDED(GetHGlobalFromStream(st, &g))) {
      STATSTG ss;
      if (SUCCEEDED(IStream_Stat(st, &ss, STATFLAG_NONAME)) && ss.cbSize.QuadPart > 0) {
        void *p = GlobalLock(g);
        if (p) {
          size_t n = (size_t)ss.cbSize.QuadPart;
          uint8_t *buf = (uint8_t *)malloc(n);
          if (buf) {
            memcpy(buf, p, n);
            *out_buf = buf;
            *out_len = n;
            ok = 1;
          }
          GlobalUnlock(g);
        }
      }
    }
  }
  if (fr) IWICBitmapFrameEncode_Release(fr);
  if (enc) IWICBitmapEncoder_Release(enc);
  if (st) IStream_Release(st);
  if (f) IWICImagingFactory_Release(f);
  if (SUCCEEDED(co)) CoUninitialize();
  return ok;
}

moonbit_bytes_t ps_long_png(void) {
  if (!L.core.out_h || !L.core.out) return moonbit_make_bytes(0, 0);
  uint8_t *buf = NULL;
  size_t len = 0;
  if (!encode_png_bgra(L.core.out, L.core.w, L.core.out_h, &buf, &len)) return moonbit_make_bytes(0, 0);
  moonbit_bytes_t got = bytes_of(buf, len);
  free(buf);
  return got;
}

static DWORD WINAPI export_thread(void *arg) {
  LongExportJob *job = (LongExportJob *)arg;
  uint8_t *buf = NULL;
  size_t len = 0;
  int ok = encode_png_bgra(job->canvas->base + job->off, job->w, job->h, &buf, &len);
  char json[128];
  int n = snprintf(json, sizeof json, "{\"do\":\"long-png\",\"id\":%d,\"w\":%d,\"h\":%d,\"ok\":%d}", job->req_id,
                   job->w, job->h, ok);
  mb_post("ps", json, (size_t)n, ok ? buf : NULL, ok ? len : 0);
  free(buf);
  canvas_release(job->canvas);
  free(job);
  return 0;
}

int32_t ps_long_export(int32_t req_id) {
  if (!L.canvas || !L.core.out || L.core.out_h <= 0) return 0;
  ps_long_stop();
  LongExportJob *job = (LongExportJob *)malloc(sizeof *job);
  if (!job) return 0;
  InterlockedIncrement(&L.canvas->refs);
  job->canvas = L.canvas;
  job->off = (size_t)(L.core.out - L.canvas->base);
  job->w = L.core.w;
  job->h = L.core.out_h;
  job->req_id = req_id;
  HANDLE t = CreateThread(NULL, 0, export_thread, job, 0, NULL);
  if (!t) {
    canvas_release(job->canvas);
    free(job);
    return 0;
  }
  CloseHandle(t);
  return 1;
}
