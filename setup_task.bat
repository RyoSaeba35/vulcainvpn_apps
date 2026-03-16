@echo off
schtasks /Delete /TN "VulcainVPN\Launch" /F 2>nul
schtasks /Create /TN "VulcainVPN\Launch" /TR "\"%~dp0vulcain_vpn.exe\"" /SC ONCE /ST 00:00 /RL HIGHEST /F
