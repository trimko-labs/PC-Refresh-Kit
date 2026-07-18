@echo off
REM Lancer-Annuler.bat - restaure les changements reversibles du dernier run (modules 12 et 13).
REM Auto-elevation UAC : si pas admin, se relance eleve.

net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0modules\14-Undo.ps1" -Unattended
if %errorlevel% neq 0 (
    echo.
    echo L'annulation n'a pas pu s'executer correctement ^(code %errorlevel%^).
    pause
)
