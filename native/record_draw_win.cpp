// Mouse-click ripples and the keys pressed, shown over the region being recorded (Windows): a transparent,
// click-through, per-pixel-alpha layered window (UpdateLayeredWindow + GDI+), deliberately NOT excluded from capture so
// the recording's WGC session takes them with their anti-aliased alpha.
//
// Nothing of it exists unless it is asked for (ps_rec_input_show) while a recording runs: no window, no GDI+, no hooks.
// The low-level hooks only note what happened and post the window a message (a hook's callback holds up every input of
// the system while it runs: it never draws). It is drawn only while something moves: a ripple's 400 ms, a key's fade;
// while a key's caps are held still (1.1 s) one timer wakes it as the fade begins. Only the box round what is drawn is
// put on the screen (the window moved and sized to it), never the whole region.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <dwmapi.h>
#include <objidl.h>
#include <gdiplus.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <math.h>
#include <string>
#include <vector>
#include <algorithm>

#pragma comment(lib, "gdiplus.lib")
#pragma comment(lib, "dwmapi.lib")

namespace {

struct ClickRipple {
  float x, y;  // in the region
  uint32_t rgb;
  ULONGLONG start_ms;
};

static const UINT_PTR ANIM_TIMER_ID = 0x5244;
static const UINT WM_RD_DRAW = WM_APP + 0x52;
static const DWORD RIPPLE_DURATION_MS = 400;
static const float RIPPLE_REACH = 36.0f;  // a ripple's most radius (32) and its ring's width, round its centre
static const DWORD KEY_HOLD_MS = 1100;
static const DWORD KEY_FADE_MS = 350;

struct DrawState {
  // asked for
  int x = 0, y = 0, w = 0, h = 0;  // the region, in the screen's pixels
  bool have_rect = false;
  bool input_show = false;
  bool rec_active = false;

  // there only while asked for and recording
  HWND hwnd = NULL;
  ULONG_PTR gdip_token = 0;
  bool gdip_ok = false;
  Gdiplus::FontFamily *family = NULL;
  Gdiplus::Font *font = NULL;
  float font_cap_h = 0.0f;
  Gdiplus::StringFormat *centred = NULL;
  HHOOK mouse_hook = NULL;
  HHOOK key_hook = NULL;
  bool draw_posted = false;
  bool timer_on = false;

  HDC dib_dc = NULL;
  HBITMAP dib_bmp = NULL;
  HGDIOBJ dib_old = NULL;
  void *dib_bits = NULL;
  int dib_w = 0, dib_h = 0;
  bool shown = false;

