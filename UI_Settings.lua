-- UI_Settings.lua
-- Compact settings window matching the Figma redesign.

local APT = AlchemyTracker

local S_W   = 380           -- window width
local S_PAD = 14            -- left/right inner padding
local S_IW  = S_W - S_PAD * 2  -- inner content width = 352

-- ============================================================
-- Local helpers
-- ============================================================

local function GetLabel(frame)
    for _, r in ipairs({ frame:GetRegions() }) do
        if r.GetObjectType and r:GetObjectType() == "FontString" then
            return r
        end
    end
end

-- Compact button: dark neutral background, dim amber border, white text.
local function MakeCompactBtn(parent, label, w, h, onClick)
    local OR  = APT.theme.OR
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(w, h)

    local bbg = btn:CreateTexture(nil, "BACKGROUND")
    bbg:SetAllPoints(btn)
    bbg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
    bbg:SetVertexColor(0.10, 0.10, 0.10)
    btn._bbg = bbg

    local function MkEdge(p1, rp1, x1, y1, p2, rp2, x2, y2, isH)
        local b = btn:CreateTexture(nil, "ARTWORK")
        if isH then
            b:SetPoint(p1, btn, rp1, x1, y1)
            b:SetPoint(p2, btn, rp2, x2, y2)
            b:SetHeight(1)
        else
            b:SetPoint(p1, btn, rp1, x1, y1)
            b:SetPoint(p2, btn, rp2, x2, y2)
            b:SetWidth(1)
        end
        b:SetTexture("Interface\\BUTTONS\\WHITE8X8")
        b:SetVertexColor(OR[1] * 0.45, OR[2] * 0.45, OR[3] * 0.45, 0.65)
    end
    MkEdge("TOPLEFT",    "TOPLEFT",    0,  0, "TOPRIGHT",    "TOPRIGHT",    0,  0, true)
    MkEdge("BOTTOMLEFT", "BOTTOMLEFT", 0,  0, "BOTTOMRIGHT", "BOTTOMRIGHT", 0,  0, true)
    MkEdge("TOPLEFT",    "TOPLEFT",    0,  0, "BOTTOMLEFT",  "BOTTOMLEFT",  0,  0, false)
    MkEdge("TOPRIGHT",   "TOPRIGHT",  -1,  0, "BOTTOMRIGHT", "BOTTOMRIGHT", -1, 0, false)

    local btxt = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    btxt:SetAllPoints(btn)
    btxt:SetText(label)
    btxt:SetTextColor(0.90, 0.90, 0.90)   -- neutral-200
    btxt:SetJustifyH("CENTER")
    btn._label = btxt

    btn:SetScript("OnEnter", function() bbg:SetVertexColor(0.18, 0.18, 0.18) end)
    btn:SetScript("OnLeave", function() bbg:SetVertexColor(0.10, 0.10, 0.10) end)
    btn:SetScript("OnClick", onClick or function() end)
    return btn
end

