#define WIN32_LEAN_AND_MEAN
#define COBJMACROS
#include <windows.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <shellapi.h>
#include <objbase.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include "moonbit.h"

#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "uuid.lib")
#pragma comment(lib, "user32.lib")

int ps_packaged(void);
int32_t ps_ui_chinese(void);

#define INST_PATH_CAP 1024

#define UNINSTALL_KEY_REAL L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\PinShot"
#define UNINSTALL_KEY_TEST L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\PinShot-Test"
#define LEGACY_INNO_KEY_REAL L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\{6B0F3C2E-8A41-4F7D-9C55-2E1B7D3A9F10}_is1"
#define LEGACY_INNO_KEY_TEST L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\PinShot-Test_is1"
#define RUN_SUBKEY L"Software\\Microsoft\\Windows\\CurrentVersion\\Run"

static int inst_is_test(void) {
  const char *t = getenv("PINSHOT_TEST");
  return t && t[0];
}

static int inst_test_root(wchar_t *out, size_t cap) {
  out[0] = 0;
  if (!inst_is_test()) return 0;
  DWORD n = GetEnvironmentVariableW(L"PINSHOT_TEST_ROOT", out, (DWORD)cap);
  if (n == 0 || n >= cap) {
    out[0] = 0;
    return 0;
  }
  while (n > 0 && (out[n - 1] == L'\\' || out[n - 1] == L'/')) out[--n] = 0;
  return n > 0;
}

static const wchar_t *uninstall_subkey(void) {
  return inst_is_test() ? UNINSTALL_KEY_TEST : UNINSTALL_KEY_REAL;
}

static const wchar_t *legacy_inno_subkey(void) {
  return inst_is_test() ? LEGACY_INNO_KEY_TEST : LEGACY_INNO_KEY_REAL;
}

static const wchar_t *run_value_name(void) {
  return inst_is_test() ? L"PinShot-Test" : L"PinShot";
}

static void inst_wide(const char *utf8, wchar_t *out, size_t cap) {
  if (!cap) return;
  out[0] = 0;
  if (!utf8 || !utf8[0]) return;
  int n = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, out, (int)cap);
  if (n <= 0) out[0] = 0;
}

static void trim_trailing_slash(wchar_t *p) {
  size_t n = wcslen(p);
  while (n > 3 && (p[n - 1] == L'\\' || p[n - 1] == L'/')) p[--n] = 0;
}

static int same_path(const wchar_t *a, const wchar_t *b) {
  wchar_t fa[INST_PATH_CAP] = {0}, fb[INST_PATH_CAP] = {0};
  if (!GetFullPathNameW(a, INST_PATH_CAP, fa, NULL)) lstrcpynW(fa, a, INST_PATH_CAP);
  if (!GetFullPathNameW(b, INST_PATH_CAP, fb, NULL)) lstrcpynW(fb, b, INST_PATH_CAP);
  trim_trailing_slash(fa);
  trim_trailing_slash(fb);
  return CompareStringOrdinal(fa, -1, fb, -1, TRUE) == CSTR_EQUAL;
}

static void parent_dir(const wchar_t *path, wchar_t *out, size_t cap) {
  lstrcpynW(out, path, (int)cap);
  wchar_t *s1 = wcsrchr(out, L'\\');
  wchar_t *s2 = wcsrchr(out, L'/');
  wchar_t *s = s1 && s2 ? (s1 > s2 ? s1 : s2) : (s1 ? s1 : s2);
  if (s) *s = 0;
  trim_trailing_slash(out);
}

static const wchar_t *base_name(const wchar_t *path) {
  const wchar_t *s1 = wcsrchr(path, L'\\');
  const wchar_t *s2 = wcsrchr(path, L'/');
  const wchar_t *s = s1 && s2 ? (s1 > s2 ? s1 : s2) : (s1 ? s1 : s2);
  return s ? s + 1 : path;
}

