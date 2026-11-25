param(
  # Partner Center's Product identity of the reserved name (Store ID 9PG140MHXTBM, reserved 2026-11-17; PFN pengx17.PinShot_3t6r3b27cpzdr)
  [string]$Name = "pengx17.PinShot",
  [string]$Publisher = "CN=0A62AE73-FF5C-4B40-9E2B-F24486072C86",
  [string]$PublisherDisplayName = "pengx17",
  [string]$Version = "1.0.32.0",
  [string]$Out = ""
)
# Makes PinShot's MSIX for the Microsoft Store: out\Release\pinshot.exe (scripts\build.ps1) as it is (one file, nothing
# beside it), the tiles made from assets\icon.png, the manifest filled in, and makeappx's package. Unsigned: the Store
# signs what it is given; a local test signs it with signtool and a certificate whose subject is $Publisher.
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path "$PSScriptRoot\..").Path
if (-not $Out) { $Out = "$repo\out\msix" }
$Out = [IO.Path]::GetFullPath($Out)
$stage = Join-Path $Out 'stage'
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force "$stage\Assets" | Out-Null

Copy-Item "$repo\out\Release\pinshot.exe" $stage
$git = (git -C $repo rev-parse --short HEAD).Trim()
Set-Content -Path "$stage\build.txt" -Value "$Version $git" -Encoding ascii

Add-Type -AssemblyName System.Drawing
$icon = [System.Drawing.Image]::FromFile("$repo\assets\icon.png")
function Tile([string]$file, [int]$w, [int]$h, [double]$part) {
  $b = New-Object System.Drawing.Bitmap $w, $h
  $g = [System.Drawing.Graphics]::FromImage($b)
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $g.Clear([System.Drawing.Color]::Transparent)
  $s = [int]([Math]::Min($w, $h) * $part)
  $g.DrawImage($icon, [int](($w - $s) / 2), [int](($h - $s) / 2), $s, $s)
  $b.Save("$stage\Assets\$file", [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $b.Dispose()
}
foreach ($k in 100, 200) {
  $f = $k / 100
  Tile "StoreLogo.scale-$k.png" ([int](50 * $f)) ([int](50 * $f)) 1.0
  Tile "Square44x44Logo.scale-$k.png" ([int](44 * $f)) ([int](44 * $f)) 1.0
  Tile "Square150x150Logo.scale-$k.png" ([int](150 * $f)) ([int](150 * $f)) 0.66
  Tile "Wide310x150Logo.scale-$k.png" ([int](310 * $f)) ([int](150 * $f)) 0.66
}
foreach ($n in 16, 24, 32, 48, 256) {
  Tile "Square44x44Logo.targetsize-$n.png" $n $n 1.0
  Tile "Square44x44Logo.targetsize-$($n)_altform-unplated.png" $n $n 1.0
}
$icon.Dispose()

$m = Get-Content "$PSScriptRoot\AppxManifest.xml" -Raw -Encoding utf8
foreach ($k in 'Name', 'Publisher', 'PublisherDisplayName', 'Version') {
  $m = $m.Replace("`$$k`$", [Security.SecurityElement]::Escape((Get-Variable $k).Value))
}
[IO.File]::WriteAllText("$stage\AppxManifest.xml", $m, (New-Object Text.UTF8Encoding $false))

$kits = "${env:ProgramFiles(x86)}\Windows Kits\10\bin"
$makepri = Get-ChildItem "$kits\*\x64\makepri.exe" | Sort-Object FullName | Select-Object -Last 1
$makeappx = Get-ChildItem "$kits\*\x64\makeappx.exe" | Sort-Object FullName | Select-Object -Last 1
# (the scaled tiles found by their names: resources.pri)
& $makepri.FullName createconfig /cf "$Out\priconfig.xml" /dq en-US /o | Out-Null
& $makepri.FullName new /pr $stage /cf "$Out\priconfig.xml" /of "$stage\resources.pri" /o | Out-Null
if ($LASTEXITCODE -ne 0) { throw "makepri failed" }
$msix = Join-Path $Out "PinShot_$($Version)_x64.msix"
& $makeappx.FullName pack /o /d $stage /p $msix | Out-Null
if ($LASTEXITCODE -ne 0) { throw "makeappx failed" }
"$msix ($([Math]::Round((Get-Item $msix).Length / 1MB, 2)) MB)"
