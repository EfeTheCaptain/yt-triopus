@echo off
REM ============================================================
REM  yt-downloader  —  YouTube channel/playlist downloader
REM ============================================================
REM
REM  WHAT THIS IS
REM    Downloads YouTube videos, playlists, or entire channels
REM    at best available quality. Parallel workers, disk-based
REM    resume, verification after every run.
REM
REM  FIRST TIME
REM    1. Run this file (setup.bat) once to configure cookies.
REM    2. Double-click run.bat, paste a URL, press Enter.
REM
REM  EVERY TIME AFTER
REM    Just double-click run.bat.
REM
REM  WHAT setup.bat DOES
REM    Prompts for a browser (Firefox, Waterfox, Chrome, etc.)
REM    and saves the choice to cookie.txt. Cookies let it
REM    download age-restricted or account-only videos. Public
REM    videos work without them — pick "Skip cookies" if you
REM    don't need them.
REM
REM  USEFUL COMMANDS
REM    setup.bat                    run setup (one-time)
REM    setup.bat -Show              show current cookie config
REM    setup.bat -Reset             re-prompt for cookies
REM    run.bat "URL"                download a specific URL
REM    run.bat                      interactive mode (paste URL)
REM    run.bat "URL" -DebugEnum     diagnose "Found N" gaps — shows
REM                                 raw/matched/rejected counts
REM    run.bat "URL" -SkipCheckup   skip startup environment check
REM
REM  IF SOMETHING BREAKS
REM    Open WHEN-BROKEN.txt — step-by-step triage card.
REM    Full documentation in README.md.
REM
REM  TO STOP A DOWNLOAD
REM    Press Ctrl+C in the run window.
REM    Do NOT close with the X button — leaves an orphan process.
REM
REM ============================================================

echo === YouTube Downloader - First-time setup ===
echo.

REM Run the cookie setup script. %* forwards any flags you passed
REM to setup.bat (e.g. -Reset, -Show) to cookies.ps1.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0cookies.ps1" %*

echo.
echo =============================================
echo Setup complete.
echo Double-click run.bat to start downloading.
echo =============================================
echo.

REM Keep the window open so you can read the output. Remove this if
REM you'd rather the window close on its own.
pause