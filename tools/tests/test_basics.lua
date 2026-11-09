dofile(arg[1] .. "/test_wow_stub.lua")

wipe = function(t) for k in pairs(t) do t[k] = nil end return t end

local addonDir = arg[2]
local function load(file, name)
  local chunk = assert(loadfile(addonDir .. "/" .. file))
  chunk(name)
end

local passed, failed = 0, 0
local function check(label, cond, extra)
  if cond then
    passed = passed + 1
    print(string.format("  ok   %s", label))
  else
    failed = failed + 1
    print(string.format("  FAIL %s %s", label, extra and ("-> " .. tostring(extra)) or ""))
  end
end

load("Locale.lua", "NextMob")
load("Core.lua", "NextMob")
load("QuestieDB.lua", "NextMob")
load("Button.lua", "NextMob")

local NM = _G.NextMob

FAKE_QUESTS = {
  { id = 101, title = "Kobold Camp Cleanup", watched = true, objectives = {
      { text = "Kobold Vermin slain: 3/8", type = "monster" } } },
  { id = 102, title = "Red Linen Goods", objectives = {
      { text = "Bolt of Linen Cloth: 0/10", type = "item" } } },
  { id = 103, title = "Already Done", complete = true, objectives = {
      { text = "Hogger slain: 1/1", type = "monster", finished = true } } },
  { id = 104, title = "Westfall Trouble", objectives = {
      { text = "Defias bandits slain: 0/12", type = "monster" },
      { text = "Riverpaw Gnoll slain: 6/6", type = "monster", finished = true } } },
}

FIRE("ADDON_LOADED", "NextMob")
check("db initialised", type(NextMobDB) == "table" and type(NM.cfg) == "table")
check("secure button created", _G.NextMobButton ~= nil)
check("combat log used on a client that allows it", NM.hasCombatLog == true, NM.combatLogNote)

FIRE("PLAYER_LOGIN")

print("\n-- scan: names found --")
local byName = {}
for _, c in ipairs(NM.candidates) do byName[c.name] = c; print(string.format("   %-22s %-10s nearby=%s", c.name, c.source, tostring(c.nearby))) end

check("kill objective name parsed", byName["Kobold Vermin"] ~= nil)
check("item objective name ignored", byName["Bolt of Linen Cloth"] == nil)
check("completed quest ignored", byName["Hogger"] == nil)
check("finished objective ignored", byName["Riverpaw Gnoll"] == nil)
check("plural objective name kept", byName["Defias bandits"] ~= nil)
check("singular variant added for /target prefix match", byName["Defias bandit"] ~= nil)

print("\n-- macro body --")
local body = ARMED_BODY()
print(body)
check("body starts with conditional cleartarget", body:match("^/cleartarget %[dead%]%[help%]"))
check("body targets the kobold", body:find("/target [noexists] Kobold Vermin", 1, true))
check("every line is a target line", (function()
  for line in body:gmatch("[^\n]+") do
    if not line:match("^/cleartarget") and not line:match("^/target %[noexists%] ") then return false end
  end
  return true
end)())
check("watched quest outranks unwatched", (function()
  local kobold = body:find("Kobold Vermin", 1, true)
  local defias = body:find("Defias bandit", 1, true)
  return kobold and defias and kobold < defias
end)())

print("\n-- nameplate gives the exact in-game spelling --")
_G.FAKE_UNITS = { nameplate1 = "Defias Bandit" }
FIRE("NAME_PLATE_UNIT_ADDED", "nameplate1")
local nearbyEntry
for _, c in ipairs(NM.candidates) do if c.name == "Defias Bandit" then nearbyEntry = c end end
check("nameplate name matched to plural objective", nearbyEntry ~= nil)
check("nameplate name flagged nearby", nearbyEntry and nearbyEntry.nearby == true)
check("nearby candidate sorted first", NM.candidates[1] and NM.candidates[1].name == "Defias Bandit",
  NM.candidates[1] and NM.candidates[1].name)

