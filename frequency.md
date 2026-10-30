# Decisions: frequency retune (2026-10-27, v1.10)

**Goal (user).** With default inputs on XAUUSD M5 (Exness demo, QUOTE_TICKS, row 0.40), the EA should take at least 5–6 filled trades per trading day: a mean of at least 5.5 and a median of at least 5. This was measured in the Strategy Tester with real ticks, on an out-of-sample window that was not used for tuning.

**Windows.**
- In-sample (IS, used for tuning): 2026-06-01 … 08-31, 66 trading days.
- Out-of-sample (OOS, evaluated once at the end): 2026-09-01 … 10-23, 39 trading days.
- Every agent log was checked for `real ticks absent`; there were none in any run.

**How a trading day is counted.**
- A trading day is a weekday server date.
- Sunday-evening entries (the market opens at 22:00) count for Monday.

Short entries: *topic — decision — why*.

## Method

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

## Funnel with the spec defaults (IS, 66 days; research data replayed, identical to the EA run)

| Stage | Signals left | Lost |
|---|---|---|
| Detected (EXH 1289, SZR 7, ABS 0) | 1296 (19.6/day) | |
| SESSION 08:00–20:00 | 695 | **601** |
| FRIDAY, REGIME ≤ 1.30, HTF | 542 | 153 |
| GRADE ≥ B (3 of 5 points) | 23 | **519** |
| Risk caps (4/day, 3 losses, 2 %) | 23 | 0 (never bound) |
| Orders → filled | **13 filled**, 10 expired | |

Two filters bound: the **session** (46 % of the signals) and the **grade** (96 % of what remained; on this feed almost every signal is grade C). ABS never fired. The extreme-row concentration of reversal bars is 0.49 at the median, 1.09 at p90 and 1.70 at p99, against the 1.5 required. The spec OOS run had 8 fills in 39 days.

## Changes (all are input defaults; the spec values are in `MQL5\Presets\FootprintTrader_spec.set`)

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

## Results

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

## Side issue: the 06:15 bar processed 124 s late (live demo, 2026-10-27)

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

## Open risks

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
