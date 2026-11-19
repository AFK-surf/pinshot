// The screen kept by Windows.Graphics.Capture (the system's own capture: each monitor's picture as DWM composes it, on
// the GPU), always on (the user, 2026-11-17: 「常驻截屏 + 不还内存」, its cost measured and taken: a few 4K frames of
// video memory, DWM's copy of each frame that changes on the 3D engine). Each monitor has a session of its own, its
// pool of two frames; the frame that came last is held (one reference, nothing copied as frames come), so as the
// shortcut is pressed the picture of that moment is already there: copied off into a staging texture and mapped on
// the UI thread (a few ms), its pixels read there and handed to mbui by their address as GDI's are. The system gives
// no frame while nothing on a monitor changes: a session that has had none yet leaves it to GDI's BitBlt
// (platform_win.c). Sessions made again as the monitors change (WM_DISPLAYCHANGE: ps_wgc_restart).
//
// A monitor in HDR: what DWM composes is scRGB (1.0 = 80 nits), each SDR window's colours brought up to the SDR white
// the user set (276 nits here: 3.45 times). Its 8-bit frames are not brought back down for what an HDR-aware window
// drew (WeChat's picture viewer: a dark grey came out 3.45 times as bright, 2026-11-17), so there the frames are
// 16-bit floats, and the one taken is brought down by the monitor's SDR white and put back in sRGB on the GPU (a
// compute shader) before it is read: SDR windows exactly as they were, HDR ones as they look, what is brighter than
// SDR white clipped.
#include <windows.h>
#include <d3d11.h>
#include <dxgi1_3.h>
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
#include <d3dcompiler.h>
#include <windows.security.authorization.appcapabilityaccess.h>

#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "runtimeobject.lib")
#pragma comment(lib, "d3dcompiler.lib")

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;
using Microsoft::WRL::Wrappers::HStringReference;
namespace WGC = ABI::Windows::Graphics::Capture;
namespace WD3D = ABI::Windows::Graphics::DirectX::Direct3D11;
using ABI::Windows::Foundation::ITypedEventHandler;

// The device, the WinRT one over it, and the factories: made once (ps_wgc_ready).
static ComPtr<ID3D11Device> dev;
static ComPtr<ID3D11DeviceContext> ctx;
static ComPtr<WD3D::IDirect3DDevice> rt_dev;
static ComPtr<IGraphicsCaptureItemInterop> item_interop;
static ComPtr<WGC::IDirect3D11CaptureFramePoolStatics2> pool_statics;
static ComPtr<ID3D11ComputeShader> to_srgb;  // an HDR frame brought down to sRGB (made with the device)
static ComPtr<ID3D11Buffer> to_srgb_k;
static int ready = 0;  // 1 made, -1 not to be had here
static CRITICAL_SECTION frame_lock;

// A monitor's session: its pool, the frame that came last (under frame_lock), its size.
#define MONS_MOST 8
struct Mon {
  HMONITOR mon;
  int w, h;
  ComPtr<WGC::IDirect3D11CaptureFramePool> pool;
  ComPtr<WGC::IGraphicsCaptureSession> session;
  EventRegistrationToken token;
  ComPtr<WGC::IDirect3D11CaptureFrame> last;
  int frames;  // how many came
  int hdr;      // its frames 16-bit floats (the monitor in HDR as its session was made)
  LONGLONG last_at;  // when the last one came (QueryPerformanceCounter, under frame_lock)
};
// Set as any frame comes (a session made again waited on for its first: ps_wgc_take_now).
static HANDLE frame_came;
static Mon mons[MONS_MOST];
static int nmons;
static HRESULT last_hr;  // what the last step that failed said (ps_wgc_state)
static double take_ms;
static int said_half;  // the last HDR frame taken was copied first (the shader could not read it where it was)
static double take_white;  // the SDR white the last one taken was brought down by (0: not HDR)

