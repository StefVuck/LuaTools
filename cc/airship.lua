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

while true do
  local x, y, z = gps.locate(2)
  if x then
    rednet.broadcast({
      type      = "airship",
      name      = NAME,
      dimension = DIMENSION,
      coords    = { x = math.floor(x), z = math.floor(z) },
    }, CHANNEL)
  else
    print("GPS fix failed")
  end
  sleep(INTERVAL)
end
