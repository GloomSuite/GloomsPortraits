-- ============================================================
-- GloomsPortraits_Tab.lua
-- The PORTRAITS tab of the Suite window (stage 2, 2026-09-19).
--
-- The stage-1 floating control panel (native Blizzard chrome, two button
-- tabs, OptionsSliderTemplate sliders) is GONE. Its contents mount as ONE
-- tab inside GloomsHub's shell, laid out the way Gloom's Bars and Gloom's
-- Overlays lay out theirs (GB is the reference, not GA):
--   • LEFT RAIL  — the Gp mark, the two portraits (Player / Target) as a
--                  selectable list, and Reset for the selected one.
--   • RIGHT PANE — the selected portrait's settings, scrolling.
-- No footer: nothing here is typed-then-saved, every control applies the
-- moment it moves, and the on-screen portrait IS the preview.
-- No profile block: Portraits has two fixed units and one account-wide
-- config — there is nothing to switch between. That is inherited, not a
-- decision, and adding profiles later would mean UI.profileBlock like the
-- other three tabs.
-- Every widget comes from LibGloomSkin-1.0. The engine (GloomsPortraits.lua)
-- exposes what this file drives on the `GloomsPortraits` namespace.
-- ============================================================

-- --------------------------------------------------------------------------
-- ★ SHARED-TOOLKIT VERSION GATE — see GloomsHub/docs/CONTRACTS.md §6.
-- "## Dependencies: GloomsHub" only checks that the Hub is PRESENT, never
-- that it is NEW ENOUGH. Check first, and fail with ONE actionable sentence.
-- ★ BUMP SKIN_NEEDS IN THE SAME COMMIT that first calls a newer widget.
-- This file needs tabHeader (MINOR 4); everything else it calls is older.
-- --------------------------------------------------------------------------
local SKIN_MAJOR, SKIN_NEEDS = "LibGloomSkin-1.0", 4

local Skin, skinMinor = LibStub(SKIN_MAJOR, true)
if not Skin or (skinMinor or 0) < SKIN_NEEDS then
  local found = Skin and ("v" .. tostring(skinMinor or 0)) or "none"
  local warn = CreateFrame("Frame")
  warn:RegisterEvent("PLAYER_LOGIN")
  warn:SetScript("OnEvent", function(self)
    self:UnregisterAllEvents()
    print("|cffff7729Gloom's Portraits:|r please update |cff936bffGloom's Hub|r. This version of "
      .. "Portraits needs a newer Hub toolkit (needs v" .. SKIN_NEEDS .. ", found " .. found
      .. "), so the PORTRAITS tab is unavailable. Your portraits keep rendering normally.")
  end)
  return   -- chunk-level return: the tab is never registered; RENDERING is untouched
end
local UI = Skin.UI
local COLOR, FONT = Skin.COLOR, Skin.FONT
local TEXT, MUTE = COLOR.text, COLOR.mute

local newText, flatButton, flatEditBox = UI.newText, UI.flatButton, UI.flatEditBox
local sliderRow, makeScrollbar, attachTip, hLine = UI.sliderRow, UI.makeScrollbar, UI.attachTip, UI.hLine

local GP = _G.GloomsPortraits

-- Every (Hub font, size) pair this tab draws BEYOND the Hub's own warm list —
-- a cold pair renders BLANK on its first draw each session (CONTRACTS §4).
-- This tab draws head 12/13 · body 10.5/11/12 · label 11 (sliderRow values),
-- plus bodyM 11 indirectly (flatButton). The base list covers all but these.
UI.RegisterWarmPairs({
  { FONT.head, 13 },    -- editor section headers
  { FONT.label, 11 },   -- sliderRow value labels
})

-- --------------------------------------------------------------------------
-- Layout constants. The shell hands us a container of AT LEAST 860x626
-- (CONTRACTS §2, PINNED).
-- --------------------------------------------------------------------------
local RAIL_W     = 240
local PAD        = 18
local LIST_ROW_H = 30
local CONTENT_H  = 700    -- editor scroll-child height (3D layout; 2D is shorter)

local container, rail, editorScroll, editorChild, editorBody, emptyNote
local selected            -- "player" | "target" | nil
local rows = {}

-- Editor widgets hang on E rather than becoming file locals (Lua's
-- 200-locals-per-function cap — the trap GA hit).
local E = {}

