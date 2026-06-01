-- hud.lua
-- Airship HUD for a 5-wide x 3-tall horizontal monitor bank.
-- Listens on the "autopilot" rednet channel for status packets broadcast
-- by autopilot.lua, and also reads sublevel directly if co-located.
-- Layout adapts automatically to whatever monitor size is attached.
--
-- Layout (three equal panels side by side):
--   [ POSITION & DEST ] [ NAVIGATION STATUS ] [ COMPASS ]
--
-- Setup:
--   1. Place monitors in a 5-wide x 3-tall bank and attach to this computer.
--   2. Attach a wireless modem.
--   3. Set HEADING_OFFSET below if heading reads wrong when stationary.
--      Face the ship due North, note the displayed heading, set
--      HEADING_OFFSET = -(that value) so it reads 0.
--   4. Run:  autopilot/hud

-- ---------------------------------------------------------------------------
-- Heading offset correction
-- getLinearVelocity() may be in local sublevel space rather than world space.
-- If the ship was built facing a non-North direction, all headings will be
-- rotated by that construction angle.  Measure it once and put it here.
-- e.g. if ship was built facing West (270 deg), set HEADING_OFFSET = 90
--      so that the displayed heading is corrected back to world North = 0.

local HEADING_OFFSET = 90   -- degrees; adjust until North reads ~0 when facing North

-- ---------------------------------------------------------------------------
-- Peripherals

local function findFirst(t)
  for _, s in ipairs(peripheral.getNames()) do
    if peripheral.getType(s) == t then return s end
  end
end

local monSide  = findFirst("monitor") or error("no monitor found")
local mon      = peripheral.wrap(monSide)
mon.setTextScale(1)

local W, H = mon.getSize()
local PW   = math.floor(W / 3)   -- panel width in chars

local modemSide = findFirst("modem")
if modemSide then rednet.open(modemSide) end

-- ---------------------------------------------------------------------------
-- Colour palette

local C = {
  title  = colors.cyan,
  label  = colors.lightGray,
  value  = colors.white,
  good   = colors.lime,
  warn   = colors.yellow,
  bad    = colors.red,
  border = colors.gray,
  bg     = colors.black,
}

-- ---------------------------------------------------------------------------
-- State  (declared early so every function below can reference it)

local data = {
  name    = "?",
  phase   = "waiting",
  pos     = { x = 0, z = 0 },
  dest    = { x = 0, z = 0 },
  dist    = 0,
  vel     = { x = 0, z = 0 },
  speed   = 0,
  bearing = 0,      -- degrees clockwise from North to destination
  heading = 0,      -- degrees clockwise from North, current movement direction
  err_deg = 0,      -- signed heading error (+ve = turn right)
  zone    = "wait", -- fine / medium / coarse / wait
  eta     = nil,
  updated = 0,
}

local MAX_SPEED = 10   -- matches autopilot CFG.max_speed

-- ---------------------------------------------------------------------------
-- Drawing primitives

local function cls()
  mon.setBackgroundColor(C.bg)
  mon.clear()
end

local function put(x, y, text, fg, bg)
  if x < 1 or y < 1 or x > W or y > H then return end
  text = tostring(text or "")
  mon.setCursorPos(x, y)
  mon.setTextColor(fg or C.value)
  mon.setBackgroundColor(bg or C.bg)
  mon.write(text:sub(1, W - x + 1))
end

local function putr(x, y, w, text, fg, bg)
  text = tostring(text or "")
  local pad = w - #text
  if pad > 0 then put(x, y, (" "):rep(pad) .. text, fg, bg)
  else            put(x, y, text:sub(-w),             fg, bg) end
end

