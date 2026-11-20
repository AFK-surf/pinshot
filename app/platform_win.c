// PinShot's Windows side (platform.mbt says what each call is; a Mac's platform_mac.m answers the same calls). What
// is the system's and nothing of the UI: the one run per person, the notification area's icon and its menu, the global
// shortcuts, the screen frozen as a picture and the windows on it, how PinShot's own windows stand (the capture
// overlay, each pin: no frame, over the others, where and how big in the screen's pixels), and files.
//
// What happens outside the frames (a shortcut pressed, the icon clicked, its menu chosen) is told the app on its
// channel "ps" (mb_post: @ui.on_message_said), as JSON: {"do":"capture"}, {"do":"menu","item":"settings"}, ...
// The screen is taken as the shortcut is pressed, here, before the app is told: the picture is of the moment it was
// asked for, whatever the app's frames do meanwhile.
#define WIN32_LEAN_AND_MEAN
#define COBJMACROS
#include <windows.h>
#include <windowsx.h>
#include <commctrl.h>
#include <dwmapi.h>
#include <shellapi.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <psapi.h>
#include <d3d11.h>
#include <dxgi1_3.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <mmsystem.h>
#include <wtsapi32.h>
#include "moonbit.h"

#pragma comment(lib, "user32.lib")
#pragma comment(lib, "gdi32.lib")
#pragma comment(lib, "dwmapi.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "uuid.lib")
#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "comctl32.lib")
#pragma comment(lib, "dxguid.lib")
#pragma comment(lib, "winmm.lib")
#pragma comment(lib, "wtsapi32.lib")

// (mbui's Windows host, linked in the same program)
extern void mb_post(const char *channel, const char *json, size_t len, const uint8_t *bytes, size_t blen);
extern void *mb_app_hwnd_of(int wid);

// ---- small things ----

static moonbit_bytes_t ps_bytes(const void *p, size_t n) {
  moonbit_bytes_t b = moonbit_make_bytes((int32_t)n, 0);
  if (n > 0 && p) memcpy(b, p, n);
  return b;
}

static moonbit_bytes_t ps_text(const char *s) { return ps_bytes(s, strlen(s)); }

static wchar_t *ps_wide(const char *utf8) {
  int n = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, NULL, 0);
  wchar_t *w = (wchar_t *)malloc(sizeof(wchar_t) * (n > 0 ? n : 1));
  if (n > 0) MultiByteToWideChar(CP_UTF8, 0, utf8, -1, w, n);
  else w[0] = 0;
  return w;
}

static moonbit_bytes_t ps_utf8_bytes(const wchar_t *w) {
  int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, NULL, 0, NULL, NULL);
  if (n <= 1) return moonbit_make_bytes(0, 0);
  moonbit_bytes_t b = moonbit_make_bytes(n - 1, 0);
  WideCharToMultiByte(CP_UTF8, 0, w, -1, (char *)b, n - 1, NULL, NULL);
  return b;
}

static void ps_tell(const char *json) { mb_post("ps", json, strlen(json), NULL, 0); }

static double ps_ms(void) {
  static LARGE_INTEGER f;
  LARGE_INTEGER t;
  if (!f.QuadPart) QueryPerformanceFrequency(&f);
  QueryPerformanceCounter(&t);
  return (double)t.QuadPart * 1000.0 / (double)f.QuadPart;
}

double ps_now_ms(void) { return ps_ms(); }

// ---- the screen, frozen ----
//
// The monitor the pointer is on, taken whole into a DIB section of its own (rows from the top, 32 bits a pixel, BGRX)
// on a thread of its own (GDI's BitBlt of the screen: what DWM composes, SDR; ~45-70 ms for 4K with HDR on), so the
// overlay is put up at the monitor's size meanwhile: the app is told {"do":"prepare",...} as the shortcut is pressed
// and {"do":"capture",...} once the picture is there. The pixels stay here, in the section, never copied: the app is
// handed where they are (ps_capture_take: mbui makes the texture from there, patches/mbui-pinshot.patch), reads them
// here (ps_pixel, ps_mean), and lets them go as the capture closes (ps_capture_release), the section freed a moment
// later (a decode that might still read it done by then).

#define WM_PS_TAKEN (WM_APP + 42)
#define PS_FREE_TIMER 7
#define PS_WGC_TIMER 8  // the captures made again a moment after the monitors wake (tray_proc)
static int wgc_off;     // PINSHOT_CAPTURE=gdi: no capture kept
// GUID_CONSOLE_DISPLAY_STATE (the monitors off 0, on 1, dimmed 2)
static const GUID display_state_guid = {0x6fe69556, 0x704a, 0x47a0, {0x8f, 0x24, 0xc2, 0x8d, 0x93, 0x6f, 0xda, 0x47}};

typedef struct {
  HBITMAP dib;    // GDI's section, or
  void *staging;  // the system capture's texture (capture_wgc.cpp), mapped
  uint8_t *bits;
  int w, h, pitch;
} Shot;

// (capture_wgc.cpp)
int ps_wgc_restart(void);
void *ps_wgc_take_now(HMONITOR mon, int w, int h, uint8_t **bits, int *pitch);
void ps_wgc_release(void *taken);
static HMONITOR cap_mon;

static Shot cap;               // the picture being taken or taken
static Shot cap_old[4];        // pictures let go, freed at the timer
static volatile LONG cap_busy;  // a taking under way (its thread fills cap)
static int cap_ok;              // the last taking's outcome
static int cap_x, cap_y, cap_w, cap_h, cap_dpi;
static double cap_t0, cap_ms, cap_key_lag;  // when it was asked, how long the taking took, how long WM_HOTKEY waited
static int keep_gpu_warm = 1;               // 1: keep driver pools warm between captures (Instant mode)
static HWND tray_hwnd;
static char *win_list;  // the windows on the monitor as it was taken (ps_windows)
static size_t win_list_len;
static void windows_listed(void);

static void shot_free(Shot *s) {
  if (s->dib) DeleteObject(s->dib);
  if (s->staging) ps_wgc_release(s->staging);
  memset(s, 0, sizeof *s);
}

static int monitor_under_pointer(void) {
  // (the screen's own pixels, whoever asks first: the run sets it as it starts, a bench does not start one)
  static int aware;
  if (!aware) aware = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) || 1;
  POINT p;
  GetCursorPos(&p);
  HMONITOR mon = MonitorFromPoint(p, MONITOR_DEFAULTTONEAREST);
  MONITORINFO mi = {sizeof mi};
  if (!GetMonitorInfoW(mon, &mi)) return 0;
  int w = mi.rcMonitor.right - mi.rcMonitor.left, h = mi.rcMonitor.bottom - mi.rcMonitor.top;
  if (w <= 0 || h <= 0) return 0;
  UINT dx = 96, dy = 96;
  typedef HRESULT(WINAPI * GetDpiForMonitorFn)(HMONITOR, int, UINT *, UINT *);
  static GetDpiForMonitorFn dpi_of;
  if (!dpi_of) {
    HMODULE sh = LoadLibraryW(L"shcore.dll");
    if (sh) dpi_of = (GetDpiForMonitorFn)GetProcAddress(sh, "GetDpiForMonitor");
  }
  if (dpi_of) dpi_of(mon, 0, &dx, &dy);
  cap_x = mi.rcMonitor.left, cap_y = mi.rcMonitor.top, cap_w = w, cap_h = h, cap_dpi = (int)dx;
  cap_mon = mon;
  return 1;
}

// The taking itself, on its own thread: BitBlt into the section made for it.
static DWORD WINAPI cap_work(void *arg) {
  (void)arg;
  int ok = 0;
  HDC screen = GetDC(NULL);
  HDC mem = CreateCompatibleDC(screen);
  if (cap.dib) {
    HGDIOBJ old = SelectObject(mem, cap.dib);
    ok = BitBlt(mem, 0, 0, cap_w, cap_h, screen, cap_x, cap_y, SRCCOPY) != 0;
    SelectObject(mem, old);
    GdiFlush();
  }
  DeleteDC(mem);
  ReleaseDC(NULL, screen);
  cap_ok = ok;
  cap_ms = ps_ms() - cap_t0;
  InterlockedExchange(&cap_busy, 0);
  if (tray_hwnd) PostMessageW(tray_hwnd, WM_PS_TAKEN, (WPARAM)ok, 0);
  return 0;
}

// A taking begun (the UI thread's): the monitor found, its section made, the windows on it listed, the work handed
// to its thread. 0 where one is under way already or there is no monitor.
static int gdi_begin(void);

static int cap_begin(void) {
  if (cap_busy) return 0;
  cap_t0 = ps_ms();
  if (!monitor_under_pointer()) return 0;
  // (one not taken by the app, or kept: gone)
  shot_free(&cap);
  windows_listed();
  cap_ok = 0;
  // (the system's capture kept on: the monitor's last frame, there already; GDI's where it has had none yet)
  uint8_t *bits = NULL;
  int pitch = 0;
  void *t = ps_wgc_take_now(cap_mon, cap_w, cap_h, &bits, &pitch);
  if (t && tray_hwnd) {
    cap.staging = t;
    cap.bits = bits;
    cap.w = cap_w, cap.h = cap_h, cap.pitch = pitch;
    cap_ok = 1;
    cap_ms = ps_ms() - cap_t0;
    PostMessageW(tray_hwnd, WM_PS_TAKEN, 1, 0);
    return 1;
  }
  if (t) ps_wgc_release(t);
  return gdi_begin();
}

