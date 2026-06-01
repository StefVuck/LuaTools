-- display.lua
-- Scrollable, pannable, zoomable map display for CC:Tweaked + CC:Sable.
--
-- Requires a single high-resolution map file per dimension.
-- Generate with:
--   python map.py input.png map_overworld.lua \
--     --width 500 --height 670 \
--     --bbox -83 -1183 1917 1497 \
--     --dimension overworld --colours 14
-- Adjust --width/--height to keep your bbox aspect ratio; ~4 blocks/pixel
-- gives good detail. Larger = more detail, bigger file.
--
-- Controls:
--   Monitor touch    - centre view on tapped location
--   Arrow keys       - pan
--   Z / X            - zoom in / out
--   R                - reload map + reset view
--   D                - toggle dimension
--   Redstone analog  - zoom (0 = widest, 15 = closest)
--
-- Markers:
--   Red dot          - train (with black halo ring)
--   ^ > v < *        - airship heading + name + speed
--   \127 (house)     - base + name

local CHANNEL         = "train_map"
local REDRAW_PERIOD   = 0.25
local TRAIN_TIMEOUT   = 600
local AIRSHIP_TIMEOUT = 300
local PAN_STEP        = 8      -- screen pixels per arrow keypress
local ZOOM_STEP       = 1.25   -- scale multiplier per Z/X keypress

-- ---------------------------------------------------------------------------
-- Static base markers  (fill in your bases here)
local BASES = {
  -- { name = "Main Base",  dim = "overworld", x =  500, z = -300 },
  -- { name = "Nether Hub", dim = "nether",    x =    0, z =    0 },
}

-- ---------------------------------------------------------------------------
-- Peripherals

local function findFirst(t)
  for _, s in ipairs(peripheral.getNames()) do
    if peripheral.getType(s) == t then return s end
  end
end

local monitorSide = findFirst("monitor") or error("no monitor")
local modemSide   = findFirst("modem")   or error("no modem")
local mon = peripheral.wrap(monitorSide)
rednet.open(modemSide)

mon.setTextScale(0.5)
local CW, CH = mon.getSize()
local PH = CH * 2
print(("Monitor: %d x %d chars  ->  %d x %d px"):format(CW, CH, CW, PH))

-- ---------------------------------------------------------------------------
-- Map loading  (single file per dimension)

local function loadMap(path)
  if not fs.exists(path) then return nil end
  local fn = loadfile(path)
  return fn and fn() or nil
end

local MAP_FILES = {
  overworld = "map_overworld.lua",
  nether    = "map_nether.lua",
}
local maps = { overworld = nil, nether = nil }

local function loadAllMaps()
  for dim, f in pairs(MAP_FILES) do
    maps[dim] = loadMap(f)
    if maps[dim] then
      print(("  %s: %dx%d px"):format(dim, maps[dim].width, maps[dim].height))
    end
  end
end

loadAllMaps()
assert(maps.overworld or maps.nether, "no maps loaded")

local currentDim = maps.overworld and "overworld" or "nether"

local function currentMap() return maps[currentDim] end

-- ---------------------------------------------------------------------------
-- Viewport
--   view.left / view.top  : top-left corner in map-pixel space
--   view.scale            : map pixels per screen pixel (1 = max detail)

local view = { left = 0.0, top = 0.0, scale = 1.0 }

local function maxScale(map)
  if not map then return 1.0 end
  return math.max(map.width / CW, map.height / PH)
end

local function clampView(map)
  if not map then return end
  local ms = maxScale(map)
  view.scale = math.max(1.0, math.min(ms, view.scale))
  view.left  = math.max(0, math.min(map.width  - CW * view.scale, view.left))
  view.top   = math.max(0, math.min(map.height - PH * view.scale, view.top))
end

local function resetView()
  local map = currentMap()
  if not map then return end
  view.scale = maxScale(map)
  view.left  = 0
  view.top   = 0
end

local function zoomAround(newScale, pivotMapX, pivotMapY)
  local map = currentMap()
  if not map then return end
  view.scale = math.max(1.0, math.min(maxScale(map), newScale))
  view.left  = pivotMapX - (CW / 2) * view.scale
  view.top   = pivotMapY - (PH / 2) * view.scale
  clampView(map)
end

local function zoomIn()
  local cx = view.left + (CW / 2) * view.scale
  local cy = view.top  + (PH / 2) * view.scale
  zoomAround(view.scale / ZOOM_STEP, cx, cy)
end

local function zoomOut()
  local cx = view.left + (CW / 2) * view.scale
  local cy = view.top  + (PH / 2) * view.scale
  zoomAround(view.scale * ZOOM_STEP, cx, cy)
