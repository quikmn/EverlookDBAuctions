# EverlookDB Auctions

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
