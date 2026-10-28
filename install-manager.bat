@echo off
rem Nastavi samodejni zagon managerja ob prijavi (Scheduled Task "NodeManager", z admin pravicami) in ga zazene.
net session >nul 2>&1 || (echo [NAPAKA] Zazeni kot administrator. & exit /b 1)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0manager.ps1" -Install
