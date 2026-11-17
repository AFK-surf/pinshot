param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release",
    [switch]$Loose
)

# Builds PinShot into out\pinshot.exe. Needs Visual Studio 2022 with C++, Git Bash and MoonBit on PATH.
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$vcvars = "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
$bash = "C:\Program Files\Git\bin\bash.exe"
$mode = if ($Configuration -eq "Release") { "release" } else { "debug" }
$strictVal = if ($Loose) { "0" } else { "1" }
& cmd /c "`"$vcvars`" >nul && set `"MODE=$mode`" && set `"STRICT=$strictVal`" && `"$bash`" `"$root\scripts\build.sh`""
exit $LASTEXITCODE
