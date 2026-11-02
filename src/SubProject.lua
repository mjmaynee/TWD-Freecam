-- Free camera: loads the game's original shared SubProject script, then the camera hook.
local ok, err = pcall(require, "Freecam_SubProjectOrig.lua")
if not ok then error(err) end
pcall(require, "Freecam_Hook.lua")
