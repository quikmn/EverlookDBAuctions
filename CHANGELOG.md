# EverlookDB Auctions

## Unreleased

- The settings window has a search box at the top: type to find any setting.

## v0.9.0 (2026-11-17)

- Full scans for EverlookDB.com are kept for 7 days instead of only the newest 4, so none are lost when they can't be uploaded for a while (up to 60 scans, about 20 MB). Only the newest scan of each auction house is kept as it was; older ones are packed into a compressed line of text, about a quarter of the size.
- The price bar says when scans wait to be saved: the game only writes them to disk at /reload, logout or a character switch, so after half an hour it shows "3 scans waiting to upload · /reload saves them". /eah status lists them too, and how many scans are kept.

## v0.8.0 (2026-11-17)

- The AH price in tooltips now updates when Quick sell or Buy looks an item up, so it shows the lowest price just seen instead of the last full scan (which could be half an hour old). The 30-day low counts it too.
- Advanced search: `source is vendor` now finds every item a vendor sells, also ones you can get other ways too (it only found items whose only way was a vendor), as on EverlookDB.com. `is`, `has`, `in` and `is not` compare whole ways, so `source has drop` no longer finds world drops (`source is "world drop"` does). The guide lists all 13 ways; `from` is another word for source, `worlddrop` means world drop and `profession` means crafted, and a way that isn't one (`source is trainer`) says which ways there are.
- The item data covers more ways to get an item: fishing, herbalism, mining, object, world drop, container and disenchant are new.
- Quick sell: when a vendor pays exactly what the auction house gets you after its cut, the Sells to vendor box says so instead of "pays more than the AH".
- Quick sell: a long item name beside the Sells to vendor and 30-day low boxes steps down a font size or two before it is cut off.
- Price bar: the waiting line is short enough to read whole ("Asking the server for every auction… 0:42 · usually within a minute"), a line that would still be cut off drops one font size, and after every auction is read it says it is loading item details instead of sitting at "read 45,000 of 45,000".
- /eah status: an update cut off by a reload or logout shows in the update log too.
- Advanced search: a tooltip search next to a cheaper condition (`has "fire damage" and slot is trinket`) reads only the tooltips of items the other condition leaves open, so the first such search over a whole scan no longer stalls the game while it reads every tooltip.
- Fixed a Lua error when hovering a button whose tooltip had nothing to say (for example Buy with nothing picked).

- Advanced search finds what an item does, like EverlookDB.com: `effect` holds every Equip:, Use: and Chance on hit: line (`slot is feet and effect has "speed"`, `effect has "chance on hit" and category is Weapon top 10 by dps`), and `text` everything on the item's tooltip: name, stats, binds, effects, set bonuses, flavour text. `has` without a column searches the tooltip: `has "fire damage" and slot is trinket`, also after and, or, not and (, and with `has any (a, b)`. A quoted word on its own still searches names. The guide lists the new columns with examples.
- Effect lines come with the addon (from EverlookDB.com, English) so effect searches need nothing from the game; the tooltip text is read from the game once per item while Advanced search is open and kept until you log out. On a non-English client effect lines are read from the game's tooltips too, so they are in your language.

## v0.7.0 (2026-11-17)

- Quick sell's post panel is sectioned into three bands with one look: the item on a raised strip with two matching stat blocks (Sells to vendor, 30-day low with its chart under it); Your auction as a two-column grid (Quantity and Unit price left, Duration and Undercut by right, labels lined up with their boxes, where the price comes from right under it); and a summary strip with Deposit, Total price and You get (after the AH cut) as three equal blocks beside Post. Big amounts shrink to fit instead of being cut off; a long item name ends in "..." (its tooltip has all of it).
- Quick sell: hovering the picked item's icon or name shows its tooltip; a big "Sells to vendor" box next to the 30-day low shows what a vendor pays and whether the auction house pays more after its cut.

- Tab text stays in the middle of the tab when the tab is selected (it dropped to the bottom edge).

