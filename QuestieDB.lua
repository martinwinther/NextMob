--[[-------------------------------------------------------------------------
  NextMob - QuestieDB.lua

  Optional adapter for the QuestieDB addon, which ships a real quest/NPC/item
  database for Classic Era, TBC, Wrath, Cata, Mists and Forever. When it is
  installed we can stop guessing: it knows which NPCs a quest wants and which
  NPCs drop a quest item. When it is absent, nothing here runs and NextMob
  falls back to its own heuristics.

  Everything is defensive on purpose:

  * QuestieDB is a separate addon on its own release cycle. Every call goes
    through pcall so a changed signature degrades us to the heuristics instead
    of erroring in someone's quest log.
  * The published docs describe the ENTITY api (`QuestDB.Get(id, key)`,
    `NpcDB.Get(id, key)`, generated getters, `Support.Get`) but do NOT document
    the row layout of a quest's `objectives` field. So rather than hard-code a
    layout, we walk the structure and keep every integer that resolves to a
    real NPC name. A wrong guess cannot survive the walk: NpcDB has no name
    for it, so it is discarded.
---------------------------------------------------------------------------]]

local NM = _G.NextMob

-- `wipe` is a WoW global; keep a local fallback so the file is testable.
local wipe = _G.wipe or function(t)
  for k in pairs(t) do t[k] = nil end
  return t
end

local DB = {}
NM.db = DB

local MAX_PER_QUEST = 8
local MAX_DEPTH     = 5
-- Drop tables tend to carry a drop CHANCE next to the npc id. Chances are
-- 1-100, and so are a handful of real npc ids, so ids below this are not
-- trusted from the drop path specifically.
local MIN_DROP_NPC_ID = 100

-- Which groups of the `objectives` field we read. Group 4 is the reputation
-- pair {factionID, value} - a faction id can collide with a real npc id, so
-- it is never walked. Other groups are ignored only because they are not
-- creature-bearing in any layout we know of.
local KILL_GROUPS = { 1, 5 }
local ITEM_GROUPS = { 3 }

local detected = false
local note     = nil  -- why we are not using QuestieDB, if we are not
local cache    = {}   -- [questID] = list (false means "looked, found nothing")

--[[ detection ]]-----------------------------------------------------------

local function Entities()
  local questDB, npcDB = _G.QuestDB, _G.NpcDB
  if type(questDB) ~= "table" or type(npcDB) ~= "table" then return nil end
  if type(questDB.Get) ~= "function" or type(npcDB.Get) ~= "function" then return nil end
  return questDB, npcDB
end

function DB:IsAvailable()
  if detected then return true end
  if not Entities() then return false end

  -- Version gate, best effort: the contract number is QuestieDB's own
  -- compatibility signal. We ask for 1, not the current 4, on purpose: all we
  -- use is Get(id, key) on QuestDB/NpcDB plus the optional Support.Get, which
  -- is the oldest and most stable part of its surface. The Forever builds are
  -- on their own 1.0.x line, so gating any higher would refuse a QuestieDB
  -- that works perfectly well for us. Support.Get is guarded separately, so a
  -- build without it just loses drop data.
  local lib = _G.LibQuestieDB
  if type(lib) == "table" and type(lib.RequireContract) == "function" then
    local called, ok, message = pcall(lib.RequireContract, 1)
    if called and ok == false then
      note = tostring(message or "QuestieDB contract too old")
      return false
    end
  end

  detected = true
  wipe(cache)
  return true
end

function DB:Reset()
  detected = false
  note = nil
  wipe(cache)
end

--[[ lookups ]]-------------------------------------------------------------

local function NpcName(id)
  if type(id) ~= "number" or id <= 0 or id ~= math.floor(id) then return nil end
  local _, npcDB = Entities()
  if not npcDB then return nil end
  local ok, name = pcall(npcDB.Get, id, "name")
  if ok and type(name) == "string" and name ~= "" then return name end
  return nil
end

-- Keep every integer in a nested structure, bounded in depth.
local function CollectNumbers(value, out, depth)
  if depth > MAX_DEPTH then return end
  if type(value) == "number" then
    out[value] = true
  elseif type(value) == "table" then
    for _, inner in pairs(value) do
      CollectNumbers(inner, out, depth + 1)
    end
  end
end

