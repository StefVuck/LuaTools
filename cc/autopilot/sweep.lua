-- sweep.lua
-- Lawnmower-pattern area sweep using the autopilot motor stack.
--
-- Usage:
--   autopilot/sweep <x1> <z1> <x2> <z2>
--
-- The two XZ pairs are opposite corners of the rectangle to sweep.
-- The ship "discovers" HALF_WIDTH (default 150) blocks either side of its
-- track, so sweep lines are spaced HALF_WIDTH*2 (300) blocks apart.
--
-- The sweep axis is chosen automatically: lines run parallel to the
-- longer side of the rectangle so fewer passes are needed.
--
-- Setup: same as autopilot.lua — needs a redstone_link_bridge and
-- a sublevel that is in the plot grid.

-- ---------------------------------------------------------------------------
-- Sweep config

local HALF_WIDTH   = 150   -- blocks discovered either side of track
local LINE_SPACING = HALF_WIDTH * 2

-- ---------------------------------------------------------------------------
-- Frequency pairs  (must match autopilot.lua)

local LINKS = {
  primary_clutch = { "minecraft:diamond",    "create:clutch"              },
  left_clutch    = { "minecraft:iron_ingot", "create:clutch"              },
  right_clutch   = { "minecraft:gold_ingot", "create:clutch"              },
  left_gear      = { "minecraft:iron_ingot", "create:brass_casing"        },
  right_gear     = { "minecraft:gold_ingot", "create:brass_casing"        },
  primary_speed  = { "minecraft:diamond",    "create:industrial_iron_block" },
  left_speed     = { "minecraft:iron_ingot", "create:industrial_iron_block" },
  right_speed    = { "minecraft:gold_ingot", "create:industrial_iron_block" },
}

local WIRED = {
  primary_clutch = true, left_clutch = true, right_clutch = true,
  left_gear      = true, right_gear  = true,
  primary_speed  = true, left_speed  = true, right_speed  = true,
}

-- ---------------------------------------------------------------------------
-- Navigation tuning

local CFG = {
  max_speed      = 18,
  mid_speed      = 10,
  approach_speed = 3,

  arrival_radius        = 30,
  inner_approach_radius = 250,
  outer_approach_radius = 500,

  brake_speed_threshold = 1.5,

  ultra_fine_threshold = 2,
  fine_threshold       = 10,
  coarse_threshold     = 45,
  turn_p               = 0.9,

  heading_offset   = 0,
  status_channel   = "autopilot",
  broadcast_status = true,
  tick             = 0.2,
}

-- ---------------------------------------------------------------------------
-- Args

local args = { ... }
if #args < 4 then
  error("Usage: autopilot/sweep <x1> <z1> <x2> <z2>")
end
local x1, z1, x2, z2 = tonumber(args[1]), tonumber(args[2]),
                        tonumber(args[3]), tonumber(args[4])
if not (x1 and z1 and x2 and z2) then
  error("All four arguments must be numbers")
end

-- ---------------------------------------------------------------------------
-- Sweep waypoint generation
--
-- We pick the axis where the rectangle is longest for the "run" direction.
-- Lines are offset by LINE_SPACING along the perpendicular axis, starting
-- at the near edge + HALF_WIDTH so the first pass covers the edge too.

