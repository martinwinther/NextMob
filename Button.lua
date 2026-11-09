--[[-------------------------------------------------------------------------
  NextMob - Button.lua

  A small movable, keybindable secure button. Its "macrotext" attribute is
  rewritten by Core.lua whenever the candidate list changes, so clicking it
  is exactly like clicking a macro - no protected-function trickery.
---------------------------------------------------------------------------]]

local NM = _G.NextMob

local SIZE = 44

function NM:RestorePosition()
  local button = _G.NextMobButton
  if not button or InCombatLockdown() then return end
  local anchor = NextMobDB.anchor or {}
  button:ClearAllPoints()
  if anchor.point then
    button:SetPoint(anchor.point, UIParent, anchor.point, anchor.x or 0, anchor.y or 0)
  else
    button:SetPoint("CENTER", UIParent, "CENTER", 0, -140)
  end
end

local function SavePosition(button)
  local point, _, _, x, y = button:GetPoint()
  NextMobDB.anchor = { point = point, x = x, y = y }
end

function NM:UpdateButton()
  local button = _G.NextMobButton
  if not button then return end

  local best = self.candidates[1]
  local count = #self.candidates

  if best then
    local label = best.name
    if #label > 20 then label = label:sub(1, 19) .. "\226\128\166" end
    button.label:SetText(label)
    button.icon:SetDesaturated(false)
    button:SetAlpha(1)
    button.count:SetText(count > 1 and count or "")
  else
    button.label:SetText("|cff999999no target|r")
    button.icon:SetDesaturated(true)
    button:SetAlpha(0.45)
    button.count:SetText("")
  end

  -- Show/Hide on a secure frame is blocked in combat; defer it.
  if not InCombatLockdown() then
    if self.cfg.hidden then button:Hide() else button:Show() end
  end
end

local function OnEnter(button)
  GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
  GameTooltip:AddLine("NextMob")
  local candidates = NM.candidates
  if #candidates == 0 then
    GameTooltip:AddLine("No kill objectives in your quest log.", 0.7, 0.7, 0.7)
  else
    GameTooltip:AddLine("Click to target, best first:", 0.7, 0.7, 0.7)
    for i = 1, math.min(#candidates, 8) do
      local entry = candidates[i]
      local note = entry.nearby and " |cff00ff00(nearby)|r" or ""
      GameTooltip:AddDoubleLine(entry.name .. note, entry.quest or "", 1, 1, 1, 0.6, 0.6, 0.6)
    end
  end
  if type(NM.activeUnit) == "string" then
    GameTooltip:AddLine("Locked on a verified quest mob.", 0, 1, 0)
  end
  GameTooltip:AddLine(" ")
  if NM.cfg.locked then
    GameTooltip:AddLine("Locked. /nm lock to move it.", 0.5, 0.5, 0.5)
  else
    GameTooltip:AddLine("Drag to move. /nm for options.", 0.5, 0.5, 0.5)
  end
  GameTooltip:Show()
end

function NM:CreateButton()
  if _G.NextMobButton then return end

  local button = CreateFrame("Button", "NextMobButton", UIParent, "SecureActionButtonTemplate")
  button:SetSize(SIZE, SIZE)
  button:SetMovable(true)
  button:SetClampedToScreen(true)
  button:RegisterForDrag("LeftButton")
  -- Some clients fire secure action buttons on key/mouse down rather than up
  -- depending on the ActionButtonUseKeyDown cvar; registering both means the
  -- click is never silently swallowed. Targeting twice is harmless.
  button:RegisterForClicks("AnyUp", "AnyDown")
  button:SetAttribute("type", "macro")
  button:SetAttribute("macrotext", "/cleartarget [dead][help]")

  local icon = button:CreateTexture(nil, "ARTWORK")
  icon:SetAllPoints()
  icon:SetTexture("Interface\\Icons\\Ability_Hunter_SniperShot")
  icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  button.icon = icon

  local border = button:CreateTexture(nil, "OVERLAY")
  border:SetPoint("TOPLEFT", -2, 2)
  border:SetPoint("BOTTOMRIGHT", 2, -2)
  border:SetColorTexture(0, 0, 0, 0)
  button.border = border

  button:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
  button:SetPushedTexture("Interface\\Buttons\\UI-Quickslot-Depress")

  local label = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  label:SetPoint("TOP", button, "BOTTOM", 0, -2)
  label:SetWidth(150)
  button.label = label

  local count = button:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
  count:SetPoint("BOTTOMRIGHT", -2, 2)
  button.count = count

  button:SetScript("OnDragStart", function(self)
    if NM.cfg.locked or InCombatLockdown() then return end
    self:StartMoving()
  end)
  button:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    SavePosition(self)
  end)
  button:SetScript("OnEnter", OnEnter)
  button:SetScript("OnLeave", function() GameTooltip:Hide() end)

  -- PreClick runs even when the secure action itself is blocked, so this
  -- counter distinguishes "the click never arrived" from "the click arrived
  -- but targeting was refused". /nm test reports it.
  button:HookScript("PreClick", function()
    NM.clickCount = NM.clickCount + 1
    NM.lastClick = GetTime()
  end)

  -- Rotate the list so a second click reaches the next candidate.
  button:HookScript("PostClick", function()
    -- Guard against the double fire that AnyUp+AnyDown can cause.
    local now = GetTime()
    if #NM.candidates > 1 and (now - NM.lastRotate) > 0.2 then
      NM.lastRotate = now
      NM.rotation = NM.rotation + 1
      NM:PushMacro()
    end
  end)

  self:RestorePosition()
  self:UpdateButton()
end
