// A long screenshot's Windows side (longshot.mbt says what it is to the person): a part of the screen taken again and
// again while the person scrolls what is under it, each new picture laid under the last where they overlap, into one
// tall picture kept here.
//
// The part is taken from the system's capture (capture_wgc.cpp's ps_wgc_take_part: the monitor's last frame, only the
// part copied off), GDI's BitBlt where that has none, every TICK_MS on the UI thread (a timer). Each picture is
// matched against the last one laid in (not merely the last taken: scrolled back up and down again, nothing is laid in
// twice), strip by strip (STRIPS of its width, each on its own: what stands beside what scrolls, a sidebar, a desktop
// that moves on its own, says nothing of the shift): in each, its rows hashed, the rows that did not move at its top and
// its foot (a header, a bar held there) kept apart, and the shift found at which the rows between agree best. The shift
// most strips agree on is taken; what it brought in at the foot is added to the picture, the foot's still rows kept
// after it (replaced each time, so they come once, at its end).
//
// A frame of the accent round the part (a window of its own, the pointer passing through it, not in any capture) shows
// what is taken. The app is told {"do":"long"} as the picture grows or a picture could not be matched.
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

#pragma comment(lib, "windowscodecs.lib")
#pragma comment(lib, "dwmapi.lib")

#ifndef WDA_EXCLUDEFROMCAPTURE
#define WDA_EXCLUDEFROMCAPTURE 0x11
#endif

extern void mb_post(const char *channel, const char *json, size_t len, const uint8_t *bytes, size_t blen);
void *ps_wgc_take_part(HMONITOR mon, int w, int h, int rx, int ry, int rw, int rh, uint8_t **bits, int *pitch);
void ps_wgc_release(void *taken);

#define TICK_MS 33
#define MOST_ROWS 30000  // how tall the picture may grow (the person told once it is)
#define LEAST_OVERLAP 24  // rows two pictures must share to be matched
#define FIXED_MOST 3      // a still header or foot at most a third of the part
#define SETTLE_MS 180
#define STRIPS_MOST 8
#define STRIP_LEAST 64    // pixels: a part narrower than two strips of it is one strip

static struct {
  int on;
  int x, y, w, h;          // the part, in the screen's pixels
  HMONITOR mon;
  int mx, my, mw, mh;      // its monitor
  uint8_t *out;            // the picture: rows of w * 4 bytes, MOST_ROWS reserved, committed as it grows
  size_t committed;
  int out_h;
  int foot_h;              // its last rows: the foot's still rows of the last picture laid in
  int strips;
  uint8_t *ref;            // the last picture laid in, and each strip's rows' hashes and whether each is one colour

  uint64_t *ref_hash;
  uint8_t *ref_flat;
  uint8_t *now;            // the picture taken now
  uint64_t *now_hash;
  uint8_t *now_flat;
  int pictures;            // how many were laid in
  int lost;                // the last taken matched none (scrolled too far at once)
  int full;                // MOST_ROWS reached
  UINT_PTR timer;
  HWND frame;
  int told_h, told_lost;
  ULONGLONG begun;         // when it began (GetTickCount64)
} L;

static void tell(void) {
  if (L.told_h == L.out_h && L.told_lost == L.lost) return;
  L.told_h = L.out_h, L.told_lost = L.lost;
  char json[128];
  int n = snprintf(json, sizeof json, "{\"do\":\"long\",\"h\":%d,\"lost\":%d,\"full\":%d}", L.out_h, L.lost, L.full);
  mb_post("ps", json, (size_t)n, NULL, 0);
}

static moonbit_bytes_t bytes_of(const void *p, size_t n) {
  moonbit_bytes_t b = moonbit_make_bytes((int32_t)n, 0);
  if (n) memcpy(b, p, n);
  return b;
}

// ---- the picture ----

