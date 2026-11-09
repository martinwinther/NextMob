-- Profile 5: creature-id matching and the opt-in unit mode.
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
local function guid(creatureID) return "Creature-0-3151-1-184-" .. creatureID .. "-000136DF9A" end
local function btn(attr) return _G.NextMobButton:GetAttribute(attr) end

-- QuestieDB says quest 601 wants creature 1234, which it calls "Murloc Oracle".
-- The live client is German, so the unit on screen is named differently: the
-- whole point of matching on the id instead of the text.
_G.QuestDB = { Get = function(id, key)
  if key == "objectives" and id == 601 then return { [1] = { { 1234, "x" } } } end
end }
_G.NpcDB = { Get = function(id, key) if key == "name" then
  return ({ [1234] = "Murloc Oracle" })[id] end end }
_G.LibQuestieDB = { RequireContract = function() return true end }

FIRE("ADDON_LOADED", "NextMob")
FAKE_QUESTS = {
  { id = 601, title = "Murloc Poachers", watched = true, objectives = {
      { text = "Murloc Fin: 0/10", type = "item" } } },
}
FIRE("PLAYER_LOGIN")

print("-- the wanted creature id is collected from QuestieDB --")
check("id 1234 tracked", NM.wanted[1234] == "Murloc Poachers", NM.wanted[1234])

print("\n-- a nameplate with that id yields its exact in-game name --")
_G.FAKE_UNITS = { nameplate3 = "Murloc-Orakel" }
_G.FAKE_GUIDS = { nameplate3 = guid(1234) }
FIRE("NAME_PLATE_UNIT_ADDED", "nameplate3")
check("creature id read off the nameplate", NM.plateIDs["nameplate3"] == 1234, NM.plateIDs["nameplate3"])
check("exact name harvested", NM.idNames[1234] == "Murloc-Orakel", NM.idNames[1234])
local verified = named("Murloc-Orakel")
check("name became a candidate", verified ~= nil)
check("tagged as id-match", verified and verified.source == "id-match", verified and verified.source)
check("id-verified name outranks the database name",
  NM.candidates[1].name == "Murloc-Orakel", NM.candidates[1] and NM.candidates[1].name)
check("first macro line is the verified name",
  ARMED_BODY():match("/target %[noexists%] ([^\n]+)") == "Murloc-Orakel",
  ARMED_BODY():match("/target %[noexists%] ([^\n]+)"))

print("\n-- an unrelated nameplate is not matched --")
_G.FAKE_UNITS.nameplate4 = "Harmless Critter"
_G.FAKE_GUIDS.nameplate4 = guid(777)
FIRE("NAME_PLATE_UNIT_ADDED", "nameplate4")
check("unwanted id recorded but not matched", NM.plateIDs["nameplate4"] == 777)
check("unwanted name is not an id-match",
  not named("Harmless Critter") or named("Harmless Critter").source ~= "id-match")

print("\n-- malformed and vehicle guids --")
_G.FAKE_UNITS.nameplate5 = "Odd One"
_G.FAKE_GUIDS.nameplate5 = "not-a-guid"
local ok, err = pcall(function() FIRE("NAME_PLATE_UNIT_ADDED", "nameplate5") end)
check("garbage guid does not crash", ok, err)
check("garbage guid yields no id", NM.plateIDs["nameplate5"] == nil)
_G.FAKE_UNITS.nameplate6 = "Siege Engine"
_G.FAKE_GUIDS.nameplate6 = "Vehicle-0-3151-1-184-1234-000136DF9B"
FIRE("NAME_PLATE_UNIT_ADDED", "nameplate6")
check("vehicle guid parsed too", NM.plateIDs["nameplate6"] == 1234, NM.plateIDs["nameplate6"])

print("\n-- by default the button drives a REAL saved macro --")
check("button is in macro mode", btn("type") == "macro", btn("type"))
check("it points at the saved macro by name", btn("macro") == "NextMob", btn("macro"))
check("inline macrotext is cleared, so which wins is never ambiguous",
  btn("macrotext") == nil, btn("macrotext"))
