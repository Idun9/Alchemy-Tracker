-- UI_Settings.lua
-- Custom settings window matching the addon's orange/dark theme.
-- Replaces the Blizzard Interface Options panel.

local APT = AlchemyTracker

local S_W   = 380   -- fixed window width
local S_PAD = 14    -- left/right inner padding

-- ============================================================
-- Local helpers
-- ============================================================

-- Returns the first FontString region found on a frame.
local function GetLabel(frame)
    for _, r in ipairs({ frame:GetRegions() }) do
        if r.GetObjectType and r:GetObjectType() == "FontString" then
            return r
        end
    end
end

-- Wraps MakeNavButton and caches its FontString as btn._label.
local function MakeBtn(parent, label, w, h, onClick)
    local btn = APT.MakeNavButton(parent, label, w, h, onClick)
    btn._label = GetLabel(btn)
    return btn
end

-- Creates a small square checkbox with a label to its right.
-- Returns a Refresh() function that syncs the visual state.
local function MakeCheckbox(parent, label, x, y, getF, setF)
    local OR  = APT.theme.OR
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(14, 14)
    btn:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)

    local box = btn:CreateTexture(nil, "BACKGROUND")
    box:SetAllPoints()
    box:SetTexture("Interface\\BUTTONS\\WHITE8X8")
    box:SetVertexColor(0.20, 0.20, 0.20)

    local check = btn:CreateTexture(nil, "OVERLAY")
    check:SetAllPoints()
    check:SetTexture("Interface\\BUTTONS\\WHITE8X8")
    check:SetVertexColor(OR[1], OR[2], OR[3])

    local lbl = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lbl:SetPoint("LEFT", btn, "RIGHT", 5, 0)
    lbl:SetText(label)
    lbl:SetTextColor(1, 1, 1)

    local function Refresh()
        check:SetAlpha(getF() and 1 or 0)
    end

    btn:SetScript("OnClick", function()
        setF(not getF())
        Refresh()
    end)
    btn:SetScript("OnEnter", function() box:SetVertexColor(0.35, 0.35, 0.35) end)
    btn:SetScript("OnLeave", function() box:SetVertexColor(0.20, 0.20, 0.20) end)

    Refresh()
    return Refresh
end

-- Creates a labelled horizontal slider with a current-value readout and
-- min/max endpoint labels.  Returns a Refresh() function.
local function MakeSlider(parent, label, x, y, w, minV, maxV, step, getF, setF, fmtF)
    local OR = APT.theme.OR
    fmtF = fmtF or function(v) return string.format("%.1f", v) end

    -- Row 1: descriptor label (left) + current value (right)
    local lblFS = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lblFS:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    lblFS:SetText(label)
    lblFS:SetTextColor(0.76, 0.76, 0.76)

    local valFS = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    valFS:SetPoint("TOPRIGHT", parent, "TOPLEFT", x + w, y)
    valFS:SetJustifyH("RIGHT")
    valFS:SetTextColor(OR[1], OR[2], OR[3])

    -- Coloured track strip behind the slider thumb
    local track = parent:CreateTexture(nil, "BACKGROUND")
    track:SetPoint("TOPLEFT",  parent, "TOPLEFT", x,     y - 22)
    track:SetPoint("TOPRIGHT", parent, "TOPLEFT", x + w, y - 22)
    track:SetHeight(4)
    track:SetTexture("Interface\\BUTTONS\\WHITE8X8")
    track:SetVertexColor(0.22, 0.22, 0.22)

    -- Slider frame
    local sl = CreateFrame("Slider", nil, parent)
    sl:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y - 16)
    sl:SetSize(w, 16)
    sl:SetOrientation("HORIZONTAL")
    sl:SetMinMaxValues(minV, maxV)
    sl:SetValueStep(step)
    sl:EnableMouseWheel(true)
    sl:SetThumbTexture("Interface\\BUTTONS\\WHITE8X8")

    local thumb = sl.GetThumbTexture and sl:GetThumbTexture()
    if thumb then
        thumb:SetSize(10, 20)
        thumb:SetVertexColor(OR[1], OR[2], OR[3])
    end

    -- Row 3: min/max endpoint labels
    local minFS = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    minFS:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y - 32)
    minFS:SetText(fmtF(minV))
    minFS:SetTextColor(0.45, 0.45, 0.45)

    local maxFS = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    maxFS:SetPoint("TOPRIGHT", parent, "TOPLEFT", x + w, y - 32)
    maxFS:SetJustifyH("RIGHT")
    maxFS:SetText(fmtF(maxV))
    maxFS:SetTextColor(0.45, 0.45, 0.45)

    -- Guard against recursive OnValueChanged calls from SetValue() in Refresh.
    local _updating = false

    sl:SetScript("OnValueChanged", function(self, val)
        if _updating then return end
        local snapped = math.floor(val / step + 0.5) * step
        snapped = math.max(minV, math.min(maxV, snapped))
        setF(snapped)
        valFS:SetText(fmtF(snapped))
    end)

    sl:SetScript("OnMouseWheel", function(self, delta)
        self:SetValue(math.max(minV, math.min(maxV, self:GetValue() + delta * step)))
    end)

    -- Initialise display
    local initVal = getF()
    sl:SetValue(initVal)
    valFS:SetText(fmtF(initVal))

    return function()
        local v = getF()
        _updating = true
        sl:SetValue(v)
        _updating = false
        valFS:SetText(fmtF(v))
    end
