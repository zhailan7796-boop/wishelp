@echo off
setlocal
cd /d "%~dp0"
if not exist "%~dp0runtime\AutoHotkey64.exe" (
  echo Missing portable AutoHotkey runtime. Extract the complete folder first.
  pause
  exit /b 2
)
start "" "%~dp0runtime\AutoHotkey64.exe" "%~dp0TaskbarFollow.ahk"
