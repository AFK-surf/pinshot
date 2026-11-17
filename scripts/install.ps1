# Installs the build (out\build\pinshot.exe) for this person: %LOCALAPPDATA%\Programs\PinShot\pinshot.exe, the one
# running there asked to quit first, then started again by Explorer (so it is not a child of whatever ran this script).
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$src = Join-Path $root "out\build\pinshot.exe"
$dir = Join-Path $env:LOCALAPPDATA "Programs\PinShot"
$exe = Join-Path $dir "pinshot.exe"
New-Item -ItemType Directory -Force $dir | Out-Null
$running = Get-CimInstance Win32_Process -Filter "Name='pinshot.exe'" | Where-Object { $_.ExecutablePath -eq $exe }
if ($running) {
  & $exe --quit
  foreach ($p in $running) {
    $proc = Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue
    if ($proc) { $null = $proc.WaitForExit(3000) }
  }
}
Copy-Item -Force $src $exe
Start-Process explorer.exe -ArgumentList "`"$exe`""
Write-Host "installed: $exe"
