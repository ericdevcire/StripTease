-- ==========================================================================
-- StripTease Check
-- Version: 1.2.0
-- Developer: Eric Avondo
--
-- Freeware - personal use. Resale or redistribution for profit is
-- prohibited. See LICENSE.txt.
-- ==========================================================================
local NMAX  = 4
local NGATE = 2

local NS      = "StripTeaseGR"
local GRV     = 266240
local VSTRIDE = 8

-- Attached right in the header: the virtual channel is read from gmem, and the
-- report consults it track by track, well before the link-recipe section.
reaper.gmem_attach("StripTease")

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

-- Second route, the same one the service uses: a parameter whose name announces
-- a reduction readout and whose travel is in dB. It exists because a JSFX cannot
-- answer GainReduction_dB, whatever it hands REAPER's track meter through
-- ext_gr_meter.
local GR_PARAM_WORDS = { "gain reduction", "gr readout", "gr meter" }

local function GRNamed(nm)
  local low = nm:lower()
  for _, w in ipairs(GR_PARAM_WORDS) do
    if low:find(w, 1, true) then return true end
  end
  return false
end

-- Learned readout: the service confirms a less explicitly named candidate by
-- watching how it behaves during playback, then files the result per plugin type.
-- The report reads that same memory, so it states what StripTease actually reads
-- and not what the naming rule alone would suggest.
local function GRLearned(tr, fx)
  local ok, id = reaper.TrackFX_GetNamedConfigParm(tr, fx, "fx_ident")
  if not ok or id == "" then return nil end
  local v = reaper.GetExtState(NS, "grp." .. id)
  if not v or v == "" then return nil end
  local pm, mode = v:match("^(%d+)|(%a+)$")
  if not pm then return nil end
  local _, nm = reaper.TrackFX_GetParamName(tr, fx, tonumber(pm), "")
  return tonumber(pm), nm or "", mode, true
end

-- Must stay identical to DBNum in StripTease System: the report has to state
-- what the service reads, not what a different parse would suggest. What is
-- looked for is the number ATTACHED to its unit, not the first number around.
local function DBNum(s, is_gr)
  if not s or s == "" then return nil end

  s = s:gsub("\226\136\146", "-"):gsub("\226\128\147", "-")
       :gsub("\194\160", " ")
  s = s:gsub("(%d),(%d)", "%1.%2")

  if not s:find("%d") then
    return (is_gr and s:lower():find("inf")) and 0 or nil
  end

  for num, unit in s:gmatch("([%-%+]?%d+%.?%d*)%s*(%a+)") do
    if unit:lower():sub(1, 2) == "db" then return tonumber(num) end
  end

  if s:match("^%s*[%-%+]?%d+%.?%d*%s*$") then return tonumber(s) end
  return nil
end

-- Must stay identical to GRScale in StripTease System. It also returns the two
-- displayed bounds, so that the report can show the scale on which it
-- s'est prononce.
local GRKMIN, GRKMAX, GRSPANMAX = 0.05, 20, 80

local function GRScale(tr, fx, pm)
  if not reaper.TrackFX_FormatParamValueNormalized then return "unknown" end

  local _, mn, mx = reaper.TrackFX_GetParamEx(tr, fx, pm)
  if not mn or not mx or mx - mn <= 0 then return "unknown" end

  local ok0, s0 = reaper.TrackFX_FormatParamValueNormalized(tr, fx, pm, 0, "")
  local ok1, s1 = reaper.TrackFX_FormatParamValueNormalized(tr, fx, pm, 1, "")
  local okh, sh = reaper.TrackFX_FormatParamValueNormalized(tr, fx, pm, 0.5, "")
  if not ok0 or not ok1 then return "unknown" end

  local a, b = DBNum(s0), DBNum(s1)
  if not a or not b then
    local both = ((s0 or "") .. " " .. (s1 or "")):lower()
    return both:find("inf") and "unknown" or "nodb", nil, nil, s0, s1
  end

  if math.abs(a) < 0.0005 and math.abs(b - 1) < 0.0005 then return "unknown" end
  if math.abs(b - a) > GRSPANMAX then return "nodb", nil, nil, s0, s1 end

  local k = (b - a) / (mx - mn)
  local c = a - k * mn
  if math.abs(k) <= GRKMIN or math.abs(k) >= GRKMAX then
    return "nodb", nil, nil, s0, s1
  end

  local h = okh and DBNum(sh) or nil
  if h then
    local tol = math.max(0.5, 0.05 * math.abs(b - a))
    if math.abs(h - (a + b) * 0.5) > tol then
      return "nonlinear", nil, nil, s0, s1
    end
  end

  if math.abs(a) < 0.5 then c = -k * mn
  elseif math.abs(b) < 0.5 then c = -k * mx end

  return "linear", k, c, s0, s1
end

local function GRIdentity(k, c)
  return math.abs(math.abs(k) - 1) < 0.02 and math.abs(c) < 0.2
