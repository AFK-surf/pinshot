// The screen taken by Windows.Graphics.Capture (the system's own capture: the monitor's picture as DWM composes it, on
// the GPU), where PINSHOT_CAPTURE=wgc asks for it: GDI's BitBlt is platform_win.c's way otherwise (as fast here, and
// this is given no frame while nothing on the screen changes; GDI's taken where none comes in 400 ms). On a device of its own (not the renderer's: the capture's threads use
// it), the frame copied into a staging texture and mapped: its pixels read there (ps_pixel, ps_mean) and handed to
// mbui by their address as BitBlt's are, nothing else copied. A frame pool and a session per capture, closed once the
// frame is there: nothing of the capture's held between captures but the device and the item of each monitor.
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

#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "runtimeobject.lib")

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;
using Microsoft::WRL::Wrappers::HStringReference;
namespace WGC = ABI::Windows::Graphics::Capture;
namespace WD3D = ABI::Windows::Graphics::DirectX::Direct3D11;
using ABI::Windows::Foundation::ITypedEventHandler;

// The device, the WinRT one over it, and the factories: made once (wgc_ready).
static ComPtr<ID3D11Device> dev;
static ComPtr<ID3D11DeviceContext> ctx;
static ComPtr<WD3D::IDirect3DDevice> rt_dev;
static ComPtr<IGraphicsCaptureItemInterop> item_interop;
static ComPtr<WGC::IDirect3D11CaptureFramePoolStatics2> pool_statics;
static int ready = 0;  // 1 made, -1 not to be had here

// The capture under way: its pool, session, the frame come (taken on the pool's thread, handed to the UI thread).
static ComPtr<WGC::IDirect3D11CaptureFramePool> pool;
static ComPtr<WGC::IGraphicsCaptureSession> session;
static EventRegistrationToken arrived_token;
static CRITICAL_SECTION frame_lock;
static ComPtr<WGC::IDirect3D11CaptureFrame> frame_came;
static HWND told_hwnd;
static UINT told_msg;
// how long its parts took, for the log (ps_wgc_timing): begun to started, started to the frame come, copied and mapped
static LARGE_INTEGER t_begin, t_started, t_came, t_mapped;

extern "C" void ps_wgc_timing(double *out) {
  LARGE_INTEGER f;
  QueryPerformanceFrequency(&f);
  double k = 1000.0 / (double)f.QuadPart;
  out[0] = (t_started.QuadPart - t_begin.QuadPart) * k;
  out[1] = (t_came.QuadPart - t_started.QuadPart) * k;
  out[2] = (t_mapped.QuadPart - t_came.QuadPart) * k;
}


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

static void capture_end(void) {
  if (pool) pool->remove_FrameArrived(arrived_token);
  ComPtr<ABI::Windows::Foundation::IClosable> c;
  if (session && SUCCEEDED(session.As(&c))) c->Close();
  if (pool && SUCCEEDED(pool.As(&c))) c->Close();
  session.Reset();
  pool.Reset();
}

