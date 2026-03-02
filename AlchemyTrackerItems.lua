-- AlchemyTrackerItems.lua
-- All item data for the Alchemy Proc Tracker, organized as:
--
--   AlchemyTrackerItemData[expansion][group][itemID] = "Item Name"
--
-- expansion : a label string, e.g. "TBC", "Classic"
-- group     : one of "FLASK", "ELIXIR", "POTION", "TRANSMUTE"
-- itemID    : the numeric item ID of the CRAFTED (output) item
-- name      : display string used in chat messages and the UI
--
-- HOW TO VERIFY ITEMS
--   1. Find the item on Wowhead TBC: https://www.wowhead.com/tbc/item=ITEMID
--   2. Confirm the name matches. If wrong, correct the ID.
--   3. Add or fix the line and /reload in-game.
--
-- IMPORTANT: always use the CRAFTED ITEM ID, not the recipe/scroll ID.
-- Recipe IDs and item IDs are different numbers for the same name.
-- Example: "Flask of Fortification" item = 22851; its recipe scroll = different.
--
-- DATA SOURCES
--   Primary item search:  https://www.wowhead.com/tbc/search?q=NAME&type=item&json
--   Item verification:    https://www.wowhead.com/tbc/item=ITEMID
--   Item verification:    https://warcraftdb.com/tbc/item/ITEMID
--   Transmute spell IDs:  verified via recipe item pages on Wowhead TBC
--                         e.g. https://www.wowhead.com/tbc/item=22915 (links to taught spell)
--
-- NOTE ON RECIPE vs ITEM IDs
--   Wowhead search returns both the craftable item and its recipe scroll under
--   the same name. Always pick the lower-numbered result — recipe scrolls
--   typically have higher IDs than the items they teach.

