-- ==========================================================================
-- StripTease System
-- Version: 1.2.0
-- Developer: Eric Avondo
--
-- Freeware - personal use. Resale or redistribution for profit is
-- prohibited. See LICENSE.txt.
-- ==========================================================================
local NS     = "StripTeaseGR"
local GR     = 4096
local STRIDE = 8
local NMAX   = 4
local NGATE  = 2
local MAXTRK = 255

-- LINKED and WISH are addressed by panel slot, not by track: two panels on the
-- same track would otherwise write into the same cells. The stride must stay
-- >= NEL, or one panel's elements write over the next panel's.
-- See WORK/packaging/tools/gmem_map.json.
local KSTRIDE = 128
local NEL     = 100

-- Panel slots. Slots 0..MAXTRK are the tracks' own: the first panel of a track
-- keeps the address it had back when there could only be one, so a project made
-- before this finds its links without republishing anything, and a lone panel
-- stays reachable even before the first rescan. Slots 256..511 are the reserve
-- the following panels are housed in.
local NSLOT   = 512

-- Panel directory, published by the service and read by the JSFX to learn its
-- own slot: per track, the number of panels then NPAN pairs
-- (position in the chain + 1, slot).
local PAN     = 131072
local PSTRIDE = 32
local NPAN    = 15

local REQ    = 49152
local RSP    = 49160
local TIPMAX = 23

local LRN  = 12288

local TL   = 61440

local LNK  = 65536

local WSH     = 270336
local WSTRIDE = 512
local WNAME   = 60

local SVC = 49240

-- Virtual measurement channel: the panel acts as the input probe, the track
-- meter as the output probe. See ScanVirtual and the panel's measurement block.
local GRV     = 266240
local VSTRIDE = 8
local VNONE   = 9999

-- Matching name of an FX in the link recipes. TrackFX_GetFXName returns the
-- *displayed* name: as soon as the user renames the instance, it returns the
-- custom name and the recipe no longer finds its target. The 'fx_name' config
-- key returns the original name, in the exact format TrackFX_GetFXName gives on
-- an unrenamed instance ("AU: UADx 610-A Preamp and EQ (...)"): recipes already
-- captured, including those embedded in the FX chains that ship with StripTease,
-- therefore keep the same key. Falls back to the displayed name on a REAPER that
-- does not expose the key.
local function FXKey(tr, fx)
  local ok, nm = reaper.TrackFX_GetNamedConfigParm(tr, fx, "fx_name")
  if not ok or nm == "" then
    local _, dn = reaper.TrackFX_GetFXName(tr, fx, "")
    nm = dn
  end
  return nm:sub(1, WNAME)
end

-- The old key: the displayed name. Serves as a matching fallback, and covers the
-- two ways an earlier recipe can differ -- an instance that was already renamed
-- when it was captured, and any format discrepancy between 'fx_name' and
-- TrackFX_GetFXName on a given plugin type. The previous behaviour therefore
-- stays reachable in every circumstance.
local function FXAltKey(tr, fx)
  local _, nm = reaper.TrackFX_GetFXName(tr, fx, "")
  return nm:sub(1, WNAME)
end

local DEAD = 0.0004
local LEARN_TIMEOUT = 20

-- How often the panel is checked for survival during a learn (in frames of the
-- defer loop, ~30/s). Close enough to close the ghost-element window, spaced
-- enough not to enumerate the FX on every frame.
local PANEL_CHECK_EVERY = 15

local RESCAN_EVERY = 60

reaper.gmem_attach("StripTease")

local sources = {}
local by_key  = {}
local panels  = {}

-- panel slot -> { tr, k, fx, ord }. Used by the handshakes, which only carry the
-- requester's slot.
local slots   = {}

-- Who held a slot at the previous rescan. A reserve slot changes hands as soon as
-- a panel appears on a higher track, and the tracking state left by the previous
-- holder would then push a value onto the target of a link barely established,
-- without anyone having touched anything.
local owned   = {}

local dlinks  = {}
local dstate  = {}
local learn   = nil
local sws_warned = false
local served  = nil

local tick    = 0
local rescan  = 0
local pstate  = nil
local force_rescan = true

local prev    = {}

local ecache  = {}
local fgcache = {}
local ncache  = {}
local tcache  = {}

local function ResetCaches()
  ecache, fgcache, ncache, tcache = {}, {}, {}, {}
end

-- The decibel number of a label, and that one only.
--
-- Taking the first number around only works on "-3.2 dB". A readout that
-- introduces itself -- "GR: -3.2 dB" -- or that gives the ratio before the
-- reduction -- "4.0:1  -6.0 dB" -- returned the wrong number, and it was the
-- whole VU that went crooked with nothing to signal it. What is looked for is
-- therefore the number ATTACHED to its unit.
--
-- The first dB token wins. On a stereo display -- "-3.2 dB L / -6.0 dB R" --
-- taking the larger one would be tempting, but a label that restates its
-- threshold -- "-3.2 dB (thr -20 dB)" -- would lose everything to it: the first
-- one is the only choice that never picks the wrong field.
--
-- With no unit anywhere, only the bare number is accepted: a label that mixes
-- digits with something else cannot be guessed. And for a reduction readout,
-- "-inf" means zero reduction, not zero for the value read.
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

-- Reading a readout kept by the second route. "raw": the parameter is graduated
-- in dB and its value is read as is -- up to a factor, when its graduation is
-- not the one it was taken for (see GRScale). "fmt": it is normalised 0..1 and
-- only gives its dB on screen, so they have to be read back from the label.
--
-- An unreadable label returns the last value read rather than zero: Publish
-- holds the maximum of two frames, and a single frame at zero would make the
-- needle flick all the way down.
local function GRValue(tr, fx, e)
  if e.mode == "fmt" then
    local ok, s = reaper.TrackFX_GetFormattedParamValue(tr, fx, e.pm, "")
    local v = ok and DBNum(s, true) or nil
    if v then e.last = v end
    return v or e.last or 0
  end

  local v = reaper.TrackFX_GetParam(tr, fx, e.pm) or 0
  return e.k and (e.k * v + (e.c or 0)) or v
end

-- Only the cells we have a source for are written. The others are left to
-- whoever feeds them -- the StripTease GR JSFX, or the panel through the virtual
-- channel -- for a compressor that does not report its gain reduction: writing 0
-- into them on every frame would erase that measurement. A `false` cell is
-- exactly one of those: it takes up a number without the service writing to it.
-- Cells freed when a source disappears are zeroed once, by ClaimGR.
local function Publish(tr, b, list, n, off, kbase, gp)
  for j = 1, n do
    local key = kbase + j
    if list[j] then
      local db
      local e = gp and gp[list[j]]
      if e then

        -- Absolute value and ceiling: depending on the plugin, a reduction
        -- readout counts downwards (-6) or upwards (6), and the StripTease VU
        -- works in positive reduction on a bounded scale.
        db = math.min(60, math.abs(GRValue(tr, list[j], e)))
      else
        local ok, v = reaper.TrackFX_GetNamedConfigParm(tr, list[j], "GainReduction_dB")
        db = math.abs(ok and tonumber(v) or 0)
      end
      local pv = prev[key] or 0
      prev[key] = db
      reaper.gmem_write(b + off + j, db > pv and db or pv)
    else
      prev[key] = nil
    end
  end
end

-- gmem[GR + k*STRIDE + 1] tells the StripTease GR JSFX which cells the service
-- feeds: it gives way on those, otherwise the two fight over the same cell and
-- the VU alternates between two values. That claim must reflect the current
-- state and not a leftover from the previous track or project -- gmem survives a
-- project change -- hence the reset on every rescan.
local claim = {}

local function ClaimGR(k, nc, ng)
  local b = GR + k * STRIDE
  local p = claim[k]

  -- First visit: what gmem holds is unknown, so everything we do not claim is
  -- cleared. After that, only the cells we stop claiming are zeroed: without that
  -- they would keep their last value and, with the track's stamp still moving,
  -- the panel would display a frozen GR.
  local pc = p and (p % 16) or NMAX
  local pg = p and math.floor(p / 16) or NGATE

  for j = nc + 1, pc do reaper.gmem_write(b + 1 + j, 0) end
  for j = ng + 1, pg do reaper.gmem_write(b + 5 + j, 0) end

  claim[k] = nc + ng * 16
  reaper.gmem_write(b + 1, claim[k])
end

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

