# Decisions: signals layer (FPSignals, FPFilters, FPSignalTests, fp_analyze)

Each entry is *topic — decision — why*.

## Shared types (FPSignalTypes.mqh, additive only)

- **New metric slots** — `FP_M_RANGESMA 6` (IN, placebo: SMA of bar range of the bars before T) and `FP_M_WICK 7` (out, placebo: rejection-wick fraction). `FP_M_COUNT` stays 8. — The placebo detectors need a price-only input/output, and the free slots already existed.
- **New `FPSignalConfig` fields (at the end)** — `valueAreaPct` (0.70), `placeboWickFrac` (0.40), `placeboSzrBodyATR` (0.60). A value ≤ 0 means "use the default" (`CFPSignals::Init` normalises). — The engine config is not readable through the contract API, so the session value area needs its own percentage (it must equal the engine's `FPConfig.valueAreaPct`). The placebo knobs are needed to match the placebo's trade count to the real version's.
- **Default helpers** — `CFPSignals::DefaultConfig()` and `CFPFilters::DefaultConfig()` fill every spec default. `Init` also fills the spec constants (ATR 14/50, 1.15/0.85, SMA 20, EXH close 0.40, HTF H1/EMA 50) when the caller leaves them at 0. — This way a config the trade layer fills only partly cannot silently disable rules.

## As-of rule and context

- **Indicator reads** — The chart-TF ATR is read at the shift of bar T itself (`iBarShift(T, exact)`), and the HTF EMA/close at the last HTF bar that was complete at T's close. Live, after the staleness guard, these are exactly shift 1 on both timeframes. If T would be shift 0, the read is refused. — A time-derived shift equals "shift 1" when called on time, and it can never look ahead, even if called late, in a test, or for `BuildContext` of an older bar.
- **HTF race** — If the new HTF bar is not yet in the HTF series when T is evaluated, the HTF value is left unknown (`htfBias=0`), which fails the SZR HTF filter. — This is the conservative choice and should be rare.
- **ATR ratio** — `r = ATR(T) / mean(ATR over the 50 bars ending at T)`. TREND if r > 1.15, CHOP if r < 0.85, else BASE (02 §8.8(e)). — This matches the indicator's ATR Reg definition.
- **Context validity** — `ctx.valid` means that ATR and the ATR ratio are known; every setup needs them. Any other unknown field is 0. Without a valid context, `Evaluate` returns 0 signals. — Stops, zone height and all filters depend on ATR.
- **Session profile** — Built by the signals layer from the held bars of T's session with time ≤ T, through a PrevBarTime walk. `SessionProfile()` is not used because it may include later bars. The POC is the maximum volume; on a tie, the row closest to T's close wins, then the lower row. VA uses `CFPAnalytics::ValueArea`. Prices are: POC = mid of its row, VAH = top edge of the VAH row, VAL = bottom edge of the VAL row. — No look-ahead, and a deterministic tie rule.
- **Previous-session POC** — The held bars in [SessionStart(prev), SessionStart(T)). The engine keeps whole sessions, so a partly held session cannot occur except at the oldest edge. On a tie, the lower row wins. — This is the engine's coverage rule.
- **Previous-day high/low** — From the broker's D1 series: the D1 bar strictly before T's server day. — The engine may not hold a whole server day when the session start is not 00:00.
- **volSMA** — The mean volume of the 20 usable bars (closed, state 0, rows > 0) before T. Unusable bars are skipped. The walk is at most 40 bars; if fewer than 20 usable bars are found, volSMA = 0 and the ABS volume test fails. `revMinVolMult ≤ 0` disables the volume test. — A nodata bar has volume 0 and would bias the SMA.
- **Price comparisons** — Comparisons against zone edges, the mid and the lookback extremes use a 1e-8 absolute tolerance. — Row edges are computed as `row × rowSize` and can differ from tick prices by float noise. 1e-8 is far below one point for every symbol.

## SZR

- **Qualification ATR** — `ZoneQualifies` gets the ATR of the origin bar. — The spec says the zone is "judged when its origin bar closes".
- **Age** — Age is counted in held bars with a PrevBarTime walk (times[1..szrMaxAgeBars]), so a zone from before a weekend is not aged by calendar time.
- **Touches** — `touchesBefore = touches − (lastTouchTime==T)`. If `lastTouchTime > T`, the zone is skipped. — The count as of T cannot be rebuilt in that case. It cannot happen after the staleness guard.
- **Retest bar** — Besides low ≤ priceHigh, close ≥ mid and delta ≥ 0, the retest also requires low ≥ priceLow (SELL: high ≤ priceHigh). — This is consistent with the engine fill rule: such a bar fills the zone, so the zone is not open at T anyway.
- **One SZR per direction per bar** — When several zones trigger at T, the one with the most grade points is kept, then the newest origin. — Overlapping zones describe the same event, and duplicates would distort the statistics.
- **LIMIT_AT_ZONE** — One LIMIT signal is emitted on the origin bar T when the zone qualifies: entry priceHigh (long) / priceLow (short), `validBars = szrMaxAgeBars`, and `invalidPrice` = the far zone edge (long: cancel when bid < priceLow, i.e. the zone has been filled). CONFIRM and LIMIT are exclusive. The retest-delta grade item cannot score (there is no retest bar), so LIMIT signals have at most 4 points. — This follows the spec, with the zone-fill invalidation of the SZR thesis.
- **Location confluence (SZR)** — The zone interval lies within `levelTolATR × ATR(T)` of any of VAL, VAH, prev-day high, prev-day low or prev-session POC. — The spec lists them without a direction for SZR. A support zone at VAH or VAL is a valid confluence.

## ABS / EXH

- **Location** — Uses exactly the `revLookback` held bars before T, excluding T. If any of them is unusable (state ≠ 0 or no rows), there is no signal. — This is conservative: an unknown extreme cannot prove a new low.
- **Location confluence (ABS/EXH)** — Directional. A long's low is compared with VAL, prev-day low and prev-session POC. A short's high is compared with VAH, prev-day high and prev-session POC. — §4.2 pairs "VAL/VAH" and "low/high" with "mirror for shorts". This is the conservative reading (fewer points).
- **EXH has no volume test** — §4.2 lists none for EXH, only for ABS.
- **Metrics** — Both detectors always run, so share, concentration and exhaustion% are logged for every ABS/EXH signal, whichever detector fired. Both detectors true gives one signal of type ABS.
- **Sell-imbalance grade item** — Long: `imbSell` tier ≥ 2 in the bottom k rows. Short: `imbBuy` tier ≥ 2 in the top k rows.
- **tpStructure** — The session POC, set only when it lies beyond the entry on the profit side; otherwise 0. SZR uses VAH (long) / VAL (short) against the reference entry: T's close for MARKET, the limit price for LIMIT. — A target on the wrong side is meaningless. The trade layer still applies the ≥ 1.2R rule.

## DIV

- **Pivots** — Strength `divPivot`, strict inequality on both sides. Every bar in the pivot window must be usable. — Ties and holes do not make a pivot. This is conservative.
- **P1** — The nearest earlier pivot of the same kind with P2 − P1 ≤ `divMaxBars`. If it does not satisfy P2 > P1, there is no divergence; the search does not go further back. — This is the standard "previous swing" reading and the conservative one.
- **Detector** — `DetectDivergence(FPDivBar b[], count, dir, pivot, maxBars, p1, p2)` is pure. It reports a divergence confirmed at index count−1 (P2 = count−1−pivot). — Being pure makes it testable without the engine. The confirmation delay is structural: before the confirming bar, P2 is not a pivot.
- **CVD** — CVD is compared only if P1 and P2 have the same `SessionStart` and both are `cvdValid`. Otherwise only the bar-delta condition applies.
- **Confluence** — For ABS/EXH at T, divergences confirmed at T, T−1, T−2 and T−3 (held bars) are checked, each judged on the window that ends at its own confirming bar. `Evaluate` is stateless, so no logged signal can ever be re-graded.
- **Standalone DIV** — Emitted only when `divStandalone=true`, and never in placebo mode. It is a stop entry beyond the confirming bar T (ABS-style, `revEntryOffsetPts`, `revValidBars`). The stop and `invalidPrice` are beyond the P2 pivot extreme. Grade items: HTF agreement, location confluence (P2 extreme), regime BASE, so the maximum is B. The regime filter is the reversal one (r ≤ 1.3). — The spec gives no DIV grade list or stop rule. P2 is the structure that the divergence invalidates on.

## Output and grading

- **Order of `out[]`** — Grade descending, points descending, then setup SZR < ABS < EXH < DIV, then long before short. — The trade layer processes `out[]` in order, so the best signal gets the position slot.
- **`LastContext`** — Returns true after any `Evaluate` call. The caller checks `ctx.valid`.

## Placebo (`placeboPriceOnly`, 03 §11.10)

- **ABS'** — Location and shape are kept. Share, concentration and volume are replaced by: rejection wick ≥ `placeboWickFrac` (long: (min(open,close) − low)/range), closeFrac ≥ `absCloseFrac` (kept), and range ≥ `revMinVolMult` × SMA(range, 20). — This is the "pin bar at a 20-bar extreme with above-average range" null hypothesis that order flow must beat.
- **EXH'** — Location and shape are kept, plus closeFrac ≥ 0.40 and a body in the signal direction. The thin-extreme and drying-up tests are removed.
- **SZR'** — The zone is the `szrMinRows` rows at the base of an impulse bar (long: from the open's row upward). It qualifies when body ≥ `placeboSzrBodyATR` × ATR(origin), replacing delta% and tier. Close beyond the zone and height ≤ `szrMaxHeightATR` × ATR are kept. Fill and touches are rebuilt as of T from the bars between origin and T, with the engine's rules. In the retest, "delta ≥ 0" becomes "close ≥ open" (long). Age, first-touch, mid-close, stop, entry and LIMIT handling are unchanged. — Stacked imbalances are themselves order flow, so the price analogue is the classic "demand zone at the base of a displacement bar".
- **DIV** — Removed entirely: no confluence point and no standalone signals.
- **Grading** — Placebo signals get `grade = InpMinGrade` (they always pass the grade gate). `points` holds only the price-only items (SZR: location, TREND; ABS/EXH: HTF, location, BASE). `info` starts with `placebo=1`. — The order-flow grade items cannot exist in placebo mode. Grading the price items against the A/B/C cut-offs would filter almost every placebo signal and make the trade counts incomparable. The placebo's selectivity is therefore placed entirely in its detection knobs.
- **Count calibration** — `fp_analyze --placebo` prints the placebo/real trade-count ratio per setup and warns outside 0.67–1.5. Tune `placeboWickFrac` (ABS') and `placeboSzrBodyATR` (SZR') in-sample until the counts match, then compare out of sample. — An expectancy comparison between very different selection intensities is meaningless.

