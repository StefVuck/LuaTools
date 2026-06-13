-- autopilot.lua
-- Navigates an airship to a destination using:
--   - sublevel API for live position + velocity (heading derived from velocity)
--   - CC: Redstone Link Bridge for motor control
--
-- Steering model (differential drive):
--   FINE   zone (error < 10°) : speed differential only, no gearshifts
--   MEDIUM zone (error < 45°) : speed differential + gearshift on slower side
--   COARSE zone (error >= 45°): one motor fully reversed, other full forward
--   Primary engine stays on throughout; only clutched off on arrival.
--
-- Setup:
--   1. Place this computer on the airship Sub-Level.
--   2. Attach a CC: Redstone Link Bridge peripheral.
--   3. Tune heading_offset in CFG (see comment there).
--   4. Run:  autopilot/autopilot <x> <z>  OR  autopilot/autopilot <waypointName>

-- ---------------------------------------------------------------------------
-- Frequency pair config
-- Each entry is { freq1, freq2 } matching the two item IDs set on the
-- in-world Redstone Link.  Replace the placeholders with your actual IDs.

local LINKS = {
  -- Clutches: send strength > 0 to DISENGAGE (stop the motor)
  primary_clutch = { "minecraft:diamond",    "create:clutch"              },
  left_clutch    = { "minecraft:iron_ingot", "create:clutch"              },
  right_clutch   = { "minecraft:gold_ingot", "create:clutch"              },

  -- Gearshifts: send strength > 0 to REVERSE direction
  left_gear      = { "minecraft:iron_ingot", "create:brass_casing"        },
  right_gear     = { "minecraft:gold_ingot", "create:brass_casing"        },

  -- Speed controllers: INVERTED — 0 = full speed (128 RPM), 15 = fully off
  primary_speed  = { "minecraft:diamond",    "create:industrial_iron_block" },
  left_speed     = { "minecraft:iron_ingot", "create:industrial_iron_block" },
  right_speed    = { "minecraft:gold_ingot", "create:industrial_iron_block" },
}

-- Set to false for any channel that is not physically wired up yet.
local WIRED = {
  primary_clutch = true,
  left_clutch    = true,
  right_clutch   = true,
  left_gear      = true,
  right_gear     = true,
  primary_speed  = true,
  left_speed     = true,
  right_speed    = true,
}

-- ---------------------------------------------------------------------------
-- Navigation config

local CFG = {
  -- Default destination; overridden by CLI args or waypoint name
  dest_x = 0,
  dest_z = 0,

  -- Distance thresholds
  arrival_radius        = 30,   -- blocks: cut engines and brake
  inner_approach_radius = 250,  -- blocks: slow to approach_speed ramp
  outer_approach_radius = 500,  -- blocks: start gentle deceleration

  -- Speed (blocks/s) — used to scale the analog speed signal 0-15
  max_speed      = 18,
  mid_speed      = 10,  -- cruise speed between outer and inner approach
  approach_speed = 3,   -- crawl speed inside inner approach

  -- Braking: reverse drive motors to kill momentum on arrival
  brake_speed_threshold = 1.5,  -- m/s below which we stop braking and allStop

  -- Steering zones (absolute heading error in degrees)
  ultra_fine_threshold = 2,   -- below this: deadband, no correction (stops oscillation)
  fine_threshold       = 10,  -- below this: differential speed only
  coarse_threshold     = 45,  -- above this: one motor reversed, primary cut

  -- Proportional gain for differential speed correction (0-1)
  turn_p = 0.9,

  -- Heading offset: compensates for ships built facing a non-North direction.
  -- If the ship was built facing West (270 deg), set heading_offset = 90 so
  -- that moving West reads as 270 deg rather than 0.
  -- Tune by facing North, noting the raw heading, then set offset = -(that value).
  heading_offset = 0,

  -- Broadcast status on this rednet channel
  status_channel   = "autopilot",
  broadcast_status = true,

  tick = 0.2,
}

-- ---------------------------------------------------------------------------
-- CLI args  (autopilot <x> <z>  OR  autopilot <waypointName>)