-- Bordered section box with amber-tinted header bar.
-- Returns an inner content Frame to place controls in.
-- The content frame is (S_IW - 8) wide, positioned 18px below box top.
local function MakeSectionBox(parent, label, y, contentH)
    local OR     = APT.theme.OR
    local totalH = 18 + contentH

    local box = CreateFrame("Frame", nil, parent)
    box:SetSize(S_IW, totalH)
    box:SetPoint("TOPLEFT", parent, "TOPLEFT", S_PAD, y)

    local function MkEdge(p1, rp1, x1, y1, p2, rp2, x2, y2, isH)
        local b = box:CreateTexture(nil, "ARTWORK")
        if isH then
            b:SetPoint(p1, box, rp1, x1, y1)
            b:SetPoint(p2, box, rp2, x2, y2)
            b:SetHeight(1)
        else
            b:SetPoint(p1, box, rp1, x1, y1)
            b:SetPoint(p2, box, rp2, x2, y2)
            b:SetWidth(1)
        end
        b:SetTexture("Interface\\BUTTONS\\WHITE8X8")
        b:SetVertexColor(OR[1] * 0.55, OR[2] * 0.55, OR[3] * 0.55, 0.65)
    end
    MkEdge("TOPLEFT",    "TOPLEFT",    0,  0, "TOPRIGHT",    "TOPRIGHT",    0,  0, true)
    MkEdge("BOTTOMLEFT", "BOTTOMLEFT", 0,  0, "BOTTOMRIGHT", "BOTTOMRIGHT", 0,  0, true)
    MkEdge("TOPLEFT",    "TOPLEFT",    0,  0, "BOTTOMLEFT",  "BOTTOMLEFT",  0,  0, false)
    MkEdge("TOPRIGHT",   "TOPRIGHT",  -1,  0, "BOTTOMRIGHT", "BOTTOMRIGHT", -1, 0, false)

    -- Header background
    local hdrBg = box:CreateTexture(nil, "BACKGROUND")
    hdrBg:SetPoint("TOPLEFT",  box, "TOPLEFT",  1, -1)
    hdrBg:SetPoint("TOPRIGHT", box, "TOPRIGHT", -1, -1)
    hdrBg:SetHeight(16)
    hdrBg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
    hdrBg:SetVertexColor(OR[1] * 0.08, OR[2] * 0.08, OR[3] * 0.08)

    -- Divider between header and content
    local hdrDiv = box:CreateTexture(nil, "ARTWORK")
    hdrDiv:SetPoint("TOPLEFT",  box, "TOPLEFT",  1, -17)
    hdrDiv:SetPoint("TOPRIGHT", box, "TOPRIGHT", -1, -17)
    hdrDiv:SetHeight(1)
    hdrDiv:SetTexture("Interface\\BUTTONS\\WHITE8X8")
    hdrDiv:SetVertexColor(OR[1] * 0.40, OR[2] * 0.40, OR[3] * 0.40, 0.55)

    local hdrLbl = box:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hdrLbl:SetPoint("TOPLEFT", box, "TOPLEFT", 6, -2)
    hdrLbl:SetText(label)
    hdrLbl:SetTextColor(0.99, 0.83, 0.30)   -- amber-300

    local content = CreateFrame("Frame", nil, box)
    content:SetPoint("TOPLEFT",     box, "TOPLEFT",     4, -18)
    content:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -4,  0)

    return content
end

