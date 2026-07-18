@echo off
REM Lancer-Rapport.bat - regenere le rapport (module 10, lecture seule).
REM A relancer apres un redemarrage pour mesurer le temps de boot reel.
REM Aucun droit admin requis : ce module ne modifie pas le systeme.

cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0modules\10-Report.ps1"
if %errorlevel% neq 0 (
    echo.
    echo Le rapport n'a pas pu etre genere ^(code %errorlevel%^).
)
pause
