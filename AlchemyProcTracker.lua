-- AlchemyProcTracker.lua
-- Tracks Alchemy mastery procs (Flask/Elixir/Potion/Transmute) in TBC Classic.
--
-- Usage:
--   /apt          → show help
--   /apt show     → open the stats window
--   /apt hide     → close the stats window
--   /apt reset    → reset session stats (overall stats are kept)
--   /apt reset all → reset ALL stats including overall
--   /apt group X  → switch the displayed group (FLASK/ELIXIR/POTION/TRANSMUTE)

local ADDON_NAME = ...

-- ============================================================
-- Addon Object
-- Mixins: AceConsole-3.0 (Print, RegisterChatCommand)
--         AceEvent-3.0   (RegisterEvent, UnregisterEvent)
-- ============================================================

local APT = LibStub("AceAddon-3.0"):NewAddon("AlchemyTracker", "AceConsole-3.0", "AceEvent-3.0")

-- ============================================================
-- Constants: Alchemy Mastery Passive Spell IDs (TBC Classic)
-- ============================================================

local ELIXIR_MASTER_SPELL_ID    = 28677
local POTION_MASTER_SPELL_ID    = 28675
local TRANSMUTE_MASTER_SPELL_ID = 28672

-- ============================================================
-- TrackedItems (flat lookup, built at load time)
-- Do not edit directly — edit AlchemyTrackerItems.lua instead.
-- ============================================================

local TrackedItems = {}

-- ============================================================
-- UI state
-- ============================================================

local APT_Frame
local APT_Lines   = {}
local APT_RefreshUI      -- forward declaration; assigned after CreateUI
local APT_RefreshHistory -- forward declaration; assigned after CreateHistoryUI
local debugMode   = false

-- ============================================================
-- Current Craft State
-- A single in-progress craft accumulates here.
-- Messages for the same item within CRAFT_WINDOW seconds are grouped as one
-- craft (base + proc). After the window the craft is finalized immediately.
-- A different item arriving mid-window finalizes the previous craft first.
-- ============================================================

local CRAFT_WINDOW    = 0.4   -- seconds to collect proc messages after first "You create"
local SESSION_TIMEOUT = 900   -- 15 minutes: if alchemy window stays closed this long, new session starts next open
local MAX_SESSIONS    = 200   -- maximum number of past sessions to keep in history

local currentCraft  = nil
local craftTimer    = nil   -- C_Timer handle for finalizing the current craft
local sessionTimer  = nil   -- C_Timer handle for session inactivity
local sessionClosed = false -- true when 15-min timeout fired; session resets on next TRADE_SKILL_SHOW

--[[
  currentCraft shape while accumulating:
  {
    itemID       = number,
    itemName     = string,
    group        = string,   -- "FLASK" | "ELIXIR" | "POTION" | "TRANSMUTE"
    totalCreated = number,
  }
  Finalized CRAFT_WINDOW seconds after the last "You create" message for that item,
  or immediately when a different item arrives or TRADE_SKILL_CLOSE fires.
]]

-- ============================================================
-- AceDB-3.0 Defaults
-- AceDB handles per-character (db.char) vs global (db.global)
-- scoping and deep-copies these defaults for new entries.
-- ============================================================

local function newStatsDefaults()
    return {
        totalCrafts         = 0,
        totalPotions        = 0,
        totalExtra          = 0,
        procs1              = 0,
        procs2              = 0,
        procs3              = 0,
        procs4              = 0,
        currentNoProcStreak = 0,
        longestNoProcStreak = 0,
    }
end

local function newGroupDefaults()
    return { session = newStatsDefaults(), overall = newStatsDefaults() }
end

-- Shallow-copies the scalar stats fields from s into a new table.
-- Used when snapshotting a session; items = {} is always a fresh table.
local function CopyStats(s)
    return {
        totalCrafts         = s.totalCrafts,
        totalPotions        = s.totalPotions,
        totalExtra          = s.totalExtra,
        procs1              = s.procs1,
        procs2              = s.procs2,
        procs3              = s.procs3,
        procs4              = s.procs4,
        longestNoProcStreak = s.longestNoProcStreak,
        items               = {},
    }
end

local defaults = {
    global = {
        minimap = {},
    },
    char = {
        specialization = {
            current     = "None",
            isElixir    = false,
            isPotion    = false,
            isTransmute = false,
        },
        stats = {
            FLASK     = newGroupDefaults(),
            ELIXIR    = newGroupDefaults(),
            POTION    = newGroupDefaults(),
            TRANSMUTE = newGroupDefaults(),
        },
        nextSessionID = 0,  -- monotonic counter; assigned to each saved session for stable UI keys
        sessions      = {},  -- history of past sessions, newest first; max MAX_SESSIONS entries
        windowPos     = false,  -- saved position for the main stats window
        historyPos    = false,  -- saved position for the session history window
    },
}

-- ============================================================
-- BuildTrackedItemLookup
-- Reads AlchemyTrackerItemData and flattens it into TrackedItems.
-- Called once from OnInitialize after SavedVariables are loaded.
-- ============================================================

local function BuildTrackedItemLookup()
    if not AlchemyTrackerItemData then
        APT:Print("|cffff0000ERROR:|r AlchemyTrackerItemData not found. Check AlchemyTrackerItems.lua.")
        return
    end

    for expansion, groups in pairs(AlchemyTrackerItemData) do
        for group, items in pairs(groups) do
            for itemID, name in pairs(items) do
                if TrackedItems[itemID] then
                    APT:Print(string.format(
                        "|cffff8800Warning:|r duplicate item ID %d ('%s') in %s/%s — first entry kept.",
                        itemID, name, expansion, group
                    ))
                else
                    TrackedItems[itemID] = {
                        group     = group,
                        name      = name,
                        expansion = expansion,
                    }
                end
            end
        end
    end
end

-- ============================================================
-- GetTrackedGroupForItem
-- ============================================================

local function GetTrackedGroupForItem(itemID)
    local info = TrackedItems[itemID]
    if info then return info.group, info.name end
    return nil, nil
end

-- ============================================================
-- CalcPctGain
-- ============================================================

local GROUPS_ORDER = { "FLASK", "ELIXIR", "POTION", "TRANSMUTE" }

local function CalcPctGain(s)
    if s.totalPotions > 0 then
        return string.format("+%.1f%%", (s.totalExtra / s.totalPotions) * 100)
    end
    return "+0.0%"
end

-- ============================================================
-- DetectAlchemySpecialization
-- Returns true if a mastery was found (so callers can stop watching).
-- ============================================================

local function DetectAlchemySpecialization()
    local spec        = APT.db.char.specialization
    local isElixir    = IsPlayerSpell(ELIXIR_MASTER_SPELL_ID)    or false
    local isPotion    = IsPlayerSpell(POTION_MASTER_SPELL_ID)    or false
    local isTransmute = IsPlayerSpell(TRANSMUTE_MASTER_SPELL_ID) or false

    local current = "None"
    if     isElixir    then current = "Elixir"
    elseif isPotion    then current = "Potion"
    elseif isTransmute then current = "Transmute"
    end

    spec.current     = current
    spec.isElixir    = isElixir
    spec.isPotion    = isPotion
    spec.isTransmute = isTransmute

    return current ~= "None"
end

-- ============================================================
-- UpdateStats
-- Applies one finalized craft to both session and overall scopes.
-- ============================================================

local function UpdateStats(groupStats, totalCreated, itemID, itemName)
    local extra = totalCreated - 1

    for _, scope in ipairs({ "session", "overall" }) do
        local s = groupStats[scope]

        s.totalCrafts  = s.totalCrafts  + 1
        s.totalPotions = s.totalPotions + totalCreated
        s.totalExtra   = s.totalExtra   + extra

        if extra >= 1 then
            if     extra == 1 then s.procs1 = s.procs1 + 1
            elseif extra == 2 then s.procs2 = s.procs2 + 1
            elseif extra == 3 then s.procs3 = s.procs3 + 1
            else                   s.procs4 = s.procs4 + 1
            end
            s.currentNoProcStreak = 0
        else
            s.currentNoProcStreak = s.currentNoProcStreak + 1
            if s.currentNoProcStreak > s.longestNoProcStreak then
                s.longestNoProcStreak = s.currentNoProcStreak
            end
        end
    end

    -- Per-item tracking (session only).
    if itemID and itemName then
        local s = groupStats["session"]
        if not s.items then s.items = {} end
        local it = s.items[itemID]
        if not it then
            it = { name = itemName, totalCrafts = 0, totalPotions = 0, totalExtra = 0 }
            s.items[itemID] = it
        end
        it.totalCrafts  = it.totalCrafts  + 1
        it.totalPotions = it.totalPotions + totalCreated
        it.totalExtra   = it.totalExtra   + extra
    end
end

-- ============================================================
-- FinalizeCraft
-- ============================================================

