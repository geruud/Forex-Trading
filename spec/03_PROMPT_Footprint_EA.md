# BUILD PROMPT — MT5 Order-Flow Footprint Expert Advisor ("FootprintTrader")

> **How to use this prompt (for the human):** use it **after** the indicator project from `02_PROMPT_Footprint_Indicator.md` exists, its engine passes `FPTests`, and the footprint looks right on your charts. Paste everything below the line into your AI coding tool. Start with `InpTradeMode = SIGNALS_ONLY`, then `VIRTUAL`, and only after the validation protocol (§11) passes, `LIVE` on a **demo** account. Order-flow signals on Forex/CFD feeds are based on tick counts, not real exchange volume. No profitability is implied or guaranteed.

---

## 0. Your role and mission

You are a senior MQL5 quant developer. Build **FootprintTrader**: an MT5 Expert Advisor that trades objective, closed-bar order-flow setups. It computes them with the **same footprint engine** as the OrderFlowFP indicator, by compiling the same `.mqh` files. It must not read indicator buffers.

Quality bar:
- 0 compile errors and 0 warnings.
- Deterministic, with no look-ahead.
- Robust execution and strict risk limits.
- Every signal and every trade logged for analysis.
- A clean separation of four layers: **engine → signals → filters/grading → risk/execution**.

## 1. Prerequisites and file layout

The engine files already exist and pass `FPTests`. **If they don't exist, STOP** and ask the user to paste §5 and §11 of `02_PROMPT_Footprint_Indicator.md`. Build the engine and `FPTests` from that text. §2 below is only a summary, and an engine built from it would not match the indicator.

```
Include\OrderFlowFP\FPTypes.mqh, FPClassifier.mqh, FPEngine.mqh, FPAnalytics.mqh, FPPresets.mqh   (existing engine – do not modify the public API)
Include\OrderFlowFP\FPSignals.mqh            NEW  CFPSignals: setup detectors (pure functions) + evaluator
Include\OrderFlowFP\Trade\FPFilters.mqh      NEW  session/spread/news/volatility/HTF/data-quality filters
Include\OrderFlowFP\Trade\FPRisk.mqh         NEW  position sizing, daily limits, kill switch
Include\OrderFlowFP\Trade\FPExecution.mqh    NEW  CTrade wrapper, retcode handling, pending-order lifecycle, trade management
Include\OrderFlowFP\Trade\FPJournal.mqh      NEW  CSV logging (signals, trades, bar dumps), virtual-trade simulator
Experts\OrderFlowFP\FootprintTrader.mq5      NEW  thin EA: inputs, events, wiring
Scripts\OrderFlowFP\FPSignalTests.mq5        NEW  unit tests for detectors with hand-built CFPBar objects
README_EA.md (workspace)                       how to run, validate and interpret
DECISIONS.md (workspace)                       every choice this prompt does not fix
```

**Rule:** the UI files of the indicator (`Include\OrderFlowFP\UI\*`) must **not** be included by the EA.

## 2. Engine rules you rely on (condensed; the indicator prompt has the full text)

- **Source (frozen at Init):**
  - EXCHANGE_FLAGS: real trade sizes; side from `TICK_FLAG_BUY/SELL`, then the quote rule, then the tick rule.
  - TRADE_TICKS: trade sizes; side from the quote rule (`last>=ask` buy, `last<=bid` sell), then the tick rule.
  - QUOTE_TICKS (Forex/CFD): each bid/ask change = 1 unit, placed at bid; side by mid-price direction, unchanged → previous side, unknown → 50/50 split.
  - A tick counts as a trade **only** via its flags (`TICK_FLAG_LAST|VOLUME|BUY|SELL`), never via `volume`/`last`: unchanged fields hold stale values. The quote rule uses the **previous** tick's bid/ask.
  - **For exact indicator ↔ EA equality, set `InpSource`, `InpBucketPoints` and `InpSessionStart` explicitly and identically in both, and use the same value for the indicator's `InpHistoryBars` and the EA's `InpWarmupBars`.**
