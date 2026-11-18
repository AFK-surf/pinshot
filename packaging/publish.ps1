param([Parameter(Mandatory = $true)][string]$Version)
# Puts a release's downloads in the R2 bucket `pinshot` (Cloudflare account hisenxpress@gmail.com, wrangler logged in)
# and the download page (site/) on Cloudflare Pages: https://pinshot.pages.dev. The files: out/setup/
# PinShot-Setup-<Version>.exe (packaging/pack-setup.ps1) and out/build/pinshot.exe, each at v<Version>/ and as the
# latest (PinShot-Setup.exe, pinshot.exe), and latest.json (the version and sizes the page shows).
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path "$PSScriptRoot\..").Path
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
@{ version = $Version; setup = (Get-Item $setup).Length; exe = (Get-Item $exe).Length } | ConvertTo-Json -Compress |
  Set-Content -NoNewline -Encoding ascii $json
Put $json "latest.json" "application/json"

Push-Location "$repo\site"
try {
  npx wrangler pages deploy --project-name pinshot --branch main --commit-dirty=true
  if ($LASTEXITCODE) { throw "pages deploy failed" }
} finally { Pop-Location }
