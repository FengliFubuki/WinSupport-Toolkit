@echo off
chcp 65001 >nul
title WinSupport Toolkit V1.3
cd /d "%~dp0"

if /I "%~1"=="--console" goto console

where pwsh.exe >nul 2>nul
if %errorlevel%==0 (
  pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0gui\WinSupport-GUI.ps1"
) else (
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0gui\WinSupport-GUI.ps1"
)
goto end

:console
where pwsh.exe >nul 2>nul
if %errorlevel%==0 (
  pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0IT-Support-Toolkit.ps1" -Console
) else (
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0IT-Support-Toolkit.ps1" -Console
)

:end

echo.
echo ========================================
echo  Program has exited. Press any key...
echo ========================================
pause >nul
