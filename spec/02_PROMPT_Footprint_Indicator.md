# BUILD PROMPT — MT5 Footprint & Order-Flow Workspace ("Minimalist" style) — MQL5 indicator

> **How to use this prompt (for the human):** paste everything below the line into your AI coding tool. Claude Code or Codex can work directly inside your MT5 data folder; ChatGPT works too, but you compile yourself. If the tool accepts images, also attach the files in `reference/` (listed in §1.2). Build milestone by milestone and do not let the AI jump ahead (§12). The trading EA prompt (`03_PROMPT_Footprint_EA.md`) reuses the engine built here.

---

## 0. Your role and mission

You are a senior MQL5 engineer. You are expert in MetaTrader 5 tick data (`CopyTicksRange`, `MqlTick` flags), high-performance `CCanvas` rendering and order-flow analytics.

Build **OrderFlowFP**: an MT5 indicator that turns a chart into a full-window **footprint and order-flow workspace**. It must reproduce the look and behaviour specified below. Build it on a **reusable engine library** that a trading Expert Advisor will later compile unchanged.

Quality bar:
- The code compiles with **0 errors and 0 warnings**.
- It never shows fabricated data.
- It stays responsive on a live chart.
- Its numbers are deterministic. The same ticks must always give the same footprint, in the indicator, the EA and a dump script.

## 1. Target look and reference images

### 1.1 Summary of the target (memorise this)

1. The whole chart client area is replaced by a custom-drawn, opaque workspace. Native candles are not visible.
2. Left/main area: **footprint columns in "Minimalist" style**. Every bar is a vertical stack of price rows, and every row shows `SELL x BUY` as two small monospace numbers with a dim "x" between them. There is **no candle body, wick or frame**. Imbalanced numbers are bold and coloured: seller red on the left number, buyer green on the right number.
3. The footprint panel has its **own price scale** on its right edge, a current-price tag, a dashed purple **session-POC** line labelled "POC", and a **mini session chart** overlaid top-left.
4. A **summary table** (Volume / Delta / Cum Delta / Ask / Bid) sits under the bars, heat-coloured, with a bar-close countdown.
5. Top: a **header bar**, with toggle buttons, a ticker, multi-timeframe trend arrows, bias labels and view buttons. Below it, a **style-tab row** of 9 footprint styles.
6. Right column (toggleable, "SIDE PANELS"):
   - **Chart Analyst**: 9 sections of rule-generated sentences.
   - **Signal Meter**: a gauge plus 11 indicator rows.
   - **DOM ladder**, **Time & Sales** with RSI(14) and MACD minis, and a **VP Total** session/N-bar volume profile with VAH/POC/VAL.
7. Dark and Light panel themes, combined with 16 bull/bear colour themes.

### 1.2 Reference images (in `./reference/`; open them if you can read images)

| File | Shows |
|---|---|
| `01_full_workspace_dark_orange_t0020.jpg` | Whole workspace, Dark + Orange/dark-grey theme (the main target) |
| `02_minimalist_cells_closeup_dark.png` | Close-up of the cells: "sell x buy" grammar, coloured imbalances, POC line, price tag, own price scale |
| `03_summary_table_dark.png` | Summary table rows and heat colouring, countdown `03:10` |
| `04_chart_analyst_and_signal_meter.png` | Full Chart Analyst text and the Signal Meter with all rows |
| `05_dom_ladder_time_sales_vp_rsi_macd.png` | DOM ladder columns, Time & Sales, Bar Totals, RSI/MACD minis, VP Total with VAH/POC/VAL |
| `06a_header_left_and_style_tabs.png`, `06b_header_right_buttons.png` | Header and tab row |
| `07_full_workspace_dark_green_t0080.jpg` | Same layout, another theme |
| `08_light_fullwidth_no_side_panels_t0230.jpg` | Light theme, side panels off, supply/demand zones |
| `09_full_workspace_light_t0280.jpg`, `10_xauusd_light_t0350.jpg` | Light theme workspace; XAUUSD |
| `11_vendor_manual_v7_minimalist_closeup_POC_outline.png` | Optional per-bar POC outline (fuchsia boxes), a newer variant |

The numbers visible in the references come from an estimating engine. **Match the layout, typography, colours and rules, not those exact numbers.**

## 2. Scope and priorities

- **MUST:** engine (tick loading, classification, rows, bars, imbalances, stacks, POC/VA, CVD, VWAP); Minimalist rendering; own price scale; price tag; session POC line; summary table + countdown; header + tabs (Minimalist functional); zoom/up/down/reset; horizontal history scroll + LIVE; side panels (VP Total, T&S, RSI/MACD, DOM ladder, Signal Meter, Chart Analyst); Dark/Light × 16 themes; data-window buffers; dump script; unit-test script.
- **SHOULD:** mini session chart, delta bars, bar volume profile, stacked-imbalance zones, supply & demand zones, per-bar POC outline option, alerts (stack on close, delta thresholds).
- **MAY:** fundamentals (economic calendar) panel; the 8 other footprint styles (§8.5).
- **Out of scope:** any trading. This is an indicator: no `OrderSend`/`CTrade`.

Work strictly in the milestone order of §12. Each milestone must compile and run on its own before you start the next.

## 3. Deliverables and file layout

All paths are relative to the terminal's `MQL5\` data folder.

```
Include\OrderFlowFP\FPTypes.mqh          enums, structs, FPConfig, CFPBar, CFPTickSource (no chart calls)
Include\OrderFlowFP\FPClassifier.mqh     CFPClassifier  – aggressor classification cascade
Include\OrderFlowFP\FPEngine.mqh         CFPEngine – loading, bars, rows, sessions, zones, prints
Include\OrderFlowFP\FPAnalytics.mqh      CFPAnalytics  – imbalances, stacks, POC, value area, VWAP helpers
Include\OrderFlowFP\FPPresets.mqh        bucket presets per symbol + auto bucket
Include\OrderFlowFP\UI\FPTheme.mqh       themes, palettes, blending
Include\OrderFlowFP\UI\FPLayout.mqh      layout rectangles, hit-testing, scaling
Include\OrderFlowFP\UI\FPRenderer.mqh    footprint panel, price scale, overlays, summary table
Include\OrderFlowFP\UI\FPPanels.mqh      header, tabs, mini chart, VP Total, T&S, RSI/MACD, DOM, Signal Meter
Include\OrderFlowFP\UI\FPAnalyst.mqh     Chart Analyst rule engine and text layout
Indicators\OrderFlowFP\FootprintChart.mq5  the indicator (thin: inputs, events, wiring)
Scripts\OrderFlowFP\FPDumpBars.mq5       builds N bars with the engine and writes CSV (verification tool)
Scripts\OrderFlowFP\FPTests.mq5          unit tests with hand-made MqlTick arrays (prints PASS/FAIL)
DECISIONS.md (in your workspace)          every choice you make that this prompt does not fix
```

**Hard rule:** the five **engine files** (`FPTypes`, `FPClassifier`, `FPEngine`, `FPAnalytics`, `FPPresets`) must not call chart, object, canvas, indicator-buffer or indicator-handle functions (`iMA`, `iATR` …), and must not `Print` per tick. Series functions (`CopyTime`, `CopyTickVolume`, `CopyRates`, `iTime`) and `CopyTicks*` are allowed. The engine must compile unchanged into an Expert Advisor and a script. Later EA-side files (signals, trade) may use indicator handles.

## 4. Hard constraints

1. Pure MQL5. No DLLs, no web requests, no external files except CSV output from the scripts.
2. **0 errors, 0 warnings.** Use `#property strict`-equivalent hygiene: explicit casts, no unused variables, no implicit narrowing.
3. **No fabricated data.** If ticks for a bar are not available yet, show that bar as "loading", with dim text in place of its cells. Never estimate from OHLC and never use random numbers.
4. **Closed bars never change after finalisation (§5.5).** The forming bar may change.
5. **Responsiveness.** All indicators of a symbol share **one thread**, so never block:
   - history loading works in time-budgeted steps (default ≤ 40 ms per timer event);
   - `OnCalculate` returns fast (≤ 2 ms typical);
   - one full redraw takes ≤ 30 ms at 1920×1080 with 20 bars × 40 rows (measure it with `GetMicrosecondCount` and log the average every 100 frames);
   - no `Sleep`, and no busy loops.
