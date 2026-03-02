-- AlchemyProcTracker.lua
-- Tracks Alchemy mastery procs (Flask/Elixir/Potion/Transmute) in TBC Classic.
-- Focus: Elixir Mastery (spell ID 28677), but the logic is generic for all masteries.
--
-- Usage:
--   /apt          → show help
--   /apt show     → open the stats window
--   /apt hide     → close the stats window
--   /apt reset    → reset session stats (overall stats are kept)
--   /apt group X  → switch the displayed group (FLASK/ELIXIR/POTION/TRANSMUTE)

local ADDON_NAME, ns = ...

-- ============================================================
-- Constants: Alchemy Mastery Passive Spell IDs (TBC Classic)
-- Verify these IDs are correct in-game if detection feels off.
-- ============================================================

local ELIXIR_MASTER_SPELL_ID    = 28677
local POTION_MASTER_SPELL_ID    = 28675
local TRANSMUTE_MASTER_SPELL_ID = 28672

-- ============================================================
-- TrackedItems (flat lookup, built at load time)
-- Do not edit this table directly.
-- To add or remove items, edit AlchemyTrackerItems.lua instead.
-- ============================================================

local TrackedItems = {}

-- ============================================================
-- BuildTrackedItemLookup
-- Reads AlchemyTrackerItemData (defined in AlchemyTrackerItems.lua)
-- and flattens its expansion > group > itemID structure into the
-- simple flat lookup table above.
--
-- Result: TrackedItems[itemID] = { group, name, expansion }
--
-- Called once from ADDON_LOADED, after both files are loaded.
-- ============================================================

local function BuildTrackedItemLookup()
    if not AlchemyTrackerItemData then
        print("|cffff0000[Alchemy Tracker]|r ERROR: AlchemyTrackerItemData not found. Check AlchemyTrackerItems.lua.")
        return
    end

    for expansion, groups in pairs(AlchemyTrackerItemData) do
        for group, items in pairs(groups) do
            for itemID, name in pairs(items) do
                -- Warn about duplicate item IDs (easy mistake when filling in the list).
                if TrackedItems[itemID] then
                    print(string.format(
                        "|cffff8800[Alchemy Tracker]|r Warning: duplicate item ID %d ('%s') in %s/%s — first entry kept.",
                        itemID, name, expansion, group
                    ))
                else
                    TrackedItems[itemID] = {
                        group     = group,      -- "FLASK", "ELIXIR", "POTION", or "TRANSMUTE"
                        name      = name,       -- display name shown in chat and the UI
                        expansion = expansion,  -- "TBC", "Classic", "WotLK", etc.
                    }
                end
            end
        end
    end
end

-- ============================================================
-- GetTrackedGroupForItem
-- Returns the group key ("FLASK", "ELIXIR", etc.) and the
-- display name for a given itemID, or nil, nil if not tracked.
-- ============================================================

local function GetTrackedGroupForItem(itemID)
    local info = TrackedItems[itemID]
    if info then
        return info.group, info.name
    end
    return nil, nil
end

-- ============================================================
-- GetCharacterKey
-- Builds a unique string key for the current character.
-- Format: "RealmName-CharacterName"
-- ============================================================

local function GetCharacterKey()
    local name  = UnitName("player") or "Unknown"
    local realm = GetRealmName()     or "Unknown"
    return realm .. "-" .. name
end

-- ============================================================
-- NewStatsBlock
-- Returns a fresh stats table with every counter at zero.
-- Both session and overall scopes share the same structure.
-- ============================================================

local function NewStatsBlock()
    return {
        totalCrafts         = 0,  -- number of crafts finalized
        totalPotions        = 0,  -- total items produced (base + all extras)
        totalExtra          = 0,  -- total extra items gained from procs
        procs1              = 0,  -- crafts that gave exactly +1 extra
        procs2              = 0,  -- crafts that gave exactly +2 extra
        procs3              = 0,  -- crafts that gave exactly +3 extra
        procs4              = 0,  -- crafts that gave +4 or more extra
        currentNoProcStreak = 0,
        longestNoProcStreak = 0,
    }
end

