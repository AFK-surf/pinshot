#include <windows.h>
#include <shellapi.h>
#include <d3d11.h>
#include <dxgi1_5.h>
#include <roapi.h>
#include <wrl.h>
#include <wrl/wrappers/corewrappers.h>
#include <windows.foundation.h>
#include <windows.graphics.capture.h>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.h>
#include <windows.graphics.directx.direct3d11.interop.h>
#include <stdint.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <windows.security.authorization.appcapabilityaccess.h>

#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "runtimeobject.lib")

// Precompiled cs_5_0 bytecode for to_srgb (compiled with fxc /T cs_5_0 /O3 /E main):
//   Texture2D<float4> src : register(t0);
//   RWTexture2D<unorm float4> dst : register(u0);
//   cbuffer K : register(b0) { float inv_white; uint ox; uint oy; uint pad; };
//   float enc(float v) { v = saturate(v); return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1.0 / 2.4) - 0.055; }
//   [numthreads(16, 16, 1)] void main(uint3 id : SV_DispatchThreadID) {
//     uint dw, dh; dst.GetDimensions(dw, dh); if (id.x >= dw || id.y >= dh) return;
//     float3 c = src[uint2(id.x + ox, id.y + oy)].rgb * inv_white;
//     dst[id.xy] = float4(enc(c.b), enc(c.g), enc(c.r), 1.0);
//   }
// Embedded so HDR capture never loads d3dcompiler_47.dll at runtime.
static const uint8_t to_srgb_bc[] = {
  68,88,66,67,117,38,71,212,153,44,226,219,84,135,113,200,56,178,202,255,1,0,0,0,
  108,5,0,0,5,0,0,0,52,0,0,0,48,2,0,0,64,2,0,0,80,2,0,0,
  208,4,0,0,82,68,69,70,244,1,0,0,1,0,0,0,168,0,0,0,3,0,0,0,
  60,0,0,0,0,5,83,67,0,129,0,0,203,1,0,0,82,68,49,49,60,0,0,0,
  24,0,0,0,32,0,0,0,40,0,0,0,36,0,0,0,12,0,0,0,0,0,0,0,
  156,0,0,0,2,0,0,0,5,0,0,0,4,0,0,0,255,255,255,255,0,0,0,0,
  1,0,0,0,13,0,0,0,160,0,0,0,4,0,0,0,1,0,0,0,4,0,0,0,
  255,255,255,255,0,0,0,0,1,0,0,0,13,0,0,0,164,0,0,0,0,0,0,0,
  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,0,0,0,1,0,0,0,
  115,114,99,0,100,115,116,0,75,0,171,171,164,0,0,0,4,0,0,0,192,0,0,0,
  16,0,0,0,0,0,0,0,0,0,0,0,96,1,0,0,0,0,0,0,4,0,0,0,
  2,0,0,0,112,1,0,0,0,0,0,0,255,255,255,255,0,0,0,0,255,255,255,255,
  0,0,0,0,148,1,0,0,4,0,0,0,4,0,0,0,2,0,0,0,160,1,0,0,
  0,0,0,0,255,255,255,255,0,0,0,0,255,255,255,255,0,0,0,0,196,1,0,0,
  8,0,0,0,4,0,0,0,2,0,0,0,160,1,0,0,0,0,0,0,255,255,255,255,
  0,0,0,0,255,255,255,255,0,0,0,0,199,1,0,0,12,0,0,0,4,0,0,0,
  0,0,0,0,160,1,0,0,0,0,0,0,255,255,255,255,0,0,0,0,255,255,255,255,
  0,0,0,0,105,110,118,95,119,104,105,116,101,0,102,108,111,97,116,0,0,0,3,0,
  1,0,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
  0,0,0,0,106,1,0,0,111,120,0,100,119,111,114,100,0,171,171,171,0,0,19,0,
  1,0,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
  0,0,0,0,151,1,0,0,111,121,0,112,97,100,0,77,105,99,114,111,115,111,102,116,
  32,40,82,41,32,72,76,83,76,32,83,104,97,100,101,114,32,67,111,109,112,105,108,101,
  114,32,49,48,46,49,0,171,73,83,71,78,8,0,0,0,0,0,0,0,8,0,0,0,
  79,83,71,78,8,0,0,0,0,0,0,0,8,0,0,0,83,72,69,88,120,2,0,0,
  80,0,5,0,158,0,0,0,106,8,0,1,89,0,0,4,70,142,32,0,0,0,0,0,
  1,0,0,0,88,24,0,4,0,112,16,0,0,0,0,0,85,85,0,0,156,24,0,4,
  0,224,17,0,0,0,0,0,17,17,0,0,95,0,0,2,50,0,2,0,104,0,0,2,
  3,0,0,0,155,0,0,4,16,0,0,0,16,0,0,0,1,0,0,0,61,16,0,137,
  194,0,0,128,67,68,4,0,50,0,16,0,0,0,0,0,1,64,0,0,0,0,0,0,
  70,238,17,0,0,0,0,0,80,0,0,6,50,0,16,0,0,0,0,0,70,0,2,0,
  70,0,16,0,0,0,0,0,60,0,0,7,18,0,16,0,0,0,0,0,26,0,16,0,
  0,0,0,0,10,0,16,0,0,0,0,0,31,0,4,3,10,0,16,0,0,0,0,0,
  62,0,0,1,21,0,0,1,30,0,0,7,50,0,16,0,0,0,0,0,70,0,2,0,
  150,133,32,0,0,0,0,0,0,0,0,0,54,0,0,8,194,0,16,0,0,0,0,0,
  2,64,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,45,0,0,137,
  194,0,0,128,67,85,21,0,114,0,16,0,0,0,0,0,70,14,16,0,0,0,0,0,
  70,126,16,0,0,0,0,0,56,32,0,8,114,0,16,0,0,0,0,0,102,8,16,0,
  0,0,0,0,6,128,32,0,0,0,0,0,0,0,0,0,29,0,0,10,114,0,16,0,
  1,0,0,0,2,64,0,0,28,46,77,59,28,46,77,59,28,46,77,59,0,0,0,0,
  70,2,16,0,0,0,0,0,56,0,0,10,114,0,16,0,2,0,0,0,70,2,16,0,
  0,0,0,0,2,64,0,0,82,184,78,65,82,184,78,65,82,184,78,65,0,0,0,0,
  47,0,0,5,114,0,16,0,0,0,0,0,70,2,16,0,0,0,0,0,56,0,0,10,
  114,0,16,0,0,0,0,0,70,2,16,0,0,0,0,0,2,64,0,0,85,85,213,62,
  85,85,213,62,85,85,213,62,0,0,0,0,25,0,0,5,114,0,16,0,0,0,0,0,
  70,2,16,0,0,0,0,0,50,0,0,15,114,0,16,0,0,0,0,0,70,2,16,0,
  0,0,0,0,2,64,0,0,61,10,135,63,61,10,135,63,61,10,135,63,0,0,0,0,
  2,64,0,0,174,71,97,189,174,71,97,189,174,71,97,189,0,0,0,0,55,0,0,9,
  114,0,16,0,0,0,0,0,70,2,16,0,1,0,0,0,70,2,16,0,2,0,0,0,
  70,2,16,0,0,0,0,0,54,0,0,5,130,0,16,0,0,0,0,0,1,64,0,0,
  0,0,128,63,164,0,0,6,242,224,17,0,0,0,0,0,70,5,2,0,70,14,16,0,
  0,0,0,0,62,0,0,1,83,84,65,84,148,0,0,0,20,0,0,0,3,0,0,0,
  0,0,0,0,1,0,0,0,7,0,0,0,1,0,0,0,2,0,0,0,2,0,0,0,
  1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
  0,0,0,0,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,2,0,0,0,
  1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,0,0,0
};

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;
using Microsoft::WRL::Wrappers::HStringReference;
namespace WGC = ABI::Windows::Graphics::Capture;
namespace WD3D = ABI::Windows::Graphics::DirectX::Direct3D11;
using ABI::Windows::Foundation::ITypedEventHandler;

