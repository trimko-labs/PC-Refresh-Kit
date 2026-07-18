@echo off
REM Lancer.bat - ouvre le cockpit graphique du PC-Refresh-Kit en mode administrateur.
REM Auto-elevation UAC : si pas admin, se relance eleve.

net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Run-GUI.ps1"
if %errorlevel% neq 0 (
    echo.
    echo Le cockpit graphique n'a pas pu demarrer correctement ^(code %errorlevel%^).
    echo Essayer Lancer-Console.bat en secours, ou lire le message ci-dessus.
    pause
)
