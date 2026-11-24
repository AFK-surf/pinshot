// PinShot's updates, the Windows side (update.mbt decides when and what; platform.mbt says each call): how this copy
// was installed, a file fetched over HTTPS on a thread of its own (WinHTTP, the system's proxy) and its SHA-256 checked
// as it comes, and the new version put in place: the installer run silently (installed by PinShot-Setup), or the exe
// swapped for the new one and started (the portable pinshot.exe). A Store package is updated by the Store: none of this
// runs there.
//
// What a fetch comes to is told the app on its channel "ps" (mb_post, from the fetch's thread: the host copies it in
// and hands it to the next frame): {"do":"fetching","got":N,"total":N} as a download goes, {"do":"fetched","ok":true,
// "status":200} with the body beside it (a small fetch) or {"do":"fetched","ok":true,"file":true} (a download, checked
// and in place), {"do":"fetched","ok":false,"error":"..."} where it failed.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winhttp.h>
#include <bcrypt.h>
#include <shellapi.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "moonbit.h"

#pragma comment(lib, "winhttp.lib")
#pragma comment(lib, "bcrypt.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "advapi32.lib")

extern void mb_post(const char *channel, const char *json, size_t len, const uint8_t *bytes, size_t blen);
// (platform_win.c: the run's one-run mutex and its icon let go, so the run started next is the one run)
void ps_run_handover(void);
// (startup_task.cpp)
int ps_packaged(void);

static void up_tell(const char *json, const uint8_t *bytes, size_t blen) {
  mb_post("ps", json, strlen(json), bytes, blen);
}

static void up_failed(const char *why) {
  char json[256];
  snprintf(json, sizeof json, "{\"do\":\"fetched\",\"ok\":false,\"error\":\"%s\"}", why);
  up_tell(json, NULL, 0);
}

static wchar_t *up_wide(const char *utf8) {
  int n = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, NULL, 0);
  wchar_t *w = (wchar_t *)malloc(sizeof(wchar_t) * (n > 0 ? n : 1));
  if (n > 0) MultiByteToWideChar(CP_UTF8, 0, utf8, -1, w, n);
  else w[0] = 0;
  return w;
}

static moonbit_bytes_t up_utf8(const wchar_t *w) {
  int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, NULL, 0, NULL, NULL);
  if (n <= 1) return moonbit_make_bytes(0, 0);
  moonbit_bytes_t b = moonbit_make_bytes(n - 1, 0);
  WideCharToMultiByte(CP_UTF8, 0, w, -1, (char *)b, n - 1, NULL, NULL);
  return b;
}

// ---- how this copy was installed ----

// The folder of the running exe, no backslash at its end.
static void exe_dir(wchar_t *out, DWORD n) {
  GetModuleFileNameW(NULL, out, n);
  wchar_t *slash = wcsrchr(out, L'\\');
  if (slash) *slash = 0;
}

// 2 a Store package (the Store updates it), 0 the single-file exe (both self-installed and portable copies update
// atomically in place by swapping pinshot.exe).
int32_t ps_install_kind(void) {
  return ps_packaged() ? 2 : 0;
}

// Where an update is downloaded to: beside the running exe (pinshot.exe.download: same folder so MoveFileExW is atomic
// and a non-writable folder is caught before anything is fetched).
moonbit_bytes_t ps_update_path(moonbit_bytes_t name) {
  const char *n = (const char *)name;
  if (!n[0] || strpbrk(n, "\\/:*?\"<>|") || strstr(n, "..")) return moonbit_make_bytes(0, 0);
  wchar_t p[MAX_PATH * 2] = {0};
  GetModuleFileNameW(NULL, p, MAX_PATH * 2);
  wcscat_s(p, MAX_PATH * 2, L".download");
  return up_utf8(p);
}