static int path_is_inside_dir(const wchar_t *file_path, const wchar_t *dir_path) {
  if (!file_path[0] || !dir_path[0]) return 0;
  wchar_t ff[INST_PATH_CAP] = {0}, fd[INST_PATH_CAP] = {0};
  if (!GetFullPathNameW(file_path, INST_PATH_CAP, ff, NULL)) return 0;
  if (!GetFullPathNameW(dir_path, INST_PATH_CAP, fd, NULL)) return 0;
  trim_trailing_slash(ff);
  trim_trailing_slash(fd);
  size_t dl = wcslen(fd);
  if (dl == 0 || wcslen(ff) <= dl) return 0;
  if (ff[dl] != L'\\' && ff[dl] != L'/') return 0;
  return CompareStringOrdinal(ff, (int)dl, fd, (int)dl, TRUE) == CSTR_EQUAL;
}

static int get_known_dir(REFKNOWNFOLDERID id, wchar_t *out, size_t cap) {
  out[0] = 0;
  PWSTR p = NULL;
  if (FAILED(SHGetKnownFolderPath(id, 0, NULL, &p)) || !p) return 0;
  lstrcpynW(out, p, (int)cap);
  CoTaskMemFree(p);
  trim_trailing_slash(out);
  return out[0] != 0;
}

static int get_install_dir(wchar_t *out, size_t cap) {
  wchar_t root[INST_PATH_CAP] = {0};
  if (inst_test_root(root, INST_PATH_CAP)) {
    _snwprintf(out, cap - 1, L"%ls\\Install", root);
    out[cap - 1] = 0;
    return 1;
  }
  wchar_t local[INST_PATH_CAP] = {0};
  if (!get_known_dir(&FOLDERID_LocalAppData, local, INST_PATH_CAP)) return 0;
  _snwprintf(out, cap - 1, L"%ls\\Programs\\PinShot", local);
  out[cap - 1] = 0;
  return 1;
}

static int get_start_menu_lnk(wchar_t *out, size_t cap) {
  wchar_t root[INST_PATH_CAP] = {0};
  if (inst_test_root(root, INST_PATH_CAP)) {
    _snwprintf(out, cap - 1, L"%ls\\StartMenu\\PinShot.lnk", root);
    out[cap - 1] = 0;
    return 1;
  }
  wchar_t progs[INST_PATH_CAP] = {0};
  if (!get_known_dir(&FOLDERID_Programs, progs, INST_PATH_CAP)) return 0;
  _snwprintf(out, cap - 1, L"%ls\\PinShot.lnk", progs);
  out[cap - 1] = 0;
  return 1;
}

static int get_desktop_lnk(wchar_t *out, size_t cap) {
  wchar_t root[INST_PATH_CAP] = {0};
  if (inst_test_root(root, INST_PATH_CAP)) {
    _snwprintf(out, cap - 1, L"%ls\\Desktop\\PinShot.lnk", root);
    out[cap - 1] = 0;
    return 1;
  }
  wchar_t desk[INST_PATH_CAP] = {0};
  if (!get_known_dir(&FOLDERID_Desktop, desk, INST_PATH_CAP)) return 0;
  _snwprintf(out, cap - 1, L"%ls\\PinShot.lnk", desk);
  out[cap - 1] = 0;
  return 1;
}

static void ensure_dir_for_file(const wchar_t *file_path) {
  wchar_t dir[INST_PATH_CAP] = {0};
  parent_dir(file_path, dir, INST_PATH_CAP);
  if (dir[0]) SHCreateDirectoryExW(NULL, dir, NULL);
}