-- Bordered checkbox tile: dark card with small checkbox square + label.
-- Returns a Refresh() function.
local function MakeTileCheckbox(parent, label, x, y, w, getF, setF)
    local OR   = APT.theme.OR
    local tile = CreateFrame("Button", nil, parent)
    tile:SetSize(w, 22)
    tile:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)

    local tileBg = tile:CreateTexture(nil, "BACKGROUND")
    tileBg:SetAllPoints(tile)
    tileBg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
    tileBg:SetVertexColor(0.10, 0.10, 0.10)

    local function MkEdge(p1, rp1, x1, y1, p2, rp2, x2, y2, isH)
        local b = tile:CreateTexture(nil, "ARTWORK")
        if isH then
            b:SetPoint(p1, tile, rp1, x1, y1)
            b:SetPoint(p2, tile, rp2, x2, y2)
            b:SetHeight(1)
        else
            b:SetPoint(p1, tile, rp1, x1, y1)
            b:SetPoint(p2, tile, rp2, x2, y2)
            b:SetWidth(1)
        end
        b:SetTexture("Interface\\BUTTONS\\WHITE8X8")
        b:SetVertexColor(OR[1] * 0.42, OR[2] * 0.42, OR[3] * 0.42, 0.55)
    end
    MkEdge("TOPLEFT",    "TOPLEFT",    0,  0, "TOPRIGHT",    "TOPRIGHT",    0,  0, true)
    MkEdge("BOTTOMLEFT", "BOTTOMLEFT", 0,  0, "BOTTOMRIGHT", "BOTTOMRIGHT", 0,  0, true)
    MkEdge("TOPLEFT",    "TOPLEFT",    0,  0, "BOTTOMLEFT",  "BOTTOMLEFT",  0,  0, false)
    MkEdge("TOPRIGHT",   "TOPRIGHT",  -1,  0, "BOTTOMRIGHT", "BOTTOMRIGHT", -1, 0, false)

    local cbBg = tile:CreateTexture(nil, "ARTWORK")
    cbBg:SetSize(10, 10)
    cbBg:SetPoint("LEFT", tile, "LEFT", 6, 0)
    cbBg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
    cbBg:SetVertexColor(0.18, 0.18, 0.18)

    local cbCheck = tile:CreateTexture(nil, "OVERLAY")
    cbCheck:SetSize(10, 10)
    cbCheck:SetPoint("LEFT", tile, "LEFT", 6, 0)
    cbCheck:SetTexture("Interface\\BUTTONS\\WHITE8X8")
    cbCheck:SetVertexColor(OR[1], OR[2], OR[3])

    local lbl = tile:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lbl:SetPoint("LEFT",  tile, "LEFT",  20, 0)
    lbl:SetPoint("RIGHT", tile, "RIGHT", -4, 0)
    lbl:SetText(label)
    lbl:SetTextColor(0.90, 0.90, 0.90)   -- neutral-200
    lbl:SetJustifyH("LEFT")
    lbl:SetWordWrap(false)

    local function Refresh()
        cbCheck:SetAlpha(getF() and 1 or 0)
    end

    tile:SetScript("OnClick",  function() setF(not getF()); Refresh() end)
    tile:SetScript("OnEnter",  function() tileBg:SetVertexColor(0.16, 0.16, 0.16) end)
    tile:SetScript("OnLeave",  function() tileBg:SetVertexColor(0.10, 0.10, 0.10) end)
    Refresh()
    return Refresh
end