AlchemyTrackerItemData = {

    -- ============================================================
    -- The Burning Crusade
    -- ============================================================
    ["TBC"] = {

        -- ------------------------------------------------------------
        -- FLASK
        -- Elixir Master procs on flasks AND elixirs.
        -- Only alchemist-CRAFTED flasks are listed here.
        -- Shattrath flasks and Unstable flasks are vendor/quest items;
        -- they never produce a "You create" message and are omitted.
        -- ------------------------------------------------------------
        ["FLASK"] = {
            [22851] = "Flask of Fortification",
            [22853] = "Flask of Mighty Restoration",
            [22854] = "Flask of Relentless Assault",
            [22861] = "Flask of Blinding Light",
            [22866] = "Flask of Pure Death",
            [33208] = "Flask of Chromatic Wonder",           -- Phase 5, Sunwell patch
        },

        -- ------------------------------------------------------------
        -- ELIXIR
        -- Elixir Master procs on elixirs and flasks (above).
        -- TBC uses Battle / Guardian elixir slots; one of each allowed.
        -- ------------------------------------------------------------
        ["ELIXIR"] = {
            -- Battle Elixirs
            [22824] = "Elixir of Major Strength",
            [22825] = "Elixir of Healing Power",
            [22827] = "Elixir of Major Frost Power",
            [22831] = "Elixir of Major Agility",
            [22833] = "Elixir of Major Firepower",
            [22835] = "Elixir of Major Shadow Power",
            [22840] = "Elixir of Major Mageblood",
            [22848] = "Elixir of Empowerment",
            [28102] = "Onslaught Elixir",
            [28103] = "Adept's Elixir",
            [31679] = "Fel Strength Elixir",
            -- Guardian Elixirs
            [22823] = "Elixir of Camouflage",
            [22830] = "Elixir of the Searching Eye",
            [22834] = "Elixir of Major Defense",
            [28104] = "Elixir of Mastery",
            [32062] = "Elixir of Major Fortitude",
            [32063] = "Earthen Elixir",
            [32067] = "Elixir of Draenic Wisdom",
            [32068] = "Elixir of Ironskin",
        },

        -- ------------------------------------------------------------
        -- POTION
        -- Potion Master procs on all potions.
        -- ------------------------------------------------------------
        ["POTION"] = {
            -- Health / Mana
            [22829] = "Super Healing Potion",
            [22832] = "Super Mana Potion",
            [22850] = "Super Rejuvenation Potion",
            [28100] = "Volatile Healing Potion",             -- (verify) wowhead.com/tbc/item=28100
            [28101] = "Unstable Mana Potion",               -- (verify) wowhead.com/tbc/item=28101
            -- Combat cooldown potions
            [22828] = "Insane Strength Potion",
            [22837] = "Heroic Potion",
            [22838] = "Haste Potion",
            [22839] = "Destruction Potion",
            [22849] = "Ironshield Potion",
            -- Utility
            [22826] = "Sneaking Potion",
            [22836] = "Major Dreamless Sleep Potion",
            [22871] = "Shrouding Potion",
            -- Resistance
            [22841] = "Major Fire Protection Potion",
            [22842] = "Major Frost Protection Potion",
            [22844] = "Major Nature Protection Potion",
            [22845] = "Major Arcane Protection Potion",
            [22846] = "Major Shadow Protection Potion",
            [22847] = "Major Holy Protection Potion",
            -- Later phases
            [31676] = "Fel Regeneration Potion",
            [31677] = "Fel Mana Potion",
            [34440] = "Mad Alchemist's Potion",              -- Phase 5, Sunwell patch
        },

        -- ------------------------------------------------------------
        -- TRANSMUTE
        -- Transmute Master procs on all transmutes.
        -- Each entry maps the OUTPUT item ID to the item name.
        -- Spell IDs for cooldown tracking: see AlchemyTransmuteSpellIDs below.
        -- ------------------------------------------------------------
        ["TRANSMUTE"] = {
            -- Primal element cross-transmutes (share a single 23-hour cooldown)
            [21884] = "Primal Fire",        -- spellID 28566  (from Primal Air)
            [21885] = "Primal Water",       -- spellID 28567  (from Primal Earth)
            [22451] = "Primal Air",         -- spellID 28569  (from Primal Water)
            [22452] = "Primal Earth",       -- spellID 28568  (from Primal Fire)
            -- Primal Might (its own separate 20-hour cooldown)
            [23571] = "Primal Might",       -- spellID 29688
            -- Meta gem transmutes (share their own separate 23-hour cooldown)
            [25867] = "Earthstorm Diamond", -- spellID 32765
            [25868] = "Skyfire Diamond",    -- spellID 32766
        },
    },

    -- ============================================================
    -- Classic (Vanilla)
    -- ============================================================
    ["Classic"] = {

        -- ------------------------------------------------------------
        -- FLASK
        -- ------------------------------------------------------------
        ["FLASK"] = {
            [13506] = "Flask of Petrification",
            [13510] = "Flask of the Titans",
            [13511] = "Flask of Distilled Wisdom",
            [13512] = "Flask of Supreme Power",
            [13513] = "Flask of Chromatic Resistance",
            [20130] = "Diamond Flask",
        },

        -- ------------------------------------------------------------
        -- ELIXIR
        -- End-game relevant elixirs from Classic raiding.
        -- ------------------------------------------------------------
        ["ELIXIR"] = {
            -- Offensive
            [6373]  = "Elixir of Firepower",
            [8949]  = "Elixir of Agility",
            [9155]  = "Arcane Elixir",
            [9179]  = "Elixir of Greater Intellect",
            [9187]  = "Elixir of Greater Agility",
            [9206]  = "Elixir of Giants",
            [9224]  = "Elixir of Demonslaying",
            [9264]  = "Elixir of Shadow Power",
            [13447] = "Elixir of the Sages",
            [13452] = "Elixir of the Mongoose",
            [13453] = "Elixir of Brute Force",
            [13454] = "Greater Arcane Elixir",
            [17708] = "Elixir of Frost Power",
            [21546] = "Elixir of Greater Firepower",
            -- Defensive
            [3825]  = "Elixir of Fortitude",
            [8951]  = "Elixir of Greater Defense",
            [13445] = "Elixir of Superior Defense",
        },

        -- ------------------------------------------------------------
        -- POTION
        -- End-game relevant potions from Classic raiding.
        -- ------------------------------------------------------------
        ["POTION"] = {
            -- Combat
            [3387]  = "Limited Invulnerability Potion",
            [5633]  = "Great Rage Potion",
            [5634]  = "Free Action Potion",
            [9172]  = "Invisibility Potion",
            [13442] = "Mighty Rage Potion",
            [20008] = "Living Action Potion",
            -- Health / Mana
            [13443] = "Superior Mana Potion",
            [13444] = "Major Mana Potion",
            [13446] = "Major Healing Potion",
            [18253] = "Major Rejuvenation Potion",
            [20007] = "Mageblood Potion",
            [20004] = "Major Troll's Blood Potion",
            -- Utility
            [9030]  = "Restorative Potion",
            [9036]  = "Magic Resistance Potion",
            [9144]  = "Wildvine Potion",
            [12190] = "Dreamless Sleep Potion",
            [20002] = "Greater Dreamless Sleep Potion",
            -- Resistance
            [13455] = "Greater Stoneshield Potion",
            [13456] = "Greater Frost Protection Potion",
            [13457] = "Greater Fire Protection Potion",
            [13458] = "Greater Nature Protection Potion",
            [13459] = "Greater Shadow Protection Potion",
            [13460] = "Greater Holy Protection Potion",
            [13461] = "Greater Arcane Protection Potion",
            [13462] = "Purification Potion",
        },

        -- ------------------------------------------------------------
        -- TRANSMUTE
        -- All Classic transmutes share a 2-day cooldown per category.
        -- Spell IDs are in AlchemyTransmuteSpellIDs below.
        -- Note: Essence of Earth and Essence of Water each have two
        -- source transmutes; only one entry per output item is needed.
        -- ------------------------------------------------------------
        ["TRANSMUTE"] = {
            -- Metal bars
            [3577]  = "Gold Bar",           -- spellID 11479  (Iron → Gold)
            [6037]  = "Truesilver Bar",     -- spellID 11480  (Mithril → Truesilver)
            [12360] = "Arcanite Bar",       -- spellID 17187  (Thorium + Arcane Crystal)
            -- Essences (elemental cross-transmutes)
            [7076]  = "Essence of Earth",   -- spellID 17560 (Fire→Earth) or 17594 (Life→Earth)
            [7078]  = "Essence of Fire",    -- spellID 17559  (Air → Fire)
            [7080]  = "Essence of Water",   -- spellID 17561 (Earth→Water) or 17563 (Undeath→Water)
            [7082]  = "Essence of Air",     -- spellID 17562  (Water → Air)
            [12803] = "Living Essence",     -- spellID 17566  (Earth → Life)
            [12808] = "Essence of Undeath", -- spellID 17564  (Water → Undeath)
        },
    },
}

