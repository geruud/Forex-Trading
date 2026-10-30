# DECISIONS — FootprintTrader EA and the OrderFlowFP engine

Every choice that `03_PROMPT_Footprint_EA.md` and `02_PROMPT_Footprint_Indicator.md` leave open, as *topic — decision — why*.

This file is merged from `docs/decisions/{engine,signals,trade}.md`. Those three part files are the sources: edit them, then re-merge. Cross-layer interfaces are in `docs/EA_ARCHITECTURE.md`.

## Project-level (orchestrator)

- **Engine built from the indicator spec**: 03 §1 says to stop if the engine files don't exist. `02_PROMPT_Footprint_Indicator.md` is in the workspace, so the engine was built directly from its §5/§11, together with `FPTests` and `FPDumpBars`. The indicator UI (`Include\OrderFlowFP\UI\*`, `FootprintChart.mq5`) is **not** built. The EA doesn't need it, and the spec forbids the EA from including it. — A complete spec was available, and the user asked for the EA.
- **Workspace layout**: the sources live in `MQL5\...` under this folder, mirroring the terminal's `MQL5\`. `tools\build.ps1` copies them into the **standard (demo) MT5 terminal** and compiles there. It never touches the Exness live terminal. — One source of truth in OneDrive; compiled binaries depend on the terminal build.
- **Extra files beyond 03 §1**:
  - `Include\OrderFlowFP\FPSignalTypes.mqh` holds the types shared by the signal and trade layers.
  - `Include\OrderFlowFP\FPDump.mqh` is the single writer of the dump CSV format, used by `FPDumpBars` and the EA.
  - `tools\fp_analyze.py` is the analysis and Monte-Carlo tool of 03 §11.7.
  - — Lets three builders work in parallel against frozen interfaces, and guarantees that the dump-equality check compares the same writer.
- **`FPSignal` additions**: `orderKind`, `validBars`, `invalidPrice`, `tpStructure`, `atr`, `share`, `concentration`, `closeFrac`, `exhaustionPct`, `stackRows`, `divConfluence`, `zoneOrigin`. — The 03 §4 struct can't express stop vs limit entries, pending invalidation, or the per-signal metrics the signals CSV needs.
- **Engine public addition**: `CFPEngine::PrevBarTime()`. — 03 §4 requires walking bars with `ByTime()` and never `At(k)`, and that is impossible across weekend or session gaps without a "previous held bar" query.
- **Management on skipped bars**: bar-close management (pending expiry and invalidation, time stop, BAR trailing) runs on every popped bar, including `SKIPPED:LATE` and `SKIPPED:NOT_READY` bars. Only signal evaluation and new entries are skipped. — Expiry and time stops reduce risk. Skipping them is the less conservative reading (03 §15).
- **Unfilled pending orders in the analysis**: `fp_analyze.py` excludes `exitReason=EXPIRED` rows from every statistic, and reports their count. — An unfilled order is not a trade. Counting it as 0R would dilute expectancy and inflate the out-of-sample trade count.


## Engine decisions (engine agent)

Format: *topic* — decision — why. Spec references: 02 = `02_PROMPT_Footprint_Indicator.md`, 03 = `03_PROMPT_Footprint_EA.md`.

### Public API

- **API additions** — Exactly two, both from EA_ARCHITECTURE §4: `datetime CFPEngine::PrevBarTime(const datetime barTime) const` and `CFPDumpWriter` (`Open/Write/Close`). Everything else public in `CFPEngine`/`CFPAnalytics` is the verbatim contract v1. — The signal layer needs a look-ahead-free backwards walk; the dump format needs one writer.
- **`PrevBarTime` semantics** — Returns the open time of the held bar at index i−1 when `barTime` is exactly a held bar; returns 0 when `barTime` is the oldest held bar or not held at all. It walks held bars, so session/weekend gaps are skipped and nodata bars (state 2) are returned like any other held bar. — Matches "0 = none / not held"; the caller checks `state`.
- **`CFPBar` constructor** — `CFPBar()` zero-initialises every field (`pocIdx = -1`, arrays non-series). It is not an API addition: it changes no contract member. — MQL5 does not initialise class members; hand-built bars in FPSignalTests need defined defaults.
- **`CFPTickSource` virtual destructor** — Added (`virtual ~CFPTickSource()`). — Subclasses (test sources) are safe to delete through a base pointer.
- **Internal helpers that are technically global** (allowed as "helper functions" by 02 §5.7): `FPFloorDiv` (FPTypes), `FPPocIndexArrays`, `FPPocIndexNear`, `FPZoneHitTest` (FPAnalytics); internal classes `CFPClassifier` (FPClassifier.mqh) and `CFPPresets` (FPPresets.mqh); macros `FPE_*`, enum `ENUM_FPE_LOADMODE`, struct `FPELoadInfo`. Other layers should not define these names and should not rely on them.

### Runtime contexts and loading

- **Context detection** — `MQL_TESTER`/`MQL_OPTIMIZATION` → TESTER mode; else `MQL_PROGRAM_TYPE`: indicator → PERBAR, expert → BLOCKING, script/service → SCRIPT. — Spec: one engine, three contexts plus the tester.
- **PERBAR (indicator)** — One non-blocking `CopyTicksRange` per bar, newest first. Accept a bar only when a repeat call ≥ 1 s later returns the same raw count and a tick exists at/after t1 (next held bar has ticks, else `Since(t1,1)`), except for the newest closed bar. No ticks while tick_volume > 0 → pending, retried every 1 s, nodata after 120 s. A bar with ticks that never confirms is accepted after 120 s (not discarded). Nodata bars are re-pended after a reconnect (`TERMINAL_CONNECTED` rising edge). — 02 §5.5.
- **BLOCKING (EA live) and SCRIPT** — Chunked warm-up: one `CopyTicksRange` per run of pending bars over `[t0(oldest)−300 s, t1(newest)−1 ms]`, at most 7 days and about 500k raw ticks per call; ticks are split per bar locally. Chunks go newest first. Error (incl. `ERR_HISTORY_TIMEOUT`) or a bar with 0 ticks while tick_volume > 0 ("short result") keeps the bar pending. EA: retried after 2 s on later `LoadStep` calls, nodata 120 s after the first attempt. Script: retried immediately, nodata after 3 attempts (each attempt is a blocking call, so no hot loop and no `Sleep`). — 03 §2 Timing.
- **Chunk size** — Budgeted by bar tick_volume × a measured ratio (raw ticks per tick_volume, updated after every chunk; the first chunk assumes 5×). — Exchange feeds return several quote ticks per counted tick; a fixed tick_volume budget could exceed the 200 MB memory limit.
- **TESTER** — Chunked like the EA, but never waits on wall time: a bar without ticks is nodata at once (past ticks cannot arrive later in the tester); a failing call is retried at most 3 times (consecutive `LoadStep`s), then nodata. The source decision falls back to QUOTE after 30 s of simulated time. — "Never wait 120 s of wall time for data that can't arrive"; `HistoryReady()` turns true promptly so the EA can warm up on live bars.
- **Equality of chunked, per-bar and live builds** — Guaranteed by construction: every bar is built by the single function `BuildBarFromTicks(bar, t0, ticks[], n)`, which binary-searches `[t0−300 s, t0)` (seed, classified without accumulating) and `[t0, t0+period)` (accumulated) by `time_msc` in whatever array it is given. The chunk array is a superset of the per-bar `CopyTicksRange` result, so the subsequences, the classifier state and the float accumulation order are identical. The live path seeds every new bar from a ring of raw ticks selected with the same window, and every closed live bar is replaced by its rebuild from a fresh per-bar `CopyTicksRange`.
- **Bar list** — `CopyTime(sym, tf, fOpen−1, historyBars)` gives the oldest requested bar O; coverage start C = `SessionStart` of the last bar before `SessionStart(O)` (the previous session *with bars*, so weekends don't produce an empty "previous session"); then one `CopyRates(sym, tf, C, fOpen−1)` gives times and tick volumes together. Bars whose time is not a multiple of `PeriodSeconds` are logged once (ticks are still assigned by `t − t % period`). — `CopyRates` keeps time and tick_volume aligned; date-based requests are immune to a new bar starting between `Init` and `LoadStep`.
- **Bar list failure** — `CopyTime`/`CopyRates` failure is retried (EA/indicator: 1 s apart, give up after 120 s; script/tester: 3 attempts); then the engine continues without history. — Never block readiness forever.
- **Forming-bar bootstrap** — In `Init`: `fOpen = iTime(sym, tf, 0)` (fallback: last tick time, then `TimeCurrent()`, floored to the period); `lastMsc = (fOpen−300 s)·1000`, `k = 0`; then `Update()`. Ticks before fOpen only feed the seed ring; the first tick ≥ fOpen opens the forming bar seeded from that ring. — Exactly "like a history bar", and `Update()` never needs `from = 0`.
- **Source decision** — AUTO samples `Since(sym, 0, 5000)` (the only `from = 0` call; it is in `Init`/`LoadStep`, never in `Update`). TRADE_TICKS requires ≥ 95 % of trade ticks with `last > 0` (spec: "their last > 0"). Empty sample: retried on later `LoadStep` calls; EA/indicator 30 s wall, script 3 attempts, tester 30 s simulated → QUOTE with a warning. In the tester a non-empty sample below 1000 ticks is also deferred (max 30 s simulated), because without pre-test ticks the first samples hold only a few ticks; until the decision `Update()` returns 0 and the bootstrap starts at the bar current at decision time. Set `InpSource` explicitly in the tester. — 02 §5.2.
- **`LoadStep(budgetMs)`** — Order: source → bootstrap → bar list → load (budget checked with `GetTickCount64()` between bars; one unit of work is always done) → chronological pass when nothing is pending → `Update()` → return `HistoryReady()`. A blocking chunk call can exceed the budget (EA only, allowed by 03).

### Live path

- **De-duplication** — `Update()` = `Since(sym, lastMsc, 100000)`, loop while exactly 100000 come back (max 64 loops per call); `FeedTicks()` runs the same `ProcessTicks()`. The engine remembers the k ticks already processed at `lastMsc` and skips a leading returned tick only while `time_msc == lastMsc`, fewer than k were skipped, and the tick is field-for-field identical to the processed tick at that position. Ticks older than `lastMsc` are ignored. — On a real `CopyTicks(from = lastMsc)` result (which always re-delivers those k ticks first) this is exactly the spec's "skip the first k". The pure positional rule silently dropped a NEW same-ms tick when a batch did not start with the re-delivery (FPTests 8.02 fed one tick per `FeedTicks` call and lost b3, which shares b2's ms); the identity check removes that failure mode. Residual ambiguity: only a hand-fed disjoint slice whose first tick is bit-identical to an already-processed same-ms tick.
- **Seeding at every boundary** — On the first tick of a new bar the live classifier is `Reset()` and re-seeded from the ring ticks in `[t0−300 s, t0)`; state is never carried across a boundary. The ring keeps ticks with `time_msc ≥ (forming t0 + period − 300 s)·1000` (the earliest tick any future seed window can need), so it holds ≤ ~300 s of ticks.
- **Finalisation** — On the first tick with `time ≥ t0+period`: rebuild from `Range((t0−300)·1000, (t0+period)·1000−1)`, compare with the live bar (ticks, rows, volumes per row, OHLC, delta, deltaMax/Min — bit exact), keep the rebuild, compute imbalances/POC, run CVD + zone lifecycle (+ new stacks) when the chronological pass has run, lock (`closed = true`), queue for `PopClosedBar`. If the rebuild returns no ticks but the live bar has some, the live bar is kept and counted as a rebuild failure. — 02 §5.5.
- **Mismatch logging** — First 5 mismatches and first 5 rebuild failures printed in detail; a summary every 50 live-closed bars. No per-tick `Print`.
- **Forming bar** — Imbalances, POC and `cumDelta` (session CVD of closed bars + own delta) are refreshed once per `Update()/FeedTicks()` call, not per tick. Before `HistoryReady()` its `cumDelta = 0`, `cvdValid = false`.
- **`historyBars = 0`** — Live-only/test mode: no bar list, no bootstrap, no `iTime`/`CopyTime`; `HistoryReady()` is true right after `Init`. The stream starts at the first tick given to `FeedTicks()`; if `Update()` runs first it starts at `TimeCurrent() − 300 s` (never `from = 0`). Live closes run CVD/zones incrementally at once. — Lets FPTests drive the whole live path, the finalisation rebuild and the seeding through an injected `CFPTickSource` without any bar history. **The EA must pass `historyBars ≥ 1`.**
- **Trimming** — After a live close (only when not loading): keep the newest `historyBars` closed bars (300 in live-only mode) plus their session and the previous session with bars; remove older bars in whole sessions, and zones whose origin bar is removed.
- **Prints ring** — 4096 prints, fed by the bootstrap and the live path only (never by history or rebuilds), newest first.
- **Closed-bar queue** — Unbounded FIFO of live-path bar times; history bars are never queued; bars closed before `HistoryReady()` are queued too (the EA skips them as NOT_READY).

