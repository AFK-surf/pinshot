// The screen kept by Windows.Graphics.Capture (the system's own capture: each monitor's picture as DWM composes it, on
// the GPU), always on (the user, 2026-11-17: 「常驻截屏 + 不还内存」, its cost measured and taken: a few 4K frames of
// video memory, DWM's copy of each frame that changes on the 3D engine). Each monitor has a session of its own, its
// pool of two frames; the frame that came last is held (one reference, nothing copied as frames come), so as the
// shortcut is pressed the picture of that moment is already there: copied off into a staging texture and mapped on
// the UI thread (a few ms), its pixels read there and handed to mbui by their address as GDI's are. The system gives
// no frame while nothing on a monitor changes: a session that has had none yet leaves it to GDI's BitBlt
// (platform_win.c). Sessions made again as the monitors change (WM_DISPLAYCHANGE: ps_wgc_restart).
#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
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

#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "runtimeobject.lib")

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
};
static Mon mons[MONS_MOST];
static int nmons;
static HRESULT last_hr;  // what the last step that failed said (ps_wgc_state)
static double take_ms;

extern "C" void ps_wgc_timing(double *out) { out[0] = take_ms; }

extern "C" int ps_wgc_ready(void) {
  if (ready) return ready > 0;
  ready = -1;
  InitializeCriticalSection(&frame_lock);
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
  ready = 1;
  return 1;
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
}

static int mon_start(Mon *m, HMONITOR mon, int w, int h) {
  m->mon = mon, m->w = w, m->h = h, m->frames = 0;
  ComPtr<WGC::IGraphicsCaptureItem> item;
  if (FAILED(last_hr = item_interop->CreateForMonitor(mon, IID_PPV_ARGS(&item)))) return 0;
  ABI::Windows::Graphics::SizeInt32 size = {w, h};
  if (FAILED(last_hr = pool_statics->CreateFreeThreaded(rt_dev.Get(), ABI::Windows::Graphics::DirectX::DirectXPixelFormat_B8G8R8A8UIntNormalized,
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
          LeaveCriticalSection(&frame_lock);
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
  ComPtr<WGC::IGraphicsCaptureSession3> s3;
  if (SUCCEEDED(m->session.As(&s3))) {
    HRESULT hr = s3->put_IsBorderRequired(FALSE);
    if (FAILED(hr)) last_hr = hr;
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

// Every monitor's session (made again: the monitors changed). How many there are.
extern "C" int ps_wgc_restart(void) {
  for (int i = 0; i < nmons; i++) mon_stop(&mons[i]);
  nmons = 0;
  if (!ps_wgc_ready()) return 0;
  EnumDisplayMonitors(NULL, NULL, mon_found, 0);
  return nmons;
}

// The picture of monitor `mon` (w by h) as it is now: its last frame copied into a staging texture and mapped. The
// texture (an opaque handle, ps_wgc_release lets it go) and where its pixels are (rows `pitch` bytes apart); NULL
// where its session has had no frame yet, or is of another size.
extern "C" void *ps_wgc_take_now(HMONITOR mon, int w, int h, uint8_t **bits, int *pitch) {
  LARGE_INTEGER t0, t1, f;
  QueryPerformanceCounter(&t0);
  Mon *m = NULL;
  for (int i = 0; i < nmons; i++)
    if (mons[i].mon == mon) m = &mons[i];
  if (!m || m->w != w || m->h != h) return NULL;
  ComPtr<WGC::IDirect3D11CaptureFrame> fr;
  EnterCriticalSection(&frame_lock);
  fr = m->last;
  LeaveCriticalSection(&frame_lock);
  if (!fr) return NULL;
  ComPtr<WD3D::IDirect3DSurface> surface;
  ComPtr<Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess> access;
  ComPtr<ID3D11Texture2D> tex;
  if (FAILED(fr->get_Surface(&surface)) || FAILED(surface.As(&access)) || FAILED(access->GetInterface(IID_PPV_ARGS(&tex))))
    return NULL;
  D3D11_TEXTURE2D_DESC td;
  tex->GetDesc(&td);
  if ((int)td.Width != w || (int)td.Height != h) return NULL;
  td.Usage = D3D11_USAGE_STAGING;
  td.BindFlags = 0;
  td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
  td.MiscFlags = 0;
  td.MipLevels = td.ArraySize = 1;
  ComPtr<ID3D11Texture2D> staging;
  D3D11_MAPPED_SUBRESOURCE mp;
  if (FAILED(dev->CreateTexture2D(&td, NULL, &staging))) return NULL;
  ctx->CopyResource(staging.Get(), tex.Get());
  if (FAILED(ctx->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &mp))) return NULL;
  *bits = (uint8_t *)mp.pData;
  *pitch = (int)mp.RowPitch;
  QueryPerformanceCounter(&t1);
  QueryPerformanceFrequency(&f);
  take_ms = (t1.QuadPart - t0.QuadPart) * 1000.0 / (double)f.QuadPart;
  return staging.Detach();
}

// A picture taken let go (its staging texture, unmapped).
extern "C" void ps_wgc_release(void *taken) {
  ID3D11Texture2D *t = (ID3D11Texture2D *)taken;
  if (!t) return;
  ctx->Unmap(t, 0);
  t->Release();
}

// How the captures stand, for the log: "sessions N, frames A B..., hr 0x..".
extern "C" void ps_wgc_state(char *out, int n) {
  int k = snprintf(out, n, "sessions %d, frames", nmons);
  for (int i = 0; i < nmons && k < n; i++) k += snprintf(out + k, n - k, " %d", mons[i].frames);
  if (k < n) snprintf(out + k, n - k, ", hr 0x%08lx, ready %d", (unsigned long)last_hr, ready);
}