static int out_room(int rows) {
  if (rows > MOST_ROWS) return 0;
  size_t need = (size_t)rows * L.w * 4;
  if (need <= L.committed) return 1;
  size_t step = (size_t)L.w * 4 * 1024;
  size_t to = need + step;
  size_t most = (size_t)MOST_ROWS * L.w * 4;
  if (to > most) to = most;
  if (!VirtualAlloc(L.out, to, MEM_COMMIT, PAGE_READWRITE)) return 0;
  L.committed = to;
  return 1;
}

// Rows [from, to) of the picture taken now added to the picture's end.
static void out_add(int from, int to) {
  if (to <= from) return;
  int n = to - from;
  if (L.out_h + n > MOST_ROWS) {
    n = MOST_ROWS - L.out_h;
    L.full = 1;
  }
  if (n <= 0 || !out_room(L.out_h + n)) {
    L.full = 1;
    return;
  }
  memcpy(L.out + (size_t)L.out_h * L.w * 4, L.now + (size_t)from * L.w * 4, (size_t)n * L.w * 4);
  L.out_h += n;
}

// Each strip's rows of picture `px` hashed (their fourth bytes not read), each marked where it is all one colour:
// strip s's row y at [s * h + y].
static void hash_rows(const uint8_t *px, uint64_t *hash, uint8_t *flat) {
  for (int s = 0; s < L.strips; s++) {
    int x0 = s * L.w / L.strips, x1 = (s + 1) * L.w / L.strips;
    for (int y = 0; y < L.h; y++) {
      const uint32_t *r = (const uint32_t *)(px + (size_t)y * L.w * 4);
      uint64_t hv = 1469598103934665603ULL;
      uint32_t first = r[x0] & 0xFFFFFF;
      int one = 1;
      for (int x = x0; x < x1; x++) {
        uint32_t c = r[x] & 0xFFFFFF;
        if (c != first) one = 0;
        hv = (hv ^ c) * 1099511628211ULL;
      }
      hash[s * L.h + y] = hv;
      flat[s * L.h + y] = (uint8_t)one;
    }
  }
}

// The part taken now into L.now: 1 when taken.
static int take_now(void) {
  uint8_t *bits = NULL;
  int pitch = 0;
  void *t = ps_wgc_take_part(L.mon, L.mw, L.mh, L.x - L.mx, L.y - L.my, L.w, L.h, &bits, &pitch);
  if (t) {
    for (int y = 0; y < L.h; y++) memcpy(L.now + (size_t)y * L.w * 4, bits + (size_t)y * pitch, (size_t)L.w * 4);
    ps_wgc_release(t);
    return 1;
  }
  // (GDI's: the system's capture has had no frame of this monitor yet, or is off)
  HDC screen = GetDC(NULL);
  HDC mem = CreateCompatibleDC(screen);
  BITMAPINFO bi;
  memset(&bi, 0, sizeof bi);
  bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bi.bmiHeader.biWidth = L.w;
  bi.bmiHeader.biHeight = -L.h;
  bi.bmiHeader.biPlanes = 1;
  bi.bmiHeader.biBitCount = 32;
  bi.bmiHeader.biCompression = BI_RGB;
  void *dib_bits = NULL;
  HBITMAP dib = CreateDIBSection(screen, &bi, DIB_RGB_COLORS, &dib_bits, NULL, 0);
  int ok = 0;
  if (dib && dib_bits) {
    HGDIOBJ old = SelectObject(mem, dib);
    ok = BitBlt(mem, 0, 0, L.w, L.h, screen, L.x, L.y, SRCCOPY) != 0;
    SelectObject(mem, old);
    GdiFlush();
    if (ok) memcpy(L.now, dib_bits, (size_t)L.w * L.h * 4);
  }
  if (dib) DeleteObject(dib);
  DeleteDC(mem);
  ReleaseDC(NULL, screen);
  return ok;
}