// What an earlier update left: the old exe moved aside (pinshot.exe.old) and a download not finished. (The installer
// left in %TEMP% is let go of by the system's cleanup; it is removed here too once it is no longer running.)
void ps_update_cleanup(void) {
  wchar_t exe[MAX_PATH * 2], p[MAX_PATH * 2 + 16];
  GetModuleFileNameW(NULL, exe, MAX_PATH * 2);
  _snwprintf(p, MAX_PATH * 2 + 15, L"%ls.old", exe);
  DeleteFileW(p);
  _snwprintf(p, MAX_PATH * 2 + 15, L"%ls.download", exe);
  DeleteFileW(p);
  _snwprintf(p, MAX_PATH * 2 + 15, L"%ls.download.part", exe);
  DeleteFileW(p);
  wchar_t dir[MAX_PATH * 2] = {0};
  GetTempPathW(MAX_PATH, dir);
  wcscat_s(dir, MAX_PATH * 2, L"PinShot-update");
  wchar_t pat[MAX_PATH * 2 + 4];
  _snwprintf(pat, MAX_PATH * 2 + 3, L"%ls\\*", dir);
  WIN32_FIND_DATAW f;
  HANDLE h = FindFirstFileW(pat, &f);
  if (h != INVALID_HANDLE_VALUE) {
    do {
      if (f.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) continue;
      _snwprintf(p, MAX_PATH * 2 + 15, L"%ls\\%ls", dir, f.cFileName);
      DeleteFileW(p);
    } while (FindNextFileW(h, &f));
    FindClose(h);
  }
}

// ---- what a release is: signed ----

// The key releases are signed with (ECDSA P-256; its private half is in the owner's still.fail vault, 「PinShot 更新签名私
// 钥」, and packaging/publish.ps1 signs latest.json with it). What latest.json says is taken only signed by it: the
// SHA-256 a download is checked against comes from there, so whoever could change the files on the download site
// could otherwise have every copy that updates itself run a program of theirs.
static const uint8_t release_key_x[32] = {
    0x5d, 0x53, 0x16, 0xca, 0x6a, 0xab, 0xf5, 0xd9, 0x01, 0x26, 0x5a, 0x15, 0xbe, 0x52, 0xf4, 0x80,
    0xa7, 0x64, 0x54, 0xc0, 0x52, 0x0f, 0xad, 0x96, 0xb1, 0x75, 0x01, 0x82, 0xb7, 0x72, 0xd3, 0x5e};
static const uint8_t release_key_y[32] = {
    0xcd, 0x71, 0xe3, 0xc7, 0xfe, 0x26, 0xb5, 0xf7, 0xa6, 0x11, 0xbe, 0xd0, 0xb7, 0xbb, 0xa7, 0x48,
    0xf3, 0x09, 0x8d, 0x3c, 0xae, 0x9d, 0xd0, 0xb8, 0x29, 0xe2, 0x5c, 0x18, 0x58, 0x86, 0x6b, 0xbc};

static int hex_digit(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

// `hex` (exactly 2 * n hex digits) into `out`: 1 it was.
static int from_hex(const char *hex, uint8_t *out, size_t n) {
  if (strlen(hex) != n * 2) return 0;
  for (size_t i = 0; i < n; i++) {
    int a = hex_digit(hex[i * 2]), b = hex_digit(hex[i * 2 + 1]);
    if (a < 0 || b < 0) return 0;
    out[i] = (uint8_t)(a * 16 + b);
  }
  return 1;
}

static int sha256_of(const uint8_t *data, size_t n, uint8_t digest[32]) {
  BCRYPT_ALG_HANDLE alg = NULL;
  BCRYPT_HASH_HANDLE h = NULL;
  int ok = BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA256_ALGORITHM, NULL, 0) == 0 &&
           BCryptCreateHash(alg, &h, NULL, 0, NULL, 0, 0) == 0 && BCryptHashData(h, (PUCHAR)data, (ULONG)n, 0) == 0 &&
           BCryptFinishHash(h, digest, 32, 0) == 0;
  if (h) BCryptDestroyHash(h);
  if (alg) BCryptCloseAlgorithmProvider(alg, 0);
  return ok;
}

