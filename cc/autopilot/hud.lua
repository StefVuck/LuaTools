-- hud.lua
-- Airship HUD for a 1x3 horizontal monitor bank.
-- Listens on the "autopilot" rednet channel for status packets broadcast
-- by autopilot.lua, and also reads sublevel directly if co-located.
--
-- Layout (three equal panels side by side):
--   [ POSITION & DEST ] [ NAVIGATION STATUS ] [ COMPASS & VELOCITY ]
--
-- Setup:
--   1. Place 3 monitors horizontally and attach to this computer.
--   2. Attach a wireless modem.
--   3. Run:  autopilot/hud

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
-- Each of the 3 panels occupies one third of the total width
local PW = math.floor(W / 3)   -- panel width in chars

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
-- Drawing primitives

local function cls()
  mon.setBackgroundColor(C.bg)
  mon.clear()
end

local function put(x, y, text, fg, bg)
  if x < 1 or y < 1 or x > W or y > H then return end
  mon.setCursorPos(x, y)
  mon.setTextColor(fg or C.value)
  mon.setBackgroundColor(bg or C.bg)
  -- Clip to monitor width
  mon.write(text:sub(1, W - x + 1))
end

-- Right-align text within a column of width `w` starting at `x`
local function putr(x, y, w, text, fg, bg)
  local pad = w - #text
  if pad > 0 then put(x, y, (" "):rep(pad) .. text, fg, bg)
  else            put(x, y, text:sub(-w),             fg, bg) end
end

