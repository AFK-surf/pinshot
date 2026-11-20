// Transparent per-pixel-alpha live annotation + mouse-click ripple + keyboard shortcut overlay for screen recording
// (Windows). Uses UpdateLayeredWindow + GDI+ over the exact recording region (x, y, w, h).
// Deliberately NOT marked WDA_EXCLUDEFROMCAPTURE so WGC captures drawn annotations, click ripples, and keycaps natively
// with crisp anti-aliased alpha. When tool == 0 (passthrough), WS_EX_TRANSPARENT lets all mouse input reach the apps
// underneath. Low-level hooks are installed ONLY while actively recording AND input overlay is enabled.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <windowsx.h>
#include <objidl.h>
#include <gdiplus.h>
#include <stdint.h>
#include <stdio.h>
#include <math.h>
#include <string>
#include <vector>
#include <algorithm>

#pragma comment(lib, "gdiplus.lib")

extern "C" void mb_post(const char *channel, const char *json, size_t len, const uint8_t *bytes, size_t blen);

namespace {

struct DrawPt {
  float x, y;
};

struct DrawMark {
  int tool;           // 1=rect, 2=arrow, 3=pen, 4=number, 5=oval
  uint32_t rgb;       // 0xRRGGBB
  float width;
  int num;
  std::vector<DrawPt> pts;
};

struct ClickRipple {
  float x, y;
  uint32_t rgb;
  ULONGLONG start_ms;
};

struct KeyOverlay {
  std::vector<std::wstring> caps;
  ULONGLONG start_ms = 0;
  bool active = false;
};

static const UINT_PTR ANIM_TIMER_ID = 0x5244;
static const DWORD RIPPLE_DURATION_MS = 400;
static const DWORD KEY_HOLD_MS = 1100;
static const DWORD KEY_FADE_MS = 350;

struct DrawState {
  ULONG_PTR gdip_token = 0;
  bool gdip_ok = false;
  HWND hwnd = NULL;
  int x = 0, y = 0, w = 0, h = 0;
  int tool = 0;       // 0=passthrough, 1=rect, 2=arrow, 3=pen, 4=number, 5=oval
  uint32_t rgb = 0xD84A2F;
  int next_num = 1;
  bool drawing = false;
  DrawMark draft = {};
  std::vector<DrawMark> marks;

  // Cached layered DIB backing store (lazily created on first visible draw, freed when hidden/closed)
  HDC dib_dc = NULL;
  HBITMAP dib_bmp = NULL;
  HGDIOBJ dib_old = NULL;
  void *dib_bits = NULL;
  int dib_w = 0, dib_h = 0;

