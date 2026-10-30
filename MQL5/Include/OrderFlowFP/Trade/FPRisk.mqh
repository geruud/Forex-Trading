//+------------------------------------------------------------------+
//| FPRisk.mqh - FootprintTrader risk layer (03 §7)                   |
//|                                                                    |
//|  - position sizing: OrderCalcProfit on MARKET order types with the |
//|    spread-converted fill/stop prices, floor to the volume step,    |
//|    clamp to min/max, OrderCalcMargin vs free margin                |
//|  - daily trade count, daily loss (closed P/L of today's magic      |
//|    deals + floating vs the day-start equity), consecutive losses   |
//|  - kill switch: equity drawdown from the recorded peak             |
//|    (GlobalVariables FT_<symbol>_<magic>_PEAK / _KILL; the tester   |
//|    emulates GlobalVariables, so it is active there too)            |
//|                                                                    |
//|  FORBIDDEN and not implemented anywhere: martingale, grid,         |
//|  averaging, size increase after losses, removing stops. The lot    |
//|  size depends only on equity, InpRiskPct and the stop distance.    |
//|                                                                    |
//|  Mode-agnostic: the EA feeds it account values (LIVE, persisted)   |
//|  or virtual values (VIRTUAL, memory only) - see docs\decisions.    |
//+------------------------------------------------------------------+
#include "FPFilters.mqh"

#define FT_RISK_EV_KILL     1
#define FT_RISK_EV_DAYLOSS  2
#define FT_RISK_EV_CONSEC   4

//+------------------------------------------------------------------+
//| Small helpers shared by the trade layer (FT prefix = no clashes)  |
//+------------------------------------------------------------------+
void FTAddReason(string &reasons, const string code)
{
   if(code == "")
      return;
   if(reasons == "")
      reasons = code;
   else
      reasons = reasons + "|" + code;
}

datetime FTDayStart(const datetime t)
{
   return (datetime)((long)t - (long)t % 86400);
}

int FTMinuteOfDay(const datetime t)
{
   return (int)(((long)t % 86400) / 60);
}

double FTFloorStep(const double v, const double step)
{
   if(step <= 0.0)
      return v;
   return MathFloor(v / step + 1e-9) * step;
}

int FTStepDigits(const double step)
{
   int    d = 0;
   double s = step;
   while(d < 8 && MathAbs(s - MathRound(s)) > 1e-7)
   {
      s *= 10.0;
      d++;
   }
   return d;
}

// fixed, locale-free number text with trailing zeros removed (deterministic CSV output)
string FTNumTrim(const double v)
{
   string s = DoubleToString(v, 6);
   if(StringFind(s, ".") >= 0)
   {
      int n = StringLen(s);
      while(n > 0 && StringGetCharacter(s, n - 1) == '0')
         n--;
      if(n > 0 && StringGetCharacter(s, n - 1) == '.')
         n--;
      s = StringSubstr(s, 0, n);
   }
   if(s == "-0" || s == "")
      s = "0";
   return s;
}

//+------------------------------------------------------------------+
//| Risk configuration (03 §7 inputs + test hooks)                    |
//+------------------------------------------------------------------+
struct FTRiskConfig
{
   string   symbol;
   long     magic;
   string   tag;               // "LIVE" / "VIRTUAL" (log prefix)
   bool     persist;           // LIVE: peak/kill/day-block in GlobalVariables; VIRTUAL: memory only
   double   riskPct;           // InpRiskPct
   bool     allowMinLot;       // InpAllowMinLot
   int      maxTradesPerDay;   // InpMaxTradesPerDay (0 = off)
   double   maxDailyLossPct;   // InpMaxDailyLossPct (0 = off)
   int      maxConsecLosses;   // InpMaxConsecLosses (0 = off)
   int      consecPauseMin;    // InpConsecPauseMin: pause after maxConsecLosses losses, minutes (0 = until the next server day, spec)
   double   maxDDPct;          // InpMaxDDPct (0 = off)
   datetime testDailyLossAt;   // test hooks (0 = off), see FootprintTrader.mq5 "Test hooks"
   datetime testConsecLossAt;
   datetime testKillAt;
   bool     testResetKill;
};

