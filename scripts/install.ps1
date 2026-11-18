# Installs the build (out\build\pinshot.exe) for this person: %LOCALAPPDATA%\Programs\PinShot\pinshot.exe, a Start
# menu shortcut to it (what launchers such as Raycast and Windows search find), the one running there asked to quit
# first, then started again by the Task Scheduler on the person's own desktop (not a child of whatever ran this script;
# Explorer started from an agent's runner can put it on a desktop nobody sees, 2026-11-18: no icon, no shortcuts).
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

$lnk = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\PinShot.lnk"
$sh = New-Object -ComObject WScript.Shell
$s = $sh.CreateShortcut($lnk)
$s.TargetPath = $exe
$s.WorkingDirectory = $dir
$s.IconLocation = "$exe,0"
$s.Description = "PinShot"
$s.Save()

$log = Join-Path $env:APPDATA "PinShot\pinshot.log"
$before = if (Test-Path $log) { (Get-Item $log).Length } else { 0 }
schtasks /create /tn PinShotStart /tr "`"$exe`"" /sc once /st 00:00 /it /f 2>$null | Out-Null
schtasks /run /tn PinShotStart | Out-Null
Start-Sleep 4
schtasks /delete /tn PinShotStart /f | Out-Null
$said = ""
if (Test-Path $log) {
  $fs = [IO.File]::Open($log, 'Open', 'Read', 'ReadWrite')
  $null = $fs.Seek($before, 'Begin')
  $said = (New-Object IO.StreamReader($fs)).ReadToEnd()
  $fs.Close()
}
Write-Host "installed: $exe"
Write-Host $said
if ($said -notmatch "icon shown" -or $said -notmatch "capture \S+ ok") { Write-Error "started wrong (see the log above)" }