- Price updates: the server allows one about every 15 minutes and counts every request, answered or not; Try again now waits those 15 minutes instead of 1 (asking sooner was ignored, so one cut-off update led to "no answer" after "no answer").
- The price bar no longer shows a made-up percentage while waiting: it says it is asking the server and for how long, then counts the auctions actually read.
- /eah status lists the last price updates and how each ended.
- Your money at the bottom left: the whole box, gold edge included, is now tall enough for the coins.

- Blizzard's Cancel Auction button no longer sits on top of the price bar's button: Blizzard's Auctions and Sell views now end above the bar.
- Quick sell, Shopping and Advanced search are washed in their own colour (green, violet, blue) with a thicker coloured border and a coloured window title, so you always see where you are.

- `/eah` opens a real settings window in the same look as Lattice and the other EverlookDB addons (it is also in the game's Settings under AddOns). Every setting is a command too: `/eah settings` lists them and `/eah duration 24`, `/eah tipvendor on` or `/eah skin off` changes one, says so in chat and updates the open window. `/eah undercut` updates the open window and Quick sell's price as well.
- Quick sell and Shopping tabs are as wide as Blizzard's tabs, so their names no longer run to the edges, and the window's title says where you are (Quick sell, Shopping lists) instead of keeping the last Blizzard tab's title.
- Closing the auction house with Quick sell or Shopping open no longer leaves the next visit with no tab selected.
- The bar says why the last price update didn't finish: no answer from the server, an empty list, the auction house closed, or a reload. It used to blame a reload every time.
- Quick sell: "Usual price at the last full scan" (was "Typical"); what you get after the cut has its own line and no longer runs off the panel; the 30-day strip shows the low (the median and highest are in its tooltip) so it isn't cut off; a post or cancel the auction house doesn't answer says so; Your auctions says it is asking instead of "You have no auctions up" until the auction house answers.
- Shopping: a list's new name is kept when you click elsewhere (it was only kept with Enter, so New list, type a name, click Add a search lost it); Escape puts the old name back. List names show `|` as typed.

- Quick sell shows what you actually get when it sells: the total minus the auction house's cut (5%, or 15% at the neutral houses), with the deposit back. The vendor and disenchant comparisons and the crafting box's profit use the same cut.
- Each place has its own colour so you can tell where you are: Advanced search and its buy panel blue, Quick sell green, Shopping violet, the price-update bar cyan-grey. It shows in the panel's border, its title, its tab, its section headers and the box you're typing in. Gold stays for the one main action (Buy, Post, Search, New list); Blizzard's own views keep their look.
- The bar's Update prices / Try again is a small quiet button in the bar's colour, and "the last price update was cut off" is no longer alarm red: red is kept for real problems. The progress bar is in the bar's colour too.
- Quick sell's post block is laid out like Blizzard's Sell frame: Quantity with Max, Unit price in separate gold, silver and copper boxes with the coin inside each, Duration, Deposit, Total price, Post. No Suggest button: the price is set for you (the cheapest live auction minus your undercut), a click on a live auction undercuts that one, and an Undercut cheapest link brings the automatic price back after you type your own. The line under Quantity only says "Buyers can buy any amount." for stackable goods.
- Your money at the bottom left of the auction house sits inside its box again: the box is taller and the coins are centred in it.
- Quick sell (was Selling) and Shopping tabs now open when clicked: each click used to open and close the panel at once. Quick sell has a title, says how many you're selling and how, shows the undercut, takes copper prices, and warns when the deposit is more than the sale brings (on Blizzard's Sell tab too).
- One gold button per screen: Update prices and Advanced search are plain buttons now, so the main action (Buy, Post, Search) is the only gold one.
- Advanced search: a missing answer from the auction house is never shown as "sold out"; Now and Last scan columns; money like 1g 50s, slot words like cloak, quality words like blue.
- Buy panel: during Start buying only the auction it picked is bought in one click, and it only picks auctions that make at least 10s (like the list); refused or unanswered purchases say so; commodity quotes run out like Blizzard's, and one more than 5% above the listed price is refused; the status line no longer covers the list. A live look in the buy panel also updates the item's row in Advanced search.
- The Shopping tab explains itself when you have no lists yet: what lists are for, in big plain words, with a New list button in the middle.
- Clicking a search in a shopping list puts it in the box to change, and Save now changes it in place. It used to add a second copy.
- Tooltips no longer say "none up" for an item whose only auctions have bids and no buyout; they say so. "None up" and the disenchant estimate now say how old the scan or prices are.
- Random-stat gear ("of the Bear") shows the price of its own version from your last full scan. When that version wasn't in the scan, the line says the price is for any version.
- The crafting box says how old its prices are, and prices over a day old are grey. Its price columns fit prices in the thousands of gold. The recipe shopping list updates how many you have when your bags change, keeping amounts you typed.
- Tags like "vendor +1g 23s 45c" grow to fit their text instead of spilling over their neighbours. `/eah debug` lists any labels that are cut off on screen.
- `/eah` says when the options couldn't open and why. Durations in the options read 12 hours, 24 hours, 48 hours. `/eah auto on` and `off` show in the options at once.
- `/eah run <list>` says to open the auction house first when it's closed, and a list name it doesn't know gets your list names and an example.
- With automatic updates off, the button reads "Allowed in 12:34" instead of "Next update", since none starts by itself.
- Day-by-day prices older than 30 days are cut every time you log in, not only after a full scan.
- Text you type (a command, a list name, a search) shows in chat and lists exactly as typed, `|` included.
- Scroll bars you can use: every list (Buy, Selling, Shopping, search results), the Advanced search guide and the import box have a wider scroll bar you can grab and drag with the left mouse button, or click above or below it to jump a page. Search results had no scroll bar before. The mouse wheel works over the bar too.
- `/eah feedback` and a Feedback button in the options show a link for reporting bugs and ideas.
- The box beside the auction house is gone. Its contents are on a bar along the bottom of the auction house window instead, beside your money: which house, how many items have prices, and how old they are. The window is a little taller to make room, so the lists keep their size.
- Price updates show a progress bar with the time left, worked out from how long your last update took. The bar says when an update waits for your purchase, and shows "Prices updated" when it's done. Hover it to see how updates work.
- Update prices sits on the bar and is always there. During the 15-minute wait it shows when the next update is.
- Advanced search is a gold button on the Buy tab's search row.
- Advanced search has a much wider query box: it spans the whole top of the panel, two lines tall, and long searches wrap. Enter searches. The status line and the buttons sit on the row under it.
- `/eah` on its own opens the options. `/eah help` lists the commands and `/eah status` shows what's saved. A command typed wrong gets a reply with an example.
- `/eah undercut 1c` undercuts by one copper. Prices used to be rounded to whole silver, so a 1c undercut posted a whole silver lower; this auction house takes copper prices. The help line for it shows properly in chat.
- Below vendor is quick: the list is worked out from every single auction when a price update finishes, so it opens at once. It only lists auctions that make at least 10s each (name a profit in the search to see smaller ones), shows how many such auctions each item has and what they make together, and no longer checks hundreds of rows live one by one; prices are from the update, and the item you open is checked live. When the last update is over 5 minutes old and the server allows a new one, the Below vendor button starts it and the list fills when it's done.
- Start buying: on a Below vendor list the button becomes Start buying. It opens the top item with its cheapest auction under vendor price picked; one click on Buy buys it (stackable goods: Buy, then Confirm the quote, which is refused if it costs more than a vendor pays), then the next auction or item comes up. Items with nothing left under vendor price drop out, and a running total shows what you bought, its vendor value and the profit.
- You can always tell which search is active. While Advanced search is open it has a gold edge and its name at the top left ("Advanced search > item" while buying, Back goes up one level), the Advanced search button lights up and reads "Close advanced search", and Blizzard's search box, Filter and Search are dimmed and switched off. Closing it puts them back. The buy panel's Blizzard's list button is now "Show in Blizzard search".
- Live auctions are looked up the way Blizzard's own Search button does it: a search by name, then the auctions of each version the auction house lists. Random-stat gear ("of the Bear") showed "Nobody is selling this right now" while Blizzard's list had dozens; it now finds them. When the auction house doesn't answer, the panel says so and asks again instead of claiming nobody sells it, and a result is only marked sold out from a complete answer.
- The addon sends one auction house search at a time and waits while Blizzard's own search runs, so Blizzard's list button no longer comes back with "No items found". It searches the item's base name, so every version shows.
- `/eah debug` lists the addon's waiting searches and the auction house keys the buy panel used.
- Advanced search takes a search the way you'd say it, with no `|` before a step: `type has wand and reqlevel le 29 sort by price`. `sort` without a column sorts by price (`sort asc`, `sort desc`). `lvlreq` and `levelreq` mean reqlevel too. A search that's missing something says what, with an example, such as "reqlvl le what? e.g. reqlvl le 29".
- The Selling tab no longer shows a second copy of your money.
- The crafting cost box looks like part of the game now: the game's tooltip frame and fonts, item icons, lined-up columns and prices in gold, silver and copper. It sits right of the profession window's tab buttons instead of over them. A material without a price says "no AH price" in grey, with a short note under the totals, and the profit line only shows once everything has a price. Recipes that make no item (enchants) skip "Sells for".
- Shopping list from a recipe: the Shopping list button in the crafting box lists the recipe's materials with how many you have and how many to buy, ticked when you have too few. Change an amount or the number of crafts, then Create list saves the ticked ones as a list named after the recipe in the auction house's Shopping tab. Press Run beside an item there to search for it. Making the list again for the same recipe updates it.
- Shopping lists show how many to buy beside each search made from a recipe, and in the results.
- Below vendor price: auctions cheaper than what a vendor pays for the item, so you can buy them and sell them to a vendor. The Below vendor button in Advanced search (or the search `belowvendor`, or `price lt vendor`) lists them from your last price update with the profit each and for a full stack, biggest profit first. Vendors take no cut. Advanced search results, the buy panel and Blizzard's own lists mark such auctions in green. Quest items and items vendors don't buy never count.

