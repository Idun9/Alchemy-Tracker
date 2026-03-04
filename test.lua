-- test.lua  –  Offline test harness for Alchemy-Tracker
--
-- Requirements: Lua 5.1+ or LuaJIT (no external dependencies)
--   Windows:  https://luabinaries.sourceforge.net/  (grab lua54_Win64_bin.zip)
--   Or via:   winget install DEVCOM.Lua
--
-- Run from the addon directory:
--   cd d:\Gitclone\Alchemy-Tracker
--   lua test.lua

-- ============================================================
-- Simulated game clock
-- ============================================================

local _time = 10000.0
GetTime = function() return _time end

local function advance_time(n) _time = _time + n end

-- ============================================================
-- Minimal WoW API stubs
-- ============================================================

UnitName           = function(unit) return unit == "player" and "Testadin" or "Unknown" end
GetRealmName       = function() return "Faerlina" end
IsPlayerSpell      = function() return false end   -- overridden per-test where needed
GetAddOnMetadata   = function(_, field) if field == "Version" then return "1.0.0" end end
GetCursorPosition  = function() return 0, 0 end

-- GameTooltip stub (used by the minimap button; not directly tested here)
GameTooltip = {}
function GameTooltip:SetOwner() end
function GameTooltip:AddLine()  end
function GameTooltip:Show()     end
function GameTooltip:Hide()     end

-- Minimap stub (parent for the minimap button frame)
Minimap = { GetCenter = function() return 0, 0 end }

local function new_fontstring()
    local fs = {}
    function fs:SetPoint() end
    function fs:SetWidth() end
    function fs:SetJustifyH() end
    function fs:SetText(t) self._text = t end
    function fs:SetTextColor() end
    function fs:GetText() return self._text or "" end
    return fs
end

-- _event_frame is captured the first time RegisterEvent("ADDON_LOADED") is called.
-- That is the addon's main event dispatcher.
local _event_frame

local function new_texture()
    local t = {}
    function t:SetSize() end  function t:SetPoint() end
    function t:SetTexture() end
    return t
end

local function new_frame()
    local f = { _scripts = {}, _shown = false }
    function f:SetSize() end           function f:SetPoint() end
    function f:SetFrameStrata() end    function f:SetFrameLevel() end
    function f:SetMovable() end        function f:EnableMouse() end
    function f:RegisterForDrag() end   function f:SetClampedToScreen() end
    function f:SetBackdrop() end       function f:SetBackdropColor() end
    function f:SetHighlightTexture() end
    function f:GetEffectiveScale() return 1 end
    function f:Hide()    self._shown = false end
    function f:Show()    self._shown = true  end
    function f:IsShown() return self._shown  end
    function f:StartMoving() end  function f:StopMovingOrSizing() end
    function f:SetScript(ev, fn) self._scripts[ev] = fn end
    function f:CreateFontString() return new_fontstring() end
    function f:CreateTexture()    return new_texture()    end
    function f:RegisterEvent(ev)
        if ev == "ADDON_LOADED" and not _event_frame then
            _event_frame = self
        end
    end
    -- Helper used by this test file to dispatch events into the addon.
    function f:Fire(ev, ...)
        if self._scripts["OnEvent"] then
            self._scripts["OnEvent"](self, ev, ...)
        end
    end
    return f
end

UIParent     = new_frame()
SlashCmdList = {}
CreateFrame  = function() return new_frame() end

-- ============================================================
-- Load addon (order must match the .toc)
-- ============================================================

dofile("AlchemyTrackerItems.lua")

-- AlchemyProcTracker.lua starts with  `local ADDON_NAME, ns = ...`
-- Pass "AlchemyTracker" as a vararg so ADDON_NAME resolves correctly.
local chunk = assert(loadfile("AlchemyProcTracker.lua"))
chunk("AlchemyTracker")

assert(_event_frame,
    "FATAL: _event_frame not captured. "
    .. "RegisterEvent('ADDON_LOADED') was never called — check CreateFrame mock.")

-- Fire ADDON_LOADED to trigger BuildTrackedItemLookup / InitCharacterDB / CreateUI.
_event_frame:Fire("ADDON_LOADED", "AlchemyTracker")

-- ============================================================
-- Test runner
-- ============================================================

local _pass, _fail = 0, 0

local function ok(desc, cond, got, exp)
    if cond then
        _pass = _pass + 1
        io.write(string.format("  PASS  %s\n", desc))
    else
        _fail = _fail + 1
        io.write(string.format("  FAIL  %s\n", desc))
        if got ~= nil then
            io.write(string.format(
                "        got=%s  expected=%s\n", tostring(got), tostring(exp)))
        end
    end
end

local function section(name)
    io.write(string.format("\n--- %s ---\n", name))
end

-- ============================================================
-- Helpers
-- ============================================================

local function get_db()
    local key = GetRealmName() .. "-" .. UnitName("player")
    return AlchemyProcTrackerDB.characters[key]
end

local function stats(group, scope)
    return get_db().stats[group][scope]
end