print("\n-- learning: credit a kill the objective text does not name --")
FAKE_QUESTS[4].objectives[1].text = "Defias bandits slain: 0/12"
FIRE("QUEST_LOG_UPDATE")                                  -- snapshot 0/12
FAKE_COMBAT_EVENT = { 0, "SPELL_DAMAGE", false, "Player-1-AAAA", "Me", 0, 0, "Creature-0-1-1-1-448-00001", "Defias Smuggler" }
FIRE("COMBAT_LOG_EVENT_UNFILTERED")                        -- we hit it
FAKE_COMBAT_EVENT = { 0, "UNIT_DIED", false, nil, nil, 0, 0, "Creature-0-1-1-1-448-00001", "Defias Smuggler" }
FIRE("COMBAT_LOG_EVENT_UNFILTERED")                        -- it died
FAKE_QUESTS[4].objectives[1].text = "Defias bandits slain: 1/12"
FIRE("QUEST_LOG_UPDATE")                                   -- credit arrives
check("npc learned for the objective", NextMobDB.npcs["104:1"] and NextMobDB.npcs["104:1"]["Defias Smuggler"] == 1,
  NextMobDB.npcs["104:1"] and next(NextMobDB.npcs["104:1"]))
local learnedEntry
for _, c in ipairs(NM.candidates) do if c.name == "Defias Smuggler" then learnedEntry = c end end
check("learned npc now in candidate list", learnedEntry ~= nil)
check("learned npc marked as learned", learnedEntry and learnedEntry.source == "learned")

print("\n-- undamaged corpses are not learned --")
NextMobDB.npcs = {}
NM.kills = {}
FAKE_QUESTS[1].objectives[1].text = "Kobold Vermin slain: 3/8"
FIRE("QUEST_LOG_UPDATE")
FAKE_COMBAT_EVENT = { 0, "UNIT_DIED", false, nil, nil, 0, 0, "Creature-0-1-1-1-999-00002", "Random Critter" }
FIRE("COMBAT_LOG_EVENT_UNFILTERED")
FAKE_QUESTS[1].objectives[1].text = "Kobold Vermin slain: 4/8"
FIRE("QUEST_LOG_UPDATE")
check("kill we never damaged is not learned", NextMobDB.npcs["101:1"] == nil,
  NextMobDB.npcs["101:1"] and next(NextMobDB.npcs["101:1"]))

print("\n-- click rotation reaches the next candidate --")
local firstName = NM.candidates[1].name
local secondName = NM.candidates[2].name
_G.NextMobButton._hook_PostClick()
local rotated = ARMED_BODY()
local firstTargetLine = rotated:match("/target %[noexists%] ([^\n]+)")
check("rotation moves to the next name on reclick", firstTargetLine == secondName,
  tostring(firstName) .. " -> " .. tostring(firstTargetLine) .. " (expected " .. tostring(secondName) .. ")")

print("\n-- macro body never exceeds the 255 char macro limit --")
local long = NM:BuildBody(255)
check("255-char budget respected", #long <= 255, #long)

print("\n-- empty quest log --")
FAKE_QUESTS = {}
NM.plates = {}
NM.seen = {}
FIRE("QUEST_LOG_UPDATE")
check("no candidates, body still valid", NM.candidates and #NM.candidates == 0
  and ARMED_BODY() == "/cleartarget [dead][help]")

print("\n-- localized objective format (deDE-style) --")
check("format-to-pattern handles other locales", (function()
  QUEST_MONSTERS_KILLED = "%s getotet: %d/%d"
  local chunk = assert(loadfile(addonDir .. "/Core.lua"))
  chunk("NextMob")
  local QT2 = _G.NextMob
  FAKE_QUESTS = { { id = 201, title = "Test", objectives = {
    { text = "Schwarzfels-Grunzer getotet: 0/5", type = "monster" } } } }
  QT2:InitDB()
  QT2:ScanQuests()
  for _, c in ipairs(QT2.candidates) do
    if c.name == "Schwarzfels-Grunzer" then return true end
  end
  return false, QT2.candidates[1] and QT2.candidates[1].name
end)())

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
