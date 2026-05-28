-- display.lua
-- Runs on a CC computer wired to a 3x3 advanced monitor and an ender/wired modem.
-- Loads pre-baked map_overworld.lua and map_nether.lua, listens to station events,
-- maintains train state, and renders.
--
-- Rendering uses the half-block trick: each character cell renders TWO vertical
-- pixels via the '\127' / '\143' characters (▀ effectively) by setting bg and fg
-- to the two pixel colours. Effective resolution = monitor_chars_w x (monitor_chars_h * 2).
--
-- For a 3x3 advanced monitor at scale 0.5: 164 x 81.

local CHANNEL       = "train_map"
local REDRAW_PERIOD = 0.25
local TRAIN_TIMEOUT = 600         -- drop trains we haven't heard about in N seconds

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
local PW, PH = CW, CH * 2     -- pixel-space dimensions with half-block trick

-- ---------------------------------------------------------------------------
-- Map loading

local function loadMap(path)
  if not fs.exists(path) then return nil end
  local fn = loadfile(path)
  if not fn then return nil end
  return fn()
end

local maps = {
  overworld = loadMap("map_overworld.lua"),
  nether    = loadMap("map_nether.lua"),
}
assert(maps.overworld or maps.nether, "no maps loaded")

local currentDim = maps.overworld and "overworld" or "nether"

-- ---------------------------------------------------------------------------
-- Palette setup: apply per-dimension palette to monitor colour slots

local PALETTE_SLOTS = {
  colors.white, colors.orange, colors.magenta, colors.lightBlue,
  colors.yellow, colors.lime, colors.pink, colors.gray,
  colors.lightGray, colors.cyan, colors.purple, colors.blue,
  colors.brown, colors.green, colors.red, colors.black,
}
local HEX_TO_SLOT = {}
for i, slot in ipairs(PALETTE_SLOTS) do HEX_TO_SLOT[i - 1] = slot end
-- Reserve one slot for train markers; we overwrite slot 15 (black) at render time
-- if needed, but the half-block trick means we just need *colours.red* available
-- with a high-contrast value.
local TRAIN_COLOUR = colors.red

local function applyPalette(map)
  for idx = 0, 15 do
    local hex = map.palette[idx]
    if hex then mon.setPaletteColour(HEX_TO_SLOT[idx], hex) end
  end
  -- Force the train marker slot to bright red regardless of map palette
  mon.setPaletteColour(TRAIN_COLOUR, 0xff0040)
end

-- ---------------------------------------------------------------------------
-- Rendering

local hexVal = {}
for i = 0, 15 do hexVal[string.format("%x", i)] = i end

local function pixelAt(map, x, y)
  -- x in [0, PW), y in [0, PH)
  if x < 0 or x >= map.width or y < 0 or y >= map.height then return 15 end
  local idx = y * map.width + x + 1
  return hexVal[map.pixels:sub(idx, idx)] or 15
end

-- Train overlay: list of {dim=, px=, py=, name=}
local trainPixels = {}

local function isTrainAt(px, py)
  for _, t in ipairs(trainPixels) do
    if t.dim == currentDim and t.px == px and t.py == py then return t end
  end
end

-- Half-block character: U+2580 ▀ — top half foreground, bottom half background.
-- CC uses the legacy "\143" for the top-half block in its bundled font.
local HALF = "\143"

local function render()
  local map = maps[currentDim]
  if not map then return end
  applyPalette(map)

  -- Build per-row strings: each char cell = 2 vertical pixels.
  for cy = 1, CH do
    local pyTop = (cy - 1) * 2
    local pyBot = pyTop + 1
    local chars, fgs, bgs = {}, {}, {}
    for cx = 1, CW do
      local px = cx - 1
      local topIdx = pixelAt(map, px, pyTop)
      local botIdx = pixelAt(map, px, pyBot)

      -- Train markers override the underlying pixel
      local topIsTrain = isTrainAt(px, pyTop) ~= nil
      local botIsTrain = isTrainAt(px, pyBot) ~= nil

      local fgCol = topIsTrain and TRAIN_COLOUR or HEX_TO_SLOT[topIdx]
      local bgCol = botIsTrain and TRAIN_COLOUR or HEX_TO_SLOT[botIdx]
      chars[cx] = HALF
      fgs[cx]   = colors.toBlit(fgCol)
      bgs[cx]   = colors.toBlit(bgCol)
    end
    mon.setCursorPos(1, cy)
    mon.blit(table.concat(chars), table.concat(fgs), table.concat(bgs))
  end