local function generateWaypoints(ax1, az1, ax2, az2)
  local minX = math.min(ax1, ax2)
  local maxX = math.max(ax1, ax2)
  local minZ = math.min(az1, az2)
  local maxZ = math.max(az1, az2)

  local width  = maxX - minX   -- east-west extent
  local height = maxZ - minZ   -- north-south extent

  local wps = {}

  if width >= height then
    -- Sweep east-west (lines run along X), step northward through Z
    local z = minZ + HALF_WIDTH
    local leftToRight = true
    while z <= maxZ + HALF_WIDTH do
      local clampedZ = math.min(z, maxZ)
      if leftToRight then
        wps[#wps + 1] = { x = minX, z = clampedZ }
        wps[#wps + 1] = { x = maxX, z = clampedZ }
      else
        wps[#wps + 1] = { x = maxX, z = clampedZ }
        wps[#wps + 1] = { x = minX, z = clampedZ }
      end
      leftToRight = not leftToRight
      z = z + LINE_SPACING
    end
  else
    -- Sweep north-south (lines run along Z), step eastward through X
    local x = minX + HALF_WIDTH
    local topToBottom = true
    while x <= maxX + HALF_WIDTH do
      local clampedX = math.min(x, maxX)
      if topToBottom then
        wps[#wps + 1] = { x = clampedX, z = minZ }
        wps[#wps + 1] = { x = clampedX, z = maxZ }
      else
        wps[#wps + 1] = { x = clampedX, z = maxZ }
        wps[#wps + 1] = { x = clampedX, z = minZ }
      end
      topToBottom = not topToBottom
      x = x + LINE_SPACING
    end
  end

  return wps
end

local waypoints   = generateWaypoints(x1, z1, x2, z2)
local wpIndex     = 1
local totalWPs    = #waypoints

print(("[sweep] Rectangle (%.0f,%.0f)-(%.0f,%.0f)"):format(x1, z1, x2, z2))
print(("[sweep] Generated %d waypoints"):format(totalWPs))

-- ---------------------------------------------------------------------------
-- Peripherals

local bridge = peripheral.find("redstone_link_bridge")
  or error("No redstone_link_bridge found")

local modem = peripheral.find("modem")
if modem and CFG.broadcast_status then
  rednet.open(peripheral.getName(modem))
end

while not sublevel.isInPlotGrid() do
  print("[sweep] Waiting for Sub-Level...")
  sleep(2)
end

local shipName = sublevel.getName()
print(("[sweep] Ship: %s"):format(shipName))

-- ---------------------------------------------------------------------------
-- Redstone link helpers (identical to autopilot.lua)

local function send(channel, strength)
  if not WIRED[channel] then return end
  local f = LINKS[channel]
  bridge.sendLinkSignal(f[1], f[2], math.floor(math.max(0, math.min(15, strength))))
end

local function setBool(channel, active)
  send(channel, active and 15 or 0)
end

local function setSpeed(channel, fraction)
  fraction = math.max(0, math.min(1, fraction))
  send(channel, math.floor((1 - fraction) * 15))
end

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
  if disable then setSpeed("primary_speed", 0) ; return end
  setSpeed("primary_speed", speed)
end

local function allStop()
  setMotor("left",  0, false, true)
  setMotor("right", 0, false, true)
  setPrimary(0, true)
end

-- ---------------------------------------------------------------------------
-- Heading / steering (identical to autopilot.lua)

local function signedAngleDiff(a, b)
  return (b - a + 180) % 360 - 180
end

local function headingError(vx, vz, dest_x, dest_z, pos_x, pos_z)
  local tdx = dest_x - pos_x
  local tdz = dest_z - pos_z
  local target_bearing = (math.deg(math.atan2(tdx, -tdz)) + 360) % 360
  local speed = math.sqrt(vx*vx + vz*vz)
  if speed < 2.0 then return 0 end
  local current_heading = (math.deg(math.atan2(vx, -vz)) + CFG.heading_offset + 360) % 360
  return signedAngleDiff(current_heading, target_bearing)
end

local function applySteer(error_deg, base_frac)
  local abs_err = math.abs(error_deg)
  local sign    = error_deg >= 0 and 1 or -1

  if abs_err <= CFG.ultra_fine_threshold then
    setMotor("left",  base_frac, false, false)
    setMotor("right", base_frac, false, false)
    setPrimary(base_frac, false)

  elseif abs_err <= CFG.fine_threshold then
    local frac       = (abs_err - CFG.ultra_fine_threshold) /
                       (CFG.fine_threshold - CFG.ultra_fine_threshold)
    local correction = frac * CFG.turn_p * base_frac * 0.5
    local fast = math.min(1, base_frac + correction)
    local slow = math.max(0, base_frac - correction)
    setMotor("left",  sign > 0 and fast or slow, false, false)
    setMotor("right", sign > 0 and slow or fast, false, false)
    setPrimary(base_frac, false)

  elseif abs_err <= CFG.coarse_threshold then
    local frac = (abs_err - CFG.fine_threshold) /
                 (CFG.coarse_threshold - CFG.fine_threshold)
    local fast_frac = base_frac
    local slow_frac, slow_rev
    if frac <= 0.5 then
      slow_frac = base_frac * (1 - frac * 2) ; slow_rev = false
    else
      slow_frac = base_frac * ((frac - 0.5) * 2) ; slow_rev = true
    end
    if sign > 0 then
      setMotor("left",  fast_frac, false,    false)
      setMotor("right", slow_frac, slow_rev, false)
    else
      setMotor("left",  slow_frac, slow_rev, false)
      setMotor("right", fast_frac, false,    false)
    end
    local primary_frac = base_frac * (1 - frac)
    setPrimary(primary_frac, primary_frac < 0.02)

  else
    setMotor("left",  base_frac, sign < 0, false)
    setMotor("right", base_frac, sign > 0, false)
    setPrimary(0, true)
  end
end

local function speedFrac(target_bps)
  return math.max(0, math.min(1, target_bps / CFG.max_speed))
end

-- ---------------------------------------------------------------------------
-- Sweep state

local sweepState = { phase = "navigating" }

-- ---------------------------------------------------------------------------
-- Nav tick (returns true = keep going, false = abort)
-- dest_x / dest_z come from the current waypoint.

local function navTick(dest_x, dest_z)
  if not sublevel.isInPlotGrid() then
    print("[sweep] Sub-Level lost — stopping.")
    allStop()
    return false, "lost"
  end

  local pose  = sublevel.getLogicalPose()
  local vel   = sublevel.getLinearVelocity()
  local pos_x = pose.position.x
  local pos_z = pose.position.z

  local dx   = dest_x - pos_x
  local dz   = dest_z - pos_z
  local dist = math.sqrt(dx*dx + dz*dz)

  -- Arrival / braking
  if dist < CFG.arrival_radius then
    local speed = math.sqrt(vel.x^2 + vel.z^2)
    if speed > CFG.brake_speed_threshold then
      sweepState.phase = "braking"
      local brake_frac = math.min(1, speed / CFG.max_speed)
      setMotor("left",  brake_frac, true, false)
      setMotor("right", brake_frac, true, false)
      setPrimary(0, true)
      return true, "braking"
    end
    allStop()
    return true, "arrived"
  end

  sweepState.phase = "navigating"

  -- Two-stage decel
  local target_bps
  if dist >= CFG.outer_approach_radius then
    target_bps = CFG.max_speed
  elseif dist >= CFG.inner_approach_radius then
    local t = (dist - CFG.inner_approach_radius) /
              (CFG.outer_approach_radius - CFG.inner_approach_radius)
    target_bps = CFG.mid_speed + (CFG.max_speed - CFG.mid_speed) * t
  else
    local t = math.max(0, (dist - CFG.arrival_radius) /
              (CFG.inner_approach_radius - CFG.arrival_radius))
    target_bps = CFG.approach_speed + (CFG.mid_speed - CFG.approach_speed) * t
  end

  local base_sig = speedFrac(target_bps)
  local err_deg  = headingError(vel.x, vel.z, dest_x, dest_z, pos_x, pos_z)
  applySteer(err_deg, base_sig)

  -- Status broadcast
  if CFG.broadcast_status and modem then
    rednet.broadcast({
      type     = "autopilot",
      name     = shipName,
      phase    = "sweep-" .. wpIndex .. "/" .. totalWPs,
      pos      = { x = pos_x, z = pos_z },
      dest     = { x = dest_x, z = dest_z },
      dist     = dist,
      err_deg  = err_deg,
      velocity = { x = vel.x, z = vel.z },
    }, CFG.status_channel)
  end

  return true, "navigating"
end

-- ---------------------------------------------------------------------------
-- Main loop: iterate through waypoints

print(("[sweep] Starting sweep — %d legs"):format(totalWPs))

while wpIndex <= totalWPs do
  local wp = waypoints[wpIndex]
  print(("[sweep] Leg %d/%d  -> x=%.0f z=%.0f"):format(
    wpIndex, totalWPs, wp.x, wp.z))

  local legDone = false
  while not legDone do
    local ok, result = pcall(navTick, wp.x, wp.z)
    if not ok then
      print("[sweep] Error: " .. tostring(result))
      allStop()
      sleep(1)
    elseif result == "lost" then
      -- Sub-level lost — abort entire sweep
      return
    elseif result == "arrived" then
      legDone = true
    end
    sleep(CFG.tick)
  end

  wpIndex = wpIndex + 1
end

allStop()
print("[sweep] Sweep complete.")
