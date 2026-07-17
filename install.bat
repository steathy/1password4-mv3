@echo off
REM Double-click launcher for install.ps1 (which self-elevates via UAC).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
