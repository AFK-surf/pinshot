#ifndef PINSHOT_LONGSHOT_ALGO_H
#define PINSHOT_LONGSHOT_ALGO_H

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define LS_MOST_ROWS 30000
#define LS_LEAST_OVERLAP 24
#define LS_FIXED_MOST 3
#define LS_STRIPS_MOST 8
#define LS_STRIP_LEAST 64
#define LS_PROF_W 64
#define LS_LOOSE_MOST 6.0

typedef int (*LongCommitFn)(void *ctx, int lo, int hi);
typedef void (*LongDumpFn)(void *ctx, const char *what, int a, int b, int c, int d);

typedef struct {
  int w, h;
  int hw;
  int strips;
  uint8_t *base;
  int first;
  uint8_t *out;
  int out_h;
  int head_h;
  int foot_h;
  int grew_top;
  int at;
  uint8_t *ref;
  uint64_t *ref_hash;
  uint8_t *ref_flat;
  uint8_t *now;
  uint64_t *now_hash;
  uint8_t *now_flat;
  uint8_t *ref_prof;
  uint8_t *now_prof;
  int ref_prof_ok;
  int now_prof_ok;
  int pictures;
  int lost;
  int full;
  int last_dir;
  int pending_top;
  LongCommitFn commit_fn;
  LongDumpFn dump_fn;
  void *cb_ctx;
} LongCore;

typedef struct {
  int still;
  int down, up;
  double down_score, up_score;
  int top, bot;
} LongStrip;

static inline int ls_compute_hw(int w, int gutter) {
  if (gutter > 0 && w >= gutter * 6 && w - gutter >= 16) return w - gutter;
  return w;
}

static inline int ls_compute_strips(int hw) {
  int s = hw / LS_STRIP_LEAST;
  if (s < 2) return 1;
  return s > LS_STRIPS_MOST ? LS_STRIPS_MOST : s;
}

static inline void ls_out_at(LongCore *c, int first) {
  c->first = first;
  c->out = c->base + (size_t)first * (size_t)c->w * 4;
}

static inline int ls_work_alloc(LongCore *c) {
  if (c->ref) return 1;
  size_t frame = (size_t)c->w * (size_t)c->h * 4;
  size_t rows = (size_t)c->strips * (size_t)c->h;
  c->ref = (uint8_t *)malloc(frame);
  c->now = (uint8_t *)malloc(frame);
  c->ref_hash = (uint64_t *)malloc(rows * sizeof(uint64_t));
  c->now_hash = (uint64_t *)malloc(rows * sizeof(uint64_t));
  c->ref_flat = (uint8_t *)malloc(rows);
  c->now_flat = (uint8_t *)malloc(rows);
  c->ref_prof = (uint8_t *)malloc((size_t)c->h * LS_PROF_W);
  c->now_prof = (uint8_t *)malloc((size_t)c->h * LS_PROF_W);
  c->ref_prof_ok = 0;
  c->now_prof_ok = 0;
  return c->ref && c->now && c->ref_hash && c->now_hash && c->ref_flat && c->now_flat && c->ref_prof && c->now_prof;
}

static inline void ls_work_free(LongCore *c) {
  free(c->ref);
  free(c->now);
  free(c->ref_hash);
  free(c->now_hash);
  free(c->ref_flat);
  free(c->now_flat);
  free(c->ref_prof);
  free(c->now_prof);
  c->ref = c->now = c->ref_flat = c->now_flat = c->ref_prof = c->now_prof = NULL;
  c->ref_hash = c->now_hash = NULL;
  c->ref_prof_ok = c->now_prof_ok = 0;
}

static inline void ls_reset_state(LongCore *c) {
  ls_out_at(c, LS_MOST_ROWS);
  c->out_h = 0;
  c->head_h = 0;
  c->foot_h = 0;
  c->grew_top = 0;
  c->at = 0;
  c->pictures = 0;
  c->lost = 0;
  c->full = 0;
  c->last_dir = 0;
  c->pending_top = 0;
  c->ref_prof_ok = 0;
  c->now_prof_ok = 0;
}

