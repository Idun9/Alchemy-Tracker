-- UI_History.lua
-- Session history browser: collapsible tree (Sessions → Groups → Items)
-- plus Overall stats banner and the session rename dialog.

local APT = AlchemyTracker

-- ============================================================
-- Layout constants
-- ============================================================
local H_DEF_W    = 500
local H_DEF_H    = 440
local H_ROW      = 20
local H_ARROW    = 8
local H_LABEL    = 26
local H_BASE     = 305
local H_TOTAL    = 365
local H_PCT      = 420
local H_COL_W    = 54
local H_MAX_ROWS = 120

-- ============================================================
-- Expansion state
-- Keys: "overall" or "sid_<id>" where id is the session's stable ID.
-- Synced to db.char.expandedSessions for persistence across reloads.
-- ============================================================
local expandedSessions = {}

local function SaveExpandedState()
    if not APT.db or not APT.db.char then return end
    local t = {}
    for k, v in pairs(expandedSessions) do
        if v then t[k] = true end
    end
    APT.db.char.expandedSessions = t
end

local function ToggleExpanded(key)
    expandedSessions[key] = not expandedSessions[key]
    SaveExpandedState()
    APT.RefreshHistory()
end

-- ============================================================
-- Session Rename Dialog  (lazily created)
-- ============================================================
local RenameFrame
local RenameTarget  -- sess object being renamed

local function ShowRenameDialog(sess)
    if not RenameFrame then
        local d = CreateFrame("Frame", "APT_RenameFrame", UIParent, "BackdropTemplate")
        d:SetSize(300, 110)
        d:SetFrameStrata("DIALOG")
        d:SetMovable(true)
        d:EnableMouse(true)
        d:RegisterForDrag("LeftButton")
        d:SetScript("OnDragStart", d.StartMoving)
        d:SetScript("OnDragStop",  d.StopMovingOrSizing)
        d:SetClampedToScreen(true)

        local dbg = d:CreateTexture(nil, "BACKGROUND")
        dbg:SetAllPoints(d)
        dbg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
        dbg:SetVertexColor(0.07, 0.07, 0.07)
        dbg:SetAlpha(0.97)
        APT.DrawBorders(d)

        local OR = APT.theme.OR
        local title = d:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("TOPLEFT", d, "TOPLEFT", 10, -10)
        title:SetText("Rename Session")
        title:SetTextColor(OR[1], OR[2], OR[3])

        local hint = d:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        hint:SetPoint("TOPLEFT", d, "TOPLEFT", 10, -26)
        hint:SetText("Leave blank to restore the default name.")
        hint:SetTextColor(0.50, 0.50, 0.50)

        local eb = CreateFrame("EditBox", "APT_RenameEditBox", d, "InputBoxTemplate")
        eb:SetSize(278, 22)
        eb:SetPoint("TOP", d, "TOP", 0, -46)
        eb:SetAutoFocus(false)
        eb:SetMaxLetters(64)
        d.eb = eb

        local save = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
        save:SetSize(80, 22)
        save:SetPoint("BOTTOMRIGHT", d, "BOTTOM", -4, 10)
        save:SetText("Save")
        save:SetScript("OnClick", function()
            if RenameTarget then
                local name = d.eb:GetText():match("^%s*(.-)%s*$")
                RenameTarget.customName = (name ~= "") and name or nil
                if APT.RefreshHistory then APT.RefreshHistory() end
            end
            d:Hide()
        end)

        local cancel = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
        cancel:SetSize(80, 22)
        cancel:SetPoint("BOTTOMLEFT", d, "BOTTOM", 4, 10)
        cancel:SetText("Cancel")
        cancel:SetScript("OnClick", function() d:Hide() end)

        eb:SetScript("OnEscapePressed", function() d:Hide() end)
        eb:SetScript("OnEnterPressed",  function() save:Click() end)

        RenameFrame = d
    end

    RenameTarget = sess
    RenameFrame.eb:SetText(sess.customName or "")
    RenameFrame:ClearAllPoints()
    RenameFrame:SetPoint("CENTER")
    RenameFrame:Show()
    RenameFrame.eb:SetFocus()
end

-- ============================================================
-- Helper: stable session key
-- Uses the session's numeric ID when available, then falls back
-- to the date string, then to a stringified index.
-- This prevents expansion-state collisions after session deletion.
-- ============================================================
local function SessionKey(sess, idx)
    return "sid_" .. (sess.id or ("d_" .. (sess.date or tostring(idx))))