6. Memory ≤ 200 MB with the default history depth.
7. Restore every chart property you change, and delete every object you create, in `OnDeinit`. Kill timers.
8. MQL5 language limits: no pointers to structs. Use classes for anything held by pointer. Free every `new` you allocate. Keep `ArraySetAsSeries` state explicit.

## 5. Data engine specification

### 5.1 Configuration

```mql5
enum ENUM_FP_SOURCE      { FP_SRC_AUTO=0, FP_SRC_EXCHANGE_FLAGS=1, FP_SRC_TRADE_TICKS=2, FP_SRC_QUOTE_TICKS=3 };
enum ENUM_FP_QUOTE_PRICE { FP_QP_BID=0, FP_QP_MID=1 };

struct FPConfig
{
   string              symbol;
   ENUM_TIMEFRAMES     timeframe;        // M1..D1 supported; W1/MN -> Init() fails with a clear message
   int                 bucketPoints;     // row height in points (>=1); 0 = auto (FPPresets)
   ENUM_FP_SOURCE      source;           // default FP_SRC_AUTO
   ENUM_FP_QUOTE_PRICE quotePrice;       // default FP_QP_BID (MT5 charts are bid-based)
   int                 historyBars;      // closed bars to build, default 300
   int                 sessionStartMin;  // minutes after 00:00 SERVER time, default 0
   double              imbRatio1;        // 2.0
   double              imbRatio2;        // 3.0
   double              imbRatio3;        // 4.0
   double              imbMinVolume;     // 10 (dominant side, volume units of the active source)
   int                 stackMinRows;     // 3
   double              valueAreaPct;     // 0.70
};
```

### 5.2 Choosing the volume source (AUTO)

At `Init`, sample the most recent ≤ 5000 ticks: `CopyTicks(symbol, arr, COPY_TICKS_ALL, 0, 5000)`.
- A tick is a *trade tick* **only** if `(flags & (TICK_FLAG_LAST|TICK_FLAG_VOLUME|TICK_FLAG_BUY|TICK_FLAG_SELL)) != 0`.
  - **Never infer a trade from `volume`, `volume_real` or `last`.** With `COPY_TICKS_ALL`, unchanged fields are filled with the last known values, so every quote tick carries the previous trade's volume. Counting those would double-count trades.
  - The same rule applies everywhere ticks are counted (§5.3).
- If trade ticks are ≥ 20 % of the sample **and** ≥ 80 % of them carry `TICK_FLAG_BUY` or `TICK_FLAG_SELL` → `FP_SRC_EXCHANGE_FLAGS`.
- Otherwise, if trade ticks are ≥ 20 % and their `last > 0` → `FP_SRC_TRADE_TICKS`.
- Otherwise → `FP_SRC_QUOTE_TICKS` (typical Forex/CFD, e.g. XAUUSD).

If the sample is empty, the tick base is not synchronised yet. Don't decide: retry on later `LoadStep` calls for up to 30 s, then fall back to QUOTE_TICKS with a warning.

Freeze the decision for the engine's lifetime. Print it once, e.g. `OrderFlowFP: source=QUOTE_TICKS (sample 5000, trades 0%)`, and show it in the header tooltip/status line. Document in the UI (status text) that in QUOTE mode volumes are **tick counts = relative activity**.

### 5.3 Aggressor classification cascade (`CFPClassifier`)

Process ticks strictly in time order. The classifier keeps state: `prevMid`, `prevTradePrice`, `prevSide`.

| Source | Which ticks count | Size | Row price | Side |
|---|---|---|---|---|
| EXCHANGE_FLAGS | trade ticks only | `volume_real>0 ? volume_real : (double)volume` | `last` | `TICK_FLAG_BUY` → BUY; `TICK_FLAG_SELL` → SELL; both/none → *quote rule*, then *tick rule* |
| TRADE_TICKS | trade ticks only | same | `last` | *quote rule*: `last >= ask` → BUY, `last <= bid` → SELL, using the bid/ask of the **previous** tick (the quote prevailing before the trade; the same tick may already carry the post-trade quote); inside the spread → *tick rule* |
| QUOTE_TICKS | ticks with `TICK_FLAG_BID` or `TICK_FLAG_ASK` | `1.0` | `bid` (or mid if `FP_QP_MID`) | *mid rule*: `mid > prevMid` → BUY, `<` → SELL, `==` → `prevSide` |

- **Tick rule:** `price > prevTradePrice` → BUY, `<` → SELL, `==` → `prevSide`.
- If the side is still unknown (no previous state), split the size **50/50** between sell and buy.
- **Seeding for determinism.** The classifier state at bar open `t0` is defined as follows:
  1. Start unseeded.
  2. Classify, **without accumulating**, every tick in `[t0−300 s, t0)`, fetched with one `CopyTicksRange(symbol, tmp, COPY_TICKS_ALL, (t0-300)*1000, t0*1000-1)`. This seeds `prevMid`, `prevTradePrice`, `prevSide` and the previous quote.
  3. Live processing does the same at every bar boundary. Keep the last 300 s of raw ticks in a ring buffer and re-derive the state from it on the first tick of the new bar. **Never carry the running state across a bar boundary.**
  4. A rebuild may fetch `[(t0−300)·1000, t1·1000−1]` in one call and split it locally.

  Live processing and rebuilds then produce identical bars.

### 5.4 Rows (price buckets)

- `rowSize = bucketPoints * _Point` of the symbol (`SymbolInfoDouble(symbol, SYMBOL_POINT)`).
- Work in **integer points** to avoid float drift: `long pts = (long)MathRound(price / point); long row = floorDiv(pts, bucketPoints);`. Implement `floorDiv` correctly for negatives. `RowToPrice(row) = row * bucketPoints * point` (the bottom edge of the row).
- **Auto bucket (`bucketPoints = 0`), `FPPresets.mqh`:**
  1. Strip broker suffixes/prefixes (`.i`, `m`, `-ECN`, `#`, `@` …) and match case-insensitively:

     | Symbol | Points |
     |---|---|
     | XAUUSD/GOLD | 40 |
     | BTCUSD | 1000 |
     | US30/DJ30, NAS100/USTEC, DE40/GER40 | 100 |
     | SP500/US500, UK100 | 30 |
     | EURUSD, GBPUSD, USDCAD, USDCHF | 5 |
     | AUDUSD | 6 |
     | EURGBP | 3 |
     | AUDCAD, GBPCAD | 5 |
     | USDJPY, EURJPY, GBPJPY | 10 |
     | AUDJPY, CADJPY | 5 |
     | Futures roots: GC/GCE | so that a row = 5 ticks (`@GCE` row = 0.50 in the reference) |
     | ES/MES | 1 tick |
     | NQ/ENQ/MNQ | 4 ticks |

  **Presets are price steps, not raw points.** The point values above assume these common feed digits:

  | Feed | Example | Row size |
  |---|---|---|
  | XAUUSD/GOLD, 2 digits | 40 | 0.40 |
  | BTCUSD, 2 digits | 1000 | 10.00 |
  | Indices, 1 digit | 100 / 30 | 10.0 / 3.0 |
  | FX, 5 digits | 5 | 0.00005 |
  | JPY pairs, 3 digits | 10 | 0.010 |

  Store each preset as `step = points × pointOfThatFeed`. On the actual symbol, compute `bucketPoints = max(1, round(step / _Point))`, so a 3-digit gold feed still gets 0.40.

  2. Sanity and fallback: compute ATR(14) of the chart timeframe from `CopyRates` inside `FPPresets` (no indicator handles in the engine).
     - If there is no preset, choose `bucket = niceRound(ATR / (20*point))`, so a typical bar spans about 20 rows. Nice values: {1,2,3,5,10,20,25,50,100,200,250,500,1000…}, minimum 1.
     - If a preset gives `ATR/rowSize` outside 6–80, use the ATR rule instead and log both.
  3. Log the chosen value as points and as a price step.

### 5.5 Bars, real-time updates and finalisation

