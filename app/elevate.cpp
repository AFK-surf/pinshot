// Over every window, Task Manager's too (the settings' 盖过任务管理器等置顶窗口; the user, 2026-11-18: 「pinshot的层级不够
//高」, Task Manager set always on top stood over the capture). A window made topmost is over the other topmost ones of
// its band only; Task Manager's is a band above (ZBID_SYSTEM_TOOLS), and a program's windows go as high only where its
// token has UIAccess. Windows gives that to a signed program in Program Files that asks in its manifest; PinShot is
// neither, so, run as administrator, it gives its token UIAccess itself, as killtimer0/uiaccess does: winlogon's token
// (the session's, which holds SeTcbPrivilege) impersonated, its own token duplicated with TokenUIAccess set, and itself
// started again with that token. Started with Windows, a task of the Task Scheduler run with the highest privileges
// starts it (no UAC asked at each sign-in) in place of HKCU's Run key.
//
// Wanted or not is kept in HKCU\Software\PinShot (AboveAll), read as the run starts, before its settings are.
#include <windows.h>
#include <tlhelp32.h>
#include <sddl.h>
#include <shellapi.h>
#include <taskschd.h>
#include <comdef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string>

#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "taskschd.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "oleaut32.lib")
#pragma comment(lib, "shell32.lib")

extern "C" void ps_log_w(const wchar_t *line);

static bool test_run() { return getenv("PINSHOT_TEST") != NULL; }
static const wchar_t *reg_key() { return test_run() ? L"Software\\PinShot-test" : L"Software\\PinShot"; }

// Whether the person wants PinShot over every window.
extern "C" int ps_above_wanted(void) {
  DWORD v = 0, size = sizeof v;
  if (RegGetValueW(HKEY_CURRENT_USER, reg_key(), L"AboveAll", RRF_RT_REG_DWORD, NULL, &v, &size) != ERROR_SUCCESS) return 0;
  return v != 0;
}

static bool above_keep(bool on) {
  HKEY k;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, reg_key(), 0, NULL, 0, KEY_SET_VALUE, NULL, &k, NULL) != ERROR_SUCCESS) return false;
  DWORD v = on ? 1 : 0;
  LONG r = RegSetValueExW(k, L"AboveAll", 0, REG_DWORD, (const BYTE *)&v, sizeof v);
  RegCloseKey(k);
  return r == ERROR_SUCCESS;
}

static DWORD token_dword(TOKEN_INFORMATION_CLASS what) {
  HANDLE t;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &t)) return 0;
  DWORD v = 0, len = 0;
  if (!GetTokenInformation(t, what, &v, sizeof v, &len)) v = 0;
  CloseHandle(t);
  return v;
}

// Whether this run's windows go over every window (its token has UIAccess).
extern "C" int ps_above_on(void) { return token_dword(TokenUIAccess) != 0; }

// Whether this run is an administrator's, elevated.
static bool elevated() { return token_dword(TokenElevation) != 0; }

static void log_err(const wchar_t *what);

// This run's own privilege `name` turned on (an elevated administrator's run holds SeDebugPrivilege, off).
static void privilege_on(const wchar_t *name) {
  HANDLE t;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, &t)) return;
  TOKEN_PRIVILEGES tp = {1};
  if (LookupPrivilegeValueW(NULL, name, &tp.Privileges[0].Luid)) {
    tp.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;
    AdjustTokenPrivileges(t, FALSE, &tp, sizeof tp, NULL, NULL);
  }
  CloseHandle(t);
}

// winlogon's token of session `session` (it holds SeTcbPrivilege), to impersonate.
static HANDLE winlogon_token(DWORD session) {
  LUID tcb;
  if (!LookupPrivilegeValueW(NULL, L"SeTcbPrivilege", &tcb)) return NULL;
  // (winlogon's process and token opened by an administrator with SeDebugPrivilege on)
  privilege_on(L"SeDebugPrivilege");
  HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snap == INVALID_HANDLE_VALUE) return NULL;
  HANDLE out = NULL;
  PROCESSENTRY32W pe = {sizeof pe};
  for (BOOL more = Process32FirstW(snap, &pe); more && !out; more = Process32NextW(snap, &pe)) {
    if (_wcsicmp(pe.szExeFile, L"winlogon.exe")) continue;
    HANDLE p = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pe.th32ProcessID);
    if (!p) {
      log_err(L"opening winlogon");
      continue;
    }
    HANDLE t;
    if (!OpenProcessToken(p, TOKEN_QUERY | TOKEN_DUPLICATE, &t)) log_err(L"opening winlogon's token");
    else {
      PRIVILEGE_SET ps = {1, PRIVILEGE_SET_ALL_NECESSARY};
      ps.Privilege[0].Luid = tcb;
      BOOL has = FALSE;
      DWORD sid = 0, len = 0;
      if (PrivilegeCheck(t, &ps, &has) && has && GetTokenInformation(t, TokenSessionId, &sid, sizeof sid, &len) &&
          sid == session)
        if (!DuplicateTokenEx(t, TOKEN_IMPERSONATE, NULL, SecurityImpersonation, TokenImpersonation, &out))
          log_err(L"duplicating winlogon's token");
      CloseHandle(t);
    }
    CloseHandle(p);
  }
  CloseHandle(snap);
  return out;
}

