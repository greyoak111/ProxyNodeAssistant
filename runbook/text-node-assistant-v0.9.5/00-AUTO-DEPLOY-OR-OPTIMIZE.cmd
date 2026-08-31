@echo off
setlocal
chcp 65001 >nul
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp000-AUTO-DEPLOY-OR-OPTIMIZE.ps1"
pause
