:: Place this script in C:\Windows\System32 to ensure it can be run from anywhere
@echo off

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo This command requires Administrator privileges.
    echo Right-click CMD and choose "Run as administrator".
    pause
    exit /b 1
)

DISM /Online /Cleanup-Image /RestoreHealth
sfc /scannow