static int create_shortcut(const wchar_t *lnk_path, const wchar_t *target_exe, const wchar_t *work_dir) {
  ensure_dir_for_file(lnk_path);
  HRESULT co = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
  int ok = 0;
  IShellLinkW *sl = NULL;
  if (SUCCEEDED(CoCreateInstance(&CLSID_ShellLink, NULL, CLSCTX_INPROC_SERVER, &IID_IShellLinkW, (void **)&sl)) && sl) {
    IShellLinkW_SetPath(sl, target_exe);
    IShellLinkW_SetWorkingDirectory(sl, work_dir);
    IShellLinkW_SetIconLocation(sl, target_exe, 0);
    IShellLinkW_SetDescription(sl, L"PinShot");
    IPersistFile *pf = NULL;
    if (SUCCEEDED(IShellLinkW_QueryInterface(sl, &IID_IPersistFile, (void **)&pf)) && pf) {
      if (SUCCEEDED(IPersistFile_Save(pf, lnk_path, TRUE))) ok = 1;
      IPersistFile_Release(pf);
    }
    IShellLinkW_Release(sl);
  }
  if (SUCCEEDED(co)) CoUninitialize();
  return ok;
}

static void reg_set_sz(HKEY k, const wchar_t *name, const wchar_t *val) {
  DWORD bytes = (DWORD)((wcslen(val) + 1) * sizeof(wchar_t));
  RegSetValueExW(k, name, 0, REG_SZ, (const BYTE *)val, bytes);
}

static void reg_set_dword(HKEY k, const wchar_t *name, DWORD val) {
  RegSetValueExW(k, name, 0, REG_DWORD, (const BYTE *)&val, sizeof(val));
}

static DWORD file_size_kb(const wchar_t *path) {
  WIN32_FILE_ATTRIBUTE_DATA d;
  if (!GetFileAttributesExW(path, GetFileExInfoStandard, &d)) return 0;
  uint64_t bytes = ((uint64_t)d.nFileSizeHigh << 32) | (uint64_t)d.nFileSizeLow;
  return (DWORD)((bytes + 1023ULL) / 1024ULL);
}

static void write_uninstall_entry(const wchar_t *install_dir, const wchar_t *target_exe, const wchar_t *version) {
  HKEY k = NULL;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, uninstall_subkey(), 0, NULL, 0, KEY_SET_VALUE, NULL, &k, NULL) != ERROR_SUCCESS)
    return;
  wchar_t icon[INST_PATH_CAP + 8], unins[INST_PATH_CAP + 32], quiet[INST_PATH_CAP + 48];
  _snwprintf(icon, INST_PATH_CAP + 7, L"%ls,0", target_exe);
  icon[INST_PATH_CAP + 7] = 0;
  _snwprintf(unins, INST_PATH_CAP + 31, L"\"%ls\" --uninstall", target_exe);
  unins[INST_PATH_CAP + 31] = 0;
  _snwprintf(quiet, INST_PATH_CAP + 47, L"\"%ls\" --uninstall --silent", target_exe);
  quiet[INST_PATH_CAP + 47] = 0;
  reg_set_sz(k, L"DisplayName", inst_is_test() ? L"PinShot (Test)" : L"PinShot");
  if (version && version[0]) reg_set_sz(k, L"DisplayVersion", version);
  reg_set_sz(k, L"Publisher", L"pengx17");
  reg_set_sz(k, L"InstallLocation", install_dir);
  reg_set_sz(k, L"DisplayIcon", icon);
  reg_set_sz(k, L"UninstallString", unins);
  reg_set_sz(k, L"QuietUninstallString", quiet);
  reg_set_dword(k, L"NoModify", 1);
  reg_set_dword(k, L"NoRepair", 1);
  DWORD kb = file_size_kb(target_exe);
  if (kb > 0) reg_set_dword(k, L"EstimatedSize", kb);
  RegCloseKey(k);
}

static void remove_legacy_inno(const wchar_t *install_dir) {
  RegDeleteTreeW(HKEY_CURRENT_USER, legacy_inno_subkey());
  wchar_t p[INST_PATH_CAP + 32];
  _snwprintf(p, INST_PATH_CAP + 31, L"%ls\\unins000.exe", install_dir);
  p[INST_PATH_CAP + 31] = 0;
  DeleteFileW(p);
  _snwprintf(p, INST_PATH_CAP + 31, L"%ls\\unins000.dat", install_dir);
  p[INST_PATH_CAP + 31] = 0;
  DeleteFileW(p);
}

