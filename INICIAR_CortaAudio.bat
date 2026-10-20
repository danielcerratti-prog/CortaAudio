@echo off
setlocal
cd /d "%~dp0"
title CortaAudio - FFmpeg local
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0CortaAudioServer.ps1"
echo.
echo O CortaAudio foi encerrado.
pause
endlocal
