# EverlookDB Auctions

## Unreleased

- Scroll bars you can use: every list (Buy, Selling, Shopping, search results), the Advanced search guide and the import box have a wider scroll bar you can grab and drag with the left mouse button, or click above or below it to jump a page. Search results had no scroll bar before. The mouse wheel works over the bar too.
- `/eah feedback` and a Feedback button in the options show a link for reporting bugs and ideas.
- The box beside the auction house is gone. Its contents are on a bar along the bottom of the auction house window instead, beside your money: which house, how many items have prices, and how old they are. The window is a little taller to make room, so the lists keep their size.
- Price updates show a progress bar with the time left, worked out from how long your last update took. The bar says when an update waits for your purchase, and shows "Prices updated" when it's done. Hover it to see how updates work.
- Update prices sits on the bar and is always there. During the 15-minute wait it shows when the next update is.
- Advanced search is a gold button on the Buy tab's search row.
- The Selling tab no longer shows a second copy of your money.
- The crafting cost box looks like part of the game now: the game's tooltip frame and fonts, item icons, lined-up columns and prices in gold, silver and copper. It sits right of the profession window's tab buttons instead of over them. A material without a price says "no AH price" in grey, with a short note under the totals, and the profit line only shows once everything has a price. Recipes that make no item (enchants) skip "Sells for".
- Shopping list from a recipe: the Shopping list button in the crafting box lists the recipe's materials with how many you have and how many to buy, ticked when you have too few. Change an amount or the number of crafts, then Create list saves the ticked ones as a list named after the recipe in the auction house's Shopping tab. Press Run beside an item there to search for it. Making the list again for the same recipe updates it.
- Shopping lists show how many to buy beside each search made from a recipe, and in the results.

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
