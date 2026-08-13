-- ============================================================================
-- StripTease Check
-- Version: 1.0
-- Developer: Eric Avondo
--
-- Copyright (c) 2026 Eric Avondo. Tous droits reserves.
-- Licence commerciale : usage personnel autorise, redistribution interdite.
-- Voir LICENSE.txt, livre avec le paquet.
-- ============================================================================

local NMAX  = 4
local NGATE = 2

local GATE_WORDS = { "gate", "expander", "pro-g", "pro g" }

local function EnumFX(tr, parent, out)
  local count
  if parent then
    local _, c = reaper.TrackFX_GetNamedConfigParm(tr, parent, "container_count")
    count = tonumber(c) or 0
  else
    count = reaper.TrackFX_GetCount(tr)
  end
  for i = 0, count - 1 do
    local idx = i
    if parent then
      local _, s = reaper.TrackFX_GetNamedConfigParm(tr, parent, "container_item." .. i)
      idx = tonumber(s)
    end
    if idx then
      out[#out + 1] = idx
      local _, isc = reaper.TrackFX_GetNamedConfigParm(tr, idx, "container_count")
      if isc ~= "" then EnumFX(tr, idx, out) end
    end
  end
  return out
end

local function GRof(tr, fx)
  local ok, v = reaper.TrackFX_GetNamedConfigParm(tr, fx, "GainReduction_dB")
  if ok and v ~= "" and tonumber(v) ~= nil then return tonumber(v) end
  return nil
end

-- Seconde voie, la meme que celle du service : un parametre dont le nom annonce
-- une lecture de reduction et dont la course est en dB. Elle existe parce qu'un
-- JSFX ne peut pas repondre a GainReduction_dB, quoi qu'il donne au VU de piste
-- de REAPER par ext_gr_meter.
local GR_PARAM_WORDS = { "gain reduction", "gr readout", "gr meter" }

local function GRNamed(nm)
  local low = nm:lower()
  for _, w in ipairs(GR_PARAM_WORDS) do
    if low:find(w, 1, true) then return true end
  end
  return false
end

local function GRParam(tr, fx)
  local n = reaper.TrackFX_GetNumParams(tr, fx) or 0
  local pm = 0
  while pm < n do
    local ok, nm = reaper.TrackFX_GetParamName(tr, fx, pm, "")
    if ok and nm ~= "" and GRNamed(nm) then
      local _, mn, mx = reaper.TrackFX_GetParamEx(tr, fx, pm)
      if mn and mx and mx - mn > 1.5 then return pm, nm end
    end
    pm = pm + 1
  end
  return nil
end

local function IsGate(tr, fx)
  local _, nm = reaper.TrackFX_GetFXName(tr, fx, "")
  nm = nm:lower()
  for _, w in ipairs(GATE_WORDS) do
    if nm:find(w, 1, true) then return true end
  end
  return false
end

local function IsPanel(tr, fx)
  local ok, id = reaper.TrackFX_GetNamedConfigParm(tr, fx, "fx_ident")
  if ok and id ~= "" and id:lower():find("striptease panel", 1, true) then
    return true
  end
  local _, nm = reaper.TrackFX_GetFXName(tr, fx, "")
  return nm:lower():find("striptease panel", 1, true) ~= nil
end

local out = {}
local function say(s) out[#out + 1] = s end

say("StripTease Check")
say("=================")
say("")
say("k = track number as seen by the panels (0 = master track).")
say("The left column tells whether the device REPORTS its reduction to REAPER.")
say("")

local total = 0
local readable = {}
local panels = {}

-- Tous les plugins non-panneau, lisibles ou non. La section des parametres les
-- parcourt tous : c'est precisement sur ceux qui ne rapportent rien qu'il faut
-- chercher un parametre, les autres n'en ont pas besoin.
local candidates = {}

local function scan(tr, k, label)
  local fxlist = EnumFX(tr, nil, {})
  if #fxlist == 0 then return end

  say(string.format("--- k=%d  %s", k, label))

  local ncomp, ngate, npanel = 0, 0, 0
  for _, fx in ipairs(fxlist) do
    local _, nm = reaper.TrackFX_GetFXName(tr, fx, "")
    local db = GRof(tr, fx)
    local via, pname = nil, nil

    if IsPanel(tr, fx) then
      npanel = npanel + 1
    else
      candidates[#candidates + 1] = { tr = tr, fx = fx, nm = nm, k = k }
    end

    if db == nil and not IsPanel(tr, fx) then
      local pm
      pm, pname = GRParam(tr, fx)
      if pm then
        db  = reaper.TrackFX_GetParam(tr, fx, pm)
        via = pname
      end
    end

    if db == nil then
      say(string.format("      reports nothing              %s", nm))
    else
      total = total + 1
      local slot
      if IsGate(tr, fx) then
        ngate = ngate + 1
        slot = ngate <= NGATE and string.format("-> Gate %d", ngate) or "(ignored)"
      else
        ncomp = ncomp + 1
        slot = ncomp <= NMAX and string.format("-> Compressor %d", ncomp) or "(ignored)"
      end
      say(string.format("  %-6.1f dB  %-18s %s%s", math.abs(db), slot, nm,
                        via and ("   [via parameter: " .. via .. "]") or ""))
      readable[#readable + 1] = { tr = tr, fx = fx, nm = nm, k = k, label = label }
    end
  end
  if npanel > 1 then
    say(string.format("  !! %d StripTease panels on this track -- see below", npanel))
  end
  panels[k] = npanel
  say("")
end

scan(reaper.GetMasterTrack(0), 0, "MASTER TRACK")
for i = 0, reaper.CountTracks(0) - 1 do
  local tr = reaper.GetTrack(0, i)
  local _, nm = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
  scan(tr, i + 1, (nm ~= "" and nm) or string.format("track %d", i + 1))
end

say(string.format("%d readable device(s) in total.", total))
if total > 0 then
  say("")
  say("A StripTease GR JSFX must use a compressor number NOT listed above for its")
  say("track: on a number already listed, the service publishes the real reduction")
  say("and the JSFX steps aside silently.")
end
if total == 0 then
  say("")
  say("None: either there is no compressor or gate in the project, or none of")
  say("them reports its reduction. Careful with JSFX: one that sets ext_gr_meter")
  say("does feed the REAPER track meter, but that path has no script side -- it")
  say("will show a reduction bar on the fader and still land here. Such a plugin")
  say("has to expose a parameter named 'Gain Reduction', graduated in dB.")
end

local METER_WORDS = { "gain reduction", "reduction", "gate", "expand", "meter",
                      "gr ", " gr", "-gr", "gr-", "level", "output",
                      "comp", "ratio", "threshold" }

local function LooksLikeMeter(nm)
  nm = nm:lower()
  for _, w in ipairs(METER_WORDS) do
    if nm:find(w, 1, true) then return true end
  end
  return false
end

say("")
say("========================================================================")
say("PARAMETERS THAT LOOK LIKE A METER")
say("")
say("GainReduction_dB returns only ONE number per plugin. If gate and compressor")
say("live in the SAME plugin (channel strip), the only other path is through its")
say("parameters -- and that is also the ONLY path for a JSFX, whatever it sends")
say("to the fader. Run DURING PLAYBACK: when stopped everything reads zero and")
say("zero proves nothing.")
say("")
say("TAKEN means StripTease reads it: the name contains 'gain reduction',")
say("'gr readout' or 'gr meter', AND the range spans more than 1.5 units, which")
say("is what tells a dB readout from a normalized 0..1 parameter.")
say("")

for _, R in ipairs(candidates) do
  local np = reaper.TrackFX_GetNumParams(R.tr, R.fx) or 0
  say(string.format("--- k=%d  %s", R.k, R.nm))
  say(string.format("    %d parameters in total", np))
  local hits, taken = 0, GRParam(R.tr, R.fx)
  for p = 0, math.min(np, 1024) - 1 do
    local _, pn = reaper.TrackFX_GetParamName(R.tr, R.fx, p, "")
    if LooksLikeMeter(pn) then
      local _, pv = reaper.TrackFX_GetFormattedParamValue(R.tr, R.fx, p, "")
      local _, mn, mx = reaper.TrackFX_GetParamEx(R.tr, R.fx, p)
      local verdict = ""
      if p == taken then
        verdict = "   <- TAKEN"
      elseif GRNamed(pn) then
        verdict = string.format("   <- name ok, range %.2f..%.2f too narrow", mn or 0, mx or 0)
      end
      say(string.format("    p%-4d %-34s %-12s%s", p, pn:sub(1, 34), pv, verdict))
      hits = hits + 1
    end
  end
  if hits == 0 then
    say("    no parameter with a meter-like name.")
  end
  if not taken then
    say("    -> nothing StripTease can read here.")
    say("       If you just added a slider to a JSFX, RELOAD the plugin: an")
    say("       instance already in the project keeps its old parameter list.")
  end
  say("")
end

local NS      = "StripTeaseGR"
local NEL     = 50
local WSH     = 131072
local WSTRIDE = 512
local WNAME   = 60

reaper.gmem_attach("StripTease")

-- Doit rester identique a FXKey de StripTease System : c'est la cle sur laquelle le
-- service apparie les recettes, et ce diagnostic sert justement a expliquer
-- pourquoi une recette ne trouve pas sa cible. 'fx_name' est le nom d'origine,
-- insensible au renommage de l'instance.
local function FXKey(tr, fx)
  local ok, nm = reaper.TrackFX_GetNamedConfigParm(tr, fx, "fx_name")
  if not ok or nm == "" then
    local _, dn = reaper.TrackFX_GetFXName(tr, fx, "")
    nm = dn
  end
  return nm:sub(1, WNAME)
end

local function FXOccurrence(tr, fx)
  local want = FXKey(tr, fx)
  local seen = 0
  for _, f in ipairs(EnumFX(tr, nil, {})) do
    if f == fx then return seen, want end
    if FXKey(tr, f) == want then seen = seen + 1 end
  end
  return 0, want
end

local function GetStr(a, n)
  n = math.floor(n or 0)
  if n <= 0 or n > WNAME then return nil end
  local cs = {}
  for i = 0, n - 1 do
    local c = math.floor(reaper.gmem_read(a + i) or 0)
    if c < 0 or c > 255 then return nil end
    cs[#cs + 1] = string.char(c)
  end
  return table.concat(cs)
end

local function Links(tr)
  local t = {}
  local g = reaper.GetTrackGUID(tr)
  local ok, v = reaper.GetProjExtState(0, NS, "link." .. g)
  if ok ~= 1 or not v or v == "" then return t end
  for line in v:gmatch("[^\n]+") do
    local el, tg, fg, pid = line:match("^(%d+)\t([^\t]*)\t([^\t]*)\t(.*)$")
    if el then t[#t + 1] = { el = tonumber(el), tg = tg, fg = fg, pid = pid } end
  end
  return t
end

say("")
say("========================================================================")
say("PRESET RECIPE: where the chain breaks")
say("")
say("Only tracks carrying a StripTease panel are listed.")
say("The \"StripTease System.lua\" action must be running: it is what fills all this.")
say("")

local function wish(tr, k, label)
  local fxlist = EnumFX(tr, nil, {})
  local panelfx = nil
  for _, fx in ipairs(fxlist) do
    if IsPanel(tr, fx) then panelfx = fx; break end
  end
  if not panelfx then return end

  say(string.format("--- k=%d  %s", k, label))
  local b = WSH + k * WSTRIDE

  local stamp = reaper.gmem_read(b) or 0
  local pubname, pubocc, pubn
  if stamp <= 0 then
    say("  1. publishes   : NOTHING -- stamp at zero.")
    say("                   The panel never wrote here. Either it is out of")
    say("                   date (reload the .jsfx-inc), or it believes it is")
    say("                   on a track other than k=" .. k .. ".")
  else
    pubname = GetStr(b + 3, reaper.gmem_read(b + 2))
    pubocc  = math.floor(reaper.gmem_read(b + 1) or 0)
    pubn = 0
    for el = 0, NEL - 1 do
      if (reaper.gmem_read(b + 64 + el) or 0) > 0 then pubn = pubn + 1 end
    end
    if not pubname then
      say(string.format("  1. publishes   : EMPTY recipe (stamp %d).", stamp))
      say("                   Nothing will travel with a preset saved right")
      say("                   now.")
    else
      say(string.format("  1. publishes   : \"%s\" rank %d, %d element(s)  (stamp %d)",
                        pubname, pubocc, pubn, stamp))
    end
  end

  local L = Links(tr)
  local same, groups, order = 0, {}, {}
  for _, e in ipairs(L) do
    local ttr = (reaper.GetTrackGUID(reaper.GetMasterTrack(0)) == e.tg)
                and reaper.GetMasterTrack(0) or nil
    if not ttr then
      for i = 0, reaper.CountTracks(0) - 1 do
        local c = reaper.GetTrack(0, i)
        if reaper.GetTrackGUID(c) == e.tg then ttr = c; break end
      end
    end
    if ttr and reaper.GetTrackGUID(ttr) == reaper.GetTrackGUID(tr) then
      local tfx
      for _, f in ipairs(fxlist) do
        if reaper.TrackFX_GetFXGUID(tr, f) == e.fg then tfx = f; break end
      end
      if tfx then
        same = same + 1
        local occ, nm = FXOccurrence(tr, tfx)
        local key = occ .. "\t" .. nm
        local g = groups[key]
        if not g then
          g = { nm = nm, occ = occ, n = 0 }
          groups[key] = g
          order[#order + 1] = g
        end
        g.n = g.n + 1
      end
    end
  end
  say(string.format("  2. to adopt    : %d link(s) in total, %d on this track",
                    #L, same))

  local pick
  for _, g in ipairs(order) do
    if not pick or g.n > pick.n then pick = g end
  end
  local ostamp = reaper.gmem_read(b + 256) or 0
  local oname  = GetStr(b + 259, reaper.gmem_read(b + 258))
  if pick then
    say(string.format("  3. would offer : \"%s\" rank %d, %d element(s)",
                      pick.nm, pick.occ, pick.n))
  else
    say("  3. would offer : nothing (no link to a plugin on this track)")
  end
  if ostamp <= 0 then
    say("                   BUT the service wrote nothing here (stamp at zero):")
    say("                   it is out of date. Reload \"StripTease System.lua\"")
    say("                   -- stop the action, then start it again.")
  elseif oname then
    say(string.format("                   service: \"%s\" rank %d  (stamp %d)",
                      oname, math.floor(reaper.gmem_read(b + 257) or 0), ostamp))
  end

  if pubname then
    local hit, seen, legacy = nil, 0, false
    for _, fx in ipairs(fxlist) do
      if FXKey(tr, fx) == pubname then
        if seen == pubocc then hit = fx; break end
        seen = seen + 1
      end
    end

    -- Meme repli que le service : une recette capturee avant que la cle ne devienne
    -- insensible au renommage porte le nom affiche.
    if not hit then
      seen = 0
      for _, fx in ipairs(fxlist) do
        local _, dn = reaper.TrackFX_GetFXName(tr, fx, "")
        if dn:sub(1, WNAME) == pubname then
          if seen == pubocc then hit = fx; legacy = true; break end
          seen = seen + 1
        end
      end
    end

    if hit then
      local np = reaper.TrackFX_GetNumParams(tr, hit) or 0
      local n, over = 0, 0
      for el = 0, NEL - 1 do
        local p = math.floor(reaper.gmem_read(b + 64 + el) or 0)
        if p > 0 then
          if p - 1 < np then n = n + 1 else over = over + 1 end
        end
      end
      say(string.format("  4. resolution  : plugin FOUND (fx %d, %d parameters)"
                        .. " -> %d element(s) linkable", hit, np, n))
      if legacy then
        say("                   matched on the DISPLAYED name: recipe captured by an")
        say("                   older version. It works; capture it again to store")
        say("                   the original name instead.")
      end
      if over > 0 then
        say(string.format("                   %d element(s) target a parameter"
                          .. " beyond %d: ignored.", over, np))
      end
    else
      say("  4. resolution  : plugin NOT FOUND on this track.")
      say(string.format("                   looking for: \"%s\" (rank %d)", pubname, pubocc))
      say("                   found      :")
      for _, fx in ipairs(fxlist) do
        say(string.format("                     \"%s\"", FXKey(tr, fx)))
      end
      say("                   Compare character by character: the recipe targets")
      say("                   the plugin by its NAME, a single difference is")
      say("                   enough to make it fail. The names above are the")
      say("                   ORIGINAL ones: renaming an instance does not matter.")
    end
  end
  say("")
end

wish(reaper.GetMasterTrack(0), 0, "MASTER TRACK")
for i = 0, reaper.CountTracks(0) - 1 do
  local tr = reaper.GetTrack(0, i)
  local _, nm = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
  wish(tr, i + 1, (nm ~= "" and nm) or string.format("track %d", i + 1))
end

local dup = {}
for k, n in pairs(panels) do
  if n > 1 then dup[#dup + 1] = k end
end
if #dup > 0 then
  table.sort(dup)
  say("========================================================================")
  say("SEVERAL StripTease PANELS ON THE SAME TRACK: k=" ..
      table.concat(dup, ", "))
  say("")
  say("A track has only ONE CC map in gmem (16384 + k*64). Two panels on the")
  say("same track each write their own, one after the other, and the service")
  say("only sees the last one in: the links of the other panel silently stop")
  say("working. If the duplicate is not intended, delete one of them.")
  say("")
end

reaper.ClearConsole()
reaper.ShowConsoleMsg(table.concat(out, "\n") .. "\n")
