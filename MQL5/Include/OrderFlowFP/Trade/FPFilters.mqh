//+------------------------------------------------------------------+
//| FPFilters.mqh - CFPFilters: signal-time filters of 03 section 5    |
//| (data quality, session, Friday, spread, ATR min, ATR regime, HTF, |
//| news, position flag). API fixed by docs\EA_ARCHITECTURE.md 5.     |
//|                                                                   |
//| Reason codes ('|'-joined, every failing filter, in this order):   |
//| DATA_STATE|DATA_TICKS|DATA_SOURCE|SESSION|FRIDAY|SPREAD|ATR_MIN|  |
//| REGIME|HTF|NEWS|POSITION                                          |
//| Times are SERVER time. The signal-time check uses the decision    |
//| moment T + PeriodSeconds(tf) (= open of the bar after T), so the  |
//| result is deterministic and identical in the tester and live.    |
//+------------------------------------------------------------------+
#include "..\FPSignals.mqh"

#define FP_NEWS_REFRESH_OK_SEC    900   // calendar cache refresh after a successful query
#define FP_NEWS_REFRESH_FAIL_SEC  60    // retry delay after a failed query

class CFPFilters
{
private:
   CFPEngine        *m_engine;
   FPFilterConfig    m_cfg;
   bool              m_tester;
   double            m_point;
   int               m_period;
   string            m_ccy[];
   datetime          m_newsTimes[];
   datetime          m_newsTriedAt;
   datetime          m_newsLoadedAt;
   bool              m_newsOk;
   bool              m_newsFailLogged;

   static void       Add(string &reasons, const string code);
   static int        MinuteOfDay(const datetime t);
   bool              NewsActive(void) const { return (!m_tester && m_cfg.newsMin > 0); }
   void              EnsureNews(const datetime now);
   void              RefreshNews(const datetime now);
   bool              NewsBlocked(const datetime t);
   void              AddCurrency(const string c);
   double            CurrentSpread(void) const;

public:
                     CFPFilters(void);
                    ~CFPFilters(void) { Deinit(); }

   //--- EA_ARCHITECTURE section 5 API
   bool              Init(CFPEngine *engine, const FPFilterConfig &cfg);
   void              Deinit(void);
   bool              CheckSignal(const FPSignal &sig, CFPBar *bar, const FPContext &ctx, const bool positionBusy,
                                 string &reasons);
   bool              CheckLive(const datetime now, const double atr, string &reasons);
   void              OnTimer(void);
   void              StartupWarnings(void);

   //--- pure helpers (unit-tested in FPSignalTests)
   static void       DefaultConfig(FPFilterConfig &cfg);
   static bool       InTimeWindow(const int minuteOfDay, const int startMin, const int endMin);
   static bool       FridayBlocked(const datetime t, const int cutoffMin);
   static bool       SpreadOk(const double spreadPrice, const double spreadPts, const double atr,
                              const double maxSpreadATR, const int maxSpreadPts);
   static int        Staleness(const bool prevOfForming, const long lagSec, const int maxLagSec, const int maxLatePendingSec);
};

#define FP_BAR_ON_TIME       0   // evaluate normally
#define FP_BAR_LATE_PENDING  1   // evaluate; only untriggered pending entries may be placed
#define FP_BAR_STALE         2   // SKIPPED:LATE

//+------------------------------------------------------------------+
//| 03 s4 staleness guard + the late-pending extension. A bar that is |
//| not the one just before the forming bar (break, weekend, batched  |
//| bars) is always stale. Lag <= maxLagSec is on time. A larger lag  |
//| (feed stall, blocked CopyTicks) is LATE_PENDING while it is       |
//| <= maxLatePendingSec (0 = off), else stale.                       |
//+------------------------------------------------------------------+
int CFPFilters::Staleness(const bool prevOfForming, const long lagSec, const int maxLagSec, const int maxLatePendingSec)
{
   if(!prevOfForming)
      return FP_BAR_STALE;
   if(lagSec <= (long)maxLagSec)
      return FP_BAR_ON_TIME;
   if(maxLatePendingSec > maxLagSec && lagSec <= (long)maxLatePendingSec)
      return FP_BAR_LATE_PENDING;
   return FP_BAR_STALE;
}

