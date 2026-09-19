-- GloomsPortraits.lua — Gloom's Portraits, the suite's fifth tool.
-- Free-floating 3D full-body models OR 2D circular portraits for player and target.
-- /gp (or /portraits, /sm) toggles the control panel.
--
-- STAGE 1 (2026-09-19): a suite member with NO visual change — same frames, same
-- panel, same behaviour as the single-file addon it grew from, plus a one-time copy
-- of that addon's saved settings. Stage 2 replaces the panel with a Portraits tab in
-- the Suite window on LibGloomSkin; see docs/BACKLOG.md item 11 in ~/GloomsHub.
--
-- COORDINATE SYSTEM NOTE:
-- WoW's UI coordinate space is always 768 units tall regardless of resolution.
-- For 16:9, width is ~1365 units. Screen center is 0,0.
-- Safe X range ~-600 to +600, Y range ~-350 to +350.

------------------------------------------------------------------------
-- Defaults
------------------------------------------------------------------------
local DEFAULTS = {
    player = {
        x             = -300,
        y             = -150,
        size          = 350,
        facing        = 0,
        zoom          = 2.5,
        strata        = "MEDIUM",
        modelYOffset  = 0,
        pitch         = 0,
        showCondition = "always",  -- "always"|"combat"|"target"|"combat_or_target"
        mode          = "3d",      -- "3d"|"2d"
    },
    target = {
        x             = 300,
        y             = -150,
        size          = 350,
        facing        = math.pi,
        zoom          = 2.5,
        strata        = "MEDIUM",
        modelYOffset  = 0,
        pitch         = 0,
        showCondition = "always",
        mode          = "3d",
    },
}

------------------------------------------------------------------------
-- State
------------------------------------------------------------------------
local db          = nil
local initialised = false
local isUnlocked  = false
local models      = {}   -- PlayerModel frames (3D)
local portraits   = {}   -- portrait container frames (2D)
local anchors     = {}   -- invisible draggable anchor frames
local panels      = {}
local ghosts      = {}   -- green outlines shown during drag / panel open
local refreshUI   = {}   -- per-unit fn to re-sync panel controls to db

------------------------------------------------------------------------
-- Forward declarations
------------------------------------------------------------------------
local UpdateVisibility
local SetLocked

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------
local function ApplyDefaults(tbl, defaults)
    for k, v in pairs(defaults) do
        if tbl[k] == nil then
            tbl[k] = (type(v) == "table") and {} or v
            if type(v) == "table" then ApplyDefaults(tbl[k], v) end
        end
    end
end

local function SavePosition(which)
    local anchor = anchors[which]
    local cx, cy = anchor:GetCenter()
    local sw, sh = UIParent:GetWidth(), UIParent:GetHeight()
    if cx and cy then
        db[which].x = cx - sw / 2
        db[which].y = cy - sh / 2
    end
end

------------------------------------------------------------------------
-- Sync visual frames to anchor position/size
------------------------------------------------------------------------
local function SyncToAnchor(which)
    local anchor = anchors[which]
    local cfg    = db[which]
    local cx, cy = anchor:GetCenter()
    local sw, sh = UIParent:GetWidth(), UIParent:GetHeight()
    local ox = cx and (cx - sw / 2) or cfg.x
    local oy = cy and (cy - sh / 2) or cfg.y

    local model = models[which]
    if model then
        model:ClearAllPoints()
        model:SetSize(cfg.size, cfg.size)
        model:SetPoint("CENTER", UIParent, "CENTER", ox, oy)
    end

    local portFrame = portraits[which]
    if portFrame then
        portFrame:ClearAllPoints()
        portFrame:SetSize(cfg.size, cfg.size)
        portFrame:SetPoint("CENTER", UIParent, "CENTER", ox, oy)
    end

    local g = ghosts[which]
    if g and g:IsShown() then
        g:SetSize(cfg.size, cfg.size)
        g:ClearAllPoints()
        g:SetPoint("CENTER", UIParent, "CENTER", cfg.x, cfg.y)
    end
end

