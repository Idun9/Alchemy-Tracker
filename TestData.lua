-- TestData.lua
-- Injects fake session history and stats so the UI can be previewed without
-- crafting anything.
--
-- USAGE: Add "TestData.lua" to AlchemyTracker.toc (after Commands.lua),
--        reload UI, then open /apt history.
-- REMOVE the .toc entry again before shipping/playing normally.

local APT = AlchemyTracker

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function()
    if not APT.db or not APT.db.char then return end

    -- ── Sessions ──────────────────────────────────────────────
    -- Each entry: date, duration (seconds), optional customName, then
    -- group tables (FLASK/ELIXIR/POTION/TRANSMUTE) with item arrays.
    local sessions = {
        {
            date="2026-03-09 14:22", duration=3720, customName=nil,
            FLASK    = { { n="Flask of Fortification",      tc=18, tp=26, te=8  },
                         { n="Flask of Relentless Assault", tc=12, tp=16, te=4  } },
            ELIXIR   = { { n="Elixir of Major Agility",     tc=25, tp=34, te=9  },
                         { n="Elixir of Major Strength",    tc=10, tp=13, te=3  } },
            POTION   = { { n="Super Healing Potion",        tc=30, tp=42, te=12 } },
            TRANSMUTE= { { n="Primal Might",                tc= 5, tp= 7, te=2  } },
        },
        {
            date="2026-03-10 19:05", duration=5400, customName="Flask Farm Run",
            FLASK    = { { n="Flask of Fortification",      tc=22, tp=31, te=9  },
                         { n="Flask of Blinding Light",     tc=14, tp=19, te=5  } },
            ELIXIR   = { { n="Elixir of Major Agility",     tc=20, tp=27, te=7  },
                         { n="Elixir of Healing Power",     tc= 8, tp=10, te=2  } },
            POTION   = { { n="Super Mana Potion",           tc=24, tp=33, te=9  },
                         { n="Super Healing Potion",        tc=15, tp=20, te=5  } },
            TRANSMUTE= {},
        },
        {
            date="2026-03-11 21:38", duration=2160, customName=nil,
            FLASK    = { { n="Flask of Relentless Assault", tc=16, tp=22, te=6  },
                         { n="Flask of Mighty Restoration", tc=10, tp=13, te=3  } },
            ELIXIR   = { { n="Elixir of Major Strength",    tc=18, tp=25, te=7  },
                         { n="Elixir of Mastery",           tc= 6, tp= 8, te=2  } },
            POTION   = { { n="Super Healing Potion",        tc=20, tp=28, te=8  } },
            TRANSMUTE= { { n="Primal Might",                tc= 4, tp= 6, te=2  } },
        },
        {
            date="2026-03-12 16:14", duration=4860, customName="Elixir Night",
            FLASK    = { { n="Flask of Fortification",      tc=26, tp=36, te=10 } },
            ELIXIR   = { { n="Elixir of Major Agility",     tc=30, tp=42, te=12 },
                         { n="Elixir of Major Strength",    tc=14, tp=19, te=5  },
                         { n="Elixir of Healing Power",     tc=12, tp=16, te=4  } },
            POTION   = { { n="Super Mana Potion",           tc=18, tp=25, te=7  } },
            TRANSMUTE= { { n="Primal Might",                tc= 6, tp= 8, te=2  } },
        },
        {
            date="2026-03-13 20:47", duration=nil, customName=nil,
            FLASK    = { { n="Flask of Blinding Light",     tc=20, tp=27, te=7  },
                         { n="Flask of Mighty Restoration", tc=15, tp=20, te=5  } },
            ELIXIR   = { { n="Elixir of Mastery",           tc=10, tp=14, te=4  } },
            POTION   = { { n="Super Healing Potion",        tc=25, tp=35, te=10 },
                         { n="Super Mana Potion",           tc=16, tp=22, te=6  } },
            TRANSMUTE= { { n="Primal Might",                tc= 3, tp= 4, te=1  } },
        },
    }

    -- Build a stats block from one session definition
    local function buildStats(def)
        local out = {}
        for _, g in ipairs(APT.GROUPS_ORDER) do
            local items = {}
            local tc, tp, te = 0, 0, 0
            for _, it in ipairs(def[g] or {}) do
                items[it.n] = { name=it.n, totalCrafts=it.tc, totalPotions=it.tp, totalExtra=it.te }
                tc = tc + it.tc;  tp = tp + it.tp;  te = te + it.te
            end
            out[g] = { totalCrafts=tc, totalPotions=tp, totalExtra=te, items=items }
        end
        return out
    end

    -- Populate session list
    APT.db.char.sessions = {}
    for i, sd in ipairs(sessions) do
        table.insert(APT.db.char.sessions, {
            id         = i,
            date       = sd.date,
            duration   = sd.duration,
            customName = sd.customName,
            stats      = buildStats(sd),
        })
    end
    APT.db.char.nextSessionID = #sessions

    -- Overall stats = sum across all sessions
    for _, g in ipairs(APT.GROUPS_ORDER) do
        APT.db.char.stats[g] = APT.db.char.stats[g] or {}
        local tc, tp, te = 0, 0, 0
        for _, sd in ipairs(sessions) do
            for _, it in ipairs(sd[g] or {}) do
                tc = tc + it.tc;  tp = tp + it.tp;  te = te + it.te
            end
        end
        APT.db.char.stats[g].overall = {
            totalCrafts=tc, totalPotions=tp, totalExtra=te,
            procs1=math.floor(tc*0.20), procs2=math.floor(tc*0.08),
            procs3=math.floor(tc*0.02), procs4=0,
        }
        -- Current session = last entry's data
        local last = sessions[#sessions]
        local ltc, ltp, lte = 0, 0, 0
        local litems = {}
        for _, it in ipairs(last[g] or {}) do
            ltc = ltc + it.tc;  ltp = ltp + it.tp;  lte = lte + it.te
            litems[it.n] = { name=it.n, totalCrafts=it.tc, totalPotions=it.tp, totalExtra=it.te }
        end
        APT.db.char.stats[g].session = {
            totalCrafts=ltc, totalPotions=ltp, totalExtra=lte,
            procs1=math.floor(ltc*0.20), procs2=math.floor(ltc*0.08),
            procs3=math.floor(ltc*0.02), procs4=0,
            items=litems,
        }
    end

    -- Open both windows side by side
    APT.db.char.windowPos  = false
    APT.db.char.historyPos = false
    APT.db.char.expandedSessions = {}

    if APT.frame then
        APT.frame:SetSize(APT.frame._defW or 300, APT.frame._defH or 217)
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

    if APT.InvalidateStatsCache then APT.InvalidateStatsCache() end
    if APT.RefreshUI      then APT.RefreshUI()      end
    if APT.RefreshHistory then APT.RefreshHistory() end

    print("|cffffd700AlchemyTracker:|r Test data loaded — 5 sessions, 10 items across 4 groups.")
end)