local function FinalizeCraft()
    if not currentCraft then return end

    local groupStats = APT.db.char.stats[currentCraft.group]
    if not groupStats then
        currentCraft = nil
        return
    end

    local totalCreated = currentCraft.totalCreated
    local extra        = totalCreated - 1

    if extra > 0 then
        APT:Print(string.format(
            "|cff00ff00Proc!|r %s: crafted %d (+%d extra).",
            currentCraft.itemName, totalCreated, extra
        ))
    end

    UpdateStats(groupStats, totalCreated, currentCraft.itemID, currentCraft.itemName)
    if APT_RefreshUI then APT_RefreshUI() end

    currentCraft = nil
end

-- ============================================================
-- ParseItemIDFromLink
-- ============================================================

local function ParseItemIDFromLink(link)
    if not link then return nil end
    local idStr = link:match("|Hitem:(%d+):")
    return idStr and tonumber(idStr) or nil
end

-- ============================================================
-- ParseCreateMessage
-- Handles the two TBC Classic "You create" formats:
--   "You create: [link]."    → 1 item
--   "You create Nx [link]."  → N items
-- ============================================================

local function ParseCreateMessage(msg)
    if not msg then return nil, nil end

    local amountStr, link = msg:match("^You create (%d+)x (.+)%.$")
    if amountStr and link then return tonumber(amountStr), link end

    link = msg:match("^You create: (.+)%.$")
    if link then return 1, link end

    return nil, nil
end

-- ============================================================
-- ParseLootMessage
-- Parses "You receive loot: Nx[link]." or "You receive loot: [link]."
-- These fire from CHAT_MSG_LOOT when alchemy mastery procs give extra items.
-- ============================================================

local function ParseLootMessage(msg)
    if not msg then return nil, nil end
    -- Multi: "You receive loot: 2x|Hitem:...|h[Name]|h|r."  (no space between x and link)
    local n, link = msg:match("^You receive loot: (%d+)x(.+)%.$")
    if n then return tonumber(n), link end
    -- Single: "You receive loot: |Hitem:...|h[Name]|h|r."
    link = msg:match("^You receive loot: (.+)%.$")
    if link then return 1, link end
    return nil, nil
end

-- ============================================================
-- HandleCraftEvent
-- Groups same-item messages within CRAFT_WINDOW seconds (base + proc).
-- Each craft is finalized independently via a short timer.
-- ============================================================

local function CancelCraftTimer()
    if craftTimer then
        craftTimer:Cancel()
        craftTimer = nil
    end
end

local function ScheduleCraftFinalize()
    CancelCraftTimer()
    craftTimer = C_Timer.NewTimer(CRAFT_WINDOW, function()
        craftTimer = nil
        FinalizeCraft()
    end)
end

local function HandleCraftEvent(msg)
    local amount, link = ParseCreateMessage(msg)
    if not amount then return end

    local itemID = ParseItemIDFromLink(link)
    if not itemID then return end

    local group, itemName = GetTrackedGroupForItem(itemID)
    if not group then return end

    if currentCraft and currentCraft.itemID == itemID then
        -- Same item within the window: accumulate (proc extra items).
        currentCraft.totalCreated = currentCraft.totalCreated + amount
        ScheduleCraftFinalize()
    else
        -- Different item (or no active craft): finalize previous immediately.
        CancelCraftTimer()
        FinalizeCraft()
        currentCraft = {
            itemID       = itemID,
            itemName     = itemName,
            group        = group,
            totalCreated = amount,
        }
        ScheduleCraftFinalize()
    end
end

-- ============================================================
-- SaveCurrentSession
-- Snapshots session stats into db.char.sessions before a reset.
-- Does nothing if the session had no crafts.
-- ============================================================

local function SaveCurrentSession()
    if not APT.db or not APT.db.char then return end
    if not APT.db.char.sessions then APT.db.char.sessions = {} end

    -- Only save if at least one craft happened this session.
    local hasActivity = false
    for _, group in ipairs(GROUPS_ORDER) do
        local gs = APT.db.char.stats[group]
        if gs and gs.session.totalCrafts > 0 then
            hasActivity = true
            break
        end
    end
    if not hasActivity then return end

    -- Build snapshot: copy session stats for each group.
    APT.db.char.nextSessionID = (APT.db.char.nextSessionID or 0) + 1
    local snapshot = { date = date("%Y-%m-%d %H:%M"), id = APT.db.char.nextSessionID, stats = {} }
    for _, group in ipairs(GROUPS_ORDER) do
        local s  = APT.db.char.stats[group].session
        local gs = CopyStats(s)
        if s.items then
            for id, it in pairs(s.items) do
                gs.items[id] = { name = it.name, totalCrafts = it.totalCrafts, totalPotions = it.totalPotions, totalExtra = it.totalExtra }
            end
        end
        snapshot.stats[group] = gs
    end

    -- Prepend (newest first) and trim to MAX_SESSIONS.
    table.insert(APT.db.char.sessions, 1, snapshot)
    while #APT.db.char.sessions > MAX_SESSIONS do
        table.remove(APT.db.char.sessions)
    end
end

-- ============================================================
-- ResetSessionStats
-- ============================================================

local function ResetSessionStats()
    SaveCurrentSession()
    for _, group in ipairs(GROUPS_ORDER) do
        if APT.db.char.stats[group] then
            APT.db.char.stats[group].session = newStatsDefaults()
        end
    end
    APT:Print("Session stats have been reset.")
    if APT_RefreshUI then APT_RefreshUI() end
end

local function ResetAllStats()
    SaveCurrentSession()
    for _, group in ipairs(GROUPS_ORDER) do
        if APT.db.char.stats[group] then
            APT.db.char.stats[group].session = newStatsDefaults()
            APT.db.char.stats[group].overall = newStatsDefaults()
        end
    end
    APT:Print("All stats (session and overall) have been reset.")
    if APT_RefreshUI then APT_RefreshUI() end
end

-- ============================================================
-- Shared UI constants and helpers
-- ============================================================

local C_OR  = { 1,    0.55, 0.10        }   -- orange accent
local C_ORD = { 0.70, 0.33, 0.05        }   -- dark orange (button normal)
local C_DIV = { 0.40, 0.22, 0.03, 0.50  }   -- dim divider
local C_GRN = { 0.20, 0.85, 0.50        }   -- green for % values

local function DrawBorders(frame)
    -- All borders use child frames to avoid scissor-rect clipping at parent edges.
    local function MakeLine(p1, rp1, x1, y1, p2, rp2, x2, y2, isH)
        local b = CreateFrame("Frame", nil, frame)
        b:SetPoint(p1, frame, rp1, x1, y1)
        b:SetPoint(p2, frame, rp2, x2, y2)
        if isH then b:SetHeight(1) else b:SetWidth(1) end
        local t = b:CreateTexture(nil, "BACKGROUND")
        t:SetAllPoints(b)
        t:SetTexture("Interface\\BUTTONS\\WHITE8X8")
        t:SetVertexColor(C_OR[1], C_OR[2], C_OR[3])
    end
    MakeLine("TOPLEFT","TOPLEFT",0,0,       "TOPRIGHT","TOPRIGHT",0,0,       true)   -- top
    MakeLine("BOTTOMLEFT","BOTTOMLEFT",0,0, "BOTTOMRIGHT","BOTTOMRIGHT",0,0, true)   -- bottom
    MakeLine("TOPLEFT","TOPLEFT",0,0,       "BOTTOMLEFT","BOTTOMLEFT",0,0,   false)  -- left
    MakeLine("TOPRIGHT","TOPRIGHT",-1,0,    "BOTTOMRIGHT","BOTTOMRIGHT",-1,0,false)  -- right
end

local function MakeNavButton(parent, label, w, h, onClick)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(w, h)
    local bbg = btn:CreateTexture(nil, "BACKGROUND")
    bbg:SetAllPoints(btn)
    bbg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
    bbg:SetVertexColor(C_ORD[1], C_ORD[2], C_ORD[3])
    btn._bbg = bbg
    local btxt = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    btxt:SetAllPoints(btn)
    btxt:SetText(label)
    btxt:SetTextColor(1, 1, 1)
    btn:SetScript("OnEnter", function() bbg:SetVertexColor(C_OR[1], C_OR[2], C_OR[3]) end)
    btn:SetScript("OnLeave", function() bbg:SetVertexColor(C_ORD[1], C_ORD[2], C_ORD[3]) end)
    btn:SetScript("OnClick", onClick or function() end)
    return btn
end

local function MakeFrameCloseButton(parent)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(18, 18)
    btn:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -4, -8)
    local cbg = btn:CreateTexture(nil, "BACKGROUND")
    cbg:SetAllPoints(btn)
    cbg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
    cbg:SetVertexColor(0.60, 0.08, 0.08)
    local cx = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    cx:SetAllPoints(btn)
    cx:SetText("X")
    cx:SetTextColor(1, 1, 1)
    btn:SetScript("OnEnter", function() cbg:SetVertexColor(0.90, 0.20, 0.20) end)
    btn:SetScript("OnLeave", function() cbg:SetVertexColor(0.60, 0.08, 0.08) end)
    btn:SetScript("OnClick", function() parent:Hide() end)
    return btn
