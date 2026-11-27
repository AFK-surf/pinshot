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
void ps_wgc_long_hold(int on);
int ps_wgc_mon_hdr(HMONITOR mon, float *white);
int ps_wgc_borderless_ok(void);
int ps_capture_keep_on(void);

typedef struct {
  int32_t ok;
  int32_t w, h, pitch;
  double take_ms;
  double white;
  int32_t said_half;
  int32_t pad;
} LongWgcShmHeader;

#define TICK_MS 16
#define MOST_ROWS 30000
#define LEAST_OVERLAP 24
#define FIXED_MOST 3
#define SETTLE_MS 180
#define STRIPS_MOST 8
#define STRIP_LEAST 64
#define PROF_W 64
#define LOOSE_MOST 6.0

static struct {
  int on;
  int x, y, w, h;
  HMONITOR mon;
  int mx, my, mw, mh;
  uint8_t *base;
  int first;
  int lo, hi;
  uint8_t *out;
  int out_h;
  int foot_h;
  int head_h;
  int at;
  int strips;
  uint8_t *ref;

  uint64_t *ref_hash;
  uint8_t *ref_flat;
  uint8_t *now;
  uint64_t *now_hash;
  uint8_t *now_flat;
  uint8_t *ref_prof, *now_prof;
  int ref_prof_ok, now_prof_ok;
  HDC gdi_dc;
  HBITMAP gdi_bmp;
  HGDIOBJ gdi_old;
  void *gdi_bits;
  int use_gdi_only;
  int use_helper;
  int helper_first;
  HANDLE h_shm, h_req, h_rsp, h_stop, h_proc;
  void *h_view;
  int pictures;
  int lost;
  int full;
  int paused;
  int last_dir;
  int pending_top;
  UINT_PTR timer;
  HWND frame;
  COLORREF frame_color;
  int frame_dashed;
  int told_h, told_lost, told_full, told_paused, told_pics, told_at, told_dir;
  ULONGLONG begun;
} L;

extern void ps_update_region_frame(HWND hwnd, int rx, int ry, int rw, int rh, COLORREF color, int dashed, int handles);

static COLORREF frame_want_color(void) {
  if (L.paused) return RGB(0x9E, 0xA4, 0xB2);
  if (L.full || L.lost) return RGB(0xF5, 0xA5, 0x24);
  return RGB(0x2F, 0x9B, 0xFF);
}

static void frame_sync_color(void) {
  COLORREF c = frame_want_color();
  int d = L.paused ? 1 : 0;
  if (c != L.frame_color || d != L.frame_dashed) {
    L.frame_color = c;
    L.frame_dashed = d;
    if (L.frame) ps_update_region_frame(L.frame, L.x, L.y, L.w, L.h, c, d, 0);
  }
}

static void tell(void) {
  frame_sync_color();
  int live_at = L.head_h + L.at;
  if (L.told_h == L.out_h && L.told_lost == L.lost && L.told_full == L.full && L.told_paused == L.paused &&
      L.told_pics == L.pictures && L.told_at == live_at && L.told_dir == L.last_dir && L.pending_top == 0)
    return;
  L.told_h = L.out_h, L.told_lost = L.lost, L.told_full = L.full;
  L.told_paused = L.paused, L.told_pics = L.pictures, L.told_at = live_at, L.told_dir = L.last_dir;
  int top = L.pending_top;
  L.pending_top = 0;
  char json[192];
  int n = snprintf(json, sizeof json,
                   "{\"do\":\"long\",\"h\":%d,\"lost\":%d,\"full\":%d,\"paused\":%d,\"pics\":%d,\"dir\":%d,\"at\":%d,\"top\":%d}",
                   L.out_h, L.lost, L.full, L.paused, L.pictures, L.last_dir, live_at, top);
  mb_post("ps", json, (size_t)n, NULL, 0);
}

static moonbit_bytes_t bytes_of(const void *p, size_t n) {
  moonbit_bytes_t b = moonbit_make_bytes((int32_t)n, 0);
  if (n) memcpy(b, p, n);
  return b;
}

