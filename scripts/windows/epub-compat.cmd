@echo off
setlocal
chcp 65001 >nul
rem Cover art needs Pillow, formula images need Pillow + PyMuPDF (fitz).
rem The bridge venv has both; fall back to wenyi's venv only if it is richer.
set "BRIDGE_PY=%~dp0wenyi-babeldoc-bridge\.venv\Scripts\python.exe"
set "PY=%BRIDGE_PY%"
"%BRIDGE_PY%" -c "import PIL, fitz" >nul 2>nul || set "PY=%~dp0wenyi\.venv\Scripts\python.exe"
"%PY%" "%~dp0epub-compat.py" %*
echo.
pause
