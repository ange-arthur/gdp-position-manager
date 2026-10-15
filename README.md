# GDP — Gestionnaire De Positions for MetaTrader 5

A complete position manager for discretionary traders, delivered as **one MQL5 source file** with no
external dependency. It sizes the position for the risk you choose (fees included), places the order
from the chart, manages open positions, keeps the account's daily / weekly / monthly results, and
journals every trade with its reasons and a screenshot.

**It never trades on its own.** There is no signal, no detection, no alert: every order is a click by
the trader. GDP removes the arithmetic and the bookkeeping, not the decision.

> Interface available in French and English (`GDP_Language`).

## What it does

| Module | Details |
|---|---|
| **Fee-inclusive position sizing** | Iterative lot calculation that converges on the exact loss at stop including commission, swap and spread; margin guard; capped target risk. Commission can be auto-detected per symbol or set per lot (Forex / CFD). |
| **Reward / risk, three ways** | Gross RR, RR net of fees, and RR adjusted for volatility (ATR above a threshold is converted into an expected slippage). |
| **Order placement** | Market or pending, from draggable Entry / Stop / Target lines on the chart. Default levels are derived from the current ATR so there is always something to drag. |
| **Open positions panel** | Move to break-even (plus fees), close one, close all; manages every position of the symbol or only GDP's own (`GDP_ManageOnlyOwn`). |
| **Results (Bilan)** | Day / week / month per instrument from the account history: profit, commission, swap. Day boundary configurable in server time. Movable panel, refreshed automatically. |
| **Trade journal** | At each order: free-text reasons, up to 8 clickable tags (structure, liquidity, FVG, order block, retest, session, news, counter-trend by default), a screenshot of the setup (BMP or PNG), stored as CSV under `MQL5\Files\GDP_Journal`. A review panel lets you re-read every entry with its image without leaving the chart. |
| **Interface** | Movable panels, compact / advanced mode, single colour palette, status line instead of pop-up alerts, bilingual. |

## Install

1. Copy `GDP.mq5` into `<MetaTrader 5 data folder>\MQL5\Experts\`.
2. Open it in MetaEditor and compile (F7) — 0 errors, 0 warnings — or use the command line:
   `metaeditor64.exe /compile:"MQL5\Experts\GDP.mq5" /log`.
3. Drag **GDP** onto a chart and allow algorithmic trading for that chart (needed to send your orders; GDP still never opens anything by itself).

## Inputs

| Group | Input | Default | Meaning |
|---|---|---|---|
| Risk & sizing | `GDP_RiskPercent` | 0.25 | Default risk per trade, % of balance |
| | `GDP_IncludeAllCosts` | true | Include fees in the lot calculation |
| | `GDP_ShowCalculations` | false | Detailed calculation logs in the Experts journal |
| Commission | `GDP_UseCommission` | true | Take commission into account |
| | `GDP_AutoDetectCommission` | false | Guess the commission from the symbol |
| | `GDP_CommissionPerLot` | 7.0 | Forex commission per lot, round trip, $ |
| | `GDP_CFDCommissionPerLot` | 0.0 | CFD / index commission per lot, $ |
| Volatility | `GDP_ShowVolatility` | true | Show Vol $ and RR Vol |
| | `GDP_ATRPeriod` | 14 | ATR period |
| | `GDP_MaxATRPips` | 50.0 | ATR (pips) above which slippage is estimated |
| | `GDP_VolSlippageFactor` | 0.10 | Estimated slippage per ATR pip above the threshold |
| Execution | `GDP_MagicNumber` | 26082501 | Magic number of GDP orders |
| | `GDP_ManageOnlyOwn` | false | true = manage GDP positions only |
| | `GDP_Deviation` | 20 | Max deviation (points) on market orders |
| Results | `GDP_DayResetHour` | 0 | Server hour that starts the trading day |
| Journal | `GDP_JournalEnabled` | true | Journal placed orders |
| | `GDP_SnapshotOnOrder` | true | Capture the setup when recording |
| | `GDP_SnapshotWidth` / `Height` | 760 / 420 | Snapshot size in pixels |
| | `GDP_SnapshotAsBMP` | true | BMP (readable in the review panel) or PNG (lighter) |
| | `GDP_JournalTags` | 8 tags | Clickable reasons, comma-separated |
| Default levels | `GDP_DefaultSLPips` | 0.0 | Stop distance at start (0 = current ATR) |
| | `GDP_DefaultRR` | 3.0 | Target at start = RR × stop distance |
| Interface | `GDP_Language` | FR | Interface language (FR / EN) |
| | `GDP_AdvancedOnStart` | false | Show the advanced block at start |
| | `GDP_PanelX` / `GDP_PanelY` | 20 / 20 | Panel position |
| | `GDP_LinesOnStart` | true | Entry / SL / TP lines visible at start |

## Design notes

- **Single file on purpose.** Traders install tools by dropping one file; every `#include` is a support ticket. The only dependency is the standard `Trade\Trade.mqh`.
- **Sizing converges, it does not approximate.** The lot is iterated until the loss at stop, fees included, matches the target risk within the broker's lot step, then clamped by margin.
- **Text at the point of use.** Both languages are written where the string is used (`GDP_T(fr, en)`), so a missing translation cannot exist.
- **Journal first.** The review panel exists because a trade you cannot re-read with its screenshot is a trade you cannot learn from.

## Status

Version 1.00, ~3,400 lines, compiles with 0 errors / 0 warnings in the current MetaEditor. Tested on a demo account. Use at your own risk; this is a tool, not advice.

## License

[PolyForm Noncommercial 1.0.0](LICENSE). Free to use, study and modify for personal and other non-commercial purposes. Commercial use, including resale or inclusion in a paid product, requires written permission from the author (adoua.arthur@gmail.com).
