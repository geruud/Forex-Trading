//+------------------------------------------------------------------+
//| FootprintTrader.mq5 - order-flow footprint Expert Advisor         |
//|                                                                    |
//| Thin EA: inputs, events, wiring. Layers:                          |
//|   engine (FPEngine) -> signals (FPSignals) -> filters/grading      |
//|   (Trade\FPFilters) -> risk/execution/journal (Trade\FPRisk,       |
//|   FPExecution, FPJournal).                                         |
//| Signals are evaluated ONLY on closed bars popped by the engine     |
//| (PopClosedBar), never on the forming bar (docs\EA_ARCHITECTURE §6).|
//|                                                                    |
//| Rollout: SIGNALS_ONLY -> VIRTUAL -> LIVE on a DEMO account only.   |
//| Volumes on Forex/CFD feeds are tick counts, not exchange volume.   |
//| No edge or profitability is implied.                               |
//|                                                                    |
//| v1.10: input defaults retuned for ~5-6 trades/day on XAUUSD M5     |
//| (docs\decisions\frequency.md, docs\TRADE_LOGIC.md). The original   |
//| spec defaults: MQL5\Presets\FootprintTrader_spec.set.              |
//|                                                                    |
//| v1.11: tick feed held while disconnected / just reconnected (no    |
//| more minute-long OnTick blocks), EA status heartbeat for the chart |
//| badge (FPStatus.mqh), stable auto row size. Defaults: min 2 grade  |
//| points, 0.25 % risk, 10 % kill switch. New research setup SIB      |
//| (stacked-imbalance breakout), off by default.                      |
//+------------------------------------------------------------------+
#property copyright   "FootprintTrader"
#property version     "1.11"
#property description "Closed-bar order-flow footprint setups (SZR / ABS / EXH / DIV)."
#property description "Start with SIGNALS_ONLY, then VIRTUAL, then LIVE on a demo account."
#property description "Tester: only 'Every tick based on real ticks' is meaningful."

#include <OrderFlowFP\Trade\FPJournal.mqh>
#include <OrderFlowFP\FPStatus.mqh>

//+------------------------------------------------------------------+
//| Inputs (03 §10). Comment = label; [..] = optimisation range.      |
//| Optimise at most 4 parameters per setup at once (03 §11).         |
//+------------------------------------------------------------------+
input group "Mode"
input ENUM_FP_TRADE_MODE     InpTradeMode         = FP_MODE_SIGNALS_ONLY; // Trade mode SIGNALS_ONLY/VIRTUAL/LIVE [not optimised]
input long                   InpMagic             = 240611;      // Magic number [fixed]
input bool                   InpCommonFiles       = false;       // CSV files in the common Files folder [fixed]
input bool                   InpDumpBars          = false;       // Dump closed bars in FPDumpBars format [fixed]
input bool                   InpAttachIndicator   = false;       // Attach OrderFlowFP\FootprintChart (visuals only) [fixed]
input int                    InpMaxSignalLagSec   = 10;          // Max signal lag after the bar close, s [fixed 10]
input int                    InpMaxLatePendingSec = 180;         // Late bar (feed stall) still placed as a pending order if untriggered, up to s (0 = off; spec 0) [fixed]
input bool                   InpShowStatus        = true;        // Show the EA status (LIVE / PAUSED / OFF ...) on the chart [fixed]

input group "Research"
input bool                   InpPlaceboPriceOnly  = false;       // Placebo: price-only setups, no order flow [false/true per study]
input double                 InpStressSpreadMult  = 1.0;         // VIRTUAL spread multiplier [1.0..2.0 step 0.25]
input int                    InpStressSlipPts     = 0;           // VIRTUAL slippage per fill, points [0..50 step 10]
input bool                   InpResearchAllSignals = false;      // VIRTUAL research: simulate EVERY signal as an independent trade (filters/grade/risk logged, not applied) [keep false]

input group "Engine"
input ENUM_FP_SOURCE         InpSource            = FP_SRC_AUTO; // Volume source (same as the indicator) [fixed]
input int                    InpBucketPoints      = 0;           // Row height in points, 0 = auto (same as the indicator) [fixed]
input ENUM_FP_QUOTE_PRICE    InpQuotePrice        = FP_QP_BID;   // QUOTE row price BID/MID [fixed]
input int                    InpWarmupBars        = 300;         // Warm-up closed bars (= indicator InpHistoryBars) [fixed]
input string                 InpSessionStart      = "00:00";     // Session start HH:MM server time (same as the indicator) [fixed]
input double                 InpImbRatio1         = 2.0;         // Imbalance ratio tier 1 [fixed 2]
input double                 InpImbRatio2         = 3.0;         // Imbalance ratio tier 2 [fixed 3]
input double                 InpImbRatio3         = 4.0;         // Imbalance ratio tier 3 [fixed 4]
input double                 InpImbMinVolume      = 10;          // Imbalance min dominant volume [3..50 step 1]
input int                    InpStackMinRows      = 3;           // Stack min rows [2..5 step 1]

input group "SZR"
input bool                   InpSZREnable         = true;        // SZR: enable zone-retest setup [fixed]
input ENUM_FP_SZR_ENTRY      InpSZREntry          = FP_SZR_CONFIRM_CLOSE; // SZR entry mode [fixed]
input int                    InpSZRMinRows        = 3;           // SZR min stacked rows [2..5 step 1]
input int                    InpSZRMinTier        = 2;           // SZR min imbalance tier in the stack [1..3 step 1]
input double                 InpSZRMinDeltaPct    = 0.10;        // SZR min origin-bar delta% [0..0.3 step 0.05]
input double                 InpSZRMaxHeightATR   = 0.6;         // SZR max zone height x ATR [0.3..1.0 step 0.1]
input int                    InpSZRMaxAgeBars     = 30;          // SZR max zone age, bars [10..60 step 10]
input int                    InpSZRMaxTouches     = 1;           // SZR max touches before the retest [fixed 1]

input group "SIB (v1.11 research setup - test in VIRTUAL before LIVE)"
input bool                   InpSIBEnable         = false;       // SIB: breakout of a fresh stacked-imbalance zone (continuation) [false/true per study]
input int                    InpSIBLookback       = 10;          // SIB: the bar must make a new high/low of this many bars [5..30 step 5]
input int                    InpSIBValidBars      = 2;           // SIB: stop-entry validity, bars [1..4 step 1]

