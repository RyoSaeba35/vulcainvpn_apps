@echo off
mkdir "C:\ProgramData\VulcainVPN" 2>nul

REM Check if app is already running
tasklist /FI "IMAGENAME eq vulcain_vpn.exe" /NH | find /i "vulcain_vpn.exe" >nul

if not errorlevel 1 (
  REM App is running — write flag to show window
  echo. > "C:\ProgramData\VulcainVPN\show.flag"
) else (
  REM App is not running — launch via scheduled task
  schtasks /Run /TN "VulcainVPN\Launch"
)