static ComPtr<ID3D11Device> dev;
static ComPtr<ID3D11DeviceContext> ctx;
static ComPtr<WD3D::IDirect3DDevice> rt_dev;
static ComPtr<IGraphicsCaptureItemInterop> item_interop;
static ComPtr<WGC::IDirect3D11CaptureFramePoolStatics2> pool_statics;
static ComPtr<ID3D11ComputeShader> to_srgb;
static ComPtr<ID3D11Buffer> to_srgb_k;
static int ready = 0;
static CRITICAL_SECTION frame_lock;

#define MONS_MOST 8
struct Mon {
  HMONITOR mon;
  int w, h;
  ComPtr<WGC::IDirect3D11CaptureFramePool> pool;
  ComPtr<WGC::IGraphicsCaptureSession> session;
  EventRegistrationToken token;
  ComPtr<WGC::IDirect3D11CaptureFrame> last;
  int frames;
  int hdr;
  LONGLONG last_at;
  unsigned gen;
  int live;
};
static HANDLE frame_came;
static Mon mons[MONS_MOST];
static int nmons;
static HRESULT last_hr;
static double take_ms;
static int said_half;
static double take_white;

static double take_age;
static int take_fresh;
static int take_used_dd;
static int keep_sessions = 1;
static int long_holds;
static ComPtr<ID3D11Texture2D> kept_staging;
static ComPtr<ID3D11Texture2D> kept_out;
static ComPtr<ID3D11UnorderedAccessView> kept_uav;
static void kept_let_go(void) {
  kept_staging.Reset();
  kept_out.Reset();
  kept_uav.Reset();
}

static ComPtr<ID3D11Device> dd_dev;
static ComPtr<ID3D11DeviceContext> dd_ctx;
static ComPtr<ID3D11ComputeShader> dd_srgb;
static ComPtr<ID3D11Buffer> dd_srgb_k;
static LUID dd_luid = {0, 0};
static int dd_ok = -1;

static int dd_disabled(void) {
  const char *how = getenv("PINSHOT_CAPTURE");
  return how && (!strcmp(how, "gdi") || !strcmp(how, "wgc"));
}

static void dd_teardown(void) {
  kept_let_go();
  dd_srgb.Reset();
  dd_srgb_k.Reset();
  if (dd_ctx) {
    dd_ctx->ClearState();
    dd_ctx->Flush();
  }
  if (dd_dev) {
    ComPtr<IDXGIDevice3> d3;
    if (SUCCEEDED(dd_dev.As(&d3))) d3->Trim();
  }
  dd_ctx.Reset();
  dd_dev.Reset();
  dd_luid.LowPart = 0;
  dd_luid.HighPart = 0;
}

static int dd_find_output(HMONITOR mon, ComPtr<IDXGIAdapter1> &out_adap, ComPtr<IDXGIOutput> &out_out) {
  ComPtr<IDXGIFactory1> fac;
  if (FAILED(CreateDXGIFactory1(IID_PPV_ARGS(&fac)))) return 0;
  for (UINT ai = 0;; ai++) {
    ComPtr<IDXGIAdapter1> adap;
    if (fac->EnumAdapters1(ai, &adap) == DXGI_ERROR_NOT_FOUND) break;
    if (!adap) continue;
    for (UINT oi = 0;; oi++) {
      ComPtr<IDXGIOutput> out;
      if (adap->EnumOutputs(oi, &out) == DXGI_ERROR_NOT_FOUND) break;
      if (!out) continue;
      DXGI_OUTPUT_DESC od = {};
      if (SUCCEEDED(out->GetDesc(&od)) && od.Monitor == mon) {
        out_adap = adap;
        out_out = out;
        return 1;
      }
    }
  }
  return 0;
}

static int dd_ensure_dev(IDXGIAdapter1 *adap) {
  DXGI_ADAPTER_DESC1 ad = {};
  if (FAILED(adap->GetDesc1(&ad))) return 0;
  if (dd_dev && dd_ctx && dd_dev->GetDeviceRemovedReason() == S_OK &&
      dd_luid.LowPart == ad.AdapterLuid.LowPart && dd_luid.HighPart == ad.AdapterLuid.HighPart) {
    return 1;
  }
  dd_teardown();
  D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1};
  if (FAILED(D3D11CreateDevice(adap, D3D_DRIVER_TYPE_UNKNOWN, NULL, D3D11_CREATE_DEVICE_BGRA_SUPPORT, levels, 2,
                               D3D11_SDK_VERSION, &dd_dev, NULL, &dd_ctx))) {
    return 0;
  }
  ComPtr<ID3D10Multithread> mt;
  if (SUCCEEDED(dd_dev.As(&mt))) mt->SetMultithreadProtected(TRUE);
  dd_dev->CreateComputeShader(to_srgb_bc, sizeof to_srgb_bc, NULL, &dd_srgb);
  D3D11_BUFFER_DESC bd = {16, D3D11_USAGE_DYNAMIC, D3D11_BIND_CONSTANT_BUFFER, D3D11_CPU_ACCESS_WRITE, 0, 0};
  dd_dev->CreateBuffer(&bd, NULL, &dd_srgb_k);
  dd_luid = ad.AdapterLuid;
  return 1;
}

static int dd_make_dupl(IDXGIOutput *out, ComPtr<IDXGIOutputDuplication> &dupl) {
  ComPtr<IDXGIOutput5> out5;
  if (SUCCEEDED(out->QueryInterface(IID_PPV_ARGS(&out5)))) {
    DXGI_FORMAT fmts[2] = {DXGI_FORMAT_R16G16B16A16_FLOAT, DXGI_FORMAT_B8G8R8A8_UNORM};
    if (SUCCEEDED(last_hr = out5->DuplicateOutput1(dd_dev.Get(), 0, 2, fmts, &dupl)) && dupl) return 1;
  }
  ComPtr<IDXGIOutput1> out1;
  if (SUCCEEDED(out->QueryInterface(IID_PPV_ARGS(&out1)))) {
    if (SUCCEEDED(last_hr = out1->DuplicateOutput(dd_dev.Get(), &dupl)) && dupl) return 1;
  }
  return 0;
}

static int dd_probe(void) {
  if (dd_disabled()) {
    dd_ok = 0;
    return 0;
  }
  POINT pt = {0, 0};
  HMONITOR mon = MonitorFromPoint(pt, MONITOR_DEFAULTTOPRIMARY);
  ComPtr<IDXGIAdapter1> adap;
  ComPtr<IDXGIOutput> out;
  if (!mon || !dd_find_output(mon, adap, out) || !dd_ensure_dev(adap.Get())) {
    dd_ok = 0;
    return 0;
  }
  ComPtr<IDXGIOutputDuplication> dupl;
  int ok = dd_make_dupl(out.Get(), dupl);
  dupl.Reset();
  if (dd_ctx) {
    dd_ctx->ClearState();
    dd_ctx->Flush();
  }
  if (dd_dev) {
    ComPtr<IDXGIDevice3> d3;
    if (SUCCEEDED(dd_dev.As(&d3))) d3->Trim();
  }
  if (!ok || !keep_sessions) dd_teardown();
  dd_ok = ok ? 1 : 0;
  return dd_ok;
}

extern "C" int ps_wgc_dd_ok(void) {
  if (dd_disabled()) return 0;
  if (dd_ok < 0) return dd_probe();
  return dd_ok == 1;
}

extern "C" int ps_wgc_last_used_dd(void) { return take_used_dd; }

extern "C" void ps_wgc_timing(double *out) {
  out[0] = take_ms, out[1] = take_white, out[2] = said_half, out[3] = take_age, out[4] = take_fresh;
}

