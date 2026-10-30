# FootprintTrader — MT5 order-flow footprint Expert Advisor

FootprintTrader trades objective, **closed-bar** order-flow setups. It computes them with the same footprint engine as the OrderFlowFP indicator, by compiling the same `.mqh` files. It never reads indicator buffers.

| Setup | Idea | Default entry |
|---|---|---|
| **SZR** | Retest of a stacked-imbalance zone (continuation) | Market at the next bar open (or a limit at the zone) |
| **ABS / EXH** | Absorption or exhaustion at a 20-bar extreme (reversal) | Stop order beyond the signal bar, valid 2 bars |
| **DIV** | Delta divergence | Grade point for ABS/EXH; standalone trading is off |

> **Defaults (v1.10).** The input defaults were retuned on 2026-10-27 so that, on XAUUSD M5, the EA takes about 5–7 trades per trading day instead of ~1 per week. In practice it trades the exhaustion setup almost exclusively. What changed and why: `docs\decisions\frequency.md`. The trade logic in plain language: `docs\TRADE_LOGIC.md`. The original spec defaults are in `MQL5\Presets\FootprintTrader_spec.set`; see §5 to restore them. **`InpTradeMode` still defaults to SIGNALS_ONLY**: choose VIRTUAL or LIVE (demo) to trade.

> **Risk disclaimer.** On Forex/CFD feeds (e.g. XAUUSD) "volume" is the **tick count** of quote changes, not exchange volume. Delta and imbalances are derived from the mid-price path. No edge, profitability or fitness for live trading is implied. Run it on a **demo** account until the full validation protocol below has passed, and keep it there unless the placebo test (step 10) shows the order flow adds value on your feed. You alone are responsible for any use with real money.

---

## 1. Files

| File | Role |
|---|---|
| `MQL5\Experts\OrderFlowFP\FootprintTrader.mq5` | The thin EA: inputs, events, wiring |
| `MQL5\Include\OrderFlowFP\FPTypes/FPClassifier/FPAnalytics/FPPresets/FPEngine.mqh` | Footprint engine (shared with the indicator) |
| `MQL5\Include\OrderFlowFP\FPDump.mqh` | `CFPDumpWriter`, the one writer of the bar-dump format |
| `MQL5\Include\OrderFlowFP\FPSignalTypes.mqh`, `FPSignals.mqh` | Signal types and detectors (SZR, ABS, EXH, DIV, grading) |
| `MQL5\Include\OrderFlowFP\Trade\FPFilters.mqh` | Data-quality, session, spread, volatility, HTF, news and position filters |
| `MQL5\Include\OrderFlowFP\Trade\FPRisk.mqh` | Sizing, daily limits, kill switch |
| `MQL5\Include\OrderFlowFP\Trade\FPExecution.mqh` | Bid/ask conversion, order planning, the shared trade-management routine, live orders, restart recovery |
| `MQL5\Include\OrderFlowFP\Trade\FPJournal.mqh` | CSV journal, bar dump, VIRTUAL simulator |
| `MQL5\Scripts\OrderFlowFP\FPDumpBars.mq5` | Dumps closed bars for the equality check |
| `MQL5\Scripts\OrderFlowFP\FPTests.mq5`, `FPSignalTests.mq5` | Engine and detector unit tests |
| `tools\build.ps1` | Deploy + compile (demo terminal only) |
| `tools\fp_analyze.py` | Signal/trade study and Monte-Carlo tool (see §9) |
| `tools\mt5_run_script.ps1`, `tools\mt5_run_tester.ps1` | Run the unit tests, `FPDumpBars` and tester passes in the demo terminal from PowerShell (see §8a) |
| `docs\EA_ARCHITECTURE.md`, `DECISIONS.md` | Contracts between the parts; every design choice |
| `docs\TRADE_LOGIC.md` | The trade logic in plain language (v1.10 defaults) |
| `docs\decisions\frequency.md` | The 2026-10-27 frequency retune: measurements, changes, results, open risks |
| `MQL5\Presets\FootprintTrader_spec.set` | Every input at its original 03 (spec) value |

## 2. Install and compile

**Scripted (recommended).** In PowerShell, from the workspace root:

```powershell
& ".\tools\build.ps1"                                                   # all targets
& ".\tools\build.ps1" -Targets Experts\OrderFlowFP\FootprintTrader.mq5  # the EA only
```

