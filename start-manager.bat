@echo off
rem Rocni zagon managerja (npr. po "Izhod"). Ce je namescen samodejni zagon, ga zazene prek njega (z admin pravicami).
schtasks /Query /TN NodeManager >nul 2>&1
if not errorlevel 1 (
    schtasks /Run /TN NodeManager >nul
) else (
    start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0manager.ps1"
)
