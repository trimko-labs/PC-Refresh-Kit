@echo off
REM Lancer-Nettoyage.bat - nettoyage rapide des fichiers systeme Windows inutiles (module 07).
REM Mode -SkipRepair : saute le DISM (30-60 min) et le SFC, garde TEMP, cache Windows Update,
REM Disk Cleanup (cleanmgr) et TRIM. Ne vide PAS la corbeille ni les caches navigateur (non demande).
REM Auto-elevation UAC : si pas admin, se relance eleve.

net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0modules\07-Cleanup.ps1" -Unattended -SkipRepair
if %errorlevel% neq 0 (
    echo.
    echo Le nettoyage n'a pas pu s'executer correctement ^(code %errorlevel%^).
    pause
)
