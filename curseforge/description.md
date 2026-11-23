EverlookDB Auctions

Auction house prices, advanced search and quick selling for WoW Forever, from the makers of everlookdb.com.

FEATURES

Full scan  
One button beside the auction house reads every auction at once. The server allows this about every 15 minutes, and the addon does it for you when you open the auction house.

Searches count too  
Prices from your normal auction house searches are saved as well, no scan needed.

Prices in tooltips  
Every item tooltip shows the lowest buyout, how many are up, how old that price is, and the lowest price in the last 30 days.

Disenchant preview  
Gear tooltips show what the item disenchants into, like "Strange Dust 1-2 (75%)", with each material's worth at your auction house and the total, green when disenchanting pays more than selling. The Disenchanting page (/eah de) lists the gear in your bags with what each piece gives: click one to preview it and disenchant it with one click.

Advanced search  
Search your last full scan with the same query language as everlookdb.com, including things the normal search can't do: stats, random-stat versions ("of the Bear"), slot, item level, required level and price. For example:  
slot is trinket and price lt 5g | sort by price  
items | where sta ge 10 and reqlevel le 40 | top 20 by sta  
slot is onehand and enchant is "Fiery Weapon"  
Find gear other players already enchanted with `enchant is`, `enchant like "*crusader*"` or `has enchant`.  
Click a result to jump to it on the auction house and buy it as usual.

Fast selling  
Put an item in the sell frame and the price is set just under the cheapest auction someone else has up (1 silver by default). Your own auctions are matched, never undercut. If nobody is selling it, the typical price from your last scan is used. A list beside the auction house shows everything in your bags you can sell, with prices: click one, check the price, press Post.

Shopping lists, and buying a whole list  
Paste a list of what you want, one item per line ("60 Light Leather", "Light Leather x60", item links...), and it becomes a shopping list. Press Buy this list at the auction house: it asks "Buy 60 Light Leather?", shows the cheapest way to get them and what that costs, and buys when you press Buy. Then the next item, until the list is done. It warns you when a price is far above the usual one or fewer are listed than you want, and it takes off what you already have. Add "max 25s" to a line to never pay more than that for one. EverlookDB Crafting and the leveling guides on everlookdb.com can send their shopping lists here too.

A cleaner auction house  
A darker, flatter look for the auction house window. Turn it off with /eah skin off.

Per realm and per house  
Prices are kept separately for each realm and each auction house: Alliance, Horde, and the neutral houses in Booty Bay, Gadgetzan and Everlook.

LIVE PRICES FOR EVERYONE (OPTIONAL)  
With the free EverlookDB Uploader app (Windows and Mac), your scans also fill in live auction prices on everlookdb.com for everyone. How to set it up: https://everlookdb.com/help.html

PRIVACY  
Sellers, bidders and other players are never saved. No account, character or realm names are ever sent.

COMMANDS  
/eah - what's saved, and help  
/eah scan - full scan while the auction house is open  
/eah import - paste a list of items to buy  
/eah buy [list] - buy a shopping list item by item  
/eah undercut 1s - how far under the cheapest auction to price: 50c, 1g, 5%, or 0 to match it  
/eah auto off (or on) - stop or restart the automatic full scan  
/eah skin off (or on) - turn the auction house look off or on (then /reload)

Source code: https://github.com/quikmn/EverlookDBAuctions (GPL-3.0)  
Not affiliated with Blizzard Entertainment.