`build.ps1` copies `MQL5\{Include,Experts,Scripts,Indicators}\OrderFlowFP` into the **standard (demo) terminal** data folder and compiles with `C:\Program Files\MetaTrader 5\MetaEditor64.exe`. It prints the error/warning lines and `Result:`, and keeps UTF-8 logs in `build\logs\`. It exits 1 unless every target reports `0 errors, 0 warnings`. It never touches the Exness (live) terminal; keep it that way.

**Manual.** Copy the `OrderFlowFP` folders into `<DataDir>\MQL5\...` (MT5 → File → Open Data Folder), then compile from PowerShell or cmd. Git Bash rewrites `/x:` arguments; use `MSYS_NO_PATHCONV=1` if you must use it.

```powershell
& "C:\Program Files\MetaTrader 5\MetaEditor64.exe" /compile:"<DataDir>\MQL5\Experts\OrderFlowFP\FootprintTrader.mq5" /include:"<DataDir>\MQL5" /log
```

The log `FootprintTrader.log` is written next to the source in UTF-16. Look for `Result: 0 errors, 0 warnings`. Do not trust the exit code.

**Attach:** open an XAUUSD (or futures) **M5** chart and drag *Experts → OrderFlowFP → FootprintTrader* onto it. Enable *Algo Trading* only for LIVE mode.

## 3. Modes and a safe rollout

| `InpTradeMode` | What happens |
|---|---|
| `SIGNALS_ONLY` (default) | Signals and decisions are logged; no orders. Risk limits and sizing are not evaluated. |
| `VIRTUAL` | Entries, stops, targets, partials, break-even, trailing and time stops are simulated **tick by tick inside the EA** (bid/ask aware, stressed by `InpStressSpreadMult` / `InpStressSlipPts`). Outcomes are logged exactly like real trades (`ticket=0`, mode `VIRTUAL`). Risk limits apply to the virtual equity. |
| `LIVE` | Real orders with `InpMagic`. |

Roll out in this order. Do not skip a step.

1. **SIGNALS_ONLY**, live chart, at least a week, plus tester runs: check `signals_*.csv`, the dump equality (§8) and the filter rejections.
2. **VIRTUAL** in the tester (≥ 6 months) and live: the signal study (§7, steps 3–7).
3. **LIVE in the tester** on the same period as VIRTUAL: results must agree within slippage (E3).
4. **LIVE on a DEMO account** for at least 6 weeks; it must match the tester on the same days (§7 step 8).
5. Only then consider real money, at the minimum risk, and only if every acceptance criterion and the placebo gate passed.

**Restart behaviour:** positions and pending orders of this magic are restored and managed in **every** mode, so switching mode never orphans a live trade. VIRTUAL trades are memory-only; they are discarded when the EA stops.

## 4. How it works (one closed bar)

Inside `OnTick`, the engine ingests the ticks. For each bar T it reports as closed:

1. History not ready, or indicators not ready → `SKIPPED:NOT_READY`.
2. Staleness guard: `T + period == open of the forming bar` and lag ≤ `InpMaxSignalLagSec`, else `SKIPPED:LATE` (catches weekend/daily-break bars and blocked calls).
3. Assertion: T and every signal's `barTime` must be before the forming bar. On a violation the EA logs `ASSERT` and stops itself. No signal logic ever runs on the forming bar.
4. Optional bar dump (`InpDumpBars`).
5. Signals of T are evaluated as of T's close. Each one goes through the filters, then the grade gate, then the risk gates. It is journaled with a decision, and if `TAKEN` it is sent (LIVE) or simulated (VIRTUAL).
6. Bar-close management: pending expiry and invalidation, time stop, BAR trailing, exit on an opposite grade-A signal. This step runs for **every** closed bar, including bars skipped in steps 1–2; a skipped bar only gets no signals and no new entries. Skipped bars use the last valid ATR, or one built as of T. Without any ATR, only ATR trailing waits (logged as `FT MGMT`).

On every tick: pending orders are cancelled when the bid crosses the signal's invalidation price or the session/spread/news filter turns false. Then come the partial close, break-even, ATR trailing, flat time and MAE/MFE tracking. The kill switch, daily-loss and consecutive-loss limits are checked first on each tick.

**Prices.** Signal levels are in the engine's price basis (bid for QUOTE+BID). They are converted to execution prices:

| Basis | Long entry | Long SL/TP | Short entry | Short SL/TP |
|---|---|---|---|---|
| QUOTE + BID (default) | level + spread | level | level | level + spread |
| QUOTE + MID | level + ½ spread | level − ½ spread | level − ½ spread | level + ½ spread |
| EXCHANGE / TRADE ticks | as QUOTE + BID (approximation) | | | |

R = |fill − initial SL| in execution prices. Prices are rounded to the tick size. SL, TP and pending prices respect `STOPS_LEVEL`/`FREEZE_LEVEL`; if the SL has to be widened, the position is re-sized.

**Sizing.** The loss per lot comes from `OrderCalcProfit` with BUY/SELL types on the converted prices. `lots = floor_to_step(InpRiskPct % × equity / lossPerLot)`, clamped to the volume limits. Below the minimum the signal is `RISK_MIN_LOT`, unless `InpAllowMinLot`. Margin is checked with `OrderCalcMargin`. There is **no martingale, grid, averaging or size increase after losses**, ever.

Every other choice (expiry, retcode policy, netting/hedging, persistence, VIRTUAL fill model, …) is listed in `DECISIONS.md` (trade section: `docs\decisions\trade.md`).

## 5. Inputs

Ranges in brackets are the suggested **coarse optimisation grids**. "fixed" means: do not optimise, set it per symbol or study. **Optimise at most 4 parameters per setup at once** (§7 step 4). Where v1.10 differs from the original 03 default, the spec value is given in brackets after it. **Bold** defaults were retuned for trade frequency (`docs\decisions\frequency.md`).

### Restoring the spec defaults
`MQL5\Presets\FootprintTrader_spec.set` holds every input at its original 03 value. It includes the new v1.10 inputs, set to the values that reproduce the spec behaviour. To use it:
- in the EA: *Inputs → Load*;
- in the tester: `tools\mt5_run_tester.ps1 -SetFile MQL5\Presets\FootprintTrader_spec.set`.

These inputs differ from the spec:

| Input | v1.10 default | Spec value |
|---|---|---|
| `InpMinGrade` / `InpMinPoints` (new) | C / 1 | B / 0 |
| `InpTradeStart` / `InpTradeEnd` | "00:00" / "00:00" (all day) | "08:00" / "20:00" |
| `InpRevMaxATRRatio` (new; hard-coded in the spec) | 1.60 | 1.30 |
| `InpTP_R_REV` | 2.0 | 1.5 |
| `InpMaxTradesPerDay` | 10 | 4 |
| `InpConsecPauseMin` (new) | 60 | 0 (= pause until the next day) |
| `InpMaxDDPct` (kill switch) | 15 | 10 |
| `InpMaxLatePendingSec` (new) | 180 | 0 (off) |

Unchanged new inputs: `InpSZRMinATRRatio` 0.85 (hard-coded in the spec) and `InpResearchAllSignals` false.

### Mode
| Input | Default | Range / note |
|---|---|---|
| `InpTradeMode` | SIGNALS_ONLY | SIGNALS_ONLY / VIRTUAL / LIVE. Kept at SIGNALS_ONLY for safety: select LIVE (on a demo) to trade |
| `InpMagic` | 240611 | fixed; one magic per symbol/TF instance |
| `InpCommonFiles` | false | CSVs in the common `Files` folder |
| `InpDumpBars` | false | write `dump_<sym>_<tf>_bars/_rows.csv` (§8) |
| `InpAttachIndicator` | false | add `OrderFlowFP\FootprintChart` to the chart, visuals only (fails gracefully if absent) |
| `InpMaxSignalLagSec` | 10 | fixed |
| `InpShowStatus` | true | v1.11. Without the FootprintChart indicator on the chart, the EA writes its status in the lower-left corner. With the indicator, the status is the coloured badge at the left of its header (see §6a) |
| `InpMaxLatePendingSec` | **180** (spec: none) | Handles a bar processed later than `InpMaxSignalLagSec` but within this many seconds, i.e. a feed stall such as CopyTicks blocked during a reconnect:<br>• The bar is still evaluated.<br>• Only pending (stop/limit) entries whose level has not been crossed may be placed.<br>• Market entries and already-crossed levels are `FILTERED:LATE`.<br>• Bars before a break or weekend stay `SKIPPED:LATE`.<br>0 = spec behaviour |

### Research
| Input | Default | Range |
|---|---|---|
| `InpPlaceboPriceOnly` | false | false / true (placebo study, §7 step 10) |
| `InpStressSpreadMult` | 1.0 | 1.0 – 2.0 (VIRTUAL fills) |
| `InpStressSlipPts` | 0 | 0 – 50 points (VIRTUAL fills) |
| `InpResearchAllSignals` | false | VIRTUAL only; never for trading.<br>• Every signal becomes an independent virtual trade.<br>• Filters, grade and risk gates are evaluated and logged (`decision = RESEARCH:<reasons or PASS>`) but not applied.<br>• Use it with loose detector inputs; `fp_analyze.py --research` can then replay any tighter configuration (§9) |

### Engine (must equal the indicator / FPDumpBars for equality checks)
| Input | Default | Range |
|---|---|---|
| `InpSource` | AUTO | fixed (set QUOTE_TICKS = 3 explicitly in the tester) |
| `InpBucketPoints` | 0 (auto) | fixed per symbol |
| `InpQuotePrice` | BID | fixed |
| `InpWarmupBars` | 300 | fixed (= indicator `InpHistoryBars`) |
| `InpSessionStart` | "00:00" | fixed |
| `InpImbRatio1/2/3` | 2 / 3 / 4 | fixed |
| `InpImbMinVolume` | 10 | 3 – 50 |
| `InpStackMinRows` | 3 | 2 – 5 |

### SZR
| Input | Default | Range |
|---|---|---|
| `InpSZREnable` | true | |
| `InpSZREntry` | CONFIRM_CLOSE | CONFIRM_CLOSE / LIMIT_AT_ZONE |
| `InpSZRMinRows` | 3 | 2 – 5 |
| `InpSZRMinTier` | 2 | 1 – 3 |
| `InpSZRMinDeltaPct` | 0.10 | 0 – 0.3 |
| `InpSZRMaxHeightATR` | 0.6 | 0.3 – 1.0 |
| `InpSZRMaxAgeBars` | 30 | 10 – 60 |
| `InpSZRMaxTouches` | 1 | fixed |

### ABS/EXH
| Input | Default | Range |
|---|---|---|
| `InpRevEnable` | true | |
| `InpRevLookback` | 20 | 10 – 40 |
| `InpRevRows` | 3 | 2 – 5 |
| `InpABSSellShare` | 0.60 | 0.55 – 0.75 |
| `InpABSConcentration` | 1.5 | 1.2 – 2.5. On XAUUSD quote ticks the extreme-row concentration is 0.49 at the median and 1.09 at p90, so ABS almost never fires. Recalibrated thresholds were tested and showed no consistent effect (`docs\decisions\frequency.md`) |
| `InpABSCloseFrac` | 0.50 | 0.4 – 0.7 |
| `InpEXHMaxPct` | 0.03 | 0.01 – 0.06 |
| `InpRevMinVolMult` | 1.0 | 0.8 – 2.0 |
| `InpRevEntryOffsetPts` | 0 | fixed |
| `InpRevValidBars` | 2 | 1 – 4 |
| `InpLevelTolATR` | 0.25 | fixed |

### DIV / Grade
| Input | Default | Range |
|---|---|---|
| `InpDIVPivot` | 3 | fixed |
| `InpDIVMaxBars` | 30 | fixed |
| `InpDIVStandalone` | false | fixed |
| `InpMinGrade` | **C** (spec B) | C / B / A |
| `InpMinPoints` | **1** (new; spec 0) | 0 – 3. A signal trades only if its grade ≥ `InpMinGrade` **and** its points ≥ `InpMinPoints`. The grades are unchanged (A ≥ 4, B = 3, C ≤ 2 points) |

### Filters
| Input | Default | Range |
|---|---|---|
| `InpMinTicksPerBar` | 60 | fixed per TF (M1 20, M5 60, M15 150) |
| `InpRequireSource` | ANY | ANY / EXCHANGE_ONLY |
| `InpTradeStart` / `InpTradeEnd` | **"00:00" / "00:00"** (spec "08:00" / "20:00") | Server time. Start = end means the whole day; the XAUUSD daily break (21:00–22:00) and the spread filter handle the reopen |
| `InpFridayCutoff` | "18:00" | "" = off |
| `InpMaxSpreadPts` | 0 (off) | fixed |
| `InpMaxSpreadATR` | 0.15 | 0.10 – 0.25 |
| `InpMinATRPts` | 0 | fixed per symbol |
| `InpRevMaxATRRatio` | **1.60** (new input; spec fixed at 1.30) | ABS/EXH need ATR(14)/SMA(ATR,50) ≤ this; 99 = off [1.15 – 2.0] |
| `InpSZRMinATRRatio` | 0.85 (new input; = spec) | SZR needs the ratio ≥ this |
| `InpHTF` / `InpHTFEMA` | H1 / 50 | fixed |
| `InpNewsMin` | 15 | fixed (live only; disabled in the tester) |
| `InpMaxPositions` | 1 | fixed (netting is always limited to 1) |

### Risk
| Input | Default | Range |
|---|---|---|
| `InpRiskPct` | 0.5 | 0.1 – 1.0 (`docs\decisions\frequency.md` argues for 0.25 at this frequency) |
| `InpAllowMinLot` | false | fixed |
| `InpMaxTradesPerDay` | **10** (spec 4) | fixed (0 = off) |
| `InpMaxDailyLossPct` | 2.0 | fixed (0 = off) |
| `InpMaxConsecLosses` | 3 | fixed (0 = off) |
| `InpConsecPauseMin` | **60** (new; spec 0) | After `InpMaxConsecLosses` losses in a row, no new entries for this many minutes; then a new streak starts. 0 = spec: no entries until the next server day |
| `InpMaxDDPct` | **15** (spec 10) | Kill switch: % equity drawdown from the recorded peak (0 = off) |

### Exits / Execution
| Input | Default | Range |
|---|---|---|
| `InpSLBufferATR` | 0.10 | 0.05 – 0.3 |
| `InpTPMode` | R_MULTIPLE | R_MULTIPLE / STRUCTURE |
| `InpTP_R_SZR` | 2.0 | 1.5 – 3 |
| `InpTP_R_REV` | **2.0** (spec 1.5) | 1 – 2.5 |
| `InpPartialPct` | 50 | fixed (0 = no partial; must be < 100) |
| `InpPartialR` | 1.0 | fixed (0 = no partial and no break-even) |
| `InpBEOffsetPts` | 0 | fixed |
| `InpTrailStartR` | 1.5 | fixed (0 = no trailing) |
| `InpTrailMode` | ATR | ATR / BAR |
| `InpTrailATR` | 1.0 | fixed |
| `InpTimeStopBars` | 12 | fixed (0 = off) |
| `InpTimeStopMinR` | 0.3 | fixed |
| `InpExitOnOpposite` | false | fixed |
| `InpFlatTime` | "" (off) | fixed |
| `InpSlippagePts` | 20 | fixed |

### Test hooks (E2 acceptance only — keep OFF)
| Input | Default | Effect |
|---|---|---|
| `InpTestDailyLossAt` | 0 (off) | At this time, a synthetic realised loss equal to the daily limit is added to that day:<br>• `RISK_DAILY_LOSS`;<br>• pendings cancelled;<br>• the next server day trades again |
| `InpTestConsecLossAt` | 0 (off) | At this time, the consecutive-loss counter is set to the limit. Entries are then blocked with `RISK_CONSEC_LOSSES` for `InpConsecPauseMin` minutes (until the next day with `InpConsecPauseMin=0`) |
| `InpTestKillAt` | 0 (off) | At this time, the recorded equity peak is raised so that the drawdown exceeds `InpMaxDDPct`. The kill switch then fires:<br>• close all;<br>• cancel pendings;<br>• Alert;<br>• `RISK_KILL` from then on |
| `InpTestResetKill` | false | At start, delete the persisted kill flag, equity peak and day block of this symbol+magic |

## 6. Output files and how to read them

**Where.** Files are written to `<DataDir>\MQL5\Files\OrderFlowFP\`. With `InpCommonFiles=true` they go to `%APPDATA%\MetaQuotes\Terminal\Common\Files\OrderFlowFP\`. **In the Strategy Tester** they land in the agent's sandbox: `<DataDir>\Tester\Agent-127.0.0.1-3000\MQL5\Files\OrderFlowFP\` (one folder per agent). The common folder is the easiest place to collect tester output. Files are appended across runs, and the header is written only when a file is new: move old files away before a new study. Optimisation passes append into the same files, so use single runs for CSV studies and `OnTester` for optimisations. File names carry no magic number, so run one EA instance per symbol/TF per folder.

Format: comma-separated, `.` decimals, times `yyyy.mm.dd hh:mi:ss` (server time), CRLF.

### `signals_<sym>_<tf>.csv` — one row per signal (and per skipped bar)
| Column | Meaning |
|---|---|
| `signalId` | `barTime(unix) × 100 + index`; 0 on skipped rows. Joins to `trades.signalId` |
| `barTime` | Open time of the closed signal bar T |
| `setup`, `dir`, `grade`, `points` | SZR/ABS/EXH/DIV (NONE on skipped rows), 1/−1, A/B/C, grade points |
| `entryPrice`, `stopPrice`, `refLow`, `refHigh` | Signal levels in the **engine basis** (0 entry = market at the next open) |
| `open … close`, `volume`, `delta`, `deltaPct`, `cumDelta` | Bar T from the footprint engine (volume = tick count in QUOTE mode) |
| `imbBuyCount`, `imbSellCount` | Rows with a buy/sell imbalance in bar T |
| `stackRows`, `sellShare`, `concentration`, `closeFrac`, `exhaustionPct` | Setup metrics (`sellShare` = absorbed-side share in the signal direction; 0 = n/a) |
| `atr`, `atrRatio`, `spreadPts`, `htfBias` | Context as of T's close |
| `source`, `mode` | Engine source (QUOTE_TICKS, …), EA mode |
| `decision` | `TAKEN`, `SIGNALS_ONLY`, `FILTERED:<codes>`, `SKIPPED:<NOT_READY\|LATE\|ASSERT>`, or in research runs `RESEARCH:<codes or PASS>` (simulated regardless of the codes) |
| `info` | `key=value;…`: the signal's metrics plus the order plan (`kind, entry, sl, tp, rPts, lots, riskMoney, riskTarget, spreadPts, note, precheck`) |

**Reason codes** in `FILTERED:` (`|`-joined, every failing check is listed):
- Filters: `DATA_STATE, DATA_TICKS, DATA_SOURCE, SESSION, FRIDAY, SPREAD, ATR_MIN, REGIME, HTF, NEWS, POSITION`.
- Trade layer: `GRADE` (grade < `InpMinGrade` or points < `InpMinPoints`), `LATE` (a bar processed late by a feed stall whose signal is a market entry or whose stop level was already crossed; see `InpMaxLatePendingSec`), `RISK_DAILY_TRADES, RISK_DAILY_LOSS, RISK_CONSEC_LOSSES, RISK_KILL, RISK_MIN_LOT, RISK_MARGIN, WARMUP`, plus `FLAT` (after `InpFlatTime`), `PLAN` (no valid order plan, e.g. already invalidated or stop not beyond the entry), `TRADE_DISABLED` (terminal/account/symbol trading off), and `FILTER` (filters failed without a code).

### `trades_<sym>_<tf>.csv` — one row per **position** (partials merged), written when it is fully closed
| Column | Meaning |
|---|---|
| `tradeId` | LIVE: `POSITION_IDENTIFIER`; VIRTUAL: = `signalId` |
| `signalId`, `ticket` | Link to the signal; LIVE position ticket (order ticket on EXPIRED rows), VIRTUAL 0 |
| `setup`, `dir`, `grade`, `mode` | As in signals; mode LIVE/VIRTUAL |
| `entryTime`, `entryPrice` | Actual fill (execution price) |
| `sl`, `tp` | **Initial** SL and TP (execution prices) |
| `lots`, `riskMoney` | Initial lots; money lost at a full stop with these lots (`lots × lossPerLot`) |
| `exitTime`, `exitPrice` | Last close; `exitPrice` = volume-weighted average of all closes |
| `exitReason` | `SL, TP, BE, TRAIL, TIME, OPPOSITE, FLAT, KILL, MANUAL, EXPIRED` |
| `rMultiple` | Net money P/L ÷ `riskMoney` (partials merged; LIVE includes commission/swap) |
| `maeR`, `mfeR` | Max adverse / favourable excursion in R, as **non-negative** magnitudes (a full stop shows maeR ≈ 1) |
| `barsHeld` | Bars opened after the entry bar up to the exit bar |
| `spreadAtEntry`, `slippagePts` | Spread in points at the fill; fill − planned price in points (positive = worse) |
| `profitMoney`, `partialDone` | Net money; 1 if a partial close was executed |

**`EXPIRED` rows are pending entries that never filled** (expiry, invalidation, live filter, risk event, kill, flat). Their `exitPrice`, `rMultiple`, `maeR` and `mfeR` are **empty** (n/a) and `profitMoney` is 0, so they can never count as 0 R trades; `OnTester` ignores them. They give the fill rate of stop/limit entries. The exact cancel reason is in the Experts log.

**Experts log prefixes:** `FT INIT`, `FT READY`, `FT WARMUP`, `FT SIGNAL`, `FT EXEC` (every request attempt with its retcode and policy), `FT RISK`, `FT RISKCHECK` (per stop-out: realised loss vs `riskMoney` and the risk target, for the ±10 % check), `FT STATE:RESTORED/RECOVERED/PENDING_CANCELLED`, `FT VIRT`, `FT TEST`, `FT MGMT` (bar-close management without a known ATR), `FT ASSERT`, `FT PERF` (OnTick timing at deinit), `FT ONTESTER`, `FT ENGINE` (tick-fetch errors, recovery, and any `Update()` call that blocked for 5 s or more).

**Bar dump** (`InpDumpBars`): `dump_<sym>_<tf>_bars.csv` (`time,open,high,low,close,volume,delta,cumDelta,pocPrice,ticks,buyImbCount,sellImbCount,state,cvdValid`) and `_rows.csv` (`time,rowPrice,sell,buy,imbSell,imbBuy`). These are written by the engine's own writer, so they are byte-compatible with `FPDumpBars`. The EA dumps only the bars it processes (not skipped ones) and overwrites the files when it starts.

## 6a. Is the EA running? The status badge (v1.11)

The EA publishes its state every second. The FootprintChart header shows it as a coloured badge on the left; without the indicator the EA writes the same text in the lower-left corner of the chart.

| Colour | Text | Meaning |
|---|---|---|
| Green | `EA LIVE - 3/10 today, 1 open` | Running in LIVE mode and allowed to enter |
| Blue | `EA VIRTUAL - …` / `EA SIGNALS ONLY (no orders)` | Running, but it does not send real orders |
| Orange | `EA PAUSED: DAILY LOSS` / `LOSS STREAK to 14:35` / `DAY CAP` | Running; new entries are blocked for now |
| Orange | `EA LOADING` / `EA WARM-UP (no trades)` / `EA: FEED STALLED` | Running; history loading, warm-up, or the tick feed held or blocked in the last minute |
| Red | `EA OFF` | No heartbeat for 15 s: the EA is not attached, the terminal is closed, or it is frozen |
| Red | `EA STOPPED: KILL SWITCH` | The kill switch fired; it stays off until you delete `FT_<symbol>_<magic>_KILL` / `_PEAK` (F3) or start once with `InpTestResetKill=true` |
| Red | `EA: ALGO TRADING OFF` / `EA: NO CONNECTION` / `EA HALTED (assert)` | LIVE but trading disabled in the terminal, account or EA settings; no server connection; or the look-ahead assertion stopped the EA |

If the EA "is not trading", read the badge first: a kill switch that fired weeks ago, SIGNALS_ONLY mode or AutoTrading off all look like "no trades" on the chart. The badge reads the EA with the indicator's `InpTradeMagic` (default 240611), which must equal the EA's `InpMagic`.

## 7. Validation protocol (03 §11)

1. **Data.** Confirm that the broker's real tick history exists for the whole span (*View → Symbols → Ticks*). Use **"Every tick based on real ticks"** only. Every other model produces meaningless footprints. The EA prints a warning at each tester start because the mode cannot be read via the API.
   - If the tester has no ticks before the start date, the engine reports mostly-nodata history. The EA then logs `FT WARMUP` and uses the first `InpWarmupBars` live bars as warm-up (`FILTERED:WARMUP`, no trades).
   - **Set `InpSource` explicitly for tester runs** (e.g. `QUOTE_TICKS` for XAUUSD). With `AUTO`, the tester decides the source only after 1000 ticks or 30 s of simulated time, and the first bars are built before the decision.
   - The news filter is disabled in the tester (logged). Live, if the economic calendar cannot be read, entries are blocked with `NEWS`; `InpNewsMin=0` disables the filter.
2. **Equality checks.**
   - (a) EA **live** in SIGNALS_ONLY with `InpDumpBars=true` vs `FPDumpBars` on the same days with identical engine inputs: the closed-bar files must be identical (procedure in §8).
   - (b) Two identical tester runs must produce identical `signals`/`trades`/dump files (move the files away between runs and diff them).
   - (c) Tester vs terminal on the same days: report the number of mismatching bars. It need not be 0, because the tester serves ticks from its own database.
3. **Signal study.** Run SIGNALS_ONLY and VIRTUAL over **≥ 6 months**. Report, per setup and grade: counts, win rate, average R, expectancy after spread, and the MFE/MAE distributions (`fp_analyze.py`, §9).
4. **Optimisation.** Use coarse grids (§5 ranges), with **≤ 4 parameters per setup** at a time. Prefer **plateaus** (neighbourhoods that are all profitable) over single peaks. The optimisation criterion is `OnTester` (§10).
5. **Walk-forward.** Rolling 6-month in-sample / 2-month out-of-sample, ≥ 4 folds. Record the parameters chosen in each fold and their stability.
6. **Hold-out.** Keep the last 20–25 % of the data untouched until the very end, and evaluate it **once**.
7. **Stress.** Real-tick testing replays the recorded bid/ask, so the tester itself has no spread or slippage multiplier. Use:
   - `InpStressSpreadMult` (e.g. 1.5) and `InpStressSlipPts` in VIRTUAL runs, and the same costs as a per-trade R cost in the analysis script;
   - the tester's *Random delay* execution setting for LIVE-in-tester runs;
   - a Monte-Carlo **bootstrap with replacement** of `trades.csv`, ≥ 5000 paths, for the drawdown distribution (`fp_analyze.py`).
8. **Acceptance.**
   - out-of-sample PF ≥ 1.25;
   - ≥ 100 out-of-sample trades;
   - expectancy ≥ 0.10 R after costs;
   - 95th-percentile Monte-Carlo drawdown within your limit;
   - no single month > 40 % of the profit;
   - forward demo ≥ 6 weeks, matching tester behaviour on the same days.
9. **Per symbol and broker.** Quote-tick footprints differ between brokers. Validate each symbol/broker pair separately, and prefer exchange-flag futures where available.
10. **Placebo — the real gate in QUOTE mode.** Run the same study with `InpPlaceboPriceOnly=true`. This removes every order-flow condition and keeps only the location, price and risk rules. The real version must beat the placebo on out-of-sample expectancy by **≥ 0.05 R**. If it does not, the order flow adds nothing on this feed: **do not trade it.**

### Milestone acceptance tests (03 §12) and how to run them
| Item | How |
|---|---|
| E1 warm-up live and in the tester | Watch `FT READY` / `FT WARMUP` in the Experts/Journal tab |
| E1 `PopClosedBar` drives evaluation; assertion | Every evaluated bar produces rows/`FT SIGNAL` lines; `FT ASSERT` + EA removal on any look-ahead |
| E1 `signals.csv` in a real-tick test; data-quality rejections | Tester, SIGNALS_ONLY; look for `DATA_*` codes |
| E1 dump equality | §8 |
| E2 loss at a full stop within ±10 % of `riskMoney` | `FT RISKCHECK` lines; `rMultiple` of `SL` rows ≈ −1 |
| E2 no entries outside session/spread/news | `SESSION/FRIDAY/SPREAD/NEWS` codes; `LIVE_FILTER` pending cancels in the log |
| E2 daily loss / consecutive losses / kill switch | Test hooks (§5): set each time inside the test span, one per run, and check the `FT TEST`/`FT RISK` lines, the cancels/closes, the `RISK_*` codes and the next-day reset |
| E2 every retcode path logged | `FT EXEC … rc=… -> policy` lines |
| E2 netting and hedging | Run the tester on a netting and on a hedging account (tester settings) |
| E3 partial, BE, trailing, time stop | Visual tester run in LIVE mode; `TRAIL`, `BE`, `TIME` exit reasons, `partialDone=1` |
| E3 VIRTUAL vs LIVE agree within slippage | Same period and inputs, `InpStressSpreadMult=1`, `InpStressSlipPts=0`, a symbol without commission; compare the `trades` files by `signalId` (entries and exits should match except for fills) |
| E4 OnTester | `FT ONTESTER` line; the criterion in the optimisation results |
| E4 restart persistence | Demo, LIVE: with a position open and after the partial/BE, remove the EA (or restart the terminal) and re-attach it. Expect `FT STATE:RESTORED`, and the management continues (trailing, time stop). Then delete the position's `FT_<magic>_<id>_*` GlobalVariables (F3) and re-attach: expect `FT STATE:RECOVERED` with R from the opening order's SL |

## 8. Dump-equality procedure (step 2a)

The EA and `FPDumpBars` write files with the **same names**. Keep them apart:

1. Attach the EA to the live chart in SIGNALS_ONLY with `InpDumpBars=true`. Set `InpSource`, `InpBucketPoints`, `InpQuotePrice`, `InpSessionStart` and the imbalance inputs **explicitly**, and use `InpWarmupBars` = the bar count you will dump. Let it run for the session(s) you want to compare.
2. Remove the EA; this closes the dump. Copy `MQL5\Files\OrderFlowFP\dump_<sym>_<tf>_bars.csv` and `_rows.csv` to a safe place (e.g. `dump_ea_*`).
3. Run `Scripts\OrderFlowFP\FPDumpBars` on the same symbol/TF with the **same engine inputs**, and `InpBars` large enough to cover the EA's period. Alternatively, set its `InpCommonFiles=true` so it writes to the common folder and nothing is overwritten.
4. Compare the two dumps **joined on `time`**: every bar present in the EA dump must be byte-identical in the script dump (both `_bars` and `_rows`). The EA dumps only live bars that it processed; the script also contains older history bars. Any difference is an engine determinism bug; report the bar times.

For check 2(b), run the same tester configuration twice and compare the whole files.

## 8a. Automated verification scripts (standard demo terminal only)

Both scripts start `C:\Program Files\MetaTrader 5\terminal64.exe` with a startup config and close it afterwards. They never touch the Exness terminal. Only one terminal instance per data folder can run.

`mt5_run_tester.ps1` follows the shared **terminal lock** protocol, because other agents and tools use the same terminal:
- Before each launch it atomically creates `build\terminal.lock`.
- If the lock exists, it polls every 45 s. A lock is stale only if it is older than 60 min and no terminal is running.
- It deletes the lock as soon as the terminal has exited.
- It waits 90 s before taking the lock again.

`mt5_run_script.ps1` does not take the lock: create it yourself, or close the terminal first.

```powershell
# unit tests (PASS/FAIL summary; logs in build\runs\)
& .\tools\mt5_run_script.ps1 -Script OrderFlowFP\FPTests       -Marker "FPTests:"
& .\tools\mt5_run_script.ps1 -Script OrderFlowFP\FPSignalTests -Marker "FPSignalTests:"
# dump N bars in the terminal (also forces the terminal to download missing ticks)
& .\tools\mt5_run_script.ps1 -Script OrderFlowFP\FPDumpBars -Marker "FPDumpBars: wrote" -TimeoutSec 540 -Params "InpBars=11000","InpSource=3"
# tester passes: signals (SIGNALS_ONLY + dump), virtual, live, hooks (E2 risk paths); outputs in build\tester\<run>[_<Tag>]\
& .\tools\mt5_run_tester.ps1 -Runs signals,virtual,live,hooks -From 2026.09.07 -To 2026.09.26
# the spec configuration, tagged, on another window
& .\tools\mt5_run_tester.ps1 -Runs virtual -Tag spec_oos -SetFile MQL5\Presets\FootprintTrader_spec.set -From 2026.09.01 -To 2026.10.24
# a research pass (VIRTUAL + InpResearchAllSignals + bar dump, risk limits off) with loose detectors, for fp_analyze --research
& .\tools\mt5_run_tester.ps1 -Runs research -Tag is -SetFile MQL5\Presets\FootprintTrader_spec.set -From 2026.06.01 -To 2026.09.01 `
      -Params "InpRevLookback=5","InpRevRows=2","InpABSSellShare=0","InpABSConcentration=0","InpABSCloseFrac=0","InpRevMinVolMult=0","InpMinTicksPerBar=0","InpTradeStart=00:00","InpTradeEnd=00:00","InpFridayCutoff=","InpMaxSpreadATR=0"
```
How the inputs of a run are built: the EA defaults, then `-SetFile`, then the run's own lines, then `-Params` (the last one wins). Every run keeps its `inputs.set` in its output folder.

