@echo off
setlocal
rem Script version: v1.0.0  (keep this in sync with the .ps1 filename)
set "SCRIPT=%~dp0wb-apply-users-v1.0.0.ps1"

if not exist "%SCRIPT%" (
    echo [ERROR] wb-apply-users-v1.0.0.ps1 not found in the same folder.
    pause
    exit /b 1
)

net session >nul 2>&1
if not errorlevel 1 goto runit

set "ARGS=%*"
echo Administrator privileges required. Requesting elevation...
if not defined ARGS goto elev_noarg
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -ArgumentList '%ARGS%' -Verb RunAs"
goto done

:elev_noarg
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
goto done

:runit
echo ============================================================
echo   WorkBuddy Migrator v1.0.0  -  wb-apply-users
echo ============================================================
if "%~1"=="" (
    echo   PREVIEW MODE - nothing will be changed
    echo   To really apply, run wb-apply-users-apply-v1.0.0.bat
    echo   or add -Apply / -Verify / -Rollback as argument.
    echo ============================================================
) else (
    echo Running: "%SCRIPT%" %*
    echo ============================================================
)
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set "RC=%ERRORLEVEL%"
echo.
echo [INFO] Exit code: %RC%
pause

:done
endlocal
exit /b 0