// GDI's taking begun: its section made, the work handed to its thread.
static int gdi_begin(void) {
  BITMAPINFO bi;
  memset(&bi, 0, sizeof bi);
  bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bi.bmiHeader.biWidth = cap_w;
  bi.bmiHeader.biHeight = -cap_h;  // rows from the top
  bi.bmiHeader.biPlanes = 1;
  bi.bmiHeader.biBitCount = 32;
  bi.bmiHeader.biCompression = BI_RGB;
  void *bits = NULL;
  cap.dib = CreateDIBSection(NULL, &bi, DIB_RGB_COLORS, &bits, NULL, 0);
  if (!cap.dib || !bits) {
    shot_free(&cap);
    return 0;
  }
  cap.bits = (uint8_t *)bits;
  cap.w = cap_w, cap.h = cap_h, cap.pitch = cap_w * 4;
  InterlockedExchange(&cap_busy, 1);
  HANDLE t = CreateThread(NULL, 0, cap_work, NULL, 0, NULL);
  if (!t) {
    InterlockedExchange(&cap_busy, 0);
    shot_free(&cap);
    return 0;
  }
  CloseHandle(t);
  return 1;
}

// The screen taken now, waited for here (a bench): 1 when taken.
static void tray_window_made(void);

int32_t ps_capture_now(void) {
  tray_window_made();
  if (!cap_begin()) return 0;
  // (what the capture posts the tray window handled here; its WM_PS_TAKEN dropped: it was waited for)
  MSG m;
  while (cap_busy) {
    if (PeekMessageW(&m, tray_hwnd, 0, 0, PM_REMOVE)) {
      if (m.message != WM_PS_TAKEN) DispatchMessageW(&m);
    } else {
      MsgWaitForMultipleObjects(0, NULL, FALSE, 1, QS_ALLINPUT);
    }
  }
  while (PeekMessageW(&m, tray_hwnd, WM_PS_TAKEN, WM_PS_TAKEN, PM_REMOVE)) {
  }
  return cap_ok;
}

// What was taken: "x,y,w,h,dpi,ms,how" (the monitor in the screen's pixels, its DPI, how long the taking took, and
// by what: "wgc copy MS" or "gdi"); "" none.
void ps_wgc_timing(double *out);
void ps_wgc_state(char *out, int n);
moonbit_bytes_t ps_capture_info(void) {
  if (!cap.bits || cap_busy) return moonbit_make_bytes(0, 0);
  char s[320], lag[48] = {0};
  if (cap_key_lag >= 10.0) snprintf(lag, sizeof lag, "; key lag %.0f ms", cap_key_lag);
  if (cap.staging) {
    double t[5];
    ps_wgc_timing(t);
    snprintf(s, sizeof s, "%d,%d,%d,%d,%d,%.2f,wgc copy %.1f; hdr white %.2f%s; frame %.1f s old%s%s", cap_x, cap_y, cap_w,
             cap_h, cap_dpi, cap_ms, t[0], t[1], t[2] > 0 ? " (copied first)" : "", t[3],
             t[4] > 0 ? " (session made again)" : "", lag);
  } else {
    char st[96];
    ps_wgc_state(st, sizeof st);
    snprintf(s, sizeof s, "%d,%d,%d,%d,%d,%.2f,gdi (%s%s)", cap_x, cap_y, cap_w, cap_h, cap_dpi, cap_ms, st, lag);
  }
  return ps_text(s);
}

// Where the picture taken is, as mbui is handed pixels kept elsewhere ("MBRAWPTR", their address, width, height, row
// pitch): empty where there is none, or it is still being taken. Kept here till ps_capture_release.
moonbit_bytes_t ps_capture_take(void) {
  if (!cap.bits || cap_busy || !cap_ok) return moonbit_make_bytes(0, 0);
  uint8_t d[28];
  uint64_t at = (uint64_t)(uintptr_t)cap.bits;
  int32_t w = cap.w, h = cap.h, pitch = cap.pitch;
  memcpy(d, "MBRAWPTR", 8);
  memcpy(d + 8, &at, 8);
  memcpy(d + 16, &w, 4);
  memcpy(d + 20, &h, 4);
  memcpy(d + 24, &pitch, 4);
  return ps_bytes(d, sizeof d);
}

// The picture taken let go: freed a moment later (what decoded it is done by then).
void ps_capture_release(void) {
  if (!cap.dib || cap_busy) return;
  for (int i = 0; i < 4; i++)
    if (!cap_old[i].dib) {
      cap_old[i] = cap;
      memset(&cap, 0, sizeof cap);
      if (tray_hwnd) SetTimer(tray_hwnd, PS_FREE_TIMER, 1500, NULL);
      return;
    }
  shot_free(&cap);
}

static void cap_old_free(void) {
  for (int i = 0; i < 4; i++) shot_free(&cap_old[i]);
}

// The colour of the pixel at (x, y) of the picture taken: 0xRRGGBB, -1 where there is none.
int32_t ps_pixel(int32_t x, int32_t y) {
  if (!cap.bits || cap_busy || x < 0 || y < 0 || x >= cap.w || y >= cap.h) return -1;
  const uint8_t *p = cap.bits + (size_t)y * cap.pitch + (size_t)x * 4;
  return (p[2] << 16) | (p[1] << 8) | p[0];
}

// The mean colour (0xRRGGBB) of the `cell` square at (x, y) of the picture taken (what of it is on the picture), every
// other pixel read where it is 8 or more, a little quantized so a flat ground's squares are one run; 0x808080 none.
int32_t ps_mean(int32_t x, int32_t y, int32_t cell) {
  if (!cap.bits || cap_busy) return 0x808080;
  int x0 = x < 0 ? 0 : x, y0 = y < 0 ? 0 : y;
  int x1 = x + cell > cap.w ? cap.w : x + cell, y1 = y + cell > cap.h ? cap.h : y + cell;
  if (x1 <= x0 || y1 <= y0) return 0x808080;
  int step = cell >= 24 ? 4 : (cell >= 8 ? 2 : 1);
  unsigned r = 0, g = 0, b = 0, n = 0;
  for (int yy = y0; yy < y1; yy += step) {
    const uint8_t *p = cap.bits + (size_t)yy * cap.pitch + (size_t)x0 * 4;
    for (int xx = x0; xx < x1; xx += step, p += 4 * step) {
      b += p[0];
      g += p[1];
      r += p[2];
      n++;
    }
  }
  unsigned qr = r / n / 4 * 4 + 2, qg = g / n / 4 * 4 + 2, qb = b / n / 4 * 4 + 2;
  return (int32_t)((qr << 16) | (qg << 8) | qb);
}

// ---- the windows on the screen ----
//
// The windows that show on the monitor taken, the front first: each "x,y,w,h" in the monitor's pixels (its frame as DWM
// draws it, without the shadow), one a line; what a click picks while nothing is selected. Child windows big enough to be
// a part of their window (a pane, a view) follow their window's line, before the next window. Ours are left out.

typedef struct {
  char *out;
  size_t len, cap;
  int depth;
  HWND *hwnds;  // each line's window, in the lines' order (ps_window_shows)
  size_t n, hwnds_cap;
} WinList;

static HWND *win_hwnds;  // the windows of win_list's lines, in its order
static size_t win_hwnds_n;

static void list_put(WinList *l, RECT r, HWND h) {
  if (l->n + 1 > l->hwnds_cap) {
    l->hwnds_cap = (l->n + 1) * 2;
    l->hwnds = (HWND *)realloc(l->hwnds, l->hwnds_cap * sizeof(HWND));
  }
  l->hwnds[l->n++] = h;
  char s[200], cls[96] = {0};
  GetClassNameA(h, cls, sizeof cls);
  int n = snprintf(s, sizeof s, "%ld,%ld,%ld,%ld;%s\n", r.left - cap_x, r.top - cap_y, r.right - r.left, r.bottom - r.top, cls);
  if (l->len + n + 1 > l->cap) {
    l->cap = (l->len + n + 1) * 2;
    l->out = (char *)realloc(l->out, l->cap);
  }
  memcpy(l->out + l->len, s, (size_t)n);
  l->len += (size_t)n;
}

static int rect_on_monitor(RECT r) {
  RECT m = {cap_x, cap_y, cap_x + cap_w, cap_y + cap_h}, i;
  return IntersectRect(&i, &r, &m) && (i.right - i.left) >= 8 && (i.bottom - i.top) >= 8;
}

static BOOL CALLBACK child_found(HWND h, LPARAM lp) {
  WinList *l = (WinList *)lp;
  if (!IsWindowVisible(h)) return TRUE;
  RECT r;
  if (!GetWindowRect(h, &r)) return TRUE;
  if ((r.right - r.left) < 40 || (r.bottom - r.top) < 24 || !rect_on_monitor(r)) return TRUE;
  list_put(l, r, h);
  return TRUE;
}

static BOOL CALLBACK window_found(HWND h, LPARAM lp) {
  WinList *l = (WinList *)lp;
  if (!IsWindowVisible(h) || IsIconic(h)) return TRUE;
  DWORD pid = 0;
  GetWindowThreadProcessId(h, &pid);
  if (pid == GetCurrentProcessId()) return TRUE;
  BOOL cloaked = FALSE;
  DwmGetWindowAttribute(h, DWMWA_CLOAKED, &cloaked, sizeof cloaked);
  if (cloaked) return TRUE;
  LONG_PTR ex = GetWindowLongPtrW(h, GWL_EXSTYLE);
  if ((ex & WS_EX_TRANSPARENT) && (ex & WS_EX_LAYERED)) return TRUE;  // (what a click goes through: an overlay)
  // (a layered window drawn wholly clear shows nothing: NVIDIA's overlay over the whole screen, at rest)
  if (ex & WS_EX_LAYERED) {
    BYTE alpha = 255;
    DWORD flags = 0;
    if (GetLayeredWindowAttributes(h, NULL, &alpha, &flags) && (flags & LWA_ALPHA) && alpha == 0) return TRUE;
  }
  RECT r;
  if (FAILED(DwmGetWindowAttribute(h, DWMWA_EXTENDED_FRAME_BOUNDS, &r, sizeof r)) && !GetWindowRect(h, &r)) return TRUE;
  if ((r.right - r.left) < 8 || (r.bottom - r.top) < 8 || !rect_on_monitor(r)) return TRUE;
  // (the taskbar and the desktop are windows too: kept, they are what is on the screen)
  list_put(l, r, h);
  EnumChildWindows(h, child_found, lp);
  return TRUE;
}