//+------------------------------------------------------------------+
CFPFilters::CFPFilters(void)
{
   m_engine = NULL;
   m_tester = false;
   m_point = 0.0;
   m_period = 0;
   m_newsTriedAt = 0;
   m_newsLoadedAt = 0;
   m_newsOk = false;
   m_newsFailLogged = false;
   DefaultConfig(m_cfg);
}

void CFPFilters::DefaultConfig(FPFilterConfig &c)
{
   c.symbol = _Symbol;
   c.timeframe = (ENUM_TIMEFRAMES)Period();
   c.minTicksPerBar = 60;
   c.requireSource = FP_REQ_ANY;
   c.tradeStartMin = 8 * 60;
   c.tradeEndMin = 20 * 60;
   c.fridayCutoffMin = 18 * 60;
   c.maxSpreadPts = 0;
   c.maxSpreadATR = 0.15;
   c.minATRPts = 0.0;
   c.szrMinAtrRatio = 0.85;
   c.revMaxAtrRatio = 1.30;
   c.htf = PERIOD_H1;
   c.htfEma = 50;
   c.newsMin = 15;
   c.maxPositions = 1;
}

bool CFPFilters::Init(CFPEngine *engine, const FPFilterConfig &cfg)
{
   Deinit();
   m_engine = engine;
   m_cfg = cfg;
   if(m_cfg.symbol == "")
      m_cfg.symbol = _Symbol;
   if(m_cfg.timeframe == PERIOD_CURRENT)
      m_cfg.timeframe = (ENUM_TIMEFRAMES)Period();
   if(m_cfg.szrMinAtrRatio <= 0.0)
      m_cfg.szrMinAtrRatio = 0.85;
   if(m_cfg.revMaxAtrRatio <= 0.0)
      m_cfg.revMaxAtrRatio = 1.30;
   m_point = SymbolInfoDouble(m_cfg.symbol, SYMBOL_POINT);
   m_period = PeriodSeconds(m_cfg.timeframe);
   m_tester = (MQLInfoInteger(MQL_TESTER) != 0 || MQLInfoInteger(MQL_OPTIMIZATION) != 0);
   if(m_point <= 0.0 || m_period <= 0)
   {
      Print("CFPFilters: Init failed - no point size / period for ", m_cfg.symbol);
      return false;
   }
   ArrayResize(m_ccy, 0);
   AddCurrency(SymbolInfoString(m_cfg.symbol, SYMBOL_CURRENCY_BASE));
   AddCurrency(SymbolInfoString(m_cfg.symbol, SYMBOL_CURRENCY_PROFIT));
   AddCurrency(SymbolInfoString(m_cfg.symbol, SYMBOL_CURRENCY_MARGIN));
   if(m_tester && m_cfg.newsMin > 0)
      Print("CFPFilters: news filter disabled in the Strategy Tester (no calendar history; 03 section 5)");
   return true;
}

void CFPFilters::Deinit(void)
{
   m_engine = NULL;
   ArrayResize(m_newsTimes, 0);
   m_newsTriedAt = 0;
   m_newsLoadedAt = 0;
   m_newsOk = false;
   m_newsFailLogged = false;
}

void CFPFilters::AddCurrency(const string c)
{
   if(c == "")
      return;
   int n = ArraySize(m_ccy);
   for(int i = 0; i < n; i++)
      if(m_ccy[i] == c)
         return;
   ArrayResize(m_ccy, n + 1);
   m_ccy[n] = c;
}

void CFPFilters::Add(string &reasons, const string code)
{
   if(reasons != "")
      reasons += "|";
   reasons += code;
}

int CFPFilters::MinuteOfDay(const datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return dt.hour * 60 + dt.min;
}

