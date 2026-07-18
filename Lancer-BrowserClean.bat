@echo off
REM Lancer-BrowserClean.bat - execute le module BrowserPUP (nettoyage navigateurs) en mode administrateur.
REM Auto-elevation UAC : si pas admin, se relance eleve.

net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0modules\13-BrowserPUP.ps1" -Unattended
if %errorlevel% neq 0 (
    echo.
    echo Le module BrowserPUP n'a pas pu s'executer correctement ^(code %errorlevel%^).
    pause
)