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

local displayGroup = "ELIXIR"
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
-- Session History Browser
-- Collapsible tree: Sessions → Groups → Items, plus Overall.
-- ============================================================

local APT_HistoryFrame
local expandedSessions = {}

local H_W        = 480
local H_H        = 420
local H_ROW      = 18
local H_ARROW    = 8
local H_LABEL    = 26
local H_BASE     = 290
local H_TOTAL    = 348
local H_PCT      = 400
local H_COL_W    = 52
local H_MAX_ROWS = 120

local function CreateHistoryUI()
    local f = CreateFrame("Frame", "APT_HistoryFrame", UIParent, "BackdropTemplate")
    f:SetSize(H_W, H_H)
    f:SetPoint("CENTER")
    f:SetFrameStrata("HIGH")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop",  f.StopMovingOrSizing)
    f:SetClampedToScreen(true)
    f:Hide()
    APT_HistoryFrame = f

    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(f)
    bg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
    bg:SetVertexColor(0.08, 0.10, 0.20)
    bg:SetAlpha(0.95)
    f:SetBackdrop({
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        edgeSize = 16,
        insets   = { left = 4, right = 4, top = 4, bottom = 4 },
    })

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", f, "TOP", 0, -10)
    title:SetText("Session History")
    title:SetTextColor(1, 0.85, 0)

    local function MakeColHead(txt, x)
        local fs = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("TOPLEFT", f, "TOPLEFT", x, -32)
        fs:SetWidth(H_COL_W)
        fs:SetJustifyH("RIGHT")
        fs:SetTextColor(0.9, 0.8, 0.1)
        fs:SetText(txt)
    end
    MakeColHead("Base",  H_BASE)
    MakeColHead("Total", H_TOTAL)
    MakeColHead("Proc%", H_PCT)

    local div = f:CreateTexture(nil, "ARTWORK")
    div:SetPoint("TOPLEFT",  f, "TOPLEFT",  8,   -44)
    div:SetPoint("TOPRIGHT", f, "TOPRIGHT", -24, -44)
    div:SetHeight(1)
    div:SetTexture("Interface\\BUTTONS\\WHITE8X8")
    div:SetVertexColor(0.4, 0.4, 0.5, 0.6)

    local sf = CreateFrame("ScrollFrame", "APT_HistorySF", f, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT",     f, "TOPLEFT",     8,  -48)
    sf:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -24,  8)
    f.sf = sf

    local sc = CreateFrame("Frame", "APT_HistorySC", sf)
    sc:SetSize(sf:GetWidth() or (H_W - 40), 10)
    sf:SetScrollChild(sc)
    f.sc = sc

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)

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
        btn:SetScript("OnEnter", function() rbg:SetVertexColor(0.3, 0.3, 0.6, 0.25) end)
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
-- History UI helpers (module-level; no upvalues from refresh state)
-- ============================================================

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
        r.arrow:SetTextColor(1, 1, 1)
        r.lbl:ClearAllPoints()
        r.lbl:SetPoint("LEFT",  r, "LEFT", H_LABEL, 0)
        r.lbl:SetPoint("RIGHT", r, "LEFT", H_BASE - 4, 0)
        r.lbl:SetText("")
        r.lbl:SetTextColor(1, 1, 1)
        r.base:SetText("")  r.base:SetTextColor(1, 1, 1)
        r.total:SetText("") r.total:SetTextColor(1, 1, 1)
        r.pct:SetText("")   r.pct:SetTextColor(1, 1, 1)
        SetRowBg(r, 0, 0, 0, 0)
        r:Show()
        curY = curY + (height or H_ROW)
        return r
    end

    local function AddSessionHeader(label, key, combined)
        local r = UseRow()
        if not r then return end
        local expanded = expandedSessions[key]
        r.arrow:SetText(expanded and "▼" or "▶")
        r.arrow:SetTextColor(1, 0.85, 0)
        r.lbl:SetText(label)
        r.lbl:SetTextColor(1, 0.85, 0)
        if combined.totalCrafts > 0 then
            r.base:SetText(tostring(combined.totalCrafts))
            r.base:SetTextColor(1, 0.85, 0)
            r.pct:SetText(CalcPctGain(combined))
            r.pct:SetTextColor(1, 0.85, 0)
        end
        SetRowBg(r, 0.14, 0.16, 0.32, 0.8)
        local k = key
        r.btn:SetScript("OnClick", function()
            expandedSessions[k] = not expandedSessions[k]
            APT_RefreshHistory()
        end)
    end

    local function AddGroupHeader(groupName, s)
        local r = UseRow()
        if not r then return end
        r.lbl:ClearAllPoints()
        r.lbl:SetPoint("LEFT",  r, "LEFT", H_LABEL + 10, 0)
        r.lbl:SetPoint("RIGHT", r, "LEFT", H_BASE - 4,   0)
        r.lbl:SetText(groupName)
        r.lbl:SetTextColor(0.53, 0.67, 1.0)
        r.base:SetText(tostring(s.totalCrafts))
        r.base:SetTextColor(0.55, 0.70, 1.0)
        r.pct:SetText(CalcPctGain(s))
        r.pct:SetTextColor(0.55, 0.70, 1.0)
        SetRowBg(r, 0.10, 0.12, 0.26, 0.6)
    end

    local function AddItemRow(it)
        local r = UseRow()
        if not r then return end
        r.lbl:ClearAllPoints()
        r.lbl:SetPoint("LEFT",  r, "LEFT", H_LABEL + 22, 0)
        r.lbl:SetPoint("RIGHT", r, "LEFT", H_BASE - 4,   0)
        r.lbl:SetText(it.name)
        r.lbl:SetTextColor(0.80, 0.80, 0.80)
        r.base:SetText(tostring(it.totalCrafts))
        r.total:SetText(tostring(it.totalPotions))
        r.pct:SetText(CalcPctGain(it))
    end

    local function AddTotalRow(combined)
        local r = UseRow()
        if not r then return end
        r.lbl:ClearAllPoints()
        r.lbl:SetPoint("LEFT",  r, "LEFT", H_LABEL + 10, 0)
        r.lbl:SetPoint("RIGHT", r, "LEFT", H_BASE - 4,   0)
        r.lbl:SetText("|cffaaaaaa— Total —|r")
        r.base:SetText(tostring(combined.totalCrafts))   r.base:SetTextColor(0.7, 0.7, 0.7)
        r.total:SetText(tostring(combined.totalPotions)) r.total:SetTextColor(0.7, 0.7, 0.7)
        r.pct:SetText(CalcPctGain(combined))             r.pct:SetTextColor(0.7, 0.7, 0.7)
        SetRowBg(r, 0.08, 0.08, 0.15, 0.6)
    end

    local function RenderGroupItems(s)
        if not s.items then return end
        local sorted = {}
        for _, it in pairs(s.items) do sorted[#sorted + 1] = it end
        table.sort(sorted, function(a, b) return a.name < b.name end)
        for _, it in ipairs(sorted) do AddItemRow(it) end
    end

    -- ── Past sessions (newest first) ──────────────────────────
    for i, sess in ipairs(sessions) do
        local key      = "sid_" .. (sess.id or i)   -- sess.id is stable across prepends; fallback for legacy entries
        local combined = CombineGroups(sess.stats or {})
        AddSessionHeader(string.format("Session %d  —  %s", i, sess.date), key, combined)
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

    -- ── Overall (all-time) ────────────────────────────────────
    local ovMap = {}
    for _, g in ipairs(GROUPS_ORDER) do
        ovMap[g] = APT.db.char.stats[g] and APT.db.char.stats[g].overall
    end
    local combinedOv = CombineGroups(ovMap)
    AddSessionHeader("Overall", "overall", combinedOv)
    if expandedSessions["overall"] then
        for _, g in ipairs(GROUPS_ORDER) do
            local ov = ovMap[g]
            if ov and ov.totalCrafts > 0 then
                AddGroupHeader(g, ov)
            end
        end
        AddTotalRow(combinedOv)
    end

    sc:SetHeight(math.max(curY + 8, 10))
end

-- ============================================================
-- CreateUI
-- Builds the stats window once on OnInitialize. Hidden by default.
-- ============================================================

local function CreateUI()
    local f = CreateFrame("Frame", "AlchemyProcTrackerFrame", UIParent, "BackdropTemplate")
    f:SetSize(300, 230)
    f:SetPoint("CENTER")
    f:SetFrameStrata("MEDIUM")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop",  f.StopMovingOrSizing)
    f:SetClampedToScreen(true)

    f:Hide()
    APT_Frame = f

    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(f)
    bg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
    bg:SetVertexColor(0.08, 0.10, 0.20)
    bg:SetAlpha(0.92)

    f:SetBackdrop({
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        edgeSize = 16,
        insets   = { left = 4, right = 4, top = 4, bottom = 4 },
    })

    local X_LABEL   = 12
    local X_SESSION = 170
    local X_OVERALL = 232
    local COL_W     = 55
    local curY      = -12

    local function AddFullLine(key, font)
        local fs = f:CreateFontString(nil, "OVERLAY", font or "GameFontNormal")
        fs:SetPoint("TOPLEFT", f, "TOPLEFT", X_LABEL, curY)
        fs:SetWidth(272)
        fs:SetJustifyH("LEFT")
        APT_Lines[key] = fs
        curY = curY - 16
        return fs
    end

    local function AddDataRow(key, labelText)
        local lbl = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        lbl:SetPoint("TOPLEFT", f, "TOPLEFT", X_LABEL, curY)
        lbl:SetWidth(155)
        lbl:SetJustifyH("LEFT")
        lbl:SetText(labelText)

        local sess = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        sess:SetPoint("TOPLEFT", f, "TOPLEFT", X_SESSION, curY)
        sess:SetWidth(COL_W)
        sess:SetJustifyH("RIGHT")
        sess:SetText("0")

        local over = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        over:SetPoint("TOPLEFT", f, "TOPLEFT", X_OVERALL, curY)
        over:SetWidth(COL_W)
        over:SetJustifyH("RIGHT")
        over:SetText("0")

        APT_Lines[key] = { sess = sess, over = over }
        curY = curY - 16
    end

    local title = AddFullLine("title", "GameFontNormalLarge")
    title:SetText("Alchemy Proc Tracker")
    title:SetTextColor(1, 0.85, 0)

    curY = curY - 2

    local hSess = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hSess:SetPoint("TOPLEFT", f, "TOPLEFT", X_SESSION, curY)
    hSess:SetWidth(COL_W)
    hSess:SetJustifyH("RIGHT")
    hSess:SetText("Session")
    hSess:SetTextColor(1, 0.9, 0.1)

    local hOver = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hOver:SetPoint("TOPLEFT", f, "TOPLEFT", X_OVERALL, curY)
    hOver:SetWidth(COL_W)
    hOver:SetJustifyH("RIGHT")
    hOver:SetText("Overall")
    hOver:SetTextColor(1, 0.9, 0.1)

    curY = curY - 16

    AddDataRow("procs1", "x1 Proc:")
    AddDataRow("procs2", "x2 Proc:")
    AddDataRow("procs3", "x3 Proc:")
    AddDataRow("procs4", "x4 Proc:")

    curY = curY - 4

    AddDataRow("crafts",  "Total Crafts:")
    AddDataRow("potions", "Total Items Produced:")
    AddDataRow("extra",   "Total Extra Items:")
    AddDataRow("pct",     "Percent Gain:")

    curY = curY - 4

    AddDataRow("streak",  "No-Proc Streak:")
    AddDataRow("longest", "Longest No-Proc Streak:")

    local btn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    btn:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
end

-- ============================================================
-- APT_RefreshUI
-- Updates every FontString with current data from db.char.
-- ============================================================

APT_RefreshUI = function()
    if not APT_Frame or not APT_Frame:IsShown() then return end

    local char       = APT.db.char
    local groupStats = char.stats[displayGroup]
    if not groupStats then return end

    local se = groupStats.session
    local ov = groupStats.overall

    local function SetRow(key, sVal, oVal)
        local row = APT_Lines[key]
        if row then
            row.sess:SetText(tostring(sVal))
            row.over:SetText(tostring(oVal))
        end
    end

    SetRow("procs1",  se.procs1,              ov.procs1)
    SetRow("procs2",  se.procs2,              ov.procs2)
    SetRow("procs3",  se.procs3,              ov.procs3)
    SetRow("procs4",  se.procs4,              ov.procs4)
    SetRow("crafts",  se.totalCrafts,         ov.totalCrafts)
    SetRow("potions", se.totalPotions,        ov.totalPotions)
    SetRow("extra",   se.totalExtra,          ov.totalExtra)
    SetRow("pct",     CalcPctGain(se),        CalcPctGain(ov))
    SetRow("streak",  se.currentNoProcStreak, ov.currentNoProcStreak)
    SetRow("longest", se.longestNoProcStreak, ov.longestNoProcStreak)
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
        self:Print("  |cffffd700/apt group|r |cffaaaaaa<FLASK|ELIXIR|POTION|TRANSMUTE>|r  — switch displayed group")

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

    else
        local groupArg = cmdLower:match("^group%s+(%a+)$")
        if groupArg then
            local g = groupArg:upper()
            if g == "FLASK" or g == "ELIXIR" or g == "POTION" or g == "TRANSMUTE" then
                displayGroup = g
                self:Print(string.format("Displaying group: %s", g))
                if APT_Frame and APT_Frame:IsShown() then
                    APT_RefreshUI()
                end
            else
                self:Print("Unknown group. Valid groups: FLASK, ELIXIR, POTION, TRANSMUTE")
            end
        else
            self:Print("Unknown command. Type /apt for help.")
        end
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
    if debugMode and msg and msg:find("You create") then
        self:Print(string.format("|cffaaaaaa[DEBUG] event=%s msg=%s|r", event, msg))
    end
    HandleCraftEvent(msg)
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
