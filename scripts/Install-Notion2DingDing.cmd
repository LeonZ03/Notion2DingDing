@echo off
chcp 65001 >nul
title Notion2DingDing 安装
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-release.ps1"
set N2DD_EXIT=%ERRORLEVEL%
echo.
if not "%N2DD_EXIT%"=="0" echo 安装未完成，请保留上方错误信息。
if "%N2DD_EXIT%"=="0" echo 安装完成。请重启 Edge，然后打开扩展继续钉钉登录和位置设置。
echo.
pause
exit /b %N2DD_EXIT%