static void windows_listed(void) {
  WinList l = {NULL, 0, 0, 0, NULL, 0, 0};
  EnumWindows(window_found, (LPARAM)&l);
  free(win_list);
  win_list = l.out;
  win_list_len = l.len;
  free(win_hwnds);
  win_hwnds = l.hwnds;
  win_hwnds_n = l.n;
}

// Whether the window of win_list's line `i` is a part (a pane, a view) of the window of line `of` and what shows at
// (x, y) of the monitor taken: the window its own window has there, going down through what holds it as the system finds a click's window
// among its children (none hidden, none a click goes through), is it or one of its own. A part covered there by another
// part of the same window (a page behind the one shown, a view under a panel) is not: it is not seen (the user,
// 2026-11-20: 「假如一个窗口看不到，不应该在 area capture 时能嗅探到」). Asked as the pointer comes to it, of the
// windows as they are then (as the screen was taken, unless they moved since).
int32_t ps_window_shows(int32_t of, int32_t i, int32_t x, int32_t y) {
  if (i < 0 || (size_t)i >= win_hwnds_n || of < 0 || (size_t)of >= win_hwnds_n) return 0;
  HWND h = win_hwnds[i];
  if (!IsWindow(h)) return 0;
  HWND cur = GetAncestor(h, GA_ROOT);
  // (a part of the window `of` itself, not of a window behind it: a window listed after a big one and inside it is behind
  // it, and so are its parts; a window under a maximized one, or a pane of it, was picked through it)
  if (!cur || cur == h || cur != win_hwnds[of]) return 0;
  POINT screen = {x + cap_x, y + cap_y};
  for (int depth = 0; depth < 32; depth++) {
    POINT pt = screen;
    ScreenToClient(cur, &pt);
    HWND next = ChildWindowFromPointEx(cur, pt, CWP_SKIPINVISIBLE | CWP_SKIPTRANSPARENT);
    if (!next || next == cur) break;
    cur = next;
    if (cur == h) return 1;
  }
  return cur == h || IsChild(h, cur) ? 1 : 0;
}

// The windows as they were when the screen was taken.
moonbit_bytes_t ps_windows(void) { return ps_bytes(win_list, win_list_len); }

// ---- one run, the icon, the shortcuts ----

#define PS_CLASS L"PinShot.Tray"
// A test run (PINSHOT_TEST set): a run of its own beside the person's (its own one-run mutex and window class), no
// icon, no shortcuts taken, its own log; what the person presses goes on to theirs.
static int test_run(void) {
  static int t = -1;
  if (t < 0) t = getenv("PINSHOT_TEST") != NULL;
  return t;
}
static const wchar_t *ps_class(void) { return test_run() ? L"PinShot.TestTray" : PS_CLASS; }
#define WM_PS_TRAY (WM_APP + 40)
#define WM_PS_AGAIN (WM_APP + 41)
static NOTIFYICONDATAW tray;
static int tray_on;  // the icon is in the notification area (ps_tray_on)
static UINT taskbar_created;
static HANDLE one_run;

enum { HK_CAPTURE = 1, HK_PIN_CLIP = 2, HK_PINS = 3, HK_MOST = 4 };
static int hk_on[HK_MOST];

static HICON own_icon(int size) {
  HICON i = (HICON)LoadImageW(GetModuleHandleW(NULL), MAKEINTRESOURCEW(1), IMAGE_ICON, size, size, LR_DEFAULTCOLOR);
  return i ? i : LoadIcon(NULL, IDI_APPLICATION);
}

static void tray_put(void) {
  if (test_run()) return;
  memset(&tray, 0, sizeof tray);
  tray.cbSize = sizeof tray;
  tray.hWnd = tray_hwnd;
  tray.uID = 1;
  tray.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
  tray.uCallbackMessage = WM_PS_TRAY;
  tray.hIcon = own_icon(GetSystemMetricsForDpi(SM_CXSMICON, GetDpiForWindow(tray_hwnd)));
  lstrcpynW(tray.szTip, L"PinShot", 64);
  if (Shell_NotifyIconW(NIM_ADD, &tray)) {
    tray.uVersion = NOTIFYICON_VERSION_4;
    Shell_NotifyIconW(NIM_SETVERSION, &tray);
    tray_on = 1;
  }
}

static void tray_gone(void) {
  if (tray_hwnd) Shell_NotifyIconW(NIM_DELETE, &tray);
}

// The icon's menu (words the app gave: ps_set_menu), each item's key told back as chosen.
#define MENU_MOST 16
static wchar_t *menu_words[MENU_MOST];
static char menu_keys[MENU_MOST][32];
static int menu_n;

// "key\twords\n" lines; a line "-" a separator.
void ps_set_menu(moonbit_bytes_t lines) {
  for (int i = 0; i < menu_n; i++) free(menu_words[i]);
  menu_n = 0;
  int n = (int)Moonbit_array_length(lines);
  const char *s = (const char *)lines;
  int at = 0;
  while (at < n && menu_n < MENU_MOST) {
    int end = at;
    while (end < n && s[end] != '\n') end++;
    int tab = at;
    while (tab < end && s[tab] != '\t') tab++;
    char key[32] = {0}, words[256] = {0};
    int kl = tab - at < 31 ? tab - at : 31;
    memcpy(key, s + at, (size_t)kl);
    if (tab < end) {
      int wl = end - tab - 1 < 255 ? end - tab - 1 : 255;
      memcpy(words, s + tab + 1, (size_t)wl);
    }
    lstrcpynA(menu_keys[menu_n], key, 32);
    menu_words[menu_n] = ps_wide(words);
    menu_n++;
    at = end + 1;
  }
}

static void tray_menu(int x, int y) {
  HMENU m = CreatePopupMenu();
  for (int i = 0; i < menu_n; i++) {
    if (!strcmp(menu_keys[i], "-")) AppendMenuW(m, MF_SEPARATOR, 0, NULL);
    else AppendMenuW(m, MF_STRING, (UINT_PTR)(i + 1), menu_words[i]);
  }
  SetForegroundWindow(tray_hwnd);
  int chose = (int)TrackPopupMenuEx(m, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON | TPM_BOTTOMALIGN, x, y, tray_hwnd, NULL);
  PostMessageW(tray_hwnd, WM_NULL, 0, 0);
  DestroyMenu(m);
  if (chose > 0 && chose <= menu_n) {
    char json[96];
    snprintf(json, sizeof json, "{\"do\":\"menu\",\"item\":\"%s\"}", menu_keys[chose - 1]);
    ps_tell(json);
  }
}

static char cap_by[16];
static int capture_open;  // the app has a capture open (ps_capture_open): 1 the person's, 2 the one taken as it starts
static char ask_waiting[16];  // a capture asked for while the one taken as it starts was open: asked as that closes
#define WM_PS_ASK (WM_APP + 45)
#define WM_PS_MOVE (WM_APP + 46)
static void gpu_trim_now(void);
#define WM_PS_TRIM (WM_APP + 43)

static HWND own_window(int wid);

static void capture_asked(const char *by) {
  // (not while a capture is open: the overlay would be taken too; while the one taken as the run starts is, asked
  // for as soon as it closes: a shortcut pressed as the run starts is not lost)
  if (capture_open == 2) {
    lstrcpynA(ask_waiting, by, sizeof ask_waiting);
    return;
  }
  if (capture_open) return;
  if (strcmp(by, "key") != 0) cap_key_lag = 0.0;
  if (!cap_begin()) return;
  lstrcpynA(cap_by, by, sizeof cap_by);
  char json[192];
  snprintf(json, sizeof json, "{\"do\":\"prepare\",\"x\":%d,\"y\":%d,\"w\":%d,\"h\":%d,\"dpi\":%d,\"t\":%.3f}", cap_x, cap_y, cap_w, cap_h,
           cap_dpi, cap_t0);
  ps_tell(json);
}