input group "ABS/EXH"
input bool                   InpRevEnable         = true;        // ABS/EXH: enable reversal setups [fixed]
input int                    InpRevLookback       = 20;          // Extreme lookback, bars [10..40 step 5]
input int                    InpRevRows           = 3;           // Extreme rows k [2..5 step 1]
input double                 InpABSSellShare      = 0.60;        // ABS absorbed-side share [0.55..0.75 step 0.05]
input double                 InpABSConcentration  = 1.5;         // ABS concentration [1.2..2.5 step 0.1]
input double                 InpABSCloseFrac      = 0.50;        // ABS close location [0.4..0.7 step 0.05]
input double                 InpEXHMaxPct         = 0.03;        // EXH max extreme-row share of volume [0.01..0.06 step 0.01]
input double                 InpRevMinVolMult     = 1.0;         // Min bar volume x SMA(20) [0.8..2.0 step 0.2]
input int                    InpRevEntryOffsetPts = 0;           // Stop-entry offset beyond the bar, points [fixed 0]
input int                    InpRevValidBars      = 2;           // Stop-entry validity, bars [1..4 step 1]
input double                 InpLevelTolATR       = 0.25;        // Level confluence tolerance x ATR [fixed 0.25]

input group "DIV"
input int                    InpDIVPivot          = 3;           // Divergence pivot strength [fixed 3]
input int                    InpDIVMaxBars        = 30;          // Divergence max pivot distance, bars [fixed 30]
input bool                   InpDIVStandalone     = false;       // Trade DIV standalone [fixed false]

input group "Grade"
input ENUM_FP_GRADE          InpMinGrade          = FP_GRADE_C;  // Minimum grade to trade [C, B or A] (spec B)
input int                    InpMinPoints         = 2;           // Minimum grade points to trade (0..5; grade C = 0-2 points; v1.10 1, spec 0) [0..3 step 1]

input group "Filters"
input int                    InpMinTicksPerBar    = 60;          // Min ticks per bar (M1 20, M5 60, M15 150) [fixed per TF]
input ENUM_FP_REQUIRE_SOURCE InpRequireSource     = FP_REQ_ANY;  // Required volume source [fixed]
input string                 InpTradeStart        = "00:00";     // Entries from HH:MM server time (start = end: all day; spec 08:00) [fixed per symbol]
input string                 InpTradeEnd          = "00:00";     // Entries until HH:MM server time (spec 20:00) [fixed per symbol]
input string                 InpFridayCutoff      = "18:00";     // No entries on Friday after HH:MM ("" = off) [fixed]
input int                    InpMaxSpreadPts      = 0;           // Max spread, points (0 = off) [fixed]
input double                 InpMaxSpreadATR      = 0.15;        // Max spread x ATR [0.10..0.25 step 0.05]
input double                 InpMinATRPts         = 0;           // Min ATR(14), points [fixed per symbol]
input double                 InpRevMaxATRRatio    = 1.60;        // ABS/EXH regime: ATR/SMA(ATR,50) <= this (99 = off; spec 1.30) [1.15..2.0 step 0.15]
input double                 InpSZRMinATRRatio    = 0.85;        // SZR regime: ATR/SMA(ATR,50) >= this [fixed 0.85]
input ENUM_TIMEFRAMES        InpHTF               = PERIOD_H1;   // Higher timeframe for the trend filter [fixed H1]
input int                    InpHTFEMA            = 50;          // HTF EMA period [fixed 50]
input int                    InpNewsMin           = 15;          // News blackout +/- minutes (live only) [fixed 15]
input int                    InpMaxPositions      = 1;           // Max positions + pending entries of this magic [fixed 1]

input group "Risk"
input double                 InpRiskPct           = 0.25;        // Risk per trade, % of equity (v1.10 and spec 0.5) [0.1..1.0 step 0.1]
input bool                   InpAllowMinLot       = false;       // Trade the minimum lot if the size is below it [fixed false]
input int                    InpMaxTradesPerDay   = 10;          // Max entries per server day (0 = off; spec 4) [fixed]
input double                 InpMaxDailyLossPct   = 2.0;         // Max daily loss, % of day-start equity (0 = off) [fixed 2]
input int                    InpMaxConsecLosses   = 3;           // Consecutive losses -> pause (0 = off) [fixed 3]
input int                    InpConsecPauseMin    = 60;          // Pause after the consecutive losses, minutes (0 = until the next server day = spec) [0..240 step 30]
input double                 InpMaxDDPct          = 10;          // Kill switch: equity DD from peak, % (0 = off; v1.10 15, spec 10) [fixed]

input group "Exits"
input double                 InpSLBufferATR       = 0.10;        // Stop buffer x ATR [0.05..0.3 step 0.05]
input ENUM_FP_TP_MODE        InpTPMode            = FP_TP_R_MULTIPLE; // Target mode [R_MULTIPLE / STRUCTURE]
input double                 InpTP_R_SZR          = 2.0;         // SZR target, R [1.5..3.0 step 0.25]
input double                 InpTP_R_REV          = 2.0;         // ABS/EXH target, R (spec 1.5) [1.0..2.5 step 0.25]
input double                 InpPartialPct        = 50;          // Partial close, % of the initial volume [fixed 50; 0 = off]
input double                 InpPartialR          = 1.0;         // Partial + break-even at, R (0 = off) [fixed 1.0]
input int                    InpBEOffsetPts       = 0;           // Break-even offset, points [fixed 0]
input double                 InpTrailStartR       = 1.5;         // Trailing starts at, R (0 = off) [fixed 1.5]
input ENUM_FP_TRAIL_MODE     InpTrailMode         = FP_TRAIL_ATR; // Trailing mode ATR / BAR [fixed]
input double                 InpTrailATR          = 1.0;         // ATR trailing distance x ATR [fixed 1.0]
input int                    InpTimeStopBars      = 12;          // Time stop after N bars (0 = off) [fixed 12]
input double                 InpTimeStopMinR      = 0.3;         // Time stop if open profit below, R [fixed 0.3]
input bool                   InpExitOnOpposite    = false;       // Close on an opposite grade-A signal [fixed false]
input string                 InpFlatTime          = "";          // Flat time HH:MM server time ("" = off) [fixed]

input group "Execution"
input int                    InpSlippagePts       = 20;          // Max deviation for market orders, points [fixed 20]

input group "Test hooks (E2 acceptance only - keep OFF)"
input datetime               InpTestDailyLossAt   = 0;           // TEST: inject a daily-limit loss at this time (0 = off)
input datetime               InpTestConsecLossAt  = 0;           // TEST: set consecutive losses to the limit at this time (0 = off)
input datetime               InpTestKillAt        = 0;           // TEST: raise the equity peak so the kill switch fires (0 = off)
input bool                   InpTestResetKill     = false;       // TEST: delete the persisted kill flag/peak/day block at start

//+------------------------------------------------------------------+
//| Globals                                                           |
//+------------------------------------------------------------------+
CFPEngine     g_engine;
CFPSignals    g_signals;
CFPFilters    g_filters;
CFPRisk       g_risk;
CFTPlanner    g_planner;
CFPExecution  g_exec;
CFPVirtual    g_virt;
CFPJournal    g_journal;