local args = { ... }
if #args >= 2 and tonumber(args[1]) and tonumber(args[2]) then
  CFG.dest_x = tonumber(args[1])
  CFG.dest_z = tonumber(args[2])
elseif #args == 1 then
  local ok, wp = pcall(require, "autopilot/waypoints")
  local dest = ok and wp.get(args[1])
  if dest then
    CFG.dest_x = dest.x
    CFG.dest_z = dest.z
    print(("[autopilot] Waypoint '%s' -> x=%.0f z=%.0f"):format(args[1], dest.x, dest.z))
  else
    error("Unknown waypoint '" .. args[1] .. "'.  Check autopilot/waypoints.lua")
  end
end

-- ---------------------------------------------------------------------------
-- Peripherals

local bridge = peripheral.find("redstone_link_bridge")
  or error("No redstone_link_bridge found")

local modem = peripheral.find("modem")
if modem and CFG.broadcast_status then
  rednet.open(peripheral.getName(modem))
end

while not sublevel.isInPlotGrid() do
  print("[autopilot] Waiting for Sub-Level...")
  sleep(2)
end

local shipName = sublevel.getName()
print(("[autopilot] %s  ->  dest %.0f, %.0f"):format(
  shipName, CFG.dest_x, CFG.dest_z))

-- ---------------------------------------------------------------------------
-- Redstone link helpers

-- Raw send: strength 0-15 directly to the link.
local function send(channel, strength)
  if not WIRED[channel] then return end
  local f = LINKS[channel]
  bridge.sendLinkSignal(f[1], f[2], math.floor(math.max(0, math.min(15, strength))))
end

-- Boolean channels: high signal = active (clutch disengaged / gear reversed).
local function setBool(channel, active)
  send(channel, active and 15 or 0)
end

-- Speed channels: INVERTED — the analog transmission divides the base 128 RPM,
-- so strength 0 = full speed and strength 15 = fully stopped.
-- Pass fraction 0.0 (stop) → 1.0 (full speed); this function inverts it.
local function setSpeed(channel, fraction)
  fraction = math.max(0, math.min(1, fraction))
  send(channel, math.floor((1 - fraction) * 15))
end

-- ---------------------------------------------------------------------------
-- Motor abstraction
--
-- speed  : 0-15 analog (only used if WIRED.xxx_speed is true)
-- reverse: true/false  -> gearshift
-- disable: true/false  -> clutch

-- speed is a fraction 0.0-1.0; reverse and disable are booleans.
local function setMotor(side, speed, reverse, disable)
  setBool(side .. "_clutch", disable)
  if disable then
    setBool(side .. "_gear",   false)
    setSpeed(side .. "_speed", 0)
    return
  end
  setBool(side .. "_gear",   reverse)
  setSpeed(side .. "_speed", speed)
end

local function setPrimary(speed, disable)
  setBool("primary_clutch", disable)
  if disable then
    setSpeed("primary_speed", 0)
    return
  end
  setSpeed("primary_speed", speed)
end

local function allStop()
  setMotor("left",  0, false, true)
  setMotor("right", 0, false, true)
  setPrimary(0, true)
end

-- ---------------------------------------------------------------------------
-- Heading error
--
-- Returns signed degrees in (-180, 180].
-- Positive = need to turn clockwise (right).
-- Negative = need to turn counter-clockwise (left).

local function signedAngleDiff(a, b)
  -- Difference b - a wrapped to (-180, 180]
  local d = (b - a + 180) % 360 - 180
  return d
end

local function headingError(vx, vz, dest_x, dest_z, pos_x, pos_z)
  -- Bearing to destination (degrees clockwise from North)
  local tdx = dest_x - pos_x
  local tdz = dest_z - pos_z
  local target_bearing = (math.deg(math.atan2(tdx, -tdz)) + 360) % 360

  -- Current heading from velocity (degrees clockwise from North).
  -- CFG.heading_offset corrects for ships built facing a non-North direction.
  local speed = math.sqrt(vx*vx + vz*vz)
  if speed < 2.0 then return 0 end  -- below this velocity is too noisy to steer from

  local current_heading = (math.deg(math.atan2(vx, -vz)) + CFG.heading_offset + 360) % 360
  return signedAngleDiff(current_heading, target_bearing)