//+------------------------------------------------------------------+
//| Session window [start, end) in minutes of the server day.         |
//| start > end wraps midnight (e.g. 22:00-02:00). start == end means |
//| the whole day. -1 (input "") = open edge (start 00:00 / end       |
//| 24:00). -2 (malformed) = window closed (conservative).            |
//+------------------------------------------------------------------+
bool CFPFilters::InTimeWindow(const int minuteOfDay, const int startMin, const int endMin)
{
   if(startMin == -2 || endMin == -2)
      return false;
   int s = (startMin < 0) ? 0 : startMin;
   int e = (endMin < 0) ? 1440 : endMin;
   if(s == e)
      return true;
   if(s < e)
      return (minuteOfDay >= s && minuteOfDay < e);
   return (minuteOfDay >= s || minuteOfDay < e);
}

// Friday at/after the cutoff; -1 = off; -2 (malformed) blocks the whole Friday (conservative)
bool CFPFilters::FridayBlocked(const datetime t, const int cutoffMin)
{
   if(cutoffMin == -1)
      return false;
   MqlDateTime dt;
   TimeToStruct(t, dt);
   if(dt.day_of_week != 5)
      return false;
   if(cutoffMin < 0)
      return true;
   return (dt.hour * 60 + dt.min >= cutoffMin);
}

// spread <= maxSpreadATR x ATR (unknown ATR fails; maxSpreadATR <= 0 = off) and, only if maxSpreadPts > 0, <= maxSpreadPts
bool CFPFilters::SpreadOk(const double spreadPrice, const double spreadPts, const double atr,
                          const double maxSpreadATR, const int maxSpreadPts)
{
   if(maxSpreadATR > 0.0)
   {
      if(atr <= 0.0)
         return false;
      if(spreadPrice > maxSpreadATR * atr)
         return false;
   }
   if(maxSpreadPts > 0 && spreadPts > (double)maxSpreadPts)
      return false;
   return true;
}

double CFPFilters::CurrentSpread(void) const
{
   MqlTick tk;
   if(SymbolInfoTick(m_cfg.symbol, tk) && tk.ask > 0.0 && tk.bid > 0.0)
      return MathMax(0.0, tk.ask - tk.bid);
   return (double)SymbolInfoInteger(m_cfg.symbol, SYMBOL_SPREAD) * m_point;
}

//+------------------------------------------------------------------+
//| News cache (live only). HIGH-importance values of the symbol's    |
//| currencies in [now-1d, now+3d], refreshed at most every 900 s     |
//| (60 s after a failure). Never queried per tick.                   |
//+------------------------------------------------------------------+
void CFPFilters::RefreshNews(const datetime now)
{
   m_newsTriedAt = now;
   datetime from = now - 86400;
   datetime to = now + 3 * 86400;
   datetime found[];
   int nf = 0;
   bool ok = true;
   string skipped = "";
   // a currency the calendar does not track (e.g. XAU) has no events; CalendarValueHistory
   // returns false with error 0 for it, so skip it up front instead of treating it as unreadable
   MqlCalendarCountry cty[];
   ResetLastError();
   int ncty = CalendarCountries(cty);
   if(ncty <= 0)
   {
      if(!m_newsFailLogged)
         Print("CFPFilters: CalendarCountries failed, error ", GetLastError(),
               " - entries blocked with NEWS until the calendar answers (set InpNewsMin=0 to disable)");
      m_newsFailLogged = true;
      m_newsOk = false;
      return;
   }
   int nc = ArraySize(m_ccy);
   for(int c = 0; c < nc; c++)
   {
      bool tracked = false;
      for(int k = 0; k < ncty && !tracked; k++)
         tracked = (cty[k].currency == m_ccy[c]);
      if(!tracked)
      {
         skipped += (skipped == "" ? "" : ",") + m_ccy[c];
         continue;
      }
      MqlCalendarValue vals[];
      ResetLastError();
      if(!CalendarValueHistory(vals, from, to, NULL, m_ccy[c]))
      {
         int err = GetLastError();
         if(err == ERR_CALENDAR_NO_DATA)
            continue;                                 // currency without calendar events (e.g. XAU)
         ok = false;
         if(!m_newsFailLogged)
            Print("CFPFilters: CalendarValueHistory(", m_ccy[c], ") failed, error ", err,
                  " - entries blocked with NEWS until the calendar answers (set InpNewsMin=0 to disable)");
         m_newsFailLogged = true;
         continue;
      }
      int nv = ArraySize(vals);
      for(int i = 0; i < nv; i++)
      {
         MqlCalendarEvent ev;
         if(!CalendarEventById(vals[i].event_id, ev))
            continue;
         if(ev.importance != CALENDAR_IMPORTANCE_HIGH)
            continue;
         ArrayResize(found, nf + 1, 64);
         found[nf] = vals[i].time;
         nf++;
      }
   }
   if(ok)
   {
      ArrayResize(m_newsTimes, nf);
      for(int i = 0; i < nf; i++)
         m_newsTimes[i] = found[i];
      m_newsLoadedAt = now;
      if(!m_newsOk)
         Print("CFPFilters: news calendar loaded - ", nf, " HIGH event(s) in [-1d, +3d]",
               (skipped != "" ? ", not in the calendar (skipped): " + skipped : ""));
      m_newsOk = true;
      m_newsFailLogged = false;
   }
   else
      m_newsOk = false;
}

