-- UI_PriceEstimator.lua
-- Collapsible price estimator panel attached to the main stats window.
-- Toggled by the "$" button in the header.
--
-- Auction addon integration (future):
--   The GetAuctionPrice() function checks for TSM, Auctionator, and Auctioneer
--   in priority order before falling back to manual input.  To activate an
--   integration, simply fill in the relevant block — no other code needs changing.

local APT = AlchemyTracker

local PANEL_H  = 166   -- pixel height of the estimator section
local M_PAD    = 12
local M_ROW_H  = 18
local AH_FEE   = 0.05  -- 5% Auction House cut (TBC Classic standard)

-- ============================================================
-- Auction addon price lookup — returns copper or nil.
-- Priority: TSM → Auctionator → Auctioneer → nil (manual fallback).
-- ============================================================
local function GetAuctionPrice(itemID)
    -- TSM
    if TSM_API then
        local ok, val = pcall(TSM_API.GetCustomPriceValue, "DBMarket", "i:" .. itemID)
        if ok and type(val) == "number" and val > 0 then return val end
    end

    -- Auctionator
    if Auctionator and Auctionator.API and Auctionator.API.v1 then
        local ok, val = pcall(Auctionator.API.v1.GetAuctionPriceByItemID, "AlchemyTracker", itemID)
        if ok and type(val) == "number" and val > 0 then return val end
    end

    -- Auctioneer
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
local function FormatGold(copper)
    if not copper or copper == 0 then return "0.00g" end
    local sign = copper < 0 and "-" or ""
    return string.format("%s%.2fg", sign, math.abs(copper) / 10000)
end

local function ParseGoldInput(text)
    if not text then return nil end
    local clean = text:match("^%s*(.-)%s*$"):gsub(",", ".")
    local g = tonumber(clean)
    if not g or g < 0 then return nil end
    return math.floor(g * 10000 + 0.5)
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
    local useAHFee  = settings.ahFee ~= false   -- default true

    -- Effective sell price after AH cut
    local effectiveSell = useAHFee and (sellPrice * (1 - AH_FEE)) or sellPrice

    -- Avg yield per craft attempt (1.0 when no data yet)
    local avgYield = tc > 0 and (sess.totalPotions / tc) or 1.0
    PE.avgYield:SetText(string.format("%.2fx", avgYield))

    -- Revenue per craft (after AH fee)
    local revPerCraft = avgYield * effectiveSell
    PE.revPerCraft:SetText(FormatGold(revPerCraft))

    -- Profit per craft
    local profitPerCraft = revPerCraft - matCost
    local pc = profitPerCraft >= 0 and {0.20, 0.85, 0.50} or {1, 0.27, 0.27}
    PE.profitPerCraft:SetText(FormatGold(profitPerCraft))
    PE.profitPerCraft:SetTextColor(unpack(pc))

    -- Session profit
    local sessProfit = sess.totalPotions * effectiveSell - tc * matCost
    local sc = sessProfit >= 0 and {0.20, 0.85, 0.50} or {1, 0.27, 0.27}
    PE.sessProfit:SetText(FormatGold(sessProfit))
    PE.sessProfit:SetTextColor(unpack(sc))
end