static inline int ls_out_room_at(LongCore *c, int lo, int hi) {
  if (lo < 0 || hi > LS_MOST_ROWS * 2 || hi - lo > LS_MOST_ROWS) return 0;
  if (c->commit_fn) return c->commit_fn(c->cb_ctx, lo, hi);
  return 1;
}

static inline int ls_out_add_exact(LongCore *c, int from, int to) {
  if (to <= from) return 0;
  int n = to - from;
  if (c->out_h + n > LS_MOST_ROWS) {
    n = LS_MOST_ROWS - c->out_h;
    c->full = 1;
  }
  if (n <= 0 || !ls_out_room_at(c, c->first, c->first + c->out_h + n)) {
    c->full = 1;
    return 0;
  }
  size_t row = (size_t)c->w * 4;
  memcpy(c->out + (size_t)c->out_h * row, c->now + (size_t)from * row, (size_t)n * row);
  c->out_h += n;
  return n;
}

static inline int ls_out_put_at(LongCore *c, int at, int from, int to) {
  if (to <= from) return 0;
  int n = to - from;
  if (c->out_h + n > LS_MOST_ROWS) {
    n = LS_MOST_ROWS - c->out_h;
    c->full = 1;
  }
  if (n <= 0 || !ls_out_room_at(c, c->first - n, c->first + c->out_h)) {
    c->full = 1;
    return 0;
  }
  size_t row = (size_t)c->w * 4;
  uint8_t *old = c->out;
  ls_out_at(c, c->first - n);
  if (at > 0) memmove(c->out, old, (size_t)at * row);
  memcpy(c->out + (size_t)at * row, c->now + (size_t)(to - n) * row, (size_t)n * row);
  c->out_h += n;
  return n;
}

static inline void ls_hash_rows(const LongCore *c, const uint8_t *px, uint64_t *hash, uint8_t *flat) {
  for (int s = 0; s < c->strips; s++) {
    int x0 = s * c->hw / c->strips, x1 = (s + 1) * c->hw / c->strips;
    if (x1 <= x0) x1 = x0 + 1;
    for (int y = 0; y < c->h; y++) {
      const uint32_t *r = (const uint32_t *)(px + (size_t)y * (size_t)c->w * 4);
      uint64_t hv = 1469598103934665603ULL;
      uint32_t first = r[x0] & 0xFFFFFFu;
      int one = 1;
      for (int x = x0; x < x1; x++) {
        uint32_t v = r[x] & 0xFFFFFFu;
        if (v != first) one = 0;
        hv = (hv ^ v) * 1099511628211ULL;
      }
      hash[(size_t)s * (size_t)c->h + y] = hv;
      flat[(size_t)s * (size_t)c->h + y] = (uint8_t)one;
    }
  }
}

static inline void ls_profile_of(const LongCore *c, const uint8_t *img, uint8_t *prof) {
  for (int y = 0; y < c->h; y++) {
    const uint8_t *row = img + (size_t)y * (size_t)c->w * 4;
    for (int col = 0; col < LS_PROF_W; col++) {
      int x0 = col * c->hw / LS_PROF_W;
      int x1 = (col + 1) * c->hw / LS_PROF_W;
      if (x1 <= x0) x1 = x0 + 1;
      if (x1 > c->hw) x1 = c->hw;
      unsigned sum = 0, n = 0;
      for (int x = x0; x < x1; x += 2) {
        const uint8_t *px = row + (size_t)x * 4;
        sum += (px[0] + px[1] * 5u + px[2] * 2u) >> 3;
        n++;
      }
      prof[(size_t)y * LS_PROF_W + col] = (uint8_t)(n ? sum / n : 0);
    }
  }
}

static inline void ls_profiles_made(LongCore *c) {
  if (!c->now_prof_ok) {
    ls_profile_of(c, c->now, c->now_prof);
    c->now_prof_ok = 1;
  }
  if (!c->ref_prof_ok) {
    ls_profile_of(c, c->ref, c->ref_prof);
    c->ref_prof_ok = 1;
  }
}

static inline int ls_prof_row_diff_all(const uint8_t *a, int ya, const uint8_t *b, int yb) {
  const uint8_t *p = a + (size_t)ya * LS_PROF_W;
  const uint8_t *q = b + (size_t)yb * LS_PROF_W;
  int d = 0;
  for (int col = 0; col < LS_PROF_W; col++) d += p[col] > q[col] ? p[col] - q[col] : q[col] - p[col];
  return d;
}