- **Rows:** `row = floorDiv(round(price/_Point), bucketPoints)`.
- **Bars:** `barOpen = t − t % PeriodSeconds(tf)`. The forming bar is updated incrementally. On the first tick of the next bar, the old bar is **rebuilt from a full `CopyTicksRange` of its range**. The classifier state is re-derived from the ticks of the 300 s before the bar, classified without accumulating. Then imbalances, POC, stacks, the zone lifecycle and CVD are computed, and the bar is **locked** (`closed=true`). `PopClosedBar()` yields its time **exactly once**, and only for live-path bars, never history bars.
- **History:** loads back to the session start of the oldest bar, plus the previous session. After loading, one chronological pass computes CVD and zones. Only then does `HistoryReady()` return true.
- **Imbalances:** diagonal; BUY at row i: `buy[i] ≥ r × sell[i−1]`; SELL at row i: `sell[i] ≥ r × buy[i+1]`; tiers r = 2/3/4; dominant side ≥ `imbMinVolume`; opposite = 0 → tier 3; edge rows have no imbalance.
- **Stacks:** ≥ `stackMinRows` consecutive same-side imbalance rows → `FPZone` (BUY = support, SELL = resistance). A BUY zone is filled by a later bar with `low < priceLow`; a SELL zone by `high > priceHigh`. Touches count bars that entered the zone without filling it.
- **Value area:** 70 %, expanding two rows at a time from the POC. CVD resets at session start (server time).
- **Timing.** In an EA, every `CopyTicks*` call may **block for up to ~45 s** while history synchronises. In the tester it returns only ticks up to the current simulated time. So:
  - Warm up with **one `CopyTicksRange` call per chunk of at most 7 days** over `[SessionStart(oldest) − 300 s, now]`, and split the ticks into bars locally. The result is identical to per-bar calls, with far fewer blocking calls.
  - On `ERR_HISTORY_TIMEOUT` or a short result, keep the affected bars pending and retry from `OnTimer` (live) or `OnTick` (tester).
  - If the tester has no ticks before the test start date, log it and use the first `InpWarmupBars` bars of the test as warm-up, with no trades.
  - **Never evaluate signals until `HistoryReady()`.**

## 3. ENGINE API CONTRACT v1 (verbatim from the indicator project — do not change)

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

## 4. Signal layer (`FPSignals.mqh`) — new API

```mql5
enum ENUM_FP_SIGNAL { FP_SIG_NONE=0, FP_SIG_ZONE_RETEST=1, FP_SIG_ABSORPTION=2, FP_SIG_EXHAUSTION=3, FP_SIG_DELTA_DIVERGENCE=4 };

struct FPSignal
{
   ENUM_FP_SIGNAL type;
   int      dir;            // +1 long, -1 short
   datetime barTime;        // CLOSED bar that produced it; ALWAYS < open time of the forming bar
   double   entryPrice;     // stop-entry trigger price (bid-based level), or 0 = market at next bar open
   double   stopPrice;      // initial protective stop (bid-based level, before spread adjustment)
   double   refLow, refHigh;// zone or bar extremes used by the setup
   int      grade;          // 2 = A, 1 = B, 0 = C
   int      points;         // grade points (see §6)
   string   info;           // "key=value;..." metrics for the CSV
};

struct FPSignalConfig { /* every Inp* of §4.1-4.3 and §6, copied 1:1 */ };

class CFPSignals
{
public:
   bool        Init(CFPEngine *engine, const FPSignalConfig &cfg);
   int         Evaluate(const datetime closedBarTime, FPSignal &out[]);   // uses ONLY bars with time <= closedBarTime
   // pure detectors (unit-testable with hand-built CFPBar objects):
   static bool DetectAbsorption(CFPBar *bar, const int dir, const FPSignalConfig &cfg, double &m[]);
   static bool DetectExhaustion(CFPBar *bar, const int dir, const FPSignalConfig &cfg, double &m[]);
   static bool ZoneQualifies(const FPZone &z, CFPBar *originBar, const double atr, const FPSignalConfig &cfg);
};
```

`Evaluate` runs once per closed bar, in real time, on the first tick of the next bar, right after `PopClosedBar`. It **never** reads `At(0)`, the forming bar.

Read every indicator and higher-timeframe value at that moment with **shift 1**, the last fully closed bar of its own timeframe, never shift 0. ATR/EMA/SMA handles are created in `OnInit`; check `BarsCalculated` before `CopyBuffer`. (Indicator handles are allowed in `FPSignals` and `Trade\*`, but not in the five engine files.) History bars loaded during warm-up feed zones and context but **never generate trades**.