bool     g_tester       = false;
bool     g_engineOk     = false;
bool     g_signalsOk    = false;
bool     g_filtersOk    = false;
bool     g_journalOk    = false;
bool     g_inited       = false;
bool     g_readySeen    = false;
bool     g_halted       = false;
bool     g_dealsDirty   = false;
int      g_warmupLeft   = 0;
int      g_flatMin      = -1;
double   g_lastAtr      = 0.0;
int      g_indHandle    = INVALID_HANDLE;
int      g_updateErrors = 0;
int      g_updateFailStreak = 0;
ulong    g_lastBlockMs  = 0;            // GetTickCount64() when Update() last blocked >= 5 s (0 = never)
long     g_statusSec    = 0;            // TimeLocal() second of the last status publish
//--- OnTick timing (03 §14: <= 5 ms average outside bar closes)
ulong    g_perfN        = 0;
ulong    g_perfSumUs    = 0;
ulong    g_perfMaxUs    = 0;
ulong    g_perfBarN     = 0;
ulong    g_perfBarSumUs = 0;

//+------------------------------------------------------------------+
//| Helpers                                                           |
//+------------------------------------------------------------------+
bool ParseTime(const string name, const string v, const bool emptyIsOff, int &out)
{
   out = FPParseHHMM(v);
   if(out == -2 || (out == -1 && !emptyIsOff))
   {
      Print("FT INIT: input ", name, "=\"", v, "\" is not a valid HH:MM time");
      return false;
   }
   return true;
}

void FillMarketNow(FTMarket &m, const MqlTick &tk)
{
   g_planner.FillMarket(m, tk.bid, tk.ask, g_lastAtr, TimeCurrent());
}

void DrainRecords()
{
   FTTradeRecord r;
   int guard = 0;
   while(guard++ < 1000 && g_exec.PopRecord(r))
      g_journal.LogTrade(r);
   guard = 0;
   while(guard++ < 1000 && g_virt.PopRecord(r))
      g_journal.LogTrade(r);
}

//--- engine history became ready: report, decide the warm-up fallback (03 §2)
void CheckReady()
{
   if(g_readySeen || !g_engine.HistoryReady())
      return;
   g_readySeen = true;
   //--- walk the held closed bars newest -> oldest (At(1), then PrevBarTime) and count their states
   int      ok = 0;
   int      nodata = 0;
   int      closed = 0;
   int      limit = g_engine.Total() + 1;
   CFPBar  *b1 = g_engine.At(1);
   datetime t = (b1 != NULL) ? b1.time : 0;
   for(int guard = 0; t > 0 && guard < limit; guard++)
   {
      CFPBar *b = g_engine.ByTime(t);
      if(b != NULL && b.closed)
      {
         closed++;
         if(b.state == 0)
            ok++;
         else if(b.state == 2)
            nodata++;
      }
      t = g_engine.PrevBarTime(t);
   }
   g_filters.StartupWarnings();             // again: with AUTO the source may only be decided now
   Print(StringFormat("FT READY: engine history ready - %d closed bars held (%d ok, %d nodata), source %s, row %s",
                      closed, ok, nodata, FTSourceName(g_engine.ActiveSource()), DoubleToString(g_engine.RowSize(), _Digits)));
   if(ok < InpWarmupBars / 2 || nodata > ok)
   {
      g_warmupLeft = InpWarmupBars;
      Print("FT WARMUP: history is mostly nodata (", ok, " ok bars) - the first ", InpWarmupBars,
            " live bars are warm-up: signals are logged as FILTERED:WARMUP, no trades");
   }
}

//--- kill switch / daily loss / consecutive losses; reacts to events that fired now
void RiskMonitor(const MqlTick &tk, const datetime now)
{
   if(InpTradeMode == FP_MODE_SIGNALS_ONLY)
      return;
   double eq = 0.0;
   double fl = 0.0;
   if(InpTradeMode == FP_MODE_LIVE)
   {
      eq = AccountInfoDouble(ACCOUNT_EQUITY);
      fl = g_exec.Floating();
   }
   else
   {
      fl = g_virt.Floating(tk);
      eq = g_virt.Equity(tk);
   }
   int ev = g_risk.Monitor(now, eq, fl);
   FTMarket m;
   FillMarketNow(m, tk);
   if((ev & FT_RISK_EV_KILL) != 0)
   {
      if(InpTradeMode == FP_MODE_LIVE)
      {
         g_exec.CancelAll("KILL", m);
         g_exec.CloseAll("KILL", m);
      }
      else
      {
         g_virt.CancelAll("KILL", tk);
         g_virt.CloseAll("KILL", tk);
      }
   }
   if((ev & (FT_RISK_EV_DAYLOSS | FT_RISK_EV_CONSEC)) != 0)
   {
      if(InpTradeMode == FP_MODE_LIVE)
         g_exec.CancelAll("RISK", m);
      else
         g_virt.CancelAll("RISK", tk);
   }
   //--- flat time: no pending entry survives it (positions are closed by the shared decision routine)
   if(g_flatMin >= 0 && FTMinuteOfDay(now) >= g_flatMin)
   {
      if(InpTradeMode == FP_MODE_LIVE && g_exec.PendingCount() > 0)
         g_exec.CancelAll("FLAT", m);
      if(InpTradeMode == FP_MODE_VIRTUAL && g_virt.PendingCount() > 0)
         g_virt.CancelAll("FLAT", tk);
   }
}