- **Bar boundaries:** `barOpen = tickTime - tickTime % PeriodSeconds(tf)` (server time; valid for M1..D1). The engine is chart-independent: do not use `OnCalculate` arrays inside the engine.
- **History build (`LoadStep(budgetMs)`):**
  - **Bar list.** Get the bar open times with `CopyTime(symbol, tf, 1, N, times)` and their tick volumes with `CopyTickVolume`.
    - Never step back by `PeriodSeconds` across weekends or daily breaks; that creates hundreds of empty bars.
    - Use `t - t % PeriodSeconds(tf)` only to assign ticks to bars, and assert that it reproduces those times.
  - **Session coverage.** `historyBars` is a minimum. Always load back to `SessionStart(oldest requested bar)`, plus the whole previous session (for previous-session POC and previous-day levels). Trim only whole sessions.
  - **Order.** Build the newest closed bars first, so the visible area appears quickly. Each bar is one `CopyTicksRange(symbol, ticks, COPY_TICKS_ALL, t0*1000, t1*1000-1)` (both bounds are inclusive).
  - **Pending bars.** In indicators, `CopyTicks*` do not wait for synchronisation: they return what is in the local tick base and start a download.
    - If a bar returns ≤ 0 ticks, or an error, while its tick volume is > 0, mark it `pending`.
    - Retry it on later steps until 120 s have passed since the first attempt; then mark it `nodata`.
    - Accept a bar only when a repeat call at least 1 s later returns the same tick count, **and** a tick exists at or after `t1` (except for the newest closed bar).
    - Retry `nodata` bars on RESET and after a reconnect.
  - **Chronological pass.** While history loads, **don't** compute `cumDelta`, the zone lifecycle (creation, fill, touch) or the session POC/VWAP.
    - When no bar is `pending`, run one chronological pass, oldest → newest, over all held bars, including live bars finalised in the meantime. It computes `cumDelta`, the zones and the session values.
    - Only then does `HistoryReady()` return true.
    - A `nodata` bar contributes 0 and sets `cvdValid=false` on the later bars of its session.
  - **Forming-bar bootstrap.** In `Init`, set `fOpen = iTime(symbol, tf, 0)`. Build the forming bar like a history bar over `[fOpen·1000, now]`. Then set `lastMsc` to the last tick's `time_msc` and `k` to the number of ticks with that `time_msc`. `Update()` never calls `CopyTicks` with `from = 0`, because that returns the *last* `count` ticks.
  - **OHLC** uses the row-price basis of counted ticks only: bid in QUOTE mode (mid with `FP_QP_MID`), `last` in TRADE/EXCHANGE mode.
  - Respect the time budget with `GetTickCount64()`.
  - Before finishing a step, process any new real-time ticks (call `Update()`), so live data never waits behind history.
- **Real-time (`Update()`):**
  - Pull new ticks with `CopyTicks(symbol, arr, COPY_TICKS_ALL, lastMsc, 100000)`. If exactly 100000 come back, process them and loop.
  - **De-duplicate:** skip the first `k` returned ticks whose `time_msc == lastMsc`, where `k` = how many ticks with that exact `time_msc` were already processed. Then update `lastMsc` and `k`.
  - Classify each tick and add it to the forming bar: sell/buy volume at its row, OHLC, volume, delta, running `deltaMax`/`deltaMin`, and `ticks`. Rows grow dynamically: keep `rowLow` and resize the arrays when price extends the range.
- **Finalisation:**
  - When the first tick with `time >= t0 + PeriodSeconds(tf)` arrives, **rebuild the old bar from a fresh `CopyTicksRange` over its full range** (seeded per §5.3).
  - Before replacing the live-accumulated bar, compare the two and count mismatches; log a summary every 50 bars.
  - Then compute imbalances, POC, stacks, the zone lifecycle update and session CVD, set `closed = true`, and **never modify that bar again**.
  - Push its time onto the closed-bar event queue (`PopClosedBar`). Only bars finalised on the **live** path are queued, never history bars.
  - Trim old bars only in whole sessions, keeping the coverage rule above.
- **Sessions:**
  - `SessionStart(t)` = the latest time ≤ t whose time-of-day equals `sessionStartMin`.
  - `cumDelta` resets at session start.
  - Session VWAP = Σ(rowMid × rowVol) / Σ rowVol over the session's bars.

### 5.6 Per-bar analytics (`CFPAnalytics`)

Row index `i = 0` is the lowest row of the bar; `n = rows`.

