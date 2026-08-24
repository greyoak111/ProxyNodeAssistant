@echo off
setlocal EnableExtensions
chcp 65001 >nul

set "SOURCE_DIR=%~1"
if not defined SOURCE_DIR set "SOURCE_DIR=%PNA_SOURCE_DIR%"
if not defined SOURCE_DIR if exist "%CD%\build.ps1" set "SOURCE_DIR=%CD%"
if not defined SOURCE_DIR if exist "%~dp0ProxyNodeAssistant-v0.9.5-source\build.ps1" set "SOURCE_DIR=%~dp0ProxyNodeAssistant-v0.9.5-source"
if not defined SOURCE_DIR if exist "%USERPROFILE%\Documents\ChatGPT\vps a1\work\ProxyNodeAssistant-v0.8.3-source\build.ps1" set "SOURCE_DIR=%USERPROFILE%\Documents\ChatGPT\vps a1\work\ProxyNodeAssistant-v0.8.3-source"

if not defined SOURCE_DIR (
    echo 没有自动找到 ProxyNodeAssistant 源码目录。
    echo 可以把源码目录拖到本 BAT 上，或在下面手动输入完整路径。
    set /p "SOURCE_DIR=源码目录: "
)

for %%I in ("%SOURCE_DIR%") do set "SOURCE_DIR=%%~fI"
if not exist "%SOURCE_DIR%\build.ps1" goto :bad_source
if not exist "%SOURCE_DIR%\package.ps1" goto :bad_source
if not exist "%SOURCE_DIR%\build-all-pc.bat" goto :bad_source

call "%SOURCE_DIR%\build-all-pc.bat"
exit /b %ERRORLEVEL%

:bad_source
echo.
echo [ERROR] 该目录不是完整的 ProxyNodeAssistant 源码目录:
echo %SOURCE_DIR%
echo 必须包含 build.ps1、package.ps1 和 build-all-pc.bat。
pause
exit /b 2