end

local function MakeDivider(parent, x1, y, x2)
    local d = parent:CreateTexture(nil, "ARTWORK")
    d:SetPoint("TOPLEFT",  parent, "TOPLEFT",  x1, y)
    d:SetPoint("TOPRIGHT", parent, "TOPRIGHT", x2, y)
    d:SetHeight(1)
    d:SetTexture("Interface\\BUTTONS\\WHITE8X8")
    d:SetVertexColor(C_DIV[1], C_DIV[2], C_DIV[3], C_DIV[4])
    return d
end

-- ============================================================
-- Session Rename Dialog
-- ============================================================

local APT_RenameFrame
local APT_RenameTarget  -- sess object currently being renamed

local function ShowRenameDialog(sess)
    if not APT_RenameFrame then
        local d = CreateFrame("Frame", "APT_RenameFrame", UIParent, "BackdropTemplate")
        d:SetSize(300, 110)
        d:SetFrameStrata("DIALOG")
        d:SetMovable(true)
        d:EnableMouse(true)
        d:RegisterForDrag("LeftButton")
        d:SetScript("OnDragStart", d.StartMoving)
        d:SetScript("OnDragStop",  d.StopMovingOrSizing)
        d:SetClampedToScreen(true)

        local dbg = d:CreateTexture(nil, "BACKGROUND")
        dbg:SetAllPoints(d)
        dbg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
        dbg:SetVertexColor(0.07, 0.07, 0.07)
        dbg:SetAlpha(0.97)
        DrawBorders(d)

        local title = d:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("TOPLEFT", d, "TOPLEFT", 10, -10)
        title:SetText("Rename Session")
        title:SetTextColor(C_OR[1], C_OR[2], C_OR[3])

        local hint = d:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        hint:SetPoint("TOPLEFT", d, "TOPLEFT", 10, -26)
        hint:SetText("Leave blank to restore the default name.")
        hint:SetTextColor(0.50, 0.50, 0.50)

        local eb = CreateFrame("EditBox", "APT_RenameEditBox", d, "InputBoxTemplate")
        eb:SetSize(278, 22)
        eb:SetPoint("TOP", d, "TOP", 0, -46)
        eb:SetAutoFocus(false)
        eb:SetMaxLetters(64)
        d.eb = eb

        local save = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
        save:SetSize(80, 22)
        save:SetPoint("BOTTOMRIGHT", d, "BOTTOM", -4, 10)
        save:SetText("Save")
        save:SetScript("OnClick", function()
            if APT_RenameTarget then
                local name = d.eb:GetText():match("^%s*(.-)%s*$")
                APT_RenameTarget.customName = (name ~= "") and name or nil
                APT_RefreshHistory()
            end
            d:Hide()
        end)

        local cancel = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
        cancel:SetSize(80, 22)
        cancel:SetPoint("BOTTOMLEFT", d, "BOTTOM", 4, 10)
        cancel:SetText("Cancel")
        cancel:SetScript("OnClick", function() d:Hide() end)

        eb:SetScript("OnEscapePressed", function() d:Hide() end)
        eb:SetScript("OnEnterPressed", function() save:Click() end)

        APT_RenameFrame = d
    end

    APT_RenameTarget = sess
    APT_RenameFrame.eb:SetText(sess.customName or "")
    APT_RenameFrame:ClearAllPoints()
    APT_RenameFrame:SetPoint("CENTER")
    APT_RenameFrame:Show()
    APT_RenameFrame.eb:SetFocus()
end

-- ============================================================
-- Session History Browser
-- Collapsible tree: Sessions → Groups → Items, plus Overall.
-- ============================================================

local APT_HistoryFrame
local expandedSessions = {}

local H_W        = 500
local H_H        = 440
local H_ROW      = 20
local H_ARROW    = 8
local H_LABEL    = 26
local H_BASE     = 305
local H_TOTAL    = 365
local H_PCT      = 420
local H_COL_W    = 54
local H_MAX_ROWS = 120

local function CreateHistoryUI()
    local DEF_W, DEF_H = H_W, H_H

    local f = CreateFrame("Frame", "APT_HistoryFrame", UIParent, "BackdropTemplate")
    -- Default: left edge sits just right of screen centre; restored from DB if moved before.
    local hp = APT.db.char.historyPos
    f:SetSize(hp and hp.w or DEF_W, hp and hp.h or DEF_H)
    if hp then
        f:SetPoint(hp.point, UIParent, hp.relPoint or hp.point, hp.x, hp.y)
    else
        f:SetPoint("TOPLEFT", UIParent, "CENTER", 10, 200)
    end
    f._defW, f._defH = DEF_W, DEF_H

    f:SetFrameStrata("HIGH")
    f:SetMovable(true)
    f:SetResizable(true)
    f:SetToplevel(true)   -- auto-raise above sibling frames on click
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        local point, _, relPoint, x, y = f:GetPoint()
        APT.db.char.historyPos = { point=point, relPoint=relPoint, x=x, y=y,
                                   w=f:GetWidth(), h=f:GetHeight() }
    end)
    f:SetClampedToScreen(true)
    f:Hide()
    APT_HistoryFrame = f

    -- Enforce minimum size live during drag (OnSizeChanged fires before the frame is finalised)
    local _hClamp = false
    f:SetScript("OnSizeChanged", function(self, w, h)
        if _hClamp then return end
        local nw = math.max(w, 380)
        local nh = math.max(h, 200)
        if nw ~= w or nh ~= h then
            _hClamp = true
            self:SetSize(nw, nh)
            _hClamp = false
        end
    end)

    -- Background
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(f)
    bg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
    bg:SetVertexColor(0.07, 0.07, 0.07)
    bg:SetAlpha(0.97)
    DrawBorders(f)

    -- Title
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -12)
    title:SetText("Crafting Session Tracker")
    title:SetTextColor(C_OR[1], C_OR[2], C_OR[3])

    -- Subtitle
    local sub = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sub:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -30)
    sub:SetText("Track your alchemy proc rates and session statistics")
    sub:SetTextColor(0.50, 0.50, 0.50)

    -- Column headers
    local function MakeColHead(txt, x)
        local fs = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("TOPLEFT", f, "TOPLEFT", x, -46)
        fs:SetWidth(H_COL_W)
        fs:SetJustifyH("RIGHT")
        fs:SetTextColor(C_OR[1], C_OR[2], C_OR[3])
        fs:SetText(txt)
    end
    MakeColHead("Base",  H_BASE)
    MakeColHead("Total", H_TOTAL)
    MakeColHead("Proc%", H_PCT)

    MakeDivider(f, 8, -58, -24)

    -- Close button
    MakeFrameCloseButton(f)

    -- Custom scrollbar (themed track + draggable thumb)
    local SB_W = 6
    local sb = CreateFrame("Frame", nil, f)
    sb:SetPoint("TOPRIGHT",    f, "TOPRIGHT",    -(4),            -62)
    sb:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -(4),              8)
    sb:SetWidth(SB_W)

    local sbTrack = sb:CreateTexture(nil, "BACKGROUND")
    sbTrack:SetAllPoints(sb)
    sbTrack:SetTexture("Interface\\BUTTONS\\WHITE8X8")
    sbTrack:SetVertexColor(0.12, 0.12, 0.12)

    local thumb = CreateFrame("Button", nil, sb)
    thumb:SetWidth(SB_W)
    thumb:SetHeight(40)
    thumb:SetPoint("TOPLEFT", sb, "TOPLEFT", 0, 0)
    thumb:SetPoint("TOPRIGHT", sb, "TOPRIGHT", 0, 0)
    local thumbTex = thumb:CreateTexture(nil, "BACKGROUND")
    thumbTex:SetAllPoints(thumb)
    thumbTex:SetTexture("Interface\\BUTTONS\\WHITE8X8")
    thumbTex:SetVertexColor(C_OR[1], C_OR[2], C_OR[3], 0.65)
    thumb:SetScript("OnEnter", function() thumbTex:SetVertexColor(C_OR[1], C_OR[2], C_OR[3], 1) end)
    thumb:SetScript("OnLeave", function() thumbTex:SetVertexColor(C_OR[1], C_OR[2], C_OR[3], 0.65) end)

    -- Scroll frame (leaves right gutter for the custom scrollbar)
    local sf = CreateFrame("ScrollFrame", "APT_HistorySF", f)
    sf:SetPoint("TOPLEFT",     f, "TOPLEFT",     8,            -62)
    sf:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -(SB_W + 8),    8)
    sf:EnableMouseWheel(true)
    f.sf = sf

    local sc = CreateFrame("Frame", "APT_HistorySC", sf)
    sc:SetSize(sf:GetWidth() or (H_W - 20), 10)
    sf:SetScrollChild(sc)
    f.sc = sc

    -- Scrollbar update: reposition thumb to match current scroll
    local function UpdateScrollbar()
        local contentH = sc:GetHeight()
        local viewH    = sf:GetHeight()
        if contentH <= viewH or sf:GetVerticalScrollRange() == 0 then
            thumb:Hide(); return
        end
        thumb:Show()
        local trackH  = sb:GetHeight()
        local thumbH  = math.max(20, trackH * (viewH / contentH))
        local scrollPct = sf:GetVerticalScroll() / sf:GetVerticalScrollRange()
        local offsetY   = (trackH - thumbH) * scrollPct
        thumb:SetHeight(thumbH)
        thumb:ClearAllPoints()
        thumb:SetPoint("TOPLEFT",  sb, "TOPLEFT",  0, -offsetY)
        thumb:SetPoint("TOPRIGHT", sb, "TOPRIGHT", 0, -offsetY)
    end
    f.UpdateScrollbar = UpdateScrollbar

    -- Scroll via mousewheel
    sf:SetScript("OnMouseWheel", function(self, delta)
        local cur = self:GetVerticalScroll()
        local max = self:GetVerticalScrollRange()
        self:SetVerticalScroll(math.max(0, math.min(max, cur - delta * 20)))
        UpdateScrollbar()
    end)

    -- Drag thumb to scroll
    local dragStartY, dragStartScroll = 0, 0
    thumb:RegisterForClicks("LeftButtonUp")
    thumb:SetScript("OnMouseDown", function(_, btn)
        if btn ~= "LeftButton" then return end
        dragStartY      = select(2, GetCursorPosition()) / UIParent:GetEffectiveScale()
        dragStartScroll = sf:GetVerticalScroll()
        thumb:SetScript("OnUpdate", function()
            local curY    = select(2, GetCursorPosition()) / UIParent:GetEffectiveScale()
            local delta   = dragStartY - curY
            local trackH  = sb:GetHeight()
            local thumbH  = thumb:GetHeight()
            local maxS    = sf:GetVerticalScrollRange()
            if trackH > thumbH then
                sf:SetVerticalScroll(math.max(0, math.min(maxS,
                    dragStartScroll + delta * maxS / (trackH - thumbH))))
                UpdateScrollbar()
            end
        end)
    end)
    thumb:SetScript("OnMouseUp", function()
        thumb:SetScript("OnUpdate", nil)
        UpdateScrollbar()
    end)

    -- Resize grip (bottom-right corner); saves size + position when done
    local grip = CreateFrame("Button", nil, f)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function()
        f:StopMovingOrSizing()
        local point, _, relPoint, x, y = f:GetPoint()
        APT.db.char.historyPos = { point=point, relPoint=relPoint, x=x, y=y,
                                   w=f:GetWidth(), h=f:GetHeight() }
        UpdateScrollbar()
    end)

    -- Pre-create row pool.
    f.rows = {}
    for i = 1, H_MAX_ROWS do
        local row = CreateFrame("Frame", nil, sc)
        row:SetHeight(H_ROW)
        row:Hide()

        local rbg = row:CreateTexture(nil, "BACKGROUND")
        rbg:SetAllPoints(row)
        rbg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
        rbg:SetVertexColor(0, 0, 0, 0)
        row.rbg = rbg

        local btn = CreateFrame("Button", nil, row)
        btn:SetAllPoints(row)
        btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        btn:SetScript("OnEnter", function() rbg:SetVertexColor(C_OR[1], C_OR[2], C_OR[3], 0.12) end)
        btn:SetScript("OnLeave", function()
            rbg:SetVertexColor(row._r or 0, row._g or 0, row._b or 0, row._a or 0)
        end)
        row.btn = btn

        local arrow = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        arrow:SetPoint("LEFT", row, "LEFT", H_ARROW, 0)
        arrow:SetWidth(14)
        arrow:SetJustifyH("LEFT")
        row.arrow = arrow

        local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        lbl:SetPoint("LEFT",  row, "LEFT", H_LABEL, 0)
        lbl:SetPoint("RIGHT", row, "LEFT", H_BASE - 4, 0)
        lbl:SetJustifyH("LEFT")
        row.lbl = lbl

        local base = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        base:SetPoint("LEFT", row, "LEFT", H_BASE, 0)
        base:SetWidth(H_COL_W)
        base:SetJustifyH("RIGHT")
        row.base = base

        local total = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        total:SetPoint("LEFT", row, "LEFT", H_TOTAL, 0)
        total:SetWidth(H_COL_W)
        total:SetJustifyH("RIGHT")
        row.total = total

        local pct = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        pct:SetPoint("LEFT", row, "LEFT", H_PCT, 0)
        pct:SetWidth(H_COL_W)
        pct:SetJustifyH("RIGHT")
        row.pct = pct

        f.rows[i] = row
    end