### Bars, rows, analytics

- **Row math** — `PriceToRow = FPFloorDiv(round(price/point), bucket)`; `RowToPrice(row) = (double)row × rowSize` (identical to `CFPBar::RowPrice`, so both give bit-equal prices).
- **Row span cap** — A tick that would make a bar span > 100000 rows is ignored (identically on every path). — Protects memory from a bad tick.
- **Trade ticks with `last ≤ 0` or size ≤ 0** — Not counted (state still updated). Quote ticks need a price > 0. — A print at price 0 would create a bogus row.
- **Quote rule details** — "Previous quote" = bid/ask of the immediately preceding tick of any kind, updated by every tick with bid > 0 and ask > 0; `last ≥ prevAsk` is tested before `last ≤ prevBid` (crossed quotes → BUY). Without a previous quote the tick rule applies. QUOTE mode's `prevMid` is the mid of the previous *counted* tick (uncounted ticks have an unchanged quote anyway).
- **`deltaMax/deltaMin`** — Running extremes starting from 0 at bar open (so deltaMax ≥ 0 ≥ deltaMin).
- **POC tie-break** — Engine bars: exact close row (`PriceToRow(close) − rowLow`). `CFPAnalytics::PocIndex(bar)` (contract signature, no row size available) estimates the close row by interpolating the close between low (row 0) and high (row rows−1); it agrees with the engine whenever the close is at the high/low or the tied rows are not equidistant from it. Profiles: tie → closest to the close of the newest included bar, then the lower row.
- **`ValueArea(p, pct)`** — Recomputes `p.total`; uses `p.pocIdx` if valid, else computes it (tie → lower row); pairs that run past an edge count only the existing rows; when one side is exhausted the other side is taken even if smaller.
- **Imbalance edge cases** — A dominant side of 0 is never an imbalance (even with `imbMinVolume = 0`).
- **Stacks** — `FindStacks` returns BUY stacks bottom-up, then SELL stacks; `priceLow = rowFrom × rowSize`, `priceHigh = (rowTo+1) × rowSize`.
- **Zone lifecycle** — In integer points (no float matching): BUY filled if `low < bottom`, else touched if `low ≤ top`; SELL filled if `high > top`, else touched if `high ≥ bottom`. Only bars after the origin bar; nodata/empty bars are skipped. The touch rule equals the SZR "entered the zone" test, so `touchesBefore = touches − (lastTouchTime == T)` works for the retest bar.
- **CVD** — A nodata bar gets `cumDelta` = running value, `cvdValid = false`, and invalidates the rest of its session. The first held session is assumed complete (the bar list starts at a session start).
- **Session values** — `SessionProfile`/`SessionVWAP` use CLOSED ok bars only (forming bar excluded) and return false/0 until `HistoryReady()`. `SessionProfile` accepts any time and normalises it with `SessionStart()`. `RangeProfile(a, b)` covers shifts min..max and includes the forming bar when shift 0 is in range. — Deterministic, and as-of-safe for the newest closed bar.
- **Init validation** — Fails (with `LastError()`) on W1/MN, unknown symbol, `bucketPoints < 0`, `sessionStartMin` outside 0..1439, `valueAreaPct` outside (0, 1], non-positive ratios. Negative `historyBars` → 0; `stackMinRows < 1` → 1.

### Presets (auto bucket)

- **Symbol matching** — Upper case, keep only A–Z/0–9, then: futures roots (GCE/GC 5 ticks, MES/ES 1, MNQ/ENQ/NQ 4) match the root alone or root + month code + 1–4 digits; CFD/FX keys match the key alone or the key + an alphabetic suffix of ≤ 6 chars (`m`, `PRO`, `ECN`, `CASH`, …). — Avoids false hits like `ESP35` → ES.
- **ATR** — Simple mean of the last 14 true ranges of closed bars from `CopyRates`. niceRound is the nearest value of {1,2,3,5,10,20,25,50,…} on a log scale.
- **No preset and no ATR** — `niceRound(price × 0.0002 / point)` (≈ 2 bp per row) with a log line. — Avoids bucket 1 on high-priced symbols (huge row counts).

### Dump format (`CFPDumpWriter`)

- **Files** — `MQL5\Files\OrderFlowFP\dump_<sym>_<tf>_bars.csv` and `_rows.csv` (`FILE_COMMON` when asked); overwritten by `Open()`; written as UTF-8 bytes with CRLF line ends via `FILE_BIN`; flushed after every bar. Characters illegal in Windows file names are replaced by `_` in `<sym>`.
- **Columns** — bars: `time,open,high,low,close,volume,delta,cumDelta,pocPrice,ticks,buyImbCount,sellImbCount,state,cvdValid` (02 §11 columns + `state` and `cvdValid` appended); rows: `time,rowPrice,sell,buy,imbSell,imbBuy`, one line per row of the bar's range, lowest first. — The two extra columns make nodata bars and broken CVD visible in equality checks.
- **Numbers** — time `yyyy.mm.dd hh:mi:ss`; prices `DoubleToString(p, SYMBOL_DIGITS)` (MID-basis half points are rounded); volumes/deltas `DoubleToString(v, 4)` with trailing zeros and `.` stripped, `-0` → `0`; `pocPrice`/`rowPrice` = row bottom edge (`RowToPrice`), `pocPrice = 0` when the bar has no rows. — Locale-free and a pure function of the doubles, so two writers produce byte-identical lines.
- **FPDumpBars** — Writes every held closed bar (≥ `InpBars`, whole sessions), oldest first, after `HistoryReady()`; loops `LoadStep(1000)` without `Sleep` (bounded by the script retry policy and `InpTimeoutSec`). Prints a QUOTE-mode check Σ(sell+buy) == ticks and the counted-ticks/`iVolume` ratio as diagnostics.

### Tests (FPTests)

- **Injection** — `CFPMemTickSource` serves `Since()` and `Range()` from the same hand-made ticks; `m_visible` simulates arrival over time; it records `Since(from = 0)` calls. Every engine gets it before `Init` and runs with `historyBars = 0`, explicit `bucketPoints` and (except the AUTO tests) an explicit source, so no test reaches `CopyTicks*`, `CopyTime`, `CopyRates` or `iTime`. Prices are integer multiples of the chart symbol's point.
- **Not unit-tested** — The history loaders (chunk split, per-bar acceptance, tester nodata policy) need a real bar series; they share `BuildBarFromTicks` with the tested rebuild path. Validate with FPDumpBars (dump → restart → dump) and the EA-vs-FPDumpBars equality check (03 §11.2).

## Decisions: signals layer (FPSignals, FPFilters, FPSignalTests, fp_analyze)

Each entry is *topic — decision — why*.

### Shared types (FPSignalTypes.mqh, additive only)

