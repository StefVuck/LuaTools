-- airship.lua
-- Broadcasts this airship's position to the map display using CC:Sable.
-- Requires CC:Sable (Create: Simulated addon) and a wireless modem.
-- The computer must be placed on the airship (a physics Sub-Level).
--
-- Setup:
--   1. Place this computer on the airship Sub-Level.
--   2. Set DIMENSION to "overworld" or "nether".
--   3. Attach a wireless modem.
--   4. Run this script (or add to startup).

local DIMENSION = "overworld"   -- "overworld" or "nether"
local CHANNEL   = "train_map"
local INTERVAL  = 2             -- seconds between position broadcasts

local modem = peripheral.find("modem") or error("no modem found")
rednet.open(peripheral.getName(modem))

-- Wait until the computer is actually on a Sub-Level
while not sublevel.isInPlotGrid() do
  print("Waiting for Sub-Level... (is this computer on an airship?)")
  sleep(2)
end

local name = sublevel.getName()
print(("Airship tracker started: %s"):format(name))

while true do
  if not sublevel.isInPlotGrid() then
    print("Warning: Sub-Level lost (airship deconstructed?)")
    sleep(INTERVAL)
  else
    local pose = sublevel.getLogicalPose()
    local vel  = sublevel.getLinearVelocity()
    local pos  = pose.position

    rednet.broadcast({
      type      = "airship",
      name      = name,
      dimension = DIMENSION,
      coords    = { x = pos.x, z = pos.z },
      velocity  = { x = vel.x, z = vel.z },
    }, CHANNEL)
    print(("  %s @ %.1f, %.1f  vel: %.2f, %.2f"):format(
      name, pos.x, pos.z, vel.x, vel.z))
    sleep(INTERVAL)
  end
end