extern "C" int ps_wgc_ready(void) {
  if (ready) return ready > 0;
  ready = -1;
  const char *how = getenv("PINSHOT_CAPTURE");
  if (how && !strcmp(how, "gdi")) return 0;
  static int lock_made;
  if (!lock_made) {
    InitializeCriticalSection(&frame_lock);
    frame_came = CreateEventW(NULL, FALSE, FALSE, NULL);
    lock_made = 1;
  }
  static int ro_asked;
  if (!ro_asked) {
    ro_asked = 1;
    RoInitialize(RO_INIT_SINGLETHREADED);
  }
  D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1};
  if (FAILED(D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, D3D11_CREATE_DEVICE_BGRA_SUPPORT, levels, 2,
                               D3D11_SDK_VERSION, &dev, NULL, &ctx)))
    return 0;
  ComPtr<ID3D10Multithread> mt;
  if (SUCCEEDED(dev.As(&mt))) mt->SetMultithreadProtected(TRUE);
  ComPtr<IDXGIDevice> xdev;
  ComPtr<IInspectable> insp;
  if (FAILED(dev.As(&xdev)) || FAILED(CreateDirect3D11DeviceFromDXGIDevice(xdev.Get(), &insp)) || FAILED(insp.As(&rt_dev)))
    return 0;
  if (FAILED(RoGetActivationFactory(HStringReference(RuntimeClass_Windows_Graphics_Capture_GraphicsCaptureItem).Get(),
                                    IID_PPV_ARGS(&item_interop))))
    return 0;
  if (FAILED(RoGetActivationFactory(HStringReference(RuntimeClass_Windows_Graphics_Capture_Direct3D11CaptureFramePool).Get(),
                                    IID_PPV_ARGS(&pool_statics))))
    return 0;
  dev->CreateComputeShader(to_srgb_bc, sizeof to_srgb_bc, NULL, &to_srgb);
  D3D11_BUFFER_DESC bd = {16, D3D11_USAGE_DYNAMIC, D3D11_BIND_CONSTANT_BUFFER, D3D11_CPU_ACCESS_WRITE, 0, 0};
  dev->CreateBuffer(&bd, NULL, &to_srgb_k);
  ready = 1;
  return 1;
}

#define WHITES_MOST 8
static struct {
  wchar_t name[CCHDEVICENAME];
  float white;
} whites[WHITES_MOST];
static float disk_white = -1;

static float *white_of(const wchar_t *name) {
  for (int i = 0; i < WHITES_MOST; i++)
    if (whites[i].name[0] && !wcscmp(whites[i].name, name)) return &whites[i].white;
  for (int i = 0; i < WHITES_MOST; i++)
    if (!whites[i].name[0]) {
      wcscpy_s(whites[i].name, CCHDEVICENAME, name);
      whites[i].white = 0;
      return &whites[i].white;
    }
  return NULL;
}

#define HDR_ASKED_MS 1000
static struct {
  HMONITOR mon;
  ULONGLONG at;
  int hdr;
  float white;
} hdr_asked[WHITES_MOST];
static void hdr_forget(void) { memset(hdr_asked, 0, sizeof hdr_asked); }

static int mon_hdr_asked(HMONITOR mon, float *white);

static int mon_hdr(HMONITOR mon, float *white) {
  ULONGLONG now = GetTickCount64();
  for (int i = 0; i < WHITES_MOST; i++)
    if (hdr_asked[i].mon == mon && now - hdr_asked[i].at < HDR_ASKED_MS) {
      *white = hdr_asked[i].white;
      return hdr_asked[i].hdr;
    }
  int hdr = mon_hdr_asked(mon, white);
  int slot = 0;
  for (int i = 0; i < WHITES_MOST; i++) {
    if (hdr_asked[i].mon == mon) {
      slot = i;
      break;
    }
    if (hdr_asked[i].at < hdr_asked[slot].at) slot = i;
  }
  hdr_asked[slot].mon = mon, hdr_asked[slot].at = now, hdr_asked[slot].hdr = hdr, hdr_asked[slot].white = *white;
  return hdr;
}

static int mon_hdr_asked(HMONITOR mon, float *white) {
  *white = 1.0f;
  MONITORINFOEXW mi;
  mi.cbSize = sizeof mi;
  if (!GetMonitorInfoW(mon, &mi)) return 0;
  UINT32 np = 0, nm = 0;
  if (GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &np, &nm) != ERROR_SUCCESS || !np) return 0;
  DISPLAYCONFIG_PATH_INFO *paths = (DISPLAYCONFIG_PATH_INFO *)calloc(np, sizeof *paths);
  DISPLAYCONFIG_MODE_INFO *modes = (DISPLAYCONFIG_MODE_INFO *)calloc(nm ? nm : 1, sizeof *modes);
  int hdr = 0;
  if (paths && modes && QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &np, paths, &nm, modes, NULL) == ERROR_SUCCESS) {
    hdr = -1;
  }
  for (UINT32 i = 0; hdr == -1 && i < np; i++) {
    DISPLAYCONFIG_SOURCE_DEVICE_NAME sn = {};
    sn.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
    sn.header.size = sizeof sn;
    sn.header.adapterId = paths[i].sourceInfo.adapterId;
    sn.header.id = paths[i].sourceInfo.id;
    if (DisplayConfigGetDeviceInfo(&sn.header) != ERROR_SUCCESS || wcscmp(sn.viewGdiDeviceName, mi.szDevice)) continue;
    DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO ai = {};
    ai.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_ADVANCED_COLOR_INFO;
    ai.header.size = sizeof ai;
    ai.header.adapterId = paths[i].targetInfo.adapterId;
    ai.header.id = paths[i].targetInfo.id;
    if (DisplayConfigGetDeviceInfo(&ai.header) != ERROR_SUCCESS || !ai.advancedColorEnabled) {
      hdr = 0;
      break;
    }
    DISPLAYCONFIG_SDR_WHITE_LEVEL wl = {};
    wl.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_SDR_WHITE_LEVEL;
    wl.header.size = sizeof wl;
    wl.header.adapterId = paths[i].targetInfo.adapterId;
    wl.header.id = paths[i].targetInfo.id;
    if (DisplayConfigGetDeviceInfo(&wl.header) == ERROR_SUCCESS && wl.SDRWhiteLevel >= 1000)
      *white = (float)wl.SDRWhiteLevel / 1000.0f;
    // (a monitor asleep or turned off at its button says 80 nits, its white unknown: the last it said awake kept,
    // each monitor's its own; ScreenReplay found the same, 2026-11-15)
    // Kept on disk too (%APPDATA%\PinShot\sdr-white.txt): a run started while the monitor sleeps has it. Written only
    // as a monitor's own white changes, never as captures go from one monitor to another.
    wchar_t path[MAX_PATH];
    DWORD n = GetEnvironmentVariableW(L"APPDATA", path, MAX_PATH);
    int have_path = n > 0 && n < MAX_PATH - 40;
    if (have_path) wcscat_s(path, MAX_PATH, L"\\PinShot\\sdr-white.txt");
    if (disk_white < 0) {
      disk_white = 0;
      FILE *f = NULL;
      if (have_path && _wfopen_s(&f, path, L"r") == 0 && f) {
        if (fscanf_s(f, "%f", &disk_white) != 1) disk_white = 0;
        fclose(f);
      }
    }
    float *last = white_of(mi.szDevice);
    if (*white > 1.001f) {
      if (last && *last != *white && *white != disk_white && have_path) {
        FILE *f = NULL;
        if (_wfopen_s(&f, path, L"w") == 0 && f) {
          fprintf(f, "%.3f\n", *white);
          fclose(f);
          disk_white = *white;
        }
      }
      if (last) *last = *white;
    } else if (last && *last > 1.001f) {
      *white = *last;
    } else if (disk_white > 1.001f) {
      *white = disk_white;
    }
    hdr = 1;
  }
  free(paths);
  free(modes);
  return hdr == 1;
}

extern "C" int ps_wgc_mon_hdr(HMONITOR mon, float *white) {
  return mon_hdr_asked(mon, white);
}