local RefreshList, SelectUnit, RefreshEditor

local UNIT_LABEL = { player = "Player", target = "Target" }
local MODE_LABEL = { ["3d"] = "3D", ["2d"] = "2D" }
local COND_LABEL = {
  always           = "Always",
  combat           = "In combat",
  target           = "Target selected",
  combat_or_target = "Combat or target",
  never            = "Off",
}

local function Cfg()
  return selected and GP:Config(selected) or nil
end

-- --------------------------------------------------------------------------
-- Small local widget shapes built on the lib (the same shapes the Overlays
-- tab keeps; `makeSection`-style helpers are deliberately NOT in the lib).
-- --------------------------------------------------------------------------
local function label(parent, text, x, y, size, cc)
  local fs = newText(parent, FONT.body, size or 12, cc or TEXT, "LEFT")
  fs:SetPoint("TOPLEFT", x, y); fs:SetText(text)
  return fs
end

local function sectionHead(parent, text, y)
  local fs = newText(parent, FONT.head, 13, COLOR.purple, "LEFT")
  fs:SetPoint("TOPLEFT", PAD, y); fs:SetText(text:upper())
  local div = hLine(parent)
  div:SetPoint("TOPLEFT", PAD, y - 18); div:SetPoint("TOPRIGHT", -PAD, y - 18)
  return fs
end

-- A number row: UI.sliderRow for dragging plus a typed box in the row's
-- top-right corner (the family answer is both). `fmt` returns "" on purpose:
-- sliderRow parks its read-only value text exactly where the box goes.
-- `apply(v)` receives an integer already clamped to [minV, maxV].
local function numRow(parent, yTop, labelText, minV, maxV, get, apply, sub)
  local h = {}

  local ebox = flatEditBox(parent, 56, 18)
  ebox:SetPoint("TOPRIGHT", -18, yTop + 3)
  ebox:SetMaxLetters(6)
  ebox:SetJustifyH("CENTER")
  h.box = ebox

  local row = sliderRow(parent, yTop, labelText, minV, maxV, 1, get,
    function(v)
      v = math.floor(v + 0.5)
      apply(v)
      ebox:SetText(tostring(v))
    end,
    function() return "" end,
    sub)

  function h:refresh()
    row:refresh()
    ebox:SetText(tostring(math.floor((get() or minV) + 0.5)))
  end

  local function commit(self)
    local v = tonumber(self:GetText())
    if v then apply(math.max(minV, math.min(maxV, math.floor(v + 0.5)))) end
    h:refresh()
  end
  ebox:SetScript("OnEnterPressed", function(self) self:ClearFocus(); commit(self) end)
  ebox:HookScript("OnEditFocusLost", commit)
  ebox:SetScript("OnEscapePressed", function(self) h:refresh(); self:ClearFocus() end)

  return h
end

-- A caret-art arrow button (the bundled faces have no ▲▼◄► glyphs).
local ROT = { right = 0, down = UI.CARET_DOWN, left = math.pi, up = math.pi / 2 }
local function caretButton(parent, w, h, dir, x, y)
  local b = flatButton(parent, w, h, COLOR.heroic, "", 11)
  b:SetBase(0.2); b:SetPoint("TOPLEFT", x, y)
  local t = b:CreateTexture(nil, "ARTWORK")
  t:SetTexture(UI.CARET)
  t:SetVertexColor(COLOR.orange.r, COLOR.orange.g, COLOR.orange.b)
  t:SetSize(8, 8); t:SetPoint("CENTER"); t:SetRotation(ROT[dir])
  return b
end