void CFPFilters::EnsureNews(const datetime now)
{
   if(!NewsActive())
      return;
   int wait = m_newsOk ? FP_NEWS_REFRESH_OK_SEC : FP_NEWS_REFRESH_FAIL_SEC;
   if(m_newsTriedAt == 0 || now - m_newsTriedAt >= wait || now < m_newsTriedAt)
      RefreshNews(now);
}

// true = an entry at t is blocked (a HIGH event within +-newsMin, or the calendar could not be read)
bool CFPFilters::NewsBlocked(const datetime t)
{
   if(!NewsActive())
      return false;
   EnsureNews(TimeTradeServer());
   if(!m_newsOk)
      return true;
   long win = (long)m_cfg.newsMin * 60;
   int n = ArraySize(m_newsTimes);
   for(int i = 0; i < n; i++)
   {
      long d = (long)m_newsTimes[i] - (long)t;
      if(d <= win && d >= -win)
         return true;
   }
   return false;
}

void CFPFilters::OnTimer(void)
{
   EnsureNews(TimeTradeServer());
}

//+------------------------------------------------------------------+
//| All signal-time filters. Returns true when every filter passes.   |
//+------------------------------------------------------------------+
bool CFPFilters::CheckSignal(const FPSignal &sig, CFPBar *bar, const FPContext &ctx, const bool positionBusy,
                             string &reasons)
{
   reasons = "";
   bool barOk = (CheckPointer(bar) != POINTER_INVALID);
   //--- data quality
   if(!barOk || bar.state != 0 || !bar.closed)
      Add(reasons, "DATA_STATE");
   if(m_cfg.minTicksPerBar > 0 && (!barOk || bar.ticks < m_cfg.minTicksPerBar))
      Add(reasons, "DATA_TICKS");
   ENUM_FP_SOURCE src = (CheckPointer(m_engine) != POINTER_INVALID) ? m_engine.ActiveSource() : ctx.source;
   if(m_cfg.requireSource == FP_REQ_EXCHANGE_ONLY && src != FP_SRC_EXCHANGE_FLAGS)
      Add(reasons, "DATA_SOURCE");
   //--- session / Friday at the decision moment (open of the bar after T)
   datetime t = sig.barTime + m_period;
   if(!InTimeWindow(MinuteOfDay(t), m_cfg.tradeStartMin, m_cfg.tradeEndMin))
      Add(reasons, "SESSION");
   if(FridayBlocked(t, m_cfg.fridayCutoffMin))
      Add(reasons, "FRIDAY");
   //--- spread at signal time (from the context)
   if(!SpreadOk(ctx.spreadPrice, ctx.spreadPts, ctx.atr, m_cfg.maxSpreadATR, m_cfg.maxSpreadPts))
      Add(reasons, "SPREAD");
   //--- volatility
   if(ctx.atr <= 0.0 || (m_cfg.minATRPts > 0.0 && ctx.atr / m_point < m_cfg.minATRPts))
      Add(reasons, "ATR_MIN");
   bool regimeOk = (ctx.atrRatio > 0.0);
   if(regimeOk)
   {
      if(sig.type == FP_SIG_ZONE_RETEST)
         regimeOk = (ctx.atrRatio >= m_cfg.szrMinAtrRatio);
      else
         regimeOk = (ctx.atrRatio <= m_cfg.revMaxAtrRatio);   // ABS / EXH / standalone DIV (reversals)
   }
   if(!regimeOk)
      Add(reasons, "REGIME");
   //--- HTF trend: hard for SZR only (ABS/EXH score it in the grade)
   if(sig.type == FP_SIG_ZONE_RETEST && ctx.htfBias != sig.dir)
      Add(reasons, "HTF");
   //--- news (live only)
   if(NewsBlocked(t))
      Add(reasons, "NEWS");
   //--- position (computed by the trade layer)
   if(positionBusy)
      Add(reasons, "POSITION");
   return (reasons == "");
}

