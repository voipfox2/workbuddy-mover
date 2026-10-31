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

echo Requesting administrator privileges ...
echo.
if "%~1"=="" (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
)
goto done

:runit
echo ============================================================
echo   APPLY MODE : will write registry + create folders
echo   WorkBuddy Migrator v1.0.0  -  wb-apply-users
echo   extra args : %*
echo ============================================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Apply %*
set "RC=%ERRORLEVEL%"
echo.
echo [INFO] Exit code: %RC%
if not "%RC%"=="0" echo [WARN] Non-zero exit code. Read the messages above.
echo.
pause

:done
endlocal
exit /b 0