- **New metric slots** — `FP_M_RANGESMA 6` (IN, placebo: SMA of bar range of the bars before T) and `FP_M_WICK 7` (out, placebo: rejection-wick fraction). `FP_M_COUNT` stays 8. — The placebo detectors need a price-only input/output, and the free slots already existed.
- **New `FPSignalConfig` fields (at the end)** — `valueAreaPct` (0.70), `placeboWickFrac` (0.40), `placeboSzrBodyATR` (0.60). A value ≤ 0 means "use the default" (`CFPSignals::Init` normalises). — The engine config is not readable through the contract API, so the session value area needs its own percentage (it must equal the engine's `FPConfig.valueAreaPct`). The placebo knobs are needed to match the placebo's trade count to the real version's.
- **Default helpers** — `CFPSignals::DefaultConfig()` and `CFPFilters::DefaultConfig()` fill every spec default. `Init` also fills the spec constants (ATR 14/50, 1.15/0.85, SMA 20, EXH close 0.40, HTF H1/EMA 50) when the caller leaves them at 0. — This way a config the trade layer fills only partly cannot silently disable rules.

### As-of rule and context

- **Indicator reads** — The chart-TF ATR is read at the shift of bar T itself (`iBarShift(T, exact)`), and the HTF EMA/close at the last HTF bar that was complete at T's close. Live, after the staleness guard, these are exactly shift 1 on both timeframes. If T would be shift 0, the read is refused. — A time-derived shift equals "shift 1" when called on time, and it can never look ahead, even if called late, in a test, or for `BuildContext` of an older bar.
- **HTF race** — If the new HTF bar is not yet in the HTF series when T is evaluated, the HTF value is left unknown (`htfBias=0`), which fails the SZR HTF filter. — This is the conservative choice and should be rare.
- **ATR ratio** — `r = ATR(T) / mean(ATR over the 50 bars ending at T)`. TREND if r > 1.15, CHOP if r < 0.85, else BASE (02 §8.8(e)). — This matches the indicator's ATR Reg definition.
- **Context validity** — `ctx.valid` means that ATR and the ATR ratio are known; every setup needs them. Any other unknown field is 0. Without a valid context, `Evaluate` returns 0 signals. — Stops, zone height and all filters depend on ATR.
- **Session profile** — Built by the signals layer from the held bars of T's session with time ≤ T, through a PrevBarTime walk. `SessionProfile()` is not used because it may include later bars. The POC is the maximum volume; on a tie, the row closest to T's close wins, then the lower row. VA uses `CFPAnalytics::ValueArea`. Prices are: POC = mid of its row, VAH = top edge of the VAH row, VAL = bottom edge of the VAL row. — No look-ahead, and a deterministic tie rule.
- **Previous-session POC** — The held bars in [SessionStart(prev), SessionStart(T)). The engine keeps whole sessions, so a partly held session cannot occur except at the oldest edge. On a tie, the lower row wins. — This is the engine's coverage rule.
- **Previous-day high/low** — From the broker's D1 series: the D1 bar strictly before T's server day. — The engine may not hold a whole server day when the session start is not 00:00.
- **volSMA** — The mean volume of the 20 usable bars (closed, state 0, rows > 0) before T. Unusable bars are skipped. The walk is at most 40 bars; if fewer than 20 usable bars are found, volSMA = 0 and the ABS volume test fails. `revMinVolMult ≤ 0` disables the volume test. — A nodata bar has volume 0 and would bias the SMA.
- **Price comparisons** — Comparisons against zone edges, the mid and the lookback extremes use a 1e-8 absolute tolerance. — Row edges are computed as `row × rowSize` and can differ from tick prices by float noise. 1e-8 is far below one point for every symbol.

### SZR

- **Qualification ATR** — `ZoneQualifies` gets the ATR of the origin bar. — The spec says the zone is "judged when its origin bar closes".
- **Age** — Age is counted in held bars with a PrevBarTime walk (times[1..szrMaxAgeBars]), so a zone from before a weekend is not aged by calendar time.
- **Touches** — `touchesBefore = touches − (lastTouchTime==T)`. If `lastTouchTime > T`, the zone is skipped. — The count as of T cannot be rebuilt in that case. It cannot happen after the staleness guard.
- **Retest bar** — Besides low ≤ priceHigh, close ≥ mid and delta ≥ 0, the retest also requires low ≥ priceLow (SELL: high ≤ priceHigh). — This is consistent with the engine fill rule: such a bar fills the zone, so the zone is not open at T anyway.
- **One SZR per direction per bar** — When several zones trigger at T, the one with the most grade points is kept, then the newest origin. — Overlapping zones describe the same event, and duplicates would distort the statistics.
- **LIMIT_AT_ZONE** — One LIMIT signal is emitted on the origin bar T when the zone qualifies: entry priceHigh (long) / priceLow (short), `validBars = szrMaxAgeBars`, and `invalidPrice` = the far zone edge (long: cancel when bid < priceLow, i.e. the zone has been filled). CONFIRM and LIMIT are exclusive. The retest-delta grade item cannot score (there is no retest bar), so LIMIT signals have at most 4 points. — This follows the spec, with the zone-fill invalidation of the SZR thesis.
- **Location confluence (SZR)** — The zone interval lies within `levelTolATR × ATR(T)` of any of VAL, VAH, prev-day high, prev-day low or prev-session POC. — The spec lists them without a direction for SZR. A support zone at VAH or VAL is a valid confluence.

### ABS / EXH

- **Location** — Uses exactly the `revLookback` held bars before T, excluding T. If any of them is unusable (state ≠ 0 or no rows), there is no signal. — This is conservative: an unknown extreme cannot prove a new low.
- **Location confluence (ABS/EXH)** — Directional. A long's low is compared with VAL, prev-day low and prev-session POC. A short's high is compared with VAH, prev-day high and prev-session POC. — §4.2 pairs "VAL/VAH" and "low/high" with "mirror for shorts". This is the conservative reading (fewer points).
- **EXH has no volume test** — §4.2 lists none for EXH, only for ABS.
- **Metrics** — Both detectors always run, so share, concentration and exhaustion% are logged for every ABS/EXH signal, whichever detector fired. Both detectors true gives one signal of type ABS.
- **Sell-imbalance grade item** — Long: `imbSell` tier ≥ 2 in the bottom k rows. Short: `imbBuy` tier ≥ 2 in the top k rows.
- **tpStructure** — The session POC, set only when it lies beyond the entry on the profit side; otherwise 0. SZR uses VAH (long) / VAL (short) against the reference entry: T's close for MARKET, the limit price for LIMIT. — A target on the wrong side is meaningless. The trade layer still applies the ≥ 1.2R rule.

### DIV

- **Pivots** — Strength `divPivot`, strict inequality on both sides. Every bar in the pivot window must be usable. — Ties and holes do not make a pivot. This is conservative.
- **P1** — The nearest earlier pivot of the same kind with P2 − P1 ≤ `divMaxBars`. If it does not satisfy P2 > P1, there is no divergence; the search does not go further back. — This is the standard "previous swing" reading and the conservative one.
- **Detector** — `DetectDivergence(FPDivBar b[], count, dir, pivot, maxBars, p1, p2)` is pure. It reports a divergence confirmed at index count−1 (P2 = count−1−pivot). — Being pure makes it testable without the engine. The confirmation delay is structural: before the confirming bar, P2 is not a pivot.
- **CVD** — CVD is compared only if P1 and P2 have the same `SessionStart` and both are `cvdValid`. Otherwise only the bar-delta condition applies.
- **Confluence** — For ABS/EXH at T, divergences confirmed at T, T−1, T−2 and T−3 (held bars) are checked, each judged on the window that ends at its own confirming bar. `Evaluate` is stateless, so no logged signal can ever be re-graded.
- **Standalone DIV** — Emitted only when `divStandalone=true`, and never in placebo mode. It is a stop entry beyond the confirming bar T (ABS-style, `revEntryOffsetPts`, `revValidBars`). The stop and `invalidPrice` are beyond the P2 pivot extreme. Grade items: HTF agreement, location confluence (P2 extreme), regime BASE, so the maximum is B. The regime filter is the reversal one (r ≤ 1.3). — The spec gives no DIV grade list or stop rule. P2 is the structure that the divergence invalidates on.

### Output and grading

- **Order of `out[]`** — Grade descending, points descending, then setup SZR < ABS < EXH < DIV, then long before short. — The trade layer processes `out[]` in order, so the best signal gets the position slot.
- **`LastContext`** — Returns true after any `Evaluate` call. The caller checks `ctx.valid`.

### Placebo (`placeboPriceOnly`, 03 §11.10)

- **ABS'** — Location and shape are kept. Share, concentration and volume are replaced by: rejection wick ≥ `placeboWickFrac` (long: (min(open,close) − low)/range), closeFrac ≥ `absCloseFrac` (kept), and range ≥ `revMinVolMult` × SMA(range, 20). — This is the "pin bar at a 20-bar extreme with above-average range" null hypothesis that order flow must beat.
- **EXH'** — Location and shape are kept, plus closeFrac ≥ 0.40 and a body in the signal direction. The thin-extreme and drying-up tests are removed.
- **SZR'** — The zone is the `szrMinRows` rows at the base of an impulse bar (long: from the open's row upward). It qualifies when body ≥ `placeboSzrBodyATR` × ATR(origin), replacing delta% and tier. Close beyond the zone and height ≤ `szrMaxHeightATR` × ATR are kept. Fill and touches are rebuilt as of T from the bars between origin and T, with the engine's rules. In the retest, "delta ≥ 0" becomes "close ≥ open" (long). Age, first-touch, mid-close, stop, entry and LIMIT handling are unchanged. — Stacked imbalances are themselves order flow, so the price analogue is the classic "demand zone at the base of a displacement bar".
- **DIV** — Removed entirely: no confluence point and no standalone signals.
- **Grading** — Placebo signals get `grade = InpMinGrade` (they always pass the grade gate). `points` holds only the price-only items (SZR: location, TREND; ABS/EXH: HTF, location, BASE). `info` starts with `placebo=1`. — The order-flow grade items cannot exist in placebo mode. Grading the price items against the A/B/C cut-offs would filter almost every placebo signal and make the trade counts incomparable. The placebo's selectivity is therefore placed entirely in its detection knobs.
- **Count calibration** — `fp_analyze --placebo` prints the placebo/real trade-count ratio per setup and warns outside 0.67–1.5. Tune `placeboWickFrac` (ABS') and `placeboSzrBodyATR` (SZR') in-sample until the counts match, then compare out of sample. — An expectancy comparison between very different selection intensities is meaningless.

### Filters

- **Decision time** — `CheckSignal` evaluates session, Friday and news at T + PeriodSeconds(tf), the open of the bar after T. — It is deterministic and identical in the tester and live, and it is the moment the entry is placed.
- **Session window** — [start, end). start > end wraps midnight. start == end means the whole day. An empty input (−1) is an open edge (00:00 / 24:00). A malformed input (−2) closes the window, and `StartupWarnings` says so.
- **Friday** — Blocked at or after the cutoff on Fridays (server time). "" is off. A malformed cutoff blocks the whole Friday.
- **CheckLive** — Checks SESSION, FRIDAY, SPREAD and NEWS. — The Friday cutoff is part of the spec's Session row.
- **Spread** — `CheckSignal` uses the context's spread, read at signal time. `CheckLive` reads the current tick. `maxSpreadATR ≤ 0` turns the ATR test off. The points test applies only when `maxSpreadPts > 0`. An unknown ATR fails SPREAD, ATR_MIN and REGIME.
- **Regime** — SZR needs r ≥ 0.85. ABS, EXH and standalone DIV need r ≤ 1.30. r = 0 (unknown) fails.
- **HTF** — Hard for SZR only: `ctx.htfBias` must equal `sig.dir`, and bias 0 (unknown or flat) fails. The filters create no indicator handles; HTF, ATR and spread come from `FPContext`, so `FPFilterConfig.htf/htfEma` must equal the signal config's values.
- **News** — Live only. `CalendarValueHistory` is queried per currency (`SYMBOL_CURRENCY_BASE/PROFIT/MARGIN`, de-duplicated) over [now−1d, now+3d], keeping HIGH importance events. The cache refreshes at most every 900 s (60 s after a failure) from `OnTimer`, or lazily on the first check. It is never queried per tick. An entry is blocked within ±`newsMin` minutes of an event. Currencies the calendar does not track (not in `CalendarCountries()`, e.g. XAU) are skipped before the query, and `ERR_CALENDAR_NO_DATA` for a currency is not a failure. *(Fixed 2026-10-27 on the first demo run: for XAU, `CalendarValueHistory` returns false with error 0, which had blocked every live entry; the first successful load now logs `news calendar loaded - N HIGH event(s)`.)* A failing `CalendarCountries()` or any other calendar failure blocks entries with NEWS and logs once. `InpNewsMin=0` disables the filter. In the tester, the filter is off with one log line at `Init`. — This follows the conservative rule (§15). The user keeps an explicit off switch.
- **DATA_SOURCE** — Uses `engine.ActiveSource()`. `StartupWarnings()` should be called again after `HistoryReady()`, because AUTO may decide late.

### fp_analyze.py

