-- TestData.lua
-- Defines APT.TEST_SESSIONS used by the "Load Test Data" settings button.
-- Edit this table freely; a /reload is only needed once after changes.
-- To remove test-data support entirely, delete this file and its .toc entry.
--
-- IMPORTANT: each session must only contain groups that the character's
-- specialization can proc. A character has exactly ONE spec:
--   Elixir Master  → FLASK and ELIXIR (never POTION or TRANSMUTE)
--   Potion Master  → POTION only      (never FLASK, ELIXIR, or TRANSMUTE)
--   Transmute Master → TRANSMUTE only (never FLASK, ELIXIR, or POTION)
--
-- The sessions below represent an Elixir Master character.

local APT = AlchemyTracker

APT.TEST_SESSIONS = {
    {
        date="2026-03-09 14:22", duration=3720, customName=nil,
        FLASK    = { { n="Flask of Fortification",      tc=18, tp=26, te=8  },
                     { n="Flask of Relentless Assault", tc=12, tp=16, te=4  } },
        ELIXIR   = { { n="Elixir of Major Agility",     tc=25, tp=34, te=9  },
                     { n="Elixir of Major Strength",    tc=10, tp=13, te=3  } },
        POTION   = {},
        TRANSMUTE= {},
    },
    {
        date="2026-03-10 19:05", duration=5400, customName="Flask Farm Run",
        FLASK    = { { n="Flask of Fortification",      tc=22, tp=31, te=9  },
                     { n="Flask of Blinding Light",     tc=14, tp=19, te=5  } },
        ELIXIR   = { { n="Elixir of Major Agility",     tc=20, tp=27, te=7  },
                     { n="Elixir of Healing Power",     tc= 8, tp=10, te=2  } },
        POTION   = {},
        TRANSMUTE= {},
    },
    {
        date="2026-03-11 21:38", duration=2160, customName=nil,
        FLASK    = { { n="Flask of Relentless Assault", tc=16, tp=22, te=6  },
                     { n="Flask of Mighty Restoration", tc=10, tp=13, te=3  } },
        ELIXIR   = { { n="Elixir of Major Strength",    tc=18, tp=25, te=7  },
                     { n="Elixir of Mastery",           tc= 6, tp= 8, te=2  } },
        POTION   = {},
        TRANSMUTE= {},
    },
    {
        date="2026-03-12 16:14", duration=4860, customName="Elixir Night",
        FLASK    = { { n="Flask of Fortification",      tc=26, tp=36, te=10 } },
        ELIXIR   = { { n="Elixir of Major Agility",     tc=30, tp=42, te=12 },
                     { n="Elixir of Major Strength",    tc=14, tp=19, te=5  },
                     { n="Elixir of Healing Power",     tc=12, tp=16, te=4  } },
        POTION   = {},
        TRANSMUTE= {},
    },
    {
        date="2026-03-13 20:47", duration=nil, customName=nil,
        FLASK    = { { n="Flask of Blinding Light",     tc=20, tp=27, te=7  },
                     { n="Flask of Mighty Restoration", tc=15, tp=20, te=5  } },
        ELIXIR   = { { n="Elixir of Mastery",           tc=10, tp=14, te=4  },
                     { n="Elixir of Major Agility",     tc=16, tp=22, te=6  } },
        POTION   = {},
        TRANSMUTE= {},
    },
}