// What strip s did from the last picture laid in to the one taken now.
typedef struct {
  int still;     // the same (but for 5% of its rows at most)
  int down, up;  // what is between its still rows moved up by `down` (scrolled down: now's row y is ref's y + down),
                 // or down by `up` (scrolled back up); 0 none found
  int bot;       // its still rows at its foot
} Strip;

// The shift d at which the most rows between `top` and `bot` that are not all one colour agree, too few disagreeing:
// a's row y is b's row y + d. 0: none.
static int shift_of(const uint64_t *a, const uint64_t *b, const uint8_t *flat, int top, int bot) {
  int band = L.h - top - bot;
  if (band < LEAST_OVERLAP * 2) return 0;
  int best = 0, best_score = 0;
  for (int d = 1; d <= band - LEAST_OVERLAP; d++) {
    int agree = 0, differ = 0, lines = band - d;
    for (int y = top; y < top + lines; y++) {
      if (a[y] == b[y + d]) {
        if (!flat[y]) agree++;
      } else if (++differ * 20 > lines) {  // (more than 5% apart: not this shift)
        break;
      }
    }
    if (differ * 20 > lines) continue;
    // (rows enough that say something: a shift seen only in a flat ground is no shift)
    if (agree < 8 || agree * 16 < lines) continue;
    if (agree > best_score) best_score = agree, best = d;
  }
  return best;
}

static Strip strip_of(int s) {
  Strip r = {0, 0, 0, 0};
  const uint64_t *ref = L.ref_hash + s * L.h, *now = L.now_hash + s * L.h;
  int differ = 0;
  for (int y = 0; y < L.h; y++) differ += now[y] != ref[y];
  if (differ * 20 <= L.h) {
    r.still = 1;
    return r;
  }
  int most = L.h / FIXED_MOST, top = 0;
  while (top < most && now[top] == ref[top]) top++;
  while (r.bot < most && now[L.h - 1 - r.bot] == ref[L.h - 1 - r.bot]) r.bot++;
  r.down = shift_of(now, ref, L.now_flat + s * L.h, top, r.bot);
  if (!r.down) r.up = shift_of(ref, now, L.ref_flat + s * L.h, top, r.bot);
  return r;
}

// The shift most strips that moved agree on (`up`: of those that moved back down), its foot's still rows in `bot`
// (the fewest any of them saw); 0 none they agree on enough: two at least where two or more moved, more than for any
// other shift, a third of them at least.
static int agreed(const Strip *st, int up, int *bot) {
  int moving = 0, best = 0, best_n = 0, second_n = 0;
  for (int s = 0; s < L.strips; s++) moving += !st[s].still;
  for (int s = 0; s < L.strips; s++) {
    int d = up ? st[s].up : st[s].down, n = 0, seen = 0;
    if (!d) continue;
    for (int t = 0; t < s && !seen; t++) seen = (up ? st[t].up : st[t].down) == d;
    if (seen) continue;  // (each shift counted once)
    for (int t = s; t < L.strips; t++) n += (up ? st[t].up : st[t].down) == d;
    if (n > best_n) second_n = best_n, best_n = n, best = d;
    else if (n > second_n) second_n = n;
  }
  if (!best || best_n < (moving < 2 ? moving : 2) || best_n <= second_n || best_n * 3 < moving) return 0;
  *bot = L.h;
  for (int s = 0; s < L.strips; s++)
    if ((up ? st[s].up : st[s].down) == best && st[s].bot < *bot) *bot = st[s].bot;
  return best;
}