static void mon_stop(Mon *m) {
  if (m->pool) m->pool->remove_FrameArrived(m->token);
  ComPtr<ABI::Windows::Foundation::IClosable> c;
  ComPtr<WGC::IDirect3D11CaptureFrame> last;
  EnterCriticalSection(&frame_lock);
  m->live = 0;
  m->gen++;
  last.Swap(m->last);
  LeaveCriticalSection(&frame_lock);
  if (last && SUCCEEDED(last.As(&c))) c->Close();
  last.Reset();
  if (m->session && SUCCEEDED(m->session.As(&c))) c->Close();
  if (m->pool && SUCCEEDED(m->pool.As(&c))) c->Close();
  m->session.Reset();
  m->pool.Reset();
  m->mon = NULL;
  m->frames = 0;
  m->hdr = 0;
}

static int mon_start(Mon *m, HMONITOR mon, int w, int h, int hdr = -1) {
  float white;
  m->mon = mon, m->w = w, m->h = h, m->frames = 0;
  m->hdr = hdr >= 0 ? hdr : (to_srgb && to_srgb_k && mon_hdr(mon, &white));
  EnterCriticalSection(&frame_lock);
  unsigned gen = ++m->gen;
  m->live = 1;
  LeaveCriticalSection(&frame_lock);
  ComPtr<WGC::IGraphicsCaptureItem> item;
  if (FAILED(last_hr = item_interop->CreateForMonitor(mon, IID_PPV_ARGS(&item)))) return 0;
  ABI::Windows::Graphics::SizeInt32 size = {w, h};
  int nbufs = (keep_sessions || long_holds) ? 2 : 1;
  if (FAILED(last_hr = pool_statics->CreateFreeThreaded(
                     rt_dev.Get(),
                     m->hdr ? ABI::Windows::Graphics::DirectX::DirectXPixelFormat_R16G16B16A16Float
                            : ABI::Windows::Graphics::DirectX::DirectXPixelFormat_B8G8R8A8UIntNormalized,
                     nbufs, size, &m->pool)))
    return 0;
  auto arrived = Callback<Microsoft::WRL::Implements<Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::ClassicCom>,
                                                     ITypedEventHandler<WGC::Direct3D11CaptureFramePool *, IInspectable *>,
                                                     Microsoft::WRL::FtmBase>>(
      [m, gen](WGC::IDirect3D11CaptureFramePool *sender, IInspectable *) -> HRESULT {
        ComPtr<WGC::IDirect3D11CaptureFrame> f;
        if (SUCCEEDED(sender->TryGetNextFrame(&f)) && f) {
          ComPtr<WGC::IDirect3D11CaptureFrame> old;
          EnterCriticalSection(&frame_lock);
          if (!m->live || m->gen != gen) {
            old = f;
          } else {
            old = m->last;
            m->last = f;
            m->frames++;
            LARGE_INTEGER now;
            QueryPerformanceCounter(&now);
            m->last_at = now.QuadPart;
          }
          LeaveCriticalSection(&frame_lock);
          SetEvent(frame_came);
          ComPtr<ABI::Windows::Foundation::IClosable> c;
          if (old && SUCCEEDED(old.As(&c))) c->Close();
        }
        return S_OK;
      });
  if (FAILED(last_hr = m->pool->add_FrameArrived(arrived.Get(), &m->token))) {
    mon_stop(m);
    return 0;
  }
  if (FAILED(last_hr = m->pool->CreateCaptureSession(item.Get(), &m->session))) {
    mon_stop(m);
    return 0;
  }
  ComPtr<WGC::IGraphicsCaptureSession2> s2;
  if (SUCCEEDED(m->session.As(&s2))) s2->put_IsCursorCaptureEnabled(FALSE);
  ComPtr<WGC::IGraphicsCaptureSession3> s3;
  if (FAILED(m->session.As(&s3)) || FAILED(last_hr = s3->put_IsBorderRequired(FALSE))) {
    mon_stop(m);
    return 0;
  }
  if (FAILED(last_hr = m->session->StartCapture())) {
    mon_stop(m);
    return 0;
  }
  return 1;
}

static BOOL CALLBACK mon_found(HMONITOR mon, HDC, LPRECT r, LPARAM) {
  if (nmons >= MONS_MOST) return FALSE;
  if (mon_start(&mons[nmons], mon, r->right - r->left, r->bottom - r->top)) nmons++;
  return TRUE;
}

extern "C" int ps_packaged(void);
extern "C" void ps_wgc_wake(void);
static volatile LONG borderless = -1;

static int borderless_allowed(void) {
  if (!ps_packaged()) return 1;
  if (borderless >= 0) return borderless;
  if (InterlockedCompareExchange(&borderless, -2, -1) != -1) return 0;
  ComPtr<WGC::IGraphicsCaptureAccessStatics> statics;
  ComPtr<ABI::Windows::Foundation::IAsyncOperation<ABI::Windows::Security::Authorization::AppCapabilityAccess::AppCapabilityAccessStatus>> op;
  HRESULT fhr = RoGetActivationFactory(HStringReference(RuntimeClass_Windows_Graphics_Capture_GraphicsCaptureAccess).Get(),
                                       IID_PPV_ARGS(&statics));
  if (fhr == CO_E_NOTINITIALIZED) {
    InterlockedExchange(&borderless, -1);
    return 0;
  }
  if (FAILED(fhr) ||
      FAILED(statics->RequestAccessAsync(WGC::GraphicsCaptureAccessKind_Borderless, &op))) {
    borderless = 0;
    return 0;
  }
  using Status = ABI::Windows::Security::Authorization::AppCapabilityAccess::AppCapabilityAccessStatus;
  auto done = Callback<Microsoft::WRL::Implements<Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::ClassicCom>,
                                                  ABI::Windows::Foundation::IAsyncOperationCompletedHandler<Status>,
                                                  Microsoft::WRL::FtmBase>>(
      [](ABI::Windows::Foundation::IAsyncOperation<Status> *o, ABI::Windows::Foundation::AsyncStatus) -> HRESULT {
        Status s;
        borderless = SUCCEEDED(o->GetResults(&s)) &&
                     s == ABI::Windows::Security::Authorization::AppCapabilityAccess::AppCapabilityAccessStatus_Allowed;
        ps_wgc_wake();
        return S_OK;
      });
  if (FAILED(op->put_Completed(done.Get()))) borderless = 0;
  return 0;
}

extern "C" int ps_wgc_borderless_ok(void) {
  return borderless_allowed();
}

extern "C" int ps_wgc_restart(void) {
  for (int i = 0; i < nmons; i++) mon_stop(&mons[i]);
  nmons = 0;
  hdr_forget();
  dd_ok = -1;
  if (!keep_sessions) {
    dd_teardown();
    return 0;
  }
  if (dd_probe()) {
    if (ready > 0) {
      to_srgb.Reset();
      to_srgb_k.Reset();
      pool_statics.Reset();
      item_interop.Reset();
      if (rt_dev) {
        ComPtr<ABI::Windows::Foundation::IClosable> c;
        if (SUCCEEDED(rt_dev.As(&c))) c->Close();
      }
      rt_dev.Reset();
      if (ctx) { ctx->ClearState(); ctx->Flush(); }
      if (dev) {
        ComPtr<IDXGIDevice3> d3;
        if (SUCCEEDED(dev.As(&d3))) d3->Trim();
      }
      ctx.Reset();
      dev.Reset();
      ready = 0;
    }
    return 1;
  }
  if (!ps_wgc_ready()) return 0;
  if (!borderless_allowed()) return 0;
  EnumDisplayMonitors(NULL, NULL, mon_found, 0);
  return nmons;
}

static void wgc_teardown(void) {
  for (int i = 0; i < nmons; i++) mon_stop(&mons[i]);
  nmons = 0;
  dd_teardown();
  kept_let_go();
  to_srgb.Reset();
  to_srgb_k.Reset();
  pool_statics.Reset();
  item_interop.Reset();
  if (rt_dev) {
    ComPtr<ABI::Windows::Foundation::IClosable> c;
    if (SUCCEEDED(rt_dev.As(&c))) c->Close();
  }
  rt_dev.Reset();
  if (ctx) {
    ctx->ClearState();
    ctx->Flush();
  }
  if (dev) {
    ComPtr<IDXGIDevice3> d3;
    if (SUCCEEDED(dev.As(&d3))) d3->Trim();
  }
  ctx.Reset();
  dev.Reset();
  ready = 0;
}

