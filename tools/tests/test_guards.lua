-- Profile 7: corpse skipping, and attributing blocked actions.
dofile(arg[1] .. "/test_wow_stub.lua")
FOREVER_MODE = true
C_RestrictedActions = {}

local addonDir = arg[2]
local function load(file) assert(loadfile(addonDir .. "/" .. file))("NextMob") end
load("Locale.lua"); load("Core.lua"); load("QuestieDB.lua"); load("Button.lua")
local NM = _G.NextMob

local passed, failed = 0, 0
local function check(label, cond, extra)
  if cond then passed = passed + 1; print("  ok   " .. label)
  else failed = failed + 1; print("  FAIL " .. label .. (extra and (" -> " .. tostring(extra)) or "")) end
end

FIRE("ADDON_LOADED", "NextMob")
FAKE_QUESTS = {
  { id = 801, title = "Many Things", watched = true, objectives = {
      { text = "Murloc Oracle slain: 0/5", type = "monster" },
      { text = "Murloc Netter slain: 0/5", type = "monster" },
      { text = "Murloc Tidehunter slain: 0/5", type = "monster" },
      { text = "Murloc Forager slain: 0/5", type = "monster" },
      { text = "Murloc Minor Oracle slain: 0/5", type = "monster" },
      { text = "Murloc Coastrunner slain: 0/5", type = "monster" },
      { text = "Murloc Shorestriker slain: 0/5", type = "monster" },
      { text = "Murloc Nightcrawler slain: 0/5", type = "monster" } } },
}
FIRE("PLAYER_LOGIN")

print("-- corpses are dropped as soon as /target lands on one --")
check("skip dead is on by default", NM.cfg.skipDead == true)
local body = ARMED_BODY()
print(body:gsub("\n", "\n     "))
local targets, guards = 0, 0
for line in body:gmatch("[^\n]+") do
  if line:match("^/target ") then targets = targets + 1 end
  if line == "/cleartarget [dead]" then guards = guards + 1 end
end
check("every attempt is followed by a guard", targets > 0 and guards == targets,
  targets .. " targets / " .. guards .. " guards")
check("body ends with a guard, so a click never leaves a corpse",
  body:match("([^\n]+)$") == "/cleartarget [dead]", body:match("([^\n]+)$"))
check("opening line still clears dead and friendly targets",
  body:match("^([^\n]+)") == "/cleartarget [dead][help]")
check("within the 255 limit", #body <= 255, #body)

print("\n-- turning it off fits more names in --")
local withGuards = targets
SlashCmdList["NEXTMOB"]("dead")
check("toggled off", NM.cfg.skipDead == false)
local body2 = ARMED_BODY()
local targets2 = 0
for line in body2:gmatch("[^\n]+") do
  if line:match("^/target ") then targets2 = targets2 + 1 end
end
check("no guards present", body2:find("/cleartarget [dead]\n", 1, true) == nil
  and select(2, body2:gsub("/cleartarget", "")) == 1, body2)
check("more names fit without guards", targets2 > withGuards,
  withGuards .. " -> " .. targets2)
check("still within 255", #body2 <= 255, #body2)
SlashCmdList["NEXTMOB"]("dead")
check("toggled back on", NM.cfg.skipDead == true)

print("\n-- a truncated body never ends on an unguarded attempt --")
local long = {}
for i = 1, 12 do long[i] = { name = ("Very Long Mob Name Number %02d"):format(i) } end
NM.candidates = long
local tight = NM:BuildBody(255)
check("truncated body still ends with a guard",
  tight:match("([^\n]+)$") == "/cleartarget [dead]", tight:match("([^\n]+)$"))
local t3, g3 = 0, 0
for line in tight:gmatch("[^\n]+") do
  if line:match("^/target ") then t3 = t3 + 1 end
  if line == "/cleartarget [dead]" then g3 = g3 + 1 end
end
check("attempts and guards stay paired after truncation", t3 == g3, t3 .. "/" .. g3)
check("truncated body within 255", #tight <= 255, #tight)

print("\n-- blocked actions get attributed --")
check("nothing blocked yet", #NM.blocked == 0, #NM.blocked)
FIRE("ADDON_ACTION_FORBIDDEN", "SomeOtherAddon", "DoThing")
check("another addon's block is ignored", #NM.blocked == 0, #NM.blocked)
FIRE("ADDON_ACTION_FORBIDDEN", "NextMob", "RegisterEvent")
check("our own block is recorded", #NM.blocked == 1, #NM.blocked)
check("the refused function is captured",
  NM.blocked[1].what == "RegisterEvent", NM.blocked[1].what)
check("warned once only", NM.blockedWarned == true)
FIRE("ADDON_ACTION_BLOCKED", "NextMob", "TargetUnit")
check("further blocks accumulate", #NM.blocked == 2, #NM.blocked)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