end

-- ============================================================
-- APT:CreateSettingsUI
-- Called once from OnInitialize; builds the frame and hides it.
-- ============================================================
function APT:CreateSettingsUI()
    local DrawBorders          = APT.DrawBorders
    local MakeFrameCloseButton = APT.MakeFrameCloseButton
    local MakeDivider          = APT.MakeDivider
    local OR                   = APT.theme.OR

    local f = CreateFrame("Frame", "APT_SettingsFrame", UIParent, "BackdropTemplate")
    f:SetSize(S_W, 100)  -- height set dynamically below
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetFrameStrata("HIGH")
    f:SetMovable(true)
    f:SetToplevel(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetClampedToScreen(true)
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop",  f.StopMovingOrSizing)
    f:Hide()
    APT.settingsFrame = f

    -- Background
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(f)
    bg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
    bg:SetVertexColor(0.09, 0.09, 0.09)
    bg:SetAlpha(0.97)

    DrawBorders(f)

    -- Header strip
    local hdrBg = f:CreateTexture(nil, "BACKGROUND")
    hdrBg:SetPoint("TOPLEFT",  f, "TOPLEFT",  1, -1)
    hdrBg:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, -1)
    hdrBg:SetHeight(28)
    hdrBg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
    hdrBg:SetVertexColor(0.04, 0.04, 0.04)

    MakeFrameCloseButton(f)

    local curY = -7

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", f, "TOPLEFT", S_PAD, curY)
    title:SetText("Alchemy Tracker  —  Settings")
    title:SetTextColor(1, 0.76, 0.18)
    curY = curY - 28

    MakeDivider(f, 1, curY, -1)
    curY = curY - 4

    -- ── section header helper (modifies curY upvalue) ───────────
    local function SectionHeader(label)
        local hbg = f:CreateTexture(nil, "BACKGROUND")
        hbg:SetPoint("TOPLEFT",  f, "TOPLEFT",  1, curY)
        hbg:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, curY)
        hbg:SetHeight(18)
        hbg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
        hbg:SetVertexColor(OR[1] * 0.12, OR[2] * 0.12, OR[3] * 0.12)

        local lbl = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetPoint("TOPLEFT", f, "TOPLEFT", S_PAD, curY - 2)
        lbl:SetText(label)
        lbl:SetTextColor(OR[1], OR[2], OR[3])
        curY = curY - 20
    end

    -- ── Window ───────────────────────────────────────────────────
    SectionHeader("Window")

    local toggleBtn
    toggleBtn = MakeBtn(f, "Show Stats Window", S_W - S_PAD * 2, 20, function()
        if APT.frame then
            if APT.frame:IsShown() then
                APT.frame:Hide()
                if toggleBtn._label then toggleBtn._label:SetText("Show Stats Window") end
            else
                APT.frame:Show()
                APT.RefreshUI()
                if toggleBtn._label then toggleBtn._label:SetText("Hide Stats Window") end
            end
        end
    end)
    toggleBtn:SetPoint("TOPLEFT", f, "TOPLEFT", S_PAD, curY)
    curY = curY - 28

    -- ── Session History ───────────────────────────────────────────
    SectionHeader("Session History")

    local histBtn
    histBtn = MakeBtn(f, "Browse Session History", S_W - S_PAD * 2, 20, function()
        if APT.historyFrame then
            APT.historyFrame:Show()
            APT.RefreshHistory()
        end
    end)
    histBtn:SetPoint("TOPLEFT", f, "TOPLEFT", S_PAD, curY)
    curY = curY - 28

    -- ── Reset ─────────────────────────────────────────────────────
    SectionHeader("Reset")

    local btnW = math.floor((S_W - S_PAD * 2 - 8) / 2)

    local function MakeConfirmBtn(label, xPos, action)
        local pending, timer = false, nil
        local btn = MakeBtn(f, label, btnW, 20, nil)
        btn:SetPoint("TOPLEFT", f, "TOPLEFT", xPos, curY)
        btn:SetScript("OnClick", function()
            if pending then
                pending = false
                if timer then timer:Cancel(); timer = nil end
                if btn._label then btn._label:SetText(label) end
                action()
            else
                pending = true
                if btn._label then btn._label:SetText("Are you sure?") end
                timer = C_Timer.NewTimer(2, function()
                    pending = false
                    timer   = nil
                    if btn._label then btn._label:SetText(label) end
                end)
            end
        end)
        return btn
    end

    MakeConfirmBtn("Reset Session Stats", S_PAD,            APT.ResetSessionStats)
    MakeConfirmBtn("Reset All Stats",     S_PAD + btnW + 8, APT.ResetAllStats)
    curY = curY - 28

    -- ── Interface ─────────────────────────────────────────────────
    SectionHeader("Interface")

    local refreshMiniCB = MakeCheckbox(f, "Show Minimap Button", S_PAD, curY,
        function() return not APT.db.global.minimap.hide end,
        function(val)
            APT.db.global.minimap.hide = not val
            local LibDBIcon = LibStub("LibDBIcon-1.0", true)
            if LibDBIcon then
                if val then LibDBIcon:Show("AlchemyTracker")
                else         LibDBIcon:Hide("AlchemyTracker")
                end
            end
        end)

    local refreshDebugCB = MakeCheckbox(f, "Debug Mode", S_W / 2, curY,
        function() return APT.debugMode end,
        function(val) APT.debugMode = val end)

    curY = curY - 28

    -- ── Detection & Session ───────────────────────────────────────
    SectionHeader("Detection & Session")

    local slW = math.floor((S_W - S_PAD * 2 - 12) / 2)

    local refreshCraftSl = MakeSlider(f, "Craft Window (s)",
        S_PAD, curY, slW, 0.1, 2.0, 0.1,
        function() return APT.db.char.settings.craftWindow end,
        function(v) APT.db.char.settings.craftWindow = v end,
        function(v) return string.format("%.1f", v) end)

    local refreshTimeoutSl = MakeSlider(f, "Session Timeout (min)",
        S_PAD + slW + 12, curY, slW, 5, 120, 5,
        function() return APT.db.char.settings.sessionTimeout / 60 end,
        function(v) APT.db.char.settings.sessionTimeout = v * 60 end,
        function(v) return string.format("%d", v) end)

    curY = curY - 48

    -- ── Storage Caps ──────────────────────────────────────────────
    SectionHeader("Storage Caps")

    local refreshMaxSessSl = MakeSlider(f, "Max Saved Sessions",
        S_PAD, curY, slW, 10, 500, 10,
        function() return APT.db.char.settings.maxSessions end,
        function(v) APT.db.char.settings.maxSessions = v end,
        function(v) return string.format("%d", v) end)

    local refreshMaxItemsSl = MakeSlider(f, "Max Items per Group",
        S_PAD + slW + 12, curY, slW, 10, 500, 10,
        function() return APT.db.char.settings.maxItemsPerGroup end,
        function(v) APT.db.char.settings.maxItemsPerGroup = v end,
        function(v) return string.format("%d", v) end)

    curY = curY - 48

    -- Bottom Close button
    local closeBtn = APT.MakeNavButton(f, "Close", 80, 22, function() f:Hide() end)
    closeBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -S_PAD, S_PAD)

    -- Size the frame to exactly fit the content
    f:SetHeight(math.abs(curY) + 36)

    -- ── OnShow: sync all dynamic content ─────────────────────────
    f:SetScript("OnShow", function()
        -- Window toggle label
        if toggleBtn._label then
            toggleBtn._label:SetText(
                (APT.frame and APT.frame:IsShown())
                and "Hide Stats Window" or "Show Stats Window")
        end

        -- Session history button label
        local n = APT.db and APT.db.char.sessions and #APT.db.char.sessions or 0
        if histBtn._label then
            histBtn._label:SetText(string.format("Browse Session History  (%d saved)", n))
        end

        -- Checkboxes and sliders
        refreshMiniCB()
        refreshDebugCB()
        refreshCraftSl()
        refreshTimeoutSl()
        refreshMaxSessSl()
        refreshMaxItemsSl()
    end)
end

-- ============================================================
-- APT.OpenSettings  (called from slash command / minimap menu)
-- ============================================================
function APT.OpenSettings()
    if APT.settingsFrame then
        if APT.settingsFrame:IsShown() then
            APT.settingsFrame:Hide()
        else
            APT.settingsFrame:Show()
        end
    end
end
