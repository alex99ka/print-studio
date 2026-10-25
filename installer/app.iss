; Windows installer. Built by the release workflow (and by hand with
; `iscc /DAppVersion=1.2.3 installer\app.iss`). Saved as UTF-8 *with BOM*:
; Inno Setup reads Hebrew only from a BOM file; keep it when editing.
; Per-user install: no administrator prompt, an uninstaller in Settings > Apps.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#define AppName "סטודיו הדפסה"
#define AppExe "print_studio.exe"

[Setup]
; Never change AppId: it is how an update recognises the installed copy.
; A new app generates its own once (python -c "import uuid;print(uuid.uuid4())").
AppId={{67DD8708-5429-4CF3-BE11-639B92364CBA}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=alex99ka
DefaultDirName={localappdata}\Programs\PrintStudio
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\dist
; The updater looks for "-setup-" and ".exe" (lib/core/update.dart, assetFor).
OutputBaseFilename=print-studio-setup-{#AppVersion}
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
; An update closes the running app instead of failing on a locked file.
CloseApplications=yes
RestartApplications=no

[Tasks]
Name: "desktopicon"; Description: "קיצור דרך בשולחן העבודה"

[Files]
; The Flutter release bundle, with the Visual C++ runtime copied in by the
; workflow so the app starts on a PC that never installed it.
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"; WorkingDir: "{app}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
; Not skipifsilent: the updater's "update now" runs this with /SILENT and the
; new version should open when done. Closing the window with an update ready
; runs it with /VERYSILENT /nolaunch=1: closed on purpose, so not reopened.
Filename: "{app}\{#AppExe}"; Description: "פתיחת {#AppName}"; Flags: nowait postinstall; Check: Launch

[Code]
function Launch: Boolean;
begin
  Result := ExpandConstant('{param:nolaunch|0}') <> '1';
end;
