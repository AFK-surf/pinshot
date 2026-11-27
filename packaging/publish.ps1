param([string]$Version = "", [switch]$NoMac)
# Puts a release's downloads in the R2 bucket `pinshot` (Cloudflare account hisenxpress@gmail.com, wrangler logged in)
# and the download page (site/) on Cloudflare Pages: https://pin-shot.pages.dev. PinShot on Windows is a single
# self-installing executable (out/Release/pinshot.exe); it is uploaded as pinshot.exe (and mirrored as PinShot-Setup*.exe
# with matching setup_sha256 so existing <= 1.0.24 Inno Setup installs upgrade seamlessly via /UPDATE into the
# single-file install), along with signed latest.json (packaging/sign-release.ps1, key in $env:PINSHOT_SIGN_KEY).
# The macOS build is the tag's: PinShot-mac.dmg (for website/user downloads) and PinShot-mac.zip (for in-app auto-update
# via native/update_mac.m), both signed with AFK AI's Developer ID and notarized by the macOS package workflow and
# attached to the GitHub release v<version> (gh, logged in), waited for here, uploaded to R2 and recorded in latest.json
# with mac_sha256 / mac_signature (for the zip) and mac_dmg / mac_dmg_sha256 (for the dmg) (-NoMac: Windows alone).
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path "$PSScriptRoot\..").Path
$appVersion = (Select-String -Path "$repo\src\main.pion" -Pattern '^let app_version : String = "([^"]+)"').Matches[0].Groups[1].Value
if (-not $Version) { $Version = $appVersion }
if ($Version -ne $appVersion) { throw "version $Version is not app_version $appVersion (src/main.pion)" }
$exe = "$repo\out\Release\pinshot.exe"
if (-not (Test-Path $exe)) { throw "missing $exe" }
$mac = $null
$macDmg = $null
if (-not $NoMac) {
  $mac = Join-Path $env:TEMP "PinShot-mac-$Version.zip"
  $macDmg = Join-Path $env:TEMP "PinShot-mac-$Version.dmg"
  Remove-Item -Force -ErrorAction SilentlyContinue $mac, $macDmg
  # (the workflow takes some 10 minutes from the tag: notarizing is Apple's queue)
  for ($i = 0; $i -lt 90; $i++) {
    if (-not (Test-Path $mac)) {
      gh release download "v$Version" -R AFK-surf/pinshot -p PinShot-mac.zip -O $mac --clobber 2>$null
    }
    if (-not (Test-Path $macDmg)) {
      gh release download "v$Version" -R AFK-surf/pinshot -p PinShot-mac.dmg -O $macDmg --clobber 2>$null
    }
    if ((Test-Path $mac) -and (Test-Path $macDmg)) { break }
    if ($i -eq 0) { Write-Host "waiting for PinShot-mac.dmg and PinShot-mac.zip on release v$Version (the macOS package workflow)..." }
    Start-Sleep 20
  }
  if (-not (Test-Path $mac) -or -not (Test-Path $macDmg)) { throw "missing PinShot-mac.dmg or PinShot-mac.zip on release v${Version}: see the macOS package workflow, or -NoMac" }
}

function Put([string]$file, [string]$key, [string]$type) {
  npx wrangler r2 object put "pinshot/$key" --file $file --content-type $type --remote
  if ($LASTEXITCODE) { throw "upload failed: $key" }
}
# (signed first: with no key at hand, nothing is put anywhere)
$json = Join-Path $env:TEMP "pinshot-latest.json"
$exeSize = (Get-Item $exe).Length
$exeSha = (Get-FileHash -Algorithm SHA256 $exe).Hash.ToLower()
$latest = @{
  version = $Version
  setup = $exeSize
  exe = $exeSize
  setup_sha256 = $exeSha
  exe_sha256 = $exeSha
  signature = & "$PSScriptRoot\sign-release.ps1" -Version $Version -SetupSha $exeSha -ExeSha $exeSha
}
if ($mac) {
  # (the zip named as both files Windows names: what update_mac.m checks the signature of)
  $macSha = (Get-FileHash -Algorithm SHA256 $mac).Hash.ToLower()
  $latest.mac = (Get-Item $mac).Length
  $latest.mac_sha256 = $macSha
  $latest.mac_signature = & "$PSScriptRoot\sign-release.ps1" -Version $Version -SetupSha $macSha -ExeSha $macSha
}
if ($macDmg) {
  $latest.mac_dmg = (Get-Item $macDmg).Length
  $latest.mac_dmg_sha256 = (Get-FileHash -Algorithm SHA256 $macDmg).Hash.ToLower()
}
$latest | ConvertTo-Json -Compress |
  Set-Content -NoNewline -Encoding ascii $json
Put $exe "v$Version/pinshot.exe" "application/octet-stream"
Put $exe "pinshot.exe" "application/octet-stream"
# Keep legacy PinShot-Setup paths pointing to the same self-installing exe for seamless upgrade from <= 1.0.24
Put $exe "v$Version/PinShot-Setup-$Version.exe" "application/octet-stream"
Put $exe "PinShot-Setup.exe" "application/octet-stream"
if ($mac) {
  Put $mac "v$Version/PinShot-mac.zip" "application/zip"
  Put $mac "PinShot-mac.zip" "application/zip"
}
if ($macDmg) {
  Put $macDmg "v$Version/PinShot-mac.dmg" "application/x-apple-diskimage"
  Put $macDmg "PinShot-mac.dmg" "application/x-apple-diskimage"
}
Put $json "latest.json" "application/json"

Push-Location "$repo\site"
try {
  npx wrangler pages deploy --project-name pin-shot --branch main --commit-dirty=true
  if ($LASTEXITCODE) { throw "pages deploy failed" }
} finally { Pop-Location }