static double take_age;  // how old the frame taken was, in seconds
static int take_fresh;  // its session was made again as it was taken (its last frame too old to trust)
// 1: keep each monitor's WGC session open in the background (default); 0: open a session on demand for one frame and
// close it right after (saving ~245 MB of idle video memory on 4K HDR while still capturing 16-bit HDR frames).
static int keep_sessions = 1;

extern "C" void ps_wgc_timing(double *out) {
  out[0] = take_ms, out[1] = take_white, out[2] = said_half, out[3] = take_age, out[4] = take_fresh;
}

extern "C" int ps_wgc_ready(void) {
  if (ready) return ready > 0;
  ready = -1;
  static int lock_made;
  if (!lock_made) {
    InitializeCriticalSection(&frame_lock);
    frame_came = CreateEventW(NULL, FALSE, FALSE, NULL);
    lock_made = 1;
  }
  // (the window's thread has COM already, OLE's: then this says so and changes nothing; a bench's has none)
  RoInitialize(RO_INIT_SINGLETHREADED);
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
  // (the shader: scRGB over the SDR white back to sRGB, its bytes in BGRA order as GDI's are)
  static const char hlsl[] =
      "Texture2D<float4> src : register(t0);"
      "RWTexture2D<unorm float4> dst : register(u0);"
      "cbuffer K : register(b0) { float inv_white; float3 pad; };"
      "float enc(float v) { v = saturate(v); return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1.0 / 2.4) - 0.055; }"
      "[numthreads(16, 16, 1)] void main(uint3 id : SV_DispatchThreadID) {"
      "  uint w, h; src.GetDimensions(w, h); if (id.x >= w || id.y >= h) return;"
      "  float3 c = src[id.xy].rgb * inv_white;"
      "  dst[id.xy] = float4(enc(c.b), enc(c.g), enc(c.r), 1.0); }";
  ComPtr<ID3DBlob> code, errs;
  if (SUCCEEDED(D3DCompile(hlsl, sizeof hlsl - 1, "to_srgb", NULL, NULL, "main", "cs_5_0", D3DCOMPILE_OPTIMIZATION_LEVEL3, 0,
                           &code, &errs)))
    dev->CreateComputeShader(code->GetBufferPointer(), code->GetBufferSize(), NULL, &to_srgb);
  D3D11_BUFFER_DESC bd = {16, D3D11_USAGE_DYNAMIC, D3D11_BIND_CONSTANT_BUFFER, D3D11_CPU_ACCESS_WRITE, 0, 0};
  dev->CreateBuffer(&bd, NULL, &to_srgb_k);
  ready = 1;
  return 1;
}

