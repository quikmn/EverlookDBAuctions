# EverlookDB Auctions

## Unreleased

- Darker, cleaner look for the whole auction house and the addon's own panels: one palette, flat fills with 1 px borders, clear hover and selected states, larger text.
- New Selling tab: your sellable bags on the left (filter by name, favourites with right-click, hide with Shift+right-click), a post panel with quantity (Stack and All), price each, total, deposit and 12/24/48h, a price just under the cheapest auction someone else has up (or your last price, or the scan price), the live auctions for the item (click one to price under it), and your own auctions with a Cancel button each. Each item's last price, quantity and duration are remembered. One click posts once; one click cancels one auction.
- Your auctions are checked against the live auctions and marked Undercut, Lowest or Sold.
- 30-day price chart (lowest per day) for the item you're selling.
- The bag list beside the auction house is gone; the Selling tab replaces it.
- Tooltips: 30-day median next to the 30-day low, vendor price (off by default), and the price of a full stack while Shift is held.
- New Shopping tab: named lists of searches in the Advanced search language. Run a whole list in one click (results grouped under each search, with live prices), run one search, add, edit and remove searches, rename and delete lists, and import or export lists as plain text. Save in Advanced search adds the current search to the picked list. /eah run <list> runs one.
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