//+------------------------------------------------------------------+
//| CFPRisk                                                           |
//+------------------------------------------------------------------+
class CFPRisk
{
private:
   FTRiskConfig m_cfg;
   //--- server day
   datetime     m_dayStart;        // 00:00 server time of the current day (0 = not started)
   double       m_dayStartEquity;
   int          m_tradesToday;     // filled entries today
   double       m_closedToday;     // realised money today (this magic + symbol)
   int          m_consec;          // consecutive losing positions today (since the last pause, in pause mode)
   bool         m_dayLossHit;      // sticky until the next server day
   bool         m_consecHit;       // spec mode: sticky until the next server day
   datetime     m_pauseUntil;      // pause mode: no entries before this time (0 = none)
   datetime     m_consecResetAt;   // pause mode: only positions closed after this time count toward the streak
   datetime     m_now;             // last Monitor() time (for the pause gate)
   double       m_synthLoss;       // test hook: synthetic realised loss of today
   //--- kill switch
   double       m_peak;
   double       m_peakSaved;
   bool         m_kill;
   //--- test hooks fired
   bool         m_hookDaily;
   bool         m_hookConsec;
   bool         m_hookKill;

   string       Gv(const string suffix) const
   {
      return "FT_" + m_cfg.symbol + "_" + IntegerToString(m_cfg.magic) + "_" + suffix;
   }
   void         SavePeakNow(void)
   {
      if(!m_cfg.persist)
         return;
      GlobalVariableSet(Gv("PEAK"), m_peak);
      m_peakSaved = m_peak;
   }

public:
                CFPRisk(void)
   {
      m_dayStart = 0; m_dayStartEquity = 0.0; m_tradesToday = 0; m_closedToday = 0.0; m_consec = 0;
      m_dayLossHit = false; m_consecHit = false; m_synthLoss = 0.0;
      m_pauseUntil = 0; m_consecResetAt = 0; m_now = 0;
      m_peak = 0.0; m_peakSaved = 0.0; m_kill = false;
      m_hookDaily = false; m_hookConsec = false; m_hookKill = false;
   }

   //--- equityNow: account equity (LIVE) or virtual equity (VIRTUAL)
   bool         Init(const FTRiskConfig &cfg, const double equityNow)
   {
      m_cfg  = cfg;
      m_kill = false;
      m_peak = equityNow;
      m_peakSaved = 0.0;
      m_dayStart = 0;
      if(m_cfg.persist)
      {
         if(m_cfg.testResetKill)
         {
            GlobalVariableDel(Gv("KILL"));
            GlobalVariableDel(Gv("PEAK"));
            GlobalVariableDel(Gv("DAYBLOCK"));
            Print("FT TEST: InpTestResetKill -> deleted ", Gv("KILL"), ", ", Gv("PEAK"), ", ", Gv("DAYBLOCK"));
         }
         if(GlobalVariableCheck(Gv("PEAK")))
         {
            double p = GlobalVariableGet(Gv("PEAK"));
            if(p > m_peak)
               m_peak = p;
         }
         if(GlobalVariableCheck(Gv("KILL")) && GlobalVariableGet(Gv("KILL")) > 0.5)
         {
            m_kill = true;
            Print("FT RISK[", m_cfg.tag, "]: KILL SWITCH IS ACTIVE (persisted in ", Gv("KILL"),
                  "). No new entries. Delete that GlobalVariable (F3) or run once with InpTestResetKill=true to re-enable.");
         }
         //--- consecutive-loss pause (pause mode): survives a restart
         if(GlobalVariableCheck(Gv("CRESET")))
            m_consecResetAt = (datetime)(long)GlobalVariableGet(Gv("CRESET"));
         if(GlobalVariableCheck(Gv("PAUSE")))
         {
            m_pauseUntil = (datetime)(long)GlobalVariableGet(Gv("PAUSE"));
            if(m_pauseUntil > TimeCurrent())
               Print("FT RISK[", m_cfg.tag, "]: consecutive-loss pause active until ", TimeToString(m_pauseUntil, TIME_DATE | TIME_MINUTES),
                     " (", Gv("PAUSE"), ")");
         }
         SavePeakNow();
      }
      string pause = (m_cfg.consecPauseMin > 0) ? StringFormat("pause %d min", m_cfg.consecPauseMin) : "pause to the next day";
      Print(StringFormat("FT RISK[%s]: risk %.2f%%/trade, minLot %s, max %d trades/day, daily loss %.2f%%, %d consecutive losses (%s), kill at %.2f%% DD (peak %.2f)",
                         m_cfg.tag, m_cfg.riskPct, m_cfg.allowMinLot ? "allowed" : "skip", m_cfg.maxTradesPerDay,
                         m_cfg.maxDailyLossPct, m_cfg.maxConsecLosses, pause, m_cfg.maxDDPct, m_peak));
      return true;
   }