-- Pull the ids and the label out of one objective row without assuming field
-- order: the first integer at any depth is an id, the first string is the
-- label. The label is what lets Core work out WHICH live objective this row
-- belongs to, so a row whose count is already filled can be dropped.
local function RowIDsAndText(row)
  local ids, text = {}, nil
  local function walk(value, depth)
    if depth > MAX_DEPTH then return end
    local kind = type(value)
    if kind == "number" then
      ids[#ids + 1] = value
    elseif kind == "string" then
      if text == nil and value ~= "" then text = value end
    elseif kind == "table" then
      for _, inner in pairs(value) do walk(inner, depth + 1) end
    end
  end
  walk(row, 0)
  return ids, text
end

local function GroupRows(objectives, groups)
  local rows = {}
  if type(objectives) ~= "table" then return rows end
  for _, group in ipairs(groups) do
    local entries = objectives[group]
    if type(entries) == "table" then
      for _, row in pairs(entries) do
        local ids, text = RowIDsAndText(row)
        if #ids > 0 then rows[#rows + 1] = { ids = ids, text = text } end
      end
    elseif type(entries) == "number" then
      rows[#rows + 1] = { ids = { entries } }
    end
  end
  return rows
end

-- QuestieDB exposes drop data through LibQuestieDB.Support.Get. Its schema is
-- not published, so three plausible shapes are tried and anything unexpected
-- is simply ignored.
local function DropSourceIDs(itemID)
  local lib = _G.LibQuestieDB
  if type(lib) ~= "table" or type(lib.Support) ~= "table" then return nil end
  if type(lib.Support.Get) ~= "function" then return nil end

  local ok, module = pcall(lib.Support.Get, "DropDB")
  if not ok or type(module) ~= "table" then return nil end

  local entry
  if type(module.Get) == "function" then
    local got, result = pcall(module.Get, itemID)
    if got then entry = result end
  end
  if entry == nil then entry = module[itemID] end
  if entry == nil then return nil end

  local numbers = {}
  CollectNumbers(entry, numbers, 0)
  return numbers
end

--[[ public: names for a quest ]]-------------------------------------------

-- Returns a list of { name = , npcID = , why = "kill"|"drop", text = }, best
-- first. `text` is QuestieDB's own label for the objective, used by Core to
-- skip rows whose live counter is already full. It may be nil.
-- or nil when QuestieDB has nothing for this quest.
function DB:NamesForQuest(questID)
  if type(questID) ~= "number" then return nil end
  if not self:IsAvailable() then return nil end

  local cached = cache[questID]
  if cached ~= nil then
    if cached == false then return nil end
    return cached
  end

  local questDB = Entities()
  local ok, objectives = pcall(questDB.Get, questID, "objectives")
  if not ok or type(objectives) ~= "table" then
    cache[questID] = false
    return nil
  end

  local list, seen = {}, {}

  local function push(id, why, text)
    if #list >= MAX_PER_QUEST or seen[id] then return end
    local name = NpcName(id)
    if not name then return end
    seen[id] = true
    list[#list + 1] = { name = name, npcID = id, why = why, text = text }
  end

  -- 1. NPCs the quest wants killed
  for _, row in ipairs(GroupRows(objectives, KILL_GROUPS)) do
    for _, id in ipairs(row.ids) do
      push(id, "kill", row.text)
    end
  end

  -- 2. NPCs that drop the quest's items
  for _, row in ipairs(GroupRows(objectives, ITEM_GROUPS)) do
    for _, itemID in ipairs(row.ids) do
      local sources = DropSourceIDs(itemID)
      if sources then
        for id in pairs(sources) do
          if id >= MIN_DROP_NPC_ID then push(id, "drop", row.text) end
        end
      end
    end
  end

  if #list == 0 then
    cache[questID] = false
    return nil
  end

  table.sort(list, function(a, b)
    if a.why ~= b.why then return a.why == "kill" end
    return a.npcID < b.npcID
  end)

  cache[questID] = list
  return list
end

function DB:Note()
  return note
end

function DB:Describe()
  if not self:IsAvailable() then
    return "not installed" .. (note and (" (" .. note .. ")") or "")
  end
  local lib = _G.LibQuestieDB
  local version
  if type(lib) == "table" then
    local ok, value = pcall(function() return lib.version or lib.Version end)
    if ok and value then version = tostring(value) end
  end
  return "installed" .. (version and (" (" .. version .. ")") or "")
end