**As-of rule (no look-ahead).** `Evaluate(T)` uses state *as of the close of bar T*:
- A zone counts as open at T if `filledTime == 0 || filledTime > T`.
- `touchesBefore = touches − (lastTouchTime == T ? 1 : 0)`.
- Walk bars with `ByTime()`, never `At(k)`.
- Never use information from bars after T, even if the engine has already finalised them in the same batch.

**Staleness guard.** Evaluate a popped bar T only if both hold:
- `T + PeriodSeconds(tf) == iTime(_Symbol, tf, 0)`, so it is the bar just before the forming one;
- `TimeCurrent() − (T + PeriodSeconds(tf)) ≤ InpMaxSignalLagSec` (10).

Otherwise log `SKIPPED:LATE` and don't trade it. This catches batched `OnTick` calls, blocking calls, and bars that closed before a weekend or daily break.

### 4.1 Setup SZR — Stacked-imbalance Zone Retest (continuation) — default ON

**Zone qualifies (`ZoneQualifies`)**, judged when the origin bar closes:
1. `rowsCount ≥ InpSZRMinRows` (3).
2. Origin-bar delta% = delta/volume ≥ `+InpSZRMinDeltaPct` (0.10) for a BUY zone, ≤ −0.10 for SELL.
3. The origin bar closes beyond the zone in the stack direction: BUY `close ≥ priceHigh`; SELL `close ≤ priceLow`.
4. Zone height ≤ `InpSZRMaxHeightATR` (0.6) × ATR(14) of the chart timeframe.
5. At least one row in the stack has tier ≥ `InpSZRMinTier` (2). Find the stack rows by index (`rowFrom − originBar.rowLow … rowTo − originBar.rowLow`), never by matching float prices.

**Trigger, on each later closed bar (the "retest bar")**, within `InpSZRMaxAgeBars` (30) bars of the origin:
- The zone is open as of T, and `touchesBefore < InpSZRMaxTouches` (1, i.e. the first retest only). Both use the as-of rule above.
- BUY: the retest bar's `low ≤ priceHigh` (it entered the zone) **and** `close ≥ (priceLow+priceHigh)/2` **and** the retest bar's delta ≥ 0 (buyers defend).
- SELL: mirror image.

**Entry and stop:**
- Market at the next bar open (`entryPrice=0`).
- Stop = `priceLow − max(InpSLBufferATR×ATR, 2×spread)` for longs, mirror for shorts.
- Alternative entry mode `InpSZREntry = LIMIT_AT_ZONE`: place a limit order at `priceHigh` (long) when the zone qualifies, expiring after `InpSZRMaxAgeBars`. Default: `CONFIRM_CLOSE`.

### 4.2 Setup ABS / EXH — Absorption or Exhaustion reversal at an extreme — default ON

**Location (required).** For a long: `bar.low ≤ min(low of the InpRevLookback (20) bars before it)`; the signal bar itself is not part of the lookback. Mirror for shorts. **Shape (required):** `bar.rows ≥ 2*InpRevRows + 1`, so the "bottom k rows" really are the extreme of the bar. Location confluence (adds grade points, §6): the extreme lies within `InpLevelTolATR` (0.25) × ATR of the session VAL/VAH, the previous day's low/high, or the previous session's POC.

**Absorption** (long, at the low), `DetectAbsorption(dir=+1)`. Let `k = InpRevRows` (3), the bottom k rows:
- `sellShare = Σsell / Σ(sell+buy)` over those rows, ≥ `InpABSSellShare` (0.60).
- `concentration = Σ(sell+buy over k rows) / (k × bar.volume/bar.rows)` ≥ `InpABSConcentration` (1.5): heavy trade at the low.
- Close location `(close − low)/(high − low)` ≥ `InpABSCloseFrac` (0.50): price was held.
- `bar.volume ≥ InpRevMinVolMult` (1.0) × SMA(bar volume, 20).
- Mirror everything for shorts at the high (top k rows, buy share).

**Exhaustion** (long), `DetectExhaustion(dir=+1)`:
- The lowest row's total volume ≤ `InpEXHMaxPct` (0.03) × bar.volume: a "finished" auction with only tiny prints at the low.
- The sell volume in rows 0, 1 and 2 is strictly increasing upward (`sell[0] < sell[1] < sell[2]`): selling dried up toward the low.
- Close location ≥ 0.40.
- Mirror for shorts.

