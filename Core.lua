-- Core.lua
-- AlchemyTracker: addon object, craft logic, session management, event handlers.
-- All UI modules load after this file and attach methods to the APT object.
-- They are available at OnInitialize time because WoW fires addon lifecycle
-- events only after every .toc file has finished loading.

local ADDON_NAME = ...

-- ============================================================
-- Addon Object
-- Exposed as AlchemyTracker global so later files can reference it.
-- ============================================================
local APT = LibStub("AceAddon-3.0"):NewAddon("AlchemyTracker", "AceConsole-3.0", "AceEvent-3.0")
AlchemyTracker      = APT
APT.ADDON_NAME      = ADDON_NAME  -- used by Commands.lua for version lookup

-- ============================================================
-- Mastery Spell IDs (TBC Classic)
-- ============================================================
local ELIXIR_MASTER_SPELL_ID    = 28677
local POTION_MASTER_SPELL_ID    = 28675
local TRANSMUTE_MASTER_SPELL_ID = 28672

-- ============================================================
-- Craft Configuration
-- ============================================================
-- Default values — stored in db.char.settings so they can be overridden per character.
local DEFAULT_CRAFT_WINDOW        = 0.4   -- seconds to collect proc messages after first "You create"
local DEFAULT_SESSION_TIMEOUT     = 900   -- 15 min inactivity → new session on next open
local DEFAULT_MAX_SESSIONS        = 200
local DEFAULT_MAX_ITEMS_PER_GROUP = 150   -- max unique items tracked per group per session

-- Runtime accessors — always read from db so overrides take effect immediately.
local function CraftWindow()        return APT.db.char.settings.craftWindow      end
local function SessionTimeout()     return APT.db.char.settings.sessionTimeout   end
local function MaxSessions()        return APT.db.char.settings.maxSessions      end
local function MaxItemsPerGroup()   return APT.db.char.settings.maxItemsPerGroup end

-- ============================================================
-- Craft State Machine
-- IDLE: no craft in progress.
-- ACCUMULATING: base craft received; waiting for proc loot within CRAFT_WINDOW.
-- ============================================================
local CRAFT_STATE = { IDLE = "IDLE", ACCUMULATING = "ACCUMULATING" }
local craftState    = CRAFT_STATE.IDLE
local currentCraft  = nil   -- { itemID, itemName, group, totalCreated }
local craftTimer    = nil   -- C_Timer handle
local sessionTimer  = nil   -- inactivity timer
local sessionClosed = false -- true when timeout fired; resets on next TRADE_SKILL_SHOW

-- Debug mode: exposed on APT so Commands.lua can toggle it.
APT.debugMode = false

-- ============================================================
-- Shared Item Lookup  (flat; built at load time from AlchemyTrackerItems.lua)
-- ============================================================
local TrackedItems = {}

-- ============================================================
-- Stats Schema
-- ============================================================
local GROUPS_ORDER = { "FLASK", "ELIXIR", "POTION", "TRANSMUTE" }
APT.GROUPS_ORDER = GROUPS_ORDER

local function newStatsDefaults()
    return {
        totalCrafts  = 0,
        totalPotions = 0,
        totalExtra   = 0,
        procs1       = 0,
        procs2       = 0,
        procs3       = 0,
        procs4       = 0,
    }
end

local function newGroupDefaults()
    return { session = newStatsDefaults(), overall = newStatsDefaults() }
end

-- Shallow-copy scalar stat fields; items = {} is always a fresh table.
local function CopyStats(s)
    return {
        totalCrafts  = s.totalCrafts,
        totalPotions = s.totalPotions,
        totalExtra   = s.totalExtra,
        procs1       = s.procs1,
        procs2       = s.procs2,
        procs3       = s.procs3,
        procs4       = s.procs4,
        items        = {},
    }
end

-- ============================================================
-- AceDB Defaults
-- ============================================================
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
        nextSessionID    = 0,
        sessions         = {},
        windowPos        = false,
        historyPos       = false,
        expandedSessions = {},    -- persisted expand state for the history browser
        sessionStartTime = false, -- epoch time when the current session started
        settings = {
            craftWindow      = DEFAULT_CRAFT_WINDOW,
            sessionTimeout   = DEFAULT_SESSION_TIMEOUT,
            maxSessions      = DEFAULT_MAX_SESSIONS,
            maxItemsPerGroup = DEFAULT_MAX_ITEMS_PER_GROUP,
        },
    },
}

-- ============================================================
-- BuildTrackedItemLookup
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
                        itemID, name, expansion, group))
                else
                    TrackedItems[itemID] = { group = group, name = name, expansion = expansion }
                end
            end
        end
    end
