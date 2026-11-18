param([string]$Version = "")
# Puts a release's downloads in the R2 bucket `pinshot` (Cloudflare account hisenxpress@gmail.com, wrangler logged in)
# and the download page (site/) on Cloudflare Pages: https://pin-shot.pages.dev. The files: out/setup/
# PinShot-Setup-<Version>.exe (packaging/pack-setup.ps1) and out/build/pinshot.exe, each at v<Version>/ and as the
# latest (PinShot-Setup.exe, pinshot.exe), and latest.json: the version and sizes the page shows, and each file's
# SHA-256, which PinShot's updates check what they download against (app/update.mbt). The version is app/main.mbt's
# app_version unless given. latest.json goes last, once the files it names are there.
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path "$PSScriptRoot\..").Path
$appVersion = (Select-String -Path "$repo\app\main.mbt" -Pattern '^let app_version : String = "([^"]+)"').Matches[0].Groups[1].Value
if (-not $Version) { $Version = $appVersion }
if ($Version -ne $appVersion) { throw "version $Version is not app_version $appVersion (app/main.mbt)" }
$setup = "$repo\out\setup\PinShot-Setup-$Version.exe"
$exe = "$repo\out\build\pinshot.exe"
foreach ($f in $setup, $exe) { if (-not (Test-Path $f)) { throw "missing $f" } }

function Put([string]$file, [string]$key, [string]$type) {
  npx wrangler r2 object put "pinshot/$key" --file $file --content-type $type --remote
  if ($LASTEXITCODE) { throw "upload failed: $key" }
}
Put $setup "v$Version/PinShot-Setup-$Version.exe" "application/octet-stream"
Put $exe "v$Version/pinshot.exe" "application/octet-stream"
Put $setup "PinShot-Setup.exe" "application/octet-stream"
Put $exe "pinshot.exe" "application/octet-stream"
$json = Join-Path $env:TEMP "pinshot-latest.json"
@{
  version = $Version
  setup = (Get-Item $setup).Length
  exe = (Get-Item $exe).Length
  setup_sha256 = (Get-FileHash -Algorithm SHA256 $setup).Hash.ToLower()
  exe_sha256 = (Get-FileHash -Algorithm SHA256 $exe).Hash.ToLower()
} | ConvertTo-Json -Compress |
  Set-Content -NoNewline -Encoding ascii $json
Put $json "latest.json" "application/json"

Push-Location "$repo\site"
try {
  npx wrangler pages deploy --project-name pin-shot --branch main --commit-dirty=true
  if ($LASTEXITCODE) { throw "pages deploy failed" }
} finally { Pop-Location }
