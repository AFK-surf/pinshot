// Windows native host implementation for PinShot:
// - Monitor-under-cursor frozen screen capture (32-bit top-down DIB)
// - Visible window bounds enumeration via DWMWA_EXTENDED_FRAME_BOUNDS
// - Borderless topmost popup window positioning & opacity
// - Global hotkeys (Ctrl+Shift+A, F1) + system tray icon & menu
// - Save PNG dialog, clipboard PNG read, and detached Pin window launch

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <commdlg.h>
#include <dwmapi.h>
#include <shellapi.h>
#include <wincodec.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "moonbit.h"

#pragma comment(lib, "user32.lib")
#pragma comment(lib, "gdi32.lib")
#pragma comment(lib, "dwmapi.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "comdlg32.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "windowscodecs.lib")

static moonbit_bytes_t ps_bytes(const void *p, int32_t n) {
  moonbit_bytes_t b = moonbit_make_bytes(n, 0);
  if (n > 0 && p) memcpy(b, p, (size_t)n);
  return b;
}

static wchar_t *ps_wide(const char *utf8) {
  int n = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, NULL, 0);
  wchar_t *w = (wchar_t *)malloc(sizeof(wchar_t) * (n > 0 ? n : 1));
  if (n > 0) MultiByteToWideChar(CP_UTF8, 0, utf8, -1, w, n);
  else w[0] = 0;
  return w;
}

static char *ps_utf8(const wchar_t *w) {
  int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, NULL, 0, NULL, NULL);
  char *s = (char *)malloc((size_t)(n > 0 ? n : 1));
  if (n > 0) WideCharToMultiByte(CP_UTF8, 0, w, -1, s, n, NULL, NULL);
  else s[0] = 0;
  return s;
}

moonbit_bytes_t ps_args_str(void) {
  int argc = 0;
  LPWSTR *argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  if (!argv) return moonbit_make_bytes(0, 0);
  size_t cap = 1024, len = 0;
  char *out = (char *)malloc(cap);
  for (int i = 1; i < argc; i++) {
    char *u = ps_utf8(argv[i]);
    size_t ul = strlen(u);
    if (len + ul + 2 > cap) {
      cap = (len + ul + 2) * 2;
      out = (char *)realloc(out, cap);
    }
    memcpy(out + len, u, ul);
    len += ul;
    out[len++] = '\n';
    free(u);
  }
  LocalFree(argv);
  moonbit_bytes_t b = ps_bytes(out, (int32_t)len);
  free(out);
  return b;
}

// ---- Frozen screen capture ----

static uint8_t *g_cap_bmp = NULL;
static int32_t g_cap_bmp_len = 0;
static int g_cap_x = 0, g_cap_y = 0, g_cap_w = 0, g_cap_h = 0;
static double g_cap_scale = 1.0;

static HWND ps_find_own_hwnd(void) {
  HWND best = NULL;
  DWORD me = GetCurrentProcessId();
  HWND h = GetTopWindow(NULL);
  while (h) {
    DWORD pid = 0;
    GetWindowThreadProcessId(h, &pid);
    if (pid == me) {
      wchar_t cls[64];
      if (GetClassNameW(h, cls, 64) && wcscmp(cls, L"mbui") == 0) {
        best = h;
        break;
      }
    }
    h = GetNextWindow(h, GW_HWNDNEXT);
  }
  return best;
}

