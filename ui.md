# UI decisions (indicator UI agent)

Format: *topic* — decision — why. Spec: 02 = `02_PROMPT_Footprint_Indicator.md` (§1, §3, §6–10, §12). The engine files are untouched.

## Files and structure

- **Files** — `Indicators\OrderFlowFP\FootprintChart.mq5` (inputs, events, scheduling, buffers, alerts) and `Include\OrderFlowFP\UI\{FPTheme, FPCanvas, FPLayout, FPTrades, FPAnalyst, FPPanels, FPRenderer}.mqh`. Two files beyond 02 §3: `FPCanvas.mqh` (CCanvas subclass: font cache + primitives) and `FPTrades.mqh` (read-only trade overlay data). Test tooling: `Scripts\OrderFlowFP\FPShot.mq5` + `tools\mt5_screenshot.ps1`. — Keep each file single-purpose.
- **Include chain** — FPTheme ← FPCanvas ← FPLayout (includes `..\FPEngine.mqh`) ← FPAnalyst ← FPPanels; FPLayout + FPTrades ← FPRenderer. UI global names use `FPUI*`, `CFP<Ui>` or `FPB_*`/`FPT_*`/`FPTONE_*`. They never reuse the engine helpers or the EA's `FPTfName`. — The EA never includes UI (EA_ARCHITECTURE §3).
- **Engine API used** — Only the public contract: `Init, LoadStep, Update, PopClosedBar, Total, At, ByTime, ActiveSource, RowSize, PriceToRow, RowToPrice, SessionStart, SessionProfile, RangeProfile, SessionVWAP, Zones, Prints, LastError`, plus `CFPAnalytics::FindStacks`. `At()` pointers are used only inside one event handler and never stored.

## Scheduling and performance

- **Timer step** — `EventSetMillisecondTimer(50)`. Each step calls `LoadStep(budget)`, also after the history is ready, because `LoadStep` contains the reconnect/nodata retry and then calls `Update()`. Then: pop closed bars, periodic work, and a redraw when dirty and ≥ `InpRedrawMs` since the last draw (250 ms while loading). When a redraw is due, the load budget drops to 15 ms. — Spec §6; keeps a step near 50 ms.
- **Periodic work** — Studies and flow stats every 1 s; Signal Meter every 2 s; book every 2 s, or 200 ms after `OnBookEvent`; Chart Analyst every `InpAnalystRefreshSec` and on every closed bar; session POC/VWAP/buy-sell on every closed bar (every 1 s while loading); trades poll every 500 ms. A dirty frame is forced once per second for the countdown and "Updated Ns ago".
- **OnCalculate** — `Update()` plus the data-window buffers. In the tester, the whole step runs from `OnCalculate`. The non-visual tester creates no canvas and changes no chart properties.
- **Measured** — Draw averages: 4.1–4.8 ms at 1857×978 (s=1.0, side panels on, 15 bars, 400 frames, market open); 8.4 ms at 2487×1408 (s=1.5); 3.8–4.6 ms without side panels (25 bars). Split at 1857×978: footprint 1.5–2.0, table+chrome 0.7, side panels 1.1–1.4, `Canvas.Update` 0.8–1.0 ms. The max frame was 8–35 ms. Logged every 100 frames by `OrderFlowFP UI: draw avg ...`.
- **Loading responsiveness** — Measured: history ready after 14–18 s (≈444 bars); timer steps while loading average 45–55 ms, and the UI part is ≈0–6 ms of that. The worst step is always inside the engine's `LoadStep`. Usually 66–140 ms; on cold starts 341 ms and 977 ms were seen once each, when the first tick files are read. It is logged as `history ready after ... | worst step: ...`.
- **Text** — `CCanvas::TextOut` calls `TextSetFont` on every call. `CFPCanvas` registers fonts once and switches only on an id change. Footprint cells go through `CFPTextBatch`, which draws grouped by font, so there are ~6 font switches per frame. Earlier runs measured 7.5–9 ms averages, but those ran while the other agent's tester passes loaded the CPU.
- **Fonts** — Positive `TextSetFont` sizes behave as cell heights, so Segoe UI renders ~20 % smaller than its nominal point size. The cell numbers use the 02 formula `px = round(pt·96/72·s)`. The UI fonts were calibrated against the reference frames: buttons 8.8 pt, labels 9.5 pt, small 8.5 pt, titles 10.5 pt, tabs 7.5 pt semibold.
- **Scale** — `s = InpUIScalePct/100 × TERMINAL_SCREEN_DPI/96`, applied to all geometry. The auto-hide rule is `W < 1500·s`. On this 150 % DPI screen, the docked default chart (2146×790 px) auto-hides the side panels, while a 2487×1408 chart shows them.