//--- one signal of closed bar T: filters + grade + risk gates -> decision -> journal -> order
void HandleSignal(const FPSignal &sig, const int idx, const datetime T, CFPBar *bar, const FPContext &ctx,
                  const MqlTick &tk, const bool warm, const long lateSec)
{
   long sid = (long)T * 100 + idx;
   //--- research (VIRTUAL only): every signal becomes its own virtual trade; the reasons are logged, not applied
   bool research = (InpResearchAllSignals && InpTradeMode == FP_MODE_VIRTUAL);
   bool busy = false;
   if(InpTradeMode == FP_MODE_LIVE)
      busy = g_exec.Busy(InpMaxPositions);
   else if(InpTradeMode == FP_MODE_VIRTUAL && !research)
      busy = g_virt.Busy(InpMaxPositions);
   string reasons = "";
   bool pass = g_filters.CheckSignal(sig, bar, ctx, busy, reasons);
   if(!pass && reasons == "")
      reasons = "FILTER";
   if(sig.grade < (int)InpMinGrade || sig.points < InpMinPoints)
      FTAddReason(reasons, "GRADE");
   FTPlan plan;
   plan.Reset();
   string codes = "";
   string note = "";
   string why = "";
   string extra = "";
   if(InpTradeMode != FP_MODE_SIGNALS_ONLY)
   {
      int pend = (InpTradeMode == FP_MODE_LIVE) ? g_exec.PendingCount() : g_virt.PendingCount();
      if(!research)
         g_risk.Gates(pend, reasons);
      MqlTick ptk = tk;
      double eq = 0.0;
      double fm = 0.0;
      if(InpTradeMode == FP_MODE_VIRTUAL)
      {
         g_virt.Stress(tk, ptk);
         eq = g_virt.Equity(tk);
         fm = research ? MathMax(eq, 1.0) * 1000.0 : g_virt.FreeMargin(tk);   // research: margin never binds
      }
      else
      {
         eq = AccountInfoDouble(ACCOUNT_EQUITY);
         fm = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      }
      g_planner.Build(sig, sid, ptk, 0.0, eq, fm, plan, codes, note);
      if(codes == "RISK_MIN_LOT" || codes == "RISK_MARGIN")
         FTAddReason(reasons, codes);
      if(plan.entry > 0.0)
         extra = g_planner.Describe(plan);
      if(note != "")
         extra = (extra == "") ? "note=" + note : extra + ";note=" + note;
   }
   if(warm)
      FTAddReason(reasons, "WARMUP");
   //--- a bar processed late (feed stall) is only usable as a pending entry that the market has not reached yet:
   //--- market entries and stop levels already crossed (the planner would chase them at market) are LATE
   if(lateSec > 0)
   {
      bool pendingSig = (sig.entryPrice > 0.0 && (sig.orderKind == FP_ORD_STOP || sig.orderKind == FP_ORD_LIMIT));
      bool chased = (InpTradeMode != FP_MODE_SIGNALS_ONLY && plan.entry > 0.0 && plan.kind == FP_ORD_MARKET);
      if(!pendingSig || chased)
         FTAddReason(reasons, "LATE");
      extra = (extra == "") ? StringFormat("lateSec=%I64d", lateSec) : extra + StringFormat(";lateSec=%I64d", lateSec);
   }
   if(InpTradeMode != FP_MODE_SIGNALS_ONLY)
   {
      if(g_flatMin >= 0 && FTMinuteOfDay(TimeCurrent()) >= g_flatMin)
         FTAddReason(reasons, "FLAT");
      if(codes == "PLAN")
         FTAddReason(reasons, "PLAN");
      if(InpTradeMode == FP_MODE_LIVE && !g_exec.TradeAllowed(sig.dir, why))
      {
         FTAddReason(reasons, "TRADE_DISABLED");
         extra = (extra == "") ? "precheck=" + why : extra + ";precheck=" + why;
      }
   }
   string decision = (reasons != "") ? "FILTERED:" + reasons : ((InpTradeMode == FP_MODE_SIGNALS_ONLY) ? "SIGNALS_ONLY" : "TAKEN");
   //--- research: only an impossible plan (or warm-up / flat time) stops the simulation; every other reason is data
   if(research && !warm && codes == "" && StringFind(reasons, "FLAT") < 0)
      decision = "RESEARCH:" + ((reasons == "") ? "PASS" : reasons);
   g_journal.LogSignal(sid, sig, bar, ctx, decision, extra);
   Print(StringFormat("FT SIGNAL sid %I64d %s %s grade %s (%d pts) -> %s", sid, FPSetupName(sig.type), sig.dir > 0 ? "LONG" : "SHORT",
                      FPGradeName(sig.grade), sig.points, decision));
   if(decision != "TAKEN" && StringFind(decision, "RESEARCH:") != 0)
      return;
   if(InpTradeMode == FP_MODE_LIVE)
      g_exec.Submit(sig, sid, plan);
   else if(InpTradeMode == FP_MODE_VIRTUAL)
      g_virt.Submit(sig, sid, plan, tk);
}

//--- skipped bar (NOT_READY / LATE): refresh the ATR from a context built as of T when possible.
//--- Without any known ATR only the ATR-dependent action (ATR trailing) waits; it is logged.
void RefreshSkippedContext(const datetime T)
{
   if(g_engine.HistoryReady() && g_signals.IndicatorsReady())
   {
      FPContext c;
      c.Reset();
      if(g_signals.BuildContext(T, c) && c.valid && c.atr > 0.0)
         g_lastAtr = c.atr;
   }
   if(g_lastAtr <= 0.0 && InpTrailMode == FP_TRAIL_ATR && InpTrailStartR > 0.0 && g_exec.OpenCount() + g_virt.OpenCount() > 0)
      Print("FT MGMT: no ATR known at skipped bar ", TimeToString(T, TIME_DATE | TIME_SECONDS),
            " - ATR trailing waits for a valid context; expiry, time stop and BAR trailing still run");
}

//--- docs\EA_ARCHITECTURE §6, signal part for one popped bar T.
//--- Returns false when T is skipped (NOT_READY / LATE) or the EA is halting (ASSERT).
bool EvaluateBar(const datetime T, const MqlTick &tk, bool &longA, bool &shortA)
{
   longA = false;
   shortA = false;
   CFPBar *bar = g_engine.ByTime(T);
   if(!g_engine.HistoryReady() || !g_signals.IndicatorsReady())
   {
      g_journal.LogSkip(T, bar, g_engine.ActiveSource(), "NOT_READY", g_engine.HistoryReady() ? "indicators" : "engine");
      return false;
   }
   bool warm = (g_warmupLeft > 0);
   if(g_warmupLeft > 0)
      g_warmupLeft--;
   //--- staleness guard (03 §4). T must be the bar just before the forming one (a bar before a break or weekend
   //--- never is). A lag above InpMaxSignalLagSec but within InpMaxLatePendingSec (a feed stall, e.g. CopyTicks
   //--- blocked during a reconnect) is evaluated, but only untriggered pending entries may be placed (HandleSignal).
   int      P = PeriodSeconds(_Period);
   datetime forming = iTime(_Symbol, _Period, 0);
   long     lag = (long)TimeCurrent() - ((long)T + P);
   int      when = CFPFilters::Staleness((long)T + P == (long)forming, lag, InpMaxSignalLagSec, InpMaxLatePendingSec);
   long     lateSec = (when == FP_BAR_LATE_PENDING) ? lag : 0;
   if(when == FP_BAR_STALE)
   {
      g_journal.LogSkip(T, bar, g_engine.ActiveSource(), "LATE",
                        StringFormat("forming=%s;lagSec=%I64d", TimeToString(forming, TIME_DATE | TIME_SECONDS), lag));
      return false;
   }
   //--- no-look-ahead assertion
   if(T >= forming)
   {
      Print("FT ASSERT: closed bar ", TimeToString(T, TIME_DATE | TIME_SECONDS), " >= forming bar ",
            TimeToString(forming, TIME_DATE | TIME_SECONDS), " - stopping the EA");
      g_journal.LogSkip(T, bar, g_engine.ActiveSource(), "ASSERT", "barTime>=forming");
      g_halted = true;
      ExpertRemove();
      return false;
   }
   if(InpDumpBars && bar != NULL)
      g_journal.DumpBar(bar, GetPointer(g_engine));
   FPSignal sigs[];
   int n = g_signals.Evaluate(T, sigs);
   if(n > ArraySize(sigs))
      n = ArraySize(sigs);
   FPContext ctx;
   ctx.Reset();
   g_signals.LastContext(ctx);
   if(ctx.atr > 0.0)
      g_lastAtr = ctx.atr;
   bar = g_engine.ByTime(T);
   for(int i = 0; i < n; i++)
   {
      if(sigs[i].barTime >= forming)
      {
         Print("FT ASSERT: signal ", i, " of bar ", TimeToString(T, TIME_DATE | TIME_SECONDS), " has barTime ",
               TimeToString(sigs[i].barTime, TIME_DATE | TIME_SECONDS), " >= forming bar - stopping the EA");
         g_journal.LogSkip(T, bar, g_engine.ActiveSource(), "ASSERT", "signal.barTime>=forming");
         g_halted = true;
         ExpertRemove();
         return false;
      }
      if(sigs[i].grade >= (int)FP_GRADE_A)
      {
         if(sigs[i].dir > 0)
            longA = true;
         else if(sigs[i].dir < 0)
            shortA = true;
      }
      HandleSignal(sigs[i], i, T, bar, ctx, tk, warm, lateSec);
   }
   return true;
}

