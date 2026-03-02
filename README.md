# Alchemy-Tracker
TBC alchemy tracker for wow procs

---
1. Verify it loads without errors

Install the addon folder into your WoW directory, log in, and check the chat window on login. The addon prints:
[Alchemy Tracker] Loaded. Type /apt for help.
If it errors instead, the Lua error message will tell you exactly which line is broken.

Also run:
/apt show
The stats window should appear. If it does, the UI and saved variables are working.

---
2. Verify item IDs are correct without crafting

In-game chat, type:
/run print(GetItemInfo(22851))
If it returns "Flask of Fortification" you know that item ID is correct. You can spot-check any suspicious ID this
way.

To check a whole group at once, paste this into the chat box:
/run for id, name in pairs(AlchemyTrackerItemData["TBC"]["FLASK"]) do local n = GetItemInfo(id); if n ~= name then
print("MISMATCH", id, name, "->", tostring(n)) end end
Any line where the stored name doesn't match what the game returns is a wrong ID.

---
3. Simulate a craft event

The addon listens to CHAT_MSG_SKILL. You can fire a fake one directly in-game:

/run local f = _G["AlchemyProcTrackerEventFrame"] -- won't work since it's local

Since the event frame is local, the easier approach is to craft something cheap that's in the list — like Elixir of
Fortitude (Classic) or any low-reagent TBC elixir — and watch for:
- A proc message in chat if you get extra items
- The stats updating in /apt show

---
4. Confirm specialization detection

/run print(IsPlayerSpell(28677))  -- Elixir Master
/run print(IsPlayerSpell(28675))  -- Potion Master
/run print(IsPlayerSpell(28672))  -- Transmute Master
Should print true for whichever mastery your character has.

---
5. Check the event channel

The addon uses CHAT_MSG_SKILL — if you craft something and no proc tracking happens, the "You create" message might be
coming through CHAT_MSG_SYSTEM instead. You can check by temporarily adding this before logging in:

-- Add temporarily to AlchemyProcTracker.lua for debugging
eventFrame:RegisterEvent("CHAT_MSG_SYSTEM")
Then swap CHAT_MSG_SKILL → CHAT_MSG_SYSTEM in the OnEvent handler if that's where the messages appear.

---
The most reliable full test is: craft 5–10 of a cheap elixir with Elixir Master, then /apt show and verify Total
Crafts incremented and Total Items Produced matches what you actually received.