static inline int ls_prof_row_diff_cols(const uint8_t *a, int ya, const uint8_t *b, int yb, const uint8_t *cols) {
  const uint8_t *p = a + (size_t)ya * LS_PROF_W;
  const uint8_t *q = b + (size_t)yb * LS_PROF_W;
  int d = 0;
  for (int col = 0; col < LS_PROF_W; col++) {
    if (!cols[col]) continue;
    d += p[col] > q[col] ? p[col] - q[col] : q[col] - p[col];
  }
  return d;
}

static inline int ls_prof_row_marked_cols(const uint8_t *prof, int y, const uint8_t *cols) {
  const uint8_t *p = prof + (size_t)y * LS_PROF_W;
  int lo = 255, hi = 0;
  for (int col = 0; col < LS_PROF_W; col++) {
    if (!cols[col]) continue;
    if (p[col] < lo) lo = p[col];
    if (p[col] > hi) hi = p[col];
  }
  return hi - lo >= 8;
}

static inline double ls_prof_band(const LongCore *c, int d, int top, int band, int step, int up, const uint8_t *cols,
                                  int ncols) {
  long sum = 0, n = 0;
  for (int y = top; y < top + band - d; y += step) {
    int yn = up ? y + d : y;
    int yr = up ? y : y + d;
    int mn = ls_prof_row_marked_cols(c->now_prof, yn, cols);
    int mr = ls_prof_row_marked_cols(c->ref_prof, yr, cols);
    int rd = ls_prof_row_diff_cols(c->now_prof, yn, c->ref_prof, yr, cols);
    if (!mn && !mr && rd <= ncols * 3) continue;
    sum += rd;
    n++;
  }
  return n * step >= LS_LEAST_OVERLAP ? (double)sum / (double)(n * ncols) : 1e9;
}

static inline int ls_row_flat_color(const uint8_t *img, int w, int hw, int y, int *b0, int *g0, int *r0) {
  const uint8_t *row = img + (size_t)y * (size_t)w * 4;
  int fb = row[0], fg = row[1], fr = row[2];
  for (int x = 1; x < hw; x++) {
    const uint8_t *p = row + (size_t)x * 4;
    int db = p[0] - fb, dg = p[1] - fg, dr = p[2] - fr;
    if (db < -3 || db > 3 || dg < -3 || dg > 3 || dr < -3 || dr > 3) return 0;
  }
  *b0 = fb;
  *g0 = fg;
  *r0 = fr;
  return 1;
}

static inline int ls_row_shares_bg(const uint8_t *img, int w, int hw, int y, int fb, int fg, int fr) {
  const uint8_t *row = img + (size_t)y * (size_t)w * 4;
  int step = hw > 64 ? hw / 64 : 1;
  int hit = 0, tot = 0;
  for (int x = 0; x < hw; x += step) {
    const uint8_t *p = row + (size_t)x * 4;
    int db = p[0] - fb, dg = p[1] - fg, dr = p[2] - fr;
    if (db >= -6 && db <= 6 && dg >= -6 && dg <= 6 && dr >= -6 && dr <= 6) hit++;
    tot++;
  }
  return tot > 0 && hit * 4 >= tot;
}

static inline int ls_color_near(int b0, int g0, int r0, int b1, int g1, int r1) {
  int db = b0 - b1, dg = g0 - g1, dr = r0 - r1;
  return db >= -6 && db <= 6 && dg >= -6 && dg <= 6 && dr >= -6 && dr <= 6;
}