-- Dispatch a CHAT_MSG_SKILL event (the channel craft messages arrive on).
local function craft(msg)
    _event_frame:Fire("CHAT_MSG_SKILL", msg)
end

-- WoW item hyperlinks for one known item from each group (TBC data).
local L = {
    ELIXIR    = "|cffffffff|Hitem:22831:0:0:0:0:0:0:0|h[Elixir of Major Agility]|h|r",
    FLASK     = "|cffffffff|Hitem:22851:0:0:0:0:0:0:0|h[Flask of Fortification]|h|r",
    POTION    = "|cffffffff|Hitem:22829:0:0:0:0:0:0:0|h[Super Healing Potion]|h|r",
    TRANSMUTE = "|cffffffff|Hitem:21884:0:0:0:0:0:0:0|h[Primal Fire]|h|r",
    UNKNOWN   = "|cffffffff|Hitem:99999:0:0:0:0:0:0:0|h[Unknown Potion]|h|r",
}

-- Finalize whatever craft is currently pending by starting a TRANSMUTE craft
-- on a new timestamp (different item + different second always triggers FinalizeCraft).
local function flush()
    advance_time(2)
    craft("You create: " .. L.TRANSMUTE .. ".")
end

-- Flush the pending craft, then zero all session stats for a clean slate.
-- After this call there is always a TRANSMUTE craft pending; it will be
-- finalized harmlessly by the first craft() call in the next test.
local function reset_session()
    flush()
    SlashCmdList["ALCHEMYPROCTRACKER"]("reset")
end

-- ============================================================
-- TESTS
-- ============================================================

section("DB initialisation")
do
    local cdb = get_db()
    ok("DB created",               AlchemyProcTrackerDB ~= nil)
    ok("characters table exists",  AlchemyProcTrackerDB.characters ~= nil)
    ok("character entry created",  cdb ~= nil)
    ok("specialization block",     cdb.specialization ~= nil)
    ok("default spec = None",
        cdb.specialization.current == "None", cdb.specialization.current, "None")
    for _, g in ipairs({"FLASK", "ELIXIR", "POTION", "TRANSMUTE"}) do
        ok(g .. " stats block present", cdb.stats[g] ~= nil)
    end
end

section("Specialization detection")
do
    -- Simulate having Elixir Master (spell ID 28677).
    IsPlayerSpell = function(id) return id == 28677 end
    _event_frame:Fire("PLAYER_LOGIN")
    local sp = get_db().specialization
    ok("current = Elixir",    sp.current == "Elixir",  sp.current,   "Elixir")
    ok("isElixir = true",     sp.isElixir  == true)
    ok("isPotion = false",    sp.isPotion  == false)
    ok("isTransmute = false", sp.isTransmute == false)

    -- Remove spec and confirm it clears.
    IsPlayerSpell = function() return false end
    _event_frame:Fire("PLAYER_LOGIN")
    ok("spec clears to None",
        get_db().specialization.current == "None",
        get_db().specialization.current, "None")
end

section("Single craft — no proc  (single-item 'You create: <link>.' format)")
do
    reset_session()
    craft("You create: " .. L.ELIXIR .. ".")
    flush()    -- finalizes the elixir craft
    local s = stats("ELIXIR", "session")
    ok("totalCrafts = 1",            s.totalCrafts  == 1, s.totalCrafts,  1)
    ok("totalPotions = 1",           s.totalPotions == 1, s.totalPotions, 1)
    ok("totalExtra = 0",             s.totalExtra   == 0, s.totalExtra,   0)
    ok("currentNoProcStreak = 1",    s.currentNoProcStreak == 1, s.currentNoProcStreak, 1)
    ok("longestNoProcStreak = 1",    s.longestNoProcStreak == 1, s.longestNoProcStreak, 1)
    ok("procs1..4 all zero",
        s.procs1 == 0 and s.procs2 == 0 and s.procs3 == 0 and s.procs4 == 0)
end

section("Proc — Nx message format  ('You create 3x <link>.' = +2 extra)")
do
    reset_session()
    craft("You create 3x " .. L.ELIXIR .. ".")
    flush()
    local s = stats("ELIXIR", "session")
    ok("totalCrafts = 1",       s.totalCrafts  == 1, s.totalCrafts,  1)
    ok("totalPotions = 3",      s.totalPotions == 3, s.totalPotions, 3)
    ok("totalExtra = 2",        s.totalExtra   == 2, s.totalExtra,   2)
    ok("procs2 = 1",            s.procs2       == 1, s.procs2,       1)
    ok("currentStreak reset=0", s.currentNoProcStreak == 0, s.currentNoProcStreak, 0)
end

