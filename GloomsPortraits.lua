-- GloomsPortraits.lua — Gloom's Portraits, the suite's fifth tool: the ENGINE.
-- Free-floating 3D full-body models OR 2D circular portraits for player and target.
-- /gp opens the Portraits tab of the Suite window (GloomsPortraits_Tab.lua).
--
-- This file owns the frames and the saved settings and exposes a small API on
-- `GloomsPortraits` for the tab. It draws no config UI of its own: the old
-- floating control panel (stage 1, 2026-09-19) was replaced by the Suite tab
-- in stage 2 the same day, and the minimap button went with it — the suite has
-- ONE launcher, the Hub's GS button.
--
-- COORDINATE SYSTEM NOTE:
-- WoW's UI coordinate space is always 768 units tall regardless of resolution.
-- For 16:9, width is ~1365 units. Screen center is 0,0.
-- Safe X range ~-600 to +600, Y range ~-350 to +350.

local GP = {}
_G.GloomsPortraits = GP

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
local ghosts      = {}   -- green outlines shown while a unit is being edited
local editing     = nil  -- which unit the tab is editing ("player"/"target"/nil)
local blocked     = {}   -- per unit: the game refused to identify it for a 3D model
local listeners   = {}   -- tab callbacks: fn(what, which)

------------------------------------------------------------------------
-- Forward declarations
------------------------------------------------------------------------
local UpdateVisibility

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
-- Per-mode layouts. `x y size strata` at the top level are always the ACTIVE
-- mode's values (every reader stays simple and every old save loads as-is);
-- the other mode's set waits in cfg.layouts[mode]. Switching modes stashes
-- one and restores the other, so 3D and 2D each keep their own size, place
-- and layer — and the 2D set is what the in-combat stand-in wears.
------------------------------------------------------------------------
local LAYOUT_KEYS = { "x", "y", "size", "strata" }

local function StashLayout(cfg, mode)
    cfg.layouts = cfg.layouts or {}
    local t = cfg.layouts[mode] or {}
    for _, k in ipairs(LAYOUT_KEYS) do t[k] = cfg[k] end
    cfg.layouts[mode] = t
end

-- Load `mode`'s stashed layout into the top level. A mode never visited
-- starts where the current one is, which is the least surprising place.
local function RestoreLayout(cfg, mode)
    local t = cfg.layouts and cfg.layouts[mode]
    if not t then return end
    for _, k in ipairs(LAYOUT_KEYS) do
        if t[k] ~= nil then cfg[k] = t[k] end
    end
end

-- The layout the 2D stand-in should wear while the unit is in 3D mode, or
-- nil (no 2D layout defined yet → follow the model).
local function StandInLayout(which)
    local cfg = db[which]
    if (cfg.mode or "3d") ~= "3d" then return nil end
    return cfg.layouts and cfg.layouts["2d"] or nil
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
        -- In 3D mode the portrait only ever appears as the STAND-IN for a
        -- blocked model, and then it wears the 2D layout the owner defined
        -- (the owner, 2026-09-19: a stand-in at the model's size and place
        -- is wrong). With no 2D layout defined yet it follows the model.
        local sl = StandInLayout(which)
        if sl then
            portFrame:SetSize(sl.size, sl.size)
            portFrame:SetPoint("CENTER", UIParent, "CENTER", sl.x, sl.y)
        else
            portFrame:SetSize(cfg.size, cfg.size)
            portFrame:SetPoint("CENTER", UIParent, "CENTER", ox, oy)
        end
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
-- ★ RE-MEASURED 2026-09-19, same delve: the secrecy is a COMBAT rule, not an
-- instance rule. Out of combat, UnitGUID and UnitName of the same hostile are
-- both readable (issecretvalue → false) and SetUnit works; the moment the pull
-- starts they go secret. Only ENEMY identity is affected either way, which is
-- why friendly and party units keep working in the same delve.
--
-- What that buys: a mob targeted BEFORE the pull gets its real 3D model, and the
-- frame keeps it through the fight because nothing re-asks the game until the
-- target changes. A mob targeted MID-fight cannot be identified — the honest
-- response is the 2D stand-in (UpdateVisibility), never a stale model — and
-- PLAYER_REGEN_ENABLED re-asks so the stand-in yields to 3D when combat ends.
-- There is no addon-side way past the in-combat half: the model IS the identity.
local function CanShowUnit(unit)
    if not UnitExists(unit) then return false end
    -- issecretvalue is the only safe question to ask: never compare or concatenate
    -- a possibly-secret value first.
    if issecretvalue and issecretvalue(UnitGUID(unit)) then return false end
    return true