**Check the tick coverage first.** When the terminal's local tick base lacks some minutes of the test window, the tester **silently generates ticks** for them. The agent log then says `real ticks absent for N minutes`, and the footprints for those minutes are meaningless. `mt5_run_tester.ps1` prints that line if it occurs. Fix it by letting the terminal download the period (`FPDumpBars` over it, or *View → Symbols → Ticks*), then re-run.

### Verification results at handover (2026-10-27, XAUUSD M5, Exness-MT5Trial3 demo, QUOTE_TICKS, row 0.40)

| Check | Result |
|---|---|
| Compile, all 4 targets | 0 errors, 0 warnings |
| `FPTests` | 100 / 100 PASS. The first run found a same-millisecond de-duplication bug that dropped a tick on the live path; fixed, with regression test 6.09 |
| `FPSignalTests` | 110 / 110 PASS |
| `FPDumpBars` | Σ(sell+buy) = ticks on every bar; counted ticks / `iVolume` = 1.000 |
| 2(b) two identical tester runs | signals, trades and dump files byte-identical |
| 2(c) tester EA dump vs terminal `FPDumpBars`, 2026-09-07 … 09-25 | **4071 / 4071 bars and all rows byte-identical** |
| Live vs rebuild in the tester | 0 mismatches over 3550 bars, with real-tick history |
| Warm-up fallback (window lacking real ticks) | `FT WARMUP` triggered, signals `FILTERED:WARMUP`, no trades |
| E2 full-stop loss vs `riskMoney` | +2.5 % … +6.9 % (limit ±10 %) |
| E2 test hooks | daily loss → `RISK_DAILY_LOSS` until the next day; 3 losses → `RISK_CONSEC_LOSSES` until the next day; kill switch → Alert, close all, `RISK_KILL` for the rest of the run |
| E3 VIRTUAL vs LIVE-in-tester | the same 4 orders: identical entries, lots and exit prices; R differs by ≤ 0.008 |
| `OnTick` cost | 0.001 ms average without a bar close (max 7 ms); 0.5 ms average on bar-close ticks |

