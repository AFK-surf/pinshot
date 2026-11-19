; PinShot's own installer (PinShot-Setup-<version>.exe): out\build\pinshot.exe for the person running it, no
; administrator asked for. Installed where scripts\install.ps1 puts it (%LOCALAPPDATA%\Programs\PinShot), a Start menu
; shortcut (what Raycast and Windows search find), an entry in Settings > Apps to remove it, started with Windows if
; chosen (the same Run value the app's own setting writes). The one running asked to quit first (pinshot.exe --quit).
;
; Run by PinShot itself to update (app/update_win.c: /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /UPDATE): the
; choices made as it was first installed are kept as they are now (start with Windows as the app's setting left it, the
; desktop icon not made again), and PinShot is started again, told it was updated (--updated).
; Made by packaging\pack-setup.ps1 (Inno Setup 6: winget install JRSoftware.InnoSetup --scope user). Saved as UTF-8
; with a BOM (the Chinese below).

; (AppVer: app/main.mbt's app_version, given by pack-setup.ps1)
#ifndef AppVer
  #error AppVer not given: packaging\pack-setup.ps1 gives it
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
Name: "{userdesktop}\PinShot"; Filename: "{app}\pinshot.exe"; WorkingDir: "{app}"; Tasks: desktopicon; Check: not IsUpdate

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "PinShot"; ValueData: """{app}\pinshot.exe"""; Tasks: autostart; Check: not IsUpdate
; (removed as it is uninstalled, whether it was set here or by the app's own setting)
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: none; ValueName: "PinShot"; Flags: uninsdeletevalue

[Run]
Filename: "{app}\pinshot.exe"; Description: "{cm:Launch}"; Flags: nowait postinstall skipifsilent
; (an update started from PinShot: started again, silently as it is)
Filename: "{app}\pinshot.exe"; Parameters: "--updated"; Flags: nowait; Check: IsUpdate

[Code]
// Whether PinShot runs this installer to update itself (/UPDATE).
function IsUpdate(): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 1 to ParamCount do
    if CompareText(ParamStr(I), '/UPDATE') = 0 then
    begin
      Result := True;
      Exit;
    end;
end;

// Whether the install went through (a run ended before that, by an error or the one running not quitting, did not).
var
  Installed: Boolean;

// The one running asked to quit (it is replaced or removed), and given a moment to: True once it is gone. A running
// exe cannot be deleted, so that is what is tried, on the exe with a copy of it kept beside it and put back at once:
// should the install then not go through, PinShot is still there as it was. At most 5 s.
function QuitRunning(const Exe: String): Boolean;
var
  Code: Integer;
  I: Integer;
begin
  Result := True;
  if not FileExists(Exe) then Exit;
  Exec(Exe, '--quit', '', SW_HIDE, ewWaitUntilTerminated, Code);
  for I := 1 to 25 do
  begin
    if FileCopy(Exe, Exe + '.probe', False) then
    begin
      if DeleteFile(Exe) then
      begin
        RenameFile(Exe + '.probe', Exe);
        Exit;
      end;
      DeleteFile(Exe + '.probe');
    end;
    Sleep(200);
  end;
  Result := False;
end;

// The one running quit before anything is changed; where it would not, nothing is installed and setup ends with an
// error (code 7): an update run silently never leaves PinShot half replaced, and the run that started it, still there,
// says the update was not put in place (app/update_win.c).
function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  if QuitRunning(ExpandConstant('{app}\pinshot.exe')) then
    Result := ''
  else
    Result := 'PinShot is still running: quit it from its icon and run the installer again.';
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssDone then Installed := True;
end;

// An update that did not go through: PinShot started again as it was (--start: where it is still running, nothing),
// so it never disappears because an update failed.
procedure DeinitializeSetup();
var
  Code: Integer;
begin
  if IsUpdate() and not Installed and FileExists(ExpandConstant('{app}\pinshot.exe')) then
    Exec(ExpandConstant('{app}\pinshot.exe'), '--start', '', SW_SHOWNORMAL, ewNoWait, Code);
end;

function InitializeUninstall(): Boolean;
begin
  QuitRunning(ExpandConstant('{app}\pinshot.exe'));
  Result := True;
end;