- **POC:** the index of the maximum `sellVol+buyVol`. On a tie, take the row closest to the close price; if still tied, the lower row.
- **Diagonal imbalances, three tiers.** Ratios are inclusive (≥). A missing neighbour (bottom or top row) means no imbalance.
  - **BUY at row i (i ≥ 1):** `B = buyVol[i]`, `S = sellVol[i-1]`. Requires `B >= imbMinVolume`. If `S == 0` → tier 3. Otherwise tier = 3 if `B/S >= r3`, 2 if `>= r2`, 1 if `>= r1`.
  - **SELL at row i (i ≤ n−2):** `S = sellVol[i]`, `B = buyVol[i+1]`. Requires `S >= imbMinVolume`. Tiers as above with S/B.
  - Store the tiers in `imbBuy[]` and `imbSell[]` (0 = none).
  - Unit-test anchors (from the vendor's documentation figure):
    - buy 96 vs sell 18 one row below → BUY tier 3 (5.3×);
    - buy 75 vs sell 20 below → tier 2 (3.75×);
    - sell 463 vs buy 237 above → none (1.95×);
    - buy 7 vs sell 3 below → none (min volume 10).
- **Stacked imbalances:** a run of ≥ `stackMinRows` consecutive rows with `imbBuy ≥ 1` → BUY stack (support); likewise SELL stacks (resistance). Each stack becomes an `FPZone` spanning the bottom edge of its lowest row to the top edge of its highest row.
- **Zone lifecycle** (evaluated on every newly closed bar after the origin bar):
  - A BUY zone is **filled** when a bar's `low < zone.priceLow`. A SELL zone is filled when `high > zone.priceHigh`. Set `filledTime` to that bar's open time.
  - A bar that enters an open zone without filling it increments `touches` and sets `lastTouchTime` to its open time.
  - Bar T's lifecycle update runs during T's own finalisation. Consumers that need the state *as of* an earlier bar use `filledTime` and `lastTouchTime` to reconstruct it (EA §4).
  - Zones also store `rowFrom` and `rowTo` (absolute row indices), so no float matching is needed.
- **Value area** for any profile (bar, session, N-bar):
  1. Start at the POC.
  2. Repeatedly compare the sum of the next two rows above with the next two rows below, and add the larger pair (tie → above).
  3. Stop when the accumulated volume is ≥ `valueAreaPct × total`. This gives VAH and VAL.

### 5.7 ENGINE API CONTRACT v1 (copy exactly; the EA prompt uses the same text)

```mql5
//--- FPTypes.mqh  (in addition to ENUM_FP_SOURCE, ENUM_FP_QUOTE_PRICE, FPConfig above)
//    FPTypes.mqh holds ALL shared types, incl. CFPBar and CFPTickSource.
//    Include order: FPAnalytics.mqh includes FPTypes.mqh; FPEngine.mqh includes FPAnalytics.mqh (no circular includes).
struct FPZone
{
   int      dir;            // +1 = BUY stack (support), -1 = SELL stack (resistance)
   datetime originTime;     // open time of the bar that formed the stack
   long     rowFrom;        // absolute row index of the lowest stacked row
   long     rowTo;          // absolute row index of the highest stacked row
   double   priceLow;       // bottom edge of rowFrom
   double   priceHigh;      // top edge of rowTo
   int      rowsCount;      // rowTo - rowFrom + 1
   double   volume;         // dominant-side volume inside the stack
   datetime filledTime;     // 0 while open; else open time of the bar that filled it
   int      touches;        // closed bars that entered the zone without filling it
   datetime lastTouchTime;  // open time of the most recent touching bar (0 = none)
};

struct FPProfile
{
   long     rowLow;         // absolute row index of element 0
   int      rows;
   double   sell[];         // per-row sell volume
   double   buy[];          // per-row buy volume
   double   total;
   int      pocIdx, vahIdx, valIdx;
};

struct FPPrint              // one classified print (ring buffer in the engine)
{
   long     time_msc;
   double   price;          // row-price basis of the active source
   double   size;
   int      side;           // +1 buy, -1 sell, 0 = split 50/50
};

class CFPTickSource         // default implementation wraps CopyTicks / CopyTicksRange; tests inject in-memory ticks
{
public:
   virtual int Since(const string symbol, const ulong fromMsc, const uint count, MqlTick &out[]);
   virtual int Range(const string symbol, const ulong fromMsc, const ulong toMsc, MqlTick &out[]);
};

class CFPBar
{
public:
   datetime time;               // bar open time (server)
   double   open, high, low, close;   // row-price basis of counted ticks only
   long     rowLow;             // absolute row index of element 0
   int      rows;
   double   sellVol[];          // [rows]  left number  (volume that hit the bid)
   double   buyVol[];           // [rows]  right number (volume that lifted the ask)
   char     imbSell[];          // [rows]  0..3 tier of SELL imbalance at this row; write with (char)tier
   char     imbBuy[];           // [rows]  0..3 tier of BUY imbalance at this row; write with (char)tier
   double   volume;             // sum of sell+buy
   double   delta;              // buy - sell
   double   deltaMax, deltaMin; // running intrabar extremes of delta
   int      ticks;              // ticks counted into this bar
   int      pocIdx;             // index of the bar POC row
   double   cumDelta;           // session cumulative delta at bar end
   bool     cvdValid;           // false if a 'nodata' bar precedes it in the same session
   bool     closed;             // true = finalised and locked
   int      state;              // 0 ok, 1 pending (loading), 2 nodata
   double   RowVolume(const int i) const { return sellVol[i] + buyVol[i]; }
   double   RowPrice(const int i, const double rowSize) const { return (double)(rowLow + i) * rowSize; }
};

//--- FPEngine.mqh
class CFPEngine
{
public:
   bool           Init(const FPConfig &cfg);
   void           Deinit();
   void           SetTickSource(CFPTickSource *src);       // NULL = default CopyTicks source; engine does not own it
   bool           LoadStep(const uint budgetMs);           // true when history is complete (see HistoryReady)
   bool           HistoryReady() const;                    // false while any bar is pending or the chronological pass has not run
   int            Update();                                // new ticks processed, -1 on error
   int            FeedTicks(const MqlTick &ticks[], const int count);   // test hook: same code path as Update() after fetching
   bool           PopClosedBar(datetime &barTime);         // FIFO of bars finalised on the LIVE path only (never history bars)
   int            Total() const;                           // bars held (forming + closed)
   CFPBar        *At(const int shift);                     // 0 = forming, 1 = last closed; NULL if n/a
   CFPBar        *ByTime(const datetime barTime);
   ENUM_FP_SOURCE ActiveSource() const;
   double         RowSize() const;
   long           PriceToRow(const double price) const;
   double         RowToPrice(const long row) const;        // bottom edge
   datetime       SessionStart(const datetime t) const;
   bool           SessionProfile(const datetime sessionStart, FPProfile &out);
   bool           RangeProfile(const int fromShift, const int toShift, FPProfile &out);
   double         SessionVWAP(const datetime sessionStart);
   int            Zones(FPZone &out[], const bool includeFilled = false) const;
   int            Prints(FPPrint &out[], const int maxCount) const;   // newest first; ring buffer >= 2000 prints
   string         LastError() const;
};
// POINTER RULE: pointers returned by At()/ByTime() are valid only until the next Update(), LoadStep(),
// FeedTicks() or Deinit() call. Never store them.

//--- FPAnalytics.mqh
class CFPAnalytics
{
public:
   static void    ComputeImbalances(CFPBar *bar, const FPConfig &cfg);
   static int     FindStacks(CFPBar *bar, const FPConfig &cfg, const double rowSize, FPZone &out[]);
   static int     PocIndex(CFPBar *bar);
   static bool    ValueArea(FPProfile &p, const double pct);
};
```

You may add **private** members and helper functions. You may add public methods only if they don't change the ones above. Record every addition in `DECISIONS.md`.

### 5.8 Data-window buffers (for the user; the EA must not depend on them)

There are 8 `DRAW_NONE` plots, aligned to chart bars by time and set to `EMPTY_VALUE` where the engine holds no bar: `FP Volume`, `FP Delta`, `FP CumDelta`, `FP POC price`, `FP BuyImb count`, `FP SellImb count`, `FP BuyStack rows`, `FP SellStack rows`.

## 6. Rendering architecture

- **One `CCanvas`** (`#include <Canvas\Canvas.mqh>`) created with `CreateBitmapLabel` at (0,0), sized to `CHART_WIDTH_IN_PIXELS × CHART_HEIGHT_IN_PIXELS`.
  - Use the `COLOR_FORMAT_XRGB_NOALPHA` format, so everything is opaque. **Pre-blend** translucent colours against the known background (`Blend(bg, c, alpha)`); don't rely on alpha.
  - Resize on `CHARTEVENT_CHART_CHANGE`.
  - Object flags: `OBJPROP_SELECTABLE=false`, `OBJPROP_HIDDEN=true`.
- **Chart properties on start:** save them, set them, and restore them on deinit:
  - `CHART_FOREGROUND=false` (objects above the price chart);
  - `CHART_SHOW_GRID=false`, `CHART_SHOW_OHLC=false`, `CHART_SHOW_ONE_CLICK=false`;
  - `CHART_MOUSE_SCROLL=false`;
  - `CHART_EVENT_MOUSE_MOVE=true`, `CHART_EVENT_MOUSE_WHEEL=true`.
  - The native price/time scales may stay visible outside the canvas. Optional input `InpHideNativeChart`: set `CHART_SHOW=false`.
- **Scheduling:**
  - `EventSetMillisecondTimer(50)`. Each timer event: `LoadStep(InpLoadBudgetMs)` while history is incomplete, then `Update()`, then a redraw if dirty and ≥ `InpRedrawMs` (default 100) has passed since the last draw.
  - `OnCalculate` only calls `Update()`, fills buffers for new or changed bars, and sets dirty.
  - **In the Strategy Tester (`MQLInfoInteger(MQL_TESTER)`), don't rely on indicator timers.** Do the load/update/throttled draw from `OnCalculate` instead, throttled by tick time.
- **Fonts:**
  - Numbers in `Consolas`; UI text in `Segoe UI` (semibold for titles).
  - Set them via `CCanvas::FontSet` with **positive pixel sizes only**: `px = round(pt × 96/72 × s)`, where `s = InpUIScalePct/100 × TERMINAL_SCREEN_DPI/96`.
    - Negative sizes are tenths of a point and already scale with Windows DPI; mixing them with `s` would scale twice.
    - Apply the same `s` to all geometry. Imbalance boosts are px *after* scaling.
  - Measure text with `TextWidth`/`TextHeight`, and cache the widths per string length.
- **Colours:** pass every colour to CCanvas as `ColorToARGB(c, 255)`. An MQL5 `color` is stored as 0x00BBGGRR, so passing it raw swaps red and blue.
- **Hit-testing:** keep a list of button rectangles with ids. On `CHARTEVENT_CLICK` (lparam = x, dparam = y), find the button, toggle its state, relayout and redraw.
  - Mouse wheel over the footprint: zoom the row height in or out. Shift+wheel or click-drag: scroll horizontally through history.
  - The `LIVE` button (and the Home key) returns to the newest bar and re-enables auto-follow.
  - **Decoding `CHARTEVENT_MOUSE_WHEEL`:** `x=(int)(short)lparam; y=(int)(short)(lparam>>16); keys=(int)(lparam>>32); delta=(int)dparam`. Delta comes in steps of ±120; Shift is `keys & 0x0004`.
  - **In the Strategy Tester, indicators receive no `OnChartEvent`.** Read `CHART_WIDTH/HEIGHT_IN_PIXELS` on every draw (to catch resizes) and show the buttons as inactive.
- **Draw order per frame:**
  1. background;
  2. zones;
  3. grid;
  4. cells;
  5. per-bar overlays;
  6. session POC line;
  7. price scale and tag;
  8. summary table;
  9. mini chart;
  10. header and tabs;
  11. side panels.

  Call `canvas.Update(true)` **once** per frame.

## 7. Layout (defaults at 100 % scale; the chart client area is W×H)

| Region | Rectangle |
|---|---|
| Header | y 0–34, full width |
| Style tabs | y 34–60, full width (collapsible to 0 with "−") |
| Side column (if SIDE PANELS on) | x `W−690` … `W`, y 60 … H |
| Footprint panel | x 0 … `W−690−20` (or W−20 when side panels are off), y 60 … `H − tableH` |
| Summary table | under the footprint panel; `tableH = 22 + 5×20` |
| Mini session chart | x 8, y 66, 330×230 (overlay, toggle) |

Side column split (widths in px, matching the references):
- **Top block, height 470:** Chart Analyst 470 | Signal Meter 180.
- **Bottom block, height = the rest (≈475):** DOM ladder 280 | Time & Sales 185 (the bottom 2×100 px hold RSI(14) and MACD) | VP Total 180.
- Gaps 5 px. Panel title strip 26 px, with a 1 px border in the theme's `border` colour.
- If `W < 1500`, auto-hide the side panels (the user can force them on).

## 8. Visual specification

### 8.1 Footprint panel — Minimalist style (MUST)

**Geometry:**
- Bars are columns of width `InpBarWidth` (55), with `InpBarSpacing` (14) between them; newest at the right.
- Leave `gap=75` px between the last bar and the own price scale; the price scale column is 64 px.
- The number of visible bars follows from the width. The video shows about 14–16 with side panels on.

**Rows:**
- Row height `InpRowHeight` (16, minimum 14; zoom range 6–40).
- If the row height < 14, hide the numbers and draw **compact candles** instead: a 3 px wide high–low line plus an open–close body in bull/bear colours.
- Vertical scroll: UP/DOWN move by 80 px. Auto-follow re-centres when the last price leaves the middle 60 % of the panel.

**Cells:**
- For every row with volume, draw `SELL` right-aligned ending at `centre − 6 px`, a dim "x" (secondary text colour, 1 px smaller) at the centre, and `BUY` left-aligned starting at `centre + 6 px`.
- Format integers with no separator. ≥ 10 000 → `12.3k`; ≥ 1 000 000 → `1.2M`. In EXCHANGE mode with fractional volumes, round to the instrument's volume step for display.
- Normal numbers use the primary text colour. Zero values show `0`. Rows inside the bar range with no trades show `0 x 0`, dimmed.

**Imbalance styling:**
- A tier-k imbalanced number is drawn **bold** with a font-size boost (`+1/+2/+3` px for tiers 1/2/3).
- Colour: seller imbalances (left number) use `InpSellImbColor` = (239,68,68); buyer imbalances (right number) use `InpBuyImbColor` = (34,197,94). These are independent of the theme unless `InpThemeOverridesImbalance=true`.
- Optional per-tier colours: 3 inputs per side, defaulting to the same colour.

**Per-bar POC outline** (SHOULD, default **off**): a 1 px fuchsia (255,0,255) rectangle around both numbers of the POC row.

**Grid:**
- Vertical separators between columns: theme `grid` colour, very faint.
- Horizontal lines every 2 rows: same colour, even fainter.

**Own price scale:**
- Right of the bars. A label every N rows such that labels are ≥ 28 px apart.
- Format: `DoubleToString(price, digitsFor(rowSize))`. The reference shows `4394.0, 4393.0…` for a 0.5 row.

**Current price tag:**
- A filled rectangle (theme bull colour if `close ≥ open` of the forming bar, else bear) with the last price in bold contrasting text, on the price scale.
- A 1 px line in the same colour from the forming bar to the tag.
- A small dim "ASK" (or "BID" in BID basis) label left of the tag.

**Time labels:** `HH:MM` under each column, inside the summary table header row.

### 8.2 Overlays

- **Session POC line** (MUST): dashed (6 on / 4 off) 1 px line in (168,85,247) across the whole footprint panel at the session profile's POC, with the label `POC` in the same colour at the right end.
- **Stacked-imbalance zones** (SHOULD):
  - A filled band from the origin bar extending right for `InpStackZoneBars` (20) bars or up to the fill bar.
  - Fill: bull/bear colour at alpha 0.16; 1 px border at alpha 0.6; small label `STACKED BUYERS` / `STACKED SELLERS` at the left.
  - Filled zones are drawn faint (alpha 0.06), or hidden if `InpShowFilledZones=false`.
- **Supply & demand zones** (SHOULD, header toggle, default off):
  1. Find pivots with strength 8 (8 bars each side) within the last 200 bars. Keep pivots whose bar volume ≥ 1.2 × SMA(volume, 20).
  2. Each pivot makes a zone of height `ATR(50)/4`: from the pivot low upwards for demand, from the pivot high downwards for supply.
  3. Keep at most 4 zones, the most recent. Fill colour = theme bull (demand) or bear (supply) at alpha 0.16, 1 px border; they extend to the right edge.
  4. When a bar closes beyond the far edge, the zone **flips role and colour**. A zone whose middle has been touched turns grey (120,126,138).
  - The light reference shows a blue band: fill #D8E8F8, border #2889E8.
- **Delta bars** (header button, SHOULD): under each column's lowest row, a small rounded box containing the signed delta (`+30`, `-77`), with text and border in the bull/bear colour.
- **Bar volume profile** (header button, SHOULD): behind each column's numbers, a horizontal bar from the column's left edge.
  - Width ∝ row volume / bar max × column width. The sell part is drawn in (239,68,68) and the buy part stacked after it in (34,197,94), both at alpha 0.25.
  - The POC row's bar is gold (250,204,21) at alpha 0.35.

### 8.3 Header bar (MUST)

From left to right:
- **Toggle buttons:** `SUPPLY & DEMAND ZONES`, `FUNDAMENTALS`, `MINI SESSION CHART`. Bordered boxes with secondary-colour text; active text is blue (59,130,246).
- **Ticker:**
  - symbol in gold (250,204,21);
  - last price in blue;
  - daily change `+29.6 (+0.68%)` versus the D1 open, in the bull/bear colour.
- **Trend boxes:** `5M:▲ 15M:▲ 1H:▲ 4H:▼ D1:▲`. Arrow ▲ in the bull colour if MA(9) > MA(21) on that timeframe's closed bars, ▼ in the bear colour otherwise.
- **Bias labels:** `HTF: BULL/BEAR` (the H4 rule above) and `<chartTF>: BULL/BEAR` (the same rule on the chart timeframe), each in the bull/bear colour.
- **Right-aligned buttons:** `RESET ZOOM IN ZOOM OUT UP DOWN BAR VOLUME PROFILE DELTA BARS SIDE PANELS LIVE`. Toggle buttons show active state in blue text.
- **Status text** in a small dim font under the ticker or as a tooltip: source mode, bucket, history progress (`loading 120/300`), draw ms.

### 8.4 Style-tab row (MUST: Minimalist works; the other tabs are greyed until implemented)

- Tabs, letter-spaced uppercase in Segoe UI semibold 9–10 pt: `MINIMALIST | BACKGROUND CELLS | CANDLE FRAME | VOLUME PROFILE CANDLE | FRAMELESS | MIDDLE CANDLE | DELTA CELLS | BID x ASK PROFILE | BID x ASK CELLS`, then a `−` button that collapses the tab row.
- The active tab has blue text.

### 8.5 Other styles (MAY, milestone M5)

All styles keep the imbalance colouring, the POC marking and the bar VP option.

| Style | Description |
|---|---|
| Background Cells | Each row is a filled cell with `sell x buy` inside. Cell colour = the dominant side; 3 strength shades: ≥ 70 % / ≥ 40 % / below, of the bar's max row volume. Body frame and wick drawn around |
| Candle Frame | Numbers plus the open–close body drawn as a 2 px frame in the bull/bear colour and a wick through the middle; no fill |
| Volume Profile Candle | A solid body bar at the left in the bull/bear colour. Beside it, every row is a cell whose width ∝ volume, with `sell x buy` inside. POC cell solid with a gold outline |
| Frameless | A thin body and wick at the left; the numbers in clean columns beside it |
| Middle Candle | A full candle in the centre; sell numbers on its left, buy numbers on its right |
| Delta Cells | One signed number per row (buy − sell), shaded in the bull/bear colour by strength; thin side body |
| Bid × Ask Profile | Mirrored bars: sell bars grow to the left, buy bars to the right, each labelled; thin centre candle line |
| Bid × Ask Cells | Two separate cells per row, each shaded by its own volume. Sell numbers in the bear colour, buy numbers in the bull colour; body outline |

### 8.6 Mini session chart (SHOULD)

- A 330×230 panel at top-left over the footprint (theme panel background, border).
- Content: an area/line chart of M1 closes since session start (`CopyClose(symbol, PERIOD_M1, …)`). Line in the theme bull colour, area fill at alpha 0.25, dashed horizontal line at the session open, white 4 px dot at the last price.
- Caption under it, in the bull/bear colour: `Session Move: +0.70%   Local 00:00-00:00   M1 Bars: 382`.

### 8.7 Summary table (MUST)

- **Header row:** the column times `HH:MM`, aligned with the bar columns. Top-right cell: countdown `mm:ss` to bar close, coloured spring green (0,255,127), yellow at ≤ 30 s, orange at ≤ 20 s, red at ≤ 10 s. A `−` button collapses the table.
- **Rows:** `Volume`, `Delta`, `Cum Delta`, `Ask` (= buy volume), `Bid` (= sell volume), with labels in a 90 px column on the right.
- **Cell colours** (verified on the reference). Let `k` = value ÷ max of that row over the visible bars. Background = `Blend(panelBg, colour, 0.15 + 0.85*k)`:

| Row | Colour | k based on |
|---|---|---|
| Volume | Bull/bear colour by the sign of that bar's **delta** | volume |
| Delta | Bull/bear by sign | \|delta\| |
| Cum Delta | Bull/bear by sign | \|cumDelta\| |
| Ask | Always bull | value |
| Bid | Always bear | value |

- **Text:** the primary text colour. Use dark text on very light cells in the Light theme (luminance > 0.6).

### 8.8 Right-side panels (MUST unless marked)

All panels share the theme panel background, a 26 px title strip (Segoe UI semibold 11 pt, primary colour) and a 1 px border.

**(a) VP Total**
- Title `VP Total`, sub-title `(50 bars)` or `(session)`; input mode BARS (default, 50) or SESSION.
- Horizontal bars grow from the left, with length ∝ row volume / max, in the theme bull colour (alpha 0.85). Its own vertical scale: fit the profile's price range to the panel height.
- POC: a 1 px line in (250,204,21) with a `POC` label at the right. VAH and VAL: 1 px lines in (148,163,184) with `VAH`/`VAL` labels (value area 70 %).

**(b) Time & Sales**
- The data comes from `engine.Prints()`, the engine's classified prints. **Never run a second classifier in the UI.**
- Columns `Time | Price | Size`, with `HH:MM:SS`, the price at the symbol's digits and the size. Newest on top, 30 rows (input).
- Buy rows in the bull colour, sell rows in the bear colour.
- `InpTasAggregate` (default true): merge consecutive prints with the same side and price within the same second (sizes added).
- Size ≥ `InpTasBigSize` (0 = auto: 95th percentile of the last 500 prints) → bold.
- Footer `Bar Totals:` with two boxes, `B:<buy>` (bull fill) and `S:<sell>` (bear fill), for the forming bar.

**(c) RSI(14) mini and MACD(12,26,9) mini**
- Each 100 px, at the bottom of the T&S panel.
- RSI: a line in (168,85,247), dashed 50 line, the value top-right in the same colour, a faint band between 30 and 70.
- MACD: a histogram in bull/bear colours, the value top-right in the bull colour.
- Use `iRSI`/`iMACD` handles created in `OnInit`. Guard with `BarsCalculated`.

**(d) DOM ladder**
- Columns `Bid | Sold | Price | Bot | Ask | D | Vol`. Rows at the footprint row size, centred on the current price, `InpDomLevels` (12) above and below.
- `Bid`/`Ask` = the market-book volume aggregated into the row (`MarketBookAdd` in `OnInit`, update on `OnBookEvent`, read with `MarketBookGet`, `MarketBookRelease` in `OnDeinit`). Draw bars ∝ size: Bid in the bull colour, Ask in the bear colour.
- `Sold`/`Bot` = the forming bar's sell/buy volume at that row. `D = Bot − Sold` (signed, bull/bear colour). `Vol = Sold + Bot`.
- Rows the forming bar traded get a faint bull/bear tint by the sign of D. The current-price row gets a gold (250,204,21) tint at alpha 0.25.
- No book available (most CFD brokers, and the tester) → leave Bid/Ask empty and show a small dim `NO BOOK – FOOTPRINT ONLY` under the title. **Never invent depth.**

**(e) Signal Meter**
- Gauge: a semicircle 120 px in diameter. Arcs: bear colour (−100…−20), neutral grey (−20…+20), bull colour (+20…+100). A gold (250,204,21) needle with a hub.
- Under the gauge: the label and the score (`STRONG BUY +72`).
- Then 11 rows of `label | value`, with values coloured bull/bear/neutral.
- The vendor's formula is unknown. **Implement this one and document it in `DECISIONS.md`.**
- **Votes** v ∈ {−1, 0, +1}, all with weight 1, computed on the last **closed** bar of the chart timeframe:

| Row | Vote | Displayed value |
|---|---|---|
| RSI | > 55 → +1; < 45 → −1 | e.g. `53.8` |
| MACD | main > signal → +1, else −1 | main, 2 decimals |
| MA 9 / MA 21 / MA 50 | `UP ABOVE` (close > MA and MA rising vs 3 bars ago) → +1; `DOWN BELOW` → −1; `UP BELOW` / `DOWN ABOVE` → 0 | the text |
| VWAP | session VWAP: close > VWAP → `UP ABOVE` +1, else `DOWN BELOW` −1 | the text |
| POC Pos | see the rule below the table | e.g. `ABV ACC 9.4t` |
| Delta | last closed bar: delta / volume ≥ +0.10 → +1; ≤ −0.10 → −1 | the **forming** bar's delta, signed |
| Cum Delta | session CVD rising over the last 5 closed bars → +1; falling → −1 | session CVD |
| Vol B/S | session buy ÷ sell > 1.10 → +1; < 0.90 → −1 | 2 decimals |
| ATR Reg | no vote; it scales the score | `TREND 1.23x` / `BASE 0.98x` / `CHOP 0.77x` |

- **POC Pos rule:** the distance `d` from the session POC in ticks (`SYMBOL_TRADE_TICK_SIZE`).
  - `|d| < 1.5` → `AT POC` (0).
  - Otherwise, if the last 3 closes are all on the same side → `ABV ACC` (+1) or `BLW ACC` (−1).
  - Otherwise `ABV TEST` / `BLW TEST` (0).
  - Display: `ABV ACC 9.4t`.
- **ATR Reg:** `r = ATR(14) / SMA(ATR(14), 50)`. TREND if r > 1.15, CHOP if r < 0.85, else BASE.
- **Score:** `raw = Σv / 10`. Multiply by 0.6 in CHOP and 0.85 in BASE. `score = round(100 × raw)`.
- **Label:** ≥ 60 STRONG BUY; ≥ 20 BUY; > −20 NEUTRAL; > −60 SELL; otherwise STRONG SELL.
- Recompute on every closed bar and every 2 s for the forming-bar rows.

**(f) Chart Analyst**
- Title `Chart Analyst`, with `Updated: Ns ago` right-aligned (dim). Refresh every `InpAnalystRefreshSec` (30) and on bar close.
- Body: Consolas 10 pt, word-wrapped to the panel width. Section headings in the primary colour, uppercase.
- Sentence colours: bull colour (bullish), bear colour (bearish), grey (140,145,155) (neutral), blue (96,165,250) (levels), yellow (250,204,21) (summary/caution).
- Use **exactly these templates** (`{}` = values; the thresholds are ours, so document them):

1. **PAIR INFO** — `{SYMBOL} | {TF}`; `Daily: {+0.0} ({+0.00}%)` versus the D1 open.
2. **TREND + HIGHER TF | ATR: {atr}** (ATR(14), symbol digits)
   - Trend sentence:
     - close > MA9 > MA21 > MA50 → `Strong bullish trend. Price above all MAs with bullish alignment.`
     - mirror → `Strong bearish trend. Price below all MAs with bearish alignment.`
     - close > MA21 → `Moderate bullish bias. Price holding above medium-term MA.`
     - otherwise → `Moderate bearish bias. Price trading below medium-term MA.`
   - HTF sentence (H4 and D1 rules from §8.3):
     - both bull → `H4 and Daily aligned bullish. Higher timeframes support upside.`
     - both bear → `H4 and Daily aligned bearish. Higher timeframes support downside.`
     - otherwise → `Mixed HTF signals. H4/Daily showing divergence. Trade with caution.`
3. **DOM ANALYSIS** — `r` = Σ bid depth / Σ ask depth over the 10 nearest levels.
   - r ≥ 1.5 → `Strong BID support. Buyers stacked {r:0.0}:1 vs asks. Near levels favor bulls.`
   - r ≤ 1/1.5 → `Heavy ASK pressure. Sellers stacked {1/r:0.0}:1 vs bids. Near levels favor bears.`
   - otherwise → `Balanced DOM. Bid/Ask ratio near 1:1. No clear directional bias from order book.`
   - no book → `No market depth from broker. DOM analysis unavailable.`
4. **TIME & SALES** — `p` = buy % of the last 200 prints from `engine.Prints()`.
   - p ≥ 65 → `Strong buy pressure ({p}%). Buyers clearly dominating the tape.`
   - p ≥ 55 → `Moderate buy pressure ({p}%). Buyers slightly more active.`
   - p ≤ 35 → `Strong sell pressure ({100-p}%). Sellers clearly dominating the tape.`
   - p ≤ 45 → `Moderate sell pressure ({100-p}%). Sellers slightly more active.`
   - otherwise → `Balanced tape. Buy/Sell near 50/50. No clear aggressor dominance.`
5. **ORDER FLOW** — `d` = delta/volume of the last closed bar; CVD slope over 5 bars.
   - d ≥ 0.15 and rising → `Active aggressive buying detected. Delta positive, cumulative delta rising.`
   - 0.05 ≤ d < 0.15 and rising → `Active moderate buying detected. Delta positive, cumulative delta rising.`
   - Mirrors: `Active aggressive selling detected. Delta negative, cumulative delta falling.` / `Active moderate selling detected. Delta negative, cumulative delta falling.`
   - Falling CVD otherwise → `Sellers in control. Monitor for potential breakdown.`
   - Rising CVD otherwise → `Buyers in control. Monitor for potential breakout.`
   - Flat → `Neutral order flow. No clear aggressor.`
6. **VOLUME** — `R` = session buy/sell.
   - R ≥ 1.15 → `Buyers leading (ratio: {R:0.00}). Healthy buying pressure.`
   - R ≤ 0.87 → `Sellers leading (ratio: {R:0.00}). Healthy selling pressure.`
   - otherwise → `Balanced volume (ratio: {R:0.00}). Neither side dominant.`
7. **IMBALANCES** — `B`, `S` = imbalance counts over the last 5 closed bars.
   - S ≥ 2B and S ≥ 5 → `Multiple sell imbalances ({S}) detected. Institutional selling likely.`
   - Mirror → `Multiple buy imbalances ({B}) detected. Institutional buying likely.`
   - Otherwise → `Buy imb: {B} | Sell imb: {S}. Mixed institutional activity.`
8. **KEY LEVELS** — `Session POC: {poc}. Daily range: {dayLow} - {dayHigh}.`
9. **SETUP + ADVISOR SUMMARY** — two lines.
   - **Line 1 (location):**
     - close within the top 10 % of the daily range → `CAUTION: Price near daily high. Watch for rejection or breakout above {dayHigh}.`
     - mirror → `CAUTION: Price near daily low. Watch for rejection or breakdown below {dayLow}.`
     - otherwise omit the line.
   - **Line 2:** the 6 factors are trend, HTF, DOM, T&S, order flow and volume. Each is bull/bear/neutral as classified above; let `b` and `s` be the counts.
     - b ≥ 4 → `BULLISH BIAS ({b}/6 factors). Consider long positions with proper risk management.`
     - s ≥ 4 → `BEARISH BIAS ({s}/6 factors). Consider short positions with proper risk management.`
     - b + s ≤ 1 → `NEUTRAL: Wait for clearer setup. Price in middle of range with mixed signals.`
     - otherwise → `MIXED SIGNALS ({b} bull, {s} bear). Wait for alignment before committing.`

**(g) Fundamentals** (MAY; header toggle)
- A 430 px overlay panel listing economic-calendar events from 12 h ago to 48 h ahead, for the symbol's base and profit currencies (`CalendarValueHistory`, `CalendarEventById`, `CalendarCountryById`).
- Importance colours: HIGH (255,99,71), MEDIUM (255,165,0), LOW (112,128,144).
- The calendar is not available in the tester; show `Calendar unavailable`.

## 9. Themes

**Panel themes:**

| Role | Dark | Light |
|---|---|---|
| bg | (15,17,23) | (248,248,248) |
| panelBg | (19,22,29) | (255,255,255) |
| border | (40,45,55) | (214,218,225) |
| grid | (28,32,40) | (232,234,238) |
| text | (220,225,235) | (30,35,45) |
| text2 | (140,145,155) | (110,115,125) |

**16 bull/bear accent themes.** RGB values are approximations; tune them against `reference/`. "Orange" was sampled at about #D96B00 in the video.

| # | Enum | Bull | Bear |
|---|---|---|---|
| 1 | CLASSIC | (34,197,94) | (239,68,68) |
| 2 | BLUE_ORANGE | (59,130,246) | (249,115,22) |
| 3 | CYAN_MAGENTA | (6,182,212) | (217,70,239) |
| 4 | LIME_PINK | (132,204,22) | (236,72,153) |
| 5 | GOLD_PURPLE | (250,204,21) | (168,85,247) |
| 6 | TEAL_CORAL | (20,184,166) | (251,113,133) |
| 7 | SKY_CRIMSON | (56,189,248) | (220,20,60) |
| 8 | MINT_ROSE | (110,231,183) | (244,63,94) |
| 9 | ORANGE_DARK_GREY (default) | (230,115,10) | (85,90,100) |
| 10 | GREEN_DARK_GREY | (34,197,94) | (85,90,100) |
| 11 | NAVY_SLATE | (37,99,235) | (100,116,139) |
| 12 | NAVY_GOLD | (37,99,235) | (234,179,8) |
| 13 | WHITE_DARK_GREY | (229,231,235) | (85,90,100) |
| 14 | EMERALD_WHITE | (16,185,129) | (229,231,235) |
| 15 | CHERRY_TEAL | (190,18,60) | (13,148,136) |
| 16 | OLIVE_SANDY | (132,140,40) | (244,164,96) |

- Theme accents drive: price tag, table heat, T&S, VP, header bull/bear, analyst sentiment, gauge arcs, mini chart, zones.
- Imbalance colours stay fixed unless the override input is set.

## 10. Inputs (exact names; group them with `input group`)

| Group | Name | Type | Default | Notes |
|---|---|---|---|---|
| Data | `InpSource` | ENUM_FP_SOURCE | AUTO | set explicitly for exact indicator/EA equality |
| | `InpBucketPoints` | int | 0 | 0 = auto (§5.4) |
| | `InpQuotePrice` | ENUM_FP_QUOTE_PRICE | BID | |
| | `InpHistoryBars` | int | 300 | |
| | `InpSessionStart` | string | "00:00" | server time HH:MM |
| | `InpValueAreaPct` | double | 70 | percent; pass `cfg.valueAreaPct = InpValueAreaPct/100` (0.70) |
| Imbalance | `InpImbRatio1/2/3` | double | 2.0 / 3.0 / 4.0 | |
| | `InpImbMinVolume` | double | 10 | |
| | `InpImbBold` | bool | true | |
| | `InpImbBoost1/2/3` | int | 1 / 2 / 3 | px |
| | `InpBuyImbColor`, `InpSellImbColor` | color | C'34,197,94', C'239,68,68' | |
| | `InpThemeOverridesImbalance` | bool | false | |
| | `InpStackMinRows` | int | 3 | |
| | `InpShowStackZones` | bool | true | |
| | `InpStackZoneBars` | int | 20 | |
| | `InpShowFilledZones` | bool | false | |
| Display | `InpStyle` | enum (9 styles) | MINIMALIST | |
| | `InpPanelTheme` | enum DARK/LIGHT | DARK | |
| | `InpColorTheme` | enum (16) | ORANGE_DARK_GREY | |
| | `InpBarWidth` | int | 55 | |
| | `InpBarSpacing` | int | 14 | |
| | `InpRowHeight` | int | 16 | |
| | `InpMinCellHeight` | int | 14 | |
| | `InpFontNumbers` | string | "Consolas" | |
| | `InpFontUI` | string | "Segoe UI" | |
| | `InpNumberFontSize` | int | 10 | pt |
| | `InpUIScalePct` | int | 100 | |
| | `InpShowSidePanels` | bool | true | |
| | `InpShowSummaryTable` | bool | true | |
| | `InpShowMiniChart` | bool | true | |
| | `InpShowSessionPOC` | bool | true | |
| | `InpShowPerBarPOC` | bool | false | |
| | `InpShowDeltaBars` | bool | false | |
| | `InpShowBarVP` | bool | false | |
| | `InpShowSDZones` | bool | false | |
| | `InpShowFundamentals` | bool | false | |
| | `InpHideNativeChart` | bool | false | |
| Panels | `InpVPMode` | enum BARS/SESSION | BARS | |
| | `InpVPBars` | int | 50 | |
| | `InpTasRows` | int | 30 | |
| | `InpTasAggregate` | bool | true | |
| | `InpTasBigSize` | double | 0 | 0 = auto |
| | `InpUseMarketBook` | bool | true | |
| | `InpDomLevels` | int | 12 | |
| | `InpAnalystRefreshSec` | int | 30 | |
| Studies | `InpMA1/2/3` | int | 9 / 21 / 50 | |
| | `InpRSIPeriod` | int | 14 | |
| | `InpMACDFast/Slow/Signal` | int | 12 / 26 / 9 | |
| | `InpATRPeriod` | int | 14 | |
| | `InpATRBaseLen` | int | 50 | |
| | `InpATRTrend` | double | 1.15 | |
| | `InpATRChop` | double | 0.85 | |
| | `InpPOCAccBars` | int | 3 | |
| | `InpPOCAccTicks` | double | 1.5 | |
| S&D | `InpSDSwing` | int | 8 | |
| | `InpSDLookback` | int | 200 | |
| | `InpSDVolLen` | int | 20 | |
| | `InpSDVolRatio` | double | 1.2 | |
| | `InpSDATRLen` | int | 50 | |
| | `InpSDWidthDiv` | double | 4.0 | |
| | `InpSDMaxZones` | int | 4 | |
| Performance | `InpRedrawMs` | int | 100 | |
| | `InpLoadBudgetMs` | int | 40 | |
| Alerts (SHOULD) | `InpAlertStack` | bool | false | |
| | `InpAlertDeltaAbove` | double | 0 | 0 = off |
| | `InpAlertDeltaBelow` | double | 0 | 0 = off |
| | `InpAlertPopup` | bool | true | |
| | `InpAlertSound` | string | "alert.wav" | |

Alerts fire **once per closed bar per type**, never from history. Message format: `SYMBOL TF - Stacked imbalance, HH:MM candle: STACKED BUYERS 3 rows 4100.80-4101.20`.

## 11. Verification tools you must also write

- **`FPTests.mq5`** (script): build hand-made `MqlTick[]` arrays and assert:
  1. the classification cascade for each source, including both-flags, inside-spread, flat-price and unseeded cases;
  2. `floorDiv`, `PriceToRow` and `RowToPrice` for positive and negative prices and different `bucketPoints`;
  3. the imbalance anchors from §5.6;
  4. stack detection and the zone fill/touch lifecycle;
  5. value area on a known profile;
  6. de-duplication of same-millisecond ticks across two consecutive tick batches;
  7. a BID-only quote tick carrying a stale `volume > 0` adds **nothing** in EXCHANGE/TRADE mode;
  8. live-incremental vs rebuild equality across a bar boundary, including the 300 s seeding window.

  **Test injection.** Implement an in-memory `CFPTickSource` subclass that serves hand-made ticks for both `Since()` and `Range()`, and install it with `SetTickSource()`. Then `FeedTicks()`, `Update()`, the finalisation rebuild and the seeding all read the same test data. No test may touch the real symbol's tick base.

  Print `PASS`/`FAIL` per test and a total.
- **`FPDumpBars.mq5`** (script): inputs `symbol`, `tf`, `bars`, `source`, `bucketPoints`. It builds bars with the engine (blocking is fine in a script) and writes two files to `MQL5\Files\OrderFlowFP\`:
  - `dump_<sym>_<tf>_bars.csv`: time, OHLC, volume, delta, cumDelta, pocPrice, ticks, buyImbCount, sellImbCount;
  - `dump_<sym>_<tf>_rows.csv`: time, rowPrice, sell, buy, imbSell, imbBuy.

  The EA prompt reuses this format to prove identical numbers.

## 12. Milestones and acceptance tests (work in this order; stop at the end of each and report)

**M1 — Engine + raw Minimalist footprint**
- Deliverables: `FPTypes`, `FPClassifier`, `FPEngine`, `FPAnalytics`, `FPPresets`, `FPTests`, `FPDumpBars`, and a first `FootprintChart.mq5` with the canvas, footprint cells, own price scale, price tag, time labels and the 8 buffers.
- Accept when all of these hold:
  - [ ] All files compile with 0 errors and 0 warnings.
  - [ ] `FPTests` reports all PASS.
  - [ ] On XAUUSD M5 the source is QUOTE_TICKS and the row size is 0.40 in price.
  - [ ] For every closed bar, Σ(sell+buy) equals the counted ticks. Log the ratio of counted ticks to `iVolume` per bar, as a diagnostic only.
  - [ ] Dump → restart terminal → dump again: the files are byte-identical for closed bars.
  - [ ] The live-vs-rebuild mismatch is 0 on ≥ 99 % of closed bars over 1 hour live (log the counts).
  - [ ] Draw time is ≤ 30 ms average (logged).
  - [ ] The chart stays responsive while history loads.
  - [ ] If an exchange-flag symbol is available, its source is EXCHANGE_FLAGS and Σ(sell+buy) = Σ trade sizes.

**M2 — Order-flow overlays + table**
- Deliverables: imbalance tiers (colour, bold, boost), per-bar POC option, session POC line, stacked zones, summary table with heat colours and countdown, delta bars, bar VP.
- Accept: visually compare with `02_…closeup` and `03_…table`. The table colour rules match §8.7 exactly. Zones fill correctly in a tester replay.

**M3 — Chrome + navigation**
- Deliverables: header (ticker, trend arrows, bias, buttons), style tabs, zoom, UP/DOWN, RESET, horizontal scroll and LIVE, the side-panel toggle with layout reflow, mini session chart, compact view below 14 px rows.
- Accept: every button works, no flicker, and the layout survives chart resize and DPI 100 %/150 %.

**M4 — Side panels**
- Deliverables: VP Total, T&S with Bar Totals, RSI/MACD minis, DOM ladder (book and no-book), Signal Meter, Chart Analyst.
- Accept: compare with `04_…` and `05_…`. The Analyst sentences follow §8.8(f) exactly. The gauge label matches its score thresholds. With no book, the panel shows the message.

**M5 — Themes, S&D, extras**
- Deliverables: 2 × 16 themes (an input plus cycling with keyboard `T`), S&D zones, alerts, Fundamentals (MAY), the other styles (MAY).
- Accept: screenshots in Dark-Orange, Dark-Green and Light-Classic resemble `01`, `07` and `09`.

At the end of each milestone, report: the files changed, the compile result, the test results, any `DECISIONS.md` entries, and known issues.

## 13. Build, run and test procedure

1. Ask the user for two paths, unless you can find them:
   - the **MT5 data folder** (MT5 → File → Open Data Folder), containing `MQL5\`;
   - the **terminal folder** containing `metaeditor64.exe`.
2. Compile from **PowerShell or cmd**. Git Bash rewrites `/x:` arguments; if you must use it, set `MSYS_NO_PATHCONV=1`. The documented keys are `/compile:`, `/include:`, `/log` (a bare flag) and `/s` (syntax check only).

   ```powershell
   & "<TerminalDir>\metaeditor64.exe" /compile:"<DataDir>\MQL5\Indicators\OrderFlowFP\FootprintChart.mq5" /include:"<DataDir>\MQL5" /log
   ```

   - The log is written next to the source as `FootprintChart.log`. It is UTF-16; its last line looks like `Result: 0 errors, 0 warnings`.
   - Don't trust the exit code.
   - Compile the scripts the same way.
3. Live test: attach the indicator to XAUUSD M5 (and to a futures symbol if the broker offers one). Watch the Experts and Journal tabs.
4. Tester test: in the Strategy Tester, run a trivial EA (or use visual mode with the indicator) on XAUUSD M5 with **"Every tick based on real ticks"**, visual mode, the last 3 days. "Every tick" (generated) or "1 minute OHLC" produce meaningless footprints; say so in the status text if detected.
5. If you cannot run commands (chat-only tool), output **every file completely** in its own code block, headed by its path. Never abbreviate code with `...`. The user will compile and paste back the log.

## 14. Do-nots

- No fake, random or OHLC-estimated volumes. No "demo data" mode.
- No thousands of chart objects (`OBJ_TEXT`/`OBJ_LABEL`): render on the single canvas. The only object allowed is the bitmap label, plus at most a few for tooltips if needed.
- No modifying closed bars. No reading future ticks. No `Sleep`. No blocking loops in `OnCalculate`/`OnTimer`.
- No chart/canvas/indicator calls inside the engine files.
- Don't copy any vendor brand name into code or UI.
- Don't silently change the API contract (§5.7).

## 15. When something is unclear

Follow this document first and the reference images second. If a detail is still open, choose the simplest option consistent with the references, write it to `DECISIONS.md` and continue. Ask the user only when blocked, for example about paths or broker-specific symbols.