## Layout and look

- **Layout** — 02 §7 at scale `s`. The side column is 690·s wide with 5·s gaps. Meter, VP and T&S keep their 180/180/185 widths, and the remaining width goes to the Chart Analyst and the DOM. The top block is min(470·s, 49 % of the column). The table gets a 4 px bottom margin. A collapsed table keeps its header row (times, countdown, `+`). Collapsed tabs give a `+` button in the header. The whole canvas is erased with `bg` each frame (`Erase`, < 1 ms).
- **Row geometry** — Row r is the bucket [r·rs, (r+1)·rs), drawn in the band [Y(r+1), Y(r)). The price labels show the bucket bottom at the band centre, as in the references. Exact prices (trade levels, S&D edges) use Y(p/rs). The price tag sits at the band centre of the last price's bucket.
- **Price digits** — Symbol digits (`4010.400` for 3-digit XAUUSD, `4394.0` for a 1-digit feed). — This matches all the references; a row-size-based digit count would not.
- **Price tag label** — `BID` (QUOTE/BID), `MID` (QUOTE/MID), `LAST` (trade sources). — 02 §8.1 says "ASK (or BID in BID basis)", but a trade price is not an ask.
- **Orange accent** — #D96B00 (217,107,0), the value the spec notes was sampled from the video, instead of the table's (230,115,10).
- **Light theme** — The countdown green and yellow are darker on white. Heat cells darker than luma 0.40 get light text, e.g. the dark-grey bear colour at full heat. — Readability.
- **Summary table** — Full integers (no `k`) below 1 M, as in reference 03. Heat colours follow 02 §8.7 exactly. Cum Delta is blank until `HistoryReady()` and dimmed when `!cvdValid`.
- **Compact mode** (zoom < `InpMinCellHeight`) — Columns narrow in proportion to the zoom (min 3 px), so zooming out shows more bars. The wick is 3·s px and the body is ⅔ of the column.
- **Per-bar POC outline** — One fuchsia box around each number, as in reference 11.
- **Tabs** — Letter-spaced. When a label does not fit, the spacing is dropped first, then a short label is used (e.g. `VP CANDLE`). Only MINIMALIST is clickable; `InpStyle` ≠ MINIMALIST logs a note and draws Minimalist. FUNDAMENTALS (a MAY item) is greyed.
- **Status text** — `source | row | bars or loading n/m | draw ms | n bars back` sits in the free part of the tab row, or at the bottom-left of the plot if it does not fit. The canvas object's `OBJPROP_TEXT` carries a machine-readable status (`ready=1 frames=… avgms=…`) for FPShot. The tooltip is disabled.

## Studies, Signal Meter, Chart Analyst (display only)

