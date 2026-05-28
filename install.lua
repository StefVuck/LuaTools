-- install.lua  (lives at repo root, not in cc/)
-- Bootstrap installer for CC Train Map.
--
-- First time on any CC computer:
--   wget https://raw.githubusercontent.com/StefVuck/test/main/install.lua install.lua
--
-- Then run for your computer's role:
--   install display    -- main map display (5x5 monitor)
--   install station    -- per-station computer
--   install static     -- train schematic display (2-wide monitor)
--   install update     -- re-download every file already on this computer

local BASE = "https://raw.githubusercontent.com/StefVuck/test/main/cc"

-- Files for each role.
-- optional = true  -> silently skip on 404 (e.g. nether maps not yet generated)
local ROLES = {
  display = {
    { "display.lua" },
    { "map_overworld_z1.lua" },
    { "map_overworld_z2.lua" },
    { "map_overworld_z3.lua" },
    { "map_overworld_z4.lua" },
    { "map_overworld_z5.lua" },
    { "map_overworld_z6.lua" },
    { "map_nether_z1.lua", optional = true },
    { "map_nether_z2.lua", optional = true },
    { "map_nether_z3.lua", optional = true },
    { "map_nether_z4.lua", optional = true },
    { "map_nether_z5.lua", optional = true },
    { "map_nether_z6.lua", optional = true },
  },
  station = {
    { "station.lua" },
  },
  static = {
    { "staticmap.lua" },
    { "map_trainmap.lua" },
  },
}

-- All known filenames (for the 'update' role)
local ALL_FILES = {}
for _, entries in pairs(ROLES) do
  for _, e in ipairs(entries) do ALL_FILES[e[1]] = true end
end

-- ---------------------------------------------------------------------------

local function download(filename, optional)
  local url = BASE .. "/" .. filename
  io.write("  " .. filename .. " ... ")

  local response, err = http.get(url)
  if not response then
    if optional then print("(skipped)") ; return true end
    print("FAILED (" .. tostring(err) .. ")")
    return false
  end

  local code = response.getResponseCode()
  if code == 404 then
    response.close()
    if optional then print("(not published yet)") ; return true end
    print("FAILED (404)")
    return false
  end

  if code ~= 200 then
    response.close()
    print("FAILED (HTTP " .. code .. ")")
    return false
  end

  local body = response.readAll()
  response.close()

  if not body or #body == 0 then
    if optional then print("(empty, skipped)") ; return true end
    print("FAILED (empty response)")
    return false
  end

  local f = fs.open(filename, "w")
  f.write(body)
  f.close()
  print("OK")
  return true
end

local function runRole(entries)
  local ok, fail = 0, 0
  for _, entry in ipairs(entries) do
    local name     = entry[1]
    local optional = entry.optional or false
    if download(name, optional) then ok = ok + 1 else fail = fail + 1 end
  end
  return ok, fail
end

-- ---------------------------------------------------------------------------

local role = (...) or ""
role = role:lower():gsub("%s+", "")

if role == "" then
  print("Usage: install <role>")
  print("Roles: display | station | static | update")
  return
end

if role == "update" then
  -- Re-download whichever known files already exist locally
  print("Updating existing files...")
  local entries = {}
  for name in pairs(ALL_FILES) do
    if fs.exists(name) then entries[#entries + 1] = { name } end
  end
  if #entries == 0 then print("No known files found on this computer.") ; return end
  local ok, fail = runRole(entries)
  print(("\nUpdated %d file(s), %d failed."):format(ok, fail))

elseif ROLES[role] then
  print("Installing: " .. role)
  local ok, fail = runRole(ROLES[role])
  print(("\nDone: %d downloaded, %d failed."):format(ok, fail))
  if role == "display" then
    print("Run:  display")
  elseif role == "station" then
    print("Edit station.lua config, then run:  station")
  elseif role == "static" then
    print("Run:  staticmap")
  end

else
  print("Unknown role '" .. role .. "'")
  print("Valid roles: display, station, static, update")
end