-- ============================================================
-- AlchemyTransmuteSpellIDs
-- Spell IDs for future cooldown tracking.
-- NOT iterated by the proc-tracking loop above (which tracks item IDs
-- from craft messages). Stored here so you can wire up cooldown
-- detection later without having to look up the IDs again.
--
-- TBC cooldown groups:
--   Group A – 23-hour shared CD: elemental cross-transmutes (28566–28569)
--   Group B – 20-hour own CD:    Primal Might (29688)
--   Group C – 23-hour shared CD: meta gem transmutes (32765, 32766)
-- Classic:
--   Arcanite (11479) – 2-day own CD
-- ============================================================

AlchemyTransmuteSpellIDs = {
    -- TBC: elemental cross-transmutes (Group A)
    [28566] = "Transmute: Primal Air to Fire",
    [28567] = "Transmute: Primal Earth to Water",
    [28568] = "Transmute: Primal Fire to Earth",
    [28569] = "Transmute: Primal Water to Air",
    -- TBC: Primal Might (Group B)
    [29688] = "Transmute: Primal Might",
    -- TBC: meta gem transmutes (Group C)
    [32765] = "Transmute: Earthstorm Diamond",
    [32766] = "Transmute: Skyfire Diamond",
    -- Classic: metal bars (each has its own 2-day cooldown)
    [11479] = "Transmute: Iron to Gold",
    [11480] = "Transmute: Mithril to Truesilver",
    [17187] = "Transmute: Arcanite",
    -- Classic: elemental cross-transmutes (each has its own 2-day cooldown)
    [17559] = "Transmute: Air to Fire",
    [17560] = "Transmute: Fire to Earth",
    [17561] = "Transmute: Earth to Water",
    [17562] = "Transmute: Water to Air",
    [17563] = "Transmute: Undeath to Water",
    [17564] = "Transmute: Water to Undeath",
    [17566] = "Transmute: Earth to Life",
    [17594] = "Transmute: Life to Earth",
}