end

local function GRRead(tr, fx, pm, mode, k, c)
  if mode == "fmt" then
    local ok, s = reaper.TrackFX_GetFormattedParamValue(tr, fx, pm, "")
    return (ok and DBNum(s, true)) or 0
  end
  local v = reaper.TrackFX_GetParam(tr, fx, pm) or 0
  return k and (k * v + (c or 0)) or v
end

-- The fate of a readout with a graduated travel, as the service decides it:
-- read as is, read through a factor, read through its display, or refused.
-- Renvoie mode, k, c, verdict -- mode nil quand l'unite reste indeterminable.
local function GRJudge(tr, fx, pm)
  local verdict, k, c = GRScale(tr, fx, pm)

  if verdict == "linear" then
    if GRIdentity(k, c) then return "raw", nil, nil, verdict end
    return "raw", k, c, verdict
  end

  if verdict == "nonlinear" then return "fmt", nil, nil, verdict end
  if verdict == "nodb" then return nil, nil, nil, verdict end

  local _, mn, mx = reaper.TrackFX_GetParamEx(tr, fx, pm)
  if mn and mx and mx <= 60 and mx - mn <= 60 then
    return "raw", nil, nil, verdict
  end
  return nil, nil, nil, verdict
end

-- A readout learned before units could be checked is judged again as if newly
-- discovered: that is what the service does on load, and the report must not
-- show anything else.
local function GRLearnedJudged(tr, fx)
  local pm, nm, mode, learned = GRLearned(tr, fx)
  if not pm then return nil end
  if mode ~= "raw" then return pm, nm, mode, learned end

  local m, k, c, verdict = GRJudge(tr, fx, pm)
  if not m then return nil, nil, nil, nil, nil, nil, verdict end
  return pm, nm, m, learned, k, c, verdict
end

-- Renvoie pm, nom, mode, appris, k, c, verdict. Le verdict d'echelle voyage
-- with the rest: this is what tells the reader why a perfectly named readout is
-- not read, or why it is read through its display.
local function GRParam(tr, fx)
  local n = reaper.TrackFX_GetNumParams(tr, fx) or 0
  local pm = 0
  while pm < n do
    local ok, nm = reaper.TrackFX_GetParamName(tr, fx, pm, "")
    if ok and nm ~= "" and GRNamed(nm) then
      local _, mn, mx = reaper.TrackFX_GetParamEx(tr, fx, pm)
      if mn and mx and mx - mn > 1.5 then
        local mode, k, c, verdict = GRJudge(tr, fx, pm)
        if mode then return pm, nm, mode, false, k, c, verdict end

        -- Refused: the plugin falls back to being measured by the panel, unless
        -- another parameter has been learned.
        local lpm, lnm, lmode, llearned, lk, lc = GRLearnedJudged(tr, fx)
        if lpm then return lpm, lnm, lmode, llearned, lk, lc end
        return nil, nil, nil, nil, nil, nil, verdict
      end
    end
    pm = pm + 1
  end
  return GRLearnedJudged(tr, fx)
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
say("")
say("The dB below is what StripTease reads. The plugin's own meter should read")
say("the same: compare its peak hold with the VU's peak marker, never a moving")
say("needle with a moving needle -- the needle is deliberately slower.")
say("")

local total = 0
local readable = {}
local panels = {}

-- Every non-panel plugin, readable or not. The parameter section walks through
-- all of them: it is precisely on those that report nothing that a parameter has
-- to be looked for, the others do not need one.
local candidates = {}