extern "C" void ps_wgc_set_keep(int keep) {
  keep = keep ? 1 : 0;
  keep_sessions = keep;
  if (keep) {
    if (nmons == 0) ps_wgc_restart();
  } else {
    if (!long_holds) wgc_teardown();
    else {
      for (int i = 0; i < nmons; i++) mon_stop(&mons[i]);
      nmons = 0;
    }
  }
}

static void device_lost(void) {
  wgc_teardown();
  ps_wgc_wake();
}

// A frame older than this is not trusted (seconds): its session made again first and its first frame waited for.
// The system gives none while the screen does not change, but a session can also stop for good with its last frame
// kept (2026-11-18: the monitor asleep overnight, every capture in the morning the screen of the night before).
#define FRAME_TRUSTED_S 5.0
#define FIRST_FRAME_MS 250

static void *take(HMONITOR mon, int w, int h, int rx, int ry, int rw, int rh, int any_age, uint8_t **bits, int *pitch);

extern "C" void *ps_wgc_take_now(HMONITOR mon, int w, int h, uint8_t **bits, int *pitch) {
  return take(mon, w, h, 0, 0, w, h, 0, bits, pitch);
}

extern "C" void ps_wgc_long_hold(int on) {
  long_holds = on;
  if (!on) kept_let_go();
  if (on || keep_sessions) return;
  wgc_teardown();
}

extern "C" void *ps_wgc_take_part(HMONITOR mon, int w, int h, int rx, int ry, int rw, int rh, uint8_t **bits, int *pitch) {
  if (rx < 0 || ry < 0 || rw <= 0 || rh <= 0 || rx + rw > w || ry + rh > h) return NULL;
  return take(mon, w, h, rx, ry, rw, rh, 1, bits, pitch);
}

static void *dd_take(HMONITOR mon, int w, int h, int rx, int ry, int rw, int rh, uint8_t **bits, int *pitch) {
  if (dd_disabled() || dd_ok == 0) return NULL;
  LARGE_INTEGER t0, t1, f;
  QueryPerformanceCounter(&t0);
  QueryPerformanceFrequency(&f);
  ComPtr<IDXGIAdapter1> adap;
  ComPtr<IDXGIOutput> out;
  if (!dd_find_output(mon, adap, out) || !dd_ensure_dev(adap.Get())) {
    dd_ok = 0;
    return NULL;
  }
  ComPtr<IDXGIOutputDuplication> dupl;
  if (!dd_make_dupl(out.Get(), dupl)) {
    if (last_hr == E_ACCESSDENIED || last_hr == DXGI_ERROR_UNSUPPORTED) dd_ok = 0;
    return NULL;
  }
  dd_ok = 1;
  ComPtr<IDXGIResource> res;
  DXGI_OUTDUPL_FRAME_INFO fi = {};
  HRESULT hr = E_FAIL;
  for (int attempt = 0; attempt < 3; attempt++) {
    hr = dupl->AcquireNextFrame(attempt == 0 ? 250 : 40, &fi, &res);
    if (SUCCEEDED(hr) && res) {
      if (fi.LastPresentTime.QuadPart != 0 || attempt == 2) break;
      res.Reset();
      dupl->ReleaseFrame();
    } else if (hr == DXGI_ERROR_WAIT_TIMEOUT) {
      break;
    } else {
      break;
    }
  }
  if (FAILED(hr) || !res) {
    dupl.Reset();
    return NULL;
  }
  ComPtr<ID3D11Texture2D> tex;
  if (FAILED(res.As(&tex)) || !tex) {
    res.Reset();
    dupl->ReleaseFrame();
    dupl.Reset();
    return NULL;
  }
  D3D11_TEXTURE2D_DESC td = {};
  tex->GetDesc(&td);
  if ((int)td.Width != w || (int)td.Height != h) {
    tex.Reset();
    res.Reset();
    dupl->ReleaseFrame();
    dupl.Reset();
    return NULL;
  }
  int whole = rx == 0 && ry == 0 && rw == w && rh == h;
  int is_hdr = (td.Format == DXGI_FORMAT_R16G16B16A16_FLOAT);
  float white = 1.0f;
  if (is_hdr) mon_hdr(mon, &white);
  said_half = 0;
  ComPtr<ID3D11Texture2D> src_for_copy = tex;
  D3D11_TEXTURE2D_DESC copy_desc = td;
  if (is_hdr) {
    if (!dd_srgb || !dd_srgb_k) {
      tex.Reset(); res.Reset(); dupl->ReleaseFrame(); dupl.Reset();
      return NULL;
    }
    ComPtr<ID3D11ShaderResourceView> srv;
    ComPtr<ID3D11Texture2D> half;
    uint32_t ox = (uint32_t)rx, oy = (uint32_t)ry;
    if (FAILED(dd_dev->CreateShaderResourceView(tex.Get(), NULL, &srv))) {
      D3D11_TEXTURE2D_DESC hd = td;
      hd.Width = (UINT)rw;
      hd.Height = (UINT)rh;
      hd.Usage = D3D11_USAGE_DEFAULT;
      hd.BindFlags = D3D11_BIND_SHADER_RESOURCE;
      hd.CPUAccessFlags = 0;
      hd.MiscFlags = 0;
      hd.MipLevels = hd.ArraySize = 1;
      said_half = 1;
      if (FAILED(dd_dev->CreateTexture2D(&hd, NULL, &half))) {
        tex.Reset(); res.Reset(); dupl->ReleaseFrame(); dupl.Reset();
        return NULL;
      }
      if (whole) dd_ctx->CopyResource(half.Get(), tex.Get());
      else {
        D3D11_BOX box = {(UINT)rx, (UINT)ry, 0, (UINT)(rx + rw), (UINT)(ry + rh), 1};
        dd_ctx->CopySubresourceRegion(half.Get(), 0, 0, 0, 0, tex.Get(), 0, &box);
      }
      ox = oy = 0;
      if (FAILED(dd_dev->CreateShaderResourceView(half.Get(), NULL, &srv))) {
        tex.Reset(); res.Reset(); dupl->ReleaseFrame(); dupl.Reset();
        return NULL;
      }
    }
    D3D11_TEXTURE2D_DESC od = td;
    od.Width = (UINT)rw;
    od.Height = (UINT)rh;
    od.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    od.Usage = D3D11_USAGE_DEFAULT;
    od.BindFlags = D3D11_BIND_UNORDERED_ACCESS;
    od.CPUAccessFlags = 0;
    od.MiscFlags = 0;
    od.MipLevels = od.ArraySize = 1;
    ComPtr<ID3D11Texture2D> uav_tex;
    ComPtr<ID3D11UnorderedAccessView> uav;
    if (long_holds && kept_out) {
      D3D11_TEXTURE2D_DESC kd;
      kept_out->GetDesc(&kd);
      ComPtr<ID3D11Device> kdev;
      kept_out->GetDevice(&kdev);
      if (kdev.Get() == dd_dev.Get() && kd.Width == od.Width && kd.Height == od.Height && kd.Format == od.Format)
        uav_tex = kept_out, uav = kept_uav;
    }
    if (!uav_tex && (FAILED(dd_dev->CreateTexture2D(&od, NULL, &uav_tex)) ||
                     FAILED(dd_dev->CreateUnorderedAccessView(uav_tex.Get(), NULL, &uav)))) {
      tex.Reset(); res.Reset(); dupl->ReleaseFrame(); dupl.Reset();
      return NULL;
    }
    D3D11_MAPPED_SUBRESOURCE kp;
    if (FAILED(dd_ctx->Map(dd_srgb_k.Get(), 0, D3D11_MAP_WRITE_DISCARD, 0, &kp))) {
      tex.Reset(); res.Reset(); dupl->ReleaseFrame(); dupl.Reset();
      return NULL;
    }
    struct { float inv_white; uint32_t ox; uint32_t oy; uint32_t pad; } k = {1.0f / white, ox, oy, 0};
    memcpy(kp.pData, &k, sizeof k);
    dd_ctx->Unmap(dd_srgb_k.Get(), 0);
    ID3D11ShaderResourceView *srvs[1] = {srv.Get()};
    ID3D11UnorderedAccessView *uavs[1] = {uav.Get()};
    ID3D11Buffer *ks[1] = {dd_srgb_k.Get()};
    dd_ctx->CSSetShader(dd_srgb.Get(), NULL, 0);
    dd_ctx->CSSetShaderResources(0, 1, srvs);
    dd_ctx->CSSetUnorderedAccessViews(0, 1, uavs, NULL);
    dd_ctx->CSSetConstantBuffers(0, 1, ks);
    dd_ctx->Dispatch((rw + 15) / 16, (rh + 15) / 16, 1);
    ID3D11ShaderResourceView *no_srv[1] = {NULL};
    ID3D11UnorderedAccessView *no_uav[1] = {NULL};
    dd_ctx->CSSetShaderResources(0, 1, no_srv);
    dd_ctx->CSSetUnorderedAccessViews(0, 1, no_uav, NULL);
    dd_ctx->CSSetShader(NULL, NULL, 0);
    if (long_holds) kept_out = uav_tex, kept_uav = uav;
    src_for_copy = uav_tex;
    copy_desc = od;
    whole = 1;
  }
  copy_desc.Usage = D3D11_USAGE_STAGING;
  copy_desc.BindFlags = 0;
  copy_desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
  copy_desc.MiscFlags = 0;
  copy_desc.MipLevels = copy_desc.ArraySize = 1;
  copy_desc.Width = (UINT)rw;
  copy_desc.Height = (UINT)rh;
  ComPtr<ID3D11Texture2D> staging;
  if (long_holds && kept_staging) {
    D3D11_TEXTURE2D_DESC kd;
    kept_staging->GetDesc(&kd);
    ComPtr<ID3D11Device> kdev;
    kept_staging->GetDevice(&kdev);
    if (kdev.Get() == dd_dev.Get() && kd.Width == copy_desc.Width && kd.Height == copy_desc.Height && kd.Format == copy_desc.Format)
      staging = kept_staging;
    kept_staging.Reset();
  }
  if (!staging && FAILED(dd_dev->CreateTexture2D(&copy_desc, NULL, &staging))) {
    tex.Reset(); res.Reset(); dupl->ReleaseFrame(); dupl.Reset();
    return NULL;
  }
  if (whole) dd_ctx->CopyResource(staging.Get(), src_for_copy.Get());
  else {
    D3D11_BOX box = {(UINT)rx, (UINT)ry, 0, (UINT)(rx + rw), (UINT)(ry + rh), 1};
    dd_ctx->CopySubresourceRegion(staging.Get(), 0, 0, 0, 0, src_for_copy.Get(), 0, &box);
  }
  src_for_copy.Reset();
  tex.Reset();
  res.Reset();
  dupl->ReleaseFrame();
  dupl.Reset();
  D3D11_MAPPED_SUBRESOURCE mp;
  if (FAILED(dd_ctx->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &mp))) return NULL;
  *bits = (uint8_t *)mp.pData;
  *pitch = (int)mp.RowPitch;
  take_white = is_hdr ? white : 0.0;
  take_age = 0.0;
  take_fresh = 0;
  take_used_dd = 1;
  QueryPerformanceCounter(&t1);
  take_ms = (t1.QuadPart - t0.QuadPart) * 1000.0 / (double)f.QuadPart;
  return staging.Detach();
}