   //--- persist the peak on shutdown (it is throttled while running)
   void         Deinit(void)
   {
      if(m_cfg.persist && m_peak > m_peakSaved)
         SavePeakNow();
   }

   //+---------------------------------------------------------------+
   //| Server day                                                    |
   //+---------------------------------------------------------------+
   bool         NeedNewDay(const datetime now) const
   {
      return m_dayStart == 0 || FTDayStart(now) != m_dayStart;
   }

   // start a server day: counters reset, limits re-armed ("pause until the next day")
   void         BeginDay(const datetime now, const double dayStartEquity)
   {
      m_dayStart       = FTDayStart(now);
      m_dayStartEquity = dayStartEquity;
      m_tradesToday    = 0;
      m_closedToday    = 0.0;
      m_consec         = 0;
      m_dayLossHit     = false;
      m_consecHit      = false;
      m_synthLoss      = 0.0;
      if(m_cfg.persist && GlobalVariableCheck(Gv("DAYBLOCK")))
      {
         if((long)GlobalVariableGet(Gv("DAYBLOCK")) == (long)m_dayStart)
         {
            m_dayLossHit = true;
            Print("FT RISK[", m_cfg.tag, "]: daily loss limit already reached today (", Gv("DAYBLOCK"), ") - no entries until the next server day");
         }
         else
            GlobalVariableDel(Gv("DAYBLOCK"));
      }
      Print(StringFormat("FT RISK[%s]: server day %s, day-start equity %.2f",
                         m_cfg.tag, TimeToString(m_dayStart, TIME_DATE), m_dayStartEquity));
   }

