@echo off
setlocal
rem Free Camera mod installer. This folder can be anywhere.
set ROOT=%~dp0
rem Finds the game's Archives folder: next to this folder, the default Steam location, or asks.
set "GAMEDIR="
if exist "%ROOT%..\Archives\WDC_pc_Menu_data.ttarch2" set "GAMEDIR=%ROOT%.."
if not defined GAMEDIR if exist "%ProgramFiles(x86)%\Steam\steamapps\common\The Walking Dead The Telltale Definitive Series\Archives\WDC_pc_Menu_data.ttarch2" set "GAMEDIR=%ProgramFiles(x86)%\Steam\steamapps\common\The Walking Dead The Telltale Definitive Series"
if not defined GAMEDIR (
  echo Could not find the game automatically.
  set /p GAMEDIR=Paste the game folder path ^(the one containing "Archives"^): 
)
set "GAMEDIR=%GAMEDIR:"=%"
set GAME=%GAMEDIR%\Archives
set TT=%ROOT%tools\ttarchext.exe
if not exist "%TT%" (
  echo ttarchext.exe was not found in the "tools" folder.
  echo Download "Telltale TTARCH files extractor/rebuilder" by Luigi Auriemma from
  echo https://aluigi.altervista.org/papers.htm#ttarchext , unzip it, and put ttarchext.exe in the "tools" folder here.
  set /p TT=Or paste the full path to ttarchext.exe now: 
)
set "TT=%TT:"=%"
if not exist "%TT%" (echo ttarchext.exe not found. & pause & exit /b 1)
set T=%ROOT%_work
if not exist "%GAME%\WDC_pc_Menu_data.ttarch2" (
  echo "%GAME%" is not the game's Archives folder.
  pause & exit /b 1
)
rem remove files from the earlier 'SceneEditor' version of this mod
del "%GAME%\WDC_pc_Menu_data_SceneEditor.ttarch2" 2>nul
del "%GAME%\_resdesc_50_Menu_SceneEditor.lua" 2>nul
del "%GAME%\..\SceneEditor.ini" 2>nul
if exist "%T%" rmdir /s /q "%T%"
mkdir "%T%\unp\WDC_pc_Project_data" "%T%\unp\WDC_pc_Menu_data" "%T%\pack"

echo Reading the needed game files from your own copy of the game...
"%TT%" 67 "%GAME%\WDC_pc_Project_data.ttarch2" "%T%\unp\WDC_pc_Project_data" >nul
"%TT%" 67 "%GAME%\WDC_pc_Menu_data.ttarch2" "%T%\unp\WDC_pc_Menu_data" >nul
if not exist "%T%\unp\WDC_pc_Project_data\SubProject.lua" (echo Could not read the game archives. & pause & exit /b 1)

echo Building...
for %%F in (SubProject Freecam_Hook Freecam_Run) do (
  if not exist "%ROOT%compiled\%%F.lua" (echo Missing compiled\%%F.lua - re-download the mod. & pause & exit /b 1)
  copy /y "%ROOT%compiled\%%F.lua" "%T%\pack\%%F.lua" >nul
)
copy /y "%T%\unp\WDC_pc_Project_data\SubProject.lua" "%T%\pack\Freecam_SubProjectOrig.lua" >nul
copy /y "%T%\unp\WDC_pc_Menu_data\CharacterZoo.imap" "%T%\pack\" >nul
copy /y "%T%\unp\WDC_pc_Menu_data\WidgetInputHandler.imap" "%T%\pack\" >nul
"%TT%" -b -o 67 "%T%\WDC_pc_Menu_data_Freecam.ttarch2" "%T%\pack" >nul
copy /y "%ROOT%src\resdesc_template.lua" "%T%\_resdesc_50_Menu_Freecam.lua" >nul
"%TT%" -V 7 -e 0 -o 67 "%T%\_resdesc_50_Menu_Freecam.lua" "%T%" >nul

copy /y "%T%\WDC_pc_Menu_data_Freecam.ttarch2" "%GAME%\" >nul || (echo Copy failed & pause & exit /b 1)
copy /y "%T%\_resdesc_50_Menu_Freecam.lua" "%GAME%\" >nul || (echo Copy failed & pause & exit /b 1)
rmdir /s /q "%T%"
echo.
echo Installed. Start the game and play normally - press Enter in any scene (see README.txt).
echo Original game archives were not modified.
pause