static void *take(HMONITOR mon, int w, int h, int rx, int ry, int rw, int rh, int any_age, uint8_t **bits, int *pitch) {
  take_used_dd = 0;
  if (void *dd_res = dd_take(mon, w, h, rx, ry, rw, rh, bits, pitch)) return dd_res;
  LARGE_INTEGER t0, t1, f;
  QueryPerformanceCounter(&t0);
  QueryPerformanceFrequency(&f);
  if (ready > 0 && dev->GetDeviceRemovedReason() != S_OK) {
    device_lost();
    return NULL;
  }
  if (!ps_wgc_ready() || !borderless_allowed()) return NULL;
  if (keep_sessions && nmons == 0) ps_wgc_restart();
  Mon *m = NULL;
  for (int i = 0; i < nmons; i++)
    if (mons[i].mon == mon) m = &mons[i];
  if (!m && !keep_sessions) {
    for (int i = 0; i < nmons; i++) mon_stop(&mons[i]);
    nmons = 1;
    m = &mons[0];
    m->mon = mon, m->w = w, m->h = h;
  }
  if (!m) return NULL;
  float white = 1.0f;
  int hdr = to_srgb && to_srgb_k && mon_hdr(mon, &white);
  if ((m->pool && hdr != m->hdr) || m->w != w || m->h != h) {
    mon_stop(m);
    m->mon = mon, m->w = w, m->h = h;
  }
  ComPtr<WGC::IDirect3D11CaptureFrame> fr;
  EnterCriticalSection(&frame_lock);
  fr = m->last;
  LONGLONG at = m->last_at;
  LeaveCriticalSection(&frame_lock);
  take_fresh = 0;
  static double trusted = -1;
  if (trusted < 0) {
    const char *e = getenv("PINSHOT_FRAME_TRUSTED_S");
    trusted = e ? atof(e) : FRAME_TRUSTED_S;
  }
  double age = fr ? (t0.QuadPart - at) / (double)f.QuadPart : 1e9;
  if (age > trusted && !(any_age && fr)) {
    fr.Reset();
    mon_stop(m);
    ResetEvent(frame_came);
    if (!mon_start(m, mon, w, h, hdr)) {
      m->mon = mon, m->w = w, m->h = h;
      return NULL;
    }
    take_fresh = 1;
    LARGE_INTEGER started;
    QueryPerformanceCounter(&started);
    for (;;) {
      EnterCriticalSection(&frame_lock);
      fr = m->last;
      at = m->last_at;
      LeaveCriticalSection(&frame_lock);
      if (fr) break;
      LARGE_INTEGER now;
      QueryPerformanceCounter(&now);
      double left = FIRST_FRAME_MS - (now.QuadPart - started.QuadPart) * 1000.0 / (double)f.QuadPart;
      if (left <= 0) {
        if (!keep_sessions && !long_holds) {
          mon_stop(m);
          nmons = 0;
        }
        return NULL;
      }
      WaitForSingleObject(frame_came, (DWORD)left + 1);
    }
    LARGE_INTEGER now;
    QueryPerformanceCounter(&now);
    age = (now.QuadPart - at) / (double)f.QuadPart;
  }
  auto drop_on_demand = [&]() {
    if (!keep_sessions && !long_holds) {
      mon_stop(m);
      nmons = 0;
    }
  };
  take_age = age;
  if (!fr) {
    drop_on_demand();
    return NULL;
  }
  ComPtr<WD3D::IDirect3DSurface> surface;
  ComPtr<Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess> access;
  ComPtr<ID3D11Texture2D> tex;
  if (FAILED(fr->get_Surface(&surface)) || FAILED(surface.As(&access)) || FAILED(access->GetInterface(IID_PPV_ARGS(&tex)))) {
    fr.Reset();
    drop_on_demand();
    return NULL;
  }
  D3D11_TEXTURE2D_DESC td;
  tex->GetDesc(&td);
  if ((int)td.Width != w || (int)td.Height != h) {
    tex.Reset();
    surface.Reset();
    access.Reset();
    fr.Reset();
    drop_on_demand();
    return NULL;
  }
  int whole = rx == 0 && ry == 0 && rw == w && rh == h;
  said_half = 0;
  if (m->hdr) {
    ComPtr<ID3D11ShaderResourceView> srv;
    ComPtr<ID3D11Texture2D> half;
    uint32_t ox = (uint32_t)rx, oy = (uint32_t)ry;
    if (FAILED(dev->CreateShaderResourceView(tex.Get(), NULL, &srv))) {
      D3D11_TEXTURE2D_DESC hd = td;
      hd.Width = (UINT)rw;
      hd.Height = (UINT)rh;
      hd.Usage = D3D11_USAGE_DEFAULT;
      hd.BindFlags = D3D11_BIND_SHADER_RESOURCE;
      hd.CPUAccessFlags = 0;
      hd.MiscFlags = 0;
      hd.MipLevels = hd.ArraySize = 1;
      said_half = 1;
      if (FAILED(dev->CreateTexture2D(&hd, NULL, &half))) {
        tex.Reset(); surface.Reset(); access.Reset(); fr.Reset();
        drop_on_demand();
        return NULL;
      }
      if (whole) {
        ctx->CopyResource(half.Get(), tex.Get());
      } else {
        D3D11_BOX box = {(UINT)rx, (UINT)ry, 0, (UINT)(rx + rw), (UINT)(ry + rh), 1};
        ctx->CopySubresourceRegion(half.Get(), 0, 0, 0, 0, tex.Get(), 0, &box);
      }
      ox = oy = 0;
      if (FAILED(dev->CreateShaderResourceView(half.Get(), NULL, &srv))) {
        tex.Reset(); surface.Reset(); access.Reset(); fr.Reset();
        drop_on_demand();
        return NULL;
      }
    }
    D3D11_TEXTURE2D_DESC od = td;
    od.Width = (UINT)rw;
    od.Height = (UINT)rh;
    od.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    od.Usage = D3D11_USAGE_DEFAULT;
    od.BindFlags = D3D11_BIND_UNORDERED_ACCESS;
    od.CPUAccessFlags = 0;
    od.MiscFlags = 0;
    od.MipLevels = od.ArraySize = 1;
    ComPtr<ID3D11Texture2D> out;
    ComPtr<ID3D11UnorderedAccessView> uav;
    if (long_holds && kept_out) {
      D3D11_TEXTURE2D_DESC kd;
      kept_out->GetDesc(&kd);
      if (kd.Width == od.Width && kd.Height == od.Height && kd.Format == od.Format) out = kept_out, uav = kept_uav;
    }
    if (!out && (FAILED(dev->CreateTexture2D(&od, NULL, &out)) || FAILED(dev->CreateUnorderedAccessView(out.Get(), NULL, &uav)))) {
      tex.Reset(); surface.Reset(); access.Reset(); fr.Reset();
      drop_on_demand();
      return NULL;
    }
    D3D11_MAPPED_SUBRESOURCE kp;
    if (FAILED(ctx->Map(to_srgb_k.Get(), 0, D3D11_MAP_WRITE_DISCARD, 0, &kp))) {
      tex.Reset(); surface.Reset(); access.Reset(); fr.Reset();
      drop_on_demand();
      return NULL;
    }
    struct { float inv_white; uint32_t ox; uint32_t oy; uint32_t pad; } k = {1.0f / white, ox, oy, 0};
    memcpy(kp.pData, &k, sizeof k);
    ctx->Unmap(to_srgb_k.Get(), 0);
    ID3D11ShaderResourceView *srvs[1] = {srv.Get()};
    ID3D11UnorderedAccessView *uavs[1] = {uav.Get()};
    ID3D11Buffer *ks[1] = {to_srgb_k.Get()};
    ctx->CSSetShader(to_srgb.Get(), NULL, 0);
    ctx->CSSetShaderResources(0, 1, srvs);
    ctx->CSSetUnorderedAccessViews(0, 1, uavs, NULL);
    ctx->CSSetConstantBuffers(0, 1, ks);
    ctx->Dispatch((rw + 15) / 16, (rh + 15) / 16, 1);
    ID3D11ShaderResourceView *no_srv[1] = {NULL};
    ID3D11UnorderedAccessView *no_uav[1] = {NULL};
    ctx->CSSetShaderResources(0, 1, no_srv);
    ctx->CSSetUnorderedAccessViews(0, 1, no_uav, NULL);
    ctx->CSSetShader(NULL, NULL, 0);
    if (long_holds) kept_out = out, kept_uav = uav;
    tex = out;
    td = od;
    whole = 1;
  }
  td.Usage = D3D11_USAGE_STAGING;
  td.BindFlags = 0;
  td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
  td.MiscFlags = 0;
  td.MipLevels = td.ArraySize = 1;
  td.Width = (UINT)rw;
  td.Height = (UINT)rh;
  ComPtr<ID3D11Texture2D> staging;
  D3D11_MAPPED_SUBRESOURCE mp;
  if (long_holds && kept_staging) {
    D3D11_TEXTURE2D_DESC kd;
    kept_staging->GetDesc(&kd);
    if (kd.Width == td.Width && kd.Height == td.Height && kd.Format == td.Format) staging = kept_staging;
    kept_staging.Reset();
  }
  if (!staging && FAILED(dev->CreateTexture2D(&td, NULL, &staging))) {
    tex.Reset(); surface.Reset(); access.Reset(); fr.Reset();
    drop_on_demand();
    return NULL;
  }
  if (whole) {
    ctx->CopyResource(staging.Get(), tex.Get());
  } else {
    D3D11_BOX box = {(UINT)rx, (UINT)ry, 0, (UINT)(rx + rw), (UINT)(ry + rh), 1};
    ctx->CopySubresourceRegion(staging.Get(), 0, 0, 0, 0, tex.Get(), 0, &box);
  }
  take_white = m->hdr ? white : 0.0;
  if (!keep_sessions && !long_holds) {
    tex.Reset();
    {
      ComPtr<ABI::Windows::Foundation::IClosable> c;
      if (surface && SUCCEEDED(surface.As(&c))) c->Close();
      c.Reset();
      if (fr && SUCCEEDED(fr.As(&c))) c->Close();
    }
    surface.Reset();
    access.Reset();
    fr.Reset();
    mon_stop(m);
    nmons = 0;
  }
  if (FAILED(ctx->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &mp))) return NULL;
  *bits = (uint8_t *)mp.pData;
  *pitch = (int)mp.RowPitch;
  QueryPerformanceCounter(&t1);
  take_ms = (t1.QuadPart - t0.QuadPart) * 1000.0 / (double)f.QuadPart;
  return staging.Detach();
}

