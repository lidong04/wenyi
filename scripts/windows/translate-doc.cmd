@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0translate-doc.ps1" %*
exit /b %ERRORLEVEL%
