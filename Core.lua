--[[-------------------------------------------------------------------------
  NextMob - Core.lua   (v1.1)

  Builds a /target macro for whatever your active quests want you to kill,
  and keeps it up to date as your quest log changes.

  Candidate sources, best first:
    1. Learned NPCs  - names we have seen give credit for this objective.
    2. Nearby units  - a nameplate/mouseover whose name matches the objective
                       text (gives us the exact in-game spelling).
    3. Objective text - "Kobold Vermin slain: 3/8" -> "Kobold Vermin".

  Client notes (WoW Forever 1.60.1 / Midnight 12.x):
    * COMBAT_LOG_EVENT_UNFILTERED *errors* when an addon registers it, so
      every RegisterEvent goes through SafeRegister and the learning pass
      falls back to target/mouseover history.
    * Unit APIs may hand back Secret values instead of strings. Comparing or
      concatenating one raises a Lua error, and they cannot be written to
      SavedVariables, so every name is type-checked before use.
    * The "macrotext" attribute is limited to 255 characters.
---------------------------------------------------------------------------]]

local ADDON_NAME = ...

local NM = CreateFrame("Frame", "NextMobCore")
_G.NextMob = NM

-- runtime state ------------------------------------------------------------
NM.candidates  = {}   -- ordered list of { name, quest, source, nearby }
NM.plates      = {}   -- [unitToken] = name  (hostile nameplates on screen)
NM.seen        = {}   -- [name] = expiry     (nameplate/mouseover/target)
NM.progress    = {}   -- ["questID:objIndex"] = numFulfilled  (last snapshot)
NM.damaged     = {}   -- [guid] = time       (things we personally hit)
NM.kills       = {}   -- recent qualifying kills, newest first
NM.engaged     = {}   -- recent hostile target/mouseover names, newest first
NM.guids       = {}   -- [guid] = name, so loot sources can be named
NM.guidCount   = 0
NM.plateIDs    = {}   -- [unitToken] = creatureID of that nameplate
NM.idNames     = {}   -- [creatureID] = that creature's exact in-game name
NM.wanted      = {}   -- [creatureID] = quest title, rebuilt every scan
NM.rotation    = 0
NM.lastRotate  = 0
NM.clickCount  = 0
NM.blocked     = {}   -- actions this client refused us, for /nm test
NM.blockedWarned = false
NM.lastBody    = ""   -- the macro body most recently pushed
NM.lastClick   = 0
NM.activeUnit  = nil  -- set to a unit token only while unit mode is locked on
NM.macroIndex  = nil  -- slot of the saved macro, once it exists
NM.macroError  = nil
NM.combatLogNote = nil
NM.adoptedOldDB = false
NM.pendingScan = false
NM.pendingPush = false
NM.hasCombatLog = false

-- tunables -----------------------------------------------------------------
local MAX_NAMES     = 12    -- candidates to keep
local MACRO_LIMIT   = 255   -- hard limit of a real WoW macro
local BUTTON_LIMIT  = 255   -- "macrotext" is capped at 255 since 11.0.2
local KILL_WINDOW   = 5     -- s between a combat-log kill and quest credit
local ENGAGE_WINDOW = 25    -- s between targeting something and quest credit
local DAMAGE_MEMORY = 90    -- s we remember having hit a given GUID
local SEEN_MEMORY   = 45    -- s a name stays "nearby" after we last saw it
local MAX_LEARNED   = 6     -- names stored per objective
local MAX_GUIDS     = 300   -- size of the guid -> name cache

local DEFAULTS = {
  -- How a click actually targets. "macro" drives a real saved macro, which is
  -- the mechanism most likely to survive Midnight-era addon restrictions;
  -- "macrotext" uses the inline body (blocked on some clients); "unit" points
  -- straight at a matched nameplate.
  clickMode   = "macro",
  skipDead    = true,   -- drop a corpse the moment /target lands on one
  alwaysClear = false,  -- drop the current target on every click
  hidden      = false,
  locked      = false,
  debug       = false,
}

--[[ helpers ]]--------------------------------------------------------------

local function Print(...)
  print("|cff33ff99NextMob|r:", ...)
end

local function Debug(...)
  if NextMobDB and NextMobDB.config and NextMobDB.config.debug then
    Print("|cff888888debug|r", ...)
  end
end

-- Unit APIs can return Secret values in Midnight-era clients. Touching one
-- (compare, concatenate, store) raises a Lua error, so everything that comes
-- out of a Unit* call goes through here first.
local function SafeName(value)
  if type(value) ~= "string" then return nil end
  if value == "" then return nil end
  return value
end

local function Trim(s)
  return (s:gsub("^%s*(.-)%s*$", "%1"))
end

-- Turn a localized format string ("%s slain: %d/%d") into a Lua pattern.
local function FormatToPattern(fmt)
  local p = fmt:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
  p = p:gsub("%%%%s", "(.-)")
  p = p:gsub("%%%%d", "(%%d+)")
  return "^" .. p .. "$"
end

local MONSTER_PATTERN = FormatToPattern(SafeName(QUEST_MONSTERS_KILLED) or "%s slain: %d/%d")

local function StripCounter(text)
  local s = text:gsub("%s*%d+%s*/%s*%d+%s*", " ")
  s = s:gsub("%s*[:\239\188\154]%s*$", "")
  return Trim(s)
end

-- "Kobold Vermin slain: 3/8" -> "Kobold Vermin", 3, 8
local function ParseObjective(text)
  if type(text) ~= "string" or text == "" then return nil end
  local cur, max = text:match("(%d+)%s*/%s*(%d+)")
  local name = text:match(MONSTER_PATTERN)
  if not name or name == "" then
    name = StripCounter(text)
  end
  if name == "" then name = nil end
  return name, tonumber(cur), tonumber(max)