static inline void ls_trim_flat_edges(const LongCore *c, int *head, int *foot) {
  int top = *head;
  if (top > 0) {
    int b0 = 0, g0 = 0, r0 = 0;
    int all_flat = ls_row_flat_color(c->now, c->w, c->hw, 0, &b0, &g0, &r0) &&
                   ls_row_flat_color(c->ref, c->w, c->hw, 0, &b0, &g0, &r0);
    if (all_flat) {
      for (int y = 1; y < top && all_flat; y++) {
        int nb = 0, ng = 0, nr = 0, rb = 0, rg = 0, rr = 0;
        if (!ls_row_flat_color(c->now, c->w, c->hw, y, &nb, &ng, &nr) ||
            !ls_row_flat_color(c->ref, c->w, c->hw, y, &rb, &rg, &rr) ||
            !ls_color_near(nb, ng, nr, b0, g0, r0) || !ls_color_near(rb, rg, rr, b0, g0, r0)) {
          all_flat = 0;
        }
      }
    }
    if (all_flat) {
      top = 0;
    } else if (top < c->h) {
      int bg_set = 0, bg_b = 0, bg_g = 0, bg_r = 0;
      while (top > 0) {
        int nb = 0, ng = 0, nr = 0, rb = 0, rg = 0, rr = 0;
        if (!ls_row_flat_color(c->now, c->w, c->hw, top - 1, &nb, &ng, &nr) ||
            !ls_row_flat_color(c->ref, c->w, c->hw, top - 1, &rb, &rg, &rr) ||
            !ls_color_near(nb, ng, nr, rb, rg, rr)) {
          break;
        }
        if (!bg_set) {
          if (!ls_row_shares_bg(c->now, c->w, c->hw, top, nb, ng, nr) &&
              !ls_row_shares_bg(c->ref, c->w, c->hw, top, nb, ng, nr)) {
            break;
          }
          bg_set = 1;
          bg_b = nb;
          bg_g = ng;
          bg_r = nr;
        } else if (!ls_color_near(nb, ng, nr, bg_b, bg_g, bg_r)) {
          break;
        }
        top--;
      }
    }
    *head = top;
  }

  int bot = *foot;
  if (bot > 0) {
    int y_end = c->h - 1;
    int b0 = 0, g0 = 0, r0 = 0;
    int all_flat = ls_row_flat_color(c->now, c->w, c->hw, y_end, &b0, &g0, &r0) &&
                   ls_row_flat_color(c->ref, c->w, c->hw, y_end, &b0, &g0, &r0);
    if (all_flat) {
      for (int k = 1; k < bot && all_flat; k++) {
        int y = y_end - k;
        int nb = 0, ng = 0, nr = 0, rb = 0, rg = 0, rr = 0;
        if (!ls_row_flat_color(c->now, c->w, c->hw, y, &nb, &ng, &nr) ||
            !ls_row_flat_color(c->ref, c->w, c->hw, y, &rb, &rg, &rr) ||
            !ls_color_near(nb, ng, nr, b0, g0, r0) || !ls_color_near(rb, rg, rr, b0, g0, r0)) {
          all_flat = 0;
        }
      }
    }
    if (all_flat) {
      bot = 0;
    } else if (bot < c->h) {
      int bg_set = 0, bg_b = 0, bg_g = 0, bg_r = 0;
      while (bot > 0) {
        int y = c->h - bot;
        int nb = 0, ng = 0, nr = 0, rb = 0, rg = 0, rr = 0;
        if (!ls_row_flat_color(c->now, c->w, c->hw, y, &nb, &ng, &nr) ||
            !ls_row_flat_color(c->ref, c->w, c->hw, y, &rb, &rg, &rr) ||
            !ls_color_near(nb, ng, nr, rb, rg, rr)) {
          break;
        }
        if (!bg_set) {
          int adj = y - 1;
          if (!ls_row_shares_bg(c->now, c->w, c->hw, adj, nb, ng, nr) &&
              !ls_row_shares_bg(c->ref, c->w, c->hw, adj, nb, ng, nr)) {
            break;
          }
          bg_set = 1;
          bg_b = nb;
          bg_g = ng;
          bg_r = nr;
        } else if (!ls_color_near(nb, ng, nr, bg_b, bg_g, bg_r)) {
          break;
        }
        bot--;
      }
    }
    *foot = bot;
  }
}

static inline void ls_still_rows(LongCore *c, int *head, int *foot) {
  ls_profiles_made(c);
  int most = c->h / LS_FIXED_MOST, top = 0, bot = 0;
  int still_most = LS_PROF_W * 3;
  while (top < most && ls_prof_row_diff_all(c->now_prof, top, c->ref_prof, top) <= still_most) top++;
  while (bot < most && ls_prof_row_diff_all(c->now_prof, c->h - 1 - bot, c->ref_prof, c->h - 1 - bot) <= still_most)
    bot++;
  *head = top;
  *foot = bot;
}

