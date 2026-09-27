@echo off
cd /d "%~dp0"
echo Kontur offline. A .gguf must be in the models folder.
echo This window stays open while the local model runs.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0server.ps1"
echo.
echo Server stopped.
pause