-- A row of mutually-exclusive choices: flatButtons, the selected one ORANGE.
-- `choices` = { { value, text, tip? }, … }; wraps after `perRow` if given.
local function choiceRow(parent, choices, bw, bh, x, y, gap, onPick, perRow)
  local btns = {}
  for i, c in ipairs(choices) do
    local value, text = c[1], c[2] or c[1]
    local col = perRow and ((i - 1) % perRow) or (i - 1)
    local rowN = perRow and math.floor((i - 1) / perRow) or 0
    local b = flatButton(parent, bw, bh, COLOR.heroic, text, 11)
    b:SetBase(0.2)
    b:SetPoint("TOPLEFT", x + col * (bw + (gap or 4)), y - rowN * (bh + 4))
    b:SetScript("OnClick", function()
      onPick(value)
      for _, e in ipairs(btns) do e.b:SetActive(e.v == value) end
    end)
    if c[3] then attachTip(b, text, c[3]) end
    btns[#btns + 1] = { b = b, v = value }
  end
  return {
    sync = function(value)
      for _, e in ipairs(btns) do e.b:SetActive(e.v == value) end
    end,
  }
end

-- --------------------------------------------------------------------------
-- LEFT RAIL — mark, the two portraits, reset
-- --------------------------------------------------------------------------
local function BuildRail(c)
  rail = CreateFrame("Frame", nil, c)
  rail:SetPoint("TOPLEFT", 0, 0)
  rail:SetPoint("BOTTOMLEFT", 0, 0)
  rail:SetWidth(RAIL_W)

  local X, W = 14, RAIL_W - 28

  -- The Gp mark + wordmark — the shared UI.tabHeader (LibGloomSkin MINOR 4).
  UI.tabHeader(rail, {
    texture = "Interface\\AddOns\\GloomsPortraits\\Media\\ui\\logo.png",
    label   = "GLOOM'S PORTRAITS",
    x       = X,
  })

  local oh = newText(rail, FONT.head, 12, MUTE, "LEFT")
  oh:SetPoint("TOPLEFT", X, -62); oh:SetText("PORTRAITS")

  -- The list is exactly two rows and always will be: the game has one player
  -- and one target. Each row names the unit and, in mute, its mode + when it
  -- shows, so the rail answers "what is each one doing" without a click.
  for i, which in ipairs(GP.UNITS) do
    local row = CreateFrame("Button", nil, rail)
    row:SetSize(W, LIST_ROW_H)
    row:SetPoint("TOPLEFT", X, -80 - (i - 1) * LIST_ROW_H)

    row.sel = row:CreateTexture(nil, "BACKGROUND"); row.sel:SetAllPoints()
    row.sel:SetColorTexture(COLOR.purple.r, COLOR.purple.g, COLOR.purple.b, 0.28); row.sel:Hide()
    local hl = row:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.07)

    row.text = newText(row, FONT.body, 12, TEXT, "LEFT")
    row.text:SetPoint("LEFT", 8, 0)
    row.text:SetText(UNIT_LABEL[which])

    row.sub = newText(row, FONT.body, 10.5, MUTE, "RIGHT")
    row.sub:SetPoint("RIGHT", -8, 0)

    row:SetScript("OnClick", function() SelectUnit(which) end)
    rows[which] = row
  end

  local hint = newText(rail, FONT.body, 10.5, MUTE, "LEFT")
  hint:SetPoint("TOPLEFT", X, -80 - 2 * LIST_ROW_H - 10)
  hint:SetPoint("TOPRIGHT", -X, -80 - 2 * LIST_ROW_H - 10)
  hint:SetJustifyH("LEFT")
  hint:SetText("While this tab is open, the selected portrait can be dragged on screen. "
    .. "The green outline shows where it sits — the model itself may be smaller than its frame.")

  -- Reset acts on the SELECTED portrait and asks first (every destructive
  -- action goes through UI.confirm — CONTRACTS §4).
  E.resetBtn = flatButton(rail, W, 22, COLOR.heroic, "Reset to defaults", 11)
  E.resetBtn:SetBase(0.2); E.resetBtn:SetPoint("BOTTOMLEFT", X, 6)
  E.resetBtn:SetScript("OnClick", function()
    local which = selected
    if not which then return end
    UI.confirm(("Reset the %s portrait to its factory position, size and settings?")
      :format(UNIT_LABEL[which]:lower()), function()
      GP:Reset(which)
      RefreshEditor()
      RefreshList()
    end)
  end)
  attachTip(E.resetBtn, "Reset to defaults",
    "Puts the selected portrait back where a fresh install would have it. Asks you to confirm first.")
end

RefreshList = function()
  for _, which in ipairs(GP.UNITS) do
    local row, cfg = rows[which], GP:Config(which)
    if row then
      row.sel:SetShown(which == selected)
      if cfg then
        row.sub:SetText((MODE_LABEL[cfg.mode] or "3D") .. " · " .. (COND_LABEL[cfg.showCondition] or "Always"))
      else
        row.sub:SetText("")
      end
    end
  end
  if E.resetBtn then E.resetBtn:SetEnabled(selected ~= nil) end
