-- ============================================================================
-- StripTease Panel Builder
-- Version: 1.2.0
-- Developer: Eric Avondo
--
-- Freeware - personal use. Resale or redistribution for profit is
-- prohibited. See LICENSE.txt.
--
-- Reads the parameters of a plugin sitting on the selected track, lets you
-- tick the ones you want, and drops a complete StripTease panel on the track:
-- elements typed, placed, named, coloured, and already linked to the plugin --
-- without a single "Learn plugin parameter".
--
-- The link rests on three fields of the serialized stream: the target FX name,
-- its instance rank, and one parameter index per element. StripTease System
-- reads them back from gmem and wires up the rest on its own.
--
-- Everything lives in this one file: nothing to install beside it, nothing to
-- keep together. The first four sections never talk to REAPER, and the script
-- returns its internal table instead of opening its window when loaded outside
-- REAPER -- that is how test_panel_builder.lua examines it.
--
-- Sections:
--   1. serialized stream -- reading and writing the <JS_SER> block
--   2. palettes          -- starting colours per plugin and per family
--   3. building          -- element type, label, layout, size
--   4. track chunk       -- locating and replacing lines
--   5. window            -- ReaImGui, reading the plugins, writing
-- ============================================================================

-- ==========================================================================
-- 1. Serialized stream
-- ==========================================================================
-- A panel's <JS_SER> block is the stream written by sb_serialize() in
-- striptease_panel.jsfx-inc. This module decodes it and re-encodes it exactly,
-- which is what allows both building a panel from scratch and reading an
-- existing one back.
--
-- Stream convention: little-endian, a float over 4 bytes, a string over 4 bytes
-- of length followed by its bytes then zero padding up to the next multiple of
-- 4. The field order follows sb_serialize() exactly.

local SER = {}
do
local M = SER

-- Elements a panel carries: sb_MAX in the engine. Stream version 17 is the
-- tier that writes this many; anything below stays on the count frozen in
-- nel_of() below.
M.NEL = 100

-- Element types, as the engine numbers them (see sb_add()).
M.KNOB  = 1
M.TOGGLE= 2
M.SEP   = 3
M.TITLE = 4
M.RADIO = 5
M.METER = 6
M.METER2 = 8
M.BAR   = 7

-- Flags of field 7.
M.F_HOLD     = 1    -- peak hold (VU) / momentary (toggle)
M.F_BIPOLAR  = 2    -- bipolar knob
M.F_INITMAX  = 4    -- knob starting at maximum / VU showing its value
M.F_VERTICAL = 8
M.F_POSMASK  = 112  -- radio positions, minus 2, shifted by 16
M.F_TABSHIFT = 1024

-- ---------------------------------------------------------------------------
-- Base64
-- ---------------------------------------------------------------------------

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local B64R = {}
for i = 1, #B64 do B64R[B64:sub(i, i)] = i - 1 end