### v1.10 frequency retune (2026-10-27): verification

| Check | Result |
|---|---|
| Compile `FootprintTrader.mq5`, `FPSignalTests.mq5` | 0 errors, 0 warnings |
| `FPSignalTests` | **127 / 127 PASS**: the 110 original tests plus 8 staleness/late-pending and 9 consecutive-loss-pause tests |
| `FPTests` | engine untouched; not re-run (100 / 100 at handover) |
| Real-tick coverage | no `real ticks absent` in any of the 15 tester runs |
| Research replay vs EA | spec IS run reproduced trade for trade (23/23 orders) |
| VIRTUAL vs LIVE-in-tester, OOS | 114 / 115 common orders with identical entries and exit reasons, median \|ΔR\| 0.007. The exception is the trade open when the kill switch fired: LIVE equity crossed 15.00 % about 9 h earlier |
| Results (trades/day, R, drawdown, kill switch) | `docs\decisions\frequency.md` |

Not yet done; these need you:
- 2(a), the dump equality with the EA running **live**;
- the E4 restart test on demo;
- a netting-account run;
- a visual check of the trailing and time-stop exits;
- the ≥ 6-month study, walk-forward and placebo of §7.

## 9. Analysis tool `tools\fp_analyze.py`

`fp_analyze.py` (maintained with the signal layer) reads `trades_*.csv` and, optionally, `signals_*.csv`. It reports:
- counts, win rate, average R and expectancy per setup and grade;
- in-sample vs out-of-sample results (`--split`);
- the effect of costs (fixed R cost, spread multiplier, slippage);
- the MFE/MAE distributions;
- results by month (the 40 % rule);
- the placebo vs real comparison;
- a Monte-Carlo bootstrap of the drawdown;
- the §7 acceptance checks.

