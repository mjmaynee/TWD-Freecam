--[[
Free camera runtime.

Inside an episode, background threads started at launch never resume, but a thread started from
a key press does. So the first key press starts a small per-frame loop, and held keys / mouse
drags move the camera smoothly. Input comes from two input maps the game already ships
(WidgetInputHandler.imap and CharacterZoo.imap); they call global functions by name.

CONTROLS (see CONTROLS.txt)
  W A S D ........ fly the camera          Arrow Left/Right ... turn      Arrow Up/Down ... tilt
  Right-drag ..... look around             Left-drag .......... pan sideways / up-down
  Wheel .......... dolly in / out          Right button + wheel  speed
  Enter .......... camera <-> object mode  Escape ............. back to the main menu
]]

local luaSelect = select   -- the real built-in, before anything can shadow it
local kCfg = "Freecam.ini"

local function log() end   -- diagnostics removed for release

local function try(name, fn, ...)
  local ok, a, b, c = pcall(fn, ...)
  if not ok then
    log("ERROR in " .. name .. ": " .. tostring(a))
    return nil
  end
  return a, b, c
end

SE = SE or {}
-- fixed behaviour (these were the tested switchboard settings)
local kFlags = { modes = true, suspend = false, softsuspend = true, camera = true, reticle = false,
                 confine = true, order = true, triggers = false }
local function flag(name) return kFlags[name] == true end
SE.passthrough = true      -- game has control until Enter
SE.engaged, SE.ready, SE.loopStarted = false, false, false
SE.cam, SE.camName, SE.verify = nil, nil, nil
SE.mode = "CAMERA"
SE.frozen = false
SE.agents = {}
SE.index = 1
SE.scene = nil
SE.cam = nil
SE.ready = false
SE.hidden = {}

-- ---------------------------------------------------------------- config
local function readCfg()
  local f = io.open(kCfg, "r")
  if not f then return nil, nil end
  f:read("*l")
  local archive = f:read("*l")
  local level = f:read("*l")
  f:close()
  if archive then archive = archive:gsub("[\r\n]", "") end
  if level then level = level:gsub("[\r\n]", "") end
  return archive, level
end

-- ---------------------------------------------------------------- scene discovery (lazy)
local function findScene()
  local names = SceneGetActiveSceneNames()
  if type(names) == "table" then
    for _, v in pairs(names) do
      if type(v) == "string" and not v:lower():find("^ui_") and not v:lower():find("^module_")
          and not v:lower():find("overlay") then return v end
    end
    return nil
  elseif type(names) == "string" then
    return names
  end
  if SE.opened and #SE.opened > 0 then
    for i = #SE.opened, 1, -1 do
      if not SE.opened[i]:lower():find("^ui_") then
        log("falling back to recorded scene " .. SE.opened[i])
        return SE.opened[i]
      end
    end
  end
  return nil
end