end

-- ============================================================
-- Shared UI helpers (module-level; no upvalues from refresh state)
-- ============================================================

-- FmtCell: formats a stats table as "N  +X.X%" for popup rows.
-- Returns "—" when there are no crafts yet.
local function FmtCell(s)
    if not s or s.totalCrafts == 0 then return "—" end
    return string.format("%d  %s", s.totalCrafts, CalcPctGain(s))
end

local function SetRowBg(r, rr, gg, bb, aa)
    r._r, r._g, r._b, r._a = rr, gg, bb, aa
    r.rbg:SetVertexColor(rr, gg, bb, aa)
end

-- Combine per-group stats tables into one flat table for CalcPctGain.
local function CombineGroups(statsMap)
    local s = { totalCrafts = 0, totalPotions = 0, totalExtra = 0 }
    for _, g in ipairs(GROUPS_ORDER) do
        local gs = statsMap[g]
        if gs then
            s.totalCrafts  = s.totalCrafts  + gs.totalCrafts
            s.totalPotions = s.totalPotions + gs.totalPotions
            s.totalExtra   = s.totalExtra   + gs.totalExtra
        end
    end
    return s
end

-- Proc% for history rows: extra potions per craft attempt (as %)
local function CalcProcPct(s)
    if not s or s.totalCrafts == 0 then return "—" end
    return string.format("%.1f%%", s.totalExtra / s.totalCrafts * 100)
end

