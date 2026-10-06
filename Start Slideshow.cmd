@echo off
rem Photo Slideshow: syncs your Google Photos shared albums, then opens the
rem slideshow full screen. Close it with Alt+F4.
setlocal
cd /d "%~dp0"
title Photo Slideshow
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0sync-google-photos.ps1"

set "PAGE=%~dp0slideshow.html"
set "PAGE=%PAGE:\=/%"
set "EDGE="
if exist "%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe" set "EDGE=%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe"
if not defined EDGE if exist "%ProgramFiles%\Microsoft\Edge\Application\msedge.exe" set "EDGE=%ProgramFiles%\Microsoft\Edge\Application\msedge.exe"
if not defined EDGE goto plain

rem A separate browser profile so kiosk mode works even if Edge is already open.
start "" "%EDGE%" --user-data-dir="%LOCALAPPDATA%\PhotoSlideshow\browser" --kiosk "file:///%PAGE%" --edge-kiosk-type=fullscreen --no-first-run --autoplay-policy=no-user-gesture-required
goto :eof

:plain
start "" "%~dp0slideshow.html"