// (PINSHOT_LONG_DUMP: a folder each picture taken that differs from the last is written to as a BMP, and what each
// was found to be to its log: for working out why pictures did not join)
static FILE *dump_log;
static int dumped;
static uint64_t dumped_hash;
static void dump(const char *what, int a, int b, int c, int d) {
  const char *dir = getenv("PINSHOT_LONG_DUMP");
  if (!dir) return;
  char path[MAX_PATH];
  if (!dump_log) {
    snprintf(path, sizeof path, "%s\\long.log", dir);
    dump_log = fopen(path, "w");
  }
  uint64_t hv = 0;
  for (int y = 0; y < L.h; y++) hv = hv * 31 + L.now_hash[y];
  if (dump_log) fprintf(dump_log, "%llu %s %d %d %d %d (picture %d, h %d)\n", GetTickCount64() - L.begun, what, a, b, c, d,
                        hv == dumped_hash ? dumped - 1 : dumped, L.out_h), fflush(dump_log);
  if (hv == dumped_hash || dumped >= 80) return;
  dumped_hash = hv;
  snprintf(path, sizeof path, "%s\\%03d.bmp", dir, dumped++);
  FILE *f = fopen(path, "wb");
  if (!f) return;
  BITMAPFILEHEADER fh = {0x4D42, (DWORD)(54 + (size_t)L.w * L.h * 4), 0, 0, 54};
  BITMAPINFOHEADER ih = {sizeof ih, L.w, -L.h, 1, 32, BI_RGB, 0, 0, 0, 0, 0};
  fwrite(&fh, sizeof fh, 1, f);
  fwrite(&ih, sizeof ih, 1, f);
  fwrite(L.now, (size_t)L.w * L.h * 4, 1, f);
  fclose(f);
}

static void tick(void) {
  if (!L.on || L.full) return;
  // (the overlay just put out of sight may still be in the system's last frame: the first taken a moment after)
  if (GetTickCount64() - L.begun < SETTLE_MS) return;
  if (!take_now()) return;
  hash_rows(L.now, L.now_hash, L.now_flat);
  if (!L.pictures) {
    dump("first", 0, 0, 0, 0);
    out_add(0, L.h);
    L.foot_h = 0;
  } else {
    Strip st[STRIPS_MOST];
    int moving = 0;
    for (int s = 0; s < L.strips; s++) {
      st[s] = strip_of(s);
      moving += !st[s].still;
    }
    int bot = 0, d = agreed(st, 0, &bot);
    if (!d) {
      // (not moved: the most of it the same, what changed beside it moving on its own; or scrolled back up: nothing
      // new, the last laid in kept; else nothing here is the last picture's: scrolled too far down at once, or the
      // page changed)
      int still = L.strips - moving, up_bot = 0;
      L.lost = still < moving && !agreed(st, 1, &up_bot);
      dump(L.lost ? "lost" : "still", moving, still, 0, 0);
      tell();
      return;
    }
    dump("moved", moving, d, bot, 0);
    // what came in at the foot laid in after the picture's rows (the last laid in's foot taken off: its still rows,
    // the first picture's as this one sees them), the foot's still rows after them
    int foot = L.pictures == 1 ? bot : L.foot_h;
    L.out_h -= foot;
    out_add(L.h - foot - d < 0 ? 0 : L.h - foot - d, L.h);
    L.foot_h = L.full ? 0 : bot;
  }
  L.lost = 0;
  L.pictures++;
  // (the one taken now is the one laid in last)
  uint8_t *p = L.ref;
  L.ref = L.now, L.now = p;
  uint64_t *hp = L.ref_hash;
  L.ref_hash = L.now_hash, L.now_hash = hp;
  uint8_t *fp = L.ref_flat;
  L.ref_flat = L.now_flat, L.now_flat = fp;
  tell();
}

static void CALLBACK tick_timer(HWND h, UINT msg, UINT_PTR id, DWORD t) {
  (void)h, (void)msg, (void)id, (void)t;
  tick();
}

// ---- the frame round the part ----

#define FRAME_LINE 2
#define FRAME_KEY RGB(255, 0, 255)

