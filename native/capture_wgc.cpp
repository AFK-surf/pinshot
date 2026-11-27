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
#include <math.h>
#include <windows.security.authorization.appcapabilityaccess.h>

#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "runtimeobject.lib")

// Precompiled cs_5_0 bytecodes (fxc /T cs_5_0 /O3 /E main) so HDR capture never loads d3dcompiler_47.dll at runtime.
// Pass 1 (hdr_tile_max_bc): 8x8 tile max (R32_FLOAT), has_hdr flag, and 64-bit per-pixel HDR bitmask (R32G32_UINT).
// Pass 2 (to_srgb_bc): negative gamut clamp + 1-pixel masked per-island Extended Reinhard (peak_map, pixel_mask) + sRGB.
static const uint8_t hdr_tile_max_bc[] = { // 3212 bytes
  68,88,66,67,223,231,202,57,120,107,126,170,16,103,235,101,169,113,109,161,1,0,0,0,
  140,12,0,0,5,0,0,0,52,0,0,0,168,3,0,0,184,3,0,0,200,3,0,0,
  240,11,0,0,82,68,69,70,108,3,0,0,2,0,0,0,0,1,0,0,5,0,0,0,
  60,0,0,0,0,5,83,67,0,129,0,0,68,3,0,0,82,68,49,49,60,0,0,0,
  24,0,0,0,32,0,0,0,40,0,0,0,36,0,0,0,12,0,0,0,0,0,0,0,
  220,0,0,0,2,0,0,0,5,0,0,0,4,0,0,0,255,255,255,255,0,0,0,0,
  1,0,0,0,13,0,0,0,224,0,0,0,4,0,0,0,5,0,0,0,4,0,0,0,
  255,255,255,255,0,0,0,0,1,0,0,0,1,0,0,0,233,0,0,0,6,0,0,0,
  6,0,0,0,1,0,0,0,4,0,0,0,1,0,0,0,1,0,0,0,1,0,0,0,
  241,0,0,0,4,0,0,0,4,0,0,0,4,0,0,0,255,255,255,255,2,0,0,0,
  1,0,0,0,5,0,0,0,251,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
  0,0,0,0,0,0,0,0,1,0,0,0,1,0,0,0,115,114,99,0,116,105,108,101,
  95,109,97,120,0,104,97,115,95,104,100,114,0,116,105,108,101,95,109,97,115,107,0,75,
  0,171,171,171,251,0,0,0,8,0,0,0,48,1,0,0,32,0,0,0,0,0,0,0,
  0,0,0,0,233,0,0,0,1,0,0,0,236,2,0,0,4,0,0,0,0,0,0,0,
  3,0,0,0,112,2,0,0,0,0,0,0,4,0,0,0,2,0,0,0,128,2,0,0,
  0,0,0,0,255,255,255,255,0,0,0,0,255,255,255,255,0,0,0,0,164,2,0,0,
  4,0,0,0,4,0,0,0,2,0,0,0,176,2,0,0,0,0,0,0,255,255,255,255,
  0,0,0,0,255,255,255,255,0,0,0,0,212,2,0,0,8,0,0,0,4,0,0,0,
  2,0,0,0,176,2,0,0,0,0,0,0,255,255,255,255,0,0,0,0,255,255,255,255,
  0,0,0,0,215,2,0,0,12,0,0,0,4,0,0,0,2,0,0,0,176,2,0,0,
  0,0,0,0,255,255,255,255,0,0,0,0,255,255,255,255,0,0,0,0,217,2,0,0,
  16,0,0,0,4,0,0,0,2,0,0,0,176,2,0,0,0,0,0,0,255,255,255,255,
  0,0,0,0,255,255,255,255,0,0,0,0,219,2,0,0,20,0,0,0,4,0,0,0,
  0,0,0,0,176,2,0,0,0,0,0,0,255,255,255,255,0,0,0,0,255,255,255,255,
  0,0,0,0,224,2,0,0,24,0,0,0,4,0,0,0,0,0,0,0,176,2,0,0,
  0,0,0,0,255,255,255,255,0,0,0,0,255,255,255,255,0,0,0,0,229,2,0,0,
  28,0,0,0,4,0,0,0,0,0,0,0,176,2,0,0,0,0,0,0,255,255,255,255,
  0,0,0,0,255,255,255,255,0,0,0,0,105,110,118,95,119,104,105,116,101,0,102,108,
  111,97,116,0,0,0,3,0,1,0,1,0,0,0,0,0,0,0,0,0,0,0,0,0,
  0,0,0,0,0,0,0,0,0,0,0,0,122,2,0,0,111,120,0,100,119,111,114,100,
  0,171,171,171,0,0,19,0,1,0,1,0,0,0,0,0,0,0,0,0,0,0,0,0,
  0,0,0,0,0,0,0,0,0,0,0,0,167,2,0,0,111,121,0,119,0,104,0,112,
  97,100,48,0,112,97,100,49,0,112,97,100,50,0,171,171,20,3,0,0,0,0,0,0,
  4,0,0,0,2,0,0,0,32,3,0,0,0,0,0,0,255,255,255,255,0,0,0,0,
  255,255,255,255,0,0,0,0,36,69,108,101,109,101,110,116,0,171,171,171,0,0,19,0,
  1,0,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
  0,0,0,0,167,2,0,0,77,105,99,114,111,115,111,102,116,32,40,82,41,32,72,76,
  83,76,32,83,104,97,100,101,114,32,67,111,109,112,105,108,101,114,32,49,48,46,49,0,
  73,83,71,78,8,0,0,0,0,0,0,0,8,0,0,0,79,83,71,78,8,0,0,0,
  0,0,0,0,8,0,0,0,83,72,69,88,32,8,0,0,80,0,5,0,8,2,0,0,
  106,8,0,1,89,0,0,4,70,142,32,0,0,0,0,0,2,0,0,0,88,24,0,4,
  0,112,16,0,0,0,0,0,85,85,0,0,156,24,0,4,0,224,17,0,0,0,0,0,
  85,85,0,0,158,0,0,4,0,224,17,0,1,0,0,0,4,0,0,0,156,24,0,4,
  0,224,17,0,2,0,0,0,68,68,0,0,95,0,0,2,0,64,2,0,95,0,0,2,
  50,16,2,0,95,0,0,2,50,32,2,0,104,0,0,2,2,0,0,0,160,0,0,5,
  0,240,17,0,0,0,0,0,4,0,0,0,64,0,0,0,159,0,0,4,0,240,17,0,
  1,0,0,0,4,0,0,0,159,0,0,4,0,240,17,0,2,0,0,0,4,0,0,0,
  155,0,0,4,8,0,0,0,8,0,0,0,1,0,0,0,31,0,0,2,10,64,2,0,
  166,0,0,7,18,240,17,0,1,0,0,0,1,64,0,0,0,0,0,0,1,64,0,0,
  0,0,0,0,166,0,0,7,18,240,17,0,2,0,0,0,1,64,0,0,0,0,0,0,
  1,64,0,0,0,0,0,0,21,0,0,1,190,24,0,1,35,0,0,10,50,0,16,0,
  0,0,0,0,70,16,2,0,2,64,0,0,8,0,0,0,8,0,0,0,0,0,0,0,
  0,0,0,0,70,32,2,0,79,0,0,8,66,0,16,0,0,0,0,0,10,0,16,0,
  0,0,0,0,58,128,32,0,0,0,0,0,0,0,0,0,79,0,0,8,130,0,16,0,
  0,0,0,0,26,0,16,0,0,0,0,0,10,128,32,0,0,0,0,0,1,0,0,0,
  1,0,0,7,66,0,16,0,0,0,0,0,58,0,16,0,0,0,0,0,42,0,16,0,
  0,0,0,0,31,0,4,3,42,0,16,0,0,0,0,0,30,0,0,8,50,0,16,0,
  0,0,0,0,70,0,16,0,0,0,0,0,150,133,32,0,0,0,0,0,0,0,0,0,
  54,0,0,8,194,0,16,0,0,0,0,0,2,64,0,0,0,0,0,0,0,0,0,0,
  0,0,0,0,0,0,0,0,45,0,0,137,194,0,0,128,67,85,21,0,114,0,16,0,
  0,0,0,0,70,14,16,0,0,0,0,0,70,126,16,0,0,0,0,0,56,0,0,8,
  114,0,16,0,0,0,0,0,70,2,16,0,0,0,0,0,6,128,32,0,0,0,0,0,
  0,0,0,0,52,0,0,7,34,0,16,0,0,0,0,0,42,0,16,0,0,0,0,0,
  26,0,16,0,0,0,0,0,52,0,0,7,18,0,16,0,0,0,0,0,26,0,16,0,
  0,0,0,0,10,0,16,0,0,0,0,0,18,0,0,1,54,0,0,5,18,0,16,0,
  0,0,0,0,1,64,0,0,0,0,0,0,21,0,0,1,168,0,0,8,18,240,17,0,
  0,0,0,0,10,64,2,0,1,64,0,0,0,0,0,0,10,0,16,0,0,0,0,0,
  49,0,0,7,34,0,16,0,0,0,0,0,1,64,0,0,92,143,130,63,10,0,16,0,
  0,0,0,0,31,0,4,3,26,0,16,0,0,0,0,0,35,0,0,7,34,0,16,0,
  0,0,0,0,26,32,2,0,1,64,0,0,8,0,0,0,10,32,2,0,79,0,0,7,
  66,0,16,0,0,0,0,0,26,0,16,0,0,0,0,0,1,64,0,0,32,0,0,0,
  31,0,4,3,42,0,16,0,0,0,0,0,41,0,0,7,66,0,16,0,0,0,0,0,
  1,64,0,0,1,0,0,0,26,0,16,0,0,0,0,0,170,0,0,7,0,240,17,0,
  1,0,0,0,1,64,0,0,0,0,0,0,42,0,16,0,0,0,0,0,18,0,0,1,
  41,0,0,7,34,0,16,0,0,0,0,0,1,64,0,0,1,0,0,0,26,0,16,0,
  0,0,0,0,170,0,0,7,0,240,17,0,2,0,0,0,1,64,0,0,0,0,0,0,
  26,0,16,0,0,0,0,0,21,0,0,1,21,0,0,1,190,24,0,1,79,0,0,9,
  242,0,16,0,1,0,0,0,6,64,2,0,2,64,0,0,32,0,0,0,16,0,0,0,
  8,0,0,0,4,0,0,0,31,0,4,3,10,0,16,0,1,0,0,0,30,0,0,6,
  34,0,16,0,0,0,0,0,10,64,2,0,1,64,0,0,32,0,0,0,167,0,0,9,
  34,0,16,0,0,0,0,0,26,0,16,0,0,0,0,0,1,64,0,0,0,0,0,0,
  6,240,17,0,0,0,0,0,52,0,0,7,18,0,16,0,0,0,0,0,26,0,16,0,
  0,0,0,0,10,0,16,0,0,0,0,0,168,0,0,8,18,240,17,0,0,0,0,0,
  10,64,2,0,1,64,0,0,0,0,0,0,10,0,16,0,0,0,0,0,21,0,0,1,
  190,24,0,1,31,0,4,3,26,0,16,0,1,0,0,0,167,0,0,8,18,0,16,0,
  0,0,0,0,10,64,2,0,1,64,0,0,0,0,0,0,6,240,17,0,0,0,0,0,
  30,0,0,6,34,0,16,0,0,0,0,0,10,64,2,0,1,64,0,0,16,0,0,0,
  167,0,0,9,34,0,16,0,0,0,0,0,26,0,16,0,0,0,0,0,1,64,0,0,
  0,0,0,0,6,240,17,0,0,0,0,0,52,0,0,7,18,0,16,0,0,0,0,0,
  26,0,16,0,0,0,0,0,10,0,16,0,0,0,0,0,168,0,0,8,18,240,17,0,
  0,0,0,0,10,64,2,0,1,64,0,0,0,0,0,0,10,0,16,0,0,0,0,0,
  21,0,0,1,190,24,0,1,31,0,4,3,42,0,16,0,1,0,0,0,167,0,0,8,
  18,0,16,0,0,0,0,0,10,64,2,0,1,64,0,0,0,0,0,0,6,240,17,0,
  0,0,0,0,30,0,0,6,34,0,16,0,0,0,0,0,10,64,2,0,1,64,0,0,
  8,0,0,0,167,0,0,9,34,0,16,0,0,0,0,0,26,0,16,0,0,0,0,0,
  1,64,0,0,0,0,0,0,6,240,17,0,0,0,0,0,52,0,0,7,18,0,16,0,
  0,0,0,0,26,0,16,0,0,0,0,0,10,0,16,0,0,0,0,0,168,0,0,8,
  18,240,17,0,0,0,0,0,10,64,2,0,1,64,0,0,0,0,0,0,10,0,16,0,
  0,0,0,0,21,0,0,1,190,24,0,1,31,0,4,3,58,0,16,0,1,0,0,0,
  167,0,0,8,18,0,16,0,0,0,0,0,10,64,2,0,1,64,0,0,0,0,0,0,
  6,240,17,0,0,0,0,0,30,0,0,6,34,0,16,0,0,0,0,0,10,64,2,0,
  1,64,0,0,4,0,0,0,167,0,0,9,34,0,16,0,0,0,0,0,26,0,16,0,
  0,0,0,0,1,64,0,0,0,0,0,0,6,240,17,0,0,0,0,0,52,0,0,7,
  18,0,16,0,0,0,0,0,26,0,16,0,0,0,0,0,10,0,16,0,0,0,0,0,
  168,0,0,8,18,240,17,0,0,0,0,0,10,64,2,0,1,64,0,0,0,0,0,0,
  10,0,16,0,0,0,0,0,21,0,0,1,190,24,0,1,79,0,0,6,18,0,16,0,
  0,0,0,0,10,64,2,0,1,64,0,0,2,0,0,0,31,0,4,3,10,0,16,0,
  0,0,0,0,167,0,0,8,18,0,16,0,0,0,0,0,10,64,2,0,1,64,0,0,
  0,0,0,0,6,240,17,0,0,0,0,0,30,0,0,6,34,0,16,0,0,0,0,0,
  10,64,2,0,1,64,0,0,2,0,0,0,167,0,0,9,34,0,16,0,0,0,0,0,
  26,0,16,0,0,0,0,0,1,64,0,0,0,0,0,0,6,240,17,0,0,0,0,0,
  52,0,0,7,18,0,16,0,0,0,0,0,26,0,16,0,0,0,0,0,10,0,16,0,
  0,0,0,0,168,0,0,8,18,240,17,0,0,0,0,0,10,64,2,0,1,64,0,0,
  0,0,0,0,10,0,16,0,0,0,0,0,21,0,0,1,190,24,0,1,31,0,0,2,
  10,64,2,0,167,0,0,9,18,0,16,0,0,0,0,0,1,64,0,0,0,0,0,0,
  1,64,0,0,0,0,0,0,6,240,17,0,0,0,0,0,167,0,0,9,34,0,16,0,
  0,0,0,0,1,64,0,0,1,0,0,0,1,64,0,0,0,0,0,0,6,240,17,0,
  0,0,0,0,52,0,0,7,18,0,16,0,0,0,0,0,26,0,16,0,0,0,0,0,
  10,0,16,0,0,0,0,0,164,0,0,6,242,224,17,0,0,0,0,0,70,21,2,0,
  6,0,16,0,0,0,0,0,165,0,0,7,18,0,16,0,1,0,0,0,1,64,0,0,
  0,0,0,0,6,240,17,0,1,0,0,0,165,0,0,7,34,0,16,0,1,0,0,0,
  1,64,0,0,0,0,0,0,6,240,17,0,2,0,0,0,164,0,0,6,242,224,17,0,
  2,0,0,0,70,21,2,0,70,0,16,0,1,0,0,0,49,0,0,7,18,0,16,0,
  0,0,0,0,1,64,0,0,92,143,130,63,10,0,16,0,0,0,0,0,31,0,4,3,
  10,0,16,0,0,0,0,0,168,0,0,9,18,224,17,0,1,0,0,0,1,64,0,0,
  0,0,0,0,1,64,0,0,0,0,0,0,1,64,0,0,1,0,0,0,21,0,0,1,
  21,0,0,1,62,0,0,1,83,84,65,84,148,0,0,0,88,0,0,0,2,0,0,0,
  0,0,0,0,3,0,0,0,11,0,0,0,10,0,0,0,6,0,0,0,3,0,0,0,
  11,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
  0,0,0,0,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,2,0,0,0,
  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
  0,0,0,0,0,0,0,0,7,0,0,0,2,0,0,0,3,0,0,0
};
static const uint8_t to_srgb_bc[] = { // 2744 bytes
  68,88,66,67,105,174,197,248,75,243,240,158,201,246,156,49,11,178,226,51,1,0,0,0,
  184,10,0,0,5,0,0,0,52,0,0,0,136,2,0,0,152,2,0,0,168,2,0,0,
  28,10,0,0,82,68,69,70,76,2,0,0,1,0,0,0,252,0,0,0,5,0,0,0,
  60,0,0,0,0,5,83,67,0,129,0,0,35,2,0,0,82,68,49,49,60,0,0,0,
  24,0,0,0,32,0,0,0,40,0,0,0,36,0,0,0,12,0,0,0,0,0,0,0,
  220,0,0,0,2,0,0,0,5,0,0,0,4,0,0,0,255,255,255,255,0,0,0,0,
  1,0,0,0,13,0,0,0,224,0,0,0,2,0,0,0,5,0,0,0,4,0,0,0,
  255,255,255,255,1,0,0,0,1,0,0,0,1,0,0,0,233,0,0,0,2,0,0,0,
  4,0,0,0,4,0,0,0,255,255,255,255,2,0,0,0,1,0,0,0,5,0,0,0,
  244,0,0,0,4,0,0,0,1,0,0,0,4,0,0,0,255,255,255,255,0,0,0,0,
  1,0,0,0,13,0,0,0,248,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
  0,0,0,0,0,0,0,0,1,0,0,0,1,0,0,0,115,114,99,0,112,101,97,107,
  95,109,97,112,0,112,105,120,101,108,95,109,97,115,107,0,100,115,116,0,75,0,171,171,
  248,0,0,0,4,0,0,0,20,1,0,0,16,0,0,0,0,0,0,0,0,0,0,0,
  180,1,0,0,0,0,0,0,4,0,0,0,2,0,0,0,196,1,0,0,0,0,0,0,
  255,255,255,255,0,0,0,0,255,255,255,255,0,0,0,0,232,1,0,0,4,0,0,0,
  4,0,0,0,2,0,0,0,244,1,0,0,0,0,0,0,255,255,255,255,0,0,0,0,
  255,255,255,255,0,0,0,0,24,2,0,0,8,0,0,0,4,0,0,0,2,0,0,0,
  244,1,0,0,0,0,0,0,255,255,255,255,0,0,0,0,255,255,255,255,0,0,0,0,
  27,2,0,0,12,0,0,0,4,0,0,0,2,0,0,0,244,1,0,0,0,0,0,0,
  255,255,255,255,0,0,0,0,255,255,255,255,0,0,0,0,105,110,118,95,119,104,105,116,
  101,0,102,108,111,97,116,0,0,0,3,0,1,0,1,0,0,0,0,0,0,0,0,0,
  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,190,1,0,0,111,120,0,100,
  119,111,114,100,0,171,171,171,0,0,19,0,1,0,1,0,0,0,0,0,0,0,0,0,
  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,235,1,0,0,111,121,0,104,
  97,115,95,104,100,114,0,77,105,99,114,111,115,111,102,116,32,40,82,41,32,72,76,83,
  76,32,83,104,97,100,101,114,32,67,111,109,112,105,108,101,114,32,49,48,46,49,0,171,
  73,83,71,78,8,0,0,0,0,0,0,0,8,0,0,0,79,83,71,78,8,0,0,0,
  0,0,0,0,8,0,0,0,83,72,69,88,108,7,0,0,80,0,5,0,219,1,0,0,
  106,8,0,1,89,0,0,4,70,142,32,0,0,0,0,0,1,0,0,0,88,24,0,4,
  0,112,16,0,0,0,0,0,85,85,0,0,88,24,0,4,0,112,16,0,1,0,0,0,
  85,85,0,0,88,24,0,4,0,112,16,0,2,0,0,0,68,68,0,0,156,24,0,4,
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
  70,126,16,0,0,0,0,0,56,0,0,8,114,0,16,0,1,0,0,0,70,2,16,0,
  0,0,0,0,6,128,32,0,0,0,0,0,0,0,0,0,51,0,0,7,130,0,16,0,
  0,0,0,0,42,0,16,0,1,0,0,0,26,0,16,0,1,0,0,0,51,0,0,7,
  130,0,16,0,0,0,0,0,58,0,16,0,0,0,0,0,10,0,16,0,1,0,0,0,
  49,0,0,7,130,0,16,0,1,0,0,0,58,0,16,0,0,0,0,0,1,64,0,0,
  0,0,0,0,16,0,0,10,18,0,16,0,2,0,0,0,70,2,16,0,1,0,0,0,
  2,64,0,0,208,179,89,62,89,23,55,63,152,221,147,61,0,0,0,0,49,0,0,7,
  34,0,16,0,2,0,0,0,1,64,0,0,189,55,134,53,10,0,16,0,2,0,0,0,
  0,0,0,8,130,0,16,0,0,0,0,0,58,0,16,128,65,0,0,0,0,0,0,0,
  10,0,16,0,2,0,0,0,52,0,0,7,130,0,16,0,0,0,0,0,58,0,16,0,
  0,0,0,0,1,64,0,0,189,55,134,53,14,0,0,7,130,0,16,0,0,0,0,0,
  10,0,16,0,2,0,0,0,58,0,16,0,0,0,0,0,50,0,0,11,114,0,16,0,
  0,0,0,0,70,2,16,0,0,0,0,0,6,128,32,0,0,0,0,0,0,0,0,0,
  6,0,16,128,65,0,0,0,2,0,0,0,50,0,0,9,114,0,16,0,0,0,0,0,
  70,2,16,0,0,0,0,0,246,15,16,0,0,0,0,0,6,0,16,0,2,0,0,0,
  55,0,0,9,114,0,16,0,0,0,0,0,86,5,16,0,2,0,0,0,70,2,16,0,
  0,0,0,0,70,2,16,0,1,0,0,0,55,0,0,9,114,0,16,0,0,0,0,0,
  246,15,16,0,1,0,0,0,70,2,16,0,0,0,0,0,70,2,16,0,1,0,0,0,
  52,0,0,10,114,0,16,0,0,0,0,0,102,8,16,0,0,0,0,0,2,64,0,0,
  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,31,0,4,4,58,128,32,0,
  0,0,0,0,0,0,0,0,85,0,0,9,50,0,16,0,1,0,0,0,70,0,2,0,
  2,64,0,0,3,0,0,0,3,0,0,0,0,0,0,0,0,0,0,0,54,0,0,8,
  194,0,16,0,1,0,0,0,2,64,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
  0,0,0,0,45,0,0,137,194,0,0,128,3,17,17,0,50,0,16,0,2,0,0,0,
  70,15,16,0,1,0,0,0,70,126,16,0,2,0,0,0,140,0,0,10,130,0,16,0,
  0,0,0,0,1,64,0,0,3,0,0,0,1,64,0,0,3,0,0,0,26,0,2,0,
  1,64,0,0,0,0,0,0,140,0,0,10,130,0,16,0,0,0,0,0,1,64,0,0,
  3,0,0,0,1,64,0,0,0,0,0,0,10,0,2,0,58,0,16,0,0,0,0,0,
  79,0,0,7,66,0,16,0,2,0,0,0,58,0,16,0,0,0,0,0,1,64,0,0,
  32,0,0,0,55,0,0,9,18,0,16,0,2,0,0,0,42,0,16,0,2,0,0,0,
  10,0,16,0,2,0,0,0,26,0,16,0,2,0,0,0,85,0,0,7,130,0,16,0,
  0,0,0,0,10,0,16,0,2,0,0,0,58,0,16,0,0,0,0,0,1,0,0,7,
  130,0,16,0,0,0,0,0,58,0,16,0,0,0,0,0,1,64,0,0,1,0,0,0,
  31,0,4,3,58,0,16,0,0,0,0,0,45,0,0,137,194,0,0,128,67,85,21,0,
  130,0,16,0,0,0,0,0,70,14,16,0,1,0,0,0,150,115,16,0,1,0,0,0,
  49,0,0,7,18,0,16,0,1,0,0,0,1,64,0,0,0,0,128,63,58,0,16,0,
  0,0,0,0,52,0,0,7,34,0,16,0,1,0,0,0,10,0,16,0,0,0,0,0,
  26,0,16,0,0,0,0,0,52,0,0,7,34,0,16,0,1,0,0,0,42,0,16,0,
  0,0,0,0,26,0,16,0,1,0,0,0,49,0,0,7,66,0,16,0,1,0,0,0,
  1,64,0,0,189,55,134,53,26,0,16,0,1,0,0,0,56,0,0,7,130,0,16,0,
  0,0,0,0,58,0,16,0,0,0,0,0,58,0,16,0,0,0,0,0,14,0,0,7,
  130,0,16,0,0,0,0,0,26,0,16,0,1,0,0,0,58,0,16,0,0,0,0,0,
  0,0,0,7,130,0,16,0,0,0,0,0,58,0,16,0,0,0,0,0,1,64,0,0,
  0,0,128,63,56,0,0,7,130,0,16,0,0,0,0,0,58,0,16,0,0,0,0,0,
  26,0,16,0,1,0,0,0,0,0,0,7,130,0,16,0,1,0,0,0,26,0,16,0,
  1,0,0,0,1,64,0,0,0,0,128,63,14,0,0,7,130,0,16,0,0,0,0,0,
  58,0,16,0,0,0,0,0,58,0,16,0,1,0,0,0,14,0,0,7,130,0,16,0,
  0,0,0,0,58,0,16,0,0,0,0,0,26,0,16,0,1,0,0,0,56,0,0,7,
  114,0,16,0,2,0,0,0,246,15,16,0,0,0,0,0,102,8,16,0,0,0,0,0,
  55,0,0,9,226,0,16,0,1,0,0,0,166,10,16,0,1,0,0,0,6,9,16,0,
  2,0,0,0,166,1,16,0,0,0,0,0,55,0,0,9,114,0,16,0,0,0,0,0,
  6,0,16,0,1,0,0,0,182,13,16,0,1,0,0,0,70,2,16,0,0,0,0,0,
  21,0,0,1,21,0,0,1,54,32,0,5,114,0,16,0,0,0,0,0,70,2,16,0,
  0,0,0,0,29,0,0,10,114,0,16,0,1,0,0,0,2,64,0,0,28,46,77,59,
  28,46,77,59,28,46,77,59,0,0,0,0,70,2,16,0,0,0,0,0,56,0,0,10,
  114,0,16,0,2,0,0,0,70,2,16,0,0,0,0,0,2,64,0,0,82,184,78,65,
  82,184,78,65,82,184,78,65,0,0,0,0,47,0,0,5,114,0,16,0,0,0,0,0,
  70,2,16,0,0,0,0,0,56,0,0,10,114,0,16,0,0,0,0,0,70,2,16,0,
  0,0,0,0,2,64,0,0,85,85,213,62,85,85,213,62,85,85,213,62,0,0,0,0,
  25,0,0,5,114,0,16,0,0,0,0,0,70,2,16,0,0,0,0,0,50,0,0,15,
  114,0,16,0,0,0,0,0,70,2,16,0,0,0,0,0,2,64,0,0,61,10,135,63,
  61,10,135,63,61,10,135,63,0,0,0,0,2,64,0,0,174,71,97,189,174,71,97,189,
  174,71,97,189,0,0,0,0,55,0,0,9,114,0,16,0,0,0,0,0,70,2,16,0,
  1,0,0,0,70,2,16,0,2,0,0,0,70,2,16,0,0,0,0,0,54,0,0,5,
  130,0,16,0,0,0,0,0,1,64,0,0,0,0,128,63,164,0,0,6,242,224,17,0,
  0,0,0,0,70,5,2,0,70,14,16,0,0,0,0,0,62,0,0,1,83,84,65,84,
  148,0,0,0,62,0,0,0,3,0,0,0,0,0,0,0,1,0,0,0,30,0,0,0,
  1,0,0,0,6,0,0,0,3,0,0,0,2,0,0,0,0,0,0,0,0,0,0,0,
  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,3,0,0,0,0,0,0,0,
  0,0,0,0,0,0,0,0,4,0,0,0,6,0,0,0,0,0,0,0,0,0,0,0,
  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
  0,0,0,0,1,0,0,0
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
static ComPtr<ID3D11ComputeShader> to_tile_max;
static ComPtr<ID3D11Buffer> to_tile_k;
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
static ComPtr<ID3D11ComputeShader> dd_tile_max;
static ComPtr<ID3D11Buffer> dd_tile_k;
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
  dd_tile_max.Reset();
  dd_tile_k.Reset();
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
  dd_dev->CreateComputeShader(hdr_tile_max_bc, sizeof hdr_tile_max_bc, NULL, &dd_tile_max);
  D3D11_BUFFER_DESC bd = {16, D3D11_USAGE_DYNAMIC, D3D11_BIND_CONSTANT_BUFFER, D3D11_CPU_ACCESS_WRITE, 0, 0};
  dd_dev->CreateBuffer(&bd, NULL, &dd_srgb_k);
  D3D11_BUFFER_DESC td_k = {32, D3D11_USAGE_DYNAMIC, D3D11_BIND_CONSTANT_BUFFER, D3D11_CPU_ACCESS_WRITE, 0, 0};
  dd_dev->CreateBuffer(&td_k, NULL, &dd_tile_k);
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
  dev->CreateComputeShader(hdr_tile_max_bc, sizeof hdr_tile_max_bc, NULL, &to_tile_max);
  D3D11_BUFFER_DESC bd = {16, D3D11_USAGE_DYNAMIC, D3D11_BIND_CONSTANT_BUFFER, D3D11_CPU_ACCESS_WRITE, 0, 0};
  dev->CreateBuffer(&bd, NULL, &to_srgb_k);
  D3D11_BUFFER_DESC td_k = {32, D3D11_USAGE_DYNAMIC, D3D11_BIND_CONSTANT_BUFFER, D3D11_CPU_ACCESS_WRITE, 0, 0};
  dev->CreateBuffer(&td_k, NULL, &to_tile_k);
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

static void wgc_dev_teardown(void) {
  for (int i = 0; i < nmons; i++) mon_stop(&mons[i]);
  nmons = 0;
  if (kept_staging) {
    ComPtr<ID3D11Device> kdev;
    kept_staging->GetDevice(&kdev);
    if (kdev.Get() == dev.Get()) kept_staging.Reset();
  }
  if (kept_out) {
    ComPtr<ID3D11Device> kdev;
    kept_out->GetDevice(&kdev);
    if (kdev.Get() == dev.Get()) kept_out.Reset(), kept_uav.Reset();
  }
  to_srgb.Reset();
  to_srgb_k.Reset();
  to_tile_max.Reset();
  to_tile_k.Reset();
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

static void wgc_teardown(void) {
  wgc_dev_teardown();
  dd_teardown();
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
    if (ready > 0) wgc_dev_teardown();
    return 1;
  }
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
  if (on) return;
  if (keep_sessions) {
    if (dd_ok == 1 && (nmons > 0 || ready > 0)) wgc_dev_teardown();
    return;
  }
  wgc_teardown();
}

extern "C" void *ps_wgc_take_part(HMONITOR mon, int w, int h, int rx, int ry, int rw, int rh, uint8_t **bits, int *pitch) {
  if (rx < 0 || ry < 0 || rw <= 0 || rh <= 0 || rx + rw > w || ry + rh > h) return NULL;
  return take(mon, w, h, rx, ry, rw, rh, 1, bits, pitch);
}

#define DD_FRAME_MS 200.0
static int dd_black;

extern "C" int ps_wgc_dd_black(void) { return dd_black; }

static inline int hdr_raw_bit(const uint64_t *tile_mask, int pitch_u64, int x, int y) {
  uint64_t m = tile_mask[(size_t)(y >> 3) * (size_t)pitch_u64 + (size_t)(x >> 3)];
  return (int)((m >> (((y & 7) << 3) | (x & 7))) & 1ULL);
}

static inline void hdr_clear_bit(uint64_t *mask_out, int tw, int x, int y) {
  mask_out[(size_t)(y >> 3) * (size_t)tw + (size_t)(x >> 3)] &= ~(1ULL << (((y & 7) << 3) | (x & 7)));
}

static int hdr_build_peak_map(const float *tile_max, int pitch_floats,
                              const uint64_t *tile_mask, int pitch_u64,
                              int tw, int th, int img_w, int img_h,
                              float *peak_out, uint64_t *mask_out) {
  int n = tw * th;
  uint8_t *hdr = (uint8_t *)malloc((size_t)n);
  uint8_t *dil_h = (uint8_t *)malloc((size_t)n);
  uint8_t *dil = (uint8_t *)malloc((size_t)n);
  uint8_t *vis = (uint8_t *)calloc((size_t)n, 1);
  int *qx = (int *)malloc((size_t)n * sizeof(int));
  int *qy = (int *)malloc((size_t)n * sizeof(int));
  if (!hdr || !dil_h || !dil || !vis || !qx || !qy) {
    free(hdr); free(dil_h); free(dil); free(vis); free(qx); free(qy);
    return 0;
  }

  int any_hdr = 0;
  for (int y = 0; y < th; y++) {
    const float *row = tile_max + (size_t)y * pitch_floats;
    uint8_t *dst = hdr + (size_t)y * tw;
    for (int x = 0; x < tw; x++) {
      uint8_t h = row[x] > 1.02f ? 1 : 0;
      dst[x] = h;
      any_hdr |= h;
    }
  }
  if (!any_hdr) {
    free(hdr); free(dil_h); free(dil); free(vis); free(qx); free(qy);
    return 0;
  }

  const int R = 2;
  for (int y = 0; y < th; y++) {
    const uint8_t *src_r = hdr + (size_t)y * tw;
    uint8_t *dst_r = dil_h + (size_t)y * tw;
    for (int x = 0; x < tw; x++) {
      int x0 = x - R > 0 ? x - R : 0;
      int x1 = x + R < tw - 1 ? x + R : tw - 1;
      uint8_t m = 0;
      for (int xx = x0; xx <= x1; xx++) m |= src_r[xx];
      dst_r[x] = m;
    }
  }
  for (int y = 0; y < th; y++) {
    int y0 = y - R > 0 ? y - R : 0;
    int y1 = y + R < th - 1 ? y + R : th - 1;
    uint8_t *dst_r = dil + (size_t)y * tw;
    for (int x = 0; x < tw; x++) {
      uint8_t m = 0;
      for (int yy = y0; yy <= y1; yy++) m |= dil_h[(size_t)yy * tw + x];
      dst_r[x] = m;
    }
  }

  memset(peak_out, 0, (size_t)n * sizeof(float));
  memset(mask_out, 0, (size_t)n * sizeof(uint64_t));
  static const int dx4[4] = {-1, 1, 0, 0};
  static const int dy4[4] = {0, 0, -1, 1};

  for (int sy = 0; sy < th; sy++) {
    for (int sx = 0; sx < tw; sx++) {
      int sidx = sy * tw + sx;
      if (!dil[sidx] || vis[sidx]) continue;
      int head = 0, tail = 0;
      vis[sidx] = 1;
      qx[tail] = sx;
      qy[tail] = sy;
      tail++;

      int px0 = img_w, py0 = img_h, px1 = -1, py1 = -1;
      int hist[512];
      memset(hist, 0, sizeof hist);
      int nvals = 0;
      float max_v = 0.0f;

      while (head < tail) {
        int cx = qx[head], cy = qy[head];
        head++;
        if (hdr[cy * tw + cx]) {
          uint64_t m = tile_mask[(size_t)cy * (size_t)pitch_u64 + (size_t)cx];
          if (m && (cx * 8 < px0 || cx * 8 + 7 > px1 || cy * 8 < py0 || cy * 8 + 7 > py1)) {
            uint8_t col_or = 0;
            int ly_lo = 7, ly_hi = 0;
            for (int ly = 0; ly < 8; ly++) {
              uint8_t rb = (uint8_t)((m >> (ly * 8)) & 0xFFu);
              if (rb) {
                col_or |= rb;
                if (ly < ly_lo) ly_lo = ly;
                ly_hi = ly;
              }
            }
            int lx_lo = 0, lx_hi = 7;
            while (lx_lo < 7 && !(col_or & (1u << lx_lo))) lx_lo++;
            while (lx_hi > 0 && !(col_or & (1u << lx_hi))) lx_hi--;
            if (cx * 8 + lx_lo < px0) px0 = cx * 8 + lx_lo;
            if (cx * 8 + lx_hi > px1) px1 = cx * 8 + lx_hi;
            if (cy * 8 + ly_lo < py0) py0 = cy * 8 + ly_lo;
            if (cy * 8 + ly_hi > py1) py1 = cy * 8 + ly_hi;
          }
          float v = tile_max[(size_t)cy * pitch_floats + cx];
          if (v > max_v) max_v = v;
          int b = (int)((v - 1.0f) * (511.0f / 9.0f));
          if (b < 0) b = 0;
          if (b > 511) b = 511;
          hist[b]++;
          nvals++;
        }
        for (int k = 0; k < 4; k++) {
          int nx = cx + dx4[k], ny = cy + dy4[k];
          if (nx < 0 || nx >= tw || ny < 0 || ny >= th) continue;
          int nidx = ny * tw + nx;
          if (dil[nidx] && !vis[nidx]) {
            vis[nidx] = 1;
            qx[tail] = nx;
            qy[tail] = ny;
            tail++;
          }
        }
      }

      if (nvals <= 0 || px1 < px0 || py1 < py0) continue;
      if (px1 >= img_w) px1 = img_w - 1;
      if (py1 >= img_h) py1 = img_h - 1;

      int target = (int)(0.98 * (double)(nvals - 1)) + 1;
      int acc = 0, bin = 511;
      for (int b = 0; b < 512; b++) {
        acc += hist[b];
        if (acc >= target) {
          bin = b;
          break;
        }
      }
      float wp = 1.0f + ((float)bin + 0.5f) * (9.0f / 511.0f);
      if (wp > max_v) wp = max_v;
      if (wp < 1.05f) wp = 1.05f;
      if (wp > 10.0f) wp = 10.0f;

      int tx0 = px0 >> 3, tx1 = px1 >> 3, ty0 = py0 >> 3, ty1 = py1 >> 3;
      for (int ty = ty0; ty <= ty1; ty++) {
        int ly0 = (ty == ty0) ? (py0 & 7) : 0;
        int ly1 = (ty == ty1) ? (py1 & 7) : 7;
        for (int tx = tx0; tx <= tx1; tx++) {
          int lx0 = (tx == tx0) ? (px0 & 7) : 0;
          int lx1 = (tx == tx1) ? (px1 & 7) : 7;
          uint64_t rect_m;
          if (lx0 == 0 && lx1 == 7 && ly0 == 0 && ly1 == 7) {
            rect_m = ~0ULL;
          } else {
            uint8_t row_bits = (uint8_t)(((1u << (lx1 - lx0 + 1)) - 1u) << lx0);
            rect_m = 0;
            for (int ly = ly0; ly <= ly1; ly++) rect_m |= ((uint64_t)row_bits << (ly * 8));
          }
          size_t idx = (size_t)ty * (size_t)tw + (size_t)tx;
          if (wp > peak_out[idx]) peak_out[idx] = wp;
          mask_out[idx] |= rect_m;
        }
      }

      int cw = px1 - px0 + 1, ch = py1 - py0 + 1;
      int C = (cw < ch ? cw : ch) / 3;
      if (C > 48) C = 48;
      if (C >= 4) {
        const int corners[4][4] = {
            {px0, py0, 1, 1}, {px1, py0, -1, 1}, {px0, py1, 1, -1}, {px1, py1, -1, -1}};
        int rf[4][48], cf[4][48];
        int rx[4], ry[4], r_est[4], has_c[4];
        int clean_r[4], n_clean = 0;

        for (int ci = 0; ci < 4; ci++) {
          int cx0 = corners[ci][0], cy0 = corners[ci][1];
          int dxs = corners[ci][2], dys = corners[ci][3];
          r_est[ci] = -1;
          rx[ci] = ry[ci] = 0;
          has_c[ci] = !hdr_raw_bit(tile_mask, pitch_u64, cx0, cy0);
          if (!has_c[ci]) continue;
          for (int dy = 0; dy < C; dy++) {
            int f = C;
            for (int dx = 0; dx < C; dx++) {
              if (hdr_raw_bit(tile_mask, pitch_u64, cx0 + dxs * dx, cy0 + dys * dy)) {
                f = dx;
                break;
              }
            }
            if (dy > 0 && f > rf[ci][dy - 1]) f = rf[ci][dy - 1];
            rf[ci][dy] = f;
          }
          for (int dx = 0; dx < C; dx++) {
            int f = C;
            for (int dy = 0; dy < C; dy++) {
              if (hdr_raw_bit(tile_mask, pitch_u64, cx0 + dxs * dx, cy0 + dys * dy)) {
                f = dy;
                break;
              }
            }
            if (dx > 0 && f > cf[ci][dx - 1]) f = cf[ci][dx - 1];
            cf[ci][dx] = f;
          }
          rx[ci] = rf[ci][0];
          ry[ci] = cf[ci][0];
          int dd = C;
          for (int d = 0; d < C; d++) {
            if (hdr_raw_bit(tile_mask, pitch_u64, cx0 + dxs * d, cy0 + dys * d)) {
              dd = d;
              break;
            }
          }
          if (rx[ci] >= 4 && rx[ci] <= C - 2 && ry[ci] >= 4 && ry[ci] <= C - 2 &&
              abs(rx[ci] - ry[ci]) <= 4 && rf[ci][C - 1] == 0 && cf[ci][C - 1] == 0) {
            float r_avg = 0.5f * (float)(rx[ci] + ry[ci]);
            if (fabsf((float)dd - r_avg * 0.29289322f) <= 3.0f) {
              r_est[ci] = (int)(r_avg + 0.5f);
              clean_r[n_clean++] = r_est[ci];
            }
          }
        }

        int r_sib = 0;
        if (n_clean >= 2) {
          for (int a = 0; a < n_clean; a++) {
            for (int b = a + 1; b < n_clean; b++) {
              if (clean_r[b] < clean_r[a]) {
                int tmp = clean_r[a]; clean_r[a] = clean_r[b]; clean_r[b] = tmp;
              }
            }
          }
          int med = clean_r[n_clean / 2], agree = 0;
          for (int a = 0; a < n_clean; a++) {
            if (abs(clean_r[a] - med) <= 3) agree++;
          }
          if (agree >= 2) r_sib = med;
        }

        for (int ci = 0; ci < 4; ci++) {
          if (!has_c[ci]) continue;
          int cx0 = corners[ci][0], cy0 = corners[ci][1];
          int dxs = corners[ci][2], dys = corners[ci][3];
          if (r_est[ci] >= 4) {
            float Rf = (float)r_est[ci];
            float r2 = (Rf - 0.5f) * (Rf - 0.5f);
            int lim = r_est[ci] + 2 < C ? r_est[ci] + 2 : C;
            for (int dy = 0; dy < lim; dy++) {
              for (int dx = 0; dx < lim; dx++) {
                int x = cx0 + dxs * dx, y = cy0 + dys * dy;
                if (hdr_raw_bit(tile_mask, pitch_u64, x, y)) continue;
                float ex = Rf - (float)dx, ey = Rf - (float)dy;
                if ((dx < rf[ci][dy] && dy < cf[ci][dx]) || (ex * ex + ey * ey > r2)) {
                  hdr_clear_bit(mask_out, tw, x, y);
                }
              }
            }
          } else if (r_sib >= 4) {
            float Rf = (float)r_sib;
            float r2 = (Rf - 0.5f) * (Rf - 0.5f);
            int lim = r_sib + 1 < C ? r_sib + 1 : C;
            for (int dy = 0; dy < lim; dy++) {
              for (int dx = 0; dx < lim; dx++) {
                int x = cx0 + dxs * dx, y = cy0 + dys * dy;
                if (hdr_raw_bit(tile_mask, pitch_u64, x, y)) continue;
                float ex = Rf - (float)dx, ey = Rf - (float)dy;
                if (ex * ex + ey * ey > r2) hdr_clear_bit(mask_out, tw, x, y);
              }
            }
          } else if (rx[ci] <= 24 && ry[ci] <= 24 && rf[ci][C - 1] == 0 && cf[ci][C - 1] == 0) {
            int ly_lim = ry[ci] + 1 < C ? ry[ci] + 1 : C;
            int lx_lim = rx[ci] + 1 < C ? rx[ci] + 1 : C;
            for (int dy = 0; dy < ly_lim; dy++) {
              for (int dx = 0; dx < lx_lim; dx++) {
                int x = cx0 + dxs * dx, y = cy0 + dys * dy;
                if (!hdr_raw_bit(tile_mask, pitch_u64, x, y) && dx < rf[ci][dy] && dy < cf[ci][dx]) {
                  hdr_clear_bit(mask_out, tw, x, y);
                }
              }
            }
          }
        }
      }
    }
  }

  free(hdr); free(dil_h); free(dil); free(vis); free(qx); free(qy);
  return 1;
}

static int hdr_convert_gpu(ID3D11Device *d, ID3D11DeviceContext *c,
                           ID3D11ComputeShader *tile_cs, ID3D11Buffer *tile_k,
                           ID3D11ComputeShader *srgb_cs, ID3D11Buffer *srgb_k,
                           ID3D11ShaderResourceView *src_srv, ID3D11UnorderedAccessView *dst_uav,
                           float white, uint32_t ox, uint32_t oy, int rw, int rh) {
  uint32_t has_hdr = 0;
  ComPtr<ID3D11ShaderResourceView> peak_srv, pmask_srv;
  int tw = (rw + 7) / 8;
  int th = (rh + 7) / 8;
  if (tile_cs && tile_k && tw > 0 && th > 0) {
    D3D11_TEXTURE2D_DESC td = {};
    td.Width = (UINT)tw;
    td.Height = (UINT)th;
    td.MipLevels = td.ArraySize = 1;
    td.Format = DXGI_FORMAT_R32_FLOAT;
    td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DEFAULT;
    td.BindFlags = D3D11_BIND_UNORDERED_ACCESS;

    D3D11_TEXTURE2D_DESC md = td;
    md.Format = DXGI_FORMAT_R32G32_UINT;

    D3D11_BUFFER_DESC fbd = {};
    fbd.ByteWidth = 4;
    fbd.Usage = D3D11_USAGE_DEFAULT;
    fbd.BindFlags = D3D11_BIND_UNORDERED_ACCESS;
    fbd.MiscFlags = D3D11_RESOURCE_MISC_BUFFER_STRUCTURED;
    fbd.StructureByteStride = 4;
    uint32_t zero = 0;
    D3D11_SUBRESOURCE_DATA finit = {&zero, 0, 0};

    D3D11_BUFFER_DESC fsd = {};
    fsd.ByteWidth = 4;
    fsd.Usage = D3D11_USAGE_STAGING;
    fsd.CPUAccessFlags = D3D11_CPU_ACCESS_READ;

    ComPtr<ID3D11Texture2D> tile_tex, mask_tex;
    ComPtr<ID3D11UnorderedAccessView> tile_uav, mask_uav, flag_uav;
    ComPtr<ID3D11Buffer> flag_buf, flag_stg;

    if (SUCCEEDED(d->CreateTexture2D(&td, NULL, &tile_tex)) &&
        SUCCEEDED(d->CreateUnorderedAccessView(tile_tex.Get(), NULL, &tile_uav)) &&
        SUCCEEDED(d->CreateTexture2D(&md, NULL, &mask_tex)) &&
        SUCCEEDED(d->CreateUnorderedAccessView(mask_tex.Get(), NULL, &mask_uav)) &&
        SUCCEEDED(d->CreateBuffer(&fbd, &finit, &flag_buf)) &&
        SUCCEEDED(d->CreateUnorderedAccessView(flag_buf.Get(), NULL, &flag_uav)) &&
        SUCCEEDED(d->CreateBuffer(&fsd, NULL, &flag_stg))) {
      D3D11_MAPPED_SUBRESOURCE tkp;
      if (SUCCEEDED(c->Map(tile_k, 0, D3D11_MAP_WRITE_DISCARD, 0, &tkp))) {
        struct { float inv_white; uint32_t ox, oy, rw, rh, p0, p1, p2; } tk = {
            1.0f / white, ox, oy, (uint32_t)rw, (uint32_t)rh, 0, 0, 0};
        memcpy(tkp.pData, &tk, sizeof tk);
        c->Unmap(tile_k, 0);
        ID3D11ShaderResourceView *tsrv[1] = {src_srv};
        ID3D11UnorderedAccessView *tuav[3] = {tile_uav.Get(), flag_uav.Get(), mask_uav.Get()};
        ID3D11Buffer *tks[1] = {tile_k};
        c->CSSetShader(tile_cs, NULL, 0);
        c->CSSetShaderResources(0, 1, tsrv);
        c->CSSetUnorderedAccessViews(0, 3, tuav, NULL);
        c->CSSetConstantBuffers(0, 1, tks);
        c->Dispatch((UINT)tw, (UINT)th, 1);
        ID3D11ShaderResourceView *no_s[1] = {NULL};
        ID3D11UnorderedAccessView *no_u[3] = {NULL, NULL, NULL};
        c->CSSetShaderResources(0, 1, no_s);
        c->CSSetUnorderedAccessViews(0, 3, no_u, NULL);
        c->CSSetShader(NULL, NULL, 0);

        c->CopyResource(flag_stg.Get(), flag_buf.Get());
        D3D11_MAPPED_SUBRESOURCE fmp;
        uint32_t any_flag = 0;
        if (SUCCEEDED(c->Map(flag_stg.Get(), 0, D3D11_MAP_READ, 0, &fmp))) {
          any_flag = *(const uint32_t *)fmp.pData;
          c->Unmap(flag_stg.Get(), 0);
        }

        if (any_flag != 0) {
          D3D11_TEXTURE2D_DESC sd = td;
          sd.Usage = D3D11_USAGE_STAGING;
          sd.BindFlags = 0;
          sd.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
          D3D11_TEXTURE2D_DESC msd = sd;
          msd.Format = DXGI_FORMAT_R32G32_UINT;
          ComPtr<ID3D11Texture2D> tile_stg, mask_stg;
          if (SUCCEEDED(d->CreateTexture2D(&sd, NULL, &tile_stg)) &&
              SUCCEEDED(d->CreateTexture2D(&msd, NULL, &mask_stg))) {
            c->CopyResource(tile_stg.Get(), tile_tex.Get());
            c->CopyResource(mask_stg.Get(), mask_tex.Get());
            D3D11_MAPPED_SUBRESOURCE tmp, mmp;
            if (SUCCEEDED(c->Map(tile_stg.Get(), 0, D3D11_MAP_READ, 0, &tmp))) {
              if (SUCCEEDED(c->Map(mask_stg.Get(), 0, D3D11_MAP_READ, 0, &mmp))) {
                float *peak_buf = (float *)malloc((size_t)tw * (size_t)th * sizeof(float));
                uint64_t *mask_buf = (uint64_t *)malloc((size_t)tw * (size_t)th * sizeof(uint64_t));
                if (peak_buf && mask_buf) {
                  if (hdr_build_peak_map((const float *)tmp.pData, (int)(tmp.RowPitch / sizeof(float)),
                                         (const uint64_t *)mmp.pData, (int)(mmp.RowPitch / sizeof(uint64_t)),
                                         tw, th, rw, rh, peak_buf, mask_buf)) {
                    D3D11_TEXTURE2D_DESC pd = td;
                    pd.Usage = D3D11_USAGE_IMMUTABLE;
                    pd.BindFlags = D3D11_BIND_SHADER_RESOURCE;
                    D3D11_SUBRESOURCE_DATA pinit = {peak_buf, (UINT)(tw * sizeof(float)), 0};
                    D3D11_TEXTURE2D_DESC pmd = pd;
                    pmd.Format = DXGI_FORMAT_R32G32_UINT;
                    D3D11_SUBRESOURCE_DATA pminit = {mask_buf, (UINT)(tw * sizeof(uint64_t)), 0};
                    ComPtr<ID3D11Texture2D> peak_tex, pmask_tex;
                    if (SUCCEEDED(d->CreateTexture2D(&pd, &pinit, &peak_tex)) &&
                        SUCCEEDED(d->CreateShaderResourceView(peak_tex.Get(), NULL, &peak_srv)) &&
                        SUCCEEDED(d->CreateTexture2D(&pmd, &pminit, &pmask_tex)) &&
                        SUCCEEDED(d->CreateShaderResourceView(pmask_tex.Get(), NULL, &pmask_srv))) {
                      has_hdr = 1;
                    }
                  }
                }
                free(peak_buf);
                free(mask_buf);
                c->Unmap(mask_stg.Get(), 0);
              }
              c->Unmap(tile_stg.Get(), 0);
            }
          }
        }
      }
    }
  }

  D3D11_MAPPED_SUBRESOURCE kp;
  if (FAILED(c->Map(srgb_k, 0, D3D11_MAP_WRITE_DISCARD, 0, &kp))) return 0;
  struct { float inv_white; uint32_t ox; uint32_t oy; uint32_t has_hdr; } k = {1.0f / white, ox, oy, has_hdr};
  memcpy(kp.pData, &k, sizeof k);
  c->Unmap(srgb_k, 0);
  ID3D11ShaderResourceView *srvs[3] = {src_srv, peak_srv.Get(), pmask_srv.Get()};
  ID3D11UnorderedAccessView *uavs[1] = {dst_uav};
  ID3D11Buffer *ks[1] = {srgb_k};
  c->CSSetShader(srgb_cs, NULL, 0);
  c->CSSetShaderResources(0, 3, srvs);
  c->CSSetUnorderedAccessViews(0, 1, uavs, NULL);
  c->CSSetConstantBuffers(0, 1, ks);
  c->Dispatch((UINT)((rw + 15) / 16), (UINT)((rh + 15) / 16), 1);
  ID3D11ShaderResourceView *no_srv[3] = {NULL, NULL, NULL};
  ID3D11UnorderedAccessView *no_uav[1] = {NULL};
  c->CSSetShaderResources(0, 3, no_srv);
  c->CSSetUnorderedAccessViews(0, 1, no_uav, NULL);
  c->CSSetShader(NULL, NULL, 0);
  return 1;
}

static int dd_all_black(const uint8_t *bits, int pitch, int w, int h) {
  for (int j = 0; j < 32; j++) {
    const uint8_t *row = bits + (size_t)((2 * j + 1) * (int64_t)h / 64) * pitch;
    for (int i = 0; i < 32; i++) {
      const uint8_t *p = row + (size_t)((2 * i + 1) * (int64_t)w / 64) * 4;
      if (p[0] | p[1] | p[2]) return 0;
    }
  }
  return 1;
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
    if (!keep_sessions && !long_holds) dd_teardown();
    return NULL;
  }
  dd_ok = 1;
  ComPtr<IDXGIResource> res;
  DXGI_OUTDUPL_FRAME_INFO fi = {};
  HRESULT hr = DXGI_ERROR_WAIT_TIMEOUT;
  LARGE_INTEGER t_acq;
  QueryPerformanceCounter(&t_acq);
  // A fresh duplication can first hand pointer-only frames (LastPresentTime 0) whose surface is still all black:
  // never take one; wait out the remaining budget for a desktop frame, otherwise leave capture to WGC / GDI.
  for (;;) {
    LARGE_INTEGER now;
    QueryPerformanceCounter(&now);
    double left = DD_FRAME_MS - (now.QuadPart - t_acq.QuadPart) * 1000.0 / (double)f.QuadPart;
    if (left <= 0.0) {
      hr = DXGI_ERROR_WAIT_TIMEOUT;
      break;
    }
    UINT wait_ms = left < 1.0 ? 1u : (UINT)left;
    hr = dupl->AcquireNextFrame(wait_ms, &fi, &res);
    if (FAILED(hr) || !res) break;
    if (fi.LastPresentTime.QuadPart != 0) break;
    res.Reset();
    dupl->ReleaseFrame();
    hr = DXGI_ERROR_WAIT_TIMEOUT;
  }
  if (FAILED(hr) || !res) {
    last_hr = hr;
    dupl.Reset();
    if (!keep_sessions && !long_holds) dd_teardown();
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
  const int whole_monitor = whole;
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
    if (!hdr_convert_gpu(dd_dev.Get(), dd_ctx.Get(), dd_tile_max.Get(), dd_tile_k.Get(),
                         dd_srgb.Get(), dd_srgb_k.Get(), srv.Get(), uav.Get(), white, ox, oy, rw, rh)) {
      tex.Reset(); res.Reset(); dupl->ReleaseFrame(); dupl.Reset();
      return NULL;
    }
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
  // A whole monitor is never all black (its taskbar at least); leave such a frame to WGC / GDI.
  if (whole_monitor && dd_all_black((const uint8_t *)mp.pData, (int)mp.RowPitch, rw, rh)) {
    dd_ctx->Unmap(staging.Get(), 0);
    staging.Reset();
    dd_black++;
    if (!keep_sessions && !long_holds) {
      dd_teardown();
    } else if (dd_ctx) {
      dd_ctx->ClearState();
      dd_ctx->Flush();
    }
    return NULL;
  }
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

extern "C" void *ps_wgc_take_dd(HMONITOR mon, int w, int h, uint8_t **bits, int *pitch) {
  take_used_dd = 0;
  return dd_take(mon, w, h, 0, 0, w, h, bits, pitch);
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
  if (keep_sessions && nmons == 0 && dd_ok != 1) ps_wgc_restart();
  Mon *m = NULL;
  for (int i = 0; i < nmons; i++)
    if (mons[i].mon == mon) m = &mons[i];
  int one_shot = !keep_sessions || (dd_ok == 1 && !m);
  if (!m && one_shot) {
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
        if (one_shot && !long_holds) {
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
    if (one_shot && !long_holds) {
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
      ComPtr<ID3D11Device> kdev;
      kept_out->GetDevice(&kdev);
      if (kdev.Get() == dev.Get() && kd.Width == od.Width && kd.Height == od.Height && kd.Format == od.Format)
        out = kept_out, uav = kept_uav;
    }
    if (!out && (FAILED(dev->CreateTexture2D(&od, NULL, &out)) || FAILED(dev->CreateUnorderedAccessView(out.Get(), NULL, &uav)))) {
      tex.Reset(); surface.Reset(); access.Reset(); fr.Reset();
      drop_on_demand();
      return NULL;
    }
    if (!hdr_convert_gpu(dev.Get(), ctx.Get(), to_tile_max.Get(), to_tile_k.Get(),
                         to_srgb.Get(), to_srgb_k.Get(), srv.Get(), uav.Get(), white, ox, oy, rw, rh)) {
      tex.Reset(); surface.Reset(); access.Reset(); fr.Reset();
      drop_on_demand();
      return NULL;
    }
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
    ComPtr<ID3D11Device> kdev;
    kept_staging->GetDevice(&kdev);
    if (kdev.Get() == dev.Get() && kd.Width == td.Width && kd.Height == td.Height && kd.Format == td.Format)
      staging = kept_staging;
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
  if (one_shot && !long_holds) {
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
    int same_wgc = (d.Get() == dev.Get());
    int same_dd = (d.Get() == dd_dev.Get());
    if (!keep_sessions || (same_wgc && dd_ok == 1)) {
      d3.Reset();
      c.Reset();
      d.Reset();
      if (same_wgc) {
        if (keep_sessions) wgc_dev_teardown();
        else wgc_teardown();
      } else if (same_dd) {
        dd_teardown();
      }
    }
  }
}

extern "C" void ps_wgc_state(char *out, int n) {
  int k = snprintf(out, n, "sessions %d; frames", nmons);
  for (int i = 0; i < nmons && k < n; i++) k += snprintf(out + k, n - k, " %d%s", mons[i].frames, mons[i].hdr ? " hdr" : "");
  if (k < n) k += snprintf(out + k, n - k, "; hr 0x%08lx; ready %d", (unsigned long)last_hr, ready);
  if (dd_black && k < n) snprintf(out + k, n - k, "; dxgi black %d", dd_black);
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
    dd_ok = 0;
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