static LRESULT CALLBACK tray_proc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
  if (taskbar_created && msg == taskbar_created) {
    tray_put();
    return 0;
  }
  switch (msg) {
    case WM_HOTKEY:
      if (wp == HK_CAPTURE) {
        cap_key_lag = (double)((DWORD)GetTickCount() - (DWORD)GetMessageTime());
        capture_asked("key");
      }
      else if (wp == HK_PIN_CLIP) ps_tell("{\"do\":\"pin-clipboard\"}");
      else if (wp == HK_PINS) ps_tell("{\"do\":\"pins\"}");
      return 0;
    case WM_PS_AGAIN:  // started again: as the shortcut, or as its arguments say (ps_start)
      if (wp == 1) ps_tell("{\"do\":\"menu\",\"item\":\"settings\"}");
      else if (wp == 2) ps_tell("{\"do\":\"menu\",\"item\":\"quit\"}");
      else if (wp == 3) ;  // (--updated: an update's new run, and this one is still here: nothing taken)
      else capture_asked("again");
      return 0;
    case WM_PS_TRIM:
      gpu_trim_now();
      return 0;
    case WM_PS_ASK:
      if (ask_waiting[0] && !capture_open) {
        char by[16];
        lstrcpynA(by, ask_waiting, sizeof by);
        ask_waiting[0] = 0;
        capture_asked(by);
      }
      return 0;
    case WM_DISPLAYCHANGE:  // (the monitors changed: each one's capture made again)
      ps_wgc_restart();
      return 0;
    // (the monitors woken, the computer resumed, the session unlocked or connected to again: each one's capture made
    // again a moment later, once DWM composes again; a session can stop across these with its last frame kept)
    case WM_POWERBROADCAST:
      if (wp == PBT_APMRESUMEAUTOMATIC ||
          (wp == PBT_POWERSETTINGCHANGE && lp &&
           !memcmp(&((POWERBROADCAST_SETTING *)lp)->PowerSetting, &display_state_guid, sizeof(GUID)) &&
           ((POWERBROADCAST_SETTING *)lp)->DataLength >= sizeof(DWORD) && *(DWORD *)((POWERBROADCAST_SETTING *)lp)->Data == 1))
        SetTimer(h, PS_WGC_TIMER, 1500, NULL);
      return TRUE;
    case WM_WTSSESSION_CHANGE:
      if (wp == WTS_SESSION_UNLOCK || wp == WTS_CONSOLE_CONNECT || wp == WTS_REMOTE_CONNECT)
        SetTimer(h, PS_WGC_TIMER, 1500, NULL);
      return 0;
    case WM_TIMER:
      if (wp == PS_WGC_TIMER) {
        KillTimer(h, PS_WGC_TIMER);
        if (!wgc_off) ps_wgc_restart();
      }
      if (wp == PS_FREE_TIMER) {
        KillTimer(h, PS_FREE_TIMER);
        cap_old_free();
      }
      return 0;
    case WM_PS_TAKEN: {
      char json[128];
      snprintf(json, sizeof json, "{\"do\":\"capture\",\"ok\":%s,\"by\":\"%s\"}", wp ? "true" : "false", cap_by);
      ps_tell(json);
      return 0;
    }
    case WM_PS_TRAY:
      switch (LOWORD(lp)) {
        case NIN_SELECT:
        case NIN_KEYSELECT: capture_asked("icon"); break;
        case WM_CONTEXTMENU: tray_menu(GET_X_LPARAM(wp), GET_Y_LPARAM(wp)); break;
        case NIN_BALLOONUSERCLICK: ps_tell("{\"do\":\"menu\",\"item\":\"settings\"}"); break;
      }
      return 0;
    case WM_ENDSESSION:
      if (wp) tray_gone();
      return 0;
  }
  return DefWindowProcW(h, msg, wp, lp);
}

// Whether the app has a capture open: no other is taken meanwhile (its shortcut pressed again does nothing).
void ps_capture_open(int32_t on) {
  capture_open = on;
  // (asked for once the app is through closing it: a message to the icon's window, after what closes it now)
  if (!on && ask_waiting[0] && tray_hwnd) PostMessageW(tray_hwnd, WM_PS_ASK, 0, 0);
}

// The tray window (what the icon, the shortcuts and the capture tell): made once.
static void tray_window_made(void) {
  if (tray_hwnd) return;
  WNDCLASSEXW wc = {sizeof wc};
  wc.lpfnWndProc = tray_proc;
  wc.hInstance = GetModuleHandleW(NULL);
  wc.lpszClassName = ps_class();
  RegisterClassExW(&wc);
  // (a top-level window never shown, not one of HWND_MESSAGE: Explorer's TaskbarCreated is broadcast to top-level ones)
  tray_hwnd = CreateWindowExW(WS_EX_TOOLWINDOW, ps_class(), L"PinShot", WS_POPUP, 0, 0, 0, 0, NULL, NULL, wc.hInstance, NULL);
}

// A capture asked for by the app (the icon's menu): as the shortcut.
void ps_capture_ask(void) { capture_asked("menu"); }

// The run begun: 1 it is the one run (its icon put, its window made), 0 another runs already (told `again`: 0 take
// the screen, as its shortcut does; 1 open the settings; 2 quit): this one ends.
int32_t ps_start(int32_t again) {
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  one_run = CreateMutexW(NULL, TRUE, test_run() ? L"Local\\PinShot.TestRun" : L"Local\\PinShot.OneRun");
  if (one_run && GetLastError() == ERROR_ALREADY_EXISTS) {
    HWND other = FindWindowW(ps_class(), NULL);
    if (other) {
      DWORD pid = 0;
      GetWindowThreadProcessId(other, &pid);
      AllowSetForegroundWindow(pid);
      PostMessageW(other, WM_PS_AGAIN, (WPARAM)again, 0);
    }
    return 0;
  }
  tray_window_made();
  // (mbui's compiled HLSL shaders cached in %LOCALAPPDATA%\PinShot\shaders so starting or updating PinShot loads them in
  // ~5 ms instead of compiling for ~3.8 s on the UI thread after shortcuts are registered)
  if (!_wgetenv(L"MBUI_SHADERS")) {
    wchar_t local[MAX_PATH] = {0}, app_dir[MAX_PATH * 2] = {0}, sh_dir[MAX_PATH * 2] = {0};
    DWORD n = GetEnvironmentVariableW(L"LOCALAPPDATA", local, MAX_PATH);
    if (n > 0 && n < MAX_PATH - 40) {
      _snwprintf(app_dir, MAX_PATH * 2 - 1, L"%ls\\PinShot", local);
      CreateDirectoryW(app_dir, NULL);
      _snwprintf(sh_dir, MAX_PATH * 2 - 1, L"%ls\\shaders", app_dir);
      CreateDirectoryW(sh_dir, NULL);
      _wputenv_s(L"MBUI_SHADERS", sh_dir);
    }
  }
  taskbar_created = RegisterWindowMessageW(L"TaskbarCreated");
  ChangeWindowMessageFilterEx(tray_hwnd, taskbar_created, MSGFLT_ALLOW, NULL);
  tray_put();
  atexit(tray_gone);
  // (each monitor's capture kept on from now: capture_wgc.cpp; PINSHOT_CAPTURE=gdi none, GDI's every time)
  const char *how = getenv("PINSHOT_CAPTURE");
  wgc_off = how && !strcmp(how, "gdi");
  if (!wgc_off) {
    RegisterPowerSettingNotification(tray_hwnd, &display_state_guid, DEVICE_NOTIFY_WINDOW_HANDLE);
    WTSRegisterSessionNotification(tray_hwnd, NOTIFY_FOR_THIS_SESSION);
  }
  return 1;
}

void ps_wgc_set_keep(int keep);
void ps_set_capture_keep(int32_t keep) {
  keep_gpu_warm = keep ? 1 : 0;
  if (!wgc_off) ps_wgc_set_keep(keep);
}

// A note from the icon (the system's balloon, a notification): `title` and `text` (UTF-8, ending in a NUL); clicked,
// it opens the settings ({"do":"menu","item":"settings"}).
void ps_tray_note(moonbit_bytes_t title, moonbit_bytes_t text) {
  if (!tray_on) return;
  NOTIFYICONDATAW n = tray;
  n.uFlags = NIF_INFO;
  n.dwInfoFlags = NIIF_INFO;
  wchar_t *t = ps_wide((const char *)title), *b = ps_wide((const char *)text);
  lstrcpynW(n.szInfoTitle, t, 64);
  lstrcpynW(n.szInfo, b, 256);
  free(t);
  free(b);
  Shell_NotifyIconW(NIM_MODIFY, &n);
}

// Whether the icon is in the notification area.
int32_t ps_tray_on(void) { return tray_on; }

// A global shortcut set (`mods`: MOD_ALT 1, MOD_CONTROL 2, MOD_SHIFT 4, MOD_WIN 8; `vk` 0: none): 1 it is ours now, 0 the
// system or another program has it (it is left unset).
int32_t ps_hotkey(int32_t which, int32_t mods, int32_t vk) {
  if (which <= 0 || which >= HK_MOST || !tray_hwnd) return 0;
  if (hk_on[which]) UnregisterHotKey(tray_hwnd, which);
  hk_on[which] = 0;
  if (vk == 0 || test_run()) return 1;
  hk_on[which] = RegisterHotKey(tray_hwnd, which, (UINT)mods | MOD_NOREPEAT, (UINT)vk) ? 1 : 0;
  return hk_on[which];
}

// ---- a shortcut set by pressing it ----
//
// While the settings ask for a shortcut (ps_key_record(1)), the next key pressed in PinShot's own window is taken by a
// low-level keyboard hook, never passed on (so Alt+F4, Win+D or the Start menu do nothing then), and told the app with
// the modifiers held: {"do":"key-pressed","mods":M,"vk":V} (Alt 1, Ctrl 2, Shift 4, Win 8, as RegisterHotKey takes
// them), Escape as {"how":"cancel"} and Backspace or Delete alone as {"how":"clear"}. A key pressed while another
// program is in front is let through and ends it ({"how":"cancel"}). One key ends it either way.

static HHOOK key_hook;
static int key_mods;  // the modifiers held, as the hook has seen them (it takes them from the system too)

static void key_record_end(const char *how, int mods, int vk) {
  if (key_hook) {
    UnhookWindowsHookEx(key_hook);
    key_hook = NULL;
  }
  key_mods = 0;
  char json[96];
  snprintf(json, sizeof json, "{\"do\":\"key-pressed\",\"how\":\"%s\",\"mods\":%d,\"vk\":%d}", how, mods, vk);
  ps_tell(json);
}