  // Optional mouse click ripple & keycap overlay
  bool input_show = false;
  bool rec_active = false;
  HHOOK mouse_hook = NULL;
  HHOOK key_hook = NULL;
  bool timer_on = false;
  std::vector<ClickRipple> ripples;
  KeyOverlay key_ov = {};
} D;

static void notify_draw_state(int tool, int count) {
  char buf[96];
  int n = snprintf(buf, sizeof buf, "{\"do\":\"rec-draw\",\"tool\":%d,\"count\":%d}", tool, count);
  if (n > 0) mb_post("ps", buf, (size_t)n, NULL, 0);
}

static void ensure_gdip() {
  if (D.gdip_ok) return;
  Gdiplus::GdiplusStartupInput in;
  if (Gdiplus::GdiplusStartup(&D.gdip_token, &in, NULL) == Gdiplus::Ok) D.gdip_ok = true;
}

static Gdiplus::Color gdip_color(uint32_t rgb, BYTE a = 255) {
  return Gdiplus::Color(a, (BYTE)((rgb >> 16) & 0xFF), (BYTE)((rgb >> 8) & 0xFF), (BYTE)(rgb & 0xFF));
}

static void add_round_rect(Gdiplus::GraphicsPath &path, float x, float y, float w, float h, float r) {
  float d = std::min(r * 2.0f, std::min(w, h));
  path.AddArc(x, y, d, d, 180.0f, 90.0f);
  path.AddArc(x + w - d, y, d, d, 270.0f, 90.0f);
  path.AddArc(x + w - d, y + h - d, d, d, 0.0f, 90.0f);
  path.AddArc(x, y + h - d, d, d, 90.0f, 90.0f);
  path.CloseFigure();
}

static void draw_one_mark(Gdiplus::Graphics &g, const DrawMark &m) {
  if (m.pts.empty()) return;
  Gdiplus::Color col = gdip_color(m.rgb, 255);
  Gdiplus::Pen pen(col, m.width);
  pen.SetStartCap(Gdiplus::LineCapRound);
  pen.SetEndCap(Gdiplus::LineCapRound);
  pen.SetLineJoin(Gdiplus::LineJoinRound);

  if (m.tool == 1 && m.pts.size() >= 2) {
    float x0 = std::min(m.pts.front().x, m.pts.back().x);
    float y0 = std::min(m.pts.front().y, m.pts.back().y);
    float rw = fabsf(m.pts.back().x - m.pts.front().x);
    float rh = fabsf(m.pts.back().y - m.pts.front().y);
    if (rw >= 2.0f && rh >= 2.0f) g.DrawRectangle(&pen, x0, y0, rw, rh);
  } else if (m.tool == 5 && m.pts.size() >= 2) {
    float x0 = std::min(m.pts.front().x, m.pts.back().x);
    float y0 = std::min(m.pts.front().y, m.pts.back().y);
    float rw = fabsf(m.pts.back().x - m.pts.front().x);
    float rh = fabsf(m.pts.back().y - m.pts.front().y);
    if (rw >= 2.0f && rh >= 2.0f) g.DrawEllipse(&pen, x0, y0, rw, rh);
  } else if (m.tool == 2 && m.pts.size() >= 2) {
    float x0 = m.pts.front().x, y0 = m.pts.front().y;
    float x1 = m.pts.back().x, y1 = m.pts.back().y;
    float dx = x1 - x0, dy = y1 - y0;
    float len = sqrtf(dx * dx + dy * dy);
    if (len < 4.0f) return;
    float ux = dx / len, uy = dy / len;
    float head = std::min(std::max(14.0f, m.width * 4.2f), len * 0.45f);
    float back = head * 0.82f;
    float wing = head * 0.48f;
    float sx = x1 - ux * back, sy = y1 - uy * back;
    g.DrawLine(&pen, x0, y0, sx, sy);
    Gdiplus::PointF tri[3] = {
        {x1, y1},
        {sx - uy * wing, sy + ux * wing},
        {sx + uy * wing, sy - ux * wing},
    };
    Gdiplus::SolidBrush br(col);
    g.FillPolygon(&br, tri, 3);
  } else if (m.tool == 3) {
    if (m.pts.size() == 1) {
      Gdiplus::SolidBrush br(col);
      float r = m.width * 0.5f;
      g.FillEllipse(&br, m.pts[0].x - r, m.pts[0].y - r, m.width, m.width);
    } else {
      std::vector<Gdiplus::PointF> gp(m.pts.size());
      for (size_t i = 0; i < m.pts.size(); i++) gp[i] = {m.pts[i].x, m.pts[i].y};
      g.DrawLines(&pen, gp.data(), (INT)gp.size());
    }
  } else if (m.tool == 4) {
    float cx = m.pts[0].x, cy = m.pts[0].y;
    float d = 28.0f;
    Gdiplus::SolidBrush fill(col);
    Gdiplus::Pen rim(Gdiplus::Color(255, 255, 255, 255), 2.0f);
    g.FillEllipse(&fill, cx - d * 0.5f, cy - d * 0.5f, d, d);
    g.DrawEllipse(&rim, cx - d * 0.5f, cy - d * 0.5f, d, d);
    wchar_t num_txt[16];
    swprintf_s(num_txt, L"%d", m.num);
    Gdiplus::FontFamily fam(L"Segoe UI");
    Gdiplus::Font font(&fam, 14.5f, Gdiplus::FontStyleBold, Gdiplus::UnitPixel);
    Gdiplus::SolidBrush ink(m.rgb == 0xFFFFFF ? Gdiplus::Color(255, 20, 22, 26) : Gdiplus::Color(255, 255, 255, 255));
    Gdiplus::StringFormat sf;
    sf.SetAlignment(Gdiplus::StringAlignmentCenter);
    sf.SetLineAlignment(Gdiplus::StringAlignmentCenter);
    Gdiplus::RectF box(cx - d * 0.5f, cy - d * 0.5f + 0.5f, d, d);
    g.DrawString(num_txt, -1, &font, box, &sf, &ink);
  }
}

static void draw_ripples_and_keys(Gdiplus::Graphics &g, ULONGLONG now_ms) {
  // Click ripples (expanding smooth ring + subtle fill pulse)
  for (const auto &rp : D.ripples) {
    if (now_ms < rp.start_ms) continue;
    float t = (float)(now_ms - rp.start_ms) / (float)RIPPLE_DURATION_MS;
    if (t >= 1.0f) continue;
    float ease = 1.0f - (1.0f - t) * (1.0f - t);
    float rad = 8.0f + 24.0f * ease;
    BYTE ring_a = (BYTE)((1.0f - t) * 220.0f);
    BYTE fill_a = (BYTE)((1.0f - t) * 60.0f);
    Gdiplus::SolidBrush fill(gdip_color(rp.rgb, fill_a));
    g.FillEllipse(&fill, rp.x - rad, rp.y - rad, rad * 2.0f, rad * 2.0f);
    Gdiplus::Pen pen(gdip_color(rp.rgb, ring_a), 2.5f);
    g.DrawEllipse(&pen, rp.x - rad, rp.y - rad, rad * 2.0f, rad * 2.0f);
  }

  // ScreenCam-style dark rounded keycaps centered near the bottom edge
  if (D.key_ov.active && !D.key_ov.caps.empty() && now_ms >= D.key_ov.start_ms) {
    ULONGLONG age = now_ms - D.key_ov.start_ms;
    if (age < KEY_HOLD_MS + KEY_FADE_MS) {
      float alpha = 1.0f;
      if (age > KEY_HOLD_MS) {
        alpha = 1.0f - (float)(age - KEY_HOLD_MS) / (float)KEY_FADE_MS;
      }
      if (alpha > 0.01f) {
        Gdiplus::FontFamily fam(L"Segoe UI");
        float cap_h = (D.h < 320) ? 28.0f : 34.0f;
        float font_sz = cap_h * 0.48f;
        Gdiplus::Font font(&fam, font_sz, Gdiplus::FontStyleBold, Gdiplus::UnitPixel);
        Gdiplus::StringFormat sf;
        sf.SetAlignment(Gdiplus::StringAlignmentCenter);
        sf.SetLineAlignment(Gdiplus::StringAlignmentCenter);

        float gap = 6.0f;
        float total_w = 0.0f;
        std::vector<float> cap_ws;
        cap_ws.reserve(D.key_ov.caps.size());
        for (const auto &lbl : D.key_ov.caps) {
          Gdiplus::RectF mr;
          g.MeasureString(lbl.c_str(), -1, &font, Gdiplus::PointF(0, 0), &mr);
          float cw = std::max(cap_h, mr.Width + 18.0f);
          cap_ws.push_back(cw);
          total_w += cw;
        }
        total_w += gap * (float)(D.key_ov.caps.size() - 1);

        float cx = ((float)D.w - total_w) * 0.5f;
        float cy = (float)D.h - cap_h - std::min(28.0f, (float)D.h * 0.08f);
        if (cy < 8.0f) cy = 8.0f;

        for (size_t i = 0; i < D.key_ov.caps.size(); i++) {
          float cw = cap_ws[i];
          Gdiplus::GraphicsPath sh_path;
          add_round_rect(sh_path, cx, cy + 2.5f, cw, cap_h, 8.0f);
          Gdiplus::SolidBrush sh_br(Gdiplus::Color((BYTE)(95.0f * alpha), 0, 0, 0));
          g.FillPath(&sh_br, &sh_path);

          Gdiplus::GraphicsPath bg_path;
          add_round_rect(bg_path, cx, cy, cw, cap_h, 8.0f);
          Gdiplus::SolidBrush bg_br(Gdiplus::Color((BYTE)(230.0f * alpha), 24, 26, 31));
          g.FillPath(&bg_br, &bg_path);

          Gdiplus::Pen rim(Gdiplus::Color((BYTE)(56.0f * alpha), 255, 255, 255), 1.2f);
          g.DrawPath(&rim, &bg_path);

          Gdiplus::SolidBrush ink(Gdiplus::Color((BYTE)(245.0f * alpha), 255, 255, 255));
          Gdiplus::RectF box(cx, cy + 0.5f, cw, cap_h);
          g.DrawString(D.key_ov.caps[i].c_str(), -1, &font, box, &sf, &ink);
          cx += cw + gap;
        }
      }
    }
  }
}

static void prune_effects(ULONGLONG now_ms) {
  D.ripples.erase(std::remove_if(D.ripples.begin(), D.ripples.end(),
                                 [now_ms](const ClickRipple &r) { return now_ms >= r.start_ms + RIPPLE_DURATION_MS; }),
                  D.ripples.end());
  if (D.key_ov.active && now_ms >= D.key_ov.start_ms + KEY_HOLD_MS + KEY_FADE_MS) {
    D.key_ov.active = false;
    D.key_ov.caps.clear();
  }
}

static void free_dib() {
  if (D.dib_dc && D.dib_old) {
    SelectObject(D.dib_dc, D.dib_old);
    D.dib_old = NULL;
  }
  if (D.dib_bmp) {
    DeleteObject(D.dib_bmp);
    D.dib_bmp = NULL;
  }
  if (D.dib_dc) {
    DeleteDC(D.dib_dc);
    D.dib_dc = NULL;
  }
  D.dib_bits = NULL;
  D.dib_w = 0;
  D.dib_h = 0;
}

static bool ensure_dib(HDC screen) {
  if (D.dib_dc && D.dib_bmp && D.dib_bits && D.dib_w == D.w && D.dib_h == D.h) return true;
  free_dib();
  D.dib_dc = CreateCompatibleDC(screen);
  if (!D.dib_dc) return false;
  BITMAPINFO bi = {};
  bi.bmiHeader.biSize = sizeof bi.bmiHeader;
  bi.bmiHeader.biWidth = D.w;
  bi.bmiHeader.biHeight = -D.h;
  bi.bmiHeader.biPlanes = 1;
  bi.bmiHeader.biBitCount = 32;
  bi.bmiHeader.biCompression = BI_RGB;
  D.dib_bmp = CreateDIBSection(screen, &bi, DIB_RGB_COLORS, &D.dib_bits, NULL, 0);
  if (!D.dib_bmp || !D.dib_bits) {
    free_dib();
    return false;
  }
  D.dib_old = SelectObject(D.dib_dc, D.dib_bmp);
  D.dib_w = D.w;
  D.dib_h = D.h;
  return true;
}

static void redraw_layer() {
  if (!D.hwnd || !D.gdip_ok || D.w <= 0 || D.h <= 0) return;

  ULONGLONG now_ms = GetTickCount64();
  prune_effects(now_ms);

  bool has_anim = !D.ripples.empty() || D.key_ov.active;
  if (has_anim && !D.timer_on) {
    SetTimer(D.hwnd, ANIM_TIMER_ID, 16, NULL);
    D.timer_on = true;
  } else if (!has_anim && D.timer_on) {
    KillTimer(D.hwnd, ANIM_TIMER_ID);
    D.timer_on = false;
  }

  bool need_visible = (D.tool != 0) || !D.marks.empty() || D.drawing || has_anim;
  if (!need_visible) {
    ShowWindow(D.hwnd, SW_HIDE);
    free_dib();
    return;
  }

  HDC screen = GetDC(NULL);
  if (ensure_dib(screen)) {
    memset(D.dib_bits, 0, (size_t)D.w * D.h * 4);
    {
      Gdiplus::Graphics g(D.dib_dc);
      g.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
      g.SetTextRenderingHint(Gdiplus::TextRenderingHintAntiAliasGridFit);
      if (D.tool != 0) {
        Gdiplus::SolidBrush hit(Gdiplus::Color(1, 0, 0, 0));
        g.FillRectangle(&hit, 0, 0, D.w, D.h);
      }
      for (const auto &m : D.marks) draw_one_mark(g, m);
      if (D.drawing) draw_one_mark(g, D.draft);
      if (has_anim) draw_ripples_and_keys(g, now_ms);
    }
    SIZE sz = {D.w, D.h};
    POINT src = {0, 0};
    POINT dst = {D.x, D.y};
    BLENDFUNCTION bf = {};
    bf.BlendOp = AC_SRC_OVER;
    bf.SourceConstantAlpha = 255;
    bf.AlphaFormat = AC_SRC_ALPHA;
    ShowWindow(D.hwnd, SW_SHOWNOACTIVATE);
    UpdateLayeredWindow(D.hwnd, screen, &dst, &sz, D.dib_dc, &src, 0, &bf, ULW_ALPHA);
  }
  ReleaseDC(NULL, screen);
}

static void sync_clickthrough() {
  if (!D.hwnd) return;
  LONG_PTR ex = GetWindowLongPtrW(D.hwnd, GWL_EXSTYLE);
  if (D.tool == 0) {
    ex |= WS_EX_TRANSPARENT;
  } else {
    ex &= ~(LONG_PTR)WS_EX_TRANSPARENT;
  }
  SetWindowLongPtrW(D.hwnd, GWL_EXSTYLE, ex);
  SetWindowPos(D.hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_FRAMECHANGED);
  redraw_layer();
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
  if ((vk >= '0' && vk <= '9') || (vk >= 'A' && vk <= 'Z')) {
    return std::wstring(1, (wchar_t)vk);
  }
  wchar_t name[32] = {};
  LONG lp = (LONG)((scan & 0xFF) << 16);
  if (GetKeyNameTextW(lp, name, 32) > 0) return name;
  return L"";
}

static bool is_modifier_vk(DWORD vk) {
  return vk == VK_CONTROL || vk == VK_LCONTROL || vk == VK_RCONTROL || vk == VK_SHIFT || vk == VK_LSHIFT ||
         vk == VK_RSHIFT || vk == VK_MENU || vk == VK_LMENU || vk == VK_RMENU || vk == VK_LWIN || vk == VK_RWIN;
}

static LRESULT CALLBACK ll_mouse_proc(int code, WPARAM wp, LPARAM lp) {
  if (code == HC_ACTION && D.hwnd && D.rec_active && D.input_show && D.tool == 0) {
    if (wp == WM_LBUTTONDOWN || wp == WM_RBUTTONDOWN || wp == WM_MBUTTONDOWN) {
      const MSLLHOOKSTRUCT *ms = (const MSLLHOOKSTRUCT *)lp;
      if (ms->pt.x >= D.x && ms->pt.x < D.x + D.w && ms->pt.y >= D.y && ms->pt.y < D.y + D.h) {
        ClickRipple rp;
        rp.x = (float)(ms->pt.x - D.x);
        rp.y = (float)(ms->pt.y - D.y);
        rp.rgb = (wp == WM_RBUTTONDOWN) ? 0xF5A524u : (wp == WM_MBUTTONDOWN ? 0x4CC38Au : 0x2F9BFFu);
        rp.start_ms = GetTickCount64();
        D.ripples.push_back(rp);
        if (D.ripples.size() > 8) D.ripples.erase(D.ripples.begin());
        redraw_layer();
      }
    }
  }
  return CallNextHookEx(NULL, code, wp, lp);
}

static LRESULT CALLBACK ll_key_proc(int code, WPARAM wp, LPARAM lp) {
  if (code == HC_ACTION && D.hwnd && D.rec_active && D.input_show && (wp == WM_KEYDOWN || wp == WM_SYSKEYDOWN)) {
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
        D.key_ov.caps = std::move(caps);
        D.key_ov.start_ms = GetTickCount64();
        D.key_ov.active = true;
        redraw_layer();
      }
    }
  }
  return CallNextHookEx(NULL, code, wp, lp);
}

