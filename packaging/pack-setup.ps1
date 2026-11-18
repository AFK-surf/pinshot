param([string]$Version = "1.0.1")
# Makes PinShot's own installer, out\setup\PinShot-Setup-<Version>.exe, from out\build\pinshot.exe (scripts\build.ps1
# first) with Inno Setup 6 (winget install JRSoftware.InnoSetup --scope user).
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path "$PSScriptRoot\..").Path
$iscc = @("$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe", "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe") |
  Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { throw "Inno Setup 6 not found: winget install JRSoftware.InnoSetup --scope user" }
& $iscc /Q "/DAppVer=$Version" "/DRepo=$repo" "$repo\packaging\PinShot.iss"
if ($LASTEXITCODE) { throw "ISCC failed: $LASTEXITCODE" }
Get-Item "$repo\out\setup\PinShot-Setup-$Version.exe"