//--- one popped bar T: signals when T is evaluable, then bar-close management for EVERY popped bar
//--- (pending expiry/invalidation, time stop, BAR trailing; exit-on-opposite only from evaluated signals)
void ProcessClosedBar(const datetime T, const MqlTick &tk)
{
   bool longA = false;
   bool shortA = false;
   bool evaluated = EvaluateBar(T, tk, longA, shortA);
   if(g_halted)
      return;
   if(!evaluated)
      RefreshSkippedContext(T);
   CFPBar *bar = g_engine.ByTime(T);
   bool   use = (bar != NULL && bar.closed);
   double lo = use ? bar.low : 0.0;
   double hi = use ? bar.high : 0.0;
   FTMarket m;
   FillMarketNow(m, tk);
   g_exec.OnBarClosed(T, lo, hi, longA, shortA, m);
   if(InpTradeMode == FP_MODE_VIRTUAL)
      g_virt.OnBarClosed(T, lo, hi, longA, shortA, tk, g_lastAtr);
}

//+------------------------------------------------------------------+
//| Status heartbeat (FPStatus.mqh). The FootprintChart header shows   |
//| it as a coloured badge; without the indicator the EA draws its own  |
//| label. Published once a second and whenever a bar was processed.    |
//+------------------------------------------------------------------+
#define FT_STATUS_OBJ "FT_STATUS"

bool FootprintOnChart()
{
   int n = ChartIndicatorsTotal(0, 0);
   for(int i = 0; i < n; i++)
      if(ChartIndicatorName(0, 0, i) == "OrderFlowFP Footprint")
         return true;
   return false;
}

void BuildStatus(FTStatus &s)
{
   ZeroMemory(s);
   s.present = true;
   s.mode    = (int)InpTradeMode;
   int pend  = 0;
   if(InpTradeMode == FP_MODE_LIVE)
   {
      s.open = g_exec.OpenCount() + g_exec.PendingCount();
      pend   = g_exec.PendingCount();
      if(TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) == 0 || MQLInfoInteger(MQL_TRADE_ALLOWED) == 0 ||
         AccountInfoInteger(ACCOUNT_TRADE_EXPERT) == 0 || AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) == 0)
         s.flags |= FTS_ALGO_OFF;
   }
   else if(InpTradeMode == FP_MODE_VIRTUAL)
   {
      s.open = g_virt.OpenCount() + g_virt.PendingCount();
      pend   = g_virt.PendingCount();
   }
   if(!g_tester && TerminalInfoInteger(TERMINAL_CONNECTED) == 0)
      s.flags |= FTS_DISCONNECTED;
   if(!g_engine.HistoryReady() || !g_signals.IndicatorsReady())
      s.flags |= FTS_LOADING;
   if(g_warmupLeft > 0)
      s.flags |= FTS_WARMUP;
   if(g_halted)
      s.flags |= FTS_HALTED;
   if(g_engine.FeedHeld() || g_updateFailStreak > 0 || (g_lastBlockMs > 0 && GetTickCount64() - g_lastBlockMs < 60000))
      s.flags |= FTS_FEED_STALL;
   if(InpTradeMode != FP_MODE_SIGNALS_ONLY)
   {
      if(g_risk.KillActive())
         s.flags |= FTS_KILL;
      if(g_risk.DayLossHit())
         s.flags |= FTS_DAY_LOSS;
      if(g_risk.ConsecBlocked())
         s.flags |= FTS_PAUSE;
      if(g_risk.DayCapHit(0))
         s.flags |= FTS_DAY_CAP;
      s.tradesToday = g_risk.TradesToday();
      s.maxTrades   = g_risk.MaxTradesPerDay();
      s.pauseUntil  = g_risk.PauseUntil();
   }
}

