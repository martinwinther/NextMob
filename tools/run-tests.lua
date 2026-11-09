-- Runs every suite in tools/tests, each in its own interpreter.
--
--     lua5.4 tools/run-tests.lua .
--
-- The suites cannot share a process: each one stubs the WoW API from scratch
-- and ends in os.exit, so they are spawned rather than dofile'd. Exits
-- non-zero if any suite fails, which is what CI keys off.

local root = arg[1] or "."
local testdir = root .. "/tools/tests"

local lua = os.getenv("LUA_BIN")
if not lua or lua == "" then
  for _, candidate in ipairs({ "lua5.4", "lua5.3", "lua" }) do
    local probe = io.popen("command -v " .. candidate .. " 2>/dev/null")
    if probe then
      local found = probe:read("*l")
      probe:close()
      if found and found ~= "" then lua = candidate break end
    end
  end
end
if not lua then
  io.stderr:write("no lua interpreter found; set LUA_BIN\n")
  os.exit(1)
end

-- Named explicitly rather than globbed: Lua has no portable directory read,
-- and an explicit list means a suite that stops being run gets noticed.
local suites = {
  "test_basics",      -- parsing, ranking, macro building, learning
  "test_forever",     -- a client that forbids the combat log, and Secret values
  "test_drops",       -- collect objectives, loot sources, item/mob name overlap
  "test_questiedb",   -- the optional QuestieDB adapter, including it misbehaving
  "test_idmatch",     -- creature-id matching and every click mode
  "test_completion",  -- objectives whose count is already filled
  "test_guards",      -- corpse skipping and blocked-action attribution
}

local failed = {}
for _, name in ipairs(suites) do
  print(("\n================ %s ================"):format(name))
  local cmd = ('%s "%s/%s.lua" "%s" "%s"'):format(lua, testdir, name, testdir, root)
  local ok, how, code = os.execute(cmd)
  if not (ok == true or ok == 0) then
    failed[#failed + 1] = ("%s (%s %s)"):format(name, tostring(how), tostring(code))
  end
end

print(("\n================ summary ================"))
print(("%d suite(s) run, %d failed"):format(#suites, #failed))
for _, f in ipairs(failed) do print("  FAILED: " .. f) end
os.exit(#failed == 0 and 0 or 1)
