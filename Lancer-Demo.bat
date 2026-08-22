@echo off
REM Lancer-Demo.bat - ouvre le cockpit en mode SIMULATION (aucune modification).
REM Usage : demonstration devant un prospect ou un proche, sur une machine qu'on ne touche pas.
REM Le cockpit s'ouvre avec la case "Simulation" deja cochee : toutes les etapes sont
REM simulees, le journal defile normalement, mais rien n'est modifie sur le PC.

net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"
echo.
echo  ================================================================
echo   PC-Refresh-Kit - MODE DEMONSTRATION (simulation)
echo  ================================================================
echo.
echo   Aucune modification ne sera appliquee a ce PC.
echo   La case "Simulation" est cochee au demarrage du cockpit.
echo   Pour une intervention reelle, fermer et utiliser Lancer.bat.
echo.
echo  ================================================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Run-GUI.ps1" -WhatIf
if %errorlevel% neq 0 (
    echo.
    echo Le cockpit graphique n'a pas pu demarrer correctement ^(code %errorlevel%^).
    echo Essayer Lancer-Console.bat en secours, ou lire le message ci-dessus.
    pause
)
