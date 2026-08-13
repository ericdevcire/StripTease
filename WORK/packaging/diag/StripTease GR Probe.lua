-- ============================================================================
-- StripTease GR Probe -- outil de diagnostic, ne fait pas partie du produit.
--
-- Repond a une seule question : pour chaque plugin de la piste selectionnee,
-- StripTease peut-il lire un gain reduction, et par quelle voie ?
--
-- Les deux voies testees ici sont exactement celles de StripTease System.lua :
--
--   1. GainReduction_dB. Ne repond que du cote VST : extension VST2 de REAPER,
--      et interface VST3 IGainReductionInfo. Un JSFX n'y passe JAMAIS -- sa
--      variable ext_gr_meter alimente le VU de piste du mixer par un chemin
--      interne au module jsfx, sans aucune sortie cote script.
--
--   2. Un parametre dont le nom contient "gain reduction", "gr readout" ou
--      "gr meter", et dont la course fait plus de 1.5 unite (une lecture en dB,
--      donc, et pas un parametre normalise 0..1).
--
-- Mode d'emploi
--   1. selectionner la piste, activer le compresseur du plugin a tester ;
--   2. lancer la lecture, avec du signal qui declenche la compression ;
--   3. lancer ce script.
--
-- La section DETAIL DES PARAMETRES dit pourquoi la voie 2 echoue quand elle
-- echoue : parametre absent, mal nomme, ou course hors dB.
-- ============================================================================

local tr = reaper.GetSelectedTrack(0, 0) or reaper.GetMasterTrack(0)
if not tr then
  reaper.ShowConsoleMsg("StripTease GR Probe : aucune piste selectionnee.\n")
  return
end

-- Les plugins ranges dans un container ne sont pas comptes par TrackFX_GetCount
-- et s'adressent par un index calcule : sans cette descente, un compresseur en
-- container passerait pour absent.
local function EnumFX(t, parent, out)
  local count
  if parent then
    local _, c = reaper.TrackFX_GetNamedConfigParm(t, parent, "container_count")
    count = tonumber(c) or 0
  else
    count = reaper.TrackFX_GetCount(t)
  end
  for i = 0, count - 1 do
    local idx = i
    if parent then
      local _, s = reaper.TrackFX_GetNamedConfigParm(t, parent, "container_item." .. i)
      idx = tonumber(s)
    end
    if idx then
      out[#out + 1] = idx
      local _, isc = reaper.TrackFX_GetNamedConfigParm(t, idx, "container_count")
      if isc ~= "" then EnumFX(t, idx, out) end
    end
  end
  return out
end

local GR_PARAM_WORDS = { "gain reduction", "gr readout", "gr meter" }

-- Renvoie l'index du parametre retenu, plus le detail de ce qui a ete examine.
-- Le detail est ce qui rend la sonde utile : un parametre qui porte le bon nom
-- mais une mauvaise course apparait comme rejete, avec sa course.
local function ScanParams(t, fx)
  local n = reaper.TrackFX_GetNumParams(t, fx) or 0
  local hit, near = nil, {}
  local pm = 0
  while pm < n do
    local ok, nm = reaper.TrackFX_GetParamName(t, fx, pm, "")
    if ok and nm ~= "" then
      local low = nm:lower()

      -- "gain", "reduc" et "gr" attrapent large exprès : on veut voir aussi les
      -- parametres qui ressemblent a une lecture de reduction sans etre retenus.
      if low:find("gain", 1, true) or low:find("reduc", 1, true)
         or low:find("gr", 1, true) then
        local v, mn, mx = reaper.TrackFX_GetParamEx(t, fx, pm)
        local exact = false
        for _, w in ipairs(GR_PARAM_WORDS) do
          if low:find(w, 1, true) then exact = true end
        end
        local wide = mn and mx and (mx - mn) > 1.5
        near[#near + 1] = { pm = pm, nm = nm, v = v, mn = mn, mx = mx,
                            exact = exact, wide = wide }
        if exact and wide and not hit then hit = pm end
      end
    end
    pm = pm + 1
  end
  return hit, near, n
end

local out = {}
local function say(s) out[#out + 1] = s end

local _, tname = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)

say("=== StripTease GR Probe ===")
say("REAPER " .. tostring(reaper.GetAppVersion()))
say("Piste : " .. ((tname ~= "" and tname) or "(sans nom)"))
say("Lecture en cours : " .. ((reaper.GetPlayState() & 1) == 1 and "oui" or "NON -- le GR sera fige"))
say("")
say(string.format("%-4s %-38s %-10s %s", "#", "plugin", "voie", "valeur"))
say(string.rep("-", 78))

local found = 0
local detail = {}

for _, fx in ipairs(EnumFX(tr, nil, {})) do
  local _, nm = reaper.TrackFX_GetFXName(tr, fx, "")
  local ok, v = reaper.TrackFX_GetNamedConfigParm(tr, fx, "GainReduction_dB")
  local num = ok and v ~= "" and tonumber(v) or nil

  local via, val = nil, nil
  if num then
    via, val = "native", math.abs(num)
  else
    local hit, near, n = ScanParams(tr, fx)
    detail[#detail + 1] = { fx = fx, nm = nm, near = near, n = n, hit = hit }
    if hit then
      via = "parametre"
      val = math.min(60, math.abs(reaper.TrackFX_GetParam(tr, fx, hit) or 0))
    end
  end

  if via then found = found + 1 end

  say(string.format("%-4d %-38s %-10s %s",
      fx, nm:sub(1, 38), via or "-- rien",
      val and string.format("%.2f dB", val) or ""))
end

say("")
say(found > 0
    and (found .. " plugin(s) utilisable(s) comme source de gain reduction.")
    or  "Aucun plugin de cette piste ne donne son gain reduction a StripTease.")

say("")
say("========================================================================")
say("DETAIL DES PARAMETRES  (plugins qui ne repondent pas a GainReduction_dB)")
say("")
say("retenu = le nom contient 'gain reduction' / 'gr readout' / 'gr meter'")
say("         ET la course fait plus de 1.5 unite.")
say("")

if #detail == 0 then
  say("Aucun : tous les plugins de cette piste repondent nativement.")
end

for _, D in ipairs(detail) do
  say(string.format("--- fx %d  %s", D.fx, D.nm))
  say(string.format("    %d parametres exposes par REAPER", D.n))
  if #D.near == 0 then
    say("    aucun parametre dont le nom evoque un gain ou une reduction.")
    say("    -> si tu viens d'ajouter un slider au JSFX : recharger le plugin")
    say("       (bouton Reload dans l'editeur JSFX, ou fermer/rouvrir le projet).")
  else
    for _, P in ipairs(D.near) do
      local verdict
      if P.pm == D.hit then         verdict = "RETENU"
      elseif not P.exact then       verdict = "nom non reconnu"
      elseif not P.wide then        verdict = "course trop etroite (pas des dB)"
      else                          verdict = "double d'un autre" end
      say(string.format("    p%-4d %-30s val %-9.3f course %.3f..%.3f  %s",
          P.pm, P.nm:sub(1, 30), P.v or 0, P.mn or 0, P.mx or 0, verdict))
    end
  end
  say("")
end

say("Rappel : StripTease ne propose que Compressor 1, Compressor 2 et Gate 1,")
say("comptes dans l'ordre de la chaine parmi les plugins ayant une voie.")

reaper.ShowConsoleMsg(table.concat(out, "\n") .. "\n\n")
