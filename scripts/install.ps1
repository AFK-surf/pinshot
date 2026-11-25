# Installs the build (out\build\pinshot.exe) for this person: %LOCALAPPDATA%\Programs\PinShot\pinshot.exe, a Start
# menu shortcut to it (what launchers such as Raycast and Windows search find), the one running there asked to quit
# first, then started again. Both the quitting and the starting go through the Task Scheduler on the person's own
# desktop: an agent's runner may sit on a desktop of its own (2026-11-18), where Explorer starts it unseen (no icon, no
# shortcuts) and `--quit` finds no window to tell.
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$src = Join-Path $root "out\Release\pinshot.exe"
if (-not (Test-Path $src)) { $src = Join-Path $root "out\build\pinshot.exe" }
$dir = Join-Path $env:LOCALAPPDATA "Programs\PinShot"
$exe = Join-Path $dir "pinshot.exe"
New-Item -ItemType Directory -Force $dir | Out-Null

function On-Desktop([string]$what) {
  $ErrorActionPreference = "Continue"
  schtasks /create /tn PinShotInstall /tr $what /sc once /st 00:00 /it /f 2>$null | Out-Null
  schtasks /run /tn PinShotInstall | Out-Null
  Start-Sleep -Milliseconds 800
  schtasks /delete /tn PinShotInstall /f | Out-Null
}

$running = @(Get-CimInstance Win32_Process -Filter "Name='pinshot.exe'" | Where-Object { $_.ExecutablePath -eq $exe })
if ($running) {
  On-Desktop "`"$exe`" --quit"
  foreach ($p in $running) {
    $proc = Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue
    if ($proc -and -not $proc.WaitForExit(5000)) { throw "PinShot ($($p.ProcessId)) did not quit" }
  }
}
Copy-Item -Force $src $exe

$lnk = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\PinShot.lnk"
$s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
$s.TargetPath = $exe
$s.WorkingDirectory = $dir
$s.IconLocation = "$exe,0"
$s.Description = "PinShot"
$s.Save()

$log = Join-Path $env:APPDATA "PinShot\pinshot.log"
$before = if (Test-Path $log) { (Get-Item $log).Length } else { 0 }
On-Desktop "`"$exe`""
Start-Sleep 3
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