end

local function pan(dsx, dsy)
  local map = currentMap()
  if not map then return end
  view.left = view.left + dsx * view.scale
  view.top  = view.top  + dsy * view.scale
  clampView(map)
end

local function centreTouchAt(charX, charY)
  local map = currentMap()
  if not map then return end
  -- Convert character click to map pixel, then centre view there
  local mapX = view.left + (charX - 1) * view.scale
  local mapY = view.top  + ((charY - 1) * 2) * view.scale
  view.left  = mapX - (CW / 2) * view.scale
  view.top   = mapY - (PH / 2) * view.scale
  clampView(map)
end

resetView()

-- ---------------------------------------------------------------------------
-- Coordinate transforms

-- World position -> screen pixel (0-indexed; may be off-screen)
local function worldToScreen(map, wx, wz)
  local fx  = (wx - map.bbox.minX) / (map.bbox.maxX - map.bbox.minX)
  local fy  = (wz - map.bbox.minZ) / (map.bbox.maxZ - map.bbox.minZ)
  local mpx = fx * map.width
  local mpy = fy * map.height
  return math.floor((mpx - view.left) / view.scale + 0.5),
         math.floor((mpy - view.top)  / view.scale + 0.5)
end

-- ---------------------------------------------------------------------------
-- Palette
-- With --colours 14, indices 0-13 are used; slot 14 (colors.black) and
-- colors.red (slot 16, never in PALETTE_SLOTS) remain free for markers.

local PALETTE_SLOTS = {
  colors.white, colors.orange, colors.magenta, colors.lightBlue,
  colors.yellow, colors.lime,  colors.pink,    colors.gray,
  colors.lightGray, colors.cyan, colors.purple, colors.blue,
  colors.brown, colors.green, colors.black,
}
local HEX_TO_SLOT = {}
for i, slot in ipairs(PALETTE_SLOTS) do HEX_TO_SLOT[i - 1] = slot end

local TRAIN_COLOUR = colors.red

local function applyPalette(map)
  for idx = 0, #PALETTE_SLOTS - 1 do
    local hex = map.palette[idx]
    if hex then mon.setPaletteColour(HEX_TO_SLOT[idx], hex) end
  end
  mon.setPaletteColour(TRAIN_COLOUR, 0xff0040)
  mon.setPaletteColour(colors.black, 0x111111)
end

-- ---------------------------------------------------------------------------
-- Rendering

local hexVal = {}
for i = 0, 15 do hexVal[string.format("%x", i)] = i end

local function pixelAt(map, x, y)
  x = math.floor(x); y = math.floor(y)
  -- Return slot 14 (colors.black = near-black) for out-of-map areas
  if x < 0 or x >= map.width or y < 0 or y >= map.height then return 14 end
  local idx = y * map.width + x + 1
  return hexVal[map.pixels:sub(idx, idx)] or 0
end

-- trainPixels and airshipPixels store SCREEN pixel coords (sx, sy 0-indexed)
local trainPixels   = {}
local airshipPixels = {}

local function isTrainAt(sx, sy)
  for _, t in ipairs(trainPixels) do
    if t.sx == sx and t.sy == sy then return t end
  end
end

local function isAdjacentToTrain(sx, sy)
  return isTrainAt(sx-1, sy) or isTrainAt(sx+1, sy) or
         isTrainAt(sx, sy-1) or isTrainAt(sx, sy+1)
end

local HALF = "\143"

local function render()
  local map = currentMap()
  if not map then return end
  applyPalette(map)

  for cy = 1, CH do
    local syTop = (cy - 1) * 2
    local syBot = syTop + 1
    local chars, fgs, bgs = {}, {}, {}
    for cx = 1, CW do
      local sx   = cx - 1
      local tIdx = pixelAt(map, view.left + sx * view.scale, view.top + syTop * view.scale)
      local bIdx = pixelAt(map, view.left + sx * view.scale, view.top + syBot * view.scale)

      local topTr   = isTrainAt(sx, syTop)
      local botTr   = isTrainAt(sx, syBot)
      local topRing = not topTr and isAdjacentToTrain(sx, syTop)
      local botRing = not botTr and isAdjacentToTrain(sx, syBot)

      chars[cx] = HALF
      fgs[cx] = colors.toBlit(
        topTr and TRAIN_COLOUR or topRing and colors.black or HEX_TO_SLOT[tIdx])
      bgs[cx] = colors.toBlit(
        botTr and TRAIN_COLOUR or botRing and colors.black or HEX_TO_SLOT[bIdx])
    end
    mon.setCursorPos(1, cy)
    mon.blit(table.concat(chars), table.concat(fgs), table.concat(bgs))
  end