static int key_mod_of(DWORD vk) {
  switch (vk) {
    case VK_MENU: case VK_LMENU: case VK_RMENU: return MOD_ALT;
    case VK_CONTROL: case VK_LCONTROL: case VK_RCONTROL: return MOD_CONTROL;
    case VK_SHIFT: case VK_LSHIFT: case VK_RSHIFT: return MOD_SHIFT;
    case VK_LWIN: case VK_RWIN: return MOD_WIN;
  }
  return 0;
}

static LRESULT CALLBACK key_hook_proc(int code, WPARAM wp, LPARAM lp) {
  if (code != HC_ACTION || !key_hook) return CallNextHookEx(NULL, code, wp, lp);
  const KBDLLHOOKSTRUCT *k = (const KBDLLHOOKSTRUCT *)lp;
  if (k->flags & LLKHF_INJECTED) return CallNextHookEx(NULL, code, wp, lp);
  DWORD pid = 0;
  GetWindowThreadProcessId(GetForegroundWindow(), &pid);
  if (pid != GetCurrentProcessId()) {
    key_record_end("cancel", 0, 0);
    return CallNextHookEx(NULL, code, wp, lp);
  }
  int down = wp == WM_KEYDOWN || wp == WM_SYSKEYDOWN;
  int mod = key_mod_of(k->vkCode);
  if (mod) {
    if (down) key_mods |= mod;
    else key_mods &= ~mod;
    return 1;
  }
  if (!down) return 1;
  int vk = (int)k->vkCode;
  if (vk == VK_ESCAPE && key_mods == 0) key_record_end("cancel", 0, 0);
  else if ((vk == VK_BACK || vk == VK_DELETE) && key_mods == 0) key_record_end("clear", 0, 0);
  else key_record_end("key", key_mods, vk);
  return 1;
}

// 1 a shortcut is asked for (the hook set), 0 not; ps_key_record(0) ends it with nothing told.
int32_t ps_key_record(int32_t on) {
  if (!on) {
    if (key_hook) UnhookWindowsHookEx(key_hook);
    key_hook = NULL;
    key_mods = 0;
    return 1;
  }
  if (key_hook) return 1;
  // (the modifiers already held as it starts count: Ctrl held while the box is clicked)
  key_mods = 0;
  if (GetAsyncKeyState(VK_MENU) & 0x8000) key_mods |= MOD_ALT;
  if (GetAsyncKeyState(VK_CONTROL) & 0x8000) key_mods |= MOD_CONTROL;
  if (GetAsyncKeyState(VK_SHIFT) & 0x8000) key_mods |= MOD_SHIFT;
  if ((GetAsyncKeyState(VK_LWIN) | GetAsyncKeyState(VK_RWIN)) & 0x8000) key_mods |= MOD_WIN;
  key_hook = SetWindowsHookExW(WH_KEYBOARD_LL, key_hook_proc, GetModuleHandleW(NULL), 0);
  return key_hook ? 1 : 0;
}

// A key's name as a shortcut says it (the keyboard's own for the rest: "Page Up", "Num 5", ";").
moonbit_bytes_t ps_key_name(int32_t vk) {
  wchar_t name[64] = {0};
  if ((vk >= 'A' && vk <= 'Z') || (vk >= '0' && vk <= '9')) {
    name[0] = (wchar_t)vk;
  } else if (vk >= VK_F1 && vk <= VK_F24) {
    _snwprintf(name, 63, L"F%d", vk - VK_F1 + 1);
  } else {
    const wchar_t *fixed = NULL;
    switch (vk) {
      case VK_SNAPSHOT: fixed = L"PrtSc"; break;
      case VK_SPACE: fixed = L"Space"; break;
      case VK_RETURN: fixed = L"Enter"; break;
      case VK_TAB: fixed = L"Tab"; break;
      case VK_PAUSE: fixed = L"Pause"; break;
      case VK_INSERT: fixed = L"Insert"; break;
      case VK_HOME: fixed = L"Home"; break;
      case VK_END: fixed = L"End"; break;
      case VK_PRIOR: fixed = L"PgUp"; break;
      case VK_NEXT: fixed = L"PgDn"; break;
      case VK_LEFT: fixed = L"\x2190"; break;
      case VK_UP: fixed = L"\x2191"; break;
      case VK_RIGHT: fixed = L"\x2192"; break;
      case VK_DOWN: fixed = L"\x2193"; break;
    }
    if (fixed) {
      lstrcpynW(name, fixed, 64);
    } else {
      UINT sc = MapVirtualKeyW((UINT)vk, MAPVK_VK_TO_VSC_EX);
      LONG lp = (LONG)((sc & 0xFF) << 16);
      if (sc & 0xFF00) lp |= 1 << 24;
      if (!GetKeyNameTextW(lp, name, 63)) _snwprintf(name, 63, L"Key %d", vk);
    }
  }
  return ps_utf8_bytes(name);
}

// ---- PinShot's own windows ----
//
// Each an mbui window (0 the overlay, the others beside it: @ui.window_open_here) made what it is here: no frame of the
// system's, not on the taskbar, over the others, at a rectangle in the screen's pixels. Its DPI changing (moved to
// another monitor) keeps that rectangle: the app lays itself out at the new scale (mbui reads it each frame), never
// moved to where Windows suggests. A close (Alt+F4) is told the app ({"do":"close","wid":n}), never done here: the
// overlay is only hidden, a pin closed by the app.

static LRESULT CALLBACK own_proc(HWND h, UINT msg, WPARAM wp, LPARAM lp, UINT_PTR id, DWORD_PTR wid) {
  (void)id;
  switch (msg) {
    case WM_DPICHANGED:
      InvalidateRect(h, NULL, FALSE);
      return 0;
    case WM_CLOSE: {
      // (the app's own close, mbui's window_close_here: let through)
      if (GetPropW(h, L"PinShot.Closing")) break;
      char json[64];
      snprintf(json, sizeof json, "{\"do\":\"close\",\"wid\":%d}", (int)wid);
      ps_tell(json);
      return 0;
    }
    case WM_ACTIVATE: {
      // (taken or let go as the window in front: a pin shows it)
      char json[64];
      snprintf(json, sizeof json, "{\"do\":\"active\",\"wid\":%d,\"on\":%d}", (int)wid, LOWORD(wp) != WA_INACTIVE);
      ps_tell(json);
      // (and drawn on: the app hears it on its own window's frame, a pin draws only as something comes to it; its
      // flash runs 360 ms, a frame asked of it every 16 ms till then)
      SetPropW(h, L"PinShot.Frames", (HANDLE)(INT_PTR)30);
      SetTimer(h, 0x5053, 16, NULL);
      break;
    }
    case WM_PS_MOVE: {
      // (the system's move, as a title bar's, while the button is held; then the press let go of where it ends:
      // the move's loop takes the button's release, which mbui never hears)
      // (none where the button is up already: the press was a click, its release heard)
      if (GetKeyState(VK_LBUTTON) >= 0) return 0;
      POINT p;
      GetCursorPos(&p);
      ReleaseCapture();
      SendMessageW(h, WM_NCLBUTTONDOWN, HTCAPTION, MAKELPARAM(p.x, p.y));
      GetCursorPos(&p);
      ScreenToClient(h, &p);
      PostMessageW(h, WM_LBUTTONUP, 0, MAKELPARAM(p.x, p.y));
      return 0;
    }
    case WM_TIMER:
      if (wp == 0x5053) {
        INT_PTR n = (INT_PTR)GetPropW(h, L"PinShot.Frames");
        char json[48];
        snprintf(json, sizeof json, "{\"do\":\"tick\",\"wid\":%d}", (int)wid);
        ps_tell(json);
        InvalidateRect(h, NULL, FALSE);
        if (n <= 1) {
          KillTimer(h, 0x5053);
          RemovePropW(h, L"PinShot.Frames");
        } else {
          SetPropW(h, L"PinShot.Frames", (HANDLE)(n - 1));
        }
        return 0;
      }
      break;
    case WM_NCDESTROY:
      RemovePropW(h, L"PinShot.Frames");
      RemovePropW(h, L"PinShot.Closing");
      RemoveWindowSubclass(h, own_proc, 1);
      break;
  }
  return DefSubclassProc(h, msg, wp, lp);
}

static HWND own_window(int wid) { return (HWND)mb_app_hwnd_of(wid); }

// Window `wid` moved with the pointer as its title bar would be (once the app's handling of the press is over).
void ps_move_window(int32_t wid) {
  HWND h = own_window(wid);
  if (h) PostMessageW(h, WM_PS_MOVE, 0, 0);
}

// Window `wid` to be closed by the app now (mbui posts it WM_CLOSE, which is let through for it alone).
void ps_let_close(int32_t wid) {
  HWND h = own_window(wid);
  if (h) SetPropW(h, L"PinShot.Closing", (HANDLE)1);
}