   //--- LIVE: rebuild today's counters from deal history (restart + every trade event; never per tick)
   bool         LiveRefresh(const datetime now)
   {
      datetime ds = FTDayStart(now);
      if(!HistorySelect(ds, ds + 2 * 86400))
      {
         Print("FT RISK[", m_cfg.tag, "]: HistorySelect failed, err=", GetLastError());
         return false;
      }
      //--- ids of our positions that are still open (they are not "closed today")
      long openIds[];
      int  nOpen = 0;
      int  pt = PositionsTotal();
      for(int i = 0; i < pt; i++)
      {
         ulong tk = PositionGetTicket(i);
         if(tk == 0)
            continue;
         if(PositionGetString(POSITION_SYMBOL) != m_cfg.symbol || PositionGetInteger(POSITION_MAGIC) != m_cfg.magic)
            continue;
         ArrayResize(openIds, nOpen + 1);
         openIds[nOpen++] = PositionGetInteger(POSITION_IDENTIFIER);
      }
      int      trades = 0;
      double   closed = 0.0;
      double   accountTradePL = 0.0;
      long     ids[];
      double   pl[];
      datetime lastOut[];
      int      np = 0;
      int      total = HistoryDealsTotal();
      for(int i = 0; i < total; i++)
      {
         ulong d = HistoryDealGetTicket(i);
         if(d == 0)
            continue;
         ENUM_DEAL_TYPE type = (ENUM_DEAL_TYPE)HistoryDealGetInteger(d, DEAL_TYPE);
         if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL)
            continue;                           // balance/credit operations are not trading P/L
         double money = HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP) +
                        HistoryDealGetDouble(d, DEAL_COMMISSION) + HistoryDealGetDouble(d, DEAL_FEE);
         accountTradePL += money;
         if(HistoryDealGetString(d, DEAL_SYMBOL) != m_cfg.symbol || HistoryDealGetInteger(d, DEAL_MAGIC) != m_cfg.magic)
            continue;
         closed += money;
         ENUM_DEAL_ENTRY e = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(d, DEAL_ENTRY);
         if(e == DEAL_ENTRY_IN)
            trades++;
         long pid = HistoryDealGetInteger(d, DEAL_POSITION_ID);
         int  k = -1;
         for(int j = 0; j < np; j++)
            if(ids[j] == pid)
            {
               k = j;
               break;
            }
         if(k < 0)
         {
            ArrayResize(ids, np + 1);
            ArrayResize(pl, np + 1);
            ArrayResize(lastOut, np + 1);
            ids[np] = pid;
            pl[np] = 0.0;
            lastOut[np] = 0;
            k = np++;
         }
         pl[k] += money;
         if(e == DEAL_ENTRY_OUT || e == DEAL_ENTRY_OUT_BY || e == DEAL_ENTRY_INOUT)
         {
            datetime t = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
            if(t > lastOut[k])
               lastOut[k] = t;
         }
      }
      //--- consecutive losses: closed positions ordered by their last exit, counted from the newest
      int consec = 0;
      bool used[];
      ArrayResize(used, np);
      for(int j = 0; j < np; j++)
      {
         bool isOpen = false;
         for(int q = 0; q < nOpen; q++)
            if(openIds[q] == ids[j])
            {
               isOpen = true;
               break;
            }
         used[j] = (isOpen || lastOut[j] == 0);   // still open or never closed today -> ignore
         if(m_cfg.consecPauseMin > 0 && lastOut[j] <= m_consecResetAt)
            used[j] = true;                       // pause mode: the streak restarts after each pause
      }
      for(int guard = 0; guard < np; guard++)
      {
         int best = -1;
         for(int j = 0; j < np; j++)
            if(!used[j] && (best < 0 || lastOut[j] > lastOut[best]))
               best = j;
         if(best < 0)
            break;
         used[best] = true;
         if(pl[best] < 0.0)
            consec++;
         else
            break;
      }
      if(NeedNewDay(now))
      {
         double bal = AccountInfoDouble(ACCOUNT_BALANCE);
         double eq  = bal - accountTradePL;      // balance at server-day start, derived from deal history
         if(eq <= 0.0)
            eq = bal;
         BeginDay(now, eq);
      }
      m_tradesToday = trades;
      m_closedToday = closed;
      m_consec      = consec;
      return true;
   }

   //--- VIRTUAL: incremental counters
   void         AddEntry(void)                      { m_tradesToday++; }
   void         AddClosedMoney(const double money)  { m_closedToday += money; }
   void         AddPositionResult(const double net)
   {
      if(net < 0.0)
         m_consec++;
      else
         m_consec = 0;
   }

   //+---------------------------------------------------------------+
   //| Per-tick monitor. Returns FT_RISK_EV_* bits that FIRED now.   |
   //| equity/floating: account (LIVE) or virtual (VIRTUAL) values.  |
   //+---------------------------------------------------------------+
   int          Monitor(const datetime now, const double equity, const double floating)
   {
      int ev = 0;
      //--- test hooks (single shot, off by default)
      if(!m_hookDaily && m_cfg.testDailyLossAt > 0 && now >= m_cfg.testDailyLossAt)
      {
         m_hookDaily = true;
         m_synthLoss = m_cfg.maxDailyLossPct / 100.0 * m_dayStartEquity;
         Print(StringFormat("FT TEST[%s]: InpTestDailyLossAt -> synthetic realised loss %.2f injected for %s",
                            m_cfg.tag, m_synthLoss, TimeToString(m_dayStart, TIME_DATE)));
      }
      if(!m_hookConsec && m_cfg.testConsecLossAt > 0 && now >= m_cfg.testConsecLossAt)
      {
         m_hookConsec = true;
         if(m_consec < m_cfg.maxConsecLosses)
            m_consec = m_cfg.maxConsecLosses;
         Print("FT TEST[", m_cfg.tag, "]: InpTestConsecLossAt -> consecutive-loss counter set to ", m_consec);
      }
      if(!m_hookKill && m_cfg.testKillAt > 0 && now >= m_cfg.testKillAt)
      {
         m_hookKill = true;
         if(m_cfg.maxDDPct > 0.0 && m_cfg.maxDDPct < 100.0)
         {
            double p = equity / (1.0 - m_cfg.maxDDPct / 100.0) * 1.0001;
            if(p > m_peak)
               m_peak = p;
            Print(StringFormat("FT TEST[%s]: InpTestKillAt -> equity peak raised to %.2f (equity %.2f)", m_cfg.tag, m_peak, equity));
         }
         else
            Print("FT TEST[", m_cfg.tag, "]: InpTestKillAt ignored (InpMaxDDPct is off)");
      }
      //--- kill switch: drawdown from the recorded equity peak
      if(!m_kill && m_cfg.maxDDPct > 0.0)
      {
         if(equity > m_peak)
         {
            m_peak = equity;
            if(m_cfg.persist && m_peak > m_peakSaved * 1.0001)
               SavePeakNow();
         }
         double dd = (m_peak > 0.0) ? (m_peak - equity) / m_peak * 100.0 : 0.0;
         if(dd >= m_cfg.maxDDPct)
         {
            m_kill = true;
            ev |= FT_RISK_EV_KILL;
            if(m_cfg.persist)
            {
               GlobalVariableSet(Gv("KILL"), 1.0);
               SavePeakNow();
               GlobalVariablesFlush();
            }
            string msg = StringFormat("FootprintTrader KILL SWITCH [%s %s magic %I64d]: equity %.2f is %.2f%% below the peak %.2f (limit %.2f%%) - closing all, trading disabled",
                                      m_cfg.tag, m_cfg.symbol, m_cfg.magic, equity, dd, m_peak, m_cfg.maxDDPct);
            Print("FT RISK: ", msg);
            Alert(msg);
         }
      }
      //--- daily loss: closed today + floating vs day-start equity
      if(!m_dayLossHit && m_cfg.maxDailyLossPct > 0.0 && m_dayStartEquity > 0.0)
      {
         double dayPL = m_closedToday + floating - m_synthLoss;
         double lim   = m_cfg.maxDailyLossPct / 100.0 * m_dayStartEquity;
         if(dayPL <= -lim)
         {
            m_dayLossHit = true;
            ev |= FT_RISK_EV_DAYLOSS;
            if(m_cfg.persist)
               GlobalVariableSet(Gv("DAYBLOCK"), (double)(long)m_dayStart);
            Print(StringFormat("FT RISK[%s]: DAILY LOSS limit hit: closed %.2f + floating %.2f - test %.2f = %.2f <= -%.2f (%.2f%% of %.2f). No entries until the next server day.",
                               m_cfg.tag, m_closedToday, floating, m_synthLoss, dayPL, lim, m_cfg.maxDailyLossPct, m_dayStartEquity));
         }
      }
      //--- consecutive losses: spec = pause to the next server day; pause mode = pause consecPauseMin, then a new streak
      m_now = now;
      if(m_cfg.maxConsecLosses > 0 && m_consec >= m_cfg.maxConsecLosses)
      {
         if(m_cfg.consecPauseMin > 0)
         {
            m_pauseUntil    = now + (datetime)(m_cfg.consecPauseMin * 60);
            m_consecResetAt = now;
            ev |= FT_RISK_EV_CONSEC;
            Print("FT RISK[", m_cfg.tag, "]: ", m_consec, " consecutive losses (limit ", m_cfg.maxConsecLosses, ") - paused for ",
                  m_cfg.consecPauseMin, " min, until ", TimeToString(m_pauseUntil, TIME_DATE | TIME_MINUTES));
            m_consec = 0;
            if(m_cfg.persist)
            {
               GlobalVariableSet(Gv("PAUSE"), (double)(long)m_pauseUntil);
               GlobalVariableSet(Gv("CRESET"), (double)(long)m_consecResetAt);
            }
         }
         else if(!m_consecHit)
         {
            m_consecHit = true;
            ev |= FT_RISK_EV_CONSEC;
            Print("FT RISK[", m_cfg.tag, "]: ", m_consec, " consecutive losses (limit ", m_cfg.maxConsecLosses, ") - paused until the next server day");
         }
      }
      return ev;
   }

   //--- pause mode: a consecutive-loss pause is running at m_now
   bool         PauseActive(void) const { return (m_cfg.consecPauseMin > 0 && m_pauseUntil > 0 && m_now < m_pauseUntil); }

   //--- risk gates in the canonical order; pendingCount = live/virtual pending entries not yet filled
   void         Gates(const int pendingCount, string &reasons) const
   {
      if(m_cfg.maxTradesPerDay > 0 && m_tradesToday + pendingCount >= m_cfg.maxTradesPerDay)
         FTAddReason(reasons, "RISK_DAILY_TRADES");
      if(m_dayLossHit)
         FTAddReason(reasons, "RISK_DAILY_LOSS");
      if(ConsecBlocked())
         FTAddReason(reasons, "RISK_CONSEC_LOSSES");
      if(m_kill)
         FTAddReason(reasons, "RISK_KILL");
   }

   bool         ConsecBlocked(void) const
   {
      if(m_cfg.consecPauseMin > 0)
         return PauseActive() || (m_cfg.maxConsecLosses > 0 && m_consec >= m_cfg.maxConsecLosses);
      return m_consecHit || (m_cfg.maxConsecLosses > 0 && m_consec >= m_cfg.maxConsecLosses);
   }
   bool         KillActive(void) const    { return m_kill; }
   bool         EntriesBlocked(void) const
   {
      return m_kill || m_dayLossHit || ConsecBlocked();
   }
   int          TradesToday(void) const   { return m_tradesToday; }
   double       ClosedToday(void) const   { return m_closedToday; }
   int          ConsecLosses(void) const  { return m_consec; }
   double       DayStartEquity(void) const{ return m_dayStartEquity; }
   double       Peak(void) const          { return m_peak; }

   //+---------------------------------------------------------------+
   //| Sizing (03 §7). entry/sl are the spread-converted EXECUTION   |
   //| prices (long: ask fill, bid-triggered stop; short: bid fill,  |
   //| ask-triggered stop). Market order types only.                 |
   //|  code: "" | PLAN | RISK_MIN_LOT | RISK_MARGIN                 |
   //+---------------------------------------------------------------+
   bool         Size(const int dir, const double entry, const double sl, const double equity, const double freeMargin,
                     double &lots, double &riskMoney, double &riskTarget, double &lossPerLot, string &code, string &note) const
   {
      lots = 0.0;
      riskMoney = 0.0;
      lossPerLot = 0.0;
      code = "";
      note = "";
      riskTarget = m_cfg.riskPct / 100.0 * equity;
      if(riskTarget <= 0.0 || dir == 0)
      {
         code = "PLAN";
         note = "riskTarget<=0";
         return false;
      }
      ENUM_ORDER_TYPE t = (dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      double profit = 0.0;
      ResetLastError();
      if(!OrderCalcProfit(t, m_cfg.symbol, 1.0, entry, sl, profit))
      {
         code = "PLAN";
         note = StringFormat("OrderCalcProfit failed err=%d", GetLastError());
         return false;
      }
      if(profit >= 0.0)
      {
         code = "PLAN";
         note = StringFormat("stop on the wrong side (profit/lot %.2f)", profit);
         return false;
      }
      lossPerLot = MathAbs(profit);
      double step = SymbolInfoDouble(m_cfg.symbol, SYMBOL_VOLUME_STEP);
      double vmin = SymbolInfoDouble(m_cfg.symbol, SYMBOL_VOLUME_MIN);
      double vmax = SymbolInfoDouble(m_cfg.symbol, SYMBOL_VOLUME_MAX);
      double raw  = riskTarget / lossPerLot;
      lots = FTFloorStep(raw, step);
      if(vmax > 0.0 && lots > vmax)
         lots = FTFloorStep(vmax, step);
      if(lots < vmin - 1e-9)
      {
         if(!m_cfg.allowMinLot)
         {
            code = "RISK_MIN_LOT";
            note = StringFormat("lots %.4f < min %.4f (raw %.4f)", lots, vmin, raw);
            lots = 0.0;
            return false;
         }
         note = StringFormat("min lot forced: raw %.4f -> %.4f, risk %.2f%% of equity", raw, vmin, vmin * lossPerLot / equity * 100.0);
         lots = vmin;
      }
      lots = NormalizeDouble(lots, FTStepDigits(step));
      riskMoney = lossPerLot * lots;
      double margin = 0.0;
      ResetLastError();
      if(!OrderCalcMargin(t, m_cfg.symbol, lots, entry, margin))
      {
         code = "RISK_MARGIN";
         note = StringFormat("OrderCalcMargin failed err=%d", GetLastError());
         return false;
      }
      if(margin > freeMargin)
      {
         code = "RISK_MARGIN";
         note = StringFormat("margin %.2f > free margin %.2f", margin, freeMargin);
         return false;
      }
      return true;
   }
};
//+------------------------------------------------------------------+