// Whether `sig` (hex, r then s, 64 bytes) is the release key's signature of the release named: the bytes
// "pinshot-update\n<version>\n<setup_sha256>\n<exe_sha256>\n" (what packaging/publish.ps1 signs). 1 it is.
int32_t ps_release_signed(moonbit_bytes_t version, moonbit_bytes_t setup_sha, moonbit_bytes_t exe_sha,
                          moonbit_bytes_t sig) {
  uint8_t s[64], digest[32];
  if (!from_hex((const char *)sig, s, 64)) return 0;
  char msg[512];
  int n = snprintf(msg, sizeof msg, "pinshot-update\n%s\n%s\n%s\n", (const char *)version, (const char *)setup_sha,
                   (const char *)exe_sha);
  if (n <= 0 || n >= (int)sizeof msg || !sha256_of((const uint8_t *)msg, (size_t)n, digest)) return 0;
  struct {
    BCRYPT_ECCKEY_BLOB head;
    uint8_t xy[64];
  } blob;
  blob.head.dwMagic = BCRYPT_ECDSA_PUBLIC_P256_MAGIC;
  blob.head.cbKey = 32;
  memcpy(blob.xy, release_key_x, 32);
  memcpy(blob.xy + 32, release_key_y, 32);
  BCRYPT_ALG_HANDLE alg = NULL;
  BCRYPT_KEY_HANDLE key = NULL;
  int ok = BCryptOpenAlgorithmProvider(&alg, BCRYPT_ECDSA_P256_ALGORITHM, NULL, 0) == 0 &&
           BCryptImportKeyPair(alg, NULL, BCRYPT_ECCPUBLIC_BLOB, &key, (PUCHAR)&blob, sizeof blob, 0) == 0 &&
           BCryptVerifySignature(key, NULL, digest, 32, s, 64, 0) == 0;
  if (key) BCryptDestroyKey(key);
  if (alg) BCryptCloseAlgorithmProvider(alg, 0);
  return ok ? 1 : 0;
}

// The file `f` (open) read through and its SHA-256 compared with `sha` (lowercase hex): 1 it is that.
static int file_is(HANDLE f, const char *sha) {
  uint8_t want[32];
  if (!from_hex(sha, want, 32)) return 0;
  BCRYPT_ALG_HANDLE alg = NULL;
  BCRYPT_HASH_HANDLE h = NULL;
  int ok = 0;
  // (read in 64 KB pieces, its buffer only while it is read: none kept in the program for good)
  uint8_t *buf = (uint8_t *)malloc(64 * 1024);
  if (buf && BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA256_ALGORITHM, NULL, 0) == 0 &&
      BCryptCreateHash(alg, &h, NULL, 0, NULL, 0, 0) == 0) {
    LARGE_INTEGER zero = {0};
    SetFilePointerEx(f, zero, NULL, FILE_BEGIN);
    DWORD n = 0;
    ok = 1;
    while (ReadFile(f, buf, 64 * 1024, &n, NULL) && n > 0)
      if (BCryptHashData(h, buf, n, 0) != 0) ok = 0;
    uint8_t got[32];
    ok = ok && BCryptFinishHash(h, got, 32, 0) == 0 && memcmp(got, want, 32) == 0;
  }
  if (h) BCryptDestroyHash(h);
  if (alg) BCryptCloseAlgorithmProvider(alg, 0);
  free(buf);
  return ok;
}

// The file at `path` opened so that nothing can write it while it is open (it may be read, and moved), or
// INVALID_HANDLE_VALUE.
static HANDLE open_sealed(const wchar_t *path) {
  return CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_DELETE, NULL, OPEN_EXISTING, 0, NULL);
}

// ---- a fetch ----

// Whether `url` may be fetched: https only; a test run (PINSHOT_TEST) may also fetch http from this machine
// (127.0.0.1), where updates are tried out against a release served here (PINSHOT_UPDATE_URL).
static int url_allowed(const URL_COMPONENTS *u) {
  if (u->nScheme == INTERNET_SCHEME_HTTPS) return 1;
  const char *t = getenv("PINSHOT_TEST");
  return t && t[0] && u->nScheme == INTERNET_SCHEME_HTTP && wcscmp(u->lpszHostName, L"127.0.0.1") == 0;
}

typedef struct {
  wchar_t *url;
  wchar_t *path;  // NULL: the body is told back beside the message (at most 1 MB)
  char sha[65];   // the SHA-256 the download must have (lowercase hex); "" none checked
  char agent[64];
} Fetch;

static volatile LONG fetch_busy;

#define SMALL_MOST (1024 * 1024)

static void fetch_free(Fetch *f) {
  free(f->url);
  free(f->path);
  free(f);
}