- **Cost model** — net R = rMultiple − `--cost-r` − (stress spread mult − 1) × spreadAtEntry × point / |entry − sl| − 2 × stress slip × point / |entry − sl|. The stress terms need `--point`. — rMultiple already contains the spread actually paid. The stress terms are extra (03 §11.7).
- **Evaluation set** — The OOS part (entryTime ≥ `--split`) when given; otherwise all trades, flagged as not out-of-sample.
- **Monte Carlo** — A bootstrap with replacement of the evaluation set's net R, with path length = n, default 5000 paths, seeded. It reports max DD in R (additive) and in % (compounded at `--risk-pct` per 1R), as p50/p90/p95/p99/worst. It warns if `--paths` < 5000.
- **Monthly concentration** — Net R is grouped by exit month. A month's share = its net R / total net R. The check fails if any share exceeds 40 % or if total net R ≤ 0. — Dividing by the net total (not by the sum of winning months) is the stricter reading.
- **Acceptance** — OOS PF(R) ≥ 1.25, ≥ 100 trades, expectancy ≥ 0.10R after costs, MC p95 DD% ≤ `--dd-limit-pct`, month share ≤ 40 %, real − placebo OOS expectancy ≥ 0.05R. The forward demo is a MANUAL item. `--strict` makes the exit code 1 on any FAIL.

## Trade layer decisions (FPRisk, FPExecution, FPJournal, FootprintTrader.mq5)

Format: **topic** — decision — why. Spec references: 03 = `03_PROMPT_Footprint_EA.md`, ARCH = `docs\EA_ARCHITECTURE.md`.

### Structure

- **Include chain** — `Trade\FPFilters` ← `Trade\FPRisk` ← `Trade\FPExecution` ← `Trade\FPJournal` ← EA. The EA includes only `FPJournal.mqh`. — Linear, no cycles. The VIRTUAL simulator (FPJournal) needs the shared planner and decision routine (FPExecution), which need sizing (FPRisk).
- **One decision routine** — `CFTTradeLogic` (FPExecution.mqh) holds every management rule: partial, break-even, ATR/BAR trailing, time stop, opposite exit, flat time, MAE/MFE. LIVE (`CFPExecution`) applies its actions through CTrade; VIRTUAL (`CFPVirtual`) applies them to a simulated book. Neither has rules of its own. — E3 parity: the two modes can differ only in fills, not in decisions.
- **One planner** — `CFTPlanner` turns a signal into an order plan (conversion, normalisation, distances, TP, validity, sizing) for both modes. VIRTUAL calls it with the *stressed* quote. — Same parity argument; with `InpStressSpreadMult=1`, `InpStressSlipPts=0` both modes plan identical orders.
- **Helper names** — Global helpers, structs and defines of the trade layer use the prefix `FT`/`CFT` (`FTAddReason`, `FTPlan`, `CFTPlanner`, ...). — No clash with the engine/signals agents' globals.

### Prices (03 §8)

- **Bid/ask conversion rule (required by 03 §8)** — The engine basis is read from `engine.ActiveSource()` and `InpQuotePrice` every time a plan is built. `spread` = current ask − bid at planning time.

  | Basis | Long entry (stop/limit) | Long SL / TP | Short entry | Short SL / TP |
  |---|---|---|---|---|
  | QUOTE + BID (default) | level + spread (fills on ask) | level (triggers on bid) | level (triggers on bid) | level + spread (triggers on ask) |
  | QUOTE + MID | level + spread/2 | level − spread/2 | level − spread/2 | level + spread/2 |
  | EXCHANGE_FLAGS / TRADE_TICKS | as QUOTE + BID (approximation) | | | |
  | AUTO not decided yet | as QUOTE + BID | | | |

  Market entries use the live ask (long) / bid (short). R (price units) = |entry − SL| in **execution prices**, so it includes the spread a long pays. R-multiple targets are computed from the execution entry: `TP = entry ± mult × R`. — This is the table of 03 §8. Computing R in execution prices makes a full stop equal −1 R in money, with no spread error.
- **Rounding to the tick size** — Stop entries are rounded so the trigger is never better than the level (buy-stop up, sell-stop down); limit entries are rounded away from the market; the SL is rounded away from the entry; the TP is rounded to the nearest tick. — Conservative: rounding never shrinks the stop or improves the trigger.
- **Broker distance** — `minDist = max(STOPS_LEVEL, FREEZE_LEVEL) + 1 tick` (0 when both are 0), applied to the SL, TP and pending price. — 03 §8 names both levels. The extra tick avoids `>=` vs `>` edge cases. A pending order is also never placed inside the freeze band, so it stays cancellable.
- **SL widening re-sizes** — If the SL must be widened to `minDist`, the plan is sized with the widened SL (`p.slWidened`, noted in the signal `info`). — 03 §7: "if widening raises the risk, re-size".
- **Pending price already crossed** — Buy-stop at or below the ask, or buy-limit at or above the ask (mirror for shorts) at placement becomes a **market** order at the current price. Trigger inside `minDist` → moved out to `minDist`. — This is how a broker treats a gap through a stop. It is identical in VIRTUAL, so parity holds.
- **Invalidated before entry** — If the bid is already beyond `sig.invalidPrice` when the plan is built, the signal is `FILTERED:PLAN`. — The order would be cancelled on its first tick anyway; this avoids a pointless request.

### Retcodes and requests (03 §8)

- **Policy** — DONE/PLACED/DONE_PARTIAL → ok. REQUOTE/PRICE_CHANGED/PRICE_OFF → re-plan from a fresh quote and retry, at most 3 retries. INVALID_STOPS → re-plan once with `extra = max(minDist, spread) + 2 ticks` (re-sized) and retry. NO_MONEY → skip. Anything else → skip. **Every attempt** is printed as `FT EXEC <OP> #n: sent=.. rc=.. [description] -> policy | details | err=..`. — 03 §8. Retries are immediate; there is no `Sleep`.
- **Extra fallbacks (additive)** — INVALID_EXPIRATION on a pending → retry once as GTC with manual expiry. INVALID_FILL on a pending → retry once with `ORDER_FILLING_RETURN`. NO_CHANGES on a modify counts as ok. — Real brokers reject some expiries and filling modes for pending orders. One retry, then skip.
- **Synchronous CTrade** — `SetExpertMagicNumber`, `SetDeviationInPoints(InpSlippagePts)`, `SetTypeFillingBySymbol`, `SetAsyncMode(false)`, `LogLevel(ERRORS)`. — 03 §8. The EA prints its own retcode lines, so CTrade's tester log is not needed.
- **Pre-checks** — TERMINAL_TRADE_ALLOWED, MQL_TRADE_ALLOWED, ACCOUNT_TRADE_EXPERT, ACCOUNT_TRADE_ALLOWED, SYMBOL_TRADE_MODE (incl. long-only/short-only) are checked **before** the signal row is written. A failure gives reason `TRADE_DISABLED`. — The signal row then never says TAKEN for an order that could not be sent.
- **Netting closes** — On netting accounts, partial and full closes are opposite deals with `request.position = <position ticket>`. Hedging uses `CTrade::PositionClose` / `PositionClosePartial`. — `CTrade::PositionClosePartial` returns false on netting. Binding the deal to the position ticket means it can never open a reverse position, even if the stop hit first.

### Pending lifecycle (03 §4.2, §5, §8)

- **Expiry** — If `SYMBOL_EXPIRATION_MODE` has SPECIFIED: `ORDER_TIME_SPECIFIED` at `T + (validBars + 1) × period` (the open of the first bar after the validity window). The manual check is **always** active as well: on every popped closed bar (skipped ones included), cancel when `bars after T >= validBars`. `validBars <= 0` on a pending entry is treated as 1. — 03 §8. Belt and braces: the manual check covers weekends and brokers that ignore expiry.
- **Per-tick cancel** — Cancel when `bid < invalidPrice` (long) or `bid > invalidPrice` (short), or when `filters.CheckLive(now, atr)` fails (session, spread, news; called once per tick while a pending exists). — 03 §4.2, §5, and the FPSignalTypes contract (bid-based).
- **Closed-bar cancel** — On every popped bar T after the signal bar (skipped ones included, if the engine holds T closed), cancel when T's engine-basis low < invalidPrice (long) / high > invalidPrice (short). — It catches ticks the terminal coalesced between `OnTick` calls.
- **Risk events cancel pendings** — Kill switch, daily-loss hit, consecutive-loss pause and flat time cancel every pending entry of this magic. — Otherwise a pending order could fill after a limit tripped. This is conservative (03 §15).

### Sizing and limits (03 §7)

- **riskMoney** — `riskMoney = lots × lossPerLot`, with `lossPerLot = |OrderCalcProfit(BUY/SELL, 1 lot, entry, SL)|` on execution prices, i.e. the money lost at a full stop **with the final lots**. `riskTarget = InpRiskPct % × equity` is logged too. `rMultiple = net money P/L ÷ riskMoney`. — With volume steps (e.g. 0.01 lot on gold), riskMoney can sit well below the target. Dividing by the target would make a clean full stop read −0.8 R. The ±10 % check of E2 is printed per stop-out as `FT RISKCHECK` (realised vs riskMoney, and vs riskTarget).
- **Min lot** — Size < `SYMBOL_VOLUME_MIN` → `FILTERED:RISK_MIN_LOT`, unless `InpAllowMinLot`. Then the min lot is used and the actual risk % goes into `info`. — The user opted in; the risk is made visible.
- **Margin** — `OrderCalcMargin` > free margin → `RISK_MARGIN`. VIRTUAL compares with virtual free margin (virtual equity − margin of open virtual trades).
- **Server day** — The day runs 00:00–24:00 server time (`TimeCurrent()`), independent of `InpSessionStart`. — 03 §7 says "server day".
- **Day-start equity (LIVE)** — `ACCOUNT_BALANCE − Σ(profit + swap + commission + fee)` of today's BUY/SELL deals of the **whole account**. Balance and credit operations are excluded. It is computed once per day (at start, after a restart, at the day change). — "Derived from deal history at server-day start" (03 §7). Excluding balance operations stops the tester's initial deposit (dated today) from zeroing it. Floating P/L at 00:00 cannot be derived from history and is ignored.
- **Daily loss** — `closed P/L today (this magic + symbol, incl. commission/swap) + floating P/L of this magic's positions ≤ −InpMaxDailyLossPct % × day-start equity` → no entries until the next day. Pendings are cancelled, positions stay. The hit is sticky for the day and persisted in `FT_<sym>_<magic>_DAYBLOCK` (LIVE). — 03 §7 ("stops new entries"). The GV keeps a restart from re-enabling trading the same day.
- **Daily trades** — `entries filled today (IN deals) + entries submitted and not yet filled ≥ InpMaxTradesPerDay` → `RISK_DAILY_TRADES`. — Counting live pendings stops two entries racing past the limit.
- **Consecutive losses** — Counted **within the server day** over closed positions (net money P/L < 0, incl. costs), newest first. Reaching the limit pauses entries until the next day; the counter resets at day start. — "Pause until the next day" implies a daily reset. A cross-day streak would re-pause after one loss.
- **Daily counters without per-tick history scans** — LIVE: `HistorySelect(dayStart, …)` runs at init, on every `TRADE_TRANSACTION_DEAL_ADD` of the symbol (flag from `OnTradeTransaction`, processed on the next tick) and at the day change, **never per tick**. Floating P/L comes from the open-positions loop. VIRTUAL: counters are updated incrementally by the simulator. — 03 §14 OnTick budget.
- **Kill switch** — Account equity vs the recorded peak (`FT_<symbol>_<magic>_PEAK`, written when it rises by ≥ 0.01 % and at deinit). DD ≥ `InpMaxDDPct` → close all positions and cancel all pendings of this magic, `Alert`, flag `FT_<symbol>_<magic>_KILL = 1`. All later signals are `FILTERED:RISK_KILL`; the EA keeps logging. The flag survives restarts. Reset: delete the GV (F3) or run once with `InpTestResetKill=true`. — 03 §7. Throttled writes avoid a GV write per tick. The tester emulates GVs, so the switch works there.
- **Risk in VIRTUAL** — The same `CFPRisk` runs on **virtual** values: virtual equity = account balance at EA start + realised virtual P/L + floating virtual P/L. Sizing, margin, daily trades, daily loss, consecutive losses and the kill switch all apply. State is in memory only (no GVs) and resets at each EA start. — Applying the limits makes VIRTUAL runs comparable with LIVE-in-tester (E3). Memory-only keeps virtual studies from tripping the live kill switch.
- **Risk in SIGNALS_ONLY** — No risk gates and no sizing. Only filters, `GRADE` and `WARMUP` decide. `positionBusy = false`. — There are no trades whose outcomes could drive the limits. The study shows what the filters alone would allow, deterministically.
- **No martingale / grid / averaging** — Size depends only on equity, `InpRiskPct` and the stop distance. Netting never adds to a position (`positionBusy` is true whenever any position or own pending exists on the symbol). Stops are never removed or widened after entry; they only ratchet. — 03 §7, §14.

