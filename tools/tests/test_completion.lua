-- Profile 6: objectives whose count is already filled must stop being targeted.
dofile(arg[1] .. "/test_wow_stub.lua")
FOREVER_MODE = true
C_RestrictedActions = {}   -- the signal that this client forbids combat log access
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
local function listing()
  local t = {}
  for _, c in ipairs(NM.candidates) do t[#t+1] = c.name .. "(" .. c.source .. ")" end
  return #t > 0 and table.concat(t, ", ") or "<empty>"
end

local NPCS = { [1234] = "Murloc Oracle", [9001] = "Murloc Netter", [4321] = "Mystery Mob" }
local DBOBJ = {}
_G.QuestDB = { Get = function(id, key) if key == "objectives" then return DBOBJ[id] end end }
_G.NpcDB = { Get = function(id, key) if key == "name" then return NPCS[id] end end }
_G.LibQuestieDB = { RequireContract = function() return true end }

FIRE("ADDON_LOADED", "NextMob")

print("-- a finished objective's mob is dropped, the unfinished one is kept --")
DBOBJ[701] = { [1] = { { 1234, "Murloc Oracle" }, { 9001, "Murloc Netter" } } }
FAKE_QUESTS = {
  { id = 701, title = "Two Jobs", watched = true, objectives = {
      { text = "Murloc Oracle slain: 5/5", type = "monster", finished = true },
      { text = "Murloc Netter slain: 0/7", type = "monster" } } },
}
FIRE("PLAYER_LOGIN")
print("     candidates: " .. listing())
check("completed objective's mob not offered", named("Murloc Oracle") == nil,
  named("Murloc Oracle") and named("Murloc Oracle").source)
check("unfinished objective's mob still offered", named("Murloc Netter") ~= nil)
check("its creature id is no longer tracked", NM.wanted[1234] == nil, NM.wanted[1234])
check("the live one's id is tracked", NM.wanted[9001] == "Two Jobs", NM.wanted[9001])
check("macro body excludes the finished mob",
  ARMED_BODY():find("Murloc Oracle", 1, true) == nil, ARMED_BODY())

print("\n-- a count reaching its max counts as finished, with no flag set --")
FAKE_QUESTS[1].objectives[1].finished = nil
FAKE_QUESTS[1].objectives[1].text = "Murloc Oracle slain: 5/5"
FIRE("QUEST_LOG_UPDATE")
check("8/8-style completion respected", named("Murloc Oracle") == nil,
  named("Murloc Oracle") and named("Murloc Oracle").source)

print("\n-- numFulfilled/numRequired is respected too --")
FAKE_QUESTS[1].objectives[1].text = "Murloc Oracle slain"
FAKE_QUESTS[1].objectives[1].numFulfilled = 5
FAKE_QUESTS[1].objectives[1].numRequired = 5
FIRE("QUEST_LOG_UPDATE")
check("structured counts respected", named("Murloc Oracle") == nil,
  named("Murloc Oracle") and named("Murloc Oracle").source)

print("\n-- an id-verified name cannot resurrect a finished objective --")
NM.idNames[1234] = "Murloc-Orakel"
NM:ScanQuests()
check("stale id-verified name stays out", named("Murloc-Orakel") == nil,
  named("Murloc-Orakel") and named("Murloc-Orakel").source)

print("\n-- a row QuestieDB gives no label for is kept, not thrown away --")
DBOBJ[701] = { [1] = { { 1234, "Murloc Oracle" } }, [5] = { 4321 } }
FAKE_QUESTS[1].objectives[1].numFulfilled, FAKE_QUESTS[1].objectives[1].numRequired = nil, nil
FAKE_QUESTS[1].objectives[1].text = "Murloc Oracle slain: 5/5"
NM.db:Reset()
FIRE("QUEST_LOG_UPDATE")
check("unlabelled row survives", named("Mystery Mob") ~= nil, listing())
check("labelled-and-finished row still dropped", named("Murloc Oracle") == nil)

print("\n-- every objective filled: the quest contributes nothing --")
DBOBJ[702] = { [1] = { { 1234, "Murloc Oracle" } } }
FAKE_QUESTS = {
  { id = 702, title = "All Done But Not Handed In", objectives = {
      { text = "Murloc Oracle slain: 5/5", type = "monster" },
      { text = "Murloc Netter slain: 7/7", type = "monster" } } },
}
NM.idNames, NM.plateIDs, NM.plates, NM.seen = {}, {}, {}, {}
NM.db:Reset()
FIRE("QUEST_LOG_UPDATE")
check("no candidates at all", #NM.candidates == 0, listing())
check("no ids tracked", next(NM.wanted) == nil)
check("body is just the cleartarget line",
  ARMED_BODY() == "/cleartarget [dead][help]", ARMED_BODY())

print("\n-- still wanted when another quest needs the same mob --")
DBOBJ[703] = { [1] = { { 1234, "Murloc Oracle" } } }
FAKE_QUESTS = {
  { id = 702, title = "Done", objectives = {
      { text = "Murloc Oracle slain: 5/5", type = "monster" } } },
  { id = 703, title = "Not Done", objectives = {
      { text = "Murloc Oracle slain: 0/3", type = "monster" } } },
}
NM.db:Reset()
FIRE("QUEST_LOG_UPDATE")
check("shared mob still offered for the live quest", named("Murloc Oracle") ~= nil, listing())
check("attributed to the unfinished quest", named("Murloc Oracle") and named("Murloc Oracle").quest == "Not Done",
  named("Murloc Oracle") and named("Murloc Oracle").quest)
check("its id is tracked again", NM.wanted[1234] == "Not Done", NM.wanted[1234])

print("\n-- learned names for a finished objective are not offered --")
NextMobDB.npcs["702:1"] = { ["Murloc Oracle"] = 5 }
NextMobDB.ids["702:1"] = { [1234] = 5 }
FAKE_QUESTS = {
  { id = 702, title = "Done", objectives = {
      { text = "Murloc Oracle slain: 5/5", type = "monster" } } },
}
DBOBJ[702] = nil
NM.db:Reset()
FIRE("QUEST_LOG_UPDATE")
check("learned name suppressed once the count is full", named("Murloc Oracle") == nil, listing())

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
