-- Minimal WoW API stub so we can exercise NextMob's real logic offline.

local function stub(overrides)
  local t = overrides or {}
  return setmetatable(t, { __index = function(self, k)
    local fn = function() return nil end
    self[k] = fn
    return fn
  end })
end

UIParent = stub()
GameTooltip = stub()

local eventHandler
CreateFrame = function(frameType, name, parent, template)
  local f = stub({
    attrs = {},
    SetScript = function(self, script, fn)
      self["_" .. script] = fn
      if script == "OnEvent" then eventHandler = fn end
    end,
    HookScript = function(self, script, fn) self["_hook_" .. script] = fn end,
    CreateTexture = function() return stub() end,
    CreateFontString = function() return stub({ SetText = function(self, t) self.text = t end }) end,
    SetAttribute = function(self, k, v) self.attrs = self.attrs or {}; self.attrs[k] = v end,
    GetAttribute = function(self, k) return self.attrs and self.attrs[k] end,
    RegisterEvent = function(self, event)
      if FOREVER_MODE and event == "COMBAT_LOG_EVENT_UNFILTERED" then
        error("ADDON_ACTION_FORBIDDEN: COMBAT_LOG_EVENT_UNFILTERED", 2)
      end
    end,
    UnregisterEvent = function() end,
  })
  if name then _G[name] = f end
  return f
end

QUEST_MONSTERS_KILLED = "%s slain: %d/%d"
SlashCmdList = {}
C_Timer = { After = function(_, fn) fn() end }
InCombatLockdown = function() return false end
local clock = 1000
GetTime = function() return clock end
ADVANCE_CLOCK = function(n) clock = clock + n end

FAKE_GUIDS = {}
UnitGUID = function(unit)
  if unit == "player" then return "Player-1-AAAA" end
  return FAKE_GUIDS[unit]
end
UnitExists = function(unit) return _G.FAKE_UNITS and _G.FAKE_UNITS[unit] ~= nil end
UnitName = function(unit) return _G.FAKE_UNITS and _G.FAKE_UNITS[unit] end
UnitCanAttack = function() return true end
UnitIsPlayer = function() return false end
UnitIsDead = function() return false end

-- macro store
FAKE_MACROS = {}
MACRO_SLOTS_FULL = false
local nextMacroIndex = 0
GetMacroIndexByName = function(name)
  local m = FAKE_MACROS[name]
  return m and m.index or 0
end
CreateMacro = function(name, icon, body)
  if MACRO_SLOTS_FULL then error("too many macros") end
  nextMacroIndex = nextMacroIndex + 1
  FAKE_MACROS[name] = { index = nextMacroIndex, body = body, icon = icon }
  return nextMacroIndex
end
EditMacro = function(index, name, icon, body)
  for _, m in pairs(FAKE_MACROS) do
    if m.index == index then m.body = body return index end
  end
end
GetMacroBody = function(index)
  for _, m in pairs(FAKE_MACROS) do
    if m.index == index then return m.body end
  end
end
GetBuildInfo = function() return "1.60.1", "70862", "Nov 4 2026", 16001 end

-- Whichever body the button currently has armed: inline text, or the saved
-- macro it points at.
ARMED_BODY = function()
  local b = _G.NextMobButton
  if not b then return nil end
  local text = b:GetAttribute("macrotext")
  if type(text) == "string" then return text end
  local name = b:GetAttribute("macro")
  if type(name) == "string" and FAKE_MACROS[name] then return FAKE_MACROS[name].body end
  return nil
end

-- fake quest log -----------------------------------------------------------
FAKE_QUESTS = {}
C_QuestLog = {
  GetNumQuestLogEntries = function() return #FAKE_QUESTS end,
  GetInfo = function(i)
    local q = FAKE_QUESTS[i]
    if not q then return nil end
    return { questID = q.id, title = q.title, isHeader = false }
  end,
  IsComplete = function(id)
    for _, q in ipairs(FAKE_QUESTS) do
      if q.id == id then return q.complete == true end
    end
  end,
  GetQuestObjectives = function(id)
    for _, q in ipairs(FAKE_QUESTS) do
      if q.id == id then return q.objectives end
    end
  end,
  GetQuestWatchType = function(id)
    for _, q in ipairs(FAKE_QUESTS) do
      if q.id == id then return q.watched and 0 or nil end
    end
  end,
}

FAKE_COMBAT_EVENT = nil
CombatLogGetCurrentEventInfo = function()
  local e = FAKE_COMBAT_EVENT
  return e[1], e[2], e[3], e[4], e[5], e[6], e[7], e[8], e[9]
end

FIRE = function(event, arg1, arg2) eventHandler(_G.NextMobCore, event, arg1, arg2) end

-- A stand-in for Midnight "Secret" values: any comparison, concatenation or
-- tostring on one raises, exactly like the real thing.
FOREVER_MODE = false
local function boom() error("attempted to use a Secret value", 2) end
MAKE_SECRET = function()
  return setmetatable({}, { __eq = boom, __lt = boom, __le = boom,
                            __concat = boom, __tostring = boom, __index = boom })
end

-- loot window
FAKE_LOOT = { n = 0, sources = {} }
GetNumLootItems = function() return FAKE_LOOT.n end
GetLootSourceInfo = function(slot) return FAKE_LOOT.sources[slot] end