// Window `wid` made one of PinShot's own (as said above), out of sight: 1 done.
int32_t ps_own(int32_t wid, int32_t topmost) {
  HWND h = own_window(wid);
  if (!h) return 0;
  LONG_PTR style = GetWindowLongPtrW(h, GWL_STYLE);
  style &= ~(LONG_PTR)(WS_OVERLAPPEDWINDOW);
  style |= WS_POPUP;
  SetWindowLongPtrW(h, GWL_STYLE, style);
  LONG_PTR ex = GetWindowLongPtrW(h, GWL_EXSTYLE);
  ex &= ~(LONG_PTR)WS_EX_APPWINDOW;
  ex |= WS_EX_TOOLWINDOW;
  SetWindowLongPtrW(h, GWL_EXSTYLE, ex);
  DWM_WINDOW_CORNER_PREFERENCE corner = DWMWCP_DONOTROUND;
  DwmSetWindowAttribute(h, DWMWA_WINDOW_CORNER_PREFERENCE, &corner, sizeof corner);
  // (no transition of DWM's as it shows or hides: it is there at once, and gone at once)
  BOOL no = TRUE;
  DwmSetWindowAttribute(h, DWMWA_TRANSITIONS_FORCEDISABLED, &no, sizeof no);
  SetWindowSubclass(h, own_proc, 1, (DWORD_PTR)wid);
  SetWindowPos(h, topmost ? HWND_TOPMOST : HWND_NOTOPMOST, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_FRAMECHANGED);
  return 1;
}

// Window `wid` given DWM's shadow round it (a pin: it stands off what is under it). A popup has none of its own; DWM
// draws one round a window whose frame it renders and that reaches into the client by a pixel.
void ps_shadow(int32_t wid) {
  HWND h = own_window(wid);
  if (!h) return;
  enum DWMNCRENDERINGPOLICY p = DWMNCRP_ENABLED;
  DwmSetWindowAttribute(h, DWMWA_NCRENDERING_POLICY, &p, sizeof p);
  MARGINS m = {1, 1, 1, 1};
  DwmExtendFrameIntoClientArea(h, &m);
}

// Window `wid` (w by h points) under the pointer, on its monitor's work area, round-cornered, over the others, shown
// without taking the keyboard: a word said for a moment (toast.mbt).
void ps_toast_place(int32_t wid, int32_t w, int32_t h) {
  HWND hw = own_window(wid);
  if (!hw) return;
  POINT p;
  GetCursorPos(&p);
  HMONITOR mon = MonitorFromPoint(p, MONITOR_DEFAULTTONEAREST);
  MONITORINFO mi = {sizeof mi};
  GetMonitorInfoW(mon, &mi);
  UINT dx = 96, dy = 96;
  typedef HRESULT(WINAPI * GetDpiForMonitorFn)(HMONITOR, int, UINT *, UINT *);
  GetDpiForMonitorFn dpi_of = (GetDpiForMonitorFn)GetProcAddress(LoadLibraryW(L"shcore.dll"), "GetDpiForMonitor");
  if (dpi_of) dpi_of(mon, 0, &dx, &dy);
  DWM_WINDOW_CORNER_PREFERENCE corner = DWMWCP_ROUND;
  DwmSetWindowAttribute(hw, DWMWA_WINDOW_CORNER_PREFERENCE, &corner, sizeof corner);
  int ww = MulDiv(w, (int)dx, 96), wh = MulDiv(h, (int)dx, 96);
  RECT a = mi.rcWork;
  int x = p.x - ww / 2, y = p.y + MulDiv(24, (int)dx, 96);
  if (y + wh > a.bottom) y = p.y - MulDiv(16, (int)dx, 96) - wh;
  if (x < a.left) x = a.left;
  if (x + ww > a.right) x = a.right - ww;
  SetWindowPos(hw, HWND_TOPMOST, x, y, ww, wh, SWP_NOACTIVATE | SWP_SHOWWINDOW);
}

// Window `wid` at x, y, w by h (the screen's pixels), shown (`show` 1, taking the keyboard where `focus`) or as it is.
void ps_place(int32_t wid, int32_t x, int32_t y, int32_t w, int32_t h, int32_t show, int32_t focus) {
  HWND hw = own_window(wid);
  if (!hw) return;
  // (shown: over every other window that is over the others, as it is put there, a notification's too)
  UINT f = SWP_NOACTIVATE | (show ? SWP_SHOWWINDOW : SWP_NOZORDER);
  HWND after = show && (GetWindowLongPtrW(hw, GWL_EXSTYLE) & WS_EX_TOPMOST) ? HWND_TOPMOST : (show ? HWND_TOP : NULL);
  SetWindowPos(hw, after, x, y, w, h, f);
  if (show && focus) {
    SetForegroundWindow(hw);
    SetFocus(hw);
  }
}

// Window `wid`, `w` by `h` points at its monitor's scale, in the middle of the monitor the pointer is on, shown.
void ps_center(int32_t wid, int32_t w, int32_t h) {
  HWND hw = own_window(wid);
  if (!hw) return;
  POINT p;
  GetCursorPos(&p);
  HMONITOR mon = MonitorFromPoint(p, MONITOR_DEFAULTTONEAREST);
  MONITORINFO mi = {sizeof mi};
  GetMonitorInfoW(mon, &mi);
  UINT dx = 96, dy = 96;
  typedef HRESULT(WINAPI * GetDpiForMonitorFn)(HMONITOR, int, UINT *, UINT *);
  GetDpiForMonitorFn dpi_of = (GetDpiForMonitorFn)GetProcAddress(LoadLibraryW(L"shcore.dll"), "GetDpiForMonitor");
  if (dpi_of) dpi_of(mon, 0, &dx, &dy);
  // (its frame dark, as what it shows is)
  BOOL dark = TRUE;
  DwmSetWindowAttribute(hw, 20 /* DWMWA_USE_IMMERSIVE_DARK_MODE */, &dark, sizeof dark);
  RECT r = {0, 0, MulDiv(w, (int)dx, 96), MulDiv(h, (int)dx, 96)};
  AdjustWindowRectExForDpi(&r, (DWORD)GetWindowLongPtrW(hw, GWL_STYLE), FALSE, (DWORD)GetWindowLongPtrW(hw, GWL_EXSTYLE), dx);
  int ww = r.right - r.left, wh = r.bottom - r.top;
  RECT a = mi.rcWork;
  if (wh > a.bottom - a.top - 24) wh = a.bottom - a.top - 24;
  int x = a.left + ((a.right - a.left) - ww) / 2, y = a.top + ((a.bottom - a.top) - wh) / 2;
  SetWindowPos(hw, NULL, x, y, ww, wh, SWP_NOZORDER | SWP_SHOWWINDOW);
  SetForegroundWindow(hw);
}

// Window `wid` hidden (its frames stop: mbui draws none for a window not shown).
void ps_hide(int32_t wid) {
  HWND h = own_window(wid);
  if (h) ShowWindow(h, SW_HIDE);
}

// Window `wid` kept out of sight while still drawn (DWM's cloak), or let be seen: its frame is there as it is uncloaked.
void ps_cloak(int32_t wid, int32_t on) {
  HWND h = own_window(wid);
  BOOL b = on ? TRUE : FALSE;
  if (h) DwmSetWindowAttribute(h, DWMWA_CLOAK, &b, sizeof b);
}