extern "C" void ps_wgc_trim(void) {
  if (dd_dev && dd_ctx && !long_holds) {
    dd_ctx->ClearState();
    dd_ctx->Flush();
    ComPtr<IDXGIDevice3> d3;
    if (SUCCEEDED(dd_dev.As(&d3))) d3->Trim();
  }
  if (ready > 0 && dev && ctx && !long_holds) {
    ctx->ClearState();
    ctx->Flush();
    ComPtr<IDXGIDevice3> d3;
    if (SUCCEEDED(dev.As(&d3))) d3->Trim();
  }
}

extern "C" void ps_wgc_release(void *taken) {
  ID3D11Texture2D *t = (ID3D11Texture2D *)taken;
  if (!t) return;
  ComPtr<ID3D11Device> d;
  ComPtr<ID3D11DeviceContext> c;
  t->GetDevice(&d);
  d->GetImmediateContext(&c);
  c->Unmap(t, 0);
  if (long_holds && !kept_staging && (d.Get() == dev.Get() || d.Get() == dd_dev.Get())) {
    kept_staging = t;
    t->Release();
    return;
  }
  t->Release();
  c->ClearState();
  c->Flush();
  if (!long_holds) {
    ComPtr<IDXGIDevice3> d3;
    if (SUCCEEDED(d.As(&d3))) d3->Trim();
    if (!keep_sessions) {
      int same_wgc = (d.Get() == dev.Get());
      int same_dd = (d.Get() == dd_dev.Get());
      d3.Reset();
      c.Reset();
      d.Reset();
      if (same_wgc) wgc_teardown();
      else if (same_dd) dd_teardown();
    }
  }
}

