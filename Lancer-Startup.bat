@echo off
REM Lancer-Startup.bat - execute le module Startup (gestionnaire de démarrage) en mode administrateur.
REM Auto-elevation UAC : si pas admin, se relance eleve.

net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0modules\12-Startup.ps1" -Unattended
if %errorlevel% neq 0 (
    echo.
    echo Le module Startup n'a pas pu s'executer correctement ^(code %errorlevel%^).
    pause
)