int32_t ps_capture_screen(void) {
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  POINT pt = {0, 0};
  GetCursorPos(&pt);
  HMONITOR mon = MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST);
  MONITORINFOEXW mi;
  mi.cbSize = sizeof(mi);
  if (!GetMonitorInfoW(mon, (LPMONITORINFO)&mi)) return 0;

  int mx = mi.rcMonitor.left;
  int my = mi.rcMonitor.top;
  int mw = mi.rcMonitor.right - mi.rcMonitor.left;
  int mh = mi.rcMonitor.bottom - mi.rcMonitor.top;
  if (mw <= 0 || mh <= 0) return 0;

  HDC screen = GetDC(NULL);
  HDC mem = CreateCompatibleDC(screen);
  BITMAPINFO bmi;
  ZeroMemory(&bmi, sizeof(bmi));
  bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bmi.bmiHeader.biWidth = mw;
  bmi.bmiHeader.biHeight = -mh; // top-down
  bmi.bmiHeader.biPlanes = 1;
  bmi.bmiHeader.biBitCount = 32;
  bmi.bmiHeader.biCompression = BI_RGB;

  void *bits = NULL;
  HBITMAP bmp = CreateDIBSection(screen, &bmi, DIB_RGB_COLORS, &bits, NULL, 0);
  if (!bmp || !bits) {
    if (bmp) DeleteObject(bmp);
    DeleteDC(mem);
    ReleaseDC(NULL, screen);
    return 0;
  }
  HGDIOBJ old = SelectObject(mem, bmp);
  BitBlt(mem, 0, 0, mw, mh, screen, mx, my, SRCCOPY);
  SelectObject(mem, old);

  // Force alpha=255 for all captured pixels (GDI leaves alpha 0 on some surfaces).
  size_t px_bytes = (size_t)mw * (size_t)mh * 4;
  uint8_t *px = (uint8_t *)bits;
  for (size_t i = 3; i < px_bytes; i += 4) px[i] = 255;

  const int hdr = 14 + 40;
  int32_t total = hdr + (int32_t)px_bytes;
  free(g_cap_bmp);
  g_cap_bmp = (uint8_t *)malloc((size_t)total);
  ZeroMemory(g_cap_bmp, hdr);
  g_cap_bmp[0] = 'B';
  g_cap_bmp[1] = 'M';
  memcpy(g_cap_bmp + 2, &total, 4);
  int32_t off = hdr;
  memcpy(g_cap_bmp + 10, &off, 4);
  int32_t info_sz = 40, neg_h = -mh;
  uint16_t planes = 1, bpp = 32;
  memcpy(g_cap_bmp + 14, &info_sz, 4);
  memcpy(g_cap_bmp + 18, &mw, 4);
  memcpy(g_cap_bmp + 22, &neg_h, 4);
  memcpy(g_cap_bmp + 26, &planes, 2);
  memcpy(g_cap_bmp + 28, &bpp, 2);
  memcpy(g_cap_bmp + hdr, bits, px_bytes);
  g_cap_bmp_len = total;

  DeleteObject(bmp);
  DeleteDC(mem);
  ReleaseDC(NULL, screen);

  g_cap_x = mx;
  g_cap_y = my;
  g_cap_w = mw;
  g_cap_h = mh;
  HWND own = ps_find_own_hwnd();
  UINT dpi = own ? GetDpiForWindow(own) : GetDpiForSystem();
  g_cap_scale = dpi > 0 ? (double)dpi / 96.0 : 1.0;
  return 1;
}

moonbit_bytes_t ps_capture_info(void) {
  char buf[128];
  int n = snprintf(buf, sizeof(buf), "%d,%d,%d,%d,%.4f", g_cap_x, g_cap_y, g_cap_w, g_cap_h, g_cap_scale);
  return ps_bytes(buf, n > 0 ? n : 0);
}

moonbit_bytes_t ps_capture_bmp(void) {
  if (!g_cap_bmp || g_cap_bmp_len <= 0) return moonbit_make_bytes(0, 0);
  return ps_bytes(g_cap_bmp, g_cap_bmp_len);
}

// ---- Window enumeration ----

typedef struct {
  char *buf;
  size_t len;
  size_t cap;
  DWORD self_pid;
} WinEnumCtx;