function M.b64encode(s)
  local out, n = {}, #s
  local i = 1
  while i + 2 <= n do
    local a, b, c = s:byte(i, i + 2)
    local v = a * 65536 + b * 256 + c
    out[#out + 1] = B64:sub(v // 262144 + 1, v // 262144 + 1)
                 .. B64:sub(v // 4096 % 64 + 1, v // 4096 % 64 + 1)
                 .. B64:sub(v // 64 % 64 + 1, v // 64 % 64 + 1)
                 .. B64:sub(v % 64 + 1, v % 64 + 1)
    i = i + 3
  end
  local rest = n - i + 1
  if rest == 1 then
    local a = s:byte(i)
    local v = a * 16
    out[#out + 1] = B64:sub(v // 64 + 1, v // 64 + 1) .. B64:sub(v % 64 + 1, v % 64 + 1) .. "=="
  elseif rest == 2 then
    local a, b = s:byte(i, i + 1)
    local v = (a * 256 + b) * 4
    out[#out + 1] = B64:sub(v // 4096 + 1, v // 4096 + 1)
                 .. B64:sub(v // 64 % 64 + 1, v // 64 % 64 + 1)
                 .. B64:sub(v % 64 + 1, v % 64 + 1) .. "="
  end
  return table.concat(out)
end

function M.b64decode(s)
  s = s:gsub("[^A-Za-z0-9+/=]", "")
  local out = {}
  local i = 1
  while i + 3 <= #s do
    local c1, c2, c3, c4 = s:sub(i, i), s:sub(i + 1, i + 1), s:sub(i + 2, i + 2), s:sub(i + 3, i + 3)
    local v = B64R[c1] * 262144 + B64R[c2] * 4096
    local nb = 1
    if c3 ~= "=" then v = v + B64R[c3] * 64; nb = 2 end
    if c4 ~= "=" then v = v + B64R[c4];      nb = 3 end
    local a, b, c = v // 65536, v // 256 % 256, v % 256
    if nb == 1 then out[#out + 1] = string.char(a)
    elseif nb == 2 then out[#out + 1] = string.char(a, b)
    else out[#out + 1] = string.char(a, b, c) end
    i = i + 4
  end
  return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- Reading and writing
-- ---------------------------------------------------------------------------

local Reader = {}
Reader.__index = Reader

local function reader(s)
  return setmetatable({ s = s, p = 1 }, Reader)
end

function Reader:f()
  local v = string.unpack("<f", self.s, self.p)
  self.p = self.p + 4
  return v
end

function Reader:str()
  local n = string.unpack("<I4", self.s, self.p)
  self.p = self.p + 4
  local out = self.s:sub(self.p, self.p + n - 1)
  self.p = self.p + n + (-n) % 4
  return out
end

local Writer = {}
Writer.__index = Writer

local function writer()
  return setmetatable({ t = {} }, Writer)
end

function Writer:f(v)
  self.t[#self.t + 1] = string.pack("<f", v or 0)
end

function Writer:str(v)
  v = v or ""
  self.t[#self.t + 1] = string.pack("<I4", #v) .. v .. string.rep("\0", (-#v) % 4)
end

function Writer:done()
  return table.concat(self.t)
end

-- How many elements a given stream version carries. Older versions stored
-- fewer; the engine zero-fills the rest.
--
-- Each step is frozen on a literal, as in sb_serialize: it is the count that
-- was in force when that version number was written. A step pointing at M.NEL
-- would misread every earlier state the day the engine accepts more, and the
-- links already established would fall with it.
local function nel_of(ver)
  if ver >= 17 then return M.NEL
  elseif ver >= 12 then return 50
  elseif ver >= 11 then return 40
  else return 32 end
end

-- Builds an empty state, ready to be filled then encoded.
function M.new()
  local st = {
    version = 17,
    bg = 1, defcol = 7, defchan = 0, cols = 2, rows_legacy = 0,
    names = 1, rings = 1, scroll = 1,
    fxocc = 0, fxkey = "",
    tabs = 0, tab = 0,
    elems = {}, labels = {}, labels2 = {}, links = {}, tabnames = {},
  }
  for i = 0, M.NEL - 1 do
    st.elems[i] = { 0, 0, 0, 0, 0, 0, 0, 0 }
    st.labels[i] = ""
    st.labels2[i] = ""
    st.links[i] = 0
  end
  for i = 0, 3 do st.tabnames[i] = "" end
  return st
end

-- Decodes a binary stream. Returns the state, or nil followed by a message.
function M.decode(bin)
  if type(bin) ~= "string" or #bin < 8 then return nil, "stream too short" end

  local ok, st = pcall(function()
    local r = reader(bin)
    local s = M.new()

    s.version = r:f()
    local n = nel_of(s.version)

    for i = 0, n - 1 do
      local e = {}
      for k = 1, 8 do e[k] = r:f() end
      s.elems[i] = e
    end

    s.bg, s.defcol, s.defchan = r:f(), r:f(), r:f()

    if s.version >= 2 then
      s.cols, s.rows_legacy = r:f(), r:f()
    else
      s.grid_legacy = r:f()
    end

    if s.version >= 3 then
      s.names = r:f()
      for i = 0, n - 1 do s.labels[i] = r:str() end
    end

    if s.version >= 7 then
      for i = 0, n - 1 do s.labels2[i] = r:str() end
    end

    if s.version >= 8 then s.rings = r:f() end

    if s.version >= 10 then
      s.scroll = r:f()
    elseif s.version >= 9 then
      s.solo_legacy = r:f()
    end

    if s.version >= 13 then
      s.fxocc = r:f()
      s.fxkey = r:str()
      for i = 0, n - 1 do s.links[i] = r:f() end
    end

    if s.version >= 15 then
      s.tabs, s.tab = r:f(), r:f()
      for i = 0, 3 do s.tabnames[i] = r:str() end
    end

    if s.version >= 16 then
      s.gh, s.gw = r:f(), r:f()
    end

    s.consumed = r.p - 1
    return s
  end)

  if not ok then return nil, tostring(st) end
  return st
end

-- Re-encodes a state. A state out of M.decode re-encodes byte for byte.
function M.encode(st)
  local w = writer()
  local ver = st.version or 15
  local n = nel_of(ver)

  w:f(ver)

  for i = 0, n - 1 do
    local e = st.elems[i] or { 0, 0, 0, 0, 0, 0, 0, 0 }
    for k = 1, 8 do w:f(e[k] or 0) end
  end

  w:f(st.bg); w:f(st.defcol); w:f(st.defchan)

  if ver >= 2 then
    w:f(st.cols); w:f(st.rows_legacy)
  else
    w:f(st.grid_legacy)
  end

  if ver >= 3 then
    w:f(st.names)
    for i = 0, n - 1 do w:str(st.labels[i]) end
  end

  if ver >= 7 then
    for i = 0, n - 1 do w:str(st.labels2[i]) end
  end

  if ver >= 8 then w:f(st.rings) end

  if ver >= 10 then
    w:f(st.scroll)
  elseif ver >= 9 then
    w:f(st.solo_legacy)
  end

  if ver >= 13 then
    w:f(st.fxocc)
    w:str(st.fxkey)
    for i = 0, n - 1 do w:f(st.links[i]) end
  end

  if ver >= 15 then
    w:f(st.tabs); w:f(st.tab)
    for i = 0, 3 do w:str(st.tabnames[i]) end
  end

  if ver >= 16 then
    -- A freshly built state has no grid step of its own. We write the one the
    -- engine would have worked out, rather than a zero it would then clamp to
    -- the minimum -- which would draw the panel tighter than its elements.
    local gh, gw = st.gh, st.gw
    if not (gh and gw) then gh, gw = M.fit_grid(st) end
    w:f(gh); w:f(gw)
  end

  return w:done()
end

-- ---------------------------------------------------------------------------
-- Geometry -- port of the engine functions used for sizing
-- ---------------------------------------------------------------------------

-- Number of positions of a radio: sb_radio_n().
function M.positions(e)
  return 2 + ((e[8] // 16) % 8)
end

-- The two footprints of an element, ported as they stand from sb_elem_h and
-- sb_elem_w in the engine. Their names surprise: it really is sb_elem_h that
-- gives the HORIZONTAL grid step and sb_elem_w the vertical one -- see
-- sb_fit_grid, which crosses the two. We keep the engine's names rather than
-- correcting them: a correction here is paid for at the next JSFX reading.
function M.elem_h(st, e)
  local t = e[1]
  if t == M.SEP or t == M.TITLE then return 0 end
  local z = math.max(4, e[6])
  local rings = (st.rings ~= 0) and 9 or 3
  if t == M.RADIO then
    local vert = (e[8] & M.F_VERTICAL) ~= 0
    return z * 0.75 * (vert and M.positions(e) or 1) + 6
  elseif t == M.METER or t == M.BAR then return 12
  elseif t == M.TOGGLE then return 2 * (z * 0.62 + 3)
  else return 2 * (z + rings + 1) end
end

function M.elem_w(st, e)
  local t = e[1]
  if t == M.SEP or t == M.TITLE then return 0 end
  local z = math.max(4, e[6])
  local rings = (st.rings ~= 0) and 9 or 3
  if t == M.RADIO then
    local vert = (e[8] & M.F_VERTICAL) ~= 0
    return z * (vert and 1 or M.positions(e))
  elseif t == M.METER then return z * 7.5
  elseif t == M.BAR then
    return ((e[8] & M.F_VERTICAL) ~= 0) and 12 or z * 6
  elseif t == M.TOGGLE then return 2 * z
  else return 2 * (z + rings) end
end

-- The grid step the engine will compute on load: sb_fit_grid().
function M.fit_grid(st)
  local gh, gw = 18, 40
  for i = 0, M.NEL - 1 do
    local e = st.elems[i]
    if e and e[1] > 0 then
      gh = math.max(gh, M.elem_h(st, e))
      gw = math.max(gw, M.elem_w(st, e) * 1.25 + 16)
    end
  end
  return gh, gw
end

-- Row height in pixels: sb_calc_rowh(). The vertical unit of element
-- coordinates is one eighth of it.
function M.row_px(st)
  local gh = st.gh or select(1, M.fit_grid(st))
  return math.ceil(math.max(18, gh) + ((st.names ~= 0) and 22 or 0) + 3)
end

-- Total height the panel would need to show everything without scrolling,
-- after sb_content_h().
function M.needed_px(st)
  local row = M.row_px(st)
  local unit = row / 8
  local maxy = 0
  for i = 0, M.NEL - 1 do
    local e = st.elems[i]
    if e and e[1] > 0 then maxy = math.max(maxy, e[5]) end
  end
  return math.ceil(5 + maxy * unit + row)
end
end
-- ==========================================================================
-- 2. Palettes
-- ==========================================================================
-- A table of patterns: the target plugin's name picks a theme, the theme gives
-- a background and five control tints. A parameter's name then picks which of
-- the five it gets, so that knobs of one family look alike -- what the shipped
-- panels do by hand.
--
-- Nothing here is fixed: the generator window lets it all be taken over by
-- hand. This file only pre-fills.

local TH = {}
do
local T = TH

-- Encoding of a free colour in field 6 of an element.
function T.pack(rgb)
  local r, g, b = rgb[1], rgb[2], rgb[3]
  return -(r * 65536 + g * 256 + b) - 1
end

function T.unpack(v)
  if v >= 0 then return nil end
  local n = -v - 1
  return { n // 65536, (n // 256) % 256, n % 256 }
end

-- The five families, in palette slot order.
T.FAMILIES = { "level", "dyn", "time", "filter", "mix", "power" }

-- The first pattern that catches wins. Order matters: precise patterns come
-- before generic ones.
T.FAMILY_PATTERNS = {
  { "power",               "power" },
  { "engage",              "power" },
  { "%f[%a]enable%f[%A]",  "power" },
  { "%f[%a]active%f[%A]",  "power" },
  { "%f[%a]in/out%f[%A]",  "power" },
  { "thresh",              "dyn" },
  { "ratio",               "dyn" },
  { "knee",                "dyn" },
  { "range",               "dyn" },
  { "reduc",               "dyn" },
  { "comp",                "dyn" },
  { "peak",                "dyn" },
  { "attack",              "time" },
  { "release",             "time" },
  { "recovery",            "time" },
  { "hold",                "time" },
  { "speed",               "time" },
  { "^rate",               "time" },
  { "lookahead",           "time" },
  { "sidechain",           "filter" },
  { "side%s*chain",        "filter" },
  { "^sc",                 "filter" },
  { "%f[%a]hpf%f[%A]",     "filter" },
  { "%f[%a]lpf%f[%A]",     "filter" },
  { "filter",              "filter" },
  { "freq",                "filter" },
  { "%f[%a]hz%f[%A]",      "filter" },
  { "%f[%a]khz%f[%A]",     "filter" },
  { "%f[%a]q%f[%A]",       "filter" },
  { "shelf",               "filter" },
  { "bell",                "filter" },
  { "%f[%a]eq%f[%A]",      "filter" },
  { "%f[%a]tone%f[%A]",    "filter" },
  { "%f[%a]tilt%f[%A]",    "filter" },
  { "%f[%a]air%f[%A]",     "filter" },
  { "%f[%a]mix%f[%A]",     "mix" },
  { "blend",               "mix" },
  { "dry",                 "mix" },
  { "wet",                 "mix" },
  { "width",               "mix" },
  { "stereo",              "mix" },
  { "mono",                "mix" },
  { "%f[%a]pan%f[%A]",     "mix" },
  { "makeup",              "level" },
  { "output",              "level" },
  { "input",               "level" },
  { "%f[%a]gain%f[%A]",    "level" },
  { "%f[%a]level%f[%A]",   "level" },
  { "%f[%a]trim%f[%A]",    "level" },
  { "volume",              "level" },
  { "drive",               "level" },
}

-- The backgrounds come from the shipped panels, read back with striptease_ser:
-- they are already tuned to their plugins.
T.THEMES = {
  {
    name  = "bx_opto",
    match = { "bx_opto" },
    bg    = { 169, 0, 16 },
    level = { 226, 222, 210 }, dyn   = { 42, 42, 44 },
    time  = { 226, 222, 210 }, filter= { 226, 190, 96 },
    power = { 246, 214, 120 },
    mix   = { 150, 150, 150 }, title = { 240, 236, 226 },
  },
  {
    name  = "Vertigo",
    match = { "vertigo" },
    bg    = { 19, 121, 202 },
    level = { 236, 236, 232 }, dyn   = { 32, 34, 38 },
    time  = { 32, 34, 38 },    filter= { 226, 176, 60 },
    power = { 214, 68, 52 },
    mix   = { 150, 158, 166 }, title = { 250, 250, 246 },
  },
  {
    name  = "bx_townhouse",
    match = { "townhouse" },
    bg    = { 45, 59, 77 },
    level = { 214, 210, 200 }, dyn   = { 86, 148, 108 },
    time  = { 92, 132, 176 },  filter= { 208, 168, 74 },
    power = { 206, 84, 66 },
    mix   = { 138, 146, 154 }, title = { 232, 230, 224 },
  },
  {
    name  = "SSL / console",
    match = { "ssl", "console", "4000", "9000" },
    bg    = { 99, 98, 94 },
    level = { 232, 230, 224 }, dyn   = { 178, 74, 62 },
    time  = { 74, 116, 168 },  filter= { 214, 176, 70 },
    power = { 210, 88, 70 },
    mix   = { 86, 148, 108 },  title = { 246, 244, 238 },
  },
  {
    name  = "Universal Audio",
    match = { "uad", "universal audio" },
    bg    = { 110, 149, 123 },
    level = { 238, 234, 224 }, dyn   = { 46, 44, 42 },
    time  = { 46, 44, 42 },    filter= { 202, 158, 62 },
    power = { 190, 62, 48 },
    mix   = { 150, 156, 150 }, title = { 248, 246, 238 },
  },
  {
    name  = "Analog Obsession",
    match = { "analogobsession", "analog obsession" },
    bg    = { 22, 31, 19 },
    level = { 109, 103, 98 },  dyn   = { 201, 201, 201 },
    time  = { 148, 142, 130 }, filter= { 196, 166, 84 },
    power = { 214, 118, 52 },
    mix   = { 120, 128, 118 }, title = { 226, 224, 214 },
  },
  {
    name  = "FabFilter",
    match = { "fabfilter", "pro%-c", "pro%-q", "pro%-l" },
    bg    = { 42, 46, 50 },
    level = { 226, 226, 222 }, dyn   = { 96, 176, 208 },
    time  = { 132, 196, 96 },  filter= { 226, 178, 72 },
    power = { 238, 108, 84 },
    mix   = { 150, 156, 162 }, title = { 240, 240, 236 },
  },
  {
    name  = "Waves",
    match = { "waves", "^vst3: [sc]la%-", "renaissance" },
    bg    = { 38, 40, 44 },
    level = { 222, 220, 214 }, dyn   = { 206, 148, 52 },
    time  = { 108, 148, 190 }, filter= { 196, 196, 92 },
    power = { 214, 78, 62 },
    mix   = { 140, 146, 152 }, title = { 238, 236, 230 },
  },
  {
    name  = "Plugin Alliance / bx",
    match = { "plugin alliance", "^vst3: bx_", "^au: bx_", "brainworx" },
    bg    = { 32, 34, 38 },
    level = { 190, 190, 186 }, dyn   = { 196, 88, 72 },
    time  = { 92, 132, 176 },  filter= { 214, 176, 70 },
    power = { 206, 78, 62 },
    mix   = { 130, 140, 148 }, title = { 224, 224, 220 },
  },
  {
    name  = "Neutre",
    match = {},
    bg    = { 30, 32, 36 },
    level = { 208, 208, 204 }, dyn   = { 180, 96, 84 },
    time  = { 96, 136, 178 },  filter= { 206, 172, 78 },
    power = { 200, 84, 68 },
    mix   = { 132, 140, 148 }, title = { 230, 230, 226 },
  },
}

-- Warm and cool tint pools.
--
-- What adds level or colour to the sound -- gain, drive, saturation, tube -- is
-- warm; what shapes or balances it -- ratio, attack, release, EQ, tone, mix --
-- is cool. A family draws only from the pool of its own temperature, and the
-- two never cross: whatever the draw, a panel still reads at a glance.
T.WARM = {
  { 232, 168,  72 },      -- amber
  { 226, 122,  52 },      -- orange
  { 214,  84,  74 },      -- red
  { 214, 184,  82 },      -- gold
  { 198, 118,  86 },      -- copper
  { 222, 130, 130 },      -- rose
}

T.COOL = {
  {  92, 152, 226 },      -- blue
  {  86, 190, 206 },      -- cyan
  {  74, 178, 160 },      -- teal
  { 110, 190, 120 },      -- green
  { 122, 138, 226 },      -- indigo
  { 158, 130, 216 },      -- violet
}

T.TEMPERATURE = {
  level = "warm", power = "warm",
  dyn   = "cool", time  = "cool", filter = "cool", mix = "cool",
}

-- A name the vocabulary does not place -- THD, tube, transformer -- falls back
-- on "level", and character is warm, so the fallback is warm too.
function T.temperature(family)
  return T.TEMPERATURE[family] or "warm"
end

local function same_rgb(a, b)
  return a and b and a[1] == b[1] and a[2] == b[2] and a[3] == b[3]
end

-- One tint per family, drawn from the pool of its temperature. Two families of
-- the same temperature never land on the same tint as long as the pool holds
-- out, and `avoid` -- the tints they wear already -- keeps a second draw from
-- handing back the first. Returns a table family -> { r, g, b }.
--
-- `rnd` stands in for math.random so that a test can drive the draw.
function T.draw(families, avoid, rnd)
  rnd, avoid = rnd or math.random, avoid or {}

  -- Fisher-Yates on a copy: the order the families come in must not decide
  -- which tint each one gets.
  local pools = {}
  for temp, src in pairs({ warm = T.WARM, cool = T.COOL }) do
    local pool = {}
    for i, c in ipairs(src) do pool[i] = c end
    for i = #pool, 2, -1 do
      local j = rnd(i)
      pool[i], pool[j] = pool[j], pool[i]
    end
    pools[temp] = pool
  end

  local at = { warm = 0, cool = 0 }
  local function take(temp, shun)
    local pool = pools[temp]
    at[temp] = at[temp] + 1
    local k = ((at[temp] - 1) % #pool) + 1

    -- The tint this family already wears: trade it for one still in hand,
    -- rather than stepping over it. Stepping over would run off the end of the
    -- pool and hand one tint to two families.
    if same_rgb(pool[k], shun) and k < #pool then
      pool[k], pool[k + 1] = pool[k + 1], pool[k]
    end
    return pool[k]
  end

  local out = {}
  for _, fam in ipairs(T.FAMILIES) do
    if families[fam] then out[fam] = take(T.temperature(fam), avoid[fam]) end
  end
  return out
end

-- A plugin's theme, from its name. The FIRST pattern that catches wins: the
-- table goes from the most precise to the widest, so that a bx_opto is not
-- caught by the Plugin Alliance theme behind it. The last one is the fallback.
function T.for_fx(fxname)
  local s = (fxname or ""):lower()
  for _, th in ipairs(T.THEMES) do
    for _, pat in ipairs(th.match) do
      if s:find(pat) then return th end
    end
  end
  return T.THEMES[#T.THEMES]
end

-- A parameter's family, from its name, or nothing when the vocabulary does not
-- recognize it. That is also what tells a front-panel control from an internal
-- setting: the patterns above are the vocabulary of a console strip.
function T.known(pname)
  local s = (pname or ""):lower()
  for _, row in ipairs(T.FAMILY_PATTERNS) do
    if s:find(row[1]) then return row[2] end
  end
end

function T.family_of(pname)
  return T.known(pname) or "level"
end
end
-- ==========================================================================
-- 3. Building
-- ==========================================================================
-- Nothing here touches REAPER: these are the rules for reading parameters,
-- shortening labels and laying them out on the grid. The script that calls this
-- module hands it a list of parameters already read, and gets back a state
-- ready to serialize.

local B = {}
do

B.SER = SER
B.TH  = TH

-- The seven shipped panel variants, and the stem of their file name.
B.SIZES = {
  { px = 50,  stem = "050" },
  { px = 100, stem = "100" },
  { px = 150, stem = "150" },
  { px = 200, stem = "200" },
  { px = 300, stem = "300" },
  { px = 400, stem = "400" },
  { px = 600, stem = "600" },
}

B.SIZE_KNOB   = 22
B.SIZE_RADIO  = 22
B.SIZE_TOGGLE = 17
B.SIZE_METER  = 20
B.SIZE_TITLE  = 2

-- ---------------------------------------------------------------------------
-- Labels
-- ---------------------------------------------------------------------------

-- The panel writes its names under the control, in a box one column wide: past
-- a dozen characters the text overflows or gets squashed.
B.LABEL_MAX = 10

-- Abbreviations, in order. The same ones the shipped panels use.
B.ABBREV = {
  { "THRESHOLD",   "THRESH" },
  { "SIDECHAIN",   "SC" },
  { "SIDE CHAIN",  "SC" },
  { "FREQUENCY",   "Fq" },
  { "FREQ",        "Fq" },
  { "COMPRESSION", "COMP" },
  { "COMPRESSOR",  "COMP" },
  { "REDUCTION",   "REDUC" },
  { "HEADROOM",    "HEADR" },
  { "CHARACTER",   "CHAR" },
  { "SATURATION",  "SAT" },
  { "HIGHPASS",    "HPF" },
  { "HIGH PASS",   "HPF" },
  { "LOWPASS",     "LPF" },
  { "LOW PASS",    "LPF" },
  { "HIGH SHELF",  "HI SHLF" },
  { "LOW SHELF",   "LO SHLF" },
  { "TRANSFORMER", "TRANSF" },
  { "HARMONICS",   "HARM" },
  { "AMOUNT",      "AMT" },
}

-- Strips what adds nothing to the label: the plugin name as a prefix, band
-- numbers, trailing punctuation.
local function strip_noise(s)
  s = s:gsub("^%s+", ""):gsub("%s+$", "")
  s = s:gsub("^[%w_]+%s*:%s*", "")        -- "Comp: Threshold" -> "Threshold"
  s = s:gsub("%s*%b()%s*$", "")           -- "Attack (fast)"   -> "Attack"
  s = s:gsub("[%.:]+$", "")
  return s
end

-- A parameter's label: readable, short, in capitals like the rest of the
-- panels. Abbreviations apply AFTER the uppercasing so they keep their own
-- case: the shipped panels write "Fq", "kHz", "dB", and one more capital would
-- make them unreadable.
function B.label_of(name)
  local s = strip_noise(name or "")
  if s == "" then return "" end

  s = s:upper()
  for _, row in ipairs(B.ABBREV) do
    s = s:gsub(row[1], row[2])
  end
  s = s:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")

  if #s > B.LABEL_MAX then
    -- We cut at the useful length, but never in the middle of the first word:
    -- "OUTPUT LEVEL" becomes "OUTPUT LEV", not "OUTPUT LEVE" cut anywhere, nor
    -- an acronym no one recognizes any more.
    s = s:sub(1, B.LABEL_MAX)
  end
  return (s:gsub("%s+$", ""))
end

-- ---------------------------------------------------------------------------
-- Reading a parameter
-- ---------------------------------------------------------------------------

-- What REAPER adds behind every plugin -- Wet, Bypass, Delta -- is not a
-- setting of the plugin and has no place in the list. The reliable mark is the
-- identifier: REAPER prefixes its own with a colon, where a plugin returns the
-- one it declares. The name depends on the host, and a plugin is entitled to
-- call a real setting "Dry".
function B.is_builtin(ident)
  return (ident or ""):sub(1, 1) == ":"
end

-- The empty slots and filler labels some plugins leave lying about in their
-- parameter table: nothing adjustable behind them, and that is what swells the
-- list.
B.HIDDEN = {
  "^wet$", "^bypass$", "^delta$", "^dry$",
  "^program$", "^preset$", "^midi ", "^param %d+$", "^parameter %d+$",
  "^unused", "^not used", "^reserved", "^n/a$", "^%-+$",
}

function B.is_hidden(name)
  local s = (name or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  if s == "" then return true end
  for _, p in ipairs(B.HIDDEN) do
    if s:find(p) then return true end
  end
  return false
end

-- The number a plugin puts at the head of a formatted value: "-6.0 dB" -> -6,
-- "100 %" -> 100, "1:1" -> 1. Nothing when the value does not start on a
-- number, as with "-inf dB", "AUTO" or "OFF".
function B.head_num(s)
  return tonumber((s or ""):match("^%s*([%-%+]?%d+%.?%d*)"))
end

-- Controls whose rest is the top of the travel, whatever they format there.
B.AT_MAX = { "thresh", "%f[%a]mix%f[%A]", "blend", "%f[%a]wet%f[%A]" }

function B.rests_at_max(name)
  local s = (name or ""):lower()
  for _, pat in ipairs(B.AT_MAX) do
    if s:find(pat) then return true end
  end
  return false
end

-- Works out the element type from what the plugin declares.
--
-- p = { name, istoggle, step, minv, maxv, fmt0, fmthalf, fmt1 }
-- Returns: type ("knob" | "toggle" | "radio"), number of positions, flags.
function B.classify(p)
  if p.istoggle then
    return "toggle", 2, 0
  end

  local span = (p.maxv or 1) - (p.minv or 0)
  if p.step and p.step > 0 and span > 0 then
    local n = math.floor(span / p.step + 0.5) + 1
    if n == 2 then
      return "toggle", 2, 0
    elseif n >= 3 and n <= 6 then
      return "radio", n, (n - 2) * 16
    end
  end

  -- Where the knob rests. Three shapes, and the source control says which one
  -- through the values it formats at both ends of the travel and at mid-course:
  --
  --   bipolar    zero at mid-course, negative below -- an output trim
  --   init max   zero at the top -- a threshold, a gate range, a wet/dry mix
  --   normal     everything else, at rest at the bottom of the travel
  --
  -- It is not a matter of looks: the engine draws the arc from the rest point
  -- and sends the needle back to it on a double click, so a knob that reads the
  -- wrong way round behaves the wrong way round.
  local flags = 0
  local lo  = B.head_num(p.fmt0)
  local mid = B.head_num(p.fmthalf)
  local hi  = B.head_num(p.fmt1)

  if B.rests_at_max(p.name) then
    -- A threshold does nothing at its maximum whatever it formats there, and a
    -- mix rests fully wet. Those two are known from the name, and the name is
    -- more reliable than the range: an SSL threshold runs to +20 dB.
    flags = flags | SER.F_INITMAX

  elseif lo and mid and hi and math.abs(mid) < 0.001 and lo < 0 and hi > 0 then
    flags = flags | SER.F_BIPOLAR

  elseif lo and hi and lo < 0 and math.abs(hi) < 0.001 then
    -- Zero at the top and negative below: the shape of anything that stops
    -- working at its maximum -- a gate range, a reduction depth.
    flags = flags | SER.F_INITMAX
  end

  return "knob", 0, flags
end

-- The two labels of a toggle, taken from the values formatted at both ends.
-- A plugin that formats nothing useful falls back on the parameter name.
function B.toggle_labels(p)
  local off = strip_noise(p.fmt0 or ""):upper()
  local on  = strip_noise(p.fmt1 or ""):upper()

  local useless = function(s)
    return s == "" or #s > B.LABEL_MAX or s:match("^[%-%+]?[%d%.]+$") ~= nil
  end

  if useless(off) or useless(on) or off == on then
    return B.label_of(p.name), ""
  end
  return off, on
end

-- Does the parameter belong on a panel?
--
-- REAPER does not say what the plugin shows on its face: the API gives the
-- parameter list, not the interface. We come close through the vocabulary --
-- threshold, ratio, attack, gain, frequency, mix, power... -- which is that of
-- a console strip and therefore, in practice, that of the front panel. What the
-- vocabulary does not recognize stays in the list, unticked: it is usually an
-- internal setting, a spare, or a menu option.
-- The family vocabulary only covers what earns a colour. A front panel carries
-- more than that -- character, saturation, transformer, headroom -- which the
-- shipped panels do show and which have no tint of their own.
B.FRONT_EXTRA = {
  "%f[%a]thd%f[%A]", "%f[%a]tube%f[%A]", "%f[%a]tub%f[%A]", "transform",
  "%f[%a]xl%f[%A]", "emphasis", "saturat", "character", "headroom",
  "%f[%a]headr%f[%A]", "%f[%a]phase%f[%A]", "polarity", "%f[%a]link%f[%A]",
  "analog", "warmth",
}

-- And what a plugin keeps behind its face: the second rank, settled once and
-- never touched again while mixing. The vocabulary recognizes some of it -- a
-- detector is dynamics, lookahead is time -- so this list is read FIRST and
-- overrides. Nothing here is ticked on its own; ticking it by hand still works.
B.ADVANCED = {
  "lookahead", "oversampl", "%f[%a]quality%f[%A]", "%f[%a]hq%f[%A]",
  "latency", "detector", "%f[%a]rms%f[%A]", "peak%s*/%s*rms", "peak%s*mode",
  "%f[%a]hold%f[%A]", "listen", "monitor", "hysteres", "adapt", "smooth",
  "%f[%a]curve%f[%A]", "%f[%a]scale%f[%A]", "calibrat", "%f[%a]offset%f[%A]",
  "%f[%a]window%f[%A]", "tolerance", "^advanced", "%f[%a]expert%f[%A]",
  "algorithm", "precision", "resolution", "sample%s*rate", "dither",
  "%f[%a]gui%f[%A]", "display", "%f[%a]zoom%f[%A]", "%f[%a]scroll%f[%A]",
  "%f[%a]stage%f[%A]", "%f[%a]slope%f[%A]", "sensitiv",
}

function B.is_advanced(name)
  local s = (name or ""):lower()
  for _, pat in ipairs(B.ADVANCED) do
    if s:find(pat) then return true end
  end
  return false
end

function B.on_front(p)
  if B.is_builtin(p.ident) or B.is_hidden(p.name) then return false end
  if B.is_advanced(p.name) then return false end
  if TH.known(p.name) then return true end

  local s = (p.name or ""):lower()
  for _, pat in ipairs(B.FRONT_EXTRA) do
    if s:find(pat) then return true end
  end
  return false
end

-- What Auto ticks: the main controls, and only those.
--
-- Even once the second rank is set aside, a generous plugin still declares more
-- front-panel controls than a console strip carries. So the pick is capped, and
-- what fills the cap is taken family by family, in the order a strip is read:
-- the on/off switch, the dynamics, its times, the levels, the mix, the filters,
-- and character last. Within one family the plugin's own order stands.
--
-- A cap is arbitrary by nature; this one is the number of controls that fits a
-- panel of two columns without turning it into a list. "Tick all" is one click
-- away for the plugin that deserves more.
B.AUTO_MAX = 16

B.PRIORITY = { power = 1, dyn = 2, time = 3, level = 4, mix = 5, filter = 6 }

-- params : the list read from the plugin. Returns a set, keyed by parameter.
function B.auto_pick(params)
  local ranked = {}
  for i, p in ipairs(params) do
    if B.on_front(p) then
      ranked[#ranked + 1] = { i = i, p = p,
                              rank = B.PRIORITY[TH.known(p.name) or ""] or 7 }
    end
  end

  table.sort(ranked, function(a, b)
    if a.rank ~= b.rank then return a.rank < b.rank end
    return a.i < b.i
  end)

  local out = {}
  for k = 1, math.min(#ranked, B.AUTO_MAX) do out[ranked[k].p] = true end
  return out
end

-- ---------------------------------------------------------------------------
-- Vertical geometry
-- ---------------------------------------------------------------------------
-- Two rows clear each other not because they were spaced by a fixed number of
-- units, but because the drawn bottom of one passes above the drawn top of the
-- next. The vertical unit is one eighth of the row height (sb_hh), and that
-- height is set by the largest element on the panel (sb_fit_grid,
-- sb_calc_rowh): a panel of knobs therefore has taller units than a panel of
-- toggles, and the same gap in units is not the same gap.
--
-- We redo the engine's measurement here: sb_cy() gives the centre,
-- sb_draw_label() puts the name 22 px under the control, and sb_draw_vu() draws
-- its whole box either side of the centre. The gaps that come out are those of
-- the shipped panels -- 8 units between two rows of knobs, 7 from a knob to a
-- toggle, 9 from the VU to the first knob, as in "AO The Bus".

B.LABEL_H = 22       -- sb_lab_h(): the name box, under the control

-- One witness element per kind, to measure without laying a panel out.
B.PROBE = {
  knob   = { SER.KNOB,   0, 0, 0, 0, B.SIZE_KNOB,   0, 0 },
  radio  = { SER.RADIO,  0, 0, 0, 0, B.SIZE_RADIO,  0, 16 },
  toggle = { SER.TOGGLE, 0, 0, 0, 0, B.SIZE_TOGGLE, 0, 0 },
  meter  = { SER.METER,  0, 0, 0, 0, B.SIZE_METER,  0, 0 },
  title  = { SER.TITLE,  0, 0, 0, 0, B.SIZE_TITLE,  0, 0 },
  sep    = { SER.SEP,    0, 0, 0, 0, 2,             0, 0 },
}

-- The drawn height is not always the one the grid keeps: the VU overflows its
-- cell by a long way (sb_vu_th), the title is a line of Arial 25 text, the
-- separator a rule.
function B.draw_h(st, kind)
  if kind == "meter" then return B.SIZE_METER * 5.1 * 1.20 end
  if kind == "title" then return 26 end
  if kind == "sep"   then return 12 end
  return SER.elem_h(st, B.PROBE[kind] or B.PROBE.knob)
end

-- kinds: the set of kinds the panel will carry. Returns the row height, the
-- vertical unit, and the drawn top and bottom of each kind, counted from its
-- own row line.
function B.metrics(kinds)
  local st = { rings = 1, names = 1 }        -- the panel B.layout writes

  -- sb_fit_grid() only looks at sb_elem_h: the VU counts as 12 there and the
  -- title as 0, which is exactly why they overflow.
  local gh = 18
  for kind in pairs(kinds) do
    local e = B.PROBE[kind]
    if e then gh = math.max(gh, SER.elem_h(st, e)) end
  end

  local rowh = math.ceil(math.max(18, gh) + B.LABEL_H + 3)
  local m = { rowh = rowh, unit = rowh / 8, top = {}, foot = {} }
  local cy = (rowh - B.LABEL_H) / 2          -- sb_cy(), under the row line

  for kind in pairs(B.PROBE) do
    local h = B.draw_h(st, kind)
    if kind == "sep" then
      m.top[kind], m.foot[kind] = 2 * m.unit - h / 2, 2 * m.unit + h / 2
    elseif kind == "title" or kind == "meter" then
      -- Neither of them carries a name underneath.
      m.top[kind], m.foot[kind] = cy - h / 2, cy + h / 2
    else
      m.top[kind], m.foot[kind] = cy - h / 2, cy + h / 2 + B.LABEL_H
    end
  end
  return m
end

-- The gap between two rows, in units: enough for the lowest drawn bottom of the
-- first to pass above the highest drawn top of the second, plus `air` units of
-- breathing room. Both rows are lists of kinds, since a row may now hold a knob
-- and a toggle side by side.
function B.row_step(m, from, to, air)
  local a, b = -math.huge, math.huge
  for _, k in ipairs(from) do a = math.max(a, m.foot[k] or m.foot.knob) end
  for _, k in ipairs(to)   do b = math.min(b, m.top[k]  or m.top.knob) end
  return math.max(1, math.ceil((a - b) / m.unit) + (air or 0))
end

-- ---------------------------------------------------------------------------
-- Sections
-- ---------------------------------------------------------------------------
-- A plugin never says where its front panel is cut into sections. It does two
-- things that give the cut away, though: it declares its parameters section by
-- section, in the order they are laid out, and it often names them for the
-- section they belong to.
--
-- So the order is left alone -- two controls next to each other on the plugin
-- stay next to each other on the panel -- and the cut is read from:
--
--   the prefix, when there is one: "Comp: Threshold", "EQ: Gain";
--   the family otherwise: a run of dynamics, then a run of times, is the same
--   cut seen through the vocabulary.
--
-- A run of one is not a section, it is a neighbour: it merges into the section
-- before it, so that a Freq / Gain / Q sequence stays on one row instead of
-- being cut into three.

-- "Comp: Threshold" -> "comp". Only the colon: a dash is part of too many
-- names -- "SC-FLT", "Dry/Wet - Mix" -- to be a section mark.
local function prefix_of(name)
  local head = (name or ""):match("^%s*([^:]-)%s*:%s*%S")
  if head and #head >= 2 and #head <= 14 then return head:lower() end
end

-- "Band 1 Freq" -> "band 1": everything but the last word, which is what a
-- plugin repeats across the controls of one section.
local function stem_of(name)
  local words = {}
  for w in (name or ""):gmatch("%S+") do words[#words + 1] = w:lower() end
  if #words < 2 then return nil end
  table.remove(words)
  return table.concat(words, " ")
end

-- names : the parameter names to lay out, in the plugin's order.
-- Returns one { group, label } per name; `label` is the section name when the
-- whole section agrees on one, "" otherwise.
function B.sections(names)
  local stem = {}
  for i, name in ipairs(names) do stem[i] = stem_of(name) end

  local out = {}
  for i, name in ipairs(names) do
    local pre = prefix_of(name)

    -- A stem only marks a section when a neighbour repeats it: "SC HPF" beside
    -- "SC LPF" is a section, "Makeup Gain" on its own is just a level.
    local shared = stem[i] ~= nil
                   and (stem[i] == stem[i - 1] or stem[i] == stem[i + 1])

    local key = pre and ("prefix:" .. pre)
             or (shared and ("stem:" .. stem[i]))
             or ("family:" .. TH.family_of(name))

    out[i] = { key = key, label = pre or (shared and stem[i]) or nil, group = 0 }
  end

  -- Runs of equal keys, then the merge of the runs of one.
  local run, count = {}, {}
  local g = 0
  for i = 1, #out do
    if i == 1 or out[i].key ~= out[i - 1].key then g = g + 1 end
    run[i] = g
    count[g] = (count[g] or 0) + 1
  end

  local gnum, seen = 0, nil
  for i = 1, #out do
    if run[i] ~= seen then
      seen = run[i]
      if gnum == 0 or count[seen] > 1 then gnum = gnum + 1 end
    end
    out[i].group = gnum
  end

  -- A section wears the name it opened with. What merged into it afterwards --
  -- a lone level at the end of a run -- does not rename it.
  local label = {}
  for i = 1, #out do
    local gr = out[i].group
    if label[gr] == nil then label[gr] = out[i].label or false end
  end
  for i = 1, #out do out[i].label = label[out[i].group] or "" end

  return out
end

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------

-- items: ordered list of { kind, label, label2, param, color, flags,
--                          positions, value }
--   kind   : "knob" | "toggle" | "radio"
--   color  : { r, g, b } or a palette index
--   param  : parameter index in the plugin, or nil
--   value  : 0..127
--
-- opts: cols, air, meter, bg, fxkey, fxocc, scroll
--   air : units of breathing room added to the minimum gap between two rows.
--         0 gives the gaps of the shipped panels, 1 adds a margin.
--
-- Returns the serializable state, the slider values, the number of elements
-- laid out, and the number that did not fit in the panel's slots.
function B.layout(items, opts)
  opts = opts or {}
  local cols = math.max(1, math.min(4, opts.cols or 2))
  local air  = math.max(0, math.min(4, opts.air or 1))

  -- The kinds present set the row height, hence the vertical unit: the
  -- measuring is done before anything is laid out.
  local kinds = {}
  for _, it in ipairs(items) do kinds[it.kind or "knob"] = true end
  if opts.meter then kinds.meter = true end
  if opts.meter2 then kinds.meter = true end
  local m = B.metrics(kinds)

  local st = SER.new()
  st.version = 17          -- the tier that carries SER.NEL elements
  st.cols    = cols
  st.bg      = opts.bg or 1
  st.defcol  = 7
  st.names   = 1
  st.rings   = 1
  st.scroll  = opts.scroll or 1
  st.fxkey   = (opts.fxkey or ""):sub(1, 60)
  st.fxocc   = opts.fxocc or 0

  local values = {}
  for i = 0, SER.NEL - 1 do values[i] = 0 end

  local n, dropped = 0, 0
  local function place(e, label, label2, param, value)
    if n >= SER.NEL then dropped = dropped + 1; return false end
    st.elems[n]   = e
    st.labels[n]  = label or ""
    st.labels2[n] = label2 or ""
    st.links[n]   = param and (param + 1) or 0
    values[n]     = value or 0
    n = n + 1
    return true
  end

  -- The rows, before anything is placed: the plugin's order is kept as it
  -- stands, a row holds up to `cols` controls, and a section never runs into
  -- the next one -- it starts a row of its own, behind a rule.
  local rows = {}
  local cur, group = nil, nil
  for _, it in ipairs(items) do
    if it.group ~= group then
      if group ~= nil then rows[#rows + 1] = { sep = it.section or "" } end
      group, cur = it.group, nil
    end
    if not cur or #cur.items >= cols then
      cur = { items = {} }
      rows[#rows + 1] = cur
    end
    cur.items[#cur.items + 1] = it
  end

  -- Each row drops just far enough to clear the one above. `last` holds the
  -- kinds of the last row laid out: their drawn bottoms are what the gap is
  -- measured from.
  local y, last = 2, nil
  local function newrow(next_kinds)
    if last then y = y + B.row_step(m, last, next_kinds, air) end
    last = next_kinds
  end

  -- The VU holds the top band. It overflows upwards out of its own row: laid
  -- out higher than 3, it would be clipped by the panel edge.
  if opts.meter2 then
    y = 3
    place({ SER.METER2, 1, 0, 4 * (cols - 1), y, B.SIZE_METER, 0, SER.F_INITMAX | 32 }, "", "", nil, 0)
    last = { "meter2" }
  elseif opts.meter then
    y = 3
    place({ SER.METER, 1, 0, 4 * (cols - 1), y, B.SIZE_METER, 0, SER.F_INITMAX }, "", "", nil, 0)
    last = { "meter" }
  end

  for ri, row in ipairs(rows) do
    if row.sep ~= nil then
      newrow({ "sep" })

      -- A rule that does not fit is a rule less, not a control lost: the count
      -- of what was left out only speaks of controls.
      local held = dropped
      place({ SER.SEP, 0, 0, 4 * (cols - 1), y, 2, opts.sep_color or 7, 0 },
            row.sep:upper():sub(1, B.LABEL_MAX), "", nil, 0)
      dropped = held
    else
      local kinds = {}
      for _, it in ipairs(row.items) do kinds[#kinds + 1] = it.kind or "knob" end
      newrow(kinds)

      for col, it in ipairs(row.items) do
        local size = it.kind == "toggle" and B.SIZE_TOGGLE
                  or it.kind == "radio"  and B.SIZE_RADIO
                  or B.SIZE_KNOB

        local ty = it.kind == "toggle" and SER.TOGGLE
                or it.kind == "radio"  and SER.RADIO
                or SER.KNOB

        local color = it.color
        if type(color) == "table" then color = TH.pack(color) end

        if not place({ ty, n + 1, 0, (col - 1) * 8, y, size, color or 7, it.flags or 0 },
                     it.label, it.label2, it.param, it.value) then
          -- Out of slots: what is left of this row, and every row below it.
          dropped = dropped - 1
          for k = ri, #rows do
            dropped = dropped + (rows[k].items and #rows[k].items or 0)
          end
          for k = 1, col - 1 do dropped = dropped - 1 end
          return st, values, n, dropped
        end
      end
    end
  end

  return st, values, n, dropped
end

-- The smallest panel variant that shows everything without scrolling. Returns
-- the size and the height needed.
function B.pick_size(st)
  local need = SER.needed_px(st)
  for _, s in ipairs(B.SIZES) do
    if s.px >= need then return s, need end
  end
  return B.SIZES[#B.SIZES], need
end
end
-- ==========================================================================
-- 4. Track chunk
-- ==========================================================================
-- Laying a panel's state down means writing its <JS_SER> block, which ReaScript
-- exposes no other way than through the track chunk. This module locates and
-- replaces lines; it does not talk to REAPER, which is what makes it checkable
-- outside REAPER.

local CHUNK = {}
do
local C = CHUNK

-- REAPER returns its chunks in LF, but an .RfxChain that went through a Windows
-- machine comes back in CRLF -- four of the shipped chains are like that. So we
-- cut on \n and throw the stray \r away: the chunk we hand back is LF
-- throughout, which is what REAPER expects.
function C.split_lines(s)
  local t, pos = {}, 1
  while true do
    local i = s:find("\n", pos, true)
    local last = not i
    local line = last and s:sub(pos) or s:sub(pos, i - 1)
    if line:sub(-1) == "\r" then line = line:sub(1, -2) end
    if not last or pos <= #s then t[#t + 1] = line end
    if last then break end
    pos = i + 1
  end
  return t
end

-- The FX of a chunk, in order. Each entry carries the bounds of its main block
-- and, when there is one, those of its <JS_SER>.
--
-- The count leans on the FXID lines: REAPER writes one per FX, after its block.
-- Counting opening blocks would be fragile -- a <JS_SER> or a <PROGRAMENV>
-- would count as an FX.
function C.fx_blocks(lines)
  local start, stop, depth = nil, nil, 0
  for i, l in ipairs(lines) do
    local t = l:match("^%s*(.-)%s*$")
    if not start then
      if t:match("^<FXCHAIN") then start = i; depth = 1 end
    else
      if t:sub(1, 1) == "<" then depth = depth + 1
      elseif t == ">" then
        depth = depth - 1
        if depth == 0 then stop = i; break end
      end
    end
  end
  if not (start and stop) then return nil end

  local fxs, cur, d, bstart, btag = {}, {}, 0, nil, nil
  for i = start + 1, stop - 1 do
    local t = lines[i]:match("^%s*(.-)%s*$")
    if d == 0 then
      if t:sub(1, 1) == "<" then
        bstart, btag, d = i, t:match("^<(%S+)"), 1
      elseif t:match("^FXID") then
        fxs[#fxs + 1] = cur; cur = {}
      end
    else
      if t:sub(1, 1) == "<" then d = d + 1
      elseif t == ">" then
        d = d - 1
        if d == 0 then
          if btag == "JS_SER" then cur.ser = { bstart, i }
          else cur.main = { bstart, i, btag } end
        end
      end
    end
  end
  return fxs, start, stop
end

function C.b64_block(bin)
  local s = SER.b64encode(bin)
  local out = { "<JS_SER" }
  for i = 1, #s, 128 do out[#out + 1] = "  " .. s:sub(i, i + 127) end
  out[#out + 1] = ">"
  return out
end

local function fmtnum(v)
  if v == math.floor(v) then return tostring(math.floor(v)) end
  return (("%.6g"):format(v))
end

-- Rewrites FX number `fxi` (0-based): its slider values, its displayed name, and
-- its serialized block. Returns the new chunk, or nil + a message.
function C.patch(chunk, fxi, blob, values, rename)
  local lines = C.split_lines(chunk)
  local fxs = C.fx_blocks(lines)
  if not fxs then return nil, "no FXCHAIN in the chunk" end

  local e = fxs[fxi + 1]
  if not (e and e.main) then return nil, "FX " .. fxi .. " not found in the chunk" end

  local ms, me = e.main[1], e.main[2]
  if not lines[ms]:match("^%s*<JS%s") then
    return nil, "FX " .. fxi .. " is not a JSFX"
  end

  -- The panel's displayed name: the second field of the header. REAPER only
  -- quotes it when it has to -- a name without spaces is written bare -- and the
  -- JSFX path follows the same rule. So we read both fields token by token, and
  -- always write the name back quoted.
  if rename and rename ~= "" then
    local pre, rest = lines[ms]:match("^(%s*<JS%s+)(.*)$")
    if pre then
      local path, after
      if rest:sub(1, 1) == '"' then path, after = rest:match('^("[^"]*")%s*(.*)$')
      else                          path, after = rest:match("^(%S+)%s*(.*)$") end
      if path then
        local tail
        if after:sub(1, 1) == '"' then tail = after:match('^"[^"]*"(.*)$')
        else                           tail = after:match("^%S+(.*)$") end
        lines[ms] = pre .. path .. ' "' .. rename:gsub('"', "'") .. '"' .. (tail or "")
      end
    end
  end

  -- The values line: the first SER.NEL tokens are the sliders. What follows --
  -- the free slots and the preset name -- is left as it stands.
  if values and me > ms + 1 then
    local line, pos, count = lines[ms + 1], 1, 0
    while count < SER.NEL do
      local a, b = line:find("%S+", pos)
      if not a then break end
      pos, count = b + 1, count + 1
    end
    local v = {}
    for i = 0, SER.NEL - 1 do v[#v + 1] = fmtnum(values[i] or 0) end
    lines[ms + 1] = "  " .. table.concat(v, " ") .. line:sub(pos)
  end

  -- The serialized block replaces the one already there, or slips in just after.
  local blk = C.b64_block(blob)
  local from, to
  if e.ser then from, to = e.ser[1], e.ser[2] else from, to = me + 1, me end

  local out = {}
  for i = 1, from - 1 do out[#out + 1] = lines[i] end
  for _, l in ipairs(blk) do out[#out + 1] = l end
  for i = to + 1, #lines do out[#out + 1] = lines[i] end

  return table.concat(out, "\n") .. "\n"
end
end
-- ==========================================================================
-- Loaded outside REAPER
-- ==========================================================================
-- The tests load this file for its first four sections. Outside REAPER there is
-- no window to open: we hand back the internal table and stop there.
--

local API = { ser = SER, themes = TH, build = B, chunk = CHUNK }
if not rawget(_G, "reaper") then return API end

-- ==========================================================================
-- 5. Window
-- ==========================================================================
-- ReaImGui provides the window. Without it, nothing usable can be shown.
if not reaper.ImGui_GetBuiltinPath then
  reaper.MB("This script needs ReaImGui.\n\n" ..
            "Extensions > ReaPack > Browse packages, search for \"ReaImGui\",\n" ..
            "install it, then restart REAPER.",
            "StripTease Panel Builder", 0)
  return
end
package.path = reaper.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path
local ImGui = require "imgui" "0.9"

-- Lua only seeds itself from 5.4 on; without this, every session would draw the
-- same colours in the same order.
math.randomseed(math.floor(reaper.time_precise() * 1000) % 2147483647)

-- ---------------------------------------------------------------------------
-- REAPER side: reading the track and its plugins
-- ---------------------------------------------------------------------------

-- The matching key of an FX, exactly as FXKey does in StripTease System: the
-- original name, blind to any renaming of the instance.
local function fx_key(tr, fx)
  local ok, nm = reaper.TrackFX_GetNamedConfigParm(tr, fx, "fx_name")
  if not ok or nm == "" then
    local _, dn = reaper.TrackFX_GetFXName(tr, fx, "")
    nm = dn
  end
  return nm:sub(1, 60)
end

local function fx_display(tr, fx)
  local _, nm = reaper.TrackFX_GetFXName(tr, fx, "")
  return nm
end

-- The rank of this instance among the FX of the same key on the track.
local function fx_occurrence(tr, fx)
  local want, seen = fx_key(tr, fx), 0
  for i = 0, reaper.TrackFX_GetCount(tr) - 1 do
    if i == fx then return seen end
    if fx_key(tr, i) == want then seen = seen + 1 end
  end
  return 0
end

local function fx_by_guid(tr, guid)
  for i = 0, reaper.TrackFX_GetCount(tr) - 1 do
    if reaper.TrackFX_GetFXGUID(tr, i) == guid then return i end
  end
  return -1
end

local function is_panel(tr, fx)
  return fx_key(tr, fx):find("StripTease Panel", 1, true) ~= nil
end

local function is_striptease(tr, fx)
  local k = fx_key(tr, fx)
  return k:find("StripTease", 1, true) ~= nil
end

local function panel_indices(tr)
  local out = {}
  for i = 0, reaper.TrackFX_GetCount(tr) - 1 do
    if is_panel(tr, i) then out[#out + 1] = i end
  end
  return out
end

-- The plugins we can target: everything but the StripTease parts.
local function target_list(tr)
  local out = {}
  for i = 0, reaper.TrackFX_GetCount(tr) - 1 do
    if not is_striptease(tr, i) then
      -- The GUID, not the index: adding or removing an FX while the window is
      -- open would move the target under our feet.
      out[#out + 1] = { fx = i, name = fx_display(tr, i), key = fx_key(tr, i),
                        guid = reaper.TrackFX_GetFXGUID(tr, i) }
    end
  end
  return out
end

local function read_params(tr, fx)
  local n = reaper.TrackFX_GetNumParams(tr, fx)
  local out = {}
  for p = 0, n - 1 do
    local _, name = reaper.TrackFX_GetParamName(tr, fx, p, "")
    local _, minv, maxv = reaper.TrackFX_GetParam(tr, fx, p)

    -- The identifier says who declares the parameter: the plugin, or REAPER.
    local ident = ""
    if reaper.TrackFX_GetParamIdent then
      local okid, id = reaper.TrackFX_GetParamIdent(tr, fx, p, "")
      if okid then ident = id end
    end

    local okstep, step, _, _, istoggle = reaper.TrackFX_GetParameterStepSizes(tr, fx, p)
    local nv = reaper.TrackFX_GetParamNormalized(tr, fx, p)

    -- Formatting without writing: we read what the plugin would show, the
    -- current value is not touched.
    local function fmt(v)
      local ok, s = reaper.TrackFX_FormatParamValueNormalized(tr, fx, p, v, "")
      return ok and s or ""
    end

    out[#out + 1] = {
      idx = p, name = name, ident = ident,
      minv = minv, maxv = maxv,
      step = okstep and step or 0,
      istoggle = (istoggle == true),
      norm = nv,
      fmt0 = fmt(0), fmthalf = fmt(0.5), fmt1 = fmt(1),
      fmtnow = select(2, reaper.TrackFX_GetFormattedParamValue(tr, fx, p, "")),
    }
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Chunk side: laying the panel's <JS_SER> block down
-- ---------------------------------------------------------------------------

-- Writes the state and the values into FX number `fxi` of the track.
local function patch_panel(tr, fxi, st, values, rename)
  local ok, chunk = reaper.GetTrackStateChunk(tr, "", false)
  if not ok then return false, "chunk unreadable" end

  local out, err = CHUNK.patch(chunk, fxi, SER.encode(st), values, rename)
  if not out then return false, err end

  if not reaper.SetTrackStateChunk(tr, out, false) then
    return false, "SetTrackStateChunk refused"
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Window state
-- ---------------------------------------------------------------------------

local S = {
  track = nil, trackname = "",
  targets = {}, ti = 0,          -- candidate plugins, index in the list
  params = {}, rows = {},
  showall = false, hidden = 0,   -- parameters set aside: counted, and showable
  theme = nil,
  cols = 2,
  meter = true, meter2 = false, title = "",
  bg = 0x1E2024,
  sizemode = 0,                  -- 0 = automatic, otherwise an index in B.SIZES
  replace = 0,                   -- 0 = replace, 1 = add
  status = "", statuserr = false,
}

local KINDS = { "knob", "toggle", "radio" }
local KIND_LABELS = { "Knob", "Toggle", "Radio" }

local function rgb_int(t) return (t[1] << 16) | (t[2] << 8) | t[3] end
local function int_rgb(v) return { (v >> 16) & 255, (v >> 8) & 255, v & 255 } end

local function refresh_track()
  local tr = reaper.GetSelectedTrack(0, 0)
  S.track = tr
  S.targets, S.params, S.rows, S.hidden = {}, {}, {}, 0
  S.trackname = ""
  if not tr then return end
  local _, nm = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
  local n = math.floor(reaper.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER"))
  S.trackname = ("%d%s"):format(n, nm ~= "" and (" - " .. nm) or "")
  S.targets = target_list(tr)
  if S.ti >= #S.targets then S.ti = 0 end
end

-- Prepares one table row per parameter of the chosen plugin.
local function refresh_params()
  S.params, S.rows, S.hidden, S.drawn = {}, {}, 0, nil
  local t = S.targets[S.ti + 1]
  if not (S.track and t) then return end

  local fx = fx_by_guid(S.track, t.guid)
  if fx < 0 then return end

  S.params = read_params(S.track, fx)
  S.theme  = TH.for_fx(t.key)
  S.bg     = rgb_int(S.theme.bg)

  -- Only the plugin's own settings enter the list: neither what REAPER adds
  -- behind it, nor the empty slots the plugin leaves in its table. Set aside
  -- rather than unticked, because a list of sixty lines of which twenty are
  -- wanted reads badly. "Show all" brings them back, unticked, for the plugin
  -- that names an existing setting badly.
  local auto = B.auto_pick(S.params)

  for _, p in ipairs(S.params) do
    local real = not B.is_builtin(p.ident) and not B.is_hidden(p.name)
    if not real then S.hidden = S.hidden + 1 end

    if real or S.showall then
      local kind, _, flags = B.classify(p)
      local label, label2 = B.label_of(p.name), ""
      if kind == "toggle" then label, label2 = B.toggle_labels(p) end

      local fam = TH.family_of(p.name)
      local ki = 1
      for i, k in ipairs(KINDS) do if k == kind then ki = i end end

      S.rows[#S.rows + 1] = {
        p = p, on = auto[p] == true,
        kind = ki, label = label, label2 = label2,
        flags = flags, color = rgb_int(S.theme[fam] or S.theme.level),
      }
    end
  end

  -- The plugin name without its format prefix or its maker: that is what will
  -- name the FX slot.
  local short = t.name:gsub("^%a+3?:%s*", ""):gsub("%s*%b()%s*$", "")
  S.title = short:upper():sub(1, 20)
end

-- The slider value that renders the parameter's current position.
local function slider_value(row)
  local nv = math.max(0, math.min(1, row.p.norm or 0))
  if KINDS[row.kind] == "radio" then
    local pos = 2 + ((row.flags // 16) % 8)
    local k = math.floor(nv * (pos - 1) + 0.5)
    return math.floor(k * 127 / (pos - 1) + 0.5)
  end
  return math.floor(nv * 127 + 0.5)
end

-- Assembles the state from the ticked rows.
local function build()
  local t = S.targets[S.ti + 1]
  if not t then return nil end

  local kept = {}
  for _, r in ipairs(S.rows) do
    if r.on then kept[#kept + 1] = r end
  end

  -- The sections, read off the plugin's own order and naming.
  local names = {}
  for i, r in ipairs(kept) do names[i] = r.p.name end
  local secs = B.sections(names)

  local items = {}
  for i, r in ipairs(kept) do
    items[i] = {
      kind = KINDS[r.kind], label = r.label, label2 = r.label2,
      param = r.p.idx, flags = r.flags, color = int_rgb(r.color),
      value = slider_value(r),
      group = secs[i].group, section = secs[i].label,
    }
  end

  local fx = fx_by_guid(S.track, t.guid)
  if fx < 0 then return nil end

  local st, values, n, dropped = B.layout(items, {
    cols = S.cols, meter = S.meter, meter2 = S.meter2,
    bg = TH.pack(int_rgb(S.bg)),
    sep_color = S.theme and TH.pack(S.theme.title) or 7,
    fxkey = t.key, fxocc = fx_occurrence(S.track, fx),
  })

  local auto, need = B.pick_size(st)
  local size = (S.sizemode == 0) and auto or B.SIZES[S.sizemode]
  return st, values, n, size, need, auto, dropped
end

-- ---------------------------------------------------------------------------
-- The service
-- ---------------------------------------------------------------------------
-- A panel does not wire itself up: it publishes its recipe in gmem, and it is
-- StripTease System that reads it back and holds the links. Generating without
-- the service gives a mute panel, so we start it in the user's stead, then
-- watch the links appear in the LINKED block rather than announcing them on
-- trust.

local SYS_NS   = "StripTeaseGR"   -- same state namespace as StripTease System
local SYS_FILE = "StripTease System.lua"
-- LINKED block: 512 panel slots x 128 elements. The slot is not the track: the
-- first panel of a track keeps its track's slot, the next ones take one from the
-- reserve. The check below watches the track slot, which is the one the panel it
-- has just generated gets whenever it is the only panel on that track.
local LNK      = 65536
local KSTRIDE  = 128
local VERIFY_TIMEOUT = 6          -- seconds: the service rescans every 2 s

reaper.gmem_attach("StripTease")

-- The service writes its clock every eight frames; past a second of silence it
-- is no longer running. That is the test it applies to itself at startup so as
-- not to double up.
local function system_alive()
  local t = tonumber(reaper.GetExtState(SYS_NS, "alive") or "")
  return t ~= nil and (reaper.time_precise() - t) < 1.0
end

local function system_path()
  local sep = package.config:sub(1, 1)
  local cands = {}

  -- Next to this script first: that is where ReaPack puts the two of them.
  local here = select(2, reaper.get_action_context())
  local dir = here and here:match("^(.*)[/\\][^/\\]*$")
  if dir then cands[#cands + 1] = dir .. sep .. SYS_FILE end

  local res = reaper.GetResourcePath()
  cands[#cands + 1] = res .. sep .. "Scripts" .. sep .. "StripTease" .. sep .. SYS_FILE
  cands[#cands + 1] = res .. sep .. "Scripts" .. sep .. SYS_FILE

  for _, c in ipairs(cands) do
    local f = io.open(c, "r")
    if f then f:close(); return c end
  end
end

-- Returns true if the service is running on return. Launching the action while
-- it is already running would stop it, so the liveness test comes first.
local function ensure_system()
  if system_alive() then return true end

  local path = system_path()
  if not path then return false, SYS_FILE .. " not found" end

  -- Registering an already-registered script hands back its identifier without
  -- creating a second one.
  local cmd = reaper.AddRemoveReaScript(true, 0, path, true)
  if not cmd or cmd == 0 then return false, "StripTease System refuses to register" end

  reaper.Main_OnCommand(cmd, 0)
  return true
end

-- The track rank the service files a panel under: the master at 0, the others
-- at their own number.
local function track_key(tr)
  local n = math.floor(reaper.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER") or 0)
  return n < 0 and 0 or n
end

-- Checking afterwards: the service does not wire within the second, so we keep
-- the question open for a few frames and answer once we know.
local V = { k = nil }

local function verify_tick()
  if not V.k then return end

  local got, base = 0, LNK + V.k * KSTRIDE
  for el = 0, SER.NEL - 1 do
    if (reaper.gmem_read(base + el) or 0) > 0 then got = got + 1 end
  end

  if got >= V.want then
    S.status, S.statuserr = ("%s, %d links"):format(V.msg, got), false
    V.k = nil
  elseif reaper.time_precise() - V.t0 > VERIFY_TIMEOUT then
    if got > 0 then
      S.status, S.statuserr = ("%s, %d links out of %d"):format(V.msg, got, V.want), false
    else
      S.status = V.msg .. " -- no link: StripTease System is not answering"
      S.statuserr = true
    end
    V.k = nil
  end
end

-- ---------------------------------------------------------------------------
-- Generating
-- ---------------------------------------------------------------------------

local function add_panel(tr, stem)
  for _, name in ipairs({ "StripTease/StripTease Panel " .. stem .. " px",
                          "StripTease Panel " .. stem .. " px" }) do
    local i = reaper.TrackFX_AddByName(tr, name, false, -1)
    if i >= 0 then return i end
  end
  return -1
end

local function generate()
  local st, values, n, size = build()
  if not st then return false, "no target plugin" end
  if n == 0 then return false, "nothing ticked" end

  local tr = S.track
  local guid = S.targets[S.ti + 1].guid

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  -- Deletions shift the indexes: we find the target again by its GUID.
  if S.replace == 0 then
    local old = panel_indices(tr)
    for i = #old, 1, -1 do reaper.TrackFX_Delete(tr, old[i]) end
  end

  local pos = fx_by_guid(tr, guid)
  if pos < 0 then
    reaper.PreventUIRefresh(-1)
    reaper.Undo_EndBlock("StripTease: generate a panel", -1)
    return false, "the target plugin has vanished"
  end

  local added = add_panel(tr, size.stem)
  if added < 0 then
    reaper.PreventUIRefresh(-1)
    reaper.Undo_EndBlock("StripTease: generate a panel", -1)
    return false, "panel \"" .. size.stem .. " px\" not found -- is StripTease installed?"
  end

  -- The panel goes right before the plugin: that is how the shipped FX chains
  -- are arranged, and what makes the virtual gain reduction measurement work.
  -- We note its GUID before moving it and find it again afterwards: where a
  -- move exactly lands an FX is not guessed, it is checked.
  --
  local pguid = reaper.TrackFX_GetFXGUID(tr, added)
  if added ~= pos then reaper.TrackFX_CopyToTrack(tr, added, tr, pos, true) end

  local panel = fx_by_guid(tr, pguid)
  if panel < 0 then
    reaper.PreventUIRefresh(-1)
    reaper.Undo_EndBlock("StripTease: generate a panel", -1)
    return false, "the panel just added cannot be found after the move"
  end

  local ok, err = patch_panel(tr, panel, st, values, S.title)

  if ok then
    for i = 0, SER.NEL - 1 do
      reaper.TrackFX_SetParam(tr, panel, i, values[i] or 0)
    end
  end

  reaper.PreventUIRefresh(-1)
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("StripTease: generate a panel", -1)

  if not ok then return false, err end

  local msg = ("%d elements, %d px panel"):format(n, size.px)

  -- The links: the panel already carries its recipe in its state, all that is
  -- missing is the service to serve it.
  local sysok, syserr = ensure_system()
  if not sysok then
    return true, msg .. " -- " .. syserr .. ", the links will not be made"
  end

  local want = 0
  for i = 0, SER.NEL - 1 do
    if (st.links[i] or 0) > 0 then want = want + 1 end
  end
  if want > 0 then
    V.k, V.want, V.t0, V.msg = track_key(tr), want, reaper.time_precise(), msg
    return true, msg .. ", linking"
  end

  return true, msg
end

-- ---------------------------------------------------------------------------
-- Window
-- ---------------------------------------------------------------------------

local ctx = ImGui.CreateContext("StripTease Panel Builder")

-- Redraws the colours of the ticked rows, and of those only.
--
-- One tint per family, so that ATTACK and RELEASE stay together, and a fresh
-- draw on every press -- within the temperature of each family, which never
-- moves: gain and drive warm, ratio, times, EQ and mix cool. The rows left
-- unticked keep the colour they wear.
local function recolour()
  local families = {}
  for _, r in ipairs(S.rows) do
    if r.on then families[TH.family_of(r.p.name)] = true end
  end

  S.drawn = TH.draw(families, S.drawn)

  for _, r in ipairs(S.rows) do
    if r.on then
      local c = S.drawn[TH.family_of(r.p.name)]
      if c then r.color = rgb_int(c) end
    end
  end
end

-- A drop-down over a table of labels, indexed from 1.
local function combo(id, cur, list, width)
  if width then ImGui.SetNextItemWidth(ctx, width) end
  local changed = false
  if ImGui.BeginCombo(ctx, id, list[cur] or "") then
    for i, v in ipairs(list) do
      ImGui.PushID(ctx, i)
      local sel = (i == cur)
      if ImGui.Selectable(ctx, v, sel) then cur = i; changed = true end
      if sel then ImGui.SetItemDefaultFocus(ctx) end
      ImGui.PopID(ctx)
    end
    ImGui.EndCombo(ctx)
  end
  return changed, cur
end

local COLS_LABELS  = { "1", "2", "3", "4" }

local function draw_settings()
  local _

  _, S.cols = combo("Columns", S.cols, COLS_LABELS, 70)

  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, 150)
  _, S.bg = ImGui.ColorEdit3(ctx, "Background", S.bg, ImGui.ColorEditFlags_NoInputs)

  _, S.meter = ImGui.Checkbox(ctx, "Gain reduction VU on top", S.meter)
  _, S.meter2 = ImGui.Checkbox(ctx, "Stereo VU on top (classic, peak hold)", S.meter2)
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, 180)
  _, S.title = ImGui.InputText(ctx, "Slot name", S.title)
end

local function draw_table()
  local flags = ImGui.TableFlags_Borders | ImGui.TableFlags_RowBg
              | ImGui.TableFlags_ScrollY | ImGui.TableFlags_SizingStretchProp
  if not ImGui.BeginTable(ctx, "params", 5, flags, 0, 320) then return end

  ImGui.TableSetupColumn(ctx, "##on", ImGui.TableColumnFlags_WidthFixed, 26)
  ImGui.TableSetupColumn(ctx, "Parameter", ImGui.TableColumnFlags_WidthStretch, 2)
  ImGui.TableSetupColumn(ctx, "Label", ImGui.TableColumnFlags_WidthFixed, 130)
  ImGui.TableSetupColumn(ctx, "Type", ImGui.TableColumnFlags_WidthFixed, 90)
  ImGui.TableSetupColumn(ctx, "Colour", ImGui.TableColumnFlags_WidthFixed, 70)
  ImGui.TableSetupScrollFreeze(ctx, 0, 1)
  ImGui.TableHeadersRow(ctx)

  for i, r in ipairs(S.rows) do
    ImGui.PushID(ctx, i)
    ImGui.TableNextRow(ctx)

    ImGui.TableSetColumnIndex(ctx, 0)
    local _
    _, r.on = ImGui.Checkbox(ctx, "##on", r.on)

    ImGui.TableSetColumnIndex(ctx, 1)
    ImGui.Text(ctx, ("%3d  %s"):format(r.p.idx, r.p.name))
    if ImGui.IsItemHovered(ctx) and r.p.fmtnow and r.p.fmtnow ~= "" then
      ImGui.SetTooltip(ctx, ("now: %s\n0 %%: %s\n50 %%: %s\n100 %%: %s")
        :format(r.p.fmtnow, r.p.fmt0, r.p.fmthalf, r.p.fmt1))
    end

    ImGui.TableSetColumnIndex(ctx, 2)
    ImGui.SetNextItemWidth(ctx, -1)
    local _
    _, r.label = ImGui.InputText(ctx, "##lab", r.label)

    ImGui.TableSetColumnIndex(ctx, 3)
    local ch
    ch, r.kind = combo("##kind", r.kind, KIND_LABELS, -1)
    if ch and KINDS[r.kind] == "radio" and (r.flags // 16) % 8 == 0 then
      r.flags = r.flags | 16          -- three positions by default
    end

    ImGui.TableSetColumnIndex(ctx, 4)
    ImGui.SetNextItemWidth(ctx, -1)
    _, r.color = ImGui.ColorEdit3(ctx, "##col", r.color, ImGui.ColorEditFlags_NoInputs)

    ImGui.PopID(ctx)
  end

  ImGui.EndTable(ctx)
end

local function loop()
  -- A track deleted under the window would leave a dead pointer in every read
  -- that follows.
  if S.track and not reaper.ValidatePtr2(0, S.track, "MediaTrack*") then
    S.track, S.targets, S.params, S.rows, S.hidden = nil, {}, {}, {}, 0
  end

  verify_tick()

  ImGui.SetNextWindowSize(ctx, 720, 640, ImGui.Cond_FirstUseEver)
  local visible, open = ImGui.Begin(ctx, "StripTease Panel Builder", true)

  if visible then
    -- Track and target plugin
    ImGui.Text(ctx, S.track and ("Track: " .. S.trackname) or "No track selected.")
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Reread the track") then
      refresh_track(); refresh_params(); S.status = ""
    end

    if #S.targets == 0 then
      ImGui.Separator(ctx)
      ImGui.TextWrapped(ctx, "Select a track carrying at least one plugin, " ..
                             "then click Reread the track.")
    else
      local names = {}
      for i, t in ipairs(S.targets) do names[i] = t.name end
      local ch
      ch, S.ti = combo("##target", S.ti + 1, names, -1)
      S.ti = S.ti - 1
      if ch then refresh_params(); S.status = "" end

      ImGui.Separator(ctx)
      draw_settings()
      ImGui.Separator(ctx)

      if ImGui.Button(ctx, "Tick all") then
        for _, r in ipairs(S.rows) do r.on = true end
      end
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, "None") then
        for _, r in ipairs(S.rows) do r.on = false end
      end
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, "Auto") then
        local auto = B.auto_pick(S.params)
        for _, r in ipairs(S.rows) do r.on = auto[r.p] == true end
      end
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, "Recolour") then recolour() end
      ImGui.SameLine(ctx)
      local chall
      chall, S.showall = ImGui.Checkbox(ctx, "Show all", S.showall)
      if chall then refresh_params() end
      if S.hidden > 0 then
        ImGui.SameLine(ctx)
        ImGui.Text(ctx, ("(%d not on the plugin)"):format(S.hidden))
      end

      draw_table()

      -- What it will come out as
      local st, _, n, size, need, auto, dropped = build()
      if st then
        local rows = math.ceil(math.max(0, n - ((S.meter or S.meter2) and 1 or 0)) / S.cols)
        ImGui.Text(ctx, ("%d elements  -  %d rows  -  height %d px"):format(n, rows, need))
        if dropped > 0 then
          ImGui.SameLine(ctx)
          ImGui.Text(ctx, ("  -  %d too many, a panel only carries %d")
            :format(dropped, SER.NEL))
        end

        local items = { "Automatic (" .. auto.px .. " px)" }
        for _, sz in ipairs(B.SIZES) do items[#items + 1] = sz.px .. " px" end
        local _
        _, S.sizemode = combo("Panel size", S.sizemode + 1, items, 220)
        S.sizemode = S.sizemode - 1
        if size.px < need then
          ImGui.SameLine(ctx)
          ImGui.Text(ctx, "  the panel will have to scroll")
        end

        if #panel_indices(S.track) > 0 then
          local _
          _, S.replace = combo("Panel already present", S.replace + 1,
                               { "Replace it", "Add another one" }, 220)
          S.replace = S.replace - 1
        end
      end

      ImGui.Separator(ctx)
      if ImGui.Button(ctx, "Create the panel", 160, 28) then
        local ok, msg = generate()
        S.status, S.statuserr = msg, not ok
      end
      if S.status ~= "" then
        ImGui.SameLine(ctx)
        ImGui.Text(ctx, (S.statuserr and "failed: " or "done: ") .. S.status)
      end
    end

    ImGui.End(ctx)
  end

  if open then reaper.defer(loop) end
end

refresh_track()
refresh_params()
reaper.defer(loop)
