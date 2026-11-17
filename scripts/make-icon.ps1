# assets\icon.png (1024², rendered from assets\icon.svg) into assets\pinshot.ico: 16 to 256 pixels, each a PNG inside
# the ICO (the exe's icon, the notification area's, the windows').
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path "$PSScriptRoot\..").Path
Add-Type -AssemblyName System.Drawing
$src = [System.Drawing.Image]::FromFile("$repo\assets\icon.png")
$sizes = 16, 20, 24, 32, 40, 48, 64, 128, 256
$pngs = foreach ($n in $sizes) {
  $b = New-Object System.Drawing.Bitmap $n, $n
  $g = [System.Drawing.Graphics]::FromImage($b)
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
  $g.Clear([System.Drawing.Color]::Transparent)
  $g.DrawImage($src, 0, 0, $n, $n)
  $ms = New-Object IO.MemoryStream
  $b.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $b.Dispose()
  , $ms.ToArray()
}
$src.Dispose()
$out = New-Object IO.MemoryStream
$w = New-Object IO.BinaryWriter $out
$w.Write([UInt16]0); $w.Write([UInt16]1); $w.Write([UInt16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
  $n = $sizes[$i]
  $w.Write([byte]($(if ($n -ge 256) { 0 } else { $n }))); $w.Write([byte]($(if ($n -ge 256) { 0 } else { $n })))
  $w.Write([byte]0); $w.Write([byte]0); $w.Write([UInt16]1); $w.Write([UInt16]32)
  $w.Write([UInt32]$pngs[$i].Length); $w.Write([UInt32]$offset)
  $offset += $pngs[$i].Length
}
foreach ($p in $pngs) { $w.Write($p) }
[IO.File]::WriteAllBytes("$repo\assets\pinshot.ico", $out.ToArray())
"assets\pinshot.ico: $($sizes -join ', ')"