local function refreshAgents(quiet)
  SE.agents = {}
  local list = SceneGetAgents(SE.scene)
  if type(list) == "table" then
    for _, a in ipairs(list) do table.insert(SE.agents, a) end
  end
  local cams = {}
  for _, a in ipairs(SE.agents) do
    local n = try("AgentGetName", AgentGetName, a)
    if type(n) == "string" and n:lower():find("^cam") then table.insert(cams, n) end
  end
  if not quiet then log("Agents in scene: " .. #SE.agents .. "; camera-like agents (" .. #cams .. "): " .. table.concat(cams, ", ")) end
end

local function buildCandidates()
  -- fixed scene cameras, best first; names that suggest a rig that follows something are penalised
  local list = {}
  for i, a in ipairs(SE.agents) do
    local n = try("AgentGetName", AgentGetName, a)
    if type(n) == "string" and n:lower():find("^cam") then
      local l = n:lower()
      local score = i * 0.001
      local function pen(pat, v) if l:find(pat) then score = score + v end end
      pen("nav", 50); pen("follow", 50); pen("track", 40); pen("cutscene", 100); pen("^cam_fx", 100)
      pen("player", 60); pen("parent", 60); pen("chore", 80); pen("incar", 60); pen("horizontal", 30)
      pen("orbit", 40); pen("lookat", 30); pen("^cam_ui", 300); pen("overlay", 300); pen("dialog", 5)
      pen("walk", 40); pen("rail", 40); pen("pan", 20)
      if l == "cam_kitchen" then score = score - 100 end
      if l == "cam_default" then score = score - 20 end
      table.insert(list, { agent = a, name = n, score = score })
    end
  end
  table.sort(list, function(x, y) return x.score < y.score end)
  return list
end

local function ensureReady()
  if SE.ready then return true end
  SE.scene = try("findScene", findScene)
  if not SE.scene then
    log("No scene yet")
    return false
  end
  log("Scene: " .. tostring(SE.scene))
  try("refreshAgents", refreshAgents)

  SE.ready = true
  return true
end

-- ---------------------------------------------------------------- actions
local function now() return os.clock() end

local function activeCamName()
  local c = SE.scene and try("SceneGetCamera", SceneGetCamera, SE.scene)
  if not c then return "?" end
  return tostring(try("AgentGetName", AgentGetName, c))
end

-- Re-select our camera: the level keeps switching back to the player camera.
local function activateCam(quiet)
  if not SE.camName then return end
  SE.activations = (SE.activations or 0) + 1
  local before = (not quiet and SE.activations <= 4) and activeCamName() or nil
  try("CameraActivate", SE.origCameraActivate or CameraActivate, SE.camName)
  if before then
    log(string.format("CameraActivate(%s): scene camera was '%s', now '%s'", SE.camName, before, activeCamName()))
  end
end

-- hide the cursor only while we need to, and put back exactly what the game had
local function hideCursor()
  if SE.cursorHidByUs then return end
  local ok, h = pcall(CursorHidden)
  SE.cursorPrev = (ok and h) and true or false
  if not SE.cursorLogged2 then
    SE.cursorLogged2 = true
    log("CursorHidden() before we hide it -> " .. tostring(ok) .. " " .. tostring(h))
  end
  pcall(CursorHide, true)
  SE.cursorHidByUs = true
end
local function restoreCursor()
  if not SE.cursorHidByUs then return end
  pcall(CursorHide, SE.cursorPrev and true or false)
  SE.cursorHidByUs = false
end

local kFovNames = { "Field of View", "Field Of View", "FOV" }

local function readFov(agent)
  for _, name in ipairs(kFovNames) do
    local ok, v = pcall(AgentGetProperty, agent, name)
    if ok and type(v) == "number" then return v, name end
  end
  return nil
end

local function applyFov()
  if SE.fov and SE.cam and SE.fovName then
    pcall(AgentSetProperty, SE.cam, SE.fovName, SE.fov)
  end
end

-- Anything we move on a scene camera is remembered first and put back afterwards.
SE.touched = SE.touched or {}
local function touch(agent)
  if not agent or SE.touched[agent] then return end
  local pos = try("touch pos", AgentGetWorldPos, agent)
  local rot = try("touch rot", AgentGetRot, agent)
  local fov, fovName = readFov(agent)
  SE.touched[agent] = { pos = pos, rot = rot, fov = fov, fovName = fovName }
end
local function untouch(agent)
  local t = agent and SE.touched[agent]
  if not t then return end
  if t.pos then pcall(AgentSetWorldPos, agent, t.pos) end
  if t.rot then pcall(AgentSetRot, agent, t.rot) end
  if t.fov and t.fovName then pcall(AgentSetProperty, agent, t.fovName, t.fov) end
  SE.touched[agent] = nil
end
local function untouchAll()
  local list = {}
  for a in pairs(SE.touched) do table.insert(list, a) end
  for _, a in ipairs(list) do untouch(a) end
end

-- make a camera of our own so the game's cameras are never touched
local function createOwnCamera()
  local name = "sceneEditor_cam"
  local scenes = { SE.scene }
  local ok0, sc = pcall(AgentGetScene, SE.origCam)
  if ok0 and sc then table.insert(scenes, sc) end
  for i, scn in ipairs(scenes) do
    for _, prop in ipairs({ "cam_cutscene.prop" }) do
      local ok, a = pcall(AgentCreate, name, prop, nil, nil, scn, false, true)
      log(string.format("AgentCreate(%s, %s, scene #%d) -> %s %s", name, prop, i, tostring(ok), tostring(a)))
      if ok and a then return a, name end
    end
  end
  return nil
end

-- switch to the next free-looking camera, starting from the given view
local function useNextCandidate(pos, rot)
  SE.camIdx = (SE.camIdx or 0) + 1
  local c = SE.candidates and SE.candidates[SE.camIdx]
  if not c or SE.camIdx > 8 then
    log("No free camera found - moving the scene's own camera instead")
    touch(SE.origCam)
    SE.cam = SE.origCam
    SE.camName = SE.origCamName
    SE.verify = nil
    return
  end
  touch(c.agent)
  if pos then try("set pos", AgentSetWorldPos, c.agent, pos) end
  if rot then try("set rot", AgentSetRot, c.agent, rot) end
  SE.cam, SE.camName = c.agent, c.name
  applyFov()
  try("CameraActivate", SE.origCameraActivate or CameraActivate, c.name)
  SE.verify = { frames = 0, pos = pos, name = c.name }
  log(string.format("Trying editor camera %d: %s (score %.1f)", SE.camIdx, c.name, c.score))
end

-- called on the first key press: copy the view the player actually has, then take over
local function engage()
  if SE.engaged then return true end
  if SE.passthrough then return false end
  if not ensureReady() then return false end
  SE.engaged = true
  local active = try("SceneGetCamera", SceneGetCamera, SE.scene)
  SE.origCam = active
  SE.origCamName = active and tostring(try("AgentGetName", AgentGetName, active)) or nil
  local pos = active and try("pos", AgentGetWorldPos, active)
  local rot = active and try("rot", AgentGetRot, active)
  if pos and rot then
    log(string.format("Engage: player camera '%s' at %.2f %.2f %.2f rot %.1f %.1f %.1f",
      tostring(SE.origCamName), pos.x, pos.y, pos.z, rot.x, rot.y, rot.z))
  end
  local fov, fovName = nil, nil
  if active then fov, fovName = readFov(active) end
  -- scene cameras often use a narrow lens, so the free camera always starts at a fixed field of view
  local kFov = 90
  fov = kFov
  SE.fov, SE.fovName = fov, fovName
  log("Field of view: " .. tostring(fov) .. " (property '" .. tostring(fovName) .. "')")
  local own, ownName = createOwnCamera()
  if own then
    SE.ownCam = own
    SE.cam, SE.camName = own, ownName
    if pos then try("own pos", AgentSetWorldPos, own, pos) end
    if rot then try("own rot", AgentSetRot, own, rot) end
    SE.fovName = SE.fovName or "Field of View"
    applyFov()
    try("CameraActivate", SE.origCameraActivate or CameraActivate, ownName)
    SE.verify = { frames = 0, pos = pos, name = ownName }
    log("Using our own editor camera")
    return true
  end
  log("Could not create our own camera - borrowing a scene camera (it will be restored afterwards)")
  SE.candidates = buildCandidates()
  SE.camIdx = 0
  useNextCandidate(pos, rot)
  return true
end

-- The game keeps control by default. Enter starts the editor (fresh snapshot of the game's input
-- maps, then we take over); Enter again gives everything back exactly as it was.
local function activeMapNames()
  local names = {}
  pcall(function()
    local t = InputMapperGetActiveMapperNames()
    if type(t) == "table" then for _, n in pairs(t) do table.insert(names, tostring(n)) end end
  end)
  return names
end

local unpack_ = table.unpack or unpack

-- Maps we leave alone: they only track which input device is in use / raw mouse movement.
local kKeepMaps = { ["game_input_method.imap"] = true, ["Input.imap"] = true }

local function stateSnapshot(tag)
  local parts = {}
  table.insert(parts, "maps=" .. table.concat(activeMapNames(), ","))
  local okh, h = pcall(CursorHidden)
  table.insert(parts, "cursorHidden=" .. tostring(okh and h))
  local okc, c = pcall(function()
    local cam = SceneGetCamera(SE.scene)
    return AgentGetName(cam)
  end)
  table.insert(parts, "sceneCamera=" .. tostring(okc and c))
  if type(Mode_GetCurrent) == "function" then
    local okm, m = pcall(Mode_GetCurrent)
    table.insert(parts, "mode=" .. tostring(okm and m))
  end
  if type(Input_UseCursor) == "function" then
    local oku, u = pcall(Input_UseCursor)
    table.insert(parts, "useCursor=" .. tostring(oku and u))
  end
  log("STATE " .. tag .. ": " .. table.concat(parts, " | "))
end

-- switch off only game maps that would fight the editor's keys; remember them to switch back on
local function sweepMaps()
  if not flag("suspend") then return end
  SE.suspended = SE.suspended or {}
  SE.suspendedSet = SE.suspendedSet or {}
  for _, n in ipairs(activeMapNames()) do
    if not kKeepMaps[n] and not n:find("CharacterZoo") and not n:find("WidgetInputHandler")
        and not SE.suspendedSet[n] then
      local ok, err
      if flag("softsuspend") then
        ok, err = pcall(SE.origActivate, n, false)   -- disable, keep the map set up (what the game's own menus do)
      else
        ok, err = pcall(SE.origDeactivate, n)
      end
      SE.suspendedSet[n] = true
      table.insert(SE.suspended, n)
      log("  suspended map " .. n .. (flag("softsuspend") and " (soft)" or " (hard)") .. " -> " .. tostring(ok) .. " " .. tostring(err))
    end
  end
end

-- Scene triggers (camera boxes, chore boxes, dialog triggers...) carry a "Trigger Enabled" property.
-- While the editor is on they are switched off; each one's previous value is restored exactly.
local kTriggerProp = "Trigger Enabled"
SE.trigOrig = SE.trigOrig or {}
local function disableTriggers()
  pcall(refreshAgents, true)
  local n, names = 0, {}
  for _, a in ipairs(SE.agents or {}) do
    local ok, v = pcall(AgentGetProperty, a, kTriggerProp)
    if ok and type(v) == "boolean" and SE.trigOrig[a] == nil then
      SE.trigOrig[a] = v
      pcall(AgentSetProperty, a, kTriggerProp, false)
      n = n + 1
      if #names < 12 then table.insert(names, tostring(try("AgentGetName", AgentGetName, a))) end
    end
  end
  log("Triggers disabled: " .. n .. (n > 0 and (" (e.g. " .. table.concat(names, ", ") .. ")") or ""))
end
local function restoreTriggers()
  local n = 0
  for a, v in pairs(SE.trigOrig) do
    pcall(AgentSetProperty, a, kTriggerProp, v)
    n = n + 1
  end
  SE.trigOrig = {}
  log("Triggers restored: " .. n)
end

local function enterEditor()
  SE.internal = true
  local ok, err = pcall(function()
    SE.passthrough = false
    SE.mouse.l, SE.mouse.r = false, false
    stateSnapshot("before editor")
    SE.suspended = {}
    SE.suspendedSet = {}
    SE.orderedMaps = activeMapNames()
    log("EDITOR ON (game free-look wanted: " .. tostring(SE.reticleState) .. ")")
    if flag("modes") and type(Mode_SuspendAll) == "function" then
      local okm, errm = pcall(Mode_SuspendAll, true, true)
      SE.modesSuspended = okm
      log("Mode_SuspendAll(true, true) -> " .. tostring(okm) .. " " .. tostring(errm))
    end
    if flag("triggers") then pcall(disableTriggers) end
    if flag("reticle") and SE.origReticleActive then pcall(SE.origReticleActive, false) end
    sweepMaps()
    pcall(SE.origActivate, "CharacterZoo")
    pcall(SE.origActivate, "WidgetInputHandler.imap")
    if flag("confine") then
      local okc = pcall(CursorConfine, true)
      log("CursorConfine(true) -> " .. tostring(okc))
    end
    SE.engaged = false
    if flag("camera") then engage() else log("camera switched off by switchboard (no free camera)") end
  end)
  SE.internal = false
  if not ok then log("ERROR entering editor: " .. tostring(err)) end
end

local function exitEditor()
  SE.internal = true
  local ok, err = pcall(function()
    SE.passthrough = true
    SE.mouse.l, SE.mouse.r = false, false
    restoreCursor()
    pcall(SE.origDeactivate, "CharacterZoo")
    if SE.modesSuspended and type(Mode_SuspendAll) == "function" then
      local okm, errm = pcall(Mode_SuspendAll, false, true)
      log("Mode_SuspendAll(false, true) -> " .. tostring(okm) .. " " .. tostring(errm))
      SE.modesSuspended = false
    end
    pcall(restoreTriggers)
    local back = {}
    if flag("softsuspend") then
      for _, n in ipairs(SE.suspended or {}) do
        local okr, errr = pcall(SE.origActivate, n, true)
        table.insert(back, n .. (okr and "" or "(failed)"))
      end
    elseif flag("order") and SE.orderedMaps and #SE.orderedMaps > 0 and #(SE.suspended or {}) > 0 then
      -- put the maps back in the order they were originally activated in (ours included)
      local function movable(n) return not kKeepMaps[n] and not n:find("CharacterZoo") end
      local seq, seen = {}, {}
      for _, n in ipairs(SE.orderedMaps) do
        if movable(n) and not seen[n] then seen[n] = true; table.insert(seq, n) end
      end
      for _, n in ipairs(SE.suspended) do
        if movable(n) and not seen[n] then seen[n] = true; table.insert(seq, n) end
      end
      for _, n in ipairs(seq) do pcall(SE.origDeactivate, n) end
      for _, n in ipairs(seq) do
        local okr = pcall(SE.origActivate, n)
        table.insert(back, n .. (okr and "" or "(failed)"))
      end
    else
      for _, n in ipairs(SE.suspended or {}) do
        local okr = pcall(SE.origActivate, n)
        table.insert(back, n .. (okr and "" or "(failed)"))
      end
    end
    SE.suspended = {}
    SE.suspendedSet = {}
    -- camera: the one the game last chose
    local cam = SE.gameCam or SE.origCamName
    if cam then pcall(SE.origCameraActivate, cam) end
    untouchAll()
    if SE.ownCam then
      pcall(AgentDestroy, SE.ownCam)
      SE.ownCam = nil
    end
    if flag("reticle") and SE.origReticleActive then
      local v = SE.reticleState
      if v == nil then v = true end   -- never seen the game set it: assume it was on
      pcall(SE.origReticleActive, v)
      log("game free-look restored to " .. tostring(v) .. " (game's last request: " .. tostring(SE.reticleState) .. ")")
    end
    if flag("confine") then pcall(CursorConfine, false) end
    SE.engaged = false
    SE.cam, SE.camName, SE.verify = nil, nil, nil
    log("EDITOR OFF. switched back on: " .. table.concat(back, ", ") .. " | camera=" .. tostring(cam))
    SE.postCheckAt = now() + 1.5
  end)
  SE.internal = false
  if not ok then log("ERROR leaving editor: " .. tostring(err)) end
end

local function togglePassthrough()
  if SE.passthrough then enterEditor() else exitEditor() end
end

local function ground(rot, fwd, right)
  -- Telltale rotations are degrees (x=pitch, y=yaw). Forward / right on the ground plane.
  local yaw = math.rad(rot.y)
  local fx, fz = math.sin(yaw), math.cos(yaw)
  return fwd * fx - right * fz, fwd * fz + right * fx
end

local function selectAgent(dir)
  if not ensureReady() then return end
  local n = #SE.agents
  if n == 0 then return end
  SE.index = SE.index + dir
  if SE.index < 1 then SE.index = n end
  if SE.index > n then SE.index = 1 end
  log("Selected [" .. SE.index .. "/" .. n .. "] " .. tostring(try("AgentGetName", AgentGetName, SE.agents[SE.index])))
end

local function isDown(e)
  if type(Input_IsBegin) == "function" then
    local ok, v = pcall(Input_IsBegin, e)
    if ok then return v and true or false end
  end
  return true
end

-- ---------------------------------------------------------------- held-key state
SE.hold = {}
SE.vel = {}
SE.mouse = {}
SE.speed = 3.0      -- units per second
SE.turnRate = 90.0  -- degrees per second (arrow keys)
SE.lookSens = 0.15  -- degrees per pixel (mouse look)

local function setHold(name, down, pulse)
  if down then
    SE.hold[name] = pulse and (now() + pulse) or math.huge
  else
    SE.hold[name] = nil
  end
end
local function held(name)
  local h = SE.hold[name]
  return h ~= nil and h > now()
end
local function axis(pos, neg)
  return (held(pos) and 1 or 0) - (held(neg) and 1 or 0)
end

local function cursor()
  local ok, a, b = pcall(CursorGetPos)
  if not ok then return nil end
  local x, y
  if type(a) == "number" then x, y = a, b
  elseif a ~= nil then
    local ok2 = pcall(function() x, y = a.x, a.y end)
    if not ok2 then return nil end
  end
  if not SE.cursorLogged then
    SE.cursorLogged = true
    log("CursorGetPos -> " .. type(a) .. " x=" .. tostring(x) .. " y=" .. tostring(y))
  end
  return x, y
end

-- ---------------------------------------------------------------- per-frame update
local function frame(dt)
  if SE.passthrough or not SE.ready or not SE.engaged or not SE.cam then return end

  -- is the chosen camera really free? (the scene may keep moving it)
  if SE.verify then
    SE.verify.frames = SE.verify.frames + 1
    if SE.verify.frames == 5 then
      local p = SE.verify.pos and try("verify pos", AgentGetWorldPos, SE.cam)
      if p and SE.verify.pos then
        local dx, dy, dz = p.x - SE.verify.pos.x, p.y - SE.verify.pos.y, p.z - SE.verify.pos.z
        local d = math.sqrt(dx * dx + dy * dy + dz * dz)
        if d > 0.1 and not SE.ownCam then
          log(string.format("Camera %s is driven by the scene (moved %.2f) - trying the next one", SE.verify.name, d))
          local keepRot = try("rot", AgentGetRot, SE.cam)
          untouch(SE.cam)
          useNextCandidate(SE.verify.pos, keepRot)
          return
        end
      end
      log("Camera " .. tostring(SE.verify.name) .. " verified free")
      SE.verify = nil
    end
    return
  end

  -- keep our camera selected and the field of view steady
  if now() - (SE.lastActivate or 0) > 0.5 then
    SE.lastActivate = now()
    activateCam(true)
    applyFov()
  end

  local camMode = (SE.mode == "CAMERA")
  local target = SE.cam
  if not camMode then target = SE.agents[SE.index] end

  -- keyboard targets, smoothed so starts / stops are not abrupt
  local tgt = {
    f = axis("fwd", "back"),
    r = axis("right", "left"),
    yaw = axis("turnR", "turnL"),
    pitch = camMode and axis("downKey", "upKey") or 0,
    up = (not camMode) and axis("upKey", "downKey") or 0,
  }
  local k = math.min(1, dt * 14)
  for name, v in pairs(tgt) do
    local cur = SE.vel[name] or 0
    SE.vel[name] = cur + (v - cur) * k
    if math.abs(SE.vel[name]) < 0.002 and v == 0 then SE.vel[name] = 0 end
  end

  local crot = AgentGetRot(SE.cam)

  -- mouse look (right button) and pan (left button).
  -- Same method the game's own aiming code uses: movement = this frame's cursor minus last frame's.
  -- No assumed centre, so a still mouse means no drift. Only near a window edge is the cursor put
  -- back in the middle (that is what lets you keep turning one way).
  local mdx, mdy = 0, 0
  if SE.mouse.l or SE.mouse.r then
    local cx, cy = cursor()
    if cx then
      if (SE.skipFrames or 0) > 0 then
        SE.skipFrames = SE.skipFrames - 1
        SE.prevX, SE.prevY = cx, cy
      elseif SE.prevX then
        mdx, mdy = cx - SE.prevX, cy - SE.prevY
        if math.abs(mdx) > 0.3 or math.abs(mdy) > 0.3 then mdx, mdy = 0, 0 end
        SE.prevX, SE.prevY = cx, cy
        mdx, mdy = mdx * 1000, mdy * 560   -- normalised 0..1 -> about 1000 px wide, 16:9
        if cx < 0.12 or cx > 0.88 or cy < 0.12 or cy > 0.88 then
          pcall(CursorSetAtScreenCenter)
          SE.skipFrames = 2
          SE.prevX = nil
        end
      else
        SE.prevX, SE.prevY = cx, cy
      end
    end
  else
    SE.prevX, SE.prevY, SE.skipFrames = nil, nil, 0
  end

  -- camera orientation: arrow keys + right-drag
  local dyaw = SE.vel.yaw * SE.turnRate * dt
  local dpitch = SE.vel.pitch * SE.turnRate * dt
  if SE.mouse.r then
    dyaw = dyaw - mdx * SE.lookSens
    dpitch = dpitch + mdy * SE.lookSens
  end
  if dyaw ~= 0 or dpitch ~= 0 then
    local nx = math.max(-89, math.min(89, crot.x + dpitch))
    crot = Vector(nx, crot.y + dyaw, crot.z)
    AgentSetRot(SE.cam, crot)
  end

  -- translation (relative to where the camera is facing)
  local fwd = SE.vel.f * SE.speed * dt
  local right = SE.vel.r * SE.speed * dt
  local lift = SE.vel.up * SE.speed * dt
  if SE.mouse.l then
    -- left-drag: pan sideways / up-down
    local pan = SE.speed * 0.004
    right = right + mdx * pan
    lift = lift - mdy * pan
  end
  if fwd ~= 0 or right ~= 0 or lift ~= 0 then
    local dx, dz = ground(crot, fwd, right)
    local pos = AgentGetWorldPos(target)
    AgentSetWorldPos(target, Vector(pos.x + dx, pos.y + lift, pos.z + dz))
  end
end

local function startLoop()
  if SE.loopStarted then return end
  SE.loopStarted = true
  ThreadStart(function()
    log("frame loop started")
    engage()
    local last = now()
    local iters, windowStart = 0, now()
    while true do
      Sleep(0.008)
      local t = now()
      local dt = t - last
      last = t
      if dt > 0.1 then dt = 0.1 end
      iters = iters + 1
      if t - windowStart >= 1.0 then
        if iters > 400 then
          log("frame loop is not yielding (" .. iters .. " iterations/s) - stopping it")
          return
        end
        if not SE.loopAliveLogged then
          SE.loopAliveLogged = true
          log("frame loop alive: " .. iters .. " iterations/s")
        end
        iters, windowStart = 0, t
      end
      if SE.postCheckAt and t >= SE.postCheckAt then
        SE.postCheckAt = nil
        pcall(stateSnapshot, "1.5s after editor off")
      end
      if not SE.passthrough and t - (SE.lastSweep or 0) > 0.5 then
        SE.lastSweep = t
        SE.internal = true
        pcall(sweepMaps)
        SE.internal = false
      end
      if dt > 0 then
        local ok, err = pcall(frame, dt)
        if not ok then
          SE.frameErrors = (SE.frameErrors or 0) + 1
          if SE.frameErrors <= 5 then log("ERROR in frame: " .. tostring(err)) end
        end
      end
    end
  end)
end

-- ---------------------------------------------------------------- handlers named by the shipped input maps
SE.handlerNames = {}
SE.orig, SE.ours, SE.origSeen = {}, {}, {}
local function claim(name)
  table.insert(SE.handlerNames, name)
  if not SE.origSeen[name] then
    SE.origSeen[name] = true
    SE.orig[name] = _G[name]
  end
end
local function bind(name, fn)
  claim(name)
  _G[name] = function(e)
    if SE.passthrough and name ~= "WidgetInputHandler_OnEnter" then return end
    local down = isDown(e)
    SE.events = (SE.events or 0) + 1
    if SE.events <= 20 then
      log(string.format("event #%d %s down=%s t=%.2f", SE.events, name, tostring(down), now()))
    end
    startLoop()
    try(name, fn, down, e)
  end
end

-- CharacterZoo.imap: W / S / A / D (press and release are both delivered)
bind("CharacterZoo_OnZoomIn", function(down) setHold("fwd", down) end)
bind("CharacterZoo_OnZoomOut", function(down) setHold("back", down) end)
bind("CharacterZoo_OnRotateLeft", function(down) setHold("left", down) end)
bind("CharacterZoo_OnRotateRight", function(down) setHold("right", down) end)
claim("CharacterZoo_OnRightStick")
_G.CharacterZoo_OnRightStick = function() end

-- WidgetInputHandler.imap: arrows, enter, escape, wheel, mouse buttons
local function arrow(holdName, selectDir)
  return function(down)
    if down and SE.mode == "OBJECT" and selectDir and not held(holdName) then selectAgent(selectDir) end
    -- if release events do not arrive, a short pulse keeps the motion from sticking
    setHold(holdName, down, 0.15)
  end
end
for _, n in ipairs({"WidgetInputHandler_OnKeyLeft", "WidgetInputHandler_OnLeft"}) do
  bind(n, function(down, e) if SE.mode == "OBJECT" then arrow("objL", -1)(down, e) else arrow("turnL")(down, e) end end)
end
for _, n in ipairs({"WidgetInputHandler_OnKeyRight", "WidgetInputHandler_OnRight"}) do
  bind(n, function(down, e) if SE.mode == "OBJECT" then arrow("objR", 1)(down, e) else arrow("turnR")(down, e) end end)
end
for _, n in ipairs({"WidgetInputHandler_OnKeyUp", "WidgetInputHandler_OnUp"}) do bind(n, arrow("upKey")) end
for _, n in ipairs({"WidgetInputHandler_OnKeyDown", "WidgetInputHandler_OnDown"}) do bind(n, arrow("downKey")) end

local function toggleMode(down)
  if not down then return end
  if SE.mouse.r then
    -- right button held + Enter: camera <-> object mode
    if SE.passthrough then return end
    SE.mode = (SE.mode == "CAMERA") and "OBJECT" or "CAMERA"
    log("Mode: " .. SE.mode)
    ensureReady()
  else
    -- Enter: give the game its controls back (cutscene prompts etc.) / take them again
    togglePassthrough()
  end
end
bind("WidgetInputHandler_OnEnter", toggleMode)

bind("WidgetInputHandler_OnEscape", function(down)
  if not down or SE.passthrough then return end
  log("Leaving to main menu")
  pcall(restoreTriggers)
  untouchAll()
  restoreCursor()
  pcall(CursorConfine, false)
  SubProject_Switch("Menu", "Menu_Main.lua")
end)

-- wheel: dolly forward / back; left button held = field of view; right button held = speed
local function wheel(dir)
  if SE.passthrough then return end
  if SE.mouse.l then
    if SE.fov then
      SE.fov = math.max(10, math.min(120, SE.fov * (dir > 0 and 0.94 or 1.0638)))
      applyFov()
      log(string.format("Field of view: %.1f", SE.fov))
    else
      log("Field of view property not available in this scene")
    end
  elseif SE.mouse.r then
    SE.speed = SE.speed * (dir > 0 and 1.3 or 1 / 1.3)
    log("Speed: " .. SE.speed)
  else
    setHold(dir > 0 and "fwd" or "back", true, 0.12)
  end
end
bind("WidgetInputHandler_OnScrollUp", function() wheel(1) end)
bind("WidgetInputHandler_OnScrollDown", function() wheel(-1) end)

-- mouse buttons: state follows the handler name (press / release are separate handlers)
local function mouseDown(which)
  return function()
    if SE.passthrough then return end
    SE.mouse[which] = true
    SE.prevX, SE.prevY, SE.skipFrames = nil, nil, 0
    if SE.engaged then hideCursor() end
    if which == "l" then SE.lDownAt = now(); SE.lMoved = false end
  end
end
local function mouseUp(which)
  return function()
    if SE.passthrough then return end
    SE.mouse[which] = false
    if not SE.mouse.l and not SE.mouse.r then restoreCursor() end
    -- a quick left click in OBJECT mode hides / shows the selected object
    if which == "l" and SE.mode == "OBJECT" and SE.lDownAt and now() - SE.lDownAt < 0.25 then
      if not ensureReady() then return end
      local a = SE.agents[SE.index]
      if a then
        SE.hidden[a] = not SE.hidden[a]
        AgentHide(a, SE.hidden[a])
        log((SE.hidden[a] and "Hid " or "Showed ") .. tostring(try("AgentGetName", AgentGetName, a)))
      end
    end
  end
end
local function raw(name, fn)  -- ignore press/release detection, the name says which it is
  claim(name)
  _G[name] = function(e)
    if SE.passthrough then return end
    SE.events = (SE.events or 0) + 1
    if SE.events <= 20 then log(string.format("event #%d %s t=%.2f", SE.events, name, now())) end
    startLoop()
    try(name, fn, e)
  end
end
raw("WidgetInputHandler_OnMouseLDown", mouseDown("l"))
raw("WidgetInputHandler_OnMouseLUp", mouseUp("l"))
raw("WidgetInputHandler_OnMouseRDown", mouseDown("r"))
raw("WidgetInputHandler_OnMouseRUp", mouseUp("r"))

-- harmless stubs for the remaining names in WidgetInputHandler.imap so nothing errors
for _, n in ipairs({"WidgetInputHandler_OnMouseMove", "WidgetInputHandler_OnRollOn", "WidgetInputHandler_OnRollOff",
    "WidgetInputHandler_OnSwipeLeft", "WidgetInputHandler_OnSwipeUp", "WidgetInputHandler_OnSwipeRight",
    "WidgetInputHandler_OnSwipeDown", "WidgetInputHandler_OnLeftStick", "WidgetInputHandler_OnA",
    "WidgetInputHandler_OnB", "WidgetInputHandler_OnX",
    "WidgetInputHandler_OnY", "WidgetInputHandler_OnL", "WidgetInputHandler_OnR",
    "WidgetInputHandler_OnStart", "WidgetInputHandler_OnLT", "WidgetInputHandler_OnRT",
    "WidgetInputHandler_MenuButton"}) do
  claim(n)
  if not _G[n] then _G[n] = function() end end
end

-- remember our versions, and report any names the game already had a function for
do
  local clashes = {}
  for _, n in ipairs(SE.handlerNames) do
    SE.ours[n] = _G[n]
    if type(SE.orig[n]) == "function" then table.insert(clashes, n) end
  end
  log("handler names that already had a function before ours (" .. #clashes .. "): " .. table.concat(clashes, ", "))
end

-- ---------------------------------------------------------------- go

local function takeOver(tag)
  -- do NOT touch the game's controls here: the game keeps control until Enter is pressed.
  -- We only make sure Enter can reach us.
  log("hook (" .. tag .. ")")
  if type(Main_AllowMovement) == "function" and not SE.allowWrapped then
    SE.allowWrapped = true
    SE.origAllow = Main_AllowMovement
    Main_AllowMovement = function(v, ...)
      if not SE.internal then SE.allow = v end
      return SE.origAllow(v, ...)
    end
    log("tracking Main_AllowMovement")
  end
  if type(CameraControlReticle_SetReticleActive) == "function" and not SE.reticleWrapped then
    SE.reticleWrapped = true
    SE.origReticleActive = CameraControlReticle_SetReticleActive
    CameraControlReticle_SetReticleActive = function(v, ...)
      if not SE.internal then SE.reticleState = v end
      if not SE.passthrough and not SE.internal then
        -- the editor is on: remember what the game wants, but keep free-look off for now
        return SE.origReticleActive(false, ...)
      end
      return SE.origReticleActive(v, ...)
    end
    log("tracking CameraControlReticle_SetReticleActive")
  end
  SE.internal = true
  pcall(SE.origActivate, "WidgetInputHandler.imap")
  SE.internal = false
  SE.ready = false
  try("ensureReady", ensureReady)
end

-- Listen to everything the game does with input maps / movement / cameras, so leaving the editor
-- can put things back exactly as the game left them.
SE.act = {}
SE.origActivate = SE.origActivate or InputMapperActivate
SE.origDeactivate = SE.origDeactivate or InputMapperDeactivate
SE.origDeactAll = SE.origDeactAll or InputMapperDeactivateAll
SE.origCameraActivate = SE.origCameraActivate or CameraActivate
local function isOurMap(n)
  n = tostring(n)
  return n:find("CharacterZoo", 1, true) or n:find("WidgetInputHandler", 1, true)
end
local function forget(name)
  for i = #SE.act, 1, -1 do if SE.act[i].name == name then table.remove(SE.act, i) end end
end
InputMapperActivate = function(name, ...)
  if not SE.internal and not isOurMap(name) then
    pcall(function(...)
      forget(name)
      table.insert(SE.act, { name = name, args = { ... }, n = luaSelect("#", ...) })
    end, ...)
  end
  return SE.origActivate(name, ...)
end
InputMapperDeactivate = function(name, ...)
  if not SE.internal and not isOurMap(name) then pcall(forget, name) end
  return SE.origDeactivate(name, ...)
end
if type(SE.origDeactAll) == "function" then
  InputMapperDeactivateAll = function(...)
    if not SE.internal then SE.act = {} end
    return SE.origDeactAll(...)
  end
end
CameraActivate = function(name, ...)
  if not SE.internal then SE.gameCam = name end
  return SE.origCameraActivate(name, ...)
end

-- keep the redirect active in this episode too (next episode, loading a save...)
pcall(require, "Freecam_Hook.lua")

local archive, level = readCfg()
if not level or level == "" then
  log("no level in ini - normal play: hooking SceneOpen")
  if type(SceneOpen) == "function" and not SE.sceneOpenWrapped then
    SE.sceneOpenWrapped = true
    local origOpen = SceneOpen
    SceneOpen = function(sceneFile, fn, ...)
      log("SceneOpen(" .. tostring(sceneFile) .. ", " .. tostring(fn) .. ")")
      if type(fn) == "string" and type(_G[fn]) == "function" and not SE.wrappedFns then SE.wrappedFns = {} end
      if type(fn) == "string" and type(_G[fn]) == "function" and not SE.wrappedFns[fn] then
        SE.wrappedFns[fn] = true
        local orig = _G[fn]
        _G[fn] = function(...)
          log("level function " .. fn .. " invoked by the game")
          local r1, r2 = orig(...)
          try("takeOver", takeOver, "after level function")
          return r1, r2
        end
      end
      return origOpen(sceneFile, fn, ...)
    end
  end
else
  local before = {}
  for k in pairs(_G) do before[k] = true end

  log("Running level script " .. level .. ".lua")
  local ok, err = false, "require unavailable"
  if type(require) == "function" then
    if package and package.loaded then package.loaded[level .. ".lua"] = nil end
    ok, err = pcall(require, level .. ".lua")
    log("require(level) -> " .. tostring(ok) .. " " .. tostring(err))
  end
  if not ok then
    ok, err = pcall(LoadScript, level .. ".lua")
    log("LoadScript(level) -> " .. tostring(ok) .. " " .. tostring(err))
  end

  local newFns = {}
  for k, v in pairs(_G) do
    if not before[k] and type(v) == "function" then table.insert(newFns, k) end
  end
  table.sort(newFns)
  log("new global functions from level script (" .. #newFns .. "): " .. table.concat(newFns, ", "))

  -- the game calls the level function (named like the level, minus 'env_') once the scene is open
  local want = level:gsub("^[Ee]nv_", ""):lower()
  local hooked = false
  for _, k in ipairs(newFns) do
    if k:lower() == want then
      local orig = _G[k]
      _G[k] = function(...)
        log("level function " .. k .. " invoked by the game")
        local r1, r2 = orig(...)
        try("takeOver", takeOver, "after level function")
        return r1, r2
      end
      hooked = true
      log("hooked level function " .. k)
    end
  end
  if not hooked then log("could not find level function matching '" .. want .. "'") end

  try("takeOver now", takeOver, "after script")
end