------------------------------------------------------------------------
-- SetupModel: load unit into 3D PlayerModel
------------------------------------------------------------------------
-- Can a 3D model be shown for this unit at all?
--
-- ⚠ MEASURED IN A DELVE, 2026-09-05: UnitGUID("target") on a HOSTILE npc inside
-- instanced content returns a SECRET value. Model:SetUnit has to resolve the unit
-- to look up its display info, and with the identity withheld it does nothing at
-- all -- it does not clear, it does not error, it just leaves whatever model was
-- there before. That is why targeting a delve mob used to leave your own (or a
-- party member's) model sitting on screen, looking like a working feature showing
-- the wrong unit.
--
-- Only ENEMY identity is secret, which is why friendly and party units keep
-- working in the same delve, and why the open world is fine.
--
-- There is NO addon-side workaround -- this is a deliberate Blizzard restriction,
-- not something to be clever about. The only honest response is to show nothing.
local function CanShowUnit(unit)
    if not UnitExists(unit) then return false end
    -- issecretvalue is the only safe question to ask: never compare or concatenate
    -- a possibly-secret value first.
    if issecretvalue and issecretvalue(UnitGUID(unit)) then return false end
    return true
end

local function SetupModel(which)
    local model = models[which]
    if not model then return end
    local cfg  = db[which]
    local unit = (which == "player") and "player" or "target"
    if not CanShowUnit(unit) then
        -- Empty beats WRONG. A stale model is indistinguishable from a correct one.
        if model.ClearModel then model:ClearModel() end
        return
    end
    model:SetUnit(unit)
    model:SetFacing(cfg.facing)
    model:SetPortraitZoom(0)
    model:SetCamDistanceScale(cfg.zoom)
    model:SetAnimation(0)
    model:SetViewTranslation(0, cfg.modelYOffset or 0)
    model:SetPitch(cfg.pitch or 0)
    SyncToAnchor(which)
end

------------------------------------------------------------------------
-- SetupPortrait: populate 2D portrait texture.
-- SetPortraitTexture always renders as a circle — this is WoW engine
-- behaviour and cannot be overridden without unreliable mask hacks.
------------------------------------------------------------------------
local function SetupPortrait(which)
    local portFrame = portraits[which]
    if not portFrame then return end
    local unit = (which == "player") and "player" or "target"
    -- ⚠ DELIBERATELY NOT GATED like the 3D path. Patch 12.1 restricted
    -- Model:SetUnit and ModelSceneActor:SetModelByUnit by name; SetPortraitTexture
    -- is NOT on that list. It may well still work on a secret-identity unit, since
    -- it renders engine-side and hands the addon no identifying data back. Gating
    -- it here would throw away the one path that might survive in an instance.
    -- If it turns out to be blocked too, it fails to a blank texture anyway.
    SetPortraitTexture(portFrame.tex, unit)
    SyncToAnchor(which)
end

------------------------------------------------------------------------
-- ApplyMode: switch between 3D and 2D for a unit
------------------------------------------------------------------------
local function ApplyMode(which)
    local cfg   = db[which]
    local model = models[which]
    local portF = portraits[which]
    if not model or not portF then return end

    if cfg.mode == "3d" then
        portF:Hide()
        if initialised then SetupModel(which) end
    else
        model:Hide()
        if initialised then SetupPortrait(which) end
    end
    SyncToAnchor(which)
end

------------------------------------------------------------------------
local function ApplyStrata(which)
    local s = db[which].strata or "MEDIUM"
    models[which]:SetFrameStrata(s)
    portraits[which]:SetFrameStrata(s)
    anchors[which]:SetFrameStrata(s)
    ghosts[which]:SetFrameStrata(s)
end

local function ApplySettings(which)
    local anchor = anchors[which]
    local cfg    = db[which]
    anchor:SetSize(cfg.size, cfg.size)
    anchor:ClearAllPoints()
    anchor:SetPoint("CENTER", UIParent, "CENTER", cfg.x, cfg.y)
    SyncToAnchor(which)
    ApplyStrata(which)
    ApplyMode(which)
end

------------------------------------------------------------------------
-- Ghost outline frames
------------------------------------------------------------------------
local function CreateGhostFrame(which)
    local g = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    g:SetFrameStrata("HIGH")
    g:SetBackdrop({
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        edgeSize = 12,
        insets   = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    g:SetBackdropBorderColor(0, 1, 0, 0.9)
    g:Hide()
    ghosts[which] = g
end

------------------------------------------------------------------------
local function MoveModel(which, dx, dy)
    local cfg = db[which]
    cfg.x = cfg.x + dx
    cfg.y = cfg.y + dy
    ApplySettings(which)
end

------------------------------------------------------------------------
-- Create anchor + 3D model + 2D portrait frame for a unit
------------------------------------------------------------------------
local function CreateUnitFrames(which)
    local cfg = db[which]

    local anchor = CreateFrame("Frame", "GloomsPortraits_Anchor_" .. which, UIParent)
    anchor:SetFrameStrata("MEDIUM")
    anchor:SetSize(cfg.size, cfg.size)
    anchor:SetPoint("CENTER", UIParent, "CENTER", cfg.x, cfg.y)
    anchor:SetMovable(true)
    anchor:SetUserPlaced(true)
    anchor:EnableMouse(false)
    anchor:RegisterForDrag("LeftButton")
    anchor:SetScript("OnDragStart", function(self)
        if not isUnlocked then return end
        self._dragging = true
        local g = ghosts[which]
        g:SetSize(db[which].size, db[which].size)
        g:ClearAllPoints()
        g:SetPoint("CENTER", self, "CENTER")
        g:Show()
        self:StartMoving()
        self:SetScript("OnUpdate", function(s)
            g:ClearAllPoints()
            g:SetPoint("CENTER", s, "CENTER")
        end)
    end)
    anchor:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
        self:StopMovingOrSizing()
        self:SetUserPlaced(true)
        self._dragging = false
        if not panels.unified or not panels.unified:IsShown() then
            ghosts[which]:Hide()
        end
        SavePosition(which)
        SyncToAnchor(which)
    end)
    anchors[which] = anchor

    -- 3D PlayerModel
    local model = CreateFrame("PlayerModel", "GloomsPortraits_Model_" .. which, UIParent)
    model:SetFrameStrata("MEDIUM")
    model:SetSize(cfg.size, cfg.size)
    model:SetPoint("CENTER", UIParent, "CENTER", cfg.x, cfg.y)
    model:EnableMouse(false)
    models[which] = model

    -- 2D portrait container + texture
    local portFrame = CreateFrame("Frame", "GloomsPortraits_Portrait_" .. which, UIParent)
    portFrame:SetFrameStrata("MEDIUM")
    portFrame:SetSize(cfg.size, cfg.size)
    portFrame:SetPoint("CENTER", UIParent, "CENTER", cfg.x, cfg.y)
    portFrame:EnableMouse(false)
    local tex = portFrame:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints(portFrame)
    portFrame.tex = tex
    portraits[which] = portFrame
end

------------------------------------------------------------------------
-- Slider helper
------------------------------------------------------------------------
local sliderCount = 0
local function MakeSlider(parent, label, minVal, maxVal, step, getValue, setValue, yOffset)
    sliderCount = sliderCount + 1

    local lbl = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lbl:SetPoint("TOPLEFT", parent, "TOPLEFT", 12, yOffset)
    lbl:SetText(label)

    local sName  = "GloomsPortraitsSlider" .. sliderCount
    local slider = CreateFrame("Slider", sName, parent, "OptionsSliderTemplate")
    slider:SetPoint("TOPLEFT", parent, "TOPLEFT", 12, yOffset - 17)
    slider:SetWidth(200)
    slider:SetMinMaxValues(minVal, maxVal)
    slider:SetValueStep(step)
    slider:SetObeyStepOnDrag(true)
    slider:SetValue(getValue())

    _G[sName .. "Low"]:SetText(tostring(minVal))
    _G[sName .. "High"]:SetText(tostring(maxVal))
    _G[sName .. "Text"]:SetText("")

    local readout = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    readout:SetPoint("LEFT", slider, "RIGHT", 6, 0)

    local function Refresh() readout:SetText(string.format("%.2f", slider:GetValue())) end
    Refresh()

    slider:SetScript("OnValueChanged", function(self, value)
        setValue(value)
        Refresh()
    end)

    return slider
end

------------------------------------------------------------------------
-- Nudge pad
------------------------------------------------------------------------
local nudgeStep = 5

local function MakeNudgePad(parent, which, yOffset)
    local lbl = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lbl:SetPoint("TOPLEFT", parent, "TOPLEFT", 12, yOffset)
    lbl:SetText("Position")

    local btnSize = 22
    local padX    = 12
    local padY    = yOffset - 16

    local function MakeArrow(symbol, dx, dy, offX, offY)
        local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        btn:SetSize(btnSize, btnSize)
        btn:SetText(symbol)
        btn:SetPoint("TOPLEFT", parent, "TOPLEFT", padX + offX, padY + offY)
        btn:SetScript("OnClick", function() MoveModel(which, dx * nudgeStep, dy * nudgeStep) end)
        btn:SetScript("OnMouseDown", function(self) self._held = true; self._timer = 0 end)
        btn:SetScript("OnMouseUp",   function(self) self._held = false end)
        btn:SetScript("OnUpdate", function(self, elapsed)
            if self._held then
                self._timer = (self._timer or 0) + elapsed
                if self._timer > 0.3 then
                    self._timer = self._timer - 0.08
                    MoveModel(which, dx * nudgeStep, dy * nudgeStep)
                end
            end
        end)
        return btn
    end

    MakeArrow("^",  0,  1, btnSize,      0)
    MakeArrow("v",  0, -1, btnSize,     -btnSize * 2)
    MakeArrow("<", -1,  0, 0,           -btnSize)
    MakeArrow(">",  1,  0, btnSize * 2, -btnSize)

    local stepLbl = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    stepLbl:SetPoint("TOPLEFT", parent, "TOPLEFT", padX + btnSize * 3 + 8, padY)
    stepLbl:SetText("Step:")

    local steps    = { 1, 5, 10, 25 }
    local stepBtns = {}
    for i, s in ipairs(steps) do
        local sb = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        sb:SetSize(26, 18)
        sb:SetText(tostring(s))
        sb:SetPoint("TOPLEFT", parent, "TOPLEFT",
            padX + btnSize * 3 + 6, padY - 18 * (i - 1) - 16)
        sb:SetScript("OnClick", function()
            nudgeStep = s
            for _, b in ipairs(stepBtns) do b:SetAlpha(0.5) end
            sb:SetAlpha(1.0)
        end)
        sb:SetAlpha(s == nudgeStep and 1.0 or 0.5)
        stepBtns[i] = sb
    end
end

------------------------------------------------------------------------
-- Lock / Unlock
------------------------------------------------------------------------
SetLocked = function(locked)
    isUnlocked = not locked
    for _, which in ipairs({ "player", "target" }) do
        local anchor = anchors[which]
        if not anchor then return end
        anchor:EnableMouse(not locked)
    end
    if locked and panels.unified then
        panels.unified:Hide()
    end
end

------------------------------------------------------------------------
-- BuildControls: populate one tab's content frame
--
-- Layout (y from tab content top):
--   -6    "Display Mode" label
--   -20   [3D Model] [2D Portrait] toggle buttons
--   -48   Size slider                          (always visible)
--   -106  Mode-specific block, fixed 232px:
--           3D: Facing / Zoom / Vert.Offset / Pitch  (4 x 58)
--           2D: note label (portrait is always circular)
--   -338  Position nudge pad
--   -438  Layer buttons
--   -478  Show When buttons
------------------------------------------------------------------------
local function BuildControls(f, which)
    local y = -6

    local modeLbl = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    modeLbl:SetPoint("TOPLEFT", f, "TOPLEFT", 12, y)
    modeLbl:SetText("Display Mode")
    y = y - 20

    local btn3D = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btn3D:SetSize(110, 22)
    btn3D:SetText("3D Model")
    btn3D:SetPoint("TOPLEFT", f, "TOPLEFT", 12, y)

    local btn2D = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btn2D:SetSize(110, 22)
    btn2D:SetText("2D Portrait")
    btn2D:SetPoint("TOPLEFT", f, "TOPLEFT", 130, y)
    y = y - 28

    MakeSlider(f, "Size (px)", 50, 700, 5,
        function() return db[which].size end,
        function(v)
            db[which].size = v
            anchors[which]:SetSize(v, v)
            SyncToAnchor(which)
        end, y)
    y = y - 58

    local modeBlockTop = y
    local modeBlockH   = 58 * 4  -- 232px, same for both sub-frames

    -- 3D sub-frame
    local c3 = CreateFrame("Frame", nil, f)
    c3:SetPoint("TOPLEFT", f, "TOPLEFT", 0, modeBlockTop)
    c3:SetSize(270, modeBlockH)
    do
        local ly = -6
        MakeSlider(c3, "Facing (0 - 6.28)", 0, 6.28, 0.05,
            function() return db[which].facing end,
            function(v) db[which].facing = v; if models[which] then models[which]:SetFacing(v) end end,
            ly)
        ly = ly - 58
        MakeSlider(c3, "Zoom (1=close, 5=far)", 0.5, 5.0, 0.05,
            function() return db[which].zoom end,
            function(v)
                db[which].zoom = v
                if models[which] then
                    models[which]:SetPortraitZoom(0)
                    models[which]:SetCamDistanceScale(v)
                end
            end, ly)
        ly = ly - 58
        MakeSlider(c3, "Vertical Offset (-400 to +400)", -400, 400, 1,
            function() return db[which].modelYOffset or 0 end,
            function(v) db[which].modelYOffset = v; if models[which] then models[which]:SetViewTranslation(0, v) end end,
            ly)
        ly = ly - 58
        MakeSlider(c3, "Pitch (-1.5 to 1.5)", -1.5, 1.5, 0.02,
            function() return db[which].pitch or 0 end,
            function(v) db[which].pitch = v; if models[which] then models[which]:SetPitch(v) end end,
            ly)
    end

    -- 2D sub-frame (portrait has no extra configurable settings)
    local c2 = CreateFrame("Frame", nil, f)
    c2:SetPoint("TOPLEFT", f, "TOPLEFT", 0, modeBlockTop)
    c2:SetSize(270, modeBlockH)
    do
        local note = c2:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        note:SetPoint("TOPLEFT", c2, "TOPLEFT", 12, -14)
        note:SetTextColor(0.6, 0.6, 0.6, 1)
        note:SetText("Portrait renders as a circle.\n(WoW engine limitation)")
    end

    y = modeBlockTop - modeBlockH - 10

    MakeNudgePad(f, which, y)
    y = y - 100

    -- Layer
    local strataLbl = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    strataLbl:SetPoint("TOPLEFT", f, "TOPLEFT", 12, y)
    strataLbl:SetText("Layer")

    local strataList = { "BACKGROUND", "LOW", "MEDIUM", "HIGH", "DIALOG" }
    local strataDesc = { "Below everything", "Below UI frames", "Default", "Above most UI", "Above almost all" }
    local strataBtns = {}
    for i, s in ipairs(strataList) do
        local sb = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        sb:SetSize(46, 18)
        sb:SetText(s == "BACKGROUND" and "BG" or s == "MEDIUM" and "MED" or s == "DIALOG" and "DLG" or s)
        sb:SetPoint("TOPLEFT", f, "TOPLEFT", 12 + (i - 1) * 50, y - 18)
        sb:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:ClearLines()
            GameTooltip:AddLine(s, 1, 1, 1)
            GameTooltip:AddLine(strataDesc[i], 0.8, 0.8, 0.8)
            GameTooltip:Show()
        end)
        sb:SetScript("OnLeave", function() GameTooltip:Hide() end)
        sb:SetScript("OnClick", function()
            db[which].strata = s
            ApplyStrata(which)
            for _, b in ipairs(strataBtns) do b:SetAlpha(0.5) end
            sb:SetAlpha(1.0)
        end)
        sb:SetAlpha((db[which].strata or "MEDIUM") == s and 1.0 or 0.5)
        strataBtns[i] = sb
    end
    y = y - 40

    -- Show When
    local condLbl = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    condLbl:SetPoint("TOPLEFT", f, "TOPLEFT", 12, y)
    condLbl:SetText("Show When")

    local condList  = { "always", "combat", "target", "combat_or_target" }
    local condNames = { "Always", "Combat", "Target", "Either" }
    local condBtns  = {}
    for i, c in ipairs(condList) do
        local cb = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        cb:SetSize(56, 18)
        cb:SetText(condNames[i])
        cb:SetPoint("TOPLEFT", f, "TOPLEFT", 12 + (i - 1) * 60, y - 18)
        cb:SetScript("OnEnter", function(self)
            local tips = {
                "Always visible", "Only while in combat",
                "Only while you have a target", "While in combat OR have a target",
            }
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:ClearLines()
            GameTooltip:AddLine(tips[i], 0.9, 0.9, 0.9)
            GameTooltip:Show()
        end)
        cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
        cb:SetScript("OnClick", function()
            db[which].showCondition = c
            for _, b in ipairs(condBtns) do b:SetAlpha(0.5) end
            cb:SetAlpha(1.0)
            UpdateVisibility()
        end)
        cb:SetAlpha((db[which].showCondition or "always") == c and 1.0 or 0.5)
        condBtns[i] = cb
    end

    -- Mode toggle
    local function RefreshModeUI()
        local mode = db[which].mode or "3d"
        if mode == "3d" then
            c3:Show(); c2:Hide()
            btn3D:SetAlpha(1.0); btn2D:SetAlpha(0.5)
        else
            c3:Hide(); c2:Show()
            btn3D:SetAlpha(0.5); btn2D:SetAlpha(1.0)
        end
    end

    btn3D:SetScript("OnClick", function()
        db[which].mode = "3d"
        ApplyMode(which)
        UpdateVisibility()
        RefreshModeUI()
    end)

    btn2D:SetScript("OnClick", function()
        db[which].mode = "2d"
        ApplyMode(which)
        UpdateVisibility()
        RefreshModeUI()
    end)

    RefreshModeUI()
    refreshUI[which] = RefreshModeUI
end

------------------------------------------------------------------------
-- Control panel
------------------------------------------------------------------------
local function CreateControlPanel()
    local panelW = 290
    local panelH = 30 + 30 + 48 + 58 + 232 + 100 + 40 + 58 + 40

    local panel = CreateFrame("Frame", "GloomsPortraits_Panel", UIParent, "BackdropTemplate")
    panel:SetSize(panelW, panelH)
    panel:SetFrameStrata("HIGH")
    panel:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    panel:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop",  panel.StopMovingOrSizing)

    local titleBar = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    titleBar:SetPoint("TOP", panel, "TOP", 0, -8)
    titleBar:SetText("Gloom's Portraits")

    local tabPlayer = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    tabPlayer:SetSize(110, 22)
    tabPlayer:SetText("Player")
    tabPlayer:SetPoint("TOPLEFT", panel, "TOPLEFT", 14, -28)

    local tabTarget = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    tabTarget:SetSize(110, 22)
    tabTarget:SetText("Target")
    tabTarget:SetPoint("TOPLEFT", panel, "TOPLEFT", 140, -28)

    local function MakeTabContent()
        local f = CreateFrame("Frame", nil, panel)
        f:SetPoint("TOPLEFT",     panel, "TOPLEFT",     8,  -56)
        f:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -8,   8)
        f:Hide()
        return f
    end

    local playerContent = MakeTabContent()
    local targetContent = MakeTabContent()
    local activeTab = "player"

    local function ShowGhostForTab(which)
        for _, w in ipairs({ "player", "target" }) do
            local g   = ghosts[w]
            local cfg = db[w]
            if w == which then
                g:SetSize(cfg.size, cfg.size)
                g:ClearAllPoints()
                g:SetPoint("CENTER", UIParent, "CENTER", cfg.x, cfg.y)
                g:Show()
            else
                g:Hide()
            end
        end
    end

    local function ShowTab(which)
        activeTab = which
        if which == "player" then
            playerContent:Show(); targetContent:Hide()
            tabPlayer:SetAlpha(1.0); tabTarget:SetAlpha(0.6)
        else
            playerContent:Hide(); targetContent:Show()
            tabPlayer:SetAlpha(0.6); tabTarget:SetAlpha(1.0)
        end
        if refreshUI[which] then refreshUI[which]() end
        if panel:IsShown() then ShowGhostForTab(which) end
    end

    tabPlayer:SetScript("OnClick", function() ShowTab("player") end)
    tabTarget:SetScript("OnClick", function() ShowTab("target") end)

    BuildControls(playerContent, "player")
    BuildControls(targetContent, "target")

    ShowTab("player")

    panel:SetScript("OnShow", function()
        SetLocked(false)
        ShowGhostForTab(activeTab)
    end)
    panel:SetScript("OnHide", function()
        SetLocked(true)
        for _, which in ipairs({ "player", "target" }) do
            if not anchors[which]._dragging then ghosts[which]:Hide() end
        end
    end)

    panel:Hide()
    panels.unified = panel
    tinsert(UISpecialFrames, "GloomsPortraits_Panel")