static LRESULT CALLBACK frame_proc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
  if (msg == WM_NCHITTEST) return HTTRANSPARENT;
  if (msg == WM_PAINT) {
    PAINTSTRUCT ps;
    HDC dc = BeginPaint(h, &ps);
    RECT r;
    GetClientRect(h, &r);
    HBRUSH key = CreateSolidBrush(FRAME_KEY);
    HBRUSH line = CreateSolidBrush(RGB(0x2F, 0x9B, 0xFF));
    FillRect(dc, &r, line);
    RECT in = {FRAME_LINE, FRAME_LINE, r.right - FRAME_LINE, r.bottom - FRAME_LINE};
    FillRect(dc, &in, key);
    DeleteObject(key);
    DeleteObject(line);
    EndPaint(h, &ps);
    return 0;
  }
  return DefWindowProcW(h, msg, wp, lp);
}

// (PINSHOT_LONG_SHOW: the frame and the panel left in what other programs take, a test's screenshots)
static void exclude(HWND h) {
  if (!getenv("PINSHOT_LONG_SHOW")) SetWindowDisplayAffinity(h, WDA_EXCLUDEFROMCAPTURE);
}

static void frame_show(void) {
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
  // (just outside the part: never in what is taken; and kept out of any capture besides)
  int x = L.x - FRAME_LINE, y = L.y - FRAME_LINE, w = L.w + FRAME_LINE * 2, h = L.h + FRAME_LINE * 2;
  L.frame = CreateWindowExW(WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
                            L"PinShot.LongFrame", L"", WS_POPUP, x, y, w, h, NULL, NULL, GetModuleHandleW(NULL), NULL);
  if (!L.frame) return;
  SetLayeredWindowAttributes(L.frame, FRAME_KEY, 255, LWA_COLORKEY);
  exclude(L.frame);
  ShowWindow(L.frame, SW_SHOWNOACTIVATE);
}

// ---- what the app calls ----

static void let_go(void) {
  if (L.timer) KillTimer(NULL, L.timer);
  if (L.frame) DestroyWindow(L.frame);
  if (L.out) VirtualFree(L.out, 0, MEM_RELEASE);
  free(L.ref), free(L.now), free(L.ref_hash), free(L.now_hash), free(L.ref_flat), free(L.now_flat);
  memset(&L, 0, sizeof L);
}

// A long screenshot begun of the part x, y, w by h (the screen's pixels): its frame shown, the part taken every
// TICK_MS from now. 1 begun.
int32_t ps_long_begin(int32_t x, int32_t y, int32_t w, int32_t h) {
  let_go();
  if (w < 16 || h < LEAST_OVERLAP * 3) return 0;
  POINT c = {x + w / 2, y + h / 2};
  HMONITOR mon = MonitorFromPoint(c, MONITOR_DEFAULTTONEAREST);
  MONITORINFO mi = {sizeof mi};
  if (!GetMonitorInfoW(mon, &mi)) return 0;
  // (kept on its monitor: the system's capture is one monitor's)
  if (x < mi.rcMonitor.left) w -= mi.rcMonitor.left - x, x = mi.rcMonitor.left;
  if (y < mi.rcMonitor.top) h -= mi.rcMonitor.top - y, y = mi.rcMonitor.top;
  if (x + w > mi.rcMonitor.right) w = mi.rcMonitor.right - x;
  if (y + h > mi.rcMonitor.bottom) h = mi.rcMonitor.bottom - y;
  if (w < 16 || h < LEAST_OVERLAP * 3) return 0;
  L.x = x, L.y = y, L.w = w, L.h = h;
  L.mon = mon;
  L.mx = mi.rcMonitor.left, L.my = mi.rcMonitor.top;
  L.mw = mi.rcMonitor.right - mi.rcMonitor.left, L.mh = mi.rcMonitor.bottom - mi.rcMonitor.top;
  size_t frame = (size_t)w * h * 4;
  L.out = (uint8_t *)VirtualAlloc(NULL, (size_t)MOST_ROWS * w * 4, MEM_RESERVE, PAGE_READWRITE);
  L.ref = (uint8_t *)malloc(frame), L.now = (uint8_t *)malloc(frame);
  L.strips = w / STRIP_LEAST < 2 ? 1 : (w / STRIP_LEAST > STRIPS_MOST ? STRIPS_MOST : w / STRIP_LEAST);
  size_t rows = (size_t)L.strips * h;
  L.ref_hash = (uint64_t *)malloc(rows * sizeof(uint64_t)), L.now_hash = (uint64_t *)malloc(rows * sizeof(uint64_t));
  L.ref_flat = (uint8_t *)malloc(rows), L.now_flat = (uint8_t *)malloc(rows);
  if (!L.out || !L.ref || !L.now || !L.ref_hash || !L.now_hash || !L.ref_flat || !L.now_flat) {
    let_go();
    return 0;
  }
  L.on = 1;
  L.told_h = -1;
  L.begun = GetTickCount64();
  frame_show();
  L.timer = SetTimer(NULL, 0, TICK_MS, tick_timer);
  return 1;
}

