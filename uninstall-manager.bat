@echo off
rem Odstrani samodejni zagon managerja (Scheduled Task "NodeManager").
net session >nul 2>&1 || (echo [NAPAKA] Zazeni kot administrator. & exit /b 1)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0manager.ps1" -Uninstall
