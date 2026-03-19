-- UI_Main.lua
-- The main stats window: shows current session proc-tier breakdown,
-- total crafts, total items, and % gain.

local APT = AlchemyTracker

-- ============================================================
-- Layout constants
-- ============================================================
local M_DEF_W = 300  -- default window width on first open
local M_DEF_H = 217  -- default window height on first open
local M_MIN_W = 200  -- minimum width enforced during resize
local M_MIN_H = 217  -- minimum height enforced during resize
local M_ROW_H = 18   -- height of each data row
local M_PAD   = 12   -- left/right inner padding

-- Line value widgets (populated by CreateUI, read by RefreshUI)
local Lines = {}

-- ============================================================
-- APT.RefreshUI
-- Reads combined session stats and updates every text widget.
-- No-ops when the window is hidden.
-- ============================================================
APT.RefreshUI = function()
    if not APT.frame or not APT.frame:IsShown() then return end

    local sess   = APT.CombineAllStats("session")
    local tc     = sess.totalCrafts

    local visible = tc > 0

    local noProc = tc - sess.procs1 - sess.procs2 - sess.procs3 - sess.procs4

    local tiers = {
        { key = "BASE", count = noProc      },
        { key = "X2",   count = sess.procs1 },
        { key = "X3",   count = sess.procs2 },
        { key = "X4",   count = sess.procs3 },
        { key = "X5",   count = sess.procs4 },
    }
    for _, t in ipairs(tiers) do
        if Lines[t.key] then
            Lines[t.key]:SetText(visible and tostring(t.count) or "")
        end
    end

    if Lines["TOTAL_CRAFTS"] then
        Lines["TOTAL_CRAFTS"]:SetText(visible and tostring(tc) or "")
    end

    if Lines["PCT_GAIN"] then
        local totalItems = sess.totalPotions
        if visible and totalItems > 0 then
            Lines["PCT_GAIN"]:SetText(string.format("%.1f%%", sess.totalExtra / totalItems * 100))
        else
            Lines["PCT_GAIN"]:SetText(visible and "0.0%" or "")
        end
    end
end