static BOOL CALLBACK ps_enum_proc(HWND h, LPARAM lp) {
  WinEnumCtx *ctx = (WinEnumCtx *)lp;
  if (!IsWindowVisible(h) || IsIconic(h)) return TRUE;
  DWORD pid = 0;
  GetWindowThreadProcessId(h, &pid);
  if (pid == ctx->self_pid) return TRUE;
  BOOL cloaked = FALSE;
  if (SUCCEEDED(DwmGetWindowAttribute(h, DWMWA_CLOAKED, &cloaked, sizeof(cloaked))) && cloaked) return TRUE;
  LONG_PTR ex = GetWindowLongPtrW(h, GWL_EXSTYLE);
  if (ex & WS_EX_TOOLWINDOW) return TRUE;
  RECT r;
  if (FAILED(DwmGetWindowAttribute(h, DWMWA_EXTENDED_FRAME_BOUNDS, &r, sizeof(r)))) {
    if (!GetWindowRect(h, &r)) return TRUE;
  }
  int l = r.left < g_cap_x ? g_cap_x : r.left;
  int t = r.top < g_cap_y ? g_cap_y : r.top;
  int ri = r.right > g_cap_x + g_cap_w ? g_cap_x + g_cap_w : r.right;
  int b = r.bottom > g_cap_y + g_cap_h ? g_cap_y + g_cap_h : r.bottom;
  int w = ri - l, hh = b - t;
  if (w < 24 || hh < 24) return TRUE;
  if (w >= g_cap_w - 2 && hh >= g_cap_h - 2) return TRUE; // skip desktop/shell full window
  char line[128];
  int n = snprintf(line, sizeof(line), "%d,%d,%d,%d\n", l - g_cap_x, t - g_cap_y, w, hh);
  if (n > 0) {
    if (ctx->len + (size_t)n + 1 > ctx->cap) {
      ctx->cap = (ctx->len + (size_t)n + 1) * 2;
      ctx->buf = (char *)realloc(ctx->buf, ctx->cap);
    }
    memcpy(ctx->buf + ctx->len, line, (size_t)n);
    ctx->len += (size_t)n;
  }
  return TRUE;
}

moonbit_bytes_t ps_enum_windows(void) {
  WinEnumCtx ctx = {(char *)malloc(2048), 0, 2048, GetCurrentProcessId()};
  EnumWindows(ps_enum_proc, (LPARAM)&ctx);
  moonbit_bytes_t b = ps_bytes(ctx.buf, (int32_t)ctx.len);
  free(ctx.buf);
  return b;
}

// ---- Popup window management ----

int32_t ps_setup_popup(int32_t x, int32_t y, int32_t w, int32_t h, int32_t topmost) {
  HWND hwnd = ps_find_own_hwnd();
  if (!hwnd) return 0;
  LONG_PTR style = GetWindowLongPtrW(hwnd, GWL_STYLE);
  style &= ~(WS_CAPTION | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX | WS_SYSMENU);
  style |= WS_POPUP;
  SetWindowLongPtrW(hwnd, GWL_STYLE, style);
  LONG_PTR ex = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
  ex |= WS_EX_TOOLWINDOW | WS_EX_LAYERED;
  SetWindowLongPtrW(hwnd, GWL_EXSTYLE, ex);
  SetLayeredWindowAttributes(hwnd, 0, 255, LWA_ALPHA);
  SetWindowPos(hwnd, topmost ? HWND_TOPMOST : HWND_NOTOPMOST, x, y, w, h,
               SWP_FRAMECHANGED | SWP_SHOWWINDOW);
  SetForegroundWindow(hwnd);
  return 1;
}

void ps_show_popup(int32_t x, int32_t y, int32_t w, int32_t h) {
  HWND hwnd = ps_find_own_hwnd();
  if (!hwnd) return;
  SetWindowPos(hwnd, HWND_TOPMOST, x, y, w, h, SWP_SHOWWINDOW | SWP_FRAMECHANGED);
  SetForegroundWindow(hwnd);
}