APT_RefreshHistory = function()
    if not APT_HistoryFrame or not APT_HistoryFrame:IsShown() then return end
    if not APT.db then return end

    local sc       = APT_HistoryFrame.sc
    local rows     = APT_HistoryFrame.rows
    local sessions = APT.db.char.sessions or {}

    for _, r in ipairs(rows) do
        r:Hide()
        r.btn:SetScript("OnClick", nil)
    end

    local rowIdx = 0
    local curY   = 0

    local function UseRow(height)
        rowIdx = rowIdx + 1
        local r = rows[rowIdx]
        if not r then return nil end
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT",  sc, "TOPLEFT",  0, -curY)
        r:SetPoint("TOPRIGHT", sc, "TOPRIGHT", 0, -curY)
        r:SetHeight(height or H_ROW)
        r.arrow:SetText("")
        r.arrow:SetTextColor(C_OR[1], C_OR[2], C_OR[3])
        r.lbl:ClearAllPoints()
        r.lbl:SetPoint("LEFT",  r, "LEFT", H_LABEL, 0)
        r.lbl:SetPoint("RIGHT", r, "LEFT", H_BASE - 4, 0)
        r.lbl:SetText("")
        r.lbl:SetTextColor(1, 1, 1)
        r.base:SetText("")  r.base:SetTextColor(1, 1, 1)
        r.total:SetText("") r.total:SetTextColor(1, 1, 1)
        r.pct:SetText("")   r.pct:SetTextColor(C_GRN[1], C_GRN[2], C_GRN[3])
        SetRowBg(r, 0, 0, 0, 0)
        r:Show()
        curY = curY + (height or H_ROW)
        return r
    end

    -- Overall Stats banner row (highlighted with orange left accent)
    local function AddOverallBanner(combined)
        local r = UseRow(22)
        if not r then return end
        local expanded = expandedSessions["overall"]
        r.arrow:SetText(expanded and "▼" or "▶")
        r.arrow:SetTextColor(C_OR[1], C_OR[2], C_OR[3])
        r.lbl:SetText("Overall Stats")
        r.lbl:SetTextColor(1, 1, 1)
        r.lbl:SetFont(r.lbl:GetFont(), select(2, r.lbl:GetFont()) or 12, "OUTLINE")
        if combined.totalCrafts > 0 then
            r.base:SetText(tostring(combined.totalCrafts))
            r.base:SetTextColor(1, 1, 1)
            r.total:SetText(tostring(combined.totalPotions))
            r.total:SetTextColor(1, 1, 1)
            r.pct:SetText(CalcProcPct(combined))
            r.pct:SetTextColor(C_GRN[1], C_GRN[2], C_GRN[3])
        end
        -- Orange-highlighted background
        SetRowBg(r, C_OR[1] * 0.18, C_OR[2] * 0.18, C_OR[3] * 0.18, 0.90)
        -- Orange left accent bar
        if not r._accent then
            local acc = r:CreateTexture(nil, "ARTWORK")
            acc:SetTexture("Interface\\BUTTONS\\WHITE8X8")
            acc:SetVertexColor(C_OR[1], C_OR[2], C_OR[3])
            acc:SetPoint("TOPLEFT",    r, "TOPLEFT",    0, 0)
            acc:SetPoint("BOTTOMLEFT", r, "BOTTOMLEFT", 0, 0)
            acc:SetWidth(3)
            r._accent = acc
        end
        r._accent:Show()
        local k = "overall"
        r.btn:SetScript("OnClick", function()
            expandedSessions[k] = not expandedSessions[k]
            APT_RefreshHistory()
        end)
    end

    local function AddSessionHeader(label, key, combined, sessObj)
        local r = UseRow()
        if not r then return end
        if r._accent then r._accent:Hide() end
        local expanded = expandedSessions[key]
        r.arrow:SetText(expanded and "▼" or "▶")
        r.arrow:SetTextColor(C_OR[1], C_OR[2], C_OR[3])
        -- Show custom name + date when set, otherwise the default label
        local displayLabel = (sessObj and sessObj.customName)
            and (sessObj.customName .. "  —  " .. (sessObj.date or ""))
            or label
        r.lbl:SetText(displayLabel)
        r.lbl:SetTextColor(C_OR[1], C_OR[2], C_OR[3])
        if combined.totalCrafts > 0 then
            r.base:SetText(tostring(combined.totalCrafts))
            r.base:SetTextColor(C_OR[1], C_OR[2], C_OR[3])
            r.total:SetText(tostring(combined.totalPotions))
            r.total:SetTextColor(C_OR[1], C_OR[2], C_OR[3])
            r.pct:SetText(CalcProcPct(combined))
            r.pct:SetTextColor(C_GRN[1], C_GRN[2], C_GRN[3])
        end
        SetRowBg(r, 0.12, 0.09, 0.04, 0.70)
        local k = key
        local so = sessObj
        r.btn:SetScript("OnClick", function(_, mouseBtn)
            if mouseBtn == "RightButton" and so then
                ShowRenameDialog(so)
            else
                expandedSessions[k] = not expandedSessions[k]
                APT_RefreshHistory()
            end
        end)
    end

    local function AddGroupHeader(groupName, s)
        local r = UseRow()
        if not r then return end
        if r._accent then r._accent:Hide() end
        r.lbl:ClearAllPoints()
        r.lbl:SetPoint("LEFT",  r, "LEFT", H_LABEL + 10, 0)
        r.lbl:SetPoint("RIGHT", r, "LEFT", H_BASE - 4,   0)
        r.lbl:SetText(groupName)
        r.lbl:SetTextColor(0.75, 0.75, 0.75)
        r.base:SetText(tostring(s.totalCrafts))
        r.base:SetTextColor(0.75, 0.75, 0.75)
        r.total:SetText(tostring(s.totalPotions))
        r.total:SetTextColor(0.75, 0.75, 0.75)
        r.pct:SetText(CalcProcPct(s))
        r.pct:SetTextColor(C_GRN[1], C_GRN[2], C_GRN[3])
        SetRowBg(r, 0.10, 0.10, 0.10, 0.50)
    end

    local function AddItemRow(it)
        local r = UseRow()
        if not r then return end
        if r._accent then r._accent:Hide() end
        r.lbl:ClearAllPoints()
        r.lbl:SetPoint("LEFT",  r, "LEFT", H_LABEL + 22, 0)
        r.lbl:SetPoint("RIGHT", r, "LEFT", H_BASE - 4,   0)
        r.lbl:SetText(it.name)
        r.lbl:SetTextColor(0.65, 0.65, 0.65)
        r.base:SetText(tostring(it.totalCrafts))
        r.base:SetTextColor(0.65, 0.65, 0.65)
        r.total:SetText(tostring(it.totalPotions))
        r.total:SetTextColor(0.65, 0.65, 0.65)
        r.pct:SetText(CalcProcPct(it))
        r.pct:SetTextColor(C_GRN[1], C_GRN[2], C_GRN[3])
    end

    local function AddTotalRow(combined)
        local r = UseRow()
        if not r then return end
        if r._accent then r._accent:Hide() end
        r.lbl:ClearAllPoints()
        r.lbl:SetPoint("LEFT",  r, "LEFT", H_LABEL + 10, 0)
        r.lbl:SetPoint("RIGHT", r, "LEFT", H_BASE - 4,   0)
        r.lbl:SetText("Total")
        r.lbl:SetTextColor(0.55, 0.55, 0.55)
        r.base:SetText(tostring(combined.totalCrafts))
        r.base:SetTextColor(0.55, 0.55, 0.55)
        r.total:SetText(tostring(combined.totalPotions))
        r.total:SetTextColor(0.55, 0.55, 0.55)
        r.pct:SetText(CalcProcPct(combined))
        r.pct:SetTextColor(C_GRN[1], C_GRN[2], C_GRN[3])
        SetRowBg(r, 0.08, 0.07, 0.03, 0.50)
    end

    local function RenderGroupItems(s)
        if not s.items then return end
        local sorted = {}
        for _, it in pairs(s.items) do sorted[#sorted + 1] = it end
        table.sort(sorted, function(a, b) return a.name < b.name end)
        for _, it in ipairs(sorted) do AddItemRow(it) end
    end

    -- ── Overall Stats banner (top) ────────────────────────────
    local ovMap = {}
    for _, g in ipairs(GROUPS_ORDER) do
        ovMap[g] = APT.db.char.stats[g] and APT.db.char.stats[g].overall
    end
    local combinedOv = CombineGroups(ovMap)
    AddOverallBanner(combinedOv)
    if expandedSessions["overall"] then
        for _, g in ipairs(GROUPS_ORDER) do
            local ov = ovMap[g]
            if ov and ov.totalCrafts > 0 then
                AddGroupHeader(g, ov)
            end
        end
        AddTotalRow(combinedOv)
    end
    curY = curY + 4

    -- ── Past sessions (newest first) ──────────────────────────
    for i, sess in ipairs(sessions) do
        local key      = "sid_" .. (sess.id or i)
        local combined = CombineGroups(sess.stats or {})
        AddSessionHeader(string.format("Session %d  —  %s", i, sess.date), key, combined, sess)
        if expandedSessions[key] then
            for _, g in ipairs(GROUPS_ORDER) do
                local s = sess.stats and sess.stats[g]
                if s and s.totalCrafts > 0 then
                    AddGroupHeader(g, s)
                    RenderGroupItems(s)
                end
            end
            AddTotalRow(combined)
            curY = curY + 4
        end
    end

    sc:SetHeight(math.max(curY + 8, 10))
    if APT_HistoryFrame.UpdateScrollbar then APT_HistoryFrame.UpdateScrollbar() end
end

-- ============================================================
-- CreateUI
-- Builds the stats window once on OnInitialize. Hidden by default.
-- ============================================================

local function CreateUI()
    local W, H  = 380, 250
    local ROW_H = 18
    local PAD   = 12   -- left/right inner padding

    local f = CreateFrame("Frame", "AlchemyProcTrackerFrame", UIParent, "BackdropTemplate")
    -- Default: right edge sits just left of screen centre; restored from DB if moved before.
    local wp = APT.db.char.windowPos
    f:SetSize(wp and wp.w or W, wp and wp.h or H)
    if wp then
        f:SetPoint(wp.point, UIParent, wp.relPoint or wp.point, wp.x, wp.y)
    else
        f:SetPoint("TOPRIGHT", UIParent, "CENTER", -10, 200)
    end
    f._defW, f._defH = W, H

    f:SetFrameStrata("HIGH")
    f:SetMovable(true)
    f:SetResizable(true)
    f:SetToplevel(true)   -- auto-raise above sibling frames on click
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        local point, _, relPoint, x, y = f:GetPoint()
        APT.db.char.windowPos = { point=point, relPoint=relPoint, x=x, y=y,
                                  w=f:GetWidth(), h=f:GetHeight() }
    end)
    f:SetClampedToScreen(true)
    f:Hide()
    APT_Frame = f

    -- Enforce minimum size live during drag
    local _mClamp = false
    f:SetScript("OnSizeChanged", function(self, w, h)
        if _mClamp then return end
        local nw = math.max(w, W)
        local nh = math.max(h, H)
        if nw ~= w or nh ~= h then
            _mClamp = true
            self:SetSize(nw, nh)
            _mClamp = false
        end
    end)

    -- Outer background  (bg-neutral-900)
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(f)
    bg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
    bg:SetVertexColor(0.09, 0.09, 0.09)
    bg:SetAlpha(0.97)

    -- Orange border  (border-amber-700/60)
    DrawBorders(f)

    -- Header strip  (bg-neutral-950/60, slightly darker)
    local hdrBg = f:CreateTexture(nil, "BACKGROUND")
    hdrBg:SetPoint("TOPLEFT",  f, "TOPLEFT",  1, -1)
    hdrBg:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, -1)
    hdrBg:SetHeight(28)
    hdrBg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
    hdrBg:SetVertexColor(0.04, 0.04, 0.04)

    -- Close button inside header
    MakeFrameCloseButton(f)

    local curY = -7

    -- Title  (text-amber-400 bold)
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, curY)
    title:SetText("Alchemy Proc Tracker")
    title:SetTextColor(1, 0.76, 0.18)

    curY = curY - 28

    -- Divider below header  (border-amber-900/40)
    MakeDivider(f, 1, curY, -1)
    curY = curY - 10

    -- Session label row
    local sessLbl = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sessLbl:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, curY)
    sessLbl:SetText("Session:")
    sessLbl:SetTextColor(0.60, 0.60, 0.60)   -- neutral-400

    local sessVal = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sessVal:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, curY)
    sessVal:SetJustifyH("RIGHT")
    sessVal:SetText("Current Session")
    sessVal:SetTextColor(1, 1, 1)
    curY = curY - ROW_H

    -- Sub-divider  (border-amber-900/20, very faint)
    local subdiv = f:CreateTexture(nil, "ARTWORK")
    subdiv:SetPoint("TOPLEFT",  f, "TOPLEFT",  PAD, curY - 3)
    subdiv:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, curY - 3)
    subdiv:SetHeight(1)
    subdiv:SetTexture("Interface\\BUTTONS\\WHITE8X8")
    subdiv:SetVertexColor(0.40, 0.22, 0.03, 0.22)
    curY = curY - 12

    -- Proc-tier rows
    local PROC_ROWS = {
        { key = "BASE", label = "Base Craft:" },
        { key = "X2",   label = "x2:"         },
        { key = "X3",   label = "x3:"         },
        { key = "X4",   label = "x4:"         },
        { key = "X5",   label = "x5:"         },
    }

    for _, row in ipairs(PROC_ROWS) do
        local lbl = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, curY)
        lbl:SetText(row.label)
        lbl:SetTextColor(0.76, 0.76, 0.76)   -- neutral-300

        local val = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        val:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, curY)
        val:SetJustifyH("RIGHT")
        val:SetText("0")
        val:SetTextColor(1, 1, 1)

        APT_Lines[row.key] = { val = val }
        curY = curY - ROW_H
    end

    -- Divider above totals  (border-amber-900/40)
    curY = curY - 4
    MakeDivider(f, PAD, curY, -PAD)
    curY = curY - 10

    -- Total Crafts
    local tcLbl = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tcLbl:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, curY)
    tcLbl:SetText("Total Crafts:")
    tcLbl:SetTextColor(0.60, 0.60, 0.60)

    local tcVal = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    tcVal:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, curY)
    tcVal:SetJustifyH("RIGHT")
    tcVal:SetText("0")
    tcVal:SetTextColor(1, 1, 1)
    APT_Lines["TOTAL_CRAFTS"] = { val = tcVal }
    curY = curY - ROW_H

    -- Total Items
    local tiLbl = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tiLbl:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, curY)
    tiLbl:SetText("Total Items:")
    tiLbl:SetTextColor(0.60, 0.60, 0.60)

    local tiVal = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    tiVal:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, curY)
    tiVal:SetJustifyH("RIGHT")
    tiVal:SetText("0")
    tiVal:SetTextColor(1, 1, 1)
    APT_Lines["TOTAL_ITEMS"] = { val = tiVal }
    curY = curY - ROW_H

    -- % Gain  (text-emerald-400 on both label and value)
    local pgLbl = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pgLbl:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, curY)
    pgLbl:SetText("% Gain:")
    pgLbl:SetTextColor(C_GRN[1], C_GRN[2], C_GRN[3])

    local pgVal = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    pgVal:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, curY)
    pgVal:SetJustifyH("RIGHT")
    pgVal:SetText("0.0%")
    pgVal:SetTextColor(C_GRN[1], C_GRN[2], C_GRN[3])
    APT_Lines["PCT_GAIN"] = { val = pgVal }

    -- Resize grip (bottom-right corner); saves size + position when done
    local grip = CreateFrame("Button", nil, f)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function()
        f:StopMovingOrSizing()
        local point, _, relPoint, x, y = f:GetPoint()
        APT.db.char.windowPos = { point=point, relPoint=relPoint, x=x, y=y,
                                  w=f:GetWidth(), h=f:GetHeight() }
    end)
