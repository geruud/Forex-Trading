//+------------------------------------------------------------------+
//| FPExecution.mqh - FootprintTrader execution layer (03 §8, §9)     |
//|                                                                    |
//|  CFTPlanner    signal -> order plan: bid/ask conversion of the     |
//|                engine's price basis, tick-size normalisation,      |
//|                stops/freeze distances (widen, then re-size), TP    |
//|                (R multiple / STRUCTURE), pending validity, sizing. |
//|                Used by LIVE and VIRTUAL alike.                     |
//|  CFTTradeLogic THE ONE trade-management decision routine (partial, |
//|                break-even, trailing, time stop, opposite, flat),   |
//|                shared by LIVE (CFPExecution) and VIRTUAL           |
//|                (CFPVirtual in FPJournal.mqh).                      |
//|  CFPExecution  LIVE: CTrade wrapper, retcode policy, pending       |
//|                lifecycle, netting/hedging, MAE/MFE, GlobalVariable |
//|                state persistence and restart recovery.             |
//|                                                                    |
//|  Price domains: "levels" are in the engine's row-price basis       |
//|  (bid, mid or last); "execution prices" are what the broker uses:  |
//|  long entries fill on ask, long SL/TP trigger on bid, short        |
//|  entries fill on bid, short SL/TP trigger on ask. R (price units)  |
//|  = |fill - initial SL| in execution prices.                       |
//+------------------------------------------------------------------+
#include "FPRisk.mqh"
#include <Trade\Trade.mqh>

#define FT_BASIS_BID        0     // QUOTE+BID, and EXCHANGE/TRADE (approximation, 03 §8)
#define FT_BASIS_MID        1     // QUOTE+MID

#define FT_STAGE_INITIAL    0     // SL at the initial stop
#define FT_STAGE_BE         1     // SL moved to break-even (+offset)
#define FT_STAGE_TRAIL      2     // SL moved by the trailing stop

#define FT_TRAIL_MIN_STEP_R 0.10  // ATR trailing moves the SL only by >= 0.1 R (no per-tick modify spam)
#define FT_TP_STRUCT_MIN_R  1.20  // STRUCTURE target used only if >= 1.2 R away (03 §8)

#define FT_RC_OK            0
#define FT_RC_PRICE         1     // REQUOTE / PRICE_CHANGED / PRICE_OFF   -> refresh, retry up to 3 times
#define FT_RC_STOPS         2     // INVALID_STOPS                          -> widen to min distance, retry once
#define FT_RC_NOMONEY       3     // NO_MONEY                               -> skip and log
#define FT_RC_EXPIRATION    4     // INVALID_EXPIRATION (pending)           -> GTC + manual expiry, retry once
#define FT_RC_FILL          5     // INVALID_FILL (pending)                 -> ORDER_FILLING_RETURN, retry once
#define FT_RC_OTHER         6     // anything else                          -> log retcode + description, skip

//+------------------------------------------------------------------+
//| Helpers                                                           |
//+------------------------------------------------------------------+
datetime FTBarOpen(const datetime t, const ENUM_TIMEFRAMES tf)
{
   int p = PeriodSeconds(tf);
   if(p <= 0)
      return t;
   return (datetime)((long)t - (long)t % p);
}

// number of chart bars opened after 'fromBar' up to and including 'toBar' (0 if toBar <= fromBar)
int FTBarsBetween(const string sym, const ENUM_TIMEFRAMES tf, const datetime fromBar, const datetime toBar)
{
   if(toBar <= fromBar)
      return 0;
   int a = iBarShift(sym, tf, fromBar, false);
   int b = iBarShift(sym, tf, toBar, false);
   if(a >= 0 && b >= 0 && a >= b)
      return a - b;
   int p = PeriodSeconds(tf);
   return (p > 0) ? (int)(((long)toBar - (long)fromBar) / p) : 0;
}

// money P/L of 'vol' lots opened at openPx and closed at closePx (account currency)
double FTMoney(const string sym, const int dir, const double vol, const double openPx, const double closePx)
{
   if(vol <= 0.0 || dir == 0)
      return 0.0;
   double p = 0.0;
   if(OrderCalcProfit(dir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, sym, vol, openPx, closePx, p))
      return p;
   double tv = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double ts = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   if(ts <= 0.0)
      return 0.0;
   return (closePx - openPx) * dir / ts * tv * vol;
}

int FTSetupFromName(const string s)
{
   if(s == "SZR") return (int)FP_SIG_ZONE_RETEST;
   if(s == "ABS") return (int)FP_SIG_ABSORPTION;
   if(s == "EXH") return (int)FP_SIG_EXHAUSTION;
   if(s == "DIV") return (int)FP_SIG_DELTA_DIVERGENCE;
   if(s == "SIB") return (int)FP_SIG_STACK_BREAKOUT;
   return (int)FP_SIG_NONE;
}

string FTKindName(const int kind)
{
   if(kind == FP_ORD_STOP)  return "STOP";
   if(kind == FP_ORD_LIMIT) return "LIMIT";
   return "MARKET";
}

string FTModeName(const int mode)
{
   if(mode == FP_MODE_LIVE)    return "LIVE";
   if(mode == FP_MODE_VIRTUAL) return "VIRTUAL";
   return "SIGNALS_ONLY";
}

string FTSourceName(const ENUM_FP_SOURCE s)
{
   string n = EnumToString(s);
   if(StringFind(n, "FP_SRC_") == 0)
      n = StringSubstr(n, 7);
   return n;
}

