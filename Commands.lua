-- Commands.lua
-- Slash command handler, minimap button, and AceConfig options panel.

local APT = AlchemyTracker

-- Two-step confirmation state for /apt reset all
local _resetAllPending = false
local _resetAllTimer   = nil

-- ============================================================
-- Helpers used by the options panel
-- ============================================================
local function FormatGroupSummary(s, groupName)
    if s.totalCrafts == 0 then
        return string.format("|cffffd700%s:|r  No data", groupName)
    end
    return string.format("|cffffd700%s:|r  %d crafts  •  %s proc chance",
        groupName, s.totalCrafts, APT.CalcPctGain(s))
end

local function BuildOverallDescription()
    if not APT.db then return "" end
    local lines = {}
    for _, g in ipairs(APT.GROUPS_ORDER) do
        local gs = APT.db.char.stats[g]
        if gs then lines[#lines + 1] = FormatGroupSummary(gs.overall, g) end
    end
    return table.concat(lines, "\n")
end

-- ============================================================
-- OpenOptions
-- ============================================================
local function OpenOptions()
    local AceConfigDialog = LibStub("AceConfigDialog-3.0", true)
    if AceConfigDialog then AceConfigDialog:Open("AlchemyTracker") end
end

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
        info.text = "Reset All Stats"
        info.notCheckable = true
        info.func = function() APT.ResetAllStats(); CloseDropDownMenus() end
        UIDropDownMenu_AddButton(info)

        info = UIDropDownMenu_CreateInfo()
        info.text = "Open Options"
        info.notCheckable = true
        info.func = function() OpenOptions(); CloseDropDownMenus() end
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
        icon = "Interface\\AddOns\\AlchemyTracker\\icon\\alchemy-300x300CroppedExtracted_uncompressed",
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
-- APT:RegisterOptions  (AceConfig-3.0 + AceConfigDialog-3.0)
-- ============================================================
function APT:RegisterOptions()
    local AceConfig       = LibStub("AceConfig-3.0", true)
    local AceConfigDialog = LibStub("AceConfigDialog-3.0", true)
    if not AceConfig or not AceConfigDialog then return end

    local options = {
        type = "group",
        name = "Alchemy Tracker",
        args = {
            -- ── Window ──────────────────────────────────────────
            windowHeader = { type="header", name="Window", order=1 },
            toggleWindow = {
                type  = "execute",
                name  = function()
                    return (APT.frame and APT.frame:IsShown())
                        and "Hide Stats Window" or "Show Stats Window"
                end,
                func  = function()
                    if APT.frame then
                        if APT.frame:IsShown() then APT.frame:Hide()
                        else APT.frame:Show(); APT.RefreshUI()
                        end
                    end
                end,
                order = 2,
            },

            -- ── Overall Stats ────────────────────────────────────
            overallHeader = { type="header", name="Overall Stats", order=10 },
            overallDesc = {
                type     = "description",
                name     = function() return BuildOverallDescription() end,
                fontSize = "medium",
                order    = 11,
            },

            -- ── Session History ──────────────────────────────────
            sessionHeader = { type="header", name="Session History", order=20 },
            browseHistory = {
                type  = "execute",
                name  = function()
                    local n = APT.db and APT.db.char.sessions and #APT.db.char.sessions or 0
                    return string.format("Browse Session History  (%d saved)", n)
                end,
                desc  = "Open the session history browser  (/apt history)",
                func  = function()
                    if APT.historyFrame then
                        APT.historyFrame:Show()
                        APT.RefreshHistory()
                    end
                end,
                order = 21,
            },

            -- ── Reset ────────────────────────────────────────────
            resetHeader  = { type="header", name="Reset", order=30 },
            resetSession = {
                type  = "execute",
                name  = "Reset Session Stats",
                desc  = "Save current session to history and reset session stats  (/apt reset)",
                func  = function() APT.ResetSessionStats() end,
                order = 31,
            },
            resetAll = {
                type        = "execute",
                name        = "Reset All Stats",
                desc        = "Reset ALL stats including overall — history is kept  (/apt reset all)",
                confirm     = true,
                confirmText = "Are you sure you want to reset ALL stats, including overall? Session history will be kept.",
                func        = function() APT.ResetAllStats() end,
                order       = 32,
            },

            -- ── Interface ────────────────────────────────────────
            interfaceHeader = { type="header", name="Interface", order=40 },
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
                        else         LibDBIcon:Hide("AlchemyTracker")
                        end
                    end
                end,
                order = 41,
            },
            debugMode = {
                type  = "toggle",
                name  = "Debug Mode",
                desc  = "Enable debug chat output for craft events  (/apt debug)",
                get   = function() return APT.debugMode end,
                set   = function(_, val) APT.debugMode = val end,
                order = 42,
            },

            -- ── Detection & Session ──────────────────────────────
            timersHeader = { type = "header", name = "Detection & Session", order = 50 },
            craftWindow = {
                type  = "range",
                name  = "Craft Window",
                desc  = "Seconds to wait after 'You create' for proc loot messages before finalising the craft.",
                min   = 0.1, max = 2.0, step = 0.1,
                get   = function() return APT.db.char.settings.craftWindow end,
                set   = function(_, val) APT.db.char.settings.craftWindow = val end,
                order = 51,
            },
            sessionTimeout = {
                type  = "range",
                name  = "Session Timeout (minutes)",
                desc  = "Minutes of trade-skill inactivity before the next craft opens a new session.",
                min   = 5, max = 120, step = 5,
                get   = function() return APT.db.char.settings.sessionTimeout / 60 end,
                set   = function(_, val) APT.db.char.settings.sessionTimeout = val * 60 end,
                order = 52,
            },

            -- ── Storage Caps ─────────────────────────────────────
            storageHeader = { type = "header", name = "Storage Caps", order = 60 },
            maxSessions = {
                type  = "range",
                name  = "Max Saved Sessions",
                desc  = "Maximum number of past sessions kept in history. Oldest sessions are pruned when the limit is exceeded.",
                min   = 10, max = 500, step = 10,
                get   = function() return APT.db.char.settings.maxSessions end,
                set   = function(_, val) APT.db.char.settings.maxSessions = val end,
                order = 61,
            },
            maxItemsPerGroup = {
                type  = "range",
                name  = "Max Items per Group",
                desc  = "Maximum unique items tracked per craft group per session. The item with fewest crafts is evicted when the cap is reached.",
                min   = 10, max = 500, step = 10,
                get   = function() return APT.db.char.settings.maxItemsPerGroup end,
                set   = function(_, val) APT.db.char.settings.maxItemsPerGroup = val end,
                order = 62,
            },
        },
    }

    AceConfig:RegisterOptionsTable("AlchemyTracker", options)
    AceConfigDialog:AddToBlizOptions("AlchemyTracker", "Alchemy Tracker")
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

    elseif cmdLower == "debug" then
        APT.debugMode = not APT.debugMode
        self:Print("Debug mode: " .. (APT.debugMode
            and "|cff00ff00ON|r — craft now to see events in chat."
            or  "|cffff4444OFF|r"))

    elseif cmdLower == "testdata" then
        -- Inject realistic TBC fake data so the UI can be previewed
        local fakeItems = {
            FLASK    = { { name="Flask of Fortification",   totalCrafts=18, totalPotions=26, totalExtra=8  },
                         { name="Flask of Relentless Assault", totalCrafts=12, totalPotions=16, totalExtra=4  } },
            ELIXIR   = { { name="Elixir of Major Agility",  totalCrafts=25, totalPotions=34, totalExtra=9  },
                         { name="Elixir of Major Strength", totalCrafts=10, totalPotions=13, totalExtra=3  } },
            POTION   = { { name="Super Healing Potion",     totalCrafts=30, totalPotions=42, totalExtra=12 },
                         { name="Super Mana Potion",        totalCrafts=20, totalPotions=27, totalExtra=7  } },
            TRANSMUTE= { { name="Primal Might",             totalCrafts= 5, totalPotions= 7, totalExtra=2  } },
        }

        local function makeStats(mult)
            local out = {}
            for _, g in ipairs(APT.GROUPS_ORDER) do
                local items = {}
                local tc, tp, te = 0, 0, 0
                for _, it in ipairs(fakeItems[g] or {}) do
                    local itc = math.floor(it.totalCrafts  * mult)
                    local itp = math.floor(it.totalPotions * mult)
                    local ite = math.floor(it.totalExtra   * mult)
                    items[it.name] = { name=it.name, totalCrafts=itc, totalPotions=itp, totalExtra=ite }
                    tc = tc + itc;  tp = tp + itp;  te = te + ite
                end
                out[g] = { totalCrafts=tc, totalPotions=tp, totalExtra=te, items=items }
            end
            return out
        end

        -- Current session stats (drives the main window)
        for _, g in ipairs(APT.GROUPS_ORDER) do
            APT.db.char.stats[g] = APT.db.char.stats[g] or {}
            local s = makeStats(1)[g]
            APT.db.char.stats[g].session = {
                totalCrafts  = s.totalCrafts,
                totalPotions = s.totalPotions,
                totalExtra   = s.totalExtra,
                procs1 = math.floor(s.totalCrafts * 0.20),
                procs2 = math.floor(s.totalCrafts * 0.08),
                procs3 = math.floor(s.totalCrafts * 0.02),
                procs4 = 0,
            }
            local ov = makeStats(4)[g]
            APT.db.char.stats[g].overall = {
                totalCrafts  = ov.totalCrafts,
                totalPotions = ov.totalPotions,
                totalExtra   = ov.totalExtra,
                procs1 = math.floor(ov.totalCrafts * 0.20),
                procs2 = math.floor(ov.totalCrafts * 0.08),
                procs3 = math.floor(ov.totalCrafts * 0.02),
                procs4 = 0,
            }
        end

        -- Three fake past sessions
        APT.db.char.sessions = {}
        local dates = { "2026-03-09 14:22", "2026-03-10 19:05", "2026-03-11 21:38" }
        local names = { nil, "Flask Farm Run", nil }
        for i = 1, 3 do
            table.insert(APT.db.char.sessions, {
                id         = i,
                date       = dates[i],
                customName = names[i],
                stats      = makeStats(0.5 + i * 0.3),
            })
        end

        -- Reset positions/sizes so windows open side by side cleanly
        APT.db.char.windowPos  = false
        APT.db.char.historyPos = false
        if APT.frame then
            APT.frame:SetSize(APT.frame._defW or 380, APT.frame._defH or 250)
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
        APT.InvalidateStatsCache()
        APT.RefreshUI()
        APT.RefreshHistory()
        self:Print("Test data injected. Windows repositioned side by side.")

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