-- Slider with inline number EditBox.  y is relative to parent TOPLEFT.
-- Occupies ~42px vertically (54px if warnF provided).
-- Returns a Refresh() function.
local function MakeSliderInput(parent, label, x, y, w, minV, maxV, step, getF, setF, fmtF, warnF)
    local OR = APT.theme.OR
    fmtF = fmtF or function(v) return string.format("%.1f", v) end

    -- Row 1: label (left) + editable value (right)
    local lblFS = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lblFS:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    lblFS:SetText(label)
    lblFS:SetTextColor(0.83, 0.83, 0.83)   -- neutral-300

    local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    eb:SetSize(42, 14)
    eb:SetPoint("TOPRIGHT", parent, "TOPLEFT", x + w, y + 1)
    eb:SetAutoFocus(false)
    eb:SetMaxLetters(6)

    -- Track strip
    local track = parent:CreateTexture(nil, "BACKGROUND")
    track:SetPoint("TOPLEFT",  parent, "TOPLEFT", x,     y - 20)
    track:SetPoint("TOPRIGHT", parent, "TOPLEFT", x + w, y - 20)
    track:SetHeight(3)
    track:SetTexture("Interface\\BUTTONS\\WHITE8X8")
    track:SetVertexColor(0.22, 0.22, 0.22)

    -- Slider
    local sl = CreateFrame("Slider", nil, parent)
    sl:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y - 14)
    sl:SetSize(w, 14)
    sl:SetOrientation("HORIZONTAL")
    sl:SetMinMaxValues(minV, maxV)
    sl:SetValueStep(step)
    sl:EnableMouseWheel(true)
    sl:SetThumbTexture("Interface\\BUTTONS\\WHITE8X8")
    local thumb = sl.GetThumbTexture and sl:GetThumbTexture()
    if thumb then thumb:SetSize(8, 18); thumb:SetVertexColor(OR[1], OR[2], OR[3]) end

    -- Row 3: min/max endpoint labels
    local minFS = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    minFS:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y - 30)
    minFS:SetText(fmtF(minV))
    minFS:SetTextColor(0.45, 0.45, 0.45)   -- neutral-500

    local maxFS = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    maxFS:SetPoint("TOPRIGHT", parent, "TOPLEFT", x + w, y - 30)
    maxFS:SetJustifyH("RIGHT")
    maxFS:SetText(fmtF(maxV))
    maxFS:SetTextColor(0.45, 0.45, 0.45)   -- neutral-500

    -- Optional warning row (always at y-42, only shows text when condition met)
    local warnFS
    if warnF then
        warnFS = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        warnFS:SetPoint("TOPLEFT",  parent, "TOPLEFT",  x,     y - 42)
        warnFS:SetPoint("TOPRIGHT", parent, "TOPLEFT",  x + w, y - 42)
        warnFS:SetHeight(12)
        warnFS:SetTextColor(0.97, 0.44, 0.44)   -- red-400
        warnFS:SetJustifyH("LEFT")
        warnFS:SetWordWrap(false)
        warnFS:SetText("")
    end

    local _updating = false

    local function Apply(val)
        local snapped = math.floor(val / step + 0.5) * step
        snapped = math.max(minV, math.min(maxV, snapped))
        setF(snapped)
        eb:SetText(fmtF(snapped))
        if warnFS then warnFS:SetText(warnF(snapped) or "") end
        return snapped
    end

    sl:SetScript("OnValueChanged", function(self, val)
        if _updating then return end
        local snapped = Apply(val)
        _updating = true; self:SetValue(snapped); _updating = false
    end)

    sl:SetScript("OnMouseWheel", function(self, delta)
        self:SetValue(math.max(minV, math.min(maxV, self:GetValue() + delta * step)))
    end)

    eb:SetScript("OnEnterPressed", function(self)
        local val = tonumber(self:GetText())
        if val then
            local snapped = Apply(val)
            _updating = true; sl:SetValue(snapped); _updating = false
        else
            self:SetText(fmtF(getF()))
        end
        self:ClearFocus()
    end)
    eb:SetScript("OnEscapePressed", function(self)
        self:SetText(fmtF(getF())); self:ClearFocus()
    end)
    eb:SetScript("OnEditFocusLost", function(self)
        self:SetText(fmtF(getF()))
    end)

    -- Initialise
    local initVal = getF()
    _updating = true; sl:SetValue(initVal); _updating = false
    eb:SetText(fmtF(initVal))
    if warnFS then warnFS:SetText(warnF(initVal) or "") end

    return function()
        local v = getF()
        _updating = true; sl:SetValue(v); _updating = false
        eb:SetText(fmtF(v))
        if warnFS then warnFS:SetText(warnF(v) or "") end
    end
end