local function panelHeader(panel, title)
  local x0 = (panel - 1) * PW + 1
  if panel > 1 then
    for r = 1, H do put(x0 - 1, r, "|", C.border) end
  end
  local pad = math.max(0, math.floor((PW - #title) / 2))
  put(x0 + pad, 1, title, C.title)
  put(x0, 2, ("-"):rep(PW - (panel > 1 and 1 or 0)), C.border)
end

local function row(panel, y, label, value, vcol)
  local x0    = (panel - 1) * PW + (panel > 1 and 1 or 0)
  local avail = PW - (panel > 1 and 1 or 0)
  put(x0, y, label, C.label)
  putr(x0, y, avail, value, vcol or C.value)
end

local function hline(panel, y)
  local x0    = (panel - 1) * PW + (panel > 1 and 1 or 0)
  local avail = PW - (panel > 1 and 1 or 0)
  put(x0, y, ("-"):rep(avail), C.border)
end

local function speedBar(panel, y, speed, maxspd)
  local x0    = (panel - 1) * PW + (panel > 1 and 1 or 0)
  local avail = PW - (panel > 1 and 1 or 0)
  local frac  = math.min(1, speed / math.max(1, maxspd))
  local filled = math.floor(frac * avail)
  local col   = frac < 0.5 and C.good or frac < 0.85 and C.warn or C.bad
  if filled > 0 then put(x0, y, ("|"):rep(filled), col) end
  if filled < avail then
    put(x0 + filled, y, ("-"):rep(avail - filled), C.border)
  end
end

-- ---------------------------------------------------------------------------
-- Compass rose
--
-- Two overlaid indicators:
--   Yellow = current heading (corrected by HEADING_OFFSET)
--   Cyan   = bearing to destination
--   Orange = both coincide (on course)
--   Gray   = unrelated points
--
-- Layout (13 wide x 7 tall, centred in panel):
--
--       N
--   NW     NE
--  W   [H]   E
--   SW     SE
--       S
--
--  HDG: 045 NE     (readout below rose)
--  BRG: 270 W

local HDG_CHAR = {
  [0]="^", [1]="/",  [2]=">", [3]="\\",
  [4]="v", [5]="/",  [6]="<", [7]="\\",
}
local BRG_CHAR = {
  [0]="^", [1]="^", [2]=">", [3]="v",
  [4]="v", [5]="v", [6]="<", [7]="^",
}

-- label, col-offset, row-offset, octant (0=N clockwise)
local ROSE_POINTS = {
  { "N",   5,  0, 0 },
  { "NE",  9,  1, 1 },
  { "E",  11,  3, 2 },
  { "SE",  9,  5, 3 },
  { "S",   5,  6, 4 },
  { "SW",  1,  5, 5 },
  { "W",   0,  3, 6 },
  { "NW",  1,  1, 7 },
}
local ROSE_W = 13
local ROSE_H = 7

local function degToOctant(deg)
  return math.floor(((deg + 22.5) % 360) / 45)
end

local function drawCompass(panel, y0)
  local p_off = (panel - 1) * PW + (panel > 1 and 1 or 0)
  local avail = PW - (panel > 1 and 1 or 0)
  local x0    = p_off + math.floor((avail - ROSE_W) / 2)

  local hdg_oct
  if data.speed > 0.5 then
    hdg_oct = degToOctant(data.heading)
  end
  local brg_oct = degToOctant(data.bearing)

  -- Ring labels
  for _, pt in ipairs(ROSE_POINTS) do
    local label, dc, dr, oct = pt[1], pt[2], pt[3], pt[4]
    local col
    if hdg_oct and oct == hdg_oct and oct == brg_oct then
      col = colors.orange
    elseif hdg_oct and oct == hdg_oct then
      col = colors.yellow
    elseif oct == brg_oct then
      col = colors.cyan
    else
      col = C.border
    end
    put(x0 + dc, y0 + dr, label, col)
  end

  -- Centre cell
  local cx = x0 + math.floor(ROSE_W / 2)
  local cy = y0 + math.floor(ROSE_H / 2)
  if hdg_oct then
    put(cx, cy, HDG_CHAR[hdg_oct], colors.yellow)
  else
    put(cx, cy, "+",               C.border)
  end

  -- Bearing ring tick (only if different octant from heading)
  if not hdg_oct or brg_oct ~= hdg_oct then
    local bp = ROSE_POINTS[brg_oct + 1]
    if bp then
      put(x0 + bp[2], y0 + bp[3], BRG_CHAR[brg_oct], colors.cyan)
    end
  end

  -- Readouts below rose
  local dirs  = { "N","NE","E","SE","S","SW","W","NW" }
  local rx    = p_off
  local ry    = y0 + ROSE_H + 1

  local hdg_str = data.speed > 0.5
    and ("%03d %s"):format(math.floor(data.heading),
                           dirs[degToOctant(data.heading) + 1])
    or  "--- --"
  local brg_str = ("%03d %s"):format(math.floor(data.bearing),
                                     dirs[brg_oct + 1])

  put(rx, ry,     "HDG ", C.label)
  put(rx + 4, ry, hdg_str,
      data.speed > 0.5 and colors.yellow or C.border)

  put(rx, ry + 1,     "BRG ", C.label)
  put(rx + 4, ry + 1, brg_str, colors.cyan)
end

-- ---------------------------------------------------------------------------
-- State update

local function correctedHeading(vx, vz)
  return (math.deg(math.atan2(vx, -vz)) + HEADING_OFFSET + 360) % 360
end

local function updateFromSublevel()
  if not sublevel or not sublevel.isInPlotGrid() then return end
  local pose   = sublevel.getLogicalPose()
  local vel    = sublevel.getLinearVelocity()
  data.name    = sublevel.getName()
  data.pos     = { x = pose.position.x, z = pose.position.z }
  data.vel     = { x = vel.x, z = vel.z }
  data.speed   = math.sqrt(vel.x^2 + vel.z^2)
  data.heading = correctedHeading(vel.x, vel.z)
  data.updated = os.epoch("utc") / 1000
end

local function updateFromPacket(msg)
  if type(msg) ~= "table" or msg.type ~= "autopilot" then return end
  data.name    = msg.name    or data.name
  data.phase   = msg.phase   or data.phase
  data.pos     = msg.pos     or data.pos
  data.dest    = msg.dest    or data.dest
  data.dist    = msg.dist    or data.dist
  data.err_deg = msg.err_deg or data.err_deg

  local ae = math.abs(data.err_deg)
  data.zone = ae <= 10 and "fine" or ae <= 45 and "medium" or "coarse"

  if msg.velocity then
    data.vel     = msg.velocity
    data.speed   = math.sqrt(msg.velocity.x^2 + msg.velocity.z^2)
    data.heading = correctedHeading(msg.velocity.x, msg.velocity.z)
  end

  local dx = data.dest.x - data.pos.x
  local dz = data.dest.z - data.pos.z
  data.bearing = (math.deg(math.atan2(dx, -dz)) + 360) % 360
  data.eta     = data.speed > 0.5
    and math.floor(data.dist / data.speed) or nil
  data.updated = os.epoch("utc") / 1000
end

-- ---------------------------------------------------------------------------
-- Format helpers

local function fmtCoord(x, z)
  return ("x%d z%d"):format(math.floor(x), math.floor(z))
end

local function fmtDist(d)
  if d >= 1000 then return ("%.1fkm"):format(d / 1000) end
  return ("%.0fm"):format(d)
end

local function fmtETA(eta)
  if not eta     then return "---" end
  if eta >= 3600 then return ">1h" end
  if eta >= 60   then return ("%dm%02ds"):format(math.floor(eta/60), eta%60) end
  return ("%ds"):format(eta)
end

local function fmtBearing(deg)
  local dirs = { "N","NE","E","SE","S","SW","W","NW" }
  local idx  = math.floor((deg + 22.5) / 45) % 8 + 1
  return ("%03d deg %s"):format(math.floor(deg), dirs[idx])
end

local function fmtHeading()
  if data.speed < 0.5 then return "STATIONARY" end
  local dirs = { "N","NE","E","SE","S","SW","W","NW" }
  local idx  = math.floor((data.heading + 22.5) / 45) % 8 + 1
  return ("%03d deg %s"):format(math.floor(data.heading), dirs[idx])
end

local function phaseColor(phase)
  if phase == "arrived"    then return C.good  end
  if phase == "navigating" then return C.value end
  return C.warn
end

local function stalenessColor()
  local age = os.epoch("utc") / 1000 - data.updated
  if age > 10 then return C.bad  end
  if age > 4  then return C.warn end
  return C.good
end

-- ---------------------------------------------------------------------------
-- Render

local function redraw()
  cls()

  -- ── Panel 1: Position & Destination ──────────────────────────────────────
  panelHeader(1, "POSITION")

  row(1,  3, "Ship     ", data.name, C.cyan)
  hline(1, 4)
  row(1,  5, "Position ", fmtCoord(data.pos.x,  data.pos.z))
  row(1,  6, "Dest     ", fmtCoord(data.dest.x, data.dest.z))
  hline(1, 7)
  row(1,  8, "Distance ", fmtDist(data.dist))
  row(1,  9, "Bearing  ", fmtBearing(data.bearing))
  row(1, 10, "ETA      ", fmtETA(data.eta))
  hline(1, 11)
  row(1, 12, "Heading  ", fmtHeading())
  row(1, 13, "Speed    ", ("%.1f m/s"):format(data.speed))
  hline(1, 14)

  -- Error + zone
  local aeCol = math.abs(data.err_deg) <= 10 and C.good
             or math.abs(data.err_deg) <= 45 and C.warn
             or C.bad
  row(1, 15, "Hdg Err  ",
      (data.err_deg >= 0 and "+" or "") .. ("%.1f deg"):format(data.err_deg),
      aeCol)

  local zoneCol = data.zone == "fine"   and C.good
               or data.zone == "medium" and C.warn
               or data.zone == "wait"   and C.border
               or C.bad
  row(1, 16, "Steer    ", data.zone:upper(), zoneCol)

  hline(1, H - 1)
  row(1, H, "DATA     ", data.updated > 0 and "LIVE" or "WAIT", stalenessColor())

  -- ── Panel 2: Autopilot Status ─────────────────────────────────────────────
  panelHeader(2, "AUTOPILOT")

  local phaseTxt = data.phase:upper()
  row(2, 3, "Mode     ", phaseTxt, phaseColor(data.phase))
  hline(2, 4)

  row(2, 5, "Speed    ", ("%.2f m/s"):format(data.speed))
  speedBar(2, 6, data.speed, MAX_SPEED)
  hline(2, 7)

  -- Velocity components
  row(2,  8, "Vx       ", ("% .3f"):format(data.vel.x))
  row(2,  9, "Vz       ", ("% .3f"):format(data.vel.z))
  hline(2, 10)

  -- Coords again for quick glance
  row(2, 11, "X        ", ("%d"):format(math.floor(data.pos.x)))
  row(2, 12, "Z        ", ("%d"):format(math.floor(data.pos.z)))

  -- ── Panel 3: Compass ─────────────────────────────────────────────────────
  panelHeader(3, "COMPASS")
  drawCompass(3, 3)
end

-- ---------------------------------------------------------------------------
-- Event loops

local REDRAW_PERIOD  = 0.25
local STATUS_CHANNEL = "autopilot"

local function netLoop()
  while true do
    local _, msg = rednet.receive(STATUS_CHANNEL, 5)
    if msg then updateFromPacket(msg) end
  end
end

local function renderLoop()
  while true do
    pcall(updateFromSublevel)
    redraw()
    sleep(REDRAW_PERIOD)
  end
end

print("[hud] " .. monSide .. "  " .. W .. "x" .. H .. "  PW=" .. PW)
parallel.waitForAny(netLoop, renderLoop)