static void set_run_autostart(const wchar_t *target_exe, int on) {
  HKEY k = NULL;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, RUN_SUBKEY, 0, NULL, 0, KEY_SET_VALUE, NULL, &k, NULL) != ERROR_SUCCESS) return;
  if (on) {
    wchar_t v[INST_PATH_CAP + 8];
    _snwprintf(v, INST_PATH_CAP + 7, L"\"%ls\"", target_exe);
    v[INST_PATH_CAP + 7] = 0;
    reg_set_sz(k, run_value_name(), v);
  } else {
    RegDeleteValueW(k, run_value_name());
  }
  RegCloseKey(k);
}

static int exe_unlocked(const wchar_t *exe) {
  if (GetFileAttributesW(exe) == INVALID_FILE_ATTRIBUTES) return 1;
  HANDLE h = CreateFileW(exe, DELETE | GENERIC_WRITE, 0, NULL, OPEN_EXISTING, 0, NULL);
  if (h != INVALID_HANDLE_VALUE) {
    CloseHandle(h);
    return 1;
  }
  return 0;
}

static int quit_running_exe(const wchar_t *target_exe) {
  if (GetFileAttributesW(target_exe) == INVALID_FILE_ATTRIBUTES) return 1;
  if (exe_unlocked(target_exe)) return 1;
  wchar_t cmd[INST_PATH_CAP + 24], dir[INST_PATH_CAP];
  _snwprintf(cmd, INST_PATH_CAP + 23, L"\"%ls\" --quit", target_exe);
  cmd[INST_PATH_CAP + 23] = 0;
  parent_dir(target_exe, dir, INST_PATH_CAP);
  STARTUPINFOW si;
  PROCESS_INFORMATION pi;
  memset(&si, 0, sizeof si);
  si.cb = sizeof si;
  if (CreateProcessW(target_exe, cmd, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, dir[0] ? dir : NULL, &si, &pi)) {
    WaitForSingleObject(pi.hProcess, 3000);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
  }
  for (int i = 0; i < 25; i++) {
    if (exe_unlocked(target_exe)) return 1;
    Sleep(200);
  }
  return exe_unlocked(target_exe);
}

static int launch_exe(const wchar_t *target_exe, const wchar_t *arg) {
  wchar_t cmd[INST_PATH_CAP + 32], dir[INST_PATH_CAP];
  if (arg && arg[0]) _snwprintf(cmd, INST_PATH_CAP + 31, L"\"%ls\" %ls", target_exe, arg);
  else _snwprintf(cmd, INST_PATH_CAP + 31, L"\"%ls\"", target_exe);
  cmd[INST_PATH_CAP + 31] = 0;
  parent_dir(target_exe, dir, INST_PATH_CAP);
  STARTUPINFOW si;
  PROCESS_INFORMATION pi;
  memset(&si, 0, sizeof si);
  si.cb = sizeof si;
  if (!CreateProcessW(target_exe, cmd, NULL, NULL, FALSE, 0, NULL, dir[0] ? dir : NULL, &si, &pi)) return 0;
  CloseHandle(pi.hThread);
  CloseHandle(pi.hProcess);
  return 1;
}

static int starts_with_ci(const wchar_t *s, const wchar_t *prefix) {
  size_t n = wcslen(prefix);
  if (wcslen(s) < n) return 0;
  return CompareStringOrdinal(s, (int)n, prefix, (int)n, TRUE) == CSTR_EQUAL;
}

static int eq_ci(const wchar_t *a, const wchar_t *b) {
  return CompareStringOrdinal(a, -1, b, -1, TRUE) == CSTR_EQUAL;
}