end

-- ============================================================
-- CombineAllStats
-- Merges all groups into one stat table for a given scope.
-- ============================================================

local function CombineAllStats(scope)
    local c = { totalCrafts=0, totalPotions=0, totalExtra=0,
                procs1=0, procs2=0, procs3=0, procs4=0 }
    for _, g in ipairs(GROUPS_ORDER) do
        local s = APT.db.char.stats[g] and APT.db.char.stats[g][scope]
        if s then
            c.totalCrafts  = c.totalCrafts  + s.totalCrafts
            c.totalPotions = c.totalPotions + s.totalPotions
            c.totalExtra   = c.totalExtra   + s.totalExtra
            c.procs1       = c.procs1       + s.procs1
            c.procs2       = c.procs2       + s.procs2
            c.procs3       = c.procs3       + s.procs3
            c.procs4       = c.procs4       + s.procs4
        end
    end
    return c
end

-- ============================================================
-- APT_RefreshUI
-- Populates the proc-tier breakdown table from session stats.
--   Session  = craft count per tier this session
--   Overall  = potions produced from that tier this session
--   % Craft  = tier's share of total session craft attempts
--   TOTAL %  = totalPotions / noProc_crafts * 100 (yield efficiency)
-- ============================================================

APT_RefreshUI = function()
    if not APT_Frame or not APT_Frame:IsShown() then return end

    local sess   = CombineAllStats("session")
    local tc     = sess.totalCrafts
    local noProc = tc - sess.procs1 - sess.procs2 - sess.procs3 - sess.procs4

    -- Per-tier craft counts
    local tiers = {
        { key = "BASE", count = noProc       },
        { key = "X2",   count = sess.procs1  },
        { key = "X3",   count = sess.procs2  },
        { key = "X4",   count = sess.procs3  },
        { key = "X5",   count = sess.procs4  },
    }
    for _, t in ipairs(tiers) do
        local line = APT_Lines[t.key]
        if line then line.val:SetText(tostring(t.count)) end
    end

    -- Total Crafts
    if APT_Lines["TOTAL_CRAFTS"] then
        APT_Lines["TOTAL_CRAFTS"].val:SetText(tostring(tc))
    end

    -- Total Items  (sum of count × multiplier per tier)
    local totalItems = noProc
                     + sess.procs1 * 2
                     + sess.procs2 * 3
                     + sess.procs3 * 4
                     + sess.procs4 * 5
    if APT_Lines["TOTAL_ITEMS"] then
        APT_Lines["TOTAL_ITEMS"].val:SetText(tostring(totalItems))
    end

    -- % Gain = (totalItems - noProc) / noProc * 100
    -- matches React formula: ((overallTotal - baseCraft) / baseCraft) * 100
    if APT_Lines["PCT_GAIN"] then
        if noProc > 0 then
            local pct = (totalItems - noProc) / noProc * 100
            APT_Lines["PCT_GAIN"].val:SetText(string.format("%.1f%%", pct))
        else
            APT_Lines["PCT_GAIN"].val:SetText("0.0%")
        end
    end
end

-- ============================================================
-- Options Panel (AceConfig-3.0 + AceConfigDialog-3.0)
-- Registers under Interface > AddOns > Alchemy Tracker.
-- ============================================================

local function OpenOptions()
    local AceConfigDialog = LibStub("AceConfigDialog-3.0", true)
    if AceConfigDialog then
        AceConfigDialog:Open("AlchemyTracker")
    end
end

-- ============================================================
-- Helpers for options panel stats display
-- ============================================================

-- Group summary line: name, base crafts, proc chance.
local function FormatGroupSummary(s, groupName)
    if s.totalCrafts == 0 then
        return string.format("|cffffd700%s:|r  No data", groupName)
    end
    return string.format("|cffffd700%s:|r  %d crafts  •  %s proc chance",
        groupName, s.totalCrafts, CalcPctGain(s))
end