//+------------------------------------------------------------------+
//| Re-check while a pending order is alive (every tick): session     |
//| (incl. the Friday cutoff), spread, news. Reads only the cache.    |
//+------------------------------------------------------------------+
bool CFPFilters::CheckLive(const datetime now, const double atr, string &reasons)
{
   reasons = "";
   if(!InTimeWindow(MinuteOfDay(now), m_cfg.tradeStartMin, m_cfg.tradeEndMin))
      Add(reasons, "SESSION");
   if(FridayBlocked(now, m_cfg.fridayCutoffMin))
      Add(reasons, "FRIDAY");
   double sp = CurrentSpread();
   if(!SpreadOk(sp, sp / m_point, atr, m_cfg.maxSpreadATR, m_cfg.maxSpreadPts))
      Add(reasons, "SPREAD");
   if(NewsBlocked(now))
      Add(reasons, "NEWS");
   return (reasons == "");
}

void CFPFilters::StartupWarnings(void)
{
   ENUM_FP_SOURCE src = (CheckPointer(m_engine) != POINTER_INVALID) ? m_engine.ActiveSource() : FP_SRC_AUTO;
   if(src == FP_SRC_QUOTE_TICKS)
      Print("CFPFilters: WARNING source=QUOTE_TICKS - volumes are tick counts (relative activity), delta and ",
            "imbalances derive from the mid-price path. Validate against InpPlaceboPriceOnly=true (03 section 11.10) ",
            "before trading.");
   if(src == FP_SRC_AUTO)
      Print("CFPFilters: source not decided yet - call StartupWarnings() again after HistoryReady()");
   if(m_cfg.requireSource == FP_REQ_EXCHANGE_ONLY && src != FP_SRC_EXCHANGE_FLAGS && src != FP_SRC_AUTO)
      Print("CFPFilters: WARNING InpRequireSource=EXCHANGE_ONLY but source is not EXCHANGE_FLAGS - every signal ",
            "will be FILTERED:DATA_SOURCE");
   if(m_cfg.tradeStartMin == -2 || m_cfg.tradeEndMin == -2)
      Print("CFPFilters: WARNING malformed InpTradeStart/InpTradeEnd - every signal will be FILTERED:SESSION");
   if(m_cfg.fridayCutoffMin == -2)
      Print("CFPFilters: WARNING malformed InpFridayCutoff - all of Friday is blocked");
   if(m_cfg.newsMin > 0 && !m_tester)
      Print("CFPFilters: news filter +-", m_cfg.newsMin, " min on HIGH events, currencies: ",
            (ArraySize(m_ccy) > 0 ? m_ccy[0] : "-"), (ArraySize(m_ccy) > 1 ? "," + m_ccy[1] : ""),
            (ArraySize(m_ccy) > 2 ? "," + m_ccy[2] : ""));
}
//+------------------------------------------------------------------+
