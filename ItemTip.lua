-- EverlookDB Auctions: the item tooltip of our own list rows (Buy, Quick sell, Advanced search, Gear upgrades, Crafting, Profit, AH log).
-- The hovered item's tooltip opens right next to the mouse, not at the far end of a wide row, and the "Equipped"
-- comparison shows only while the game's compare key (Shift) is held: GameTooltip.suppressAutomaticCompareItem
-- (honoured by Blizzard's TooltipUtil.ShouldDoItemComparison) is set while our tooltip is up and put back the moment
-- it hides or someone else takes the tooltip. The game's alwaysCompareItems setting is never changed, and tooltips
-- outside our windows (Blizzard's own auction list too) keep the game's behaviour.
-- Pressing or letting go of Shift (or Ctrl) while hovering fills the tooltip again, so the comparison comes and goes
-- at once. Setting db.compareShift (General: "Compare with what I wear: only while holding Shift", default on): off
-- leaves the comparison to the game.
local ADDON, ns = ...

local tip = { owner = nil, refresh = nil, prev = nil, active = false }
ns.itemTip = tip

local function onlyWithShift()
  local db = ns.db and ns.db()
  return not db or db.compareShift ~= false
end

-- Puts back what GameTooltip had before ours.
local function restore()
  if not tip.active then return end
  local gt = _G.GameTooltip
  if gt then gt.suppressAutomaticCompareItem = tip.prev end
  tip.active, tip.owner, tip.refresh, tip.prev = false, nil, nil, nil
  if tip.events then tip.events:UnregisterEvent("MODIFIER_STATE_CHANGED") end
end
tip.restore = restore

local hooked = false
local function hook(gt)
  if hooked then return end
  hooked = true
  gt:HookScript("OnHide", restore)
  -- someone else taking the tooltip (another frame's SetOwner without a hide in between) gets the game's behaviour
  if hooksecurefunc then
    hooksecurefunc(gt, "SetOwner", function(_, owner) if tip.active and owner ~= tip.owner then restore() end end)
  end
  tip.events = CreateFrame("Frame")
  tip.events:SetScript("OnEvent", function()
    local owner, refresh = tip.owner, tip.refresh
    if not (tip.active and owner and refresh and gt:IsShown()) then return end
    if gt.IsOwned and not gt:IsOwned(owner) then restore(); return end
    refresh(owner)
  end)
end

-- Instead of GameTooltip:SetOwner(row, "ANCHOR_RIGHT") on a row that shows an item: the tooltip opens just right of
-- the mouse. refresh(owner) fills it again when a modifier changes; it defaults to the row's OnEnter.
function ns.itemTipOwner(owner, refresh)
  local gt = _G.GameTooltip
  hook(gt)
  local prev = tip.active and tip.prev or gt.suppressAutomaticCompareItem
  restore()
  gt:SetOwner(owner, "ANCHOR_CURSOR_RIGHT", 16, 0)
  tip.prev = prev
  tip.owner = owner
  tip.refresh = refresh or (owner.GetScript and owner:GetScript("OnEnter")) or nil
  tip.active = true
  if onlyWithShift() then gt.suppressAutomaticCompareItem = true end
  tip.events:RegisterEvent("MODIFIER_STATE_CHANGED")
  return gt
end

-- A row's whole item tooltip: an item link ("item:..." or |H link) or an item ID, then fill(GameTooltip, shown) for
-- the row's own lines. Returns whether the item could be shown.
function ns.itemTooltip(owner, item, fill)
  local gt = ns.itemTipOwner(owner, function(o) ns.itemTooltip(o, item, fill) end)
  local ok = false
  if type(item) == "number" then
    ok = pcall(gt.SetItemByID, gt, item)
  elseif type(item) == "string" then
    ok = pcall(gt.SetHyperlink, gt, item)
  end
  if fill then fill(gt, ok) end
  gt:Show()
  return ok
end