**Signal:** ABS or EXH true → one signal (type = ABS if both).
- **Entry:** buy-stop at `bar.high + InpRevEntryOffsetPts × _Point`, valid for `InpRevValidBars` (2) bars.
  - Cancel it **on the first tick** where bid < `bar.low` (long) or bid > `bar.high` (short).
  - Also cancel it on the first tick where the session, spread or news filter turns false.
- **Stop:** `bar.low − max(InpSLBufferATR×ATR, 2×spread)`.
- Mirror for shorts.

### 4.3 Setup DIV — Delta divergence (confluence by default; standalone OFF)

- **Pivots:** strength 3 (3 closed bars on each side). Because a pivot is only confirmed 3 bars later, mark the signal's `barTime` as the confirming bar, **not** the pivot bar.
- **Bearish:** pivot high P2 > previous pivot high P1 (within 30 bars), and the CVD at P2 ≤ the CVD at P1, **or** the bar delta at P2 < 0.
  - CVD resets each session, so compare CVD only if P1 and P2 share the same `SessionStart` and both have `cvdValid`. Otherwise use only the bar-delta condition.
- **Bullish:** mirror image.
- **Usage:** a DIV adds +1 grade point to an ABS/EXH signal at bar T only if its **confirming bar lies in [T − 3 bars, T]**, in the same direction.
  - **Never re-grade a signal after it has been logged.** A later DIV must not upgrade it; that would be look-ahead.
- Standalone trading (`InpDIVStandalone=false`) uses the ABS-style stop entry beyond the confirming bar.

## 5. Filters (`FPFilters.mqh`) — evaluated at signal time; record every rejection reason

| Filter | Rule (default) |
|---|---|
| Data quality | The bar's `state==0`; `ticks ≥ InpMinTicksPerBar` (M1: 20, M5: 60, M15: 150 — input); `InpRequireSource` = ANY / EXCHANGE_ONLY (default ANY, plus a **startup warning** in QUOTE mode) |
| Session | Entries only between `InpTradeStart`–`InpTradeEnd` server time ("08:00"–"20:00"); no entries on Friday after `InpFridayCutoff` ("18:00") |
| Spread | Current spread ≤ `InpMaxSpreadATR` (0.15) × ATR and, **only if `InpMaxSpreadPts > 0`**, also ≤ `InpMaxSpreadPts` points (0 = off) |
| Volatility | ATR(14) ≥ `InpMinATRPts`. ATR regime via `r = ATR(14)/SMA(ATR(14),50)`: SZR requires r ≥ 0.85 (not CHOP); ABS/EXH require r ≤ 1.3 (not a runaway trend) |
| HTF trend | SZR long only if close > EMA(`InpHTFEMA`=50) on `InpHTF` (H1), and vice versa. ABS/EXH: no HTF requirement, but HTF agreement adds a grade point |
| News | Live only: no entries within ±`InpNewsMin` (15) min of HIGH-importance events for the symbol's currencies (`CalendarValueHistory`). In the tester this filter is disabled, with a log line |
| Position | No new entry if a position or pending order with this magic exists on the symbol (`InpMaxPositions`=1). On **netting** accounts, block entries if *any* position exists on the symbol, whatever its magic |

Filters run at signal time **and** on every tick while a pending order from that signal is alive. The pending order is cancelled when the session, spread or news filter turns false.

## 6. Grading

**Hard requirements never score points.** Each item below adds +1.

**SZR:**
- the stack contains a tier-3 row;
- the zone lies within `InpLevelTolATR` × ATR of the session VAL/VAH, the previous day's high/low or the previous session's POC;
- ATR regime TREND;
- origin-bar delta% ≥ 2 × `InpSZRMinDeltaPct`;
- retest-bar delta% ≥ +0.10 (mirror for shorts).

**ABS/EXH, long:**
- HTF agreement;
- location confluence (§4.2);
- a **SELL** imbalance of tier ≥ 2 in the bottom k rows (sellers absorbed);
- a DIV per §4.3;
- ATR regime BASE.

Mirror these for shorts.

Grade A ≥ 4, B = 3, C ≤ 2. Trade only if grade ≥ `InpMinGrade` (B). Log C signals too: they are data.

## 7. Risk management (`FPRisk.mqh`)

