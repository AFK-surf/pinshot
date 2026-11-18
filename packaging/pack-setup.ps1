param([string]$Version = "")
# Makes PinShot's own installer, out\setup\PinShot-Setup-<Version>.exe, from out\build\pinshot.exe (scripts\build.ps1
# first) with Inno Setup 6 (winget install JRSoftware.InnoSetup --scope user). The version is app/main.mbt's
# app_version unless given: the one the exe says it is, which its updates compare with latest.json.
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path "$PSScriptRoot\..").Path
$appVersion = (Select-String -Path "$repo\app\main.mbt" -Pattern '^let app_version : String = "([^"]+)"').Matches[0].Groups[1].Value
if (-not $Version) { $Version = $appVersion }
if ($Version -ne $appVersion) { throw "version $Version is not app_version $appVersion (app/main.mbt): the exe would offer itself as an update" }
$iscc = @("$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe", "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe") |
  Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { throw "Inno Setup 6 not found: winget install JRSoftware.InnoSetup --scope user" }
& $iscc /Q "/DAppVer=$Version" "/DRepo=$repo" "$repo\packaging\PinShot.iss"
if ($LASTEXITCODE) { throw "ISCC failed: $LASTEXITCODE" }
Get-Item "$repo\out\setup\PinShot-Setup-$Version.exe"