static int should_auto_install(const wchar_t *self_exe, const wchar_t *target_exe) {
  if (same_path(self_exe, target_exe)) return 0;
  if (inst_is_test()) {
    const char *a = getenv("PINSHOT_TEST_AUTOINSTALL");
    if (!a || !a[0]) return 0;
  }
  const wchar_t *name = base_name(self_exe);
  if (starts_with_ci(name, L"PinShot-Setup")) return 1;
  wchar_t dl[INST_PATH_CAP] = {0};
  if (get_known_dir(&FOLDERID_Downloads, dl, INST_PATH_CAP) && path_is_inside_dir(self_exe, dl)) return 1;
  wchar_t tmp[INST_PATH_CAP] = {0};
  DWORD tn = GetTempPathW(INST_PATH_CAP, tmp);
  if (tn > 0 && tn < INST_PATH_CAP && path_is_inside_dir(self_exe, tmp)) return 1;
  return 0;
}

static int do_install(
    const wchar_t *self_exe,
    const wchar_t *version,
    int is_update,
    int silent,
    int want_autostart,
    int want_desktop,
    int no_launch) {
  wchar_t dir[INST_PATH_CAP] = {0}, target[INST_PATH_CAP + 32] = {0};
  if (!get_install_dir(dir, INST_PATH_CAP)) return 0;
  SHCreateDirectoryExW(NULL, dir, NULL);
  _snwprintf(target, INST_PATH_CAP + 31, L"%ls\\pinshot.exe", dir);
  target[INST_PATH_CAP + 31] = 0;

  if (!same_path(self_exe, target)) {
    if (!quit_running_exe(target)) {
      if (is_update) {
        if (GetFileAttributesW(target) != INVALID_FILE_ATTRIBUTES) launch_exe(target, L"--start");
        ExitProcess(7);
      }
      if (!silent) {
        const wchar_t *msg = ps_ui_chinese()
                                 ? L"PinShot 正在运行，请先从托盘图标退出后再重新运行安装。"
                                 : L"PinShot is still running. Quit it from the tray icon and try again.";
        MessageBoxW(NULL, msg, L"PinShot", MB_OK | MB_ICONWARNING);
      }
      ExitProcess(1);
    }
    wchar_t staging[INST_PATH_CAP + 48];
    _snwprintf(staging, INST_PATH_CAP + 47, L"%ls.staging", target);
    staging[INST_PATH_CAP + 47] = 0;
    if (!CopyFileW(self_exe, staging, FALSE) || !MoveFileExW(staging, target, MOVEFILE_REPLACE_EXISTING)) {
      DeleteFileW(staging);
      if (is_update) {
        if (GetFileAttributesW(target) != INVALID_FILE_ATTRIBUTES) launch_exe(target, L"--start");
        ExitProcess(7);
      }
      if (!silent) {
        const wchar_t *msg = ps_ui_chinese()
                                 ? L"无法写入安装目录，请检查磁盘空间或权限后重试。"
                                 : L"Could not write to the installation folder.";
        MessageBoxW(NULL, msg, L"PinShot", MB_OK | MB_ICONERROR);
      }
      ExitProcess(1);
    }
  }

  remove_legacy_inno(dir);
  write_uninstall_entry(dir, target, version);

  wchar_t lnk[INST_PATH_CAP] = {0};
  if (get_start_menu_lnk(lnk, INST_PATH_CAP)) create_shortcut(lnk, target, dir);
  if (want_desktop && !is_update && get_desktop_lnk(lnk, INST_PATH_CAP)) create_shortcut(lnk, target, dir);
  if (want_autostart && !is_update) set_run_autostart(target, 1);

  if (!no_launch) {
    const wchar_t *arg = is_update ? L"--updated" : (silent ? L"--start" : L"--installed");
    launch_exe(target, arg);
  }
  return 1;
}