// This run's token with UIAccess, to start a run with (NULL: not to be had; an administrator's elevated run only).
static HANDLE uiaccess_token(void) {
  HANDLE self;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY | TOKEN_DUPLICATE, &self)) return NULL;
  DWORD session = 0, len = 0;
  HANDLE out = NULL;
  if (GetTokenInformation(self, TokenSessionId, &session, sizeof session, &len)) {
    HANDLE sys = winlogon_token(session);
    if (sys) {
      if (!SetThreadToken(NULL, sys)) log_err(L"impersonating winlogon");
      else {
        if (!DuplicateTokenEx(self, TOKEN_QUERY | TOKEN_DUPLICATE | TOKEN_ASSIGN_PRIMARY | TOKEN_ADJUST_DEFAULT, NULL,
                              SecurityAnonymous, TokenPrimary, &out))
          log_err(L"duplicating the token");
        else {
          DWORD on = 1;
          if (!SetTokenInformation(out, TokenUIAccess, &on, sizeof on)) {
            log_err(L"setting UIAccess");
            CloseHandle(out);
            out = NULL;
          }
        }
        RevertToSelf();
      }
      CloseHandle(sys);
    }
  }
  CloseHandle(self);
  return out;
}

static std::wstring exe_path() {
  wchar_t exe[MAX_PATH * 2];
  DWORD n = GetModuleFileNameW(NULL, exe, MAX_PATH * 2);
  return std::wstring(exe, n);
}

static void log_err(const wchar_t *what) {
  DWORD e = GetLastError();
  wchar_t line[160];
  _snwprintf_s(line, _TRUNCATE, L"above all: %ls failed (%lu)", what, e);
  ps_log_w(line);
}

// PinShot started again with UIAccess (`args`: what the new run is told, after --restart): 1 it was (this run ends,
// the new one waits for it to). Elevated, it starts with a token of its own made so; not, as an administrator (UAC
// asks; refused, 0).
extern "C" int ps_above_restart(const wchar_t *args) {
  std::wstring exe = exe_path();
  std::wstring params = std::wstring(L"--restart ") + args;
  if (elevated()) {
    HANDLE t = uiaccess_token();
    if (!t) {
      log_err(L"the token");
      return 0;
    }
    std::wstring line = L"\"" + exe + L"\" " + params;
    STARTUPINFOW si = {sizeof si};
    PROCESS_INFORMATION pi = {};
    BOOL ok = CreateProcessAsUserW(t, NULL, &line[0], NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi);
    if (!ok) log_err(L"starting");
    CloseHandle(t);
    if (!ok) return 0;
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return 1;
  }
  SHELLEXECUTEINFOW ei = {sizeof ei};
  ei.fMask = SEE_MASK_NOASYNC | SEE_MASK_FLAG_NO_UI;
  ei.lpVerb = L"runas";
  ei.lpFile = exe.c_str();
  ei.lpParameters = params.c_str();
  ei.nShow = SW_SHOWNORMAL;
  if (!ShellExecuteExW(&ei)) {
    log_err(L"asking for administrator");
    return 0;
  }
  return 1;
}

// ---- started with Windows: the Task Scheduler's task ----

// The task's name: one a person (tasks are the machine's, not a person's).
static std::wstring task_name() {
  wchar_t user[256] = L"";
  DWORD n = 256;
  GetUserNameW(user, &n);
  return std::wstring(test_run() ? L"PinShot-test " : L"PinShot ") + user;
}