static DWORD WINAPI fetch_work(void *arg) {
  Fetch *f = (Fetch *)arg;
  HINTERNET s = NULL, c = NULL, r = NULL;
  HANDLE out = INVALID_HANDLE_VALUE;
  BCRYPT_ALG_HANDLE alg = NULL;
  BCRYPT_HASH_HANDLE hash = NULL;
  uint8_t *body = NULL;
  size_t body_n = 0, body_cap = 0;
  wchar_t *part = NULL;
  const char *why = NULL;
  char json[192];
  wchar_t *agent = NULL;
  DWORD status = 0, sz = sizeof status;
  uint64_t total = 0, got = 0;
  DWORD last_told = GetTickCount();
  uint8_t buf[64 * 1024];

  URL_COMPONENTS u;
  memset(&u, 0, sizeof u);
  u.dwStructSize = sizeof u;
  wchar_t host[256] = {0}, path[2048] = {0};
  u.lpszHostName = host;
  u.dwHostNameLength = 255;
  u.lpszUrlPath = path;
  u.dwUrlPathLength = 2047;
  if (!WinHttpCrackUrl(f->url, 0, 0, &u) || !url_allowed(&u)) {
    why = "bad url";
    goto done;
  }
  agent = up_wide(f->agent);
  s = WinHttpOpen(agent, WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
  free(agent);
  if (!s) {
    why = "network unavailable";
    goto done;
  }
  // (resolve, connect, send 15 s each; 30 s with nothing received)
  WinHttpSetTimeouts(s, 15000, 15000, 15000, 30000);
  c = WinHttpConnect(s, host, u.nPort, 0);
  r = c ? WinHttpOpenRequest(c, L"GET", path, NULL, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES,
                             WINHTTP_FLAG_REFRESH | (u.nScheme == INTERNET_SCHEME_HTTPS ? WINHTTP_FLAG_SECURE : 0))
        : NULL;
  if (!r || !WinHttpSendRequest(r, WINHTTP_NO_ADDITIONAL_HEADERS, 0, WINHTTP_NO_REQUEST_DATA, 0, 0, 0) ||
      !WinHttpReceiveResponse(r, NULL)) {
    why = "network unavailable";
    goto done;
  }
  WinHttpQueryHeaders(r, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX, &status, &sz,
                      WINHTTP_NO_HEADER_INDEX);
  if (status != 200) {
    snprintf(json, sizeof json, "http %lu", (unsigned long)status);
    why = json;
    goto done;
  }
  {
    wchar_t len[32] = {0};
    DWORD ln = sizeof len;
    if (WinHttpQueryHeaders(r, WINHTTP_QUERY_CONTENT_LENGTH, WINHTTP_HEADER_NAME_BY_INDEX, len, &ln, WINHTTP_NO_HEADER_INDEX))
      total = _wcstoui64(len, NULL, 10);
  }
  if (f->path) {
    size_t n = wcslen(f->path) + 8;
    part = (wchar_t *)malloc(n * sizeof(wchar_t));
    _snwprintf(part, n, L"%ls.part", f->path);
    out = CreateFileW(part, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, 0, NULL);
    if (out == INVALID_HANDLE_VALUE) {
      why = "cannot write";
      goto done;
    }
    if (BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA256_ALGORITHM, NULL, 0) != 0 ||
        BCryptCreateHash(alg, &hash, NULL, 0, NULL, 0, 0) != 0) {
      why = "no sha256";
      goto done;
    }
  }
  for (;;) {
    DWORD n = 0;
    if (!WinHttpReadData(r, buf, sizeof buf, &n)) {
      why = "network unavailable";
      goto done;
    }
    if (n == 0) break;
    got += n;
    if (f->path) {
      DWORD put = 0;
      if (!WriteFile(out, buf, n, &put, NULL) || put != n) {
        why = "cannot write";
        goto done;
      }
      BCryptHashData(hash, buf, n, 0);
      DWORD now = GetTickCount();
      if (now - last_told >= 200) {
        last_told = now;
        snprintf(json, sizeof json, "{\"do\":\"fetching\",\"got\":%llu,\"total\":%llu}", (unsigned long long)got,
                 (unsigned long long)total);
        up_tell(json, NULL, 0);
      }
    } else {
      if (body_n + n > SMALL_MOST) {
        why = "too large";
        goto done;
      }
      // (grown as it comes, to what it is: latest.json is a few hundred bytes, not the 1 MB it may be at most)
      if (body_n + n > body_cap) {
        size_t cap = body_cap ? body_cap * 2 : 16 * 1024;
        while (cap < body_n + n) cap *= 2;
        if (cap > SMALL_MOST) cap = SMALL_MOST;
        uint8_t *grown = (uint8_t *)realloc(body, cap);
        if (!grown) {
          why = "out of memory";
          goto done;
        }
        body = grown, body_cap = cap;
      }
      memcpy(body + body_n, buf, n);
      body_n += n;
    }
  }
  if (total && got != total) {
    why = "network unavailable";
    goto done;
  }
  if (f->path) {
    CloseHandle(out);
    out = INVALID_HANDLE_VALUE;
    uint8_t digest[32];
    BCryptFinishHash(hash, digest, 32, 0);
    char hex[65];
    for (int i = 0; i < 32; i++) snprintf(hex + i * 2, 3, "%02x", digest[i]);
    if (_stricmp(hex, f->sha) != 0) {
      why = "checksum";
      goto done;
    }
    if (!MoveFileExW(part, f->path, MOVEFILE_REPLACE_EXISTING)) {
      why = "cannot write";
      goto done;
    }
    up_tell("{\"do\":\"fetched\",\"ok\":true,\"file\":true}", NULL, 0);
  } else {
    up_tell("{\"do\":\"fetched\",\"ok\":true,\"status\":200}", body, body_n);
  }

done:
  if (out != INVALID_HANDLE_VALUE) CloseHandle(out);
  if (why && part) DeleteFileW(part);
  if (hash) BCryptDestroyHash(hash);
  if (alg) BCryptCloseAlgorithmProvider(alg, 0);
  if (r) WinHttpCloseHandle(r);
  if (c) WinHttpCloseHandle(c);
  if (s) WinHttpCloseHandle(s);
  free(body);
  free(part);
  fetch_free(f);
  // (free for the next before it is told: the app may ask for another as it hears this one failed)
  InterlockedExchange(&fetch_busy, 0);
  if (why) up_failed(why);
  return 0;
}

