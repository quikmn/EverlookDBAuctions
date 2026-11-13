# EverlookDB Auctions

Auction house prices for WoW Forever, from the makers of [EverlookDB.com](https://everlookdb.com).

- **Full scan:** one button beside the auction house reads every auction at once. The server allows this about every 15 minutes.
- **Searches count too:** prices from normal auction house searches are saved, no scan needed.
- **Prices in tooltips:** lowest buyout per item, how many are up, how old the price is, and the lowest price in the last 30 days.
- **Selling:** when you put an item in the sell frame, the price is set just under the cheapest auction someone else has up (1 silver by default; your own auctions are matched, never undercut). If nobody is selling it, the typical price from your last full scan is used. A list beside the auction house shows everything in your bags you can sell, with prices; click one, check the price, press Post.
- Prices are kept per realm and per auction house (Alliance, Horde, and the neutral houses in Booty Bay, Gadgetzan and Everlook).

Sellers, bidders and other players are never saved.

## Install

WowUp: pick **World of Warcraft: Forever**, then Get Addons → Install from URL, and paste `https://github.com/quikmn/EverlookDBAuctions`.

By hand: download the latest zip from Releases and unzip it into `World of Warcraft\_forever_\Interface\AddOns`.

## Commands

- `/eah` shows what's saved and which auction house API the game has
- `/eah scan` starts a full scan while the auction house is open
- `/eah undercut 1s` sets how far under the cheapest auction to price: `50c`, `1g`, `5%`, or `0` to match it
- `/eah test` reloads the UI after every full scan, so the scan is saved to disk at once (for testing)
- `/eah auto off` (or `on`) stops or restarts the automatic full scan when you open the auction house (at most every 15 minutes)

## Coming next

Searches using the same query language as EverlookDB.com (stats, level, slot, price), saved searches, and alerts when one of them has a match under your price.

## License

GPL-3.0-or-later (see LICENSE). Not affiliated with Blizzard Entertainment.
