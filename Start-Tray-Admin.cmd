@echo off
setlocal
title X3D CCD Affinity Tray

set "TOOL=%~dp0"
if "%TOOL:~-1%"=="\" set "TOOL=%TOOL:~0,-1%"
set "EXE=%TOOL%\X3D-Tray-Admin.exe"

if not exist "%EXE%" goto :build
goto :run

:build
echo.
echo   X3D-Tray-Admin.exe not found. Building it now ...
echo.
where pwsh >nul 2>nul
if errorlevel 1 (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%TOOL%\launcher\build.ps1"
) else (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%TOOL%\launcher\build.ps1"
)
if not exist "%EXE%" goto :fail

:run
echo.
echo   Requesting administrator rights ...
echo   Click Yes on the UAC prompt.
echo.
start "" "%EXE%"
goto :done

:fail
echo.
echo   Build failed. Install .NET Framework 4.x and run launcher\build.ps1 manually.
echo.
pause
goto :done

:done
timeout /t 2 >nul
exit /b 0
