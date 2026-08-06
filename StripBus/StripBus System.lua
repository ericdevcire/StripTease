-- ============================================================================
-- StripBus System
-- Version: 1.0
-- Developer: Eric Avondo
--
-- License & Copyright Information (Freeware):
-- StripBus is provided as freeware. You are fully permitted to use and
-- modify this software for your personal workflow. However, it is strictly
-- prohibited to sell, commercially repackage, or redistribute for profit
-- this original version or any of its modified derivatives.
-- ============================================================================

local NS     = "StripBusGR"
local GR     = 4096
local STRIDE = 8
local NMAX   = 4
local NGATE  = 2
local MAXTRK = 255

local CCM     = 16384
local FBK     = 32768
local KSTRIDE = 64
local NEL     = 50
local PMAX    = 512

local REQ    = 49152
local RSP    = 49160
local TIPMAX = 23

local LRN  = 12288

local TL   = 61440

local LNK  = 65536

local WSH     = 131072
local WSTRIDE = 512
local WNAME   = 60

local function FXKey(tr, fx)
  local _, nm = reaper.TrackFX_GetFXName(tr, fx, "")
  return nm:sub(1, WNAME)
end

local DEAD = 0.0004
local LEARN_TIMEOUT = 20

local RESCAN_EVERY = 60

reaper.gmem_attach("StripBus")

local sources = {}
local links   = {}
local by_key  = {}
local panels  = {}

local dlinks  = {}
local dstate  = {}
local learn   = nil
local served  = nil

local tick    = 0
local rescan  = 0

local prev    = {}

local ecache  = {}
local fgcache = {}
local ncache  = {}
local tcache  = {}

local function ResetCaches()
  ecache, fgcache, ncache, tcache = {}, {}, {}, {}
end

local function Publish(tr, b, list, n, off, kbase)
  for j = 1, n do
    local db = 0
    if list[j] then
      local ok, v = reaper.TrackFX_GetNamedConfigParm(tr, list[j], "GainReduction_dB")

      db = math.abs(ok and tonumber(v) or 0)
    end
    local key = kbase + j
    local pv  = prev[key] or 0
    prev[key] = db
    reaper.gmem_write(b + off + j, db > pv and db or pv)
  end
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

