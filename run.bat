@echo off
if not exist "%~dp0cookie.txt" (
    echo.
    echo No cookie configuration found.
    echo Run setup.bat first, then try again.
    echo.
    pause
    exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0yt-downloader.ps1" -Workers 3 -Fragments 4 %*
echo.
echo Exit code: %ERRORLEVEL%
pause