local function BuildOverallDescription()
    if not APT.db then return "" end
    local lines = {}
    for _, g in ipairs(GROUPS_ORDER) do
        local gs = APT.db.char.stats[g]
        if gs then
            lines[#lines + 1] = FormatGroupSummary(gs.overall, g)
        end
    end
    return table.concat(lines, "\n")
end

-- ============================================================
-- RegisterOptions
-- ============================================================

local function RegisterOptions()
    local AceConfig       = LibStub("AceConfig-3.0", true)
    local AceConfigDialog = LibStub("AceConfigDialog-3.0", true)
    if not AceConfig or not AceConfigDialog then return end

    local options = {
        type = "group",
        name = "Alchemy Tracker",
        args = {
            -- ── Window ──────────────────────────────────────────
            windowHeader = {
                type  = "header",
                name  = "Window",
                order = 1,
            },
            toggleWindow = {
                type  = "execute",
                name  = function()
                    return (APT_Frame and APT_Frame:IsShown()) and "Hide Stats Window" or "Show Stats Window"
                end,
                func  = function()
                    if APT_Frame then
                        if APT_Frame:IsShown() then APT_Frame:Hide()
                        else APT_Frame:Show(); APT_RefreshUI()
                        end
                    end
                end,
                order = 2,
            },

            -- ── Overall Stats ────────────────────────────────────
            overallHeader = {
                type  = "header",
                name  = "Overall Stats",
                order = 10,
            },
            overallDesc = {
                type     = "description",
                name     = function() return BuildOverallDescription() end,
                fontSize = "medium",
                order    = 11,
            },

            -- ── Session History ──────────────────────────────────
            sessionHeader = {
                type  = "header",
                name  = "Session History",
                order = 20,
            },
            browseHistory = {
                type  = "execute",
                name  = function()
                    local n = APT.db and APT.db.char.sessions and #APT.db.char.sessions or 0
                    return string.format("Browse Session History  (%d saved)", n)
                end,
                desc  = "Open the session history browser  (/apt history)",
                func  = function()
                    if APT_HistoryFrame then
                        APT_HistoryFrame:Show()
                        APT_RefreshHistory()
                    end
                end,
                order = 21,
            },

            -- ── Reset ────────────────────────────────────────────
            resetHeader = {
                type  = "header",
                name  = "Reset",
                order = 30,
            },
            resetSession = {
                type  = "execute",
                name  = "Reset Session Stats",
                desc  = "Save current session to history and reset session stats (overall is kept)  (/apt reset)",
                func  = function() ResetSessionStats() end,
                order = 31,
            },
            resetAll = {
                type        = "execute",
                name        = "Reset All Stats",
                desc        = "Reset ALL stats including overall — session history is kept  (/apt reset all)",
                confirm     = true,
                confirmText = "Are you sure you want to reset ALL stats, including overall? Session history will be kept.",
                func        = function() ResetAllStats() end,
                order       = 32,
            },

            -- ── Interface ────────────────────────────────────────
            interfaceHeader = {
                type  = "header",
                name  = "Interface",
                order = 40,
            },
            minimapButton = {
                type  = "toggle",
                name  = "Show Minimap Button",
                desc  = "Show or hide the minimap button",
                get   = function() return not APT.db.global.minimap.hide end,
                set   = function(_, val)
                    APT.db.global.minimap.hide = not val
                    local LibDBIcon = LibStub("LibDBIcon-1.0", true)
                    if LibDBIcon then
                        if val then LibDBIcon:Show("AlchemyTracker")
                        else        LibDBIcon:Hide("AlchemyTracker")
                        end
                    end
                end,
                order = 41,
            },
            debugMode = {
                type  = "toggle",
                name  = "Debug Mode",
                desc  = "Enable debug chat output for craft events  (/apt debug)",
                get   = function() return debugMode end,
                set   = function(_, val) debugMode = val end,
                order = 42,
            },
        },
    }

    AceConfig:RegisterOptionsTable("AlchemyTracker", options)
    AceConfigDialog:AddToBlizOptions("AlchemyTracker", "Alchemy Tracker")
end

-- ============================================================
-- Minimap Right-Click Dropdown
-- ============================================================

local APT_MinimapMenuFrame

local function ShowMinimapMenu(anchor)
    if not APT_MinimapMenuFrame then
        APT_MinimapMenuFrame = CreateFrame("Frame", "APT_MinimapMenuFrame", UIParent, "UIDropDownMenuTemplate")
    end

    UIDropDownMenu_Initialize(APT_MinimapMenuFrame, function()
        local info

        info = UIDropDownMenu_CreateInfo()
        info.text = "Alchemy Tracker"
        info.isTitle = true
        info.notCheckable = true
        UIDropDownMenu_AddButton(info)

        info = UIDropDownMenu_CreateInfo()
        info.text = "Show Stats Window"
        info.notCheckable = true
        info.func = function()
            if APT_Frame then APT_Frame:Show(); APT_RefreshUI() end
            CloseDropDownMenus()
        end
        UIDropDownMenu_AddButton(info)

        info = UIDropDownMenu_CreateInfo()
        info.text = "Hide Stats Window"
        info.notCheckable = true
        info.func = function()
            if APT_Frame then APT_Frame:Hide() end
            CloseDropDownMenus()
        end
        UIDropDownMenu_AddButton(info)

        info = UIDropDownMenu_CreateInfo()
        info.text = "Session History"
        info.notCheckable = true
        info.func = function()
            if APT_HistoryFrame then
                APT_HistoryFrame:Show()
                APT_RefreshHistory()
            end
            CloseDropDownMenus()
        end
        UIDropDownMenu_AddButton(info)

        info = UIDropDownMenu_CreateInfo()
        info.text = "Reset"
        info.isTitle = true
        info.notCheckable = true
        UIDropDownMenu_AddButton(info)

        info = UIDropDownMenu_CreateInfo()
        info.text = "Reset Session Stats"
        info.notCheckable = true
        info.func = function()
            ResetSessionStats()
            CloseDropDownMenus()
        end
        UIDropDownMenu_AddButton(info)

        info = UIDropDownMenu_CreateInfo()
        info.text = "Reset All Stats"
        info.notCheckable = true
        info.func = function()
            ResetAllStats()
            CloseDropDownMenus()
        end
        UIDropDownMenu_AddButton(info)

        info = UIDropDownMenu_CreateInfo()
        info.text = "Open Options"
        info.notCheckable = true
        info.func = function()
            OpenOptions()
            CloseDropDownMenus()
        end
        UIDropDownMenu_AddButton(info)
    end, "MENU")

    ToggleDropDownMenu(1, nil, APT_MinimapMenuFrame, anchor, 0, 0)
end

-- ============================================================
-- Minimap Button (LibDBIcon-1.0 + LibDataBroker-1.1)
-- These are not part of Ace3 — embed them separately if needed.
-- The `true` second arg to LibStub silences the error if missing.
-- Created inside OnInitialize to follow Ace3 lifecycle conventions.
-- ============================================================

local function RegisterMinimapButton()
    local ldbLib    = LibStub("LibDataBroker-1.1", true)
    local LibDBIcon = LibStub("LibDBIcon-1.0", true)
    if not ldbLib or not LibDBIcon then return end

    local ldb = ldbLib:NewDataObject("AlchemyTracker", {
        type = "launcher",
        text = "Alchemy Tracker",
        icon = "Interface\\AddOns\\AlchemyTracker\\icon\\alchemy-300x300CroppedExtracted_uncompressed",
        OnClick = function(self, button)
            if button == "RightButton" then
                ShowMinimapMenu(self)
            else
                if APT_Frame then
                    if APT_Frame:IsShown() then
                        APT_Frame:Hide()
                    else
                        APT_Frame:Show()
                        APT_RefreshUI()
                    end
                end
            end
        end,
        OnTooltipShow = function(tooltip)
            tooltip:AddLine("Alchemy Tracker")
            tooltip:AddLine("Left-click to toggle stats window", 1, 1, 1)
            tooltip:AddLine("Right-click for options menu", 1, 1, 1)
        end,
    })

    LibDBIcon:Register("AlchemyTracker", ldb, APT.db.global.minimap)
end

-- ============================================================
-- Slash Command Handler (registered via AceConsole)
-- ============================================================

function APT:HandleSlashCommand(input)
    local cmd      = input:match("^%s*(.-)%s*$")
    local cmdLower = cmd:lower()

    if cmdLower == "" or cmdLower == "help" then
        local _meta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
        local ver   = (_meta and _meta(ADDON_NAME, "Version")) or "?"
        self:Print(string.format("v%s — TBC Classic alchemy mastery proc tracker", ver))
        self:Print("  |cffffd700/apt|r                                    — show this help")
        self:Print("  |cffffd700/apt show|r                               — open the stats window")
        self:Print("  |cffffd700/apt hide|r                               — close the stats window")
        self:Print("  |cffffd700/apt reset|r                              — reset session stats (overall kept)")
        self:Print("  |cffffd700/apt reset all|r                          — reset ALL stats including overall")
        self:Print("  |cffffd700/apt history|r                            — open the session history browser")
        self:Print("  |cffffd700/apt testdata|r                           — inject fake data for UI preview")
        self:Print("  |cffffd700/apt resetpos|r                           — reset window positions to default")

    elseif cmdLower == "resetpos" then
        APT.db.char.windowPos  = false
        APT.db.char.historyPos = false
        if APT_Frame then
            APT_Frame:SetSize(APT_Frame._defW or 380, APT_Frame._defH or 250)
            APT_Frame:ClearAllPoints()
            APT_Frame:SetPoint("TOPRIGHT", UIParent, "CENTER", -10, 200)
        end
        if APT_HistoryFrame then
            APT_HistoryFrame:SetSize(APT_HistoryFrame._defW or 500, APT_HistoryFrame._defH or 440)
            APT_HistoryFrame:ClearAllPoints()
            APT_HistoryFrame:SetPoint("TOPLEFT", UIParent, "CENTER", 10, 200)
        end
        self:Print("Window positions reset.")

    elseif cmdLower == "show" then
        if APT_Frame then
            APT_Frame:Show()
            APT_RefreshUI()
        end

    elseif cmdLower == "hide" then
        if APT_Frame then APT_Frame:Hide() end

    elseif cmdLower == "reset" then
        ResetSessionStats()

    elseif cmdLower == "reset all" then
        ResetAllStats()

    elseif cmdLower == "history" then
        if APT_HistoryFrame then
            APT_HistoryFrame:Show()
            APT_RefreshHistory()
        end

    elseif cmdLower == "debug" then
        debugMode = not debugMode
        self:Print("Debug mode: " .. (debugMode and "|cff00ff00ON|r — craft now to see event/message in chat." or "|cffff4444OFF|r"))

    elseif cmdLower == "testdata" then
        -- Inject fake data so the UI can be previewed without real crafting.
        local fakeItems = {
            FLASK    = { { name="Flask of Supreme Power",   totalCrafts=18, totalPotions=26, totalExtra=8  },
                         { name="Flask of Distilled Wisdom",totalCrafts=12, totalPotions=16, totalExtra=4  } },
            ELIXIR   = { { name="Elixir of the Mongoose",  totalCrafts=25, totalPotions=34, totalExtra=9  },
                         { name="Greater Arcane Elixir",   totalCrafts=10, totalPotions=13, totalExtra=3  } },
            POTION   = { { name="Major Healing Potion",    totalCrafts=30, totalPotions=42, totalExtra=12 },
                         { name="Major Mana Potion",       totalCrafts=20, totalPotions=27, totalExtra=7  } },
            TRANSMUTE= { { name="Arcanite Bar",            totalCrafts= 5, totalPotions= 7, totalExtra=2  } },
        }
        local function makeStats(mult)
            local out = {}
            for _, g in ipairs(GROUPS_ORDER) do
                local items = {}
                local tc, tp, te = 0, 0, 0
                for _, it in ipairs(fakeItems[g] or {}) do
                    local itc = math.floor(it.totalCrafts * mult)
                    local itp = math.floor(it.totalPotions * mult)
                    local ite = math.floor(it.totalExtra * mult)
                    items[it.name] = { name=it.name, totalCrafts=itc, totalPotions=itp, totalExtra=ite }
                    tc = tc + itc;  tp = tp + itp;  te = te + ite
                end
                out[g] = { totalCrafts=tc, totalPotions=tp, totalExtra=te, items=items }
            end
            return out
        end

        -- Current session stats (drives the main window)
        local sessStats = makeStats(1)
        for _, g in ipairs(GROUPS_ORDER) do
            APT.db.char.stats[g] = APT.db.char.stats[g] or {}
            local s = sessStats[g]
            APT.db.char.stats[g].session = {
                totalCrafts=s.totalCrafts, totalPotions=s.totalPotions, totalExtra=s.totalExtra,
                procs1=math.floor(s.totalCrafts*0.20), procs2=math.floor(s.totalCrafts*0.08),
                procs3=math.floor(s.totalCrafts*0.02), procs4=0,
            }
            local ov = makeStats(4)[g]
            APT.db.char.stats[g].overall = {
                totalCrafts=ov.totalCrafts, totalPotions=ov.totalPotions, totalExtra=ov.totalExtra,
                procs1=math.floor(ov.totalCrafts*0.20), procs2=math.floor(ov.totalCrafts*0.08),
                procs3=math.floor(ov.totalCrafts*0.02), procs4=0,
            }
        end

        -- Three fake past sessions
        APT.db.char.sessions = {}
        local dates = { "2026-03-09", "2026-03-10", "2026-03-11" }
        local names = { nil, "Flask Farm Run", nil }   -- session 2 has a custom name
        for i = 1, 3 do
            local s = makeStats(0.5 + i * 0.3)
            table.insert(APT.db.char.sessions, {
                id         = i,
                date       = dates[i],
                customName = names[i],
                stats      = s,
            })
        end

        -- Reset positions and sizes so windows open side by side
        APT.db.char.windowPos  = false
        APT.db.char.historyPos = false
        if APT_Frame then
            APT_Frame:SetSize(APT_Frame._defW or 380, APT_Frame._defH or 250)
            APT_Frame:ClearAllPoints()
            APT_Frame:SetPoint("TOPRIGHT", UIParent, "CENTER", -10, 200)
            APT_Frame:Show()
        end
        if APT_HistoryFrame then
            APT_HistoryFrame:SetSize(APT_HistoryFrame._defW or 500, APT_HistoryFrame._defH or 440)
            APT_HistoryFrame:ClearAllPoints()
            APT_HistoryFrame:SetPoint("TOPLEFT", UIParent, "CENTER", 10, 200)
            APT_HistoryFrame:Show()
        end
        APT_RefreshUI()
        APT_RefreshHistory()
        self:Print("Test data injected. Windows repositioned side by side.")

    else
        self:Print("Unknown command. Type /apt for help.")
    end
end

-- ============================================================
-- AceAddon Lifecycle
-- ============================================================

function APT:OnInitialize()
    -- AceDB sets up SavedVariables with defaults and per-char scoping.
    self.db = LibStub("AceDB-3.0"):New("AlchemyProcTrackerDB", defaults, true)

    -- Backwards-compat: existing chars won't have sessions from the default table.
    if not self.db.char.sessions then self.db.char.sessions = {} end

    BuildTrackedItemLookup()
    CreateUI()
    CreateHistoryUI()
    RegisterMinimapButton()
    RegisterOptions()
    self:RegisterChatCommand("apt", "HandleSlashCommand")
end

function APT:OnEnable()
    DetectAlchemySpecialization()

    self:RegisterEvent("PLAYER_LOGIN",        "OnPlayerLogin")
    self:RegisterEvent("TRADE_SKILL_SHOW",    "OnTradeSkillShow")
    self:RegisterEvent("SKILL_LINES_CHANGED", "OnSkillLinesChanged")
    self:RegisterEvent("CHAT_MSG_SYSTEM",     "OnChatMessage")
    self:RegisterEvent("CHAT_MSG_SKILL",      "OnChatMessage")
    self:RegisterEvent("CHAT_MSG_LOOT",       "OnChatMessage")
    self:RegisterEvent("TRADE_SKILL_CLOSE",   "OnTradeSkillClose")

    self:Print("Loaded. Type /apt for help.")
end

-- ============================================================
-- Event Handlers
-- ============================================================

function APT:OnPlayerLogin()
    if DetectAlchemySpecialization() then
        self:UnregisterEvent("SKILL_LINES_CHANGED")
    end
end

function APT:OnTradeSkillShow()
    -- Cancel the inactivity timer; window is open again.
    if sessionTimer then
        sessionTimer:Cancel()
        sessionTimer = nil
    end

    -- If the 15-min timeout already fired, start a fresh session now.
    if sessionClosed then
        sessionClosed = false
        ResetSessionStats()
        APT:Print("New session started (previous session expired).")
    end

    if DetectAlchemySpecialization() then
        self:UnregisterEvent("SKILL_LINES_CHANGED")
    end
end

function APT:OnSkillLinesChanged()
    if DetectAlchemySpecialization() then
        self:UnregisterEvent("SKILL_LINES_CHANGED")
    end
end

function APT:OnChatMessage(event, msg)
    if debugMode then
        self:Print(string.format("|cffaaaaaa[DEBUG] event=%s msg=%s|r", event, msg or "nil"))
    end

    if event == "CHAT_MSG_LOOT" then
        -- Proc extra items arrive as loot messages. Only care if a craft is in progress.
        if currentCraft then
            local amount, link = ParseLootMessage(msg)
            if amount then
                local itemID = ParseItemIDFromLink(link)
                if itemID and itemID == currentCraft.itemID then
                    currentCraft.totalCreated = currentCraft.totalCreated + amount
                    ScheduleCraftFinalize()
                end
            end
        end
    else
        -- CHAT_MSG_SKILL / CHAT_MSG_SYSTEM: "You create ..." messages
        HandleCraftEvent(msg)
    end
end

function APT:OnTradeSkillClose()
    -- Finalize any pending craft immediately when the window closes.
    CancelCraftTimer()
    FinalizeCraft()

    -- Start the 15-minute inactivity timer.
    if sessionTimer then sessionTimer:Cancel() end
    sessionTimer = C_Timer.NewTimer(SESSION_TIMEOUT, function()
        sessionTimer  = nil
        sessionClosed = true  -- session will reset on next TRADE_SKILL_SHOW
    end)
end