// Whether monitor `mon` is in HDR now, and its SDR white (1.0: 80 nits) in `white`.
static int mon_hdr(HMONITOR mon, float *white) {
  *white = 1.0f;
  MONITORINFOEXW mi;
  mi.cbSize = sizeof mi;
  if (!GetMonitorInfoW(mon, &mi)) return 0;
  UINT32 np = 0, nm = 0;
  if (GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &np, &nm) != ERROR_SUCCESS || !np) return 0;
  DISPLAYCONFIG_PATH_INFO paths[16];
  DISPLAYCONFIG_MODE_INFO modes[32];
  if (np > 16) np = 16;
  if (nm > 32) nm = 32;
  if (QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &np, paths, &nm, modes, NULL) != ERROR_SUCCESS) return 0;
  for (UINT32 i = 0; i < np; i++) {
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
    if (DisplayConfigGetDeviceInfo(&ai.header) != ERROR_SUCCESS || !ai.advancedColorEnabled) return 0;
    DISPLAYCONFIG_SDR_WHITE_LEVEL wl = {};
    wl.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_SDR_WHITE_LEVEL;
    wl.header.size = sizeof wl;
    wl.header.adapterId = paths[i].targetInfo.adapterId;
    wl.header.id = paths[i].targetInfo.id;
    if (DisplayConfigGetDeviceInfo(&wl.header) == ERROR_SUCCESS && wl.SDRWhiteLevel >= 1000)
      *white = (float)wl.SDRWhiteLevel / 1000.0f;
    // (a monitor asleep or turned off at its button says 80 nits, its white unknown: the last it said awake kept;
    // ScreenReplay found the same, 2026-11-15)
    // Kept on disk too (%APPDATA%\PinShot\sdr-white.txt): a run started while the monitor sleeps has it.
    static float last_white = -1;
    wchar_t path[MAX_PATH];
    DWORD n = GetEnvironmentVariableW(L"APPDATA", path, MAX_PATH);
    int have_path = n > 0 && n < MAX_PATH - 40;
    if (have_path) wcscat_s(path, MAX_PATH, L"\\PinShot\\sdr-white.txt");
    if (last_white < 0) {
      last_white = 0;
      FILE *f = NULL;
      if (have_path && _wfopen_s(&f, path, L"r") == 0 && f) {
        if (fscanf_s(f, "%f", &last_white) != 1) last_white = 0;
        fclose(f);
      }
    }
    if (*white > 1.001f) {
      if (*white != last_white && have_path) {
        FILE *f = NULL;
        if (_wfopen_s(&f, path, L"w") == 0 && f) {
          fprintf(f, "%.3f\n", *white);
          fclose(f);
        }
      }
      last_white = *white;
    } else if (last_white > 1.001f) {
      *white = last_white;
    }
    return 1;
  }
  return 0;
}

static void mon_stop(Mon *m) {
  if (m->pool) m->pool->remove_FrameArrived(m->token);
  ComPtr<ABI::Windows::Foundation::IClosable> c;
  EnterCriticalSection(&frame_lock);
  if (m->last && SUCCEEDED(m->last.As(&c))) c->Close();
  m->last.Reset();
  LeaveCriticalSection(&frame_lock);
  if (m->session && SUCCEEDED(m->session.As(&c))) c->Close();
  if (m->pool && SUCCEEDED(m->pool.As(&c))) c->Close();
  m->session.Reset();
  m->pool.Reset();
  m->mon = NULL;
  m->frames = 0;
  m->hdr = 0;
}

