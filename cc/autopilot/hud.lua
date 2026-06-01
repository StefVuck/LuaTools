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

local HEADING_OFFSET = 0   -- degrees; adjust until North reads ~0 when facing North

-- ---------------------------------------------------------------------------
-- Home location
-- Shown as a pink [H] marker on the compass rose and as "Dist Home" in panel 1.
-- Set to nil to disable.

local HOME = {
  x = 990,
  z = 113,
  label = "Home",
}

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
  home   = colors.pink,
}

-- ---------------------------------------------------------------------------
-- State  (declared early so every function below can reference it)

local data = {
  -- Always live from sublevel
  name         = "?",
  pos          = { x = 0, z = 0 },
  vel          = { x = 0, z = 0 },
  speed        = 0,
  heading      = 0,
  last_heading = nil,    -- latched when speed drops; shown as stale heading
  sublevel_ok  = false,  -- true when sublevel is readable this tick
  sub_updated  = 0,      -- last time sublevel data was read

  -- Only from autopilot packets
  phase        = "off",
  dest         = { x = 0, z = 0 },
  bearing      = 0,
  dist         = 0,
  err_deg      = 0,
  zone         = "off",
  eta          = nil,
  ap_updated   = 0,      -- last time an autopilot packet was received

  -- Home (derived from HOME config + live position)
  home_bearing = 0,
  home_dist    = 0,
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

-- x0: panels are 1-indexed; panel 1 starts at col 1, panel 2 at PW+1, etc.
-- avail: panel 1 has full PW width; panels 2+ lose 1 col to the divider.
local function panelX(panel)
  return (panel - 1) * PW + 1
end
local function panelW(panel)
  return panel == 1 and PW or PW - 1
end

local function row(panel, y, label, value, vcol)
  local x0    = panelX(panel)
  local avail = panelW(panel)
  put(x0, y, label, C.label)
  putr(x0, y, avail, value, vcol or C.value)
end

local function hline(panel, y)
  put(panelX(panel), y, ("-"):rep(panelW(panel)), C.border)
end

local function speedBar(panel, y, speed, maxspd)
  local x0    = panelX(panel)
  local avail = panelW(panel)
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
  local x0  = panelX(panel) + math.floor((panelW(panel) - ROSE_W) / 2)
  local rx  = panelX(panel)
  local dirs = { "N","NE","E","SE","S","SW","W","NW" }

  local active_hdg = data.speed > 0.5 and data.heading or data.last_heading

  -- The rose rotates so that the bearing-to-destination sits at the top.
  -- When no autopilot, default to North-up (up_oct = 0).
  local up_oct = (data.ap_updated > 0)
    and degToOctant(data.bearing) or 0

  -- Absolute octants for heading and home
  local hdg_abs  = active_hdg and degToOctant(active_hdg) or nil
  local home_abs = HOME and degToOctant(data.home_bearing) or nil

  -- Draw the 8 ring labels.
  -- Display position p (0=top, clockwise) shows the direction whose absolute
  -- octant is (up_oct + p) % 8.
  for display_pos, pt in ipairs(ROSE_POINTS) do
    local dc, dr    = pt[2], pt[3]
    local abs_oct   = (up_oct + display_pos - 1) % 8
    local label     = dirs[abs_oct + 1]

    local col
    if abs_oct == 0 then
      col = colors.red                          -- N is always red
    elseif hdg_abs and abs_oct == hdg_abs then
      col = colors.yellow                       -- heading direction
    elseif home_abs and abs_oct == home_abs then
      col = C.home                              -- home direction
    else
      col = C.border
    end
    put(x0 + dc, y0 + dr, label, col)
  end

  -- Centre arrow: heading relative to the rotated rose.
  -- rel = 0 means ship is heading toward bearing (straight up on rose).
  local cx = x0 + math.floor(ROSE_W / 2)
  local cy = y0 + math.floor(ROSE_H / 2)
  if active_hdg then
    local rel_oct = degToOctant((active_hdg - data.bearing + 360) % 360)
    local arrow   = HDG_CHAR[rel_oct]
    put(cx, cy, arrow, data.speed > 0.5 and colors.yellow or C.border)
  else
    put(cx, cy, "+", C.border)
  end

  -- Home ring tick: overwrite that position's label with pink H
  if home_abs then
    local home_disp = (home_abs - up_oct + 8) % 8  -- display position 0-7
    local hp = ROSE_POINTS[home_disp + 1]
    if hp then put(x0 + hp[2], y0 + hp[3], "H", C.home) end
  end

  -- Readouts below rose
  local ry = y0 + ROSE_H + 1

  local hdg_str = active_hdg
    and ("%03d %s%s"):format(math.floor(active_hdg),
                             dirs[degToOctant(active_hdg) + 1],
                             data.speed < 0.5 and "*" or "")
    or "--- --"
  put(rx,     ry,     "HDG ", C.label)
  put(rx + 4, ry,     hdg_str, data.speed > 0.5 and colors.yellow or C.border)

  local brg_str = data.ap_updated > 0
    and ("%03d %s"):format(math.floor(data.bearing), dirs[up_oct + 1])
    or  "--- --"
  put(rx,     ry + 1, "BRG ", C.label)
  put(rx + 4, ry + 1, brg_str, data.ap_updated > 0 and colors.cyan or C.border)

  if HOME then
    local home_str = ("%03d %s"):format(math.floor(data.home_bearing),
                                        dirs[(home_abs or 0) + 1])
    put(rx,     ry + 2, "HOM ", C.label)
    put(rx + 4, ry + 2, home_str, C.home)
  end
end

-- ---------------------------------------------------------------------------
-- State update

local function correctedHeading(vx, vz)
  return (math.deg(math.atan2(vx, -vz)) + HEADING_OFFSET + 360) % 360
end

-- Heading latch: update heading and remember last good value
local function updateHeading()
  local hdg = correctedHeading(data.vel.x, data.vel.z)
  data.heading = hdg
  if data.speed > 0.5 then
    data.last_heading = hdg
  end
end

-- Recalculate bearing/dist/ETA from current pos+dest+speed
local function recalcNav()
  local dx = data.dest.x - data.pos.x
  local dz = data.dest.z - data.pos.z
  data.dist    = math.sqrt(dx*dx + dz*dz)
  data.bearing = (math.deg(math.atan2(dx, -dz)) + 360) % 360
  data.eta     = (data.speed > 0.5 and data.ap_updated > 0)
    and math.floor(data.dist / data.speed) or nil

  -- Home
  if HOME then
    local hx = HOME.x - data.pos.x
    local hz = HOME.z - data.pos.z
    data.home_dist    = math.sqrt(hx*hx + hz*hz)
    data.home_bearing = (math.deg(math.atan2(hx, -hz)) + 360) % 360
  end
end

local function updateFromSublevel()
  local now = os.epoch("utc") / 1000
  if not sublevel or not sublevel.isInPlotGrid() then
    data.sublevel_ok = false
    return
  end
  local pose       = sublevel.getLogicalPose()
  local vel        = sublevel.getLinearVelocity()
  data.sublevel_ok = true
  data.name        = sublevel.getName()
  data.pos         = { x = pose.position.x, z = pose.position.z }
  data.vel         = { x = vel.x, z = vel.z }
  data.speed       = math.sqrt(vel.x^2 + vel.z^2)
  data.sub_updated = now
  updateHeading()
  recalcNav()
end

local AUTOPILOT_TIMEOUT = 10  -- seconds before autopilot considered offline

local function updateFromPacket(msg)
  if type(msg) ~= "table" or msg.type ~= "autopilot" then return end
  local now     = os.epoch("utc") / 1000
  data.phase    = msg.phase   or data.phase
  data.dest     = msg.dest    or data.dest
  data.err_deg  = msg.err_deg or data.err_deg
  data.ap_updated = now

  local ae = math.abs(data.err_deg)
  data.zone = ae <= 10 and "fine" or ae <= 45 and "medium" or "coarse"

  -- Prefer sublevel for pos/vel; only use packet values as fallback
  if not data.sublevel_ok then
    if msg.pos      then data.pos   = msg.pos   end
    if msg.velocity then
      data.vel   = msg.velocity
      data.speed = math.sqrt(msg.velocity.x^2 + msg.velocity.z^2)
      updateHeading()
    end
    if msg.name then data.name = msg.name end
  end

  recalcNav()
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
  local dirs = { "N","NE","E","SE","S","SW","W","NW" }
  local hdg  = data.speed > 0.5 and data.heading or data.last_heading
  if not hdg then return "STATIONARY" end
  local idx  = math.floor((hdg + 22.5) / 45) % 8 + 1
  local suffix = data.speed < 0.5 and " (last)" or ""
  return ("%03d deg %s%s"):format(math.floor(hdg), dirs[idx], suffix)
end

local function phaseColor(phase)
  if phase == "arrived"    then return C.good   end
  if phase == "navigating" then return C.value  end
  if phase == "off"        then return C.border end
  return C.warn
end

local function apOnline()
  return (os.epoch("utc") / 1000 - data.ap_updated) < AUTOPILOT_TIMEOUT
end

-- ---------------------------------------------------------------------------
-- Render

local function redraw()
  cls()
  local ap = apOnline()
  local now = os.epoch("utc") / 1000

  -- ── Panel 1: Position ────────────────────────────────────────────────────
  panelHeader(1, "POSITION")

  local subCol = data.sublevel_ok and C.good or C.bad
  row(1,  3, "Ship     ", data.name, C.cyan)
  hline(1, 4)
  row(1,  5, "Position ", fmtCoord(data.pos.x, data.pos.z),
      data.sublevel_ok and C.value or C.border)
  row(1,  6, "Dest     ",
      ap and fmtCoord(data.dest.x, data.dest.z) or "no autopilot",
      ap and C.value or C.border)
  hline(1, 7)
  row(1,  8, "Distance ", ap and fmtDist(data.dist)       or "---", ap and C.value or C.border)
  row(1,  9, "Bearing  ", ap and fmtBearing(data.bearing) or "---", ap and C.value or C.border)
  row(1, 10, "ETA      ", ap and fmtETA(data.eta)         or "---", ap and C.value or C.border)
  hline(1, 11)
  row(1, 12, "Heading  ", fmtHeading())
  row(1, 13, "Speed    ", ("%.1f m/s"):format(data.speed))
  if HOME then
    row(1, 14, "Dist " .. HOME.label:sub(1,4), fmtDist(data.home_dist), C.home)
  end
  hline(1, 15)

  local aeCol = math.abs(data.err_deg) <= 10 and C.good
             or math.abs(data.err_deg) <= 45 and C.warn or C.bad
  row(1, 16, "Hdg Err  ",
      ap and (data.err_deg >= 0 and "+" or "") .. ("%.1f deg"):format(data.err_deg) or "---",
      ap and aeCol or C.border)

  local zoneCol = data.zone == "fine"   and C.good
               or data.zone == "medium" and C.warn
               or data.zone == "off"    and C.border
               or C.bad
  row(1, 17, "Steer    ", data.zone:upper(), zoneCol)

  hline(1, H - 1)
  local subAge = now - data.sub_updated
  local subStr = data.sublevel_ok and "LIVE" or "NO SUBLEVEL"
  local subAgeCol = subAge < 2 and C.good or subAge < 5 and C.warn or C.bad
  row(1, H, "SHIP     ", subStr, subAgeCol)

  -- ── Panel 2: Autopilot ────────────────────────────────────────────────────
  panelHeader(2, ap and "AUTOPILOT" or "AUTOPILOT (off)")

  row(2, 3, "Mode     ", ap and data.phase:upper() or "OFFLINE",
      ap and phaseColor(data.phase) or C.border)
  hline(2, 4)

  row(2, 5, "Speed    ", ("%.2f m/s"):format(data.speed))
  speedBar(2, 6, data.speed, MAX_SPEED)
  hline(2, 7)

  row(2,  8, "Vx       ", ("% .3f"):format(data.vel.x))
  row(2,  9, "Vz       ", ("% .3f"):format(data.vel.z))
  hline(2, 10)

  row(2, 11, "X        ", ("%d"):format(math.floor(data.pos.x)))
  row(2, 12, "Z        ", ("%d"):format(math.floor(data.pos.z)))

  hline(2, H - 1)
  local apAge = now - data.ap_updated
  local apStr = ap and ("%.0fs ago"):format(apAge) or "OFFLINE"
  local apCol = ap and C.good or C.border
  row(2, H, "AP PKT   ", apStr, apCol)

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

local dbg_tick = 0
local function renderLoop()
  while true do
    local ok, err = pcall(updateFromSublevel)
    if not ok then
      print("[hud] sublevel error: " .. tostring(err))
    end

    -- Print a diagnostic line to the terminal every 5 seconds
    dbg_tick = dbg_tick + 1
    if dbg_tick % math.ceil(5 / REDRAW_PERIOD) == 0 then
      print(("[hud] sublevel=%s ok=%s name=%s pos=%.0f,%.0f spd=%.2f"):format(
        tostring(sublevel ~= nil),
        tostring(data.sublevel_ok),
        tostring(data.name),
        data.pos.x, data.pos.z,
        data.speed))
    end

    redraw()
    sleep(REDRAW_PERIOD)
  end
end

print("[hud] " .. monSide .. "  " .. W .. "x" .. H .. "  PW=" .. PW)
parallel.waitForAny(netLoop, renderLoop)
