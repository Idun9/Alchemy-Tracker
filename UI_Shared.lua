-- UI_Shared.lua
-- Shared UI helpers: theme colours, border drawing, button factories, dividers.

local APT = AlchemyTracker

local theme = {
    OR  = { 0.98, 0.75, 0.14        },   -- amber-400 accent
    ORD = { 0.71, 0.33, 0.04        },   -- amber-700 (button normal state)
    DIV = { 0.40, 0.22, 0.03, 0.50  },   -- dim divider
    GRN = { 0.20, 0.83, 0.60        },   -- emerald-400 for proc% values
}
APT.theme = theme

-- DrawBorders: uses child frames for edges to avoid scissor-clipping at parent boundary.
local function DrawBorders(frame)
    -- amber-700/65 border to match Figma `border-amber-700/60`
    local BR = { 0.71, 0.33, 0.04, 0.65 }
    local function MakeLine(p1, rp1, x1, y1, p2, rp2, x2, y2, isH)
        local b = CreateFrame("Frame", nil, frame)
        b:SetPoint(p1, frame, rp1, x1, y1)
        b:SetPoint(p2, frame, rp2, x2, y2)
        if isH then b:SetHeight(1) else b:SetWidth(1) end
        local t = b:CreateTexture(nil, "BACKGROUND")
        t:SetAllPoints(b)
        t:SetTexture("Interface\\BUTTONS\\WHITE8X8")
        t:SetVertexColor(BR[1], BR[2], BR[3], BR[4])
    end
    MakeLine("TOPLEFT",    "TOPLEFT",    0, 0,  "TOPRIGHT",    "TOPRIGHT",    0,  0,  true)
    MakeLine("BOTTOMLEFT", "BOTTOMLEFT", 0, 0,  "BOTTOMRIGHT", "BOTTOMRIGHT", 0,  0,  true)
    MakeLine("TOPLEFT",    "TOPLEFT",    0, 0,  "BOTTOMLEFT",  "BOTTOMLEFT",  0,  0,  false)
    MakeLine("TOPRIGHT",   "TOPRIGHT",  -1, 0,  "BOTTOMRIGHT", "BOTTOMRIGHT", -1, 0,  false)
end
APT.DrawBorders = DrawBorders

local function MakeNavButton(parent, label, w, h, onClick)
    local OR, ORD = theme.OR, theme.ORD
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(w, h)
    local bbg = btn:CreateTexture(nil, "BACKGROUND")
    bbg:SetAllPoints(btn)
    bbg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
    bbg:SetVertexColor(ORD[1], ORD[2], ORD[3])
    btn._bbg = bbg
    local btxt = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    btxt:SetAllPoints(btn)
    btxt:SetText(label)
    btxt:SetTextColor(1, 1, 1)
    btn:SetScript("OnEnter", function() bbg:SetVertexColor(OR[1], OR[2], OR[3]) end)
    btn:SetScript("OnLeave", function() bbg:SetVertexColor(ORD[1], ORD[2], ORD[3]) end)
    btn:SetScript("OnClick", onClick or function() end)
    return btn
end
APT.MakeNavButton = MakeNavButton

local function MakeFrameCloseButton(parent)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(18, 18)
    btn:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -8, -6)
    local cbg = btn:CreateTexture(nil, "BACKGROUND")
    cbg:SetAllPoints(btn)
    cbg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
    cbg:SetVertexColor(0.73, 0.11, 0.11)   -- red-700
    local cx = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    cx:SetAllPoints(btn)
    cx:SetText("X")
    cx:SetTextColor(1, 1, 1)
    btn:SetScript("OnEnter", function() cbg:SetVertexColor(0.90, 0.20, 0.20) end)
    btn:SetScript("OnLeave", function() cbg:SetVertexColor(0.60, 0.08, 0.08) end)
    btn:SetScript("OnClick", function() parent:Hide() end)
    return btn
end
APT.MakeFrameCloseButton = MakeFrameCloseButton

local function MakeDivider(parent, x1, y, x2)
    local DIV = theme.DIV
    local d = parent:CreateTexture(nil, "ARTWORK")
    d:SetPoint("TOPLEFT",  parent, "TOPLEFT",  x1, y)
    d:SetPoint("TOPRIGHT", parent, "TOPRIGHT", x2, y)
    d:SetHeight(1)
    d:SetTexture("Interface\\BUTTONS\\WHITE8X8")
    d:SetVertexColor(DIV[1], DIV[2], DIV[3], DIV[4])
    return d
end
APT.MakeDivider = MakeDivider

local function MakeResizeGrip(frame, onDone)
    local grip = CreateFrame("Button", nil, frame)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function()
        frame:StopMovingOrSizing()
        if onDone then onDone(frame) end
    end)
    return grip
end
APT.MakeResizeGrip = MakeResizeGrip

local function SaveWindowPos(frame, dbKey)
    local point, _, relPoint, x, y = frame:GetPoint()
    APT.db.char[dbKey] = { point=point, relPoint=relPoint, x=x, y=y,
                           w=frame:GetWidth(), h=frame:GetHeight() }
end
APT.SaveWindowPos = SaveWindowPos