## v0.6.0 (2026-11-14)

- Crafting cost beside the profession window, for the recipe you pick. It shows each material with its lowest auction price, what all the materials cost, what the result sells for (and what disenchanting it is worth, for gear), and your profit after the 5% auction house cut. It uses your saved prices, so it works anywhere. Materials without a price are counted and shown. You can turn it off in the options.

## v0.5.0 (2026-11-14)

- Your auctions: a new button cancels your next undercut auction. Each click cancels one auction, and the next click waits for the server's answer. The button shows how many of your auctions are undercut, and its tooltip shows what the next cancel costs.
- Selling tab: when you post the last of an item, the next item in your list is picked, ready to post.
- Selling tab: when the cheapest auction is a single one far below the usual price (often bait), the price line tells you the usual price.
- Shopping lists: each search shows what one of each result costs at the lowest price, which is handy for lists of materials.

## v0.4.0 (2026-11-14)

- Buttons now look like what they do. The main action on each panel (Post, Buy, Search, Run list) is solid gold. Cancel, Remove and Delete are red. Everything else is a quiet grey.
- Hover and press fade in smoothly instead of snapping. Buttons and header bands have a slight raised look.
- A focused text box gets a soft gold ring. So does an armed Confirm button, so you can see it is waiting for your second click.
- Your auctions: Undercut, Lowest and Sold are shown as small coloured tags.
- Selling tab: the total is larger. Hover the 30-day chart to see each day's lowest price.
- Grey labels are a little brighter, so small text is easier to read.
- Blizzard's own main buttons (Search, Buyout, Post) get the same gold look when the EverlookDB look is on.

