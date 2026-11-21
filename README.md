# EverlookDB Auctions

Auction house prices, selling and shopping lists for WoW Forever, from the makers of [EverlookDB.com](https://everlookdb.com).

- **Price updates:** a bar along the bottom of the auction house shows which house you're at, how many items have prices and how old they are. Prices update by themselves a few seconds after you open the auction house and every 30 minutes while it's open (the server allows one update about every 15 minutes, so other addons' scans fit in between). An update reads every auction in about 30 seconds, with a progress bar, and you can keep buying and selling meanwhile. Update prices on the bar starts one by hand.
- **Searches count too:** prices from normal auction house searches are saved, no scan needed.
- **Prices in tooltips:** lowest buyout per item, how many are up, how old the price is, and the 30-day low and median. Hold Shift for the price of a full stack, Ctrl for the stack under the mouse. Also what a vendor pays (where the game leaves it out), what crafting one costs at today's prices, and "More to vendor" or "More to auction": which pays more, after the auction house's cut. Each line can be turned off on the Tooltips page.
- **Disenchant value:** for gear that can be disenchanted, the tooltip shows what the materials are worth on your auction house: each material's chance and amount (from classic-db) times its lowest price. It's an estimate, and it shows once every material has a price.
- **Quick sell tab:** EverlookDB's own selling tab, next to Blizzard's Sell tab (which still works as before, with the same undercut and a warning when the deposit is more than the sale brings). Everything in your bags you can sell, with a filter, favourites (right-click) and hidden items (Shift+right-click). Pick one and the price is set just under the cheapest auction someone else has up (1 silver by default, copper works too; your own auctions are matched, never undercut), or your last price for it, or the typical price from your last full scan, with how old that is. The post block reads like Blizzard's own Sell frame: Quantity (or Max), Unit price in gold, silver and copper boxes, Duration, Deposit, Total price, Post. Stackable goods go up as one listing that buyers take any amount of, so there are no stacks to split. Type your own price and an Undercut cheapest link takes you back to the automatic one. A red line warns when the deposit is more than the sale brings. If the auction house doesn't answer, the tab says so instead of claiming nobody is selling. The item's live auctions are listed (click one to price under it), with a 30-day price chart. Each item's last price, quantity and duration are remembered. One click on Post posts once.
- **Your auctions:** on the Quick sell tab, each of your auctions is checked against the live auctions and marked Undercut, Lowest or Sold, with a Cancel button (one click cancels one auction). The undercut button cancels your next undercut auction, one per click, and its tooltip shows what the cancel costs. When you post the last of an item, the next one in your list is picked for you. If the cheapest auction is a single one far below the usual price, the price line says so.
- **Advanced search:** the gold Advanced search button on the Buy tab, above the categories, opens a query box over the auction list. It searches everything in your last full scan with the same query language as EverlookDB.com, including things the normal search can't: stats, random-stat versions, slot, item and required level, price. For example `type has wand and reqlevel le 29 sort by price`, `slot is trinket and price lt 5g sort by price` or `sta ge 10 and reqlevel le 40 top 20 by sta`. `effect` holds an item's Equip:, Use: and Chance on hit: lines (`slot is feet and effect has "speed"`) and `text` everything on its tooltip; `has` without a column searches the tooltip: `has "fire damage" and slot is trinket`. Click a result to see its live auctions and buy: Buy, then Confirm with the price on the button.
- **Below vendor price:** the Below vendor button in Advanced search lists auctions that cost less than a vendor pays for the item, with the profit each and for a full stack, biggest profit first: buy them and sell them to any vendor (vendors take no cut). In the query language it's `belowvendor` or `price lt vendor`, with `profit` and `stackprofit` as columns. Elsewhere such auctions get a green mark: a Below vendor tag in search results, the profit beside the auction in the buy panel, and a green edge in Blizzard's own lists. Quest items and items vendors don't buy never count.
- **Shopping tab:** named lists of searches. Run a whole list in one click and see each search's results under it, with live prices. Save in Advanced search adds a search to a list. Lists import and export as plain text (`# name`, then one search per line).
- **Crafting cost:** beside the profession window, for the recipe you pick: each material and its lowest auction price, what the materials cost together, what the result sells for (and what disenchanting it is worth, for gear), and the profit after the auction house's 5% cut. It uses your saved prices, so it works away from the auction house.
- **Shopping list from a recipe:** the Shopping list button under the crafting cost lists the recipe's materials with how many you have and how many to buy (ticked when you have too few; change the amounts or the number of crafts). Create list saves them as a shopping list named after the recipe, so at the auction house you can search each one with one click.
- **Prices anywhere:** `/eah prices` opens Advanced search in its own window away from the auction house, over your last full scan. Live prices and buying still need the auction house.
- **Crafting profit:** `/eah profit` lists every recipe you know whose result sells for more than its materials cost, after the cut, best first. Make shopping list saves what the crafts you plan need.
- **AH log:** one window, four tabs, that opens anywhere. Bought (`/eah bought`): everything you bought at the auction house; mark the purchases you crafted with and a recipe shows its cost per craft at what you paid. For sale (`/eah forsale`): your auctions as the auction house last showed them. Income (`/eah income`): sales and other gold you took from the mail, with what crafting a sold item again costs. Looted (`/eah loot`): everything you picked up, with where it came from and what it's worth.
- **Loot cards and Hurray!:** a short card at the top of the screen for each loot, with roughly what it's worth, and a card with fireworks when one of your auctions sells. Both can be turned off.
- **Everlook Bar:** a Loot plugin for Everlook Bar (or any data-broker bar) shows today's loot.
- **Options:** type `/eah` for the settings window (it is also in the game's Settings under AddOns). Every setting is a command too: `/eah get` lists them, `/eah duration 24` changes one.
- **Price Feed:** with the [EverlookDB App](https://github.com/quikmn/everlookdb-uploader) running, the newest scan anyone uploaded to EverlookDB.com for your auction houses is in the game at your next `/reload` or login, so prices are fresh even when you haven't been to the auction house for days. See below.
- Prices are kept per realm and per auction house (Alliance, Horde, and the neutral houses in Booty Bay, Gadgetzan and Everlook).

Sellers, bidders and other players are never saved. Nothing is ever posted, bought or cancelled without your click.

## Price Feed

Players' scans are uploaded to EverlookDB.com by the [EverlookDB App](https://github.com/quikmn/everlookdb-uploader). The app also goes the other way: every 15 minutes, and right after each of your uploads, it fetches the newest scan of each auction house you play on (your realms and factions, and the realm's neutral house) and writes it into the game as the Price Feed: a small data addon, **EverlookDB Auctions: Price Feed** (folder `EverlookDBAuctions_Shared`), listed under EverlookDB Auctions in the addon list. It is also on CurseForge, empty, for the app to fill (like TradeSkillMaster's AppHelper). The game only reads addon files at login and `/reload`, so that is when new prices from the feed arrive. Without the app (or with its Price Feed switch off) nothing changes.

- The bar at the bottom of the auction house and the General page of `/eah` say how the feed is: "Price Feed: Alliance · other players' scan, 12 min old", "Price Feed: no data yet" (installed, the app isn't filling it yet) or "Price Feed: off" (with where to get it). The first time you open the auction house without it, one chat line says so; never again.
- For each item and random-stat version, whichever is newer is used: your own scan or the feed's. A price from the feed always says so ("other players' scan · 12 min ago").
- The 30-day low and median combine your daily lows with everyone's (the lower of the two each day).
- Your own saved scans and prices are never overwritten; the feed is kept apart and only combined when a price is read. A missing, old or broken feed is simply ignored.
- The feed has no player names, like everything else here.
- `/eah feed` says how it is. Turn it off on the General page of `/eah` ("Use the Price Feed") or with `/eah feed off` (`/eah shared off` still works).

## Gear upgrades

What gear is worth to your spec, and what the auction house has that beats what you wear.

- **Your specs and builds:** the first time you open the auction house, pick the spec or levelling build (several, if you're not sure yet) this character gears for: the talent specs plus builds players level with, such as Beast Mastery with a melee two-hander, a dual-wield melee hunter, Protection warrior levelling, spell-power Protection paladin from 40, or Discipline to 40 then Shadow (`tools/upgrades/builds.json`). "Not now" counts every spec of your class. Change it on the Gear upgrades page of `/eah` or with `/eah up spec fury`.
- **Upgrades tab:** a tab at the bottom of the auction house, beside Quick sell and Shopping, read from the last full scan (yours or other players' shared one), so `/eah up` opens it in a window of its own anywhere. Every slot like the character window, with the best upgrade within your max price; click a slot for all its upgrades. Right-click an item to find it in Buy, Shift-click to link it. "Make shopping list" saves the best upgrade of every slot as a list in the Shopping tab. Max price per item, smallest upgrade in %, and rich mode (the biggest upgrade instead of the most upgrade per gold).
- **Scores:** every stat the game reports (spell damage per school, healing, weapon DPS for main hand, off hand and ranged, random "of the Bear" suffixes each on their own), times your spec's stat weights, plus the average value of procs and Use: effects. Compared with what you wear: rings and trinkets against the weaker of your two, an off-hand while you wear a two-hander says so, an empty slot is "fills an empty slot". Items your class can't use are skipped; plate and mail wearers see only their best armor type (casters and healers see every type they can wear). An item above your level shows as "Next upgrade needs level N".
- **Only real upgrades, with the reason:** an item counts as an upgrade only when its gain beats the error margin of the weights (twice the standard error; sims give theirs, estimates count as less sure); otherwise it says "About the same". Every gain is a share of your whole gear ("+6.5% of your gear"), the same number in tooltips, on bag slots, in the Upgrades tab and on quest rewards. The tooltip always says why ("+14 Crit Rating, +8 Strength (+136% over your worn helm)") with the price next to it, and weights that are estimates say so.
- **Stat weights per level:** each spec has weights for every five levels up to 60, because ratings, talents and abilities change as you level. Adjusted to your talents (a * marks a weight a talent changed). Copy them into a profile of your own and change any value, import and export strings to share, or import a Pawn scale. Optionally Pawn's own scale for your spec.
- **Around the game:** the upgrade for each of your specs on gear tooltips ("+6.5% of your gear" for Fury, the best two and "+N more" until you pick a spec, "Not your armor type", "You have a better one in your bags"), a "+6.5%" badge on bag slots (Blizzard's bags and Bagnon), one chat line when new gear in your bags is an upgrade, the upgrade on each quest reward with a star on the best, and, if you turn it on, your grey items sold when you open a vendor (`/eah up junk` does it once). Only grey items, never anything else.

`/eah up help` lists its commands: `spec`, `weights`, `reset`, `set <stat> <value>`, `export`, `import`, `max 25g`, `min 1`, `rich on|off`, `check`, `stats <item>`, `price <item>`, `junk`, `mem`.

Where the numbers come from:
- Level-60 stat weights, talent effects, item procs and rating conversions: [wowsims/forever](https://github.com/wowsims/forever) (MIT license): its EP presets, and its own sims for mage and warlock (run for this addon with its test harness). `tools/gen_upgrades.py` rebuilds `UpgradesData.lua` from a clone of it; its inputs are in `tools/upgrades/`, with wowsims' license.
- Weights below level 60, and for specs wowsims has no weights for (Holy and Protection paladin, Restoration shaman and druid): the per-level model in Forever Leveling BiS v0.12.0-beta's `Data/ModelWeights.lua`, MIT license, Copyright (c) 2026 Thunder (`tools/upgrades/ForeverLevelingBiS-LICENSE`), met to wowsims' numbers at 60. Those brackets are estimates. Nothing else from that addon is used.
- Items and prices: the game and EverlookDB's own data and scans.

## For addon authors: EverlookDBAuctionsAPI

A small API, read-only apart from adding shopping lists, so other addons can use these prices without reading the saved data. It reads what is already saved and never sends anything to the server.

```lua
local api = EverlookDBAuctionsAPI
if api and api.version >= 1 then
  local low, age, qty, auctions = api.price(itemID)
end
if api and api.version >= 3 then
  local low, age, qty, auctions, source = api.price(itemID)   -- source: "own" or "shared"
end
if api and api.version >= 2 then
  local ok, isNew = api.addShoppingList("Mageweave Bag", { { 4338, 8 }, { 2321, 2 } })
end
```

- `api.version`: a number that goes up by one whenever something is added. Nothing is ever removed or changed.
- `api.price(item[, suffix[, side]])` returns, or `nil` when there is no price:
  - the lowest buyout per unit, in copper
  - how old that price is, in seconds
  - how many are up
  - how many auctions (`nil` when only a normal search saw it)
  - (version 3) where it is from: `"own"` (this player's scans and searches) or `"shared"` (other players' newest scan, from the EverlookDB App; see Shared prices). Whichever is newer is returned.
- `api.history(item[, side])`: the lowest price per day for the last 30 days, oldest first: `{ { day = <unix time at the start of the day, UTC>, low = <copper> }, ... }`, own and shared scans together. It's an empty table when there is none.
- `api.disenchant(item)` returns, or `nil` when the item can't be disenchanted or a material has no price yet:
  - the estimated auction house value of disenchanting it, in copper
  - the age in seconds of the oldest material price it used

- `api.addShoppingList(name, items)` (version 2) saves a shopping list in the auction house's Shopping tab: `items = { { itemID, count }, ... }`. A list with the same name is replaced, so pushing it again updates it. Returns `true` and whether the list is new, or `false` and why: `"no name"`, `"no items"`, `"loading"` (the game hasn't loaded every item's name yet: call again in a moment) or `"not ready"` (the addon hasn't loaded its saved data yet). It is the one call that writes, and it only adds or replaces a list.

`item` is an item ID or an item link. A link carries its random-stat version ("of the Bear"), and `price` then looks up that version. With an ID, pass the version's suffix ID as `suffix`. Prices are for the player's realm and their own faction's auction house, or for the one that is open now. Pass `side` (`"Alliance"`, `"Horde"` or `"Neutral"`) to pick one. Returned tables are copies, and the API table can't be written to.

## Install

WowUp: pick **World of Warcraft: Forever**, then Get Addons → Install from URL, and paste `https://github.com/quikmn/EverlookDBAuctions`.

By hand: download the latest zip from Releases and unzip it into `World of Warcraft\_forever_\Interface\AddOns`.

## Commands

`/eah` follows the same pattern as every EverlookDB addon; a mistyped command suggests the nearest one.

- `/eah` opens the options; `/eah help` (or `?`) lists the commands
- `/eah status` shows the version, what's saved and which auction house API the game has; `/eah version`
- `/eah scan` starts a full scan while the auction house is open
- `/eah sell` opens the Quick sell tab, `/eah shop` the Shopping tab, `/eah run <list>` runs a shopping list
- `/eah up` opens Gear upgrades (the tab at the auction house, else its window); `/eah up help` lists its commands
- `/eah prices` searches your last full scan anywhere; `/eah profit` the crafting profit list
- `/eah bought`, `/eah forsale`, `/eah income`, `/eah loot` open the AH log on that tab
- `/eah lootmove` moves the loot cards, `/eah loottest` shows a few
- `/eah undercut 1s` sets how far under the cheapest auction to price: `1c`, `50c`, `1g`, `5%`, or `0` to match it
- `/eah get` lists every setting with its value (`/eah get duration` one); `/eah <setting> <value>` or `/eah set <setting> <value>` changes one (for example `/eah duration 24` or `/eah tipvendor on`), says so in chat and updates the open window. `/eah settings` still lists them too
- `/eah search <words>` opens the options with the search box filled
- `/eah debug` lists what is shown where, the addon's auction house searches and any cut-off labels (for bug reports)
- `/eah feedback` (or the Feedback button in the options) shows a link for reporting bugs and ideas
- `/eah test` reloads the UI after every full scan, so the scan is saved to disk at once (for testing)
- `/eah auto off` (or `on`) stops or restarts automatic price updates: one when you open the auction house, then every 30 minutes while it's open
- `/eah skin off` (or `on`) turns the EverlookDB look for the auction house off or on (then `/reload`)

## Coming next

Alerts when a shopping list has a match under your price.

## License

GPL-3.0-or-later (see LICENSE). Disenchant chances come from classic-db by the CMaNGOS community (GPL-3.0, https://github.com/cmangos/classic-db); `tools/disenchant_data.py` rebuilds Disenchant.lua from its dump. Gear upgrade stat weights: wowsims/forever (MIT) and the Forever Leveling BiS v0.12.0-beta model (MIT, Copyright (c) 2026 Thunder); see Gear upgrades above. Not affiliated with Blizzard Entertainment.