- **Size:**
  - `riskMoney = InpRiskPct (0.5) % × AccountInfoDouble(ACCOUNT_EQUITY)`.
  - Loss per lot: `OrderCalcProfit(ORDER_TYPE_BUY or ORDER_TYPE_SELL, symbol, 1.0, fillPrice, stopTriggerPrice, profit)`. It returns a bool: check it, then use `|profit|`.
    - Use the market order types only; stop and limit types fail.
    - Use the spread-converted prices from §8.
    - If widening the SL for stops/freeze levels raises the risk, **re-size the lots**.
  - `lots = floor_to_step(riskMoney / lossPerLot)`, clamped to `SYMBOL_VOLUME_MIN..MAX`.
  - If it is below the minimum volume → skip and log, unless `InpAllowMinLot`.
  - Check `OrderCalcMargin` against free margin.
- **Limits:**
  - `InpMaxTradesPerDay` (4).
  - `InpMaxDailyLossPct` (2.0): closed P/L of today's deals with this magic plus floating P/L, versus the day-start equity. Day start is computed from deal history at server-day start. Reaching it stops new entries until the next server day.
  - `InpMaxConsecLosses` (3): pause until the next day.
  - **Kill switch:** equity drawdown from the EA's recorded peak ≥ `InpMaxDDPct` (10) → close all, disable trading and alert. Keep the peak in a `GlobalVariable` named with symbol and magic. Keep this active in the tester too, which emulates GlobalVariables.
- **Forbidden:** martingale, grid, averaging down, increasing size after losses, removing stops.

## 8. Execution and trade management (`FPExecution.mqh`)

- **CTrade setup:** `SetExpertMagicNumber(InpMagic)`, `SetDeviationInPoints(InpSlippagePts)`, `SetTypeFillingBySymbol(_Symbol)`, synchronous mode.
- **Pre-checks:** `TERMINAL_TRADE_ALLOWED`, `MQL_TRADE_ALLOWED`, `ACCOUNT_TRADE_EXPERT` and `SYMBOL_TRADE_MODE`.
- **Price normalisation:** round prices to `SYMBOL_TRADE_TICK_SIZE`.
- **Distance checks:** enforce `SYMBOL_TRADE_STOPS_LEVEL` and `SYMBOL_TRADE_FREEZE_LEVEL` distances for SL, TP and pending prices. Widen them if needed, then re-check that the risk stays ≤ the limit.
- **Bid/ask conversion.** It depends on the engine's price basis:

  | Basis | Long entry (buy-stop/limit) | Long SL/TP | Short entry | Short SL/TP |
  |---|---|---|---|---|
  | QUOTE + BID (default) | level + current spread (fills on ask) | level as-is (triggers on bid) | level as-is (triggers on bid) | level + spread (triggers on ask) |
  | QUOTE + MID | level + half the spread | level − half the spread | level − half the spread | level + half the spread |
  | EXCHANGE / TRADE | levels are `last`-based; the broker triggers stops on bid/ask, so use the QUOTE + BID conversion as an approximation | | | |

  Write the chosen rule in `DECISIONS.md`.
- **Retcodes:**
  - `DONE` / `PLACED` / `DONE_PARTIAL` → ok.
  - `REQUOTE` / `PRICE_CHANGED` / `PRICE_OFF` → refresh and retry, up to 3 times.
  - `INVALID_STOPS` → widen to the minimum distance and retry once.
  - `NO_MONEY` → skip and log.
  - Anything else → log the retcode and its description and skip.