static void sync_input_hooks() {
  bool want = D.hwnd && D.rec_active && D.input_show;
  if (want) {
    if (!D.mouse_hook) D.mouse_hook = SetWindowsHookExW(WH_MOUSE_LL, ll_mouse_proc, GetModuleHandleW(NULL), 0);
    if (!D.key_hook) D.key_hook = SetWindowsHookExW(WH_KEYBOARD_LL, ll_key_proc, GetModuleHandleW(NULL), 0);
  } else {
    if (D.mouse_hook) {
      UnhookWindowsHookEx(D.mouse_hook);
      D.mouse_hook = NULL;
    }
    if (D.key_hook) {
      UnhookWindowsHookEx(D.key_hook);
      D.key_hook = NULL;
    }
    D.ripples.clear();
    D.key_ov.active = false;
    D.key_ov.caps.clear();
  }
}

static LRESULT CALLBACK rec_draw_proc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
  switch (msg) {
    case WM_TIMER:
      if (wp == ANIM_TIMER_ID) {
        redraw_layer();
        return 0;
      }
      break;
    case WM_SETCURSOR:
      if (D.tool != 0) {
        SetCursor(LoadCursor(NULL, IDC_CROSS));
        return TRUE;
      }
      break;
    case WM_LBUTTONDOWN:
      if (D.tool != 0) {
        float px = (float)GET_X_LPARAM(lp);
        float py = (float)GET_Y_LPARAM(lp);
        if (D.tool == 4) {
          DrawMark m;
          m.tool = 4;
          m.rgb = D.rgb;
          m.width = 3.5f;
          m.num = D.next_num++;
          m.pts.push_back({px, py});
          D.marks.push_back(m);
          redraw_layer();
          notify_draw_state(D.tool, (int)D.marks.size());
        } else {
          SetCapture(h);
          D.drawing = true;
          D.draft = {};
          D.draft.tool = D.tool;
          D.draft.rgb = D.rgb;
          D.draft.width = (D.tool == 3) ? 3.5f : 3.2f;
          D.draft.pts.push_back({px, py});
          D.draft.pts.push_back({px, py});
          redraw_layer();
        }
        return 0;
      }
      break;
    case WM_MOUSEMOVE:
      if (D.drawing) {
        float px = (float)GET_X_LPARAM(lp);
        float py = (float)GET_Y_LPARAM(lp);
        if (D.draft.tool == 3) {
          DrawPt last = D.draft.pts.back();
          float dx = px - last.x, dy = py - last.y;
          if (dx * dx + dy * dy >= 4.0f) D.draft.pts.push_back({px, py});
        } else {
          D.draft.pts.back() = {px, py};
        }
        redraw_layer();
        return 0;
      }
      break;
    case WM_LBUTTONUP:
      if (D.drawing) {
        ReleaseCapture();
        float px = (float)GET_X_LPARAM(lp);
        float py = (float)GET_Y_LPARAM(lp);
        if (D.draft.tool == 3) {
          D.draft.pts.push_back({px, py});
          D.marks.push_back(D.draft);
        } else {
          D.draft.pts.back() = {px, py};
          float dx = D.draft.pts.back().x - D.draft.pts.front().x;
          float dy = D.draft.pts.back().y - D.draft.pts.front().y;
          if (dx * dx + dy * dy >= 9.0f) D.marks.push_back(D.draft);
        }
        D.drawing = false;
        D.draft = {};
        redraw_layer();
        notify_draw_state(D.tool, (int)D.marks.size());
        return 0;
      }
      break;
    case WM_RBUTTONDOWN:
      if (D.drawing) {
        ReleaseCapture();
        D.drawing = false;
        D.draft = {};
      }
      if (D.tool != 0) {
        D.tool = 0;
        sync_clickthrough();
        notify_draw_state(0, (int)D.marks.size());
      }
      return 0;
    case WM_MOUSEACTIVATE:
      return MA_NOACTIVATE;
  }
  return DefWindowProcW(h, msg, wp, lp);
}

}  // namespace