end

local function ApplyCamera(model, cfg)
    model:SetFacing(cfg.facing)
    model:SetPortraitZoom(0)
    model:SetCamDistanceScale(cfg.zoom)
    model:SetAnimation(0)
    model:SetViewTranslation(0, cfg.modelYOffset or 0)
    model:SetPitch(cfg.pitch or 0)
end

------------------------------------------------------------------------
-- The NAMEPLATE CACHE — how a mob targeted before the pull keeps its 3D model
-- when you tab BACK to it mid-combat.
--
-- ★ MEASURED IN A DELVE, 2026-09-19 (all with /dump issecretvalue):
--   · UnitGUID("target")     out of combat → false; in combat → true.
--   · UnitGUID("nameplateN") out of combat → TRUE. Plates are secret on the
--     map, combat or not — so "record the whole pack as it comes into view"
--     is impossible; a model of a plate unit never even loads (display 0,
--     OnModelLoaded never fires).
--   · UnitGUID("mouseover")  out of combat → TRUE. Hovering identifies nothing.
--   · UnitIsUnit("target", "nameplateN") in combat → a REAL boolean (one
--     plate true, the rest false, none secret).
-- So the game identifies exactly ONE unit for an addon on a restricted map —
-- the target, out of combat — but will always say WHICH PLATE the target is.
--
-- Hence: each time the target is identifiable, its creature ID (from the
-- GUID) is recorded against the plate it is standing under. In combat, when
-- the identity is withheld, the target's plate is matched and the recorded
-- creature ID goes to SetCreature, which takes a plain number and is not
-- guarded. Plate tokens are REUSED as plates come and go, so an entry dies
-- with NAME_PLATE_UNIT_REMOVED. Players are never recorded (SetUnit works
-- on them anyway, and a creature model is the wrong thing for a player).
-- A mob never targeted before the pull cannot be identified — it gets the
-- 2D stand-in (UpdateVisibility), never a stale or guessed model.
------------------------------------------------------------------------
local plateCache = {}     -- "nameplateN" -> creature ID, while that plate is up

-- The plate the target is standing under, or nil. Safe in combat.
local function TargetPlate()
    for i = 1, 40 do
        local token = "nameplate" .. i
        if UnitExists(token) then
            local same = UnitIsUnit("target", token)
            if not (issecretvalue and issecretvalue(same)) and same then return token end
        end
    end
end

-- Called whenever the target changes: record it if the game will identify it.
local function RecordTarget()
    if not UnitExists("target") then return end
    local guid = UnitGUID("target")
    if not guid or (issecretvalue and issecretvalue(guid)) then return end   -- in combat
    local kind, _, _, _, _, npcID = strsplit("-", guid)
    if (kind ~= "Creature" and kind ~= "Vehicle") or not tonumber(npcID) then return end
    local token = TargetPlate()
    if token then plateCache[token] = tonumber(npcID) end
end

-- The creature ID recorded for whichever plate the target IS, or nil.
local function CachedTargetCreature()
    local token = TargetPlate()
    return token and plateCache[token] or nil, token
end