local function scan(tr, k, label)
  local fxlist = EnumFX(tr, nil, {})
  if #fxlist == 0 then return end

  say(string.format("--- k=%d  %s", k, label))

  local ncomp, ngate, npanel, nmute = 0, 0, 0, 0
  for _, fx in ipairs(fxlist) do
    local _, nm = reaper.TrackFX_GetFXName(tr, fx, "")
    local db = GRof(tr, fx)
    local via, pname = nil, nil

    if IsPanel(tr, fx) then
      npanel = npanel + 1
    else

      -- A container is not a device: it reports nothing, cannot be configured,
      -- and its three service parameters have nothing to say here. Letting it
      -- through made it offered for manual setup, where there is
      -- evidemment rien a designer.
      local _, isc = reaper.TrackFX_GetNamedConfigParm(tr, fx, "container_count")
      if isc == "" then
        candidates[#candidates + 1] = { tr = tr, fx = fx, nm = nm, k = k }
      end
    end

    if db ~= nil then
      via = "native: GainReduction_dB"
    elseif not IsPanel(tr, fx) then
      local pm, mode, learned, sk, sc
      pm, pname, mode, learned, sk, sc = GRParam(tr, fx)
      if pm then
        db  = GRRead(tr, fx, pm, mode, sk, sc)

        -- What StripTease reads, and through which route. The scale is stated
        -- when it corrects something: it is the answer to "why does my VU
        -- disagree with the plugin's own meter".
        via = string.format("parameter p%d \"%s\", mode %s", pm, pname, mode)
        if sk then via = via .. string.format(", scale x%.3f", sk) end
        if sc and math.abs(sc) >= 0.05 then via = via .. string.format(" %+.1f dB", sc) end
        if learned then via = via .. ", learned" end

        local ok, disp = reaper.TrackFX_GetFormattedParamValue(tr, fx, pm, "")
        if ok and disp and disp ~= "" then
          via = via .. string.format(" -- the plugin shows \"%s\"", disp)
        end
      end
    end

    if db == nil then
      if not IsPanel(tr, fx) then nmute = nmute + 1 end
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
                        via and ("   [" .. via .. "]") or ""))
      readable[#readable + 1] = { tr = tr, fx = fx, nm = nm, k = k, label = label }
    end
  end
  if npanel > 1 then
    say(string.format("  %d StripTease panels on this track -- slots listed below",
                      npanel))
  end

  -- Virtual channel. The mask is published by the service, so it stays silent
  -- when the service is not running -- which the report already says elsewhere.
  local mask = reaper.gmem_read(GRV + k * VSTRIDE) or 0
  if mask > 0 then
    local flags = reaper.gmem_read(GRV + k * VSTRIDE + 6) or 0

    local via = (flags % 8 >= 4)
      and string.format("audio rate, through the container pins (plugin latency %d samples)",
                        reaper.gmem_read(GRV + k * VSTRIDE + 7) or 0)
      or "track meter, ~30 Hz -- attack and release are too fast to show"

    local how = (flags % 2 >= 1)
      and string.format("makeup read from the plugin: %+.1f dB",
                        reaper.gmem_read(GRV + k * VSTRIDE + 3) or 0)
      or "makeup estimated (reading may sit low on a bus compressor)"
    local est = (flags % 2 < 1)
    if flags % 4 >= 2 then how = how .. ", mono plugin: left channel only" end

    -- Mix read from the plugin: the needle then shows the reduction the
    -- compressor computes, not the fraction of it that comes out.
    if flags % 32 >= 16 then
      how = how .. string.format(", parallel mix %.0f%% (undone: the needle shows the internal reduction)",
                                 100 * (reaper.gmem_read(GRV + k * VSTRIDE + 4) or 1))
    end

    local bit = 0
    while bit < 6 do
      if mask % (2 ^ (bit + 1)) >= 2 ^ bit then
        local slot = bit < 4 and string.format("Compressor %d", bit + 1)
                              or string.format("Gate %d", bit - 3)
        say(string.format("  measured    -> %-18s by the panel (nothing to install)",
                          slot))
        say("                 " .. via)
        say("                 " .. how)

        -- An estimated makeup is an OFFSET, not a factor: it moves with the
        -- programme. No calibration catches up with it, and the VU screw would
        -- only freeze it on one piece of music.
        if est then
          say("                 that error is an offset that moves with the")
          say("                 programme -- no trim can fix it. Point at the")
          say("                 makeup parameter below to remove it outright.")
        end
      end
      bit = bit + 1
    end
  elseif npanel > 0 and nmute > 0 then
    say("  not measurable. Put the plugin in a container, with the panel LAST")
    say("  inside it or in the chain right after it (after = embeddable in MCP).")
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

say(string.format("%d device(s) report their reduction to REAPER.", total))

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
say("Run during PLAYBACK -- stopped, everything reads zero and proves nothing.")
say("TAKEN = read as the reduction.")
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
        local _, k, _, vd = GRJudge(R.tr, R.fx, p)
        verdict = "   <- TAKEN"
        if vd == "nonlinear" then
          verdict = verdict .. ", non-linear range: read from its display"
        elseif vd == "unknown" then
          verdict = verdict .. ", scale unestablished: read as dB unchecked"
        elseif k then
          verdict = verdict .. string.format(", scaled x%.3f to reach dB", k)
        end

      elseif GRNamed(pn) then
        if mn and mx and mx - mn > 1.5 then

          -- Perfect name, graduated travel, and yet refused: the unit is what
          -- is missing. Saying so saves looking elsewhere -- and the plugin is
          -- then measured by the panel, which is often the better outcome.
          local _, _, _, vd = GRJudge(R.tr, R.fx, p)
          local a, b = nil, nil
          if reaper.TrackFX_FormatParamValueNormalized then
            local _, s0 = reaper.TrackFX_FormatParamValueNormalized(R.tr, R.fx, p, 0, "")
            local _, s1 = reaper.TrackFX_FormatParamValueNormalized(R.tr, R.fx, p, 1, "")
            a, b = s0, s1
          end
          verdict = string.format(
            "   <- REFUSED: reads %s..%s, that is not decibels",
            (a and a ~= "" and a) or string.format("%.2f", mn or 0),
            (b and b ~= "" and b) or string.format("%.2f", mx or 0))
          if vd == "unknown" then
            verdict = "   <- REFUSED: range %.2f..%.2f is not a plausible dB scale"
            verdict = string.format(verdict, mn or 0, mx or 0)
          end
        else
          verdict = string.format("   <- name ok, range %.2f..%.2f too narrow", mn or 0, mx or 0)
        end
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

-- ==========================================================================
-- Why the makeup is not read
--
-- When the panel measures on its own, everything hinges on the static gain that
-- separates its two probes. The service reads it from the plugin when it can,
-- and estimates it otherwise -- and the estimate starts too low on a compressor
-- that never releases. Knowing WHICH of the two is in use is not enough: the
-- report already said "estimated" without saying what was missing.
--
-- Les regles ci-dessous doivent rester identiques a MKCore / MKMatch /
-- DBFormatted de StripTease System.
-- ==========================================================================

local function MKCore(s)
  if s:find("makeup", 1, true) then return 3 end
  if s:find("outputgain", 1, true) or s:find("outgain", 1, true)
     or s:find("gainout", 1, true) then return 2 end
  if s == "output" or s == "outputlevel" then return 1 end
  if s == "gain" then return 0 end
end

local SIDES = { "stereo", "right", "left", "side", "mid", "ch", "l", "r", "m", "s" }

local function MKMatch(nm)
  local s = (nm:lower():gsub("[^%a]", ""))
  for _, p in ipairs(SIDES) do
    if s:sub(1, #p) == p then
      local r = s:sub(#p + 1)
      local k = r ~= "" and MKCore(r)
      if k then return r, true, k end
    end
    if s:sub(-#p) == p then
      local r = s:sub(1, #s - #p)
      local k = r ~= "" and MKCore(r)
      if k then return r, true, k end
    end
  end
  local k = MKCore(s)
  if k then return s, false, k end
end

-- ==========================================================================
-- Is it even seen as a dynamics processor?
--
-- That is the first question, and the report did not ask it: a plugin the
-- service does not file among the dynamics is a candidate for nothing, and the
-- rest of the diagnosis then talks into the void. Rules identical to
-- DYN_WORDS / IsDyn de StripTease System.
-- ==========================================================================

local DYN_WORDS = {
  "comp", "pressor", "limit", "maximizer", "gate", "expander", "dynamics",
  "glue", "opto", "varimu", "variablemu", "leveler", "leveller", "stalevel",
  "1176", "cla76", "la2a", "la3a", "fairchild", "puigchild", "teletronix",
  "urei", "33609", "2254", "2264", "dbx", "stressor", "arousor", "api2500",
  "cl1b", "cl2a", "tla100", "mc77", "fatso", "vsc", "tcl2", "drawmer",
  "spliron", "ds1mk3", "mv2",
  "thebus", "xbus", "buster", "lala", "fetish",
  "kotelnikov", "molot", "mjuc", "dc8c",
  "fgred", "fggrey", "fgstress", "fg116", "fg401",
  "white2a", "black76",
}

local function WordIn(s, w)
  local i = s:find(w, 1, true)
  while i do
    local a = i > 1 and s:sub(i - 1, i - 1) or " "
    local b = s:sub(i + #w, i + #w)
    if not a:match("%a") and not b:match("%a") then return true end
    i = s:find(w, i + 1, true)
  end
  return false
end

-- Returns: recognised or not, the reason in plain words, and whether it is worth
-- offering for manual setup. That third point does not follow from the first: a
-- PERFECTLY recognised plugin can have its makeup read on the wrong parameter,
-- and that is even the most painful case since nothing complains about it.
-- Anything that looks like a dynamics processor must therefore be correctable.
local function DynWhy(tr, fx)
  local n = reaper.TrackFX_GetNumParams(tr, fx) or 0
  local thr, amt, mk, atk, rel = false, false, false, false, false
  for pm = 0, math.min(n, 1024) - 1 do
    local ok, pn = reaper.TrackFX_GetParamName(tr, fx, pm, "")
    if ok and pn ~= "" then
      local p = pn:lower()
      if p:find("threshold", 1, true) or p:find("thresh", 1, true) then thr = true end
      if WordIn(p, "ratio") or WordIn(p, "range") then amt = true end
      if p:find("attack", 1, true) then atk = true end
      if p:find("release", 1, true) or p:find("recover", 1, true) then rel = true end
      local _, _, rank = MKMatch(pn)
      if rank and rank >= 2 then mk = true end
    end
  end

  local low = select(2, reaper.TrackFX_GetFXName(tr, fx, "")):lower():gsub("[^%a%d]", "")
  for _, w in ipairs(DYN_WORDS) do
    if low:find(w, 1, true) then return true, "name contains '" .. w .. "'", true end
  end

  if thr and amt then return true, "threshold + ratio", true end
  if thr and mk then return true, "threshold + makeup", true end
  if thr and atk and rel then return true, "threshold + attack + release", true end

  if not thr then
    return false, "no threshold, and the name says nothing", mk
  end
  return false, "threshold alone: no ratio, no explicit makeup, no attack+release", true
end

-- Must stay identical to MKFmt in StripTease System. The second return value
-- says why it was refused, so the report can name the reason.
local MKMAX = 40

local function MKdb(tr, fx, p)
  local ok, s = reaper.TrackFX_GetFormattedParamValue(tr, fx, p, "")
  if not ok or not s or s == "" then return nil, "shows nothing" end

  local v = tonumber(s:match("%-?%d+%.?%d*") or "")
  if not v then return nil, "shows no number" end

  if not s:lower():find("db", 1, true) then
    if not s:match("^%s*[%-%+]?%d+%.?%d*%s*$") then
      return nil, "shows a unit that is not dB"
    end

    local nz = reaper.TrackFX_GetParamNormalized(tr, fx, p)
    if nz then
      if math.abs(nz - v) < 0.0005 then
        return nil, "shows its normalized value, not a reading"
      end
      if math.abs(nz * 100 - v) < 0.05 then
        return nil, "reads 0..100 like a knob position, not dB"
      end
    end
  end

  if v < -MKMAX or v > MKMAX then
    return nil, string.format("%+.1f is past %d dB, too much for a makeup", v, MKMAX)
  end
  return v
end

-- Must stay identical to MKScale in StripTease System. It also returns the two
-- displayed bounds, so the report can show the scale that was refused.
local function MKScale(tr, fx, pm)
  if not reaper.TrackFX_FormatParamValueNormalized then return true end

  local ok0, s0 = reaper.TrackFX_FormatParamValueNormalized(tr, fx, pm, 0, "")
  local ok1, s1 = reaper.TrackFX_FormatParamValueNormalized(tr, fx, pm, 1, "")
  if not ok0 or not ok1 then return true end

  local a = tonumber((s0 or ""):match("%-?%d+%.?%d*") or "")
  local b = tonumber((s1 or ""):match("%-?%d+%.?%d*") or "")
  if not a or not b then return true end
  if a > b then a, b = b, a end

  return (b <= MKMAX and (b - a) <= 60), a, b
end

say("")
say("========================================================================")
say("SEEN AS A COMPRESSOR? AND WHICH MAKEUP?")
say("")
say("dynamics = filed as a compressor or gate; otherwise it is a candidate for")
say("nothing. USED = the parameter read as the makeup, which the panel takes")
say("off the gap between its two probes. FITTED = pointed at by hand.")
say("")
say("A needle sitting high and never coming down means the makeup was read")
say("from a knob graduated like the hardware, not in dB. Answer the question")
say("at the end of this report and clear the makeup field: the panel then")
say("measures the static gain instead of believing the number.")
say("")

-- Identity of the plugin TYPE: a learned setting is filed under it, so every
-- instance of the same plugin benefits from it.
local function Ident(tr, fx)
  local ok, id = reaper.TrackFX_GetNamedConfigParm(tr, fx, "fx_ident")
  if ok and id ~= "" then return id end
end

local unfit = {}

for _, R in ipairs(candidates) do
  local np   = reaper.TrackFX_GetNumParams(R.tr, R.fx) or 0
  local cand = {}
  local used = false

  say(string.format("--- k=%d  %s", R.k, R.nm))

  local id   = Ident(R.tr, R.fx)
  local fit  = id and reaper.GetExtState(NS, "fit." .. id) or ""
  local dyn, worth = true, true

  if fit ~= "" then
    say(string.format("    FITTED by hand: %s", fit))
  else
    local why
    dyn, why, worth = DynWhy(R.tr, R.fx)
    say(string.format("    dynamics: %-3s  %s", dyn and "YES" or "NO", why))
  end

  for p = 0, math.min(np, 1024) - 1 do
    local _, pn = reaper.TrackFX_GetParamName(R.tr, R.fx, p, "")
    local c, sd, rank = MKMatch(pn)
    if c then
      local _, pv = reaper.TrackFX_GetFormattedParamValue(R.tr, R.fx, p, "")
      local val, why = MKdb(R.tr, R.fx, p)
      local scale, lo, hi = MKScale(R.tr, R.fx, p)
      local verdict

      if not scale then
        val = nil
        verdict = string.format("<- NOT READABLE: knob graduated %.0f..%.0f, not a dB scale", lo, hi)
      elseif val then
        verdict = string.format("<- dB read: %+.1f", val)
      else
        local _, mn, mx = reaper.TrackFX_GetParamEx(R.tr, R.fx, p)
        mn, mx = mn or 0, mx or 0
        if mx - mn > 1.5 and mx <= MKMAX then
          val = reaper.TrackFX_GetParam(R.tr, R.fx, p) or 0
          verdict = string.format("<- raw read: %+.1f", val)
        else
          verdict = string.format("<- NOT READABLE: %s, and range %.2f..%.2f is no use raw",
                                  why or "no dB", mn, mx)
        end
      end

      cand[#cand + 1] = { p = p, nm = pn, pv = pv, core = c, side = sd,
                          rank = rank, val = val, verdict = verdict,
                          i = #cand }
    end
  end

  if #cand > 0 then
    -- Same choice as the service: the most explicit name wins, the order of the
    -- list breaks ties, and it walks down to the first readable one.
    local order = {}
    for _, c in ipairs(cand) do order[#order + 1] = c end
    table.sort(order, function(a, b)
      if a.rank ~= b.rank then return a.rank > b.rank end
      return a.i < b.i
    end)

    local win, twin = nil, nil
    for _, c in ipairs(order) do
      if c.val then win = c; break end
    end
    if win and win.side then
      for _, c in ipairs(order) do
        if c ~= win and c.side and c.core == win.core and c.rank == win.rank then
          twin = c
          break
        end
      end
    end

    for _, c in ipairs(cand) do
      if c == win then
        c.verdict = c.verdict .. "  <== USED"
      elseif c == twin then
        if c.val and win.val and math.abs(c.val - win.val) > 0.5 then
          c.verdict = c.verdict .. string.format(", DISAGREES with p%d by %.1f dB -> back to the estimate",
                                                 win.p, math.abs(c.val - win.val))
        else
          c.verdict = c.verdict .. string.format(", pairs with p%d", win.p)
        end
      else
        c.verdict = c.verdict .. ", not used (outranked)"
      end
      say(string.format("    p%-4d %-30s %-12s %s", c.p, c.nm:sub(1, 30), c.pv, c.verdict))
    end
    used = win ~= nil
  else
    say("    no parameter that looks like a makeup: the static gain will be estimated.")
  end

  -- Three ways to fail, and the third is the worst: not being recognised, being
  -- recognised with no makeup readable at all, or -- with nothing to complain
  -- about it -- having the makeup read on the wrong parameter. Anything that
  -- looks like a dynamics processor can therefore be offered, including what
  -- seems to work, and including what is already set, to correct or clear it.
  --
  -- An EQ or a reverb has neither threshold nor makeup and does not clutter the
  -- question qu'on va poser.
  if id and (fit ~= "" or worth) then
    unfit[#unfit + 1] = R
    say(string.format("    -> fit this by hand: answer #%d when this script asks.", #unfit))
  end

  say("")
end

local NS      = "StripTeaseGR"
local NEL     = 100
local WSH     = 270336
local WSTRIDE = 512
local WNAME   = 60

-- Panel directory, published by the service. The report reads it instead of
-- redoing the slot assignment on its own side: it is the same table the JSFX
-- looks itself up in, so what it shows is what the panel sees.
local PAN     = 131072
local PSTRIDE = 32
local NPAN    = 15

reaper.gmem_attach("StripTease")

-- Must stay identical to FXKey in StripTease System: it is the key the service
-- matches recipes on, and this diagnosis exists precisely to explain why a
-- recipe does not find its target. 'fx_name' is the original name, immune to the
-- instance being renamed.
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

local function Links(tr, ord)
  local t = {}
  local g = reaper.GetTrackGUID(tr)
  local key = (ord or 0) == 0 and ("link." .. g) or ("link." .. g .. "." .. ord)
  local ok, v = reaper.GetProjExtState(0, NS, key)
  if ok ~= 1 or not v or v == "" then return t end
  for line in v:gmatch("[^\n]+") do
    local el, tg, fg, pid = line:match("^(%d+)\t([^\t]*)\t([^\t]*)\t(.*)$")
    if el then t[#t + 1] = { el = tonumber(el), tg = tg, fg = fg, pid = pid } end
  end
  return t
end

-- The link-recipe diagnosis has nothing to do with gain reduction and makes the
-- report that much longer. It stays written and working: setting this flag to
-- true puts it back into the report, with no other change.
local SHOW_LINKS = false

if SHOW_LINKS then
  say("")
  say("========================================================================")
  say("PRESET RECIPE: where the chain breaks")
  say("")
end

local function wish(tr, k, ord, slot, label)
  local fxlist = EnumFX(tr, nil, {})

  say(string.format("--- k=%d  panel %d  slot=%d  %s", k, ord + 1, slot, label))
  local b = WSH + slot * WSTRIDE

  local stamp = reaper.gmem_read(b) or 0
  local pubname, pubocc, pubn
  if stamp <= 0 then
    say("  1. publishes   : NOTHING -- stamp at zero.")
    say("                   The panel never wrote here. Either it is out of")
    say("                   date (reload the .jsfx-inc), or it does not resolve")
    say("                   to slot " .. slot .. " -- see the panel directory above.")
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

  local L = Links(tr, ord)
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

    -- Same fallback as the service: a recipe captured before the key became
    -- immune to renaming carries the displayed name.
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

-- One report per panel: each has its own slot, recipe and link table.
local function wishtrack(tr, k, label)
  local b = PAN + k * PSTRIDE
  local n = math.floor(reaper.gmem_read(b) or 0)
  if n <= 0 then
    -- The service is not running, or has not rescanned yet. The first panel of a
    -- track sits on its track's slot in any case.
    for _, fx in ipairs(EnumFX(tr, nil, {})) do
      if IsPanel(tr, fx) then wish(tr, k, 0, k, label); return end
    end
    return
  end
  for j = 0, math.min(n, NPAN) - 1 do
    wish(tr, k, j, math.floor(reaper.gmem_read(b + 2 + j * 2) or k), label)
  end
end

if SHOW_LINKS then
  wishtrack(reaper.GetMasterTrack(0), 0, "MASTER TRACK")
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local _, nm = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    wishtrack(tr, i + 1, (nm ~= "" and nm) or string.format("track %d", i + 1))
  end
end

-- Several panels on one track: the service gives each of them a slot. The report
-- shows the assignment, which is the only thing to check -- a panel that does not
-- find itself there falls back to its track's slot and then shares the first
-- panel's cells.
local multi = {}
for k, n in pairs(panels) do
  if n > 1 then multi[#multi + 1] = k end
end
if #multi > 0 then
  table.sort(multi)
  say("========================================================================")
  say("PANEL DIRECTORY (tracks carrying several panels)")
  say("")
  for _, k in ipairs(multi) do
    local b = PAN + k * PSTRIDE
    local n = math.floor(reaper.gmem_read(b) or 0)
    if n <= 0 then
      say(string.format("  k=%-4d %d panels, but the service announces none:",
                        k, panels[k]))
      say("         they all share the track slot, and the last one to write")
      say("         wins. Start \"StripTease System.lua\".")
    else
      local t = {}
      for j = 0, math.min(n, NPAN) - 1 do
        t[#t + 1] = string.format("pos %d -> slot %d",
                        math.floor(reaper.gmem_read(b + 1 + j * 2) or 0) - 1,
                        math.floor(reaper.gmem_read(b + 2 + j * 2) or 0))
      end
      say(string.format("  k=%-4d %d panels: %s", k, n, table.concat(t, ", ")))
      if panels[k] > n then
        say(string.format("         %d more than the directory can hold (%d):"
                          .. " they fall back to the track slot.",
                          panels[k] - n, NPAN))
      end
    end
  end
  say("")
end

reaper.ClearConsole()
reaper.ShowConsoleMsg(table.concat(out, "\n") .. "\n")

-- ==========================================================================
-- Manual setup
--
-- When a plugin escapes the rules, the script is not the thing to edit: the
-- installed copy is regenerated at every version, and a correction written into
-- it would be lost at the first update. What gets corrected is the KNOWLEDGE.
-- The setting is filed per plugin type in the persistent ExtState: every
-- instance benefits from it, in every project, and it survives StripTease
-- updates as well as REAPER ones.
--
-- Nothing is filed before the user has seen the parameter list and confirmed the
-- numbers: guessing on its own is precisely what failed here.
-- ==========================================================================

if #unfit == 0 then return end

local msg = string.format(
  "%d plugin(s) here can be pointed at by hand: not recognised as dynamics, " ..
  "or with no readable makeup -- or simply read from the wrong parameter, " ..
  "which nothing can complain about on its own.\n\n" ..
  "The report marks them #1..%d.\n\n" ..
  "Fit one now?", #unfit, #unfit)

if reaper.MB(msg, "StripTease Check", 4) ~= 6 then return end

-- A single candidate: nothing to ask. That is the common case, and one more
-- dialog would only add one more way to get it wrong.
local R = unfit[1]

if #unfit > 1 then
  local ok, pick = reaper.GetUserInputs("StripTease -- which plugin?", 1,
                                        "Number in the report (1.." .. #unfit .. ")", "1")
  if not ok then return end

  -- Only the digits are taken: depending on the version, REAPER can return the
  -- field followed by a separator, and tonumber would fail on the whole string.
  R = unfit[tonumber((pick or ""):match("%d+") or "") or 0]
  if not R then
    reaper.MB("No plugin under that number -- the box returned \"" ..
              tostring(pick) .. "\".", "StripTease Check", 0)
    return
  end
end

local id = Ident(R.tr, R.fx)
if not id then
  reaper.MB("This plugin has no stable identity (fx_ident); nothing could be " ..
            "stored for it.", "StripTease Check", 0)
  return
end

-- The complete list, values included: it is what the numbers are chosen from,
-- and a dead travel or a silent display shows up on it at first glance.
local np = reaper.TrackFX_GetNumParams(R.tr, R.fx) or 0
local lst = { "", "========================================================================",
              "PARAMETERS OF " .. R.nm, "" }

for p = 0, math.min(np, 1024) - 1 do
  local _, pn = reaper.TrackFX_GetParamName(R.tr, R.fx, p, "")
  local _, pv = reaper.TrackFX_GetFormattedParamValue(R.tr, R.fx, p, "")
  local _, mn, mx = reaper.TrackFX_GetParamEx(R.tr, R.fx, p)
  local db = MKdb(R.tr, R.fx, p)
  lst[#lst + 1] = string.format("    p%-4d %-34s %-14s range %.2f..%.2f%s",
                                p, pn:sub(1, 34), pv, mn or 0, mx or 0,
                                db and string.format("   -> reads %+.1f dB", db) or "")
end

lst[#lst + 1] = ""
lst[#lst + 1] = "Makeup = the OUTPUT gain, reading dB above. Empty = estimate it."
lst[#lst + 1] = "Other side = separate L/R. Mix = parallel blend. Auto-gain = switch."
lst[#lst + 1] = ""
reaper.ShowConsoleMsg(table.concat(lst, "\n") .. "\n")

-- Starting proposal: what the rules would have given. Often right about the
-- makeup, even where they failed at recognition.
local pmk, pmk2, pmode = "-", "-", "-"
local best = nil
for p = 0, math.min(np, 1024) - 1 do
  local _, pn = reaper.TrackFX_GetParamName(R.tr, R.fx, p, "")
  local c, sd, rank = MKMatch(pn)
  if c and MKdb(R.tr, R.fx, p) and (not best or rank > best.rank) then
    best = { p = p, core = c, side = sd, rank = rank }
  end
end
if best then
  pmk, pmode = tostring(best.p), "fmt"
  if best.side then
    for p = 0, math.min(np, 1024) - 1 do
      local _, pn = reaper.TrackFX_GetParamName(R.tr, R.fx, p, "")
      local c, sd, rank = MKMatch(pn)
      if p ~= best.p and c and sd and c == best.core and rank == best.rank then
        pmk2 = tostring(p)
        break
      end
    end
  end
end

-- Short labels with no exotic punctuation: the captions travel as CSV, and
-- whatever slips in there comes back in the answers.
local ok2, res = reaper.GetUserInputs("StripTease -- fit " .. R.nm:sub(1, 30), 5,
  "Compressor or gate? y/n,Makeup param no.,Other side no.,Parallel mix no.,Auto-gain switch no.,extrawidth=120",
  table.concat({ "y", pmk, pmk2, "-", "-" }, ","))
if not ok2 then return end

local fld = {}
for w in (res .. ","):gmatch("([^,]*),") do fld[#fld + 1] = w end

-- Empty, a dash, or anything with no digit in it means "no parameter": the user
-- is not going to be blamed for clearing the field instead of typing a dash into
-- it.
local function Cell(s)
  local n = (s or ""):match("%d+")
  return n or "-"
end

local dyn = (fld[1] or ""):lower():sub(1, 1) == "y" and "1" or "0"
local mk  = Cell(fld[2])

-- The reading mode follows the parameter that was named, it is not asked for: if
-- its display gives dB it will be read there, otherwise its raw value is read.
local mode = "-"
if mk ~= "-" then
  mode = MKdb(R.tr, R.fx, tonumber(mk)) and "fmt" or "raw"
end

local payload = table.concat({ dyn, mk, mode, Cell(fld[3]), Cell(fld[4]), "-",
                               Cell(fld[5]) }, "|")

reaper.SetExtState(NS, "fit." .. id, payload, true)

-- Read back immediately: the write can fail on a plugin identity the ExtState
-- will not accept as a key, and a setting believed to be in place while nothing
-- was actually filed would be the worst outcome -- one would look elsewhere.
local back = reaper.GetExtState(NS, "fit." .. id)

if back ~= payload then
  reaper.MB("The setting could NOT be stored.\n\nKey: " .. id ..
            "\n\nNothing has changed; the rules still apply to this plugin.",
            "StripTease Check", 0)
  return
end

-- The service reads this counter back on every frame: it drops its caches and
-- runs a fresh sweep without having to be restarted.
reaper.SetExtState(NS, "fitgen", tostring(reaper.time_precise()), false)

local what = mk == "-"
  and "makeup: ESTIMATED (no parameter read)"
  or  string.format("makeup: parameter p%s, read as %s", mk, mode)

reaper.MB(string.format(
  "Fitted.\n\n%s\n%s\n\nStored per plugin type, so every instance in every " ..
  "project follows, and it survives StripTease updates.\n\nThe service has " ..
  "picked it up already -- the needle should settle within a second. Run " ..
  "this report again to see it listed as FITTED.",
  R.nm, what), "StripTease Check", 0)

reaper.ShowConsoleMsg(string.format("\nFITTED  %s\n        %s\n", id, payload))
