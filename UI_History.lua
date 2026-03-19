-- UI_History.lua
-- Session history browser: collapsible tree (Sessions → Items)
-- with filter-by-item panel, overall stats banner, and item-click filtering.

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

-- Panel heights / offsets
local HEADER_BOT = 62    -- y from top where panels begin (below title/divider)
local FP_HDR_H   = 26    -- filter panel header height (collapsed)
local FP_CNT_H   = 60    -- filter panel content height (when expanded)
local SP_H       = 26    -- overall stats panel height
local SB_W       = 6     -- scrollbar width

-- ============================================================
-- State
-- ============================================================
local expandedSessions = {}
local selectedItems    = {}   -- name -> true
local filterExpanded   = false

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

local function ToggleItem(name)
    selectedItems[name] = selectedItems[name] and nil or true
    APT.RefreshHistory()
end

local function ClearFilter()
    wipe(selectedItems)
    APT.RefreshHistory()
end

local function HasFilter()
    return next(selectedItems) ~= nil
end

local function FilterCount()
    local n = 0
    for _ in pairs(selectedItems) do n = n + 1 end
    return n
end

-- ============================================================
-- Session Rename Dialog  (lazily created)
-- ============================================================
local RenameFrame
local RenameTarget

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
-- Helpers
-- ============================================================
local function SessionKey(sess, idx)
    return "sid_" .. (sess.id or ("d_" .. (sess.date or tostring(idx))))
end

local function FormatDuration(secs)
    if not secs or secs < 60 then return nil end
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    if h > 0 then return string.format("%dh %dm", h, m) end
    return string.format("%dm", m)
end

local function CalcProcPct(s)
    if not s or s.totalCrafts == 0 then return "—" end
    return string.format("%.1f%%", s.totalExtra / s.totalCrafts * 100)
end

-- Combine groups with optional item-name filter
local function CombineGroups(statsMap, filter)
    local useFilter = filter and next(filter) ~= nil
    local s = { totalCrafts = 0, totalPotions = 0, totalExtra = 0 }
    for _, g in ipairs(APT.GROUPS_ORDER) do
        local gs = statsMap[g]
        if gs then
            if not useFilter then
                s.totalCrafts  = s.totalCrafts  + gs.totalCrafts
                s.totalPotions = s.totalPotions + gs.totalPotions
                s.totalExtra   = s.totalExtra   + gs.totalExtra
            elseif gs.items then
                for _, it in pairs(gs.items) do
                    if filter[it.name] then
                        s.totalCrafts  = s.totalCrafts  + it.totalCrafts
                        s.totalPotions = s.totalPotions + it.totalPotions
                        s.totalExtra   = s.totalExtra   + it.totalExtra
                    end
                end
            end
        end
    end
    return s
end