static inline int ls_moving_cols(const LongCore *c, int top, int band, uint8_t cols[LS_PROF_W]) {
  int ncols = 0;
  int rows = (band + 3) / 4;
  if (rows < 1) rows = 1;
  for (int col = 0; col < LS_PROF_W; col++) {
    long sum = 0;
    for (int y = top; y < top + band; y += 4) {
      int a = c->now_prof[(size_t)y * LS_PROF_W + col];
      int b = c->ref_prof[(size_t)y * LS_PROF_W + col];
      sum += a > b ? a - b : b - a;
    }
    if (sum > (long)rows * 2) {
      cols[col] = 1;
      ncols++;
    } else {
      cols[col] = 0;
    }
  }
  if (ncols < 8) {
    memset(cols, 1, LS_PROF_W);
    return LS_PROF_W;
  }
  return ncols;
}

static inline int ls_loose_dir(LongCore *c, int up, int top, int band, const uint8_t *cols, int ncols, double *out_v) {
  if (band < LS_LEAST_OVERLAP * 2) return 0;
  double at0 = ls_prof_band(c, 0, top, band, 4, up, cols, ncols);
  int margin = band / 5 > LS_LEAST_OVERLAP * 2 ? band / 5 : LS_LEAST_OVERLAP * 2;
  int reach = band - margin;
  if (reach < 2) return 0;
  int best = 0;
  double best_v = 1e9;
  for (int d = 2; d <= reach; d += 2) {
    double v = ls_prof_band(c, d, top, band, 4, up, cols, ncols);
    if (v < best_v) best_v = v, best = d;
  }
  if (!best) return 0;
  int fine = best;
  double fine_v = 1e9;
  for (int d = best - 3; d <= best + 3; d++) {
    if (d < 1 || d > reach) continue;
    double v = ls_prof_band(c, d, top, band, 2, up, cols, ncols);
    if (v < fine_v) fine_v = v, fine = d;
  }
  if (fine_v > LS_LOOSE_MOST || fine_v * 3.0 > at0) return 0;
  *out_v = fine_v;
  return fine;
}

static inline int ls_loose_shift(LongCore *c, int *up_out, int *bot_out, int *head_out) {
  int top = 0, foot = 0;
  ls_still_rows(c, &top, &foot);
  int band = c->h - top - foot;
  if (band < LS_LEAST_OVERLAP * 2) return 0;
  uint8_t cols[LS_PROF_W];
  int ncols = ls_moving_cols(c, top, band, cols);
  double dv = 1e9, uv = 1e9;
  int dd = ls_loose_dir(c, 0, top, band, cols, ncols, &dv);
  int ud = ls_loose_dir(c, 1, top, band, cols, ncols, &uv);
  if (!dd && !ud) return 0;
  ls_trim_flat_edges(c, &top, &foot);
  *head_out = top;
  *bot_out = foot;
  if (dd && (!ud || dv <= uv)) {
    *up_out = 0;
    return dd;
  }
  *up_out = 1;
  return ud;
}

static inline int ls_shift_of(const LongCore *c, const uint64_t *a, const uint64_t *b, const uint8_t *flat, int top,
                              int bot, double *out_score) {
  int band = c->h - top - bot;
  if (band < LS_LEAST_OVERLAP * 2) return 0;
  int best = 0;
  double best_score = 0.0;
  for (int d = 1; d <= band - LS_LEAST_OVERLAP; d++) {
    int agree = 0, differ = 0, lines = band - d;
    int max_differ = lines / 8;
    for (int y = top; y < top + lines; y++) {
      if (a[y] == b[y + d]) {
        if (!flat[y]) agree++;
      } else if (++differ > max_differ) {
        break;
      }
    }
    if (differ > max_differ) continue;
    if (agree < 8 || agree * 16 < lines) continue;
    double q = (double)(lines - differ) / (double)lines;
    double score = (double)agree * q * q * q;
    if (score > best_score) {
      best_score = score;
      best = d;
    }
  }
  *out_score = best_score;
  return best;
}