end

local function GetTrackedGroupForItem(itemID)
    local info = TrackedItems[itemID]
    if info then return info.group, info.name end
    return nil, nil
end

-- ============================================================
-- CalcPctGain  (extra items / total items × 100, formatted)
-- ============================================================
local function CalcPctGain(s)
    if s.totalPotions > 0 then
        return string.format("+%.1f%%", (s.totalExtra / s.totalPotions) * 100)
    end
    return "+0.0%"
end
APT.CalcPctGain = CalcPctGain   -- used by UI_History.lua

-- Session-stats cache: invalidated by UpdateStats, ResetSessionStats, ResetAllStats.
-- Declared here so all three functions share the same upvalue as CombineAllStats.
local _sessionStatsCache = nil
APT.InvalidateStatsCache = function() _sessionStatsCache = nil end

-- ============================================================
-- DetectAlchemySpecialization
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

        if     extra == 1 then s.procs1 = s.procs1 + 1
        elseif extra == 2 then s.procs2 = s.procs2 + 1
        elseif extra == 3 then s.procs3 = s.procs3 + 1
        elseif extra >= 4 then s.procs4 = s.procs4 + 1
        end
    end

    -- Per-item tracking (session only)
    if itemID and itemName then
        local s = groupStats["session"]
        if not s.items then s.items = {} end
        local it = s.items[itemID]
        if not it then
            -- Enforce cap: evict the entry with the fewest crafts to make room
            local count = 0
            for _ in pairs(s.items) do count = count + 1 end
            if count >= MaxItemsPerGroup() then
                local minKey, minVal = nil, math.huge
                for k, v in pairs(s.items) do
                    if v.totalCrafts < minVal then minKey, minVal = k, v.totalCrafts end
                end
                if minKey then s.items[minKey] = nil end
            end
            it = { name = itemName, totalCrafts = 0, totalPotions = 0, totalExtra = 0 }
            s.items[itemID] = it
        end
        it.totalCrafts  = it.totalCrafts  + 1
        it.totalPotions = it.totalPotions + totalCreated
        it.totalExtra   = it.totalExtra   + extra
    end

    _sessionStatsCache = nil  -- invalidate combined-stats cache on every craft
end

-- ============================================================
-- FinalizeCraft
-- ============================================================
local function FinalizeCraft()
    if craftState ~= CRAFT_STATE.ACCUMULATING then return end
    craftState = CRAFT_STATE.IDLE
    if not currentCraft then return end

    local groupStats = APT.db.char.stats[currentCraft.group]
    if not groupStats then currentCraft = nil; return end

    local totalCreated = currentCraft.totalCreated
    local extra        = totalCreated - 1

    if extra > 0 then
        APT:Print(string.format("|cff00ff00Proc!|r %s: crafted %d (+%d extra).",
            currentCraft.itemName, totalCreated, extra))
    end

    UpdateStats(groupStats, totalCreated, currentCraft.itemID, currentCraft.itemName)
    currentCraft = nil

    if APT.RefreshUI then APT.RefreshUI() end
end

-- ============================================================
-- Locale-safe message parsing
-- Converts WoW GlobalStrings format strings to Lua patterns.
-- Falls back to English literals when a GlobalString is absent.
-- ============================================================