end

-- ============================================================
-- APT.RefreshHistory
-- Rebuilds the row pool from the current sessions list.
-- No-ops when the window is hidden.
-- ============================================================
-- Format seconds as "45m" or "1h 12m"
local function FormatDuration(secs)
    if not secs or secs < 60 then return nil end
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    if h > 0 then return string.format("%dh %dm", h, m) end
    return string.format("%dm", m)
end

-- Returns groups in GROUPS_ORDER with the mastery-relevant group(s) first.
local function MasteryOrderedGroups()
    local spec = APT.db and APT.db.char.specialization.current or "None"
    if spec == "Potion" then
        return { "POTION", "FLASK", "ELIXIR", "TRANSMUTE" }
    elseif spec == "Transmute" then
        return { "TRANSMUTE", "FLASK", "ELIXIR", "POTION" }
    end
    -- Elixir Master or no mastery: default order (FLASK+ELIXIR already first)
    return APT.GROUPS_ORDER
end

local function CalcProcPct(s)
    if not s or s.totalCrafts == 0 then return "—" end
    return string.format("%.1f%%", s.totalExtra / s.totalCrafts * 100)
end

local function CombineGroups(statsMap)
    local s = { totalCrafts = 0, totalPotions = 0, totalExtra = 0 }
    for _, g in ipairs(APT.GROUPS_ORDER) do
        local gs = statsMap[g]
        if gs then
            s.totalCrafts  = s.totalCrafts  + gs.totalCrafts
            s.totalPotions = s.totalPotions + gs.totalPotions
            s.totalExtra   = s.totalExtra   + gs.totalExtra
        end
    end
    return s
end