static inline LongStrip ls_strip_of(const LongCore *c, int s) {
  LongStrip r;
  memset(&r, 0, sizeof r);
  const uint64_t *ref = c->ref_hash + (size_t)s * (size_t)c->h;
  const uint64_t *now = c->now_hash + (size_t)s * (size_t)c->h;
  int differ = 0;
  for (int y = 0; y < c->h; y++) differ += now[y] != ref[y];
  if (differ * 20 <= c->h) {
    r.still = 1;
    return r;
  }
  int most = c->h / LS_FIXED_MOST;
  while (r.top < most && now[r.top] == ref[r.top]) r.top++;
  while (r.bot < most && now[c->h - 1 - r.bot] == ref[c->h - 1 - r.bot]) r.bot++;
  r.down = ls_shift_of(c, now, ref, c->now_flat + (size_t)s * (size_t)c->h, r.top, r.bot, &r.down_score);
  r.up = ls_shift_of(c, ref, now, c->ref_flat + (size_t)s * (size_t)c->h, r.top, r.bot, &r.up_score);
  return r;
}

static inline int ls_agreed(const LongCore *c, const LongStrip *st, int up, int *top_out, int *bot_out, int *votes_out,
                            double *score_out) {
  int moving = 0, best = 0, best_n = 0, second_n = 0;
  double best_sum = 0.0;
  for (int s = 0; s < c->strips; s++) moving += !st[s].still;
  for (int s = 0; s < c->strips; s++) {
    int d = up ? st[s].up : st[s].down;
    if (!d) continue;
    int seen = 0;
    for (int t = 0; t < s && !seen; t++) seen = (up ? st[t].up : st[t].down) == d;
    if (seen) continue;
    int n = 0;
    double sum = 0.0;
    for (int t = s; t < c->strips; t++) {
      if ((up ? st[t].up : st[t].down) == d) {
        n++;
        sum += up ? st[t].up_score : st[t].down_score;
      }
    }
    if (n > best_n) {
      second_n = best_n;
      best_n = n;
      best_sum = sum;
      best = d;
    } else if (n == best_n) {
      second_n = n;
      if (sum > best_sum) {
        best_sum = sum;
        best = d;
      }
    } else if (n > second_n) {
      second_n = n;
    }
  }
  if (!best || best_n < (moving < 2 ? moving : 2) || best_n <= second_n || best_n * 3 < moving) return 0;
  int min_top = c->h, min_bot = c->h;
  for (int s = 0; s < c->strips; s++) {
    if ((up ? st[s].up : st[s].down) == best) {
      if (st[s].top < min_top) min_top = st[s].top;
      if (st[s].bot < min_bot) min_bot = st[s].bot;
    }
  }
  *top_out = min_top == c->h ? 0 : min_top;
  *bot_out = min_bot == c->h ? 0 : min_bot;
  *votes_out = best_n;
  *score_out = best_sum;
  return best;
}

static inline void ls_dump(LongCore *c, const char *what, int a, int b, int x, int d) {
  if (c->dump_fn) c->dump_fn(c->cb_ctx, what, a, b, x, d);
}