```
py -3 tools\fp_analyze.py --trades T.csv [--signals S.csv [--funnel]] [--placebo P.csv --placebo-signals PS.csv]
      [--split YYYY-MM-DD] [--from D --to D] [--cost-r 0.03] [--point 0.01 --stress-spread-mult 1.5 --stress-slip-pts 20]
      [--risk-pct 0.5 --dd-limit-pct 10 --paths 5000 --seed N] [--mode VIRTUAL] [--setup ...] [--strict]
py -3 tools\fp_analyze.py --research build\tester\research_is [--config cfg.json] [--from D --to D]
```
Added in v1.10:
- **Filled trades per trading day.** Mean, median and the share of days with ≥ 5 trades, overall and per setup. Trading days are Mon–Fri; Sunday-evening entries count for Monday. Use `--from/--to` to fix the window.
- **`--funnel`** (with `--signals`). Each signal is charged to its first blocking stage, in this order: data → session → spread → regime → HTF → grade → position → risk caps. The output ends with the fill rate of the orders.
- **`--research DIR`.** Replays a research run under a configuration. Pass `--config` as a JSON file with keys from `RESEARCH_DEFAULT`:
  - lookback `L` and rows `k`;
  - the EXH and ABS thresholds;
  - `min_points`, `session`, `rev_max_ratio`;
  - the risk caps, the pause and the kill switch.

  The replay rebuilds every reversal metric from the bar dump. It applies the filters, the one-position rule and the risk controls in time order. It reproduced the EA's own runs trade for trade. Trade management is fixed by the research run, so run one research pass per management variant.