static int mon_start(Mon *m, HMONITOR mon, int w, int h) {
  float white;
  m->mon = mon, m->w = w, m->h = h, m->frames = 0;
  m->hdr = to_srgb && to_srgb_k && mon_hdr(mon, &white);
  ComPtr<WGC::IGraphicsCaptureItem> item;
  if (FAILED(last_hr = item_interop->CreateForMonitor(mon, IID_PPV_ARGS(&item)))) return 0;
  ABI::Windows::Graphics::SizeInt32 size = {w, h};
  if (FAILED(last_hr = pool_statics->CreateFreeThreaded(
                     rt_dev.Get(),
                     m->hdr ? ABI::Windows::Graphics::DirectX::DirectXPixelFormat_R16G16B16A16Float
                            : ABI::Windows::Graphics::DirectX::DirectXPixelFormat_B8G8R8A8UIntNormalized,
                     2, size, &m->pool)))
    return 0;
  // (agile, as a free-threaded pool's handler must be: called on its threads, not the one that made it)
  auto arrived = Callback<Microsoft::WRL::Implements<Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::ClassicCom>,
                                                     ITypedEventHandler<WGC::Direct3D11CaptureFramePool *, IInspectable *>,
                                                     Microsoft::WRL::FtmBase>>(
      [m](WGC::IDirect3D11CaptureFramePool *sender, IInspectable *) -> HRESULT {
        ComPtr<WGC::IDirect3D11CaptureFrame> f;
        if (SUCCEEDED(sender->TryGetNextFrame(&f)) && f) {
          ComPtr<WGC::IDirect3D11CaptureFrame> old;
          EnterCriticalSection(&frame_lock);
          old = m->last;
          m->last = f;
          m->frames++;
          LARGE_INTEGER now;
          QueryPerformanceCounter(&now);
          m->last_at = now.QuadPart;
          LeaveCriticalSection(&frame_lock);
          SetEvent(frame_came);
          // (the one before back to the pool: two in it, one held, one for the next)
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
  // (no pointer in the picture, no yellow frame round the screen while it is kept)
  ComPtr<WGC::IGraphicsCaptureSession2> s2;
  if (SUCCEEDED(m->session.As(&s2))) s2->put_IsCursorCaptureEnabled(FALSE);
  // (kept only with no border: a yellow frame round the screen all the time is not to be had; where Windows draws
  // it anyway (Windows 10, or the person said no), no session, GDI's each time)
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

// A package's run may keep the screen without the border only once Windows says so
// (GraphicsCaptureAccess.RequestAccessAsync(Borderless): the manifest's graphicsCaptureWithoutBorder, Windows asking
// the person where it asks): asked once, without waiting; the sessions made again once it is answered
// (ps_wgc_wake). 1 allowed, 0 not, -1 not asked, -2 being asked. A run not a package's: allowed.
extern "C" int ps_packaged(void);
extern "C" void ps_wgc_wake(void);
static volatile LONG borderless = -1;

static int borderless_allowed(void) {
  if (!ps_packaged()) return 1;
  if (borderless >= 0) return borderless;
  if (InterlockedCompareExchange(&borderless, -2, -1) != -1) return 0;
  ComPtr<WGC::IGraphicsCaptureAccessStatics> statics;
  ComPtr<ABI::Windows::Foundation::IAsyncOperation<ABI::Windows::Security::Authorization::AppCapabilityAccess::AppCapabilityAccessStatus>> op;
  if (FAILED(RoGetActivationFactory(HStringReference(RuntimeClass_Windows_Graphics_Capture_GraphicsCaptureAccess).Get(),
                                    IID_PPV_ARGS(&statics))) ||
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

// Every monitor's session (made again: the monitors changed). How many there are.
extern "C" int ps_wgc_restart(void) {
  for (int i = 0; i < nmons; i++) mon_stop(&mons[i]);
  nmons = 0;
  if (!keep_sessions) return 0;
  if (!ps_wgc_ready()) return 0;
  if (!borderless_allowed()) return 0;
  EnumDisplayMonitors(NULL, NULL, mon_found, 0);
  return nmons;
}

extern "C" void ps_wgc_set_keep(int keep) {
  keep = keep ? 1 : 0;
  keep_sessions = keep;
  if (keep) {
    if (nmons == 0) ps_wgc_restart();
  } else {
    for (int i = 0; i < nmons; i++) mon_stop(&mons[i]);
    nmons = 0;
    if (ready > 0 && dev && ctx) {
      ctx->ClearState();
      ctx->Flush();
      ComPtr<IDXGIDevice3> d3;
      if (SUCCEEDED(dev.As(&d3))) d3->Trim();
    }
  }
}

// The device gone (the driver reset or updated, the GPU lost: its sessions give no frame again and their last stays
// as it was): everything made again from the device up, at the tray window (ps_wgc_wake).
static void device_lost(void) {
  for (int i = 0; i < nmons; i++) mon_stop(&mons[i]);
  nmons = 0;
  to_srgb.Reset(), to_srgb_k.Reset(), pool_statics.Reset(), item_interop.Reset(), rt_dev.Reset(), ctx.Reset(), dev.Reset();
  ready = 0;
  ps_wgc_wake();
}

// A frame older than this is not trusted (seconds): its session made again first and its first frame waited for.
// The system gives none while the screen does not change, but a session can also stop for good with its last frame
// kept (2026-11-18: the monitor asleep overnight, every capture in the morning the screen of the night before).
#define FRAME_TRUSTED_S 5.0
#define FIRST_FRAME_MS 250

// The picture of monitor `mon` (w by h) as it is now: its last frame copied into a staging texture and mapped. The
// texture (an opaque handle, ps_wgc_release lets it go) and where its pixels are (rows `pitch` bytes apart); NULL
// where its session has had no frame yet, or is of another size.
extern "C" void *ps_wgc_take_now(HMONITOR mon, int w, int h, uint8_t **bits, int *pitch) {
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
  if (!m || m->w != w || m->h != h) return NULL;
  // (HDR turned on or off since its session was made: made again in the other format)
  float white = 1.0f;
  int hdr = to_srgb && to_srgb_k && mon_hdr(mon, &white);
  if (m->pool && hdr != m->hdr) {
    mon_stop(m);
    m->mon = mon, m->w = w, m->h = h;
  }
  ComPtr<WGC::IDirect3D11CaptureFrame> fr;
  EnterCriticalSection(&frame_lock);
  fr = m->last;
  LONGLONG at = m->last_at;
  LeaveCriticalSection(&frame_lock);
  take_fresh = 0;
  // (PINSHOT_FRAME_TRUSTED_S: another limit, for a test)
  static double trusted = -1;
  if (trusted < 0) {
    const char *e = getenv("PINSHOT_FRAME_TRUSTED_S");
    trusted = e ? atof(e) : FRAME_TRUSTED_S;
  }
  double age = fr ? (t0.QuadPart - at) / (double)f.QuadPart : 1e9;
  if (age > trusted) {
    // (made again, its first frame waited for: the system gives one as a session starts)
    fr.Reset();
    mon_stop(m);
    ResetEvent(frame_came);
    if (!mon_start(m, mon, w, h)) return NULL;
    take_fresh = 1;
    for (;;) {
      EnterCriticalSection(&frame_lock);
      fr = m->last;
      at = m->last_at;
      LeaveCriticalSection(&frame_lock);
      if (fr) break;
      LARGE_INTEGER now;
      QueryPerformanceCounter(&now);
      double left = FIRST_FRAME_MS - (now.QuadPart - t0.QuadPart) * 1000.0 / (double)f.QuadPart;
      if (left <= 0) {
        if (!keep_sessions) {
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
  take_age = age;
  if (!fr) return NULL;
  ComPtr<WD3D::IDirect3DSurface> surface;
  ComPtr<Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess> access;
  ComPtr<ID3D11Texture2D> tex;
  if (FAILED(fr->get_Surface(&surface)) || FAILED(surface.As(&access)) || FAILED(access->GetInterface(IID_PPV_ARGS(&tex))))
    return NULL;
  D3D11_TEXTURE2D_DESC td;
  tex->GetDesc(&td);
  if ((int)td.Width != w || (int)td.Height != h) return NULL;
  said_half = 0;
  if (m->hdr) {
    // (brought down to sRGB first: read where the shader can, written into a texture of 8-bit RGBA whose bytes are
    // BGRA's)
    ComPtr<ID3D11ShaderResourceView> srv;
    ComPtr<ID3D11Texture2D> half;
    if (FAILED(dev->CreateShaderResourceView(tex.Get(), NULL, &srv))) {
      D3D11_TEXTURE2D_DESC hd = td;
      hd.Usage = D3D11_USAGE_DEFAULT;
      hd.BindFlags = D3D11_BIND_SHADER_RESOURCE;
      hd.CPUAccessFlags = 0;
      hd.MiscFlags = 0;
      hd.MipLevels = hd.ArraySize = 1;
      said_half = 1;
      if (FAILED(dev->CreateTexture2D(&hd, NULL, &half))) return NULL;
      ctx->CopyResource(half.Get(), tex.Get());
      if (FAILED(dev->CreateShaderResourceView(half.Get(), NULL, &srv))) return NULL;
    }
    D3D11_TEXTURE2D_DESC od = td;
    od.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    od.Usage = D3D11_USAGE_DEFAULT;
    od.BindFlags = D3D11_BIND_UNORDERED_ACCESS;
    od.CPUAccessFlags = 0;
    od.MiscFlags = 0;
    od.MipLevels = od.ArraySize = 1;
    ComPtr<ID3D11Texture2D> out;
    ComPtr<ID3D11UnorderedAccessView> uav;
    if (FAILED(dev->CreateTexture2D(&od, NULL, &out)) || FAILED(dev->CreateUnorderedAccessView(out.Get(), NULL, &uav)))
      return NULL;
    D3D11_MAPPED_SUBRESOURCE kp;
    if (FAILED(ctx->Map(to_srgb_k.Get(), 0, D3D11_MAP_WRITE_DISCARD, 0, &kp))) return NULL;
    float k[4] = {1.0f / white, 0, 0, 0};
    memcpy(kp.pData, k, sizeof k);
    ctx->Unmap(to_srgb_k.Get(), 0);
    ID3D11ShaderResourceView *srvs[1] = {srv.Get()};
    ID3D11UnorderedAccessView *uavs[1] = {uav.Get()};
    ID3D11Buffer *ks[1] = {to_srgb_k.Get()};
    ctx->CSSetShader(to_srgb.Get(), NULL, 0);
    ctx->CSSetShaderResources(0, 1, srvs);
    ctx->CSSetUnorderedAccessViews(0, 1, uavs, NULL);
    ctx->CSSetConstantBuffers(0, 1, ks);
    ctx->Dispatch((w + 15) / 16, (h + 15) / 16, 1);
    ID3D11ShaderResourceView *no_srv[1] = {NULL};
    ID3D11UnorderedAccessView *no_uav[1] = {NULL};
    ctx->CSSetShaderResources(0, 1, no_srv);
    ctx->CSSetUnorderedAccessViews(0, 1, no_uav, NULL);
    ctx->CSSetShader(NULL, NULL, 0);
    tex = out;
    td = od;
  }
  td.Usage = D3D11_USAGE_STAGING;
  td.BindFlags = 0;
  td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
  td.MiscFlags = 0;
  td.MipLevels = td.ArraySize = 1;
  ComPtr<ID3D11Texture2D> staging;
  D3D11_MAPPED_SUBRESOURCE mp;
  if (FAILED(dev->CreateTexture2D(&td, NULL, &staging))) {
    if (!keep_sessions) {
      mon_stop(m);
      nmons = 0;
    }
    return NULL;
  }
  ctx->CopyResource(staging.Get(), tex.Get());
  take_white = m->hdr ? white : 0.0;
  if (!keep_sessions) {
    tex.Reset();
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

// A picture taken let go (its staging texture, unmapped), and what the device keeps of it and of the textures it was
// brought down through given back now (D3D11 frees a released texture's memory only as its work is flushed, and the
// driver keeps what it freed for the next until told to trim).
extern "C" void ps_wgc_release(void *taken) {
  ID3D11Texture2D *t = (ID3D11Texture2D *)taken;
  if (!t) return;
  // (its own device's: the one now may have been made again since, device_lost)
  ComPtr<ID3D11Device> d;
  ComPtr<ID3D11DeviceContext> c;
  t->GetDevice(&d);
  d->GetImmediateContext(&c);
  c->Unmap(t, 0);
  t->Release();
  c->ClearState();
  c->Flush();
  if (!keep_sessions) {
    ComPtr<IDXGIDevice3> d3;
    if (SUCCEEDED(d.As(&d3))) d3->Trim();
  }
}

// How the captures stand, for the log: "sessions N; frames A B...; hr 0x..".
extern "C" void ps_wgc_state(char *out, int n) {
  int k = snprintf(out, n, "sessions %d; frames", nmons);
  for (int i = 0; i < nmons && k < n; i++) k += snprintf(out + k, n - k, " %d%s", mons[i].frames, mons[i].hdr ? " hdr" : "");
  if (k < n) snprintf(out + k, n - k, "; hr 0x%08lx; ready %d", (unsigned long)last_hr, ready);
}