## Filters

- **Decision time** — `CheckSignal` evaluates session, Friday and news at T + PeriodSeconds(tf), the open of the bar after T. — It is deterministic and identical in the tester and live, and it is the moment the entry is placed.
- **Session window** — [start, end). start > end wraps midnight. start == end means the whole day. An empty input (−1) is an open edge (00:00 / 24:00). A malformed input (−2) closes the window, and `StartupWarnings` says so.
- **Friday** — Blocked at or after the cutoff on Fridays (server time). "" is off. A malformed cutoff blocks the whole Friday.
- **CheckLive** — Checks SESSION, FRIDAY, SPREAD and NEWS. — The Friday cutoff is part of the spec's Session row.
- **Spread** — `CheckSignal` uses the context's spread, read at signal time. `CheckLive` reads the current tick. `maxSpreadATR ≤ 0` turns the ATR test off. The points test applies only when `maxSpreadPts > 0`. An unknown ATR fails SPREAD, ATR_MIN and REGIME.
- **Regime** — SZR needs r ≥ 0.85. ABS, EXH and standalone DIV need r ≤ 1.30. r = 0 (unknown) fails.
- **HTF** — Hard for SZR only: `ctx.htfBias` must equal `sig.dir`, and bias 0 (unknown or flat) fails. The filters create no indicator handles; HTF, ATR and spread come from `FPContext`, so `FPFilterConfig.htf/htfEma` must equal the signal config's values.
- **News** — Live only. `CalendarValueHistory` is queried per currency (`SYMBOL_CURRENCY_BASE/PROFIT/MARGIN`, de-duplicated) over [now−1d, now+3d], keeping HIGH importance events. The cache refreshes at most every 900 s (60 s after a failure) from `OnTimer`, or lazily on the first check. It is never queried per tick. An entry is blocked within ±`newsMin` minutes of an event. `ERR_CALENDAR_NO_DATA` for a currency (e.g. XAU) is not a failure. Any other calendar failure blocks entries with NEWS and logs once. `InpNewsMin=0` disables the filter. In the tester, the filter is off with one log line at `Init`. — This follows the conservative rule (§15). The user keeps an explicit off switch.
- **DATA_SOURCE** — Uses `engine.ActiveSource()`. `StartupWarnings()` should be called again after `HistoryReady()`, because AUTO may decide late.

