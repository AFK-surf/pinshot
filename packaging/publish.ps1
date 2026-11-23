param([string]$Version = "")
# Puts a release's downloads in the R2 bucket `pinshot` (Cloudflare account hisenxpress@gmail.com, wrangler logged in)
# and the download page (site/) on Cloudflare Pages: https://pin-shot.pages.dev. PinShot on Windows is a single
# self-installing executable (out/build/pinshot.exe); it is uploaded as pinshot.exe (and mirrored as PinShot-Setup*.exe
# with matching setup_sha256 so existing <= 1.0.24 Inno Setup installs upgrade seamlessly via /UPDATE into the
# single-file install), along with signed latest.json (packaging/sign-release.ps1, key in $env:PINSHOT_SIGN_KEY).
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path "$PSScriptRoot\..").Path
$appVersion = (Select-String -Path "$repo\app\main.mbt" -Pattern '^let app_version : String = "([^"]+)"').Matches[0].Groups[1].Value
if (-not $Version) { $Version = $appVersion }
if ($Version -ne $appVersion) { throw "version $Version is not app_version $appVersion (app/main.mbt)" }
$exe = "$repo\out\build\pinshot.exe"
if (-not (Test-Path $exe)) { throw "missing $exe" }

function Put([string]$file, [string]$key, [string]$type) {
  npx wrangler r2 object put "pinshot/$key" --file $file --content-type $type --remote
  if ($LASTEXITCODE) { throw "upload failed: $key" }
}
# (signed first: with no key at hand, nothing is put anywhere)
$json = Join-Path $env:TEMP "pinshot-latest.json"
$exeSize = (Get-Item $exe).Length
$exeSha = (Get-FileHash -Algorithm SHA256 $exe).Hash.ToLower()
@{
  version = $Version
  setup = $exeSize
  exe = $exeSize
  setup_sha256 = $exeSha
  exe_sha256 = $exeSha
  signature = & "$PSScriptRoot\sign-release.ps1" -Version $Version -SetupSha $exeSha -ExeSha $exeSha
} | ConvertTo-Json -Compress |
  Set-Content -NoNewline -Encoding ascii $json
Put $exe "v$Version/pinshot.exe" "application/octet-stream"
Put $exe "pinshot.exe" "application/octet-stream"
# Keep legacy PinShot-Setup paths pointing to the same self-installing exe for seamless upgrade from <= 1.0.24
Put $exe "v$Version/PinShot-Setup-$Version.exe" "application/octet-stream"
Put $exe "PinShot-Setup.exe" "application/octet-stream"
Put $json "latest.json" "application/json"

Push-Location "$repo\site"
try {
  npx wrangler pages deploy --project-name pin-shot --branch main --commit-dirty=true
  if ($LASTEXITCODE) { throw "pages deploy failed" }
} finally { Pop-Location }
