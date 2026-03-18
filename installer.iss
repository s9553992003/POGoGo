; POGoGo Windows Installer — Inno Setup 6
; No admin required. Tunneld runs as a subprocess of the app.
; Output: output\POGoGo-Setup.exe

#define AppName "POGoGo"
#define AppVersion "1.0.0"
#define AppPublisher "POGoGo"
#define AppExeName "POGoGo.exe"
[Setup]
AppId={{A1B2C3D4-E5F6-7890-ABCD-EF1234567890}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={localappdata}\{#AppName}
DefaultGroupName={#AppName}
AllowNoIcons=yes
OutputDir=output
OutputBaseFilename=POGoGo-Setup
SetupIconFile=resources\icon.ico
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64
MinVersion=10.0.17763
; No admin needed — installs to %LOCALAPPDATA%
PrivilegesRequired=lowest

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "Shortcuts:"; Flags: unchecked
Name: "startup";    Description: "Launch POGoGo on Windows startup";    GroupDescription: "Options:";   Flags: unchecked

[Files]
Source: "dist\POGoGo\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "resources\icon.ico"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#AppName}";          Filename: "{app}\{#AppExeName}"; IconFilename: "{app}\icon.ico"
Name: "{group}\Uninstall {#AppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}";    Filename: "{app}\{#AppExeName}"; IconFilename: "{app}\icon.ico"; Tasks: desktopicon

[Registry]
; Per-user app path (no admin)
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\App Paths\POGoGo.exe"; \
    ValueType: string; ValueName: ""; ValueData: "{app}\{#AppExeName}"; Flags: uninsdeletekey

; Startup entry (only if user chose the task)
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; \
    ValueType: string; ValueName: "POGoGo"; ValueData: """{app}\{#AppExeName}"""; \
    Flags: uninsdeletevalue; Tasks: startup

[Run]
; Launch app immediately after install
Filename: "{app}\{#AppExeName}"; \
    Description: "{cm:LaunchProgram,{#StringChange(AppName, '&', '&&')}}"; \
    Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{%TEMP}\pogogo"

[Code]
procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then begin
    // Pre-create temp dir for tunneld log
    CreateDir(ExpandConstant('{%TEMP}\pogogo'));
  end;
end;