// `url` (https only) fetched on a thread of its own: into memory (`path` empty) or into the file `path` (written beside
// it and moved over it once whole and of the SHA-256 `sha256`: a file is never fetched unchecked). `agent` is its
// User-Agent. 1 it is under way (told back on "ps"), 0 not (another fetch is, or a file with no SHA-256 to check).
int32_t ps_fetch(moonbit_bytes_t url, moonbit_bytes_t path, moonbit_bytes_t sha256, moonbit_bytes_t agent) {
  uint8_t sha_bytes[32];
  if (((const char *)path)[0] && !from_hex((const char *)sha256, sha_bytes, 32)) return 0;
  if (InterlockedCompareExchange(&fetch_busy, 1, 0) != 0) return 0;
  Fetch *f = (Fetch *)calloc(1, sizeof(Fetch));
  if (!f) {
    InterlockedExchange(&fetch_busy, 0);
    return 0;
  }
  f->url = up_wide((const char *)url);
  f->path = ((const char *)path)[0] ? up_wide((const char *)path) : NULL;
  lstrcpynA(f->sha, (const char *)sha256, sizeof f->sha);
  lstrcpynA(f->agent, (const char *)agent, sizeof f->agent);
  HANDLE t = CreateThread(NULL, 0, fetch_work, f, 0, NULL);
  if (!t) {
    fetch_free(f);
    InterlockedExchange(&fetch_busy, 0);
    return 0;
  }
  CloseHandle(t);
  return 1;
}

// ---- the new version put in place ----