void ps_hide_window(void) {
  HWND hwnd = ps_find_own_hwnd();
  if (hwnd) ShowWindow(hwnd, SW_HIDE);
}

void ps_set_opacity(int32_t alpha) {
  HWND hwnd = ps_find_own_hwnd();
  if (!hwnd) return;
  if (alpha < 30) alpha = 30;
  if (alpha > 255) alpha = 255;
  SetLayeredWindowAttributes(hwnd, 0, (BYTE)alpha, LWA_ALPHA);
}

// ---- Tray & Global Hotkey ----

#define PS_WM_TRAY (WM_APP + 1)
#define PS_HOTKEY_CAPTURE 101
#define PS_HOTKEY_CAPTURE_F1 102
#define PS_CMD_CAPTURE 201
#define PS_CMD_PIN_CLIP 202
#define PS_CMD_EXIT 203

static volatile LONG g_action = 0;
static volatile LONG g_tray_started = 0;

static LRESULT CALLBACK ps_tray_wndproc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
  if (msg == WM_HOTKEY) {
    if (wp == PS_HOTKEY_CAPTURE || wp == PS_HOTKEY_CAPTURE_F1) {
      InterlockedExchange(&g_action, 1);
    }
    return 0;
  }
  if (msg == PS_WM_TRAY) {
    UINT ev = LOWORD(lp);
    if (ev == WM_LBUTTONUP || ev == NIN_SELECT) {
      InterlockedExchange(&g_action, 1);
    } else if (ev == WM_RBUTTONUP || ev == WM_CONTEXTMENU) {
      POINT pt;
      GetCursorPos(&pt);
      HMENU menu = CreatePopupMenu();
      AppendMenuW(menu, MF_STRING, PS_CMD_CAPTURE, L"\u622a\u5c4f (Ctrl+Shift+A / F1)");
      AppendMenuW(menu, MF_STRING, PS_CMD_PIN_CLIP, L"\u4ece\u526a\u8d34\u677f\u8d34\u56fe");
      AppendMenuW(menu, MF_SEPARATOR, 0, NULL);
      AppendMenuW(menu, MF_STRING, PS_CMD_EXIT, L"\u9000\u51fa PinShot");
      SetForegroundWindow(h);
      UINT cmd = (UINT)TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTALIGN | TPM_BOTTOMALIGN,
                                      pt.x, pt.y, 0, h, NULL);
      DestroyMenu(menu);
      if (cmd == PS_CMD_CAPTURE) InterlockedExchange(&g_action, 1);
      else if (cmd == PS_CMD_PIN_CLIP) InterlockedExchange(&g_action, 2);
      else if (cmd == PS_CMD_EXIT) InterlockedExchange(&g_action, 3);
    }
    return 0;
  }
  return DefWindowProcW(h, msg, wp, lp);
}

static DWORD WINAPI ps_tray_thread(LPVOID unused) {
  (void)unused;
  WNDCLASSEXW wc;
  ZeroMemory(&wc, sizeof(wc));
  wc.cbSize = sizeof(wc);
  wc.lpfnWndProc = ps_tray_wndproc;
  wc.hInstance = GetModuleHandleW(NULL);
  wc.lpszClassName = L"PinShotTrayMsg";
  RegisterClassExW(&wc);

  HWND h = CreateWindowExW(0, wc.lpszClassName, L"PinShotTray", 0, 0, 0, 0, 0,
                           HWND_MESSAGE, NULL, wc.hInstance, NULL);
  RegisterHotKey(h, PS_HOTKEY_CAPTURE, MOD_CONTROL | MOD_SHIFT | MOD_NOREPEAT, 'A');
  RegisterHotKey(h, PS_HOTKEY_CAPTURE_F1, MOD_NOREPEAT, VK_F1);

  NOTIFYICONDATAW nid;
  ZeroMemory(&nid, sizeof(nid));
  nid.cbSize = sizeof(nid);
  nid.hWnd = h;
  nid.uID = 1;
  nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
  nid.uCallbackMessage = PS_WM_TRAY;
  nid.hIcon = LoadIconW(wc.hInstance, MAKEINTRESOURCEW(1));
  if (!nid.hIcon) nid.hIcon = LoadIconW(NULL, (LPCWSTR)IDI_APPLICATION);
  wcsncpy_s(nid.szTip, 128, L"PinShot \u622a\u56fe\u8d34\u56fe (Ctrl+Shift+A / F1)", _TRUNCATE);
  Shell_NotifyIconW(NIM_ADD, &nid);
  nid.uVersion = NOTIFYICON_VERSION_4;
  Shell_NotifyIconW(NIM_SETVERSION, &nid);

  MSG m;
  while (GetMessageW(&m, NULL, 0, 0) > 0) {
    TranslateMessage(&m);
    DispatchMessageW(&m);
  }
  Shell_NotifyIconW(NIM_DELETE, &nid);
  return 0;
}