void DrawStatusLabel(const string text, const int severity)
{
   if(g_tester && MQLInfoInteger(MQL_VISUAL_MODE) == 0)
      return;
   if(!InpShowStatus || FootprintOnChart())
   {
      ObjectDelete(0, FT_STATUS_OBJ);     // the indicator header shows the badge
      return;
   }
   color col = clrLimeGreen;
   if(severity == FTS_SEV_INFO)
      col = clrDodgerBlue;
   else if(severity == FTS_SEV_WARN)
      col = clrOrange;
   else if(severity == FTS_SEV_BAD)
      col = clrRed;
   if(ObjectFind(0, FT_STATUS_OBJ) < 0)
   {
      ObjectCreate(0, FT_STATUS_OBJ, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, FT_STATUS_OBJ, OBJPROP_CORNER, CORNER_LEFT_LOWER);
      ObjectSetInteger(0, FT_STATUS_OBJ, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
      ObjectSetInteger(0, FT_STATUS_OBJ, OBJPROP_XDISTANCE, 10);
      ObjectSetInteger(0, FT_STATUS_OBJ, OBJPROP_YDISTANCE, 10);
      ObjectSetString(0, FT_STATUS_OBJ, OBJPROP_FONT, "Arial Bold");
      ObjectSetInteger(0, FT_STATUS_OBJ, OBJPROP_FONTSIZE, 11);
      ObjectSetInteger(0, FT_STATUS_OBJ, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, FT_STATUS_OBJ, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, FT_STATUS_OBJ, OBJPROP_BACK, false);
   }
   ObjectSetString(0, FT_STATUS_OBJ, OBJPROP_TEXT, "FootprintTrader: " + text);
   ObjectSetInteger(0, FT_STATUS_OBJ, OBJPROP_COLOR, col);
   ChartRedraw(0);
}

void PublishStatus(const bool force)
{
   if(!g_inited || MQLInfoInteger(MQL_OPTIMIZATION) != 0)
      return;
   long sec = (long)TimeLocal();
   if(!force && sec == g_statusSec)
      return;
   g_statusSec = sec;
   FTStatus s;
   BuildStatus(s);
   FTSWrite(_Symbol, InpMagic, s);
   s.heartbeat = (datetime)sec;
   int sev = FTS_SEV_BAD;
   string text = FTSDescribe(s, sev);
   DrawStatusLabel(text, sev);
}

void AttachIndicator()
{
   if(!InpAttachIndicator)
      return;
   if(g_tester && MQLInfoInteger(MQL_VISUAL_MODE) == 0)
   {
      Print("FT ATTACH: skipped in a non-visual test (visuals only)");
      return;
   }
   string name = "OrderFlowFP\\FootprintChart";
   ResetLastError();
   g_indHandle = iCustom(_Symbol, _Period, name);
   if(g_indHandle == INVALID_HANDLE)
   {
      Print("FT ATTACH: indicator ", name, " is not available (err ", GetLastError(), ") - visuals only, the EA continues without it");
      return;
   }
   if(!ChartIndicatorAdd(0, 0, g_indHandle))
   {
      Print("FT ATTACH: ChartIndicatorAdd(", name, ") failed (err ", GetLastError(), ") - visuals only, the EA continues without it");
      IndicatorRelease(g_indHandle);
      g_indHandle = INVALID_HANDLE;
      return;
   }
   Print("FT ATTACH: ", name, " added to the chart with its default inputs (visuals only; the EA never reads its buffers)");
}

//+------------------------------------------------------------------+
//| OnInit - no long blocking: history loads via LoadStep later       |
//+------------------------------------------------------------------+
int OnInit()
{
   g_tester = (MQLInfoInteger(MQL_TESTER) != 0);
   //--- inputs
   int sessMin = 0, tsMin = 0, teMin = 0, fcMin = 0;
   if(!ParseTime("InpSessionStart", InpSessionStart, true, sessMin) || !ParseTime("InpTradeStart", InpTradeStart, true, tsMin) ||
      !ParseTime("InpTradeEnd", InpTradeEnd, true, teMin) || !ParseTime("InpFridayCutoff", InpFridayCutoff, true, fcMin) ||
      !ParseTime("InpFlatTime", InpFlatTime, true, g_flatMin))
      return INIT_PARAMETERS_INCORRECT;
   if(sessMin < 0)
      sessMin = 0;
   string bad = "";
   if(InpMagic <= 0)                                     FTAddReason(bad, "InpMagic>0");
   if(InpRiskPct <= 0.0 || InpRiskPct > 10.0)            FTAddReason(bad, "0<InpRiskPct<=10");
   if(InpPartialPct < 0.0 || InpPartialPct >= 100.0)     FTAddReason(bad, "0<=InpPartialPct<100");
   if(InpMaxPositions < 1)                               FTAddReason(bad, "InpMaxPositions>=1");
   if(InpWarmupBars < 1)                                 FTAddReason(bad, "InpWarmupBars>=1");
   if(InpStressSpreadMult < 1.0)                         FTAddReason(bad, "InpStressSpreadMult>=1");
   if(InpStressSlipPts < 0 || InpSlippagePts < 0)        FTAddReason(bad, "slippage>=0");
   if(InpMaxSignalLagSec < 0)                            FTAddReason(bad, "InpMaxSignalLagSec>=0");
   if(InpMaxDDPct < 0.0 || InpMaxDDPct >= 100.0)         FTAddReason(bad, "0<=InpMaxDDPct<100");
   if(InpMaxDailyLossPct < 0.0 || InpMaxDailyLossPct >= 100.0) FTAddReason(bad, "0<=InpMaxDailyLossPct<100");
   if(InpConsecPauseMin < 0 || InpConsecPauseMin > 1440) FTAddReason(bad, "0<=InpConsecPauseMin<=1440");
   if(InpMinPoints < 0 || InpMinPoints > 5)              FTAddReason(bad, "0<=InpMinPoints<=5");
   if(InpMaxLatePendingSec < 0)                          FTAddReason(bad, "InpMaxLatePendingSec>=0");
   if(InpSIBLookback < 1 || InpSIBValidBars < 1)         FTAddReason(bad, "InpSIBLookback>=1,InpSIBValidBars>=1");
   if(bad != "")
   {
      Print("FT INIT: invalid inputs: ", bad);
      return INIT_PARAMETERS_INCORRECT;
   }
   if(g_flatMin >= 0 && tsMin >= 0 && g_flatMin <= tsMin)
      Print("FT INIT: WARNING InpFlatTime ", InpFlatTime, " is not after InpTradeStart ", InpTradeStart, " - entries are blocked for the whole day");
   if(g_tester)
      Print("FT WARNING: Strategy Tester - the modelling mode cannot be read via the API. Only 'Every tick based on real ticks' ",
            "gives meaningful footprints; 'Every tick' (generated), '1 minute OHLC' and 'Open prices' produce meaningless order flow.");
   if(InpTradeMode == FP_MODE_LIVE)
      Print("FT INIT: LIVE mode - real orders. Use a DEMO account until the validation protocol (README_EA.md) has passed.");
   //--- engine (03 §3)
   FPConfig ec;
   ec.symbol          = _Symbol;
   ec.timeframe       = (ENUM_TIMEFRAMES)_Period;
   ec.bucketPoints    = InpBucketPoints;
   ec.source          = InpSource;
   ec.quotePrice      = InpQuotePrice;
   ec.historyBars     = InpWarmupBars;
   ec.sessionStartMin = sessMin;
   ec.imbRatio1       = InpImbRatio1;
   ec.imbRatio2       = InpImbRatio2;
   ec.imbRatio3       = InpImbRatio3;
   ec.imbMinVolume    = InpImbMinVolume;
   ec.stackMinRows    = InpStackMinRows;
   ec.valueAreaPct    = 0.70;
   if(!g_engine.Init(ec))
   {
      Print("FT INIT: engine Init failed: ", g_engine.LastError());
      return INIT_FAILED;
   }
   g_engineOk = true;
   //--- signals (03 §4, §6)
   FPSignalConfig sc;
   CFPSignals::DefaultConfig(sc);           // signals agent's defaults first (covers any additive fields), then the inputs
   sc.symbol            = _Symbol;
   sc.timeframe         = (ENUM_TIMEFRAMES)_Period;
   sc.szrEnable         = InpSZREnable;
   sc.szrEntry          = InpSZREntry;
   sc.szrMinRows        = InpSZRMinRows;
   sc.szrMinTier        = InpSZRMinTier;
   sc.szrMinDeltaPct    = InpSZRMinDeltaPct;
   sc.szrMaxHeightATR   = InpSZRMaxHeightATR;
   sc.szrMaxAgeBars     = InpSZRMaxAgeBars;
   sc.szrMaxTouches     = InpSZRMaxTouches;
   sc.revEnable         = InpRevEnable;
   sc.revLookback       = InpRevLookback;
   sc.revRows           = InpRevRows;
   sc.absSellShare      = InpABSSellShare;
   sc.absConcentration  = InpABSConcentration;
   sc.absCloseFrac      = InpABSCloseFrac;
   sc.exhMaxPct         = InpEXHMaxPct;
   sc.revMinVolMult     = InpRevMinVolMult;
   sc.revEntryOffsetPts = InpRevEntryOffsetPts;
   sc.revValidBars      = InpRevValidBars;
   sc.levelTolATR       = InpLevelTolATR;
   sc.divPivot          = InpDIVPivot;
   sc.divMaxBars        = InpDIVMaxBars;
   sc.divStandalone     = InpDIVStandalone;
   sc.minGrade          = (int)InpMinGrade;
   sc.slBufferATR       = InpSLBufferATR;
   sc.placeboPriceOnly  = InpPlaceboPriceOnly;
   sc.htf               = InpHTF;
   sc.htfEma            = InpHTFEMA;
   sc.atrPeriod         = 14;
   sc.atrBaseLen        = 50;
   sc.atrTrend          = 1.15;
   sc.atrChop           = 0.85;
   sc.volSmaLen         = 20;
   sc.exhCloseFrac      = 0.40;
   sc.valueAreaPct      = ec.valueAreaPct;   // signals-agent addition: must equal the engine's value area
   sc.placeboWickFrac   = 0.40;              // signals-agent addition (placebo ABS), its documented default
   sc.placeboSzrBodyATR = 0.60;              // signals-agent addition (placebo SZR), its documented default
   sc.sibEnable         = InpSIBEnable;
   sc.sibLookback       = InpSIBLookback;
   sc.sibValidBars      = InpSIBValidBars;
   if(!g_signals.Init(GetPointer(g_engine), sc))
   {
      Print("FT INIT: signals Init failed");
      return INIT_FAILED;
   }
   g_signalsOk = true;
   //--- filters (03 §5)
   FPFilterConfig fc;
   CFPFilters::DefaultConfig(fc);           // filters agent's defaults first, then the inputs
   fc.symbol          = _Symbol;
   fc.timeframe       = (ENUM_TIMEFRAMES)_Period;
   fc.minTicksPerBar  = InpMinTicksPerBar;
   fc.requireSource   = InpRequireSource;
   fc.tradeStartMin   = tsMin;
   fc.tradeEndMin     = teMin;
   fc.fridayCutoffMin = fcMin;
   fc.maxSpreadPts    = InpMaxSpreadPts;
   fc.maxSpreadATR    = InpMaxSpreadATR;
   fc.minATRPts       = InpMinATRPts;
   fc.szrMinAtrRatio  = InpSZRMinATRRatio;
   fc.revMaxAtrRatio  = InpRevMaxATRRatio;
   fc.htf             = InpHTF;
   fc.htfEma          = InpHTFEMA;
   fc.newsMin         = InpNewsMin;
   fc.maxPositions    = InpMaxPositions;
   if(!g_filters.Init(GetPointer(g_engine), fc))
   {
      Print("FT INIT: filters Init failed");
      return INIT_FAILED;
   }
   g_filtersOk = true;
   g_filters.StartupWarnings();
   //--- journal (CSV + optional bar dump)
   if(!g_journal.Init(_Symbol, (ENUM_TIMEFRAMES)_Period, InpCommonFiles, (int)InpTradeMode, InpDumpBars, GetPointer(g_engine)))
   {
      Print("FT INIT: journal files could not be opened");
      return INIT_FAILED;
   }
   g_journalOk = true;
   //--- risk (03 §7): LIVE persists in GlobalVariables, VIRTUAL lives in memory
   MqlTick tk;
   if(!SymbolInfoTick(_Symbol, tk))
      ZeroMemory(tk);
   FTRiskConfig rc;
   rc.symbol           = _Symbol;
   rc.magic            = InpMagic;
   rc.tag              = (InpTradeMode == FP_MODE_LIVE) ? "LIVE" : "VIRTUAL";
   rc.persist          = (InpTradeMode == FP_MODE_LIVE);
   rc.riskPct          = InpRiskPct;
   rc.allowMinLot      = InpAllowMinLot;
   rc.maxTradesPerDay  = InpMaxTradesPerDay;
   rc.maxDailyLossPct  = InpMaxDailyLossPct;
   rc.maxConsecLosses  = InpMaxConsecLosses;
   rc.consecPauseMin   = InpConsecPauseMin;
   rc.maxDDPct         = InpMaxDDPct;
   rc.testDailyLossAt  = InpTestDailyLossAt;
   rc.testConsecLossAt = InpTestConsecLossAt;
   rc.testKillAt       = InpTestKillAt;
   rc.testResetKill    = InpTestResetKill;
   double eq0 = (InpTradeMode == FP_MODE_LIVE) ? AccountInfoDouble(ACCOUNT_EQUITY) : AccountInfoDouble(ACCOUNT_BALANCE);
   g_risk.Init(rc, eq0);
   if(InpTestDailyLossAt > 0 || InpTestConsecLossAt > 0 || InpTestKillAt > 0 || InpTestResetKill)
      Print("FT TEST: test hooks are ACTIVE - this run is a risk-path test, not a study");
   //--- planner + executors (shared management config)
   FTPlanConfig pc;
   pc.symbol     = _Symbol;
   pc.tf         = (ENUM_TIMEFRAMES)_Period;
   pc.quotePrice = InpQuotePrice;
   pc.tpMode     = InpTPMode;
   pc.tpRSzr     = InpTP_R_SZR;
   pc.tpRRev     = InpTP_R_REV;
   if(!g_planner.Init(pc, GetPointer(g_engine), GetPointer(g_risk)))
   {
      Print("FT INIT: planner Init failed");
      return INIT_FAILED;
   }
   FTMgmtConfig mc;
   mc.partialPct     = InpPartialPct;
   mc.partialR       = InpPartialR;
   mc.beOffsetPts    = (double)InpBEOffsetPts;
   mc.trailStartR    = InpTrailStartR;
   mc.trailMode      = (int)InpTrailMode;
   mc.trailAtr       = InpTrailATR;
   mc.timeStopBars   = InpTimeStopBars;
   mc.timeStopMinR   = InpTimeStopMinR;
   mc.exitOnOpposite = InpExitOnOpposite;
   mc.flatMin        = g_flatMin;
   FTExecConfig xc;
   xc.symbol      = _Symbol;
   xc.tf          = (ENUM_TIMEFRAMES)_Period;
   xc.magic       = InpMagic;
   xc.slippagePts = InpSlippagePts;
   if(!g_exec.Init(xc, mc, GetPointer(g_planner), GetPointer(g_filters)))
   {
      Print("FT INIT: execution Init failed");
      return INIT_FAILED;
   }
   FTVirtConfig vc;
   vc.symbol     = _Symbol;
   vc.tf         = (ENUM_TIMEFRAMES)_Period;
   vc.spreadMult = InpStressSpreadMult;
   vc.slipPts    = InpStressSlipPts;
   if(!g_virt.Init(vc, mc, GetPointer(g_planner), GetPointer(g_risk), GetPointer(g_filters)))
   {
      Print("FT INIT: virtual simulator Init failed");
      return INIT_FAILED;
   }
   if(InpTradeMode == FP_MODE_VIRTUAL)
      g_virt.Describe();
   //--- restart: live positions/orders of this magic are restored and managed in EVERY mode
   FTMarket m;
   FillMarketNow(m, tk);
   g_exec.Recover(m);
   datetime now = TimeCurrent();
   if(InpTradeMode == FP_MODE_LIVE)
      g_risk.LiveRefresh(now);
   else if(InpTradeMode == FP_MODE_VIRTUAL)
      g_risk.BeginDay(now, g_virt.Equity(tk));
   //--- history loads in steps: live from a 1 s timer, tester from OnTick
   if(!g_tester)
      EventSetTimer(1);
   AttachIndicator();
   g_inited = true;
   PublishStatus(true);
   Print(StringFormat("FT INIT: FootprintTrader %s on %s %s, magic %I64d, risk %.2f%%, warm-up %d bars, history loading %s",
                      FTModeName((int)InpTradeMode), _Symbol, FPTfName((ENUM_TIMEFRAMES)_Period), InpMagic, InpRiskPct,
                      InpWarmupBars, g_tester ? "from OnTick" : "from OnTimer"));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   if(MQLInfoInteger(MQL_OPTIMIZATION) == 0)
      FTSClear(_Symbol, InpMagic);
   ObjectDelete(0, FT_STATUS_OBJ);
   if(g_perfN > 0)
      Print(StringFormat("FT PERF: OnTick avg %.3f ms over %I64u ticks without bar close (max %.3f ms); %I64u bar-close ticks avg %.3f ms",
                         (double)g_perfSumUs / (double)g_perfN / 1000.0, g_perfN, (double)g_perfMaxUs / 1000.0, g_perfBarN,
                         (g_perfBarN > 0) ? (double)g_perfBarSumUs / (double)g_perfBarN / 1000.0 : 0.0));
   if(g_inited)
   {
      DrainRecords();
      g_virt.Discard();
      g_risk.Deinit();
      if(InpTradeMode == FP_MODE_LIVE)
         GlobalVariablesFlush();
   }
   if(g_journalOk)
      g_journal.Deinit();
   if(g_filtersOk)
      g_filters.Deinit();
   if(g_signalsOk)
      g_signals.Deinit();
   if(g_engineOk)
      g_engine.Deinit();
   if(g_indHandle != INVALID_HANDLE)
      IndicatorRelease(g_indHandle);
   g_indHandle = INVALID_HANDLE;
   Print("FT DEINIT: reason ", reason);
}

void OnTimer()
{
   if(!g_inited)
      return;
   if(!g_engine.HistoryReady())
      g_engine.LoadStep(250);
   CheckReady();
   g_filters.OnTimer();
   PublishStatus(false);
}

void OnTick()
{
   if(!g_inited || g_halted)
      return;
   ulong t0 = GetMicrosecondCount();
   if(g_tester && !g_engine.HistoryReady())
      g_engine.LoadStep(2000);
   //--- engine.Update() calls CopyTicks, which can block while the terminal re-synchronises its tick history
   //--- (seen live: 135 s during a burst of reconnects). Since v1.11 the engine holds the fetch while the
   //--- terminal is disconnected and for a few seconds after it reconnects (CFPEngine::FetchAllowed); a block
   //--- that still happens is logged below, and bars that close meanwhile are processed late.
   ulong u0 = GetMicrosecondCount();
   int   upd = g_engine.Update();
   ulong uMs = (GetMicrosecondCount() - u0) / 1000;
   if(uMs >= 5000)
   {
      g_lastBlockMs = GetTickCount64();
      Print(StringFormat("FT ENGINE: Update() blocked %.1f s (CopyTicks waiting for the tick history, e.g. after a reconnect) - "
                         "bars closed meanwhile are processed late (InpMaxLatePendingSec=%d)", (double)uMs / 1000.0, InpMaxLatePendingSec));
   }
   if(upd < 0)
   {
      if(g_updateFailStreak++ == 0 || g_updateErrors < 10)
         Print("FT ENGINE: Update error: ", g_engine.LastError(), " - retried on the next tick");
      g_updateErrors++;
   }
   else if(g_updateFailStreak > 0)
   {
      Print("FT ENGINE: tick fetch recovered after ", g_updateFailStreak, " failed call(s)");
      g_updateFailStreak = 0;
   }
   CheckReady();
   MqlTick tk;
   if(!SymbolInfoTick(_Symbol, tk) || tk.bid <= 0.0 || tk.ask <= 0.0)
      return;
   datetime now = TimeCurrent();
   //--- daily counters: LIVE from deal history on trade events / day change (never per tick)
   if(InpTradeMode == FP_MODE_LIVE && (g_dealsDirty || g_risk.NeedNewDay(now)))
   {
      g_risk.LiveRefresh(now);
      g_dealsDirty = false;
   }
   else if(InpTradeMode == FP_MODE_VIRTUAL && g_risk.NeedNewDay(now))
      g_risk.BeginDay(now, g_virt.Equity(tk));
   RiskMonitor(tk, now);
   //--- closed bars, in order (architecture §6)
   bool     barWork = false;
   datetime T = 0;
   int      guard = 0;
   while(!g_halted && guard < 64 && g_engine.PopClosedBar(T))
   {
      guard++;
      barWork = true;
      ProcessClosedBar(T, tk);
   }
   if(g_halted)
      return;
   //--- per-tick trade management, MAE/MFE
   FTMarket m;
   FillMarketNow(m, tk);
   g_exec.OnTick(m);
   if(InpTradeMode == FP_MODE_VIRTUAL)
      g_virt.OnTick(tk, g_lastAtr);
   DrainRecords();
   PublishStatus(barWork);
   //--- timing (only once the history is ready)
   if(g_readySeen)
   {
      ulong us = GetMicrosecondCount() - t0;
      if(barWork)
      {
         g_perfBarN++;
         g_perfBarSumUs += us;
      }
      else
      {
         g_perfN++;
         g_perfSumUs += us;
         if(us > g_perfMaxUs)
            g_perfMaxUs = us;
      }
   }
}

void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD && trans.symbol == _Symbol)
      g_dealsDirty = true;
}

//+------------------------------------------------------------------+
//| OnTester (03 §9): from the EA's own per-position records          |
//+------------------------------------------------------------------+
double OnTester()
{
   DrainRecords();
   string summary = "";
   double crit = g_journal.TesterCriterion(TesterStatistics(STAT_EQUITY_DDREL_PERCENT), summary);
   Print("FT ONTESTER: ", summary);
   return crit;
}
//+------------------------------------------------------------------+
