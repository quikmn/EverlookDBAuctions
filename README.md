# EverlookDB Auctions

Auction house prices, selling and shopping lists for WoW Forever, from the makers of [EverlookDB.com](https://everlookdb.com).

- **One main window:** the minimap button, `/eah`, a key (Key Bindings, AddOns) and the EverlookDB Auctions launcher on Everlook Bar all open it. The sidebar has Home, Advanced search, AH log, Crafting profit, Gear upgrades and Merchant's Favor, then the settings, with a search box at the top. Home has a card for each: income, today's loot, Merchant's Favor, the newest gear upgrades, crafting profit, and a box that searches prices anywhere. At the auction house, Quick sell, Shopping and Upgrades are tabs of their own.
- **Minimap button:** click for the main window, right-click for the settings, drag it around the minimap. Its tooltip has today's income and how old your prices are. Hide it on the General page or with `/eah minimap`.
- **Price updates:** a bar along the bottom of the auction house shows which house you're at, how many items have prices and how old they are. Prices update by themselves a few seconds after you open the auction house and every 30 minutes while it's open (the server allows one update about every 15 minutes). An update takes about 30 seconds, with a progress bar, and you can keep buying and selling meanwhile. Normal auction house searches save prices too.
- **Prices in tooltips:** lowest buyout, how many are up, how old the price is, and the 30-day low and median. Hold Shift for a full stack, Ctrl for the stack under the mouse. Also what a vendor pays, what crafting one costs, and whether the auction house or a vendor pays more after the cut. Each line can be turned off on the Tooltips page.
- **Disenchant value:** for gear that can be disenchanted, what the materials are worth on your auction house, from what players really got when there are enough of their disenchants, else from disenchants measured in vanilla, else an estimate. The tooltip lists what it disenchants into: each material with its count, chance and worth, then the total.
- **Disenchant log:** every disenchant on all your characters, your own results on tooltips (for the item and for items like it), and a Disenchanting page with a search. The page also lists the gear in your bags with what each piece disenchants into and whether that beats selling it; click one to preview it and disenchant it with one click. `/eah de` or `/dv` opens it.
- **Quick sell tab:** everything in your bags you can sell, with a filter, favourites (right-click) and hidden items (Shift+right-click). Pick one and the price is set just under the cheapest auction someone else has up (1 silver by default; your own auctions are never undercut), or your last price for it. Quantity, unit price, duration, deposit and total work like Blizzard's Sell tab, with a 30-day price chart and a warning when the deposit is more than the sale brings. One click on Post posts once.
- **Your auctions:** each one is marked Undercut, Lowest or Sold, with a Cancel button. The undercut button cancels your next undercut auction, one per click.
- **Advanced search:** the Advanced search button on the Buy tab searches your last full scan with the same query language as EverlookDB.com: stats, random-stat versions, slot, level, price, effects. For example `type has wand and reqlevel le 29 sort by price` or `slot is feet and effect has "speed"`. Find enchanted gear with `enchant is "Fiery Weapon"` or `has enchant`. Click a result to see its live auctions and buy.
- **Below vendor price:** lists auctions that cost less than a vendor pays, with the profit each, biggest first. Such auctions also get a green mark in the auction house lists.
- **Shopping tab:** named lists of searches. Run a whole list in one click. Lists import and export as plain text.
- **Import a list:** paste what you want to buy, one item per line, in any common form: `60 Light Leather`, `Light Leather x60`, `Light Leather, 60`, item links, or an item ID and how many (`2318 60`). Add `max 25s` to a line to pay at most that for one. The same item twice adds up, and lines it can't read stay in the box to fix. The leveling guides on everlookdb.com have a "Copy for the addon" button.
- **Buy this list:** at the auction house, a small panel goes through the list one item at a time: "Buy 60 Light Leather?", Yes, then the cheapest way to get them (how many at which price, the total), a warning when that's far above the usual price or fewer are listed than you want, and one Buy button with the price on it. What you already have in your bags and bank is taken off first, and what you buy is ticked off the list. At the end it shows what you bought, skipped and spent. Nothing is bought until you press Buy.
- **Crafting cost:** beside the profession window, for the recipe you pick: each material's price, the total, what the result sells for, and the profit after the cut. The Shopping list button turns a recipe's materials into a shopping list.
- **Crafting profit:** `/eah profit` lists every recipe you know that sells for more than its materials cost, best first, with gold, silver and copper in lined-up columns. Click a heading to sort; filter by name, skill, profit, margin, cost and what you can make right now. With EverlookDB Crafting, tick your alts to add the recipes they know.
- **Prices anywhere:** `/eah prices` (or Home's search box) searches your last full scan away from the auction house.
- **AH log:** Bought (`/eah bought`), For sale (`/eah forsale`), Income (`/eah income`) and Looted (`/eah loot`). Income is a ledger of real gains: auction sales after the cut, vendor sales, looted money and quest rewards, with gold from players and your alts kept apart, and every auction you posted followed to sold, expired or cancelled.
- **Loot cards and Hurray!:** a short card at the top of the screen for each loot, with roughly what it's worth, and a card with fireworks when one of your auctions sells. Both can be turned off.
- **Everlook Bar:** a Loot plugin shows today's loot (works with any data-broker bar), and a launcher opens the main window.
- **Merchant's Favor:** how much Favor you have and, with EverlookDB Crafting, the Waylaid Crates that cost the least gold per Favor.
- **Price Feed:** with the [EverlookDB App](https://github.com/quikmn/everlookdb-uploader) running, you get the newest prices other players uploaded to EverlookDB.com for your auction houses at your next login or `/reload`. See below.
- **Settings:** the Settings pages of the main window (`/eah options`; also in the game's Settings under AddOns). Every setting is a command too: `/eah get` lists them, `/eah duration 24` changes one.

Prices are kept per realm and per auction house (Alliance, Horde, and the neutral houses in Booty Bay, Gadgetzan and Everlook). Sellers, bidders and other players are never saved. Nothing is ever posted, bought or cancelled without your click.

## Price Feed

Install **EverlookDB Auctions: Price Feed** next to this addon and run the [EverlookDB App](https://github.com/quikmn/everlookdb-uploader). The app keeps it filled with the newest prices players uploaded for the auction houses you play on, so your prices are fresh even when you haven't been to the auction house for days. New prices arrive at login and `/reload`.

- The bar at the bottom of the auction house and the General page say how the feed is ("Price Feed: Alliance · other players' scan, 12 min old").
- For each item, whichever is newer is used: your own scan or the feed's. A price from the feed always says so.
- Your own prices are never overwritten, and the feed has no player names.
- `/eah feed` says how it is; turn it off on the General page or with `/eah feed off`.

## Gear upgrades

What gear is worth to your spec, and what the auction house has that beats what you wear.

- **Your specs and builds:** the first time you open the auction house, pick the specs or levelling builds this character gears for (for example Beast Mastery with a melee two-hander, or Discipline to 40 then Shadow). Change it on the Gear upgrades page or with `/eah up spec fury`.
- **Upgrades tab:** every slot like the character window, with the best upgrade within your max price; click a slot for all its upgrades. `/eah up` opens it anywhere. "Make shopping list" saves the best upgrade of every slot.
- **Scores:** every stat times your spec's stat weights for your level, adjusted to your talents, plus procs and Use: effects, compared with what you wear. Items your class can't use are skipped.
- **Only real upgrades:** small gains say "About the same". Every gain is a share of your whole gear ("+6.5% of your gear") and the tooltip says why.
- **Stat weights:** for every spec and levelling build, every five levels up to 60, for solo levelling or groups. Make your own profile, share it with an import string, or import a Pawn scale. Weights that are estimates say so.
- **Around the game:** upgrades on gear tooltips, a "+6.5%" badge on bag slots (Blizzard's bags and Bagnon), a chat line when new gear in your bags is an upgrade, a star on the best quest reward, and, if you turn it on, your grey items sold at a vendor.

`/eah up help` lists its commands.

## Install

WowUp: pick **World of Warcraft: Forever**, then Get Addons → Install from URL, and paste `https://github.com/quikmn/EverlookDBAuctions`.

By hand: download the latest zip from Releases and unzip it into `World of Warcraft\_forever_\Interface\AddOns`.

## Commands

- `/eah` opens the main window; `/eah options` the settings; `/eah help` lists the commands
- `/eah minimap` shows or hides the minimap button
- `/eah status` shows the version and how old your prices are
- `/eah scan` updates prices now while the auction house is open
- `/eah sell` opens Quick sell, `/eah shop` Shopping, `/eah run <list>` runs a shopping list
- `/eah import` pastes a list of items to buy; `/eah buy [list]` buys a shopping list item by item
- `/eah up` opens Gear upgrades; `/eah up help` lists its commands
- `/eah prices` searches your last full scan anywhere; `/eah profit` the crafting profit list
- `/eah bought`, `/eah forsale`, `/eah income`, `/eah loot` open the AH log on that tab
- `/eah lootmove` moves the loot cards, `/eah loottest` shows a few
- `/eah undercut 1s` sets how far under the cheapest auction to price: `1c`, `50c`, `1g`, `5%`, or `0` to match it
- `/eah get` lists every setting; `/eah <setting> <value>` changes one (for example `/eah duration 24`)
- `/eah search <words>` finds a setting
- `/eah auto off` (or `on`) stops or restarts automatic price updates
- `/eah skin off` (or `on`) turns the EverlookDB look for the auction house off or on (then `/reload`)
- `/eah debug` shows details for bug reports; `/eah feedback` shows where to report bugs and ideas

Addon authors: see [API.md](API.md).

## Coming next

Alerts when a shopping list has a match under your price.

## License

GPL-3.0-or-later (see LICENSE). Not affiliated with Blizzard Entertainment.

Disenchant odds: Enchantrix (Norganna's AddOns, GPL-2.0-or-later) and classic-db (CMaNGOS, GPL-3.0); brackets from the WoW Forever client.

Credits: stat weights from our own simulations on wowsims/forever (MIT), with the Forever Leveling BiS v0.12.0-beta model (MIT, Copyright (c) 2026 Thunder) for some levels.
