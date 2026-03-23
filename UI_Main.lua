-- UI_Main.lua
-- Unified tabbed window: Session / Overall / Settings tabs in a
-- bordered container at top-right (Figma style).
-- Session and Overall switch main-frame content; Settings opens
-- the separate settings window.

local APT = AlchemyTracker

-- ============================================================
-- Layout constants
-- ============================================================
local M_DEF_W   = 340   -- widened to fit individual-bordered tab buttons + coins
local M_DEF_H   = 217
local OVR_DEF_W = 620
local OVR_DEF_H = 440
local M_MIN_W   = 220
local M_MIN_H   = 150
local OVR_MIN_W = 400
local OVR_MIN_H = 200
local M_ROW_H   = 18
local M_PAD     = 12
local CONTENT_Y = -45   -- below header + divider

-- Individual tab button dimensions (Figma style — each tab has its own border)
local TAB_W  = 52   -- each tab button width (icon glyph + text)
local TAB_H  = 20   -- tab button height
local N_TABS = 3    -- Session / History / Settings

local Lines = {}

-- ============================================================
-- APT.SwitchTab
-- "settings" opens the float window; "session"/"overall" switch
-- main frame content.
-- ============================================================
APT.SwitchTab = function(tab)
    -- Settings is a launch button, not a content switch
    if tab == "settings" then
        if APT.OpenSettings then APT.OpenSettings() end
        return
    end

    local f = APT.frame
    if not f then return end
    f._activeTab = tab
    local isSession = (tab == "session")

    -- Show / hide content sub-panels
    if f.sessionPanel then f.sessionPanel:SetShown(isSession) end
    if f.overallPanel  then f.overallPanel:SetShown(not isSession) end

    -- PE panel: only on session tab
    if f._pePanel then
        if not isSession then
            f._pePanel:Hide()
        elseif APT.db and APT.db.char and APT.db.char.settings.priceEstimator.enabled then
            f._pePanel:Show()
        end
    end

    -- Resize frame
    local peH = (isSession and f._pePanel and f._pePanel:IsShown()) and APT.PANEL_H or 0
    if isSession then
        f:SetSize(M_DEF_W, M_DEF_H + peH)
    else
        f:SetSize(OVR_DEF_W, OVR_DEF_H)
    end

    -- Tab bar highlight: reset all content tabs, then highlight active
    if f._tabBtns then
        for key, btn in pairs(f._tabBtns) do
            if key ~= "settings" then
                btn._bbg:SetVertexColor(0.06, 0.06, 0.06)
                btn._lbl:SetTextColor(0.64, 0.64, 0.64)   -- neutral-400
            end
        end
        if f._tabBtns[tab] then
            f._tabBtns[tab]._bbg:SetVertexColor(0.22, 0.12, 0.02)   -- amber-900/40
            f._tabBtns[tab]._lbl:SetTextColor(0.99, 0.83, 0.30)     -- amber-300
        end
    end

    if isSession then
        APT.RefreshUI()
    else
        if APT.RefreshHistory then APT.RefreshHistory() end
    end
end

-- ============================================================
-- APT.RefreshUI
-- ============================================================
APT.RefreshUI = function()
    if not APT.frame or not APT.frame:IsShown() then return end
    if APT.frame._activeTab ~= "session" then return end

    local sess = APT.CombineAllStats("session")
    local tc   = sess.totalCrafts

    local tiers = {
        { key = "BASE", count = tc           },
        { key = "X2",   count = sess.procs1  },
        { key = "X3",   count = sess.procs2  },
        { key = "X4",   count = sess.procs3  },
        { key = "X5",   count = sess.procs4  },
    }
    for _, t in ipairs(tiers) do
        if Lines[t.key] then Lines[t.key]:SetText(tostring(t.count)) end
    end

    if Lines["TOTAL_CRAFTS"] then
        Lines["TOTAL_CRAFTS"]:SetText(tostring(tc + sess.totalExtra))
    end

    if Lines["PCT_GAIN"] then
        if tc > 0 then
            Lines["PCT_GAIN"]:SetText(string.format("%.1f%%", sess.totalExtra / tc * 100))
        else
            Lines["PCT_GAIN"]:SetText("0.0%")
        end
    end

    if APT.RefreshPriceEstimator then APT.RefreshPriceEstimator() end
