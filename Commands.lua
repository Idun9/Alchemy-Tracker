-- Commands.lua
-- Slash command handler and minimap button.

local APT = AlchemyTracker

-- ============================================================
-- APT.InjectTestData
-- Populates fake sessions and stats for UI preview.
-- Called by /apt testdata and the Settings "Load Test Data" button.
-- ============================================================
function APT.InjectTestData()
    if not APT.db or not APT.db.char then return end

    local sessionDefs = APT.TEST_SESSIONS
    if not sessionDefs then
        APT:Print("|cffff4444No test data found.|r Add TestData.lua to your .toc and /reload once.")
        return
    end

    local function buildStats(def)
        local out = {}
        for _, g in ipairs(APT.GROUPS_ORDER) do
            local items, tc, tp, te = {}, 0, 0, 0
            for _, it in ipairs(def[g] or {}) do
                items[it.n] = { name=it.n, totalCrafts=it.tc, totalPotions=it.tp, totalExtra=it.te }
                tc = tc+it.tc; tp = tp+it.tp; te = te+it.te
            end
            out[g] = { totalCrafts=tc, totalPotions=tp, totalExtra=te, items=items }
        end
        return out
    end

    -- Populate sessions
    APT.db.char.sessions = {}
    for i, sd in ipairs(sessionDefs) do
        APT.db.char.sessions[i] = { id=i, date=sd.date, duration=sd.duration,
                                     customName=sd.customName, stats=buildStats(sd) }
    end
    APT.db.char.nextSessionID  = #sessionDefs
    APT.db.char.expandedSessions = {}

    -- Overall + current-session stats
    for _, g in ipairs(APT.GROUPS_ORDER) do
        APT.db.char.stats[g] = APT.db.char.stats[g] or {}
        local tc, tp, te = 0, 0, 0
        for _, sd in ipairs(sessionDefs) do
            for _, it in ipairs(sd[g] or {}) do tc=tc+it.tc; tp=tp+it.tp; te=te+it.te end
        end
        -- procs1 = te: treat every extra item as a separate +1 proc (conservative but consistent)
        APT.db.char.stats[g].overall = { totalCrafts=tc, totalPotions=tp, totalExtra=te,
            procs1=te, procs2=0, procs3=0, procs4=0 }
        local last = sessionDefs[#sessionDefs]
        local ltc, ltp, lte, litems = 0, 0, 0, {}
        for _, it in ipairs(last[g] or {}) do
            ltc=ltc+it.tc; ltp=ltp+it.tp; lte=lte+it.te
            litems[it.n] = { name=it.n, totalCrafts=it.tc, totalPotions=it.tp, totalExtra=it.te }
        end
        APT.db.char.stats[g].session = { totalCrafts=ltc, totalPotions=ltp, totalExtra=lte,
            procs1=lte, procs2=0, procs3=0, procs4=0, items=litems }
    end

    -- Open both windows side by side
    APT.db.char.windowPos  = false
    APT.db.char.historyPos = false
    if APT.frame then
        APT.frame:SetSize(APT.frame._defW or 300, APT.frame._defH or 217)
        APT.frame:ClearAllPoints()
        APT.frame:SetPoint("TOPRIGHT", UIParent, "CENTER", -10, 200)
        APT.frame:Show()
    end
    if APT.historyFrame then
        APT.historyFrame:SetSize(APT.historyFrame._defW or 500, APT.historyFrame._defH or 440)
        APT.historyFrame:ClearAllPoints()
        APT.historyFrame:SetPoint("TOPLEFT", UIParent, "CENTER", 10, 200)
        APT.historyFrame:Show()
    end
    if APT.InvalidateStatsCache then APT.InvalidateStatsCache() end
    if APT.RefreshUI             then APT.RefreshUI()             end
    if APT.RefreshHistory        then APT.RefreshHistory()        end
end

-- Two-step confirmation state for /apt reset all
local _resetAllPending = false
local _resetAllTimer   = nil

-- ============================================================
-- Minimap Right-Click Dropdown
-- ============================================================
local MinimapMenuFrame

local function ShowMinimapMenu(anchor)
    if not MinimapMenuFrame then
        MinimapMenuFrame = CreateFrame("Frame", "APT_MinimapMenuFrame", UIParent, "UIDropDownMenuTemplate")
    end

    UIDropDownMenu_Initialize(MinimapMenuFrame, function()
        local info

        info = UIDropDownMenu_CreateInfo()
        info.text = "Alchemy Tracker"
        info.isTitle = true; info.notCheckable = true
        UIDropDownMenu_AddButton(info)

        info = UIDropDownMenu_CreateInfo()
        info.text = "Show Stats Window"
        info.notCheckable = true
        info.func = function()
            if APT.frame then APT.frame:Show(); APT.RefreshUI() end
            CloseDropDownMenus()
        end
        UIDropDownMenu_AddButton(info)

        info = UIDropDownMenu_CreateInfo()
        info.text = "Hide Stats Window"
        info.notCheckable = true
        info.func = function()
            if APT.frame then APT.frame:Hide() end
            CloseDropDownMenus()
        end
        UIDropDownMenu_AddButton(info)

        info = UIDropDownMenu_CreateInfo()
        info.text = "Session History"
        info.notCheckable = true
        info.func = function()
            if APT.historyFrame then
                APT.historyFrame:Show()
                APT.RefreshHistory()
            end
            CloseDropDownMenus()
        end
        UIDropDownMenu_AddButton(info)

        info = UIDropDownMenu_CreateInfo()
        info.text = "Reset"
        info.isTitle = true; info.notCheckable = true
        UIDropDownMenu_AddButton(info)

        info = UIDropDownMenu_CreateInfo()
        info.text = "Reset Session Stats"
        info.notCheckable = true
        info.func = function() APT.ResetSessionStats(); CloseDropDownMenus() end
        UIDropDownMenu_AddButton(info)

        info = UIDropDownMenu_CreateInfo()
        info.text = "Open Options"
        info.notCheckable = true
        info.func = function() APT.OpenSettings(); CloseDropDownMenus() end
        UIDropDownMenu_AddButton(info)
    end, "MENU")

    ToggleDropDownMenu(1, nil, MinimapMenuFrame, anchor, 0, 0)
end

-- ============================================================
-- APT:RegisterMinimapButton  (LibDataBroker + LibDBIcon)
-- ============================================================
function APT:RegisterMinimapButton()
    local ldbLib    = LibStub("LibDataBroker-1.1", true)
    local LibDBIcon = LibStub("LibDBIcon-1.0", true)
    if not ldbLib or not LibDBIcon then return end

    local ldb = ldbLib:NewDataObject("AlchemyTracker", {
        type = "launcher",
        text = "Alchemy Tracker",
        icon = "Interface\\AddOns\\AlchemyTracker\\icon\\alchemy-256x256",
        OnClick = function(self, button)
            if button == "RightButton" then
                ShowMinimapMenu(self)
            else
                if APT.frame then
                    if APT.frame:IsShown() then
                        APT.frame:Hide()
                    else
                        APT.frame:Show()
                        APT.RefreshUI()
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
-- APT:HandleSlashCommand
-- ============================================================
function APT:HandleSlashCommand(input)
    local cmd      = input:match("^%s*(.-)%s*$")
    local cmdLower = cmd:lower()

    if cmdLower == "" or cmdLower == "help" then
        local _meta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
        local ver   = (_meta and _meta(APT.ADDON_NAME, "Version")) or "?"
        self:Print(string.format("v%s — TBC Classic alchemy mastery proc tracker", ver))
        self:Print("  |cffffd700/apt|r                 — show this help")
        self:Print("  |cffffd700/apt show|r             — open the stats window")
        self:Print("  |cffffd700/apt hide|r             — close the stats window")
        self:Print("  |cffffd700/apt reset|r            — reset session stats (overall kept)")
        self:Print("  |cffffd700/apt reset all|r        — reset ALL stats including overall")
        self:Print("  |cffffd700/apt history|r          — open the session history browser")
        self:Print("  |cffffd700/apt testdata|r         — inject fake data for UI preview")
        self:Print("  |cffffd700/apt export|r           — pre-fill chat box with session summary")
        self:Print("  |cffffd700/apt resetpos|r         — reset window positions to default")
        self:Print("  |cffffd700/apt spec|r              — show detected alchemy specialization")
        self:Print("  |cffffd700/apt debug|r             — toggle debug mode")

    elseif cmdLower == "resetpos" then
        APT.db.char.windowPos  = false
        APT.db.char.historyPos = false
        if APT.frame then
            APT.frame:SetSize(APT.frame._defW or 380, APT.frame._defH or 250)
            APT.frame:ClearAllPoints()
            APT.frame:SetPoint("TOPRIGHT", UIParent, "CENTER", -10, 200)
        end
        if APT.historyFrame then
            APT.historyFrame:SetSize(APT.historyFrame._defW or 500, APT.historyFrame._defH or 440)
            APT.historyFrame:ClearAllPoints()
            APT.historyFrame:SetPoint("TOPLEFT", UIParent, "CENTER", 10, 200)
        end
        self:Print("Window positions reset.")

    elseif cmdLower == "show" then
        if APT.frame then APT.frame:Show(); APT.RefreshUI() end

    elseif cmdLower == "hide" then
        if APT.frame then APT.frame:Hide() end

    elseif cmdLower == "reset" then
        APT.ResetSessionStats()

    elseif cmdLower == "reset all" then
        if _resetAllPending then
            _resetAllPending = false
            if _resetAllTimer then _resetAllTimer:Cancel(); _resetAllTimer = nil end
            APT.ResetAllStats()
        else
            _resetAllPending = true
            self:Print("|cffff4444WARNING:|r This will wipe ALL stats including overall.")
            self:Print("Type |cffffd700/apt reset all|r again within 10 seconds to confirm.")
            _resetAllTimer = C_Timer.NewTimer(10, function()
                _resetAllPending = false
                _resetAllTimer   = nil
                APT:Print("Reset cancelled (timed out).")
            end)
        end

    elseif cmdLower == "history" then
        if APT.historyFrame then
            APT.historyFrame:Show()
            APT.RefreshHistory()
        end

    elseif cmdLower == "spec" then
        local spec = APT.db.char.specialization
        if spec.current == "None" then
            self:Print("|cffff8800No alchemy mastery detected.|r Craft tracking is disabled.")
            self:Print("Make sure you have Elixir, Potion, or Transmute Mastery and try |cffffd700/apt spec|r again after opening the trade skill window.")
        else
            self:Print(string.format("Detected specialization: |cff00ff00%s Mastery|r", spec.current))
        end

    elseif cmdLower == "testdata" then
        APT.InjectTestData()
        self:Print("Test data injected — 5 sessions, 10 items. Windows opened side by side.")

    elseif cmdLower == "export" then
        local sess = APT.CombineAllStats("session")
        if sess.totalCrafts == 0 then
            self:Print("No crafts this session to export.")
        else
            local spec    = APT.db.char.specialization.current
            local specStr = spec ~= "None" and (spec .. " Master") or "No Mastery"
            local procPct = sess.totalCrafts > 0
                and (sess.totalExtra / sess.totalCrafts * 100) or 0
            local msg = string.format(
                "[AlchemyTracker] %s | %d crafts | %d items | x2:%d x3:%d x4:%d x5+:%d | %.1f%% proc rate",
                specStr, sess.totalCrafts, sess.totalPotions,
                sess.procs1, sess.procs2, sess.procs3, sess.procs4, procPct)
            -- Pre-fill the chat input box so the player can post or copy
            if ChatFrame1EditBox then
                ChatFrame1EditBox:Show()
                ChatFrame1EditBox:SetText(msg)
                ChatFrame1EditBox:SetFocus()
            else
                self:Print(msg)
            end
        end

    else
        self:Print("Unknown command. Type /apt for help.")
    end
end

-- /rl shortcut for /reload
SLASH_RL1 = "/rl"
SlashCmdList["RL"] = function() ReloadUI() end
