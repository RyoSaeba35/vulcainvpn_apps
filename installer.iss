#define MyAppName "Vulcain VPN"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "RyoSaeba35"
#define MyAppExeName "vulcain_vpn.exe"

[Setup]
AppId={{B7F3A1C9-D24E-4B8F-9E6D-3C5A2F1E0D7B}}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
OutputDir=installer-output
OutputBaseFilename=VulcainVPN-Setup
Compression=lzma
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
SetupIconFile=windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional icons:"

[Files]
Source: "build\windows\x64\runner\Release\*.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "build\windows\x64\runner\Release\*.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "build\windows\x64\runner\Release\data\*"; DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "schtasks.exe"; Parameters: "/Run /TN ""VulcainVPN\Launch"""; IconFilename: "{app}\{#MyAppExeName}"; AppUserModelID: "VulcainVPN"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "schtasks.exe"; Parameters: "/Run /TN ""VulcainVPN\Launch"""; IconFilename: "{app}\{#MyAppExeName}"; AppUserModelID: "VulcainVPN"; Tasks: desktopicon

[Run]
; Register the scheduled task
Filename: "schtasks"; Parameters: "/Create /TN ""VulcainVPN\Launch"" /TR ""{app}\vulcain_vpn.exe"" /SC ONDEMAND /RL HIGHEST /F"; Flags: runhidden waituntilterminated

; Launch app after install via the task
Filename: "schtasks"; Parameters: "/Run /TN ""VulcainVPN\Launch"""; Flags: runhidden; Description: "Launching {#MyAppName}..."; StatusMsg: "Starting Vulcain VPN..."

[UninstallRun]
; Remove the scheduled task on uninstall
Filename: "schtasks"; Parameters: "/Delete /TN ""VulcainVPN\Launch"" /F"; Flags: runhidden