static inline int ls_step(LongCore *c) {
  if (c->full) return 0;
  if (c->pictures > 0 && memcmp(c->now, c->ref, (size_t)c->w * (size_t)c->h * 4) == 0) {
    return 0;
  }
  ls_hash_rows(c, c->now, c->now_hash, c->now_flat);
  c->now_prof_ok = 0;
  if (!c->pictures) {
    ls_dump(c, "first", 0, 0, 0, 0);
    ls_out_add_exact(c, 0, c->h);
    c->head_h = 0;
    c->foot_h = 0;
  } else {
    LongStrip st[LS_STRIPS_MOST];
    int moving = 0;
    for (int s = 0; s < c->strips; s++) {
      st[s] = ls_strip_of(c, s);
      moving += !st[s].still;
    }
    int d_top = 0, d_bot = 0, d_votes = 0;
    double d_score = 0.0;
    int dd = ls_agreed(c, st, 0, &d_top, &d_bot, &d_votes, &d_score);
    int u_top = 0, u_bot = 0, u_votes = 0;
    double u_score = 0.0;
    int ud = ls_agreed(c, st, 1, &u_top, &u_bot, &u_votes, &u_score);

    int d = 0, up = 0, head = 0, bot = 0;
    if (dd && (!ud || d_votes > u_votes || (d_votes == u_votes && d_score >= u_score))) {
      d = dd;
      up = 0;
      head = d_top;
      bot = d_bot;
      ls_trim_flat_edges(c, &head, &bot);
    } else if (ud) {
      d = ud;
      up = 1;
      head = u_top;
      bot = u_bot;
      ls_trim_flat_edges(c, &head, &bot);
    }
    if (!d && moving) {
      d = ls_loose_shift(c, &up, &bot, &head);
      if (d) ls_dump(c, up ? "loose-up" : "loose", moving, d, up ? head : bot, 0);
    }
    if (!d) {
      int still = c->strips - moving;
      c->lost = still < moving;
      ls_dump(c, c->lost ? "lost" : "still", moving, still, 0, 0);
      return 1;
    }
    if (c->pictures == 1) {
      if (c->h - head - bot < LS_LEAST_OVERLAP * 2) head = 0, bot = 0;
      c->head_h = head;
      c->foot_h = bot;
      c->at = 0;
    } else {
      if (head < c->head_h && !c->grew_top) c->head_h = head;
      int cur_band = c->h - c->head_h - c->foot_h;
      int cur_laid = c->out_h - c->head_h - c->foot_h;
      if (bot < c->foot_h && c->at + cur_band == cur_laid) c->foot_h = bot;
    }

    int band = c->h - c->head_h - c->foot_h;
    int laid = c->out_h - c->head_h - c->foot_h;
    int eff_top = head > c->head_h ? head : c->head_h;
    int eff_bot = bot > c->foot_h ? bot : c->foot_h;
    int eff_band = c->h - eff_top - eff_bot;
    if (eff_band < LS_LEAST_OVERLAP) eff_band = band;

    if (up) {
      int need = d - c->at;
      if (need > eff_band) {
        c->lost = 1;
        ls_dump(c, "jump-up", moving, d, c->at, eff_band);
        return 1;
      }
      ls_dump(c, "moved-up", moving, d, c->at, laid);
      c->at -= d;
      if (c->at < 0) {
        int n = -c->at;
        int room = LS_MOST_ROWS - c->out_h;
        if (n > room) {
          n = room;
          c->full = 1;
        }
        int added = ls_out_put_at(c, c->head_h, c->head_h, c->head_h + n);
        if (added > 0) {
          c->grew_top = 1;
          c->last_dir = -1;
          c->pending_top += added;
        }
        c->at = 0;
      }
    } else {
      int past = (c->at + d) + band - laid;
      if (past > eff_band) {
        c->lost = 1;
        ls_dump(c, "jump-down", moving, d, past, eff_band);
        return 1;
      }
      ls_dump(c, "moved", moving, d, c->at, laid);
      c->at += d;
      if (past > 0) {
        int room = LS_MOST_ROWS - c->out_h;
        if (past > room) {
          past = room;
          c->full = 1;
        }
        if (past > 0) {
          int before = c->out_h;
          c->out_h -= c->foot_h;
          ls_out_add_exact(c, c->h - c->foot_h - past, c->h - c->foot_h);
          if (c->foot_h > 0) ls_out_add_exact(c, c->h - c->foot_h, c->h);
          if (c->out_h > before) c->last_dir = 1;
        }
        c->at = c->out_h - c->head_h - c->foot_h - band;
      }
    }
  }
  c->lost = 0;
  c->pictures++;
  uint8_t *p = c->ref;
  c->ref = c->now;
  c->now = p;
  uint64_t *hp = c->ref_hash;
  c->ref_hash = c->now_hash;
  c->now_hash = hp;
  uint8_t *fp = c->ref_flat;
  c->ref_flat = c->now_flat;
  c->now_flat = fp;
  uint8_t *pp = c->ref_prof;
  c->ref_prof = c->now_prof;
  c->now_prof = pp;
  int pok = c->ref_prof_ok;
  c->ref_prof_ok = c->now_prof_ok;
  c->now_prof_ok = pok;
  return 1;
}