end

------------------------------------------------------------------------
-- Visibility — only show/hide, never calls Setup
------------------------------------------------------------------------
UpdateVisibility = function()
    if not initialised then return end

    local inCombat  = UnitAffectingCombat("player")
    local hasTarget = UnitExists("target")

    for _, which in ipairs({ "player", "target" }) do
        local model  = models[which]
        local portF  = portraits[which]
        local anchor = anchors[which]
        if not model or not portF or not anchor then return end

        local unitExists = (which == "player") or hasTarget
        local cond = (db[which] and db[which].showCondition) or "always"
        local condMet
        if     cond == "always"           then condMet = true
        elseif cond == "combat"           then condMet = inCombat
        elseif cond == "target"           then condMet = hasTarget
        elseif cond == "combat_or_target" then condMet = inCombat or hasTarget
        else                                   condMet = true
        end

        local visible = unitExists and condMet
        local mode    = (db[which] and db[which].mode) or "3d"

        anchor:SetShown(visible)
        model:SetShown(visible and mode == "3d")
        portF:SetShown(visible and mode == "2d")
    end
end

local function OnTargetChanged()
    if not initialised then return end
    if UnitExists("target") then
        SetupModel("target")
        SetupPortrait("target")
    end
    UpdateVisibility()
end

------------------------------------------------------------------------
-- Minimap button
-- ⚠ STAGE 1 ONLY. The suite has ONE launcher — the Hub's GS button — and
-- every other tool dropped its own. This one survives until the Portraits
-- tab exists (stage 2), because until then the panel has nothing else to
-- open it. LibDBIcon comes from GloomsHub (a hard dependency), so nothing
-- is embedded here.
------------------------------------------------------------------------
local function CreateMinimapButton()
    local LibStub = _G.LibStub
    if not LibStub then
        print("|cff936bffGloom's Portraits:|r LibStub not found — minimap button unavailable.")
        return
    end
    local LDB     = LibStub:GetLibrary("LibDataBroker-1.1", true)
    local LDBIcon = LibStub:GetLibrary("LibDBIcon-1.0", true)
    if not LDB or not LDBIcon then
        print("|cff936bffGloom's Portraits:|r LibDBIcon not found — minimap button unavailable.")
        return
    end
    local broker = LDB:NewDataObject("GloomsPortraits", {
        type  = "launcher",
        label = "Gloom's Portraits",
        icon  = "Interface\\Icons\\inv_12_nonmasculinecharacter_bloodelf",
        OnClick = function()
            local p = panels.unified
            if p:IsShown() then p:Hide() else p:Show() end
        end,
        OnTooltipShow = function(tooltip)
            tooltip:AddLine("Gloom's Portraits", 1, 1, 1)
            tooltip:AddLine("Click: toggle controls", 0.8, 0.8, 0.8)
        end,
    })
    if type(db.minimap) ~= "table" then db.minimap = { hide = false } end
    LDBIcon:Register("GloomsPortraits", broker, db.minimap)
