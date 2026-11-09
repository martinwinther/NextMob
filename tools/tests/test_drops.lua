-- Profile 3: drop / collect quests ("Murloc Fin: 0/10").
dofile(arg[1] .. "/test_wow_stub.lua")
FOREVER_MODE = true
C_RestrictedActions = {}   -- the signal that this client forbids combat log access   -- the harder client: no combat log at all

wipe = function(t) for k in pairs(t) do t[k] = nil end return t end

local addonDir = arg[2]
local function load(file) assert(loadfile(addonDir .. "/" .. file))("NextMob") end
load("Locale.lua"); load("Core.lua"); load("QuestieDB.lua"); load("Button.lua")
local NM = _G.NextMob

local passed, failed = 0, 0
local function check(label, cond, extra)
  if cond then passed = passed + 1; print("  ok   " .. label)
  else failed = failed + 1; print("  FAIL " .. label .. (extra and (" -> " .. tostring(extra)) or "")) end
end
local function named(n)
  for _, c in ipairs(NM.candidates) do if c.name == n then return c end end
end
local function reset()
  NM.plates, NM.seen, NM.engaged, NM.guids = {}, {}, {}, {}
  NM.plateIDs, NM.idNames, NM.wanted = {}, {}, {}
  NM.guidCount = 0
  NM.progress = {}
end

FIRE("ADDON_LOADED", "NextMob")
FAKE_QUESTS = {
  { id = 401, title = "Murloc Poachers", watched = true, objectives = {
      { text = "Murloc Fin: 0/10", type = "item" } } },
}
FIRE("PLAYER_LOGIN")

print("-- the item name is never offered as a target --")
check("'Murloc Fin' is not a target", named("Murloc Fin") == nil)
check("nothing to target with no murlocs around", #NM.candidates == 0, #NM.candidates)

print("\n-- a nearby mob sharing the item's name is guessed --")
_G.FAKE_UNITS = { nameplate1 = "Murloc Oracle" }
FIRE("NAME_PLATE_UNIT_ADDED", "nameplate1")
local guess = named("Murloc Oracle")
check("'Murloc Oracle' guessed from 'Murloc Fin'", guess ~= nil)
check("tagged as a drop guess", guess and guess.source == "drop-guess", guess and guess.source)
check("it is in the macro body",
  ARMED_BODY():find("Murloc Oracle", 1, true) ~= nil)

print("\n-- plural item names still match --")
reset()
FAKE_QUESTS[1].objectives[1].text = "Murloc Fins: 0/10"
_G.FAKE_UNITS = { nameplate1 = "Murloc Oracle" }
FIRE("NAME_PLATE_UNIT_ADDED", "nameplate1")
check("'Murloc Fins' still matches 'Murloc Oracle'", named("Murloc Oracle") ~= nil)

print("\n-- unrelated items guess nothing --")
reset()
FAKE_QUESTS[1].objectives[1].text = "Bolt of Linen Cloth: 0/10"
_G.FAKE_UNITS = { nameplate1 = "Murloc Oracle" }
FIRE("NAME_PLATE_UNIT_ADDED", "nameplate1")
check("no guess for 'Bolt of Linen Cloth'", named("Murloc Oracle") == nil,
  NM.candidates[1] and NM.candidates[1].name)
check("stopwords alone never link", #NM.candidates == 0, #NM.candidates)

print("\n-- partial words do not count --")
reset()
FAKE_QUESTS[1].objectives[1].text = "Ring of Shadow: 0/1"
_G.FAKE_UNITS = { nameplate1 = "Shadowmage Acolyte" }
FIRE("NAME_PLATE_UNIT_ADDED", "nameplate1")
check("'Shadow' does not match 'Shadowmage'", named("Shadowmage Acolyte") == nil,
  NM.candidates[1] and NM.candidates[1].name)

print("\n-- loot credits the corpse, not whatever you targeted next --")
reset()
NextMobDB.npcs = {}
FAKE_QUESTS[1].objectives[1].text = "Murloc Fin: 0/10"
_G.FAKE_UNITS = { target = "Murloc Tidehunter" }
_G.FAKE_GUIDS = { target = "Creature-0-1-1-1-123-0001" }
FIRE("PLAYER_TARGET_CHANGED")                 -- fight it, caching guid -> name
FIRE("QUEST_LOG_UPDATE")                      -- snapshot 0/10
ADVANCE_CLOCK(40)                             -- long fight: past ENGAGE_WINDOW
FAKE_LOOT = { n = 1, sources = { "Creature-0-1-1-1-123-0001" } }
_G.FAKE_UNITS = { target = "Some Other Murloc" }  -- we already tabbed away
FIRE("LOOT_OPENED")                           -- loot the corpse
FAKE_QUESTS[1].objectives[1].text = "Murloc Fin: 1/10"
FIRE("QUEST_LOG_UPDATE")                      -- the fin drops
check("loot source learned despite the stale engage window",
  NextMobDB.npcs["401:1"] and NextMobDB.npcs["401:1"]["Murloc Tidehunter"] == 1,
  NextMobDB.npcs["401:1"] and next(NextMobDB.npcs["401:1"]))
check("the mob we tabbed to was not credited",
  NextMobDB.npcs["401:1"] and NextMobDB.npcs["401:1"]["Some Other Murloc"] == nil)
-- Learning records the creature id from the loot source's GUID as well as the
-- name, so this comes back id-verified rather than merely "learned".
local learned = named("Murloc Tidehunter")
check("learned drop source becomes a target",
  learned and (learned.source == "id-match" or learned.source == "learned"),
  learned and learned.source)
check("creature id captured from the loot source",
  NextMobDB.ids["401:1"] and NextMobDB.ids["401:1"][123] == 1,
  NextMobDB.ids["401:1"] and next(NextMobDB.ids["401:1"]))

print("\n-- fallback: unknown loot guid uses the looted unit --")
reset()
NextMobDB.npcs = {}
FAKE_QUESTS[1].objectives[1].text = "Murloc Fin: 1/10"
FIRE("QUEST_LOG_UPDATE")
FAKE_LOOT = { n = 1, sources = { "Creature-0-1-1-1-999-9999" } }  -- never cached
_G.FAKE_UNITS = { target = "Murloc Netter" }
_G.FAKE_GUIDS = { target = "Creature-0-1-1-1-999-9999" }
FIRE("LOOT_OPENED")
FAKE_QUESTS[1].objectives[1].text = "Murloc Fin: 2/10"
FIRE("QUEST_LOG_UPDATE")
check("looted unit credited via fallback",
  NextMobDB.npcs["401:1"] and NextMobDB.npcs["401:1"]["Murloc Netter"] == 1,
  NextMobDB.npcs["401:1"] and next(NextMobDB.npcs["401:1"]))

print("\n-- a secret loot source does not crash --")
reset()
FAKE_LOOT = { n = 1, sources = { MAKE_SECRET() } }
_G.FAKE_UNITS = { target = MAKE_SECRET() }
local ok, err = pcall(function() FIRE("LOOT_OPENED") end)
check("secret loot source handled", ok, err)
check("nothing engaged from a secret", #NM.engaged == 0, #NM.engaged)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