end

-- --------------------------------------------------------------------------
-- RIGHT PANE — the selected portrait's settings
-- --------------------------------------------------------------------------
local function BuildEditor(p)
  -- ── Display mode ──────────────────────────────────────────
  sectionHead(p, "Display mode", -14)
  E.mode = choiceRow(p, {
    { "3d", "3D model",    "A full-body model that turns, zooms and tilts." },
    { "2d", "2D portrait", "The unit's flat portrait. It renders as a circle — a WoW engine limit." },
  }, 120, 22, PAD, -42, 6, function(v)
    if not selected then return end
    GP:SetMode(selected, v)
    GP:SetEditing(selected)   -- the outline moves to the mode's own layout
    RefreshEditor()
    RefreshList()
  end)
  -- The one thing a 3D target cannot do, said where the choice is made.
  E.modeNote = label(p, "In dungeons, raids and delves the game won't identify an enemy targeted mid-combat. "
    .. "Mobs you targeted before the pull stay 3D; anything else shows the 2D portrait, using the size, position and layer you set in 2D mode.", PAD, -70, 10.5, MUTE)

  -- ── Size & position ───────────────────────────────────────
  -- TWO COLUMNS: SIZE on the left, POSITION on the right with the nudge
  -- arrows under it. Frames rather than x offsets because UI.sliderRow spans
  -- its PARENT (18px insets); they start at PAD-18 = 0 so the lib's inset
  -- lands their labels on the same gutter as every other row.
  sectionHead(p, "Size & position", -84)

  local COL_TOP, COL_GAP = -112, 8
  local sizeCol = CreateFrame("Frame", nil, p)
  sizeCol:SetPoint("TOPLEFT", PAD - 18, COL_TOP)
  sizeCol:SetPoint("TOPRIGHT", p, "TOP", -COL_GAP / 2, COL_TOP)
  sizeCol:SetHeight(130)

  local posCol = CreateFrame("Frame", nil, p)
  posCol:SetPoint("TOPLEFT", p, "TOP", COL_GAP / 2, COL_TOP)
  posCol:SetPoint("TOPRIGHT", -(PAD - 18), COL_TOP)
  posCol:SetHeight(130)

  local function num(field, default)
    return function() local cfg = Cfg(); return cfg and cfg[field] or default end
  end
  local function setLayout(field)
    return function(v)
      local cfg = Cfg()
      if not cfg then return end
      cfg[field] = v
      GP:ApplyLayout(selected)
      if field == "size" then GP:SetEditing(selected) end   -- the outline tracks size too
    end
  end

  -- Ranges are the old panel's (50–700 for size) and the safe screen extent
  -- for position (the coordinate note at the top of the engine file).
  E.sizeRow = numRow(sizeCol, -2, "Size", 50, 700, num("size", 350), setLayout("size"), "px — square")
  E.xRow = numRow(posCol,  -2, "X", -700, 700, num("x", 0), setLayout("x"))
  E.yRow = numRow(posCol, -48, "Y", -400, 400, num("y", 0), setLayout("y"))

  -- Nudge: an increment plus four caret arrows, under the POSITION rows.
  label(posCol, "Nudge", 18, -96)
  E.nudgeBox = flatEditBox(posCol, 40, 22)
  E.nudgeBox:SetPoint("TOPLEFT", 66, -98)
  E.nudgeBox:SetText("5"); E.nudgeBox:SetMaxLetters(5)
  E.nudgeBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  E.nudgeBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  label(posCol, "px", 112, -96, 10.5, MUTE)

  local function nudge(dx, dy)
    if not selected then return end
    local step = tonumber(E.nudgeBox:GetText()) or 1
    GP:Nudge(selected, dx * step, dy * step)
    GP:SetEditing(selected)
    E.xRow:refresh(); E.yRow:refresh()
  end
  caretButton(posCol, 26, 22, "up",    136, -98):SetScript("OnClick", function() nudge( 0,  1) end)
  caretButton(posCol, 26, 22, "down",  166, -98):SetScript("OnClick", function() nudge( 0, -1) end)
  caretButton(posCol, 26, 22, "left",  196, -98):SetScript("OnClick", function() nudge(-1,  0) end)
  caretButton(posCol, 26, 22, "right", 226, -98):SetScript("OnClick", function() nudge( 1,  0) end)

  -- ── 3D camera (only in 3D mode) ───────────────────────────
  -- Its own frame so the sections below can close the gap when it hides.
  local CAM_TOP = -252
  E.camSec = CreateFrame("Frame", nil, p)
  E.camSec:SetPoint("TOPLEFT", 0, CAM_TOP); E.camSec:SetPoint("TOPRIGHT", 0, CAM_TOP)
  E.camSec:SetHeight(210)
  sectionHead(E.camSec, "Camera", 0)

  local function cam(key, default)
    return function() local cfg = Cfg(); return cfg and cfg[key] or default end
  end
  local function setCam(key)
    return function(v) if selected then GP:SetCamera(selected, key, v) end end
  end

  -- Facing is STORED in radians (0–2π); shown and dragged in degrees.
  E.facingRow = sliderRow(E.camSec, -28, "Facing", 0, 360, 1,
    function() return math.deg(cam("facing", 0)()) end,
    function(v) setCam("facing")(math.rad(math.floor(v + 0.5))) end,
    function(v) return string.format("%d°", math.floor(v + 0.5)) end)
  E.zoomRow = sliderRow(E.camSec, -72, "Zoom", 0.5, 5, 0.05,
    cam("zoom", 2.5), setCam("zoom"),
    function(v) return string.format("%.2f", v) end,
    "lower is closer")
  E.offsetRow = numRow(E.camSec, -131, "Vertical offset", -400, 400,
    cam("modelYOffset", 0), setCam("modelYOffset"))
  E.pitchRow = sliderRow(E.camSec, -175, "Pitch", -1.5, 1.5, 0.02,
    cam("pitch", 0), setCam("pitch"),
    function(v) return string.format("%.2f", v) end)

  -- ── Layer + Visibility ────────────────────────────────────
  -- Anchored under the camera section in 3D, straight under Size in 2D.
  E.lowerSec = CreateFrame("Frame", nil, p)
  E.lowerSec:SetHeight(180)

  sectionHead(E.lowerSec, "Layer", 0)
  E.strata = choiceRow(E.lowerSec, {
    { "BACKGROUND", "BACKGROUND", "Below everything, including the game's own frames." },
    { "LOW",        "LOW",        "Below most UI frames." },
    { "MEDIUM",     "MEDIUM",     "The default — level with most of the UI." },
    { "HIGH",       "HIGH",       "Above most of the UI." },
    { "DIALOG",     "DIALOG",     "Above almost everything." },
  }, 88, 20, PAD, -28, 4, function(v)
    if selected then GP:SetStrata(selected, v) end
  end)
  label(E.lowerSec, "Where the portrait sits in the UI stack — behind or in front of other frames.",
    PAD, -56, 10.5, MUTE)

  sectionHead(E.lowerSec, "Visibility", -84)
  E.cond = choiceRow(E.lowerSec, {
    { "always",           "Always",           "Always shown (a target portrait still needs a target)." },
    { "combat",           "In combat",        "Only while you are in combat." },
    { "target",           "Target selected",  "Only while you have a target." },
    { "combat_or_target", "Combat or target", "While in combat OR while you have a target." },
    { "never",            "Off",              "Never shown. The settings are kept." },
  }, 100, 20, PAD, -112, 6, function(v)
    if selected then GP:SetCondition(selected, v) end
    RefreshList()
  end)