### Trade management (03 §8)

- **Partial** — At open profit ≥ `InpPartialR` R, close `floor(lotsInit × InpPartialPct %)` to the volume step. If that is below the min volume, or the remainder would be, skip the partial (logged) and still do the break-even. `InpPartialPct` must be in [0, 100). `InpPartialR ≤ 0` disables partial and break-even. — There is no rounding up, ever.
- **Break-even** — After the partial stage, SL → fill price ± `InpBEOffsetPts`, rounded away from the market. It is only set where the broker distance allows; otherwise it is retried each tick. — Uses the actual fill, not the planned entry.
- **Trailing** — Active once MFE ≥ `InpTrailStartR` (it stays active). ATR mode: candidate SL = bid − `InpTrailATR` × ATR (long) / ask + … (short), with ATR from the last valid context (evaluated bar, or `BuildContext(T)` on a skipped bar). Each tick, it moves only if it improves the SL by ≥ 0.1 R. BAR mode: on every popped closed bar, behind that bar's engine-basis low/high, converted with the table. Both ratchet only and are clamped to `minDist`. — The 0.1 R step stops per-tick modification spam. It is the same in VIRTUAL.
- **Time stop** — On every popped bar close (skipped ones included) with `barsCompleted ≥ InpTimeStopBars` and open R < `InpTimeStopMinR` → close (TIME). `barsCompleted` counts bars from the entry bar to T inclusive. It is checked on every bar after N, not only at bar N. — "After N bars" includes later bars. The conservative reading is that a trade cannot drift below 0.3 R after bar 12 and stay open.
- **Open R** — `(exit-side price − fill) × dir ÷ R`, where long exits at the bid and short at the ask. — It is what a market close would realise now.
- **Opposite exit** — With `InpExitOnOpposite`, close when the **raw** signal list of an evaluated (not skipped) bar at or after the entry bar has an opposite-direction grade A (filters not required). — 03 §8 says "an opposite grade-A signal". Bars before the entry bar are ignored, so a position is not closed by a conflicting signal of its own signal bar.
- **Flat time** — From `InpFlatTime` to midnight: close positions (FLAT), cancel pendings, and block entries with the reason `FLAT`. — A position opened after flat time would be closed at once.
- **Management on skipped bars** (orchestrator decision; ARCH §6 updated) — Bar-close management runs on **every** popped bar, including those logged `SKIPPED:NOT_READY` / `SKIPPED:LATE`: pending expiry and invalidation, time stop, BAR trailing. Only signal evaluation and new entries are skipped; exit-on-opposite stays signal-driven, so it never fires on a skipped bar. On a skipped bar the ATR is refreshed from `signals.BuildContext(T)` when history and indicators are ready; otherwise the last valid ATR is kept. If no ATR is known at all, only ATR trailing waits, and `FT MGMT` logs it. Invalidation and BAR trailing use bar T only when the engine holds it closed. — Expiry and time stops reduce risk, so skipping them would be the less conservative choice. Positions recovered after a restart need management while history is still loading.
- **Live positions in every mode** — Positions and pendings of this magic are recovered and managed in SIGNALS_ONLY and VIRTUAL too (no new live entries there). — A mode change or restart never leaves a live trade unmanaged.

### State and restart (03 §9)

- **GlobalVariables per position** — `FT_<magic>_<id>_` + `R`, `EBAR`, `SETUP`, `PART` (spec), plus `SIG`, `GRD`, `RISK`, `RTGT`, `LOTS`, `PLAN`, `SPRD`, `TPI`, `PDONE`, `BE` (SL stage), `MAE`, `MFE`, and for pendings `KIND`, `INV`, `SBAR`, `VB`. They are written at **order placement**, keyed by the order ticket, because `POSITION_IDENTIFIER` = the opening order's ticket. They are updated at fill (R from the actual fill), on stage changes and at each bar close (MAE/MFE). `GlobalVariablesDeleteAll(prefix)` runs on close or cancel. — Extra keys make a restarted trade's journal row complete. Bar-close cadence keeps GV writes off the tick path.
- **Restart, GVs present** (`R` and `EBAR`) → state restored, `FT STATE:RESTORED`.
- **Restart, GVs missing** → `HistorySelectByPosition(id)`: R from the opening order's `ORDER_SL` (the order whose ticket = id, else the earliest order with an SL). Fallbacks, in order: the planned `R` GV, then the current SL if it is still on the loss side. The setup comes from the GV, else from the order comment `FT <SETUP> <GRADE> <signalId>`. `lotsInit` = Σ IN deal volume; the partial is done if the volume shrank; BE is done if the SL is at or beyond the entry. Logs `FT STATE:RECOVERED`. If R cannot be recovered, the position is **unmanaged** for R rules (broker SL/TP, kill switch and flat time still apply), and this is logged. — 03 §9.
- **Pending orders after a restart** — Restored from GVs (per-tick invalidation resumes); without GVs they are **cancelled** (`FT STATE:PENDING_CANCELLED`). — Their invalidation cannot be managed without the signal data. Conservative.
- **VIRTUAL state** — Memory only. Open or pending virtual trades are discarded at EA stop and at the end of a test, and are not journaled. LIVE-in-tester positions still open at the end of a test are closed by the tester and not journaled either. — Both modes drop the last open trade, so parity holds.

### Journal (ARCH §7)

- **IDs** — `signalId = barTime(unix) × 100 + index in Evaluate's output`. Skipped-bar rows use `0`. LIVE: `tradeId = POSITION_IDENTIFIER`, `ticket = position ticket`. VIRTUAL: `tradeId = signalId`, `ticket = 0`. Unfilled pending rows: LIVE `tradeId = ticket = order ticket`, VIRTUAL `tradeId = signalId`. — The numbers fit a double exactly (GV storage) and join signals ↔ trades.
- **EXPIRED rows** — A pending entry that ends unfilled (broker expiry, manual expiry, invalidation, live filter, risk event, kill, flat) writes a trades row with `exitReason = EXPIRED`, `profitMoney = 0`, and **empty** `exitPrice`, `rMultiple`, `maeR`, `mfeR` (n/a). They are excluded from OnTester; the cancel reason is in the Experts log. — ARCH §7 lists EXPIRED as an exit reason, and fill rates are useful data. An unfilled order has no R. Empty fields (not 0) make any R statistic skip the row; `tools\fp_analyze.py` currently skips them as "malformed" (harmless warning). It should skip `exitReason == EXPIRED` explicitly.
- **exitPrice / exitReason** — `exitPrice` = volume-weighted average of all closing deals (partials merged). `exitReason` = the EA-initiated reason (TIME/OPPOSITE/FLAT/KILL), else from `DEAL_REASON` of the last closing deal: SL → SL / BE / TRAIL by SL stage; TP → TP; anything else (manual, stop-out, other EA) → MANUAL. — One row per position, partials merged.
- **maeR / mfeR** — Non-negative magnitudes in R of the worst adverse and best favourable open profit, tracked every tick and including the final exit price. So a full stop shows maeR ≥ ~1. — The classic excursion definition. Including the exit price makes LIVE (which never sees the stop tick) match VIRTUAL.
- **barsHeld** — Bars opened after the entry bar up to the exit bar (same bar = 0). A TIME exit at N bars shows N.
- **slippagePts** — `(fill − planned entry) × dir ÷ point`; positive = worse than planned. — Planned = the quote (market) or the trigger price (pending).
- **profitMoney** — LIVE: Σ(profit + swap + commission + fee) of all deals of the position. VIRTUAL: Σ OrderCalcProfit of each exit; **no commission or swap**. — VIRTUAL has no access to the broker's cost model. Compare parity runs on a commission-free symbol, or add the cost in the analysis.
- **info column** — The signal's `info` plus the trade layer's `kind, entry, sl, tp, rPts, lots, riskMoney, riskTarget, spreadPts, note, precheck`. Commas become `;`. — One row then explains every decision.
- **Additive reason codes** — After the canonical `GRADE, RISK_DAILY_TRADES, RISK_DAILY_LOSS, RISK_CONSEC_LOSSES, RISK_KILL, RISK_MIN_LOT, RISK_MARGIN, WARMUP` the trade layer may append `FLAT`, `PLAN` (no valid order plan: no quote, stop not beyond the entry, invalidated before entry, OrderCalcProfit failure) and `TRADE_DISABLED`. `FILTER` is used only if `CheckSignal` returns false without a code. — Every rejection is explained. These are additions to ARCH §5.
- **Skipped rows** — `setup=NONE, dir=0, grade empty`, bar fields from `engine.ByTime(T)` when held; `decision = SKIPPED:NOT_READY|LATE|ASSERT`, with info `engine`/`indicators` or `forming=…;lagSec=…`.
- **Files** — Append, header only when the file is new (a header mismatch prints a warning). CRLF, ANSI, `.` decimals, `TIME_DATE|TIME_SECONDS`. Rows are flushed each write live and at close in the tester. Names have no magic number, so run **one EA instance per symbol/TF per Files folder**. — ARCH §7 fixes the names.
- **Bar dump** — `InpDumpBars` uses the engine's `CFPDumpWriter` (overwrites on open), written in the §6 position: only evaluated bars, not NOT_READY/LATE ones. — ARCH §4: one writer of the format.