int32_t ps_tray_start(void) {
  if (InterlockedCompareExchange(&g_tray_started, 1, 0) == 0) {
    HANDLE th = CreateThread(NULL, 0, ps_tray_thread, NULL, 0, NULL);
    if (th) CloseHandle(th);
  }
  return 1;
}

int32_t ps_poll_action(void) {
  return (int32_t)InterlockedExchange(&g_action, 0);
}

// ---- Save PNG dialog & Launch Pin ----

int32_t ps_save_png_dialog(moonbit_bytes_t png, moonbit_bytes_t name) {
  wchar_t *wname = ps_wide((const char *)name);
  wchar_t path[MAX_PATH];
  wcsncpy_s(path, MAX_PATH, wname, _TRUNCATE);
  free(wname);

  OPENFILENAMEW ofn;
  ZeroMemory(&ofn, sizeof(ofn));
  ofn.lStructSize = sizeof(ofn);
  ofn.hwndOwner = ps_find_own_hwnd();
  ofn.lpstrFilter = L"PNG \u56fe\u7247 (*.png)\0*.png\0\0";
  ofn.lpstrFile = path;
  ofn.nMaxFile = MAX_PATH;
  ofn.lpstrDefExt = L"png";
  ofn.Flags = OFN_OVERWRITEPROMPT | OFN_PATHMUSTEXIST;
  if (!GetSaveFileNameW(&ofn)) return 0;

  HANDLE f = CreateFileW(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
  if (f == INVALID_HANDLE_VALUE) return 0;
  DWORD wrote = 0;
  int32_t n = (int32_t)Moonbit_array_length(png);
  BOOL ok = WriteFile(f, png, (DWORD)n, &wrote, NULL);
  CloseHandle(f);
  return (ok && (int32_t)wrote == n) ? 1 : 0;
}

int32_t ps_launch_pin(moonbit_bytes_t png, int32_t x, int32_t y, int32_t w, int32_t h) {
  wchar_t tmp[MAX_PATH];
  GetTempPathW(MAX_PATH, tmp);
  wchar_t file[MAX_PATH];
  swprintf_s(file, MAX_PATH, L"%spinshot-pin-%llu-%lu.png", tmp,
             (unsigned long long)GetTickCount64(), (unsigned long)GetCurrentProcessId());
  HANDLE f = CreateFileW(file, GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
  if (f == INVALID_HANDLE_VALUE) return 0;
  DWORD wrote = 0;
  int32_t n = (int32_t)Moonbit_array_length(png);
  BOOL ok = WriteFile(f, png, (DWORD)n, &wrote, NULL);
  CloseHandle(f);
  if (!ok || (int32_t)wrote != n) return 0;

  wchar_t exe[MAX_PATH];
  GetModuleFileNameW(NULL, exe, MAX_PATH);
  wchar_t cmd[MAX_PATH * 2];
  swprintf_s(cmd, MAX_PATH * 2, L"\"%s\" --pin \"%s\" %d %d %d %d", exe, file, x, y, w, h);

  STARTUPINFOW si;
  PROCESS_INFORMATION pi;
  ZeroMemory(&si, sizeof(si));
  si.cb = sizeof(si);
  ZeroMemory(&pi, sizeof(pi));
  if (!CreateProcessW(exe, cmd, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi)) return 0;
  CloseHandle(pi.hThread);
  CloseHandle(pi.hProcess);
  return 1;
}

moonbit_bytes_t ps_read_file(moonbit_bytes_t path) {
  wchar_t *wp = ps_wide((const char *)path);
  HANDLE f = CreateFileW(wp, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                         NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
  free(wp);
  if (f == INVALID_HANDLE_VALUE) return moonbit_make_bytes(0, 0);
  LARGE_INTEGER sz;
  if (!GetFileSizeEx(f, &sz) || sz.QuadPart <= 0 || sz.QuadPart > 64 * 1024 * 1024) {
    CloseHandle(f);
    return moonbit_make_bytes(0, 0);
  }
  DWORD len = (DWORD)sz.QuadPart;
  moonbit_bytes_t b = moonbit_make_bytes((int32_t)len, 0);
  DWORD got = 0;
  if (!ReadFile(f, b, len, &got, NULL) || got != len) {
    CloseHandle(f);
    return moonbit_make_bytes(0, 0);
  }
  CloseHandle(f);
  return b;
}

void ps_delete_file(moonbit_bytes_t path) {
  wchar_t *wp = ps_wide((const char *)path);
  DeleteFileW(wp);
  free(wp);
}

moonbit_bytes_t ps_clipboard_png(void) {
  if (!OpenClipboard(NULL)) return moonbit_make_bytes(0, 0);
  UINT png_fmt = RegisterClipboardFormatW(L"PNG");
  HANDLE h = png_fmt ? GetClipboardData(png_fmt) : NULL;
  if (h) {
    SIZE_T sz = GlobalSize(h);
    void *p = GlobalLock(h);
    moonbit_bytes_t out = (p && sz > 0) ? ps_bytes(p, (int32_t)sz) : moonbit_make_bytes(0, 0);
    if (p) GlobalUnlock(h);
    CloseClipboard();
    if (Moonbit_array_length(out) > 0) return out;
    if (!OpenClipboard(NULL)) return moonbit_make_bytes(0, 0);
  }
  // Fallback: CF_DIB -> 32-bit BMP bytes (handled by WIC/mbui image loader)
  HANDLE hdib = GetClipboardData(CF_DIB);
  if (!hdib) {
    CloseClipboard();
    return moonbit_make_bytes(0, 0);
  }
  SIZE_T dsz = GlobalSize(hdib);
  uint8_t *dp = (uint8_t *)GlobalLock(hdib);
  moonbit_bytes_t out = moonbit_make_bytes(0, 0);
  if (dp && dsz >= sizeof(BITMAPINFOHEADER)) {
    const BITMAPINFOHEADER *bih = (const BITMAPINFOHEADER *)dp;
    uint32_t clr = bih->biClrUsed;
    if (clr == 0 && bih->biBitCount <= 8) clr = 1u << bih->biBitCount;
    uint32_t off = 14 + bih->biSize + clr * 4 + (bih->biCompression == BI_BITFIELDS ? 12 : 0);
    int32_t total = 14 + (int32_t)dsz;
    out = moonbit_make_bytes(total, 0);
    uint8_t *dst = (uint8_t *)out;
    ZeroMemory(dst, 14);
    dst[0] = 'B';
    dst[1] = 'M';
    memcpy(dst + 2, &total, 4);
    memcpy(dst + 10, &off, 4);
    memcpy(dst + 14, dp, dsz);
  }
  if (dp) GlobalUnlock(hdib);
  CloseClipboard();
  return out;
}