-- ============================================================
-- NewGroupEntry
-- Returns a table with fresh session and overall stats blocks.
-- One of these is created for each group (FLASK, ELIXIR, etc.).
-- ============================================================

local function NewGroupEntry()
    return {
        session = NewStatsBlock(),
        overall = NewStatsBlock(),
    }
end

-- ============================================================
-- InitCharacterDB
-- Ensures AlchemyProcTrackerDB has all required keys for this
-- character. Safe to call multiple times (only fills gaps).
-- ============================================================

local function InitCharacterDB()
    -- Create the top-level DB if this is the very first ever load.
    if not AlchemyProcTrackerDB then
        AlchemyProcTrackerDB = { characters = {} }
    end
    if not AlchemyProcTrackerDB.characters then
        AlchemyProcTrackerDB.characters = {}
    end

    local key = GetCharacterKey()

    -- Create the per-character entry if it does not exist yet.
    if not AlchemyProcTrackerDB.characters[key] then
        AlchemyProcTrackerDB.characters[key] = {}
    end

    local charDB = AlchemyProcTrackerDB.characters[key]

    -- Specialization block.
    if not charDB.specialization then
        charDB.specialization = {
            current     = "None",  -- "Elixir", "Potion", "Transmute", or "None"
            isElixir    = false,
            isPotion    = false,
            isTransmute = false,
        }
    end

    -- Stats blocks, one per group.
    if not charDB.stats then
        charDB.stats = {}
    end
    for _, group in ipairs({ "FLASK", "ELIXIR", "POTION", "TRANSMUTE" }) do
        if not charDB.stats[group] then
            charDB.stats[group] = NewGroupEntry()
        end
    end

    return charDB
end

-- ============================================================
-- DetectAlchemySpecialization
-- Checks which mastery passive (if any) the player has learned
-- and writes the result to the saved variables.
--
-- NOTE: IsPlayerSpell(spellID) is used here to check for passive
-- specialization spells. This should work in TBC Classic, but
-- verify in-game if detection seems wrong. An alternative is
-- FindSpellBookSlotBySpellID, also available in TBC Classic.
-- ============================================================

local function DetectAlchemySpecialization()
    local key = GetCharacterKey()
    if not AlchemyProcTrackerDB or not AlchemyProcTrackerDB.characters then return end
    local charDB = AlchemyProcTrackerDB.characters[key]
    if not charDB then return end

    -- IsPlayerSpell returns true if the player knows that spell/passive.
    -- verify: IsPlayerSpell works for mastery passives in TBC Classic
    local isElixir    = IsPlayerSpell(ELIXIR_MASTER_SPELL_ID)    or false
    local isPotion    = IsPlayerSpell(POTION_MASTER_SPELL_ID)    or false
    local isTransmute = IsPlayerSpell(TRANSMUTE_MASTER_SPELL_ID) or false

    -- Only one mastery is possible at a time; Elixir is checked first
    -- since that is the primary use case for this addon.
    local current = "None"
    if isElixir then
        current = "Elixir"
    elseif isPotion then
        current = "Potion"
    elseif isTransmute then
        current = "Transmute"
    end

    charDB.specialization.current     = current
    charDB.specialization.isElixir    = isElixir
    charDB.specialization.isPotion    = isPotion
    charDB.specialization.isTransmute = isTransmute
end

-- ============================================================
-- Forward declarations
-- These locals are assigned later in the file but are referenced
-- in functions defined earlier. Lua closures handle this correctly:
-- by the time the functions are actually called, the values will
-- have been assigned.
-- ============================================================

local APT_RefreshUI   -- assigned in the UI section
local APT_Frame       -- the main UI frame widget
local APT_Lines = {}  -- FontString references, keyed by name

-- ============================================================
-- Current Craft State
-- A single in-progress craft accumulates here.
-- Multiple "You create" messages for the same item within the
-- same second are merged into one craft entry.
-- ============================================================

local currentCraft = nil