static int out_room_at(int lo, int hi) {
  if (lo < 0 || hi > MOST_ROWS * 2 || hi - lo > MOST_ROWS) return 0;
  if (L.hi > L.lo && lo >= L.lo && hi <= L.hi) return 1;
  int nlo = L.hi > L.lo && L.lo < lo ? L.lo : lo - 1024, nhi = L.hi > L.lo && L.hi > hi ? L.hi : hi + 1024;
  if (nlo < 0) nlo = 0;
  if (nhi > MOST_ROWS * 2) nhi = MOST_ROWS * 2;
  size_t row = (size_t)L.w * 4;
  if (!VirtualAlloc(L.base + (size_t)nlo * row, (size_t)(nhi - nlo) * row, MEM_COMMIT, PAGE_READWRITE)) return 0;
  L.lo = nlo, L.hi = nhi;
  return 1;
}

static int out_room(int rows) {
  if (rows > MOST_ROWS) return 0;
  return out_room_at(L.first, L.first + rows);
}

static void out_at(int first) {
  L.first = first;
  L.out = L.base + (size_t)first * L.w * 4;
}

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

static void out_put_at(int at, int from, int to) {
  if (to <= from) return;
  int n = to - from;
  if (L.out_h + n > MOST_ROWS) {
    n = MOST_ROWS - L.out_h;
    L.full = 1;
  }
  if (n <= 0 || !out_room_at(L.first - n, L.first + L.out_h)) {
    L.full = 1;
    return;
  }
  size_t row = (size_t)L.w * 4;
  uint8_t *old = L.out;
  out_at(L.first - n);
  memmove(L.out, old, (size_t)at * row);
  memcpy(L.out + (size_t)at * row, L.now + (size_t)(to - n) * row, (size_t)n * row);
  L.out_h += n;
}

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

static void profile_of(const uint8_t *img, uint8_t *prof) {
  for (int y = 0; y < L.h; y++) {
    const uint8_t *row = img + (size_t)y * L.w * 4;
    for (int c = 0; c < PROF_W; c++) {
      int x0 = c * L.w / PROF_W, x1 = (c + 1) * L.w / PROF_W;
      unsigned sum = 0, n = 0;
      for (int x = x0; x < x1; x += 2) {
        const uint8_t *px = row + (size_t)x * 4;
        sum += (px[0] + px[1] * 5u + px[2] * 2u) >> 3;
        n++;
      }
      prof[(size_t)y * PROF_W + c] = (uint8_t)(n ? sum / n : 0);
    }
  }
}

static void profiles_made(void) {
  if (!L.now_prof_ok) profile_of(L.now, L.now_prof), L.now_prof_ok = 1;
  if (!L.ref_prof_ok) profile_of(L.ref, L.ref_prof), L.ref_prof_ok = 1;
}

static int prof_row_diff(const uint8_t *a, int ya, const uint8_t *b, int yb) {
  const uint8_t *p = a + (size_t)ya * PROF_W, *q = b + (size_t)yb * PROF_W;
  int d = 0;
  for (int c = 0; c < PROF_W; c++) d += p[c] > q[c] ? p[c] - q[c] : q[c] - p[c];
  return d;
}

static int prof_marked(int y) {
  const uint8_t *p = L.now_prof + (size_t)y * PROF_W;
  int lo = 255, hi = 0;
  for (int c = 0; c < PROF_W; c++) {
    if (p[c] < lo) lo = p[c];
    if (p[c] > hi) hi = p[c];
  }
  return hi - lo >= 8;
}

static double prof_band(int d, int top, int band, int step, int up) {
  long sum = 0, n = 0;
  for (int y = top; y < top + band - d; y += step) {
    int yn = up ? y + d : y, yr = up ? y : y + d;
    if (!prof_marked(yn)) continue;
    sum += prof_row_diff(L.now_prof, yn, L.ref_prof, yr);
    n++;
  }
  return n * step >= LEAST_OVERLAP ? (double)sum / (n * PROF_W) : 1e9;
}

static void still_rows(int *head, int *foot) {
  profiles_made();
  int most = L.h / FIXED_MOST, top = 0, bot = 0;
  int still_most = (int)(PROF_W * 3);
  while (top < most && prof_row_diff(L.now_prof, top, L.ref_prof, top) <= still_most) top++;
  while (bot < most && prof_row_diff(L.now_prof, L.h - 1 - bot, L.ref_prof, L.h - 1 - bot) <= still_most) bot++;
  *head = top;
  *foot = bot;
}