-- Returns up to `limit` item names sorted by total potions across all sessions
local function GetTopItems(sessions, limit)
    local byName = {}
    for _, sess in ipairs(sessions) do
        for _, g in ipairs(APT.GROUPS_ORDER) do
            local gs = sess.stats and sess.stats[g]
            if gs and gs.items then
                for _, it in pairs(gs.items) do
                    if not byName[it.name] then
                        byName[it.name] = { name = it.name, totalPotions = 0 }
                    end
                    byName[it.name].totalPotions = byName[it.name].totalPotions + (it.totalPotions or 0)
                end
            end
        end
    end
    local list = {}
    for _, v in pairs(byName) do list[#list + 1] = v end
    table.sort(list, function(a, b) return a.totalPotions > b.totalPotions end)
    local result = {}
    for i = 1, math.min(limit or 5, #list) do
        result[i] = list[i].name
    end
    return result
end

-- ============================================================
-- APT.RefreshHistory
-- ============================================================
APT.RefreshHistory = function()
    local f = APT.historyFrame
    if not f or not f:IsShown() then return end
    if not APT.db then return end

    local OR, GRN  = APT.theme.OR, APT.theme.GRN
    local sessions = APT.db.char.sessions or {}

    -- ── Update layout (filter panel height drives sp/sf position) ──
    local fp = f.filterPanel
    if fp then
        local cnt = FilterCount()
        fp.hdrArrow:SetText(filterExpanded and "▼" or "▶")
        fp.hdrCount:SetText(cnt > 0 and ("(" .. cnt .. " selected)") or "")
        if cnt > 0 then fp.clearBtn:Show() else fp.clearBtn:Hide() end

        if filterExpanded then
            fp.content:Show()
            fp:SetHeight(FP_HDR_H + FP_CNT_H)

            local searchStr = fp.searchBox:GetText() or ""
            searchStr = searchStr:lower():match("^%s*(.-)%s*$") or ""

            local showItems
            if searchStr ~= "" then
                local all = GetTopItems(sessions, 200)
                showItems = {}
                for _, name in ipairs(all) do
                    if name:lower():find(searchStr, 1, true) then
                        showItems[#showItems + 1] = name
                        if #showItems >= 5 then break end
                    end
                end
                fp.sectionLabel:SetText(#showItems > 0 and "Search Results" or "No items found")
            else
                fp.sectionLabel:SetText("Top 5 Most Crafted")
                showItems = GetTopItems(sessions, 5)
            end

            for i = 1, 5 do
                local btn = fp.itemBtns[i]
                local name = showItems[i]
                if name then
                    btn._name = name
                    btn.lbl:SetText(name)
                    btn:Show()
                    if selectedItems[name] then
                        btn.bg:SetVertexColor(OR[1] * 0.28, OR[2] * 0.28, OR[3] * 0.28, 0.95)
                        btn.lbl:SetTextColor(OR[1], OR[2], OR[3])
                    else
                        btn.bg:SetVertexColor(0.10, 0.08, 0.04, 0.85)
                        btn.lbl:SetTextColor(0.65, 0.65, 0.65)
                    end
                else
                    btn._name = nil
                    btn:Hide()
                end
            end
        else
            fp.content:Hide()
            fp:SetHeight(FP_HDR_H)
        end

        -- Reposition stats panel and scroll frame based on fp height
        local fpH   = filterExpanded and (FP_HDR_H + FP_CNT_H) or FP_HDR_H
        local spTop = HEADER_BOT + fpH + 4
        local sfTop = spTop + SP_H + 4

        f.statsPanel:ClearAllPoints()
        f.statsPanel:SetPoint("TOPLEFT",  f, "TOPLEFT",  8,   -spTop)
        f.statsPanel:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, -spTop)

        f.sf:ClearAllPoints()
        f.sf:SetPoint("TOPLEFT",     f, "TOPLEFT",     8,           -sfTop)
        f.sf:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -(SB_W + 10), 8)

        f._sb:ClearAllPoints()
        f._sb:SetPoint("TOPRIGHT",    f, "TOPRIGHT",    -4, -sfTop)
        f._sb:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -4,  8)
    end

    -- ── Overall stats banner ───────────────────────────────────
    local sp = f.statsPanel
    if sp then
        local combined
        if HasFilter() then
            local s = { totalCrafts = 0, totalPotions = 0, totalExtra = 0 }
            for _, sess in ipairs(sessions) do
                local fc = CombineGroups(sess.stats or {}, selectedItems)
                s.totalCrafts  = s.totalCrafts  + fc.totalCrafts
                s.totalPotions = s.totalPotions + fc.totalPotions
                s.totalExtra   = s.totalExtra   + fc.totalExtra
            end
            combined = s
        else
            local ovMap = {}
            for _, g in ipairs(APT.GROUPS_ORDER) do
                ovMap[g] = APT.db.char.stats[g] and APT.db.char.stats[g].overall
            end
            combined = CombineGroups(ovMap, nil)
        end
        sp.labelTitle:SetText(HasFilter() and "Filtered Stats" or "Overall Stats")
        sp.labelBase:SetText("Base: "  .. tostring(combined.totalCrafts))
        sp.labelTotal:SetText("Total: " .. tostring(combined.totalPotions))
        sp.labelProc:SetText("Proc: "  .. CalcProcPct(combined))
    end

    -- ── Rebuild session rows ───────────────────────────────────
    local sc   = f.sc
    local rows = f.rows

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

    -- Session header row
    local function AddSessionHeader(label, key, combined, sessObj)
        local r = UseRow(22)
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

    -- Item column header row (shown inside expanded session)
    local function AddItemColHeader()
        local r = UseRow(18)
        if not r then return end
        if r._accent then r._accent:Hide() end
        r.lbl:ClearAllPoints()
        r.lbl:SetPoint("LEFT",  r, "LEFT", H_LABEL + 22, 0)
        r.lbl:SetPoint("RIGHT", r, "LEFT", H_BASE - 4,   0)
        r.lbl:SetText("Item")
        r.lbl:SetTextColor(OR[1] * 0.75, OR[2] * 0.75, OR[3] * 0.75)
        r.base:SetText("Base")   r.base:SetTextColor(OR[1] * 0.75, OR[2] * 0.75, OR[3] * 0.75)
        r.total:SetText("Total") r.total:SetTextColor(OR[1] * 0.75, OR[2] * 0.75, OR[3] * 0.75)
        r.pct:SetText("Proc%")   r.pct:SetTextColor(OR[1] * 0.75, OR[2] * 0.75, OR[3] * 0.75)
        SetRowBg(r, 0.07, 0.05, 0.02, 0.85)
        r.arrow:SetText("")
    end

    -- Clickable item row
    local function AddItemRow(it)
        local r = UseRow()
        if not r then return end
        if r._accent then r._accent:Hide() end
        local sel = selectedItems[it.name]
        r.lbl:ClearAllPoints()
        r.lbl:SetPoint("LEFT",  r, "LEFT", H_LABEL + 22, 0)
        r.lbl:SetPoint("RIGHT", r, "LEFT", H_BASE - 4,   0)
        r.lbl:SetText(it.name)
        if sel then
            r.lbl:SetTextColor(OR[1], OR[2], OR[3])
            r.base:SetTextColor(OR[1], OR[2], OR[3])
            r.total:SetTextColor(OR[1], OR[2], OR[3])
            SetRowBg(r, OR[1] * 0.08, OR[2] * 0.08, OR[3] * 0.08, 0.60)
        else
            r.lbl:SetTextColor(0.65, 0.65, 0.65)
            r.base:SetTextColor(0.65, 0.65, 0.65)
            r.total:SetTextColor(0.65, 0.65, 0.65)
            SetRowBg(r, 0, 0, 0, 0)
        end
        r.base:SetText(tostring(it.totalCrafts))
        r.total:SetText(tostring(it.totalPotions))
        r.pct:SetText(CalcProcPct(it))
        local name = it.name
        r.btn:SetScript("OnClick", function() ToggleItem(name) end)
    end

    -- Session total summary row
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

    local function RenderAllItems(statsMap)
        local sorted = {}
        for _, g in ipairs(APT.GROUPS_ORDER) do
            local gs = statsMap and statsMap[g]
            if gs and gs.items then
                for _, it in pairs(gs.items) do
                    if not HasFilter() or selectedItems[it.name] then
                        sorted[#sorted + 1] = it
                    end
                end
            end
        end
        table.sort(sorted, function(a, b) return a.name < b.name end)
        if #sorted > 0 then
            AddItemColHeader()
            for _, it in ipairs(sorted) do AddItemRow(it) end
        end
    end

    -- Sessions list
    local filter = HasFilter() and selectedItems or nil
    for i, sess in ipairs(sessions) do
        local key      = SessionKey(sess, i)
        local combined = CombineGroups(sess.stats or {}, filter)
        local dur      = sess.duration and FormatDuration(sess.duration)
        local dateStr  = sess.date or ""
        local dateLine = dur and (dateStr .. "  ·  " .. dur) or dateStr
        AddSessionHeader(
            string.format("Session %d  —  %s", i, dateLine),
            key, combined, sess)
        if expandedSessions[key] then
            RenderAllItems(sess.stats)
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

    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        local point, _, relPoint, x, y = f:GetPoint()
        APT.db.char.historyPos = { point=point, relPoint=relPoint, x=x, y=y,
                                   w=f:GetWidth(), h=f:GetHeight() }
    end)

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

    MakeDivider(f, 8, -58, -8)
    MakeFrameCloseButton(f)

    -- ── Filter Panel ──────────────────────────────────────────
    local fp = CreateFrame("Frame", nil, f)
    fp:SetPoint("TOPLEFT",  f, "TOPLEFT",  8,   -HEADER_BOT)
    fp:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, -HEADER_BOT)
    fp:SetHeight(FP_HDR_H)
    f.filterPanel = fp

    local fpBg = fp:CreateTexture(nil, "BACKGROUND")
    fpBg:SetAllPoints(fp)
    fpBg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
    fpBg:SetVertexColor(OR[1] * 0.06, OR[2] * 0.06, OR[3] * 0.06, 0.85)

    -- Header clickable area
    local fpHdr = CreateFrame("Button", nil, fp)
    fpHdr:SetPoint("TOPLEFT",  fp, "TOPLEFT",  0, 0)
    fpHdr:SetPoint("TOPRIGHT", fp, "TOPRIGHT", 0, 0)
    fpHdr:SetHeight(FP_HDR_H)

    local fpHdrHl = fpHdr:CreateTexture(nil, "BACKGROUND")
    fpHdrHl:SetAllPoints(fpHdr)
    fpHdrHl:SetTexture("Interface\\BUTTONS\\WHITE8X8")
    fpHdrHl:SetVertexColor(0, 0, 0, 0)
    fpHdr:SetScript("OnEnter", function() fpHdrHl:SetVertexColor(OR[1], OR[2], OR[3], 0.07) end)
    fpHdr:SetScript("OnLeave", function() fpHdrHl:SetVertexColor(0, 0, 0, 0) end)
    fpHdr:SetScript("OnClick", function()
        filterExpanded = not filterExpanded
        APT.RefreshHistory()
    end)

    local fpArrow = fp:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fpArrow:SetPoint("LEFT", fpHdr, "LEFT", 6, 0)
    fpArrow:SetWidth(14)
    fpArrow:SetJustifyH("LEFT")
    fpArrow:SetTextColor(OR[1], OR[2], OR[3])
    fpArrow:SetText("▶")
    fp.hdrArrow = fpArrow

    local fpLabel = fp:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fpLabel:SetPoint("LEFT", fpArrow, "RIGHT", 4, 0)
    fpLabel:SetTextColor(0.82, 0.82, 0.82)
    fpLabel:SetText("Filter by Item")
    fp.hdrLabel = fpLabel

    local fpCount = fp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fpCount:SetPoint("LEFT", fpLabel, "RIGHT", 8, 0)
    fpCount:SetTextColor(0.50, 0.50, 0.50)
    fpCount:SetText("")
    fp.hdrCount = fpCount

    -- Clear button
    local fpClear = CreateFrame("Button", nil, fp)
    fpClear:SetSize(52, 18)
    fpClear:SetPoint("RIGHT", fpHdr, "RIGHT", -4, 0)
    local fpClearBg = fpClear:CreateTexture(nil, "BACKGROUND")
    fpClearBg:SetAllPoints(fpClear)
    fpClearBg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
    fpClearBg:SetVertexColor(0.32, 0.07, 0.07, 0.90)
    local fpClearLbl = fpClear:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fpClearLbl:SetAllPoints(fpClear)
    fpClearLbl:SetText("Clear")
    fpClearLbl:SetTextColor(1, 1, 1)
    fpClear:SetScript("OnEnter", function() fpClearBg:SetVertexColor(0.60, 0.12, 0.12, 0.95) end)
    fpClear:SetScript("OnLeave", function() fpClearBg:SetVertexColor(0.32, 0.07, 0.07, 0.90) end)
    fpClear:SetScript("OnClick", ClearFilter)
    fpClear:Hide()
    fp.clearBtn = fpClear

    -- Filter panel content (expanded area)
    local fpContent = CreateFrame("Frame", nil, fp)
    fpContent:SetPoint("TOPLEFT",  fp, "TOPLEFT",  4, -FP_HDR_H)
    fpContent:SetPoint("TOPRIGHT", fp, "TOPRIGHT", -4, -FP_HDR_H)
    fpContent:SetHeight(FP_CNT_H)
    fpContent:Hide()
    fp.content = fpContent

    local fpSecLbl = fpContent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fpSecLbl:SetPoint("TOPLEFT", fpContent, "TOPLEFT", 0, -2)
    fpSecLbl:SetTextColor(0.42, 0.42, 0.42)
    fpSecLbl:SetText("Top 5 Most Crafted")
    fp.sectionLabel = fpSecLbl

    -- 5 item filter buttons (88px each, 3px gap)
    fp.itemBtns = {}
    local BTN_W = 88
    local BTN_H = 18
    for i = 1, 5 do
        local bx = (i - 1) * (BTN_W + 3)
        local btn = CreateFrame("Button", nil, fpContent)
        btn:SetSize(BTN_W, BTN_H)
        btn:SetPoint("TOPLEFT", fpContent, "TOPLEFT", bx, -14)
        btn:Hide()

        local bbg = btn:CreateTexture(nil, "BACKGROUND")
        bbg:SetAllPoints(btn)
        bbg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
        bbg:SetVertexColor(0.10, 0.08, 0.04, 0.85)
        btn.bg = bbg

        -- Thin border lines on each button
        local function MakeThin(p1, rp1, x1, y1, p2, rp2, x2, y2, isH)
            local b = CreateFrame("Frame", nil, btn)
            b:SetPoint(p1, btn, rp1, x1, y1)
            b:SetPoint(p2, btn, rp2, x2, y2)
            if isH then b:SetHeight(1) else b:SetWidth(1) end
            local t = b:CreateTexture(nil, "ARTWORK")
            t:SetAllPoints(b)
            t:SetTexture("Interface\\BUTTONS\\WHITE8X8")
            t:SetVertexColor(OR[1] * 0.4, OR[2] * 0.4, OR[3] * 0.4)
        end
        MakeThin("TOPLEFT",    "TOPLEFT",    0,  0, "TOPRIGHT",    "TOPRIGHT",    0,  0, true)
        MakeThin("BOTTOMLEFT", "BOTTOMLEFT", 0,  0, "BOTTOMRIGHT", "BOTTOMRIGHT", 0,  0, true)
        MakeThin("TOPLEFT",    "TOPLEFT",    0,  0, "BOTTOMLEFT",  "BOTTOMLEFT",  0,  0, false)
        MakeThin("TOPRIGHT",   "TOPRIGHT",  -1,  0, "BOTTOMRIGHT", "BOTTOMRIGHT", -1, 0, false)

        local blbl = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        blbl:SetAllPoints(btn)
        blbl:SetJustifyH("CENTER")
        blbl:SetJustifyV("MIDDLE")
        blbl:SetTextColor(0.65, 0.65, 0.65)
        btn.lbl = blbl

        btn:SetScript("OnEnter", function()
            bbg:SetVertexColor(OR[1] * 0.20, OR[2] * 0.20, OR[3] * 0.20, 0.95)
        end)
        btn:SetScript("OnLeave", function()
            if btn._name and selectedItems[btn._name] then
                bbg:SetVertexColor(OR[1] * 0.28, OR[2] * 0.28, OR[3] * 0.28, 0.95)
            else
                bbg:SetVertexColor(0.10, 0.08, 0.04, 0.85)
            end
        end)
        btn:SetScript("OnClick", function()
            if btn._name then ToggleItem(btn._name) end
        end)
        fp.itemBtns[i] = btn
    end

    -- Search box
    local searchBox = CreateFrame("EditBox", "APT_HistorySearch", fpContent, "InputBoxTemplate")
    searchBox:SetPoint("TOPLEFT",  fpContent, "TOPLEFT",  0, -36)
    searchBox:SetPoint("TOPRIGHT", fpContent, "TOPRIGHT", 0, -36)
    searchBox:SetHeight(20)
    searchBox:SetAutoFocus(false)
    searchBox:SetMaxLetters(64)
    searchBox:SetScript("OnTextChanged", function() APT.RefreshHistory() end)
    searchBox:SetScript("OnEscapePressed", function(self)
        self:SetText("")
        self:ClearFocus()
        APT.RefreshHistory()
    end)
    fp.searchBox = searchBox

    -- ── Overall Stats Panel ────────────────────────────────────
    -- Initial position (filter collapsed): HEADER_BOT + FP_HDR_H + 4
    local spTop0 = HEADER_BOT + FP_HDR_H + 4

    local sp = CreateFrame("Frame", nil, f)
    sp:SetPoint("TOPLEFT",  f, "TOPLEFT",  8,   -spTop0)
    sp:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, -spTop0)
    sp:SetHeight(SP_H)
    f.statsPanel = sp

    local spBg = sp:CreateTexture(nil, "BACKGROUND")
    spBg:SetAllPoints(sp)
    spBg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
    spBg:SetVertexColor(OR[1] * 0.14, OR[2] * 0.14, OR[3] * 0.14, 0.90)
    DrawBorders(sp)

    -- Orange left accent bar
    local spAccent = sp:CreateTexture(nil, "ARTWORK")
    spAccent:SetTexture("Interface\\BUTTONS\\WHITE8X8")
    spAccent:SetVertexColor(OR[1], OR[2], OR[3])
    spAccent:SetPoint("TOPLEFT",    sp, "TOPLEFT",    0, 0)
    spAccent:SetPoint("BOTTOMLEFT", sp, "BOTTOMLEFT", 0, 0)
    spAccent:SetWidth(3)

    local spTitle = sp:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    spTitle:SetPoint("LEFT", sp, "LEFT", 10, 0)
    spTitle:SetTextColor(OR[1], OR[2], OR[3])
    spTitle:SetText("Overall Stats")
    sp.labelTitle = spTitle

    local spBase = sp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    spBase:SetPoint("LEFT", sp, "LEFT", H_BASE - 20, 0)
    spBase:SetWidth(H_COL_W + 20)
    spBase:SetJustifyH("RIGHT")
    spBase:SetTextColor(0.72, 0.72, 0.72)
    spBase:SetText("Base: —")
    sp.labelBase = spBase

    local spTotal = sp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    spTotal:SetPoint("LEFT", sp, "LEFT", H_TOTAL - 20, 0)
    spTotal:SetWidth(H_COL_W + 20)
    spTotal:SetJustifyH("RIGHT")
    spTotal:SetTextColor(0.72, 0.72, 0.72)
    spTotal:SetText("Total: —")
    sp.labelTotal = spTotal

    local spProc = sp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    spProc:SetPoint("LEFT", sp, "LEFT", H_PCT - 20, 0)
    spProc:SetWidth(H_COL_W + 20)
    spProc:SetJustifyH("RIGHT")
    spProc:SetTextColor(GRN[1], GRN[2], GRN[3])
    spProc:SetText("Proc: —")
    sp.labelProc = spProc

    -- ── Scroll Frame ───────────────────────────────────────────
    local sfTop0 = spTop0 + SP_H + 4

    local sf = CreateFrame("ScrollFrame", "APT_HistorySF", f)
    sf:SetPoint("TOPLEFT",     f, "TOPLEFT",     8,           -sfTop0)
    sf:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -(SB_W + 10), 8)
    f.sf = sf

    local sc = CreateFrame("Frame", "APT_HistorySC", sf)
    sc:SetSize(sf:GetWidth() or (H_DEF_W - 20), 10)
    sf:SetScrollChild(sc)
    f.sc = sc

    -- ── Inline Scrollbar (anchored to f, repositioned with layout) ──
    local sb = CreateFrame("Frame", nil, f)
    sb:SetPoint("TOPRIGHT",    f, "TOPRIGHT",    -4, -sfTop0)
    sb:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -4,  8)
    sb:SetWidth(SB_W)
    f._sb = sb

    local sbTrack = sb:CreateTexture(nil, "BACKGROUND")
    sbTrack:SetAllPoints(sb)
    sbTrack:SetTexture("Interface\\BUTTONS\\WHITE8X8")
    sbTrack:SetVertexColor(0.12, 0.12, 0.12)

    local thumb = CreateFrame("Button", nil, sb)
    thumb:SetWidth(SB_W)
    thumb:SetHeight(40)
    thumb:SetPoint("TOPLEFT",  sb, "TOPLEFT",  0, 0)
    thumb:SetPoint("TOPRIGHT", sb, "TOPRIGHT", 0, 0)

    local thumbTex = thumb:CreateTexture(nil, "BACKGROUND")
    thumbTex:SetAllPoints(thumb)
    thumbTex:SetTexture("Interface\\BUTTONS\\WHITE8X8")
    thumbTex:SetVertexColor(OR[1], OR[2], OR[3], 0.65)
    thumb:SetScript("OnEnter", function() thumbTex:SetVertexColor(OR[1], OR[2], OR[3], 1.00) end)
    thumb:SetScript("OnLeave", function() thumbTex:SetVertexColor(OR[1], OR[2], OR[3], 0.65) end)

    local function UpdateScrollbar()
        local contentH    = sc:GetHeight()
        local viewH       = sf:GetHeight()
        local scrollRange = sf:GetVerticalScrollRange()
        if contentH <= viewH or scrollRange == 0 then
            thumb:Hide(); return
        end
        thumb:Show()
        local trackH    = sb:GetHeight()
        local thumbH    = math.max(20, trackH * (viewH / contentH))
        local scrollPct = sf:GetVerticalScroll() / scrollRange
        local offsetY   = (trackH - thumbH) * scrollPct
        thumb:SetHeight(thumbH)
        thumb:ClearAllPoints()
        thumb:SetPoint("TOPLEFT",  sb, "TOPLEFT",  0, -offsetY)
        thumb:SetPoint("TOPRIGHT", sb, "TOPRIGHT", 0, -offsetY)
    end
    f.UpdateScrollbar = UpdateScrollbar

    sf:EnableMouseWheel(true)
    sf:SetScript("OnMouseWheel", function(self, delta)
        local cur = self:GetVerticalScroll()
        local max = self:GetVerticalScrollRange()
        self:SetVerticalScroll(math.max(0, math.min(max, cur - delta * 20)))
        UpdateScrollbar()
    end)

    local dragStartY, dragStartScroll = 0, 0
    thumb:RegisterForClicks("LeftButtonUp")
    thumb:SetScript("OnMouseDown", function(_, btn)
        if btn ~= "LeftButton" then return end
        dragStartY      = select(2, GetCursorPosition()) / UIParent:GetEffectiveScale()
        dragStartScroll = sf:GetVerticalScroll()
        thumb:SetScript("OnUpdate", function()
            local curY_   = select(2, GetCursorPosition()) / UIParent:GetEffectiveScale()
            local delta   = dragStartY - curY_
            local trackH  = sb:GetHeight()
            local thumbH  = thumb:GetHeight()
            local maxS    = sf:GetVerticalScrollRange()
            if trackH > thumbH then
                sf:SetVerticalScroll(math.max(0, math.min(maxS,
                    dragStartScroll + delta * maxS / (trackH - thumbH))))
                UpdateScrollbar()
            end
        end)
    end)
    thumb:SetScript("OnMouseUp", function()
        thumb:SetScript("OnUpdate", nil)
        UpdateScrollbar()
    end)

    -- ── Resize Grip ────────────────────────────────────────────
    MakeResizeGrip(f, function(frame)
        local point, _, relPoint, x, y = frame:GetPoint()
        APT.db.char.historyPos = { point=point, relPoint=relPoint, x=x, y=y,
                                   w=frame:GetWidth(), h=frame:GetHeight() }
        UpdateScrollbar()
    end)

    -- ── Row Pool ───────────────────────────────────────────────
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