### EA program

- **Timing** — Live: `EventSetTimer(1)`, `LoadStep(250 ms)` per second until `HistoryReady()`. Tester: `LoadStep(2000 ms)` at the start of each `OnTick` until ready. `Update()` runs on every tick. — 03 §2/§9: no long blocking in OnInit.
- **Staleness and assertion** — `T + PeriodSeconds == iTime(_Symbol,_Period,0)` and `TimeCurrent() − (T + P) ≤ InpMaxSignalLagSec`, else `SKIPPED:LATE`. Then `T < forming open` is asserted for the bar and **for every signal's barTime**. A violation prints `FT ASSERT`, writes `SKIPPED:ASSERT` and calls `ExpertRemove()`. `IndicatorsReady()` = false is treated like NOT_READY. — 03 §4, E1. Known rare race: a tick arriving between the terminal's bar update and the engine's `CopyTicks` can make one bar LATE (conservative).
- **Warm-up fallback** — When history first becomes ready, the held closed bars are walked (`At(1)`, then `PrevBarTime`). If the bars with `state == 0` are fewer than `InpWarmupBars / 2`, or nodata bars outnumber them, the next `InpWarmupBars` live bars are warm-up (`FILTERED:WARMUP`). This applies live and in the tester. `filters.StartupWarnings()` runs again at that moment, because AUTO may decide the source late. — 03 §2. A thin warm-up also makes zones and CVD unreliable live.
- **Tester modelling warning** — Printed at every tester start; the mode cannot be read. — 03 §11.1.
- **InpAttachIndicator** — `iCustom` with the name in a variable (no tester auto-dependency on an indicator that is not part of this build), skipped in non-visual tests, one log line on failure; visuals only, buffers never read. — The indicator is not part of this build.
- **Input validation** — HH:MM fields must parse (`""` = off; for `InpSessionStart` `""` means 00:00). `0 < InpRiskPct ≤ 10`, `0 ≤ InpPartialPct < 100`, `InpMaxPositions ≥ 1`, `InpStressSpreadMult ≥ 1`, `0 ≤ InpMaxDDPct < 100`, `0 ≤ InpMaxDailyLossPct < 100`; otherwise `INIT_PARAMETERS_INCORRECT`. A flat time not after the trade start prints a warning.
- **Config mapping** — `FPConfig`: `historyBars = InpWarmupBars`, `valueAreaPct = 0.70`, session from `InpSessionStart`. `FPSignalConfig`: every input, plus the spec constants (ATR 14/50, regime 1.15/0.85, SMA 20, EXH close 0.40). The signals agent's additions are set explicitly: `valueAreaPct = 0.70` (equal to the engine's), `placeboWickFrac = 0.40`, `placeboSzrBodyATR = 0.60`. `FPFilterConfig`: inputs plus `szrMinAtrRatio 0.85`, `revMaxAtrRatio 1.30`, and `htf`/`htfEma` from the same inputs as the signals. Both structs are first filled by `CFPSignals::DefaultConfig` / `CFPFilters::DefaultConfig`, so future additive fields get the owner's defaults. `InpWarmupBars ≥ 1` is enforced (`historyBars = 0` is the engine's injected-tick test mode).
- **VIRTUAL tick source** — Tester: every `OnTick` (the tester calls it for every tick). Live: every quote tick since the last processed one is replayed with `CopyTicks(COPY_TICKS_INFO)` and same-millisecond de-duplication, so coalesced ticks are not missed. Orders and positions ignore ticks at or before their creation tick. — "Tick by tick" (03 §9). The creation-tick rule stops replayed older ticks from hitting a new entry.
- **VIRTUAL fill model** — vBid = bid; vAsk = bid + spread × `InpStressSpreadMult`; slip = `InpStressSlipPts` × point. Market and stop entries fill at vAsk + slip (long) / vBid − slip (short). Limits fill at the limit price. A stop-loss fills at vBid − slip (long) / vAsk + slip (short) on the triggering tick (gaps pass through). A take-profit fills at the TP price. EA closes and partials fill at the exit side ± slip. Broker-side SL/TP are checked before the management decision on each tick. — This mirrors how the tester fills LIVE orders, plus the stress.
- **Test hooks (E2)** — `InpTestDailyLossAt`, `InpTestConsecLossAt`, `InpTestKillAt` (datetime, 0 = off) fire once at the first tick at or after the time. They act through the normal checks: a synthetic realised loss equal to the daily limit for that day only; the consecutive-loss counter set to the limit; the equity peak raised to `equity / (1 − DD%) × 1.0001`. `InpTestResetKill` deletes the persisted kill/peak/day-block GVs at start. All are off by default and print `FT TEST` lines. — The real code paths fire (cancel, close all, Alert, gate codes), and the next day re-enables trading.
- **OnTick budget** — No history scans per tick; GV writes only on events and bar closes. The average and max `OnTick` time outside bar closes is printed at deinit (`FT PERF`). — 03 §14 (≤ 5 ms).
- **OnTester** — From the EA's own per-position records of this run (filled rows only, partials merged): `n < 30 → 0`; `PF_R = Σ(R>0)/|Σ(R<0)|` capped at 5 (5 without losers, 1 if there are neither); `(PF_R − 1) × √n / max(1, STAT_EQUITY_DDREL_PERCENT)`. A summary is printed (`FT ONTESTER`). — 03 §9. In VIRTUAL the tester's equity DD is ~0, so the divisor is 1.

## UI decisions (indicator UI agent)

Format: *topic* — decision — why. Spec: 02 = `02_PROMPT_Footprint_Indicator.md` (§1, §3, §6–10, §12). The engine files are untouched.

### Files and structure

- **Files** — `Indicators\OrderFlowFP\FootprintChart.mq5` (inputs, events, scheduling, buffers, alerts) and `Include\OrderFlowFP\UI\{FPTheme, FPCanvas, FPLayout, FPTrades, FPAnalyst, FPPanels, FPRenderer}.mqh`. Two files beyond 02 §3: `FPCanvas.mqh` (CCanvas subclass: font cache + primitives) and `FPTrades.mqh` (read-only trade overlay data). Test tooling: `Scripts\OrderFlowFP\FPShot.mq5` + `tools\mt5_screenshot.ps1`. — Keep each file single-purpose.
- **Include chain** — FPTheme ← FPCanvas ← FPLayout (includes `..\FPEngine.mqh`) ← FPAnalyst ← FPPanels; FPLayout + FPTrades ← FPRenderer. UI global names use `FPUI*`, `CFP<Ui>` or `FPB_*`/`FPT_*`/`FPTONE_*`. They never reuse the engine helpers or the EA's `FPTfName`. — The EA never includes UI (EA_ARCHITECTURE §3).
- **Engine API used** — Only the public contract: `Init, LoadStep, Update, PopClosedBar, Total, At, ByTime, ActiveSource, RowSize, PriceToRow, RowToPrice, SessionStart, SessionProfile, RangeProfile, SessionVWAP, Zones, Prints, LastError`, plus `CFPAnalytics::FindStacks`. `At()` pointers are used only inside one event handler and never stored.

### Scheduling and performance

- **Timer step** — `EventSetMillisecondTimer(50)`. Each step calls `LoadStep(budget)`, also after the history is ready, because `LoadStep` contains the reconnect/nodata retry and then calls `Update()`. Then: pop closed bars, periodic work, and a redraw when dirty and ≥ `InpRedrawMs` since the last draw (250 ms while loading). When a redraw is due, the load budget drops to 15 ms. — Spec §6; keeps a step near 50 ms.
- **Periodic work** — Studies and flow stats every 1 s; Signal Meter every 2 s; book every 2 s, or 200 ms after `OnBookEvent`; Chart Analyst every `InpAnalystRefreshSec` and on every closed bar; session POC/VWAP/buy-sell on every closed bar (every 1 s while loading); trades poll every 500 ms. A dirty frame is forced once per second for the countdown and "Updated Ns ago".
- **OnCalculate** — `Update()` plus the data-window buffers. In the tester, the whole step runs from `OnCalculate`. The non-visual tester creates no canvas and changes no chart properties.
- **Measured** — Draw averages: 4.1–4.8 ms at 1857×978 (s=1.0, side panels on, 15 bars, 400 frames, market open); 8.4 ms at 2487×1408 (s=1.5); 3.8–4.6 ms without side panels (25 bars). Split at 1857×978: footprint 1.5–2.0, table+chrome 0.7, side panels 1.1–1.4, `Canvas.Update` 0.8–1.0 ms. The max frame was 8–35 ms. Logged every 100 frames by `OrderFlowFP UI: draw avg ...`.
- **Loading responsiveness** — Measured: history ready after 14–18 s (≈444 bars); timer steps while loading average 45–55 ms, and the UI part is ≈0–6 ms of that. The worst step is always inside the engine's `LoadStep`. Usually 66–140 ms; on cold starts 341 ms and 977 ms were seen once each, when the first tick files are read. It is logged as `history ready after ... | worst step: ...`.
- **Text** — `CCanvas::TextOut` calls `TextSetFont` on every call. `CFPCanvas` registers fonts once and switches only on an id change. Footprint cells go through `CFPTextBatch`, which draws grouped by font, so there are ~6 font switches per frame. Earlier runs measured 7.5–9 ms averages, but those ran while the other agent's tester passes loaded the CPU.
- **Fonts** — Positive `TextSetFont` sizes behave as cell heights, so Segoe UI renders ~20 % smaller than its nominal point size. The cell numbers use the 02 formula `px = round(pt·96/72·s)`. The UI fonts were calibrated against the reference frames: buttons 8.8 pt, labels 9.5 pt, small 8.5 pt, titles 10.5 pt, tabs 7.5 pt semibold.
- **Scale** — `s = InpUIScalePct/100 × TERMINAL_SCREEN_DPI/96`, applied to all geometry. The auto-hide rule is `W < 1500·s`. On this 150 % DPI screen, the docked default chart (2146×790 px) auto-hides the side panels, while a 2487×1408 chart shows them.

### Layout and look

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

### Studies, Signal Meter, Chart Analyst (display only)

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

### Panels and overlays

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

### Interaction

- **Mouse** — Wheel over the footprint zooms ±1 per notch (6–40). Shift+wheel scrolls 3 bars per notch. Left-drag in the plot pans both axes: horizontally by bars, vertically by rows (this turns vertical auto-follow off). A drag suppresses the click that follows it.
- **Buttons** — ZOOM IN/OUT ±2. UP/DOWN move 80·s px and turn vertical auto-follow off. LIVE, Home and RESET turn it back on. RESET = default zoom + live + re-centre, and it re-`Init`s the engine when nodata bars exist (02 §5.5: "retry nodata on RESET"; the engine has no public retry call). SIDE PANELS toggles the effective state and forces it.
- **Keyboard** — `T` cycles the 16 accent themes and `L` toggles Dark/Light (02 §12 M5). ←/→ scroll bars, ↑/↓ move vertically, +/− zoom. `CHART_KEYBOARD_CONTROL` is set to false so the hidden native chart does not scroll; it is restored on deinit.
- **Scrolled view** — Anchored to the newest visible bar's time, so new bars do not shift it. While scrolled, vertical auto-follow centres on the visible bars.
- **Test hooks** — The custom chart events `7701` (lparam = button id) and `7702` (lparam = key code) behave exactly like a click or a key press. FPShot uses them to check the buttons and keys automatically.

