# EverlookDB Auctions for addon authors

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
  - (version 3) where it is from: `"own"` (this player's scans and searches) or `"shared"` (other players' newest scan, from the EverlookDB App; see the Price Feed in the README). Whichever is newer is returned.
- `api.history(item[, side])`: the lowest price per day for the last 30 days, oldest first: `{ { day = <unix time at the start of the day, UTC>, low = <copper> }, ... }`, own and shared scans together. It's an empty table when there is none.
- `api.disenchant(item)` returns, or `nil` when the item can't be disenchanted or a material has no price yet:
  - the estimated auction house value of disenchanting it, in copper
  - the age in seconds of the oldest material price it used
  - (version 5) where the chances are from: `"players"` (players' disenchants, from the Price Feed), `"measured"` (version 6: disenchants counted in vanilla) or `"estimate"`

- `api.addShoppingList(name, items)` (version 2) saves a shopping list in the auction house's Shopping tab: `items = { { itemID, count }, ... }`. A list with the same name is replaced, so pushing it again updates it. Returns `true` and whether the list is new, or `false` and why: `"no name"`, `"no items"`, `"loading"` (the game hasn't loaded every item's name yet: call again in a moment) or `"not ready"` (the addon hasn't loaded its saved data yet). It is the one call that writes, and it only adds or replaces a list.

- `api.mail` (version 4): lets a mail addon tell the income ledger what it read and took from the mailbox, so every mail is counted once however it was opened. See the comments at the top of `API.lua`.

`item` is an item ID or an item link. A link carries its random-stat version ("of the Bear"), and `price` then looks up that version. With an ID, pass the version's suffix ID as `suffix`. Prices are for the player's realm and their own faction's auction house, or for the one that is open now. Pass `side` (`"Alliance"`, `"Horde"` or `"Neutral"`) to pick one. Returned tables are copies, and the API table can't be written to.
