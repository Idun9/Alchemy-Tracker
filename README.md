# Alchemy Tracker

A TBC Classic addon that tracks alchemy mastery proc rates across crafting sessions.

## Features

- Tracks proc counts and rates for Elixir Master (flasks + elixirs), Potion Master, and Transmute Master
- Session history browser with per-item breakdown and filter support
- Overall stats banner showing aggregate proc rate across all sessions
- Session auto-save on inactivity timeout; rename sessions via right-click
- Minimap button with left-click toggle and right-click menu

## Installation

1. Copy the `AlchemyTracker` folder into `World of Warcraft/_classic_tbc_/Interface/AddOns/`
2. Log in and open the alchemy tradeskill window — specialization is detected automatically

## Commands

Type `/at` for the version and a pointer to the command list.
Type `/at commands` for the full list:

| Command | Description |
|---|---|
| `/at show` | Open the stats window |
| `/at hide` | Close the stats window |
| `/at history` | Open session history |
| `/at options` | Open settings |
| `/at reset` | Reset current session stats |
| `/at reset all` | Reset all stats including overall |
| `/at resetpos` | Reset window positions to default |
| `/at debug` | Toggle debug mode (logs raw chat events) |

## Specialization Support

Only one specialization is active at a time. The addon enforces this:

- **Elixir Master** — tracks flasks and elixirs
- **Potion Master** — tracks potions only
- **Transmute Master** — tracks transmutes only

Items crafted outside your specialization (e.g. a Transmute Master crafting a potion) are ignored since they can never proc.

## Verifying It Works

**Check specialization detection:**
```
/run print(IsPlayerSpell(28677))  -- Elixir Master
/run print(IsPlayerSpell(28675))  -- Potion Master
/run print(IsPlayerSpell(28672))  -- Transmute Master
```
Should print `true` for your character's mastery.

**Verify an item ID:**
```
/run print(GetItemInfo(22851))
```
Should return `Flask of Fortification`. Use this to spot-check any item ID in `AlchemyTrackerItems.lua`.

**Check a whole group at once:**
```
/run for id, name in pairs(AlchemyTrackerItemData["TBC"]["FLASK"]) do local n = GetItemInfo(id); if n ~= name then print("MISMATCH", id, name, "->", tostring(n)) end end
```
Any printed line indicates a wrong item ID.

**Full test:** Craft 5–10 of a cheap elixir with Elixir Master active, then open `/at show` and confirm Total Crafts incremented and the item count matches what you received.