void rec_draw_open(int x, int y, int w, int h) {
  ensure_gdip();
  if (D.hwnd) {
    sync_input_hooks();
    DestroyWindow(D.hwnd);
    D.hwnd = NULL;
  }
  static bool registered = false;
  if (!registered) {
    WNDCLASSEXW wc = {};
    wc.cbSize = sizeof wc;
    wc.lpfnWndProc = rec_draw_proc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = L"PinShot.RecDraw";
    wc.hCursor = LoadCursor(NULL, IDC_CROSS);
    RegisterClassExW(&wc);
    registered = true;
  }
  D.x = x;
  D.y = y;
  D.w = w;
  D.h = h;
  D.tool = 0;
  D.next_num = 1;
  D.drawing = false;
  D.rec_active = false;
  D.timer_on = false;
  D.draft = {};
  D.marks.clear();
  D.ripples.clear();
  D.key_ov.active = false;
  D.key_ov.caps.clear();
  D.hwnd = CreateWindowExW(WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
                           L"PinShot.RecDraw", L"", WS_POPUP, x, y, w, h, NULL, NULL, GetModuleHandleW(NULL), NULL);
}

void rec_draw_set_recording(int on) {
  D.rec_active = (on != 0);
  sync_input_hooks();
  redraw_layer();
}

