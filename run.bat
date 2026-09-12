@echo off
chcp 65001 >nul
title Windows IT Support Toolkit V1.1
cd /d "%~dp0"

where pwsh.exe >nul 2>nul
if %errorlevel%==0 (
  pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0IT-Support-Toolkit.ps1"
) else (
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0IT-Support-Toolkit.ps1"
)

echo.
echo ========================================
echo  Program has exited. Press any key...
echo ========================================
pause >nul