// Window `wid` over the others (1) or among them (0); `front`: brought before them all now.
void ps_topmost(int32_t wid, int32_t on, int32_t front) {
  HWND h = own_window(wid);
  if (!h) return;
  SetWindowPos(h, on ? HWND_TOPMOST : HWND_NOTOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  if (front) {
    if (!on) SetWindowPos(h, HWND_TOP, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    SetForegroundWindow(h);
  }
}

// Window `wid` seen through: 255 not at all, less as it is fainter (a layered window's alpha, which DWM composes the
// window's DirectComposition content by).
void ps_opacity(int32_t wid, int32_t alpha) {
  HWND h = own_window(wid);
  if (!h) return;
  LONG_PTR ex = GetWindowLongPtrW(h, GWL_EXSTYLE);
  if (alpha >= 255) {
    if (ex & WS_EX_LAYERED) SetWindowLongPtrW(h, GWL_EXSTYLE, ex & ~(LONG_PTR)WS_EX_LAYERED);
    return;
  }
  if (!(ex & WS_EX_LAYERED)) SetWindowLongPtrW(h, GWL_EXSTYLE, ex | WS_EX_LAYERED);
  SetLayeredWindowAttributes(h, 0, (BYTE)(alpha < 20 ? 20 : alpha), LWA_ALPHA);
}

// Where window `wid` is: "x,y,w,h,dpi" (the screen's pixels).
moonbit_bytes_t ps_window_rect(int32_t wid) {
  HWND h = own_window(wid);
  RECT r = {0};
  if (!h || !GetWindowRect(h, &r)) return moonbit_make_bytes(0, 0);
  char s[96];
  snprintf(s, sizeof s, "%ld,%ld,%ld,%ld,%u", r.left, r.top, r.right - r.left, r.bottom - r.top, GetDpiForWindow(h));
  return ps_text(s);
}

// Whether Shift is held now.
int32_t ps_shift_down(void) { return GetKeyState(VK_SHIFT) < 0; }

// The pointer on the screen: "x,y" (pixels).
moonbit_bytes_t ps_pointer(void) {
  POINT p;
  GetCursorPos(&p);
  char s[48];
  snprintf(s, sizeof s, "%ld,%ld", p.x, p.y);
  return ps_text(s);
}

// What the GPU was asked to let go of let go, between frames (the tray window's message: no frame is being drawn): the
// renderer's context's state cleared (an overlay's last picture is still bound there: D3D frees a texture only as
// nothing holds it, and a hidden window draws no frame that binds another) and flushed, the driver's pools of what was
// let go trimmed (a 4K overlay's ~140 MB). The working set is kept (the user, 2026-11-17: given back, the next capture took ~8 ms more,
// ~20 after a while idle, paging it in again). The renderer binds all it draws with each
// frame, so nothing of it is lost.
extern void *mb_render_context(void);
extern void *mb_render_device(void);
static void gpu_trim_now(void) {
  ID3D11DeviceContext *ctx = (ID3D11DeviceContext *)mb_render_context();
  if (ctx) {
    ID3D11DeviceContext_ClearState(ctx);
    ID3D11DeviceContext_Flush(ctx);
  }
  if (!keep_gpu_warm) {
    ID3D11Device *dev = (ID3D11Device *)mb_render_device();
    IDXGIDevice3 *xd = NULL;
    if (dev && SUCCEEDED(ID3D11Device_QueryInterface(dev, &IID_IDXGIDevice3, (void **)&xd))) {
      IDXGIDevice3_Trim(xd);
      IDXGIDevice3_Release(xd);
    }
  }
}

void ps_gpu_flush(void) {
  if (tray_hwnd) PostMessageW(tray_hwnd, WM_PS_TRIM, 0, 0);
}


// "ws,private" in bytes: how much of the machine's memory the run holds.
moonbit_bytes_t ps_memory(void) {
  PROCESS_MEMORY_COUNTERS_EX pm;
  memset(&pm, 0, sizeof pm);
  pm.cb = sizeof pm;
  typedef BOOL(WINAPI * GetPmi)(HANDLE, PROCESS_MEMORY_COUNTERS *, DWORD);
  static GetPmi get;
  if (!get) get = (GetPmi)GetProcAddress(LoadLibraryW(L"kernel32.dll"), "K32GetProcessMemoryInfo");
  if (get) get(GetCurrentProcess(), (PROCESS_MEMORY_COUNTERS *)&pm, sizeof pm);
  char s[64];
  snprintf(s, sizeof s, "%llu,%llu", (unsigned long long)pm.WorkingSetSize, (unsigned long long)pm.PrivateUsage);
  return ps_text(s);
}

// ---- files ----

// The folder PinShot keeps its settings in (%APPDATA%\PinShot), made where it is not.
moonbit_bytes_t ps_data_dir(void) {
  wchar_t *p = NULL;
  wchar_t dir[MAX_PATH * 2] = {0};
  if (SUCCEEDED(SHGetKnownFolderPath(&FOLDERID_RoamingAppData, 0, NULL, &p))) {
    // (a test run's settings its own: the person's left as they are)
    _snwprintf(dir, MAX_PATH * 2 - 1, test_run() ? L"%ls\\PinShot-test" : L"%ls\\PinShot", p);
    CoTaskMemFree(p);
  }
  CreateDirectoryW(dir, NULL);
  return ps_utf8_bytes(dir);
}

// The pictures folder's PinShot (%USERPROFILE%\Pictures\PinShot), not made.
// The desktop's wallpaper, its file ("" none, or a colour alone): a background a capture may be laid on (beautify.mbt).
moonbit_bytes_t ps_wallpaper(void) {
  wchar_t path[MAX_PATH * 2] = {0};
  if (!SystemParametersInfoW(SPI_GETDESKWALLPAPER, MAX_PATH * 2, path, 0) || !path[0] ||
      GetFileAttributesW(path) == INVALID_FILE_ATTRIBUTES)
    return moonbit_make_bytes(0, 0);
  return ps_utf8_bytes(path);
}

moonbit_bytes_t ps_pictures_dir(void) {
  wchar_t *p = NULL;
  wchar_t dir[MAX_PATH * 2] = {0};
  if (SUCCEEDED(SHGetKnownFolderPath(&FOLDERID_Pictures, 0, NULL, &p))) {
    _snwprintf(dir, MAX_PATH * 2 - 1, L"%ls\\PinShot", p);
    CoTaskMemFree(p);
  }
  return ps_utf8_bytes(dir);
}

moonbit_bytes_t ps_read_file(moonbit_bytes_t path) {
  wchar_t *w = ps_wide((const char *)path);
  HANDLE f = CreateFileW(w, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
  free(w);
  if (f == INVALID_HANDLE_VALUE) return moonbit_make_bytes(0, 0);
  LARGE_INTEGER sz;
  if (!GetFileSizeEx(f, &sz) || sz.QuadPart > 512LL * 1024 * 1024) {
    CloseHandle(f);
    return moonbit_make_bytes(0, 0);
  }
  moonbit_bytes_t b = moonbit_make_bytes((int32_t)sz.QuadPart, 0);
  DWORD got = 0;
  BOOL ok = ReadFile(f, b, (DWORD)sz.QuadPart, &got, NULL);
  CloseHandle(f);
  if (!ok || got != (DWORD)sz.QuadPart) return moonbit_make_bytes(0, 0);
  return b;
}

// `data` written to `path` whole (its folder made): 1 when it is there. Written beside and moved over, so a file read
// meanwhile is the old or the new, never half.
int32_t ps_write_file(moonbit_bytes_t path, moonbit_bytes_t data) {
  wchar_t *w = ps_wide((const char *)path);
  size_t n = wcslen(w);
  for (size_t i = 0; i < n; i++)
    if (w[i] == L'\\' && i > 2) {
      w[i] = 0;
      CreateDirectoryW(w, NULL);
      w[i] = L'\\';
    }
  wchar_t *tmp = (wchar_t *)malloc((n + 8) * sizeof(wchar_t));
  _snwprintf(tmp, n + 8, L"%ls.part", w);
  HANDLE f = CreateFileW(tmp, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, 0, NULL);
  int ok = 0;
  if (f != INVALID_HANDLE_VALUE) {
    DWORD put = 0;
    DWORD len = (DWORD)Moonbit_array_length(data);
    ok = WriteFile(f, data, len, &put, NULL) && put == len;
    CloseHandle(f);
    if (ok) ok = MoveFileExW(tmp, w, MOVEFILE_REPLACE_EXISTING) != 0;
    if (!ok) DeleteFileW(tmp);
  }
  free(tmp);
  free(w);
  return ok;
}

// The system's dialog to save a picture: `dir` its folder at first, `name` its name. The path chosen ("" called off).
moonbit_bytes_t ps_save_dialog(int32_t wid, moonbit_bytes_t dir, moonbit_bytes_t name) {
  IFileSaveDialog *d = NULL;
  moonbit_bytes_t out = moonbit_make_bytes(0, 0);
  if (FAILED(CoCreateInstance(&CLSID_FileSaveDialog, NULL, CLSCTX_INPROC_SERVER, &IID_IFileSaveDialog, (void **)&d)))
    return out;
  COMDLG_FILTERSPEC types[] = {{L"PNG (*.png)", L"*.png"}, {L"JPEG (*.jpg)", L"*.jpg;*.jpeg"}};
  IFileSaveDialog_SetFileTypes(d, 2, types);
  const char *ns = (const char *)name;
  size_t nl = strlen(ns);
  int is_jpg = nl >= 4 && _stricmp(ns + nl - 4, ".jpg") == 0;
  IFileSaveDialog_SetFileTypeIndex(d, is_jpg ? 2 : 1);
  IFileSaveDialog_SetDefaultExtension(d, is_jpg ? L"jpg" : L"png");
  wchar_t *wn = ps_wide((const char *)name);
  IFileSaveDialog_SetFileName(d, wn);
  free(wn);
  wchar_t *wd = ps_wide((const char *)dir);
  CreateDirectoryW(wd, NULL);
  IShellItem *folder = NULL;
  if (SUCCEEDED(SHCreateItemFromParsingName(wd, NULL, &IID_IShellItem, (void **)&folder))) {
    IFileSaveDialog_SetFolder(d, folder);
    IShellItem_Release(folder);
  }
  free(wd);
  HWND owner = wid >= 0 ? own_window(wid) : NULL;
  if (SUCCEEDED(IFileSaveDialog_Show(d, owner))) {
    IShellItem *item = NULL;
    if (SUCCEEDED(IFileSaveDialog_GetResult(d, &item))) {
      wchar_t *p = NULL;
      if (SUCCEEDED(IShellItem_GetDisplayName(item, SIGDN_FILESYSPATH, &p))) {
        out = ps_utf8_bytes(p);
        CoTaskMemFree(p);
      }
      IShellItem_Release(item);
    }
  }
  IFileSaveDialog_Release(d);
  return out;
}

// A folder (or a file, selected in its folder) shown in Explorer.
void ps_reveal(moonbit_bytes_t path) {
  wchar_t *w = ps_wide((const char *)path);
  DWORD a = GetFileAttributesW(w);
  if (a != INVALID_FILE_ATTRIBUTES && !(a & FILE_ATTRIBUTE_DIRECTORY)) {
    wchar_t args[MAX_PATH * 2 + 16];
    _snwprintf(args, MAX_PATH * 2 + 15, L"/select,\"%ls\"", w);
    ShellExecuteW(NULL, L"open", L"explorer.exe", args, NULL, SW_SHOWNORMAL);
  } else {
    CreateDirectoryW(w, NULL);
    ShellExecuteW(NULL, L"open", w, NULL, NULL, SW_SHOWNORMAL);
  }
  free(w);
}

// A line in the run's log (%APPDATA%\PinShot\pinshot.log), its local time before it; the log begun anew past 1 MB.
void ps_log(moonbit_bytes_t line) {
  static wchar_t path[MAX_PATH * 2];
  if (!path[0]) {
    wchar_t *p = NULL;
    if (FAILED(SHGetKnownFolderPath(&FOLDERID_RoamingAppData, 0, NULL, &p))) return;
    _snwprintf(path, MAX_PATH * 2 - 1, L"%ls\\PinShot", p);
    CoTaskMemFree(p);
    CreateDirectoryW(path, NULL);
    wcscat_s(path, MAX_PATH * 2, test_run() ? L"\\pinshot-test.log" : L"\\pinshot.log");
    WIN32_FILE_ATTRIBUTE_DATA a;
    if (GetFileAttributesExW(path, GetFileExInfoStandard, &a) && a.nFileSizeLow > 1024 * 1024) DeleteFileW(path);
  }
  HANDLE f = CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_ALWAYS, 0, NULL);
  if (f == INVALID_HANDLE_VALUE) return;
  SYSTEMTIME t;
  GetLocalTime(&t);
  char head[48];
  int n = snprintf(head, sizeof head, "%02d-%02d %02d:%02d:%02d.%03d ", t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond,
                   t.wMilliseconds);
  DWORD put;
  WriteFile(f, head, (DWORD)n, &put, NULL);
  WriteFile(f, line, (DWORD)strlen((const char *)line), &put, NULL);
  WriteFile(f, "\r\n", 2, &put, NULL);
  CloseHandle(f);
}

// The time now as a file's name says it: "20261117-083015".
moonbit_bytes_t ps_stamp(void) {
  SYSTEMTIME t;
  GetLocalTime(&t);
  char s[32];
  snprintf(s, sizeof s, "%04d%02d%02d-%02d%02d%02d", t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond);
  return ps_text(s);
}

// ---- started with Windows ----

#define RUN_KEY L"Software\\Microsoft\\Windows\\CurrentVersion\\Run"

// The system's capture told how a package may keep the screen (capture_wgc.cpp, on its threads): its sessions made
// again on the icon's window's thread, as when the monitors change.
void ps_wgc_wake(void) {
  if (tray_hwnd) PostMessageW(tray_hwnd, WM_DISPLAYCHANGE, 0, 0);
}

// (startup_task.cpp: a package's own way)
int ps_packaged(void);
int ps_startup_on(void);
int ps_startup_set(int on);

int32_t ps_autostart(void) {
  if (ps_packaged()) return ps_startup_on();
  HKEY k;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, RUN_KEY, 0, KEY_READ, &k) != ERROR_SUCCESS) return 0;
  DWORD type = 0, size = 0;
  LONG r = RegQueryValueExW(k, L"PinShot", NULL, &type, NULL, &size);
  RegCloseKey(k);
  return r == ERROR_SUCCESS && size > 0;
}

