-- ==========================================================================
-- StripTease Install FX chains
-- Version: 1.2.3
-- Developer: Eric Avondo
--
-- Freeware - personal use. Resale or redistribution for profit is
-- prohibited. See LICENSE.txt.
-- ==========================================================================
-- Each ReaPack data folder and the FXChains/ folder it is copied to. The
-- community folder is only present when the "StripTease Community Presets"
-- package is installed; its chains get their own sub-folder in the FX browser.
local SETS = {
  { label = "StripTease",           src = "/Data/StripTease",           dst = "/FXChains" },
  { label = "StripTease Community", src = "/Data/StripTease/Community", dst = "/FXChains/StripTease Community" },
}

local res = reaper.GetResourcePath()

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

local function install(set, chains)
  local src, dst = res .. set.src, res .. set.dst
  local r = { copied = {}, skipped = {}, failed = {}, dst = dst, label = set.label }
  reaper.RecursiveCreateDirectory(dst, 0)

  for _, name in ipairs(chains) do
    local target = dst .. "/" .. name
    local existing = read_all(target)
    local data = read_all(src .. "/" .. name)

    if not data then
      r.failed[#r.failed + 1] = name
    elseif existing == data then
      r.skipped[#r.skipped + 1] = name
    else
      local overwrite = true
      if existing then
        overwrite = reaper.ShowMessageBox(
          name .. "\n\nalready exists in " .. set.dst:sub(2) .. "/ with different content.\n" ..
          "Overwrite it with the " .. set.label .. " version?", "StripTease", 4) == 6
      end
      if overwrite then
        if write_all(target, data) then
          r.copied[#r.copied + 1] = name
        else
          r.failed[#r.failed + 1] = name
        end
      else
        r.skipped[#r.skipped + 1] = name
      end
    end
  end
  return r
end

local results = {}
for _, set in ipairs(SETS) do
  local chains = list_chains(res .. set.src)
  if #chains > 0 then results[#results + 1] = install(set, chains) end
end

if #results == 0 then
  reaper.ShowMessageBox(
    "No FX chain found in:\n" .. res .. SETS[1].src ..
    "\n\nInstall or reinstall StripTease, then run this script again.",
    "StripTease", 0)
  return
end

local msg = "StripTease FX chains"
for _, r in ipairs(results) do
  msg = msg .. string.format(
    "\n\n%s\nInstalled / updated: %d\nAlready up to date or skipped: %d",
    r.label, #r.copied, #r.skipped)
  if #r.failed > 0 then
    msg = msg .. "\nFailed: " .. #r.failed .. "\n  " .. table.concat(r.failed, "\n  ")
  end
  msg = msg .. "\nDestination: " .. r.dst
end

msg = msg .. "\n\nThe chains show up in the FX browser, under the 'FX Chains' tab."

reaper.ShowMessageBox(msg, "StripTease", 0)