-- ============================================================
-- APT.TogglePriceEstimator
-- ============================================================
APT.TogglePriceEstimator = function()
    if not PE.panel then return end
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

    -- Sub-frame pinned to the bottom of the parent (sits above the resize grip)
    local panel = CreateFrame("Frame", nil, f)
    panel:SetPoint("BOTTOMLEFT",  f, "BOTTOMLEFT",   1,  1)
    panel:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1,  1)
    panel:SetHeight(PANEL_H)
    panel:Hide()
    PE.panel = panel

    local curY = -4

    MakeDivider(panel, M_PAD, curY, -M_PAD)
    curY = curY - 10

    -- Section title
    local titleLbl = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    titleLbl:SetPoint("TOPLEFT", panel, "TOPLEFT", M_PAD, curY)
    titleLbl:SetText("Price Estimator")
    titleLbl:SetTextColor(OR[1], OR[2], OR[3])
    curY = curY - M_ROW_H

    -- Input row factory
    local function MakeInputRow(label, dbKey, y)
        local lbl = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetPoint("TOPLEFT", panel, "TOPLEFT", M_PAD, y)
        lbl:SetText(label)
        lbl:SetTextColor(0.76, 0.76, 0.76)

        local box = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
        box:SetSize(78, 18)
        box:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -M_PAD - 14, y + 1)
        box:SetAutoFocus(false)
        box:SetMaxLetters(10)

        local saved = APT.db.char.settings.priceEstimator[dbKey] or 0
        box:SetText(string.format("%.2f", saved / 10000))

        local function Commit()
            local copper = ParseGoldInput(box:GetText())
            if copper then
                APT.db.char.settings.priceEstimator[dbKey] = copper
                box:SetText(string.format("%.2f", copper / 10000))
                APT.RefreshPriceEstimator()
            else
                local s = APT.db.char.settings.priceEstimator[dbKey] or 0
                box:SetText(string.format("%.2f", s / 10000))
            end
            box:ClearFocus()
        end
        box:SetScript("OnEnterPressed", Commit)
        box:SetScript("OnEscapePressed", function(self)
            local s = APT.db.char.settings.priceEstimator[dbKey] or 0
            self:SetText(string.format("%.2f", s / 10000))
            self:ClearFocus()
        end)

        local gLbl = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        gLbl:SetPoint("LEFT", box, "RIGHT", 2, 0)
        gLbl:SetText("g")
        gLbl:SetTextColor(0.76, 0.76, 0.76)

        return box
    end

    PE.matCostBox   = MakeInputRow("Mat cost / craft:",  "matCost",   curY)
    curY = curY - M_ROW_H
    PE.sellPriceBox = MakeInputRow("Sell price / item:", "sellPrice", curY)
    curY = curY - 6

    -- AH Fee checkbox row
    local ahLbl = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ahLbl:SetPoint("TOPLEFT", panel, "TOPLEFT", M_PAD, curY)
    ahLbl:SetText("AH Fee (5%):")
    ahLbl:SetTextColor(0.76, 0.76, 0.76)

    local chk = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    chk:SetSize(20, 20)
    chk:SetPoint("RIGHT", panel, "RIGHT", -M_PAD - 2, curY + M_ROW_H / 2 - 3)
    chk:SetChecked(APT.db.char.settings.priceEstimator.ahFee ~= false)
    chk:SetScript("OnClick", function(self)
        APT.db.char.settings.priceEstimator.ahFee = self:GetChecked()
        APT.RefreshPriceEstimator()
    end)
    PE.ahFeeChk = chk
    curY = curY - M_ROW_H - 2

    MakeDivider(panel, M_PAD, curY, -M_PAD)
    curY = curY - 10

    -- Calculated row factory
    local function MakeCalcRow(label, y)
        local lbl = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetPoint("TOPLEFT", panel, "TOPLEFT", M_PAD, y)
        lbl:SetText(label)
        lbl:SetTextColor(0.60, 0.60, 0.60)

        local val = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        val:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -M_PAD, y)
        val:SetJustifyH("RIGHT")
        val:SetTextColor(1, 1, 1)
        return val
    end

    PE.avgYield       = MakeCalcRow("Avg yield / craft:", curY) ; curY = curY - M_ROW_H
    PE.revPerCraft    = MakeCalcRow("Revenue / craft:",   curY) ; curY = curY - M_ROW_H
    PE.profitPerCraft = MakeCalcRow("Profit / craft:",    curY) ; curY = curY - M_ROW_H
    PE.sessProfit     = MakeCalcRow("Session profit:",    curY)

    -- Restore persisted state
    if APT.db.char.settings.priceEstimator.enabled then
        panel:Show()
        APT.frame:SetHeight(APT.frame:GetHeight() + PANEL_H)
        APT.RefreshPriceEstimator()
    end
end
