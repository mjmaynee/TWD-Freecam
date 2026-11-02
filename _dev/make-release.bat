@echo off
rem DEV ONLY. Compiles src\*.lua with the Telltale-compatible luac and builds the release zip (no .exe files inside).
setlocal
set ROOT=%~dp0..\
set LUAC=%~dp0luac.exe
if not exist "%ROOT%compiled" mkdir "%ROOT%compiled"
for %%F in (SubProject Freecam_Hook Freecam_Run) do (
  "%LUAC%" -o "%ROOT%compiled\%%F.lua" "%ROOT%src\%%F.lua"
  if errorlevel 1 (echo Compile FAILED for %%F & pause & exit /b 1)
)
set OUT=%ROOT%release\TWD-Freecam
if exist "%ROOT%release" rmdir /s /q "%ROOT%release"
mkdir "%OUT%\src" "%OUT%\compiled" "%OUT%\tools"
copy /y "%ROOT%compiled\*.lua" "%OUT%\compiled\" >nul
copy /y "%ROOT%src\*.lua" "%OUT%\src\" >nul
copy /y "%ROOT%install.bat" "%OUT%\" >nul
copy /y "%ROOT%uninstall.bat" "%OUT%\" >nul
copy /y "%ROOT%README.txt" "%OUT%\" >nul
echo Put ttarchext.exe here (see README.txt). > "%OUT%\tools\PUT_ttarchext.exe_HERE.txt"
powershell -NoProfile -Command "Compress-Archive -Path '%OUT%' -DestinationPath '%ROOT%release\TWD-Freecam.zip' -Force"
echo Built %ROOT%release\TWD-Freecam.zip
pause
