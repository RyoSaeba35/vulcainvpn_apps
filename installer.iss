#define MyAppName "Vulcain VPN"
#define MyAppVersion "1.0.7"
#define MyAppPublisher "VulcainVPN"
#define MyAppExeName "vulcain_vpn.exe"

[Setup]
AppId={{B7F3A1C9-D24E-4B8F-9E6D-3C5A2F1E0D7B}}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf64}\{#MyAppName}
DefaultGroupName={#MyAppName}
OutputDir=installer-output
OutputBaseFilename=VulcainVPN-Setup-{#MyAppVersion}
Compression=lzma
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesInstallIn64BitMode=x64
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
Source: "setup_task.bat"; DestDir: "{app}"; Flags: ignoreversion
Source: "show_app.bat"; DestDir: "{app}"; Flags: ignoreversion
Source: "show_app.vbs"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\show_app.vbs"; IconFilename: "{app}\{#MyAppExeName}"; AppUserModelID: "VulcainVPN"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\show_app.vbs"; IconFilename: "{app}\{#MyAppExeName}"; AppUserModelID: "VulcainVPN"; Tasks: desktopicon

[Run]
Filename: "{app}\setup_task.bat"; Flags: runhidden waituntilterminated
Filename: "{cmd}"; Parameters: "/c schtasks /Run /TN ""VulcainVPN\Launch"""; Flags: runhidden; Description: "Launching {#MyAppName}..."; StatusMsg: "Starting Vulcain VPN..."

[UninstallRun]
Filename: "{cmd}"; Parameters: "/c schtasks /Delete /TN ""VulcainVPN\Launch"" /F"; Flags: runhidden

[Code]
function InitializeUninstall(): Boolean;
var
  ResultCode: Integer;
  TempFile: String;
  FileContent: AnsiString;
begin
  TempFile := ExpandConstant('{tmp}\proccheck.txt');

  Exec(ExpandConstant('{sys}\cmd.exe'),
    '/c tasklist /FI "IMAGENAME eq vulcain_vpn.exe" /NH > "' + TempFile + '" 2>&1',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode);

  if LoadStringFromFile(TempFile, FileContent) then
  begin
    if Pos('vulcain_vpn.exe', FileContent) > 0 then
    begin
      MsgBox(
        'Vulcain VPN is currently running.' + #13#10 + #13#10 +
        'Please close it before uninstalling:' + #13#10 + #13#10 +
        '  1. Click the ^ arrow in the bottom-right corner of your taskbar' + #13#10 +
        '     to show hidden icons (near the clock, wifi...).' + #13#10 +
        '  2. Right-click the Vulcain icon.' + #13#10 +
        '  3. Select "Quit".' + #13#10 + #13#10 +
        'Then run the uninstaller again.',
        mbError, MB_OK);
      Result := False;
      Exit;
    end;
  end;
  Result := True;
end;

[UninstallDelete]
Type: files; Name: "{app}\vpn_log.txt"
Type: files; Name: "{app}\vpn_log_old.txt"
Type: files; Name: "{app}\cache.db"
Type: files; Name: "{app}\api_log.txt"
Type: filesandordirs; Name: "{app}\data\cache.db"
Type: filesandordirs; Name: "C:\ProgramData\Vulcain VPN"