static int loose_shift(int up, int *bot, int *head) {
  int top = 0, foot = 0;
  still_rows(&top, &foot);
  *bot = foot;
  *head = top;
  int band = L.h - top - foot;
  if (band < LEAST_OVERLAP * 2) return 0;
  double at0 = prof_band(0, top, band, 4, up);
  int best = 0, reach = band - (band / 5 > LEAST_OVERLAP * 2 ? band / 5 : LEAST_OVERLAP * 2);
  double best_v = 1e9;
  for (int d = 2; d <= reach; d += 2) {
    double v = prof_band(d, top, band, 4, up);
    if (v < best_v) best_v = v, best = d;
  }
  if (!best) return 0;
  int fine = best;
  double fine_v = 1e9;
  for (int d = best - 3; d <= best + 3; d++) {
    if (d < 1 || d > reach) continue;
    double v = prof_band(d, top, band, 2, up);
    if (v < fine_v) fine_v = v, fine = d;
  }
  if (fine_v > LOOSE_MOST || fine_v * 3.0 > at0) return 0;
  return fine;
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
}

static int long_helper_start(void) {
  long_helper_stop();
  size_t need = sizeof(LongWgcShmHeader) + (size_t)L.w * (size_t)L.h * 4;
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
             req_n, rsp_n, stop_n, (unsigned long)pid, L.mx, L.my, L.mw, L.mh, L.x - L.mx, L.y - L.my, L.w, L.h);
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
  return 1;
}

static void long_capture_begin(void) {
  L.use_gdi_only = 0;
  if (ps_capture_keep_on()) {
    ps_wgc_long_hold(1);
    return;
  }
  float white = 1.0f;
  if (ps_wgc_mon_hdr(L.mon, &white) && ps_wgc_borderless_ok()) {
    if (long_helper_start()) return;
  }
  L.use_gdi_only = 1;
}

static void long_capture_end(void) {
  if (L.use_helper) long_helper_stop();
  else if (L.on && !L.use_gdi_only) ps_wgc_long_hold(0);
  L.use_gdi_only = 0;
}