// The taking stopped (the picture kept till ps_long_end), its frame gone.
void ps_long_stop(void) {
  if (L.timer) KillTimer(NULL, L.timer);
  L.timer = 0;
  if (L.frame) DestroyWindow(L.frame);
  L.frame = NULL;
}

// Window `wid` of the app (the long screenshot's panel): its corners round, kept out of what is taken, should it stand
// over the part.
extern void *mb_app_hwnd_of(int wid);
void ps_long_exclude(int32_t wid) {
  HWND h = (HWND)mb_app_hwnd_of(wid);
  if (!h) return;
  DWM_WINDOW_CORNER_PREFERENCE corner = DWMWCP_ROUND;
  DwmSetWindowAttribute(h, DWMWA_WINDOW_CORNER_PREFERENCE, &corner, sizeof corner);
  exclude(h);
}

// The long screenshot let go, all it held.
void ps_long_end(void) { let_go(); }

// The picture as it stands: "w,h,pictures,lost,full"; "" none.
moonbit_bytes_t ps_long_info(void) {
  if (!L.out_h) return moonbit_make_bytes(0, 0);
  char s[96];
  int n = snprintf(s, sizeof s, "%d,%d,%d,%d,%d", L.w, L.out_h, L.pictures, L.lost, L.full);
  return bytes_of(s, (size_t)n);
}

// The picture's foot as it would show `box_w` pixels wide (brought down to that, never up), as much of it as `box_h`
// pixels hold (all of it while it is shorter): what came in last at its foot, the picture at one scale all along, so
// what is added slides in under what was there rather than all of it shrinking. Each pixel the mean of those it
// covers. As mbui takes pixels kept elsewhere (MBRAWPTR...); kept here, six in turn, so one mbui still reads is not
// written over.
moonbit_bytes_t ps_long_preview(int32_t box_w, int32_t box_h) {
  static uint8_t *kept[6];
  static int turn;
  if (!L.out_h || box_w <= 0 || box_h <= 0) return moonbit_make_bytes(0, 0);
  double k = (double)box_w / L.w;
  if (k > 1.0) k = 1.0;
  int rows = (int)(box_h / k);
  int from = L.out_h > rows ? L.out_h - rows : 0, src_h = L.out_h - from;
  int pw = (int)(L.w * k + 0.5), ph = (int)(src_h * k + 0.5);
  if (pw < 1) pw = 1;
  if (ph < 1) ph = 1;
  turn = (turn + 1) % 6;
  free(kept[turn]);
  kept[turn] = (uint8_t *)malloc((size_t)pw * ph * 4);
  uint8_t *p = kept[turn];
  if (!p) return moonbit_make_bytes(0, 0);
  for (int y = 0; y < ph; y++) {
    int y0 = from + (int)((double)y * src_h / ph), y1 = from + (int)((double)(y + 1) * src_h / ph);
    if (y1 <= y0) y1 = y0 + 1;
    // (a few rows of what it covers, at most: enough for a picture this small)
    int ys = (y1 - y0) > 4 ? (y1 - y0) / 4 : 1;
    for (int x = 0; x < pw; x++) {
      int x0 = (int)((double)x * L.w / pw), x1 = (int)((double)(x + 1) * L.w / pw);
      if (x1 <= x0) x1 = x0 + 1;
      int xs = (x1 - x0) > 4 ? (x1 - x0) / 4 : 1;
      unsigned b = 0, g = 0, r = 0, n = 0;
      for (int yy = y0; yy < y1; yy += ys) {
        const uint8_t *s = L.out + ((size_t)yy * L.w + x0) * 4;
        for (int xx = x0; xx < x1; xx += xs, s += 4 * xs) b += s[0], g += s[1], r += s[2], n++;
      }
      uint8_t *d = p + ((size_t)y * pw + x) * 4;
      d[0] = (uint8_t)(b / n), d[1] = (uint8_t)(g / n), d[2] = (uint8_t)(r / n), d[3] = 255;
    }
  }
  uint8_t out[28];
  uint64_t at = (uint64_t)(uintptr_t)p;
  int32_t pitch = pw * 4;
  memcpy(out, "MBRAWPTR", 8);
  memcpy(out + 8, &at, 8);
  memcpy(out + 16, &pw, 4);
  memcpy(out + 20, &ph, 4);
  memcpy(out + 24, &pitch, 4);
  return bytes_of(out, sizeof out);
}

