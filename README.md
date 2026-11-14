# EverlookDB Auctions

Auction house prices, selling and shopping lists for WoW Forever, from the makers of [EverlookDB.com](https://everlookdb.com).

- **Full scan:** one button beside the auction house reads every auction at once. The server allows this about every 15 minutes.
- **Searches count too:** prices from normal auction house searches are saved, no scan needed.
- **Prices in tooltips:** lowest buyout per item, how many are up, how old the price is, and the 30-day low and median. Hold Shift for the price of a full stack. A vendor price line can be turned on in the options.
- **Disenchant value:** for gear that can be disenchanted, the tooltip shows what the materials are worth on your auction house: each material's chance and amount (from classic-db) times its lowest price. It's an estimate, and it shows once every material has a price.
- **Selling tab:** everything in your bags you can sell, with a filter, favourites (right-click) and hidden items (Shift+right-click). Pick one and the price is set just under the cheapest auction someone else has up (1 silver by default; your own auctions are matched, never undercut), or your last price for it, or the typical price from your last full scan. Set the quantity (a full stack or everything with one click), the duration and the price; the total and the deposit show before you post. The item's live auctions are listed (click one to price under it), with a 30-day price chart. Each item's last price, quantity and duration are remembered. One click on Post posts once.
- **Your auctions:** on the Selling tab, each of your auctions is checked against the live auctions and marked Undercut, Lowest or Sold, with a Cancel button (one click cancels one auction). The undercut button cancels your next undercut auction, one per click, and its tooltip shows what the cancel costs. When you post the last of an item, the next one in your list is picked for you. If the cheapest auction is a single one far below the usual price, the price line says so.
- **Advanced search:** the Advanced search button on the panel opens a query box over the auction list. It searches everything in your last full scan with the same query language as EverlookDB.com, including things the normal search can't: stats, random-stat versions, slot, item and required level, price. For example `slot is trinket and price lt 5g | sort by price` or `items | where sta ge 10 and reqlevel le 40 | top 20 by sta`. Click a result to see its live auctions and buy: Buy, then Confirm with the price on the button.
- **Shopping tab:** named lists of searches. Run a whole list in one click and see each search's results under it, with live prices. Save in Advanced search adds a search to a list. Lists import and export as plain text (`# name`, then one search per line).
- **Options:** in the game's Settings under AddOns, or `/eah options`.
- Prices are kept per realm and per auction house (Alliance, Horde, and the neutral houses in Booty Bay, Gadgetzan and Everlook).

Sellers, bidders and other players are never saved. Nothing is ever posted, bought or cancelled without your click.

## For addon authors: EverlookDBAuctionsAPI

A small read-only API, so other addons can use these prices without reading the saved data. It reads what is already saved and never sends anything to the server.

```lua
local api = EverlookDBAuctionsAPI
if api and api.version >= 1 then
  local low, age, qty, auctions = api.price(itemID)
end
```

- `api.version`: a number that goes up by one whenever something is added. Nothing is ever removed or changed.
- `api.price(item[, suffix[, side]])` returns, or `nil` when there is no price:
  - the lowest buyout per unit, in copper
  - how old that price is, in seconds
  - how many are up
  - how many auctions (`nil` when only a normal search saw it)
- `api.history(item[, side])`: the lowest price per day for the last 30 days, oldest first: `{ { day = <unix time at the start of the day, UTC>, low = <copper> }, ... }`. It's an empty table when there is none.
- `api.disenchant(item)` returns, or `nil` when the item can't be disenchanted or a material has no price yet:
  - the estimated auction house value of disenchanting it, in copper
  - the age in seconds of the oldest material price it used

`item` is an item ID or an item link. A link carries its random-stat version ("of the Bear"), and `price` then looks up that version. With an ID, pass the version's suffix ID as `suffix`. Prices are for the player's realm and their own faction's auction house, or for the one that is open now. Pass `side` (`"Alliance"`, `"Horde"` or `"Neutral"`) to pick one. Returned tables are copies, and the API table can't be written to.

## Install

WowUp: pick **World of Warcraft: Forever**, then Get Addons → Install from URL, and paste `https://github.com/quikmn/EverlookDBAuctions`.

By hand: download the latest zip from Releases and unzip it into `World of Warcraft\_forever_\Interface\AddOns`.

## Commands

- `/eah` shows what's saved and which auction house API the game has
- `/eah scan` starts a full scan while the auction house is open
- `/eah sell` opens the Selling tab, `/eah shop` the Shopping tab, `/eah run <list>` runs a shopping list
- `/eah undercut 1s` sets how far under the cheapest auction to price: `50c`, `1g`, `5%`, or `0` to match it
- `/eah options` opens the options
- `/eah test` reloads the UI after every full scan, so the scan is saved to disk at once (for testing)
- `/eah auto off` (or `on`) stops or restarts the automatic full scan when you open the auction house (at most every 15 minutes)
- `/eah skin off` (or `on`) turns the EverlookDB look for the auction house off or on (then `/reload`)

## Coming next

Alerts when a shopping list has a match under your price.

## License

GPL-3.0-or-later (see LICENSE). Disenchant chances come from classic-db by the CMaNGOS community (GPL-3.0, https://github.com/cmangos/classic-db); `tools/disenchant_data.py` rebuilds Disenchant.lua from its dump. Not affiliated with Blizzard Entertainment.