-- Draw a titled box border for a panel (1-indexed panel: 1, 2, 3)
local function panelHeader(panel, title)
  local x0 = (panel - 1) * PW + 1
  -- Vertical divider (skip for leftmost edge)
  if panel > 1 then
    for row = 1, H do
      put(x0 - 1, row, "\x7C", C.border)
    end
  end
  -- Title centred in panel
  local pad = math.max(0, math.floor((PW - #title) / 2))
  put(x0 + pad, 1, title, C.title)
  -- Underline
  put(x0, 2, ("\x8C"):rep(PW - (panel > 1 and 1 or 0)), C.border)
end

-- Label + value pair on one row within a panel
local function row(panel, y, label, value, vcol)
  local x0 = (panel - 1) * PW + (panel > 1 and 1 or 0)
  local avail = PW - (panel > 1 and 1 or 0)
  put(x0, y, label, C.label)
  putr(x0, y, avail, value, vcol or C.value)
end

-- ---------------------------------------------------------------------------
-- Compass rose
--
-- Drawn in panel 3.  Two overlaid indicators:
--   Heading  (where the ship is moving)  — yellow arrow, bright label
--   Bearing  (direction to destination)  — cyan arrow, bright label
--
-- The rose is a fixed 9-wide × 7-tall text block centred in the panel.
-- Each of the 8 compass points is coloured based on proximity to heading
-- or bearing; unrelated points are drawn dim.
--
--        N            row y0
--      NW * NE        row y0+1   (* = NW/NE chars share the row)
--    W  [HDG]  E      row y0+2
--      SW * SE        row y0+3
--        S            row y0+4

-- Arrow characters for each octant (heading indicator, centre cell)
local HDG_CHAR = {
  [0]="\30", [1]="/",   [2]="\16", [3]="\\",
  [4]="\31", [5]="/",   [6]="\17", [7]="\\",
}
-- Destination bearing pointer shown as a small marker on the ring
local BRG_CHAR = {
  [0]="\30", [1]="\30", [2]="\16", [3]="\31",
  [4]="\31", [5]="\31", [6]="\17", [7]="\30",
}

-- Return octant index 0-7 (0=N, 1=NE, 2=E … 7=NW) for a bearing in degrees
local function octant(deg)
  return math.floor(((deg + 22.5) % 360) / 45)
end

-- The 8 compass point labels and their (col, row) offsets from the rose origin.
-- Rose origin is the top-left of the 9×5 grid.
-- Col offsets are character positions; each label is 2 chars wide.
local ROSE_POINTS = {
  -- { label, col_offset, row_offset, octant_index }
  { "N ", 3, 0, 0 },
  { "NE", 6, 1, 1 },
  { "E ", 7, 2, 2 },
  { "SE", 6, 3, 3 },
  { "S ", 3, 4, 4 },
  { "SW", 0, 3, 5 },
  { "W ", 0, 2, 6 },
  { "NW", 0, 1, 7 },
}

local function drawCompass(panel, y0)
  local p_off  = (panel - 1) * PW + (panel > 1 and 1 or 0)
  local avail  = PW - (panel > 1 and 1 or 0)
  -- Centre the 9-wide rose horizontally
  local x0     = p_off + math.floor((avail - 9) / 2)

  local hdg_oct = (data.speed > 0.5)
    and octant((math.deg(math.atan2(data.vel.x, -data.vel.z)) + 360) % 360)
    or  nil
  local brg_oct = octant(data.bearing)

  -- Draw compass point labels, coloured by role
  for _, pt in ipairs(ROSE_POINTS) do
    local label, dc, dr, oct = pt[1], pt[2], pt[3], pt[4]
    local col
    if oct == hdg_oct and oct == brg_oct then
      col = colors.orange          -- heading AND bearing coincide here
    elseif oct == hdg_oct then
      col = colors.yellow          -- current heading direction
    elseif oct == brg_oct then
      col = colors.cyan            -- destination bearing direction
    else
      col = C.border               -- unrelated point, dim
    end
    put(x0 + dc, y0 + dr, label, col)
  end

  -- Centre cell: heading arrow (yellow) or stationary marker
  local centre_char, centre_col
  if hdg_oct then
    centre_char = HDG_CHAR[hdg_oct]
    centre_col  = colors.yellow
  else
    centre_char = "+"
    centre_col  = C.border
  end
  put(x0 + 3, y0 + 2, centre_char .. " ", centre_col)

  -- Bearing tick on the ring (cyan, only if different from heading octant)
  if not hdg_oct or brg_oct ~= hdg_oct then
    local bp = ROSE_POINTS[brg_oct + 1]
    if bp then
      put(x0 + bp[2], y0 + bp[3],
          BRG_CHAR[brg_oct] .. " ", colors.cyan)
    end
  end
end

-- ---------------------------------------------------------------------------
-- Speed bar (horizontal, panel width)

local function speedBar(panel, y, speed, maxspd)
  local x0   = (panel - 1) * PW + (panel > 1 and 1 or 0)
  local avail = PW - (panel > 1 and 1 or 0)
  local frac  = math.min(1, speed / math.max(1, maxspd))
  local filled = math.floor(frac * avail)
  local col = frac < 0.5 and C.good or frac < 0.85 and C.warn or C.bad
  put(x0, y, ("\x7F"):rep(filled), col)
  if filled < avail then
    put(x0 + filled, y, ("-"):rep(avail - filled), C.border)
  end
end

-- ---------------------------------------------------------------------------
-- State (updated from rednet or sublevel)

local data = {
  name    = "—",
  phase   = "waiting",
  pos     = { x = 0, z = 0 },
  dest    = { x = 0, z = 0 },
  dist    = 0,
  vel     = { x = 0, z = 0 },
  speed   = 0,
  bearing = 0,    -- degrees clockwise from North
  err_deg = 0,    -- signed heading error: +ve = turn right, -ve = turn left
  zone    = "—",  -- fine / medium / coarse
  eta     = nil,
  updated = 0,
}

local MAX_SPEED = 10   -- reference for bar (matches autopilot CFG.max_speed)

local function updateFromSublevel()
  if not sublevel or not sublevel.isInPlotGrid() then return end
  local pose = sublevel.getLogicalPose()
  local vel  = sublevel.getLinearVelocity()
  data.name  = sublevel.getName()
  data.pos   = { x = pose.position.x, z = pose.position.z }
  data.vel   = { x = vel.x, z = vel.z }
  data.speed = math.sqrt(vel.x^2 + vel.z^2)
  data.updated = os.epoch("utc") / 1000
end

local function updateFromPacket(msg)
  if msg.type ~= "autopilot" then return end
  data.name    = msg.name   or data.name
  data.phase   = msg.phase  or data.phase
  data.pos     = msg.pos    or data.pos
  data.dest    = msg.dest   or data.dest
  data.dist    = msg.dist    or data.dist
  data.err_deg = msg.err_deg or data.err_deg
  -- Derive steering zone from error magnitude
  local ae = math.abs(data.err_deg)
  data.zone = ae <= 10 and "fine" or ae <= 45 and "medium" or "coarse"
  if msg.velocity then
    data.vel   = msg.velocity
    data.speed = math.sqrt(msg.velocity.x^2 + msg.velocity.z^2)
  end
  data.updated = os.epoch("utc") / 1000

  -- Bearing (degrees clockwise from North: 0=N, 90=E, 180=S, 270=W)
  local dx = data.dest.x - data.pos.x
  local dz = data.dest.z - data.pos.z
  data.bearing = (math.deg(math.atan2(dx, -dz)) + 360) % 360

  -- ETA
  if data.speed > 0.5 then
    data.eta = math.floor(data.dist / data.speed)
  else
    data.eta = nil
  end
end

-- ---------------------------------------------------------------------------
-- Render

local function phaseColour(phase)
  if phase == "arrived"    then return C.good end
  if phase == "navigating" then return C.value end
  return C.warn
end

local function fmtCoord(x, z)
  return ("x%d z%d"):format(math.floor(x), math.floor(z))
end

local function fmtDist(d)
  if d >= 1000 then return ("%.1fkm"):format(d / 1000) end
  return ("%.0fm"):format(d)
end

local function fmtETA(eta)
  if not eta then return "—" end
  if eta >= 3600 then return (">1h") end
  if eta >= 60   then return ("%dm%02ds"):format(math.floor(eta/60), eta%60) end
  return ("%ds"):format(eta)
end

local function fmtBearing(deg)
  local dirs = { "N","NE","E","SE","S","SW","W","NW" }
  local idx = math.floor((deg + 22.5) / 45) % 8 + 1
  return ("%03d\xb0 %s"):format(math.floor(deg), dirs[idx])
end

local function fmtHeading(vx, vz)
  local spd = math.sqrt(vx^2 + vz^2)
  if spd < 0.5 then return "STATIONARY" end
  local deg = (math.deg(math.atan2(vx, -vz)) + 360) % 360
  local dirs = { "N","NE","E","SE","S","SW","W","NW" }
  local idx = math.floor((deg + 22.5) / 45) % 8 + 1
  return ("%03d\xb0 %s"):format(math.floor(deg), dirs[idx])
end

local function staleness()
  local age = os.epoch("utc") / 1000 - data.updated
  if age > 10 then return C.bad  end
  if age > 4  then return C.warn end
  return C.good
end

local function redraw()
  cls()

  -- ── Panel 1: Position & Destination ─────────────────────────────────────
  panelHeader(1, "POSITION")

  row(1, 3,  "Ship ", data.name, C.cyan)
  row(1, 5,  "Pos  ", fmtCoord(data.pos.x, data.pos.z))
  row(1, 6,  "Dest ", fmtCoord(data.dest.x, data.dest.z))
  row(1, 8,  "Dist ", fmtDist(data.dist))
  row(1, 9,  "Bear ", fmtBearing(data.bearing))
  row(1, 11, "ETA  ", fmtETA(data.eta))

  -- Data-fresh indicator
  row(1, H, "DATA ", data.updated > 0 and "LIVE" or "WAIT", staleness())

  -- ── Panel 2: Navigation Status ───────────────────────────────────────────
  panelHeader(2, "AUTOPILOT")

  local phaseTxt = data.phase:upper()
  row(2, 3, "Mode ", phaseTxt, phaseColour(data.phase))

  row(2, 5, "Speed", ("%.1f m/s"):format(data.speed))
  speedBar(2, 6, data.speed, MAX_SPEED)

  row(2, 8, "Head ", fmtHeading(data.vel.x, data.vel.z))

  -- Signed heading error + steering zone
  local aeCol = math.abs(data.err_deg) <= 10  and C.good
             or math.abs(data.err_deg) <= 45  and C.warn
             or C.bad
  local errSign = data.err_deg >= 0 and "+" or ""
  row(2, 10, "Err  ", ("%s%.1f\xb0"):format(errSign, data.err_deg), aeCol)

  local zoneCol = data.zone == "fine"   and C.good
               or data.zone == "medium" and C.warn
               or C.bad
  row(2, 11, "Zone ", data.zone:upper(), zoneCol)

  -- ── Panel 3: Compass rose + velocity readouts ────────────────────────────
  panelHeader(3, "COMPASS")

  -- Rose centred vertically: 5 rows tall, starting at row 3
  drawCompass(3, 3)

  -- Legend below the rose
  local p3x = 2 * PW + 2
  put(p3x, 9, "\x7F", colors.yellow)
  put(p3x + 1, 9, " HDG", C.label)
  put(p3x, 10, "\x7F", colors.cyan)
  put(p3x + 1, 10, " BRG", C.label)

  -- Velocity readouts at the bottom
  row(3, H - 2, "Vx ", ("% .2f"):format(data.vel.x))
  row(3, H - 1, "Vz ", ("% .2f"):format(data.vel.z))
  row(3, H,     "Spd", ("%.1f m/s"):format(data.speed))
end

-- ---------------------------------------------------------------------------
-- Event loops

local REDRAW_PERIOD = 0.25
local STATUS_CHANNEL = "autopilot"

local function netLoop()
  while true do
    local _, msg, proto = rednet.receive(STATUS_CHANNEL, 5)
    if msg then
      updateFromPacket(msg)
    end
  end
end

local function renderLoop()
  while true do
    -- If sublevel is local, supplement with live data
    pcall(updateFromSublevel)
    redraw()
    sleep(REDRAW_PERIOD)
  end
end

print("[hud] Starting on " .. monSide .. " (" .. W .. "x" .. H .. ")")
parallel.waitForAny(netLoop, renderLoop)