static int take_now(void) {
  if (L.use_helper && L.h_view && L.h_req && L.h_rsp && L.h_proc) {
    LongWgcShmHeader *hdr = (LongWgcShmHeader *)L.h_view;
    hdr->ok = 0;
    ResetEvent(L.h_rsp);
    SetEvent(L.h_req);
    HANDLE waits[2] = {L.h_rsp, L.h_proc};
    DWORD ms = L.helper_first ? 900 : 250;
    L.helper_first = 0;
    DWORD wr = WaitForMultipleObjects(2, waits, FALSE, ms);
    if (wr == WAIT_OBJECT_0 && hdr->ok == 1 && hdr->w == L.w && hdr->h == L.h && hdr->pitch >= L.w * 4) {
      const uint8_t *src = (const uint8_t *)hdr + sizeof(LongWgcShmHeader);
      if (hdr->pitch == L.w * 4) {
        memcpy(L.now, src, (size_t)L.w * L.h * 4);
      } else {
        for (int y = 0; y < L.h; y++) memcpy(L.now + (size_t)y * L.w * 4, src + (size_t)y * hdr->pitch, (size_t)L.w * 4);
      }
      return 1;
    }
    if (wr != WAIT_OBJECT_0) {
      long_helper_stop();
      L.use_gdi_only = 1;
    }
  }
  if (!L.use_gdi_only) {
    uint8_t *bits = NULL;
    int pitch = 0;
    void *t = ps_wgc_take_part(L.mon, L.mw, L.mh, L.x - L.mx, L.y - L.my, L.w, L.h, &bits, &pitch);
    if (t) {
      for (int y = 0; y < L.h; y++) memcpy(L.now + (size_t)y * L.w * 4, bits + (size_t)y * pitch, (size_t)L.w * 4);
      ps_wgc_release(t);
      return 1;
    }
  }
  HDC screen = GetDC(NULL);
  if (!L.gdi_dc) {
    BITMAPINFO bi;
    memset(&bi, 0, sizeof bi);
    bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bi.bmiHeader.biWidth = L.w;
    bi.bmiHeader.biHeight = -L.h;
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = BI_RGB;
    L.gdi_dc = CreateCompatibleDC(screen);
    L.gdi_bmp = L.gdi_dc ? CreateDIBSection(screen, &bi, DIB_RGB_COLORS, &L.gdi_bits, NULL, 0) : NULL;
    if (L.gdi_bmp && L.gdi_bits) L.gdi_old = SelectObject(L.gdi_dc, L.gdi_bmp);
  }
  int ok = 0;
  if (L.gdi_old) {
    ok = BitBlt(L.gdi_dc, 0, 0, L.w, L.h, screen, L.x, L.y, SRCCOPY) != 0;
    GdiFlush();
    if (ok) memcpy(L.now, L.gdi_bits, (size_t)L.w * L.h * 4);
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

typedef struct {
  int still;
  int down, up;
  int bot;
} Strip;

static int shift_of(const uint64_t *a, const uint64_t *b, const uint8_t *flat, int top, int bot) {
  int band = L.h - top - bot;
  if (band < LEAST_OVERLAP * 2) return 0;
  int best = 0, best_score = 0;
  for (int d = 1; d <= band - LEAST_OVERLAP; d++) {
    int agree = 0, differ = 0, lines = band - d;
    for (int y = top; y < top + lines; y++) {
      if (a[y] == b[y + d]) {
        if (!flat[y]) agree++;
      } else if (++differ * 20 > lines) {
        break;
      }
    }
    if (differ * 20 > lines) continue;
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

static int agreed(const Strip *st, int up, int *bot) {
  int moving = 0, best = 0, best_n = 0, second_n = 0;
  for (int s = 0; s < L.strips; s++) moving += !st[s].still;
  for (int s = 0; s < L.strips; s++) {
    int d = up ? st[s].up : st[s].down, n = 0, seen = 0;
    if (!d) continue;
    for (int t = 0; t < s && !seen; t++) seen = (up ? st[t].up : st[t].down) == d;
    if (seen) continue;
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
  if (!L.on || L.paused || L.full) return;
  if (GetTickCount64() - L.begun < SETTLE_MS) return;
  if (!take_now()) return;
  hash_rows(L.now, L.now_hash, L.now_flat);
  L.now_prof_ok = 0;
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
    int bot = 0, head = 0, d = 0, up = 0;
    d = agreed(st, 0, &bot);
    if (!d) {
      int u_bot = 0, u = agreed(st, 1, &u_bot);
      if (u) d = u, up = 1, bot = u_bot;
    }
    if (!d && moving) {
      d = loose_shift(0, &bot, &head);
      if (d) {
        dump("loose", moving, d, bot, 0);
      } else {
        d = loose_shift(1, &bot, &head);
        if (d) up = 1, dump("loose-up", moving, d, head, 0);
      }
    }
    if (!d) {
      int still = L.strips - moving;
      L.lost = still < moving;
      dump(L.lost ? "lost" : "still", moving, still, 0, 0);
      tell();
      return;
    }
    if (L.pictures == 1) {
      if (!head) {
        int b2 = 0;
        still_rows(&head, &b2);
        if (!bot) bot = b2;
      }
      L.head_h = head;
      L.foot_h = bot;
      L.at = 0;
    }
    int band = L.h - L.head_h - L.foot_h;
    int laid = L.out_h - L.head_h - L.foot_h;
    if (up) {
      dump("moved-up", moving, d, L.at, laid);
      L.at -= d;
      if (L.at < 0) {
        int n = -L.at;
        if (n > band) n = band;
        int before = L.out_h;
        out_put_at(L.head_h, L.head_h, L.head_h + n);
        int added = L.out_h - before;
        if (added > 0) {
          L.last_dir = -1;
          L.pending_top += added;
        }
        L.at = 0;
      }
    } else {
      dump("moved", moving, d, L.at, laid);
      L.at += d;
      int past = L.at + band - laid;
      if (past > 0) {
        if (past > band) past = band;
        int before = L.out_h;
        L.out_h -= L.foot_h;
        out_add(L.h - L.foot_h - past, L.h);
        if (L.out_h > before) L.last_dir = 1;
        L.at = L.out_h - L.head_h - L.foot_h - band;
      }
    }
  }
  L.lost = 0;
  L.pictures++;
  uint8_t *p = L.ref;
  L.ref = L.now, L.now = p;
  uint64_t *hp = L.ref_hash;
  L.ref_hash = L.now_hash, L.now_hash = hp;
  uint8_t *fp = L.ref_flat;
  L.ref_flat = L.now_flat, L.now_flat = fp;
  uint8_t *pp = L.ref_prof;
  L.ref_prof = L.now_prof, L.now_prof = pp;
  int pok = L.ref_prof_ok;
  L.ref_prof_ok = L.now_prof_ok, L.now_prof_ok = pok;
  tell();
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
  ps_update_region_frame(L.frame, L.x, L.y, L.w, L.h, L.frame_color ? L.frame_color : RGB(0x2F, 0x9B, 0xFF), L.frame_dashed, 0);
  ShowWindow(L.frame, SW_SHOWNOACTIVATE);
}

static void let_go(void) {
  long_capture_end();
  if (dump_log) fclose(dump_log);
  dump_log = NULL, dumped = 0, dumped_hash = 0;
  if (L.timer) KillTimer(NULL, L.timer);
  if (L.frame) DestroyWindow(L.frame);
  if (L.base) VirtualFree(L.base, 0, MEM_RELEASE);
  free(L.ref), free(L.now), free(L.ref_hash), free(L.now_hash), free(L.ref_flat), free(L.now_flat);
  free(L.ref_prof), free(L.now_prof);
  gdi_let_go();
  memset(&L, 0, sizeof L);
}

static int work_made(void) {
  if (L.ref) return 1;
  size_t frame = (size_t)L.w * L.h * 4, rows = (size_t)L.strips * L.h;
  L.ref = (uint8_t *)malloc(frame), L.now = (uint8_t *)malloc(frame);
  L.ref_hash = (uint64_t *)malloc(rows * sizeof(uint64_t)), L.now_hash = (uint64_t *)malloc(rows * sizeof(uint64_t));
  L.ref_flat = (uint8_t *)malloc(rows), L.now_flat = (uint8_t *)malloc(rows);
  L.ref_prof = (uint8_t *)malloc((size_t)L.h * PROF_W), L.now_prof = (uint8_t *)malloc((size_t)L.h * PROF_W);
  L.ref_prof_ok = L.now_prof_ok = 0;
  return L.ref && L.now && L.ref_hash && L.now_hash && L.ref_flat && L.now_flat && L.ref_prof && L.now_prof;
}

static void work_let_go(void) {
  free(L.ref), free(L.now), free(L.ref_hash), free(L.now_hash), free(L.ref_flat), free(L.now_flat);
  free(L.ref_prof), free(L.now_prof);
  L.ref = L.now = L.ref_flat = L.now_flat = L.ref_prof = L.now_prof = NULL;
  L.ref_hash = L.now_hash = NULL;
  gdi_let_go();
}

int32_t ps_long_begin(int32_t x, int32_t y, int32_t w, int32_t h) {
  let_go();
  if (w < 16 || h < LEAST_OVERLAP * 3) return 0;
  POINT c = {x + w / 2, y + h / 2};
  HMONITOR mon = MonitorFromPoint(c, MONITOR_DEFAULTTONEAREST);
  MONITORINFO mi = {sizeof mi};
  if (!GetMonitorInfoW(mon, &mi)) return 0;
  if (x < mi.rcMonitor.left) w -= mi.rcMonitor.left - x, x = mi.rcMonitor.left;
  if (y < mi.rcMonitor.top) h -= mi.rcMonitor.top - y, y = mi.rcMonitor.top;
  if (x + w > mi.rcMonitor.right) w = mi.rcMonitor.right - x;
  if (y + h > mi.rcMonitor.bottom) h = mi.rcMonitor.bottom - y;
  if (w < 16 || h < LEAST_OVERLAP * 3) return 0;
  L.x = x, L.y = y, L.w = w, L.h = h;
  L.mon = mon;
  L.mx = mi.rcMonitor.left, L.my = mi.rcMonitor.top;
  L.mw = mi.rcMonitor.right - mi.rcMonitor.left, L.mh = mi.rcMonitor.bottom - mi.rcMonitor.top;
  L.base = (uint8_t *)VirtualAlloc(NULL, (size_t)MOST_ROWS * 2 * w * 4, MEM_RESERVE, PAGE_READWRITE);
  L.strips = w / STRIP_LEAST < 2 ? 1 : (w / STRIP_LEAST > STRIPS_MOST ? STRIPS_MOST : w / STRIP_LEAST);
  if (!L.base || !work_made()) {
    let_go();
    return 0;
  }
  out_at(MOST_ROWS);
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
    if (!L.timer && !L.full) L.timer = SetTimer(NULL, 0, TICK_MS, tick_timer);
  }
  tell();
}

void ps_long_reset(void) {
  if (!L.base || !work_made()) return;
  if (L.hi > L.lo) VirtualFree(L.base + (size_t)L.lo * L.w * 4, (size_t)(L.hi - L.lo) * L.w * 4, MEM_DECOMMIT);
  L.lo = L.hi = 0;
  out_at(MOST_ROWS);
  L.out_h = 0, L.foot_h = 0, L.head_h = 0, L.at = 0;
  L.pictures = 0, L.lost = 0, L.full = 0, L.paused = 0, L.last_dir = 0, L.pending_top = 0;
  L.told_h = -1;
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
  work_let_go();
}

extern void *mb_app_hwnd_of(int wid);
extern void mb_render_set_clear(int wid, int on);
void ps_long_exclude(int32_t wid) {
  HWND h = (HWND)mb_app_hwnd_of(wid);
  if (!h) return;
  mb_render_set_clear(wid, 1);
  DWM_WINDOW_CORNER_PREFERENCE corner = DWMWCP_DONOTROUND;
  DwmSetWindowAttribute(h, DWMWA_WINDOW_CORNER_PREFERENCE, &corner, sizeof corner);
  COLORREF no_border = 0xFFFFFFFEu;
  DwmSetWindowAttribute(h, 34 /* DWMWA_BORDER_COLOR */, &no_border, sizeof no_border);
  exclude(h);
}

void ps_long_end(void) { let_go(); }

moonbit_bytes_t ps_long_info(void) {
  if (!L.out_h) return moonbit_make_bytes(0, 0);
  char s[96];
  int n = snprintf(s, sizeof s, "%d,%d,%d,%d,%d", L.w, L.out_h, L.pictures, L.lost, L.full);
  return bytes_of(s, (size_t)n);
}

void ps_bmp_header(uint8_t h[54], int32_t w, int32_t hh);

void ps_long_preview_free(void) {}

moonbit_bytes_t ps_long_preview(int32_t box_w, int32_t box_h, int32_t from_row) {
  if (!L.out_h || box_w <= 0 || box_h <= 0) return moonbit_make_bytes(0, 0);
  double k = (double)box_w / L.w;
  if (k > 1.0) k = 1.0;
  int vis_rows = (int)((double)box_h / k + 0.5);
  if (vis_rows < 1) vis_rows = 1;
  int max_from = L.out_h > vis_rows ? L.out_h - vis_rows : 0;
  int from = from_row < 0 ? 0 : (from_row > max_from ? max_from : from_row);
  int src_h = L.out_h - from;
  if (src_h > vis_rows) src_h = vis_rows;
  int pw = (int)(L.w * k + 0.5), ph = (int)(src_h * k + 0.5);
  if (pw < 1) pw = 1;
  if (ph < 1) ph = 1;
  if (ph > box_h) ph = box_h;
  moonbit_bytes_t out = moonbit_make_bytes((int32_t)(54 + (size_t)pw * (size_t)ph * 4), 0);
  ps_bmp_header(out, pw, ph);
  uint8_t *p = out + 54;
  for (int y = 0; y < ph; y++) {
    int y0 = from + (int)((double)y * src_h / ph), y1 = from + (int)((double)(y + 1) * src_h / ph);
    if (y1 <= y0) y1 = y0 + 1;
    if (y1 > L.out_h) y1 = L.out_h;
    if (y0 >= L.out_h) y0 = L.out_h - 1;
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
  return out;
}

moonbit_bytes_t ps_long_png(void) {
  moonbit_bytes_t none = moonbit_make_bytes(0, 0);
  if (!L.out_h) return none;
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