// The monitor `mon` (w by h pixels) asked to be taken: its frame comes on the pool's thread, which posts `msg` to `hwnd`
// (then ps_wgc_take on the UI thread). 0 where it cannot be (another under way, nothing of the capture here).
extern "C" int ps_wgc_begin(HMONITOR mon, int w, int h, HWND hwnd, UINT msg) {
  if (!ps_wgc_ready() || pool) return 0;
  QueryPerformanceCounter(&t_begin);
  told_hwnd = hwnd, told_msg = msg;
  ComPtr<WGC::IGraphicsCaptureItem> item;
  if (FAILED(item_interop->CreateForMonitor(mon, IID_PPV_ARGS(&item)))) return 0;
  ABI::Windows::Graphics::SizeInt32 size = {w, h};
  if (FAILED(pool_statics->CreateFreeThreaded(rt_dev.Get(), ABI::Windows::Graphics::DirectX::DirectXPixelFormat_B8G8R8A8UIntNormalized,
                                              1, size, &pool)))
    return 0;
  auto arrived = Callback<ITypedEventHandler<WGC::Direct3D11CaptureFramePool *, IInspectable *>>(
      [](WGC::IDirect3D11CaptureFramePool *sender, IInspectable *) -> HRESULT {
        ComPtr<WGC::IDirect3D11CaptureFrame> f;
        if (SUCCEEDED(sender->TryGetNextFrame(&f)) && f) {
          EnterCriticalSection(&frame_lock);
          int first = !frame_came;
          if (first) frame_came = f, QueryPerformanceCounter(&t_came);
          LeaveCriticalSection(&frame_lock);
          if (first) PostMessageW(told_hwnd, told_msg, 1, 0);
        }
        return S_OK;
      });
  pool->add_FrameArrived(arrived.Get(), &arrived_token);
  if (FAILED(pool->CreateCaptureSession(item.Get(), &session))) {
    capture_end();
    return 0;
  }
  // (no pointer in the picture, no yellow frame round the screen while it is taken)
  ComPtr<WGC::IGraphicsCaptureSession2> s2;
  if (SUCCEEDED(session.As(&s2))) s2->put_IsCursorCaptureEnabled(FALSE);
  ComPtr<WGC::IGraphicsCaptureSession3> s3;
  if (SUCCEEDED(session.As(&s3))) s3->put_IsBorderRequired(FALSE);
  if (FAILED(session->StartCapture())) {
    capture_end();
    return 0;
  }
  QueryPerformanceCounter(&t_started);
  return 1;
}

// The frame come (the UI thread's, as told): copied off the pool into a staging texture of its own and mapped; the
// capture closed. The texture (an opaque handle, ps_wgc_release lets it go) and where its pixels are (rows `pitch`
// bytes apart), or NULL where no frame is there.
extern "C" void *ps_wgc_take(uint8_t **bits, int *w, int *h, int *pitch) {
  ComPtr<WGC::IDirect3D11CaptureFrame> f;
  EnterCriticalSection(&frame_lock);
  f = frame_came;
  frame_came.Reset();
  LeaveCriticalSection(&frame_lock);
  ID3D11Texture2D *kept = NULL;
  if (f) {
    ComPtr<WD3D::IDirect3DSurface> surface;
    ComPtr<Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess> access;
    ComPtr<ID3D11Texture2D> tex;
    if (SUCCEEDED(f->get_Surface(&surface)) && SUCCEEDED(surface.As(&access)) &&
        SUCCEEDED(access->GetInterface(IID_PPV_ARGS(&tex)))) {
      D3D11_TEXTURE2D_DESC td;
      tex->GetDesc(&td);
      td.Usage = D3D11_USAGE_STAGING;
      td.BindFlags = 0;
      td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
      td.MiscFlags = 0;
      td.MipLevels = td.ArraySize = 1;
      ComPtr<ID3D11Texture2D> staging;
      D3D11_MAPPED_SUBRESOURCE m;
      if (SUCCEEDED(dev->CreateTexture2D(&td, NULL, &staging))) {
        ctx->CopyResource(staging.Get(), tex.Get());
        if (SUCCEEDED(ctx->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &m))) {
          *bits = (uint8_t *)m.pData;
          *pitch = (int)m.RowPitch;
          *w = (int)td.Width;
          *h = (int)td.Height;
          kept = staging.Detach();
          QueryPerformanceCounter(&t_mapped);
        }
      }
    }
    ComPtr<ABI::Windows::Foundation::IClosable> c;
    if (SUCCEEDED(f.As(&c))) c->Close();
  }
  capture_end();
  return kept;
}

// A picture taken let go (its staging texture, unmapped).
extern "C" void ps_wgc_release(void *taken) {
  ID3D11Texture2D *t = (ID3D11Texture2D *)taken;
  if (!t) return;
  ctx->Unmap(t, 0);
  t->Release();
}

// A capture called off before its frame came.
extern "C" void ps_wgc_cancel(void) {
  EnterCriticalSection(&frame_lock);
  frame_came.Reset();
  LeaveCriticalSection(&frame_lock);
  capture_end();
}