static std::wstring user_sid() {
  std::wstring s;
  HANDLE t;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &t)) return s;
  BYTE buf[256];
  DWORD len = 0;
  if (GetTokenInformation(t, TokenUser, buf, sizeof buf, &len)) {
    wchar_t *str = NULL;
    if (ConvertSidToStringSidW(((TOKEN_USER *)buf)->User.Sid, &str)) {
      s = str;
      LocalFree(str);
    }
  }
  CloseHandle(t);
  return s;
}

static ITaskFolder *task_root(void) {
  HRESULT hr = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
  (void)hr;
  ITaskService *svc = NULL;
  if (FAILED(CoCreateInstance(CLSID_TaskScheduler, NULL, CLSCTX_INPROC_SERVER, IID_ITaskService, (void **)&svc)))
    return NULL;
  ITaskFolder *root = NULL;
  if (SUCCEEDED(svc->Connect(_variant_t(), _variant_t(), _variant_t(), _variant_t())))
    svc->GetFolder(_bstr_t(L"\\"), &root);
  svc->Release();
  return root;
}

// Whether the task is there (it may be seen though not read: an elevated run made it).
extern "C" int ps_task_on(void) {
  ITaskFolder *root = task_root();
  if (!root) return 0;
  IRegisteredTask *t = NULL;
  HRESULT hr = root->GetTask(_bstr_t(task_name().c_str()), &t);
  if (t) t->Release();
  root->Release();
  return SUCCEEDED(hr) || hr == E_ACCESSDENIED;
}

static std::wstring xml_escaped(const std::wstring &s) {
  std::wstring o;
  for (wchar_t c : s) {
    if (c == L'&') o += L"&amp;";
    else if (c == L'<') o += L"&lt;";
    else if (c == L'>') o += L"&gt;";
    else if (c == L'"') o += L"&quot;";
    else o += c;
  }
  return o;
}

// The task made (PinShot started as the person signs in, with the highest privileges: an elevated run, so no UAC; on
// battery too, never stopped) or taken away: 1 it is as asked. Made only by an elevated run.
extern "C" int ps_task_set(int on) {
  ITaskFolder *root = task_root();
  if (!root) return 0;
  HRESULT hr;
  if (!on) {
    hr = root->DeleteTask(_bstr_t(task_name().c_str()), 0);
    root->Release();
    return SUCCEEDED(hr) || hr == HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND);
  }
  std::wstring sid = user_sid();
  std::wstring xml =
      L"<?xml version=\"1.0\" encoding=\"UTF-16\"?>"
      L"<Task version=\"1.2\" xmlns=\"http://schemas.microsoft.com/windows/2004/02/mit/task\">"
      L"<RegistrationInfo><Description>PinShot, started as you sign in (over every window: run as administrator)."
      L"</Description></RegistrationInfo>"
      L"<Triggers><LogonTrigger><Enabled>true</Enabled><UserId>" + sid + L"</UserId></LogonTrigger></Triggers>"
      L"<Principals><Principal id=\"Author\"><UserId>" + sid + L"</UserId><LogonType>InteractiveToken</LogonType>"
      L"<RunLevel>HighestAvailable</RunLevel></Principal></Principals>"
      L"<Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>"
      L"<DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>"
      L"<AllowHardTerminate>true</AllowHardTerminate><StartWhenAvailable>false</StartWhenAvailable>"
      L"<IdleSettings><StopOnIdleEnd>false</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings>"
      L"<AllowStartOnDemand>true</AllowStartOnDemand><Enabled>true</Enabled><Hidden>false</Hidden>"
      L"<ExecutionTimeLimit>PT0S</ExecutionTimeLimit><Priority>7</Priority></Settings>"
      L"<Actions Context=\"Author\"><Exec><Command>" + xml_escaped(exe_path()) + L"</Command></Exec></Actions>"
      L"</Task>";
  IRegisteredTask *t = NULL;
  hr = root->RegisterTask(_bstr_t(task_name().c_str()), _bstr_t(xml.c_str()), TASK_CREATE_OR_UPDATE, _variant_t(),
                          _variant_t(), TASK_LOGON_INTERACTIVE_TOKEN, _variant_t(L""), &t);
  if (t) t->Release();
  root->Release();
  if (FAILED(hr)) {
    wchar_t line[120];
    _snwprintf_s(line, _TRUNCATE, L"above all: the sign-in task not made (0x%08lx)", (unsigned long)hr);
    ps_log_w(line);
  }
  return SUCCEEDED(hr);
}

// Wanted or not kept: 1 kept (and in force as the run starts next), 0 not.
extern "C" int ps_above_keep(int on) { return above_keep(on != 0); }
