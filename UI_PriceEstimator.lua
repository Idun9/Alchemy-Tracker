-- UI_PriceEstimator.lua
-- Collapsible price estimator panel attached to the main stats window.
-- Toggled by the Coins button in the header (session tab only).
--
-- Inputs use separate Gold / Silver / Copper boxes matching the WoW money UI.
-- Values are stored internally as copper integers.
--
-- Auction addon integration (future):
--   GetAuctionPrice() checks TSM → Auctionator → Auctioneer → nil.

local APT = AlchemyTracker

local PANEL_H = 76    -- divider(10) + mat row(18) + sell row(18) + gap(6) + divider(10) + profit row(18) + padding(8) - 4
local M_PAD   = 12
local M_ROW_H = 18
local AH_FEE  = 0.05  -- 5 % Auction House cut (TBC Classic standard)

-- Expose panel height so UI_Main can read it when switching tabs.
APT.PANEL_H = PANEL_H

-- ============================================================
-- Auction addon price lookup — returns copper or nil.
-- ============================================================
local function GetAuctionPrice(itemID)
    if TSM_API then
        local ok, val = pcall(TSM_API.GetCustomPriceValue, "DBMarket", "i:" .. itemID)
        if ok and type(val) == "number" and val > 0 then return val end
    end
    if Auctionator and Auctionator.API and Auctionator.API.v1 then
        local ok, val = pcall(Auctionator.API.v1.GetAuctionPriceByItemID, "AlchemyTracker", itemID)
        if ok and type(val) == "number" and val > 0 then return val end
    end
    if AucAdvanced and AucAdvanced.API then
        local link = select(2, GetItemInfo(itemID))
        if link then
            local ok, val = pcall(AucAdvanced.API.GetMarketValue, link)
            if ok and type(val) == "number" and val > 0 then return val end
        end
    end
    return nil
end
APT.GetAuctionPrice = GetAuctionPrice

-- ============================================================
-- Helpers
-- ============================================================
local function CopperToGSC(copper)
    copper = math.floor(math.max(0, copper or 0) + 0.5)
    return math.floor(copper / 10000),
           math.floor((copper % 10000) / 100),
           copper % 100
end

local function GSCToCopper(g, s, c)
    return math.max(0, (g or 0)) * 10000
         + math.max(0, math.min(99, (s or 0))) * 100
         + math.max(0, math.min(99, (c or 0)))
end

local function FormatGSC(copper)
    if not copper then return "0g 0s 0c" end
    local neg = copper < 0
    local abs = math.floor(math.abs(copper) + 0.5)
    local g   = math.floor(abs / 10000)
    local s   = math.floor((abs % 10000) / 100)
    local c   = abs % 100
    if neg then
        return string.format("-%dg %ds %dc", g, s, c)
    else
        return string.format("%dg %ds %dc", g, s, c)
    end
end

local function FormatGSCProfit(copper)
    if not copper then return "+0g 0s 0c" end
    local sign = copper >= 0 and "+" or "-"
    local abs  = math.floor(math.abs(copper) + 0.5)
    local g    = math.floor(abs / 10000)
    local s    = math.floor((abs % 10000) / 100)
    local c    = abs % 100
    return string.format("%s%dg %ds %dc", sign, g, s, c)
end

-- ============================================================
-- Panel widget references
-- ============================================================
local PE = {}

-- ============================================================
-- APT.RefreshPriceEstimator
-- ============================================================
APT.RefreshPriceEstimator = function()
    if not PE.panel or not PE.panel:IsShown() then return end

    local sess     = APT.CombineAllStats("session")
    local tc       = sess.totalCrafts
    local settings = APT.db.char.settings.priceEstimator

    local matCost   = settings.matCost   or 0
    local sellPrice = settings.sellPrice or 0
    local useAHFee  = settings.ahFee ~= false

    -- Silently apply AH cut when enabled (controlled via Settings page checkbox)
    local effectiveSell = useAHFee and (sellPrice * (1 - AH_FEE)) or sellPrice

    -- Estimated profit: total output value minus total material cost
    local estimatedProfit = sess.totalPotions * effectiveSell - tc * matCost
    local color = estimatedProfit >= 0 and {0.20, 0.83, 0.60} or {0.97, 0.44, 0.44}   -- emerald-400 / red-400
    PE.estimatedProfit:SetText(FormatGSCProfit(estimatedProfit))
    PE.estimatedProfit:SetTextColor(unpack(color))
end

-- ============================================================
-- APT.TogglePriceEstimator
-- ============================================================
APT.TogglePriceEstimator = function()
    if not PE.panel then return end
    -- Only toggle in session tab
    if APT.frame and APT.frame._activeTab ~= "session" then return end

    local settings = APT.db.char.settings.priceEstimator
    local show     = not PE.panel:IsShown()
    settings.enabled = show
    PE.panel:SetShown(show)

    local f = APT.frame
    if f then
        f:SetHeight(f:GetHeight() + (show and PANEL_H or -PANEL_H))
    end

    if show then APT.RefreshPriceEstimator() end