end

-- ---------------------------------------------------------------------------
-- Steering: translate heading error into motor commands
--
-- error_deg  : signed degrees, positive = turn right
-- base_frac  : 0.0-1.0 target speed fraction for the primary + drive motors

local function applySteer(error_deg, base_frac)
  local abs_err = math.abs(error_deg)
  local sign    = error_deg >= 0 and 1 or -1   -- +1 = turn right

  if abs_err <= CFG.ultra_fine_threshold then
    -- ── ULTRA-FINE: deadband — no correction, straight ahead ───────────────
    -- Prevents oscillation when already well-aligned.
    setMotor("left",  base_frac, false, false)
    setMotor("right", base_frac, false, false)
    setPrimary(base_frac, false)

  elseif abs_err <= CFG.fine_threshold then
    -- ── FINE: differential speed only, both motors forward ─────────────────
    -- Interpolate from 0 correction (at ultra_fine) to full correction (at fine)
    local frac       = (abs_err - CFG.ultra_fine_threshold) /
                       (CFG.fine_threshold - CFG.ultra_fine_threshold)
    local correction = frac * CFG.turn_p * base_frac * 0.5

    local fast = math.min(1, base_frac + correction)
    local slow = math.max(0, base_frac - correction)

    setMotor("left",  sign > 0 and fast or slow, false, false)
    setMotor("right", sign > 0 and slow or fast, false, false)
    setPrimary(base_frac, false)

  elseif abs_err <= CFG.coarse_threshold then
    -- ── MEDIUM: differential speed + gearshift on the slower side ──────────
    -- frac 0→1 across this zone
    local frac = (abs_err - CFG.fine_threshold) /
                 (CFG.coarse_threshold - CFG.fine_threshold)

    local fast_frac = base_frac
    local slow_frac, slow_rev

    if frac <= 0.5 then
      -- First half: slow side from base down to 0, still forward
      slow_frac = base_frac * (1 - frac * 2)
      slow_rev  = false
    else
      -- Second half: slow side from 0 back up, but now reversed
      slow_frac = base_frac * ((frac - 0.5) * 2)
      slow_rev  = true
    end

    if sign > 0 then  -- turn right: left fast, right slow
      setMotor("left",  fast_frac, false,    false)
      setMotor("right", slow_frac, slow_rev, false)
    else              -- turn left: right fast, left slow
      setMotor("left",  slow_frac, slow_rev, false)
      setMotor("right", fast_frac, false,    false)
    end
    -- Primary scales from full (at fine boundary) to zero (at coarse boundary).
    -- This removes forward momentum that causes overshoot during medium turns.
    local primary_frac = base_frac * (1 - frac * 0.3)
    setPrimary(primary_frac, false)

  else
    -- ── COARSE: one motor fully reversed, other full forward ───────────────
    -- Primary is cut entirely to stop forward momentum and allow a tight turn.
    -- sign > 0 = turn right = left forward, right reversed
    setMotor("left",  base_frac, sign < 0, false)
    setMotor("right", base_frac, sign > 0, false)
    setPrimary(0, true)
  end
end

-- ---------------------------------------------------------------------------
-- Speed fraction helper: map blocks/s target to 0.0-1.0

local function speedFrac(target_bps)
  return math.max(0, math.min(1, target_bps / CFG.max_speed))
end

-- ---------------------------------------------------------------------------
-- Navigation state

local state = { phase = "navigating" }

-- ---------------------------------------------------------------------------
-- Main tick