void rec_draw_close(void) {
  D.rec_active = false;
  sync_input_hooks();
  if (D.drawing) {
    ReleaseCapture();
    D.drawing = false;
  }
  if (D.hwnd && D.timer_on) {
    KillTimer(D.hwnd, ANIM_TIMER_ID);
    D.timer_on = false;
  }
  D.draft = {};
  D.marks.clear();
  D.ripples.clear();
  D.key_ov.active = false;
  D.key_ov.caps.clear();
  D.tool = 0;
  D.next_num = 1;
  if (D.hwnd) {
    DestroyWindow(D.hwnd);
    D.hwnd = NULL;
  }
  free_dib();
}

extern "C" {

void ps_rec_draw_tool(int32_t tool) {
  if (!D.hwnd) return;
  D.tool = (tool >= 0 && tool <= 5) ? tool : 0;
  sync_clickthrough();
}

void ps_rec_draw_color(int32_t rgb) {
  D.rgb = (uint32_t)rgb & 0xFFFFFFu;
}

void ps_rec_draw_undo(void) {
  if (!D.marks.empty()) {
    if (D.marks.back().tool == 4 && D.next_num > 1) D.next_num--;
    D.marks.pop_back();
    redraw_layer();
    notify_draw_state(D.tool, (int)D.marks.size());
  }
}

void ps_rec_draw_clear(void) {
  D.drawing = false;
  D.draft = {};
  D.marks.clear();
  D.next_num = 1;
  redraw_layer();
  notify_draw_state(D.tool, 0);
}

void ps_rec_input_show(int32_t on) {
  D.input_show = (on != 0);
  sync_input_hooks();
  redraw_layer();
}

}  // extern "C"
