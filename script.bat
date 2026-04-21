@echo off
:: Launches bootstrap.ps1 with execution policy bypass and admin elevation.
:: This avoids the "running scripts is disabled" error on fresh Windows machines.

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting Administrator privileges...
    powershell -Command "Start-Process cmd -ArgumentList '/c \"%~f0\"' -Verb RunAs"
    exit /b
)

powershell -ExecutionPolicy Bypass -File "%~dp0script.ps1"
pause