`py -3 tools\fp_analyze.py --help` lists every option. Things to know:
- `EXPIRED` rows (unfilled pendings) are excluded from every statistic and counted in an `info:` line.
- `rMultiple` already includes partials and, in LIVE, commission and swap. VIRTUAL rows have no commission or swap, so add a cost with `--cost-r`.
- Analyse one mode at a time (`--mode`).
- Move old files away between studies: the journals are appended.
- In the signals file, the `decision` column (`TAKEN` / `SIGNALS_ONLY` / `FILTERED:*`) shows what the filters remove. Placebo signals (`InpPlaceboPriceOnly=true`) carry `placebo=1` at the start of `info` and are always given the minimum grade.

## 10. OnTester criterion

The criterion is computed from the EA's **own per-position records** (one per position, partials merged, EXPIRED rows excluded). This avoids `STAT_TRADES` counting every closing deal and `STAT_PROFIT_FACTOR` exploding without losers.

```
n = number of positions;  if n < 30 -> 0
PF_R = Σ(R > 0) / |Σ(R < 0)|, capped at 5 (5 if there are no losers)
criterion = (PF_R − 1) × √n / max(1, TesterStatistics(STAT_EQUITY_DDREL_PERCENT))
```

Pick *Custom max* in the optimisation settings. A value > 0 needs PF_R > 1 and at least 30 positions. Larger samples and smaller equity drawdowns are rewarded. In VIRTUAL runs the tester's equity drawdown is ~0, so the divisor is 1.