## fp_analyze.py

- **Cost model** — net R = rMultiple − `--cost-r` − (stress spread mult − 1) × spreadAtEntry × point / |entry − sl| − 2 × stress slip × point / |entry − sl|. The stress terms need `--point`. — rMultiple already contains the spread actually paid. The stress terms are extra (03 §11.7).
- **Evaluation set** — The OOS part (entryTime ≥ `--split`) when given; otherwise all trades, flagged as not out-of-sample.
- **Monte Carlo** — A bootstrap with replacement of the evaluation set's net R, with path length = n, default 5000 paths, seeded. It reports max DD in R (additive) and in % (compounded at `--risk-pct` per 1R), as p50/p90/p95/p99/worst. It warns if `--paths` < 5000.
- **Monthly concentration** — Net R is grouped by exit month. A month's share = its net R / total net R. The check fails if any share exceeds 40 % or if total net R ≤ 0. — Dividing by the net total (not by the sum of winning months) is the stricter reading.
- **Acceptance** — OOS PF(R) ≥ 1.25, ≥ 100 trades, expectancy ≥ 0.10R after costs, MC p95 DD% ≤ `--dd-limit-pct`, month share ≤ 40 %, real − placebo OOS expectancy ≥ 0.05R. The forward demo is a MANUAL item. `--strict` makes the exit code 1 on any FAIL.