- **MA type** — EMA on close for every MA: trend boxes (MA1 > MA2 on the last closed bar of M5/M15/H1/H4/D1), Analyst and Meter. — 02 does not specify the MA type.
- **Meter votes** — As in 02 §8.8e, on the last closed chart bar. These points are our own choices:
  - Cum Delta vote = sign of Σdelta over the last 5 closed ok bars; it counts as flat if |Σ| < 2 % of their volume. This works across session boundaries.
  - Vol B/S = (session closed bars + forming bar) buy/sell.
  - POC distance = close − POC-row mid, in `SYMBOL_TRADE_TICK_SIZE` ticks.
  - VWAP and POC are `n/a` (vote 0) before `HistoryReady()`.
  - The TREND multiplier is 1.0.
- **Analyst** — The exact 02 templates. These points are our own choices:
  - T&S p = size-weighted buy share of the last 200 `Prints()`; split prints count half.
  - DOM r = Σ volume of the 10 nearest bid book levels / the 10 nearest ask levels.
  - Factor classes: trend is always bull or bear; HTF is neutral when mixed; DOM is neutral without a book; T&S/volume are neutral inside their bands; order flow is "Buyers/Sellers in control" = bull/bear.
  - Setup line 1 uses the current price.
  - BULLISH/BEARISH BIAS lines use the bull/bear colour (reference 09); the other summary lines are yellow.
  - Missing data gives an `n/a` sentence, never a guessed value.
- **Book** — `MarketBookAdd` is used only when `InpUseMarketBook` is set and outside the tester. A non-empty `MarketBookGet` counts as "book available"; otherwise the DOM shows `NO BOOK - FOOTPRINT ONLY` and the Analyst shows the no-depth sentence. Book volumes are aggregated into footprint rows.

## Panels and overlays

- **T&S** — `Prints(2000)`, aggregated into same side + price + second. Auto bold size = 95th percentile of the last 500 prints. It is off when all sizes are equal (QUOTE mode, every print = 1).
- **VP Total** — BARS uses `RangeProfile(0, N−1)`, with the forming bar included. SESSION uses all held bars of the current session plus the forming bar. Refreshed every 1 s. VAH/VAL come from the engine (`valueAreaPct`).
- **Mini session chart** — `CopyRates(M1)` since the session start, refreshed every 2 s. The caption's "Local" window is the session start and end shifted by TimeLocal − TimeTradeServer, rounded to 15 min.
- **Stacked zones** — `Zones(includeFilled = InpShowFilledZones)`. A zone spans from the origin bar to min(origin + `InpStackZoneBars`, fill bar). An open zone running past the newest bar extends to the price scale. Fills are pre-blended against `bg` (overlaps: the later zone wins).
- **S&D zones** — Built from the chart's OHLC/tick volume (`CopyRates`), recomputed once per chart bar.
  - Pivots are strict. The volume SMA includes the pivot bar. ATR = simple mean of TR.
  - The role flips both ways on a close beyond the far edge.
  - "Middle touched" (grey, takes precedence over the role colour) is checked from pivot + swing + 1 onward.
  - A zone starts at its pivot column, or at the panel's left edge if that bar is not held.
- **Data-window buffers** — Filled for every held engine bar via `iBarShift` (exact). Fully refilled when the history progress changes, otherwise only shifts 0–2 are refilled. `FP POC price` = POC row bottom (as in the dump). `FP Buy/SellStack rows` = Σ `rowsCount` of `FindStacks` per side. `FP CumDelta` is EMPTY while `!cvdValid`. Pending/nodata bars and bars the engine does not hold are EMPTY.

## Interaction