end

-- ============================================================
-- APT:CreateUI
-- ============================================================
function APT:CreateUI()
    local MakeDivider   = APT.MakeDivider
    local MakeResizeGrip = APT.MakeResizeGrip
    local OR            = APT.theme.OR

    local f = CreateFrame("Frame", "AlchemyProcTrackerFrame", UIParent, "BackdropTemplate")

    local wp = APT.db.char.windowPos
    f:SetSize(wp and wp.w or M_DEF_W, wp and wp.h or M_DEF_H)
    if wp then
        f:SetPoint(wp.point, UIParent, wp.relPoint or wp.point, wp.x, wp.y)
    else
        f:SetPoint("TOPRIGHT", UIParent, "CENTER", -10, 200)
    end
    f._defW, f._defH = M_DEF_W, M_DEF_H
    f._activeTab     = "session"

    f:SetFrameStrata("HIGH")
    f:SetMovable(true)
    f:SetResizable(true)
    f:SetToplevel(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetClampedToScreen(true)
    f:Hide()
    APT.frame = f

    f:SetScript("OnShow", function() APT.SwitchTab(f._activeTab or "session") end)
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        APT.SaveWindowPos(f, "windowPos")
    end)

    local _clamp = false
    f:SetScript("OnSizeChanged", function(self, w, h)
        if _clamp then return end
        local minW = (self._activeTab == "overall") and OVR_MIN_W or M_MIN_W
        local minH = (self._activeTab == "overall") and OVR_MIN_H or M_MIN_H
        local nw, nh = math.max(w, minW), math.max(h, minH)
        if nw ~= w or nh ~= h then
            _clamp = true; self:SetSize(nw, nh); _clamp = false
        end
        if self.UpdateScrollbar then self.UpdateScrollbar() end
    end)

    -- ── Background ─────────────────────────────────────────────
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(f)
    bg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
    bg:SetVertexColor(0.09, 0.09, 0.09)
    bg:SetAlpha(0.97)

    APT.DrawBorders(f)

    -- ── Header strip ───────────────────────────────────────────
    local hdrBg = f:CreateTexture(nil, "BACKGROUND")
    hdrBg:SetPoint("TOPLEFT",  f, "TOPLEFT",  1, -1)
    hdrBg:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, -1)
    hdrBg:SetHeight(28)
    hdrBg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
    hdrBg:SetVertexColor(0.04, 0.04, 0.04)

    -- ── Close button (red, Figma style) ────────────────────────
    local closeBtn = CreateFrame("Button", nil, f)
    closeBtn:SetSize(18, 18)
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -6)

    local cBg = closeBtn:CreateTexture(nil, "BACKGROUND")
    cBg:SetAllPoints(closeBtn)
    cBg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
    cBg:SetVertexColor(0.73, 0.11, 0.11)   -- bg-red-700

    local function MkCloseBorder(p1, rp1, x1, y1, p2, rp2, x2, y2, isH)
        local b = closeBtn:CreateTexture(nil, "ARTWORK")
        if isH then
            b:SetPoint(p1, closeBtn, rp1, x1, y1)
            b:SetPoint(p2, closeBtn, rp2, x2, y2)
            b:SetHeight(1)
        else
            b:SetPoint(p1, closeBtn, rp1, x1, y1)
            b:SetPoint(p2, closeBtn, rp2, x2, y2)
            b:SetWidth(1)
        end
        b:SetTexture("Interface\\BUTTONS\\WHITE8X8")
        b:SetVertexColor(0.50, 0.11, 0.11)   -- red-900
    end
    MkCloseBorder("TOPLEFT",    "TOPLEFT",    0,  0, "TOPRIGHT",    "TOPRIGHT",    0,  0, true)
    MkCloseBorder("BOTTOMLEFT", "BOTTOMLEFT", 0,  0, "BOTTOMRIGHT", "BOTTOMRIGHT", 0,  0, true)
    MkCloseBorder("TOPLEFT",    "TOPLEFT",    0,  0, "BOTTOMLEFT",  "BOTTOMLEFT",  0,  0, false)
    MkCloseBorder("TOPRIGHT",   "TOPRIGHT",  -1,  0, "BOTTOMRIGHT", "BOTTOMRIGHT", -1, 0, false)

    local cX = closeBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    cX:SetAllPoints(closeBtn)
    cX:SetText("X")
    cX:SetTextColor(1, 1, 1)
    closeBtn:SetScript("OnEnter", function() cBg:SetVertexColor(0.90, 0.20, 0.20) end)
    closeBtn:SetScript("OnLeave", function() cBg:SetVertexColor(0.73, 0.11, 0.11) end)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    -- ── Individual tab buttons (Figma style — each has its own border) ──
    -- Icons use Arial Narrow for better Unicode glyph coverage.
    -- Layout from right: [close 20px +8gap] +2gap [Settings][History][Session]
    -- Each tab 52px wide, 2px gap between → 3×52+2×2=160px for tab group
    -- close+gap = 30px → tab group right edge at -30 from frame right
    local tabDefs = {
        { key = "session",  label = "\226\154\151 Session"  },  -- ⚗
        { key = "overall",  label = "\226\140\155 History"  },  -- ⌛
        { key = "settings", label = "\226\154\153 Settings" },  -- ⚙
    }

    -- Shared helper: draw a 1px border line on a button
    local function MkTabEdge(btn_, p1, rp1, x1, y1, p2, rp2, x2, y2, isH)
        local b = btn_:CreateTexture(nil, "ARTWORK")
        if isH then
            b:SetPoint(p1, btn_, rp1, x1, y1)
            b:SetPoint(p2, btn_, rp2, x2, y2)
            b:SetHeight(1)
        else
            b:SetPoint(p1, btn_, rp1, x1, y1)
            b:SetPoint(p2, btn_, rp2, x2, y2)
            b:SetWidth(1)
        end
        b:SetTexture("Interface\\BUTTONS\\WHITE8X8")
        b:SetVertexColor(OR[1] * 0.55, OR[2] * 0.55, OR[3] * 0.55, 0.65)
        return b
    end

    f._tabBtns = {}
    for i, def in ipairs(tabDefs) do
        local btn = CreateFrame("Button", nil, f)
        btn:SetSize(TAB_W, TAB_H)
        -- Settings=rightmost (i=3), Session=leftmost (i=1)
        -- TOPRIGHT x-offset: -(8+20+2) − (N_TABS−i)×(TAB_W+2)
        local rx = -(8 + 20 + 2) - (N_TABS - i) * (TAB_W + 2)
        btn:SetPoint("TOPRIGHT", f, "TOPRIGHT", rx, -4)

        local bbg = btn:CreateTexture(nil, "BACKGROUND")
        bbg:SetAllPoints(btn)
        bbg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
        bbg:SetVertexColor(0.06, 0.06, 0.06)
        btn._bbg = bbg

        MkTabEdge(btn, "TOPLEFT",    "TOPLEFT",    0,  0, "TOPRIGHT",    "TOPRIGHT",    0,  0, true)
        MkTabEdge(btn, "BOTTOMLEFT", "BOTTOMLEFT", 0,  0, "BOTTOMRIGHT", "BOTTOMRIGHT", 0,  0, true)
        MkTabEdge(btn, "TOPLEFT",    "TOPLEFT",    0,  0, "BOTTOMLEFT",  "BOTTOMLEFT",  0,  0, false)
        MkTabEdge(btn, "TOPRIGHT",   "TOPRIGHT",  -1,  0, "BOTTOMRIGHT", "BOTTOMRIGHT", -1, 0, false)

        local blbl = btn:CreateFontString(nil, "OVERLAY")
        blbl:SetFont("Fonts\\ARIALN.TTF", 9)
        blbl:SetAllPoints(btn)
        blbl:SetText(def.label)
        blbl:SetTextColor(0.64, 0.64, 0.64)   -- neutral-400 inactive
        blbl:SetJustifyH("CENTER")
        btn._lbl = blbl

        btn:SetScript("OnEnter", function()
            if def.key == "settings" or f._activeTab ~= def.key then
                bbg:SetVertexColor(0.14, 0.14, 0.14)
            end
        end)
        btn:SetScript("OnLeave", function()
            if def.key ~= "settings" and f._activeTab == def.key then
                bbg:SetVertexColor(0.22, 0.12, 0.02)
            else
                bbg:SetVertexColor(0.06, 0.06, 0.06)
            end
        end)
        btn:SetScript("OnClick", function() APT.SwitchTab(def.key) end)

        f._tabBtns[def.key] = btn
    end

    -- Default: Session tab active (amber-900/40 bg + amber-300 text)
    f._tabBtns["session"]._bbg:SetVertexColor(0.22, 0.12, 0.02)
    f._tabBtns["session"]._lbl:SetTextColor(0.99, 0.83, 0.30)

    -- ── Coins button (left-anchored next to title, Figma style) ─
    -- Will be anchored to title's RIGHT edge after title is created below.
    local coinsBtn = CreateFrame("Button", nil, f)
    coinsBtn:SetSize(18, 18)
    -- Anchor set after title is created (see below)

    local coinsBg = coinsBtn:CreateTexture(nil, "BACKGROUND")
    coinsBg:SetAllPoints(coinsBtn)
    coinsBg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
    coinsBg:SetVertexColor(0.10, 0.10, 0.10)

    local function MkCoinsBorder(p1, rp1, x1, y1, p2, rp2, x2, y2, isH)
        local b = coinsBtn:CreateTexture(nil, "ARTWORK")
        if isH then
            b:SetPoint(p1, coinsBtn, rp1, x1, y1)
            b:SetPoint(p2, coinsBtn, rp2, x2, y2)
            b:SetHeight(1)
        else
            b:SetPoint(p1, coinsBtn, rp1, x1, y1)
            b:SetPoint(p2, coinsBtn, rp2, x2, y2)
            b:SetWidth(1)
        end
        b:SetTexture("Interface\\BUTTONS\\WHITE8X8")
        b:SetVertexColor(OR[1] * 0.35, OR[2] * 0.35, OR[3] * 0.35, 0.60)
    end
    MkCoinsBorder("TOPLEFT",    "TOPLEFT",    0,  0, "TOPRIGHT",    "TOPRIGHT",    0,  0, true)
    MkCoinsBorder("BOTTOMLEFT", "BOTTOMLEFT", 0,  0, "BOTTOMRIGHT", "BOTTOMRIGHT", 0,  0, true)
    MkCoinsBorder("TOPLEFT",    "TOPLEFT",    0,  0, "BOTTOMLEFT",  "BOTTOMLEFT",  0,  0, false)
    MkCoinsBorder("TOPRIGHT",   "TOPRIGHT",  -1,  0, "BOTTOMRIGHT", "BOTTOMRIGHT", -1, 0, false)

    local coinsTxt = coinsBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    coinsTxt:SetAllPoints(coinsBtn)
    coinsTxt:SetText("$")
    coinsTxt:SetTextColor(OR[1] * 0.80, OR[2] * 0.80, OR[3] * 0.80)

    coinsBtn:SetScript("OnEnter", function() coinsBg:SetVertexColor(0.22, 0.22, 0.22) end)
    coinsBtn:SetScript("OnLeave", function()
        if f._pePanel and f._pePanel:IsShown() then
            coinsBg:SetVertexColor(OR[1] * 0.22, OR[2] * 0.14, OR[3] * 0.03)
        else
            coinsBg:SetVertexColor(0.10, 0.10, 0.10)
        end
    end)
    coinsBtn:SetScript("OnClick", function()
        if APT.TogglePriceEstimator then APT.TogglePriceEstimator() end
        if f._pePanel and f._pePanel:IsShown() then
            coinsBg:SetVertexColor(OR[1] * 0.22, OR[2] * 0.14, OR[3] * 0.03)
        else
            coinsBg:SetVertexColor(0.10, 0.10, 0.10)
        end
    end)
    f._coinsBtn   = coinsBtn
    f._coinsBtnBg = coinsBg

    -- ── Title ──────────────────────────────────────────────────
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", f, "TOPLEFT", M_PAD, -7)
    title:SetText("Alchemy Tracker")
    title:SetTextColor(OR[1], OR[2], OR[3])

    -- Anchor coins button immediately right of title (Figma: left cluster)
    coinsBtn:SetPoint("LEFT", title, "RIGHT", 6, 0)

    -- ── Divider below header ───────────────────────────────────
    MakeDivider(f, 1, -35, -1)

    -- ── Session Panel ──────────────────────────────────────────
    local sp = CreateFrame("Frame", nil, f)
    sp:SetPoint("TOPLEFT",     f, "TOPLEFT",     0, CONTENT_Y)
    sp:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
    f.sessionPanel = sp

    local curY = -2

    local sessLbl = sp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sessLbl:SetPoint("TOPLEFT", sp, "TOPLEFT", M_PAD, curY)
    sessLbl:SetText("Session:")
    sessLbl:SetTextColor(0.64, 0.64, 0.64)   -- neutral-400

    local sessVal = sp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sessVal:SetPoint("TOPRIGHT", sp, "TOPRIGHT", -M_PAD, curY)
    sessVal:SetJustifyH("RIGHT")
    sessVal:SetText("Current Session")
    sessVal:SetTextColor(1, 1, 1)
    curY = curY - M_ROW_H

    local subdiv = sp:CreateTexture(nil, "ARTWORK")
    subdiv:SetPoint("TOPLEFT",  sp, "TOPLEFT",  M_PAD,  curY - 3)
    subdiv:SetPoint("TOPRIGHT", sp, "TOPRIGHT", -M_PAD, curY - 3)
    subdiv:SetHeight(1)
    subdiv:SetTexture("Interface\\BUTTONS\\WHITE8X8")
    subdiv:SetVertexColor(0.40, 0.22, 0.03, 0.22)
    curY = curY - 12

    local PROC_ROWS = {
        { key = "BASE", label = "Base Craft:" },
        { key = "X2",   label = "x2:"         },
        { key = "X3",   label = "x3:"         },
        { key = "X4",   label = "x4:"         },
        { key = "X5",   label = "x5:"         },
    }
    for _, row in ipairs(PROC_ROWS) do
        local lbl = sp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetPoint("TOPLEFT", sp, "TOPLEFT", M_PAD, curY)
        lbl:SetText(row.label)
        lbl:SetTextColor(0.83, 0.83, 0.83)   -- neutral-300

        local val = sp:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        val:SetPoint("TOPRIGHT", sp, "TOPRIGHT", -M_PAD, curY)
        val:SetJustifyH("RIGHT")
        val:SetTextColor(1, 1, 1)
        Lines[row.key] = val
        curY = curY - M_ROW_H
    end

    curY = curY - 4
    MakeDivider(sp, M_PAD, curY, -M_PAD)
    curY = curY - 10

    local tcLbl = sp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tcLbl:SetPoint("TOPLEFT", sp, "TOPLEFT", M_PAD, curY)
    tcLbl:SetText("Total Crafts:")
    tcLbl:SetTextColor(0.64, 0.64, 0.64)   -- neutral-400

    local tcVal = sp:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    tcVal:SetPoint("TOPRIGHT", sp, "TOPRIGHT", -M_PAD, curY)
    tcVal:SetJustifyH("RIGHT")
    tcVal:SetTextColor(1, 1, 1)
    Lines["TOTAL_CRAFTS"] = tcVal
    curY = curY - M_ROW_H

    local pgLbl = sp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pgLbl:SetPoint("TOPLEFT", sp, "TOPLEFT", M_PAD, curY)
    pgLbl:SetText("% Gain:")
    pgLbl:SetTextColor(APT.theme.GRN[1], APT.theme.GRN[2], APT.theme.GRN[3])

    local pgVal = sp:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    pgVal:SetPoint("TOPRIGHT", sp, "TOPRIGHT", -M_PAD, curY)
    pgVal:SetJustifyH("RIGHT")
    pgVal:SetTextColor(APT.theme.GRN[1], APT.theme.GRN[2], APT.theme.GRN[3])
    Lines["PCT_GAIN"] = pgVal

    MakeResizeGrip(f, function(frame)
        APT.SaveWindowPos(frame, "windowPos")
        if frame.UpdateScrollbar then frame.UpdateScrollbar() end
    end)

    if APT.CreatePriceEstimatorPanel then APT.CreatePriceEstimatorPanel(f) end
    if APT.CreateHistoryPanel        then APT.CreateHistoryPanel(f)        end
end
