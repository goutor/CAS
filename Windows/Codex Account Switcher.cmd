@echo off
setlocal
set SCRIPT_DIR=%~dp0
set EXE_PATH=%SCRIPT_DIR%dist\CodexAccountSwitcher.exe

if not exist "%EXE_PATH%" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%build-app.ps1"
)

start "" "%EXE_PATH%"
endlocal
