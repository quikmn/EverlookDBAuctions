-- A tiny fake of the game for the crafting box and the shopping list panel: frames that remember their text, shown
-- state, checks and scripts, a profession window with a picked recipe, a few items, prices and bag counts.
local function frame(kind, name)
  local f = { kind = kind, scripts = {}, shown = true, text = "", children = {} }
  local methods = {}
  function methods.Show(self) self.shown = true end
  function methods.Hide(self) self.shown = false end
  function methods.SetShown(self, on) self.shown = on and true or false end
  function methods.IsShown(self) return self.shown end
  function methods.IsVisible(self) return self.shown end
  function methods.SetText(self, t) self.text = t end
  function methods.GetText(self) return self.text end
  function methods.SetChecked(self, on) self.checked = on and true or false end
  function methods.GetChecked(self) return self.checked end
  function methods.SetScript(self, k, fn) self.scripts[k] = fn end
  function methods.HookScript(self, k, fn) self.scripts[k] = fn end
  function methods.GetScript(self, k) return self.scripts[k] end
  function methods.SetTextColor(self, r, g, b) self.color = { r, g, b } end
  function methods.GetChildren(self) return unpack(self.children) end
  function methods.GetEffectiveScale() return 1 end
  function methods.GetFrameLevel() return 5 end
  function methods.GetFrameStrata() return "MEDIUM" end
  function methods.GetStringHeight() return 12 end
  function methods.GetStringWidth() return 40 end
  function methods.IsForbidden() return false end
  function methods.GetLeft(self) return self.l end
  function methods.GetRight(self) return self.r end
  function methods.GetTop(self) return self.t end
  function methods.GetBottom(self) return self.b end
  function methods.GetParent(self) return self.parent end
  function methods.CreateTexture() return frame("Texture") end
  function methods.CreateFontString() return frame("FontString") end
  function methods.GetName() return name end
  function methods.SetPoint(self, ...) self.point = { ... } end
  function methods.ClearAllPoints(self) self.point = nil end
  -- unknown methods do nothing; the addon's own fields (edb...) start empty, as on a real frame
  return setmetatable(f, { __index = function(_, k)
    if methods[k] then return methods[k] end
    -- "more": an EverlookUI list's "N more not shown" line, made only when needed
    if type(k) == "string" and (k:sub(1, 3) == "edb" or k == "more") then return nil end
    return function() end
  end })
end
MOCK_FRAMES = {}
function CreateFrame(kind, name, parent)
  local f = frame(kind, name)
  f.parent = parent
  if parent and parent.children then parent.children[#parent.children + 1] = f end
  if name then _G[name] = f end
  MOCK_FRAMES[#MOCK_FRAMES + 1] = f
  return f
end
function CreateFont() return frame("Font") end
UIParent = frame("Frame", "UIParent")
GameTooltip = frame("GameTooltip")
function hooksecurefunc(t, k, fn)
  if type(t) == "string" then return end
  local old = t[k]
  t[k] = function(...) local r = old(...); fn(...); return r end
end
C_Timer = { After = function(_, fn) fn() end }
function GetMoneyString(c) return tostring(c) .. "c" end
function print() end
GameFontNormal, GameFontHighlightSmall, GameFontDisableSmall, GameFontNormalSmall, GameFontHighlight = {}, {}, {}, {}, {}
ITEM_QUALITY_COLORS = { [1] = { r = 1, g = 1, b = 1 } }

MOCK_ITEMS = { [6217] = "Copper Rod", [2840] = "Copper Bar", [2880] = "Weak Flux", [6218] = "Runed Copper Rod" }
MOCK_BAGS = { [6217] = 1, [2840] = 1 }
MOCK_PRICES = { [6217] = 120, [2840] = 35, [6218] = 900 }
C_Item = {
  GetItemNameByID = function(id) return MOCK_ITEMS[id] end,
  GetItemQualityByID = function() return 1 end,
  GetItemIconByID = function() return 134400 end,
  GetItemCount = function(id) return MOCK_BAGS[id] or 0 end,
  RequestLoadItemDataByID = function() end,
}
C_TradeSkillUI = {
  GetRecipeSchematic = function()
    return { name = "Runed Copper Rod", outputItemID = 6218, quantityMin = 1, quantityMax = 1, reagentSlotSchematics = {
      { quantityRequired = 1, reagents = { { itemID = 6217 } } },
      { quantityRequired = 4, reagents = { { itemID = 2840 } } },
      { quantityRequired = 1, reagents = { { itemID = 2880 } } },
    } }
  end,
}
ProfessionsFrame = frame("Frame", "ProfessionsFrame")
ProfessionsFrame.l, ProfessionsFrame.r, ProfessionsFrame.t, ProfessionsFrame.b = 100, 900, 700, 100
-- two tab buttons down the right edge, sticking out 34 px
for k = 1, 2 do
  local tab = CreateFrame("Button", nil, ProfessionsFrame)
  tab.l, tab.r, tab.t, tab.b = 896, 934, 660 - k * 44, 620 - k * 44
end
local form = { recipeID = 2666 }
function form.GetRecipeInfo() return { recipeID = form.recipeID, name = "Runed Copper Rod" } end
function form.Init() end
function form.Refresh() end
ProfessionsFrame.CraftingPage = { SchematicForm = form }