end

-- ---------------------------------------------------------------------------
-- Station registry & train state

-- stations[id] = { dimension, coords={x,z}, name }
local stations = {}

-- trains[name] = {
--   dim, lastStation, departedAt, nextStation, edgeETA,
--   currentPx, currentPy,
-- }
local trains = {}

-- edges[fromId..">"..toId] = { dim, knownSeconds }
local edges = {}

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
    -- Drop stale trains
    if t.lastSeen and (now - t.lastSeen) > TRAIN_TIMEOUT then
      trains[name] = nil
    else
      local map = maps[t.dim]
      if map and t.lastStation then
        local from = stations[t.lastStation]
        if t.atStation then
          if from then
            local px, py = worldToPixel(map, from.coords.x, from.coords.z)
            trainPixels[#trainPixels + 1] = { dim = t.dim, px = px, py = py, name = name }
          end
        elseif t.nextStation and stations[t.nextStation] then
          local to = stations[t.nextStation]
          local key = t.lastStation .. ">" .. t.nextStation
          local eta = edges[key] and edges[key].knownSeconds or 60
          local elapsed = now - (t.departedAt or now)
          local progress = math.min(1, elapsed / eta)
          if from and to then
            local wx = lerp(from.coords.x, to.coords.x, progress)
            local wz = lerp(from.coords.z, to.coords.z, progress)
            local px, py = worldToPixel(map, wx, wz)
            trainPixels[#trainPixels + 1] = { dim = t.dim, px = px, py = py, name = name }
          end
        elseif from then
          local px, py = worldToPixel(map, from.coords.x, from.coords.z)
          trainPixels[#trainPixels + 1] = { dim = t.dim, px = px, py = py, name = name }
        end
      end
    end
  end
end

local function nextStationFromSchedule(train)
  -- Best-effort: pull first DESTINATION entry from getSchedule output.
  -- Schedule format is a Create-specific table; we don't always have one,
  -- and parsing it is left for live testing. Return nil for now.
  return nil
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
    -- If we knew this train was travelling lastStation -> sid, record edge time
    if t.lastStation and t.departedAt and t.nextStation == sid then
      local key = t.lastStation .. ">" .. sid
      edges[key] = { dim = msg.dimension, knownSeconds = now - t.departedAt }
    end
    t.dim = msg.dimension
    t.lastStation = sid
    t.atStation = true
    t.departedAt = nil
    t.nextStation = nil
    t.lastSeen = now
    trains[trainName] = t

  elseif msg.event == "departed" and trainName then
    local t = trains[trainName] or { dim = msg.dimension }
    t.dim = msg.dimension
    t.lastStation = t.lastStation or sid
    t.atStation = false
    t.departedAt = now
    t.lastSeen = now
    -- We don't know nextStation reliably without parsing schedule; left nil
    trains[trainName] = t
  end
end

-- ---------------------------------------------------------------------------
-- Input: monitor_touch toggles dimension

local function inputLoop()
  while true do
    local ev, side, x, y = os.pullEvent()
    if ev == "monitor_touch" then
      currentDim = (currentDim == "overworld") and "nether" or "overworld"
      if not maps[currentDim] then
        currentDim = (currentDim == "overworld") and "nether" or "overworld"
      end
    elseif ev == "rednet_message" then
      local _, msg, proto = side, x, y
      if proto == CHANNEL then handleEvent(msg) end
    end
  end
end

local function renderLoop()
  while true do
    recomputeTrainPositions()
    render()
    sleep(REDRAW_PERIOD)
  end
end

parallel.waitForAny(inputLoop, renderLoop)
