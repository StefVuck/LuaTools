-- airship.lua
-- Broadcasts this airship's GPS position to the map display.
-- Run this on a CC computer with a wireless modem and GPS access.
--
-- Setup:
--   1. Set NAME to a unique name for this airship.
--   2. Set DIMENSION to "overworld" or "nether".
--   3. Attach a wireless modem.
--   4. Ensure the server has a GPS constellation set up.

local NAME      = "My Airship"   -- change this per airship
local DIMENSION = "overworld"    -- "overworld" or "nether"
local CHANNEL   = "train_map"
local INTERVAL  = 5              -- seconds between position broadcasts

local modem = peripheral.find("modem") or error("no modem found")
rednet.open(peripheral.getName(modem))
print(("Airship tracker started: %s"):format(NAME))

local lastX, lastZ = nil, nil
local gpsWarned = false

while true do
  local x, y, z = gps.locate(5)
  if x then
    lastX, lastZ = math.floor(x), math.floor(z)
    gpsWarned = false
    rednet.broadcast({
      type      = "airship",
      name      = NAME,
      dimension = DIMENSION,
      coords    = { x = lastX, z = lastZ },
    }, CHANNEL)
    print(("Broadcast: %s @ %d, %d"):format(NAME, lastX, lastZ))
  elseif lastX then
    -- GPS lost but we have a last-known position; keep broadcasting it
    rednet.broadcast({
      type      = "airship",
      name      = NAME,
      dimension = DIMENSION,
      coords    = { x = lastX, z = lastZ },
    }, CHANNEL)
    print("GPS lost - broadcasting last known position")
  else
    if not gpsWarned then
      print("GPS fix failed. Ensure a GPS constellation (4 CC computers with")
      print("  wireless modems running 'gps host X Y Z') is set up on the server.")
      gpsWarned = true
    end
  end
  sleep(INTERVAL)
end