  std::vector<ClickRipple> ripples;
  std::vector<std::wstring> caps;
  std::vector<float> cap_ws;  // each cap's width, measured as the caps change
  bool caps_measured = false;
  ULONGLONG key_start_ms = 0;
  bool key_active = false;
} D;

static Gdiplus::Color gdip_color(uint32_t rgb, BYTE a) {
  return Gdiplus::Color(a, (BYTE)((rgb >> 16) & 0xFF), (BYTE)((rgb >> 8) & 0xFF), (BYTE)(rgb & 0xFF));
}

static void add_round_rect(Gdiplus::GraphicsPath &path, float x, float y, float w, float h, float r) {
  float room = std::min(w, h) * 0.5f;
  float rc = std::max(0.0f, std::min(r, room));
  if (rc <= 0.01f) {
    path.AddRectangle(Gdiplus::RectF(x, y, w, h));
    return;
  }
  float s = std::max(0.0f, std::min(1.0f, (room - rc) / (0.25f * rc)));
  float rr = std::min(rc * (1.0f + 0.25f * s), room);
  float kappa = 0.55228475f + (0.7621f - 0.55228475f) * s;
  float c = rr * (1.0f - kappa);
  float x1 = x + w, y1 = y + h;
  path.StartFigure();
  path.AddLine(x + rr, y, x1 - rr, y);
  path.AddBezier(x1 - rr, y, x1 - c, y, x1, y + c, x1, y + rr);
  path.AddLine(x1, y + rr, x1, y1 - rr);
  path.AddBezier(x1, y1 - rr, x1, y1 - c, x1 - c, y1, x1 - rr, y1);
  path.AddLine(x1 - rr, y1, x + rr, y1);
  path.AddBezier(x + rr, y1, x + c, y1, x, y1 - c, x, y1 - rr);
  path.AddLine(x, y1 - rr, x, y + rr);
  path.AddBezier(x, y + rr, x, y + c, x + c, y, x + rr, y);
  path.CloseFigure();
}

static float cap_height(void) { return (D.h < 320) ? 28.0f : 34.0f; }

static void free_dib(void) {
  if (D.dib_dc && D.dib_old) SelectObject(D.dib_dc, D.dib_old);
  if (D.dib_bmp) DeleteObject(D.dib_bmp);
  if (D.dib_dc) DeleteDC(D.dib_dc);
  D.dib_dc = NULL;
  D.dib_bmp = NULL;
  D.dib_old = NULL;
  D.dib_bits = NULL;
  D.dib_w = D.dib_h = 0;
}

// A DIB at least w by h (grown, never shrunk, while it is shown).
static bool ensure_dib(int w, int h) {
  if (D.dib_bits && D.dib_w >= w && D.dib_h >= h) return true;
  int nw = std::max(w, D.dib_w), nh = std::max(h, D.dib_h);
  free_dib();
  HDC screen = GetDC(NULL);
  D.dib_dc = CreateCompatibleDC(screen);
  BITMAPINFO bi = {};
  bi.bmiHeader.biSize = sizeof bi.bmiHeader;
  bi.bmiHeader.biWidth = nw;
  bi.bmiHeader.biHeight = -nh;
  bi.bmiHeader.biPlanes = 1;
  bi.bmiHeader.biBitCount = 32;
  bi.bmiHeader.biCompression = BI_RGB;
  if (D.dib_dc) D.dib_bmp = CreateDIBSection(screen, &bi, DIB_RGB_COLORS, &D.dib_bits, NULL, 0);
  ReleaseDC(NULL, screen);
  if (!D.dib_bmp || !D.dib_bits) {
    free_dib();
    return false;
  }
  D.dib_old = SelectObject(D.dib_dc, D.dib_bmp);
  D.dib_w = nw;
  D.dib_h = nh;
  return true;
}

static void prune(ULONGLONG now) {
  D.ripples.erase(std::remove_if(D.ripples.begin(), D.ripples.end(),
                                 [now](const ClickRipple &r) { return now >= r.start_ms + RIPPLE_DURATION_MS; }),
                  D.ripples.end());
  if (D.key_active && now >= D.key_start_ms + KEY_HOLD_MS + KEY_FADE_MS) {
    D.key_active = false;
    D.caps.clear();
    D.cap_ws.clear();
    D.caps_measured = false;
  }
}

static void measure_caps(Gdiplus::Graphics &g) {
  if (D.caps_measured) return;
  D.cap_ws.clear();
  float ch = cap_height();
  for (const auto &lbl : D.caps) {
    Gdiplus::RectF mr;
    g.MeasureString(lbl.c_str(), -1, D.font, Gdiplus::PointF(0, 0), &mr);
    D.cap_ws.push_back(std::max(ch, mr.Width + 18.0f));
  }
  D.caps_measured = true;
}

// The keycaps' row, in the region: x, y, w, h (w 0 where there are none).
static void caps_box(float &bx, float &by, float &bw, float &bh) {
  bx = by = bw = bh = 0.0f;
  if (!D.key_active || D.cap_ws.empty()) return;
  float ch = cap_height(), gap = 6.0f, total = 0.0f;
  for (float cw : D.cap_ws) total += cw;
  total += gap * (float)(D.cap_ws.size() - 1);
  float cy = (float)D.h - ch - std::min(28.0f, (float)D.h * 0.08f);
  if (cy < 8.0f) cy = 8.0f;
  bx = ((float)D.w - total) * 0.5f;
  by = cy;
  bw = total;
  bh = ch + 3.0f;  // (and the shadow below)
}

// A test run (PINSHOT_TEST) told of each picture put up (PINSHOT_TEST_RECDRAW: the file a line each is written to),
// what a check counts and times; the last picture kept as a BMP beside it.
static void test_note(ULONGLONG now, int x, int y, int w, int h) {
  static int checked = 0;
  static char path[MAX_PATH];
  if (!checked) {
    checked = 1;
    if (!GetEnvironmentVariableA("PINSHOT_TEST", NULL, 0) ||
        !GetEnvironmentVariableA("PINSHOT_TEST_RECDRAW", path, MAX_PATH))
      path[0] = 0;
  }
  if (!path[0]) return;
  FILE *f = NULL;
  if (fopen_s(&f, path, "a") == 0 && f) {
    fprintf(f, "%llu %d,%d %dx%d ripples=%d key=%d\n", (unsigned long long)now, x, y, w, h, (int)D.ripples.size(),
            D.key_active ? 1 : 0);
    fclose(f);
  }
  char bmp[MAX_PATH + 8];
  snprintf(bmp, sizeof bmp, "%s.bmp", path);
  if (fopen_s(&f, bmp, "wb") == 0 && f) {
    BITMAPFILEHEADER fh = {};
    BITMAPINFOHEADER bi = {};
    bi.biSize = sizeof bi;
    bi.biWidth = w;
    bi.biHeight = -h;
    bi.biPlanes = 1;
    bi.biBitCount = 32;
    fh.bfType = 0x4D42;
    fh.bfOffBits = sizeof fh + sizeof bi;
    fh.bfSize = fh.bfOffBits + (DWORD)(w * h * 4);
    fwrite(&fh, sizeof fh, 1, f);
    fwrite(&bi, sizeof bi, 1, f);
    for (int row = 0; row < h; row++) fwrite((uint8_t *)D.dib_bits + (size_t)row * D.dib_w * 4, 4, (size_t)w, f);
    fclose(f);
  }
}

static void hide_layer(void) {
  if (D.timer_on && D.hwnd) KillTimer(D.hwnd, ANIM_TIMER_ID);
  D.timer_on = false;
  if (D.shown && D.hwnd) ShowWindow(D.hwnd, SW_HIDE);
  D.shown = false;
  free_dib();
}

static void schedule(ULONGLONG now) {
  UINT next = 0;
  if (!D.ripples.empty()) {
    next = 16;
  } else if (D.key_active) {
    ULONGLONG fade_at = D.key_start_ms + KEY_HOLD_MS;
    next = now >= fade_at ? 16 : (UINT)std::max<ULONGLONG>(1, fade_at - now);
  }
  if (!next) {
    if (D.timer_on) KillTimer(D.hwnd, ANIM_TIMER_ID);
    D.timer_on = false;
    return;
  }
  SetTimer(D.hwnd, ANIM_TIMER_ID, next, NULL);
  D.timer_on = true;
}

static void redraw_layer(void) {
  D.draw_posted = false;
  if (!D.hwnd || !D.gdip_ok || D.w <= 0 || D.h <= 0) return;
  ULONGLONG now = GetTickCount64();
  prune(now);
  if (D.ripples.empty() && !D.key_active) {
    hide_layer();
    return;
  }

  // what is drawn's box, in the region
  float x0 = 1e9f, y0 = 1e9f, x1 = -1e9f, y1 = -1e9f;
  for (const auto &rp : D.ripples) {
    x0 = std::min(x0, rp.x - RIPPLE_REACH);
    y0 = std::min(y0, rp.y - RIPPLE_REACH);
    x1 = std::max(x1, rp.x + RIPPLE_REACH);
    y1 = std::max(y1, rp.y + RIPPLE_REACH);
  }
  if (D.key_active && !D.caps_measured) {
    // (the caps measured on a graphics of the screen's: no DIB needed for it)
    HDC screen = GetDC(NULL);
    {
      Gdiplus::Graphics mg(screen);
      measure_caps(mg);
    }
    ReleaseDC(NULL, screen);
  }
  float kx, ky, kw, kh;
  caps_box(kx, ky, kw, kh);
  if (kw > 0.0f) {
    x0 = std::min(x0, kx - 2.0f);
    y0 = std::min(y0, ky - 2.0f);
    x1 = std::max(x1, kx + kw + 2.0f);
    y1 = std::max(y1, ky + kh + 2.0f);
  }
  int bx0 = std::max(0, (int)floorf(x0)), by0 = std::max(0, (int)floorf(y0));
  int bx1 = std::min(D.w, (int)ceilf(x1)), by1 = std::min(D.h, (int)ceilf(y1));
  int bw = bx1 - bx0, bh = by1 - by0;
  if (bw <= 0 || bh <= 0 || !ensure_dib(bw, bh)) {
    hide_layer();
    return;
  }
  for (int row = 0; row < bh; row++) memset((uint8_t *)D.dib_bits + (size_t)row * D.dib_w * 4, 0, (size_t)bw * 4);
  {
    Gdiplus::Graphics g(D.dib_dc);
    g.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
    g.SetTextRenderingHint(Gdiplus::TextRenderingHintAntiAliasGridFit);
    g.TranslateTransform((float)-bx0, (float)-by0);
    for (const auto &rp : D.ripples) {
      if (now < rp.start_ms) continue;
      float t = (float)(now - rp.start_ms) / (float)RIPPLE_DURATION_MS;
      if (t >= 1.0f) continue;
      float ease = 1.0f - (1.0f - t) * (1.0f - t);
      float rad = 8.0f + 24.0f * ease;
      Gdiplus::SolidBrush fill(gdip_color(rp.rgb, (BYTE)((1.0f - t) * 60.0f)));
      g.FillEllipse(&fill, rp.x - rad, rp.y - rad, rad * 2.0f, rad * 2.0f);
      Gdiplus::Pen pen(gdip_color(rp.rgb, (BYTE)((1.0f - t) * 220.0f)), 2.5f);
      g.DrawEllipse(&pen, rp.x - rad, rp.y - rad, rad * 2.0f, rad * 2.0f);
    }
    if (kw > 0.0f) {
      ULONGLONG age = now - D.key_start_ms;
      float alpha = age > KEY_HOLD_MS ? 1.0f - (float)(age - KEY_HOLD_MS) / (float)KEY_FADE_MS : 1.0f;
      if (alpha > 0.01f) {
        float ch = cap_height(), cx = kx;
        Gdiplus::SolidBrush sh_br(Gdiplus::Color((BYTE)(95.0f * alpha), 0, 0, 0));
        Gdiplus::SolidBrush bg_br(Gdiplus::Color((BYTE)(230.0f * alpha), 24, 26, 31));
        Gdiplus::Pen rim(Gdiplus::Color((BYTE)(56.0f * alpha), 255, 255, 255), 1.2f);
        Gdiplus::SolidBrush ink(Gdiplus::Color((BYTE)(245.0f * alpha), 255, 255, 255));
        for (size_t i = 0; i < D.caps.size() && i < D.cap_ws.size(); i++) {
          float cw = D.cap_ws[i];
          Gdiplus::GraphicsPath sh_path;
          add_round_rect(sh_path, cx, ky + 2.5f, cw, ch, 8.0f);
          g.FillPath(&sh_br, &sh_path);
          Gdiplus::GraphicsPath bg_path;
          add_round_rect(bg_path, cx, ky, cw, ch, 8.0f);
          g.FillPath(&bg_br, &bg_path);
          g.DrawPath(&rim, &bg_path);
          Gdiplus::RectF box(cx, ky + 0.5f, cw, ch);
          g.DrawString(D.caps[i].c_str(), -1, D.font, box, D.centred, &ink);
          cx += cw + 6.0f;
        }
      }
    }
  }
  SIZE sz = {bw, bh};
  POINT src = {0, 0};
  POINT dst = {D.x + bx0, D.y + by0};
  BLENDFUNCTION bf = {};
  bf.BlendOp = AC_SRC_OVER;
  bf.SourceConstantAlpha = 255;
  bf.AlphaFormat = AC_SRC_ALPHA;
  UpdateLayeredWindow(D.hwnd, NULL, &dst, &sz, D.dib_dc, &src, 0, &bf, ULW_ALPHA);
  if (!D.shown) {
    ShowWindow(D.hwnd, SW_SHOWNOACTIVATE);
    D.shown = true;
  }
  schedule(now);
  test_note(now, bx0, by0, bw, bh);
}

static void ask_draw(void) {
  if (D.hwnd && !D.draw_posted) {
    D.draw_posted = true;
    PostMessageW(D.hwnd, WM_RD_DRAW, 0, 0);
  }
}

static std::wstring vk_label(DWORD vk, DWORD scan) {
  switch (vk) {
    case VK_RETURN: return L"Enter";
    case VK_ESCAPE: return L"Esc";
    case VK_SPACE: return L"Space";
    case VK_TAB: return L"Tab";
    case VK_BACK: return L"Backspace";
    case VK_DELETE: return L"Del";
    case VK_INSERT: return L"Ins";
    case VK_HOME: return L"Home";
    case VK_END: return L"End";
    case VK_PRIOR: return L"PgUp";
    case VK_NEXT: return L"PgDn";
    case VK_UP: return L"\x2191";
    case VK_DOWN: return L"\x2193";
    case VK_LEFT: return L"\x2190";
    case VK_RIGHT: return L"\x2192";
    case VK_CAPITAL: return L"Caps";
    case VK_SNAPSHOT: return L"PrtSc";
    default: break;
  }
  if (vk >= VK_F1 && vk <= VK_F24) {
    wchar_t b[8];
    swprintf_s(b, L"F%u", (unsigned)(vk - VK_F1 + 1));
    return b;
  }
  if ((vk >= '0' && vk <= '9') || (vk >= 'A' && vk <= 'Z')) return std::wstring(1, (wchar_t)vk);
  wchar_t name[32] = {};
  LONG lp = (LONG)((scan & 0xFF) << 16);
  if (GetKeyNameTextW(lp, name, 32) > 0) return name;
  return L"";
}

static bool is_modifier_vk(DWORD vk) {
  return vk == VK_CONTROL || vk == VK_LCONTROL || vk == VK_RCONTROL || vk == VK_SHIFT || vk == VK_LSHIFT ||
         vk == VK_RSHIFT || vk == VK_MENU || vk == VK_LMENU || vk == VK_RMENU || vk == VK_LWIN || vk == VK_RWIN;
}

// (the hooks run on the thread that set them, the UI's, as it waits for messages: they only note and post)
static LRESULT CALLBACK ll_mouse_proc(int code, WPARAM wp, LPARAM lp) {
  if (code == HC_ACTION && D.hwnd && (wp == WM_LBUTTONDOWN || wp == WM_RBUTTONDOWN || wp == WM_MBUTTONDOWN)) {
    const MSLLHOOKSTRUCT *ms = (const MSLLHOOKSTRUCT *)lp;
    if (ms->pt.x >= D.x && ms->pt.x < D.x + D.w && ms->pt.y >= D.y && ms->pt.y < D.y + D.h) {
      ClickRipple rp;
      rp.x = (float)(ms->pt.x - D.x);
      rp.y = (float)(ms->pt.y - D.y);
      rp.rgb = (wp == WM_RBUTTONDOWN) ? 0xF5A524u : (wp == WM_MBUTTONDOWN ? 0x4CC38Au : 0x2F9BFFu);
      rp.start_ms = GetTickCount64();
      D.ripples.push_back(rp);
      if (D.ripples.size() > 8) D.ripples.erase(D.ripples.begin());
      ask_draw();
    }
  }
  return CallNextHookEx(NULL, code, wp, lp);
}

static LRESULT CALLBACK ll_key_proc(int code, WPARAM wp, LPARAM lp) {
  if (code == HC_ACTION && D.hwnd && (wp == WM_KEYDOWN || wp == WM_SYSKEYDOWN)) {
    const KBDLLHOOKSTRUCT *kb = (const KBDLLHOOKSTRUCT *)lp;
    if (!is_modifier_vk(kb->vkCode)) {
      std::wstring lbl = vk_label(kb->vkCode, kb->scanCode);
      if (!lbl.empty()) {
        std::vector<std::wstring> caps;
        if (GetAsyncKeyState(VK_CONTROL) & 0x8000) caps.push_back(L"Ctrl");
        if (GetAsyncKeyState(VK_MENU) & 0x8000) caps.push_back(L"Alt");
        if (GetAsyncKeyState(VK_SHIFT) & 0x8000) caps.push_back(L"Shift");
        if ((GetAsyncKeyState(VK_LWIN) & 0x8000) || (GetAsyncKeyState(VK_RWIN) & 0x8000)) caps.push_back(L"Win");
        caps.push_back(lbl);
        D.caps = std::move(caps);
        D.caps_measured = false;
        D.key_start_ms = GetTickCount64();
        D.key_active = true;
        ask_draw();
      }
    }
  }
  return CallNextHookEx(NULL, code, wp, lp);
}

static LRESULT CALLBACK rec_draw_proc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
  switch (msg) {
    case WM_RD_DRAW: redraw_layer(); return 0;
    case WM_APP + 0x53:  // (a test run's click, at x, y of the screen: as the mouse hook would note it)
    case WM_APP + 0x54:  // (a test run's key, wp its virtual key: as the keyboard hook would)
      if (GetEnvironmentVariableA("PINSHOT_TEST", NULL, 0)) {
        if (msg == WM_APP + 0x53) {
          MSLLHOOKSTRUCT ms = {};
          ms.pt.x = (LONG)(short)LOWORD(lp);
          ms.pt.y = (LONG)(short)HIWORD(lp);
          ll_mouse_proc(HC_ACTION, WM_LBUTTONDOWN, (LPARAM)&ms);
        } else {
          KBDLLHOOKSTRUCT kb = {};
          kb.vkCode = (DWORD)wp;
          kb.scanCode = MapVirtualKeyW((UINT)wp, MAPVK_VK_TO_VSC);
          ll_key_proc(HC_ACTION, WM_KEYDOWN, (LPARAM)&kb);
        }
      }
      return 0;
    case WM_TIMER:
      if (wp == ANIM_TIMER_ID) {
        KillTimer(h, ANIM_TIMER_ID);
        D.timer_on = false;
        redraw_layer();
        return 0;
      }
      break;
    case WM_MOUSEACTIVATE: return MA_NOACTIVATE;
    case WM_NCHITTEST: return HTTRANSPARENT;
  }
  return DefWindowProcW(h, msg, wp, lp);
}