check("the saved macro exists", (NM.macroIndex or 0) > 0, NM.macroError)
check("and carries the verified name",
  (GetMacroBody(NM.macroIndex) or ""):find("Murloc-Orakel", 1, true) ~= nil)
check("no unit attribute in macro mode", btn("unit") == nil)

print("\n-- /nm unit turns on direct targeting --")
SlashCmdList["NEXTMOB"]("unit")
check("unit mode on", NM.cfg.clickMode == "unit", NM.cfg.clickMode)
check("button switched to target type", btn("type") == "target", btn("type"))
check("lowest matching nameplate chosen", btn("unit") == "nameplate3", btn("unit"))
check("saved macro still holds the name list for the flip back",
  (GetMacroBody(NM.macroIndex) or ""):find("Murloc-Orakel", 1, true) ~= nil,
  GetMacroBody(NM.macroIndex))

print("\n-- the matched mob dying falls back to macro mode --")
FIRE("NAME_PLATE_UNIT_REMOVED", "nameplate3")
check("plate id cleared", NM.plateIDs["nameplate3"] == nil)
check("falls back to the other match", btn("unit") == "nameplate6", btn("unit"))
FIRE("NAME_PLATE_UNIT_REMOVED", "nameplate6")
check("no matches left -> macro mode", btn("type") == "macro", btn("type"))
check("unit attribute cleared", btn("unit") == nil)
check("name list still carries the verified name",
  (ARMED_BODY() or ""):find("Murloc-Orakel", 1, true) ~= nil, ARMED_BODY())
check("macro attribute re-armed", btn("macro") == "NextMob", btn("macro"))

print("\n-- macrotext mode arms the inline body instead --")
SlashCmdList["NEXTMOB"]("mode macrotext")
check("inline body armed", type(btn("macrotext")) == "string", btn("macrotext"))
check("macro attribute cleared", btn("macro") == nil, btn("macro"))

print("\n-- if the macro list is full, it falls back to inline text --")
SlashCmdList["NEXTMOB"]("mode macro")
check("macro mode restored", btn("macro") == "NextMob", btn("macro"))
FAKE_MACROS = {}
MACRO_SLOTS_FULL = true
NM:PushMacro()
check("fell back to inline macrotext", type(btn("macrotext")) == "string", btn("macrotext"))
check("reported why", NM.macroError ~= nil, NM.macroError)
check("still targets something", (ARMED_BODY() or ""):find("/target", 1, true) ~= nil)
MACRO_SLOTS_FULL = false

print("\n-- ids are learned even with no quest database --")
_G.QuestDB, _G.NpcDB, _G.LibQuestieDB = nil, nil, nil
NM.db:Reset()
NextMobDB.npcs, NextMobDB.ids = {}, {}
NM.engaged, NM.idNames, NM.plateIDs, NM.plates = {}, {}, {}, {}
FAKE_QUESTS = { { id = 602, title = "Kill Things", objectives = {
  { text = "Things slain: 0/5", type = "monster" } } } }
FIRE("QUEST_LOG_UPDATE")
_G.FAKE_UNITS = { target = "Thing Doer" }
_G.FAKE_GUIDS = { target = guid(5150) }
FIRE("PLAYER_TARGET_CHANGED")
FAKE_QUESTS[1].objectives[1].text = "Things slain: 1/5"
FIRE("QUEST_LOG_UPDATE")
check("creature id stored alongside the name",
  NextMobDB.ids["602:1"] and NextMobDB.ids["602:1"][5150] == 1,
  NextMobDB.ids["602:1"] and next(NextMobDB.ids["602:1"]))
check("learned id is now tracked", NM.wanted[5150] == "Kill Things", NM.wanted[5150])
_G.FAKE_UNITS.nameplate1 = "Thing Doer"
_G.FAKE_GUIDS.nameplate1 = guid(5150)
FIRE("NAME_PLATE_UNIT_ADDED", "nameplate1")
check("learned id matches a nameplate without any database",
  named("Thing Doer") and named("Thing Doer").source == "id-match",
  named("Thing Doer") and named("Thing Doer").source)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