- **Pending orders:** use the expiry from `SYMBOL_EXPIRATION_MODE` if supported, otherwise cancel manually after N bars. On each closed bar, cancel the pending orders whose invalidation fired.
- **Exits:**
  - The initial TP is `InpTP_R_SZR` (2.0) or `InpTP_R_REV` (1.5, for ABS/EXH) × the initial risk. With `InpTPMode=STRUCTURE`, use the session POC (ABS/EXH) or the opposite VA edge (SZR) if it is ≥ 1.2R away, else the R target.
  - Partial close `InpPartialPct` (50 %) at `InpPartialR` (1.0R), then move the SL to break-even + `InpBEOffsetPts`.
  - Trailing from `InpTrailStartR` (1.5R): `InpTrailMode` = ATR (`InpTrailATR` 1.0 × ATR) or BAR (behind the last closed bar's low/high).
  - Time stop: after `InpTimeStopBars` (12) bars, if profit < `InpTimeStopMinR` (0.3R), close.
  - Optional `InpExitOnOpposite`: close on an opposite grade-A signal.
  - Optional `InpFlatTime` ("" = off).
- **Accounts:** support both netting and hedging (`ACCOUNT_MARGIN_MODE`). Select only positions and orders with this magic and symbol.
- **Track** MAE/MFE in R for every open position on every tick, for the journal.

## 9. Modes, state and logging (`FPJournal.mqh`)

- **`InpTradeMode`:**
  - `SIGNALS_ONLY` (default): log signals, no orders.
  - `VIRTUAL`: simulate entries, stops, targets, partials and time stops tick by tick inside the EA (bid/ask aware), and log the outcomes as if traded. Good for fast signal studies.
  - `LIVE`: real orders.
- **State after a restart:**
  - Rebuild everything deterministically: the engine re-builds history; daily counters come from `HistorySelect(dayStart, TimeCurrent())`; open positions and orders are identified by magic.
  - Persist in GlobalVariables:
    - the kill-switch flag and the equity peak;
    - **per position**, keyed by `POSITION_IDENTIFIER`: `FT_<magic>_<posId>_R` (the initial risk in price units), `_EBAR` (the entry bar time), `_SETUP` and `_PART` (whether the partial close is done).
  - Delete a position's variables when it closes.
  - If they are missing after a restart, recover R from the opening order's `ORDER_SL` (via `HistorySelectByPosition`) and log `STATE:RECOVERED`. Otherwise R-based management (break-even, trailing, time stop) would be wrong after a partial close or a move to break-even.
- **CSV files** in `MQL5\Files\OrderFlowFP\` (`InpCommonFiles` → `FILE_COMMON`; in the tester they go to the agent's sandbox — say this in the README):
  - `signals_<sym>_<tf>.csv`: barTime, setup, dir, grade, points, entryPrice, stopPrice, refLow, refHigh, bar OHLC, volume, delta, delta%, cumDelta, imbBuy/imbSell counts, stack rows, sellShare, concentration, closeFrac, exhaustionPct, ATR, atrRatio, spread, HTF bias, source, decision (`TAKEN` / `FILTERED:<reason>` / `SIGNALS_ONLY`).
  - `trades_<sym>_<tf>.csv`: id/ticket, setup, dir, grade, entry time/price, SL, TP, lots, riskMoney, exit time/price, exit reason, R multiple, MAE_R, MFE_R, bars held, spread at entry, slippage.
  - `InpDumpBars=true` → `dump_<sym>_<tf>_bars.csv` and `_rows.csv`, in exactly the `FPDumpBars` format.
- **Event handling:**
  - `OnTick`: `engine.Update()`, then process each `PopClosedBar` in order (filters → signals → orders), then trade management, then MAE/MFE.
  - `OnTimer` (1 s, live only): `LoadStep` until ready, plus housekeeping.
  - **No signal logic on the forming bar.**
- **`OnTester()`:** compute the criterion from the EA's own journal, one record per **position**, with partial closes merged. `STAT_TRADES` counts each closing deal, and `STAT_PROFIT_FACTOR` becomes huge when there are no losers.
  - Let `n` = the number of positions. If `n < 30`, return 0.
  - `PF_R = Σ(R>0) / |Σ(R<0)|`, capped at 5 (5 if there are no losers).
  - Return `(PF_R − 1) × MathSqrt(n) / MathMax(1.0, TesterStatistics(STAT_EQUITY_DDREL_PERCENT))`.
  - Document it.
- **Optional:** `InpAttachIndicator=true` adds the OrderFlowFP indicator to the chart (`iCustom` + `ChartIndicatorAdd`) **for visuals only**.

## 10. Inputs (exact names; `input group` per section; give each an optimisation range in a comment)

| Group | Inputs (default; range) |
|---|---|
| Mode | `InpTradeMode` (SIGNALS_ONLY), `InpMagic` (240611), `InpCommonFiles` (false), `InpDumpBars` (false), `InpAttachIndicator` (false), `InpMaxSignalLagSec` (10) |
| Research | `InpPlaceboPriceOnly` (false), `InpStressSpreadMult` (1.0), `InpStressSlipPts` (0) |
| Engine | `InpSource` (AUTO), `InpBucketPoints` (0), `InpQuotePrice` (BID), `InpWarmupBars` (300), `InpSessionStart` ("00:00"), `InpImbRatio1/2/3` (2/3/4), `InpImbMinVolume` (10; 3–50), `InpStackMinRows` (3; 2–5) |
| SZR | `InpSZREnable` (true), `InpSZREntry` (CONFIRM_CLOSE), `InpSZRMinRows` (3; 2–5), `InpSZRMinTier` (2; 1–3), `InpSZRMinDeltaPct` (0.10; 0–0.3), `InpSZRMaxHeightATR` (0.6; 0.3–1.0), `InpSZRMaxAgeBars` (30; 10–60), `InpSZRMaxTouches` (1) |
| ABS/EXH | `InpRevEnable` (true), `InpRevLookback` (20; 10–40), `InpRevRows` (3; 2–5), `InpABSSellShare` (0.60; 0.55–0.75), `InpABSConcentration` (1.5; 1.2–2.5), `InpABSCloseFrac` (0.50; 0.4–0.7), `InpEXHMaxPct` (0.03; 0.01–0.06), `InpRevMinVolMult` (1.0; 0.8–2.0), `InpRevEntryOffsetPts` (0), `InpRevValidBars` (2; 1–4), `InpLevelTolATR` (0.25) |
| DIV | `InpDIVPivot` (3), `InpDIVMaxBars` (30), `InpDIVStandalone` (false) |
| Grade | `InpMinGrade` (B) |
| Filters | `InpMinTicksPerBar` (60), `InpRequireSource` (ANY), `InpTradeStart` ("08:00"), `InpTradeEnd` ("20:00"), `InpFridayCutoff` ("18:00"), `InpMaxSpreadPts` (0 = off), `InpMaxSpreadATR` (0.15), `InpMinATRPts` (0), `InpHTF` (H1), `InpHTFEMA` (50), `InpNewsMin` (15), `InpMaxPositions` (1) |
| Risk | `InpRiskPct` (0.5; 0.1–1.0), `InpAllowMinLot` (false), `InpMaxTradesPerDay` (4), `InpMaxDailyLossPct` (2.0), `InpMaxConsecLosses` (3), `InpMaxDDPct` (10) |
| Exits | `InpSLBufferATR` (0.10; 0.05–0.3), `InpTPMode` (R_MULTIPLE), `InpTP_R_SZR` (2.0; 1.5–3), `InpTP_R_REV` (1.5; 1–2.5), `InpPartialPct` (50), `InpPartialR` (1.0), `InpBEOffsetPts` (0), `InpTrailStartR` (1.5), `InpTrailMode` (ATR), `InpTrailATR` (1.0), `InpTimeStopBars` (12), `InpTimeStopMinR` (0.3), `InpExitOnOpposite` (false), `InpFlatTime` ("") |
| Execution | `InpSlippagePts` (20) |

Keep the number of parameters you **optimise at once** ≤ 4 per setup (§11).

## 11. Validation protocol (write it into `README_EA.md`, and build the tooling it needs)

1. **Data:** confirm the broker's real tick history exists for the whole test span (Symbol → Ticks). Use **"Every tick based on real ticks"** only. Other modes give meaningless footprints; print a warning at start in the tester, because the modelling mode cannot be read via the API.
2. **Equality checks:**
   - (a) The EA running **live** in `SIGNALS_ONLY` with `InpDumpBars=true`, versus `FPDumpBars` on the same days with identical engine inputs: the closed-bar files must be identical.
   - (b) Two identical tester runs must produce identical files.
   - (c) Tester versus terminal: report the mismatch count; it need not be 0. The tester serves ticks from its own tick database, which can differ from the terminal's.
3. **Signal study:** run `SIGNALS_ONLY` and `VIRTUAL` over ≥ 6 months. Report per setup and grade: counts, win rate, average R, expectancy after spread, distribution of MFE/MAE.
4. **Optimisation:** coarse grids, ≤ 4 parameters per setup. Prefer **plateaus**: parameter neighbourhoods that are all profitable, not single peaks.
5. **Walk-forward:** rolling 6-month in-sample / 2-month out-of-sample, ≥ 4 folds. Record the parameters chosen per fold and their stability.
6. **Hold-out:** keep the last 20–25 % of the data untouched until the end. Evaluate it once.
7. **Stress.** With "Every tick based on real ticks", the tester replays the recorded bid/ask, so it has no spread or slippage multiplier. Use:
   - `InpStressSpreadMult` (e.g. 1.5) and `InpStressSlipPts`, applied to VIRTUAL fills and as a per-trade R cost in the analysis script;
   - the tester's "Random delay" execution setting;
   - a Monte-Carlo **bootstrap with replacement** of `trades.csv`, ≥ 5000 paths, for the drawdown distribution (a small Python script in the workspace is fine).
8. **Acceptance:**
   - out-of-sample PF ≥ 1.25;
   - ≥ 100 OOS trades;
   - expectancy ≥ 0.10R after costs;
   - 95th-percentile Monte-Carlo drawdown within the user's limit;
   - no single month > 40 % of the profit;
   - forward demo ≥ 6 weeks, matching tester behaviour on the same days.
9. **Per symbol and broker:** quote-tick footprints differ between brokers, so validate each symbol and broker combination separately. Prefer exchange-flag futures symbols where available.
10. **Placebo (the real gate in QUOTE mode).** In QUOTE mode, delta and imbalances are functions of the mid-price path, so the setups may simply be price action in disguise.
    - Run the same study with `InpPlaceboPriceOnly=true`, which removes every order-flow condition and keeps only location, price and risk rules.
    - The real version must beat the placebo on out-of-sample expectancy by ≥ 0.05R. If it doesn't, the order flow adds nothing on this feed: don't trade it.

## 12. Milestones and acceptance tests (stop and report after each)

**E1 — Skeleton + engine + SZR signals, logging only**
- [ ] Compiles with 0 errors and 0 warnings.
- [ ] Warm-up works live and in the tester.
- [ ] `PopClosedBar` drives evaluation.
- [ ] An assertion logs and aborts if any signal has `barTime >=` the forming bar's open.
- [ ] `signals.csv` is produced in a real-tick tester run.
- [ ] The dump-equality check (§11.2) passes.
- [ ] Data-quality gate rejections are logged.

**E2 — Risk + execution + SZR trading (VIRTUAL and LIVE in the tester)**
- [ ] The realised loss at a full stop is within ±10 % of `riskMoney` (logged per trade, given the volume step).
- [ ] No entries outside the session, spread or news windows.
- [ ] Daily loss, consecutive-loss and kill-switch tests can be forced through test inputs and work.
- [ ] Every retcode path is logged.
- [ ] Netting and hedging both work.

**E3 — ABS/EXH + DIV + grading + trade management**
- [ ] `FPSignalTests.mq5` passes with hand-built bars: absorption true and false cases; exhaustion true and false cases; zone qualification; divergence with pivot confirmation delay.
- [ ] Partial close, break-even, trailing and time stop are verified in a visual tester run.
- [ ] VIRTUAL and LIVE-in-tester results agree within slippage on the same period.

**E4 — Robustness and documentation**
- [ ] `OnTester` criterion is implemented.
- [ ] Restart persistence test: stop the EA mid-trade, restart, and it manages the trade correctly.
- [ ] `README_EA.md` contains the validation protocol and how to read the CSVs.
- [ ] The optimisation-ready input ranges are documented.

## 13. Build and test procedure

- Compile the EA from **PowerShell or cmd**, using the paths the user gives you. Git Bash rewrites `/x:` arguments; if you must use it, set `MSYS_NO_PATHCONV=1`.

  ```powershell
  & "<TerminalDir>\metaeditor64.exe" /compile:"<DataDir>\MQL5\Experts\OrderFlowFP\FootprintTrader.mq5" /include:"<DataDir>\MQL5" /log
  ```

  Read `FootprintTrader.log`, written next to the source in UTF-16, for `Result: 0 errors, 0 warnings`.
- Tester: symbol XAUUSD (or a futures symbol), M5, "Every tick based on real ticks", visual mode for the first checks, then non-visual runs for studies.
- If you cannot run commands, output **every file in full** in its own code block, headed by its path. Never abbreviate code.

## 14. Do-nots

- Never use the forming bar, future ticks, or a higher-timeframe bar that has not closed.
- No martingale, grid, averaging down, lot doubling, or stopless trades.
- No hard-coded broker specifics: no fixed point values, fixed filling mode or fixed symbol names. Query everything from `SymbolInfo*`.
- Do not change the engine API (§3). Do not include UI files. Do not read indicator buffers for logic.
- No unbounded loops or `Sleep` in `OnTick`. Keep `OnTick` ≤ 5 ms on average outside bar closes.

## 15. When something is unclear

Follow this document. If a rule is ambiguous, implement the most conservative interpretation (fewer trades, smaller risk), record it in `DECISIONS.md`, and continue. Ask the user only when blocked, for example about paths or symbol names.
