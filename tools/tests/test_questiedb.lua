-- Profile 4: the optional QuestieDB adapter.
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

FIRE("ADDON_LOADED", "NextMob")
FAKE_QUESTS = {
  { id = 501, title = "Murloc Poachers", watched = true, objectives = {
      { text = "Murloc Fin: 0/10", type = "item" } } },
}

print("-- with QuestieDB absent, nothing breaks --")
FIRE("PLAYER_LOGIN")
check("adapter reports not installed", NM.db:IsAvailable() == false)
check("describe() says so", NM.db:Describe():find("not installed", 1, true) ~= nil, NM.db:Describe())
check("scan still runs", type(NM.candidates) == "table")

-- ---------------------------------------------------------------- stub it in
local objectivesCalls = 0
local NPC_NAMES = {
  [1234] = "Murloc Oracle",
  [4321] = "Murloc Tidehunter",
  [9001] = "Murloc Netter",
  [72]   = "Should Not Appear",   -- a faction id that is also a valid npc id
}
local OBJECTIVES = {
  [1] = { { 1234, "Murloc Oracle" }, 10 },   -- creature objectives + a count
  [3] = { { 5678, "Murloc Fin" } },          -- item objectives
  [4] = { 72, 3000 },                        -- reputation pair: must be ignored
  [5] = { { { 4321 } }, 1234, "killcredit" },
}
local DROPS = {
  [5678] = { { 9001, 35 }, { 9002, 20 } },   -- 9002 has no name; 35/20 are chances
}

local function installQuestieDB(opts)
  opts = opts or {}
  _G.QuestDB = { Get = function(id, key)
    if opts.throw then error("QuestieDB exploded") end
    if key == "objectives" and id == 501 then
      objectivesCalls = objectivesCalls + 1
      return OBJECTIVES
    end
  end }
  _G.NpcDB = { Get = function(id, key)
    if key == "name" then return NPC_NAMES[id] end
  end }
  _G.LibQuestieDB = {
    version = "1.2.3",
    RequireContract = function() if opts.oldContract then return false, "contract too old" end return true end,
    Support = { Get = function(name) if name == "DropDB" then return DROPS end end },
  }
  NM.db:Reset()
end

print("\n-- an outdated contract is refused --")
installQuestieDB({ oldContract = true })
check("contract gate blocks use", NM.db:IsAvailable() == false)
check("reason recorded", tostring(NM.db:Note()):find("too old", 1, true) ~= nil, NM.db:Note())

print("\n-- installed and healthy --")
installQuestieDB()
check("adapter detected", NM.db:IsAvailable() == true)
check("describe() reports version", NM.db:Describe():find("1.2.3", 1, true) ~= nil, NM.db:Describe())

local known = NM.db:NamesForQuest(501)
local byName = {}
for _, k in ipairs(known or {}) do byName[k.name] = k end
print("     resolved: " .. (function()
  local t = {} ; for _, k in ipairs(known or {}) do t[#t+1] = k.name .. "/" .. k.why end
  return table.concat(t, ", ")
end)())

check("creature objective resolved", byName["Murloc Oracle"] and byName["Murloc Oracle"].why == "kill")
check("killCredit group resolved", byName["Murloc Tidehunter"] ~= nil)
check("drop source resolved from the item", byName["Murloc Netter"] and byName["Murloc Netter"].why == "drop",
  byName["Murloc Netter"] and byName["Murloc Netter"].why)
check("reputation faction id never becomes an npc", byName["Should Not Appear"] == nil)
check("unresolvable ids discarded", #known == 3, #known)
check("kill sources sort before drop sources", known[1].why == "kill" and known[#known].why == "drop")

print("\n-- results are cached per quest --")
local before = objectivesCalls
NM.db:NamesForQuest(501); NM.db:NamesForQuest(501)
check("no repeat lookups", objectivesCalls == before, objectivesCalls - before)

print("\n-- names reach the macro, outranking the text heuristics --")
FIRE("QUEST_LOG_UPDATE")
local top = named("Murloc Oracle")
check("QuestieDB name is a candidate", top ~= nil)
check("tagged as questiedb", top and top.source == "questiedb", top and top.source)
check("drop source tagged separately", named("Murloc Netter") and named("Murloc Netter").source == "questiedb-drop",
  named("Murloc Netter") and named("Murloc Netter").source)
local body = ARMED_BODY()
print("     body: " .. body:gsub("\n", " | "))
check("first target line is a QuestieDB name",
  body:match("/target %[noexists%] ([^\n]+)") == "Murloc Oracle",
  body:match("/target %[noexists%] ([^\n]+)"))
check("still within 255 chars", #body <= 255, #body)

print("\n-- a throwing QuestieDB degrades instead of erroring --")
installQuestieDB({ throw = true })
local ok, err = pcall(function()
  FIRE("QUEST_LOG_UPDATE")
  NM:ScanQuests()
end)
check("no error escapes the adapter", ok, err)
check("falls back to heuristics", named("Murloc Oracle") == nil)

print("\n-- partially installed QuestieDB is treated as absent --")
_G.QuestDB = { Get = function() end }
_G.NpcDB = nil
NM.db:Reset()
check("missing NpcDB means unavailable", NM.db:IsAvailable() == false)
local ok2, err2 = pcall(function() NM:ScanQuests() end)
check("scan unaffected", ok2, err2)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