section("Same item + same second → messages merge into one craft")
do
    -- TBC sometimes sends multiple "You create" lines for a single craft in
    -- the same second. The addon should count them as one proc event.
    reset_session()
    craft("You create: " .. L.ELIXIR .. ".")  -- first line
    -- deliberately NO advance_time — same timestamp
    craft("You create: " .. L.ELIXIR .. ".")  -- second line (should merge)
    flush()
    local s = stats("ELIXIR", "session")
    ok("counted as ONE craft",     s.totalCrafts  == 1, s.totalCrafts,  1)
    ok("totalPotions = 2 (merged)", s.totalPotions == 2, s.totalPotions, 2)
    ok("totalExtra = 1 (proc!)",   s.totalExtra   == 1, s.totalExtra,   1)
    ok("procs1 = 1",               s.procs1       == 1, s.procs1,       1)
end

section("Same item + different second → two separate crafts")
do
    reset_session()
    craft("You create: " .. L.ELIXIR .. ".")
    advance_time(2)                             -- new second
    craft("You create: " .. L.ELIXIR .. ".")   -- different timestamp → finalize + new craft
    flush()
    local s = stats("ELIXIR", "session")
    ok("two separate crafts",  s.totalCrafts  == 2, s.totalCrafts,  2)
    ok("totalPotions = 2",     s.totalPotions == 2, s.totalPotions, 2)
    ok("totalExtra = 0",       s.totalExtra   == 0, s.totalExtra,   0)
end

section("No-proc streak and longest-streak tracking")
do
    -- craft 1: no proc, craft 2: no proc (streak = 2), craft 3: proc (streak resets)
    reset_session()
    craft("You create: " .. L.ELIXIR .. ".")
    advance_time(2)
    craft("You create: " .. L.ELIXIR .. ".")
    advance_time(2)
    craft("You create 3x " .. L.ELIXIR .. ".")   -- proc
    flush()
    local s = stats("ELIXIR", "session")
    ok("totalCrafts = 3",           s.totalCrafts         == 3, s.totalCrafts,         3)
    ok("longestNoProcStreak = 2",   s.longestNoProcStreak == 2, s.longestNoProcStreak, 2)
    ok("currentNoProcStreak = 0",   s.currentNoProcStreak == 0, s.currentNoProcStreak, 0)
    ok("procs2 = 1",                s.procs2              == 1, s.procs2,              1)
end

section("Crafts route to the correct group")
do
    reset_session()
    craft("You create: " .. L.ELIXIR .. ".")
    advance_time(2)
    craft("You create: " .. L.FLASK  .. ".")   -- finalizes elixir, starts flask
    flush()                                     -- finalizes flask
    ok("ELIXIR totalCrafts = 1",
        stats("ELIXIR","session").totalCrafts == 1,
        stats("ELIXIR","session").totalCrafts, 1)
    ok("FLASK totalCrafts = 1",
        stats("FLASK","session").totalCrafts  == 1,
        stats("FLASK","session").totalCrafts,  1)
    ok("POTION totalCrafts = 0",
        stats("POTION","session").totalCrafts == 0,
        stats("POTION","session").totalCrafts, 0)
end

section("Unknown item ID is silently ignored")
do
    reset_session()
    craft("You create: " .. L.UNKNOWN .. ".")
    flush()
    ok("ELIXIR totalCrafts = 0",
        stats("ELIXIR","session").totalCrafts == 0,
        stats("ELIXIR","session").totalCrafts, 0)
end

section("Non-craft skill messages are ignored")
do
    reset_session()
    craft("Your Alchemy skill has increased to 375.")
    craft("You have learned a new recipe.")
    flush()
    ok("ELIXIR totalCrafts = 0",
        stats("ELIXIR","session").totalCrafts == 0,
        stats("ELIXIR","session").totalCrafts, 0)
end

section("Session reset zeroes session but preserves overall")
do
    reset_session()
    craft("You create 2x " .. L.ELIXIR .. ".")
    flush()
    local overall_before = stats("ELIXIR","overall").totalCrafts

    SlashCmdList["ALCHEMYPROCTRACKER"]("reset")

    ok("session.totalCrafts = 0 after reset",
        stats("ELIXIR","session").totalCrafts  == 0,
        stats("ELIXIR","session").totalCrafts,  0)
    ok("session.totalPotions = 0 after reset",
        stats("ELIXIR","session").totalPotions == 0,
        stats("ELIXIR","session").totalPotions, 0)
    ok("overall.totalCrafts preserved (>= pre-reset)",
        stats("ELIXIR","overall").totalCrafts >= overall_before)
end

section("Percent gain calculation")
do
    -- 2 crafts: 1 item + 3 items = 4 total, 2 extra → 50.0 %
    reset_session()
    craft("You create: "  .. L.ELIXIR .. ".")
    advance_time(2)
    craft("You create 3x " .. L.ELIXIR .. ".")
    flush()
    local s   = stats("ELIXIR","session")
    local pct = (s.totalExtra / s.totalPotions) * 100
    ok("percent gain = 50.0%",
        math.abs(pct - 50.0) < 0.01,
        string.format("%.1f%%", pct), "50.0%")
end

-- ============================================================
-- Results
-- ============================================================

io.write(string.format("\n================================\n"))
io.write(string.format("  %d passed,  %d failed\n", _pass, _fail))
io.write(string.format("================================\n"))

if _fail > 0 then os.exit(1) end