-- ============================================================
-- APT:CreateSettingsUI
-- ============================================================
function APT:CreateSettingsUI()
    local DrawBorders          = APT.DrawBorders
    local MakeFrameCloseButton = APT.MakeFrameCloseButton
    local MakeDivider          = APT.MakeDivider
    local OR                   = APT.theme.OR

    local f = CreateFrame("Frame", "APT_SettingsFrame", UIParent, "BackdropTemplate")
    f:SetSize(S_W, 100)   -- height set dynamically below
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

    -- ── Header (40 px tall) ────────────────────────────────────
    local hdrBg = f:CreateTexture(nil, "BACKGROUND")
    hdrBg:SetPoint("TOPLEFT",  f, "TOPLEFT",  1, -1)
    hdrBg:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, -1)
    hdrBg:SetHeight(40)
    hdrBg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
    hdrBg:SetVertexColor(0.04, 0.04, 0.04)

    MakeFrameCloseButton(f)

    -- Gear glyph + title
    local gearLbl = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    gearLbl:SetPoint("TOPLEFT", f, "TOPLEFT", S_PAD, -8)
    gearLbl:SetText("\226\154\153")   -- ⚙ U+2699
    gearLbl:SetTextColor(OR[1], OR[2], OR[3])

    local titleLbl = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleLbl:SetPoint("TOPLEFT", gearLbl, "TOPRIGHT", 4, 0)
    titleLbl:SetText("Addon Settings")
    titleLbl:SetTextColor(OR[1], OR[2], OR[3])

    local subLbl = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    subLbl:SetPoint("TOPLEFT", f, "TOPLEFT", S_PAD, -24)
    subLbl:SetText("Configure your alchemy tracker preferences")
    subLbl:SetTextColor(0.64, 0.64, 0.64)   -- neutral-400

    MakeDivider(f, 1, -40, -1)

    local curY = -44   -- content starts here

    -- ── Action buttons — row 1 (3 columns) ───────────────────
    -- widths: floor((352 - 8) / 3) = 114 px each, 4 px gaps
    local w3 = math.floor((S_IW - 8) / 3)   -- 114

    local toggleBtn = MakeCompactBtn(f, "Hide Window", w3, 22, nil)
    toggleBtn:SetPoint("TOPLEFT", f, "TOPLEFT", S_PAD, curY)
    toggleBtn:SetScript("OnClick", function()
        if APT.frame then
            if APT.frame:IsShown() then
                APT.frame:Hide()
                toggleBtn._label:SetText("Show Window")
            else
                APT.frame:Show()
                APT.RefreshUI()
                toggleBtn._label:SetText("Hide Window")
            end
        end
    end)

    local histBtn = MakeCompactBtn(f, "Browse History", w3, 22, function()
        if APT.frame and APT.SwitchTab then
            APT.frame:Show(); APT.SwitchTab("overall")
        end
    end)
    histBtn:SetPoint("TOPLEFT", f, "TOPLEFT", S_PAD + w3 + 4, curY)

    local testBtn = MakeCompactBtn(f, "Test Data", w3, 22, function()
        APT.InjectTestData()
        APT:Print("Test data injected.")
    end)
    testBtn:SetPoint("TOPLEFT", f, "TOPLEFT", S_PAD + w3 * 2 + 8, curY)

    curY = curY - 22 - 3   -- -69

    -- ── Action buttons — row 2 (2 columns) ───────────────────
    local w2 = math.floor((S_IW - 4) / 2)   -- 174

    local resetSessBtn = MakeCompactBtn(f, "Reset Session", w2, 22, APT.ResetSessionStats)
    resetSessBtn:SetPoint("TOPLEFT", f, "TOPLEFT", S_PAD, curY)

    -- "Reset All" with 2-second confirm
    local resetAllBtn
    local _raPending, _raTimer = false, nil
    resetAllBtn = MakeCompactBtn(f, "Reset All", w2, 22, function()
        if _raPending then
            _raPending = false
            if _raTimer then _raTimer:Cancel(); _raTimer = nil end
            resetAllBtn._label:SetText("Reset All")
            resetAllBtn._bbg:SetVertexColor(0.10, 0.10, 0.10)
            APT.ResetAllStats()
        else
            _raPending = true
            resetAllBtn._label:SetText("Are you sure?")
            resetAllBtn._bbg:SetVertexColor(0.60, 0.11, 0.11)   -- red-800/80
            _raTimer = C_Timer.NewTimer(2, function()
                _raPending = false; _raTimer = nil
                resetAllBtn._label:SetText("Reset All")
                resetAllBtn._bbg:SetVertexColor(0.10, 0.10, 0.10)
            end)
        end
    end)
    resetAllBtn:SetPoint("TOPLEFT", f, "TOPLEFT", S_PAD + w2 + 4, curY)

    curY = curY - 22 - 5   -- -96

    -- ── Interface Options section ─────────────────────────────
    -- 2×2 grid of tile checkboxes, 22 px each, 3 px row gap, 4 px padding
    -- contentH = 4 + 22 + 3 + 22 + 4 = 55
    local ifContent = MakeSectionBox(f, "Interface Options", curY, 55)
    local tileW = math.floor((S_IW - 8 - 4) / 2)   -- content width=344, (344-4)/2=170

    local refreshMiniCB = MakeTileCheckbox(ifContent, "Minimap Button", 0, -4, tileW,
        function() return not APT.db.global.minimap.hide end,
        function(val)
            APT.db.global.minimap.hide = not val
            local LibDBIcon = LibStub("LibDBIcon-1.0", true)
            if LibDBIcon then
                if val then LibDBIcon:Show("AlchemyTracker")
                else         LibDBIcon:Hide("AlchemyTracker") end
            end
        end)

    local refreshDebugCB = MakeTileCheckbox(ifContent, "Debug Mode", tileW + 4, -4, tileW,
        function() return APT.debugMode end,
        function(val)
            APT.debugMode = val
            APT.db.char.debugMode = val
        end)

    local refreshBestItemCB = MakeTileCheckbox(ifContent, "Show Best Item", 0, -29, tileW,
        function() return APT.db.char.settings.showBestFlask end,
        function(val)
            APT.db.char.settings.showBestFlask = val
            if APT.RefreshHistory then APT.RefreshHistory() end
        end)

    local refreshAHCutCB = MakeTileCheckbox(ifContent, "Include AH Cut (5%)", tileW + 4, -29, tileW,
        function() return APT.db.char.settings.priceEstimator.ahFee ~= false end,
        function(val)
            APT.db.char.settings.priceEstimator.ahFee = val
            if APT.RefreshPriceEstimator then APT.RefreshPriceEstimator() end
        end)

    curY = curY - (18 + 55) - 5   -- -174

    -- ── Detection & Session section ───────────────────────────
    -- Each slider: label(14) + slider(14) + minmax(12) + warning(12) = 52 px
    -- contentH = 4 + 52 + 4 = 60
    local detContent = MakeSectionBox(f, "Detection & Session", curY, 60)
    local slW = math.floor((S_IW - 8 - 4) / 2)   -- 170

    local refreshCraftSl = MakeSliderInput(detContent,
        "Craft Window (s)", 0, -4, slW,
        0.1, 2.0, 0.1,
        function() return APT.db.char.settings.craftWindow end,
        function(v) APT.db.char.settings.craftWindow = v end,
        function(v) return string.format("%.1f", v) end,
        function(v)
            return v <= 0.3 and "\226\154\160 Too low — server lag may cause missed procs" or nil
        end)

    local refreshTimeoutSl = MakeSliderInput(detContent,
        "Session Timeout (min)", slW + 4, -4, slW,
        1, 30, 1,
        function() return math.max(1, math.min(30, math.floor(APT.db.char.settings.sessionTimeout / 60 + 0.5))) end,
        function(v) APT.db.char.settings.sessionTimeout = v * 60 end,
        function(v) return string.format("%d", v) end)

    curY = curY - (18 + 60) - 5   -- -257

    -- ── Storage Caps section ──────────────────────────────────
    -- No warning row; contentH = 4 + 40 + 4 = 48
    local stgContent = MakeSectionBox(f, "Storage Caps", curY, 48)

    local refreshMaxSessSl = MakeSliderInput(stgContent,
        "Max Saved Sessions", 0, -4, slW,
        10, 500, 10,
        function() return APT.db.char.settings.maxSessions end,
        function(v) APT.db.char.settings.maxSessions = v end,
        function(v) return string.format("%d", v) end)

    local refreshMaxItemsSl = MakeSliderInput(stgContent,
        "Max Items per Group", slW + 4, -4, slW,
        10, 500, 10,
        function() return APT.db.char.settings.maxItemsPerGroup end,
        function(v) APT.db.char.settings.maxItemsPerGroup = v end,
        function(v) return string.format("%d", v) end)

    curY = curY - (18 + 48)   -- -323

    -- Fit frame to content
    f:SetHeight(math.abs(curY) + S_PAD)

    -- ── OnShow: sync all controls to current DB state ─────────
    f:SetScript("OnShow", function()
        toggleBtn._label:SetText(
            (APT.frame and APT.frame:IsShown()) and "Hide Window" or "Show Window")
        refreshMiniCB()
        refreshDebugCB()
        refreshBestItemCB()
        refreshAHCutCB()
        refreshCraftSl()
        refreshTimeoutSl()
        refreshMaxSessSl()
        refreshMaxItemsSl()
    end)
end

-- ============================================================
-- APT.OpenSettings
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
