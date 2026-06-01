-- waypoints.lua
-- Named destination registry.  Used by autopilot.lua when launched as:
--   autopilot <name>
-- or imported by other scripts: local wp = require("waypoints")

local waypoints = {
  -- ["home"]   = { x =    0, z =    0 },
  -- ["port"]   = { x =  512, z = -256 },
}

local function get(name)
  return waypoints[name]
end

local function list()
  local out = {}
  for k, v in pairs(waypoints) do
    out[#out + 1] = { name = k, x = v.x, z = v.z }
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

local function set(name, x, z)
  waypoints[name] = { x = x, z = z }
end

local function remove(name)
  waypoints[name] = nil
end

-- CLI usage: lua waypoints.lua list | set <name> <x> <z> | del <name>
if arg and arg[0] then
  local cmd = arg[1]
  if cmd == "list" then
    for _, w in ipairs(list()) do
      print(("  %-20s  x=%.0f  z=%.0f"):format(w.name, w.x, w.z))
    end
  elseif cmd == "set" and arg[2] and arg[3] and arg[4] then
    set(arg[2], tonumber(arg[3]), tonumber(arg[4]))
    print("Set " .. arg[2])
  elseif cmd == "del" and arg[2] then
    remove(arg[2])
    print("Removed " .. arg[2])
  else
    print("Usage: waypoints list | set <name> <x> <z> | del <name>")
  end
end

return { get = get, list = list, set = set, remove = remove }
