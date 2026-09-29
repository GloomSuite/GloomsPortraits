-- ============================================================
-- GloomsPortraits_Pages.lua — Gloom's Portraits
-- ★ THE TWO-WINDOW DESIGN (2026-09-27). Portraits was never mocked: it is
-- built from Unit Frames' pages, the nearest relative (two fixed units, a
-- frame dragged on screen while the windows are open), so it reads as the
-- same family — the owner, 2026-09-27: "there's already a lot of source
-- material". The Hub (Windows.lua) owns the windows: the SELECTOR (240 wide,
-- 105 tall — just Player | Target), the SETTINGS window (400) with its TAB
-- ("gloomPORTRAITS: Player"), the pop-outs, the headers, the scrolling and
-- Global Settings. This file draws:
--   the selector's two unit buttons;
--   the tab;
--   two SECTIONS — Global <Unit> Settings (display type, visibility, place,
--     size, layer, reset) · 3D Camera (dims in 2D, and when the unit is Never).
-- Every number is a Unit Frames number: a labelled control is 31 tall (the
-- label's 11, 4, the 16-tall control), rows 41 apart, blocks 30 apart,
-- columns 170 at 0 / 190. Disabled = 30%, never hidden.
-- It is DRAWING only: every control calls the engine's API
-- (GloomsPortraits.lua) exactly as the previous tab did. The previous tab
-- (GloomsPortraits_Tab.lua) is no longer loaded; delete it once the owner
-- approves these windows.
-- ============================================================

local SKIN_NEEDS = 17
local Skin, skinMinor
if LibStub then Skin, skinMinor = LibStub("LibGloomSkin-1.0", true) end
local GP = _G.GloomsPortraits
if not (Skin and GP) then return end
if (skinMinor or 0) < SKIN_NEEDS then
  print("|cffff7729Gloom's Portraits:|r the Portraits windows need Gloom's Hub with LibGloomSkin " .. SKIN_NEEDS .. " or newer — update Gloom's Hub.")
  return
end

local UI, COLOR, FONT = Skin.UI, Skin.COLOR, Skin.FONT
local LIME, LILAC = COLOR.lime, COLOR.lilac
local DIM = UI.G_DIM or 0.3
local attachTip = UI.attachTip

local UNIT_LABEL = { player = "Player", target = "Target" }
local selected = "player"
local P = { secs = {} }

local function Cfg() return selected and GP:Config(selected) or nil end
local function Relayout() if GloomsHub.RefreshWindows then GloomsHub:RefreshWindows("portraits") end end
local function is3D() local c = Cfg(); return not c or (c.mode or "3d") == "3d" end
local function never() local c = Cfg(); return c and c.showCondition == "never" end

function P.refreshAll()
  for _, s in ipairs(P.secs) do if s.refresh then s.refresh() end end
  Relayout()
end

local STRATA = {
  { "BACKGROUND", "Background" }, { "LOW", "Low" }, { "MEDIUM", "Medium" }, { "HIGH", "High" }, { "DIALOG", "Dialog" },
}
local STRATA_LABEL = {}
for _, s in ipairs(STRATA) do STRATA_LABEL[s[1]] = s[2] end

local COND = {
  { "always", "Always" }, { "combat", "In Combat" }, { "target", "Show When Target Is Selected" },
  { "combat_or_target", "Combat or Target" }, { "never", "Never" },
}
local COND_LABEL = {}
for _, c in ipairs(COND) do COND_LABEL[c[1]] = c[2] end

-- ---------------------------------------------------------------------------
-- CELLS — a labelled control (Unit Frames' shape): :refresh(), :setEnabled(on)
-- (the label dims with it).
-- ---------------------------------------------------------------------------
local function cell(parent, text, w, make)
  local c = CreateFrame("Frame", nil, parent); c:SetSize(w, 31)
  c.label = UI.gLabel(c, text or ""); c.label:SetPoint("TOPLEFT", 0, 0)
  c.control = make(c, w)
  c.control:SetPoint("TOPLEFT", 0, -15)
  function c:refresh() if self.control.refresh then self.control:refresh() end end
  function c:setEnabled(on)
    on = on and true or false
    if self.control.setEnabled then self.control:setEnabled(on) end
    self.label:SetAlpha(on and 1 or DIM)
  end
  return c
end
local function Switch(parent, text, w, choices, get, set)
  return cell(parent, text, w, function(c, cw) return UI.gSwitch(c, choices, get, set, { w = cw }) end)
end
local function Drop(parent, text, w, getLabel, getOptions, getCurrent, onPick)
  return cell(parent, text, w, function(c, cw) return UI.gDrop(c, cw, getLabel, getOptions, getCurrent, onPick) end)
end
local function Dial(parent, w, opts)
  opts.w = w
  return UI.gDial(parent, opts)
end
local function place(wd, x, y) wd:ClearAllPoints(); wd:SetPoint("TOPLEFT", x, -y); wd:Show() end

local function Section(parent, h)
  local f = CreateFrame("Frame", nil, parent); f:SetSize(360, h)
  local s = { frame = f }
  P.secs[#P.secs + 1] = s
  f:HookScript("OnShow", function() if s.refresh then s.refresh() end end)
  return f, s
end

-- ===========================================================================
-- THE SELECTOR — Player | Target, 98 × 23, 4 apart, 52 down (Unit Frames').
-- ===========================================================================
local unitBtns = {}
local function SelectUnit(which)
  selected = which
  for u, b in pairs(unitBtns) do b:SetSelected(u == which) end
  if P.windowsOpen then GP:SetEditing(which) end
  P.refreshAll()
end

local function buildSelector(c)
  for i, which in ipairs(GP.UNITS) do
    local b = UI.gButton(c, UNIT_LABEL[which], { w = 98, h = 23, size = 10, onClick = function() SelectUnit(which) end })
    b:SetPoint("TOPLEFT", 20 + (i - 1) * 102, -52)
    b:SetSelected(which == selected)
    unitBtns[which] = b
  end
  attachTip(unitBtns.player, "Player", "Edit the player portrait. While these windows are open it can be dragged on screen; the green outline is its frame — the model itself may be smaller.")
  attachTip(unitBtns.target, "Target", "Edit the target portrait. It shows empty until you have a target; while these windows are open it can be dragged on screen.")
end

-- ===========================================================================
-- THE TAB — "gloomPORTRAITS:" lime, the unit white, Sansation 10.
-- ===========================================================================
local function buildTab(tab)
  local t = {}
  local lead = UI.newText(tab, FONT.sa, 10, LIME, "LEFT"); lead:SetPoint("TOPLEFT", 20, -9)
  lead:SetText("gloomPORTRAITS: ")
  local name = UI.newText(tab, FONT.sa, 10, COLOR.paper, "LEFT"); name:SetPoint("LEFT", lead, "RIGHT", 0, 0)
  function t:refresh() name:SetText(UNIT_LABEL[selected] or "") end
  t:refresh()
  return t
end

-- ===========================================================================
-- SECTION · GLOBAL <UNIT> SETTINGS — Unit Frames' Global block, with Display
-- Type where Unit Frames has its font: Strata | Level as there (Level added
-- 2026-09-29), then Size, then Reset.
-- ===========================================================================
local function buildGlobal(parent)
  local f, s = Section(parent, 220)
  local function num(field, default) return function() local c = Cfg(); return (c and c[field]) or default end end
  local function setLayout(field)
    return function(v)
      local c = Cfg(); if not c then return end
      c[field] = v
      GP:ApplyLayout(selected)
      if field == "size" and P.windowsOpen then GP:SetEditing(selected) end   -- the outline follows the size
    end
  end
  local mode = Switch(f, "Display Type", 170, { { "3d", "3D Model" }, { "2d", "2D Portrait" } },
    function() local c = Cfg(); return (c and c.mode) or "3d" end,
    function(v)
      GP:SetMode(selected, v)
      if P.windowsOpen then GP:SetEditing(selected) end   -- each type keeps its own place and size
      P.refreshAll()
    end)
  attachTip(mode.control, "Display type", "3D Model: the full-body model, which turns, zooms and tilts (3D Camera below). 2D Portrait: the unit's flat portrait, drawn as a circle. Each type keeps its own size, position and layer.")
  place(mode, 0, 0)
  local cond = Drop(f, "Visibility", 170,
    function() local c = Cfg(); return COND_LABEL[(c and c.showCondition) or "always"] or "Always" end,
    function() local o = {}; for _, x in ipairs(COND) do o[#o + 1] = { value = x[1], label = x[2] } end; return o end,
    function() local c = Cfg(); return (c and c.showCondition) or "always" end,
    function(v) GP:SetCondition(selected, v); P.refreshAll() end)
  attachTip(cond.control, "Visibility", "Always (the target portrait still needs a target) · only in combat · only with a target · either · Never — hidden outright. The settings are kept.")
  place(cond, 0, 41)
  local x = Dial(f, 170, { label = "Horizontal Position", min = -700, max = 700, step = 1, unit = "px", dragPx = 1400, get = num("x", 0), set = setLayout("x") })
  place(x, 190, 0)
  local y = Dial(f, 170, { label = "Vertical Position", min = -400, max = 400, step = 1, unit = "px", dragPx = 1000, get = num("y", 0), set = setLayout("y") })
  place(y, 190, 41)
  local size = Dial(f, 170, { label = "Size", min = 50, max = 700, step = 1, unit = "px", dragPx = 900, get = num("size", 350), set = setLayout("size") })
  attachTip(size.strip, "Size", "The portrait's frame — a square this many pixels on a side.")
  place(size, 0, 143)
  local strata = Drop(f, "Strata", 170,
    function() local c = Cfg(); return STRATA_LABEL[(c and c.strata) or "MEDIUM"] or "Medium" end,
    function() local o = {}; for _, x2 in ipairs(STRATA) do o[#o + 1] = { value = x2[1], label = x2[2] } end; return o end,
    function() local c = Cfg(); return (c and c.strata) or "MEDIUM" end,
    function(v) GP:SetStrata(selected, v) end)
  attachTip(strata.control, "Strata", "Background is behind almost everything; Dialog above almost everything. Medium — the default — sits with most of the UI.")
  place(strata, 0, 102)
  -- LEVEL (2026-09-29): the fine order within the strata — 0 = Auto
  local level = Dial(f, 170, { label = "Level", min = 0, max = 500, step = 1, dragPx = 1000,
    fmt = function(v) v = math.floor(v + 0.5); return v == 0 and "Auto" or tostring(v) end,
    get = function() local c = Cfg(); return (c and c.level) or 0 end,
    set = function(v) GP:SetLevel(selected, v) end })
  attachTip(level, "Level", "Fine order within the strata: higher draws in front — to tuck the portrait above or behind a Unit Frames bar or an overlay on the same strata. Auto: the game's own level. 3D and 2D each keep their own.")
  place(level, 190, 102)
  local reset = UI.gButton(f, "Reset to Defaults", { w = 175, h = 16, pad = 10, onClick = function()
    UI.confirm(("Reset the %s portrait to its factory position, size and settings?"):format(UNIT_LABEL[selected]:lower()),
      function() GP:Reset(selected); P.refreshAll() end, "Reset")
  end })
  reset:SetPoint("TOPLEFT", 0, -204)
  attachTip(reset, "Reset to defaults", "Puts this portrait back where a fresh install would have it. Asks first.")
  P.posDials = { x, y }
  s.refresh = function() for _, w in ipairs({ mode, cond, x, y, size, strata, level }) do w:refresh() end end
  return f
end

-- ===========================================================================
-- SECTION · 3D CAMERA — Facing | Zoom, Vertical Offset | Pitch. For the
-- target, the one thing a 3D target cannot do is said first. Dims (30%) in 2D.
-- ===========================================================================
local function buildCamera(parent)
  local f, s = Section(parent, 72)
  local function cam(key, default) return function() local c = Cfg(); return (c and c[key]) or default end end
  local function setCam(key) return function(v) GP:SetCamera(selected, key, v) end end
  local note = UI.newText(f, FONT.sa, 10, LILAC, "LEFT")
  note:SetPoint("TOPLEFT", 0, 0); note:SetWidth(360); note:SetJustifyH("LEFT"); note:SetWordWrap(true)
  note:SetText("In dungeons, raids and delves the game won't identify an enemy targeted mid-combat. Mobs you targeted before the pull stay 3D; anything else shows the 2D portrait, at the size, position and layer set for 2D.")
  -- Facing is STORED in radians; shown and dragged in degrees.
  local facing = Dial(f, 170, { label = "Facing", min = 0, max = 359, step = 1, unit = "°", dragPx = 720,
    get = function() return math.floor(math.deg(cam("facing", 0)()) + 0.5) % 360 end,
    set = function(v) GP:SetCamera(selected, "facing", math.rad(v)) end })
  attachTip(facing.strip, "Facing", "Which way the model turns: 0 faces you.")
  local zoom = Dial(f, 170, { label = "Zoom", min = 0.5, max = 5, step = 0.05, dragPx = 900, get = cam("zoom", 2.5), set = setCam("zoom") })
  attachTip(zoom.strip, "Zoom", "The camera's distance — lower is closer.")
  local offset = Dial(f, 170, { label = "Vertical Offset", min = -400, max = 400, step = 1, dragPx = 1000, get = cam("modelYOffset", 0), set = setCam("modelYOffset") })
  attachTip(offset.strip, "Vertical offset", "Slides the model up or down inside its frame.")
  local pitch = Dial(f, 170, { label = "Pitch", min = -1.5, max = 1.5, step = 0.02, dragPx = 900, get = cam("pitch", 0), set = setCam("pitch") })
  attachTip(pitch.strip, "Pitch", "Tilts the model toward or away from you.")
  local dials = { facing, zoom, offset, pitch }
  s.refresh = function()
    local top = 0
    if selected == "target" then
      note:Show(); top = math.ceil(note:GetStringHeight()) + 14
    else
      note:Hide()
    end
    place(facing, 0, top); place(zoom, 190, top)
    place(offset, 0, top + 41); place(pitch, 190, top + 41)
    local on = is3D() and not never()
    for _, d in ipairs(dials) do d:refresh(); d:setEnabled(on) end
    note:SetAlpha(on and 1 or DIM)
    local h = top + 72
    if math.abs((f:GetHeight() or 0) - h) > 0.5 then f:SetHeight(h) end
  end
  return f
end

-- ===========================================================================
-- Mount the Portraits windows (CONTRACTS §2, the two-window block). No
-- profile: Portraits has two fixed units and one account-wide config.
-- ===========================================================================
GloomsHub:RegisterTab{
  id       = "portraits",
  title    = "Portraits",
  order    = 40,
  wordmark = "PORTRAITS",
  product  = "GloomPortraits",
  windows  = true,
  selector = { build = buildSelector, h = 105 },
  tab      = { w = 360, build = buildTab },
  sections = {
    { id = "global", title = function() return ("Global %s Settings"):format(UNIT_LABEL[selected] or "") end, build = buildGlobal },
    { id = "camera", title = "3D Camera", build = buildCamera, dim = function() return never() or not is3D() end },
  },
  onOpen   = function()
    P.windowsOpen = true
    GP:SetEditing(selected)
    for _, s in ipairs(P.secs) do if s.refresh then s.refresh() end end
  end,
  onClose  = function()
    P.windowsOpen = false
    GP:SetEditing(nil)
  end,
  refresh  = function() for _, s in ipairs(P.secs) do if s.refresh then s.refresh() end end end,
}

-- A drag on screen moves the portrait; keep the position dials honest.
GP:OnChange(function(what, which)
  if which ~= selected then return end
  if what == "position" and P.posDials then for _, d in ipairs(P.posDials) do d:refresh() end end
end)