## v0.3.0 (2026-11-14)

- Disenchant value in tooltips: for gear that can be disenchanted, what its materials are worth on your auction house, from each material's chance (classic-db) and its lowest price. You can turn it off in the options.
- Selling tab: the item line shows what disenchanting is worth. A red line warns you when a vendor, or disenchanting, would pay more than your price brings in after the auction house's 5% cut.
- Posting several of one item (they go up as single auctions, one after another) shows "Posting 2 / 5". Post stays off until the last one is up, so a second click can't post them twice.
- When the server asks you to confirm a post, the Selling tab's own Confirm shows right away.
- Your auctions: the price of a commodity auction is read the right way, learned from your own posts.
- For addon authors: EverlookDBAuctionsAPI, a small read-only API with price, 30-day history and disenchant value (see the README).

## v0.2.1 (2026-11-14)

- The full scan now steps aside for you: while a buy, bid, post or cancel waits for the server (and for 4 seconds after), the scan pauses. Before, a big scan could make the buyout popup spin for a long time.
- The scan asks the server for item details a few at a time instead of thousands at once.

## v0.2.0 (2026-11-14)

- Darker, cleaner look for the whole auction house and the addon's own panels: one palette, flat fills with 1 px borders, clear hover and selected states, larger text.
- New Selling tab: your sellable bags on the left (filter by name, favourites with right-click, hide with Shift+right-click), a post panel with quantity (Stack and All), price each, total, deposit and 12/24/48h, a price just under the cheapest auction someone else has up (or your last price, or the scan price), the live auctions for the item (click one to price under it), and your own auctions with a Cancel button each. Each item's last price, quantity and duration are remembered. One click posts once; one click cancels one auction.
- Your auctions are checked against the live auctions and marked Undercut, Lowest or Sold.
- 30-day price chart (lowest per day) for the item you're selling.
- The bag list beside the auction house is gone; the Selling tab replaces it.
- Tooltips: 30-day median next to the 30-day low, vendor price (off by default), and the price of a full stack while Shift is held.
- New Shopping tab: named lists of searches in the Advanced search language. Run a whole list in one click (results grouped under each search, with live prices), run one search, add, edit and remove searches, rename and delete lists, and import or export lists as plain text. Save in Advanced search adds the current search to the picked list. /eah run <list> runs one.
- Buy from Advanced search and shopping lists: click a result for its live auctions. Items: pick one, Buy, then Confirm. Commodities: type how many, Buy, the server quotes the total, then Confirm. Two clicks per purchase.
- Options in the game's Settings under AddOns (or /eah options): undercut, default duration, which tooltip lines to show, automatic full scan, and the auction house look.

## [v0.1.0](https://github.com/quikmn/EverlookDBAuctions/tree/v0.1.0) (2026-11-13)
[Full Changelog](https://github.com/quikmn/EverlookDBAuctions/commits/v0.1.0) [Previous Releases](https://github.com/quikmn/EverlookDBAuctions/releases)

- /eah test: reload after every full scan so the scan is written to disk at once  
    Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>  
- Random stats: use the first bonus ID when the suffix field is empty and the name differs; save link samples and the most-unlinked items; re-request item loads each retry round  
    Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>  
- Full scan: record how many auctions still lack a link after each retry round  
    Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>  
- Full scan: load items whose link wasn't ready and read them again (up to 3 rounds), so random suffixes are known  
    Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>  
- README: /eah auto  
    Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>  
- License: GPL-3.0-or-later  
    Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>  
- Automatic full scan when opening the auction house (at most every 15 minutes; /eah auto off)  
    Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>  
- Full scans keep region, realm, auction house, server time and per item version: low/p10/median price, quantity, auctions, bids, time left  
    Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>  
- Roomier panel, thousands separators  
    Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>  
- EverlookDB Auctions: full scans, prices from searches, tooltip prices  
    Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>  