end

-- ============================================================
-- APT.CreatePriceEstimatorPanel
-- Called once from CreateUI after the main frame is built.
-- ============================================================
function APT.CreatePriceEstimatorPanel(parentFrame)
    local f           = parentFrame
    local MakeDivider = APT.MakeDivider
    local OR          = APT.theme.OR

    local panel = CreateFrame("Frame", nil, f)
    panel:SetPoint("BOTTOMLEFT",  f, "BOTTOMLEFT",   1,  1)
    panel:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1,  1)
    panel:SetHeight(PANEL_H)
    panel:Hide()
    PE.panel   = panel
    f._pePanel = panel

    local curY = -4

    -- G/S/C input row factory
    local function MakeGSCRow(label, dbKey, y)
        local lbl = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetPoint("TOPLEFT", panel, "TOPLEFT", M_PAD, y)
        lbl:SetText(label)
        lbl:SetTextColor(0.64, 0.64, 0.64)   -- neutral-400

        -- Rightmost: copper
        local cLbl = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        cLbl:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -M_PAD, y)
        cLbl:SetText("c")
        cLbl:SetTextColor(0.45, 0.45, 0.45)   -- neutral-500

        local cBox = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
        cBox:SetSize(26, 18)
        cBox:SetPoint("RIGHT", cLbl, "LEFT", -2, 1)
        cBox:SetAutoFocus(false)
        cBox:SetMaxLetters(2)

        local sLbl = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        sLbl:SetPoint("RIGHT", cBox, "LEFT", -3, -1)
        sLbl:SetText("s")
        sLbl:SetTextColor(0.64, 0.64, 0.64)   -- neutral-400

        local sBox = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
        sBox:SetSize(26, 18)
        sBox:SetPoint("RIGHT", sLbl, "LEFT", -2, 1)
        sBox:SetAutoFocus(false)
        sBox:SetMaxLetters(2)

        local gLbl = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        gLbl:SetPoint("RIGHT", sBox, "LEFT", -3, -1)
        gLbl:SetText("g")
        gLbl:SetTextColor(0.98, 0.75, 0.14)   -- amber-400

        local gBox = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
        gBox:SetSize(42, 18)
        gBox:SetPoint("RIGHT", gLbl, "LEFT", -2, 1)
        gBox:SetAutoFocus(false)
        gBox:SetMaxLetters(5)

        local function RevertFromDB()
            local saved = APT.db.char.settings.priceEstimator[dbKey] or 0
            local g, s, c = CopperToGSC(saved)
            gBox:SetText(tostring(g))
            sBox:SetText(tostring(s))
            cBox:SetText(tostring(c))
        end
        RevertFromDB()

        local function Commit()
            local gv = tonumber(gBox:GetText()) or 0
            local sv = tonumber(sBox:GetText()) or 0
            local cv = tonumber(cBox:GetText()) or 0
            local copper = GSCToCopper(gv, sv, cv)
            APT.db.char.settings.priceEstimator[dbKey] = copper
            local ng, ns, nc = CopperToGSC(copper)
            gBox:SetText(tostring(ng))
            sBox:SetText(tostring(ns))
            cBox:SetText(tostring(nc))
            gBox:ClearFocus()
            sBox:ClearFocus()
            cBox:ClearFocus()
            APT.RefreshPriceEstimator()
        end

        local function Revert()
            RevertFromDB()
            gBox:ClearFocus()
            sBox:ClearFocus()
            cBox:ClearFocus()
        end

        for _, box in ipairs({gBox, sBox, cBox}) do
            box:SetScript("OnEnterPressed", Commit)
            box:SetScript("OnEscapePressed", Revert)
        end

        return gBox, sBox, cBox
    end

    MakeDivider(panel, M_PAD, curY, -M_PAD)
    curY = curY - 10

    -- Figma: Material Cost row, Sell Price row
    MakeGSCRow("Material Cost:", "matCost",   curY) ; curY = curY - M_ROW_H
    MakeGSCRow("Sell Price:",    "sellPrice", curY)
    curY = curY - 6

    -- Figma: divider, then Estimated Profit
    MakeDivider(panel, M_PAD, curY, -M_PAD)
    curY = curY - 10

    local profLbl = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    profLbl:SetPoint("TOPLEFT", panel, "TOPLEFT", M_PAD, curY)
    profLbl:SetText("Estimated Profit:")
    profLbl:SetTextColor(0.64, 0.64, 0.64)   -- neutral-400

    local profVal = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    profVal:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -M_PAD, curY)
    profVal:SetJustifyH("RIGHT")
    PE.estimatedProfit = profVal

    -- Restore persisted open/closed state
    if APT.db.char.settings.priceEstimator.enabled then
        panel:Show()
        APT.frame:SetHeight(APT.frame:GetHeight() + PANEL_H)
        APT.RefreshPriceEstimator()
    end
end