- **Mouse** — Wheel over the footprint zooms ±1 per notch (6–40). Shift+wheel scrolls 3 bars per notch. Left-drag in the plot pans both axes: horizontally by bars, vertically by rows (this turns vertical auto-follow off). A drag suppresses the click that follows it.
- **Buttons** — ZOOM IN/OUT ±2. UP/DOWN move 80·s px and turn vertical auto-follow off. LIVE, Home and RESET turn it back on. RESET = default zoom + live + re-centre, and it re-`Init`s the engine when nodata bars exist (02 §5.5: "retry nodata on RESET"; the engine has no public retry call). SIDE PANELS toggles the effective state and forces it.
- **Keyboard** — `T` cycles the 16 accent themes and `L` toggles Dark/Light (02 §12 M5). ←/→ scroll bars, ↑/↓ move vertically, +/− zoom. `CHART_KEYBOARD_CONTROL` is set to false so the hidden native chart does not scroll; it is restored on deinit.
- **Scrolled view** — Anchored to the newest visible bar's time, so new bars do not shift it. While scrolled, vertical auto-follow centres on the visible bars.
- **Test hooks** — The custom chart events `7701` (lparam = button id) and `7702` (lparam = key code) behave exactly like a click or a key press. FPShot uses them to check the buttons and keys automatically.

## Chart and EA coexistence

- **Chart properties** — Saved at init, then set, then restored on deinit: `CHART_FOREGROUND, SHOW_GRID, SHOW_OHLC, SHOW_ONE_CLICK, MOUSE_SCROLL, EVENT_MOUSE_MOVE, EVENT_MOUSE_WHEEL, KEYBOARD_CONTROL` (+ `CHART_SHOW` only with `InpHideNativeChart`). There is one `OBJ_BITMAP_LABEL` named `OFPFC_<n>` (unique per instance), and it is deleted on deinit. Timers are killed and handles and the book are released.
- **EA attach** — Verified with FPShot: `iCustom(_Symbol,_Period,"OrderFlowFP\\FootprintChart")` with default inputs + `ChartIndicatorAdd(0,0,h)` from a program on the same chart. The canvas appears on that chart, the indicator gets ready, and all 8 buffers read back through the handle (CumDelta chains bar to bar).
- **Two instances on one chart** — They work, but property restore is order-dependent: the first instance removed restores the originals while the second is still running. — Documented, not handled.

## Trade overlay (user requirement, read-only)

- **Data** — Polled at most every 500 ms (indicators get no `OnTrade`). The signature covers positions and orders of the chart symbol (ticket, volume, SL, TP, open price), filtered by magic (`InpTradeMagic`, −1 = all), plus `HistoryDealsTotal` / last ticket since the oldest held bar. The drawing data is rebuilt when the signature changes, and on every poll while positions are open (floating P/L).
- **Closed trades** — Exit deals (`OUT`, `OUT_BY`, `INOUT`) are paired with the latest IN deal of the same `DEAL_POSITION_ID` inside the window. The magic filter applies to the IN deal, so manual or SL/TP exits of EA trades still show. P/L = profit + swap + commission of the exit deal. A partial close gives one marker per exit deal.
- **Drawing** — Entry/SL/TP lines run across the plot behind the cells: solid for positions, dashed for pending orders. Colours: BUY entry (59,130,246), SELL entry (236,72,153), SL (239,68,68), TP (34,197,94). A label at the left end shows side, lots, price, P/L and ticket. Tags on the own price scale (`BUY 0.05`, `SL`, `TP`, `BUY STOP 0.05`) are filled for positions, outlined for pendings, de-overlapped, and pinned to the scale edge when off-screen. Closed trades get an entry triangle and an exit square at bar-column/price, joined by a dashed line in the bull colour (profit) or the bear colour (loss). Open positions get an entry triangle.
- **Verification** — By code review and compile only: there were no EA trades on the account during the session, and placing orders was not allowed.

## Engine additions that would help (not made: the engine is frozen)

1. `int PendingCount() const` / `int HistoryTotal() const`. The UI now scans all held bars for the loading progress, which is cheap but O(bars).
2. `void RetryNoData()`. The UI's RESET currently re-`Init`s the whole engine to retry nodata bars.
3. LoadStep budget overshoot on cold start: one per-bar `CopyTicksRange` can take 0.1–1 s when tick files are first read. A finer-grained check, or deferring `TickAfter()`'s extra `CopyTicks` to the next step, would keep a step under the 40 ms budget.