static void schedule_self_delete(const wchar_t *target_exe, const wchar_t *install_dir) {
  wchar_t tmp[INST_PATH_CAP] = {0};
  if (GetTempPathW(INST_PATH_CAP, tmp) > 0) SetCurrentDirectoryW(tmp);
  wchar_t cmd[INST_PATH_CAP * 3 + 128];
  _snwprintf(
      cmd,
      INST_PATH_CAP * 3 + 127,
      L"cmd.exe /d /c \"for /L %%i in (1,1,15) do (if exist \"%ls\" (del /f /q \"%ls\" >nul 2>&1 & ping -n 1 -w 200 127.0.0.1 >nul)) & rd \"%ls\" >nul 2>&1\"",
      target_exe,
      target_exe,
      install_dir);
  cmd[INST_PATH_CAP * 3 + 127] = 0;
  STARTUPINFOW si;
  PROCESS_INFORMATION pi;
  memset(&si, 0, sizeof si);
  si.cb = sizeof si;
  if (CreateProcessW(NULL, cmd, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, tmp[0] ? tmp : NULL, &si, &pi)) {
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
  }
}

static int do_uninstall(const wchar_t *self_exe, int silent) {
  if (!silent) {
    const wchar_t *msg = ps_ui_chinese()
                             ? L"确定要卸载 PinShot 吗？\n\n卸载不会删除你的截图文件和个人配置。"
                             : L"Uninstall PinShot?\n\nYour screenshots and settings will be kept.";
    if (MessageBoxW(NULL, msg, L"PinShot", MB_YESNO | MB_ICONQUESTION) != IDYES) return 1;
  }

  wchar_t dir[INST_PATH_CAP] = {0}, target[INST_PATH_CAP + 32] = {0};
  if (!get_install_dir(dir, INST_PATH_CAP)) return 1;
  _snwprintf(target, INST_PATH_CAP + 31, L"%ls\\pinshot.exe", dir);
  target[INST_PATH_CAP + 31] = 0;

  if (!same_path(self_exe, target)) {
    quit_running_exe(target);
  } else {
    wchar_t cmd[INST_PATH_CAP + 24];
    _snwprintf(cmd, INST_PATH_CAP + 23, L"\"%ls\" --quit", target);
    cmd[INST_PATH_CAP + 23] = 0;
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    memset(&si, 0, sizeof si);
    si.cb = sizeof si;
    if (CreateProcessW(target, cmd, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, dir, &si, &pi)) {
      WaitForSingleObject(pi.hProcess, 3000);
      CloseHandle(pi.hThread);
      CloseHandle(pi.hProcess);
    }
    Sleep(300);
  }

  wchar_t lnk[INST_PATH_CAP] = {0};
  if (get_start_menu_lnk(lnk, INST_PATH_CAP)) DeleteFileW(lnk);
  if (get_desktop_lnk(lnk, INST_PATH_CAP)) DeleteFileW(lnk);
  set_run_autostart(target, 0);
  RegDeleteTreeW(HKEY_CURRENT_USER, uninstall_subkey());
  remove_legacy_inno(dir);

  static const wchar_t *extras[] = {L".old", L".download", L".download.part", L".staging", L".probe"};
  for (size_t i = 0; i < sizeof(extras) / sizeof(extras[0]); i++) {
    wchar_t p[INST_PATH_CAP + 48];
    _snwprintf(p, INST_PATH_CAP + 47, L"%ls%ls", target, extras[i]);
    p[INST_PATH_CAP + 47] = 0;
    DeleteFileW(p);
  }

  if (same_path(self_exe, target)) {
    schedule_self_delete(target, dir);
    ExitProcess(0);
  } else {
    DeleteFileW(target);
    RemoveDirectoryW(dir);
  }
  return 1;
}

int ps_wgc_shot_cli(void);