extern "C" void ps_wgc_state(char *out, int n) {
  int k = snprintf(out, n, "sessions %d; frames", nmons);
  for (int i = 0; i < nmons && k < n; i++) k += snprintf(out + k, n - k, " %d%s", mons[i].frames, mons[i].hdr ? " hdr" : "");
  if (k < n) snprintf(out + k, n - k, "; hr 0x%08lx; ready %d", (unsigned long)last_hr, ready);
}

// One-shot out-of-process WGC capture (`pinshot.exe --wgc-shot <shm> <ev> <x> <y> <w> <h>`):
// Windows 11's WGC frame pool retains one full 4K surface (~64 MB VRAM) per session/pool creation inside the calling
// process even after IClosable::Close() and full D3D11 device destruction. Running on-demand captures in a short-lived
// helper process that copies the 16-bit-HDR-to-sRGB pixels into shared memory, signals the event, and exits immediately
// lets the OS reclaim 100% of WGC VRAM on exit (0 MB leaked across unlimited captures).
typedef struct {
  int32_t ok;
  int32_t w, h, pitch;
  double take_ms;
  double white;
  int32_t said_half;
  int32_t pad;
} WgcShmHeader;

static int wgc_long_cli(LPWSTR *argv, int argc) {
  int idx = -1;
  for (int i = 1; i + 13 < argc; i++) {
    if (!wcscmp(argv[i], L"--wgc-long")) {
      idx = i;
      break;
    }
  }
  if (idx < 0) return 0;
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  const wchar_t *shm_name = argv[idx + 1];
  const wchar_t *req_name = argv[idx + 2];
  const wchar_t *rsp_name = argv[idx + 3];
  const wchar_t *stop_name = argv[idx + 4];
  DWORD ppid = (DWORD)_wtoi(argv[idx + 5]);
  int mx = _wtoi(argv[idx + 6]);
  int my = _wtoi(argv[idx + 7]);
  int mw = _wtoi(argv[idx + 8]);
  int mh = _wtoi(argv[idx + 9]);
  int rx = _wtoi(argv[idx + 10]);
  int ry = _wtoi(argv[idx + 11]);
  int rw = _wtoi(argv[idx + 12]);
  int rh = _wtoi(argv[idx + 13]);

  HANDLE shm = OpenFileMappingW(FILE_MAP_ALL_ACCESS, FALSE, shm_name);
  HANDLE req = OpenEventW(SYNCHRONIZE, FALSE, req_name);
  HANDLE rsp = OpenEventW(EVENT_MODIFY_STATE, FALSE, rsp_name);
  HANDLE stop = OpenEventW(SYNCHRONIZE, FALSE, stop_name);
  HANDLE parent = ppid ? OpenProcess(SYNCHRONIZE, FALSE, ppid) : NULL;
  WgcShmHeader *hdr = NULL;
  size_t need = sizeof(WgcShmHeader) + (size_t)rw * (size_t)rh * 4;
  if (shm && rw > 0 && rh > 0) hdr = (WgcShmHeader *)MapViewOfFile(shm, FILE_MAP_ALL_ACCESS, 0, 0, need);

  if (hdr && req && rsp && stop) {
    keep_sessions = 0;
    long_holds = 1;
    POINT pt = {mx + mw / 2, my + mh / 2};
    HMONITOR mon = MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST);
    HANDLE waits[3] = {stop, req, parent};
    DWORD nwait = parent ? 3 : 2;
    for (;;) {
      DWORD w = WaitForMultipleObjects(nwait, waits, FALSE, 30000);
      if (w == WAIT_OBJECT_0 + 1) {
        hdr->ok = 0;
        hdr->w = rw;
        hdr->h = rh;
        hdr->pitch = rw * 4;
        uint8_t *bits = NULL;
        int pitch = 0;
        void *taken = ps_wgc_take_part(mon, mw, mh, rx, ry, rw, rh, &bits, &pitch);
        if (taken && bits && pitch >= rw * 4) {
          uint8_t *dst = (uint8_t *)hdr + sizeof(WgcShmHeader);
          size_t row = (size_t)rw * 4;
          if (pitch == (int)row) {
            memcpy(dst, bits, row * (size_t)rh);
          } else {
            for (int r = 0; r < rh; r++) memcpy(dst + (size_t)r * row, bits + (size_t)r * (size_t)pitch, row);
          }
          hdr->take_ms = take_ms;
          hdr->white = take_white;
          hdr->said_half = said_half;
          MemoryBarrier();
          hdr->ok = 1;
        }
        SetEvent(rsp);
        if (taken) ps_wgc_release(taken);
      } else {
        break;
      }
    }
    ps_wgc_long_hold(0);
  }
  if (hdr) UnmapViewOfFile(hdr);
  if (parent) CloseHandle(parent);
  if (stop) CloseHandle(stop);
  if (rsp) CloseHandle(rsp);
  if (req) CloseHandle(req);
  if (shm) CloseHandle(shm);
  LocalFree(argv);
  ExitProcess(0);
}

extern "C" int ps_wgc_shot_cli(void) {
  const wchar_t *cmd = GetCommandLineW();
  if (!cmd || (!wcsstr(cmd, L"--wgc-shot") && !wcsstr(cmd, L"--wgc-long"))) return 0;
  int argc = 0;
  LPWSTR *argv = CommandLineToArgvW(cmd, &argc);
  if (!argv) return 0;
  if (wcsstr(cmd, L"--wgc-long") && wgc_long_cli(argv, argc)) return 1;
  int idx = -1;
  for (int i = 1; i + 6 < argc; i++) {
    if (!wcscmp(argv[i], L"--wgc-shot")) {
      idx = i;
      break;
    }
  }
  if (idx < 0) {
    LocalFree(argv);
    return 0;
  }
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  const wchar_t *shm_name = argv[idx + 1];
  const wchar_t *ev_name = argv[idx + 2];
  int x = _wtoi(argv[idx + 3]);
  int y = _wtoi(argv[idx + 4]);
  int w = _wtoi(argv[idx + 5]);
  int h = _wtoi(argv[idx + 6]);

  HANDLE shm = OpenFileMappingW(FILE_MAP_ALL_ACCESS, FALSE, shm_name);
  HANDLE ev = OpenEventW(EVENT_MODIFY_STATE, FALSE, ev_name);
  WgcShmHeader *hdr = NULL;
  size_t need = sizeof(WgcShmHeader) + (size_t)w * (size_t)h * 4;
  if (shm && w > 0 && h > 0) hdr = (WgcShmHeader *)MapViewOfFile(shm, FILE_MAP_ALL_ACCESS, 0, 0, need);

  if (hdr) {
    hdr->ok = 0;
    hdr->w = w;
    hdr->h = h;
    hdr->pitch = w * 4;
    keep_sessions = 0;
    POINT pt = {x + w / 2, y + h / 2};
    HMONITOR mon = MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST);
    uint8_t *bits = NULL;
    int pitch = 0;
    void *taken = ps_wgc_take_now(mon, w, h, &bits, &pitch);
    if (taken && bits && pitch >= w * 4) {
      uint8_t *dst = (uint8_t *)hdr + sizeof(WgcShmHeader);
      size_t row = (size_t)w * 4;
      if (pitch == (int)row) {
        memcpy(dst, bits, row * (size_t)h);
      } else {
        for (int r = 0; r < h; r++) memcpy(dst + (size_t)r * row, bits + (size_t)r * (size_t)pitch, row);
      }
      hdr->take_ms = take_ms;
      hdr->white = take_white;
      hdr->said_half = said_half;
      MemoryBarrier();
      hdr->ok = 1;
    }
    if (ev) SetEvent(ev);
    if (taken) ps_wgc_release(taken);
    UnmapViewOfFile(hdr);
  } else if (ev) {
    SetEvent(ev);
  }
  if (ev) CloseHandle(ev);
  if (shm) CloseHandle(shm);
  LocalFree(argv);
  ExitProcess(0);
}
