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
local APT_RefreshUI  -- forward declaration; assigned after CreateUI
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

local selectedSessionIndex = 1  -- which past session is selected in the options panel

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
        sessions = {},  -- history of past sessions, newest first; max MAX_SESSIONS entries
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

    link = msg:match("^You create: (.+)%.?$")
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
    for _, group in ipairs({ "FLASK", "ELIXIR", "POTION", "TRANSMUTE" }) do
        local gs = APT.db.char.stats[group]
        if gs and gs.session.totalCrafts > 0 then
            hasActivity = true
            break
        end
    end
    if not hasActivity then return end

    -- Build snapshot: copy session stats for each group.
    local snapshot = { date = date("%Y-%m-%d %H:%M"), stats = {} }
    for _, group in ipairs({ "FLASK", "ELIXIR", "POTION", "TRANSMUTE" }) do
        local s = APT.db.char.stats[group].session
        local gs = {
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
    for _, group in ipairs({ "FLASK", "ELIXIR", "POTION", "TRANSMUTE" }) do
        if APT.db.char.stats[group] then
            APT.db.char.stats[group].session = newStatsDefaults()
        end
    end
    APT:Print("Session stats have been reset.")
    if APT_RefreshUI then APT_RefreshUI() end
end

local function ResetAllStats()
    SaveCurrentSession()
    for _, group in ipairs({ "FLASK", "ELIXIR", "POTION", "TRANSMUTE" }) do
        if APT.db.char.stats[group] then
            APT.db.char.stats[group].session = newStatsDefaults()
            APT.db.char.stats[group].overall = newStatsDefaults()
        end
    end
    APT:Print("All stats (session and overall) have been reset.")
    if APT_RefreshUI then APT_RefreshUI() end
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

local GROUPS_ORDER = { "FLASK", "ELIXIR", "POTION", "TRANSMUTE" }

-- Group summary line: name, base crafts, proc chance.
local function FormatGroupSummary(s, groupName)
    if s.totalCrafts == 0 then
        return string.format("|cffffd700%s:|r  No data", groupName)
    end
    return string.format("|cffffd700%s:|r  %d crafts  •  %s proc chance",
        groupName, s.totalCrafts, CalcPctGain(s))
end

-- Per-item lines sorted by name, indented under their group.
local function FormatItemLines(items)
    if not items then return {} end
    -- Collect and sort by name.
    local sorted = {}
    for id, it in pairs(items) do
        sorted[#sorted + 1] = it
    end
    table.sort(sorted, function(a, b) return a.name < b.name end)
    local lines = {}
    for _, it in ipairs(sorted) do
        lines[#lines + 1] = string.format(
            "  |cffaaaaaa%s:|r  %d base  •  %d produced  •  %s proc chance",
            it.name, it.totalCrafts, it.totalPotions, CalcPctGain(it))
    end
    return lines
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

local function BuildSessionDescription(idx)
    if not APT.db then return "" end
    local sessions = APT.db.char.sessions
    if not sessions or #sessions == 0 then return "" end
    local sess = sessions[idx]
    if not sess or not sess.stats then return "" end
    local lines = {}
    for _, g in ipairs(GROUPS_ORDER) do
        local s = sess.stats[g]
        if s and s.totalCrafts > 0 then
            lines[#lines + 1] = FormatGroupSummary(s, g)
            for _, itemLine in ipairs(FormatItemLines(s.items)) do
                lines[#lines + 1] = itemLine
            end
        end
    end
    if #lines == 0 then return "No crafts recorded in this session." end
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
            sessionNoData = {
                type   = "description",
                name   = "No sessions recorded yet. Sessions are saved automatically when the 15-minute timeout fires or when you reset.",
                order  = 21,
                hidden = function()
                    return APT.db and APT.db.char.sessions and #APT.db.char.sessions > 0
                end,
            },
            sessionSelect = {
                type   = "select",
                name   = "Session",
                order  = 22,
                hidden = function()
                    return not (APT.db and APT.db.char.sessions and #APT.db.char.sessions > 0)
                end,
                values = function()
                    local t = {}
                    local sessions = APT.db and APT.db.char.sessions or {}
                    for i, sess in ipairs(sessions) do
                        t[i] = string.format("[%d]  %s", i, sess.date)
                    end
                    return t
                end,
                sorting = function()
                    local sessions = APT.db and APT.db.char.sessions or {}
                    local t = {}
                    for i = 1, #sessions do t[i] = i end
                    return t
                end,
                get = function()
                    local n = APT.db and APT.db.char.sessions and #APT.db.char.sessions or 0
                    if n == 0 then return nil end
                    if selectedSessionIndex > n then selectedSessionIndex = 1 end
                    return selectedSessionIndex
                end,
                set = function(_, val) selectedSessionIndex = val end,
            },
            sessionDetail = {
                type     = "description",
                name     = function()
                    local n = APT.db and APT.db.char.sessions and #APT.db.char.sessions or 0
                    if n == 0 then return "" end
                    if selectedSessionIndex > n then selectedSessionIndex = 1 end
                    return BuildSessionDescription(selectedSessionIndex)
                end,
                fontSize = "medium",
                order    = 23,
                hidden   = function()
                    return not (APT.db and APT.db.char.sessions and #APT.db.char.sessions > 0)
                end,
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
    local cmd = input:match("^%s*(.-)%s*$")

    if cmd == "" or cmd:lower() == "help" then
        local _meta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
        local ver   = (_meta and _meta(ADDON_NAME, "Version")) or "?"
        self:Print(string.format("v%s — TBC Classic alchemy mastery proc tracker", ver))
        self:Print("  |cffffd700/apt|r                                    — show this help")
        self:Print("  |cffffd700/apt show|r                               — open the stats window")
        self:Print("  |cffffd700/apt hide|r                               — close the stats window")
        self:Print("  |cffffd700/apt reset|r                              — reset session stats (overall kept)")
        self:Print("  |cffffd700/apt reset all|r                          — reset ALL stats including overall")
        self:Print("  |cffffd700/apt group|r |cffaaaaaa<FLASK|ELIXIR|POTION|TRANSMUTE>|r  — switch displayed group")

    elseif cmd:lower() == "show" then
        if APT_Frame then
            APT_Frame:Show()
            APT_RefreshUI()
        end

    elseif cmd:lower() == "hide" then
        if APT_Frame then APT_Frame:Hide() end

    elseif cmd:lower() == "reset" then
        ResetSessionStats()

    elseif cmd:lower() == "reset all" then
        ResetAllStats()

    elseif cmd:lower() == "debug" then
        debugMode = not debugMode
        self:Print("Debug mode: " .. (debugMode and "|cff00ff00ON|r — craft now to see event/message in chat." or "|cffff4444OFF|r"))

    else
        local groupArg = cmd:match("^[Gg][Rr][Oo][Uu][Pp]%s+(%a+)$")
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