-- ============================================================
-- APT:CreateUI
-- Called once from OnInitialize; builds the frame and hides it.
-- ============================================================
function APT:CreateUI()
    local DrawBorders          = APT.DrawBorders
    local MakeFrameCloseButton = APT.MakeFrameCloseButton
    local MakeDivider          = APT.MakeDivider
    local MakeResizeGrip       = APT.MakeResizeGrip
    local theme                = APT.theme
    local OR, GRN              = theme.OR, theme.GRN

    local f = CreateFrame("Frame", "AlchemyProcTrackerFrame", UIParent, "BackdropTemplate")

    -- Restore saved size/position, or default to left of screen centre
    local wp = APT.db.char.windowPos
    f:SetSize(wp and wp.w or M_DEF_W, wp and wp.h or M_DEF_H)
    if wp then
        f:SetPoint(wp.point, UIParent, wp.relPoint or wp.point, wp.x, wp.y)
    else
        f:SetPoint("TOPRIGHT", UIParent, "CENTER", -10, 200)
    end
    f._defW, f._defH = M_DEF_W, M_DEF_H

    f:SetFrameStrata("HIGH")
    f:SetMovable(true)
    f:SetResizable(true)
    f:SetToplevel(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetClampedToScreen(true)
    f:Hide()
    APT.frame = f

    -- Refresh stats whenever the window is shown
    f:SetScript("OnShow", function() APT.RefreshUI() end)

    -- Persist position after drag
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        APT.SaveWindowPos(f, "windowPos")
    end)

    -- Enforce minimum size live during resize drag
    local _clamp = false
    f:SetScript("OnSizeChanged", function(self, w, h)
        if _clamp then return end
        local nw, nh = math.max(w, M_MIN_W), math.max(h, M_MIN_H)
        if nw ~= w or nh ~= h then
            _clamp = true
            self:SetSize(nw, nh)
            _clamp = false
        end
    end)

    -- Background
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(f)
    bg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
    bg:SetVertexColor(0.09, 0.09, 0.09)
    bg:SetAlpha(0.97)

    -- Orange border
    DrawBorders(f)

    -- Darker header strip
    local hdrBg = f:CreateTexture(nil, "BACKGROUND")
    hdrBg:SetPoint("TOPLEFT",  f, "TOPLEFT",  1, -1)
    hdrBg:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, -1)
    hdrBg:SetHeight(28)
    hdrBg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
    hdrBg:SetVertexColor(0.04, 0.04, 0.04)

    MakeFrameCloseButton(f)

    local curY = -7

    -- Title
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", f, "TOPLEFT", M_PAD, curY)
    title:SetText("Alchemy Proc Tracker")
    title:SetTextColor(1, 0.76, 0.18)
    curY = curY - 28

    -- Divider below header
    MakeDivider(f, 1, curY, -1)
    curY = curY - 10

    -- Session label row (fixed; stays above scroll area)
    local sessLbl = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sessLbl:SetPoint("TOPLEFT", f, "TOPLEFT", M_PAD, curY)
    sessLbl:SetText("Session:")
    sessLbl:SetTextColor(0.60, 0.60, 0.60)

    local sessVal = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sessVal:SetPoint("TOPRIGHT", f, "TOPRIGHT", -M_PAD, curY)
    sessVal:SetJustifyH("RIGHT")
    sessVal:SetText("Current Session")
    sessVal:SetTextColor(1, 1, 1)
    curY = curY - M_ROW_H

    -- Faint sub-divider
    local subdiv = f:CreateTexture(nil, "ARTWORK")
    subdiv:SetPoint("TOPLEFT",  f, "TOPLEFT",  M_PAD, curY - 3)
    subdiv:SetPoint("TOPRIGHT", f, "TOPRIGHT", -M_PAD, curY - 3)
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
        lbl:SetPoint("TOPLEFT", f, "TOPLEFT", M_PAD, curY)
        lbl:SetText(row.label)
        lbl:SetTextColor(0.76, 0.76, 0.76)

        local val = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        val:SetPoint("TOPRIGHT", f, "TOPRIGHT", -M_PAD, curY)
        val:SetJustifyH("RIGHT")
        val:SetTextColor(1, 1, 1)
        Lines[row.key] = val
        curY = curY - M_ROW_H
    end

    -- Divider above totals
    curY = curY - 4
    MakeDivider(f, M_PAD, curY, -M_PAD)
    curY = curY - 10

    -- Total Crafts
    local tcLbl = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tcLbl:SetPoint("TOPLEFT", f, "TOPLEFT", M_PAD, curY)
    tcLbl:SetText("Total Crafts:")
    tcLbl:SetTextColor(0.60, 0.60, 0.60)

    local tcVal = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    tcVal:SetPoint("TOPRIGHT", f, "TOPRIGHT", -M_PAD, curY)
    tcVal:SetJustifyH("RIGHT")
    tcVal:SetTextColor(1, 1, 1)
    Lines["TOTAL_CRAFTS"] = tcVal
    curY = curY - M_ROW_H

    -- % Gain
    local pgLbl = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pgLbl:SetPoint("TOPLEFT", f, "TOPLEFT", M_PAD, curY)
    pgLbl:SetText("% Gain:")
    pgLbl:SetTextColor(GRN[1], GRN[2], GRN[3])

    local pgVal = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    pgVal:SetPoint("TOPRIGHT", f, "TOPRIGHT", -M_PAD, curY)
    pgVal:SetJustifyH("RIGHT")
    pgVal:SetTextColor(GRN[1], GRN[2], GRN[3])
    Lines["PCT_GAIN"] = pgVal

    -- Resize grip; saves size+position when done
    MakeResizeGrip(f, function(frame)
        APT.SaveWindowPos(frame, "windowPos")
    end)
end