local function ScanTrack(tr, k, fxlist)
  local comp, gate = {}, {}
  for _, fx in ipairs(fxlist) do
    if IsGRSource(tr, fx) then
      if IsGate(tr, fx) then
        if #gate < NGATE then gate[#gate + 1] = fx end
      elseif #comp < NMAX then
        comp[#comp + 1] = fx
      end
    end
  end
  if #comp > 0 or #gate > 0 then
    sources[#sources + 1] = { tr = tr, k = k, fx = comp, gate = gate }
  end
end

local function IsPanel(tr, fx)
  local ok, id = reaper.TrackFX_GetNamedConfigParm(tr, fx, "fx_ident")
  if ok and id ~= "" and id:lower():find("stripbus panel", 1, true) then
    return true
  end
  local _, nm = reaper.TrackFX_GetFXName(tr, fx, "")
  return nm:lower():find("stripbus panel", 1, true) ~= nil
end

local function LearnedCC(tr, fx, p)
  local pre = "param." .. p .. "."

  local ok1, m1 = reaper.TrackFX_GetNamedConfigParm(tr, fx, pre .. "learn.midi1")
  local b1 = ok1 and tonumber(m1 or "") or nil
  if b1 and b1 >= 176 and b1 <= 191 then
    local _, m2 = reaper.TrackFX_GetNamedConfigParm(tr, fx, pre .. "learn.midi2")
    local cc = tonumber(m2 or "")
    if cc then return cc, b1 - 176 end
  end

  local _, act = reaper.TrackFX_GetNamedConfigParm(tr, fx, pre .. "plink.active")
  if tonumber(act or "") == 1 then
    local _, eff = reaper.TrackFX_GetNamedConfigParm(tr, fx, pre .. "plink.effect")
    if tonumber(eff or "") == -100 then
      local _, msg  = reaper.TrackFX_GetNamedConfigParm(tr, fx, pre .. "plink.midi_msg")
      local _, msg2 = reaper.TrackFX_GetNamedConfigParm(tr, fx, pre .. "plink.midi_msg2")
      local _, mch  = reaper.TrackFX_GetNamedConfigParm(tr, fx, pre .. "plink.midi_chan")
      local m  = tonumber(msg or "")
      local cc = tonumber(msg2 or "")
      local ch = tonumber(mch or "")
      if cc and (m == nil or m == 11 or (m >= 176 and m <= 191)) then
        return cc, (ch and ch > 0) and (ch - 1) or -1
      end
    end
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

local function LoadLinks(trguid)
  local t = {}
  local ok, v = reaper.GetProjExtState(0, NS, "link." .. trguid)
  if ok ~= 1 or not v or v == "" then return t end
  for line in v:gmatch("[^\n]+") do
    local el, tg, fg, pid = line:match("^(%d+)\t([^\t]*)\t([^\t]*)\t(.*)$")
    if el then t[tonumber(el)] = { tg = tg, fg = fg, pid = pid } end
  end
  return t
end

local function SaveLinks(trguid, t)
  local out = {}
  for el, L in pairs(t) do
    out[#out + 1] = string.format("%d\t%s\t%s\t%s", el, L.tg, L.fg, L.pid)
  end
  table.sort(out)
  reaper.SetProjExtState(0, NS, "link." .. trguid, table.concat(out, "\n"))
end

local function ScanDirect(tr, k, panelfx, trguid)
  local mine = {}
  local t = LoadLinks(trguid)
  if next(t) == nil then return mine end

  for el, L in pairs(t) do
    local ttr = TrackByGUID(L.tg)
    if ttr then
      local tfx = FXByGUID(ttr, L.tg, L.fg)
      if tfx then
        local pm = reaper.TrackFX_GetParamFromIdent(ttr, tfx, L.pid)
        if pm and pm >= 0 then
          local D = { ptr = tr, pfx = panelfx, k = k, el = el,
                      ttr = ttr, tfx = tfx, tparam = pm }
          dlinks[#dlinks + 1] = D

          by_key[k * KSTRIDE + el] = { tr = ttr, k = k, el = el,
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

local function ReadWish(k)
  local b = WSH + k * WSTRIDE

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

local function AnswerRecipe(k, el, sametrack, tr, fx, param)
  local b = WSH + k * WSTRIDE
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

local function ProposeRecipe(tr, k, mine, w, trg)
  local b = WSH + k * WSTRIDE

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

local function ScanWish(tr, k, panelfx, fxlist, w, trg)
  if not w then return end

  local hit, seen = nil, 0
  for _, fx in ipairs(fxlist) do
    if FXKeyC(tr, trg, fx) == w.name then
      if seen == w.occ then hit = fx; break end
      seen = seen + 1
    end
  end

  if not hit then return end

  local np = reaper.TrackFX_GetNumParams(tr, hit) or 0
  for el, p in pairs(w.p) do
    if not by_key[k * KSTRIDE + el] and p < np then
      local D = { ptr = tr, pfx = panelfx, k = k, el = el,
                  ttr = tr, tfx = hit, tparam = p }
      dlinks[#dlinks + 1] = D
      by_key[k * KSTRIDE + el] = { tr = tr, k = k, el = el, fx = hit, param = p }
    end
  end
end

local function ScanPanelLinks(tr, k, fxlist)
  local base = CCM + k * KSTRIDE

  local want, any = {}, false
  for el = 0, NEL - 1 do
    local w = reaper.gmem_read(base + el) or 0

    if by_key[k * KSTRIDE + el] then w = 0 end
    if w > 0 then
      w = w - 1
      want[#want + 1] = { el = el, cc = w % 256, chan = math.floor(w / 256) - 1 }
      any = true
    end
  end
  if not any then return end

  for el = 0, NEL - 1 do
    reaper.gmem_write(FBK + k * KSTRIDE + el, 0)
  end

  local taken = {}
  for _, fx in ipairs(fxlist) do
    if not IsPanel(tr, fx) then
      local np = math.min(reaper.TrackFX_GetNumParams(tr, fx) or 0, PMAX)
      for p = 0, np - 1 do
        local cc, ch = LearnedCC(tr, fx, p)
        if cc then
          for _, e in ipairs(want) do

            if not taken[e.el] and e.cc == cc
               and (e.chan < 0 or ch < 0 or e.chan == ch) then
              local L = { tr = tr, k = k, el = e.el, fx = fx, param = p }
              links[#links + 1] = L
              by_key[k * KSTRIDE + e.el] = L
              taken[e.el] = true
            end
          end
        end
      end
    end
  end
end

local PSIZES      = { "050", "100", "150", "200", "300", "400", "600" }
local PSYNC_EVERY = 60
local PDIR        = reaper.GetResourcePath() .. "/presets/"

local pprefix = nil
local pbank   = nil
local pseen   = {}
local psync   = 1

local function PPrefix()
  local i = 0
  while true do
    local f = reaper.EnumerateFiles(PDIR, i)
    if not f or f == "" then return nil end
    local p = f:match("^js%-(.*)StripBus Panel %d+ px%.ini$")
    if p then return p end
    i = i + 1
  end
end

local function PPath(px)
  return PDIR .. "js-" .. pprefix .. "StripBus Panel " .. px .. " px.ini"
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
  return table.concat(out, "\n") .. "\n"
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

  local raw, cut, gen, changed = {}, {}, {}, {}
  for _, px in ipairs(PSIZES) do
    local s = PRead(PPath(px))
    if s then
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
  sources, links, by_key, dlinks, panels = {}, {}, {}, {}, {}

  ResetCaches()

  local function scan(tr, k)

    local trg = TrackGUID(tr)
    local fxlist = FXList(tr, trg)
    ScanTrack(tr, k, fxlist)

    local panelfx = nil
    for _, fx in ipairs(fxlist) do
      if IsPanel(tr, fx) then panelfx = fx; break end
    end
    if panelfx then
      panels[#panels + 1] = { tr = tr, k = k }

      for el = 0, NEL - 1 do
        reaper.gmem_write(LNK + k * KSTRIDE + el, 0)
      end

      local w = ReadWish(k)
      local mine = ScanDirect(tr, k, panelfx, trg)
      ScanWish(tr, k, panelfx, fxlist, w, trg)
      ScanPanelLinks(tr, k, fxlist)

      ProposeRecipe(tr, k, mine, w, trg)
    end
  end

  scan(reaper.GetMasterTrack(0), 0)
  local n = math.min(reaper.CountTracks(0), MAXTRK)
  for i = 0, n - 1 do
    scan(reaper.GetTrack(0, i), i + 1)
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

  vcache = {}

  rescan = rescan - 1
  if rescan <= 0 then Rescan(); rescan = RESCAN_EVERY end

  psync = psync - 1
  if psync <= 0 then PSync(); psync = PSYNC_EVERY end

  tick = tick + 1
  if tick > 10000000 then tick = 1 end

  for _, s in ipairs(sources) do
    if Valid(s.tr) then
      local b = GR + s.k * STRIDE

      Publish(s.tr, b, s.fx,   NMAX,  1, s.k * 16)
      Publish(s.tr, b, s.gate, NGATE, 5, s.k * 16 + 8)

      reaper.gmem_write(b + 1, #s.fx + #s.gate * 16)
      reaper.gmem_write(b, tick)
    end
  end

  for _, p in ipairs(panels) do
    if Valid(p.tr) then

      local vol  = reaper.GetMediaTrackInfo_Value(p.tr, "D_VOL")   or 1
      local mute = reaper.GetMediaTrackInfo_Value(p.tr, "B_MUTE")  or 0

      if mute < 0.5 and vol > 0.000001 then
        local pk = reaper.Track_GetPeakInfo(p.tr, 0) or 0
        local r  = reaper.Track_GetPeakInfo(p.tr, 1) or 0
        if r > pk then pk = r end

        pk = pk / vol

        reaper.gmem_write(TL + p.k * 2,
                          pk > 0.0000001 and math.log(pk) * 8.6858896 or -144)
        reaper.gmem_write(TL + p.k * 2 + 1, tick)
      end
    end
  end

  for _, L in ipairs(links) do
    if Valid(L.tr) then
      local v = reaper.TrackFX_GetParamNormalized(L.tr, L.fx, L.param)
      if v and v >= 0 then
        reaper.gmem_write(FBK + L.k * KSTRIDE + L.el, 1 + v * 127)
      end
    end
  end

  for _, D in ipairs(dlinks) do
    if Valid(D.ptr) and Valid(D.ttr) then
      local pv = reaper.TrackFX_GetParamNormalized(D.ptr, D.pfx, D.el)
      local tv = reaper.TrackFX_GetParamNormalized(D.ttr, D.tfx, D.tparam)
      if pv and tv and pv >= 0 and tv >= 0 then
        local key = D.k * KSTRIDE + D.el
        local st  = dstate[key]
        if not st then

          st = { lp = pv, lt = tv }
          dstate[key] = st
        else
          if math.abs(pv - st.lp) > DEAD then
            reaper.TrackFX_SetParamNormalized(D.ttr, D.tfx, D.tparam, pv)
            st.lt = reaper.TrackFX_GetParamNormalized(D.ttr, D.tfx, D.tparam) or pv
            st.lp = pv
          elseif math.abs(tv - st.lt) > DEAD then
            reaper.TrackFX_SetParamNormalized(D.ptr, D.pfx, D.el, tv)
            st.lp = reaper.TrackFX_GetParamNormalized(D.ptr, D.pfx, D.el) or tv
            st.lt = tv
          end
        end
        reaper.gmem_write(LNK + D.k * KSTRIDE + D.el, 1)
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
    learn = nil
    rescan = 0
  end

  local function PanelTrack(k)
    if k <= 0 then return reaper.GetMasterTrack(0) end
    return reaper.GetTrack(0, k - 1)
  end

  if lk >= 0 and lel >= 0 and lst ~= served then
    if not learn or learn.stamp ~= lst then
      if lmod == 1 then

        local ptr = PanelTrack(lk)
        if ptr then
          local g = TrackGUID(ptr)
          local t = LoadLinks(g)
          t[lel] = nil
          SaveLinks(g, t)
          reaper.gmem_write(LNK + lk * KSTRIDE + lel, 0)
          dstate[lk * KSTRIDE + lel] = nil
        end
        learn = { k = lk, el = lel, stamp = lst }
        Answer(4)
      else
        local ok, btr, bit_, btk, bfx, bpm = reaper.GetTouchedOrFocusedFX(0)
        learn = { k = lk, el = lel, stamp = lst, t0 = reaper.time_precise(),
                  btr = ok and btr or -999,
                  bfx = ok and bfx or -999,
                  bpm = ok and bpm or -999 }
      end
    elseif learn.t0 then
      local ok, ttr_i, it_i, tk_i, tfx, tpm = reaper.GetTouchedOrFocusedFX(0)

      if ok and it_i < 0
         and (ttr_i ~= learn.btr or tfx ~= learn.bfx or tpm ~= learn.bpm) then
        local ttr = (ttr_i < 0) and reaper.GetMasterTrack(0)
                                or reaper.GetTrack(0, ttr_i)
        if not ttr then
          Answer(3)
        elseif IsPanel(ttr, tfx) then

          Answer(3)
        else
          local ptr = PanelTrack(learn.k)
          if not ptr then
            Answer(3)
          else
            local _, pid = reaper.TrackFX_GetParamIdent(ttr, tfx, tpm)
            local fg = reaper.TrackFX_GetFXGUID(ttr, tfx)
            if pid and pid ~= "" and fg and fg ~= "" then
              local g = TrackGUID(ptr)
              local t = LoadLinks(g)
              t[learn.el] = { tg = TrackGUID(ttr), fg = fg, pid = pid }
              SaveLinks(g, t)

              dstate[learn.k * KSTRIDE + learn.el] = nil
              reaper.gmem_write(LNK + learn.k * KSTRIDE + learn.el, 1)

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
    local r_k  = math.floor(reaper.gmem_read(REN_REQ + 1) or -1)
    local r_el = math.floor(reaper.gmem_read(REN_REQ + 2) or -1)
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

    local ok, col = reaper.GR_SelectColor(reaper.GetMainHwnd(), 0)

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
