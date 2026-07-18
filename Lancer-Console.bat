@echo off
REM Lancer-Console.bat - ouvre le menu texte (Run.ps1) en mode administrateur.
REM Secours si la GUI ne fonctionne pas sur une machine.

net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Run.ps1"
pause
