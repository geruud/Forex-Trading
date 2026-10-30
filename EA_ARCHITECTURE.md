# FootprintTrader — build architecture & cross-agent contract

The specification is `03_PROMPT_Footprint_EA.md` (the EA) plus §5, §11 and §13 of `02_PROMPT_Footprint_Indicator.md` (the engine). This file pins down only the things those documents leave open **between** the parts, so that the parts can be built in parallel and still fit together. If this file and the spec disagree, the spec wins. Tell the orchestrator about the conflict.

## 1. Workspace, build, deploy

- Workspace root: `C:\Users\ganzo\OneDrive\Ganzorig\Trading Experiments\Footprint`. The source of truth is `MQL5\...` under it. It mirrors the terminal's `MQL5\` folder.
- Build: in PowerShell, run `& "<root>\tools\build.ps1"`. Use `-Targets <rel path>` for one file.
  - It copies `MQL5\{Include,Experts,Scripts,Indicators}\OrderFlowFP` into the **standard (demo) MT5 terminal** data folder `C:\Users\ganzo\AppData\Roaming\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075\MQL5`. It then compiles with `C:\Program Files\MetaTrader 5\MetaEditor64.exe`.
  - It prints the error and warning lines and the `Result:` line, and leaves UTF-8 logs in `build\logs\`.
  - It exits 1 unless every target has `0 errors, 0 warnings`.
- **Never** deploy to or compile in the Exness terminal (`53785E…`, `C:\Program Files\MetaTrader 5 EXNESS`). That is the user's live-money broker.
- Edit only the workspace copy. Never edit files inside the terminal data folder; the next deploy overwrites them.
- Other agents build in parallel, so a deploy may briefly pick up another agent's half-written file. If the compile fails **only** in a file you don't own, it's their work in progress. Don't touch it. Re-run later, or report it.

## 2. File ownership (edit only your own files)

| Owner | Files |
|---|---|
| Orchestrator | `MQL5\Include\OrderFlowFP\FPSignalTypes.mqh`, `tools\build.ps1`, this file, `DECISIONS.md` (merged from `docs\decisions\*.md` at the end) |
| Engine agent | `Include\OrderFlowFP\{FPTypes,FPClassifier,FPEngine,FPAnalytics,FPPresets,FPDump}.mqh`, `Scripts\OrderFlowFP\{FPTests,FPDumpBars}.mq5`, `docs\decisions\engine.md` |
| Signals agent | `Include\OrderFlowFP\FPSignals.mqh`, `Include\OrderFlowFP\Trade\FPFilters.mqh`, `Scripts\OrderFlowFP\FPSignalTests.mq5`, `tools\fp_analyze.py`, `docs\decisions\signals.md` |
| Trade agent | `Include\OrderFlowFP\Trade\{FPRisk,FPExecution,FPJournal}.mqh`, `Experts\OrderFlowFP\FootprintTrader.mq5`, `README_EA.md`, `docs\decisions\trade.md` |

`FPSignalTypes.mqh` (shared types) may be changed **additively** by the signals agent only: new fields at the end of a struct, or new enums and defines. Never rename or remove anything. Mention every addition in your final report. The trade agent treats it as read-only.

## 3. Include conventions

- Inside `Include\OrderFlowFP\` use quoted relative includes: `#include "FPEngine.mqh"`, `#include "..\FPSignalTypes.mqh"` from `Trade\`.
- Programs (`Experts\`, `Scripts\`) use angle includes: `#include <OrderFlowFP\Trade\FPExecution.mqh>`.
- Include chain: `FPTypes` ← `FPClassifier`/`FPAnalytics` ← `FPPresets` ← `FPEngine` ← `FPDump`, `FPSignalTypes` ← `FPSignals` ← `Trade\FPFilters` ← `Trade\FPRisk` / `Trade\FPExecution` / `Trade\FPJournal` ← EA. No circular includes. Engine files never include anything above them.
- The EA must **not** include `Include\OrderFlowFP\UI\*`. (The indicator UI is not part of this build.)
- `FPSignalTypes.mqh` defines the global helpers `FPTfName`, `FPParseHHMM`, `FPSetupName` and `FPGradeName`. Don't define globals with those names elsewhere.

## 4. Engine additions (beyond the verbatim API contract v1)

The engine agent adds exactly these public members. They are additive and recorded in DECISIONS:

```mql5
// CFPEngine
datetime PrevBarTime(const datetime barTime) const;   // open time of the held bar immediately before barTime (0 = none / not held)
```

```mql5
// FPDump.mqh — the ONE writer of the FPDumpBars CSV format, used by the FPDumpBars script AND the EA (InpDumpBars)
class CFPDumpWriter
{
public:
   bool Open(const string symbol, const ENUM_TIMEFRAMES tf, const bool commonFolder); // MQL5\Files\OrderFlowFP\dump_<sym>_<tf>_bars.csv + _rows.csv; overwrite; header line
   bool Write(CFPBar *bar, CFPEngine *engine);  // one CLOSED bar: one line in _bars, one line per row in _rows
   void Close();
};
```

`<tf>` is `FPTfName(tf)` text, e.g. `M5`. The engine can't include `FPSignalTypes`, so it uses an identical private helper with another name. Number formatting is fixed and locale-free, so two writers given the same bar produce byte-identical lines.

## 5. Signals layer API (signals agent implements; trade agent calls)

```mql5
class CFPSignals
{
public:
   bool   Init(CFPEngine *engine, const FPSignalConfig &cfg);   // creates ATR (chart TF) and EMA (HTF) handles
   void   Deinit();                                            // releases handles
   bool   IndicatorsReady();                                   // BarsCalculated() ok for every handle
   int    Evaluate(const datetime closedBarTime, FPSignal &out[]);  // all signals of bar T, graded (grade C included), as-of T
   bool   LastContext(FPContext &ctx) const;                   // context built by the most recent Evaluate (valid even with 0 signals)
   bool   BuildContext(const datetime closedBarTime, FPContext &ctx);
   static bool DetectAbsorption(CFPBar *bar, const int dir, const FPSignalConfig &cfg, double &m[]);
   static bool DetectExhaustion(CFPBar *bar, const int dir, const FPSignalConfig &cfg, double &m[]);
   static bool ZoneQualifies(const FPZone &z, CFPBar *originBar, const double atr, const FPSignalConfig &cfg);
   // + a static pure divergence detector of your design, unit-tested in FPSignalTests
};

class CFPFilters
{
public:
   bool   Init(CFPEngine *engine, const FPFilterConfig &cfg);  // creates its own handles if needed
   void   Deinit();
   // ALL signal-time filters of 03 §5. Returns true when every filter passes.
   // reasons = '|'-joined codes of EVERY failing filter, in this order:
   // DATA_STATE, DATA_TICKS, DATA_SOURCE, SESSION, FRIDAY, SPREAD, ATR_MIN, REGIME, HTF, NEWS, POSITION
   bool   CheckSignal(const FPSignal &sig, CFPBar *bar, const FPContext &ctx, const bool positionBusy, string &reasons);
   // re-check while a pending order is alive (session, spread, news only), every tick
   bool   CheckLive(const datetime now, const double atr, string &reasons);
   void   OnTimer();                                           // refresh the news-calendar cache (live only)
   void   StartupWarnings();                                   // e.g. QUOTE-mode warning (§5 data quality)
};
```

- Additive in v1.10 (frequency retune, `docs\decisions\frequency.md`):
  - `static int CFPFilters::Staleness(bool prevOfForming, long lagSec, int maxLagSec, int maxLatePendingSec)` returns `FP_BAR_ON_TIME` / `FP_BAR_LATE_PENDING` / `FP_BAR_STALE`. It is the staleness guard of 03 §4 plus the late-pending extension (`InpMaxLatePendingSec`).
  - `FTRiskConfig.consecPauseMin` holds the consecutive-loss pause in minutes; 0 = until the next server day, as in the spec.
  - The regime-band constants `szrMinAtrRatio`/`revMaxAtrRatio` of `FPFilterConfig` are now filled from EA inputs.
- `positionBusy` is computed by the trade layer. In LIVE: a position or pending order with this magic on the symbol, or **any** position on the symbol on netting accounts, with count ≥ `maxPositions`. In VIRTUAL: an open or pending virtual trade.
- The grade gate (`grade < minGrade` → `GRADE`) and the risk gates (`RISK_DAILY_TRADES`, `RISK_DAILY_LOSS`, `RISK_CONSEC_LOSSES`, `RISK_KILL`, `RISK_MIN_LOT`, `RISK_MARGIN`, `WARMUP`) belong to the trade layer. They are appended to the same reason list.
- `Evaluate` is called once per bar popped by `PopClosedBar`, after the staleness guard. It never reads `At(0)`, and it walks bars with `ByTime()` / `PrevBarTime()`.

## 6. Per-closed-bar flow inside `OnTick` (trade agent)

```
engine.Update()
while(engine.PopClosedBar(T)):
   if !engine.HistoryReady()                       -> log SKIPPED:NOT_READY, go to MANAGE (no signals, no entries)
   staleness guard (03 §4)                         -> log SKIPPED:LATE, go to MANAGE (no signals, no entries)
   assert T < iTime(_Symbol,_Period,0)             -> on violation: log ASSERT + ExpertRemove() (no MANAGE)
   if InpDumpBars: dump bar T
   n = signals.Evaluate(T, sigs); signals.LastContext(ctx)
   for each sig (in out[] order):
      reasons = filters.CheckSignal(...) + grade gate + risk gates
      decision = reasons != "" ? "FILTERED:"+reasons : (mode==SIGNALS_ONLY ? "SIGNALS_ONLY" : "TAKEN")
      journal.LogSignal(sig, bar, ctx, decision)
      if decision == TAKEN: LIVE -> execution.Submit(sig, ctx) ; VIRTUAL -> virtual.Submit(sig, ctx)
   MANAGE: execution/virtual .OnBarClosed(T, ctx, sigs)
      // runs for EVERY popped bar, skipped ones included: pending invalidation/expiry, time stop, BAR trailing;
      // exit-on-opposite only from evaluated signals. Skipped bars use the last valid context/ATR, or
      // signals.BuildContext(T) when history and indicators are ready; with no ATR known only ATR trailing waits (logged).
execution/virtual .OnTick()                        // pending cancel by bid / live filters, partial, BE, trailing, flat time, MAE/MFE
```

## 7. CSV formats (exact headers; comma separated, '.' decimals, times `yyyy.mm.dd hh:mi:ss`)

Files go in `MQL5\Files\OrderFlowFP\`, or the common folder when `InpCommonFiles`. Names are `signals_<sym>_<tf>.csv` and `trades_<sym>_<tf>.csv`, where `<tf>` = `FPTfName`. Existing files are appended, with the header written only when the file is new.

`signals_*.csv`
```
signalId,barTime,setup,dir,grade,points,entryPrice,stopPrice,refLow,refHigh,open,high,low,close,volume,delta,deltaPct,cumDelta,imbBuyCount,imbSellCount,stackRows,sellShare,concentration,closeFrac,exhaustionPct,atr,atrRatio,spreadPts,htfBias,source,mode,decision,info
```
- `setup` ∈ SZR/ABS/EXH/DIV; `dir` ∈ 1/−1; `grade` ∈ A/B/C; `mode` ∈ SIGNALS_ONLY/VIRTUAL/LIVE.
- `sellShare` is the absorbed-side share in the signal direction.
- `info` has its commas replaced by `;`.
- Skipped bars log a row with `setup=NONE` and `decision=SKIPPED:<why>`.
- v1.10 (additive):
  - New trade-layer reason code `LATE`: a bar processed late by a feed stall whose signal is a market entry or whose stop level was already crossed.
  - New decision `RESEARCH:<codes or PASS>`: VIRTUAL research runs with `InpResearchAllSignals=true` simulate the signal whatever the codes.
  - The `info` column may carry `lateSec=N`.

`trades_*.csv`: one row per **position**, with partial closes merged, written when the position is fully closed.
```
tradeId,signalId,ticket,setup,dir,grade,mode,entryTime,entryPrice,sl,tp,lots,riskMoney,exitTime,exitPrice,exitReason,rMultiple,maeR,mfeR,barsHeld,spreadAtEntry,slippagePts,profitMoney,partialDone
```
- `exitReason` ∈ SL/TP/BE/TRAIL/TIME/OPPOSITE/FLAT/KILL/MANUAL/EXPIRED.
- `rMultiple` = realised money P/L ÷ the initial `riskMoney`, so partials are merged naturally.
- VIRTUAL rows use `ticket=0`.

## 8. Decisions

Each agent writes its own `docs\decisions\<part>.md`, as short entries: *topic — decision — why*. The orchestrator merges them into `DECISIONS.md`.

## 9. Quality bar (all agents)

- 0 errors and 0 warnings.
- Explicit casts.
- No unused variables.
- No `Sleep`, and no unbounded loops in event handlers.
- Free every `new`.
- No pointers to structs.
- Never store `At()`/`ByTime()` pointers past the next `Update`/`LoadStep`/`FeedTicks`/`Deinit`.
- No look-ahead.
- No hard-coded broker specifics.
- Match the spec's names exactly.