### Chart and EA coexistence

- **Chart properties** — Saved at init, then set, then restored on deinit: `CHART_FOREGROUND, SHOW_GRID, SHOW_OHLC, SHOW_ONE_CLICK, MOUSE_SCROLL, EVENT_MOUSE_MOVE, EVENT_MOUSE_WHEEL, KEYBOARD_CONTROL` (+ `CHART_SHOW` only with `InpHideNativeChart`). There is one `OBJ_BITMAP_LABEL` named `OFPFC_<n>` (unique per instance), and it is deleted on deinit. Timers are killed and handles and the book are released.
- **EA attach** — Verified with FPShot: `iCustom(_Symbol,_Period,"OrderFlowFP\\FootprintChart")` with default inputs + `ChartIndicatorAdd(0,0,h)` from a program on the same chart. The canvas appears on that chart, the indicator gets ready, and all 8 buffers read back through the handle (CumDelta chains bar to bar).
- **Two instances on one chart** — They work, but property restore is order-dependent: the first instance removed restores the originals while the second is still running. — Documented, not handled.

### Trade overlay (user requirement, read-only)

- **Data** — Polled at most every 500 ms (indicators get no `OnTrade`). The signature covers positions and orders of the chart symbol (ticket, volume, SL, TP, open price), filtered by magic (`InpTradeMagic`, −1 = all), plus `HistoryDealsTotal` / last ticket since the oldest held bar. The drawing data is rebuilt when the signature changes, and on every poll while positions are open (floating P/L).
- **Closed trades** — Exit deals (`OUT`, `OUT_BY`, `INOUT`) are paired with the latest IN deal of the same `DEAL_POSITION_ID` inside the window. The magic filter applies to the IN deal, so manual or SL/TP exits of EA trades still show. P/L = profit + swap + commission of the exit deal. A partial close gives one marker per exit deal.
- **Drawing** — Entry/SL/TP lines run across the plot behind the cells: solid for positions, dashed for pending orders. Colours: BUY entry (59,130,246), SELL entry (236,72,153), SL (239,68,68), TP (34,197,94). A label at the left end shows side, lots, price, P/L and ticket. Tags on the own price scale (`BUY 0.05`, `SL`, `TP`, `BUY STOP 0.05`) are filled for positions, outlined for pendings, de-overlapped, and pinned to the scale edge when off-screen. Closed trades get an entry triangle and an exit square at bar-column/price, joined by a dashed line in the bull colour (profit) or the bear colour (loss). Open positions get an entry triangle.
- **Verification** — By code review and compile only: there were no EA trades on the account during the session, and placing orders was not allowed.

### Engine additions that would help (not made: the engine is frozen)

1. `int PendingCount() const` / `int HistoryTotal() const`. The UI now scans all held bars for the loading progress, which is cheap but O(bars).
2. `void RetryNoData()`. The UI's RESET currently re-`Init`s the whole engine to retry nodata bars.
3. LoadStep budget overshoot on cold start: one per-bar `CopyTicksRange` can take 0.1–1 s when tick files are first read. A finer-grained check, or deferring `TickAfter()`'s extra `CopyTicks` to the next step, would keep a step under the 40 ms budget.

## Decisions: frequency retune (2026-10-27, v1.10)

**Goal (user).** With default inputs on XAUUSD M5 (Exness demo, QUOTE_TICKS, row 0.40), the EA should take at least 5–6 filled trades per trading day: a mean of at least 5.5 and a median of at least 5. This was measured in the Strategy Tester with real ticks, on an out-of-sample window that was not used for tuning.

**Windows.**
- In-sample (IS, used for tuning): 2026-06-01 … 08-31, 66 trading days.
- Out-of-sample (OOS, evaluated once at the end): 2026-09-01 … 10-23, 39 trading days.
- Every agent log was checked for `real ticks absent`; there were none in any run.

**How a trading day is counted.**
- A trading day is a weekday server date.
- Sunday-evening entries (the market opens at 22:00) count for Monday.

Short entries: *topic — decision — why*.

### Method

- **Research mode (new, `InpResearchAllSignals`, VIRTUAL only).**
  - **What it does.** Every signal of a deliberately loose detector configuration is simulated as an independent virtual trade, and its filter, grade and risk reasons are logged.
  - **Loose configuration used.** Lookback 5, 2 extreme rows, ABS thresholds 0, all day, risk limits off.
  - **Why.** With the bar dump, `fp_analyze.py --research` recomputes every detector metric from the footprint rows. Any tighter configuration is then a subset, and replaying the EA's one-position rule, daily cap, pause, daily loss and kill switch in time order gives its trades and results without another tester run.
  - **Validation.** The replay reproduced the EA's own spec run trade for trade (23/23 orders, the same fills and exits). It also predicted the final configuration's IS result: 477 fills at +0.07 R against the EA's 479 at +0.06 R.
  - **Cost.** Six research passes (one per trade-management variant) took about 80 s each.
- **Tester driver.** `mt5_run_tester.ps1` now takes the terminal lock (CreateNew, 45 s polling, stale after 60 min with no terminal running) and leaves a 90 s gap between runs. It also accepts `-SetFile`, `-Params`, `-Tag` and `-Deposit`, and has a `research` run.
- **Lock incident and fix.**
  - **What happened.** The first version judged a lock's age by the file's LastWriteTime. The workspace is on OneDrive, and the UI agent's fresh lock, created at 19:54:56, showed a LastWriteTime 256 min old. At 19:58 my driver therefore deleted that lock as stale and ran a test; no terminal was running at that moment.
  - **The fix.** The age is now taken from the newest of the creation time, the write time and any timestamp written in the lock.
  - **Check.** Afterwards the driver waited correctly for the UI agent's locks (20:01 and 20:03).

### Funnel with the spec defaults (IS, 66 days; research data replayed, identical to the EA run)

| Stage | Signals left | Lost |
|---|---|---|
| Detected (EXH 1289, SZR 7, ABS 0) | 1296 (19.6/day) | |
| SESSION 08:00–20:00 | 695 | **601** |
| FRIDAY, REGIME ≤ 1.30, HTF | 542 | 153 |
| GRADE ≥ B (3 of 5 points) | 23 | **519** |
| Risk caps (4/day, 3 losses, 2 %) | 23 | 0 (never bound) |
| Orders → filled | **13 filled**, 10 expired | |

Two filters bound: the **session** (46 % of the signals) and the **grade** (96 % of what remained; on this feed almost every signal is grade C). ABS never fired. The extreme-row concentration of reversal bars is 0.49 at the median, 1.09 at p90 and 1.70 at p99, against the 1.5 required. The spec OOS run had 8 fills in 39 days.

### Changes (all are input defaults; the spec values are in `MQL5\Presets\FootprintTrader_spec.set`)

- **Grade gate — `InpMinGrade` B→C plus a new `InpMinPoints` = 1.**
  - Grade C with **at least one** confluence point is traded; zero-point signals are not.
  - On the EXH candidates, expectancy rose with the points in both management variants: 0 points −0.075 / −0.051 R (n=251), 1 point −0.004 / −0.022 R, 2 points +0.044 / −0.014 R, 3 points +0.09 / +0.11 R (n=31).
  - With everything else final (IS replay), grade ≥ B gives 0.5 trades a day and ≥ 2 points gives 3.0; ≥ 1 point gives 7.2.
- **Session — all day (`"00:00"`–`"00:00"`), Friday cutoff 18:00 kept.**
  - The session was the largest single loss of signals. Keeping 08:00–20:00 with everything else final gives 3.8 trades a day at +0.02 R.
  - Hour-of-day results were noise: no hour differed robustly, with n ≈ 140 per hour and ±0.2 R swings.
  - The daily break (21:00–22:00) and the spread filter (≤ 0.15 ATR) handle the reopen.
- **Reversal regime band — `InpRevMaxATRRatio` 1.30→1.60.** It was a hard-coded constant and is now an input.
  - IS at lookback 20: band 1.30 gave +0.03 R at 6.4 trades/day, 1.45 / 1.6 / 2.0 / off gave +0.04…+0.07 R at 6.9–7.5 trades/day.
  - 1.6 keeps the spec's "don't fade a runaway trend" guard for extreme expansions.
- **Reversal target — `InpTP_R_REV` 1.5→2.0.**
  - The research passes are paired: the same entries, only the exits differ.
  - TP 1 R without a partial: +0.010 R; TP 1.5 R: +0.050 R; TP 2 R: +0.070 R; TP 2.5 R: ≈ TP 3 R: +0.069 R.
  - The ordering was the same in every selection tried. 2.0 is the lower edge of the plateau and inside the spec range.
  - The partial at 1 R, break-even, the trail from 1.5 R and the time stop are unchanged.
- **Daily trade cap — `InpMaxTradesPerDay` 4→10.** At 4 the cap binds on 59 of 66 IS days (4.05 trades a day). At 10 it bound on 10 of 66 days in the EA run.
- **Consecutive-loss protection — the pause is now time-limited (new `InpConsecPauseMin` = 60).**
  - After 3 losses in a row, entries pause for 60 min, then a new streak starts. 0 restores the spec (no entries until the next day).
  - The spec version (pause to the next day) fires on 22 of 66 IS days and lowers the rate from 7.2 to 6.4 a day (median 8 → 6).
  - In IS with 60 min: 22 pauses, blocking signals on 16 days.
  - **The restart rule is kept in LIVE.** The pause end and the streak reset are persisted in GlobalVariables (`_PAUSE`, `_CRESET`), so a restart does not re-trigger the pause on the same losses.
- **Daily loss limit — 2 % kept.** It stopped trading on 7 of 66 IS days (EA run). At 3 % the rate would be 7.3 instead of 7.2, which is not worth it.
- **Kill switch — `InpMaxDDPct` 10→15.** The control stays; only its threshold changes. The reason:
  - The final configuration has an expectancy of about 0 R and a standard deviation of about 1.05 R per trade, at about 7 trades a day. Its drawdown therefore behaves like a random walk.
  - IS max drawdown: 24.4 R ≈ 11.5 % at 0.5 % risk. In the replay a 10 % switch fires in-sample, which drops the IS rate to 5.6 a day.
  - **Day-block bootstrap of the IS trade days, probability that the switch fires:**

    | Risk per trade | Kill switch | Within 38 days | Within a quarter |
    |---|---|---|---|
    | 0.5 % | 10 % | 0.17–0.31 | 0.34–0.56 |
    | 0.5 % | 15 % | ≈ 0.06 | ≈ 0.18 |
    | 0.25 % | 10 % | ≈ 0.01 | ≈ 0.06 |

    A 10 % switch at 0.5 % risk would systematically end the run on noise. At 15 % it still stops a genuinely losing configuration: −0.05 R per trade at 7 trades a day is about −15 % in a quarter.
