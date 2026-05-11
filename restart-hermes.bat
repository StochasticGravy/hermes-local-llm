@echo off
:: restart-hermes.bat
:: Kills any running Hermes process and starts a fresh session in a new window.

echo Stopping Hermes...
taskkill /IM python.exe /FI "WINDOWTITLE eq hermes*" /F >nul 2>&1
taskkill /IM hermes.exe /F >nul 2>&1

:: Give it a moment to clean up
timeout /t 2 /nobreak >nul

echo Starting Hermes...
start "Hermes" cmd /k "hermes"
