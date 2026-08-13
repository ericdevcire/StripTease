-- ============================================================================
-- StripTease Install FX chains
-- Version: 1.0
-- Developer: Eric Avondo
--
-- ReaPack ne sait pas ecrire dans le dossier FXChains/ de REAPER : les chaines
-- livrees avec StripTease atterrissent dans Data/StripTease/. Ce script les recopie
-- dans FXChains/, seul dossier lu par le navigateur de FX.
--
-- Relancer ce script apres chaque mise a jour pour rafraichir les chaines.
-- ============================================================================

local SRC_REL = "/Data/StripTease"
local DST_REL = "/FXChains"

local res = reaper.GetResourcePath()
local src = res .. SRC_REL
local dst = res .. DST_REL

local function list_chains(dir)
  local out, i = {}, 0

  -- fileindex = -1 force REAPER a relire le repertoire. Sans ca, une
  -- installation ou une mise a jour ReaPack faite dans la meme session peut
  -- renvoyer l'ancien listing en cache : chaines nouvelles absentes, ou chaines
  -- supprimees encore presentes.
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
    "Aucune FX chain trouvee dans :\n" .. src ..
    "\n\nInstalle ou reinstalle StripTease via ReaPack, puis relance ce script.",
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
        name .. "\n\nexiste deja dans FXChains/ avec un contenu different.\n" ..
        "L'ecraser par la version StripTease ?", "StripTease", 4) == 6
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
  "FX chains StripTease\n\nInstallees / mises a jour : %d\nDeja a jour ou ignorees : %d",
  #copied, #skipped)

if #failed > 0 then
  msg = msg .. "\nEchecs : " .. #failed .. "\n  " .. table.concat(failed, "\n  ")
end

msg = msg .. "\n\nDestination :\n" .. dst ..
      "\n\nLes chaines apparaissent dans le navigateur de FX, onglet 'FX Chains'."

reaper.ShowMessageBox(msg, "StripTease", 0)
