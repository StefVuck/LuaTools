-- waypoints.lua
-- Persistent named destination registry stored in autopilot/waypoints.json.
--
-- As a module (required by autopilot.lua):
--   local wp = require("autopilot/waypoints")
--   wp.get("home")   -> { x=..., z=... } or nil
--   wp.list()        -> sorted array of { name, x, z }
--
-- As a CLI (run directly in the CC shell):
--   autopilot/waypoints list
--   autopilot/waypoints set <name> <x> <z>
--   autopilot/waypoints del <name>

local DB_PATH = "autopilot/waypoints.json"

-- ---------------------------------------------------------------------------
-- Persistence

local function load()
  if not fs.exists(DB_PATH) then return {} end
  local f = fs.open(DB_PATH, "r")
  local raw = f.readAll()
  f.close()
  return textutils.unserialiseJSON(raw) or {}
end

local function save(db)
  local f = fs.open(DB_PATH, "w")
  f.write(textutils.serialiseJSON(db))
  f.close()
end

-- ---------------------------------------------------------------------------
-- API

local function get(name)
  local db = load()
  return db[name]   -- { x=..., z=... } or nil
end

local function list()
  local db = load()
  local out = {}
  for k, v in pairs(db) do
    out[#out + 1] = { name = k, x = v.x, z = v.z }
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

local function set(name, x, z)
  local db = load()
  db[name] = { x = x, z = z }
  save(db)
end

local function remove(name)
  local db = load()
  db[name] = nil
  save(db)
end

-- ---------------------------------------------------------------------------
-- CC shell CLI  (args via {...}, not the unavailable 'arg' global)

local cliArgs = { ... }
if #cliArgs > 0 then
  local cmd = cliArgs[1]
  if cmd == "list" then
    local entries = list()
    if #entries == 0 then
      print("No waypoints saved.")
    else
      for _, w in ipairs(entries) do
        print(("  %-20s  x=%.0f  z=%.0f"):format(w.name, w.x, w.z))
      end
    end

  elseif cmd == "set" and cliArgs[2] and cliArgs[3] and cliArgs[4] then
    local x = tonumber(cliArgs[3])
    local z = tonumber(cliArgs[4])
    if not (x and z) then
      print("x and z must be numbers")
    else
      set(cliArgs[2], x, z)
      print(("Saved '%s'  x=%.0f  z=%.0f"):format(cliArgs[2], x, z))
    end

  elseif cmd == "del" and cliArgs[2] then
    remove(cliArgs[2])
    print("Removed '" .. cliArgs[2] .. "'")

  else
    print("Usage:")
    print("  autopilot/waypoints list")
    print("  autopilot/waypoints set <name> <x> <z>")
    print("  autopilot/waypoints del <name>")
  end
end

return { get = get, list = list, set = set, remove = remove }