end

------------------------------------------------------------------------
-- Initialise
------------------------------------------------------------------------
local DB_VERSION = 14

-- One-time COPY of the predecessor addon's saved settings, so positions,
-- sizes and modes survive the rename. Same pattern as MigrateFromStoneTweaks
-- in the Hub's Core.lua: copy, never move; the old table is left untouched
-- as the rollback. Runs at PLAYER_LOGIN because the other addon's
-- SavedVariables only exist once IT has loaded, and it sorts after us.
local function MigrateFromPredecessor()
    if type(GloomsPortraitsDB) == "table" and GloomsPortraitsDB._version == DB_VERSION then
        return   -- we already have real data; never overwrite it
    end
    local old = _G.StoneModelDB
    if type(old) ~= "table" or old._version ~= DB_VERSION then return end
    GloomsPortraitsDB = CopyTable(old)
    GloomsPortraitsDB.migratedFromPredecessor = true
    print("|cff936bffGloom's Portraits:|r Copied the saved portrait settings from the old addon. Its own data is untouched — you can disable it now.")
end

local function Initialise()
    MigrateFromPredecessor()
    if type(GloomsPortraitsDB) ~= "table" or GloomsPortraitsDB._version ~= DB_VERSION then
        GloomsPortraitsDB = { _version = DB_VERSION }
    end
    if type(GloomsPortraitsDB.player)  ~= "table" then GloomsPortraitsDB.player  = {} end
    if type(GloomsPortraitsDB.target)  ~= "table" then GloomsPortraitsDB.target  = {} end
    if type(GloomsPortraitsDB.minimap) ~= "table" then GloomsPortraitsDB.minimap = { hide = false } end
    ApplyDefaults(GloomsPortraitsDB.player, DEFAULTS.player)
    ApplyDefaults(GloomsPortraitsDB.target, DEFAULTS.target)
    db = GloomsPortraitsDB

    CreateUnitFrames("player")
    CreateUnitFrames("target")
    CreateGhostFrame("player")
    CreateGhostFrame("target")
    CreateControlPanel()
    CreateMinimapButton()

    ApplySettings("player")
    ApplySettings("target")

    SetLocked(true)
    initialised = true

    models.player:Hide()   anchors.player:Hide()   portraits.player:Hide()
    models.target:Hide()   anchors.target:Hide()   portraits.target:Hide()