local function FXList(tr, trg)
  local l = ecache[trg]
  if not l then
    l = EnumFX(tr, nil, {})

    -- Record input FX (monitoring FX on the master track): they are addressed
    -- through [0x1000000, 0x1000000+n) and TrackFX_GetCount does not count them.
    -- GetTouchedOrFocusedFX, on the other hand, can return one: without this
    -- enumeration, a Direct Link made on one of those parameters works until the
    -- project is reloaded, then disappears silently for want of being found
    -- again by FXByGUID.
    local nrec = reaper.TrackFX_GetRecCount and reaper.TrackFX_GetRecCount(tr) or 0
    for i = 0, nrec - 1 do
      local idx = 0x1000000 + i
      l[#l + 1] = idx
      local _, isc = reaper.TrackFX_GetNamedConfigParm(tr, idx, "container_count")
      if isc ~= "" then EnumFX(tr, idx, l) end
    end

    ecache[trg] = l
  end
  return l
end

local function FXKeyC(tr, trg, fx)
  local key = trg .. "|" .. fx
  local nm  = ncache[key]
  if not nm then
    nm = FXKey(tr, fx)
    ncache[key] = nm
  end
  return nm
end

local function FXByGUID(tr, trg, g)
  local m = fgcache[trg]
  if not m then
    m = {}
    for _, fx in ipairs(FXList(tr, trg)) do
      m[reaper.TrackFX_GetFXGUID(tr, fx)] = fx
    end
    fgcache[trg] = m
  end
  return m[g]
end

local function IsGRSource(tr, fx)
  local ok, v = reaper.TrackFX_GetNamedConfigParm(tr, fx, "GainReduction_dB")
  return ok and v ~= "" and tonumber(v) ~= nil
end

local GATE_WORDS = { "gate", "expander", "pro-g", "pro g" }

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

-- Output level of the chain, in dB, with the fader taken out -- REAPER's meter
-- is post-fader. Published for the VU's Output level mode, it also serves as the
-- output probe of the virtual channel and as a load reference when confirming a
-- candidate readout. Returns nil when REAPER no longer gives anything usable
-- (muted track, fader at -inf): there is nothing to compensate then, and an
-- invented value would be worth less than no value at all.
local function DB(pk)
  return pk > 0.0000001 and math.log(pk) * 8.6858896 or -144
end

-- The two channels separately. The virtual channel compares channel by channel:
-- a mono compressor on a stereo track only processes channel 1 and lets the
-- other through untouched, so a comparison on the louder of the two would follow
-- the uncompressed channel and would not even depend on the threshold any more.
local function TrackLevelsDB(tr)
  local vol  = reaper.GetMediaTrackInfo_Value(tr, "D_VOL")  or 1
  local mute = reaper.GetMediaTrackInfo_Value(tr, "B_MUTE") or 0
  if mute >= 0.5 or vol <= 0.000001 then return nil end

  local l = (reaper.Track_GetPeakInfo(tr, 0) or 0) / vol
  local r = (reaper.Track_GetPeakInfo(tr, 1) or 0) / vol
  return DB(l), DB(r)
end

local function TrackLevelDB(tr)
  local l, r = TrackLevelsDB(tr)
  if not l then return nil end
  return r > l and r or l
end

-- Second route for reading gain reduction, for the plugins REAPER does not
-- query.
--
-- GainReduction_dB is only served by the class that hosts the VSTs: through
-- REAPER's VST2 extension, and through the VST3 IGainReductionInfo interface. A
-- JSFX never goes that way. Its ext_gr_meter variable does feed the mixer's
-- track meter, but through a path internal to the jsfx module that no script
-- function exposes: what REAPER displays there, it lends to nobody.
--
-- The only channel a JSFX shares with a script is a parameter. So, failing an
-- answer to GainReduction_dB, a parameter that announces a reduction readout is
-- accepted. An explicit name and a travel in dB are enough to keep it with no
-- further examination. Below that level of evidence -- a less clear name, or a
-- readout normalised 0..1 that only gives its dB on screen, which is the most
-- common case -- the name proves nothing any more, and it is how the parameter
-- behaves during playback that decides (VConfirm).
local GR_PARAM_WORDS = { "gain reduction", "gr readout", "gr meter" }

-- Weak words. A name alone no longer tells them apart from a control ("Gain
-- reduction" is not something you name by accident, "Reduction" is), and they
-- most often apply to a readout normalised 0..1 that the old dB-travel rule
-- rejected. They open a lead, not a right: the candidate still has to behave
-- like a reduction readout (see VConfirm).
local GR_PARAM_WEAK = { "gain redux", "gr out", "redux", "reduction", "compression", "gr" }

-- Whole-word search: "gr" must not be recognised inside "Program", nor
-- "reduction" in a label where it qualifies something other than the signal.
local function WordIn(low, w)
  return low:find("%f[%w]" .. w:gsub("%-", "%%-") .. "%f[%W]") ~= nil
end

-- A readout can publish its dB in the open (travel in dB, value readable as is)
-- or normalised 0..1, giving them only on screen. The second case is the most
-- common in VST3 and AU, and it is the one the old rule walked straight past.
local function DBFormatted(tr, fx, pm)
  local ok, s = reaper.TrackFX_GetFormattedParamValue(tr, fx, pm, "")
  if not ok or not s or s == "" then return false end
  return s:lower():find("db", 1, true) ~= nil and s:find("%-?%d") ~= nil
end

-- A readout is not driven: no automation, no link, no modulation. This test
-- rules out from the start a control the user moves themselves, which would
-- otherwise pass the behavioural confirmation as soon as it had been automated
-- to follow the level.
local function Driven(tr, fx, pm)
  local pre = "param." .. pm .. "."
  local _, a = reaper.TrackFX_GetNamedConfigParm(tr, fx, pre .. "plink.active")
  local _, m = reaper.TrackFX_GetNamedConfigParm(tr, fx, pre .. "mod.active")
  if tonumber(a or "") == 1 or tonumber(m or "") == 1 then return true end
  return reaper.GetFXEnvelope(tr, fx, pm, false) ~= nil
end

-- The unit of a readout, established rather than assumed.
--
-- The old rule said: travel greater than 1.5, therefore graduated in decibels.
-- It checked nothing. A readout graduated 0 to 100 -- the percentage of its own
-- meter's travel, which many plugins expose -- passed that test and went into
-- the VU as a hundred decibels. That is where the discrepancy from one plugin to
-- the next came from, the one that used to be caught up on the screw.
--
-- REAPER can format a value without touching the parameter: the plugin is asked
-- what it would display at both ends and at the middle of its travel, and the
-- scale reads off at once. It is the MKScale procedure, applied this time to the
-- reduction readout.
--
-- Four verdicts:
--   "linear"    : k and c give the dB from the raw value.
--   "nonlinear" : the dB are indeed there, but not proportional to the travel --
--                 the display will be read rather than the value.
--   "nodb"      : the labels are readable and carry no decibels. What is not
--                 understood is not converted.
--   "unknown"   : no formatter, or a plugin that returns its normalised bounds
--                 as they are. Nothing is concluded.
--
-- The midpoint only proves the dB are linear along the normalised travel; a
-- non-linear front-panel graduation gives itself away during playback instead
-- (see VConfirm), where the raw value and what it displays are seen together.
local GRKMIN, GRKMAX, GRSPANMAX = 0.05, 20, 80

local function GRScale(tr, fx, pm)
  if not reaper.TrackFX_FormatParamValueNormalized then return "unknown" end

  local _, mn, mx = reaper.TrackFX_GetParamEx(tr, fx, pm)
  if not mn or not mx or mx - mn <= 0 then return "unknown" end

  local ok0, s0 = reaper.TrackFX_FormatParamValueNormalized(tr, fx, pm, 0, "")
  local ok1, s1 = reaper.TrackFX_FormatParamValueNormalized(tr, fx, pm, 1, "")
  local okh, sh = reaper.TrackFX_FormatParamValueNormalized(tr, fx, pm, 0.5, "")
  if not ok0 or not ok1 then return "unknown" end

  -- An end at infinity is a correct reading, but no straight line passes through
  -- infinity: this abstains rather than refuses.
  local a, b = DBNum(s0), DBNum(s1)
  if not a or not b then
    local both = ((s0 or "") .. " " .. (s1 or "")):lower()
    return both:find("inf") and "unknown" or "nodb"
  end

  -- The plugin does not format: REAPER returned the normalised value itself.
  if math.abs(a) < 0.0005 and math.abs(b - 1) < 0.0005 then return "unknown" end

  if math.abs(b - a) > GRSPANMAX then return "nodb" end

  local k = (b - a) / (mx - mn)
  local c = a - k * mn
  if math.abs(k) <= GRKMIN or math.abs(k) >= GRKMAX then return "nodb" end

  local h = okh and DBNum(sh) or nil
  if h then
    local tol = math.max(0.5, 0.05 * math.abs(b - a))
    if math.abs(h - (a + b) * 0.5) > tol then return "nonlinear" end
  end

  -- Rest must land exactly on zero: the whole VU reading starts from there, and
  -- a needle resting two tenths off zero is visible.
  if math.abs(a) < 0.5 then c = -k * mn
  elseif math.abs(b) < 0.5 then c = -k * mx end

  return "linear", k, c
end

-- A scale that corrects nothing -- up to the sign, since Publish takes the
-- absolute value -- is filed as before: no arithmetic, no field, an unchanged
-- path for every readout that was already right.
local function GRIdentity(k, c)
  return math.abs(math.abs(k) - 1) < 0.02 and math.abs(c) < 0.2
end

-- What is done with a readout whose travel is graduated.
local function GRRawEntry(tr, fx, pm)
  local verdict, k, c = GRScale(tr, fx, pm)

  if verdict == "linear" then
    if GRIdentity(k, c) then return { pm = pm, mode = "raw", judged = true } end
    return { pm = pm, mode = "raw", k = k, c = c, judged = true }
  end

  if verdict == "nonlinear" then return { pm = pm, mode = "fmt" } end
  if verdict == "nodb" then return nil end

  -- "unknown": nothing states the unit, so this falls back on how plausible the
  -- travel is. A JSFX slider graduated 0..20 is still read as is; a front-panel
  -- graduation that climbs to a hundred is turned down.
  local _, mn, mx = reaper.TrackFX_GetParamEx(tr, fx, pm)
  if mn and mx and mx <= 60 and mx - mn <= 60 then
    return { pm = pm, mode = "raw", judged = true }
  end
  return nil
end

-- Memory of the learned readouts, per plugin type and not per instance: once the
-- meter has been found on a plugin, all its instances and every later project
-- read it without learning anything again. The negative cache matters just as
-- much: without it, a plugin with 500 parameters would be swept again at every
-- rescan.
local grpcache = {}

local function GRCacheKey(tr, fx)
  local ok, id = reaper.TrackFX_GetNamedConfigParm(tr, fx, "fx_ident")
  if ok and id ~= "" then return id end
  return nil
end

-- Only the successes are written to disk. A refusal stays in session memory: the
-- plugin may simply never have been pushed hard enough to give itself away, and
-- carving that silence in stone would condemn it for good.
local function GRCacheSet(key, e)
  grpcache[key] = e
  reaper.SetExtState(NS, "grp." .. key, e.pm .. "|" .. e.mode, true)
end

local function GRCacheGet(tr, fx, key)
  local e = grpcache[key]
  if e == nil then
    local v = reaper.GetExtState(NS, "grp." .. key)
    if not v or v == "" then return nil end
    local pm, mode = v:match("^(%d+)|(%a+)$")
    if not pm then return nil end
    e = { pm = tonumber(pm), mode = mode }
    grpcache[key] = e
  end

  -- The parameter number belongs to one version of the plugin: checking that the
  -- name still answers costs one call and avoids reading a control instead of
  -- the readout after an update.
  if e then
    local _, nm = reaper.TrackFX_GetParamName(tr, fx, e.pm, "")
    if not nm or nm == "" then return nil end
    local low = nm:lower()

    local named = false
    for _, w in ipairs(GR_PARAM_WORDS) do
      if low:find(w, 1, true) then named = true; break end
    end
    if not named then
      for _, w in ipairs(GR_PARAM_WEAK) do
        if WordIn(low, w) then named = true; break end
      end
    end

    if not named then
      grpcache[key] = nil
      reaper.DeleteExtState(NS, "grp." .. key, true)
      return nil
    end

    -- A readout kept before units could be checked may have been learned
    -- crooked: the scale is judged again once per session, on a stored entry as
    -- on a fresh discovery. Without that, the offending plugin would keep its
    -- error for good -- and it is precisely the one that needed correcting.
    if e.mode == "raw" and not e.judged then
      e.judged = true
      local fresh = GRRawEntry(tr, fx, e.pm)

      if not fresh then

        -- Refused for the session, and the stored entry stays on disk: a
        -- mistaken refusal must clear by restarting REAPER, not be carved in.
        grpcache[key] = false
        return false
      end

      e.k, e.c = fresh.k, fresh.c
      if fresh.mode ~= e.mode then
        e.mode = fresh.mode
        GRCacheSet(key, e)
      end
    end
    return e
  end
  return e
end

-- ==========================================================================
-- The learned setting
--
-- The recognition rules -- a threshold accompanied by a ratio, a makeup or a
-- ballistic pair, and failing that a list of device names -- cover the vast
-- majority of compressors. There will always be one whose controls carry names
-- nobody anticipated.
--
-- Rather than wait for a version of the script, "StripTease Check" lets the
-- parameters be named by hand, once, and files the result BY plugin TYPE: every
-- instance benefits from it, in every project, and the setting survives
-- StripTease updates -- which an edit to the shipped code would not, since the
-- package is regenerated at every version.
--
-- Format: dyn|mk|mkmode|mk2|mx|mx2|ag, "-" for an empty field.
-- ==========================================================================
local fitcache = {}
local fitgen   = nil

local function FitNum(s)
  return s ~= "-" and tonumber(s) or nil
end

local function Fit(tr, fx)
  local key = GRCacheKey(tr, fx)
  if not key then return nil end

  local e = fitcache[key]
  if e ~= nil then return e or nil end

  local v = reaper.GetExtState(NS, "fit." .. key)
  if not v or v == "" then fitcache[key] = false; return nil end

  -- Empty fields carry a dash: without it gmatch would skip them, and the ones
  -- after would shift by one.
  local f = {}
  for w in v:gmatch("[^|]+") do f[#f + 1] = w end
  if #f < 7 then fitcache[key] = false; return nil end

  e = { dyn  = f[1] == "1",
        mk   = FitNum(f[2]),
        mode = f[3] ~= "-" and f[3] or nil,
        mk2  = FitNum(f[4]),
        mx   = FitNum(f[5]),
        mx2  = FitNum(f[6]),
        ag   = FitNum(f[7]) }

  fitcache[key] = e
  return e
end

-- Candidates being confirmed, per plugin type. Two baskets: what the parameter
-- displays when the track is loaded, what it displays when it is silent. A
-- reduction readout keeps them apart, a control does not.
local pend = {}

local LOUD, QUIET, NSAMP, VSPREAD = -40, -60, 15, 0.5

local function VConfirm(tr, fx, key, c)
  local lvl = TrackLevelDB(tr)
  if not lvl then return end

  -- The scale, checked live. The static probe reads both ends of the travel;
  -- here the raw value and what the plugin displays for it are seen at the same
  -- instant, on the plugin at work. A non-linear front-panel graduation, which
  -- the midpoint did not give away, comes out here.
  if c.mode == "raw" then
    local r = reaper.TrackFX_GetParam(tr, fx, c.pm)
    local ok, s = reaper.TrackFX_GetFormattedParamValue(tr, fx, c.pm, "")
    local d = ok and DBNum(s, true) or nil
    if r and d then
      if not c.rlo or r < c.rlo then c.rlo, c.dlo = r, d end
      if not c.rhi or r > c.rhi then c.rhi, c.dhi = r, d end
    end
  end

  local v = math.abs(GRValue(tr, fx, c))
  if lvl > LOUD then
    c.nl = c.nl + 1
    if v > c.loud then c.loud = v end
  elseif lvl < QUIET then
    c.nq = c.nq + 1
    if v > c.quiet then c.quiet = v end
  end

  if c.nl >= NSAMP and c.nq >= NSAMP then
    if c.loud - c.quiet > VSPREAD then
      local e = { pm = c.pm, mode = c.mode, k = c.k, c = c.c }

      -- Two points far enough apart are enough to draw the line. It wins over
      -- the static probe: it was taken on the plugin at work, and it is the only
      -- evidence when the plugin cannot format.
      if c.mode == "raw" and c.rlo and c.rhi - c.rlo >= 1.0 then
        local kk = (c.dhi - c.dlo) / (c.rhi - c.rlo)
        local cc = c.dlo - kk * c.rlo
        if math.abs(kk) > GRKMIN and math.abs(kk) < GRKMAX
           and math.abs(cc) <= 12 then
          e.judged = true
          if GRIdentity(kk, cc) then e.k, e.c = nil, nil
          else e.k, e.c = kk, cc end
        end
      end

      GRCacheSet(key, e)
    else
      grpcache[key] = false
    end
    pend[key] = nil
    force_rescan = true
  end
end

-- Returns { pm, mode, k, c } or nil. mode = "raw" (graduated value, corrected by
-- k and c when its graduation is not the decibel) or "fmt" (normalised value, dB
-- only readable on screen). nil when the unit stays undeterminable: the plugin
-- then falls back to being measured by the panel, which compares two levels in
-- dB and therefore cannot get the scale wrong.
local function GRParam(tr, fx)
  local key = GRCacheKey(tr, fx)
  if key then
    local hit = GRCacheGet(tr, fx, key)
    if hit ~= nil then return hit or nil end

    -- The observation in progress follows the live instance: the chain may have
    -- been reordered since, and reading the old index would amount to querying a
    -- different plugin.
    if pend[key] then
      pend[key].tr, pend[key].fx = tr, fx
      return nil
    end
  end

  local n = reaper.TrackFX_GetNumParams(tr, fx) or 0
  local pm, weak = 0, nil
  while pm < n do
    local ok, nm = reaper.TrackFX_GetParamName(tr, fx, pm, "")
    if ok and nm ~= "" then
      local low = nm:lower()
      local strong = false
      for _, w in ipairs(GR_PARAM_WORDS) do
        if low:find(w, 1, true) then strong = true; break end
      end

      -- The travel is only read once the name has been kept: it costs one call
      -- per parameter, and a plugin sometimes has several hundred of them.
      if strong then
        local _, mn, mx = reaper.TrackFX_GetParamEx(tr, fx, pm)

        -- Explicit name and graduated travel: kept without further ado, but no
        -- longer at just any scale -- GRRawEntry establishes the unit, and
        -- returns nil when it stays undeterminable.
        local e = (mn and mx and mx - mn > 1.5) and GRRawEntry(tr, fx, pm) or nil
        if e then
          if key then GRCacheSet(key, e) end
          return e
        end

        -- Explicit name but normalised travel, or refused unit: the candidate is
        -- worth more than anything a weak word could offer, so it takes the
        -- place.
        if (not weak or not weak.strong)
           and DBFormatted(tr, fx, pm) and not Driven(tr, fx, pm) then
          weak = { pm = pm, mode = "fmt", strong = true }
        end
      elseif not weak then
        for _, w in ipairs(GR_PARAM_WEAK) do
          if WordIn(low, w) then
            if not Driven(tr, fx, pm) then
              local _, mn, mx = reaper.TrackFX_GetParamEx(tr, fx, pm)
              if mn and mx and mx - mn > 1.5 then
                weak = GRRawEntry(tr, fx, pm)
              end
              if not weak and DBFormatted(tr, fx, pm) then
                weak = { pm = pm, mode = "fmt" }
              end
            end
            break
          end
        end
      end
    end
    pm = pm + 1
  end

  if weak and key then
    pend[key] = { tr = tr, fx = fx, pm = weak.pm, mode = weak.mode,
                  k = weak.k, c = weak.c,
                  loud = 0, quiet = 0, nl = 0, nq = 0 }
  elseif key then
    grpcache[key] = false
  end
  return nil
end

-- ==========================================================================
-- The makeup read rather than estimated
--
-- The virtual channel compares the panel's input to the chain's output: the gap
-- between the two is the compressor's static gain minus its reduction. The panel
-- guesses that static gain by keeping the largest gap seen recently -- which
-- assumes it goes by without reducing every once in a while. A bus compressor
-- never does: it reduces permanently, the estimator settles on its smallest
-- reduction, and the needle moves correctly but starts too low.
--
-- When the span is tight -- panel right above, compressor at the end of the
-- chain -- the only static gain between the two probes is its own makeup. It may
-- as well be read from the plugin: nothing left to guess, and the reading is
-- right from the first frame.
-- ==========================================================================

-- Comparison on the letters alone: "Make-Up", "Make Up" and "MakeUp" are the
-- same control. "Input Gain" contains neither "outgain" nor "outputgain" nor
-- "gain" on its own, so it cannot be taken for an output.
local function Letters(nm)
  return (nm:lower():gsub("[^%a]", ""))
end

-- Returns a rank, or nil. The rank decides between several candidates on the
-- same plugin: an UnFairchild carries a "Gain" that is its input drive and a
-- "Makeup" that really is the output gain, and taking the first one around would
-- skew the measurement by the whole gap between them. The more explicit the
-- name, the more it wins.
local function MKCore(s)
  if s:find("makeup", 1, true) then return 3 end
  if s:find("outputgain", 1, true) or s:find("outgain", 1, true)
     or s:find("gainout", 1, true) then return 2 end
  if s == "output" or s == "outputlevel" then return 1 end
  if s == "gain" then return 0 end
end

-- A stereo compressor often doubles its controls and puts the side in front:
-- "L Gain", "R Gain". That prefix is removed before comparing -- but only it, and
-- only if what remains passes the rule as it stands. "Input Gain" therefore still
-- is not taken for an output: "i" is not a side. Longest first, so that
-- "Left Gain" really yields "gain" and not "eftgain".
local SIDES = { "stereo", "right", "left", "side", "mid", "ch", "l", "r", "m", "s" }

-- Returns the name without the side, and whether a side was removed. nil if this
-- is not an output gain.
-- The side comes off first: "L Makeup" and "R Makeup" would both pass the rule
-- as they stand, but under two different names -- and they would not recognise
-- each other as the two halves of one control.
local function MKMatch(s)
  for _, p in ipairs(SIDES) do
    if s:sub(1, #p) == p then
      local r = s:sub(#p + 1)
      local k = r ~= "" and MKCore(r)
      if k then return r, true, k end
    end

    -- The other convention, "Gain L". The side generally comes after the name
    -- when the plugin files its parameters by function rather than by channel.
    if s:sub(-#p) == p then
      local r = s:sub(1, #s - #p)
      local k = r ~= "" and MKCore(r)
      if k then return r, true, k end
    end
  end

  local k = MKCore(s)
  if k then return s, false, k end
end

-- What the plugin DISPLAYS for this parameter, in dB, or nil.
--
-- The simple case is a display with the unit included -- "+3.0 dB". Many VST3
-- plugins do not write the unit and settle for the number: "2.00" for two
-- decibels. That is accepted, with three precautions, because not every bare
-- number is decibels:
--
--   * When a plugin returns no text at all, REAPER displays the normalised value
--     in its place. A display that reproduces exactly that value is not a
--     display.
--   * The "Gain" knob of an LA-2A or the "Output Gain" of a Comp TUBE-STA are
--     graduated 0 to 100, as on the device: the number displayed is then a
--     hundred times the normalised value, and that is a knob position, not
--     decibels. No dB scale lands on that equality -- it would take a travel of
--     0 to 100 dB.
--   * A makeup does not go past forty decibels. Beyond that, what was read is
--     not a makeup, whatever the name says.
--
-- The rest is refused: a percentage, a factor, a time constant carry a unit that
-- could not be converted, and guessing would do worse than the estimator, which
-- at least never gets the scale wrong.
local MKMAX = 40

local function MKFmt(tr, fx, pm)
  local ok, s = reaper.TrackFX_GetFormattedParamValue(tr, fx, pm, "")
  if not ok or not s or s == "" then return nil end

  local v = tonumber(s:match("%-?%d+%.?%d*") or "")
  if not v then return nil end

  if not s:lower():find("db", 1, true) then
    if not s:match("^%s*[%-%+]?%d+%.?%d*%s*$") then return nil end

    local nz = reaper.TrackFX_GetParamNormalized(tr, fx, pm)
    if nz then
      if math.abs(nz - v) < 0.0005 then return nil end
      if math.abs(nz * 100 - v) < 0.05 then return nil end
    end
  end

  if v < -MKMAX or v > MKMAX then return nil end
  return v
end

-- The value of the moment does not tell the whole story: the "Gain" of a UAD
-- LA-2A displays 34, which passes for decibels and is not -- its knob is
-- graduated 0 to 100 as on the device, without the displayed number being a
-- hundred times the normalised value, since the travel is not linear.
--
-- It is the TRAVEL that has to be looked at. REAPER can format a value without
-- touching the parameter: it is asked what the plugin would display at both
-- ends, and the scale reads off at once. A makeup does not climb past forty
-- decibels and does not span more than sixty; a front-panel graduation, on the
-- other hand, goes up to a hundred.
--
-- A plugin that cannot format returns its normalised bounds, 0 and 1: nothing is
-- concluded then, and the other rules keep the upper hand.
local function MKScale(tr, fx, pm)
  if not reaper.TrackFX_FormatParamValueNormalized then return true end

  local ok0, s0 = reaper.TrackFX_FormatParamValueNormalized(tr, fx, pm, 0, "")
  local ok1, s1 = reaper.TrackFX_FormatParamValueNormalized(tr, fx, pm, 1, "")
  if not ok0 or not ok1 then return true end

  local a = tonumber((s0 or ""):match("%-?%d+%.?%d*") or "")
  local b = tonumber((s1 or ""):match("%-?%d+%.?%d*") or "")
  if not a or not b then return true end
  if a > b then a, b = b, a end

  return b <= MKMAX and (b - a) <= 60
end

-- An automatic makeup moves on its own with the threshold: the parameter no
-- longer states the gain applied, and reading it would be worse than estimating
-- it.
local function AGName(s)
  return s:find("autogain", 1, true) or s:find("automakeup", 1, true)
      or s:find("autoout", 1, true)
end

-- ==========================================================================
-- The mix
--
-- A compressor blending in parallel only puts a fraction of the processed signal
-- on its output: the output is (1-m) times the input plus m times the compressed
-- signal. The reduction the chain undergoes is therefore smaller than the one the
-- compressor computes, in the exact proportion of the mix -- and the needle reads
-- it as is, which no longer tells whether the compressor is working less or is
-- simply blended in less.
--
-- Knowing m and the makeup, the relation inverts and the internal reduction is
-- recovered, the one the plugin's own meter shows. At m = 1 the computation
-- reduces exactly to the old one: nothing changes for anyone who does not touch
-- the mix. At m = 0 the compressed signal simply does not leave the plugin, and
-- no input/output comparison can recover it.
--
-- REAPER adds its own "Wet" at the end of the list, which is the same blend
-- around the whole plugin: it serves as a fallback when the plugin offers none.
local function MXCore(s)
  return s == "mix" or s == "blend" or s == "wet"
      or s:find("drywet", 1, true) or s:find("wetdry", 1, true)
end

local function MXMatch(s)
  for _, p in ipairs(SIDES) do
    if s:sub(1, #p) == p then
      local r = s:sub(#p + 1)
      if r ~= "" and MXCore(r) then return r, true end
    end
    if s:sub(-#p) == p then
      local r = s:sub(1, #s - #p)
      if r ~= "" and MXCore(r) then return r, true end
    end
  end
  if MXCore(s) then return s, false end
end

-- 0..1. A mix is almost always displayed as a percentage; otherwise the
-- normalised value does the job, such a control being linear by nature.
local function MXVal(tr, fx, pm)
  local ok, s = reaper.TrackFX_GetFormattedParamValue(tr, fx, pm, "")
  if ok and s and s:find("%%") then
    local v = tonumber(s:match("%-?%d+%.?%d*") or "")
    if v then return math.max(0, math.min(1, v / 100)) end
  end
  local v = reaper.TrackFX_GetParamNormalized(tr, fx, pm)
  if v then return math.max(0, math.min(1, v)) end
end

local mkcache = {}

-- Returns { pm, mode, ag, mx } or nil. Session cache per plugin type: nothing is
-- carved on disk, one parameter sweep per type and per session is enough.
local function MakeupParam(tr, fx)
  local key = GRCacheKey(tr, fx)
  if key then
    local e = mkcache[key]
    if e ~= nil then return e or nil end
  end

  -- What has been named by hand takes precedence over any rule: it is precisely
  -- because the rules got it wrong that it was named in the first place.
  local fit = Fit(tr, fx)
  if fit and fit.mk then
    local e = { pm = fit.mk, mode = fit.mode or "fmt", pm2 = fit.mk2,
                mx = fit.mx, mx2 = fit.mx2, ag = fit.ag }
    if key then mkcache[key] = e end
    return e
  end

  local n = reaper.TrackFX_GetNumParams(tr, fx) or 0
  local cand, ag, pm = {}, nil, 0
  local mx, mx2, mxcore, mxside = nil, nil, nil, nil

  while pm < n do
    local ok, nm = reaper.TrackFX_GetParamName(tr, fx, pm, "")
    if ok and nm ~= "" then
      local s = Letters(nm)
      local core, side, rank = MKMatch(s)

      if core then
        cand[#cand + 1] = { pm = pm, core = core, side = side, rank = rank,
                            i = #cand }
      else

        -- The mix is looked for in the same sweep: same plugin, same list, and
        -- it only serves alongside the makeup.
        local mc, ms = MXMatch(s)
        if mc then
          if not mx then mx, mxcore, mxside = pm, mc, ms
          elseif ms and mxside and mc == mxcore and not mx2 then mx2 = pm
          end
        elseif not ag and AGName(s) then
          ag = pm
        end
      end
    end
    pm = pm + 1
  end

  -- The most explicit name first, the order of the list to break ties. The
  -- ranking is walked down to the first candidate that is actually readable: a
  -- "Makeup" graduated in silent units must not carry the decision and block an
  -- "Output Gain" that does state its dB.
  table.sort(cand, function(a, b)
    if a.rank ~= b.rank then return a.rank > b.rank end
    return a.i < b.i
  end)

  local e = nil
  for _, c in ipairs(cand) do

    -- The display decides before the raw travel: a makeup graduated 0..1 only
    -- states its dB on screen, and that is again the most common case. But
    -- nothing is read from a parameter whose scale is not one of decibels.
    local mode = nil
    if MKScale(tr, fx, c.pm) then
      if MKFmt(tr, fx, c.pm) then
        mode = "fmt"
      else
        local _, mn, mxx = reaper.TrackFX_GetParamEx(tr, fx, c.pm)
        if mn and mxx and mxx - mn > 1.5 and mxx <= MKMAX then mode = "raw" end
      end
    end

    if mode then
      e = { pm = c.pm, mode = mode, core = c.core, side = c.side, rank = c.rank }
      break
    end
  end

  -- The counterpart on the other channel. It is only paired up if the two names
  -- differ by their side alone: "Makeup" and "Output Gain" on the same plugin are
  -- not a stereo pair, and confusing them would set the measurement on the wrong
  -- one of the two.
  if e and e.side then
    for _, c in ipairs(cand) do
      if c.pm ~= e.pm and c.side and c.core == e.core and c.rank == e.rank then
        e.pm2 = c.pm
        break
      end
    end
  end

  if e then e.ag = ag; e.mx = mx; e.mx2 = mx2 end
  if key then mkcache[key] = e or false end
  return e
end

-- The mix applied, 0..1, or nil if there is nothing to correct. The two sides
-- must agree, for the same reason the two makeups must: a single cell carries
-- them.
local function MakeupMix(tr, fx, e)
  if not e.mx then return nil end

  local m = MXVal(tr, fx, e.mx)
  if not m then return nil end

  if e.mx2 then
    local b = MXVal(tr, fx, e.mx2)
    if b and math.abs(m - b) > 0.02 then return nil end
  end

  return m < 0.999 and m or nil
end

local function MKRead(tr, fx, e, pm)
  if e.mode == "fmt" then return MKFmt(tr, fx, pm) end
  return reaper.TrackFX_GetParam(tr, fx, pm)
end

local function MakeupDB(tr, fx, e)
  if e.ag then
    local v = reaper.TrackFX_GetParamNormalized(tr, fx, e.ag)
    if v and v >= 0.5 then return nil end
  end

  local a = MKRead(tr, fx, e, e.pm)

  -- Holds for the raw reading and for a parameter named by hand as well: past
  -- forty decibels it is not a makeup, and the needle would display that whole
  -- gap as reduction.
  if a and (a < -MKMAX or a > MKMAX) then return nil end

  -- The two sides set differently. The makeup only travels through one cell, and
  -- keeping one of them would skew the other channel's reading by that much: the
  -- estimator takes over, since it handles the channels separately. That needs
  -- proof of disagreement: an unreadable second side proves nothing, and the
  -- first one is then still better than nothing.
  if a and e.pm2 then
    local b = MKRead(tr, fx, e, e.pm2)
    if b and math.abs(a - b) > 0.5 then return nil end
  end

  return a
end

-- The pan sits after the chain, hence between the two probes: opened anywhere
-- but centre, it adds to the makeup an attenuation the compressor knows nothing
-- about. The estimator absorbed it without knowing; the read makeup does not.
-- Off centre it therefore falls back to estimation, which stays right up to an
-- offset.
local function PanNeutral(tr)
  local m = reaper.GetMediaTrackInfo_Value(tr, "I_PANMODE") or 3
  if m == 6 then
    local l = reaper.GetMediaTrackInfo_Value(tr, "D_DUALPANL") or 0
    local r = reaper.GetMediaTrackInfo_Value(tr, "D_DUALPANR") or 0
    return l < -0.995 and r > 0.995
  end

  local p = reaper.GetMediaTrackInfo_Value(tr, "D_PAN") or 0
  if p > 0.005 or p < -0.005 then return false end
  if m == 5 then
    local w = reaper.GetMediaTrackInfo_Value(tr, "D_WIDTH") or 1
    return w > 0.995
  end
  return true
end

-- REAPER only presents channel 1 to a plugin instantiated in mono: channel 2
-- crosses the chain untouched, and the comparison there shows only the makeup, or
-- nothing at all. The panel has to know to look at the first one only.
local function MonoFX(tr, fx)
  if not reaper.TrackFX_GetIOSize then return false end
  local _, ins, outs = reaper.TrackFX_GetIOSize(tr, fx)
  ins  = tonumber(ins  or "") or 2
  outs = tonumber(outs or "") or 2
  return ins <= 1 or outs <= 1
end

-- When the makeup is not readable, the panel guesses the static gain by keeping
-- the largest gap seen recently, with thirty seconds of memory. That is what it
-- takes for a compressor that never releases to show its reduction all the same
-- -- but if the makeup is lowered mid-playback, the needle stays wrong for all
-- that time, the difference read passing for reduction. Only the service can
-- know: the plugin's settings are sampled every so often, and it is told to
-- start over.
--
-- The signal goes out on the FALLING EDGE, once the settings have gone still
-- again, and not at the first change: many compressors expose their own
-- reduction as a read-only parameter, which therefore moves at every sample.
-- Waiting for stillness rules them all out, and it is the value settled on that
-- has to be learned anyway, not those passed through while turning the knob.
-- Filed apart from `sources`, which is rebuilt at every rescan: a settings change
-- dirties the project, hence can trigger that rescan, and state filed in the
-- source would vanish just before being of use.
local jolt = {}

local function Jolt(s, now)
  local key = s.k .. ":" .. s.vfx
  local j = jolt[key]
  if not j then j = {}; jolt[key] = j end

  if now - (j.t or 0) >= 0.4 then
    j.t = now

    local n = reaper.TrackFX_GetNumParams(s.tr, s.vfx) or 0
    if n > 64 then n = 64 end

    local h = 0
    for p = 0, n - 1 do
      h = h + (reaper.TrackFX_GetParamNormalized(s.tr, s.vfx, p) or 0) * (p + 1)
    end

    if j.h == nil then j.h = h
    elseif h ~= j.h then j.h = h; j.moved = true
    elseif j.moved then j.moved = false; j.fire = now
    end
  end

  return j.fire
end

-- A plugin that reports nothing and exposes nothing does not declare itself as
-- dynamics: it has to be recognised by what it offers. A threshold + ratio pair
-- (or range, for a gate) is hardly met anywhere else, and the name serves as a
-- fallback for character compressors whose controls carry in-house names.
-- Deliberately without the words that qualify a compressor without naming it --
-- bus, VCA, FET: they turn up on EQs and saturators, and a plugin taken for a
-- compressor would be handed a number and a needle that would show nothing real.
-- The comparison is made on a name stripped of its punctuation and spaces:
-- "LA-2A", "LA 2A" and "CLA2A" all come down to the same string, and one word is
-- then enough where four would have been needed. The words below are therefore
-- written with no dash and no space.
local DYN_WORDS = {

  -- What the device does.
  "comp", "pressor", "limit", "maximizer", "gate", "expander", "dynamics",
  "glue", "opto", "varimu", "variablemu", "leveler", "leveller", "stalevel",

  -- Classic hardware, taken up under the same name by just about everyone. The
  -- model is what is aimed at, never the brand: Tube-Tech and Lindell also make
  -- EQs, elysia a saturator, and an EQ taken for a compressor would be handed a
  -- number and a needle that would show nothing real.
  "1176", "cla76", "la2a", "la3a", "fairchild", "puigchild", "teletronix",
  "urei", "33609", "2254", "2264", "dbx", "stressor", "arousor", "api2500",
  "cl1b", "cl2a", "tla100", "mc77", "fatso", "vsc", "tcl2", "drawmer",
  "spliron", "ds1mk3", "mv2",

  -- In-house names that do not say what they do: without them, only the
  -- parameters can decide, and they cannot always.
  "thebus", "xbus", "buster", "lala", "fetish",          -- Analog Obsession, Kiive
  "kotelnikov", "molot", "mjuc", "dc8c",                 -- Tokyo Dawn, Klanghelm
  "fgred", "fggrey", "fgstress", "fg116", "fg401",       -- Slate
  "white2a", "black76",                                  -- IK Multimedia
}

local dyncache = {}

local function IsDyn(tr, fx)
  local key = GRCacheKey(tr, fx)
  if key and dyncache[key] ~= nil then return dyncache[key] end

  local fit = Fit(tr, fx)
  if fit then
    if key then dyncache[key] = fit.dyn end
    return fit.dyn
  end

  local _, nm = reaper.TrackFX_GetFXName(tr, fx, "")
  local low = nm:lower():gsub("[^%a%d]", "")
  local hit = false
  for _, w in ipairs(DYN_WORDS) do
    if low:find(w, 1, true) then hit = true; break end
  end

  if not hit then
    local n = reaper.TrackFX_GetNumParams(tr, fx) or 0
    local thr, amt, mk, atk, rel = false, false, false, false, false
    local pm = 0
    while pm < n do
      local ok, pn = reaper.TrackFX_GetParamName(tr, fx, pm, "")
      if ok and pn ~= "" then
        local p = pn:lower()
        if p:find("threshold", 1, true) or p:find("thresh", 1, true) then thr = true end
        if WordIn(p, "ratio") or WordIn(p, "range") then amt = true end
        if p:find("attack", 1, true) then atk = true end
        if p:find("release", 1, true) or p:find("recover", 1, true) then rel = true end

        -- An explicit makeup next to a threshold is met nowhere else: that gain
        -- only exists to catch up a reduction. Only the explicit names are kept
        -- -- "Makeup", "Output Gain" -- because a plain "Gain" is found on just
        -- about everything.
        local _, _, rank = MKMatch(Letters(pn))
        if rank and rank >= 2 then mk = true end
      end
      pm = pm + 1
    end

    -- A threshold on its own is not enough: they are found on saturators and
    -- width expanders. It needs something to say what happens once it is crossed
    -- -- a ratio, a makeup, or a ballistic pair.
    hit = thr and (amt or mk or (atk and rel))
  end

  if key then dyncache[key] = hit end
  return hit
end

-- A setting has just been learned or cleared: the three session caches rest on
-- the rules it replaces, so all of them have to go. One ExtState read per frame,
-- and nothing more the rest of the time.
local function FitBump()
  local g = reaper.GetExtState(NS, "fitgen")
  if g == fitgen then return end
  fitgen   = g
  fitcache = {}
  mkcache  = {}
  dyncache = {}

  -- The project has not moved, so nothing would trigger the rescan on its own
  -- -- and without a rescan, the plugin just made recognisable would not enter
  -- any source before the chain is next touched.
  rescan = 0
  force_rescan = true
end

-- Record input FX (0x1000000) and container FX (0x2000000) do not file into the
-- chain order as the panel sees it: the virtual measurement, which rests entirely
-- on that order, leaves them aside rather than read a level ratio that means
-- nothing.
local function Plain(fx) return fx < 0x1000000 end

-- ==========================================================================
-- The probe through the pins
--
-- A REAPER container can copy its own input onto its channels 3/4 through plain
-- pin mapping: no plugin takes care of it, it is routing. The panel then holds
-- both ends of the compressor -- its output on 1/2, its input on 3/4 -- within
-- the same audio block. It measures at the audio rate, attack and release show
-- through, and there is not one extra slot in the chain.
--
-- It can be inside the container, as its last item, or right after it at the top
-- level of the chain: see TapFind. The second placement takes the track to four
-- channels, the first does not, but REAPER only embeds the interface of a
-- top-level FX in the MCP.
--
-- All the service does here is recognise the geometry, wire it once, and tell
-- the panel the probe exists.
-- ==========================================================================

local function ContainerItems(tr, c)
  local _, n = reaper.TrackFX_GetNamedConfigParm(tr, c, "container_count")
  local t = {}
  for i = 0, (tonumber(n or "") or 0) - 1 do
    local _, s = reaper.TrackFX_GetNamedConfigParm(tr, c, "container_item." .. i)
    t[#t + 1] = tonumber(s)
  end
  return t
end

-- Returns { c, panel, fx, gate, tight, out } or nil. The conditions are strict on
-- purpose: better to fall back on the backup route than to measure a geometry
-- nobody can vouch for.
--
-- Two placements of the panel are accepted, and they measure equally well:
--
--   inside (out = false)  Container [ compressor, panel ]
--     Channels 3/4 never leave the container, the track stays at two channels,
--     but REAPER does not embed in the MCP the interface of an FX shut inside a
--     container.
--
--   outside (out = true)  Container [ compressor ] then the panel, right after
--     The container brings the probe out on its channels 3/4, the panel picks it
--     up at track level -- which therefore has to be taken to four channels. The
--     panel stays a top-level FX: its interface embeds in the MCP.
local function TapFind(tr, fxlist)

  -- One panel only on the track. A second one would read its own pins 3/4 --
  -- empty there -- and believe its Input level mode was being fed.
  local np = 0
  for _, fx in ipairs(fxlist) do
    if IsPanel(tr, fx) then np = np + 1 end
  end
  if np ~= 1 then return nil end

  local ntop = reaper.TrackFX_GetCount(tr)

  for c = 0, ntop - 1 do
    local _, isc = reaper.TrackFX_GetNamedConfigParm(tr, c, "container_count")
    if isc ~= "" then
      local it = ContainerItems(tr, c)
      local last = it[#it]

      -- Panel inside, as the last item: it is the output probe. Otherwise the
      -- container holds the compressor alone and the panel follows it
      -- immediately -- were it separated from it, whatever came in between would
      -- touch 1/2 without touching 3/4 and its gain would read as reduction.
      local panel, dedans = nil, false
      if last and IsPanel(tr, last) then
        panel, dedans = last, true
      elseif c + 1 < ntop and IsPanel(tr, c + 1) then
        panel = c + 1
      end

      if panel then
        local fin = dedans and #it - 1 or #it
        local seul, n = nil, 0
        local ok = true

        for i = 1, fin do
          local fx = it[i]

          -- What a plugin reports on its own crosses the span of the probe and
          -- would add there to the silent one's reduction. This refuses rather
          -- than publish the sum of the two.
          if IsGRSource(tr, fx) or GRParam(tr, fx) then
            ok = false
            break
          end
          if IsDyn(tr, fx) then n = n + 1; seul = fx end
        end

        if ok and n == 1 then
          return { c = c, panel = panel, fx = seul, gate = IsGate(tr, seul),
                   out = not dedans,

                   -- Tight span: nothing but the compressor between the two
                   -- probes, so the only static gain separating them is its
                   -- makeup, and reading it from the plugin is enough.
                   tight = (fin == 1) }
        end
      end
    end
  end
end

-- The wiring is done once and marked in the project: it changes the project's
-- state, hence triggers a rescan, and without that mark the service would set
-- itself off again indefinitely.
local TAPWIRE = "4"

local function TapWire(tr, t)
  local g = reaper.TrackFX_GetFXGUID(tr, t.c)
  if not g then return end
  local mark = TAPWIRE .. (t.out and "o" or "i")
  local _, done = reaper.GetProjExtState(0, NS, "tap." .. g)
  if done == mark then return end

  -- Panel outside the container: the probe passes through the track, which
  -- therefore has to carry four channels. That is the only thing this placement
  -- costs.
  if t.out then
    local n = reaper.GetMediaTrackInfo_Value(tr, "I_NCHAN") or 2
    if n < 4 then reaper.SetMediaTrackInfo_Value(tr, "I_NCHAN", 4) end
  end

  -- Three distinct settings, and not one: container_nch is the number of
  -- channels circulating INSIDE the container, container_nch_in and _out the
  -- number of pins it presents to the track. Setting only the first leaves the
  -- container at two pins, and the mappings of pins 3 and 4 are then written
  -- nowhere -- which is what forced routing by hand.
  -- On the output side, the panel inside has nothing to give back: two pins are
  -- enough and the track stays stereo.
  reaper.TrackFX_SetNamedConfigParm(tr, t.c, "container_nch", "4")
  reaper.TrackFX_SetNamedConfigParm(tr, t.c, "container_nch_in", "4")
  reaper.TrackFX_SetNamedConfigParm(tr, t.c, "container_nch_out", t.out and "4" or "2")
  reaper.TrackFX_SetNamedConfigParm(tr, t.panel, "nchan", "4")

  -- The container's input pins say which track channels feed each of its
  -- internal channels. Channels 3 and 4 therefore take the same ones as 1 and 2:
  -- the container's input copies onto them, and that is the whole probe.
  reaper.TrackFX_SetPinMappings(tr, t.c, 0, 0, 1, 0)
  reaper.TrackFX_SetPinMappings(tr, t.c, 0, 1, 2, 0)
  reaper.TrackFX_SetPinMappings(tr, t.c, 0, 2, 1, 0)
  reaper.TrackFX_SetPinMappings(tr, t.c, 0, 3, 2, 0)

  -- On the output side: either the panel is inside and has already read
  -- everything, and nothing must come back out through 3/4; or it is outside and
  -- that is how it gets served.
  reaper.TrackFX_SetPinMappings(tr, t.c, 1, 0, 1, 0)
  reaper.TrackFX_SetPinMappings(tr, t.c, 1, 1, 2, 0)
  reaper.TrackFX_SetPinMappings(tr, t.c, 1, 2, t.out and 4 or 0, 0)
  reaper.TrackFX_SetPinMappings(tr, t.c, 1, 3, t.out and 8 or 0, 0)

  -- Taking nchan to 4 is not enough: the panel keeps the two-channel mapping it
  -- had saved, and its pins 3 and 4 stay on an empty mask -- the probe then
  -- arrives silent and the measurement returns zero. They have to be set one by
  -- one. Outputs 3 and 4 are cut instead: nothing that serves the measurement
  -- must go back out into the chain.
  reaper.TrackFX_SetPinMappings(tr, t.panel, 0, 0, 1, 0)
  reaper.TrackFX_SetPinMappings(tr, t.panel, 0, 1, 2, 0)
  reaper.TrackFX_SetPinMappings(tr, t.panel, 0, 2, 4, 0)
  reaper.TrackFX_SetPinMappings(tr, t.panel, 0, 3, 8, 0)
  reaper.TrackFX_SetPinMappings(tr, t.panel, 1, 0, 1, 0)
  reaper.TrackFX_SetPinMappings(tr, t.panel, 1, 1, 2, 0)
  reaper.TrackFX_SetPinMappings(tr, t.panel, 1, 2, 0, 0)
  reaper.TrackFX_SetPinMappings(tr, t.panel, 1, 3, 0, 0)

  -- The compressor must not consume the probe on the way through. No effect if
  -- it only has two pins, which is the common case.
  reaper.TrackFX_SetPinMappings(tr, t.fx, 0, 2, 0, 0)
  reaper.TrackFX_SetPinMappings(tr, t.fx, 0, 3, 0, 0)
  reaper.TrackFX_SetPinMappings(tr, t.fx, 1, 2, 0, 0)
  reaper.TrackFX_SetPinMappings(tr, t.fx, 1, 3, 0, 0)

  -- The mark is only laid if the wiring actually took. A pin write that fails
  -- changes nothing in the project, hence triggers no rescan and cannot loop: the
  -- service will try again at the next reshuffle of the chain, and catches up on
  -- its own if the user corrects it by hand.
  if reaper.TrackFX_GetPinMappings(tr, t.c, 0, 2) == 1
     and reaper.TrackFX_GetPinMappings(tr, t.panel, 0, 2) == 4 then
    reaper.SetProjExtState(0, NS, "tap." .. g, mark)
  end
end

-- gp is absent as long as no plugin on the track needs the second route: the
-- common case pays nothing, neither a table nor an extra test per frame.
local function ScanTrack(tr, k, fxlist, panelfx)
  local comp, gate, gp = {}, {}, nil
  local nc, ng = 0, 0
  local muet = {}
  local vfx, vmk = nil, nil

  local last, dit = 0, {}

  for pos, fx in ipairs(fxlist) do
    if Plain(fx) then last = pos end
    if not IsPanel(tr, fx) then
      local native = IsGRSource(tr, fx)
      local e = (not native) and GRParam(tr, fx) or nil
      if native or e then
        if e then gp = gp or {}; gp[fx] = e end
        if IsGate(tr, fx) then
          if ng < NGATE then ng = ng + 1; gate[ng] = fx end
        elseif nc < NMAX then
          nc = nc + 1; comp[nc] = fx
        end

        -- What a plugin reports on its own takes precedence over any estimate,
        -- and rules it out besides: its reduction crosses the span of the virtual
        -- measurement, which would count it together with the silent one's. The
        -- list exists to refuse that confusion further down.
        dit[#dit + 1] = pos
      elseif Plain(fx) and IsDyn(tr, fx) then
        muet[#muet + 1] = { fx = fx, pos = pos, gate = IsGate(tr, fx) }
      end
    end
  end

  -- The virtual probe compares the panel's input to the chain's output: it
  -- therefore only measures a compressor that sits between the two, and it cannot
  -- untangle two successive reductions. One candidate downstream of the panel,
  -- then, and no source already reporting on its own: better a VU that announces
  -- it has no source than a VU displaying the sum of two compressors.
  local vmask, ppos, tight = 0, nil, false

  -- The probe through the pins first: where it exists it makes the fallback route
  -- moot -- the panel sits downstream of the compressor there, so the flat-chain
  -- geometry would not elect it anyway.
  local tap = TapFind(tr, fxlist)
  if tap then
    tight = tap.tight
    if tap.gate then
      if ng < NGATE then
        ng = ng + 1; gate[ng] = false
        vmask = 2 ^ (3 + ng)
      end
    elseif nc < NMAX then
      nc = nc + 1; comp[nc] = false
      vmask = 2 ^ (nc - 1)
    end
    if vmask > 0 then
      vfx = tap.fx
      if tight then vmk = MakeupParam(tr, tap.fx) end
    end

    -- Wired even if all six numbers are already taken by plugins that report:
    -- the panel is downstream of the compressor, and without the pins its Input
    -- level mode would read the chain's output believing it was reading the
    -- input.
    TapWire(tr, tap)
  end

  if not tap and panelfx and Plain(panelfx) then
    for pos, fx in ipairs(fxlist) do
      if fx == panelfx then ppos = pos; break end
    end
  end

  if ppos then
    for _, pos in ipairs(dit) do
      if pos > ppos then ppos = nil; break end
    end
  end

  if ppos then
    local seul = nil
    for _, m in ipairs(muet) do
      if m.pos > ppos then
        if seul then seul = nil; break end
        seul = m
      end
    end

    -- Tight span: the compressor immediately follows the panel and ends the
    -- chain. The two probes then frame it exactly, and the only static gain
    -- separating them is its own makeup -- which is what allows reading it
    -- instead of estimating it.
    tight = seul ~= nil and seul.pos == ppos + 1 and seul.pos == last

    -- Numbered after the sources that report: the numbering of an existing
    -- project does not move, and a VU already set keeps aiming at the same
    -- plugin.
    if seul then
      if seul.gate then
        if ng < NGATE then
          ng = ng + 1; gate[ng] = false
          vmask = 2 ^ (3 + ng)
        end
      elseif nc < NMAX then
        nc = nc + 1; comp[nc] = false
        vmask = 2 ^ (nc - 1)
      end
      if vmask > 0 then
        vfx = seul.fx
        if tight then vmk = MakeupParam(tr, seul.fx) end
      end
    end
  end

  if nc > 0 or ng > 0 then

    -- comp and gate carry `false` where the panel measures: that is a value, not
    -- a hole, so `#` stays correct and Publish skips the cell without clearing
    -- it. The counts are carried separately all the same, so that the claim does
    -- not depend on a subtlety of the table.
    sources[#sources + 1] = { tr = tr, k = k, fx = comp, gate = gate, gp = gp,
                              nc = nc, ng = ng, vmask = vmask,
                              vfx = vfx, vmk = vmk, vtap = tap ~= nil }
  end
end

local function TrackGUID(tr)
  return reaper.GetTrackGUID(tr)
end

local function TrackByGUID(g)
  local hit = tcache[g]
  if hit ~= nil then
    if hit == false then return nil end
    return hit
  end

  local found
  local m = reaper.GetMasterTrack(0)
  if reaper.GetTrackGUID(m) == g then
    found = m
  else
    for i = 0, reaper.CountTracks(0) - 1 do
      local tr = reaper.GetTrack(0, i)
      if reaper.GetTrackGUID(tr) == g then found = tr; break end
    end
  end
  tcache[g] = found or false
  return found
end

-- Key of a panel's link table. Ordinal 0 keeps the old key: an earlier project,
-- where a track had only one panel, finds its links exactly as they were. The
-- following panels each have their own -- that is what was missing, and what made
-- the second one wipe the first one's links.
local function LinkKey(trguid, ord)
  ord = ord or 0
  return ord == 0 and ("link." .. trguid) or ("link." .. trguid .. "." .. ord)
end

local function LoadLinks(trguid, ord)
  local t = {}
  local ok, v = reaper.GetProjExtState(0, NS, LinkKey(trguid, ord))
  if ok ~= 1 or not v or v == "" then return t end
  for line in v:gmatch("[^\n]+") do
    local el, tg, fg, pid = line:match("^(%d+)\t([^\t]*)\t([^\t]*)\t(.*)$")
    if el then t[tonumber(el)] = { tg = tg, fg = fg, pid = pid } end
  end
  return t
end

local function SaveLinks(trguid, ord, t)
  local out = {}
  for el, L in pairs(t) do
    out[#out + 1] = string.format("%d\t%s\t%s\t%s", el, L.tg, L.fg, L.pid)
  end
  table.sort(out)
  reaper.SetProjExtState(0, NS, LinkKey(trguid, ord), table.concat(out, "\n"))
end

-- Real detents of a target parameter. StripTease knobs are linear over 0..127:
-- on a stepped or binary parameter, sending an in-between value lets the plugin
-- round as it sees fit, and the panel then displays something other than what the
-- plugin kept. The value sent is therefore snapped to the parameter's own grid.
--
-- GetParameterStepSizes returns steps in the parameter's unit, not normalised:
-- the bounds from GetParamEx are needed to convert back. Continuous parameters
-- return false or a null step and are left alone, so the current behaviour is
-- unchanged for the vast majority of them.
-- `n` is the number of positions on the grid, not the number of intervals: it is
-- what the panel publishes to its knobs so that they turn in detents.
local function StepInfo(tr, fx, param)
  local ok, step, _, _, istoggle = reaper.TrackFX_GetParameterStepSizes(tr, fx, param)
  if not ok then return nil end
  if istoggle then return { toggle = true, n = 2 } end
  if not step or step <= 0 then return nil end

  local _, mn, mx = reaper.TrackFX_GetParamEx(tr, fx, param)
  if not mn or not mx or mx <= mn then return nil end

  -- Past a few hundred detents the quantisation brings nothing perceptible and
  -- would only add rounding noise.
  local n = (mx - mn) / step
  if n < 1 or n > 512 then return nil end

  return { min = mn, max = mx, step = step, n = math.floor(n + 0.5) + 1 }
end

local function Quantize(q, pv)
  if q.toggle then return pv >= 0.5 and 1 or 0 end
  local v = q.min + pv * (q.max - q.min)
  v = q.min + math.floor((v - q.min) / q.step + 0.5) * q.step
  if v < q.min then v = q.min elseif v > q.max then v = q.max end
  return (v - q.min) / (q.max - q.min)
end

local function ScanDirect(tr, slot, panelfx, trguid, ord)
  local mine = {}
  local t = LoadLinks(trguid, ord)

  -- Recover native parameter links saved with FX Chains.
  -- Every panel is ruled out, not just this one: a neighbouring panel's
  -- parameters are never a target, and a plink pointing from one to the other is
  -- not a Direct Link.
  for _, fx in ipairs(FXList(tr, trguid)) do
    if not IsPanel(tr, fx) then
      local np = reaper.TrackFX_GetNumParams(tr, fx) or 0
      for p = 0, np - 1 do
        local pre = "param." .. p .. "."
        local _, act = reaper.TrackFX_GetNamedConfigParm(tr, fx, pre .. "plink.active")
        if tonumber(act or "") == 1 then
          local _, eff = reaper.TrackFX_GetNamedConfigParm(tr, fx, pre .. "plink.effect")
          if tonumber(eff or "") == panelfx then
            local _, prm = reaper.TrackFX_GetNamedConfigParm(tr, fx, pre .. "plink.param")
            local el = tonumber(prm or "")
            if el then
              local _, fg = reaper.TrackFX_GetFXGUID(tr, fx)
              local _, pid = reaper.TrackFX_GetParamIdent(tr, fx, p)
              if fg and pid then
                t[el] = { tg = trguid, fg = fg, pid = pid }
              end
            end
          end
        end
      end
    end
  end

  if next(t) == nil then return mine end

  for el, L in pairs(t) do
    local ttr = TrackByGUID(L.tg)
    if ttr then
      local tfx = FXByGUID(ttr, L.tg, L.fg)
      if tfx then
        local pm = reaper.TrackFX_GetParamFromIdent(ttr, tfx, L.pid)
        if pm and pm >= 0 then
          local D = { ptr = tr, pfx = panelfx, slot = slot, el = el,
                      ttr = ttr, tfx = tfx, tparam = pm,
                      q = StepInfo(ttr, tfx, pm) }
          dlinks[#dlinks + 1] = D

          by_key[slot * KSTRIDE + el] = { tr = ttr, slot = slot, el = el,
                                          fx = tfx, param = pm }

          if L.tg == trguid then
            mine[#mine + 1] = { el = el, tfx = tfx, tparam = pm }
          end
        end
      end
    end
  end
  return mine
end

local function FXOccurrence(tr, trg, fx)
  local want = FXKeyC(tr, trg, fx)
  local seen = 0
  for _, f in ipairs(FXList(tr, trg)) do
    if f == fx then return seen, want end
    if FXKeyC(tr, trg, f) == want then seen = seen + 1 end
  end
  return 0, want
end

local function ReadWish(slot)
  local b = WSH + slot * WSTRIDE

  if (reaper.gmem_read(b) or 0) <= 0 then return nil end

  local n = math.floor(reaper.gmem_read(b + 2) or 0)
  if n <= 0 or n > WNAME then return nil end

  local cs = {}
  for i = 0, n - 1 do
    local c = math.floor(reaper.gmem_read(b + 3 + i) or 32)

    if c < 0 or c > 255 then return nil end
    cs[#cs + 1] = string.char(c)
  end

  local w = { name = table.concat(cs),
              occ  = math.floor(reaper.gmem_read(b + 1) or 0),
              p    = {} }
  local any = false
  for el = 0, NEL - 1 do
    local v = math.floor(reaper.gmem_read(b + 64 + el) or 0)
    if v > 0 then w.p[el] = v - 1; any = true end
  end
  if not any then return nil end
  return w
end

local function AnswerRecipe(slot, el, sametrack, tr, fx, param)
  local b = WSH + slot * WSTRIDE
  if sametrack then

    ResetCaches()
    local occ, nm = FXOccurrence(tr, TrackGUID(tr), fx)
    reaper.gmem_write(b + 129, el)
    reaper.gmem_write(b + 130, occ)
    reaper.gmem_write(b + 131, param)
    reaper.gmem_write(b + 132, #nm)
    for c = 1, #nm do reaper.gmem_write(b + 132 + c, nm:byte(c)) end
  else
    reaper.gmem_write(b + 132, 0)
  end
  reaper.gmem_write(b + 128, tick)
end

local function ProposeRecipe(tr, slot, mine, w, trg)
  local b = WSH + slot * WSTRIDE

  local groups, order = {}, {}
  for _, M in ipairs(mine) do
    local occ, nm = FXOccurrence(tr, trg, M.tfx)
    local key = occ .. "\t" .. nm
    local g = groups[key]
    if not g then
      g = { nm = nm, occ = occ, n = 0, p = {} }
      groups[key] = g
      order[#order + 1] = g
    end
    g.p[M.el] = M.tparam
    g.n = g.n + 1
  end

  local pick
  if w then
    for _, g in ipairs(order) do
      if g.nm == w.name and g.occ == w.occ then pick = g; break end
    end
  else
    for _, g in ipairs(order) do
      if not pick or g.n > pick.n then pick = g end
    end
  end

  if not pick then
    reaper.gmem_write(b + 258, 0)
    reaper.gmem_write(b + 256, tick)
    return
  end

  reaper.gmem_write(b + 257, pick.occ)
  reaper.gmem_write(b + 258, #pick.nm)
  for c = 1, #pick.nm do reaper.gmem_write(b + 258 + c, pick.nm:byte(c)) end
  for el = 0, NEL - 1 do
    reaper.gmem_write(b + 320 + el, pick.p[el] and (pick.p[el] + 1) or 0)
  end

  reaper.gmem_write(b + 256, tick)
end

local function FindWishFX(tr, trg, fxlist, w)
  local seen = 0
  for _, fx in ipairs(fxlist) do
    if FXKeyC(tr, trg, fx) == w.name then
      if seen == w.occ then return fx end
      seen = seen + 1
    end
  end

  -- Fallback on the old key: a recipe captured before FXKey became immune to
  -- renaming carries the displayed name. It worked, and it is left working. A
  -- fresh capture will rewrite it on the original name.
  seen = 0
  for _, fx in ipairs(fxlist) do
    if FXAltKey(tr, fx) == w.name then
      if seen == w.occ then return fx end
      seen = seen + 1
    end
  end
end

local function ScanWish(tr, slot, panelfx, fxlist, w, trg)
  if not w then return end

  local hit = FindWishFX(tr, trg, fxlist, w)
  if not hit then return end

  local np = reaper.TrackFX_GetNumParams(tr, hit) or 0
  for el, p in pairs(w.p) do
    if not by_key[slot * KSTRIDE + el] and p < np then
      local D = { ptr = tr, pfx = panelfx, slot = slot, el = el,
                  ttr = tr, tfx = hit, tparam = p,
                  q = StepInfo(tr, hit, p) }
      dlinks[#dlinks + 1] = D
      by_key[slot * KSTRIDE + el] = { tr = tr, slot = slot, el = el,
                                      fx = hit, param = p }
    end
  end
end

local PSIZES      = { "050", "100", "150", "200", "300", "400", "600" }
local PSYNC_EVERY = 60
local PDIR        = reaper.GetResourcePath() .. "/presets/"

local pprefix = nil
local pbank   = nil
local pseen   = {}
local psize   = {}
local pfull   = 0

-- Line ending of the banks, read on load and given back on write.
--
-- REAPER writes these files with the platform's line endings, so CRLF on Windows.
-- Rewriting them systematically in LF changed their size at every preset save:
-- the size comparison saw a change, re-read and re-parsed the seven banks
-- (~350 kB), and rewrote them -- for the sole pleasure of returning the same
-- bytes.
local peol = "\n"

local function PEol(s)
  return s:find("\r\n", 1, true) and "\r\n" or "\n"
end

-- The 7 preset banks are ~50 kB each and only change when a preset is saved.
-- Re-reading and re-parsing them every 2 s costs ~350 kB of continuous reading
-- and parsing, for nothing most of the time. Their size is compared first (a
-- single seek, no read), and a full re-read is forced at regular intervals in
-- case a change preserved the exact size (renaming a preset to a name of the same
-- length).
local PSYNC_FULL_EVERY = 15
local psync   = 1

local function PPrefix()
  local i = 0
  while true do
    local f = reaper.EnumerateFiles(PDIR, i)
    if not f or f == "" then return nil end
    local p = f:match("^js%-(.*)StripTease Panel %d+ px%.ini$")
    if p then return p end
    i = i + 1
  end
end

local function PPath(px)
  return PDIR .. "js-" .. pprefix .. "StripTease Panel " .. px .. " px.ini"
end

local function PSize(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local n = f:seek("end")
  f:close()
  return n
end

local function PRead(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function PParse(s)
  local gen, list, cur = {}, {}, nil
  local nb = nil
  for line in (s .. "\n"):gmatch("([^\n]*)\n") do
    line = line:gsub("\r$", "")
    local sec = line:match("^%[(.-)%]%s*$")
    if sec then
      cur = nil
      if sec:match("^Preset%d+$") then
        cur = { lines = {} }
        list[#list + 1] = cur
      elseif sec == "General" then
        cur = gen
      end
    elseif line ~= "" then
      if cur == gen then
        local v = line:match("^NbPresets=(%d+)")
        if v then nb = tonumber(v) else gen[#gen + 1] = line end
      elseif cur then
        cur.lines[#cur.lines + 1] = line
      end
    end
  end

  for _, p in ipairs(list) do
    p.text = table.concat(p.lines, "\n")
    local nm = nil
    for _, l in ipairs(p.lines) do nm = l:match("^Name=(.*)$") or nm end
    if nm and nm ~= "" then
      p.key = nm:match('^"(.*)"$') or nm
    else
      p.key = "\0" .. p.text
    end
  end
  return list, gen, nb
end

local function PBuild(bank, gen)
  local out = { "[General]", "NbPresets=" .. #bank }
  for _, l in ipairs(gen) do out[#out + 1] = l end
  out[#out + 1] = ""
  for i, p in ipairs(bank) do
    out[#out + 1] = "[Preset" .. (i - 1) .. "]"
    out[#out + 1] = p.text
    out[#out + 1] = ""
  end
  local s = table.concat(out, "\n") .. "\n"

  -- p.text is normalised to LF: it is a preset's identity, compared from one bank
  -- to the next and from one cycle to the next. The conversion therefore happens
  -- on output, on the whole file, and does not touch that identity.
  if peol ~= "\n" then s = s:gsub("\n", peol) end
  return s
end

local function PApply(cur)
  local at = {}
  for i, p in ipairs(pbank) do at[p.key] = i end

  local have = {}
  for _, p in ipairs(cur) do
    have[p.key] = true
    local i = at[p.key]
    if not i then
      pbank[#pbank + 1] = p
      at[p.key] = #pbank
    elseif p.text ~= pbank[i].text then
      pbank[i] = p
    end
  end

  local keep = {}
  for _, p in ipairs(pbank) do
    if have[p.key] then keep[#keep + 1] = p end
  end
  pbank = keep
end

local function PSync()
  pprefix = pprefix or PPrefix()
  if not pprefix then return end

  pfull = pfull + 1
  local full = pfull >= PSYNC_FULL_EVERY
  if full then pfull = 0 end

  if pbank and not full then
    local moved = false
    for _, px in ipairs(PSIZES) do
      if PSize(PPath(px)) ~= psize[px] then moved = true break end
    end
    if not moved then return end
  end

  local raw, cut, gen, changed = {}, {}, {}, {}

  -- Read on every cycle, from the files themselves: a single bank in CRLF is
  -- enough for all of them to be given back in CRLF, which is the case for all
  -- seven on one installation.
  peol = "\n"

  for _, px in ipairs(PSIZES) do
    local s = PRead(PPath(px))
    psize[px] = s and #s or nil
    if s then
      if PEol(s) == "\r\n" then peol = "\r\n" end
      local list, g, nb = PParse(s)
      if nb == #list then
        raw[px], cut[px], gen[px] = s, list, g
        if s ~= pseen[px] then changed[#changed + 1] = px end
      end
    end
  end

  if pbank then
    if #changed == 0 then return end
    for _, px in ipairs(changed) do PApply(cut[px]) end
  else

    pbank = {}
    local at = {}
    for _, px in ipairs(PSIZES) do
      for _, p in ipairs(cut[px] or {}) do
        if not at[p.key] then
          at[p.key] = true
          pbank[#pbank + 1] = p
        end
      end
    end
  end

  if #pbank == 0 then
    local any = false
    for _, px in ipairs(PSIZES) do any = any or (raw[px] ~= nil) end
    if not any then return end
  end

  for _, px in ipairs(PSIZES) do
    local s = PBuild(pbank, gen[px] or {})
    local ok = (s == raw[px])
    if not ok then
      local f = io.open(PPath(px), "wb")
      if f then
        f:write(s)
        f:close()
        ok = true
      end
    end
    if ok then pseen[px] = s end
  end
end

local function Rescan()
  sources, by_key, dlinks, panels, slots = {}, {}, {}, {}, {}

  ResetCaches()

  -- Reserve of slots for the panels that are not the first of their track. It is
  -- handed out in track order then chain order: as long as the arrangement does
  -- not move, each panel finds the same slot from one rescan to the next, and
  -- nothing has to be republished.
  local pool = MAXTRK + 1

  local function scan(tr, k)

    local trg = TrackGUID(tr)
    local fxlist = FXList(tr, trg)

    local plist = {}
    for _, fx in ipairs(fxlist) do
      if IsPanel(tr, fx) then plist[#plist + 1] = fx end
    end

    if #plist == 0 then
      reaper.gmem_write(PAN + k * PSTRIDE, 0)
      return
    end

    -- GR is only published for the tracks carrying a panel: the JSFX only reads
    -- sb_GR + (its own track) * 8, so feeding the others has no consumer at all.
    -- StripTease Check queries GainReduction_dB directly and does not depend on
    -- this publication.
    --
    -- Once per track, and on the first panel: the geometry of the virtual
    -- measurement channel is judged on the highest panel in the chain, the very
    -- one the panels elect among themselves in GR_VIRT.
    ScanTrack(tr, k, fxlist, plist[1])
    panels[#panels + 1] = { tr = tr, k = k }

    local np = math.min(#plist, NPAN)
    local pb = PAN + k * PSTRIDE

    for j = 1, np do
      local panelfx = plist[j]

      -- The first panel keeps its track's slot; past the reserve there is no slot
      -- left to give and the panel stays on its fallbacks -- which is exactly what
      -- it used to do.
      local slot
      if j == 1 then
        slot = k
      elseif pool < NSLOT then
        slot = pool
        pool = pool + 1
      end

      if slot then
        -- The position announced is the one get_host_placement gives the JSFX:
        -- the index in the top-level chain. A panel housed in a container or in
        -- the input FX is not addressed the same way on both sides; no position
        -- is announced then, and the JSFX falls back on its fallbacks.
        local pos = (panelfx >= 0 and panelfx < 0x1000000) and (panelfx + 1) or 0
        reaper.gmem_write(pb + 1 + (j - 1) * 2, pos)
        reaper.gmem_write(pb + 2 + (j - 1) * 2, slot)

        slots[slot] = { tr = tr, k = k, fx = panelfx, ord = j - 1 }

        for el = 0, NEL - 1 do
          reaper.gmem_write(LNK + slot * KSTRIDE + el, 0)
        end

        local id = trg .. "#" .. (j - 1)
        if owned[slot] ~= id then
          owned[slot] = id
          for el = 0, NEL - 1 do dstate[slot * KSTRIDE + el] = nil end
        end

        local w = ReadWish(slot)
        local mine = ScanDirect(tr, slot, panelfx, trg, j - 1)
        ScanWish(tr, slot, panelfx, fxlist, w, trg)

        ProposeRecipe(tr, slot, mine, w, trg)
      end
    end

    -- The count last: written before the pairs, it would have sent a panel to a
    -- slot not yet published.
    reaper.gmem_write(pb, np)
  end

  scan(reaper.GetMasterTrack(0), 0)
  local n = math.min(reaper.CountTracks(0), MAXTRK)
  for i = 0, n - 1 do
    scan(reaper.GetTrack(0, i), i + 1)
  end

  -- Tracks that no longer exist: their announcement would send a future panel
  -- looking for the slot of a track that is gone. gmem survives a project
  -- change.
  for k = n + 1, MAXTRK do
    reaper.gmem_write(PAN + k * PSTRIDE, 0)
  end

  local seen = {}
  for _, s in ipairs(sources) do
    seen[s.k] = true
    ClaimGR(s.k, s.nc, s.ng)

    -- Election of the panel that measures: reset to a number larger than any
    -- chain position, the track's panels bring it back down to the smallest of
    -- theirs, and the one that recognises itself there measures. The arbitration
    -- is thus settled between panels, without confronting the position the JSFX
    -- sees with the one the service counts on its own side.
    reaper.gmem_write(GRV + s.k * VSTRIDE + 1, VNONE)
  end
  for k = 0, MAXTRK do
    if not seen[k] then
      ClaimGR(k, 0, 0)

      -- gmem survives a project change: a mask left by an earlier track would
      -- have a panel measure for a compressor that is no longer there.
      reaper.gmem_write(GRV + k * VSTRIDE, 0)
    end
  end
end

-- Heartbeat of the panel that measures. The service cannot simply leave the cell
-- as it stands when the panel goes quiet: the freshness stamp is shared by the
-- whole track and the service keeps moving it forward, so a last value would stay
-- on display as if it were alive. A silent panel -- bypassed, deleted, or nothing
-- crossing the track any more -- therefore counts as zero reduction, and the
-- needle falls back to rest.
local VDEAD = 0.5
local vhb   = {}

local function Heartbeat(s, b, now)
  local hb = reaper.gmem_read(GRV + s.k * VSTRIDE + 2)
  local st = vhb[s.k]

  if not st or st.v ~= hb then
    vhb[s.k] = { v = hb, t = now }
    return
  end
  if now - st.t <= VDEAD then return end

  local bit = 0
  while bit < 6 do
    if s.vmask % (2 ^ (bit + 1)) >= 2 ^ bit then
      reaper.gmem_write(b + 2 + bit, 0)
    end
    bit = bit + 1
  end
end

local vcache = {}

local function Valid(tr)
  local v = vcache[tr]
  if v == nil then
    v = reaper.ValidatePtr2(0, tr, "MediaTrack*")
    vcache[tr] = v
  end
  return v
end

local function Run()
  if reaper.GetExtState(NS, "stop") == "1" then return end

  FitBump()
  vcache = {}

  rescan = rescan - 1
  if rescan <= 0 then
    -- Rescan enumerates every track and every FX on them: no point doing it
    -- again if the project has not moved an inch since last time. The counter
    -- changes as soon as a parameter moves, so the saving only covers genuinely
    -- idle periods -- but in the worst case this falls back on the previous
    -- behaviour, never worse.
    local pc = reaper.GetProjectStateChangeCount(0)
    if force_rescan or pc ~= pstate then
      pstate = pc
      force_rescan = false
      Rescan()
    end
    rescan = RESCAN_EVERY
  end

  psync = psync - 1
  if psync <= 0 then PSync(); psync = PSYNC_EVERY end

  -- Candidate readouts under observation. The basket is empty in almost every
  -- session, and a candidate only stays in it long enough to be decided -- one
  -- parameter read and one meter read per frame.
  for key, c in pairs(pend) do
    if Valid(c.tr) then VConfirm(c.tr, c.fx, key, c) else pend[key] = nil end
  end

  tick = tick + 1
  if tick > 10000000 then tick = 1 end

  -- The service's clock, readable from the StripTease GR JSFX: it is the only way
  -- for it to tell a live claim from a leftover placed in shared memory by a
  -- service that has stopped. Without it, stopping the service would leave the
  -- JSFX silent until REAPER is restarted.
  reaper.gmem_write(SVC, tick)

  local now = reaper.time_precise()

  for _, s in ipairs(sources) do
    if Valid(s.tr) then
      local b = GR + s.k * STRIDE

      Publish(s.tr, b, s.fx,   NMAX,  1, s.k * 16,     s.gp)
      Publish(s.tr, b, s.gate, NGATE, 5, s.k * 16 + 8, s.gp)

      reaper.gmem_write(b + 1, s.nc + s.ng * 16)
      reaper.gmem_write(b, tick)

      reaper.gmem_write(GRV + s.k * VSTRIDE, s.vmask)
      if s.vmask > 0 or s.vtap then
        local vb = GRV + s.k * VSTRIDE

        -- Flags re-read on every frame: the makeup can stop being readable along
        -- the way -- automatic makeup engaged, pan opened -- and the measurement
        -- must then fall back on the estimator without waiting for a rescan.
        local f = 0
        if s.vfx and MonoFX(s.tr, s.vfx) then f = f + 2 end

        -- The pan sits after the container: between two probes taken inside it,
        -- it does not enter the gap and therefore has nothing to say about
        -- reading the makeup. It only counts for the fallback route, whose output
        -- probe is the track meter.
        if s.vmk and (s.vtap or PanNeutral(s.tr)) then
          local mk = MakeupDB(s.tr, s.vfx, s.vmk)
          if mk then
            reaper.gmem_write(vb + 3, mk)
            f = f + 1
          end
        end

        -- Makeup not readable: the panel's estimator holds the static gain, and
        -- it only comes back down over thirty seconds. Moving the makeup during
        -- playback would therefore leave it wrong for all that time. The plugin's
        -- settings are watched, and the panel is told to redo it quickly.
        if f % 2 == 0 and s.vfx then
          local j = Jolt(s, now)
          if j and now - j < 2 then f = f + 8 end
        end

        if s.vtap then
          f = f + 4

          -- Latency announced by the compressor. The panel delays its input probe
          -- by that much: without that realignment, an attack read ahead of the
          -- output would count as a reduction over the whole transient.
          local pdc = 0
          if s.vfx then
            local _, v = reaper.TrackFX_GetNamedConfigParm(s.tr, s.vfx, "pdc")
            pdc = tonumber(v or "") or 0
          end
          reaper.gmem_write(vb + 7, pdc)

          -- The mix, in cell 4 -- free on this route, where the chain levels are
          -- no longer of use. Only with a read makeup: the estimator already
          -- absorbs the mix into its static gain, and taking it out afterwards
          -- would count it twice.
          if f % 2 == 1 and s.vmk then
            local m = MakeupMix(s.tr, s.vfx, s.vmk)
            if m then
              reaper.gmem_write(vb + 4, m)
              f = f + 16
            end
          end
        end
        reaper.gmem_write(vb + 6, f)

        -- Published before the TL stamp, further down: it is its change that
        -- triggers the measurement in the panel, which will read these two cells
        -- straight after. Writing them after it would have the current window
        -- compared to the previous window's levels.
        --
        -- Nothing to publish when the probe is wired: the panel holds both of its
        -- probes itself, and cell 4 then serves the mix.
        if not s.vtap then
          local l, r = TrackLevelsDB(s.tr)
          if l then
            reaper.gmem_write(vb + 4, l)
            reaper.gmem_write(vb + 5, r)
          end
        end
        Heartbeat(s, b, now)
      end
    end
  end

  for _, p in ipairs(panels) do
    if Valid(p.tr) then
      local l, r = TrackLevelsDB(p.tr)
      if l then
        reaper.gmem_write(TL + p.k * 2, math.max(l, r))
        reaper.gmem_write(TL + p.k * 2 + 1, tick)
        reaper.gmem_write(TL + 512 + p.k * 2, l)
        reaper.gmem_write(TL + 1024 + p.k * 2, r)
      end
      end
  end

  for _, D in ipairs(dlinks) do
    if Valid(D.ptr) and Valid(D.ttr) then
      local pv = reaper.TrackFX_GetParamNormalized(D.ptr, D.pfx, D.el)
      local tv = reaper.TrackFX_GetParamNormalized(D.ttr, D.tfx, D.tparam)
      if pv and tv and pv >= 0 and tv >= 0 then
        local key = D.slot * KSTRIDE + D.el
        local st  = dstate[key]
        if not st then

          st = { lp = pv, lt = tv }
          dstate[key] = st
        else
          if math.abs(pv - st.lp) > DEAD then
            local wv = D.q and Quantize(D.q, pv) or pv
            -- On a stepped parameter, sweeping the knob now produces one write
            -- per detent instead of one per frame.
            if wv ~= st.lw then
              reaper.TrackFX_SetParamNormalized(D.ttr, D.tfx, D.tparam, wv)
              st.lt = reaper.TrackFX_GetParamNormalized(D.ttr, D.tfx, D.tparam) or wv
              st.lw = wv
            end
            st.lp = pv
          elseif math.abs(tv - st.lt) > DEAD then
            reaper.TrackFX_SetParamNormalized(D.ptr, D.pfx, D.el, tv)
            st.lp = reaper.TrackFX_GetParamNormalized(D.ptr, D.pfx, D.el) or tv
            st.lt = tv
          end
        end
        -- 1 = linked and continuous, 1 + N = linked to a parameter with N
        -- positions. The panel reads there what it takes to give its knob the same
        -- detents as the target; everything that tests the link only looks at
        -- "> 0".
        reaper.gmem_write(LNK + D.slot * KSTRIDE + D.el,
                          D.q and (1 + D.q.n) or 1)
      end
    end
  end


  local lk   = math.floor(reaper.gmem_read(LRN)     or -1)
  local lel  = math.floor(reaper.gmem_read(LRN + 1) or -1)
  local lst  = reaper.gmem_read(LRN + 2) or 0
  local lmod = math.floor(reaper.gmem_read(LRN + 3) or 0)

  local function Answer(code)
    served = learn and learn.stamp or served
    reaper.gmem_write(LRN + 4, code)
    reaper.gmem_write(LRN + 5, tick)
    reaper.gmem_write(LRN + 6, learn and learn.k  or -1)
    reaper.gmem_write(LRN + 7, learn and learn.el or -1)
    -- stamp of the request that was served: without it the JSFX accepts a stale
    -- answer as soon as (track, element) match, because LRN+6/+7 keep the values
    -- of the previous answer.
    reaper.gmem_write(LRN + 8, learn and learn.stamp or -1)
    learn = nil
    rescan = 0
    force_rescan = true
  end

  local function PanelTrack(k)
    if k <= 0 then return reaper.GetMasterTrack(0) end
    return reaper.GetTrack(0, k - 1)
  end

  -- The requesting panel, known by its slot alone: its track, its FX index, its
  -- rank among the track's panels.
  --
  -- The slot gives the track and the rank; the index, on the other hand, is
  -- re-read at every call and never taken from the last rescan. An FX inserted in
  -- the chain shifts every one that follows it, and a native link written on a
  -- stale index would aim at a different plugin. EnumFX descends into containers,
  -- like the normal scan.
  --
  -- The fallback covers the panel added since the last rescan: with no directory
  -- it has no slot other than its track's, where it is the first.
  local function PanelBySlot(sl)
    local tr, ord
    local pn = slots[sl]
    if pn then
      tr, ord = pn.tr, pn.ord
    elseif sl >= 0 and sl <= MAXTRK then
      tr, ord = PanelTrack(sl), 0
    end
    if not tr or not Valid(tr) then return nil end

    local n = 0
    for _, fx in ipairs(EnumFX(tr, nil, {})) do
      if IsPanel(tr, fx) then
        if n == ord then return tr, fx, ord end
        n = n + 1
      end
    end
  end

  -- The JSFX has no destruction hook: if the panel disappears during a learn, its
  -- request stays written in gmem and the next parameter touched would link to a
  -- ghost element. So the panel is checked to be still there.
  local function PanelAlive(sl)
    return PanelBySlot(sl) ~= nil
  end

  local function TouchedTrack(i)
    if i < 0 then return reaper.GetMasterTrack(0) end
    return reaper.GetTrack(0, i)
  end

  local function ParamValue(tr_i, fx, pm)
    local tr = TouchedTrack(tr_i)
    if not tr then return nil end
    return reaper.TrackFX_GetParamNormalized(tr, fx, pm)
  end

  if lk >= 0 and lel >= 0 and lst ~= served then
    if not learn or learn.stamp ~= lst then
      -- Modes : 0 apprendre un Direct Link, 1 l'effacer.
      if lmod == 1 then

        local ptr, _, pord = PanelBySlot(lk)
        if ptr then
          local g = TrackGUID(ptr)
          local t = LoadLinks(g, pord)
          local old = t[lel]
          if old and old.tg == g then
            local ttr = TrackByGUID(g)
            if ttr then
              local tfx = FXByGUID(ttr, old.tg, old.fg)
              if tfx then
                local pm = reaper.TrackFX_GetParamFromIdent(ttr, tfx, old.pid)
                if pm and pm >= 0 then
                  reaper.TrackFX_SetNamedConfigParm(ttr, tfx, "param."..pm..".plink.active", "0")
                end
              end
            end
          end
          t[lel] = nil
          SaveLinks(g, pord, t)
          dstate[lk * KSTRIDE + lel] = nil
          reaper.gmem_write(LNK + lk * KSTRIDE + lel, 0)
        end
        learn = { k = lk, el = lel, stamp = lst }
        Answer(4)
      else
        local ok, btr, bit_, btk, bfx, bpm = reaper.GetTouchedOrFocusedFX(0)

        -- REAPER exposes the "last touched parameter" state for writing: writing
        -- a negative value into last_touched takes that status away from the FX.
        -- The reference is therefore cleared instead of compared: after that, any
        -- return from GetTouchedOrFocusedFX is necessarily a fresh gesture,
        -- including on the very parameter the user had just moved.
        local cleared = false
        if ok then
          local btrk = TouchedTrack(btr)
          if btrk then
            reaper.TrackFX_SetNamedConfigParm(btrk, bfx, "last_touched", "-1")
            local ok2, t2, _, _, f2, p2 = reaper.GetTouchedOrFocusedFX(0)
            cleared = not (ok2 and t2 == btr and f2 == bfx and p2 == bpm)
          end
        end

        learn = { k = lk, el = lel, stamp = lst, t0 = reaper.time_precise(),
                  cleared = cleared,
                  btr = ok and btr or -999,
                  bfx = ok and bfx or -999,
                  bpm = ok and bpm or -999 }

        -- Fallback if the clearing did not take (REAPER too old): this falls back
        -- on the value comparison, which misses the click-without-movement case.
        learn.bval = (not cleared) and ok and ParamValue(btr, bfx, bpm) or nil
      end
    elseif learn.t0 and tick - (learn.chk or 0) >= PANEL_CHECK_EVERY
           and not PanelAlive(learn.k) then

      -- panel deleted during the learn: this cancels and clears the request
      reaper.gmem_write(LRN, -1)
      served = lst
      learn  = nil

    elseif learn.t0 then
      if tick - (learn.chk or 0) >= PANEL_CHECK_EVERY then learn.chk = tick end

      local ok, ttr_i, it_i, tk_i, tfx, tpm = reaper.GetTouchedOrFocusedFX(0)

      local fresh
      if learn.cleared then
        fresh = ok
      else
        local same = (ttr_i == learn.btr and tfx == learn.bfx and tpm == learn.bpm)
        local moved = false
        if ok and same and learn.bval then
          local v = ParamValue(ttr_i, tfx, tpm)
          moved = v ~= nil and math.abs(v - learn.bval) > 1e-9
        end
        fresh = ok and (not same or moved)
      end

      if fresh and it_i < 0 then
        local ttr = (ttr_i < 0) and reaper.GetMasterTrack(0)
                                or reaper.GetTrack(0, ttr_i)
        if not ttr then
          Answer(3)
        elseif IsPanel(ttr, tfx) then

          Answer(3)
        else
          local ptr, ppanelfx, pord = PanelBySlot(learn.k)
          if not ptr then
            Answer(3)
          else
            local _, pid = reaper.TrackFX_GetParamIdent(ttr, tfx, tpm)
            local fg = reaper.TrackFX_GetFXGUID(ttr, tfx)
            if pid and pid ~= "" and fg and fg ~= "" then
              local g = TrackGUID(ptr)

              local t = LoadLinks(g, pord)
              t[learn.el] = { tg = TrackGUID(ttr), fg = fg, pid = pid }
              SaveLinks(g, pord, t)

              -- The native link points at the panel that asked, and not at the
              -- first one on the track: that is how the second panel used to
              -- hijack the first one's knobs.
              if TrackGUID(ttr) == g and ppanelfx then
                local pre = "param." .. tpm .. "."
                reaper.TrackFX_SetNamedConfigParm(ttr, tfx, pre .. "plink.active", "1")
                reaper.TrackFX_SetNamedConfigParm(ttr, tfx, pre .. "plink.effect", tostring(ppanelfx))
                reaper.TrackFX_SetNamedConfigParm(ttr, tfx, pre .. "plink.param", tostring(learn.el))
              end

              dstate[learn.k * KSTRIDE + learn.el] = nil

              -- The link is announced right away, detents included: without the
              -- number of positions the knob would turn continuously until the
              -- next rescan.
              local q = StepInfo(ttr, tfx, tpm)
              reaper.gmem_write(LNK + learn.k * KSTRIDE + learn.el,
                                q and (1 + q.n) or 1)

              AnswerRecipe(learn.k, learn.el, TrackGUID(ttr) == g, ttr, tfx, tpm)
              Answer(1)
            else
              Answer(3)
            end
          end
        end
      elseif reaper.time_precise() - learn.t0 > LEARN_TIMEOUT then
        Answer(2)
      end
    end
  else
    learn = nil
  end

  local REN_REQ = 49200
  if reaper.gmem_read(REN_REQ) == 1 then
    -- REN_REQ + 1 and + 2 carry the requesting track and element: it is the JSFX
    -- that reads them back to check the answer is indeed its own, the service does
    -- not need to know them.
    local r_len = math.floor(reaper.gmem_read(REN_REQ + 3) or 0)
    local def_str = ""
    for i = 1, r_len do
      def_str = def_str .. string.char(math.floor(reaper.gmem_read(REN_REQ + 3 + i) or 0))
    end

    reaper.gmem_write(REN_REQ, 99)

    local ok, ret = reaper.GetUserInputs("Rename Control", 1, "New name:,extrawidth=50", def_str)

    if ok then
      local nlen = math.min(12, string.len(ret))
      reaper.gmem_write(REN_REQ + 3, nlen)
      for i = 1, nlen do
        reaper.gmem_write(REN_REQ + 3 + i, string.byte(ret, i))
      end
      reaper.gmem_write(REN_REQ, 2)
    else
      reaper.gmem_write(REN_REQ, 3)
    end
  end

  local PAL_REQ = 49232
  if reaper.gmem_read(PAL_REQ) == 1 then
    reaper.gmem_write(PAL_REQ, 99)

    -- GR_SelectColor comes from the SWS extension, which is optional for
    -- StripTease. Without a guard, opening the palette kills the service (calling
    -- a nil value) and leaves the panel stuck on state 99, waiting for an answer
    -- that will never come.
    local ok, col = false, 0
    if reaper.GR_SelectColor then
      ok, col = reaper.GR_SelectColor(reaper.GetMainHwnd(), 0)
    elseif not sws_warned then
      sws_warned = true
      reaper.ShowMessageBox(
        "Custom colours use the colour picker of the SWS extension, which is" ..
        "\nnot installed.\n\nThe colours of the basic palette remain available.",
        "StripTease", 0)
    end

    if ok and ok ~= 0 then
      local r, g, b = reaper.ColorFromNative(col)
      reaper.gmem_write(PAL_REQ + 1, r * 65536 + g * 256 + b)
      reaper.gmem_write(PAL_REQ, 2)
    else
      reaper.gmem_write(PAL_REQ, 3)
    end
  end

  local rk  = math.floor(reaper.gmem_read(REQ)     or -1)
  local rel = math.floor(reaper.gmem_read(REQ + 1) or -1)
  local served = false
  if rk >= 0 and rel >= 0 then
    local L = by_key[rk * KSTRIDE + rel]
    if L and Valid(L.tr) then
      local ok, s = reaper.TrackFX_GetFormattedParamValue(L.tr, L.fx, L.param, "")
      if ok and s ~= "" then
        s = s:sub(1, TIPMAX)
        reaper.gmem_write(RSP,     rk)
        reaper.gmem_write(RSP + 1, rel)
        reaper.gmem_write(RSP + 2, #s)
        reaper.gmem_write(RSP + 3, tick)
        for c = 1, #s do reaper.gmem_write(RSP + 3 + c, s:byte(c)) end
        served = true
      end
    end
  end

  if not served then reaper.gmem_write(RSP + 2, 0) end

  if tick % 8 == 1 then
    reaper.SetExtState(NS, "alive", tostring(reaper.time_precise()), false)
  end
  reaper.defer(Run)
end

local alive = tonumber(reaper.GetExtState(NS, "alive") or "")
if alive ~= nil and (reaper.time_precise() - alive) < 1.0 then
  reaper.SetExtState(NS, "stop", "1", false)
  return
end

reaper.SetExtState(NS, "stop", "0", false)
reaper.set_action_options(4)

reaper.atexit(function()
  reaper.set_action_options(8)
  reaper.DeleteExtState(NS, "alive", false)
end)

Run()