// The picture as a PNG file's bytes (WIC's encoder); empty: none, or it could not be made.
moonbit_bytes_t ps_long_png(void) {
  moonbit_bytes_t none = moonbit_make_bytes(0, 0);
  if (!L.out_h) return none;
  // (opaque: the fourth byte of a screen's pixels is not alpha)
  for (size_t i = 0; i < (size_t)L.w * L.out_h; i++) L.out[i * 4 + 3] = 255;
  HRESULT co = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
  IWICImagingFactory *f = NULL;
  IStream *st = NULL;
  IWICBitmapEncoder *enc = NULL;
  IWICBitmapFrameEncode *fr = NULL;
  moonbit_bytes_t got = none;
  WICPixelFormatGUID fmt = GUID_WICPixelFormat32bppBGRA;
  if (SUCCEEDED(CoCreateInstance(&CLSID_WICImagingFactory, NULL, CLSCTX_INPROC_SERVER, &IID_IWICImagingFactory,
                                 (void **)&f)) &&
      SUCCEEDED(CreateStreamOnHGlobal(NULL, TRUE, &st)) &&
      SUCCEEDED(IWICImagingFactory_CreateEncoder(f, &GUID_ContainerFormatPng, NULL, &enc)) &&
      SUCCEEDED(IWICBitmapEncoder_Initialize(enc, st, WICBitmapEncoderNoCache)) &&
      SUCCEEDED(IWICBitmapEncoder_CreateNewFrame(enc, &fr, NULL)) && SUCCEEDED(IWICBitmapFrameEncode_Initialize(fr, NULL)) &&
      SUCCEEDED(IWICBitmapFrameEncode_SetSize(fr, (UINT)L.w, (UINT)L.out_h)) &&
      SUCCEEDED(IWICBitmapFrameEncode_SetPixelFormat(fr, &fmt)) &&
      SUCCEEDED(IWICBitmapFrameEncode_WritePixels(fr, (UINT)L.out_h, (UINT)L.w * 4, (UINT)((size_t)L.w * L.out_h * 4),
                                                  L.out)) &&
      SUCCEEDED(IWICBitmapFrameEncode_Commit(fr)) && SUCCEEDED(IWICBitmapEncoder_Commit(enc))) {
    HGLOBAL g = NULL;
    if (SUCCEEDED(GetHGlobalFromStream(st, &g))) {
      STATSTG ss;
      if (SUCCEEDED(IStream_Stat(st, &ss, STATFLAG_NONAME))) {
        void *p = GlobalLock(g);
        if (p) {
          got = bytes_of(p, (size_t)ss.cbSize.QuadPart);
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
  return got;
}