end

local function Normalize(s)
  s = s:lower():gsub("[^%w%s]", " "):gsub("%s+", " ")
  return Trim(s)
end

local function Singular(s)
  return (s:gsub("ies$", "y"):gsub("([^s])s$", "%1"))
end

-- Words that carry no identity, so they must never be the thing that links an
-- item to a mob. Without this, "Bolt of Linen Cloth" would match any mob with
-- "of" or "the" in its name.
local STOPWORDS = {
  ["the"] = true, ["and"] = true, ["for"] = true, ["from"] = true,
  ["with"] = true, ["your"] = true, ["some"] = true, ["that"] = true,
  ["this"] = true, ["their"] = true, ["into"] = true,
}

local function Tokens(s)
  local out = {}
  for word in Normalize(s):gmatch("%a+") do
    if #word >= 4 and not STOPWORDS[word] then
      out[#out + 1] = Singular(word)
    end
  end
  return out
end

-- Does an item name share an identifying word with a mob name?
--   "Murloc Fin"          + "Murloc Oracle"  -> "murloc"
--   "Bolt of Linen Cloth" + "Murloc Oracle"  -> nil
-- Whole tokens only: "Ring of Shadow" must not match "Shadowmage".
local function SharesWord(itemName, mobName)
  itemName, mobName = SafeName(itemName), SafeName(mobName)
  if not itemName or not mobName then return nil end
  local mobTokens = {}
  for _, word in ipairs(Tokens(mobName)) do mobTokens[word] = true end
  for _, word in ipairs(Tokens(itemName)) do
    if mobTokens[word] then return word end
  end
  return nil
end

-- Loose comparison so "Defias bandits" can match the mob "Defias Bandit".
local function Matches(a, b)
  a, b = SafeName(a), SafeName(b)
  if not a or not b then return false end
  a, b = Normalize(a), Normalize(b)
  if a == "" or b == "" then return false end
  if a == b then return true end
  local sa, sb = Singular(a), Singular(b)
  if sa == sb then return true end
  if #sa >= 5 and #sb >= 5 and (sa:find(sb, 1, true) or sb:find(sa, 1, true)) then
    return true
  end
  return false
end

-- One place that decides what an objective says and whether it is done, so
-- the scan and the QuestieDB filter can never disagree about it.
local function ObjectiveState(obj)
  if type(obj) ~= "table" then return nil, nil, nil, true end
  local text = SafeName(obj.text) or ""
  local name, cur, max = ParseObjective(text)
  local finished = obj.finished and true or false
  if not finished and type(obj.numFulfilled) == "number"
     and type(obj.numRequired) == "number" and obj.numRequired > 0 then
    finished = obj.numFulfilled >= obj.numRequired
  end
  if not finished and cur and max and max > 0 then
    finished = cur >= max
  end
  return name, cur, max, finished
end

-- Which live objective a QuestieDB row refers to, by comparing its label with
-- the objective text the game reports. Returns nil when nothing matches, in
-- which case the caller keeps the row rather than throwing data away.
local function MatchObjectiveIndex(objectives, label)
  if not SafeName(label) then return nil end
  for i, obj in ipairs(objectives) do
    local name = ObjectiveState(obj)
    if name and Matches(name, label) then return i end
  end
  return nil
end

--[[ saved variables ]]------------------------------------------------------

function NM:InitDB()
  -- The addon used to be called QuestTarget. Adopt that database if it is the
  -- only one present, so upgrading keeps every NPC and creature id it learned.
  -- The TOC still declares the old name, or the client would not load it.
  if NextMobDB == nil and type(QuestTargetDB) == "table" then
    NextMobDB = QuestTargetDB
    self.adoptedOldDB = true
  end

  NextMobDB = NextMobDB or {}
  NextMobDB.npcs   = NextMobDB.npcs or {}
  NextMobDB.ids    = NextMobDB.ids or {}
  NextMobDB.config = NextMobDB.config or {}
  NextMobDB.anchor = NextMobDB.anchor or {}
  for k, v in pairs(DEFAULTS) do
    if NextMobDB.config[k] == nil then NextMobDB.config[k] = v end
  end
  self.cfg = NextMobDB.config

  -- Migrate the old pair of booleans onto clickMode.
  if self.cfg.unitMode ~= nil then
    if self.cfg.unitMode == true then self.cfg.clickMode = "unit" end
    self.cfg.unitMode = nil
  end
  if self.cfg.macro ~= nil then self.cfg.macro = nil end
  local mode = self.cfg.clickMode
  if mode ~= "macro" and mode ~= "macrotext" and mode ~= "unit" then
    self.cfg.clickMode = "macro"
  end
end

--[[ quest log abstraction (Forever / retail / classic) ]]-------------------

local function NumQuestLogEntries()
  if C_QuestLog and C_QuestLog.GetNumQuestLogEntries then
    return C_QuestLog.GetNumQuestLogEntries() or 0
  end
  return (GetNumQuestLogEntries and GetNumQuestLogEntries()) or 0
end

-- returns questID, title, isHeader, isComplete
local function QuestLogEntry(index)
  if C_QuestLog and C_QuestLog.GetInfo then
    local info = C_QuestLog.GetInfo(index)
    if info then
      local complete = false
      if info.questID and C_QuestLog.IsComplete then
        complete = C_QuestLog.IsComplete(info.questID) and true or false
      end
      return info.questID, SafeName(info.title), info.isHeader, complete
    end
  end
  if GetQuestLogTitle then
    local title, _, _, isHeader, _, isComplete, _, questID = GetQuestLogTitle(index)
    return questID, SafeName(title), isHeader, (isComplete == 1)
  end
end

-- returns a list of { text = , type = , finished = }
local function QuestObjectives(index, questID)
  if questID and C_QuestLog and C_QuestLog.GetQuestObjectives then
    local objectives = C_QuestLog.GetQuestObjectives(questID)
    if objectives and #objectives > 0 then return objectives end
  end
  local out = {}
  if GetNumQuestLeaderBoards and GetQuestLogLeaderBoard then
    for j = 1, (GetNumQuestLeaderBoards(index) or 0) do
      local text, objType, finished = GetQuestLogLeaderBoard(j, index)
      out[j] = { text = text, type = objType, finished = finished }
    end
  end
  return out
end

local function IsWatched(questID, index)
  if C_QuestLog and C_QuestLog.GetQuestWatchType and questID then
    return C_QuestLog.GetQuestWatchType(questID) ~= nil
  end
  if IsQuestWatched then return IsQuestWatched(index) end
  return false
end

--[[ "nearby" + "engaged" bookkeeping ]]-------------------------------------

local function HostileName(unit)
  if not unit or not UnitExists(unit) then return nil end
  if UnitIsPlayer(unit) or UnitIsDead(unit) then return nil end
  if not UnitCanAttack("player", unit) then return nil end
  return SafeName(UnitName(unit))
end

-- A unit GUID looks like "Creature-0-3151-1-184-448-000136DF9A"; field six is
-- the creature id, which is the same number QuestieDB stores and the same one
-- across every realm and locale.
local function CreatureIDFromGUID(guid)
  if type(guid) ~= "string" then return nil end
  local id = guid:match("^Creature%-%d+%-%d+%-%d+%-%d+%-(%d+)")
          or guid:match("^Vehicle%-%d+%-%d+%-%d+%-%d+%-(%d+)")
  return tonumber(id)
end

-- Anything lootable: unlike HostileName this allows corpses, which is the
-- whole point when crediting a drop.
local function LootedName(unit)
  if not unit or not UnitExists(unit) then return nil end
  if UnitIsPlayer(unit) then return nil end
  return SafeName(UnitName(unit))
end

function NM:CacheGUID(unit, name)
  local guid = UnitGUID and UnitGUID(unit)
  if type(guid) ~= "string" or not name then return end
  if not self.guids[guid] then
    self.guidCount = self.guidCount + 1
    if self.guidCount > MAX_GUIDS then
      self.guids, self.guidCount = {}, 1
    end
  end
  self.guids[guid] = name
end

function NM:NoteUnit(unit)
  local name = HostileName(unit)
  if not name then return nil end
  self.seen[name] = GetTime() + SEEN_MEMORY
  self:CacheGUID(unit, name)

  -- Learn the exact spelling of anything whose creature id a quest wants.
  -- This is the real prize of id matching: no localisation, no plurals, no
  -- "the objective text calls them something else" problem.
  local id = CreatureIDFromGUID(UnitGUID and UnitGUID(unit))
  if id then
    if unit:find("nameplate", 1, true) then self.plateIDs[unit] = id end
    if self.wanted[id] then self.idNames[id] = name end
  end
  return name, id
end

-- Deliberately targeting, mousing over or looting something is our stand-in
-- for the combat log: it is how we guess which NPC earned a quest tick.
function NM:PushEngaged(name, id)
  name = SafeName(name)
  if not name then return end
  if self.engaged[1] and self.engaged[1].name == name then
    self.engaged[1].t = GetTime()
    self.engaged[1].id = self.engaged[1].id or id
    return
  end
  table.insert(self.engaged, 1, { name = name, id = id, t = GetTime() })
  while #self.engaged > 10 do table.remove(self.engaged) end
end

function NM:NoteEngagedUnit(unit)
  local name, id = self:NoteUnit(unit)
  if name then self:PushEngaged(name, id) end
end

-- A drop objective ticks up when you LOOT, not when the mob dies, so the
-- corpse in the loot window is by far the best evidence we can get.
function NM:NoteLoot()
  local credited = false
  if GetNumLootItems and GetLootSourceInfo then
    pcall(function()
      for slot = 1, (GetNumLootItems() or 0) do
        local guid = GetLootSourceInfo(slot)
        local name = type(guid) == "string" and self.guids[guid] or nil
        if name then
          self:PushEngaged(name, CreatureIDFromGUID(guid))
          credited = true
        end
      end
    end)
  end
  if not credited then
    self:PushEngaged(LootedName("target"), CreatureIDFromGUID(UnitGUID and UnitGUID("target")))
  end
end

function NM:NearbyNames()
  local now, names = GetTime(), {}
  for name, expiry in pairs(self.seen) do
    if expiry < now then self.seen[name] = nil else names[name] = true end
  end
  for _, name in pairs(self.plates) do
    if SafeName(name) then names[name] = true end
  end
  return names
end

--[[ candidate scan ]]-------------------------------------------------------

local function LearnedFor(key)
  local entry = NextMobDB.npcs[key]
  if not entry then return nil end
  local list = {}
  for name, count in pairs(entry) do
    if SafeName(name) and type(count) == "number" then
      list[#list + 1] = { name = name, count = count }
    end
  end
  if #list == 0 then return nil end
  table.sort(list, function(a, b)
    if a.count == b.count then return a.name < b.name end
    return a.count > b.count
  end)
  return list
end

function NM:ScanQuests()
  local nearby = self:NearbyNames()
  local found, seenName = {}, {}
  local wanted = {}   -- [creatureID] = quest title

  local function add(name, quest, source, score)
    name = SafeName(name)
    if not name then return end
    name = Trim(name)
    if name == "" or #name > 60 then return end

    -- The nearby bonus has to be folded in BEFORE comparing against an entry
    -- we already have, or a raw score gets compared with a bonused one and the
    -- better evidence loses. When better evidence does win, the provenance
    -- moves with it: /nm list is a diagnostic, so it must not report that a
    -- name came from a guess when the creature id confirmed it.
    local key = name:lower()
    local isNearby = nearby[name] and true or false
    local effective = score + (isNearby and 100 or 0)

    local existing = seenName[key]
    if existing then
      if effective > existing.score then
        existing.score  = effective
        existing.source = source
        existing.quest  = quest or existing.quest
      end
      return
    end

    local entry = {
      name   = name,
      quest  = quest,
      source = source,
      nearby = isNearby,
      score  = effective,
    }
    seenName[key] = entry
    found[#found + 1] = entry
  end

  for index = 1, NumQuestLogEntries() do
    local questID, title, isHeader, isComplete = QuestLogEntry(index)
    if questID and not isHeader and not isComplete then
      local objectives = QuestObjectives(index, questID)

      -- A quest whose every objective is already filled has nothing left to
      -- kill, even when the game has not flagged the quest itself complete
      -- yet. None of its mobs belong in the list.
      local anyUnfinished = false
      for _, obj in ipairs(objectives) do
        local _, _, _, finished = ObjectiveState(obj)
        if not finished then anyUnfinished = true break end
      end

      if anyUnfinished then
      local watched = IsWatched(questID, index) and 10 or 0
      local dbAdded = false
      for objIndex, obj in ipairs(objectives) do
        local text = SafeName(obj.text) or ""
        local name, cur, max, finished = ObjectiveState(obj)
        if not finished then
          local key = questID .. ":" .. objIndex
          local order = -objIndex

          -- 0. QuestieDB knows the answer outright, when it is installed.
          -- Added once per quest rather than per objective, because it
          -- answers at quest granularity. Each row carries QuestieDB's own
          -- label, so a row we can tie to an objective that is already
          -- filled gets dropped here: no more targeting the boars once the
          -- boar count is done on a quest that also wants something else.
          if not dbAdded and type(self.db) == "table" then
            dbAdded = true
            local known = self.db:NamesForQuest(questID)
            if known then
              for i, item in ipairs(known) do
                local keep, matchedIndex = true, MatchObjectiveIndex(objectives, item.text)
                if matchedIndex then
                  local _, _, _, doneAlready = ObjectiveState(objectives[matchedIndex])
                  keep = not doneAlready
                end
                if keep then
                  add(item.name, title,
                    item.why == "drop" and "questiedb-drop" or "questiedb",
                    80 + watched + order - i)
                  if type(item.npcID) == "number" then
                    wanted[item.npcID] = title
                  end
                end
              end
            end
          end

          -- creature ids we have seen give credit here before
          local learnedIDs = NextMobDB.ids[key]
          if learnedIDs then
            for id in pairs(learnedIDs) do
              if type(id) == "number" then wanted[id] = title end
            end
          end

          -- 1. things we have learned actually give credit here
          local learned = LearnedFor(key)
          if learned then
            for i, item in ipairs(learned) do
              add(item.name, title, "learned", 60 + watched + order - i)
            end
          end

          -- 2/3. the objective text itself, for kill-style objectives
          local objType = obj.type
          if name and (objType == nil or objType == "monster" or objType == "player") then
            local matchedPlate = false
            for plateName in pairs(nearby) do
              if Matches(plateName, name) then
                add(plateName, title, "nearby", 40 + watched + order)
                matchedPlate = true
              end
            end
            add(name, title, "objective", 20 + watched + order)
            local singular = Singular(name)
            if not matchedPlate and singular ~= name and #singular >= 4 then
              -- /target does prefix matching, so the singular form often
              -- catches "Defias Thug" from "Defias thugs".
              add(singular, title, "objective", 15 + watched + order)
            end
          end

          -- Drop objectives name an ITEM, never a mob, so the text itself is
          -- useless as a target. But quest items are very often named after
          -- the family that drops them, so a nearby mob sharing an
          -- identifying word is a good first guess: "Murloc Fin" -> the
          -- "Murloc Oracle" standing in front of you. Restricted to nearby
          -- mobs on purpose, so a wrong guess costs one inert macro line.
          if name and (objType == "item" or objType == "object" or objType == nil) then
            for plateName in pairs(nearby) do
              if SharesWord(name, plateName) then
                add(plateName, title, "drop-guess", 35 + watched + order)
              end
            end
          end
        end
      end
      end
    end
  end

  -- Creature-id matches outrank every text heuristic, because there is
  -- nothing left to get wrong: the id came from the quest database and the
  -- name came off the unit itself.
  for token, id in pairs(self.plateIDs) do
    if wanted[id] then
      local name = SafeName(self.plates[token])
      if name then
        self.idNames[id] = name
        add(name, wanted[id], "id-match", 90)
      end
    end
  end
  for id, name in pairs(self.idNames) do
    if wanted[id] then add(name, wanted[id], "id-match", 88) end
  end

  self.wanted = wanted

  table.sort(found, function(a, b)
    if a.score == b.score then return a.name < b.name end
    return a.score > b.score
  end)

  while #found > MAX_NAMES do table.remove(found) end
  self.candidates = found
  return found
end

-- A visible nameplate whose creature id a quest wants. Used only by the
-- opt-in unit mode; see the comment in PushMacro.
function NM:LiveUnit()
  local bestToken, bestIndex
  for token, id in pairs(self.plateIDs) do
    if self.wanted[id] and UnitExists(token) and not UnitIsDead(token)
       and UnitCanAttack("player", token) then
      local index = tonumber(token:match("(%d+)$")) or 99
      if not bestIndex or index < bestIndex then
        bestToken, bestIndex = token, index
      end
    end
  end
  return bestToken
end

--[[ macro body ]]-----------------------------------------------------------

function NM:OrderedNames()
  local names = {}
  for _, entry in ipairs(self.candidates) do names[#names + 1] = entry.name end
  local n = #names
  if n > 1 and self.rotation > 0 then
    for _ = 1, self.rotation % n do
      table.insert(names, table.remove(names, 1))
    end
  end
  return names
end

function NM:BuildBody(limit)
  local body = self.cfg.alwaysClear and "/cleartarget" or "/cleartarget [dead][help]"

  -- /target matches by name and will happily land on a corpse. A macro
  -- conditional cannot test the candidate before targeting it, but it can
  -- test the result: so after every attempt, drop the target if it turned out
  -- to be dead. The following /target [noexists] then gets its turn, and the
  -- last guard means a click never leaves you holding a corpse.
  --
  -- It costs 19 characters per name out of the 255 the client allows, so the
  -- list is shorter with this on. The ranking makes that a fair trade: the
  -- names that survive the cut are the ones worth trying.
  local guard = self.cfg.skipDead and "\n/cleartarget [dead]" or ""

  for _, name in ipairs(self:OrderedNames()) do
    -- name and guard go in as one unit, so a truncated body never ends with
    -- an unguarded attempt.
    local chunk = "\n/target [noexists] " .. name .. guard
    if #body + #chunk > limit then break end
    body = body .. chunk
  end
  return body
end

local MACRO_NAME = "NextMob"
local MACRO_ICON = "INV_Misc_QuestionMark"

-- Create or update the saved macro the button drives. Returns its index, or
-- nil plus a reason. Must not be called in combat.
function NM:EnsureMacro(body)
  if type(GetMacroIndexByName) ~= "function" then return nil, "no macro api" end

  local index = GetMacroIndexByName(MACRO_NAME)
  if index and index > 0 then
    local ok, err = pcall(EditMacro, index, MACRO_NAME, MACRO_ICON, body)
    if not ok then return nil, tostring(err) end
    return index
  end

  local ok, result = pcall(CreateMacro, MACRO_NAME, MACRO_ICON, body, false)
  if not ok then return nil, tostring(result) end
  index = GetMacroIndexByName(MACRO_NAME)
  if index and index > 0 then return index end
  return nil, "macro list full"
end

function NM:PushMacro()
  if InCombatLockdown() then
    self.pendingPush = true
    return
  end
  self.pendingPush = false

  local body = self:BuildBody(MACRO_LIMIT)
  self.lastBody = body

  local mode = self.cfg.clickMode or "macro"
  local unit = (mode == "unit") and self:LiveUnit() or nil
  self.activeUnit = unit

  -- The saved macro is kept current whenever we can, so it is also usable
  -- straight off an action bar.
  local index, macroError
  if mode ~= "macrotext" then
    index, macroError = self:EnsureMacro(body)
    self.macroIndex, self.macroError = index, macroError
  end

  local button = _G.NextMobButton
  if button then
    -- Exactly one mechanism is armed at a time. Leaving both "macro" and
    -- "macrotext" set makes which one wins undefined, so the unused one is
    -- always cleared.
    if unit then
      button:SetAttribute("macrotext", nil)
      button:SetAttribute("macro", nil)
      button:SetAttribute("unit", unit)
      button:SetAttribute("type", "target")
    elseif mode ~= "macrotext" and index then
      button:SetAttribute("macrotext", nil)
      button:SetAttribute("unit", nil)
      button:SetAttribute("macro", MACRO_NAME)
      button:SetAttribute("type", "macro")
    else
      -- macrotext mode, or macro creation failed and this is all that is left
      button:SetAttribute("macro", nil)
      button:SetAttribute("unit", nil)
      button:SetAttribute("macrotext", body)
      button:SetAttribute("type", "macro")
    end
  end

  if self.UpdateButton then self:UpdateButton() end
end

function NM:Refresh()
  if self.pendingScan then return end
  self.pendingScan = true
  C_Timer.After(0.2, function()
    self.pendingScan = false
    self:ScanQuests()
    self:PushMacro()
  end)
end

--[[ learning: which NPC actually gave credit ]]-----------------------------
-- Preferred evidence is the combat log, but addons cannot register it on
-- Midnight-era clients, so target/mouseover history stands in for it there.

function NM:NoteDamage(destGUID)
  if type(destGUID) == "string" then self.damaged[destGUID] = GetTime() end
end

function NM:NoteKill(destGUID, destName)
  destName = SafeName(destName)
  if type(destGUID) ~= "string" or not destName then return end
  local hit = self.damaged[destGUID]
  if not hit or (GetTime() - hit) > DAMAGE_MEMORY then return end
  table.insert(self.kills, 1, { name = destName, t = GetTime() })
  while #self.kills > 8 do table.remove(self.kills) end
  self.damaged[destGUID] = nil
end

function NM:Learn(key, objectiveText)
  local now = GetTime()
  local best

  local bestID

  local function consider(name, id, when, window)
    if (now - when) > window then return false end
    if Matches(name, objectiveText) then best, bestID = name, id; return true end
    if not best then best, bestID = name, id end
    return false
  end

  for _, kill in ipairs(self.kills) do
    if consider(kill.name, kill.id, kill.t, KILL_WINDOW) then break end
  end
  if not best then
    for _, engagement in ipairs(self.engaged) do
      if consider(engagement.name, engagement.id, engagement.t, ENGAGE_WINDOW) then break end
    end
  end
  if not SafeName(best) then return end

  if type(bestID) == "number" then
    local ids = NextMobDB.ids[key]
    if not ids then ids = {}; NextMobDB.ids[key] = ids end
    ids[bestID] = (ids[bestID] or 0) + 1
    self.idNames[bestID] = best
  end

  local entry = NextMobDB.npcs[key]
  if not entry then entry = {}; NextMobDB.npcs[key] = entry end
  entry[best] = (entry[best] or 0) + 1

  local count = 0
  for _ in pairs(entry) do count = count + 1 end
  if count > MAX_LEARNED then
    local worstName, worstCount
    for name, n in pairs(entry) do
      if not worstCount or n < worstCount then worstName, worstCount = name, n end
    end
    entry[worstName] = nil
  end

  Debug("learned", best, "for", key)
end

function NM:CheckProgress()
  local fresh = {}
  for index = 1, NumQuestLogEntries() do
    local questID, _, isHeader = QuestLogEntry(index)
    if questID and not isHeader then
      local objectives = QuestObjectives(index, questID)
      for objIndex, obj in ipairs(objectives) do
        local text = SafeName(obj.text) or ""
        local _, cur = ParseObjective(text)
        if type(obj.numFulfilled) == "number" then cur = obj.numFulfilled end
        if cur then
          local key = questID .. ":" .. objIndex
          fresh[key] = cur
          local previous = self.progress[key]
          if previous and cur > previous then
            self:Learn(key, text)
          end
        end
      end
    end
  end
  self.progress = fresh
end

--[[ events ]]--------------------------------------------------------------

local playerGUID

local DAMAGE_EVENTS = {
  SWING_DAMAGE = true, RANGE_DAMAGE = true, SPELL_DAMAGE = true,
  SPELL_PERIODIC_DAMAGE = true, DAMAGE_SHIELD = true, DAMAGE_SPLIT = true,
  SPELL_BUILDING_DAMAGE = true, SWING_MISSED = true, SPELL_MISSED = true,
}

function NM:OnCombatLog()
  if not CombatLogGetCurrentEventInfo then return end
  local _, subEvent, _, sourceGUID, _, _, _, destGUID, destName = CombatLogGetCurrentEventInfo()
  if DAMAGE_EVENTS[subEvent] then
    local petGUID = UnitGUID("pet")
    if sourceGUID == playerGUID or (petGUID and sourceGUID == petGUID) then
      self:NoteDamage(destGUID)
    end
  elseif subEvent == "UNIT_DIED" or subEvent == "PARTY_KILL" then
    self:NoteKill(destGUID, destName)
  end
end

NM:SetScript("OnEvent", function(self, event, arg1, ...)
  if event == "ADDON_LOADED" then
    if arg1 == ADDON_NAME then
      self:InitDB()
      if self.CreateButton then self:CreateButton() end
    end
    return
  end

  if event == "ADDON_ACTION_FORBIDDEN" or event == "ADDON_ACTION_BLOCKED" then
    -- arg1 is the addon, arg2 the function it was refused. Only ours is any
    -- of our business; other addons' notices are not ours to narrate.
    if arg1 == ADDON_NAME then
      local what = ...   -- arg2: the function that was refused
      self.blocked[#self.blocked + 1] = { event = event, what = tostring(what or "?") }
      if not self.blockedWarned then
        self.blockedWarned = true
        Print("|cffff0000the client refused an action|r - run |cffffff00/nm test|r and send the output.")
      end
    end
    return
  end

  if event == "COMBAT_LOG_EVENT_UNFILTERED" then
    self:OnCombatLog()
    return
  end

  if event == "PLAYER_LOGIN" then
    if self.adoptedOldDB then
      Print("carried your learned NPC database over from QuestTarget.")
      Print("the old |cffffff00QuestTarget|r macro is now unused and can be deleted.")
    end
    playerGUID = UnitGUID("player")
    self:CheckProgress()
    self:Refresh()
    return
  end

  if event == "PLAYER_REGEN_ENABLED" then
    if self.pendingPush then self:PushMacro() end
    return
  end

  if event == "NAME_PLATE_UNIT_ADDED" then
    -- via NoteUnit, so the creature id and exact name are recorded too
    local name = self:NoteUnit(arg1)
    if name then
      self.plates[arg1] = name
      self:Refresh()
    end
    return
  end

  if event == "NAME_PLATE_UNIT_REMOVED" then
    if arg1 then
      local id = self.plateIDs[arg1]
      self.plates[arg1] = nil
      self.plateIDs[arg1] = nil
      -- Only a wanted mob leaving is worth a rescan; ordinary traffic is not.
      if id and self.wanted[id] then self:Refresh() end
    end
    return
  end

  if event == "UPDATE_MOUSEOVER_UNIT" then
    self:NoteEngagedUnit("mouseover")
    return
  end

  if event == "PLAYER_TARGET_CHANGED" then
    self:NoteEngagedUnit("target")
    return
  end

  if event == "LOOT_OPENED" or event == "LOOT_READY" then
    self:NoteLoot()
    return
  end

  if event == "QUEST_LOG_UPDATE" or event == "UNIT_QUEST_LOG_CHANGED" then
    self:CheckProgress()
    self:Refresh()
    return
  end

  -- QUEST_ACCEPTED / QUEST_REMOVED / QUEST_WATCH_* / zone changes
  self:Refresh()
end)

-- Midnight-era clients forbid addons from registering combat log events. A
-- pcall is not necessarily enough: a refusal can arrive as a blocked-action
-- notice rather than a catchable Lua error, which shows the player a popup on
-- login even though nothing is actually broken. So we do not ask at all unless
-- the client looks like one that allows it.
--
-- C_RestrictedActions is part of the same generation that removed combat log
-- access, which makes it a cheap and specific signal. Classic flavours have
-- neither, and keep the combat log.
local function CombatLogAllowed()
  if type(CombatLogGetCurrentEventInfo) ~= "function" then return false end
  if _G.C_RestrictedActions ~= nil then return false end
  if _G.C_NamePlateManager ~= nil then return false end
  return true
end

local function SafeRegister(event)
  local ok = pcall(NM.RegisterEvent, NM, event)
  if not ok then Debug("event unavailable:", event) end
  return ok
end

SafeRegister("ADDON_LOADED")
SafeRegister("PLAYER_LOGIN")
SafeRegister("PLAYER_REGEN_ENABLED")
SafeRegister("PLAYER_ENTERING_WORLD")
SafeRegister("QUEST_LOG_UPDATE")
SafeRegister("QUEST_ACCEPTED")
SafeRegister("QUEST_REMOVED")
SafeRegister("QUEST_TURNED_IN")
SafeRegister("UNIT_QUEST_LOG_CHANGED")
SafeRegister("ZONE_CHANGED")
SafeRegister("ZONE_CHANGED_NEW_AREA")
SafeRegister("UPDATE_MOUSEOVER_UNIT")
SafeRegister("PLAYER_TARGET_CHANGED")
SafeRegister("LOOT_OPENED")
SafeRegister("LOOT_READY")
SafeRegister("NAME_PLATE_UNIT_ADDED")
SafeRegister("NAME_PLATE_UNIT_REMOVED")
SafeRegister("QUEST_WATCH_LIST_CHANGED")
SafeRegister("QUEST_WATCH_UPDATE")
if CombatLogAllowed() then
  NM.hasCombatLog = SafeRegister("COMBAT_LOG_EVENT_UNFILTERED")
else
  NM.hasCombatLog = false
  NM.combatLogNote = "not offered by this client"
end

-- So a blocked action can be attributed instead of being a mystery popup.
SafeRegister("ADDON_ACTION_FORBIDDEN")
SafeRegister("ADDON_ACTION_BLOCKED")

--[[ slash commands ]]------------------------------------------------------

SLASH_NEXTMOB1 = "/nm"
SLASH_NEXTMOB2 = "/nextmob"

SlashCmdList["NEXTMOB"] = function(input)
  local cmd, rest = (input or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")

  if cmd == "show" then
    NM.cfg.hidden = false
    NM:UpdateButton()
    Print("button shown.")

  elseif cmd == "hide" then
    NM.cfg.hidden = true
    NM:UpdateButton()
    Print("button hidden. /nm show brings it back.")

  elseif cmd == "lock" then
    NM.cfg.locked = not NM.cfg.locked
    Print("button is now", NM.cfg.locked and "locked." or "unlocked - drag to move.")

  elseif cmd == "reset" then
    NextMobDB.anchor = {}
    NM:RestorePosition()
    Print("button position reset to the centre of the screen.")

  elseif cmd == "mode" then
    local want = rest
    if want == "macro" or want == "macrotext" or want == "unit" then
      NM.cfg.clickMode = want
      NM:PushMacro()
      Print("click mode set to |cffffff00" .. want .. "|r.")
      if want == "macro" then
        Print("the button now runs the saved macro named NextMob.")
      elseif want == "macrotext" then
        Print("the button now runs an inline macro body (blocked on some clients).")
      else
        Print("the button now targets a matched nameplate directly.")
      end
    else
      Print("click mode is |cffffff00" .. tostring(NM.cfg.clickMode) .. "|r.")
      print("  |cffffff00/nm mode macro|r     - run the saved NextMob macro (default, most compatible)")
      print("  |cffffff00/nm mode macrotext|r - run an inline body (older mechanism)")
      print("  |cffffff00/nm mode unit|r      - target a matched nameplate directly")
    end

  elseif cmd == "macro" then
    NM.cfg.clickMode = "macro"
    NM:PushMacro()
    if type(NM.macroIndex) == "number" and NM.macroIndex > 0 then
      Print(("the saved macro |cffffff00%s|r is at macro slot %d - you can drag it onto an action bar from Esc -> Macros."):format("NextMob", NM.macroIndex))
    else
      Print("could not create the saved macro:", tostring(NM.macroError or "unknown"))
    end

  elseif cmd == "unit" then
    NM.cfg.clickMode = (NM.cfg.clickMode == "unit") and "macro" or "unit"
    NM:PushMacro()
    Print("click mode is now |cffffff00" .. NM.cfg.clickMode .. "|r.")
    if NM.cfg.clickMode == "unit" then
      Print("note: if the locked mob dies during combat the click goes inert until combat ends.")
    end

  elseif cmd == "dead" then
    NM.cfg.skipDead = not NM.cfg.skipDead
    NM:PushMacro()
    if NM.cfg.skipDead then
      Print("skipping dead targets: |cff00ff00ON|r - a corpse is dropped straight away.")
      Print(("costs 19 chars per name, so the list is shorter: %d of 255 used now."):format(#NM:BuildBody(255)))
    else
      Print("skipping dead targets: OFF - more names fit, but clicks can land on corpses.")
    end

  elseif cmd == "cycle" then
    NM.cfg.alwaysClear = not NM.cfg.alwaysClear
    Print("drop current target on every click:", NM.cfg.alwaysClear and "ON" or "OFF")
    NM:PushMacro()

  elseif cmd == "list" then
    NM:ScanQuests()
    if #NM.candidates == 0 then
      Print("no kill targets found in your quest log right now.")
    else
      Print("current targets, best first:")
      for i, entry in ipairs(NM.candidates) do
        print(string.format("  %d. |cffffff00%s|r  (%s%s)  - %s",
          i, entry.name, entry.source, entry.nearby and ", nearby" or "",
          entry.quest or "?"))
      end
    end

  elseif cmd == "status" then
    Print("QuestieDB:", type(NM.db) == "table" and NM.db:Describe() or "adapter missing")
    Print("learning source:", NM.hasCombatLog and "combat log"
      or ("target history (" .. (type(NM.combatLogNote) == "string" and NM.combatLogNote
        or "combat log unavailable") .. ")"))
    Print("skip dead targets:", NM.cfg.skipDead and "ON" or "OFF")
    local objectives, names = 0, 0
    for _, entry in pairs(NextMobDB.npcs) do
      objectives = objectives + 1
      for _ in pairs(entry) do names = names + 1 end
    end
    Print(string.format("learned %d NPC name(s) across %d objective(s).", names, objectives))
    local wantedCount, verified = 0, 0
    for id in pairs(NM.wanted) do
      wantedCount = wantedCount + 1
      if NM.idNames[id] then verified = verified + 1 end
    end
    Print(string.format("tracking %d creature id(s); %d seen and name-verified.", wantedCount, verified))
    Print("click mode:", tostring(NM.cfg.clickMode),
      type(NM.activeUnit) == "string" and ("(locked on " .. NM.activeUnit .. ")") or "")
    Print("macro body is", #NM:BuildBody(BUTTON_LIMIT), "of", BUTTON_LIMIT, "characters.")

  elseif cmd == "db" then
    Print("QuestieDB:", type(NM.db) == "table" and NM.db:Describe() or "adapter missing")
    if type(NM.db) == "table" and NM.db:IsAvailable() then
      local shown = 0
      for index = 1, NumQuestLogEntries() do
        local questID, title, isHeader, isComplete = QuestLogEntry(index)
        if questID and not isHeader and not isComplete then
          local known = NM.db:NamesForQuest(questID)
          if known then
            shown = shown + 1
            Print(("|cffffff00%s|r (quest %d):"):format(title or "?", questID))
            for _, item in ipairs(known) do
              print(("    %s  [npc %d, %s]"):format(item.name, item.npcID, item.why))
            end
          end
        end
      end
      if shown == 0 then
        Print("no quest in your log resolved through QuestieDB.")
      end
    end

  elseif cmd == "test" then
    local button = _G.NextMobButton
    Print("|cffffff00--- diagnostics ---|r")
    local _, build, _, toc = GetBuildInfo()
    Print(("client: build %s, interface %s"):format(tostring(build), tostring(toc)))
    Print("click mode:", tostring(NM.cfg.clickMode))
    Print("QuestieDB:", type(NM.db) == "table" and NM.db:Describe() or "adapter missing")
    Print("candidates:", #NM.candidates)
    for i = 1, math.min(#NM.candidates, 3) do
      print(("    %d. %s (%s)"):format(i, NM.candidates[i].name, NM.candidates[i].source))
    end

    if not button then
      Print("|cffff0000the button does not exist|r - Button.lua failed to load.")
    else
      Print(("button: type=%s macro=%s unit=%s macrotext=%s"):format(
        tostring(button:GetAttribute("type")),
        tostring(button:GetAttribute("macro")),
        tostring(button:GetAttribute("unit")),
        button:GetAttribute("macrotext") and "(set)" or "nil"))
      Print(("clicks received since login: %d"):format(NM.clickCount or 0))
      if (NM.clickCount or 0) == 0 then
        Print("|cffffff00click the button once, then run /nm test again.|r")
        Print("if this stays at 0, the click is not reaching the button at all.")
        Print("if it counts up but nothing gets targeted, the targeting mechanism is blocked -")
        Print("try |cffffff00/nm mode unit|r, and |cffffff00/nm mode macrotext|r, reporting which works.")
      end
    end

    if type(NM.macroIndex) == "number" and NM.macroIndex > 0 then
      Print(("saved macro: slot %d"):format(NM.macroIndex))
      local body = GetMacroBody and GetMacroBody(NM.macroIndex)
      if body then
        Print("macro body:")
        for line in tostring(body):gmatch("[^\n]+") do print("    " .. line) end
      end
    elseif NM.cfg.clickMode ~= "macrotext" then
      Print("|cffff0000saved macro missing|r:", tostring(NM.macroError or "unknown"))
    end
    if type(NM.lastBody) == "string" and #NM.lastBody > 0 then
      Print(("body length: %d / %d chars"):format(#NM.lastBody, 255))
    end
    Print("combat log:", NM.hasCombatLog and "registered"
      or (type(NM.combatLogNote) == "string" and NM.combatLogNote or "not registered"))
    Print("skip dead targets:", NM.cfg.skipDead and "ON" or "OFF")
    if #NM.blocked > 0 then
      Print(("|cffff0000%d blocked action(s) attributed to this addon:|r"):format(#NM.blocked))
      for _, entry in ipairs(NM.blocked) do
        print(("    %s: %s"):format(entry.event, entry.what))
      end
    else
      Print("blocked actions attributed to this addon: none")
    end

  elseif cmd == "forget" then
    NextMobDB.npcs = {}
    Print("learned NPC list wiped.")
    NM:Refresh()

  elseif cmd == "debug" then
    NM.cfg.debug = not NM.cfg.debug
    Print("debug:", NM.cfg.debug and "ON" or "OFF")

  else
    Print("commands:")
    print("  |cffffff00/nm list|r    - show what it would target right now")
    print("  |cffffff00/nm status|r  - data sources and database size")
    print("  |cffffff00/nm db|r      - what QuestieDB knows about your current quests")
    print("  |cffffff00/nm hide|r / |cffffff00show|r - toggle the floating button")
    print("  |cffffff00/nm lock|r    - lock/unlock dragging the button")
    print("  |cffffff00/nm reset|r   - move the button back to the screen centre")
    print("  |cffffff00/nm macro|r   - also keep a real macro named NextMob updated")
    print("  |cffffff00/nm test|r    - diagnostics: why is nothing getting targeted?")
    print("  |cffffff00/nm mode|r    - how a click targets (macro / macrotext / unit)")
    print("  |cffffff00/nm unit|r    - shortcut: toggle direct nameplate targeting")
    print("  |cffffff00/nm dead|r    - skip corpses when targeting (on by default)")
    print("  |cffffff00/nm cycle|r   - clear your target on every click (lets you cycle)")
    print("  |cffffff00/nm forget|r  - wipe the learned NPC database")
    print("  Keybind it under Key Bindings -> NextMob.")
  end
end