--[[
  currentCraft shape while a craft is being accumulated:
  {
    itemID       = number,   -- item being crafted
    itemName     = string,   -- display name from TrackedItems
    group        = string,   -- "FLASK", "ELIXIR", "POTION", or "TRANSMUTE"
    timestampSec = number,   -- math.floor(GetTime()) at first message
    totalCreated = number,   -- running total of items seen so far
  }
]]

-- ============================================================
-- UpdateStats
-- Applies one finalized craft result to both session and overall
-- stats for its group.
--
--   groupStats   : charDB.stats[group]  (contains .session and .overall)
--   totalCreated : integer, total items produced in this craft
-- ============================================================

local function UpdateStats(groupStats, totalCreated)
    -- A craft always produces at least 1 item; everything above 1 is "extra".
    local extra = totalCreated - 1

    -- Apply the exact same logic to both session and overall.
    for _, scope in ipairs({ "session", "overall" }) do
        local s = groupStats[scope]

        s.totalCrafts  = s.totalCrafts  + 1
        s.totalPotions = s.totalPotions + totalCreated
        s.totalExtra   = s.totalExtra   + extra

        if extra >= 1 then
            -- Proc: put it in the right bucket.
            if     extra == 1 then s.procs1 = s.procs1 + 1
            elseif extra == 2 then s.procs2 = s.procs2 + 1
            elseif extra == 3 then s.procs3 = s.procs3 + 1
            else                   s.procs4 = s.procs4 + 1  -- +4 or more
            end
            -- Any proc resets the running no-proc streak.
            s.currentNoProcStreak = 0
        else
            -- No proc this craft.
            s.currentNoProcStreak = s.currentNoProcStreak + 1
            if s.currentNoProcStreak > s.longestNoProcStreak then
                s.longestNoProcStreak = s.currentNoProcStreak
            end
        end
    end
end

-- ============================================================
-- FinalizeCraft
-- Called when the current craft is complete: either because a
-- new craft started or a new item was seen (different ID/second).
-- Calculates extra, updates stats, prints a notice on proc.
-- ============================================================

local function FinalizeCraft()
    if not currentCraft then return end

    local key = GetCharacterKey()
    if not AlchemyProcTrackerDB or not AlchemyProcTrackerDB.characters then
        currentCraft = nil
        return
    end
    local charDB = AlchemyProcTrackerDB.characters[key]
    if not charDB then
        currentCraft = nil
        return
    end

    local group      = currentCraft.group
    local groupStats = charDB.stats[group]
    if not groupStats then
        currentCraft = nil
        return
    end

    local totalCreated = currentCraft.totalCreated
    local extra        = totalCreated - 1

    -- Print a chat message on a proc so the player notices.
    if extra > 0 then
        print(string.format(
            "|cff00ff00[Alchemy Tracker]|r Proc! %s: crafted %d (+%d extra).",
            currentCraft.itemName, totalCreated, extra
        ))
    end

    UpdateStats(groupStats, totalCreated)

    -- Refresh the window if it is currently open.
    if APT_RefreshUI then APT_RefreshUI() end

    currentCraft = nil
end

-- ============================================================
-- ParseItemIDFromLink
-- Extracts the numeric item ID from a WoW item hyperlink string.
-- Item links look like: |cffffffff|Hitem:12345:0:0:0:...|h[Name]|h|r
-- Returns the item ID as a number, or nil if no link is found.
-- ============================================================

local function ParseItemIDFromLink(link)
    if not link then return nil end
    local idStr = link:match("|Hitem:(%d+):")
    if idStr then
        return tonumber(idStr)
    end
    return nil
end

-- ============================================================
-- ParseCreateMessage
-- Parses an English "You create" chat message.
-- Handles two formats that appear in TBC Classic:
--   "You create: [item link]."       → 1 item
--   "You create Nx [item link]."     → N items  (N >= 2)
-- Returns amount (number) and the raw link string, or nil, nil
-- if the message is not a creation message.
-- ============================================================

local function ParseCreateMessage(msg)
    if not msg then return nil, nil end

    -- Format with explicit count: "You create 3x |Hitem:...|h[Name]|h|r."
    local amountStr, link = msg:match("^You create (%d+)x (.+)%.$")
    if amountStr and link then
        return tonumber(amountStr), link
    end

    -- Single-item format: "You create: |Hitem:...|h[Name]|h|r."
    link = msg:match("^You create: (.+)%.$")
    if link then
        return 1, link
    end

    -- Not a creation message we recognize.
    return nil, nil