static inline int ls_preview_dims(const LongCore *c, int box_w, int box_h, int from_row, int *out_from, int *out_src_h,
                                  int *out_pw, int *out_ph) {
  if (!c->out_h || box_w <= 0 || box_h <= 0) return 0;
  double k = (double)box_w / (double)c->w;
  if (k > 1.0) k = 1.0;
  int vis_rows = (int)((double)box_h / k + 0.5);
  if (vis_rows < 1) vis_rows = 1;
  int max_from = c->out_h > vis_rows ? c->out_h - vis_rows : 0;
  int from = from_row < 0 ? 0 : (from_row > max_from ? max_from : from_row);
  int src_h = c->out_h - from;
  if (src_h > vis_rows) src_h = vis_rows;
  int pw = (int)((double)c->w * k + 0.5);
  int ph = (int)((double)src_h * k + 0.5);
  if (pw < 1) pw = 1;
  if (ph < 1) ph = 1;
  if (ph > box_h) ph = box_h;
  *out_from = from;
  *out_src_h = src_h;
  *out_pw = pw;
  *out_ph = ph;
  return 1;
}

static inline void ls_preview_render(const LongCore *c, int from, int src_h, int pw, int ph, uint8_t *dst) {
  if (pw == c->w && ph == src_h) {
    size_t row = (size_t)pw * 4;
    for (int y = 0; y < ph; y++) {
      const uint8_t *s = c->out + (size_t)(from + y) * row;
      uint8_t *d = dst + (size_t)y * row;
      memcpy(d, s, row);
      for (int x = 0; x < pw; x++) d[(size_t)x * 4 + 3] = 255;
    }
    return;
  }
  size_t stack_xa[1024], stack_xb[1024];
  size_t *xa = pw <= 1024 ? stack_xa : (size_t *)malloc((size_t)pw * sizeof(size_t));
  size_t *xb = pw <= 1024 ? stack_xb : (size_t *)malloc((size_t)pw * sizeof(size_t));
  if (!xa || !xb) {
    if (xa && xa != stack_xa) free(xa);
    if (xb && xb != stack_xb) free(xb);
    return;
  }
  for (int x = 0; x < pw; x++) {
    int x0 = (int)((int64_t)x * c->w / pw);
    int x1 = (int)((int64_t)(x + 1) * c->w / pw);
    int span = x1 - x0;
    int a = span >= 4 ? x0 + span / 4 : x0;
    int b = span >= 4 ? x0 + (span * 3) / 4 : (span >= 2 ? x0 + span / 2 : x0);
    if (a >= c->w) a = c->w - 1;
    if (b >= c->w) b = c->w - 1;
    xa[x] = (size_t)a * 4;
    xb[x] = (size_t)b * 4;
  }
  size_t stride = (size_t)c->w * 4;
  for (int y = 0; y < ph; y++) {
    int y0 = from + (int)((int64_t)y * src_h / ph);
    int y1 = from + (int)((int64_t)(y + 1) * src_h / ph);
    int span = y1 - y0;
    int ya = span >= 4 ? y0 + span / 4 : y0;
    int yb = span >= 4 ? y0 + (span * 3) / 4 : (span >= 2 ? y0 + span / 2 : y0);
    if (ya >= c->out_h) ya = c->out_h - 1;
    if (yb >= c->out_h) yb = c->out_h - 1;
    const uint8_t *row0 = c->out + (size_t)ya * stride;
    const uint8_t *row1 = c->out + (size_t)yb * stride;
    uint8_t *d = dst + (size_t)y * (size_t)pw * 4;
    for (int x = 0; x < pw; x++, d += 4) {
      const uint8_t *pa = row0 + xa[x];
      const uint8_t *pb = row0 + xb[x];
      const uint8_t *pc = row1 + xa[x];
      const uint8_t *pd = row1 + xb[x];
      d[0] = (uint8_t)((pa[0] + pb[0] + pc[0] + pd[0] + 2u) >> 2);
      d[1] = (uint8_t)((pa[1] + pb[1] + pc[1] + pd[1] + 2u) >> 2);
      d[2] = (uint8_t)((pa[2] + pb[2] + pc[2] + pd[2] + 2u) >> 2);
      d[3] = 255;
    }
  }
  if (xa != stack_xa) free(xa);
  if (xb != stack_xb) free(xb);
}

#endif
