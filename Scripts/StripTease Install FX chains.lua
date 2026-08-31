-- ==========================================================================
-- StripTease Install FX chains
-- Version: 1.2.0
-- Developer: Eric Avondo
--
-- Freeware - personal use. Resale or redistribution for profit is
-- prohibited. See LICENSE.txt.
-- ==========================================================================
local SRC_REL = "/Data/StripTease"
local DST_REL = "/FXChains"

local res = reaper.GetResourcePath()
local src = res .. SRC_REL
local dst = res .. DST_REL

local function list_chains(dir)
  local out, i = {}, 0

  -- fileindex = -1 forces REAPER to re-read the directory. Without it, an
  -- install or an update performed in the same session can return the stale
  -- cached listing: new chains missing, or deleted chains still present.
  reaper.EnumerateFiles(dir, -1)

  while true do
    local name = reaper.EnumerateFiles(dir, i)
    if not name then break end
    if name:lower():sub(-9) == ".rfxchain" then out[#out + 1] = name end
    i = i + 1
  end
  return out
end

local function read_all(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

local function write_all(path, data)
  local f = io.open(path, "wb")
  if not f then return false end
  f:write(data)
  f:close()
  return true
end

local chains = list_chains(src)

if #chains == 0 then
  reaper.ShowMessageBox(
    "No FX chain found in:\n" .. src ..
    "\n\nInstall or reinstall StripTease, then run this script again.",
    "StripTease", 0)
  return
end

reaper.RecursiveCreateDirectory(dst, 0)

local copied, skipped, failed = {}, {}, {}

for _, name in ipairs(chains) do
  local target = dst .. "/" .. name
  local existing = read_all(target)
  local data = read_all(src .. "/" .. name)

  if not data then
    failed[#failed + 1] = name
  elseif existing == data then
    skipped[#skipped + 1] = name
  else
    local overwrite = true
    if existing then
      overwrite = reaper.ShowMessageBox(
        name .. "\n\nalready exists in FXChains/ with different content.\n" ..
        "Overwrite it with the StripTease version?", "StripTease", 4) == 6
    end
    if overwrite then
      if write_all(target, data) then
        copied[#copied + 1] = name
      else
        failed[#failed + 1] = name
      end
    else
      skipped[#skipped + 1] = name
    end
  end
end

local msg = string.format(
  "StripTease FX chains\n\nInstalled / updated: %d\nAlready up to date or skipped: %d",
  #copied, #skipped)

if #failed > 0 then
  msg = msg .. "\nFailed: " .. #failed .. "\n  " .. table.concat(failed, "\n  ")
end

msg = msg .. "\n\nDestination:\n" .. dst ..
      "\n\nThe chains show up in the FX browser, under the 'FX Chains' tab."

reaper.ShowMessageBox(msg, "StripTease", 0)
