@echo off
rem Launcher for deploy-agent from an RDP session. Double-click it from the redirected drive.
rem Edit ROLE and SHARE below (or pass the role as the first argument: agent-start.cmd prod).
rem .cmd is used on purpose: Win+R / context menu may be blocked by policy for .ps1,
rem and the window stays open long enough to read the diagnostics.
set ROLE=%1
set SHARE=\\tsclient\F\deploy
title deploy-agent launcher
if "%ROLE%"=="" (
    powershell -ExecutionPolicy Bypass -File "%SHARE%\agent-start.ps1" -ShareRoot "%SHARE%"
) else (
    powershell -ExecutionPolicy Bypass -File "%SHARE%\agent-start.ps1" -ShareRoot "%SHARE%" -Role %ROLE%
)
echo.
echo Done. If the agent window closed at once, read the messages above and log\start-fail-*.log.
pause
