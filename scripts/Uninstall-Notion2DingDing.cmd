@echo off
chcp 65001 >nul
title Notion2DingDing 卸载
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-release.ps1" -Action Uninstall
set N2DD_EXIT=%ERRORLEVEL%
echo.
if not "%N2DD_EXIT%"=="0" echo 卸载未完成，请保留上方错误信息。
if "%N2DD_EXIT%"=="0" echo 卸载完成。
echo.
pause
exit /b %N2DD_EXIT%
