-- display.lua
-- Central map display with multi-zoom and redstone zoom control.
--
-- Map files expected (widest -> closest):
--   map_overworld_z1.lua  (1:20 - widest overview)
--   map_overworld_z2.lua  (1:10)
--   map_overworld_z3.lua  (1:5)
--   map_overworld_z4.lua  (1:3)
--   map_overworld_z5.lua  (1:2)
--   map_overworld_z6.lua  (1:1  - 1 block per pixel)
--   map_nether_z*.lua     (optional, same structure)
--
-- Controls:
--   Monitor touch  - cycle zoom level
--   Redstone       - any side, analog 0-15 selects zoom (0=widest, 15=closest)
--   R key          - reload all map files from disk
--   D key          - toggle dimension
--
-- Scale indicator: top-right corner shows "1:S" (blocks per pixel) after each render.

local CHANNEL       = "train_map"
local REDRAW_PERIOD = 0.25
local TRAIN_TIMEOUT = 600

-- ---------------------------------------------------------------------------
-- Peripherals

local function findFirst(type_)
  for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == type_ then return side end
  end
end

local monitorSide = findFirst("monitor") or error("no monitor")
local modemSide   = findFirst("modem")   or error("no modem")
local mon = peripheral.wrap(monitorSide)
rednet.open(modemSide)

mon.setTextScale(0.5)
local CW, CH = mon.getSize()
local PW, PH = CW, CH * 2
print(("Monitor: %d x %d chars -> map %d x %d px"):format(CW, CH, PW, PH))

-- ---------------------------------------------------------------------------
-- Map loading

local function loadMap(path)
  if not fs.exists(path) then return nil end
  local fn = loadfile(path)
  return fn and fn() or nil
end

local MAP_FILES = {
  overworld = {
    "map_overworld_z1.lua",   -- 1:20  widest overview
    "map_overworld_z2.lua",   -- 1:10
    "map_overworld_z3.lua",   -- 1:5
    "map_overworld_z4.lua",   -- 1:3
    "map_overworld_z5.lua",   -- 1:2
    "map_overworld_z6.lua",   -- 1:1  one block per pixel
  },
  nether = {
    "map_nether_z1.lua",
    "map_nether_z2.lua",
    "map_nether_z3.lua",
    "map_nether_z4.lua",
    "map_nether_z5.lua",
    "map_nether_z6.lua",
  },
}
local allMaps = { overworld = {}, nether = {} }