// The window, GDI+ and the hooks made (asked for, recording, the region known) or let go.
static void sync_overlay(void) {
  bool want = D.have_rect && D.rec_active && D.input_show;
  if (want && !D.hwnd) {
    Gdiplus::GdiplusStartupInput in;
    if (Gdiplus::GdiplusStartup(&D.gdip_token, &in, NULL) != Gdiplus::Ok) return;
    D.gdip_ok = true;
    D.family = new Gdiplus::FontFamily(L"Segoe UI");
    D.font = new Gdiplus::Font(D.family, cap_height() * 0.48f, Gdiplus::FontStyleBold, Gdiplus::UnitPixel);
    D.centred = new Gdiplus::StringFormat();
    D.centred->SetAlignment(Gdiplus::StringAlignmentCenter);
    D.centred->SetLineAlignment(Gdiplus::StringAlignmentCenter);
    static bool registered = false;
    if (!registered) {
      WNDCLASSEXW wc = {};
      wc.cbSize = sizeof wc;
      wc.lpfnWndProc = rec_draw_proc;
      wc.hInstance = GetModuleHandleW(NULL);
      wc.lpszClassName = L"PinShot.RecDraw";
      wc.hCursor = LoadCursor(NULL, IDC_ARROW);
      RegisterClassExW(&wc);
      registered = true;
    }
    D.hwnd = CreateWindowExW(WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
                             L"PinShot.RecDraw", L"", WS_POPUP, D.x, D.y, 1, 1, NULL, NULL, GetModuleHandleW(NULL),
                             NULL);
    if (D.hwnd) {
      // (a test run kept out of sight: drawn, never seen)
      if (GetEnvironmentVariableA("PINSHOT_TEST_CLOAKED", NULL, 0)) {
        BOOL cloak = TRUE;
        DwmSetWindowAttribute(D.hwnd, DWMWA_CLOAK, &cloak, sizeof cloak);
      }
      D.mouse_hook = SetWindowsHookExW(WH_MOUSE_LL, ll_mouse_proc, GetModuleHandleW(NULL), 0);
      D.key_hook = SetWindowsHookExW(WH_KEYBOARD_LL, ll_key_proc, GetModuleHandleW(NULL), 0);
    }
  } else if (!want && (D.hwnd || D.gdip_ok)) {
    if (D.mouse_hook) UnhookWindowsHookEx(D.mouse_hook);
    if (D.key_hook) UnhookWindowsHookEx(D.key_hook);
    D.mouse_hook = D.key_hook = NULL;
    hide_layer();
    if (D.hwnd) DestroyWindow(D.hwnd);
    D.hwnd = NULL;
    D.draw_posted = false;
    D.ripples.clear();
    D.ripples.shrink_to_fit();
    D.caps.clear();
    D.cap_ws.clear();
    D.caps_measured = false;
    D.key_active = false;
    delete D.centred;
    delete D.font;
    delete D.family;
    D.centred = NULL;
    D.font = NULL;
    D.family = NULL;
    if (D.gdip_ok) Gdiplus::GdiplusShutdown(D.gdip_token);
    D.gdip_ok = false;
    D.gdip_token = 0;
  }
}

}  // namespace

void rec_draw_open(int x, int y, int w, int h) {
  D.rec_active = false;
  sync_overlay();
  D.x = x;
  D.y = y;
  D.w = w;
  D.h = h;
  D.have_rect = w > 0 && h > 0;
}

void rec_draw_set_recording(int on) {
  D.rec_active = (on != 0);
  sync_overlay();
}

void rec_draw_close(void) {
  D.rec_active = false;
  D.have_rect = false;
  sync_overlay();
}

extern "C" {

void ps_rec_input_show(int32_t on) {
  D.input_show = (on != 0);
  sync_overlay();
}

}  // extern "C"