int32_t ps_install_cli(moonbit_bytes_t version_bytes) {
  if (ps_wgc_shot_cli()) return 1;
  if (ps_packaged()) return 0;

  wchar_t version[64] = {0};
  inst_wide((const char *)version_bytes, version, 64);

  wchar_t self_exe[INST_PATH_CAP] = {0};
  if (GetModuleFileNameW(NULL, self_exe, INST_PATH_CAP) == 0) return 0;

  int argc = 0;
  LPWSTR *argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  if (!argv) return 0;

  enum { MODE_NONE = 0, MODE_INSTALL = 1, MODE_UPDATE = 2, MODE_UNINSTALL = 3 };
  int mode = MODE_NONE;
  int silent = 0, want_autostart = 0, want_desktop = 0, portable = 0, no_launch = 0, normal_flag = 0;

  for (int i = 1; i < argc; i++) {
    const wchar_t *a = argv[i];
    if (eq_ci(a, L"--install") || eq_ci(a, L"/INSTALL")) mode = MODE_INSTALL;
    else if (eq_ci(a, L"--uninstall") || eq_ci(a, L"/UNINSTALL")) mode = MODE_UNINSTALL;
    else if (eq_ci(a, L"/UPDATE") || eq_ci(a, L"--update-install")) {
      mode = MODE_UPDATE;
      silent = 1;
    } else if (eq_ci(a, L"--silent") || eq_ci(a, L"/VERYSILENT") || eq_ci(a, L"/SILENT")) silent = 1;
    else if (eq_ci(a, L"--autostart")) want_autostart = 1;
    else if (eq_ci(a, L"--desktop")) want_desktop = 1;
    else if (eq_ci(a, L"--portable")) portable = 1;
    else if (eq_ci(a, L"--no-launch")) no_launch = 1;
    else if (eq_ci(a, L"--quit") || eq_ci(a, L"--settings") || eq_ci(a, L"--bench") || eq_ci(a, L"--ocr") ||
             eq_ci(a, L"--updated") || eq_ci(a, L"--installed") || eq_ci(a, L"--start"))
      normal_flag = 1;
  }
  LocalFree(argv);

  if (mode == MODE_UNINSTALL) return do_uninstall(self_exe, silent);
  if (mode == MODE_INSTALL || mode == MODE_UPDATE) {
    return do_install(self_exe, version, mode == MODE_UPDATE, silent, want_autostart, want_desktop, no_launch);
  }
  if (portable || normal_flag) return 0;

  wchar_t dir[INST_PATH_CAP] = {0}, target[INST_PATH_CAP + 32] = {0};
  if (get_install_dir(dir, INST_PATH_CAP)) {
    _snwprintf(target, INST_PATH_CAP + 31, L"%ls\\pinshot.exe", dir);
    target[INST_PATH_CAP + 31] = 0;
    if (should_auto_install(self_exe, target)) {
      return do_install(self_exe, version, 0, 0, 0, 0, no_launch);
    }
  }
  return 0;
}

void ps_install_sync_meta(moonbit_bytes_t version_bytes) {
  if (ps_packaged()) return;
  wchar_t self_exe[INST_PATH_CAP] = {0}, dir[INST_PATH_CAP] = {0}, target[INST_PATH_CAP + 32] = {0};
  if (GetModuleFileNameW(NULL, self_exe, INST_PATH_CAP) == 0) return;
  if (!get_install_dir(dir, INST_PATH_CAP)) return;
  _snwprintf(target, INST_PATH_CAP + 31, L"%ls\\pinshot.exe", dir);
  target[INST_PATH_CAP + 31] = 0;
  if (!same_path(self_exe, target)) return;

  HKEY k = NULL;
  int has_new = RegOpenKeyExW(HKEY_CURRENT_USER, uninstall_subkey(), 0, KEY_READ, &k) == ERROR_SUCCESS;
  if (k) RegCloseKey(k);
  k = NULL;
  int has_old = RegOpenKeyExW(HKEY_CURRENT_USER, legacy_inno_subkey(), 0, KEY_READ, &k) == ERROR_SUCCESS;
  if (k) RegCloseKey(k);
  if (!has_new && !has_old) return;

  wchar_t version[64] = {0};
  inst_wide((const char *)version_bytes, version, 64);
  if (has_old) remove_legacy_inno(dir);
  write_uninstall_entry(dir, target, version);
  wchar_t lnk[INST_PATH_CAP] = {0};
  if (get_start_menu_lnk(lnk, INST_PATH_CAP) && GetFileAttributesW(lnk) == INVALID_FILE_ATTRIBUTES) {
    create_shortcut(lnk, target, dir);
  }
}
