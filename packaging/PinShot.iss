; PinShot's own installer (PinShot-Setup-<version>.exe): out\build\pinshot.exe for the person running it, no
; administrator asked for. Installed where scripts\install.ps1 puts it (%LOCALAPPDATA%\Programs\PinShot), a Start menu
; shortcut (what Raycast and Windows search find), an entry in Settings > Apps to remove it, started with Windows if
; chosen (the same Run value the app's own setting writes). The one running asked to quit first (pinshot.exe --quit).
; Made by packaging\pack-setup.ps1 (Inno Setup 6: winget install JRSoftware.InnoSetup --scope user). Saved as UTF-8
; with a BOM (the Chinese below).

#ifndef AppVer
  #define AppVer "1.0.1"
#endif
#ifndef Repo
  #define Repo ".."
#endif

[Setup]
AppId={{6B0F3C2E-8A41-4F7D-9C55-2E1B7D3A9F10}
AppName=PinShot
AppVersion={#AppVer}
AppVerName=PinShot {#AppVer}
AppPublisher=pengx17
VersionInfoVersion={#AppVer}
DefaultDirName={localappdata}\Programs\PinShot
DisableDirPage=auto
DisableProgramGroupPage=yes
DisableReadyPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.19041
OutputDir={#Repo}\out\setup
OutputBaseFilename=PinShot-Setup-{#AppVer}
SetupIconFile={#Repo}\assets\pinshot.ico
UninstallDisplayIcon={app}\pinshot.exe
UninstallDisplayName=PinShot
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=no
ShowLanguageDialog=auto

[Languages]
Name: "chs"; MessagesFile: "{#Repo}\packaging\ChineseSimplified.isl"
Name: "en"; MessagesFile: "compiler:Default.isl"

[CustomMessages]
chs.AutoStart=开机时自动启动 PinShot
en.AutoStart=Start PinShot with Windows
chs.Launch=立即运行 PinShot
en.Launch=Run PinShot now

[Tasks]
Name: "autostart"; Description: "{cm:AutoStart}"
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; Flags: unchecked

[Files]
Source: "{#Repo}\out\build\pinshot.exe"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{userprograms}\PinShot"; Filename: "{app}\pinshot.exe"; WorkingDir: "{app}"
Name: "{userdesktop}\PinShot"; Filename: "{app}\pinshot.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "PinShot"; ValueData: """{app}\pinshot.exe"""; Tasks: autostart
; (removed as it is uninstalled, whether it was set here or by the app's own setting)
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: none; ValueName: "PinShot"; Flags: uninsdeletevalue

[Run]
Filename: "{app}\pinshot.exe"; Description: "{cm:Launch}"; Flags: nowait postinstall skipifsilent

[Code]
// The one running asked to quit (it is replaced or removed), and given a moment to.
procedure QuitRunning(const Exe: String);
var
  Code: Integer;
  I: Integer;
begin
  if not FileExists(Exe) then Exit;
  Exec(Exe, '--quit', '', SW_HIDE, ewWaitUntilTerminated, Code);
  // (until it is gone: a running exe cannot be deleted, and it is about to be replaced or removed anyway; at most 5 s)
  for I := 1 to 25 do
  begin
    if DeleteFile(Exe) then Exit;
    Sleep(200);
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  QuitRunning(ExpandConstant('{app}\pinshot.exe'));
  Result := '';
end;

function InitializeUninstall(): Boolean;
begin
  QuitRunning(ExpandConstant('{app}\pinshot.exe'));
  Result := True;
end;
