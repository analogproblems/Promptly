; The Windows installer, built with Inno Setup 6 by tools/windows-installer.ps1:
;
;   tools\windows-installer.ps1 app\build\windows\x64\runner\Release 1.0.2 dist
;
; It installs for the current user (no administrator prompt), into
; %LOCALAPPDATA%\Programs\Promptly, with a Start menu entry and an
; uninstaller under Settings, Apps. Settings, hosts and keys live in the
; user's AppData, not here, so updating or uninstalling leaves them alone.
;
; The app updates itself by running a newer copy of this installer with
; /SILENT /CLOSEAPPLICATIONS (app/lib/features/updates/updates.dart). Two
; things here make that work: the fixed AppId, which makes a new version
; replace the old one in place, and the [Run] entry, which opens Promptly
; again after a silent install (it is a checkbox when installing by hand).
; The app spots an installed copy by unins000.exe next to promptly.exe.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #error Pass /DSourceDir=<the Release bundle folder>
#endif
#ifndef OutputDir
  #define OutputDir "dist"
#endif

[Setup]
; Never change the AppId: it is how Windows knows a new version is Promptly.
AppId={{947BD29E-9C02-4A1F-BAD2-01877D3AC8FB}
AppName=Promptly
AppVersion={#AppVersion}
AppVerName=Promptly {#AppVersion}
AppPublisher=The Promptly authors
AppPublisherURL=https://analogproblems.github.io/Promptly/
AppSupportURL=https://github.com/analogproblems/Promptly/issues
AppUpdatesURL=https://github.com/analogproblems/Promptly/releases
VersionInfoVersion={#AppVersion}
DefaultDirName={autopf}\Promptly
DisableProgramGroupPage=yes
DisableDirPage=auto
DisableReadyPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputDir}
OutputBaseFilename=promptly-{#AppVersion}-windows-x64-setup
SetupIconFile=..\app\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\promptly.exe
UninstallDisplayName=Promptly
WizardStyle=modern
Compression=lzma2
SolidCompression=yes
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[InstallDelete]
; Flutter's own files from the version being replaced (not user data).
Type: filesandordirs; Name: "{app}\data"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\LICENSE"; DestDir: "{app}"; DestName: "LICENSE.txt"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\Promptly"; Filename: "{app}\promptly.exe"
Name: "{autodesktop}\Promptly"; Filename: "{app}\promptly.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\promptly.exe"; Description: "{cm:LaunchProgram,Promptly}"; Flags: nowait postinstall