int32_t ps_set_autostart(int32_t on) {
  if (ps_packaged()) return ps_startup_set(on);
  HKEY k;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, RUN_KEY, 0, KEY_SET_VALUE, &k) != ERROR_SUCCESS) return 0;
  LONG r;
  if (on) {
    wchar_t exe[MAX_PATH], v[MAX_PATH + 4];
    GetModuleFileNameW(NULL, exe, MAX_PATH);
    _snwprintf(v, MAX_PATH + 3, L"\"%ls\"", exe);
    v[MAX_PATH + 3] = 0;
    r = RegSetValueExW(k, L"PinShot", 0, REG_SZ, (const BYTE *)v, (DWORD)((wcslen(v) + 1) * sizeof(wchar_t)));
  } else {
    r = RegDeleteValueW(k, L"PinShot");
    if (r == ERROR_FILE_NOT_FOUND) r = ERROR_SUCCESS;
  }
  RegCloseKey(k);
  return r == ERROR_SUCCESS;
}

// The run's arguments after the program's name, one a line (UTF-8).
moonbit_bytes_t ps_args(void) {
  int argc = 0;
  LPWSTR *argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  if (!argv) return moonbit_make_bytes(0, 0);
  size_t total = 0;
  for (int i = 1; i < argc; i++) total += wcslen(argv[i]) * 3 + 1;
  char *out = (char *)malloc(total + 1);
  size_t len = 0;
  for (int i = 1; i < argc; i++) {
    int n = WideCharToMultiByte(CP_UTF8, 0, argv[i], -1, out + len, (int)(total + 1 - len), NULL, NULL);
    if (n > 0) len += (size_t)n - 1;
    out[len++] = '\n';
  }
  LocalFree(argv);
  moonbit_bytes_t b = ps_bytes(out, len);
  free(out);
  return b;
}

// ---- a pin's menu, the clipboard's picture ----

// A menu at the pointer, over window `wid`: "key\twords\tflags" lines (flags: c checked, g greyed), "-" a separator.
// The key of what was chosen ("" none). Modal: the window's frames wait while it is open.
moonbit_bytes_t ps_popup_menu(int32_t wid, moonbit_bytes_t lines) {
  HWND owner = own_window(wid);
  if (!owner) owner = tray_hwnd;
  HMENU m = CreatePopupMenu();
  char keys[32][32];
  int n = 0;
  int len = (int)Moonbit_array_length(lines);
  const char *s = (const char *)lines;
  int at = 0;
  while (at < len && n < 32) {
    int end = at;
    while (end < len && s[end] != '\n') end++;
    char line[512] = {0};
    int ll = end - at < 511 ? end - at : 511;
    memcpy(line, s + at, (size_t)ll);
    at = end + 1;
    if (!strcmp(line, "-")) {
      AppendMenuW(m, MF_SEPARATOR, 0, NULL);
      continue;
    }
    char *t1 = strchr(line, '\t');
    if (!t1) continue;
    *t1 = 0;
    char *t2 = strchr(t1 + 1, '\t');
    const char *flags = "";
    if (t2) {
      *t2 = 0;
      flags = t2 + 1;
    }
    lstrcpynA(keys[n], line, 32);
    wchar_t *w = ps_wide(t1 + 1);
    UINT f = MF_STRING;
    if (strchr(flags, 'c')) f |= MF_CHECKED;
    if (strchr(flags, 'g')) f |= MF_GRAYED;
    AppendMenuW(m, f, (UINT_PTR)(n + 1), w);
    free(w);
    n++;
  }
  POINT p;
  GetCursorPos(&p);
  SetForegroundWindow(owner);
  int chose = (int)TrackPopupMenuEx(m, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON, p.x, p.y, owner, NULL);
  PostMessageW(owner, WM_NULL, 0, 0);
  DestroyMenu(m);
  if (chose > 0 && chose <= n) return ps_text(keys[chose - 1]);
  return moonbit_make_bytes(0, 0);
}

#pragma pack(push, 1)
typedef struct {
  uint16_t type;
  uint32_t size;
  uint32_t reserved;
  uint32_t offset;
} BmpFileHead;
#pragma pack(pop)

// The picture on the clipboard as a file's bytes: its PNG where it has one, else its bitmap as a BMP file; empty
// where it holds none.
moonbit_bytes_t ps_clipboard_image(void) {
  moonbit_bytes_t out = moonbit_make_bytes(0, 0);
  if (!OpenClipboard(tray_hwnd)) return out;
  UINT png = RegisterClipboardFormatW(L"PNG");
  HANDLE h = GetClipboardData(png);
  if (h) {
    void *p = GlobalLock(h);
    if (p) {
      out = ps_bytes(p, GlobalSize(h));
      GlobalUnlock(h);
    }
  } else if ((h = GetClipboardData(CF_DIB)) != NULL) {
    BITMAPINFOHEADER *bi = (BITMAPINFOHEADER *)GlobalLock(h);
    if (bi) {
      size_t n = GlobalSize(h);
      size_t colors = bi->biClrUsed ? bi->biClrUsed : (bi->biBitCount <= 8 ? (size_t)1 << bi->biBitCount : 0);
      size_t masks = (bi->biCompression == BI_BITFIELDS && bi->biSize == sizeof(BITMAPINFOHEADER)) ? 12 : 0;
      size_t off = sizeof(BmpFileHead) + bi->biSize + masks + colors * 4;
      out = moonbit_make_bytes((int32_t)(sizeof(BmpFileHead) + n), 0);
      BmpFileHead fh = {0x4D42, (uint32_t)(sizeof(BmpFileHead) + n), 0, (uint32_t)off};
      memcpy(out, &fh, sizeof fh);
      memcpy(out + sizeof fh, bi, n);
      GlobalUnlock(h);
    }
  }
  CloseClipboard();
  return out;
}

// This run handing over to the next (update_win.c, the portable exe swapped): its icon taken away, its shortcuts and
// its one-run mutex let go, so the run started next is the one run, not one that asks this one to take the screen.
void ps_run_handover(void) {
  tray_gone();
  tray_on = 0;
  for (int i = 1; i < HK_MOST; i++)
    if (hk_on[i]) {
      UnregisterHotKey(tray_hwnd, i);
      hk_on[i] = 0;
    }
  if (one_run) {
    ReleaseMutex(one_run);
    CloseHandle(one_run);
    one_run = NULL;
  }
  if (tray_hwnd) {
    DestroyWindow(tray_hwnd);
    tray_hwnd = NULL;
  }
}

// The run ended (the icon's 退出): its icon taken away first.
void ps_quit(void) {
  tray_gone();
  fflush(stdout);
  TerminateProcess(GetCurrentProcess(), 0);
  ExitProcess(0);
}

// ---- the shutter's sound ----

// A camera's shutter: a Leica rangefinder's soft click made by ElevenLabs' sound generation (2026-11-18, the person
// chose it of eleven: crisp and not tiresome; the one made here before, noise pushed loud, was harsh). Its silence before
// cut off, 0.35 s, faded out: assets/shutter.wav, in the exe as resource SHUTTER (pinshot.rc). PlaySound plays it
// from the module's own resources, after the call returns.
void ps_shutter(void) {
  PlaySoundW(L"SHUTTER", GetModuleHandleW(NULL), SND_RESOURCE | SND_ASYNC | SND_NODEFAULT);
}

// Whether Windows' own language (the user's, as its menus are in) is Chinese.
int32_t ps_ui_chinese(void) { return PRIMARYLANGID(GetUserDefaultUILanguage()) == LANG_CHINESE; }