local function SetupModel(which)
    local model = models[which]
    if not model then return end
    local cfg  = db[which]
    local unit = (which == "player") and "player" or "target"
    blocked[which] = not CanShowUnit(unit)
    if blocked[which] and which == "target" then
        local id = CachedTargetCreature()
        if id then
            -- The identity is secret but the plate isn't: draw what we recorded.
            model:SetCreature(id)
            ApplyCamera(model, cfg)
            blocked[which] = false
            SyncToAnchor(which)
            UpdateVisibility()
            return
        end
    end
    if blocked[which] then
        -- Empty beats WRONG. A stale model is indistinguishable from a correct one.
        -- ⚠ ClearModel is NOT enough on 12.1 (owner-observed in a delve,
        -- 2026-09-19): friendly target → clear → hostile target showed the
        -- FRIENDLY model again. So the frame is hidden outright by
        -- UpdateVisibility while `blocked` is set; the clear is belt-and-braces.
        if model.ClearModel then model:ClearModel() end
        UpdateVisibility()
        return
    end
    model:SetUnit(unit)
    ApplyCamera(model, cfg)
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
    anchors[which]:SetFrameStrata(s)
    ghosts[which]:SetFrameStrata(s)
    local sl = StandInLayout(which)
    portraits[which]:SetFrameStrata(sl and sl.strata or s)
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
    StashLayout(cfg, cfg.mode or "3d")
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
        if editing ~= which then
            ghosts[which]:Hide()
        end
        SavePosition(which)
        StashLayout(db[which], db[which].mode or "3d")
        SyncToAnchor(which)
        GP:Notify("position", which)
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
        -- A blocked 3D model is never shown, whatever ClearModel did or didn't do.
        -- ★ FALLBACK (owner-QA'd in a delve, 2026-09-19): SetPortraitTexture is
        -- NOT on the guarded list — it renders engine-side and hands Lua nothing —
        -- so a hostile that the game refuses to identify for a 3D model still
        -- gets its correct 2D portrait, in the same frame, at the same size.
        -- The right face beats an empty frame.
        model:SetShown(visible and mode == "3d" and not blocked[which])
        portF:SetShown(visible and (mode == "2d" or blocked[which] == true))
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
-- The API the Portraits tab drives (GloomsPortraits_Tab.lua). Everything
-- applies LIVE: there is no save step, the frames ARE the preview.
------------------------------------------------------------------------
GP.UNITS = { "player", "target" }

-- The unit's saved settings, or nil before PLAYER_LOGIN.
function GP:Config(which)
    return db and db[which] or nil
end

function GP:Defaults(which)
    return DEFAULTS[which]
end

function GP:IsReady()
    return initialised
end

-- Size / position changed: cheap re-anchor, no model reload.
function GP:ApplyLayout(which)
    if not initialised then return end
    local cfg, anchor = db[which], anchors[which]
    StashLayout(cfg, cfg.mode or "3d")   -- keep the stash current for the active mode
    anchor:SetSize(cfg.size, cfg.size)
    anchor:ClearAllPoints()
    anchor:SetPoint("CENTER", UIParent, "CENTER", cfg.x, cfg.y)
    SyncToAnchor(which)
end

function GP:Nudge(which, dx, dy)
    if not initialised then return end
    MoveModel(which, dx, dy)
end

function GP:SetMode(which, mode)
    if not initialised then return end
    local cfg = db[which]
    local old = cfg.mode or "3d"
    if mode ~= old then
        StashLayout(cfg, old)
        cfg.mode = mode
        RestoreLayout(cfg, mode)
        ApplySettings(which)   -- re-anchors to the restored layout
    else
        ApplyMode(which)
    end
    UpdateVisibility()
end

function GP:SetStrata(which, strata)
    if not initialised then return end
    db[which].strata = strata
    StashLayout(db[which], db[which].mode or "3d")
    ApplyStrata(which)
end

function GP:SetCondition(which, cond)
    if not initialised then return end
    db[which].showCondition = cond
    UpdateVisibility()
end

-- The 3D camera: facing (radians), zoom, modelYOffset, pitch. Each pokes
-- the live model directly, exactly as the old panel's sliders did.
function GP:SetCamera(which, key, v)
    if not initialised then return end
    db[which][key] = v
    local m = models[which]
    if not m then return end
    if     key == "facing"       then m:SetFacing(v)
    elseif key == "zoom"         then m:SetPortraitZoom(0); m:SetCamDistanceScale(v)
    elseif key == "modelYOffset" then m:SetViewTranslation(0, v)
    elseif key == "pitch"        then m:SetPitch(v)
    end
end

-- Back to the factory settings for ONE unit. The tab confirms first.
function GP:Reset(which)
    if not initialised then return end
    db[which] = {}
    ApplyDefaults(db[which], DEFAULTS[which])
    ApplySettings(which)
    if which == "player" or UnitExists("target") then
        SetupModel(which)
        SetupPortrait(which)
    end
    UpdateVisibility()
    if editing == which then GP:SetEditing(which) end
    GP:Notify("reset", which)
end

-- Which unit the tab is editing. Unlocks dragging and shows the green
-- outline for that unit; nil locks everything and hides the outlines —
-- the tab calls this from its OnShow/OnHide, so closing the Suite window
-- always locks.
function GP:SetEditing(which)
    editing = which
    isUnlocked = which ~= nil
    for _, w in ipairs(GP.UNITS) do
        local anchor, g = anchors[w], ghosts[w]
        if anchor then anchor:EnableMouse(isUnlocked) end
        if g then
            if w == which and db then
                local cfg = db[w]
                g:SetSize(cfg.size, cfg.size)
                g:ClearAllPoints()
                g:SetPoint("CENTER", UIParent, "CENTER", cfg.x, cfg.y)
                g:Show()
            elseif not (anchor and anchor._dragging) then
                g:Hide()
            end
        end
    end
end

-- The tab listens so a drag on screen updates its X/Y rows.
function GP:OnChange(fn)
    listeners[#listeners + 1] = fn
end

function GP:Notify(what, which)
    for _, fn in ipairs(listeners) do fn(what, which) end
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

    ApplySettings("player")
    ApplySettings("target")

    GP:SetEditing(nil)
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
eventFrame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
eventFrame:RegisterEvent("NAME_PLATE_UNIT_REMOVED")

eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "PLAYER_LOGIN" then
        Initialise()
        self:UnregisterEvent("PLAYER_LOGIN")

    elseif event == "PLAYER_ENTERING_WORLD" then
        if initialised then
            RecordTarget()
            SetupModel("player")
            SetupPortrait("player")
            OnTargetChanged()
        end

    elseif event == "NAME_PLATE_UNIT_ADDED" then
        -- The target's own plate may appear after the target did.
        if UnitExists("target") then RecordTarget() end

    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        plateCache[arg1] = nil

    elseif event == "PLAYER_TARGET_CHANGED" then
        RecordTarget()
        OnTargetChanged()

    elseif event == "PLAYER_REGEN_DISABLED" then
        UpdateVisibility()

    elseif event == "PLAYER_REGEN_ENABLED" then
        -- ★ MEASURED IN A DELVE, 2026-09-19: a hostile's identity is secret ONLY
        -- IN COMBAT (issecretvalue(UnitGUID("target")) → false before the pull,
        -- true during it). So a model the game refused mid-fight can be asked
        -- for again the moment combat drops — and the 2D stand-in gives way to
        -- the real 3D model without the owner re-targeting.
        RecordTarget()       -- the target is identifiable again
        if initialised and blocked.target and UnitExists("target") then
            SetupModel("target")
        end
        UpdateVisibility()

    elseif event == "UNIT_MODEL_CHANGED" then
        if arg1 == "player" and initialised then
            SetupModel("player")
        elseif arg1 == "target" and initialised and UnitExists("target") then
            SetupModel("target")
        end

    elseif event == "UNIT_PORTRAIT_UPDATE" then
        -- Also while a 3D model is blocked: the portrait is standing in for it.
        if arg1 == "player" and initialised and (db.player.mode == "2d" or blocked.player) then
            SetupPortrait("player")
        elseif arg1 == "target" and initialised and (db.target.mode == "2d" or blocked.target) and UnitExists("target") then
            SetupPortrait("target")
        end
    end
end)

------------------------------------------------------------------------
-- Slash commands — /gp opens the Portraits tab. The old lock/unlock/panel
-- subcommands are gone with the panel: the tab unlocks dragging while it is
-- open and locks it again when it closes. Reset lives in the tab's rail.
------------------------------------------------------------------------
SLASH_GLOOMSPORTRAITS1 = "/gp"
SLASH_GLOOMSPORTRAITS2 = "/portraits"
SLASH_GLOOMSPORTRAITS3 = "/sm"   -- the old habit keeps working

SlashCmdList["GLOOMSPORTRAITS"] = function(msg)
    if not initialised then
        print("|cff936bffGloom's Portraits:|r Still loading, please wait.")
        return
    end
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if msg == "plates" then
        -- QA probe: what the nameplate cache knows right now.
        local n = 0
        for i = 1, 40 do
            local token = "nameplate" .. i
            local id = plateCache[token]
            if id then
                n = n + 1
                local same = UnitIsUnit("target", token)
                same = not (issecretvalue and issecretvalue(same)) and same
                print(("  %s → creature %d%s"):format(token, id, same and "  ← TARGET" or ""))
            end
        end
        print(("|cff936bffGloom's Portraits:|r %d plate%s cached, target %s."):format(
            n, n == 1 and "" or "s", blocked.target and "BLOCKED (2D stand-in)" or "3D"))
        return
    end
    GloomsHub:ToggleWindow("portraits")
end