end

-- ---------------------------------------------------------------------------
-- HUD overlays

local function blitLabel(cx, cy, icon, label)
  local fg = colors.toBlit(TRAIN_COLOUR)
  local bg = colors.toBlit(colors.black)
  if cx < 1 or cx > CW or cy < 1 or cy > CH then return end
  mon.setCursorPos(cx, cy)
  mon.blit(icon, fg, bg)
  if label and #label > 0 and cx + 1 <= CW then
    local s = label:sub(1, CW - cx)
    mon.setCursorPos(cx + 1, cy)
    mon.blit(s, fg:rep(#s), bg:rep(#s))
  end
end

local function renderHUD()
  local map = currentMap()
  if not map then return end
  local fg = colors.toBlit(TRAIN_COLOUR)
  local bg = colors.toBlit(colors.black)

  -- Top-right: scale indicator  "1:N"
  local bpp = view.scale * (map.bbox.maxX - map.bbox.minX) / map.width
  local scaleStr = "1:" .. tostring(math.max(1, math.floor(bpp + 0.5)))
  local slen = #scaleStr
  mon.setCursorPos(CW - slen + 1, 1)
  mon.blit(scaleStr, fg:rep(slen), bg:rep(slen))

  -- Top-left: centre world coordinates  "x### z###"
  local cmx = view.left + (CW / 2) * view.scale
  local cmy = view.top  + (PH / 2) * view.scale
  local wx  = map.bbox.minX + cmx / map.width  * (map.bbox.maxX - map.bbox.minX)
  local wz  = map.bbox.minZ + cmy / map.height * (map.bbox.maxZ - map.bbox.minZ)
  local coordStr = ("x%d z%d"):format(math.floor(wx), math.floor(wz))
  local clen = #coordStr
  mon.setCursorPos(1, 1)
  mon.blit(coordStr, fg:rep(clen), bg:rep(clen))
end

local function headingChar(vx, vz)
  local speed = math.sqrt(vx * vx + vz * vz)
  if speed < 0.5 then return "*" end
  local deg = math.deg(math.atan2(-vz, vx))
  if deg < 0 then deg = deg + 360 end
  if     deg >= 45  and deg < 135 then return "^"
  elseif deg >= 135 and deg < 225 then return "<"
  elseif deg >= 225 and deg < 315 then return "v"
  else                                  return ">"
  end
end

local function renderBases()
  local map = currentMap()
  if not map or #BASES == 0 then return end
  for _, base in ipairs(BASES) do
    if base.dim == currentDim then
      local sx, sy = worldToScreen(map, base.x, base.z)
      if sx >= 0 and sx < CW and sy >= 0 and sy < PH then
        blitLabel(sx + 1, math.floor(sy / 2) + 1, "\127", base.name)
      end
    end
  end
end

local function renderAirships()
  for _, a in ipairs(airshipPixels) do
    if a.sx >= 0 and a.sx < CW and a.sy >= 0 and a.sy < PH then
      local speed = math.sqrt(a.vx ^ 2 + a.vz ^ 2)
      blitLabel(a.sx + 1, math.floor(a.sy / 2) + 1,
        headingChar(a.vx, a.vz),
        ("%s %.1f/s"):format(a.name, speed))
    end
  end
end

-- ---------------------------------------------------------------------------
-- Station registry & train state

local stations = {}
local trains   = {}
local airships = {}
local edges    = {}

local function lerp(a, b, t) return a + (b - a) * t end

local function recomputeTrainPositions()
  trainPixels = {}
  local now = os.epoch("utc") / 1000
  local map = currentMap()
  for name, t in pairs(trains) do
    if t.lastSeen and (now - t.lastSeen) > TRAIN_TIMEOUT then
      trains[name] = nil
    elseif map and t.dim == currentDim and t.lastStation then
      local from = stations[t.lastStation]
      local wx, wz
      if t.atStation and from then
        wx, wz = from.coords.x, from.coords.z
      elseif t.nextStation and stations[t.nextStation] and from then
        local to  = stations[t.nextStation]
        local key = t.lastStation .. ">" .. t.nextStation
        local eta = edges[key] and edges[key].knownSeconds or 60
        local p   = math.min(1, (now - (t.departedAt or now)) / eta)
        wx = lerp(from.coords.x, to.coords.x, p)
        wz = lerp(from.coords.z, to.coords.z, p)
      elseif from then
        wx, wz = from.coords.x, from.coords.z
      end
      if wx then
        local sx, sy = worldToScreen(map, wx, wz)
        trainPixels[#trainPixels + 1] = { sx = sx, sy = sy, name = name }
      end
    end
  end
end

local function recomputeAirshipPositions()
  airshipPixels = {}
  local now = os.epoch("utc") / 1000
  local map = currentMap()
  if not map then return end
  for name, a in pairs(airships) do
    if (now - a.lastSeen) > AIRSHIP_TIMEOUT then
      airships[name] = nil
    elseif a.dim == currentDim then
      local dt = now - a.lastSeen
      local sx, sy = worldToScreen(map, a.x + (a.vx or 0) * dt,
                                        a.z + (a.vz or 0) * dt)
      airshipPixels[#airshipPixels + 1] = {
        sx = sx, sy = sy, name = name,
        vx = a.vx or 0, vz = a.vz or 0,
      }
    end
  end
end

local function handleEvent(msg)
  if not msg then return end

  if msg.type == "airship" then
    if msg.name and msg.coords then
      airships[msg.name] = {
        dim      = msg.dimension or "overworld",
        x        = msg.coords.x,
        z        = msg.coords.z,
        vx       = msg.velocity and msg.velocity.x or 0,
        vz       = msg.velocity and msg.velocity.z or 0,
        lastSeen = os.epoch("utc") / 1000,
      }
    end
    return
  end

  if not msg.stationId then return end
  local sid = msg.stationId
  stations[sid] = stations[sid] or {}
  stations[sid].dimension = msg.dimension
  stations[sid].coords    = msg.coords
  if msg.extra and msg.extra.stationName then
    stations[sid].name = msg.extra.stationName
  end

  local trainName = msg.extra and msg.extra.trainName
  if not trainName and msg.event ~= "hello" then return end
  local now = msg.time / 1000

  if msg.event == "arrived" and trainName then
    local t = trains[trainName] or { dim = msg.dimension }
    if t.lastStation and t.departedAt and t.nextStation == sid then
      edges[t.lastStation .. ">" .. sid] = {
        dim = msg.dimension, knownSeconds = now - t.departedAt
      }
    end
    t.dim = msg.dimension; t.lastStation = sid
    t.atStation = true;  t.departedAt = nil; t.nextStation = nil
    t.lastSeen  = now;   trains[trainName] = t

  elseif msg.event == "departed" and trainName then
    local t = trains[trainName] or { dim = msg.dimension }
    t.dim = msg.dimension; t.lastStation = t.lastStation or sid
    t.atStation = false; t.departedAt = now; t.lastSeen = now
    trains[trainName] = t
  end
end

-- ---------------------------------------------------------------------------
-- Redstone zoom

local function zoomFromRedstone()
  local map = currentMap()
  if not map then return end
  local s = 0
  for _, side in ipairs({"top","bottom","left","right","front","back"}) do
    s = math.max(s, rs.getAnalogInput(side))
  end
  -- 0 = widest (maxScale), 15 = closest (scale 1)
  local ms  = maxScale(map)
  local cx  = view.left + (CW / 2) * view.scale
  local cy  = view.top  + (PH / 2) * view.scale
  zoomAround(ms + (1 - ms) * (s / 15), cx, cy)
end

-- ---------------------------------------------------------------------------
-- Input & render loops

local function inputLoop()
  while true do
    local ev, a, b, c = os.pullEvent()

    if ev == "monitor_touch" then
      centreTouchAt(b, c)

    elseif ev == "key" then
      if     a == keys.up    then pan(0, -PAN_STEP)
      elseif a == keys.down  then pan(0,  PAN_STEP)
      elseif a == keys.left  then pan(-PAN_STEP, 0)
      elseif a == keys.right then pan( PAN_STEP, 0)
      elseif a == keys.z     then zoomIn()
      elseif a == keys.x     then zoomOut()
      elseif a == keys.r     then loadAllMaps(); resetView()
      elseif a == keys.d     then
        local other = (currentDim == "overworld") and "nether" or "overworld"
        if maps[other] then currentDim = other; resetView() end
      end

    elseif ev == "redstone" then
      zoomFromRedstone()

    elseif ev == "rednet_message" then
      local _, msg, proto = a, b, c
      if proto == CHANNEL then handleEvent(msg) end
    end
  end
end

local function renderLoop()
  while true do
    recomputeTrainPositions()
    recomputeAirshipPositions()
    render()
    renderHUD()
    renderAirships()
    renderBases()
    sleep(REDRAW_PERIOD)
  end
end

parallel.waitForAny(inputLoop, renderLoop)