end

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("UNIT_MODEL_CHANGED")
eventFrame:RegisterEvent("UNIT_PORTRAIT_UPDATE")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")

eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "PLAYER_LOGIN" then
        Initialise()
        self:UnregisterEvent("PLAYER_LOGIN")

    elseif event == "PLAYER_ENTERING_WORLD" then
        if initialised then
            SetupModel("player")
            SetupPortrait("player")
            OnTargetChanged()
        end

    elseif event == "PLAYER_TARGET_CHANGED" then
        OnTargetChanged()

    elseif event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
        UpdateVisibility()

    elseif event == "UNIT_MODEL_CHANGED" then
        if arg1 == "player" and initialised then
            SetupModel("player")
        elseif arg1 == "target" and initialised and UnitExists("target") then
            SetupModel("target")
        end

    elseif event == "UNIT_PORTRAIT_UPDATE" then
        if arg1 == "player" and initialised and db.player.mode == "2d" then
            SetupPortrait("player")
        elseif arg1 == "target" and initialised and db.target.mode == "2d" and UnitExists("target") then
            SetupPortrait("target")
        end
    end
end)

------------------------------------------------------------------------
-- Slash commands
------------------------------------------------------------------------
SLASH_GLOOMSPORTRAITS1 = "/gp"
SLASH_GLOOMSPORTRAITS2 = "/portraits"
SLASH_GLOOMSPORTRAITS3 = "/sm"   -- the old habit keeps working

