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

// PinShot-Setup's entry in Settings > Apps (packaging/PinShot.iss: AppId, as Inno Setup names it)
#define UNINSTALL_KEY L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\{6B0F3C2E-8A41-4F7D-9C55-2E1B7D3A9F10}_is1"

// The folder of the running exe, no backslash at its end.
static void exe_dir(wchar_t *out, DWORD n) {
  GetModuleFileNameW(NULL, out, n);
  wchar_t *slash = wcsrchr(out, L'\\');
  if (slash) *slash = 0;
}

// 2 a Store package (the Store updates it), 1 installed by PinShot-Setup (its installer updates it), 0 the portable
// exe (swapped for the new one).
int32_t ps_install_kind(void) {
  if (ps_packaged()) return 2;
  HKEY k;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, UNINSTALL_KEY, 0, KEY_READ, &k) != ERROR_SUCCESS) return 0;
  wchar_t at[MAX_PATH * 2] = {0};
  DWORD size = sizeof at - sizeof(wchar_t), type = 0;
  LONG r = RegQueryValueExW(k, L"InstallLocation", NULL, &type, (BYTE *)at, &size);
  RegCloseKey(k);
  if (r != ERROR_SUCCESS || type != REG_SZ) return 0;
  size_t n = wcslen(at);
  while (n > 0 && at[n - 1] == L'\\') at[--n] = 0;
  wchar_t mine[MAX_PATH * 2] = {0};
  exe_dir(mine, MAX_PATH * 2);
  // (the portable exe run from elsewhere while PinShot is also installed is still the portable one)
  return CompareStringOrdinal(at, -1, mine, -1, TRUE) == CSTR_EQUAL ? 1 : 0;
}

// Where an update is downloaded to: the installer in %TEMP%\PinShot-update (made); the portable exe beside itself
// (pinshot.exe.download: the same folder, so it can be moved over it, and a folder it cannot write is found before
// anything is fetched).
moonbit_bytes_t ps_update_path(moonbit_bytes_t name) {
  wchar_t p[MAX_PATH * 2] = {0};
  if (ps_install_kind() == 0) {
    GetModuleFileNameW(NULL, p, MAX_PATH * 2);
    wcscat_s(p, MAX_PATH * 2, L".download");
    return up_utf8(p);
  }
  GetTempPathW(MAX_PATH, p);
  wcscat_s(p, MAX_PATH * 2, L"PinShot-update");
  CreateDirectoryW(p, NULL);
  wchar_t *w = up_wide((const char *)name);
  wcscat_s(p, MAX_PATH * 2, L"\\");
  wcscat_s(p, MAX_PATH * 2, w);
  free(w);
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

// ---- a fetch ----

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
  size_t body_n = 0;
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
  if (!WinHttpCrackUrl(f->url, 0, 0, &u) || u.nScheme != INTERNET_SCHEME_HTTPS) {
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
  r = c ? WinHttpOpenRequest(c, L"GET", path, NULL, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, WINHTTP_FLAG_SECURE)
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
  } else {
    body = (uint8_t *)malloc(SMALL_MOST);
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
    if (f->sha[0] && _stricmp(hex, f->sha) != 0) {
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
// it and moved over it once whole and, where `sha256` is not empty, of that SHA-256). `agent` is its User-Agent. 1 it
// is under way (told back on "ps"), 0 another fetch is.
int32_t ps_fetch(moonbit_bytes_t url, moonbit_bytes_t path, moonbit_bytes_t sha256, moonbit_bytes_t agent) {
  if (InterlockedCompareExchange(&fetch_busy, 1, 0) != 0) return 0;
  Fetch *f = (Fetch *)calloc(1, sizeof(Fetch));
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

// The installer downloaded (`path`) run silently, as an update: it quits this run (pinshot.exe --quit), replaces the
// exe, keeps the choices made as it was installed (start with Windows, the desktop icon) and starts PinShot again
// (packaging/PinShot.iss: /UPDATE). 1 it was started.
int32_t ps_run_setup(moonbit_bytes_t path) {
  wchar_t *w = up_wide((const char *)path);
  SHELLEXECUTEINFOW e;
  memset(&e, 0, sizeof e);
  e.cbSize = sizeof e;
  e.fMask = SEE_MASK_NOASYNC;
  e.lpVerb = L"open";
  e.lpFile = w;
  e.lpParameters = L"/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /UPDATE";
  e.nShow = SW_HIDE;
  BOOL ok = ShellExecuteExW(&e);
  free(w);
  return ok ? 1 : 0;
}

// The portable exe swapped for the one downloaded (`path`, beside it) and started in its place: the running exe moved
// aside to pinshot.exe.old (Windows lets a running exe be renamed, not written; the new run deletes it), the new one
// moved in, this run's mutex and icon let go and the new one started with --updated, this one ended. Where any of that
// fails, what was moved is put back and 0 is answered (this run goes on).
int32_t ps_swap_exe(moonbit_bytes_t path) {
  wchar_t exe[MAX_PATH * 2], old[MAX_PATH * 2 + 8];
  GetModuleFileNameW(NULL, exe, MAX_PATH * 2);
  _snwprintf(old, MAX_PATH * 2 + 7, L"%ls.old", exe);
  wchar_t *fresh = up_wide((const char *)path);
  DeleteFileW(old);
  if (!MoveFileExW(exe, old, MOVEFILE_REPLACE_EXISTING)) {
    free(fresh);
    return 0;
  }
  if (!MoveFileExW(fresh, exe, MOVEFILE_REPLACE_EXISTING)) {
    MoveFileExW(old, exe, MOVEFILE_REPLACE_EXISTING);
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
    DeleteFileW(exe);
    MoveFileExW(old, exe, MOVEFILE_REPLACE_EXISTING);
    _snwprintf(cmd, MAX_PATH * 2 + 31, L"\"%ls\"", exe);
    if (!CreateProcessW(exe, cmd, NULL, NULL, FALSE, 0, NULL, dir, &si, &pi)) ExitProcess(1);
  }
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
  return (int32_t)(GetTickCount() - li.dwTime);
}

static void CALLBACK update_tick(void *arg, BOOLEAN fired) {
  (void)arg;
  (void)fired;
  up_tell("{\"do\":\"update-tick\"}", NULL, 0);
}

// {"do":"update-tick"} told after `first_ms`, then every `every_ms` (once: a second call does nothing).
void ps_update_ticks(int32_t first_ms, int32_t every_ms) {
  static HANDLE timer;
  if (timer) return;
  CreateTimerQueueTimer(&timer, NULL, update_tick, NULL, (DWORD)first_ms, (DWORD)every_ms, WT_EXECUTEDEFAULT);
}