end

-- ============================================================
-- HandleCraftEvent
-- Processes one incoming chat message.
-- Groups same-item, same-second messages into a single craft.
-- ============================================================

local function HandleCraftEvent(msg)
    local amount, link = ParseCreateMessage(msg)
    if not amount then return end  -- not a "You create" message

    local itemID = ParseItemIDFromLink(link)
    if not itemID then return end  -- could not extract item ID

    local group, itemName = GetTrackedGroupForItem(itemID)
    if not group then return end   -- item is not in our tracking table

    -- Use whole-second timestamps for grouping.
    local tSec = math.floor(GetTime())

    if currentCraft
        and currentCraft.itemID       == itemID
        and currentCraft.timestampSec == tSec
    then
        -- Same item, same second → accumulate into the running craft.
        currentCraft.totalCreated = currentCraft.totalCreated + amount
    else
        -- Different item or different second → close the previous craft,
        -- then open a new one.
        FinalizeCraft()

        currentCraft = {
            itemID       = itemID,
            itemName     = itemName,
            group        = group,
            timestampSec = tSec,
            totalCreated = amount,
        }
    end
end

-- ============================================================
-- ResetSessionStats
-- Wipes the session stats block for every group.
-- Overall stats are intentionally left untouched.
-- ============================================================

local function ResetSessionStats()
    local key = GetCharacterKey()
    if not AlchemyProcTrackerDB or not AlchemyProcTrackerDB.characters then return end
    local charDB = AlchemyProcTrackerDB.characters[key]
    if not charDB then return end

    for _, group in ipairs({ "FLASK", "ELIXIR", "POTION", "TRANSMUTE" }) do
        if charDB.stats[group] then
            charDB.stats[group].session = NewStatsBlock()
        end
    end

    print("|cff00ff00[Alchemy Tracker]|r Session stats have been reset.")
    if APT_RefreshUI then APT_RefreshUI() end
end

-- ============================================================
-- CalcPctGain
-- Returns a formatted "+X.X%" string for a stats block.
-- ============================================================

local function CalcPctGain(s)
    if s.totalPotions > 0 then
        local pct = (s.totalExtra / s.totalPotions) * 100
        return string.format("+%.1f%%", pct)
    end
    return "+0.0%"
end

-- ============================================================
-- displayGroup
-- Which group the UI is currently showing. Change with /apt group.
-- ============================================================

local displayGroup = "ELIXIR"

-- ============================================================
-- CreateUI
-- Builds the stats window once on ADDON_LOADED.
-- Hidden by default; shown with /apt show.
-- ============================================================