local function navTick()
  if not sublevel.isInPlotGrid() then
    print("[autopilot] Sub-Level lost — stopping.")
    allStop()
    return false
  end

  local pose   = sublevel.getLogicalPose()
  local vel    = sublevel.getLinearVelocity()
  local pos_x  = pose.position.x
  local pos_z  = pose.position.z

  local dx   = CFG.dest_x - pos_x
  local dz   = CFG.dest_z - pos_z
  local dist = math.sqrt(dx*dx + dz*dz)

  -- ── Arrival / Braking ────────────────────────────────────────────────────
  if dist < CFG.arrival_radius then
    local speed = math.sqrt(vel.x^2 + vel.z^2)

    local phase
    if speed > CFG.brake_speed_threshold then
      state.phase = "braking"
      local brake_frac = math.min(1, speed / CFG.max_speed)
      setMotor("left",  brake_frac, true, false)
      setMotor("right", brake_frac, true, false)
      setPrimary(0, true)
      phase = "braking"
    else
      if state.phase ~= "arrived" then
        print(("[autopilot] Arrived at %.0f, %.0f"):format(CFG.dest_x, CFG.dest_z))
        state.phase = "arrived"
      end
      allStop()
      phase = "arrived"
    end
    if CFG.broadcast_status and modem then
      rednet.broadcast({
        type     = "autopilot",
        name     = shipName,
        phase    = phase,
        pos      = { x = pos_x, z = pos_z },
        dest     = { x = CFG.dest_x, z = CFG.dest_z },
        dist     = dist,
        err_deg  = 0,
        velocity = { x = vel.x, z = vel.z },
      }, CFG.status_channel)
    end
    return true
  end

  state.phase = "navigating"

  -- ── Target speed (two-stage decel) ───────────────────────────────────────
  local target_bps
  if dist >= CFG.outer_approach_radius then
    target_bps = CFG.max_speed
  elseif dist >= CFG.inner_approach_radius then
    local t = (dist - CFG.inner_approach_radius) /
              (CFG.outer_approach_radius - CFG.inner_approach_radius)
    target_bps = CFG.mid_speed + (CFG.max_speed - CFG.mid_speed) * t
  else
    local t = (dist - CFG.arrival_radius) /
              (CFG.inner_approach_radius - CFG.arrival_radius)
    t = math.max(0, t)
    target_bps = CFG.approach_speed + (CFG.mid_speed - CFG.approach_speed) * t
  end
  local base_sig = speedFrac(target_bps)

  -- ── Heading error ────────────────────────────────────────────────────────
  local err_deg = headingError(vel.x, vel.z, CFG.dest_x, CFG.dest_z, pos_x, pos_z)

  -- ── Apply steering ───────────────────────────────────────────────────────
  applySteer(err_deg, base_sig)

  -- ── Status broadcast ─────────────────────────────────────────────────────
  if CFG.broadcast_status and modem then
    rednet.broadcast({
      type     = "autopilot",
      name     = shipName,
      phase    = state.phase,
      pos      = { x = pos_x, z = pos_z },
      dest     = { x = CFG.dest_x, z = CFG.dest_z },
      dist     = dist,
      err_deg  = err_deg,
      velocity = { x = vel.x, z = vel.z },
    }, CFG.status_channel)
  end

  -- ── Heartbeat log ────────────────────────────────────────────────────────
  if math.floor(os.epoch("utc") / 5000) ~=
     math.floor((os.epoch("utc") - CFG.tick * 1000) / 5000) then
    local spd = math.sqrt(vel.x^2 + vel.z^2)
    local zone = math.abs(err_deg) <= CFG.ultra_fine_threshold and "ultrafine"
              or math.abs(err_deg) <= CFG.fine_threshold        and "fine"
              or math.abs(err_deg) <= CFG.coarse_threshold      and "medium"
              or "coarse"
    print(("[autopilot] %.0fblk  err=%+.1f°  spd=%.1f  zone=%s"):format(
      dist, err_deg, spd, zone))
  end

  return true
end

-- ---------------------------------------------------------------------------
-- Run

print(("[autopilot] Navigating to x=%.0f z=%.0f"):format(CFG.dest_x, CFG.dest_z))

while true do
  local ok, err = pcall(navTick)
  if not ok then
    print("[autopilot] Error: " .. tostring(err))
    allStop()
    sleep(1)
  elseif state.phase == "arrived" then
    break
  end
  sleep(CFG.tick)
end

print("[autopilot] Done.")
