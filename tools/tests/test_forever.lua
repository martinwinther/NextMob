-- Profile 2: a WoW Forever / Midnight-shaped client.
--   * registering COMBAT_LOG_EVENT_UNFILTERED raises an error
--   * unit APIs can hand back Secret values instead of strings
dofile(arg[1] .. "/test_wow_stub.lua")
FOREVER_MODE = true
C_RestrictedActions = {}   -- the signal that this client forbids combat log access

wipe = function(t) for k in pairs(t) do t[k] = nil end return t end

local addonDir = arg[2]
local function load(file) assert(loadfile(addonDir .. "/" .. file))("NextMob") end

local passed, failed = 0, 0
local function check(label, cond, extra)
  if cond then passed = passed + 1; print("  ok   " .. label)
  else failed = failed + 1; print("  FAIL " .. label .. (extra and (" -> " .. tostring(extra)) or "")) end
end

print("-- addon loads on a client where the combat log is forbidden --")
local ok, err = pcall(function()
  load("Locale.lua"); load("Core.lua"); load("QuestieDB.lua"); load("Button.lua")
end)
check("no error raised while loading", ok, err)

local NM = _G.NextMob
check("combat log detected as unavailable", NM.hasCombatLog == false)
check("and we never even asked for it, so nothing is blocked on login",
  tostring(NM.combatLogNote):find("not offered", 1, true) ~= nil, NM.combatLogNote)

FAKE_QUESTS = {
  { id = 301, title = "Bandit Trouble", watched = true, objectives = {
      { text = "Defias bandits slain: 0/12", type = "monster" } } },
}
FIRE("ADDON_LOADED", "NextMob")
FIRE("PLAYER_LOGIN")
check("still builds candidates", #NM.candidates > 0, #NM.candidates)

local body = ARMED_BODY()
check("macro body within the 255 char cap", #body <= 255, #body)
print("     body: " .. body:gsub("\n", " | "))

print("\n-- learning falls back to target history --")
FIRE("QUEST_LOG_UPDATE")                        -- snapshot 0/12
_G.FAKE_UNITS = { target = "Defias Smuggler" }
FIRE("PLAYER_TARGET_CHANGED")                   -- we pick a mob to fight
check("engaged history recorded", NM.engaged[1] and NM.engaged[1].name == "Defias Smuggler",
  NM.engaged[1] and NM.engaged[1].name)
ADVANCE_CLOCK(8)                                -- fight it for 8 seconds
FAKE_QUESTS[1].objectives[1].text = "Defias bandits slain: 1/12"
FIRE("QUEST_LOG_UPDATE")                        -- credit arrives
check("npc learned without any combat log",
  NextMobDB.npcs["301:1"] and NextMobDB.npcs["301:1"]["Defias Smuggler"] == 1,
  NextMobDB.npcs["301:1"] and next(NextMobDB.npcs["301:1"]))

local learned
for _, c in ipairs(NM.candidates) do if c.name == "Defias Smuggler" then learned = c end end
check("learned npc promoted into the list", learned and learned.source == "learned")

print("\n-- stale target history is not credited --")
NextMobDB.npcs = {}
NM.engaged = {}
_G.FAKE_UNITS = { target = "Innocent Bystander Mob" }
FIRE("PLAYER_TARGET_CHANGED")
ADVANCE_CLOCK(60)                               -- well past ENGAGE_WINDOW
FAKE_QUESTS[1].objectives[1].text = "Defias bandits slain: 2/12"
FIRE("QUEST_LOG_UPDATE")
check("target from a minute ago is ignored", NextMobDB.npcs["301:1"] == nil,
  NextMobDB.npcs["301:1"] and next(NextMobDB.npcs["301:1"]))

print("\n-- Secret values from unit APIs do not crash or get stored --")
NM.engaged = {}
_G.FAKE_UNITS = { nameplate9 = MAKE_SECRET(), target = MAKE_SECRET() }
local ok2, err2 = pcall(function()
  FIRE("NAME_PLATE_UNIT_ADDED", "nameplate9")
  FIRE("PLAYER_TARGET_CHANGED")
  NM:ScanQuests()
  NM:PushMacro()
end)
check("secret unit name handled without error", ok2, err2)
check("secret name not added to nameplate cache", NM.plates["nameplate9"] == nil)
check("secret name not added to engaged history", #NM.engaged == 0, #NM.engaged)
local body2 = ARMED_BODY()
check("macro body still valid after secrets", type(body2) == "string" and body2:find("/cleartarget", 1, true) == 1)

print("\n-- a secret-poisoned saved database is survived --")
NextMobDB.npcs["301:1"] = { [1] = 3 }       -- non-string key, as if corrupted
local ok3, err3 = pcall(function() NM:ScanQuests() end)
check("non-string learned keys skipped", ok3, err3)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