local function CreateUI()
    -- Main frame: movable, draggable, clamped to screen.
    local f = CreateFrame("Frame", "AlchemyProcTrackerFrame", UIParent)
    f:SetSize(370, 268)
    f:SetPoint("CENTER")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop",  f.StopMovingOrSizing)
    f:SetClampedToScreen(true)

    -- Background + border.
    -- SetBackdrop is a native Frame method in TBC Classic (2.x) clients.
    -- It was moved to BackdropTemplateMixin in Shadowlands (9.x) — not relevant here.
    f:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile     = true,
        tileSize = 16,
        edgeSize = 16,
        insets   = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0.05, 0.05, 0.08, 0.90)

    -- Hidden until the player opens it.
    f:Hide()
    APT_Frame = f

    -- Column x positions (pixels from the left edge of the frame).
    local X_LABEL   = 14   -- row label text starts here
    local X_SESSION = 230  -- "Session" values right-align up to here
    local X_OVERALL = 305  -- "Overall" values right-align up to here
    local COL_W     = 60   -- width of each value column

    -- curY tracks the running y offset from the top of the frame.
    local curY = -14

    -- AddFullLine: a single label spanning nearly the full width.
    -- Used for the title and subheader rows.
    local function AddFullLine(key, font)
        local fs = f:CreateFontString(nil, "OVERLAY", font or "GameFontNormal")
        fs:SetPoint("TOPLEFT", f, "TOPLEFT", X_LABEL, curY)
        fs:SetWidth(340)
        fs:SetJustifyH("LEFT")
        APT_Lines[key] = fs
        curY = curY - 18
        return fs
    end

    -- AddDataRow: a row with a left-aligned label and two right-aligned
    -- value columns (Session and Overall).
    -- APT_Lines[key] is stored as { sess = FontString, over = FontString }.
    local function AddDataRow(key, labelText)
        -- Label
        local lbl = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        lbl:SetPoint("TOPLEFT", f, "TOPLEFT", X_LABEL, curY)
        lbl:SetWidth(210)
        lbl:SetJustifyH("LEFT")
        lbl:SetText(labelText)

        -- Session value
        local sess = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        sess:SetPoint("TOPLEFT", f, "TOPLEFT", X_SESSION, curY)
        sess:SetWidth(COL_W)
        sess:SetJustifyH("RIGHT")
        sess:SetText("0")

        -- Overall value
        local over = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        over:SetPoint("TOPLEFT", f, "TOPLEFT", X_OVERALL, curY)
        over:SetWidth(COL_W)
        over:SetJustifyH("RIGHT")
        over:SetText("0")

        APT_Lines[key] = { sess = sess, over = over }
        curY = curY - 18
    end

    -- ---- Build frame content ----

    -- Title
    local title = AddFullLine("title", "GameFontNormalLarge")
    title:SetText("Alchemy Proc Tracker")
    title:SetTextColor(1, 0.85, 0)  -- gold

    -- Subheader: current group and specialization
    local sub = AddFullLine("subhead", "GameFontNormal")
    sub:SetText("Group: ELIXIR  |  Spec: None")
    sub:SetTextColor(0.75, 0.75, 0.75)

    curY = curY - 4  -- small gap before column headers

    -- Column headers (manual placement, not a data row).
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

    curY = curY - 18

    -- Proc count rows
    AddDataRow("procs1", "1x Proc  (+1 extra):")
    AddDataRow("procs2", "2x Proc  (+2 extra):")
    AddDataRow("procs3", "3x Proc  (+3 extra):")
    AddDataRow("procs4", "4x Proc  (+4 extra):")

    curY = curY - 6  -- gap

    -- Summary rows
    AddDataRow("crafts",  "Total Crafts:")
    AddDataRow("potions", "Total Items Produced:")
    AddDataRow("pct",     "Percent Gain:")

    curY = curY - 6  -- gap

    -- Streak rows
    AddDataRow("streak",  "No-Proc Streak:")
    AddDataRow("longest", "Longest No-Proc Streak:")

    -- Close button pinned to the top-right corner.
    local btn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    btn:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
end

-- ============================================================
-- APT_RefreshUI
-- Updates every FontString in the window with current data.
-- Called after each craft finalization and after a reset.
-- Returns early (silently) when the window is hidden.
-- ============================================================

APT_RefreshUI = function()
    if not APT_Frame or not APT_Frame:IsShown() then return end

    local key = GetCharacterKey()
    if not AlchemyProcTrackerDB or not AlchemyProcTrackerDB.characters then return end
    local charDB = AlchemyProcTrackerDB.characters[key]
    if not charDB then return end

    local spec       = charDB.specialization.current or "None"
    local groupStats = charDB.stats[displayGroup]
    if not groupStats then return end

    local se = groupStats.session
    local ov = groupStats.overall

    -- Update subheader to reflect current group and spec.
    APT_Lines["subhead"]:SetText(
        string.format("Group: %s  |  Spec: %s", displayGroup, spec)
    )

    -- Helper: update the session and overall columns for one data row.
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
    SetRow("pct",     CalcPctGain(se),        CalcPctGain(ov))
    SetRow("streak",  se.currentNoProcStreak, ov.currentNoProcStreak)
    SetRow("longest", se.longestNoProcStreak, ov.longestNoProcStreak)
end

-- ============================================================
-- HandleSlashCommand
-- Processes all /apt sub-commands.
-- ============================================================