local function loadAllMaps()
  for dim, files in pairs(MAP_FILES) do
    allMaps[dim] = {}
    for _, f in ipairs(files) do
      local m = loadMap(f)
      if m then allMaps[dim][#allMaps[dim] + 1] = m end
    end
  end
  print(("Loaded: %d overworld, %d nether zoom levels"):format(
    #allMaps.overworld, #allMaps.nether))
end

loadAllMaps()
assert(#allMaps.overworld > 0 or #allMaps.nether > 0, "no maps loaded")

local currentDim = (#allMaps.overworld > 0) and "overworld" or "nether"
local zoomLevel  = 1   -- 1 = widest, N = closest

local function currentMap()
  local list = allMaps[currentDim]
  if not list or #list == 0 then return nil end
  return list[math.min(zoomLevel, #list)]
end

-- ---------------------------------------------------------------------------
-- Palette
-- Only 15 CC colour slots are used for map data so that colors.red is never
-- overwritten by applyPalette and remains exclusively for train markers.

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
end

-- ---------------------------------------------------------------------------
-- Rendering

local hexVal = {}
for i = 0, 15 do hexVal[string.format("%x", i)] = i end

local function pixelAt(map, x, y)
  if x < 0 or x >= map.width or y < 0 or y >= map.height then return 0 end
  local idx = y * map.width + x + 1
  return hexVal[map.pixels:sub(idx, idx)] or 0
end

local trainPixels = {}

local function isTrainAt(px, py)
  for _, t in ipairs(trainPixels) do
    if t.dim == currentDim and t.px == px and t.py == py then return t end
  end
end

local HALF = "\143"

local function render()
  local map = currentMap()
  if not map then return end
  applyPalette(map)

  for cy = 1, CH do
    local pyTop = (cy - 1) * 2
    local pyBot = pyTop + 1
    local chars, fgs, bgs = {}, {}, {}
    for cx = 1, CW do
      local px   = cx - 1
      local tIdx = pixelAt(map, px, pyTop)
      local bIdx = pixelAt(map, px, pyBot)
      local topTr = isTrainAt(px, pyTop) ~= nil
      local botTr = isTrainAt(px, pyBot) ~= nil
      chars[cx] = HALF
      fgs[cx]   = colors.toBlit(topTr and TRAIN_COLOUR or HEX_TO_SLOT[tIdx])
      bgs[cx]   = colors.toBlit(botTr and TRAIN_COLOUR or HEX_TO_SLOT[bIdx])
    end
    mon.setCursorPos(1, cy)
    mon.blit(table.concat(chars), table.concat(fgs), table.concat(bgs))
  end
end

-- ---------------------------------------------------------------------------
-- Scale indicator  ("1:S" in top-right corner, using reserved palette slots)
--
-- With --colours 14, map pixel values only use indices 0-13, so:
--   colors.black (HEX_TO_SLOT[14]) - never written by applyPalette, safe to repurpose
--   TRAIN_COLOUR (colors.red)      - set to 0xff0040 by applyPalette, use for text fg

local function renderScaleIndicator()
  local map = currentMap()
  if not map then return end
  local s = math.floor((map.bbox.maxX - map.bbox.minX) / map.width + 0.5)
  local label = "1:" .. tostring(s)
  local len   = #label
  -- Dark background: set colors.black to near-black (never touched by applyPalette)
  mon.setPaletteColour(colors.black, 0x111111)
  local fg = colors.toBlit(TRAIN_COLOUR)   -- bright red/pink  (already 0xff0040)
  local bg = colors.toBlit(colors.black)   -- dark
  mon.setCursorPos(CW - len + 1, 1)
  mon.blit(label, fg:rep(len), bg:rep(len))
end

-- ---------------------------------------------------------------------------
-- Station registry & train state

local stations = {}
local trains   = {}
local edges    = {}

local function worldToPixel(map, wx, wz)
  local fx = (wx - map.bbox.minX) / (map.bbox.maxX - map.bbox.minX)
  local fy = (wz - map.bbox.minZ) / (map.bbox.maxZ - map.bbox.minZ)
  return math.floor(fx * map.width + 0.5), math.floor(fy * map.height + 0.5)
end

local function lerp(a, b, t) return a + (b - a) * t end

local function recomputeTrainPositions()
  trainPixels = {}
  local now = os.epoch("utc") / 1000
  for name, t in pairs(trains) do
    if t.lastSeen and (now - t.lastSeen) > TRAIN_TIMEOUT then
      trains[name] = nil
    else
      local map = currentMap()
      if map and t.dim == currentDim and t.lastStation then
        local from = stations[t.lastStation]
        if t.atStation and from then
          local px, py = worldToPixel(map, from.coords.x, from.coords.z)
          trainPixels[#trainPixels + 1] = { dim = t.dim, px = px, py = py, name = name }
        elseif t.nextStation and stations[t.nextStation] and from then
          local to  = stations[t.nextStation]
          local key = t.lastStation .. ">" .. t.nextStation
          local eta = edges[key] and edges[key].knownSeconds or 60
          local progress = math.min(1, (now - (t.departedAt or now)) / eta)
          local px, py = worldToPixel(map,
            lerp(from.coords.x, to.coords.x, progress),
            lerp(from.coords.z, to.coords.z, progress))
          trainPixels[#trainPixels + 1] = { dim = t.dim, px = px, py = py, name = name }
        elseif from then
          local px, py = worldToPixel(map, from.coords.x, from.coords.z)
          trainPixels[#trainPixels + 1] = { dim = t.dim, px = px, py = py, name = name }
        end
      end
    end
  end
end

local function handleEvent(msg)
  if not msg or not msg.stationId then return end
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
-- Zoom from redstone: check all sides, use the highest analog signal

local function zoomFromRedstone()
  local s = 0
  for _, side in ipairs({ "top", "bottom", "left", "right", "front", "back" }) do
    s = math.max(s, rs.getAnalogInput(side))
  end
  local n = math.max(1, #allMaps[currentDim])
  -- Map 0-15 evenly onto zoom levels 1..n
  return math.min(n, math.floor(s * n / 16) + 1)
end

-- ---------------------------------------------------------------------------
-- Input & render loops

local function inputLoop()
  while true do
    local ev, a, b, c = os.pullEvent()

    if ev == "monitor_touch" then
      local n = #allMaps[currentDim]
      if n > 0 then zoomLevel = (zoomLevel % n) + 1 end

    elseif ev == "redstone" then
      zoomLevel = zoomFromRedstone()

    elseif ev == "key" then
      if a == keys.r then
        loadAllMaps()
      elseif a == keys.d then
        local other = (currentDim == "overworld") and "nether" or "overworld"
        if #allMaps[other] > 0 then currentDim = other end
      end

    elseif ev == "rednet_message" then
      local _, msg, proto = a, b, c
      if proto == CHANNEL then handleEvent(msg) end
    end
  end
end

local function renderLoop()
  while true do
    recomputeTrainPositions()
    render()
    renderScaleIndicator()
    sleep(REDRAW_PERIOD)
  end
end

parallel.waitForAny(inputLoop, renderLoop)