// The exe swapped for the one downloaded (`path`, beside it) and started in its place: the running exe moved
// aside to pinshot.exe.old (Windows lets a running exe be renamed, not written; the new run deletes it), the new one
// moved in, this run's mutex and icon let go and the new one started with --updated, this one ended. Where any of that
// fails, what was moved is put back and 0 is answered (this run goes on). The new exe is checked once more to be of
// `sha256` before anything is moved, and kept from being written until it is started; -1 it is not that file.
int32_t ps_swap_exe(moonbit_bytes_t path, moonbit_bytes_t sha256) {
  wchar_t exe[MAX_PATH * 2], old[MAX_PATH * 2 + 8];
  GetModuleFileNameW(NULL, exe, MAX_PATH * 2);
  _snwprintf(old, MAX_PATH * 2 + 7, L"%ls.old", exe);
  wchar_t *fresh = up_wide((const char *)path);
  HANDLE sealed = open_sealed(fresh);
  if (sealed == INVALID_HANDLE_VALUE || !file_is(sealed, (const char *)sha256)) {
    if (sealed != INVALID_HANDLE_VALUE) CloseHandle(sealed);
    DeleteFileW(fresh);
    free(fresh);
    return -1;
  }
  DeleteFileW(old);
  if (!MoveFileExW(exe, old, MOVEFILE_REPLACE_EXISTING)) {
    CloseHandle(sealed);
    free(fresh);
    return 0;
  }
  if (!MoveFileExW(fresh, exe, MOVEFILE_REPLACE_EXISTING)) {
    MoveFileExW(old, exe, MOVEFILE_REPLACE_EXISTING);
    CloseHandle(sealed);
    free(fresh);
    return 0;
  }
  free(fresh);
  ps_run_handover();
  wchar_t cmd[MAX_PATH * 2 + 32], dir[MAX_PATH * 2];
  _snwprintf(cmd, MAX_PATH * 2 + 31, L"\"%ls\" --updated", exe);
  exe_dir(dir, MAX_PATH * 2);
  STARTUPINFOW si;
  PROCESS_INFORMATION pi;
  memset(&si, 0, sizeof si);
  si.cb = sizeof si;
  if (!CreateProcessW(exe, cmd, NULL, NULL, FALSE, 0, NULL, dir, &si, &pi)) {
    // (the new exe would not start: the old one put back and started, so PinShot is still there)
    CloseHandle(sealed);
    sealed = INVALID_HANDLE_VALUE;
    DeleteFileW(exe);
    MoveFileExW(old, exe, MOVEFILE_REPLACE_EXISTING);
    _snwprintf(cmd, MAX_PATH * 2 + 31, L"\"%ls\"", exe);
    if (!CreateProcessW(exe, cmd, NULL, NULL, FALSE, 0, NULL, dir, &si, &pi)) ExitProcess(1);
  }
  if (sealed != INVALID_HANDLE_VALUE) CloseHandle(sealed);
  CloseHandle(pi.hThread);
  CloseHandle(pi.hProcess);
  ExitProcess(0);
  return 1;
}

// ---- small things ----

// A web page opened in the person's browser (https only).
void ps_open_url(moonbit_bytes_t url) {
  if (strncmp((const char *)url, "https://", 8) != 0) return;
  wchar_t *w = up_wide((const char *)url);
  ShellExecuteW(NULL, L"open", w, NULL, NULL, SW_SHOWNORMAL);
  free(w);
}

// Seconds since 1970 (UTC): when the last check was, kept across runs.
double ps_epoch_s(void) {
  FILETIME ft;
  GetSystemTimeAsFileTime(&ft);
  ULARGE_INTEGER t;
  t.LowPart = ft.dwLowDateTime;
  t.HighPart = ft.dwHighDateTime;
  return (double)(t.QuadPart - 116444736000000000ULL) / 1e7;
}

// How long the person has not touched the keyboard or the mouse, in ms.
int32_t ps_idle_ms(void) {
  LASTINPUTINFO li;
  li.cbSize = sizeof li;
  if (!GetLastInputInfo(&li)) return 0;
  // (a DWORD's difference, right across GetTickCount's wrap; past 24.8 days, as long as an Int says)
  DWORD idle = GetTickCount() - li.dwTime;
  return idle > 0x7FFFFFFFu ? 0x7FFFFFFF : (int32_t)idle;
}

static void CALLBACK update_tick(void *arg, BOOLEAN fired) {
  (void)arg;
  (void)fired;
  up_tell("{\"do\":\"update-tick\"}", NULL, 0);
}

// {"do":"update-tick"} told after `first_ms`, then every `every_ms` (once: a second call does nothing while they go);
// `every_ms` 0: they stop (自动更新 turned off: no timer kept for nothing).
void ps_update_ticks(int32_t first_ms, int32_t every_ms) {
  static HANDLE timer;
  if (every_ms <= 0) {
    if (timer) DeleteTimerQueueTimer(NULL, timer, NULL);
    timer = NULL;
    return;
  }
  if (timer) return;
  if (!CreateTimerQueueTimer(&timer, NULL, update_tick, NULL, (DWORD)first_ms, (DWORD)every_ms, WT_EXECUTEDEFAULT))
    timer = NULL;
}
