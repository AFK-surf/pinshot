// Starting with Windows as the Store's package does it: a package's program is not started by HKCU's Run key, its
// manifest's startup task is (packaging/AppxManifest.xml: TaskId PinShotAtSignIn, off as installed), turned on or off
// by Windows.ApplicationModel.StartupTask. platform_win.c asks here where the run is a package's, else keeps the Run key.
#include <windows.h>
#include <appmodel.h>
#include <roapi.h>
#include <wrl.h>
#include <wrl/wrappers/corewrappers.h>
#include <windows.foundation.h>
#include <windows.applicationmodel.h>
#include <memory>
#include <objbase.h>

#pragma comment(lib, "runtimeobject.lib")

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;
using Microsoft::WRL::Wrappers::HStringReference;
namespace AM = ABI::Windows::ApplicationModel;
namespace WF = ABI::Windows::Foundation;

// Whether this run is a package's (installed from the Store or an MSIX).
extern "C" int ps_packaged(void) {
  UINT32 n = 0;
  return GetCurrentPackageFullName(&n, NULL) == ERROR_INSUFFICIENT_BUFFER;
}

// `op` waited for (it ends on the system's threads: an agile handler sets an event). The caller is the UI thread, an
// STA: the wait goes on dispatching its window messages and COM calls (CoWaitForMultipleHandles), as a modal dialog's
// does, so what the operation needs of this thread (RequestEnableAsync's consent dialog) is never deadlocked on it.
// The event is shared with the handler: a handler run after a wait that gave up sets an event still there.
template <typename T, typename R>
static HRESULT wait_for(WF::IAsyncOperation<T> *op, R *out, DWORD most_ms) {
  HANDLE ev = CreateEventW(NULL, TRUE, FALSE, NULL);
  if (!ev) return E_FAIL;
  std::shared_ptr<void> done(ev, CloseHandle);
  auto h = Callback<Microsoft::WRL::Implements<Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::ClassicCom>,
                                              WF::IAsyncOperationCompletedHandler<T>, Microsoft::WRL::FtmBase>>(
      [done](WF::IAsyncOperation<T> *, WF::AsyncStatus) -> HRESULT {
        SetEvent(done.get());
        return S_OK;
      });
  if (!h) return E_OUTOFMEMORY;
  HRESULT hr = op->put_Completed(h.Get());
  if (SUCCEEDED(hr)) {
    DWORD which = 0;
    HANDLE hs[1] = {ev};
    HRESULT w = CoWaitForMultipleHandles(COWAIT_DISPATCH_CALLS | COWAIT_DISPATCH_WINDOW_MESSAGES, most_ms, 1, hs, &which);
    hr = (w == S_OK && which == 0) ? op->GetResults(out) : E_FAIL;
  }
  return hr;
}

// WinRT on this thread for as long as it is asked here (paired: a thread whose COM is another mode already, the UI
// thread's STA as OLE set it, is used as it is).
struct RoScope {
  HRESULT hr;
  RoScope() : hr(RoInitialize(RO_INIT_SINGLETHREADED)) {}
  ~RoScope() {
    if (SUCCEEDED(hr)) RoUninitialize();
  }
  bool usable() const { return SUCCEEDED(hr) || hr == RPC_E_CHANGED_MODE; }
};

static HRESULT startup_task(ComPtr<AM::IStartupTask> &task) {
  ComPtr<AM::IStartupTaskStatics> statics;
  HRESULT hr = RoGetActivationFactory(HStringReference(RuntimeClass_Windows_ApplicationModel_StartupTask).Get(),
                                      IID_PPV_ARGS(&statics));
  if (FAILED(hr)) return hr;
  ComPtr<WF::IAsyncOperation<AM::StartupTask *>> op;
  hr = statics->GetAsync(HStringReference(L"PinShotAtSignIn").Get(), &op);
  if (FAILED(hr)) return hr;
  return wait_for(op.Get(), task.GetAddressOf(), 5000);
}

// The package's startup task: 1 on, 0 off (or not to be had).
extern "C" int ps_startup_on(void) {
  RoScope ro;
  if (!ro.usable()) return 0;
  ComPtr<AM::IStartupTask> task;
  if (FAILED(startup_task(task)) || !task) return 0;
  AM::StartupTaskState s;
  if (FAILED(task->get_State(&s))) return 0;
  return s == AM::StartupTaskState_Enabled || s == AM::StartupTaskState_EnabledByPolicy;
}

// The package's startup task turned on or off: 1 it is as asked (turned off in Windows' settings by the person, it
// stays off: Windows asks them there).
extern "C" int ps_startup_set(int on) {
  RoScope ro;
  if (!ro.usable()) return 0;
  ComPtr<AM::IStartupTask> task;
  if (FAILED(startup_task(task)) || !task) return 0;
  if (!on) return SUCCEEDED(task->Disable());
  ComPtr<WF::IAsyncOperation<AM::StartupTaskState>> op;
  if (FAILED(task->RequestEnableAsync(&op))) return 0;
  AM::StartupTaskState s;
  // (Windows may ask the person first: a minute for them to answer)
  if (FAILED(wait_for(op.Get(), &s, 60000))) return 0;
  return s == AM::StartupTaskState_Enabled || s == AM::StartupTaskState_EnabledByPolicy;
}
