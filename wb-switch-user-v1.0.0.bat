@echo off
setlocal
cd /d "%~dp0"

rem Script version: v1.0.0  (keep this in sync with the .ps1 filename)
set "SCRIPT=%~dp0wb-switch-user-v1.0.0.ps1"
if not exist "%SCRIPT%" (
    echo [ERROR] Script not found: %SCRIPT%
    echo         Keep wb-switch-user-v1.0.0.ps1 in the same folder as this .bat
    pause
    exit /b 1
)

rem No arguments: auto kill WorkBuddy processes before migrating.
rem With arguments: pass them through, user decides.
if "%~1"=="" ( set "DEFKILL=-KillRunning" ) else ( set "DEFKILL=" )

echo ============================================================
echo   WorkBuddy Migrator v1.0.0  -  wb-switch-user
echo ============================================================
echo Calling: %SCRIPT%
echo Args   : %DEFKILL% %*
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %DEFKILL% %*
set "RC=%ERRORLEVEL%"

echo.
if "%RC%"=="0" (
    echo [DONE] Exit code 0. Window stays open to show results.
) else (
    echo [WARN] Exit code %RC%. Non-zero means aborted or env vars not changed.
)
pause
exit /b %RC%