SlashCmdList["GLOOMSPORTRAITS"] = function(msg)
    if not initialised then
        print("|cff936bffGloom's Portraits:|r Still loading, please wait.")
        return
    end
    msg = msg:lower():gsub("^%s+", ""):gsub("%s+$", "")

    if msg == "lock" then
        SetLocked(true)
        print("|cff936bffGloom's Portraits:|r Locked.")
    elseif msg == "unlock" then
        SetLocked(false)
        print("|cff936bffGloom's Portraits:|r Unlocked.")
    elseif msg == "panel" then
        local p = panels.unified
        if p:IsShown() then p:Hide() else p:Show() end
    elseif msg == "reset" then
        GloomsPortraitsDB.player = {}
        GloomsPortraitsDB.target = {}
        ApplyDefaults(GloomsPortraitsDB.player, DEFAULTS.player)
        ApplyDefaults(GloomsPortraitsDB.target, DEFAULTS.target)
        db = GloomsPortraitsDB
        ApplySettings("player")
        ApplySettings("target")
        SetupModel("player")
        SetupPortrait("player")
        if UnitExists("target") then
            SetupModel("target")
            SetupPortrait("target")
        end
        print("|cff936bffGloom's Portraits:|r Reset to defaults.")
    else
        local p = panels.unified
        if p:IsShown() then p:Hide() else p:Show() end
    end
end