APT.RefreshHistory = function()
    local f = APT.historyFrame
    if not f or not f:IsShown() then return end
    if not APT.db then return end

    local OR, GRN = APT.theme.OR, APT.theme.GRN
    local sc       = f.sc
    local rows     = f.rows
    local sessions = APT.db.char.sessions or {}

    -- Hide and reset all pooled rows
    for _, r in ipairs(rows) do
        r:Hide()
        r.btn:SetScript("OnClick", nil)
    end

    local rowIdx = 0
    local curY   = 0

    local function UseRow(height)
        rowIdx = rowIdx + 1
        local r = rows[rowIdx]
        if not r then return nil end
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT",  sc, "TOPLEFT",  0, -curY)
        r:SetPoint("TOPRIGHT", sc, "TOPRIGHT", 0, -curY)
        r:SetHeight(height or H_ROW)
        r.arrow:SetText("")
        r.arrow:SetTextColor(OR[1], OR[2], OR[3])
        r.lbl:ClearAllPoints()
        r.lbl:SetPoint("LEFT",  r, "LEFT", H_LABEL, 0)
        r.lbl:SetPoint("RIGHT", r, "LEFT", H_BASE - 4, 0)
        r.lbl:SetText("")
        r.lbl:SetTextColor(1, 1, 1)
        r.base:SetText("")   r.base:SetTextColor(1, 1, 1)
        r.total:SetText("")  r.total:SetTextColor(1, 1, 1)
        r.pct:SetText("")    r.pct:SetTextColor(GRN[1], GRN[2], GRN[3])
        r._r, r._g, r._b, r._a = 0, 0, 0, 0
        r.rbg:SetVertexColor(0, 0, 0, 0)
        r:Show()
        curY = curY + (height or H_ROW)
        return r
    end

    local function SetRowBg(r, rr, gg, bb, aa)
        r._r, r._g, r._b, r._a = rr, gg, bb, aa
        r.rbg:SetVertexColor(rr, gg, bb, aa)
    end

    -- ── Overall Stats banner ──────────────────────────────────
    local function AddOverallBanner(combined)
        local r = UseRow(22)
        if not r then return end
        local expanded = expandedSessions["overall"]
        r.arrow:SetText(expanded and "▼" or "▶")
        r.lbl:SetText("Overall Stats")
        r.lbl:SetTextColor(1, 1, 1)
        r.lbl:SetFont(r.lbl:GetFont(), select(2, r.lbl:GetFont()) or 12, "OUTLINE")
        if combined.totalCrafts > 0 then
            r.base:SetText(tostring(combined.totalCrafts))
            r.total:SetText(tostring(combined.totalPotions))
            r.pct:SetText(CalcProcPct(combined))
        end
        SetRowBg(r, OR[1]*0.18, OR[2]*0.18, OR[3]*0.18, 0.90)
        -- Orange left accent bar
        if not r._accent then
            local acc = r:CreateTexture(nil, "ARTWORK")
            acc:SetTexture("Interface\\BUTTONS\\WHITE8X8")
            acc:SetVertexColor(OR[1], OR[2], OR[3])
            acc:SetPoint("TOPLEFT",    r, "TOPLEFT",    0, 0)
            acc:SetPoint("BOTTOMLEFT", r, "BOTTOMLEFT", 0, 0)
            acc:SetWidth(3)
            r._accent = acc
        end
        r._accent:Show()
        r.btn:SetScript("OnClick", function() ToggleExpanded("overall") end)
    end

    -- ── Session header row ────────────────────────────────────
    local function AddSessionHeader(label, key, combined, sessObj)
        local r = UseRow()
        if not r then return end
        if r._accent then r._accent:Hide() end
        r.arrow:SetText(expandedSessions[key] and "▼" or "▶")
        local displayLabel = (sessObj and sessObj.customName)
            and (sessObj.customName .. "  —  " .. (sessObj.date or ""))
            or label
        r.lbl:SetText(displayLabel)
        r.lbl:SetTextColor(OR[1], OR[2], OR[3])
        if combined.totalCrafts > 0 then
            r.base:SetText(tostring(combined.totalCrafts))
            r.base:SetTextColor(OR[1], OR[2], OR[3])
            r.total:SetText(tostring(combined.totalPotions))
            r.total:SetTextColor(OR[1], OR[2], OR[3])
            r.pct:SetText(CalcProcPct(combined))
        end
        SetRowBg(r, 0.12, 0.09, 0.04, 0.70)
        local k, so = key, sessObj
        r.btn:SetScript("OnClick", function(_, mouseBtn)
            if mouseBtn == "RightButton" and so then
                ShowRenameDialog(so)
            else
                ToggleExpanded(k)
            end
        end)
    end

    -- ── Group header row ──────────────────────────────────────
    local function AddGroupHeader(groupName, s)
        local r = UseRow()
        if not r then return end
        if r._accent then r._accent:Hide() end
        r.lbl:ClearAllPoints()
        r.lbl:SetPoint("LEFT",  r, "LEFT", H_LABEL + 10, 0)
        r.lbl:SetPoint("RIGHT", r, "LEFT", H_BASE - 4,   0)
        r.lbl:SetText(groupName)
        r.lbl:SetTextColor(0.75, 0.75, 0.75)
        r.base:SetText(tostring(s.totalCrafts))   r.base:SetTextColor(0.75, 0.75, 0.75)
        r.total:SetText(tostring(s.totalPotions)) r.total:SetTextColor(0.75, 0.75, 0.75)
        r.pct:SetText(CalcProcPct(s))
        SetRowBg(r, 0.10, 0.10, 0.10, 0.50)
    end

    -- ── Item row ──────────────────────────────────────────────
    local function AddItemRow(it)
        local r = UseRow()
        if not r then return end
        if r._accent then r._accent:Hide() end
        r.lbl:ClearAllPoints()
        r.lbl:SetPoint("LEFT",  r, "LEFT", H_LABEL + 22, 0)
        r.lbl:SetPoint("RIGHT", r, "LEFT", H_BASE - 4,   0)
        r.lbl:SetText(it.name)
        r.lbl:SetTextColor(0.65, 0.65, 0.65)
        r.base:SetText(tostring(it.totalCrafts))   r.base:SetTextColor(0.65, 0.65, 0.65)
        r.total:SetText(tostring(it.totalPotions)) r.total:SetTextColor(0.65, 0.65, 0.65)
        r.pct:SetText(CalcProcPct(it))
    end

    -- ── Total row ─────────────────────────────────────────────
    local function AddTotalRow(combined)
        local r = UseRow()
        if not r then return end
        if r._accent then r._accent:Hide() end
        r.lbl:ClearAllPoints()
        r.lbl:SetPoint("LEFT",  r, "LEFT", H_LABEL + 10, 0)
        r.lbl:SetPoint("RIGHT", r, "LEFT", H_BASE - 4,   0)
        r.lbl:SetText("Total")
        r.lbl:SetTextColor(0.55, 0.55, 0.55)
        r.base:SetText(tostring(combined.totalCrafts))   r.base:SetTextColor(0.55, 0.55, 0.55)
        r.total:SetText(tostring(combined.totalPotions)) r.total:SetTextColor(0.55, 0.55, 0.55)
        r.pct:SetText(CalcProcPct(combined))
        SetRowBg(r, 0.08, 0.07, 0.03, 0.50)
    end

    local function RenderGroupItems(s)
        if not s.items then return end
        local sorted = {}
        for _, it in pairs(s.items) do sorted[#sorted + 1] = it end
        table.sort(sorted, function(a, b) return a.name < b.name end)
        for _, it in ipairs(sorted) do AddItemRow(it) end
    end

    -- ── Overall stats banner (top of list) ───────────────────
    local ovMap = {}
    for _, g in ipairs(APT.GROUPS_ORDER) do
        ovMap[g] = APT.db.char.stats[g] and APT.db.char.stats[g].overall
    end
    local combinedOv = CombineGroups(ovMap)
    AddOverallBanner(combinedOv)
    if expandedSessions["overall"] then
        for _, g in ipairs(APT.GROUPS_ORDER) do
            local ov = ovMap[g]
            if ov and ov.totalCrafts > 0 then AddGroupHeader(g, ov) end
        end
        AddTotalRow(combinedOv)
    end
    curY = curY + 4

    -- ── Past sessions (newest first) ─────────────────────────
    local groupOrder = MasteryOrderedGroups()
    for i, sess in ipairs(sessions) do
        local key      = SessionKey(sess, i)
        local combined = CombineGroups(sess.stats or {})
        local dur      = sess.duration and FormatDuration(sess.duration)
        local dateStr  = sess.date or ""
        local dateLine = dur and (dateStr .. "  ·  " .. dur) or dateStr
        AddSessionHeader(
            string.format("Session %d  —  %s", i, dateLine),
            key, combined, sess)
        if expandedSessions[key] then
            for _, g in ipairs(groupOrder) do
                local s = sess.stats and sess.stats[g]
                if s and s.totalCrafts > 0 then
                    AddGroupHeader(g, s)
                    RenderGroupItems(s)
                end
            end
            AddTotalRow(combined)
            curY = curY + 4
        end
    end

    sc:SetHeight(math.max(curY + 8, 10))
    if f.UpdateScrollbar then f.UpdateScrollbar() end
end

-- ============================================================
-- APT:CreateHistoryUI
-- Called once from OnInitialize; builds the frame and hides it.
-- ============================================================
function APT:CreateHistoryUI()
    local DrawBorders          = APT.DrawBorders
    local MakeFrameCloseButton = APT.MakeFrameCloseButton
    local MakeDivider          = APT.MakeDivider
    local MakeResizeGrip       = APT.MakeResizeGrip
    local MakeCustomScrollbar  = APT.MakeCustomScrollbar
    local theme                = APT.theme
    local OR, GRN              = theme.OR, theme.GRN

    local f = CreateFrame("Frame", "APT_HistoryFrame", UIParent, "BackdropTemplate")

    local hp = APT.db.char.historyPos
    f:SetSize(hp and hp.w or H_DEF_W, hp and hp.h or H_DEF_H)
    if hp then
        f:SetPoint(hp.point, UIParent, hp.relPoint or hp.point, hp.x, hp.y)
    else
        f:SetPoint("TOPLEFT", UIParent, "CENTER", 10, 200)
    end
    f._defW, f._defH = H_DEF_W, H_DEF_H

    f:SetFrameStrata("HIGH")
    f:SetMovable(true)
    f:SetResizable(true)
    f:SetToplevel(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetClampedToScreen(true)
    f:Hide()
    APT.historyFrame = f

    -- Restore persisted expansion state
    for k, v in pairs(APT.db.char.expandedSessions or {}) do
        expandedSessions[k] = v
    end
    -- Auto-expand overall on first ever open (nothing persisted)
    if not next(expandedSessions) then
        expandedSessions["overall"] = true
        SaveExpandedState()
    end

    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        local point, _, relPoint, x, y = f:GetPoint()
        APT.db.char.historyPos = { point=point, relPoint=relPoint, x=x, y=y,
                                   w=f:GetWidth(), h=f:GetHeight() }
    end)

    -- Enforce minimum size during resize drag
    local _clamp = false
    f:SetScript("OnSizeChanged", function(self, w, h)
        if _clamp then return end
        local nw, nh = math.max(w, 380), math.max(h, 200)
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
    bg:SetVertexColor(0.07, 0.07, 0.07)
    bg:SetAlpha(0.97)
    DrawBorders(f)

    -- Title
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -12)
    title:SetText("Crafting Session Tracker")
    title:SetTextColor(OR[1], OR[2], OR[3])

    local sub = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sub:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -30)
    sub:SetText("Track your alchemy proc rates and session statistics")
    sub:SetTextColor(0.50, 0.50, 0.50)

    -- Column headers
    local function MakeColHead(txt, x)
        local fs = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("TOPLEFT", f, "TOPLEFT", x, -46)
        fs:SetWidth(H_COL_W)
        fs:SetJustifyH("RIGHT")
        fs:SetTextColor(OR[1], OR[2], OR[3])
        fs:SetText(txt)
    end
    MakeColHead("Base",  H_BASE)
    MakeColHead("Total", H_TOTAL)
    MakeColHead("Proc%", H_PCT)

    MakeDivider(f, 8, -58, -24)
    MakeFrameCloseButton(f)

    -- Scroll frame (leaves right gutter for the custom scrollbar)
    local SB_W = 6
    local sf = CreateFrame("ScrollFrame", "APT_HistorySF", f)
    sf:SetPoint("TOPLEFT",     f, "TOPLEFT",     8,          -62)
    sf:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -(SB_W+8),    8)
    f.sf = sf

    local sc = CreateFrame("Frame", "APT_HistorySC", sf)
    sc:SetSize(sf:GetWidth() or (H_DEF_W - 20), 10)
    sf:SetScrollChild(sc)
    f.sc = sc

    -- Custom scrollbar (themed, drag-to-scroll)
    -- topOffset=62 matches the header height; botOffset=8 matches bottom padding
    f.UpdateScrollbar = MakeCustomScrollbar(f, sf, sc, 62, 8)

    -- Resize grip; also refreshes scrollbar after resize
    MakeResizeGrip(f, function(frame)
        local point, _, relPoint, x, y = frame:GetPoint()
        APT.db.char.historyPos = { point=point, relPoint=relPoint, x=x, y=y,
                                   w=frame:GetWidth(), h=frame:GetHeight() }
        if frame.UpdateScrollbar then frame.UpdateScrollbar() end
    end)

    -- ── Row pool ─────────────────────────────────────────────
    f.rows = {}
    for i = 1, H_MAX_ROWS do
        local row = CreateFrame("Frame", nil, sc)
        row:SetHeight(H_ROW)
        row:Hide()

        local rbg = row:CreateTexture(nil, "BACKGROUND")
        rbg:SetAllPoints(row)
        rbg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
        rbg:SetVertexColor(0, 0, 0, 0)
        row.rbg = rbg

        local btn = CreateFrame("Button", nil, row)
        btn:SetAllPoints(row)
        btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        btn:SetScript("OnEnter", function()
            rbg:SetVertexColor(OR[1], OR[2], OR[3], 0.12)
        end)
        btn:SetScript("OnLeave", function()
            rbg:SetVertexColor(row._r or 0, row._g or 0, row._b or 0, row._a or 0)
        end)
        row.btn = btn

        local arrow = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        arrow:SetPoint("LEFT", row, "LEFT", H_ARROW, 0)
        arrow:SetWidth(14)
        arrow:SetJustifyH("LEFT")
        row.arrow = arrow

        local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        lbl:SetPoint("LEFT",  row, "LEFT", H_LABEL, 0)
        lbl:SetPoint("RIGHT", row, "LEFT", H_BASE - 4, 0)
        lbl:SetJustifyH("LEFT")
        row.lbl = lbl

        local base = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        base:SetPoint("LEFT", row, "LEFT", H_BASE, 0)
        base:SetWidth(H_COL_W)
        base:SetJustifyH("RIGHT")
        row.base = base

        local total = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        total:SetPoint("LEFT", row, "LEFT", H_TOTAL, 0)
        total:SetWidth(H_COL_W)
        total:SetJustifyH("RIGHT")
        row.total = total

        local pct = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        pct:SetPoint("LEFT", row, "LEFT", H_PCT, 0)
        pct:SetWidth(H_COL_W)
        pct:SetJustifyH("RIGHT")
        pct:SetTextColor(GRN[1], GRN[2], GRN[3])
        row.pct = pct

        f.rows[i] = row
    end
end
