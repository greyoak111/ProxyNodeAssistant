@echo off
setlocal EnableExtensions
chcp 65001 >nul

set "SOURCE_DIR=%~dp0"
for %%I in ("%SOURCE_DIR%") do set "SOURCE_DIR=%%~fI"
set "WORKSPACE_DIR=%SOURCE_DIR%..\.."
for %%I in ("%WORKSPACE_DIR%") do set "WORKSPACE_DIR=%%~fI"
set "OUTPUT_DIR=%WORKSPACE_DIR%\outputs\TextNodeAssistant-v0.9.5-official"

echo ============================================================
echo  TextNodeAssistant v0.9.5 - Windows 全架构正式打包
echo ============================================================
echo  源码目录: %SOURCE_DIR%
echo  输出目录: %OUTPUT_DIR%
echo.
echo  将生成:
echo    1. Windows x64   - TextNodeAssistant-v0.9.5-win64.exe
echo    2. Windows x86   - TextNodeAssistant-v0.9.5-win32.exe
echo    3. Windows ARM64 - TextNodeAssistant-v0.9.5-win-arm64.exe
echo.

where powershell.exe >nul 2>nul || goto :missing_powershell
set "GO_ENV_FILE=%TEMP%\tna-go-env-%RANDOM%-%RANDOM%.cmd"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SOURCE_DIR%scripts\ensure-go.ps1" -CmdFile "%GO_ENV_FILE%"
if errorlevel 1 goto :missing_go
call "%GO_ENV_FILE%"
del /q "%GO_ENV_FILE%" >nul 2>nul

echo [1/4] 构建并完整验证 Windows x64...
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SOURCE_DIR%build.ps1" -Architecture amd64
if errorlevel 1 goto :failed

echo.
echo [2/4] 构建并完整验证 Windows x86...
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SOURCE_DIR%build.ps1" -Architecture 386 -SkipCommonValidation
if errorlevel 1 goto :failed

echo.
echo [3/4] 交叉编译 Windows ARM64...
echo 当前 x64 电脑无法原生运行 ARM64 工作流，因此执行编译和静态校验，不伪造运行测试。
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SOURCE_DIR%build.ps1" -Architecture arm64 -SkipCommonValidation -SkipRuntimeSmoke
if errorlevel 1 goto :failed

echo.
echo [4/4] 生成便携包、源码包和 SHA-256 清单...
set "TNA_PACKAGE_OUTPUT=%OUTPUT_DIR%"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SOURCE_DIR%package.ps1"
if errorlevel 1 goto :failed

copy /y "%OUTPUT_DIR%\TextNodeAssistant-v0.9.5-win64.exe" "%WORKSPACE_DIR%\outputs\TextNodeAssistant-v0.9.5-win64.exe" >nul
copy /y "%OUTPUT_DIR%\TextNodeAssistant-v0.9.5-win32.exe" "%WORKSPACE_DIR%\outputs\TextNodeAssistant-v0.9.5-win32.exe" >nul
copy /y "%OUTPUT_DIR%\TextNodeAssistant-v0.9.5-win-arm64.exe" "%WORKSPACE_DIR%\outputs\TextNodeAssistant-v0.9.5-win-arm64.exe" >nul

echo.
echo ============================================================
echo  全部 PC 版本打包完成
echo  正式发行目录: %OUTPUT_DIR%
echo ============================================================
start "" explorer.exe "%OUTPUT_DIR%"
pause
exit /b 0

:missing_powershell
echo [ERROR] 找不到 powershell.exe。
goto :failed

:missing_go
echo [ERROR] 没有找到可用 Go，且官方便携 Go 下载、SHA-256 校验或启动验证失败。
goto :failed

:failed
echo.
echo [FAILED] 打包失败，错误码 %ERRORLEVEL%。上方日志已指出失败阶段。
pause
exit /b 1
