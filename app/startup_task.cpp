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

// `op` waited for (it ends on the system's threads: an agile handler sets an event).
template <typename T, typename R>
static HRESULT wait_for(WF::IAsyncOperation<T> *op, R *out) {
  HANDLE done = CreateEventW(NULL, TRUE, FALSE, NULL);
  if (!done) return E_FAIL;
  auto h = Callback<Microsoft::WRL::Implements<Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::ClassicCom>,
                                              WF::IAsyncOperationCompletedHandler<T>, Microsoft::WRL::FtmBase>>(
      [done](WF::IAsyncOperation<T> *, WF::AsyncStatus) -> HRESULT {
        SetEvent(done);
        return S_OK;
      });
  HRESULT hr = op->put_Completed(h.Get());
  if (SUCCEEDED(hr)) {
    // (a few ms; never long: 5 s at most)
    if (WaitForSingleObject(done, 5000) != WAIT_OBJECT_0) hr = E_FAIL;
    else hr = op->GetResults(out);
  }
  CloseHandle(done);
  return hr;
}

static HRESULT startup_task(ComPtr<AM::IStartupTask> &task) {
  RoInitialize(RO_INIT_SINGLETHREADED);
  ComPtr<AM::IStartupTaskStatics> statics;
  HRESULT hr = RoGetActivationFactory(HStringReference(RuntimeClass_Windows_ApplicationModel_StartupTask).Get(),
                                      IID_PPV_ARGS(&statics));
  if (FAILED(hr)) return hr;
  ComPtr<WF::IAsyncOperation<AM::StartupTask *>> op;
  hr = statics->GetAsync(HStringReference(L"PinShotAtSignIn").Get(), &op);
  if (FAILED(hr)) return hr;
  return wait_for(op.Get(), task.GetAddressOf());
}

// The package's startup task: 1 on, 0 off (or not to be had).
extern "C" int ps_startup_on(void) {
  ComPtr<AM::IStartupTask> task;
  if (FAILED(startup_task(task)) || !task) return 0;
  AM::StartupTaskState s;
  if (FAILED(task->get_State(&s))) return 0;
  return s == AM::StartupTaskState_Enabled || s == AM::StartupTaskState_EnabledByPolicy;
}

// The package's startup task turned on or off: 1 it is as asked (turned off in Windows' settings by the person, it
// stays off: Windows asks them there).
extern "C" int ps_startup_set(int on) {
  ComPtr<AM::IStartupTask> task;
  if (FAILED(startup_task(task)) || !task) return 0;
  if (!on) return SUCCEEDED(task->Disable());
  ComPtr<WF::IAsyncOperation<AM::StartupTaskState>> op;
  if (FAILED(task->RequestEnableAsync(&op))) return 0;
  AM::StartupTaskState s;
  if (FAILED(wait_for(op.Get(), &s))) return 0;
  return s == AM::StartupTaskState_Enabled || s == AM::StartupTaskState_EnabledByPolicy;
}