local function HandleSlashCommand(input)
    -- Trim leading and trailing whitespace.
    local cmd = input:match("^%s*(.-)%s*$")

    if cmd == "" or cmd:lower() == "help" then
        print("|cff00ff00[Alchemy Tracker]|r Commands:")
        print("  /apt show            – open the stats window")
        print("  /apt hide            – close the stats window")
        print("  /apt reset           – reset session stats (overall stats are kept)")
        print("  /apt group <name>    – switch displayed group (FLASK/ELIXIR/POTION/TRANSMUTE)")

    elseif cmd:lower() == "show" then
        if APT_Frame then
            APT_Frame:Show()
            APT_RefreshUI()
        end

    elseif cmd:lower() == "hide" then
        if APT_Frame then
            APT_Frame:Hide()
        end

    elseif cmd:lower() == "reset" then
        ResetSessionStats()

    else
        -- Check for "group <NAME>" sub-command (case-insensitive).
        local groupArg = cmd:match("^[Gg][Rr][Oo][Uu][Pp]%s+(%a+)$")
        if groupArg then
            local g = groupArg:upper()
            if g == "FLASK" or g == "ELIXIR" or g == "POTION" or g == "TRANSMUTE" then
                displayGroup = g
                print(string.format(
                    "|cff00ff00[Alchemy Tracker]|r Displaying group: %s", g
                ))
                if APT_Frame and APT_Frame:IsShown() then
                    APT_RefreshUI()
                end
            else
                print("|cff00ff00[Alchemy Tracker]|r Unknown group. Valid groups: FLASK, ELIXIR, POTION, TRANSMUTE")
            end
        else
            print("|cff00ff00[Alchemy Tracker]|r Unknown command. Type /apt for help.")
        end
    end
end

-- ============================================================
-- Main Event Frame
-- A single frame handles all events the addon needs.
-- ============================================================

local eventFrame = CreateFrame("Frame")

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        -- ADDON_LOADED fires for every addon; ignore others.
        local addonName = ...
        if addonName ~= ADDON_NAME then return end

        -- Saved variables are loaded by now.
        -- Build the flat item lookup from AlchemyTrackerItems.lua first.
        BuildTrackedItemLookup()
        InitCharacterDB()
        DetectAlchemySpecialization()
        CreateUI()
        print("|cff00ff00[Alchemy Tracker]|r Loaded. Type /apt for help.")

    elseif event == "PLAYER_LOGIN" then
        -- Re-detect specialization after the full login sequence completes.
        DetectAlchemySpecialization()

    elseif event == "TRADE_SKILL_SHOW" then
        -- Re-detect when the trade skill window opens.
        -- Useful if the player trained a mastery during this session.
        DetectAlchemySpecialization()

    elseif event == "LEARNED_SPELL_IN_TAB" then
        -- Re-detect when the player learns any new spell (e.g. mastery training).
        DetectAlchemySpecialization()

    elseif event == "CHAT_MSG_SKILL" then
        -- In TBC Classic, alchemy craft creation messages appear in the Skill
        -- channel. If you find they do not trigger here, try CHAT_MSG_SYSTEM
        -- instead (swap the name below and in RegisterEvent()).
        -- verify: CHAT_MSG_SKILL vs CHAT_MSG_SYSTEM for creation messages in TBC Classic
        local msg = ...
        HandleCraftEvent(msg)

    end
end)

-- Register all events the addon uses.
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("TRADE_SKILL_SHOW")
eventFrame:RegisterEvent("LEARNED_SPELL_IN_TAB")
eventFrame:RegisterEvent("CHAT_MSG_SKILL")

-- If "You create" messages appear in the System channel instead of the Skill
-- channel, uncomment the line below and comment out CHAT_MSG_SKILL above:
-- eventFrame:RegisterEvent("CHAT_MSG_SYSTEM")

-- ============================================================
-- Slash Command Registration
-- ============================================================

SLASH_ALCHEMYPROCTRACKER1 = "/apt"
SlashCmdList["ALCHEMYPROCTRACKER"] = HandleSlashCommand