## 11. Risk controls at a glance

- **Per trade:** `InpRiskPct` of equity at the initial stop. Stops are always attached and only ever tightened.
- **Per day (server time):**
  - at most `InpMaxTradesPerDay` entries (10);
  - stop at `InpMaxDailyLossPct` (2 %) of day-start equity, closed + floating;
  - after `InpMaxConsecLosses` (3) losses in a row, pause for `InpConsecPauseMin` (60) minutes, or until the next day with 0. The pause survives a restart (GlobalVariables `_PAUSE`/`_CRESET`).

  When a limit is hit, pending entries are cancelled and open positions keep their stops.
- **Kill switch:** equity drawdown ≥ `InpMaxDDPct` (15 %; spec 10 %) from the recorded peak closes everything of this magic, disables new entries and raises an Alert. The state persists in GlobalVariables `FT_<symbol>_<magic>_PEAK/_KILL`. To re-enable, delete them (F3) or start once with `InpTestResetKill=true`. **Withdrawals reduce equity and can trip the kill switch**; reset the peak after balance operations.
- **Restart-safe:** per-position state lives in `FT_<magic>_<positionId>_*` GlobalVariables and is deleted when the position closes. Daily counters are rebuilt from the deal history.

## 12. Known limitations

- On Forex/CFD the engine measures quote activity, not traded volume (see the disclaimer). Validate with the placebo test.
- A tick arriving exactly between the terminal's bar update and the engine's tick fetch can make one bar `SKIPPED:LATE` (rare, conservative).
- `CopyTicks` inside the engine can block `OnTick` while the terminal re-synchronises its tick history after a reconnect (seen live: 135 s before v1.11).
  - Since v1.11 the engine does not fetch ticks while the terminal is disconnected, for 5 s after it reconnects, and then until the symbol reports synchronised (at most 30 s). The log shows `tick feed held (...)` and `tick feed resumed`; the status badge shows `FEED STALLED`.
  - A disconnect that starts in the middle of a fetch can still block that one call. Bars that close meanwhile are processed late: an untriggered pending entry is still placed (`InpMaxLatePendingSec`, 180 s); anything else is `FILTERED:LATE` / `SKIPPED:LATE`.
- **The auto row size (`InpBucketPoints=0`).**
  - Before v1.11 the symbol preset was rejected when the M5 ATR at start-up was outside 6–80 rows; on 2026-02-02 this picked 2.0 instead of 0.40 for XAUUSD, and the EA traded about 1 trade a day instead of 7.
  - Since v1.11 the preset is kept unless the ATR is below 2 or above 250 rows. Pinning it per symbol (XAUUSD: `InpBucketPoints=400`, identically in the indicator) is still the most robust setting.
- **With the v1.10 defaults, expectancy is about zero.** The setups showed no robust edge on this quote-tick feed; see `docs\decisions\frequency.md`. At 0.5 % risk and about 7 trades a day:
  - expect drawdowns of 10–17 % within a quarter;
  - the 15 % kill switch has a 6–18 % chance per quarter of firing on noise.
  - 0.25 % risk is the coherent setting for this frequency.
- The VIRTUAL simulator has no commission/swap model, and open virtual trades are lost when the EA stops.
- `InpAttachIndicator` uses the indicator's default inputs; it is a visual aid only.
- One EA instance per symbol/TF per Files folder: the CSV names do not include the magic number.