end

-- Re-anchor the lower sections to the current mode and size the scroll child.
local function Relayout()
  local cfg = Cfg()
  local is3d = not cfg or (cfg.mode or "3d") == "3d"
  E.camSec:SetShown(is3d)
  E.lowerSec:ClearAllPoints()
  local top = is3d and -480 or -252
  E.lowerSec:SetPoint("TOPLEFT", 0, top); E.lowerSec:SetPoint("TOPRIGHT", 0, top)
  editorChild:SetHeight(is3d and CONTENT_H or (CONTENT_H - 228))
end

-- Populate every control from the selected unit.
RefreshEditor = function()
  local cfg = Cfg()
  if not cfg then
    if editorBody then editorBody:Hide() end
    if E.editorBar then E.editorBar:Hide() end
    if emptyNote then emptyNote:Show() end
    return
  end
  if emptyNote then emptyNote:Hide() end
  editorBody:Show()
  E.editorBar:Show()

  E.mode.sync(cfg.mode or "3d")
  E.modeNote:SetShown(selected == "target" and (cfg.mode or "3d") == "3d")
  E.sizeRow:refresh()
  E.xRow:refresh(); E.yRow:refresh()
  E.facingRow:refresh(); E.zoomRow:refresh(); E.offsetRow:refresh(); E.pitchRow:refresh()
  E.strata.sync(cfg.strata or "MEDIUM")
  E.cond.sync(cfg.showCondition or "always")
  Relayout()