- **Risk per trade — kept at 0.5 % (not changed).** My recommendation, which the user must decide: **0.25 %** at this frequency, with the kill switch back at 10 %.
  - The spec budgeted at most 4 trades a day at 0.5 %, i.e. ≤ 2 % at risk a day.
  - At 7–10 trades a day, 0.25 % keeps the daily risk budget comparable and the kill switch at the same money level (40 R).
  - At 0.25 % the switch fires on noise with a probability of about 1 % per OOS window instead of 20–30 %.
- **Rejected after testing.** All of these were tested on IS:
  - **Recalibrated ABS** (share 0.55–0.60, concentration 0.6–1.0, lookback 10/20, 2 or 3 rows): 0.3–4 signals a day, and the sign of the result flipped between 2 and 3 rows for the same thresholds (e.g. +0.22 vs −0.30 R). That is noise, so ABS was left at the spec values; it remains dormant on quote ticks.
  - **Lookback 15/25** (≈ 0 R, against +0.05…0.07 at 20). The spec's 20 sits on a local spike, so the IS edge is likely overstated.
  - **Close fraction 0.45/0.5:** slightly better IS, fewer trades; kept at 0.40, the spec value.
  - **Pending validity of 4 bars:** +0.02 R against +0.05 R, for 2 % more fills.
  - **Loose SZR** (−0.15 R, n=54), **standalone DIV** (≈ 0 R) and **two positions at a time**: not adopted.
- **Late bars after a feed stall — new `InpMaxLatePendingSec` = 180** (spec 0). See the side issue below.

### Results

All runs below are actual EA tester passes:
- VIRTUAL, real ticks, 10 000 USD, `InpSource=3`;
- default inputs unless stated;
- trading days = Mon–Fri, with days without bars counted as 0.

"Max DD" is in R; 1 R = 0.5 % of equity. SZR was the only other setup that traded, with 2 fills (IS) and 1 fill (Feb–May); ABS and DIV made 0. All the rest are EXH.

| Config | Window | Fills | Trades/day mean | Median | Days ≥ 5 | Win % | Avg R | PF | Max DD | Net R |
|---|---|---|---|---|---|---|---|---|---|---|
| spec | IS (66 d) | 13 | 0.20 | 0 | 0 % | 61.5 | +0.212 | 1.54 | 2.0 | +2.8 |
| **v1.10** | IS (66 d) | 479 | **7.26** | **8** | 85 % | 50.7 | +0.059 | 1.12 | 24.4 | +28.4 |
| spec | OOS (39 d) | 8 | 0.21 | 0 | 0 % | 37.5 | −0.175 | 0.73 | 4.1 | −1.4 |
| **v1.10** | OOS (39 d) | 89 | **2.28** | **0** | 28 % | 33.7 | **−0.339** | 0.47 | 34.2 | −30.2 |
| v1.10, LIVE in the tester | OOS | 85 | 2.18 | 0 | 26 % | 32.9 | −0.356 | 0.45 | 34.2 | −30.2 |
| v1.10, kill switch off (diagnostic) | OOS | 307 | 7.87 | 8 | 95 % | 45.3 | −0.113 | 0.79 | 52.0 | −34.7 |
| v1.10 (auto row picked 2.0) | Feb–May (85 d) | 92 | 1.08 | 0 | 5 % | 47.8 | −0.094 | 0.80 | 12.7 | −8.7 |
| v1.10, row pinned 0.40 (diagnostic) | Feb–May (85 d) | 596 | 7.01 | 7 | 85 % | 49.8 | +0.001 | 1.00 | 27.1 | +0.7 |

**The frequency goal is met structurally, but not in the OOS measurement.**
- **While the EA trades,** it takes 7–8 fills a day with a median of 7–8, in every window where the row is 0.40: IS, OOS before the kill, OOS without the kill switch, and Feb–May.
- **OOS, it lost.** From 2 to 16 September it lost 2–5 R almost every day, on longs and shorts alike. Price ran through the reversal entries: only 31 % reached +1 R, against 49 % in IS. The spread, ATR and stop sizes were unchanged.
- **The kill switch stopped it.** At −15 % on 16 September the kill switch closed everything and stopped the EA (LIVE 01:35, VIRTUAL 10:20). For the rest of the window it took no trades, so the OOS average is 2.3 a day.
- **Without the kill switch**, the whole OOS window gives 7.9 trades a day at −0.11 R.
- **Across all windows the expectancy is about zero or negative:**

  | Window | Avg R per trade |
  |---|---|
  | Feb–May | +0.00 |
  | June | strongly positive |
  | July–August | ≈ 0 |
  | September | −0.3 |
  | October (no kill switch) | ≈ 0 (−2 R over the month) |

  The IS +0.06 R was luck from June.

**Per-day risk controls** (cut-short counts):

| Window | Daily loss limit | Consecutive-loss pause (60 min) | Cap of 10 reached | Kill switch |
|---|---|---|---|---|
| IS | stopped trading on 7 of 66 days | 22 pauses, blocking signals on 16 days | on 10 days | did not fire |
| OOS | 4 days | 11 pauses | — | fired on day 12 |

### Side issue: the 06:15 bar processed 124 s late (live demo, 2026-10-27)

**What the logs show** (terminal journal, Experts log; local time = server + 8 h):
- The connection flapped 6 times between 06:18:43 and 06:23:20 server time:
  - lost at 06:18:43, re-synchronised at 06:19:44;
  - lost at 06:20:25, back at 06:20:27;
  - lost at 06:21:59, back at 06:22:03;
  - lost again at 06:22:07 and 06:23:19.
- At shutdown the EA reported `FT PERF … max 135583 ms`: **one `OnTick` call blocked for 135.6 s**, from about 06:19:47 to 06:22:02.

**Root cause.**
- The call was `CFPEngine::Update()` → `CFPTickSource::Since()` → `CopyTicks(COPY_TICKS_ALL, from = last processed msc)`. In an EA, CopyTicks waits while the terminal re-synchronises its tick history after a reconnect. Here the re-sync kept being interrupted by the next disconnect.
- The call finally returned −1 with error 4401 (ERR_HISTORY_NOT_FOUND) at 06:22:02, just after the 06:21:59 disconnect. That is the `Update error` line.
- The very next tick, 06:22:04, succeeded. It delivered all the ticks since 06:19:4x, crossed the 06:20:00 boundary and finalised the 06:15 bar. The pop was 124 s after the close, beyond the 10 s guard, hence `SKIPPED:LATE`.
- **Recovery after the failure was already immediate (2 s).** The lost time is the block itself, during which nothing in the single-threaded EA can run.
- The 1-tick live-vs-rebuild mismatch on the 06:20 bar comes from the same re-sync: a tick was back-filled after the live path had read the batch. The engine kept the rebuild, which is the correct, deterministic result.
- None of the tester's 66 + 38 `SKIPPED:LATE` were of this kind; all are the 20:55 bar before the daily break, which must stay skipped.

**What the EA now does (my files only).**
1. **New `InpMaxLatePendingSec` (default 180 s).** A bar that is still the one just before the forming bar, but processed 10–180 s late, is evaluated instead of skipped.
   - Only **pending** entries whose level the market has not crossed may be placed. A late **market** entry, or a stop level already crossed (which the planner would otherwise chase at market), gives `FILTERED:LATE`.
   - Bars before a break or weekend remain `SKIPPED:LATE`.
   - The decision is a pure helper, `CFPFilters::Staleness`, unit-tested.
   - In the incident, a stop-entry signal on the 06:15 bar would have been evaluated at 06:22:04 and placed, provided price had not yet crossed its level.
2. **Diagnostics.**
   - `FT ENGINE: Update() blocked X s …` is logged whenever a tick fetch takes ≥ 5 s.
   - Errors are reported per failure streak: the first error of each streak, plus a "recovered after N failed calls" line. Previously only the first 10 errors per EA lifetime were logged.

**The root cause is in the engine (frozen), so I did not change it. The minimal engine fix:** `Update()` should not issue a blocking `CopyTicks` while the symbol's tick history is not synchronised. For example, in `CFPEngine::Update()`:
- skip the fetch, and return 0 with a `LastError` note, while `TerminalInfoInteger(TERMINAL_CONNECTED)==0`;
- otherwise fetch with `CopyTicksRange(symbol, …, from = lastMsc, to = TimeCurrent()*1000 + 999)` in a loop bounded to about 2 s with `GetTickCount64`, carrying the remainder to the next call. The same applies to the 45 s waits in `FinalizeLive`'s rebuild call.

An alternative needs no engine change: give the EA its own `CFPTickSource` through the public `SetTickSource()`, which refuses to fetch while disconnected. I did not do this, because the disconnect-then-block sequence here began right **after** a successful re-sync, so the guard would not have prevented it.

### Open risks

- **Expectancy is about zero or negative, and no edge is proven.**
  - IS: +0.06 R per trade, with 89 % of that profit in June.
  - Feb–May: 0.00 R.
  - OOS: −0.34 R until the kill switch fired (−0.11 R without it).
  - The spec's own acceptance gates (PF ≥ 1.25, +0.10 R, placebo) are not met. This is a frequency retune, not an edge, and I do not recommend trading it with real money.
- **The auto row size can silently change the strategy.**
  - The setting is `InpBucketPoints=0`. When the M5 ATR at start-up exceeds 80 rows, the XAUUSD preset (0.40) is rejected: at the 2026-02-02 start the ATR was ≈ 40 USD, and 2.0 was picked.
  - With 2.0-USD rows the shape rule (≥ 7 rows) rarely holds, and the rate collapsed to 1.1 trades a day.
  - **Recommendation:** set `InpBucketPoints=400` for XAUUSD in the demo preset, and the same value in the indicator. I did not hard-code it as an EA default, because 03 §14 forbids fixed point values.
- **Drawdown.**
  - The historical drawdowns were 24 R (IS), 27 R (Feb–May) and 34 R (OOS, killed); at 0.5 % risk that is 12–17 %.
  - With zero edge, the 15 % kill switch fires on noise with a 6–18 % chance per quarter; with a negative regime, as in September, it fires within two weeks.
  - The kill state persists until it is reset manually (F3: delete `FT_XAUUSD_240611_KILL` / `_PEAK`).
- **Quote-tick order flow.** The EXH conditions (thin extreme row, rising sell counts) are mostly a property of price paths at a local extreme. The placebo comparison (03 §11.10) has not been run at these defaults.
- **Frequency depends on volatility.** In quieter months fewer bars qualify (fill rate about 65 %).
- **The tester cannot reproduce live behaviour.** News blackouts (live only), spread widening and reconnect stalls happen only live.
