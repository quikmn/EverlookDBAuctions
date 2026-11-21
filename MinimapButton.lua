-- EverlookDB Auctions: the minimap button and the Everlook Bar launcher, both a way into the main window (Hub.lua).
--   Left-click   the main window (Home, or the page used last)
--   Right-click  the settings (General)
--   Drag         around the minimap's edge: on the circle of a round minimap, out to the edge of a square one
--                (GetMinimapShape, which Everlook Bar and other minimap addons answer)
-- The tooltip: income today and this week, how old the newest prices are. The button is our own (no LibDBIcon): a
-- named Button on the Minimap with an .icon texture, so Everlook Bar's drawer and other collectors can hold it; while
-- one holds it, dragging is theirs. Hidden with the "minimap" setting (General) or /eah minimap.
-- The launcher: an LDB "launcher" called "EverlookDB Auctions" with the same clicks and tooltip, for Everlook Bar or
-- any LibDataBroker display.
local ADDON, ns = ...

local M = {}
ns.minimapButton = M
M.ICON = "Interface\\AddOns\\" .. ADDON .. "\\Media\\icon"
M.DEFAULT_ANGLE = 200

local function db() return ns.db and ns.db() end
local function money(c) return ns.money and ns.money(c) or tostring(c) end
local function settings()
  local d = db()
  if not d then return {} end
  d.minimapButton = d.minimapButton or {}
  return d.minimapButton
end

-- The summary both tooltips show.
function M.tooltip(tip)
  local H = ns.hub
  tip:AddLine("EverlookDB Auctions", 1, 0.82, 0)
  local d = db() or {}
  if H then
    local today, week, waiting, est = H.income(d.income, d.soldPending)
    tip:AddDoubleLine("Income today", money(today), 1, 1, 1, 1, 1, 1)
    tip:AddDoubleLine("Last 7 days", money(week), 1, 1, 1, 1, 1, 1)
    if waiting > 0 then
      tip:AddDoubleLine("Waiting in the mail", ("%d sold%s"):format(waiting, est > 0 and (", ~" .. money(est)) or ""), 1, 1, 1, 1, 1, 1)
    end
    local age, shared = H.newestPrices()
    if age then
      tip:AddDoubleLine("Prices", H.age(time() - age) .. (shared and " (Price Feed)" or ""), 1, 1, 1, 1, 1, 1)
    else
      tip:AddDoubleLine("Prices", "none yet: open the auction house", 1, 1, 1, 0.6, 0.6, 0.6)
    end
  end
  tip:AddLine(" ")
  tip:AddDoubleLine("Click", "open", 0.6, 0.6, 0.6, 0.6, 0.6, 0.6)
  tip:AddDoubleLine("Right-click", "settings", 0.6, 0.6, 0.6, 0.6, 0.6, 0.6)
end

function M.click(button)
  local H = ns.hub
  if button == "RightButton" then
    if H and H.isOpen("general") then H.close() elseif H then H.open("general") end
    return
  end
  if H and H.ready then H.toggle() elseif ns.app then ns.app:Toggle() end
end

---------------------------------------------------------------------------------------------------------------------
-- The button

local button

local function shape() return (GetMinimapShape and GetMinimapShape()) or "ROUND" end

function M.place()
  if not button or not Minimap or button:GetParent() ~= Minimap then return end   -- held by a collector: theirs
  local H = ns.hub
  local w = Minimap:GetWidth() or 140
  local x, y = H.minimapOffset(settings().angle or M.DEFAULT_ANGLE, shape(), w / 2 + 5)
  button:ClearAllPoints()
  button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function make()
  if button or not Minimap then return button end
  local b = CreateFrame("Button", "EverlookDBAuctionsMinimapButton", Minimap)
  b:SetSize(31, 31)
  b:SetFrameStrata("MEDIUM")
  b:SetFrameLevel((Minimap:GetFrameLevel() or 1) + 8)
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b:RegisterForDrag("LeftButton")
  b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
  local bg = b:CreateTexture(nil, "BACKGROUND")
  bg:SetSize(24, 24)
  bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
  bg:SetPoint("CENTER")
  b.icon = b:CreateTexture(nil, "ARTWORK")
  b.icon:SetSize(18, 18)
  b.icon:SetPoint("CENTER")
  b.icon:SetTexture(M.ICON)
  local border = b:CreateTexture(nil, "OVERLAY")
  border:SetSize(50, 50)
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  border:SetPoint("TOPLEFT")
  b.border = border
  b:SetScript("OnClick", function(_, which) GameTooltip:Hide(); M.click(which) end)
  b:SetScript("OnEnter", function(self)
    if self.dragging then return end
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    M.tooltip(GameTooltip)
    GameTooltip:AddDoubleLine("Drag", "move it", 0.6, 0.6, 0.6, 0.6, 0.6, 0.6)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  b:SetScript("OnDragStart", function(self)
    -- held by a button drawer (Everlook Bar, MinimapButtonBag...): not ours to move around the minimap
    if self:GetParent() ~= Minimap then return end
    self.dragging = true
    GameTooltip:Hide()
    self:SetScript("OnUpdate", function()
      local mx, my = Minimap:GetCenter()
      local scale = Minimap:GetEffectiveScale()
      local cx, cy = GetCursorPosition()
      if not (mx and cx) then return end
      settings().angle = math.floor(math.deg(math.atan2(cy / scale - my, cx / scale - mx)) % 360 + 0.5)
      M.place()
    end)
  end)
  b:SetScript("OnDragStop", function(self)
    self.dragging = nil
    self:SetScript("OnUpdate", nil)
  end)
  button = b
  M.button = b
  return b
end

-- Shows or hides the button as the setting says, and puts it in its place.
function M.refresh()
  local want = not settings().hide
  if want and not button then make() end
  if not button then return end
  button:SetShown(want)
  if want then M.place() end
end

---------------------------------------------------------------------------------------------------------------------
-- The launcher for Everlook Bar (or any LibDataBroker display)

local function launcher()
  local LDB = LibStub and LibStub("LibDataBroker-1.1", true)
  if not LDB or M.ldb then return end
  M.ldb = LDB:NewDataObject("EverlookDB Auctions", {
    type = "launcher", label = "EverlookDB Auctions", icon = M.ICON,
    OnClick = function(_, which) M.click(which) end,
    OnTooltipShow = function(tip) M.tooltip(tip) end,
  })
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function()
  launcher()
  M.refresh()
  -- the minimap may change shape or size after login (Everlook Bar, other minimap addons): place it again then
  if C_Timer then C_Timer.After(2, M.place) end
  if Minimap and Minimap.HookScript then Minimap:HookScript("OnSizeChanged", function() M.place() end) end
end)