-- Converts a printf-style format string to a Lua pattern.
-- Handles %s → (.+) and %d → (%d+); escapes all other magic chars.
local function FmtToPattern(fmt)
    local result = {}
    local i = 1
    while i <= #fmt do
        local c = fmt:sub(i, i)
        if c == "%" then
            local nxt = fmt:sub(i + 1, i + 1)
            if nxt == "s" then
                result[#result + 1] = "(.+)"
                i = i + 2
            elseif nxt == "d" then
                result[#result + 1] = "(%d+)"
                i = i + 2
            else
                result[#result + 1] = "%%"
                i = i + 1
            end
        elseif c:find("[%^%$%(%)%.%[%]%*%+%-%?]") then
            result[#result + 1] = "%" .. c
            i = i + 1
        else
            result[#result + 1] = c
            i = i + 1
        end
    end
    return "^" .. table.concat(result) .. "$"
end

-- Craft message patterns (CHAT_MSG_SKILL)
local PAT_CREATE_SINGLE = FmtToPattern(LOOT_ITEM_CREATED_SELF          or "You create: %s.")
local PAT_CREATE_MULTI  = FmtToPattern(LOOT_ITEM_CREATED_SELF_MULTIPLE or "You create %dx %s.")

-- Loot message patterns (CHAT_MSG_LOOT) — proc extras
local PAT_LOOT_SINGLE   = FmtToPattern(LOOT_ITEM_PUSHED_SELF          or "You receive loot: %s.")
local PAT_LOOT_MULTI    = FmtToPattern(LOOT_ITEM_PUSHED_SELF_MULTIPLE or "You receive loot: %dx%s.")

local function ParseItemIDFromLink(link)
    if not link then return nil end
    local idStr = link:match("|Hitem:(%d+):")
    return idStr and tonumber(idStr) or nil
end

local function ParseCreateMessage(msg)
    if not msg then return nil, nil end
    local n, link = msg:match(PAT_CREATE_MULTI)
    if n and link then return tonumber(n), link end
    link = msg:match(PAT_CREATE_SINGLE)
    if link then return 1, link end
    return nil, nil
end

local function ParseLootMessage(msg)
    if not msg then return nil, nil end
    local n, link = msg:match(PAT_LOOT_MULTI)
    if n and link then return tonumber(n), link end
    link = msg:match(PAT_LOOT_SINGLE)
    if link then return 1, link end
    return nil, nil
end

-- ============================================================
-- Craft timer helpers
-- ============================================================
local function CancelCraftTimer()
    if craftTimer then craftTimer:Cancel(); craftTimer = nil end
end

local function ScheduleCraftFinalize()
    CancelCraftTimer()
    craftTimer = C_Timer.NewTimer(CraftWindow(), function()
        craftTimer = nil
        FinalizeCraft()
    end)
end

-- ============================================================
-- HandleCraftEvent
-- Called for every CHAT_MSG_SKILL message.
-- Groups same-item messages within CRAFT_WINDOW seconds.
-- ============================================================
local function HandleCraftEvent(msg)
    -- Mastery guard: only track if the player has an alchemy mastery specialization.
    if APT.db.char.specialization.current == "None" then return end

    local amount, link = ParseCreateMessage(msg)
    if not amount then return end

    local itemID = ParseItemIDFromLink(link)
    if not itemID then return end

    local group, itemName = GetTrackedGroupForItem(itemID)
    if not group then return end

    if craftState == CRAFT_STATE.ACCUMULATING
    and currentCraft and currentCraft.itemID == itemID then
        -- Same item within window: accumulate (proc extras from multi-create)
        currentCraft.totalCreated = currentCraft.totalCreated + amount
        ScheduleCraftFinalize()
    else
        -- New or different item: finalize previous craft first, then start new
        CancelCraftTimer()
        FinalizeCraft()
        craftState   = CRAFT_STATE.ACCUMULATING
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
-- Session Management
-- ============================================================
local function SaveCurrentSession()
    if not APT.db or not APT.db.char then return end
    if not APT.db.char.sessions then APT.db.char.sessions = {} end

    local hasActivity = false
    for _, group in ipairs(GROUPS_ORDER) do
        local gs = APT.db.char.stats[group]
        if gs and gs.session.totalCrafts > 0 then hasActivity = true; break end
    end
    if not hasActivity then return end

    APT.db.char.nextSessionID = (APT.db.char.nextSessionID or 0) + 1
    local startTime = APT.db.char.sessionStartTime
    local snapshot = {
        date     = date("%Y-%m-%d %H:%M"),
        id       = APT.db.char.nextSessionID,
        duration = startTime and math.max(0, time() - startTime) or nil,
        stats    = {},
    }
    for _, group in ipairs(GROUPS_ORDER) do
        local s  = APT.db.char.stats[group].session
        local gs = CopyStats(s)
        if s.items then
            for id, it in pairs(s.items) do
                gs.items[id] = {
                    name         = it.name,
                    totalCrafts  = it.totalCrafts,
                    totalPotions = it.totalPotions,
                    totalExtra   = it.totalExtra,
                }
            end
        end
        snapshot.stats[group] = gs
    end

    table.insert(APT.db.char.sessions, 1, snapshot)
    while #APT.db.char.sessions > MaxSessions() do
        table.remove(APT.db.char.sessions)
    end
end

local function ResetSessionStats()
    SaveCurrentSession()
    for _, group in ipairs(GROUPS_ORDER) do
        if APT.db.char.stats[group] then
            APT.db.char.stats[group].session = newStatsDefaults()
        end
    end
    _sessionStatsCache           = nil
    APT.db.char.sessionStartTime = time()
    APT:Print("Session stats have been reset.")
    if APT.RefreshUI then APT.RefreshUI() end
end
APT.ResetSessionStats = ResetSessionStats

local function ResetAllStats()
    SaveCurrentSession()
    for _, group in ipairs(GROUPS_ORDER) do
        if APT.db.char.stats[group] then
            APT.db.char.stats[group].session = newStatsDefaults()
            APT.db.char.stats[group].overall = newStatsDefaults()
        end
    end
    _sessionStatsCache           = nil
    APT.db.char.sessionStartTime = time()
    APT:Print("All stats (session and overall) have been reset.")
    if APT.RefreshUI then APT.RefreshUI() end
end
APT.ResetAllStats = ResetAllStats

-- ============================================================
-- CombineAllStats  (aggregates all groups for the main window)
-- Session scope is cached; invalidated by UpdateStats and resets.
-- ============================================================
local function CombineAllStats(scope)
    if scope == "session" and _sessionStatsCache then
        return _sessionStatsCache
    end
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
    if scope == "session" then _sessionStatsCache = c end
    return c
end
APT.CombineAllStats = CombineAllStats

-- ============================================================
-- AceAddon Lifecycle
-- ============================================================
function APT:OnInitialize()
    self.db = LibStub("AceDB-3.0"):New("AlchemyProcTrackerDB", defaults, true)

    -- Back-compat: chars without sessions from the default table
    if not self.db.char.sessions then self.db.char.sessions = {} end

    -- Ensure every saved session has a stable ID (migration for old data)
    local nextID = self.db.char.nextSessionID or 0
    for _, sess in ipairs(self.db.char.sessions) do
        if not sess.id then
            nextID = nextID + 1
            sess.id = nextID
        end
    end
    self.db.char.nextSessionID = nextID

    -- Initialise session timer if missing (e.g. first ever load)
    if not self.db.char.sessionStartTime then
        self.db.char.sessionStartTime = time()
    end

    BuildTrackedItemLookup()

    -- UI modules (loaded after Core.lua) attach Create* methods to APT.
    if self.CreateUI         then self:CreateUI()         end
    if self.CreateHistoryUI  then self:CreateHistoryUI()  end
    if self.RegisterMinimapButton then self:RegisterMinimapButton() end
    if self.CreateSettingsUI then self:CreateSettingsUI() end

    self:RegisterChatCommand("apt", "HandleSlashCommand")
end

function APT:OnEnable()
    local detected = DetectAlchemySpecialization()
    if not detected then
        self:Print("|cffff8800No alchemy mastery detected.|r Tracking is disabled until a mastery specialization is found. Use |cffffd700/apt spec|r to check.")
    end

    self:RegisterEvent("PLAYER_LOGIN",        "OnPlayerLogin")
    self:RegisterEvent("TRADE_SKILL_SHOW",    "OnTradeSkillShow")
    self:RegisterEvent("SKILL_LINES_CHANGED", "OnSkillLinesChanged")
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
    if sessionTimer then sessionTimer:Cancel(); sessionTimer = nil end

    if sessionClosed then
        sessionClosed = false
        ResetSessionStats()   -- also resets sessionStartTime
        APT:Print("New session started (previous session expired).")
    elseif not APT.db.char.sessionStartTime then
        APT.db.char.sessionStartTime = time()
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
    if APT.debugMode then
        -- Strip hyperlinks and colour codes for readable debug output
        local clean = msg and msg
            :gsub("|H[^|]*|h(.-)|h", "%1")
            :gsub("|c%x%x%x%x%x%x%x%x", "")
            :gsub("|r", "")
            or "nil"
        self:Print(string.format("|cffaaaaaa[DEBUG] %s: %s|r", event, clean))
    end

    if event == "CHAT_MSG_LOOT" then
        -- Mastery guard: only accumulate proc loot if a mastery is active
        if APT.db.char.specialization.current == "None" then return end
        -- Only matters if a craft is currently accumulating
        if craftState ~= CRAFT_STATE.ACCUMULATING or not currentCraft then return end

        local amount, link = ParseLootMessage(msg)
        if not amount then return end
        local itemID = ParseItemIDFromLink(link)
        if itemID and itemID == currentCraft.itemID then
            currentCraft.totalCreated = currentCraft.totalCreated + amount
            ScheduleCraftFinalize()
        end
    else
        -- CHAT_MSG_SKILL: "You create ..." messages
        HandleCraftEvent(msg)
    end
end

function APT:OnTradeSkillClose()
    -- Finalize any pending craft immediately
    CancelCraftTimer()
    FinalizeCraft()

    -- Start inactivity timer; fires sessionClosed if window stays closed 15 min
    if sessionTimer then sessionTimer:Cancel() end
    sessionTimer = C_Timer.NewTimer(SessionTimeout(), function()
        sessionTimer  = nil
        sessionClosed = true
    end)
end
