@echo off
setlocal
set "GAMEDIR="
if exist "%~dp0..\Archives\WDC_pc_Menu_data_Freecam.ttarch2" set "GAMEDIR=%~dp0.."
if not defined GAMEDIR if exist "%ProgramFiles(x86)%\Steam\steamapps\common\The Walking Dead The Telltale Definitive Series\Archives" set "GAMEDIR=%ProgramFiles(x86)%\Steam\steamapps\common\The Walking Dead The Telltale Definitive Series"
if not defined GAMEDIR set /p GAMEDIR=Paste the game folder path ^(the one containing "Archives"^): 
set "GAMEDIR=%GAMEDIR:"=%"
del "%GAMEDIR%\Archives\WDC_pc_Menu_data_Freecam.ttarch2" 2>nul
del "%GAMEDIR%\Archives\_resdesc_50_Menu_Freecam.lua" 2>nul
del "%GAMEDIR%\Freecam.ini" 2>nul
del "%GAMEDIR%\Archives\WDC_pc_Menu_data_SceneEditor.ttarch2" 2>nul
del "%GAMEDIR%\Archives\_resdesc_50_Menu_SceneEditor.lua" 2>nul
del "%GAMEDIR%\SceneEditor.ini" 2>nul
echo Removed. The original game archives were never modified.
pause
