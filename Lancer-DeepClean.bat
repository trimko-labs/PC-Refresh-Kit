@echo off
REM Lancer-DeepClean.bat - execute le module DeepClean (nettoyage autonome) en mode administrateur.
REM Auto-elevation UAC : si pas admin, se relance eleve.

net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0modules\11-DeepClean.ps1" -Unattended
if %errorlevel% neq 0 (
    echo.
    echo Le module DeepClean n'a pas pu s'executer correctement ^(code %errorlevel%^).
    pause
)