ENUM_ORDER_TYPE_FILLING FTFilling(const string sym)
{
   long fm = SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);
   if((fm & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      return ORDER_FILLING_FOK;
   if((fm & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
}

int FTRcClass(const uint rc)
{
   switch(rc)
   {
      case TRADE_RETCODE_DONE:
      case TRADE_RETCODE_PLACED:
      case TRADE_RETCODE_DONE_PARTIAL:
         return FT_RC_OK;
      case TRADE_RETCODE_REQUOTE:
      case TRADE_RETCODE_PRICE_CHANGED:
      case TRADE_RETCODE_PRICE_OFF:
         return FT_RC_PRICE;
      case TRADE_RETCODE_INVALID_STOPS:
         return FT_RC_STOPS;
      case TRADE_RETCODE_NO_MONEY:
         return FT_RC_NOMONEY;
      case TRADE_RETCODE_INVALID_EXPIRATION:
         return FT_RC_EXPIRATION;
      case TRADE_RETCODE_INVALID_FILL:
         return FT_RC_FILL;
   }
   return FT_RC_OTHER;
}

string FTRcPolicyText(const int cls)
{
   switch(cls)
   {
      case FT_RC_OK:         return "ok";
      case FT_RC_PRICE:      return "refresh+retry";
      case FT_RC_STOPS:      return "widen+retry once";
      case FT_RC_NOMONEY:    return "skip (no money)";
      case FT_RC_EXPIRATION: return "GTC+manual expiry, retry once";
      case FT_RC_FILL:       return "filling RETURN, retry once";
   }
   return "skip";
}

//+------------------------------------------------------------------+
//| Shared types                                                      |
//+------------------------------------------------------------------+
//--- one order plan built from one signal (LIVE and VIRTUAL)
struct FTPlan
{
   long     signalId;
   int      setup;          // ENUM_FP_SIGNAL
   int      grade;
   int      dir;
   datetime signalBar;      // T
   int      kind;           // ENUM_FP_ORDER_KIND after the market-distance checks
   double   entry;          // execution price: market fill estimate or pending trigger
   double   sl;             // execution price (long: bid trigger, short: ask trigger)
   double   tp;             // execution price, 0 = none
   double   rPrice;         // |entry - sl|
   double   lots;
   double   riskMoney;      // lots * lossPerLot (money lost at a full stop with no slippage)
   double   riskTarget;     // InpRiskPct % of equity
   double   lossPerLot;
   double   spreadPts;      // spread at planning time (stressed in VIRTUAL)
   double   atr;            // signal ATR
   int      validBars;      // pending validity (chart bars after T)
   double   invalidPrice;   // bid-based invalidation level (0 = none)
   datetime expiry;         // T + (validBars + 1) * period (0 = market)
   bool     slWidened;
   bool     entryMoved;
   bool     tpStructure;

   void     Reset(void)
   {
      signalId = 0; setup = 0; grade = 0; dir = 0; signalBar = 0; kind = FP_ORD_MARKET;
      entry = 0.0; sl = 0.0; tp = 0.0; rPrice = 0.0; lots = 0.0; riskMoney = 0.0; riskTarget = 0.0;
      lossPerLot = 0.0; spreadPts = 0.0; atr = 0.0; validBars = 0; invalidPrice = 0.0; expiry = 0;
      slWidened = false; entryMoved = false; tpStructure = false;
   }
};

//--- a submitted entry: pending order alive, or market order waiting for its position to show up
struct FTPend
{
   ulong    ticket;         // LIVE order ticket (== future POSITION_IDENTIFIER); VIRTUAL 0
   bool     market;
   FTPlan   plan;
   datetime placed;
   long     placedMsc;      // VIRTUAL: ticks at or before this msc are ignored (no same-tick fills)
   bool     brokerExpiry;   // LIVE: ORDER_TIME_SPECIFIED used
   int      lookups;        // LIVE: ticks spent waiting for history/position
   datetime retryAfter;     // LIVE: cool-down after a failed cancel

   void     Reset(void)
   {
      ticket = 0; market = false; plan.Reset(); placed = 0; placedMsc = 0;
      brokerExpiry = false; lookups = 0; retryAfter = 0;
   }
};

//--- one open position (LIVE or VIRTUAL) - the state the decision routine works on
struct FTPosState
{
   long     id;             // LIVE: POSITION_IDENTIFIER; VIRTUAL: signalId
   ulong    ticket;         // LIVE: position ticket; VIRTUAL: 0
   long     signalId;
   int      setup;
   int      grade;
   int      dir;
   datetime entryTime;
   datetime entryBar;       // EBAR
   long     entryMsc;       // VIRTUAL: fill tick msc
   double   plannedEntry;
   double   entryPrice;
   double   slInit;
   double   sl;
   double   tpInit;
   double   tp;
   double   rPrice;         // initial risk in price units (R); 0 = unrecoverable -> unmanaged
   double   lotsInit;
   double   lots;
   double   riskMoney;
   double   riskTarget;
   double   spreadPts;
   bool     partStage;      // _PART: partial stage passed (partial done or impossible)
   bool     partialDone;    // a partial close was executed
   int      slStage;        // FT_STAGE_*
   double   maeR;           // max adverse excursion, R (>= 0)
   double   mfeR;           // max favourable excursion, R (>= 0)
   double   realised;       // VIRTUAL: money realised so far (partials)
   double   exitPxVol;      // VIRTUAL: sum(exit price * volume)
   double   exitVol;        // VIRTUAL: closed volume
   string   pendingClose;   // EA-initiated close in progress (TIME/OPPOSITE/FLAT/KILL), "" = none
   datetime retryAfter;     // LIVE: cool-down after a failed request
   bool     recovered;
   bool     seen;           // LIVE reconcile mark
   int      lookups;        // LIVE: ticks spent waiting for the closing deals

   void     Reset(void)
   {
      id = 0; ticket = 0; signalId = 0; setup = 0; grade = 0; dir = 0; entryTime = 0; entryBar = 0; entryMsc = 0;
      plannedEntry = 0.0; entryPrice = 0.0; slInit = 0.0; sl = 0.0; tpInit = 0.0; tp = 0.0; rPrice = 0.0;
      lotsInit = 0.0; lots = 0.0; riskMoney = 0.0; riskTarget = 0.0; spreadPts = 0.0;
      partStage = false; partialDone = false; slStage = FT_STAGE_INITIAL; maeR = 0.0; mfeR = 0.0;
      realised = 0.0; exitPxVol = 0.0; exitVol = 0.0; pendingClose = ""; retryAfter = 0;
      recovered = false; seen = false; lookups = 0;
   }
};

//--- one row of trades_<sym>_<tf>.csv (one per position, partials merged; or one unfilled pending = EXPIRED)
struct FTTradeRecord
{
   long     tradeId;
   long     signalId;
   ulong    ticket;
   int      setup;
   int      dir;
   int      grade;
   string   mode;
   datetime entryTime;
   double   entryPrice;
   double   sl;
   double   tp;
   double   lots;
   double   riskMoney;
   datetime exitTime;
   double   exitPrice;
   string   exitReason;
   double   rMultiple;
   double   maeR;
   double   mfeR;
   int      barsHeld;
   double   spreadAtEntry;
   double   slippagePts;
   double   profitMoney;
   bool     partialDone;
   bool     filled;         // false = unfilled pending (EXPIRED), excluded from R statistics

   void     Reset(void)
   {
      tradeId = 0; signalId = 0; ticket = 0; setup = 0; dir = 0; grade = 0; mode = "";
      entryTime = 0; entryPrice = 0.0; sl = 0.0; tp = 0.0; lots = 0.0; riskMoney = 0.0;
      exitTime = 0; exitPrice = 0.0; exitReason = ""; rMultiple = 0.0; maeR = 0.0; mfeR = 0.0;
      barsHeld = 0; spreadAtEntry = 0.0; slippagePts = 0.0; profitMoney = 0.0; partialDone = false; filled = false;
   }
};

//--- trade-management inputs (03 §8 "Exits")
struct FTMgmtConfig
{
   double partialPct;       // InpPartialPct (0..99)
   double partialR;         // InpPartialR   (<= 0: no partial, no break-even)
   double beOffsetPts;      // InpBEOffsetPts
   double trailStartR;      // InpTrailStartR (<= 0: no trailing)
   int    trailMode;        // ENUM_FP_TRAIL_MODE
   double trailAtr;         // InpTrailATR
   int    timeStopBars;     // InpTimeStopBars (<= 0: off)
   double timeStopMinR;     // InpTimeStopMinR
   bool   exitOnOpposite;   // InpExitOnOpposite
   int    flatMin;          // InpFlatTime as minutes (-1 = off)
};

//--- market snapshot the decision routine sees (LIVE: real bid/ask; VIRTUAL: stressed bid/ask)
struct FTMarket
{
   datetime now;
   double   bid;
   double   ask;
   double   point;
   double   tickSize;
   int      digits;
   double   minDist;        // max(stops, freeze) distance + 1 tick, price units
   double   freezeDist;     // freeze distance, price units
   double   volStep;
   double   volMin;
   double   atr;            // ATR of the last evaluated closed bar (0 = unknown)
};

//--- what to do with one position now
struct FTAction
{
   bool     close;
   string   reason;
   bool     partialStage;   // mark the partial stage passed
   double   partialLots;    // > 0: close this volume now
   double   newSL;          // > 0: move the SL here
   int      newStage;

   void     Reset(void)
   {
      close = false; reason = ""; partialStage = false; partialLots = 0.0; newSL = 0.0; newStage = FT_STAGE_INITIAL;
   }
};

//+------------------------------------------------------------------+
//| CFTPlanner - bid/ask conversion + order plan (03 §7, §8)          |
//|                                                                    |
//| Conversion table (written down in docs\decisions\trade.md):       |
//|   basis          long entry   long SL/TP   short entry  short SL/TP|
//|   QUOTE+BID      L + spread   L            L            L + spread |
//|   QUOTE+MID      L + spr/2    L - spr/2    L - spr/2    L + spr/2  |
//|   EXCHANGE/TRADE  = QUOTE+BID (approximation; broker triggers on   |
//|                   bid/ask)                                          |
//| spread = current ask - bid at planning time.                       |
//+------------------------------------------------------------------+
struct FTPlanConfig
{
   string              symbol;
   ENUM_TIMEFRAMES     tf;
   ENUM_FP_QUOTE_PRICE quotePrice;   // InpQuotePrice
   ENUM_FP_TP_MODE     tpMode;       // InpTPMode
   double              tpRSzr;       // InpTP_R_SZR
   double              tpRRev;       // InpTP_R_REV (ABS/EXH, also DIV standalone)
};

class CFTPlanner
{
private:
   FTPlanConfig m_c;
   CFPEngine   *m_engine;
   CFPRisk     *m_risk;
   double       m_point;
   int          m_digits;

public:
                CFTPlanner(void) { m_engine = NULL; m_risk = NULL; m_point = 0.0; m_digits = 0; }

   bool         Init(const FTPlanConfig &c, CFPEngine *engine, CFPRisk *risk)
   {
      m_c = c;
      m_engine = engine;
      m_risk = risk;
      m_point = SymbolInfoDouble(m_c.symbol, SYMBOL_POINT);
      m_digits = (int)SymbolInfoInteger(m_c.symbol, SYMBOL_DIGITS);
      return (m_engine != NULL && m_risk != NULL && m_point > 0.0);
   }

   //--- price basis read from the engine's ACTIVE source (decided at engine init)
   int          Basis(void)
   {
      if(m_engine == NULL)
         return FT_BASIS_BID;
      if(m_engine.ActiveSource() == FP_SRC_QUOTE_TICKS && m_c.quotePrice == FP_QP_MID)
         return FT_BASIS_MID;
      return FT_BASIS_BID;
   }
   string       BasisName(void)
   {
      if(m_engine == NULL)
         return "BID";
      ENUM_FP_SOURCE s = m_engine.ActiveSource();
      if(s == FP_SRC_QUOTE_TICKS)
         return (m_c.quotePrice == FP_QP_MID) ? "QUOTE+MID" : "QUOTE+BID";
      return FTSourceName(s) + " (as QUOTE+BID)";
   }

   double       LongEntry(const double level, const double spr)  { return (Basis() == FT_BASIS_MID) ? level + spr * 0.5 : level + spr; }
   double       LongExit(const double level, const double spr)   { return (Basis() == FT_BASIS_MID) ? level - spr * 0.5 : level; }
   double       ShortEntry(const double level, const double spr) { return (Basis() == FT_BASIS_MID) ? level - spr * 0.5 : level; }
   double       ShortExit(const double level, const double spr)  { return (Basis() == FT_BASIS_MID) ? level + spr * 0.5 : level + spr; }
   double       ExitLevel(const int dir, const double level, const double spr) { return (dir > 0) ? LongExit(level, spr) : ShortExit(level, spr); }

   //--- tick-size normalisation
   double       TickSize(void) const
   {
      double ts = SymbolInfoDouble(m_c.symbol, SYMBOL_TRADE_TICK_SIZE);
      return (ts > 0.0) ? ts : m_point;
   }
   double       Norm(const double p) const     { double ts = TickSize(); return NormalizeDouble(MathRound(p / ts) * ts, m_digits); }
   double       NormDown(const double p) const { double ts = TickSize(); return NormalizeDouble(MathFloor(p / ts + 1e-7) * ts, m_digits); }
   double       NormUp(const double p) const   { double ts = TickSize(); return NormalizeDouble(MathCeil(p / ts - 1e-7) * ts, m_digits); }

   //--- broker distances
   double       StopsDist(void) const  { return (double)SymbolInfoInteger(m_c.symbol, SYMBOL_TRADE_STOPS_LEVEL) * m_point; }
   double       FreezeDist(void) const { return (double)SymbolInfoInteger(m_c.symbol, SYMBOL_TRADE_FREEZE_LEVEL) * m_point; }
   double       MinDist(void) const
   {
      double d = MathMax(StopsDist(), FreezeDist());
      return (d > 0.0) ? d + TickSize() : 0.0;
   }

   void         FillMarket(FTMarket &m, const double bid, const double ask, const double atr, const datetime now) const
   {
      m.now = now;
      m.bid = bid;
      m.ask = ask;
      m.point = m_point;
      m.tickSize = TickSize();
      m.digits = m_digits;
      m.minDist = MinDist();
      m.freezeDist = FreezeDist();
      m.volStep = SymbolInfoDouble(m_c.symbol, SYMBOL_VOLUME_STEP);
      m.volMin = SymbolInfoDouble(m_c.symbol, SYMBOL_VOLUME_MIN);
      m.atr = atr;
   }

   //+---------------------------------------------------------------+
   //| Build the plan for one signal from the quote 'tk'.            |
   //| extraDist: added to the broker min distance (INVALID_STOPS    |
   //| retry). equity/freeMargin: account (LIVE) or virtual values.  |
   //| codes: "" or one of PLAN / RISK_MIN_LOT / RISK_MARGIN.        |
   //+---------------------------------------------------------------+
   bool         Build(const FPSignal &sig, const long sid, const MqlTick &tk, const double extraDist,
                      const double equity, const double freeMargin, FTPlan &p, string &codes, string &note)
   {
      p.Reset();
      codes = "";
      note = "";
      p.signalId = sid;
      p.setup = (int)sig.type;
      p.grade = sig.grade;
      p.dir = sig.dir;
      p.signalBar = sig.barTime;
      p.atr = sig.atr;
      p.invalidPrice = sig.invalidPrice;
      double bid = tk.bid;
      double ask = tk.ask;
      int    dir = sig.dir;
      if(bid <= 0.0 || ask <= 0.0 || ask < bid || (dir != 1 && dir != -1))
      {
         codes = "PLAN";
         note = "no valid quote or direction";
         return false;
      }
      double spr = ask - bid;
      p.spreadPts = spr / m_point;
      double minDist = MinDist() + extraDist;
      if(sig.stopPrice <= 0.0)
      {
         codes = "PLAN";
         note = "signal has no stop";
         return false;
      }
      if(sig.invalidPrice > 0.0 && ((dir > 0 && bid < sig.invalidPrice) || (dir < 0 && bid > sig.invalidPrice)))
      {
         codes = "PLAN";
         note = "invalidated before entry";
         return false;
      }
      //--- entry
      int kind = (int)sig.orderKind;
      if(sig.entryPrice <= 0.0 || (kind != FP_ORD_STOP && kind != FP_ORD_LIMIT))
         kind = FP_ORD_MARKET;
      double entry = 0.0;
      if(kind == FP_ORD_MARKET)
         entry = (dir > 0) ? ask : bid;
      else
      {
         entry = (dir > 0) ? LongEntry(sig.entryPrice, spr) : ShortEntry(sig.entryPrice, spr);
         if(kind == FP_ORD_STOP)
         {
            entry = (dir > 0) ? NormUp(entry) : NormDown(entry);       // never a better trigger than the level
            if(dir > 0)
            {
               if(entry <= ask)                { kind = FP_ORD_MARKET; entry = ask; note = "stop level already crossed -> market"; }
               else if(entry - ask < minDist)  { entry = NormUp(ask + minDist); p.entryMoved = true; }
            }
            else
            {
               if(entry >= bid)                { kind = FP_ORD_MARKET; entry = bid; note = "stop level already crossed -> market"; }
               else if(bid - entry < minDist)  { entry = NormDown(bid - minDist); p.entryMoved = true; }
            }
         }
         else
         {
            entry = (dir > 0) ? NormDown(entry) : NormUp(entry);
            if(dir > 0)
            {
               if(entry >= ask)                { kind = FP_ORD_MARKET; entry = ask; note = "limit level already reached -> market"; }
               else if(ask - entry < minDist)  { entry = NormDown(ask - minDist); p.entryMoved = true; }
            }
            else
            {
               if(entry <= bid)                { kind = FP_ORD_MARKET; entry = bid; note = "limit level already reached -> market"; }
               else if(entry - bid < minDist)  { entry = NormUp(bid + minDist); p.entryMoved = true; }
            }
         }
      }
      p.kind = kind;
      p.entry = entry;
      //--- stop (rounded away from the entry), then the broker distance (widen)
      double sl = (dir > 0) ? NormDown(LongExit(sig.stopPrice, spr)) : NormUp(ShortExit(sig.stopPrice, spr));
      double ref = (kind == FP_ORD_MARKET) ? ((dir > 0) ? bid : ask) : entry;
      if(dir > 0 && ref - sl < minDist)
      {
         sl = NormDown(ref - minDist);
         p.slWidened = true;
      }
      if(dir < 0 && sl - ref < minDist)
      {
         sl = NormUp(ref + minDist);
         p.slWidened = true;
      }
      p.sl = sl;
      p.rPrice = (entry - sl) * dir;
      if(p.rPrice <= 0.0)
      {
         codes = "PLAN";
         note = "stop not beyond the entry";
         return false;
      }
      //--- target
      //--- continuation setups (SZR, SIB) use the SZR target, reversals the REV target
      bool   cont = (sig.type == FP_SIG_ZONE_RETEST || sig.type == FP_SIG_STACK_BREAKOUT);
      double mult = cont ? m_c.tpRSzr : m_c.tpRRev;
      double tp = (mult > 0.0) ? entry + dir * mult * p.rPrice : 0.0;
      if(m_c.tpMode == FP_TP_STRUCTURE && sig.tpStructure > 0.0)
      {
         double ts = ExitLevel(dir, sig.tpStructure, spr);
         if((ts - entry) * dir >= FT_TP_STRUCT_MIN_R * p.rPrice)
         {
            tp = ts;
            p.tpStructure = true;
         }
      }
      if(tp > 0.0)
      {
         tp = Norm(tp);
         if(dir > 0 && tp - ref < minDist)
            tp = NormUp(ref + minDist);
         if(dir < 0 && ref - tp < minDist)
            tp = NormDown(ref - minDist);
      }
      p.tp = tp;
      //--- pending validity
      if(kind != FP_ORD_MARKET)
      {
         p.validBars = (sig.validBars > 0) ? sig.validBars : 1;
         p.expiry = sig.barTime + (p.validBars + 1) * PeriodSeconds(m_c.tf);
      }
      //--- sizing with the FINAL (possibly widened) stop
      string rc = "";
      string rn = "";
      bool ok = m_risk.Size(dir, p.entry, p.sl, equity, freeMargin, p.lots, p.riskMoney, p.riskTarget, p.lossPerLot, rc, rn);
      if(rn != "")
         note = (note == "") ? rn : note + "; " + rn;
      if(p.slWidened)
         note = (note == "") ? "SL widened to broker distance (re-sized)" : note + "; SL widened to broker distance (re-sized)";
      if(!ok)
      {
         codes = rc;
         return false;
      }
      return true;
   }

   //--- ';'-separated key=value summary for the signals CSV 'info' column and logs
   string       Describe(const FTPlan &p) const
   {
      return StringFormat("kind=%s;entry=%s;sl=%s;tp=%s;rPts=%.1f;lots=%s;riskMoney=%.2f;riskTarget=%.2f;spreadPts=%.1f",
                          FTKindName(p.kind), DoubleToString(p.entry, m_digits), DoubleToString(p.sl, m_digits),
                          DoubleToString(p.tp, m_digits), p.rPrice / m_point, FTNumTrim(p.lots), p.riskMoney,
                          p.riskTarget, p.spreadPts);
   }
};

//+------------------------------------------------------------------+
//| CFTTradeLogic - THE trade-management decision routine.            |
//| Pure functions of (config, position state, market snapshot).      |
//| LIVE applies the actions through CTrade, VIRTUAL applies them to  |
//| its simulated book; neither has its own management rules.        |
//+------------------------------------------------------------------+
class CFTTradeLogic
{
public:
   //--- open profit of the remaining position in R (exit side: long -> bid, short -> ask)
   static double OpenR(const FTPosState &st, const double bid, const double ask)
   {
      if(st.rPrice <= 0.0)
         return 0.0;
      double px = (st.dir > 0) ? bid : ask;
      return (px - st.entryPrice) * st.dir / st.rPrice;
   }

   static void   Excursion(FTPosState &st, const double bid, const double ask)
   {
      if(st.rPrice <= 0.0)
         return;
      double r = OpenR(st, bid, ask);
      if(r > st.mfeR)
         st.mfeR = r;
      if(-r > st.maeR)
         st.maeR = -r;
   }

   //--- volume for the partial close; 0 when it cannot be split within the volume step/min
   static double PartialVolume(const double lotsInit, const double lots, const double pct, const double step, const double vmin)
   {
      if(pct <= 0.0 || lotsInit <= 0.0)
         return 0.0;
      double v = FTFloorStep(lotsInit * pct / 100.0, step);
      if(v < vmin - 1e-9 || lots - v < vmin - 1e-9)
         return 0.0;
      return NormalizeDouble(v, FTStepDigits(step));
   }

   static bool   Improves(const int dir, const double cand, const double cur, const double minStep)
   {
      if(cand <= 0.0)
         return false;
      if(cur <= 0.0)
         return true;
      return (cand - cur) * dir > minStep;
   }

   static bool   SlAllowed(const int dir, const double sl, const FTMarket &m)
   {
      if(sl <= 0.0)
         return false;
      return (dir > 0) ? (m.bid - sl >= m.minDist && sl < m.bid) : (sl - m.ask >= m.minDist && sl > m.ask);
   }

   //--- keep a proposed SL at least minDist from the exit price, rounded away from the price
   static double ClampSL(const int dir, const double cand, const FTMarket &m)
   {
      double ts = (m.tickSize > 0.0) ? m.tickSize : m.point;
      double v = cand;
      if(dir > 0)
      {
         double lim = m.bid - MathMax(m.minDist, ts);
         if(v > lim)
            v = lim;
         return NormalizeDouble(MathFloor(v / ts + 1e-7) * ts, m.digits);
      }
      double lim = m.ask + MathMax(m.minDist, ts);
      if(v < lim)
         v = lim;
      return NormalizeDouble(MathCeil(v / ts - 1e-7) * ts, m.digits);
   }

   //--- freeze level: no modification while the price is within the freeze distance of SL/TP
   static bool   Modifiable(const FTPosState &st, const FTMarket &m)
   {
      if(m.freezeDist <= 0.0)
         return true;
      if(st.dir > 0)
         return (st.sl <= 0.0 || m.bid - st.sl > m.freezeDist) && (st.tp <= 0.0 || st.tp - m.bid > m.freezeDist);
      return (st.sl <= 0.0 || st.sl - m.ask > m.freezeDist) && (st.tp <= 0.0 || m.ask - st.tp > m.freezeDist);
   }

   static string StopReason(const FTPosState &st)
   {
      if(st.slStage == FT_STAGE_TRAIL)
         return "TRAIL";
      if(st.slStage == FT_STAGE_BE)
         return "BE";
      return "SL";
   }

   //+---------------------------------------------------------------+
   //| Per tick: EA-initiated close, flat time, partial at           |
   //| InpPartialR, SL -> BE + offset, ATR trailing from             |
   //| InpTrailStartR. Returns true when 'a' holds an action.        |
   //+---------------------------------------------------------------+
   static bool   DecideTick(const FTMgmtConfig &c, const FTPosState &st, const FTMarket &m, FTAction &a)
   {
      a.Reset();
      if(st.pendingClose != "")
      {
         a.close = true;
         a.reason = st.pendingClose;
         return true;
      }
      if(c.flatMin >= 0 && FTMinuteOfDay(m.now) >= c.flatMin)
      {
         a.close = true;
         a.reason = "FLAT";
         return true;
      }
      if(st.rPrice <= 0.0)
         return false;                          // R unknown: broker SL/TP only
      double r = OpenR(st, m.bid, m.ask);
      bool partNow = false;
      if(c.partialR > 0.0 && !st.partStage && r >= c.partialR)
      {
         partNow = true;
         a.partialStage = true;
         a.partialLots = PartialVolume(st.lotsInit, st.lots, c.partialPct, m.volStep, m.volMin);
      }
      if(!Modifiable(st, m))
         return a.partialStage;
      double cand = 0.0;
      int    stage = st.slStage;
      double tick = (m.tickSize > 0.0) ? m.tickSize : m.point;
      if(c.partialR > 0.0 && (st.partStage || partNow) && st.slStage < FT_STAGE_BE)
      {
         double be = st.entryPrice + st.dir * c.beOffsetPts * m.point;
         be = (st.dir > 0) ? NormalizeDouble(MathCeil(be / tick - 1e-7) * tick, m.digits)
                           : NormalizeDouble(MathFloor(be / tick + 1e-7) * tick, m.digits);
         if(SlAllowed(st.dir, be, m) && Improves(st.dir, be, st.sl, 0.5 * tick))
         {
            cand = be;
            stage = FT_STAGE_BE;
         }
      }
      bool trailOn = (c.trailStartR > 0.0 && (st.slStage == FT_STAGE_TRAIL || st.mfeR >= c.trailStartR));
      if(trailOn && c.trailMode == FP_TRAIL_ATR && m.atr > 0.0)
      {
         double t = (st.dir > 0) ? m.bid - c.trailAtr * m.atr : m.ask + c.trailAtr * m.atr;
         t = ClampSL(st.dir, t, m);
         double base = (cand > 0.0) ? cand : st.sl;
         if(Improves(st.dir, t, base, MathMax(FT_TRAIL_MIN_STEP_R * st.rPrice, 0.5 * tick)))
         {
            cand = t;
            stage = FT_STAGE_TRAIL;
         }
      }
      if(cand > 0.0)
      {
         a.newSL = cand;
         a.newStage = (stage > st.slStage) ? stage : st.slStage;
      }
      return (a.partialStage || a.newSL > 0.0);
   }

   //+---------------------------------------------------------------+
   //| On each closed bar T: time stop, exit on opposite grade A,    |
   //| BAR trailing. barsCompleted = bars from the entry bar to T    |
   //| inclusive. trailLong/trailShort: T's low/high already         |
   //| converted to execution prices (0 = n/a).                      |
   //+---------------------------------------------------------------+
   static bool   DecideBar(const FTMgmtConfig &c, const FTPosState &st, const FTMarket &m, const int barsCompleted,
                           const double trailLong, const double trailShort, const bool oppositeA, FTAction &a)
   {
      a.Reset();
      if(st.pendingClose != "" || st.rPrice <= 0.0)
         return false;
      double r = OpenR(st, m.bid, m.ask);
      if(c.timeStopBars > 0 && barsCompleted >= c.timeStopBars && r < c.timeStopMinR)
      {
         a.close = true;
         a.reason = "TIME";
         return true;
      }
      if(c.exitOnOpposite && oppositeA)
      {
         a.close = true;
         a.reason = "OPPOSITE";
         return true;
      }
      bool trailOn = (c.trailStartR > 0.0 && (st.slStage == FT_STAGE_TRAIL || st.mfeR >= c.trailStartR));
      if(trailOn && c.trailMode == FP_TRAIL_BAR && Modifiable(st, m))
      {
         double t = (st.dir > 0) ? trailLong : trailShort;
         if(t > 0.0)
         {
            t = ClampSL(st.dir, t, m);
            double tick = (m.tickSize > 0.0) ? m.tickSize : m.point;
            if(Improves(st.dir, t, st.sl, 0.5 * tick))
            {
               a.newSL = t;
               a.newStage = FT_STAGE_TRAIL;
            }
         }
      }
      return (a.newSL > 0.0);
   }

   //--- journal row for a closed position (both modes). exitPrice = volume-weighted exit of all closes;
   //--- finalPx = price of the last close (also folded into MAE/MFE, so a full stop shows MAE >= ~1 R)
   static void   FillRecord(const FTPosState &st, const string mode, const datetime exitTime, const double exitPrice,
                            const double finalPx, const string reason, const double profit, const int barsHeld,
                            const double point, FTTradeRecord &r)
   {
      r.Reset();
      double mae = st.maeR;
      double mfe = st.mfeR;
      if(st.rPrice > 0.0 && finalPx > 0.0)
      {
         double xr = (finalPx - st.entryPrice) * st.dir / st.rPrice;
         if(-xr > mae)
            mae = -xr;
         if(xr > mfe)
            mfe = xr;
      }
      r.tradeId = st.id;
      r.signalId = st.signalId;
      r.ticket = st.ticket;
      r.setup = st.setup;
      r.dir = st.dir;
      r.grade = st.grade;
      r.mode = mode;
      r.entryTime = st.entryTime;
      r.entryPrice = st.entryPrice;
      r.sl = st.slInit;
      r.tp = st.tpInit;
      r.lots = st.lotsInit;
      r.riskMoney = st.riskMoney;
      r.exitTime = exitTime;
      r.exitPrice = exitPrice;
      r.exitReason = reason;
      r.rMultiple = (st.riskMoney > 0.0) ? profit / st.riskMoney : 0.0;
      r.maeR = mae;
      r.mfeR = mfe;
      r.barsHeld = barsHeld;
      r.spreadAtEntry = st.spreadPts;
      r.slippagePts = (st.plannedEntry > 0.0 && point > 0.0) ? (st.entryPrice - st.plannedEntry) * st.dir / point : 0.0;
      r.profitMoney = profit;
      r.partialDone = st.partialDone;
      r.filled = true;
   }

   //--- journal row for a pending entry that ended unfilled (exitReason EXPIRED)
   static void   FillUnfilled(const FTPend &p, const string mode, const datetime now, const int barsAlive, FTTradeRecord &r)
   {
      r.Reset();
      r.tradeId = (p.ticket > 0) ? (long)p.ticket : p.plan.signalId;
      r.signalId = p.plan.signalId;
      r.ticket = p.ticket;
      r.setup = p.plan.setup;
      r.dir = p.plan.dir;
      r.grade = p.plan.grade;
      r.mode = mode;
      r.entryTime = p.placed;
      r.entryPrice = p.plan.entry;
      r.sl = p.plan.sl;
      r.tp = p.plan.tp;
      r.lots = p.plan.lots;
      r.riskMoney = p.plan.riskMoney;
      r.exitTime = now;
      r.exitReason = "EXPIRED";
      r.barsHeld = barsAlive;
      r.spreadAtEntry = p.plan.spreadPts;
      r.filled = false;
   }
};

//+------------------------------------------------------------------+
//| CFPExecution - LIVE orders (03 §8, §9 state)                     |
//+------------------------------------------------------------------+
struct FTExecConfig
{
   string          symbol;
   ENUM_TIMEFRAMES tf;
   long            magic;
   int             slippagePts;   // InpSlippagePts
};

class CFPExecution
{
private:
   FTExecConfig  m_c;
   FTMgmtConfig  m_mc;
   CTrade        m_trade;
   CFTPlanner   *m_planner;
   CFPFilters   *m_filters;
   bool          m_hedging;
   double        m_point;
   int           m_digits;
   FTPend        m_pend[];
   FTPosState    m_pos[];
   FTTradeRecord m_done[];

   //--- GlobalVariables FT_<magic>_<id>_<KEY>; id = POSITION_IDENTIFIER (== opening order ticket)
   string        GvPre(const long id) const { return "FT_" + IntegerToString(m_c.magic) + "_" + IntegerToString(id) + "_"; }
   void          GvSet(const long id, const string key, const double v) const { GlobalVariableSet(GvPre(id) + key, v); }
   bool          GvHas(const long id, const string key) const { return GlobalVariableCheck(GvPre(id) + key); }
   double        GvGet(const long id, const string key, const double def) const
   {
      string n = GvPre(id) + key;
      return GlobalVariableCheck(n) ? GlobalVariableGet(n) : def;
   }
   void          GvDelAll(const long id) const { GlobalVariablesDeleteAll(GvPre(id)); }

   string        OrderComment(const FTPlan &p) const
   {
      return StringFormat("FT %s %s %I64d", FPSetupName((ENUM_FP_SIGNAL)p.setup), FPGradeName(p.grade), p.signalId);
   }

   bool          IsOurs(const string sym, const long magic) const { return sym == m_c.symbol && magic == m_c.magic; }

   int           FindPos(const long id) const
   {
      int n = ArraySize(m_pos);
      for(int i = 0; i < n; i++)
         if(m_pos[i].id == id)
            return i;
      return -1;
   }
   void          RemovePend(const int i)
   {
      int n = ArraySize(m_pend);
      for(int j = i; j < n - 1; j++)
         m_pend[j] = m_pend[j + 1];
      ArrayResize(m_pend, n - 1);
   }
   void          RemovePos(const int i)
   {
      int n = ArraySize(m_pos);
      for(int j = i; j < n - 1; j++)
         m_pos[j] = m_pos[j + 1];
      ArrayResize(m_pos, n - 1);
   }
   int           AddPos(const FTPosState &st)
   {
      int n = ArraySize(m_pos);
      ArrayResize(m_pos, n + 1);
      m_pos[n] = st;
      return n;
   }
   void          PushRecord(const FTTradeRecord &r)
   {
      int n = ArraySize(m_done);
      ArrayResize(m_done, n + 1);
      m_done[n] = r;
   }

   //--- open position of this magic/symbol whose POSITION_IDENTIFIER == id (0 = none)
   ulong         FindPositionTicket(const long id) const
   {
      int pt = PositionsTotal();
      for(int i = 0; i < pt; i++)
      {
         ulong tk = PositionGetTicket(i);
         if(tk == 0)
            continue;
         if(!IsOurs(PositionGetString(POSITION_SYMBOL), PositionGetInteger(POSITION_MAGIC)))
            continue;
         if(PositionGetInteger(POSITION_IDENTIFIER) == id)
            return tk;
      }
      return 0;
   }

   //--- persistence: written at placement (keyed by the order ticket = future position id)
   void          PersistPlan(const ulong ticket, const FTPlan &p) const
   {
      long id = (long)ticket;
      GvSet(id, "R", p.rPrice);
      GvSet(id, "SETUP", (double)p.setup);
      GvSet(id, "PART", 0.0);
      GvSet(id, "SIG", (double)p.signalId);
      GvSet(id, "GRD", (double)p.grade);
      GvSet(id, "RISK", p.riskMoney);
      GvSet(id, "RTGT", p.riskTarget);
      GvSet(id, "LOTS", p.lots);
      GvSet(id, "PLAN", p.entry);
      GvSet(id, "SPRD", p.spreadPts);
      GvSet(id, "KIND", (double)p.kind);
      GvSet(id, "INV", p.invalidPrice);
      GvSet(id, "SBAR", (double)(long)p.signalBar);
      GvSet(id, "VB", (double)p.validBars);
      GvSet(id, "TPI", p.tp);
   }
   //--- persistence: position state (adoption, stage changes, bar closes)
   void          PersistPos(const FTPosState &st) const
   {
      GvSet(st.id, "R", st.rPrice);
      GvSet(st.id, "EBAR", (double)(long)st.entryBar);
      GvSet(st.id, "SETUP", (double)st.setup);
      GvSet(st.id, "PART", st.partStage ? 1.0 : 0.0);
      GvSet(st.id, "SIG", (double)st.signalId);
      GvSet(st.id, "GRD", (double)st.grade);
      GvSet(st.id, "RISK", st.riskMoney);
      GvSet(st.id, "RTGT", st.riskTarget);
      GvSet(st.id, "LOTS", st.lotsInit);
      GvSet(st.id, "PLAN", st.plannedEntry);
      GvSet(st.id, "SPRD", st.spreadPts);
      GvSet(st.id, "TPI", st.tpInit);
      SaveState(st);
   }
   void          SaveState(const FTPosState &st) const
   {
      GvSet(st.id, "PART", st.partStage ? 1.0 : 0.0);
      GvSet(st.id, "PDONE", st.partialDone ? 1.0 : 0.0);
      GvSet(st.id, "BE", (double)st.slStage);
      GvSet(st.id, "MAE", st.maeR);
      GvSet(st.id, "MFE", st.mfeR);
   }

   void          LogRc(const string op, const int attempt, const bool sent, const uint rc, const string text, const string detail) const
   {
      Print(StringFormat("FT EXEC %s #%d: sent=%s rc=%u [%s] -> %s | %s | err=%d",
                         op, attempt, sent ? "yes" : "no", rc, text, FTRcPolicyText(FTRcClass(rc)), detail, GetLastError()));
   }

   bool          FreshTick(MqlTick &tk) const
   {
      return SymbolInfoTick(m_c.symbol, tk) && tk.bid > 0.0 && tk.ask > 0.0;
   }

   //--- send the open request of plan p (market or pending)
   bool          SendOpen(const FTPlan &p, const bool brokerExpiry)
   {
      string cmt = OrderComment(p);
      ResetLastError();
      if(p.kind == FP_ORD_MARKET)
         return (p.dir > 0) ? m_trade.Buy(p.lots, m_c.symbol, p.entry, p.sl, p.tp, cmt)
                            : m_trade.Sell(p.lots, m_c.symbol, p.entry, p.sl, p.tp, cmt);
      ENUM_ORDER_TYPE_TIME tt = brokerExpiry ? ORDER_TIME_SPECIFIED : ORDER_TIME_GTC;
      datetime exp = brokerExpiry ? p.expiry : 0;
      if(p.kind == FP_ORD_STOP)
         return (p.dir > 0) ? m_trade.BuyStop(p.lots, p.entry, m_c.symbol, p.sl, p.tp, tt, exp, cmt)
                            : m_trade.SellStop(p.lots, p.entry, m_c.symbol, p.sl, p.tp, tt, exp, cmt);
      return (p.dir > 0) ? m_trade.BuyLimit(p.lots, p.entry, m_c.symbol, p.sl, p.tp, tt, exp, cmt)
                         : m_trade.SellLimit(p.lots, p.entry, m_c.symbol, p.sl, p.tp, tt, exp, cmt);
   }

   //--- close 'vol' lots (0 = all) of position k with the retcode policy
   bool          SendClose(const int k, const double vol, const string why)
   {
      ulong ticket = m_pos[k].ticket;
      int   priceRetries = 0;
      for(int attempt = 1; attempt <= 4; attempt++)
      {
         if(!PositionSelectByTicket(ticket))
         {
            Print("FT EXEC CLOSE ", why, " pos ", ticket, ": position no longer open (already closed)");
            return true;
         }
         double posVol = PositionGetDouble(POSITION_VOLUME);
         double v = (vol > 0.0) ? MathMin(vol, posVol) : posVol;
         bool   sent = false;
         uint   rc = 0;
         string text = "";
         ResetLastError();
         if(m_hedging)
         {
            sent = (vol > 0.0) ? m_trade.PositionClosePartial(ticket, v) : m_trade.PositionClose(ticket);
            rc = m_trade.ResultRetcode();
            text = m_trade.ResultRetcodeDescription();
         }
         else
         {
            //--- netting: opposite deal BOUND to the position ticket, so it can never open a reverse position
            MqlTick tk;
            if(!FreshTick(tk))
               return false;
            MqlTradeRequest rq;
            MqlTradeResult  rs;
            ZeroMemory(rq);
            ZeroMemory(rs);
            rq.action = TRADE_ACTION_DEAL;
            rq.symbol = m_c.symbol;
            rq.volume = v;
            rq.magic = (ulong)m_c.magic;
            rq.position = ticket;
            rq.type = (m_pos[k].dir > 0) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
            rq.price = (m_pos[k].dir > 0) ? tk.bid : tk.ask;
            rq.deviation = (ulong)m_c.slippagePts;
            rq.type_filling = FTFilling(m_c.symbol);
            rq.comment = "FT " + why;
            sent = OrderSend(rq, rs);
            rc = rs.retcode;
            m_trade.FormatRequestResult(text, rq, rs);
         }
         int cls = FTRcClass(rc);
         LogRc((vol > 0.0) ? "PARTIAL" : "CLOSE", attempt, sent, rc, text,
               StringFormat("%s pos %I64u vol %s", why, ticket, FTNumTrim(v)));
         if(cls == FT_RC_OK)
            return true;
         if(cls == FT_RC_PRICE && priceRetries < 3)
         {
            priceRetries++;
            continue;
         }
         break;
      }
      return false;
   }

   bool          ModifySL(const int k, const double newSL, const FTMarket &m)
   {
      ulong  ticket = m_pos[k].ticket;
      int    dir = m_pos[k].dir;
      double sl = newSL;
      bool   widened = false;
      int    priceRetries = 0;
      for(int attempt = 1; attempt <= 6; attempt++)
      {
         if(!PositionSelectByTicket(ticket))
            return false;
         double tp = PositionGetDouble(POSITION_TP);
         ResetLastError();
         bool sent = m_trade.PositionModify(ticket, sl, tp);
         uint rc = m_trade.ResultRetcode();
         int  cls = FTRcClass(rc);
         if(rc == TRADE_RETCODE_NO_CHANGES)
            cls = FT_RC_OK;
         LogRc("MODIFY", attempt, sent, rc, m_trade.ResultRetcodeDescription(),
               StringFormat("pos %I64u sl %s -> %s", ticket, DoubleToString(m_pos[k].sl, m_digits), DoubleToString(sl, m_digits)));
         if(cls == FT_RC_OK)
         {
            m_pos[k].sl = sl;
            return true;
         }
         if(cls == FT_RC_PRICE && priceRetries < 3)
         {
            priceRetries++;
            continue;
         }
         if(cls == FT_RC_STOPS && !widened)
         {
            widened = true;
            MqlTick tk;
            if(!FreshTick(tk))
               return false;
            double d = MathMax(m.minDist, tk.ask - tk.bid) + 2.0 * m.tickSize;
            double ts = (m.tickSize > 0.0) ? m.tickSize : m.point;
            if(dir > 0)
               sl = NormalizeDouble(MathFloor(MathMin(sl, tk.bid - d) / ts + 1e-7) * ts, m_digits);
            else
               sl = NormalizeDouble(MathCeil(MathMax(sl, tk.ask + d) / ts - 1e-7) * ts, m_digits);
            if(!CFTTradeLogic::Improves(dir, sl, m_pos[k].sl, 0.5 * ts))
            {
               Print("FT EXEC MODIFY pos ", ticket, ": widened SL no longer improves the stop - skipped");
               return false;
            }
            continue;
         }
         break;
      }
      return false;
   }

   bool          DeleteOrder(const ulong ticket, const string why)
   {
      int priceRetries = 0;
      for(int attempt = 1; attempt <= 4; attempt++)
      {
         if(!OrderSelect(ticket))
         {
            Print("FT EXEC CANCEL order ", ticket, " (", why, "): no longer pending");
            return false;                        // filled or gone: the reconcile step decides
         }
         ResetLastError();
         bool sent = m_trade.OrderDelete(ticket);
         uint rc = m_trade.ResultRetcode();
         int  cls = FTRcClass(rc);
         LogRc("CANCEL", attempt, sent, rc, m_trade.ResultRetcodeDescription(), StringFormat("order %I64u %s", ticket, why));
         if(cls == FT_RC_OK)
            return true;
         if(cls == FT_RC_PRICE && priceRetries < 3)
         {
            priceRetries++;
            continue;
         }
         break;
      }
      return false;
   }

   //--- a tracked entry became position posTk
   void          AdoptOpen(const FTPend &p, const ulong posTk, const FTMarket &m)
   {
      if(!PositionSelectByTicket(posTk))
         return;
      FTPosState st;
      st.Reset();
      st.id = PositionGetInteger(POSITION_IDENTIFIER);
      st.ticket = posTk;
      st.signalId = p.plan.signalId;
      st.setup = p.plan.setup;
      st.grade = p.plan.grade;
      st.dir = p.plan.dir;
      st.entryTime = (datetime)PositionGetInteger(POSITION_TIME);
      st.entryBar = FTBarOpen(st.entryTime, m_c.tf);
      st.plannedEntry = p.plan.entry;
      st.entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      st.sl = PositionGetDouble(POSITION_SL);
      st.slInit = (st.sl > 0.0) ? st.sl : p.plan.sl;
      st.tp = PositionGetDouble(POSITION_TP);
      st.tpInit = (st.tp > 0.0) ? st.tp : p.plan.tp;
      st.lots = PositionGetDouble(POSITION_VOLUME);
      st.lotsInit = st.lots;
      st.rPrice = (st.entryPrice - st.slInit) * st.dir;
      if(st.rPrice <= 0.0)
         st.rPrice = p.plan.rPrice;
      st.riskMoney = (p.plan.lots > 0.0) ? p.plan.riskMoney * st.lotsInit / p.plan.lots : p.plan.riskMoney;
      st.riskTarget = p.plan.riskTarget;
      st.spreadPts = p.market ? p.plan.spreadPts : (m.ask - m.bid) / m_point;
      PersistPos(st);
      AddPos(st);
      Print(StringFormat("FT EXEC FILL sid %I64d pos %I64d %s %s lots %s @ %s (planned %s, slip %.1f pts) sl %s tp %s R %.1f pts risk %.2f",
                         st.signalId, st.id, FPSetupName((ENUM_FP_SIGNAL)st.setup), st.dir > 0 ? "BUY" : "SELL",
                         FTNumTrim(st.lotsInit), DoubleToString(st.entryPrice, m_digits), DoubleToString(st.plannedEntry, m_digits),
                         (st.entryPrice - st.plannedEntry) * st.dir / m_point, DoubleToString(st.slInit, m_digits),
                         DoubleToString(st.tpInit, m_digits), st.rPrice / m_point, st.riskMoney));
   }

   //--- aggregate the deals of position st.id into a journal row; false while the close is not in history yet
   bool          BuildRecord(const FTPosState &st, FTTradeRecord &r)
   {
      if(!HistorySelectByPosition(st.id))
         return false;
      int      n = HistoryDealsTotal();
      double   outVol = 0.0;
      double   outPx = 0.0;
      double   net = 0.0;
      int      outDeals = 0;
      datetime exitT = 0;
      long     lastReason = -1;
      double   lastPx = 0.0;
      for(int i = 0; i < n; i++)
      {
         ulong d = HistoryDealGetTicket(i);
         if(d == 0)
            continue;
         ENUM_DEAL_TYPE type = (ENUM_DEAL_TYPE)HistoryDealGetInteger(d, DEAL_TYPE);
         if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL)
            continue;
         net += HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP) +
                HistoryDealGetDouble(d, DEAL_COMMISSION) + HistoryDealGetDouble(d, DEAL_FEE);
         ENUM_DEAL_ENTRY e = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(d, DEAL_ENTRY);
         if(e == DEAL_ENTRY_OUT || e == DEAL_ENTRY_OUT_BY || e == DEAL_ENTRY_INOUT)
         {
            double v = HistoryDealGetDouble(d, DEAL_VOLUME);
            outVol += v;
            outPx += HistoryDealGetDouble(d, DEAL_PRICE) * v;
            outDeals++;
            datetime t = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
            if(t >= exitT)
            {
               exitT = t;
               lastReason = HistoryDealGetInteger(d, DEAL_REASON);
               lastPx = HistoryDealGetDouble(d, DEAL_PRICE);
            }
         }
      }
      if(outDeals == 0 || outVol <= 0.0)
         return false;
      string reason = st.pendingClose;
      if(reason == "")
      {
         if(lastReason == (long)DEAL_REASON_SL)
            reason = CFTTradeLogic::StopReason(st);
         else if(lastReason == (long)DEAL_REASON_TP)
            reason = "TP";
         else
            reason = "MANUAL";
      }
      int held = FTBarsBetween(m_c.symbol, m_c.tf, st.entryBar, FTBarOpen(exitT, m_c.tf));
      CFTTradeLogic::FillRecord(st, "LIVE", exitT, outPx / outVol, lastPx, reason, net, held, m_point, r);
      r.partialDone = (st.partialDone || outDeals > 1);
      return true;
   }

   //--- position k is no longer open: write its journal row
   void          Finalize(const int k)
   {
      FTTradeRecord r;
      if(!BuildRecord(m_pos[k], r))
      {
         m_pos[k].lookups++;
         if(m_pos[k].lookups < 100)
            return;                              // history not synchronised yet; retry next tick
         Print("FT EXEC: closing deals of pos ", m_pos[k].id, " not found in history - row written with MANUAL/0");
         CFTTradeLogic::FillRecord(m_pos[k], "LIVE", TimeCurrent(), 0.0, 0.0, "MANUAL", 0.0, 0, m_point, r);
      }
      Print(StringFormat("FT EXEC CLOSED pos %I64d sid %I64d %s exit %s @ %s  P/L %.2f = %.2f R  MAE %.2f MFE %.2f",
                         r.tradeId, r.signalId, FPSetupName((ENUM_FP_SIGNAL)r.setup), r.exitReason,
                         DoubleToString(r.exitPrice, m_digits), r.profitMoney, r.rMultiple, r.maeR, r.mfeR));
      if(r.exitReason == "SL" && r.riskMoney > 0.0)
         Print(StringFormat("FT RISKCHECK pos %I64d: full-stop loss %.2f vs riskMoney %.2f (%+.1f%%), riskTarget %.2f (%+.1f%%)",
                            r.tradeId, -r.profitMoney, r.riskMoney, (-r.profitMoney / r.riskMoney - 1.0) * 100.0,
                            m_pos[k].riskTarget, (m_pos[k].riskTarget > 0.0) ? (-r.profitMoney / m_pos[k].riskTarget - 1.0) * 100.0 : 0.0));
      PushRecord(r);
      GvDelAll(m_pos[k].id);
      RemovePos(k);
   }

   //--- untracked open position of this magic: restore from GlobalVariables or recover from history
   bool          RecoverPosition(const ulong tk, FTPosState &st)
   {
      if(!PositionSelectByTicket(tk))
         return false;
      st.Reset();
      st.id = PositionGetInteger(POSITION_IDENTIFIER);
      st.ticket = tk;
      st.dir = (PositionGetInteger(POSITION_TYPE) == (long)POSITION_TYPE_BUY) ? 1 : -1;
      st.entryTime = (datetime)PositionGetInteger(POSITION_TIME);
      st.entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      st.sl = PositionGetDouble(POSITION_SL);
      st.tp = PositionGetDouble(POSITION_TP);
      st.lots = PositionGetDouble(POSITION_VOLUME);
      st.recovered = true;
      string cmt = PositionGetString(POSITION_COMMENT);
      long id = st.id;
      if(GvHas(id, "R") && GvHas(id, "EBAR"))
      {
         st.rPrice = GvGet(id, "R", 0.0);
         st.entryBar = (datetime)(long)GvGet(id, "EBAR", 0.0);
         st.setup = (int)GvGet(id, "SETUP", 0.0);
         st.partStage = (GvGet(id, "PART", 0.0) > 0.5);
         st.partialDone = (GvGet(id, "PDONE", 0.0) > 0.5);
         st.slStage = (int)GvGet(id, "BE", 0.0);
         st.signalId = (long)GvGet(id, "SIG", 0.0);
         st.grade = (int)GvGet(id, "GRD", 0.0);
         st.riskMoney = GvGet(id, "RISK", 0.0);
         st.riskTarget = GvGet(id, "RTGT", 0.0);
         st.lotsInit = GvGet(id, "LOTS", st.lots);
         st.plannedEntry = GvGet(id, "PLAN", 0.0);
         st.spreadPts = GvGet(id, "SPRD", 0.0);
         st.maeR = GvGet(id, "MAE", 0.0);
         st.mfeR = GvGet(id, "MFE", 0.0);
         st.tpInit = GvGet(id, "TPI", st.tp);
         st.slInit = st.entryPrice - st.dir * st.rPrice;
         Print(StringFormat("FT STATE:RESTORED pos %I64d %s %s R %.1f pts EBAR %s part %d stage %d (GlobalVariables)",
                            id, FPSetupName((ENUM_FP_SIGNAL)st.setup), st.dir > 0 ? "BUY" : "SELL", st.rPrice / m_point,
                            TimeToString(st.entryBar), st.partStage ? 1 : 0, st.slStage));
         return true;
      }
      //--- per-position variables missing: R from the opening order's ORDER_SL
      double orderSL = 0.0;
      double inVol = 0.0;
      string src = "";
      if(HistorySelectByPosition(id))
      {
         int  no = HistoryOrdersTotal();
         long bestT = LONG_MAX;
         for(int j = 0; j < no; j++)
         {
            ulong ot = HistoryOrderGetTicket(j);
            if(ot == 0)
               continue;
            double osl = HistoryOrderGetDouble(ot, ORDER_SL);
            long   ts = HistoryOrderGetInteger(ot, ORDER_TIME_SETUP_MSC);
            if(ot == (ulong)id && osl > 0.0)
            {
               orderSL = osl;
               src = "ORDER_SL";
               break;
            }
            if(osl > 0.0 && ts < bestT)
            {
               bestT = ts;
               orderSL = osl;
               src = "ORDER_SL(first order)";
            }
         }
         int nd = HistoryDealsTotal();
         for(int j = 0; j < nd; j++)
         {
            ulong d = HistoryDealGetTicket(j);
            if(d == 0)
               continue;
            if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(d, DEAL_ENTRY) == DEAL_ENTRY_IN)
               inVol += HistoryDealGetDouble(d, DEAL_VOLUME);
         }
      }
      if(orderSL > 0.0 && (st.entryPrice - orderSL) * st.dir > 0.0)
         st.rPrice = (st.entryPrice - orderSL) * st.dir;
      else if(GvHas(id, "R"))
      {
         st.rPrice = GvGet(id, "R", 0.0);
         src = "planned R (GlobalVariable)";
      }
      else if(st.sl > 0.0 && (st.entryPrice - st.sl) * st.dir > 0.0)
      {
         st.rPrice = (st.entryPrice - st.sl) * st.dir;
         src = "current POSITION_SL (may be moved)";
      }
      st.slInit = (st.rPrice > 0.0) ? st.entryPrice - st.dir * st.rPrice : st.sl;
      st.entryBar = FTBarOpen(st.entryTime, m_c.tf);
      string parts[];
      if(StringSplit(cmt, ' ', parts) >= 2 && parts[0] == "FT")
         st.setup = FTSetupFromName(parts[1]);
      if((int)GvGet(id, "SETUP", 0.0) > 0)
         st.setup = (int)GvGet(id, "SETUP", 0.0);
      st.signalId = (long)GvGet(id, "SIG", 0.0);
      st.grade = (int)GvGet(id, "GRD", 0.0);
      st.plannedEntry = GvGet(id, "PLAN", 0.0);
      st.spreadPts = GvGet(id, "SPRD", 0.0);
      st.riskTarget = GvGet(id, "RTGT", 0.0);
      st.lotsInit = (inVol > 0.0) ? inVol : GvGet(id, "LOTS", st.lots);
      st.partialDone = (st.lots < st.lotsInit - 1e-9);
      st.partStage = st.partialDone;
      if(st.sl > 0.0 && st.rPrice > 0.0 && (st.sl - st.entryPrice) * st.dir >= 0.0)
         st.slStage = FT_STAGE_BE;
      st.tpInit = GvGet(id, "TPI", st.tp);
      st.riskMoney = GvGet(id, "RISK", 0.0);
      if(st.riskMoney <= 0.0 && st.rPrice > 0.0)
         st.riskMoney = MathAbs(FTMoney(m_c.symbol, st.dir, st.lotsInit, st.entryPrice, st.slInit));
      if(st.rPrice > 0.0)
      {
         PersistPos(st);
         Print(StringFormat("FT STATE:RECOVERED pos %I64d %s %s R %.1f pts from %s, lotsInit %s, part %d, stage %d",
                            id, FPSetupName((ENUM_FP_SIGNAL)st.setup), st.dir > 0 ? "BUY" : "SELL", st.rPrice / m_point,
                            src, FTNumTrim(st.lotsInit), st.partStage ? 1 : 0, st.slStage));
      }
      else
         Print(StringFormat("FT STATE:RECOVERED pos %I64d: R could not be recovered (no ORDER_SL) - R-based management OFF, broker SL/TP, kill switch and flat time still apply", id));
      return true;
   }

   //--- pending orders / market entries: filled, cancelled, expired?
   void          ReconcilePending(const FTMarket &m)
   {
      for(int i = ArraySize(m_pend) - 1; i >= 0; i--)
      {
         ulong ticket = m_pend[i].ticket;
         if(!m_pend[i].market && OrderSelect(ticket))
            continue;                            // still pending
         ulong posTk = FindPositionTicket((long)ticket);
         if(posTk > 0)
         {
            AdoptOpen(m_pend[i], posTk, m);
            RemovePend(i);
            continue;
         }
         int nIn = 0;
         int nOut = 0;
         if(HistorySelectByPosition((long)ticket))
         {
            int nd0 = HistoryDealsTotal();
            for(int j = 0; j < nd0; j++)
            {
               ulong d = HistoryDealGetTicket(j);
               if(d == 0)
                  continue;
               ENUM_DEAL_ENTRY e = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(d, DEAL_ENTRY);
               if(e == DEAL_ENTRY_IN)
                  nIn++;
               else if(e == DEAL_ENTRY_OUT || e == DEAL_ENTRY_OUT_BY || e == DEAL_ENTRY_INOUT)
                  nOut++;
            }
         }
         if(nIn > 0 && nOut == 0)
         {
            m_pend[i].lookups++;                 // filled, position not visible yet: adopt it on a later tick
            if(m_pend[i].lookups > 100)
            {
               Print("FT EXEC: entry ", ticket, " filled but its position never became visible - dropped (recovered if it shows up)");
               RemovePend(i);
            }
            continue;
         }
         if(nIn > 0 && nOut > 0)
         {
            //--- filled and already closed between two ticks
            FTPosState st;
            st.Reset();
            st.id = (long)ticket;
            st.signalId = m_pend[i].plan.signalId;
            st.setup = m_pend[i].plan.setup;
            st.grade = m_pend[i].plan.grade;
            st.dir = m_pend[i].plan.dir;
            st.plannedEntry = m_pend[i].plan.entry;
            st.slInit = m_pend[i].plan.sl;
            st.tpInit = m_pend[i].plan.tp;
            st.lotsInit = m_pend[i].plan.lots;
            st.riskMoney = m_pend[i].plan.riskMoney;
            st.riskTarget = m_pend[i].plan.riskTarget;
            st.spreadPts = m_pend[i].plan.spreadPts;
            int nd = HistoryDealsTotal();
            for(int j = 0; j < nd; j++)
            {
               ulong d = HistoryDealGetTicket(j);
               if(d > 0 && (ENUM_DEAL_ENTRY)HistoryDealGetInteger(d, DEAL_ENTRY) == DEAL_ENTRY_IN)
               {
                  st.entryTime = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
                  st.entryPrice = HistoryDealGetDouble(d, DEAL_PRICE);
                  st.ticket = (ulong)HistoryDealGetInteger(d, DEAL_POSITION_ID);
                  break;
               }
            }
            st.entryBar = FTBarOpen(st.entryTime, m_c.tf);
            st.rPrice = (st.entryPrice - st.slInit) * st.dir;
            if(st.rPrice <= 0.0)
               st.rPrice = m_pend[i].plan.rPrice;
            int k = AddPos(st);
            Print("FT EXEC: entry ", ticket, " filled and closed between ticks - journaling from history");
            RemovePend(i);
            Finalize(k);
            continue;
         }
         if(!m_pend[i].market && HistoryOrderSelect(ticket))
         {
            ENUM_ORDER_STATE s = (ENUM_ORDER_STATE)HistoryOrderGetInteger(ticket, ORDER_STATE);
            if(s == ORDER_STATE_CANCELED || s == ORDER_STATE_EXPIRED || s == ORDER_STATE_REJECTED)
            {
               FTTradeRecord r;
               int alive = FTBarsBetween(m_c.symbol, m_c.tf, FTBarOpen(m_pend[i].placed, m_c.tf), FTBarOpen(m.now, m_c.tf));
               CFTTradeLogic::FillUnfilled(m_pend[i], "LIVE", m.now, alive, r);
               PushRecord(r);
               Print("FT EXEC: pending ", ticket, " ended by the server: ", EnumToString(s), " -> EXPIRED");
               GvDelAll((long)ticket);
               RemovePend(i);
               continue;
            }
         }
         m_pend[i].lookups++;
         if(m_pend[i].lookups > 100)
         {
            Print("FT EXEC: entry ", ticket, " vanished without a position or history record - dropped");
            GvDelAll((long)ticket);
            RemovePend(i);
         }
      }
   }

   //--- open positions of this magic/symbol vs the tracked list
   void          ReconcilePositions(void)
   {
      int n = ArraySize(m_pos);
      for(int k = 0; k < n; k++)
         m_pos[k].seen = false;
      int pt = PositionsTotal();
      for(int i = 0; i < pt; i++)
      {
         ulong tk = PositionGetTicket(i);
         if(tk == 0)
            continue;
         if(!IsOurs(PositionGetString(POSITION_SYMBOL), PositionGetInteger(POSITION_MAGIC)))
            continue;
         long id = PositionGetInteger(POSITION_IDENTIFIER);
         int  k = FindPos(id);
         if(k < 0)
         {
            FTPosState st;
            if(!RecoverPosition(tk, st))
               continue;
            k = AddPos(st);
         }
         if(!PositionSelectByTicket(tk))
            continue;
         m_pos[k].ticket = tk;
         m_pos[k].lots = PositionGetDouble(POSITION_VOLUME);
         m_pos[k].sl = PositionGetDouble(POSITION_SL);
         m_pos[k].tp = PositionGetDouble(POSITION_TP);
         m_pos[k].seen = true;
      }
      for(int k = ArraySize(m_pos) - 1; k >= 0; k--)
         if(!m_pos[k].seen)
            Finalize(k);
   }

   void          CancelPending(const int i, const string why, const FTMarket &m)
   {
      if(m.now < m_pend[i].retryAfter)
         return;
      ulong ticket = m_pend[i].ticket;
      if(!DeleteOrder(ticket, why))
      {
         m_pend[i].retryAfter = m.now + 2;
         return;
      }
      FTTradeRecord r;
      int alive = FTBarsBetween(m_c.symbol, m_c.tf, FTBarOpen(m_pend[i].placed, m_c.tf), FTBarOpen(m.now, m_c.tf));
      CFTTradeLogic::FillUnfilled(m_pend[i], "LIVE", m.now, alive, r);
      PushRecord(r);
      Print("FT EXEC: pending ", ticket, " sid ", m_pend[i].plan.signalId, " cancelled (", why, ") -> EXPIRED");
      GvDelAll((long)ticket);
      RemovePend(i);
   }

   void          ClosePos(const int k, const string reason, const FTMarket &m)
   {
      m_pos[k].pendingClose = reason;
      if(!SendClose(k, 0.0, reason))
         m_pos[k].retryAfter = m.now + 5;
   }

   void          Apply(const int k, const FTAction &a, const FTMarket &m)
   {
      if(a.close)
      {
         ClosePos(k, a.reason, m);
         return;
      }
      if(a.partialStage)
      {
         if(a.partialLots > 0.0)
         {
            if(!SendClose(k, a.partialLots, "PARTIAL"))
            {
               m_pos[k].retryAfter = m.now + 5;
               return;
            }
            m_pos[k].partialDone = true;
         }
         else
            Print("FT EXEC pos ", m_pos[k].id, ": partial close skipped (volume cannot be split within step/min) - break-even only");
         m_pos[k].partStage = true;
         SaveState(m_pos[k]);
      }
      if(a.newSL > 0.0)
      {
         if(ModifySL(k, a.newSL, m))
         {
            if(a.newStage > m_pos[k].slStage)
               m_pos[k].slStage = a.newStage;
            SaveState(m_pos[k]);
         }
         else
            m_pos[k].retryAfter = m.now + 10;
      }
   }

public:
                 CFPExecution(void) { m_planner = NULL; m_filters = NULL; m_hedging = true; m_point = 0.0; m_digits = 0; }

   bool          Init(const FTExecConfig &c, const FTMgmtConfig &mc, CFTPlanner *planner, CFPFilters *filters)
   {
      m_c = c;
      m_mc = mc;
      m_planner = planner;
      m_filters = filters;
      m_point = SymbolInfoDouble(m_c.symbol, SYMBOL_POINT);
      m_digits = (int)SymbolInfoInteger(m_c.symbol, SYMBOL_DIGITS);
      m_hedging = ((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
      m_trade.SetMarginMode();
      m_trade.SetExpertMagicNumber((ulong)m_c.magic);
      m_trade.SetDeviationInPoints((ulong)m_c.slippagePts);
      m_trade.SetTypeFillingBySymbol(m_c.symbol);
      m_trade.SetAsyncMode(false);
      m_trade.LogLevel(LOG_LEVEL_ERRORS);
      ArrayResize(m_pend, 0);
      ArrayResize(m_pos, 0);
      ArrayResize(m_done, 0);
      Print(StringFormat("FT EXEC: %s account, magic %I64d, slippage %d pts, filling %s, expiry %s, price basis %s",
                         m_hedging ? "HEDGING" : "NETTING", m_c.magic, m_c.slippagePts, EnumToString(FTFilling(m_c.symbol)),
                         BrokerExpiryOK() ? "broker (ORDER_TIME_SPECIFIED) + manual check" : "manual (GTC, cancel after N bars)",
                         (m_planner != NULL) ? m_planner.BasisName() : "?"));
      return (m_planner != NULL && m_filters != NULL && m_point > 0.0);
   }

   bool          Hedging(void) const { return m_hedging; }

   bool          BrokerExpiryOK(void) const
   {
      return ((SymbolInfoInteger(m_c.symbol, SYMBOL_EXPIRATION_MODE) & SYMBOL_EXPIRATION_SPECIFIED) != 0);
   }

   //--- 03 §8 pre-checks; why = '|'-joined failures
   bool          TradeAllowed(const int dir, string &why) const
   {
      why = "";
      if(TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) == 0)
         FTAddReason(why, "TERMINAL_TRADE_ALLOWED=0");
      if(MQLInfoInteger(MQL_TRADE_ALLOWED) == 0)
         FTAddReason(why, "MQL_TRADE_ALLOWED=0");
      if(AccountInfoInteger(ACCOUNT_TRADE_EXPERT) == 0)
         FTAddReason(why, "ACCOUNT_TRADE_EXPERT=0");
      if(AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) == 0)
         FTAddReason(why, "ACCOUNT_TRADE_ALLOWED=0");
      ENUM_SYMBOL_TRADE_MODE tm = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(m_c.symbol, SYMBOL_TRADE_MODE);
      if(tm == SYMBOL_TRADE_MODE_DISABLED || tm == SYMBOL_TRADE_MODE_CLOSEONLY ||
         (tm == SYMBOL_TRADE_MODE_LONGONLY && dir < 0) || (tm == SYMBOL_TRADE_MODE_SHORTONLY && dir > 0))
         FTAddReason(why, "SYMBOL_TRADE_MODE=" + EnumToString(tm));
      return (why == "");
   }

   //--- architecture §5: positionBusy for CFPFilters::CheckSignal (LIVE)
   bool          Busy(const int maxPositions) const
   {
      int  ours = 0;
      bool anyOnSymbol = false;
      long ids[];
      int  nIds = 0;
      int  pt = PositionsTotal();
      for(int i = 0; i < pt; i++)
      {
         ulong tk = PositionGetTicket(i);
         if(tk == 0 || PositionGetString(POSITION_SYMBOL) != m_c.symbol)
            continue;
         anyOnSymbol = true;
         if(PositionGetInteger(POSITION_MAGIC) == m_c.magic)
         {
            ours++;
            ArrayResize(ids, nIds + 1);
            ids[nIds++] = PositionGetInteger(POSITION_IDENTIFIER);
         }
      }
      int ot = OrdersTotal();
      for(int i = 0; i < ot; i++)
      {
         ulong tk = OrderGetTicket(i);
         if(tk == 0)
            continue;
         if(IsOurs(OrderGetString(ORDER_SYMBOL), OrderGetInteger(ORDER_MAGIC)))
            ours++;
      }
      int np = ArraySize(m_pend);
      for(int i = 0; i < np; i++)
      {
         if(!m_pend[i].market)
            continue;                            // pending orders were counted above
         bool visible = false;
         for(int j = 0; j < nIds; j++)
            if(ids[j] == (long)m_pend[i].ticket)
            {
               visible = true;
               break;
            }
         if(!visible)
            ours++;                              // market order sent, position not visible yet
      }
      if(!m_hedging && (anyOnSymbol || ours > 0))
         return true;                            // netting: never add to / net against an existing position
      return (ours >= maxPositions);
   }

   //--- entries submitted but not filled yet (daily-trades gate)
   int           PendingCount(void) const { return ArraySize(m_pend); }
   int           OpenCount(void) const    { return ArraySize(m_pos); }

   //--- floating P/L of this magic/symbol (daily-loss check)
   double        Floating(void) const
   {
      double f = 0.0;
      int pt = PositionsTotal();
      for(int i = 0; i < pt; i++)
      {
         ulong tk = PositionGetTicket(i);
         if(tk == 0)
            continue;
         if(!IsOurs(PositionGetString(POSITION_SYMBOL), PositionGetInteger(POSITION_MAGIC)))
            continue;
         f += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      }
      return f;
   }

   //+---------------------------------------------------------------+
   //| Restart: restore pendings/positions of this magic (03 §9)     |
   //+---------------------------------------------------------------+
   void          Recover(const FTMarket &m)
   {
      for(int i = OrdersTotal() - 1; i >= 0; i--)
      {
         ulong tk = OrderGetTicket(i);
         if(tk == 0)
            continue;
         if(!IsOurs(OrderGetString(ORDER_SYMBOL), OrderGetInteger(ORDER_MAGIC)))
            continue;
         ENUM_ORDER_TYPE t = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
         if(t != ORDER_TYPE_BUY_STOP && t != ORDER_TYPE_SELL_STOP && t != ORDER_TYPE_BUY_LIMIT && t != ORDER_TYPE_SELL_LIMIT)
            continue;
         long id = (long)tk;
         if(GvHas(id, "KIND") && GvHas(id, "SBAR"))
         {
            FTPend p;
            p.Reset();
            p.ticket = tk;
            p.market = false;
            p.placed = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
            p.brokerExpiry = ((ENUM_ORDER_TYPE_TIME)OrderGetInteger(ORDER_TYPE_TIME) == ORDER_TIME_SPECIFIED);
            p.plan.signalId = (long)GvGet(id, "SIG", 0.0);
            p.plan.setup = (int)GvGet(id, "SETUP", 0.0);
            p.plan.grade = (int)GvGet(id, "GRD", 0.0);
            p.plan.dir = (t == ORDER_TYPE_BUY_STOP || t == ORDER_TYPE_BUY_LIMIT) ? 1 : -1;
            p.plan.kind = (int)GvGet(id, "KIND", 0.0);
            p.plan.entry = OrderGetDouble(ORDER_PRICE_OPEN);
            p.plan.sl = OrderGetDouble(ORDER_SL);
            p.plan.tp = OrderGetDouble(ORDER_TP);
            p.plan.lots = OrderGetDouble(ORDER_VOLUME_CURRENT);
            p.plan.rPrice = GvGet(id, "R", 0.0);
            p.plan.riskMoney = GvGet(id, "RISK", 0.0);
            p.plan.riskTarget = GvGet(id, "RTGT", 0.0);
            p.plan.spreadPts = GvGet(id, "SPRD", 0.0);
            p.plan.invalidPrice = GvGet(id, "INV", 0.0);
            p.plan.signalBar = (datetime)(long)GvGet(id, "SBAR", 0.0);
            p.plan.validBars = (int)GvGet(id, "VB", 1.0);
            p.plan.expiry = p.plan.signalBar + (p.plan.validBars + 1) * PeriodSeconds(m_c.tf);
            int n = ArraySize(m_pend);
            ArrayResize(m_pend, n + 1);
            m_pend[n] = p;
            Print(StringFormat("FT STATE:RESTORED pending %I64u sid %I64d %s %s @ %s inv %s valid %d bars",
                               tk, p.plan.signalId, FPSetupName((ENUM_FP_SIGNAL)p.plan.setup), FTKindName(p.plan.kind),
                               DoubleToString(p.plan.entry, m_digits), DoubleToString(p.plan.invalidPrice, m_digits), p.plan.validBars));
         }
         else
         {
            Print("FT STATE:PENDING_CANCELLED order ", tk, ": its state variables are missing, so its invalidation cannot be managed");
            if(DeleteOrder(tk, "STATE"))
               GvDelAll(id);
         }
      }
      ReconcilePositions();
      ReconcilePending(m);
      Print("FT STATE: ", ArraySize(m_pos), " open position(s) and ", ArraySize(m_pend), " pending order(s) of magic ", m_c.magic, " under management");
   }

   //+---------------------------------------------------------------+
   //| Submit plan p (built by CFTPlanner from sig) with the retcode |
   //| policy. Market retries re-plan from a fresh quote; an         |
   //| INVALID_STOPS retry re-plans with a wider distance (re-size). |
   //+---------------------------------------------------------------+
   bool          Submit(const FPSignal &sig, const long sid, const FTPlan &plan0)
   {
      FTPlan plan = plan0;
      string why = "";
      if(!TradeAllowed(plan.dir, why))
      {
         Print("FT EXEC OPEN sid ", sid, ": pre-check failed: ", why, " -> skip");
         return false;
      }
      bool   brokerExpiry = BrokerExpiryOK();
      bool   widened = false;
      bool   expRetried = false;
      bool   fillRetried = false;
      int    priceRetries = 0;
      double extra = 0.0;
      bool   result = false;
      for(int attempt = 1; attempt <= 8; attempt++)
      {
         bool sent = SendOpen(plan, brokerExpiry && plan.kind != FP_ORD_MARKET);
         uint rc = m_trade.ResultRetcode();
         int  cls = FTRcClass(rc);
         LogRc("OPEN", attempt, sent, rc, m_trade.ResultRetcodeDescription(),
               StringFormat("sid %I64d %s %s %s", sid, FPSetupName((ENUM_FP_SIGNAL)plan.setup), plan.dir > 0 ? "BUY" : "SELL",
                            m_planner.Describe(plan)));
         if(cls == FT_RC_OK)
         {
            ulong ticket = m_trade.ResultOrder();
            if(ticket == 0)
            {
               Print("FT EXEC OPEN sid ", sid, ": retcode ok but no order ticket - not tracked");
               break;
            }
            FTPend p;
            p.Reset();
            p.ticket = ticket;
            p.market = (plan.kind == FP_ORD_MARKET);
            p.plan = plan;
            p.placed = TimeCurrent();
            p.brokerExpiry = brokerExpiry && !p.market;
            int n = ArraySize(m_pend);
            ArrayResize(m_pend, n + 1);
            m_pend[n] = p;
            PersistPlan(ticket, plan);
            result = true;
            break;
         }
         if(cls == FT_RC_PRICE && priceRetries < 3)
            priceRetries++;
         else if(cls == FT_RC_STOPS && !widened)
         {
            widened = true;
            MqlTick t0;
            if(!FreshTick(t0))
               break;
            extra = MathMax(m_planner.MinDist(), t0.ask - t0.bid) + 2.0 * m_planner.TickSize();
         }
         else if(cls == FT_RC_EXPIRATION && plan.kind != FP_ORD_MARKET && brokerExpiry && !expRetried)
         {
            expRetried = true;
            brokerExpiry = false;
            continue;                            // same plan, GTC + manual expiry
         }
         else if(cls == FT_RC_FILL && plan.kind != FP_ORD_MARKET && !fillRetried)
         {
            fillRetried = true;
            m_trade.SetTypeFilling(ORDER_FILLING_RETURN);
            continue;
         }
         else
            break;                               // NO_MONEY / anything else: logged above, skip
         //--- re-plan from a fresh quote (and the wider distance after INVALID_STOPS): re-sized
         MqlTick tk;
         if(!FreshTick(tk))
            break;
         string codes = "";
         string note = "";
         if(!m_planner.Build(sig, sid, tk, extra, AccountInfoDouble(ACCOUNT_EQUITY), AccountInfoDouble(ACCOUNT_MARGIN_FREE), plan, codes, note))
         {
            Print("FT EXEC OPEN sid ", sid, ": re-plan failed (", codes, ": ", note, ") -> skip");
            break;
         }
         if(note != "")
            Print("FT EXEC OPEN sid ", sid, ": re-plan: ", note);
      }
      m_trade.SetTypeFillingBySymbol(m_c.symbol);
      return result;
   }

   //+---------------------------------------------------------------+
   //| Every tick: fills/closes, pending cancel (bid vs invalidPrice,|
   //| live filters), partial/BE/trailing/flat, MAE/MFE.             |
   //+---------------------------------------------------------------+
   void          OnTick(const FTMarket &m)
   {
      ReconcilePending(m);
      ReconcilePositions();
      //--- pending entries
      bool   liveChecked = false;
      bool   liveOk = true;
      string liveWhy = "";
      for(int i = ArraySize(m_pend) - 1; i >= 0; i--)
      {
         if(m_pend[i].market)
            continue;
         double inv = m_pend[i].plan.invalidPrice;
         int    dir = m_pend[i].plan.dir;
         if(inv > 0.0 && ((dir > 0 && m.bid < inv) || (dir < 0 && m.bid > inv)))
         {
            CancelPending(i, StringFormat("INVALID bid %s vs %s", DoubleToString(m.bid, m_digits), DoubleToString(inv, m_digits)), m);
            continue;
         }
         if(!liveChecked)
         {
            liveOk = m_filters.CheckLive(m.now, (m.atr > 0.0) ? m.atr : m_pend[i].plan.atr, liveWhy);
            liveChecked = true;
         }
         if(!liveOk)
            CancelPending(i, "LIVE_FILTER:" + liveWhy, m);
      }
      //--- positions
      int n = ArraySize(m_pos);
      for(int k = n - 1; k >= 0; k--)
      {
         CFTTradeLogic::Excursion(m_pos[k], m.bid, m.ask);
         if(m.now < m_pos[k].retryAfter)
            continue;
         FTAction a;
         if(CFTTradeLogic::DecideTick(m_mc, m_pos[k], m, a))
            Apply(k, a, m);
      }
   }

   //+---------------------------------------------------------------+
   //| Closed bar T (after its signals): pending expiry/invalidation,|
   //| time stop, opposite grade A, BAR trailing, MAE/MFE persisted. |
   //| barLow/barHigh: T's engine-basis low/high (0 = n/a).          |
   //+---------------------------------------------------------------+
   void          OnBarClosed(const datetime T, const double barLow, const double barHigh, const bool longA, const bool shortA, const FTMarket &m)
   {
      for(int i = ArraySize(m_pend) - 1; i >= 0; i--)
      {
         if(m_pend[i].market || !OrderSelect(m_pend[i].ticket))
            continue;                            // gone: the reconcile step journals it
         int    dir = m_pend[i].plan.dir;
         double inv = m_pend[i].plan.invalidPrice;
         bool   fired = (T > m_pend[i].plan.signalBar && inv > 0.0 &&
                         ((dir > 0 && barLow > 0.0 && barLow < inv) || (dir < 0 && barHigh > 0.0 && barHigh > inv)));
         if(fired)
            CancelPending(i, "INVALID_BAR", m);
         else if(FTBarsBetween(m_c.symbol, m_c.tf, m_pend[i].plan.signalBar, T) >= m_pend[i].plan.validBars)
            CancelPending(i, StringFormat("EXPIRY %d bars", m_pend[i].plan.validBars), m);
      }
      double spr = m.ask - m.bid;
      for(int k = ArraySize(m_pos) - 1; k >= 0; k--)
      {
         //--- only bars at/after the entry bar count (bar T may be the signal bar of a position opened just now)
         bool   held = (T >= m_pos[k].entryBar);
         int    done = held ? FTBarsBetween(m_c.symbol, m_c.tf, m_pos[k].entryBar, T) + 1 : 0;
         double tl = (barLow > 0.0) ? m_planner.LongExit(barLow, spr) : 0.0;
         double ts = (barHigh > 0.0) ? m_planner.ShortExit(barHigh, spr) : 0.0;
         bool   opp = held && ((m_pos[k].dir > 0) ? shortA : longA);
         FTAction a;
         if(m.now >= m_pos[k].retryAfter && CFTTradeLogic::DecideBar(m_mc, m_pos[k], m, done, tl, ts, opp, a))
            Apply(k, a, m);
         if(k < ArraySize(m_pos) && m_pos[k].rPrice > 0.0)
            SaveState(m_pos[k]);
      }
   }

   //--- kill switch / flat: close every position of this magic
   void          CloseAll(const string reason, const FTMarket &m)
   {
      ReconcilePending(m);
      ReconcilePositions();
      for(int k = ArraySize(m_pos) - 1; k >= 0; k--)
         ClosePos(k, reason, m);
   }

   //--- risk events: cancel every pending entry of this magic
   void          CancelAll(const string reason, const FTMarket &m)
   {
      for(int i = ArraySize(m_pend) - 1; i >= 0; i--)
      {
         if(m_pend[i].market)
            continue;
         m_pend[i].retryAfter = 0;
         CancelPending(i, reason, m);
      }
      for(int i = OrdersTotal() - 1; i >= 0; i--)
      {
         ulong tk = OrderGetTicket(i);
         if(tk == 0 || !IsOurs(OrderGetString(ORDER_SYMBOL), OrderGetInteger(ORDER_MAGIC)))
            continue;
         Print("FT EXEC: untracked pending ", tk, " of this magic cancelled (", reason, ")");
         if(DeleteOrder(tk, reason))
            GvDelAll((long)tk);
      }
   }

   bool          PopRecord(FTTradeRecord &r)
   {
      int n = ArraySize(m_done);
      if(n == 0)
         return false;
      r = m_done[0];
      for(int i = 0; i < n - 1; i++)
         m_done[i] = m_done[i + 1];
      ArrayResize(m_done, n - 1);
      return true;
   }
};
//+------------------------------------------------------------------+
