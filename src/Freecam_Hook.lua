--[[
Free camera hook. Loaded from the shared SubProject script in every project state.
When an episode state starts, it loads Freecam_Run.lua (the free camera; Enter toggles it).
]]
local cur
pcall(function() cur = SubProject_GetCurrent() end)
if type(cur) == "string" and cur:find("^WalkingDead") and not Freecam_RunLoaded then
  Freecam_RunLoaded = true
  pcall(function()
    local f = io.open("Freecam.ini", "w")
    if f then f:write("overlay=on\n\n\n") f:close() end
  end)
  pcall(require, "Freecam_Run.lua")
end
