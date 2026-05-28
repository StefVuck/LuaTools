-- staticmap.lua
-- Renders a pre-baked bitmap map then overlays station labels in CC-native
-- text (crisp at any scale).
--
-- Bitmap uses --colours 14, leaving CC palette slots 14+15 free:
--   slot 14 (colors.black) = label foreground  0x001180  navy
--   slot 15 (colors.red)   = label background  0xffffff  white

local MAPS    = { "map_trainmap.lua" }
local REFRESH = 30   -- seconds between redraws

-- Station labels: { cx, cy, text }
-- cx/cy are 1-based character coordinates on the monitor.
-- Adjust these if labels appear slightly off on your monitor.
local LABELS = {
  { cx = 14, cy =  7, text = "Newholm"       },
  { cx = 48, cy =  6, text = "Spawn"         },
  { cx = 48, cy =  7, text = "Sidings"       },
  { cx = 94, cy = 10, text = "Raventon"      },
  { cx =  2, cy = 14, text = "San Del"       },
  { cx =  2, cy = 15, text = "Norte"         },
}

-- Optional zone label (rendered differently -- dark text on pink bg)
-- Set to nil to disable.
local ZONE_LABEL = { cx = 40, cy = 15, text = "N" }

-- Label colours (applied AFTER bitmap render; slots 14+15 are reserved)
local TEXT_FG_COLOUR  = colors.black  -- palette slot 14
local TEXT_FG_VALUE   = 0x001180      -- navy blue
local TEXT_BG_COLOUR  = colors.red    -- palette slot 15
local TEXT_BG_VALUE   = 0xffffff      -- white

-- ---------------------------------------------------------------------------
-- Peripheral setup

local function findFirst(type_)
  for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == type_ then return side end
  end
end

local monitorSide = findFirst("monitor") or error("no monitor found")
local mon = peripheral.wrap(monitorSide)
mon.setTextScale(0.5)
local CW, CH = mon.getSize()
print(("Monitor: %d x %d chars  ->  %d x %d px"):format(CW, CH, CW, CH * 2))

-- ---------------------------------------------------------------------------
-- Map loading

local function loadMap(path)
  if not fs.exists(path) then return nil end
  local fn = loadfile(path)
  return fn and fn() or nil
end

local maps = {}
for _, f in ipairs(MAPS) do
  local m = loadMap(f)
  if m then maps[#maps + 1] = m ; print("Loaded " .. f)
  else print("WARNING: could not load " .. f) end
end
assert(#maps > 0, "no maps loaded -- check MAPS at top of file")

local current = 1

-- ---------------------------------------------------------------------------
-- Palette
-- 16 slots listed; bitmap was generated with --colours 14, so only slots
-- 0-13 are used by pixel data. Slots 14 (colors.black) and 15 (colors.red)
-- are never written during blit and are safe to repurpose for text.

local PALETTE_SLOTS = {
  colors.white, colors.orange, colors.magenta, colors.lightBlue,
  colors.yellow, colors.lime,  colors.pink,    colors.gray,
  colors.lightGray, colors.cyan, colors.purple, colors.blue,
  colors.brown, colors.green, colors.black, colors.red,
}
local HEX_TO_SLOT = {}
for i, slot in ipairs(PALETTE_SLOTS) do HEX_TO_SLOT[i - 1] = slot end

local hexVal = {}
for i = 0, 15 do hexVal[string.format("%x", i)] = i end

local HALF = "\143"

-- ---------------------------------------------------------------------------
-- Render bitmap

local function renderBitmap(map)
  for idx = 0, 15 do
    local hex = map.palette[idx]
    if hex then mon.setPaletteColour(HEX_TO_SLOT[idx], hex) end
  end

  for cy = 1, CH do
    local pyTop = (cy - 1) * 2
    local pyBot = pyTop + 1
    local chars, fgs, bgs = {}, {}, {}
    for cx = 1, CW do
      local px = cx - 1
      local function pix(y)
        if px < 0 or px >= map.width or y < 0 or y >= map.height then
          return 0
        end
        local i = y * map.width + px + 1
        return hexVal[map.pixels:sub(i, i)] or 0
      end
      chars[cx] = HALF
      fgs[cx]   = colors.toBlit(HEX_TO_SLOT[pix(pyTop)])
      bgs[cx]   = colors.toBlit(HEX_TO_SLOT[pix(pyBot)])
    end
    mon.setCursorPos(1, cy)
    mon.blit(table.concat(chars), table.concat(fgs), table.concat(bgs))
  end
end

-- ---------------------------------------------------------------------------
-- Overlay station labels using CC-native text (crisp at any scale)

local function renderLabels()
  -- Reassign the two reserved palette slots
  mon.setPaletteColour(TEXT_FG_COLOUR, TEXT_FG_VALUE)
  mon.setPaletteColour(TEXT_BG_COLOUR, TEXT_BG_VALUE)

  mon.setTextColour(TEXT_FG_COLOUR)
  mon.setBackgroundColour(TEXT_BG_COLOUR)

  for _, lbl in ipairs(LABELS) do
    if lbl.cx >= 1 and lbl.cx <= CW and lbl.cy >= 1 and lbl.cy <= CH then
      mon.setCursorPos(lbl.cx, lbl.cy)
      -- Truncate if label would run off screen
      local max_len = CW - lbl.cx + 1
      mon.write(lbl.text:sub(1, max_len))
    end
  end

  if ZONE_LABEL then
    -- Zone label: use existing colours (no bg override needed for single char)
    mon.setCursorPos(ZONE_LABEL.cx, ZONE_LABEL.cy)
    mon.write(ZONE_LABEL.text)
  end
end

-- ---------------------------------------------------------------------------
-- Full render pass

local function render()
  renderBitmap(maps[current])
  renderLabels()
end

-- ---------------------------------------------------------------------------
-- Main loop

local function main()
  while true do
    render()
    local timer = os.startTimer(REFRESH)
    while true do
      local ev, a = os.pullEvent()
      if ev == "timer" and a == timer then
        break
      elseif ev == "monitor_touch" and #maps > 1 then
        current = (current % #maps) + 1
        break
      end
    end
  end
end

main()