end

SelectUnit = function(which)
  selected = which
  if container and container:IsVisible() then GP:SetEditing(which) end
  RefreshEditor()
  RefreshList()
  if editorScroll then editorScroll:SetVerticalScroll(0) end
end

-- --------------------------------------------------------------------------
-- The tab
-- --------------------------------------------------------------------------
local function BuildTab(c)
  container = c

  BuildRail(c)

  local vdiv = c:CreateTexture(nil, "ARTWORK")
  vdiv:SetColorTexture(COLOR.rim.r, COLOR.rim.g, COLOR.rim.b, COLOR.rim.a or 0.1)
  vdiv:SetWidth(1)
  vdiv:SetPoint("TOPLEFT", RAIL_W, 0); vdiv:SetPoint("BOTTOMLEFT", RAIL_W, 0)

  editorScroll = CreateFrame("ScrollFrame", nil, c)
  editorScroll:SetPoint("TOPLEFT", RAIL_W + 1, -1)
  editorScroll:SetPoint("BOTTOMRIGHT", -10, 1)
  editorScroll:EnableMouseWheel(true)
  editorScroll:SetScript("OnMouseWheel", function(self, delta)
    local range = self:GetVerticalScrollRange()
    self:SetVerticalScroll(math.max(0, math.min(range, self:GetVerticalScroll() - delta * 42)))
  end)
  editorChild = CreateFrame("Frame", nil, editorScroll)
  editorChild:SetSize(math.max(10, editorScroll:GetWidth()), CONTENT_H)
  editorScroll:SetScrollChild(editorChild)
  editorScroll:SetScript("OnSizeChanged", function(_, w)
    if w and w > 0 then editorChild:SetWidth(w) end
  end)
  E.editorBar = makeScrollbar(c, editorScroll, function(b)
    b:SetPoint("TOPRIGHT", -4, -2); b:SetPoint("BOTTOMRIGHT", -4, 2)
  end)

  editorBody = CreateFrame("Frame", nil, editorChild)
  editorBody:SetAllPoints()
  BuildEditor(editorBody)
  editorBody:Hide()

  emptyNote = newText(c, FONT.body, 12, MUTE, "CENTER")
  emptyNote:SetPoint("CENTER", editorScroll, "CENTER", 0, 0)
  emptyNote:SetText("Select Player or Target on the left to edit that portrait.")

  -- OnShow/OnHide live on the CONTAINER: they fire as the tab gains/loses
  -- visibility — window open/close AND tab switches (CONTRACTS §2). Showing
  -- unlocks dragging for the selected portrait; hiding locks everything, so
  -- closing the window can never leave a portrait draggable.
  c:HookScript("OnShow", function()
    if selected then GP:SetEditing(selected) end
    RefreshEditor()
    RefreshList()
  end)
  c:HookScript("OnHide", function()
    GP:SetEditing(nil)
  end)

  -- A drag on screen moves the portrait; keep the X/Y rows honest.
  GP:OnChange(function(what, which)
    if which ~= selected then return end
    if what == "position" and E.xRow then E.xRow:refresh(); E.yRow:refresh() end
  end)

  SelectUnit("player")
end

-- --------------------------------------------------------------------------
-- Mount the PORTRAITS tab (CONTRACTS §2; order 40 — after Overlays, before
-- Media). Registration is immediate; BuildTab runs ONCE, lazily, on first show.
-- --------------------------------------------------------------------------
GloomsHub:RegisterTab{
  id    = "portraits",
  title = "PORTRAITS",
  order = 40,
  build = BuildTab,
}
