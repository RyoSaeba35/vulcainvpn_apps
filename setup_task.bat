@echo off
schtasks /Delete /TN "VulcainVPN\Launch" /F 2>nul
schtasks /Create /TN "VulcainVPN\Launch" /TR "\"%~dp0vulcain_vpn.exe\"" /SC ONCE /ST 00:00 /RL HIGHEST /F

REM Verify task was created with highest privileges
schtasks /Query /TN "VulcainVPN\Launch" /V /FO LIST >> "C:\ProgramData\VulcainVPN\task_info.txt" 2>&1
