//+------------------------------------------------------------------+
//| FPSignals.mqh - CFPSignals: setup detectors, grading, context     |
//|   03 s4 (as-of rule, SZR, ABS/EXH, DIV), s6 (grading),            |
//|   s11.10 (placebo). API fixed by docs\EA_ARCHITECTURE.md s5.      |
//|                                                                   |
//| AS-OF RULE: Evaluate(T)/BuildContext(T) use only bars with        |
//| time <= T, reached by engine.ByTime(T) + engine.PrevBarTime()     |
//| walking. At() is never called. Zone state is reconstructed as of  |
//| T from filledTime / lastTouchTime. Indicator values are read for  |
//| the bar T itself (chart TF; == shift 1 when T is the last closed  |
//| bar) and for the last HTF bar fully closed at T's close (== HTF   |
//| shift 1 live). Evaluate is stateless: the same T always gives the |
//| same signals (except the spread, which is read at call time).     |
//+------------------------------------------------------------------+
#include "FPSignalTypes.mqh"

#define FP_SZR_RETEST_DPCT  0.10     // s6: retest-bar delta% >= +0.10 (fixed by the spec)
#define FP_DIV_CONF_BARS    3        // s4.3: DIV confluence window [T-3 bars, T]
#define FP_WALK_LIMIT       20000    // hard bound for every PrevBarTime walk
#define FP_PX_EPS           1e-8     // absorbs float noise in price comparisons (far below one point)

//+------------------------------------------------------------------+
//| Input of the pure divergence detector (oldest bar first)          |
//+------------------------------------------------------------------+
struct FPDivBar
{
   datetime time;
   double   high;
   double   low;
   double   delta;
   double   cumDelta;
   datetime sessionStart;   // engine.SessionStart(time)
   bool     cvdValid;
   bool     ok;             // usable bar: closed, state 0, rows > 0
};

//+------------------------------------------------------------------+
class CFPSignals
{
private:
   CFPEngine        *m_engine;
   FPSignalConfig    m_cfg;
   int               m_hATR;
   int               m_hEMA;
   FPContext         m_ctx;
   bool              m_haveCtx;
   double            m_point;
   int               m_digits;
   int               m_period;

   static bool       PrepM(double &m[]);
   static bool       BarUsable(CFPBar *bar);
   static double     CloseFrac(CFPBar *bar, const int dir);
   static void       Normalize(FPSignalConfig &c);

   int               CollectBack(const datetime T, const int maxCount, datetime &times[]);
   bool              AtrAt(const datetime t, double &atr);
   bool              ReadAtrContext(const datetime T, FPContext &ctx);
   void              ReadHtf(const datetime T, FPContext &ctx);
   void              ReadPrevDay(const datetime T, FPContext &ctx);
   void              ReadSpread(FPContext &ctx);
   void              BuildProfiles(const datetime T, const double closeT, FPContext &ctx);
   void              FillProfile(const datetime &times[], const int n, FPProfile &p);
   double            PriorSma(const datetime T, const int len, const bool useRange);
   double            Px(const double v) const { return NormalizeDouble(v, m_digits); }
   double            StopBuffer(void) const;
   int               BuildDivWindow(const datetime &times[], const int nWin, FPDivBar &w[]);
   bool              DivNear(const FPDivBar &w[], const int nw, const int dir, const int maxBack, string &where);
   void              PushBest(FPSignal &best[], bool &have[], const FPSignal &s);
   void              EvalSZR(const datetime T, CFPBar *bar, const datetime &times[], const int nWin, FPSignal &out[]);
   void              EvalSZRPlacebo(const datetime T, CFPBar *bar, const datetime &times[], const int nWin, FPSignal &out[]);
   bool              MakeSZRSignal(const FPZone &z, CFPBar *origin, CFPBar *bar, const datetime T, const bool limit,
                                   const int age, const int touchesBefore, FPSignal &s);
   void              EvalRev(const datetime T, CFPBar *bar, const int dir, const datetime &times[], const int nWin,
                             const FPDivBar &w[], const int nw, FPSignal &out[]);
   void              EvalDivStandalone(const datetime T, CFPBar *bar, const int dir, const FPDivBar &w[], const int nw,
                                       FPSignal &out[]);
   void              SortSignals(FPSignal &a[]);
   static bool       Better(const FPSignal &a, const FPSignal &b);
   static void       Append(FPSignal &out[], const FPSignal &s);

public:
                     CFPSignals(void);
                    ~CFPSignals(void) { Deinit(); }

   //--- EA_ARCHITECTURE s5 API
   bool              Init(CFPEngine *engine, const FPSignalConfig &cfg);
   void              Deinit(void);
   bool              IndicatorsReady(void);
   int               Evaluate(const datetime closedBarTime, FPSignal &out[]);
   bool              LastContext(FPContext &ctx) const;
   bool              BuildContext(const datetime closedBarTime, FPContext &ctx);
   static bool       DetectAbsorption(CFPBar *bar, const int dir, const FPSignalConfig &cfg, double &m[]);
   static bool       DetectExhaustion(CFPBar *bar, const int dir, const FPSignalConfig &cfg, double &m[]);
   static bool       ZoneQualifies(const FPZone &z, CFPBar *originBar, const double atr, const FPSignalConfig &cfg);
   static bool       DetectDivergence(const FPDivBar &b[], const int count, const int dir, const int pivot,
                                      const int maxBars, int &p1, int &p2);

   //--- additional pure helpers (unit-tested in FPSignalTests)
   static void       DefaultConfig(FPSignalConfig &cfg);
   static bool       IsPivot(const FPDivBar &b[], const int count, const int i, const int dir, const int strength);
   static bool       LocationOK(const double extreme, const double &prior[], const int dir);
   static bool       ZoneOpenAsOf(const FPZone &z, const datetime T);
   static int        ZoneTouchesBefore(const FPZone &z, const datetime T);
   static bool       SzrRetest(const FPZone &z, CFPBar *bar, const bool placebo);
   static bool       StackHasTier(const FPZone &z, CFPBar *originBar, const int minTier);
   static bool       ExtremeImbalance(CFPBar *bar, const int dir, const int k, const int minTier);
   static ENUM_FP_SIGNAL ResolveRevType(const bool absorption, const bool exhaustion);
   static int        GradeFromPoints(const int points);
   static bool       NearAnyLevel(const double lo, const double hi, const double &levels[], const double tol);
   static bool       DetectAbsorptionPlacebo(CFPBar *bar, const int dir, const FPSignalConfig &cfg, double &m[]);
   static bool       DetectExhaustionPlacebo(CFPBar *bar, const int dir, const FPSignalConfig &cfg, double &m[]);
   static bool       PlaceboZone(CFPBar *originBar, const int dir, const long openRow, const double rowSize,
                                 const double atr, const FPSignalConfig &cfg, FPZone &z);
};

//+------------------------------------------------------------------+
//| Pure helpers                                                      |
//+------------------------------------------------------------------+
bool CFPSignals::PrepM(double &m[])
{
   int n = ArraySize(m);
   if(n >= FP_M_COUNT)
      return true;
   if(ArrayResize(m, FP_M_COUNT) != FP_M_COUNT)
      return false;
   for(int i = n; i < FP_M_COUNT; i++)
      m[i] = 0.0;
   return true;
}

bool CFPSignals::BarUsable(CFPBar *bar)
{
   if(CheckPointer(bar) == POINTER_INVALID)
      return false;
   if(bar.rows <= 0)
      return false;
   if(ArraySize(bar.sellVol) < bar.rows || ArraySize(bar.buyVol) < bar.rows)
      return false;
   return true;
}

// close location in the signal direction, 0..1 (long: (close-low)/(high-low); short: (high-close)/(high-low))
double CFPSignals::CloseFrac(CFPBar *bar, const int dir)
{
   double range = bar.high - bar.low;
   if(range <= 0.0)
      return 0.0;
   return (dir > 0) ? (bar.close - bar.low) / range : (bar.high - bar.close) / range;
}

void CFPSignals::DefaultConfig(FPSignalConfig &c)
{
   c.symbol = _Symbol;
   c.timeframe = (ENUM_TIMEFRAMES)Period();
   c.szrEnable = true;
   c.szrEntry = FP_SZR_CONFIRM_CLOSE;
   c.szrMinRows = 3;
   c.szrMinTier = 2;
   c.szrMinDeltaPct = 0.10;
   c.szrMaxHeightATR = 0.6;
   c.szrMaxAgeBars = 30;
   c.szrMaxTouches = 1;
   c.revEnable = true;
   c.revLookback = 20;
   c.revRows = 3;
   c.absSellShare = 0.60;
   c.absConcentration = 1.5;
   c.absCloseFrac = 0.50;
   c.exhMaxPct = 0.03;
   c.revMinVolMult = 1.0;
   c.revEntryOffsetPts = 0;
   c.revValidBars = 2;
   c.levelTolATR = 0.25;
   c.divPivot = 3;
   c.divMaxBars = 30;
   c.divStandalone = false;
   c.minGrade = FP_GRADE_B;
   c.slBufferATR = 0.10;
   c.placeboPriceOnly = false;
   c.htf = PERIOD_H1;
   c.htfEma = 50;
   c.atrPeriod = 14;
   c.atrBaseLen = 50;
   c.atrTrend = 1.15;
   c.atrChop = 0.85;
   c.volSmaLen = 20;
   c.exhCloseFrac = 0.40;
   c.valueAreaPct = 0.70;
   c.placeboWickFrac = 0.40;
   c.placeboSzrBodyATR = 0.60;
}

// fills the spec constants / signals-agent additions that the caller left at 0
void CFPSignals::Normalize(FPSignalConfig &c)
{
   if(c.symbol == "")
      c.symbol = _Symbol;
   if(c.timeframe == PERIOD_CURRENT)
      c.timeframe = (ENUM_TIMEFRAMES)Period();
   if(c.htf == PERIOD_CURRENT)
      c.htf = PERIOD_H1;
   if(c.htfEma <= 0)
      c.htfEma = 50;
   if(c.atrPeriod <= 0)
      c.atrPeriod = 14;
   if(c.atrBaseLen <= 0)
      c.atrBaseLen = 50;
   if(c.atrTrend <= 0.0)
      c.atrTrend = 1.15;
   if(c.atrChop <= 0.0)
      c.atrChop = 0.85;
   if(c.volSmaLen <= 0)
      c.volSmaLen = 20;
   if(c.exhCloseFrac <= 0.0)
      c.exhCloseFrac = 0.40;
   if(c.valueAreaPct <= 0.0 || c.valueAreaPct > 1.0)
      c.valueAreaPct = 0.70;
   if(c.placeboWickFrac <= 0.0)
      c.placeboWickFrac = 0.40;
   if(c.placeboSzrBodyATR <= 0.0)
      c.placeboSzrBodyATR = 0.60;
   if(c.divPivot < 1)
      c.divPivot = 1;
   if(c.divMaxBars < 1)
      c.divMaxBars = 1;
   if(c.revLookback < 1)
      c.revLookback = 1;
   if(c.revValidBars < 1)
      c.revValidBars = 1;
   if(c.szrMaxAgeBars < 1)
      c.szrMaxAgeBars = 1;
}

int CFPSignals::GradeFromPoints(const int points)
{
   if(points >= 4)
      return FP_GRADE_A;
   if(points == 3)
      return FP_GRADE_B;
   return FP_GRADE_C;
}

ENUM_FP_SIGNAL CFPSignals::ResolveRevType(const bool absorption, const bool exhaustion)
{
   if(absorption)
      return FP_SIG_ABSORPTION;          // ABS and EXH both true -> ONE signal of type ABS (s4.2)
   if(exhaustion)
      return FP_SIG_EXHAUSTION;
   return FP_SIG_NONE;
}

//+------------------------------------------------------------------+
//| s4.2 Absorption. m[FP_M_VOLSMA] is an INPUT: SMA(bar volume,      |
//| volSmaLen) of the bars BEFORE the signal bar (0 = unknown -> the  |
//| volume test fails). Outputs SHARE, CONC, CLOSEFRAC, VOLMULT.      |
//| Shape rows >= 2k+1 is checked here; location is not (it needs     |
//| the prior bars: see LocationOK).                                  |
//+------------------------------------------------------------------+
bool CFPSignals::DetectAbsorption(CFPBar *bar, const int dir, const FPSignalConfig &cfg, double &m[])
{
   if(!PrepM(m))
      return false;
   m[FP_M_SHARE] = 0.0;
   m[FP_M_CONC] = 0.0;
   m[FP_M_CLOSEFRAC] = 0.0;
   m[FP_M_VOLMULT] = 0.0;
   if(!BarUsable(bar) || (dir != 1 && dir != -1))
      return false;
   int k = cfg.revRows;
   int n = bar.rows;
   if(k < 1 || n < 2 * k + 1)
      return false;
   if(bar.high - bar.low <= 0.0 || bar.volume <= 0.0)
      return false;
   double side = 0.0, tot = 0.0;
   for(int j = 0; j < k; j++)
   {
      int i = (dir > 0) ? j : n - 1 - j;
      tot += bar.sellVol[i] + bar.buyVol[i];
      side += (dir > 0) ? bar.sellVol[i] : bar.buyVol[i];
   }
   double avgRow = bar.volume / (double)n;
   double share = (tot > 0.0) ? side / tot : 0.0;
   double conc = (avgRow > 0.0) ? tot / ((double)k * avgRow) : 0.0;
   double cf = CloseFrac(bar, dir);
   double vs = m[FP_M_VOLSMA];
   m[FP_M_SHARE] = share;
   m[FP_M_CONC] = conc;
   m[FP_M_CLOSEFRAC] = cf;
   m[FP_M_VOLMULT] = (vs > 0.0) ? bar.volume / vs : 0.0;
   if(tot <= 0.0)
      return false;
   bool volOk = (cfg.revMinVolMult <= 0.0) || (vs > 0.0 && bar.volume >= cfg.revMinVolMult * vs);
   return (share >= cfg.absSellShare && conc >= cfg.absConcentration && cf >= cfg.absCloseFrac && volOk);
}

//+------------------------------------------------------------------+
//| s4.2 Exhaustion (no volume condition in the spec).                |
//| Long: lowest row volume <= exhMaxPct*volume, sell[0]<sell[1]<     |
//| sell[2], closeFrac >= exhCloseFrac (0.40). Short mirrors on the   |
//| top rows with buy volume. Outputs EXHPCT, CLOSEFRAC.              |
//+------------------------------------------------------------------+
bool CFPSignals::DetectExhaustion(CFPBar *bar, const int dir, const FPSignalConfig &cfg, double &m[])
{
   if(!PrepM(m))
      return false;
   m[FP_M_EXHPCT] = 0.0;
   m[FP_M_CLOSEFRAC] = 0.0;
   if(!BarUsable(bar) || (dir != 1 && dir != -1))
      return false;
   int k = cfg.revRows;
   int n = bar.rows;
   if(k < 1 || n < 2 * k + 1 || n < 3)
      return false;
   if(bar.high - bar.low <= 0.0 || bar.volume <= 0.0)
      return false;
   int e0 = (dir > 0) ? 0 : n - 1;
   int e1 = (dir > 0) ? 1 : n - 2;
   int e2 = (dir > 0) ? 2 : n - 3;
   double extPct = (bar.sellVol[e0] + bar.buyVol[e0]) / bar.volume;
   double cf = CloseFrac(bar, dir);
   m[FP_M_EXHPCT] = extPct;
   m[FP_M_CLOSEFRAC] = cf;
   bool increasing = (dir > 0) ? (bar.sellVol[e0] < bar.sellVol[e1] && bar.sellVol[e1] < bar.sellVol[e2])
                               : (bar.buyVol[e0] < bar.buyVol[e1] && bar.buyVol[e1] < bar.buyVol[e2]);
   double minCf = (cfg.exhCloseFrac > 0.0) ? cfg.exhCloseFrac : 0.40;
   return (extPct <= cfg.exhMaxPct && increasing && cf >= minCf);
}

//+------------------------------------------------------------------+
//| Stack rows by INDEX (rowFrom - originBar.rowLow ...), never by    |
//| price matching. True if any stacked row has tier >= minTier.      |
//+------------------------------------------------------------------+
bool CFPSignals::StackHasTier(const FPZone &z, CFPBar *originBar, const int minTier)
{
   if(!BarUsable(originBar))
      return false;
   int iFrom = (int)(z.rowFrom - originBar.rowLow);
   int iTo = (int)(z.rowTo - originBar.rowLow);
   if(iFrom < 0 || iTo >= originBar.rows || iFrom > iTo)
      return false;
   if(z.dir > 0 && ArraySize(originBar.imbBuy) < originBar.rows)
      return false;
   if(z.dir < 0 && ArraySize(originBar.imbSell) < originBar.rows)
      return false;
   for(int i = iFrom; i <= iTo; i++)
   {
      int tier = (z.dir > 0) ? (int)originBar.imbBuy[i] : (int)originBar.imbSell[i];
      if(tier >= minTier)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| s4.1 Zone qualification, judged on the ORIGIN bar with the ATR of |
//| the origin bar.                                                   |
//+------------------------------------------------------------------+
bool CFPSignals::ZoneQualifies(const FPZone &z, CFPBar *originBar, const double atr, const FPSignalConfig &cfg)
{
   if(!BarUsable(originBar))
      return false;
   if(z.dir != 1 && z.dir != -1)
      return false;
   if(z.originTime != originBar.time)
      return false;
   //--- 1. rows
   if(z.rowsCount < cfg.szrMinRows)
      return false;
   //--- 2. origin-bar delta%
   if(originBar.volume <= 0.0)
      return false;
   double dp = originBar.delta / originBar.volume;
   if(z.dir > 0 && dp < cfg.szrMinDeltaPct)
      return false;
   if(z.dir < 0 && dp > -cfg.szrMinDeltaPct)
      return false;
   //--- 3. close beyond the zone in the stack direction
   if(z.dir > 0 && originBar.close < z.priceHigh - FP_PX_EPS)
      return false;
   if(z.dir < 0 && originBar.close > z.priceLow + FP_PX_EPS)
      return false;
   //--- 4. height vs ATR(origin)
   if(atr <= 0.0 || (z.priceHigh - z.priceLow) > cfg.szrMaxHeightATR * atr + FP_PX_EPS)
      return false;
   //--- 5. a stacked row with tier >= szrMinTier (by index)
   return StackHasTier(z, originBar, cfg.szrMinTier);
}

// as-of T: the zone exists (origin <= T) and is not filled by T or earlier
bool CFPSignals::ZoneOpenAsOf(const FPZone &z, const datetime T)
{
   if(z.originTime > T)
      return false;
   return (z.filledTime == 0 || z.filledTime > T);
}

// touches strictly before T; -1 if it cannot be reconstructed (a touch AFTER T was already counted)
int CFPSignals::ZoneTouchesBefore(const FPZone &z, const datetime T)
{
   if(z.lastTouchTime > T)
      return -1;
   return z.touches - ((z.lastTouchTime == T) ? 1 : 0);
}

//+------------------------------------------------------------------+
//| s4.1 retest-bar conditions. BUY: low <= priceHigh (entered),      |
//| low >= priceLow (not filled), close >= mid, delta >= 0. Placebo:  |
//| the delta test becomes close >= open. SELL mirrors.               |
//+------------------------------------------------------------------+
bool CFPSignals::SzrRetest(const FPZone &z, CFPBar *bar, const bool placebo)
{
   if(CheckPointer(bar) == POINTER_INVALID)
      return false;
   double mid = (z.priceLow + z.priceHigh) * 0.5;
   if(z.dir > 0)
   {
      if(bar.low > z.priceHigh + FP_PX_EPS || bar.low < z.priceLow - FP_PX_EPS)
         return false;
      if(bar.close < mid - FP_PX_EPS)
         return false;
      return placebo ? (bar.close >= bar.open) : (bar.delta >= 0.0);
   }
   if(z.dir < 0)
   {
      if(bar.high < z.priceLow - FP_PX_EPS || bar.high > z.priceHigh + FP_PX_EPS)
         return false;
      if(bar.close > mid + FP_PX_EPS)
         return false;
      return placebo ? (bar.close <= bar.open) : (bar.delta <= 0.0);
   }
   return false;
}

// s6 ABS/EXH item: long -> a SELL imbalance tier >= minTier in the bottom k rows; short -> BUY imbalance in the top k
bool CFPSignals::ExtremeImbalance(CFPBar *bar, const int dir, const int k, const int minTier)
{
   if(!BarUsable(bar) || k < 1)
      return false;
   int n = bar.rows;
   if(ArraySize(bar.imbSell) < n || ArraySize(bar.imbBuy) < n)
      return false;
   int kk = MathMin(k, n);
   for(int j = 0; j < kk; j++)
   {
      int tier = (dir > 0) ? (int)bar.imbSell[j] : (int)bar.imbBuy[n - 1 - j];
      if(tier >= minTier)
         return true;
   }
   return false;
}

// s4.2 location: long -> extreme(low) <= min(prior lows); short -> extreme(high) >= max(prior highs).
// prior[] holds exactly the InpRevLookback bars BEFORE the signal bar (the signal bar is excluded).
bool CFPSignals::LocationOK(const double extreme, const double &prior[], const int dir)
{
   int n = ArraySize(prior);
   if(n < 1 || (dir != 1 && dir != -1))
      return false;
   for(int i = 0; i < n; i++)
   {
      if(dir > 0 && extreme > prior[i] + FP_PX_EPS)
         return false;
      if(dir < 0 && extreme < prior[i] - FP_PX_EPS)
         return false;
   }
   return true;
}

// true if the interval [lo,hi] lies within tol of any non-zero level
bool CFPSignals::NearAnyLevel(const double lo, const double hi, const double &levels[], const double tol)
{
   if(tol < 0.0)
      return false;
   int n = ArraySize(levels);
   for(int i = 0; i < n; i++)
   {
      double L = levels[i];
      if(L <= 0.0)
         continue;
      double d = 0.0;
      if(L > hi)
         d = L - hi;
      else
         if(L < lo)
            d = lo - L;
      if(d <= tol + FP_PX_EPS)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Pivot of strength s at index i (b[] oldest first, count bars):    |
//| dir=-1 pivot HIGH: high[i] > high[i+-j] for j=1..s (strict);      |
//| dir=+1 pivot LOW : low[i]  < low[i+-j]. Every bar of the window   |
//| must be ok. Needs i+s <= count-1: a pivot is only known s bars    |
//| later.                                                            |
//+------------------------------------------------------------------+
bool CFPSignals::IsPivot(const FPDivBar &b[], const int count, const int i, const int dir, const int strength)
{
   int s = strength;
   if(s < 1 || i - s < 0 || i + s > count - 1 || count > ArraySize(b))
      return false;
   for(int j = i - s; j <= i + s; j++)
      if(!b[j].ok)
         return false;
   for(int j = 1; j <= s; j++)
   {
      if(dir < 0)
      {
         if(!(b[i].high > b[i - j].high && b[i].high > b[i + j].high))
            return false;
      }
      else
      {
         if(!(b[i].low < b[i - j].low && b[i].low < b[i + j].low))
            return false;
      }
   }
   return true;
}

//+------------------------------------------------------------------+
//| s4.3 divergence CONFIRMED AT the last bar (index count-1).        |
//| P2 = count-1-pivot must be a pivot (it is confirmed exactly now). |
//| P1 = the NEAREST earlier pivot of the same kind with P2-P1 <=     |
//| maxBars. Bearish (dir=-1): high[P2] > high[P1] and (CVD[P2] <=    |
//| CVD[P1] when both bars share the session and have cvdValid, or    |
//| delta[P2] < 0). Bullish mirrors. Different sessions / invalid CVD |
//| -> only the bar-delta condition. Returns p1/p2 indices.           |
//+------------------------------------------------------------------+
bool CFPSignals::DetectDivergence(const FPDivBar &b[], const int count, const int dir, const int pivot,
                                  const int maxBars, int &p1, int &p2)
{
   p1 = -1;
   p2 = -1;
   if((dir != 1 && dir != -1) || pivot < 1 || maxBars < 1 || count > ArraySize(b))
      return false;
   int c = count - 1 - pivot;
   if(!IsPivot(b, count, c, dir, pivot))
      return false;
   int found = -1;
   int lim = MathMax(pivot, c - maxBars);
   for(int p = c - 1; p >= lim; p--)
   {
      if(IsPivot(b, count, p, dir, pivot))
      {
         found = p;
         break;
      }
   }
   if(found < 0)
      return false;
   bool cvdComparable = (b[c].sessionStart == b[found].sessionStart && b[c].cvdValid && b[found].cvdValid);
   bool div = false;
   if(dir < 0)
   {
      if(!(b[c].high > b[found].high))
         return false;
      div = (cvdComparable && b[c].cumDelta <= b[found].cumDelta) || (b[c].delta < 0.0);
   }
   else
   {
      if(!(b[c].low < b[found].low))
         return false;
      div = (cvdComparable && b[c].cumDelta >= b[found].cumDelta) || (b[c].delta > 0.0);
   }
   if(!div)
      return false;
   p1 = found;
   p2 = c;
   return true;
}

//+------------------------------------------------------------------+
//| PLACEBO (s11.10) price-only analogues. Every order-flow test is   |
//| removed; the price analogues keep a comparable selectivity.       |
//| ABS': shape rows >= 2k+1, rejection wick >= placeboWickFrac,      |
//|       closeFrac >= absCloseFrac, range >= revMinVolMult x         |
//|       SMA(range) (m[FP_M_RANGESMA] IN; 0 -> fails).               |
//| EXH': shape, closeFrac >= exhCloseFrac, body in the signal        |
//|       direction (close > open long).                              |
//+------------------------------------------------------------------+
bool CFPSignals::DetectAbsorptionPlacebo(CFPBar *bar, const int dir, const FPSignalConfig &cfg, double &m[])
{
   if(!PrepM(m))
      return false;
   m[FP_M_WICK] = 0.0;
   m[FP_M_CLOSEFRAC] = 0.0;
   if(CheckPointer(bar) == POINTER_INVALID || (dir != 1 && dir != -1))
      return false;
   int k = cfg.revRows;
   if(k < 1 || bar.rows < 2 * k + 1)
      return false;
   double range = bar.high - bar.low;
   if(range <= 0.0)
      return false;
   double wick = (dir > 0) ? (MathMin(bar.open, bar.close) - bar.low) / range
                           : (bar.high - MathMax(bar.open, bar.close)) / range;
   double cf = CloseFrac(bar, dir);
   double rs = m[FP_M_RANGESMA];
   m[FP_M_WICK] = wick;
   m[FP_M_CLOSEFRAC] = cf;
   double wmin = (cfg.placeboWickFrac > 0.0) ? cfg.placeboWickFrac : 0.40;
   bool rangeOk = (cfg.revMinVolMult <= 0.0) || (rs > 0.0 && range >= cfg.revMinVolMult * rs);
   return (wick >= wmin && cf >= cfg.absCloseFrac && rangeOk);
}

bool CFPSignals::DetectExhaustionPlacebo(CFPBar *bar, const int dir, const FPSignalConfig &cfg, double &m[])
{
   if(!PrepM(m))
      return false;
   m[FP_M_CLOSEFRAC] = 0.0;
   if(CheckPointer(bar) == POINTER_INVALID || (dir != 1 && dir != -1))
      return false;
   int k = cfg.revRows;
   if(k < 1 || bar.rows < 2 * k + 1)
      return false;
   if(bar.high - bar.low <= 0.0)
      return false;
   double cf = CloseFrac(bar, dir);
   m[FP_M_CLOSEFRAC] = cf;
   double minCf = (cfg.exhCloseFrac > 0.0) ? cfg.exhCloseFrac : 0.40;
   bool body = (dir > 0) ? (bar.close > bar.open) : (bar.close < bar.open);
   return (cf >= minCf && body);
}

//+------------------------------------------------------------------+
//| PLACEBO SZR zone: the szrMinRows rows at the BASE of an impulse   |
//| bar (BUY: rows openRow..openRow+minRows-1; SELL: openRow-minRows  |
//| +1..openRow). Price-only qualification: body >= placeboSzrBodyATR |
//| x ATR(origin) [replaces delta% + tier], close beyond the zone and |
//| height <= szrMaxHeightATR x ATR [kept]. openRow is the absolute   |
//| row of originBar.open (engine.PriceToRow).                        |
//+------------------------------------------------------------------+
bool CFPSignals::PlaceboZone(CFPBar *originBar, const int dir, const long openRow, const double rowSize,
                             const double atr, const FPSignalConfig &cfg, FPZone &z)
{
   z.dir = 0;
   if(CheckPointer(originBar) == POINTER_INVALID || (dir != 1 && dir != -1) || rowSize <= 0.0 || atr <= 0.0)
      return false;
   int nRows = MathMax(1, cfg.szrMinRows);
   double body = (dir > 0) ? originBar.close - originBar.open : originBar.open - originBar.close;
   double bodyAtr = (cfg.placeboSzrBodyATR > 0.0) ? cfg.placeboSzrBodyATR : 0.60;
   if(body < bodyAtr * atr - FP_PX_EPS)
      return false;
   z.dir = dir;
   z.originTime = originBar.time;
   z.rowFrom = (dir > 0) ? openRow : openRow - nRows + 1;
   z.rowTo = z.rowFrom + nRows - 1;
   z.priceLow = (double)z.rowFrom * rowSize;
   z.priceHigh = (double)(z.rowTo + 1) * rowSize;
   z.rowsCount = nRows;
   z.volume = 0.0;
   z.filledTime = 0;
   z.touches = 0;
   z.lastTouchTime = 0;
   if(dir > 0 && originBar.close < z.priceHigh - FP_PX_EPS)
      return false;
   if(dir < 0 && originBar.close > z.priceLow + FP_PX_EPS)
      return false;
   if((z.priceHigh - z.priceLow) > cfg.szrMaxHeightATR * atr + FP_PX_EPS)
      return false;
   return true;
}

//+------------------------------------------------------------------+
//| Lifecycle                                                         |
//+------------------------------------------------------------------+
CFPSignals::CFPSignals(void)
{
   m_engine = NULL;
   m_hATR = INVALID_HANDLE;
   m_hEMA = INVALID_HANDLE;
   m_haveCtx = false;
   m_point = 0.0;
   m_digits = 0;
   m_period = 0;
   m_ctx.Reset();
   DefaultConfig(m_cfg);
}

bool CFPSignals::Init(CFPEngine *engine, const FPSignalConfig &cfg)
{
   Deinit();
   if(CheckPointer(engine) == POINTER_INVALID)
   {
      Print("CFPSignals: Init failed - engine pointer is invalid");
      return false;
   }
   m_engine = engine;
   m_cfg = cfg;
   Normalize(m_cfg);
   m_point = SymbolInfoDouble(m_cfg.symbol, SYMBOL_POINT);
   m_digits = (int)SymbolInfoInteger(m_cfg.symbol, SYMBOL_DIGITS);
   m_period = PeriodSeconds(m_cfg.timeframe);
   if(m_point <= 0.0 || m_period <= 0)
   {
      Print("CFPSignals: Init failed - no point size / period for ", m_cfg.symbol);
      return false;
   }
   m_hATR = iATR(m_cfg.symbol, m_cfg.timeframe, m_cfg.atrPeriod);
   m_hEMA = iMA(m_cfg.symbol, m_cfg.htf, m_cfg.htfEma, 0, MODE_EMA, PRICE_CLOSE);
   if(m_hATR == INVALID_HANDLE || m_hEMA == INVALID_HANDLE)
   {
      Print("CFPSignals: Init failed - cannot create ATR/EMA handles, error ", GetLastError());
      Deinit();
      return false;
   }
   if(m_cfg.placeboPriceOnly)
      Print("CFPSignals: PLACEBO price-only mode (03 11.10): every order-flow condition removed; grade fixed at ",
            FPGradeName(m_cfg.minGrade), ", points = price-only items");
   return true;
}

void CFPSignals::Deinit(void)
{
   if(m_hATR != INVALID_HANDLE)
      IndicatorRelease(m_hATR);
   if(m_hEMA != INVALID_HANDLE)
      IndicatorRelease(m_hEMA);
   m_hATR = INVALID_HANDLE;
   m_hEMA = INVALID_HANDLE;
   m_engine = NULL;
   m_haveCtx = false;
}

bool CFPSignals::IndicatorsReady(void)
{
   if(m_hATR == INVALID_HANDLE || m_hEMA == INVALID_HANDLE)
      return false;
   int a = BarsCalculated(m_hATR);
   int e = BarsCalculated(m_hEMA);
   return (a >= m_cfg.atrPeriod + m_cfg.atrBaseLen + 2 && e >= m_cfg.htfEma + 2);
}

bool CFPSignals::LastContext(FPContext &ctx) const
{
   ctx = m_ctx;
   return m_haveCtx;
}

//+------------------------------------------------------------------+
//| times[0] = T, times[i] = i held bars before T (PrevBarTime walk). |
//+------------------------------------------------------------------+
int CFPSignals::CollectBack(const datetime T, const int maxCount, datetime &times[])
{
   ArrayResize(times, 0);
   if(CheckPointer(m_engine) == POINTER_INVALID || maxCount <= 0)
      return 0;
   int lim = MathMin(maxCount, FP_WALK_LIMIT);
   ArrayResize(times, lim);
   int n = 0;
   datetime t = T;
   while(n < lim && t != 0)
   {
      times[n] = t;
      n++;
      t = m_engine.PrevBarTime(t);
   }
   ArrayResize(times, n);
   return n;
}

// ATR(atrPeriod) of the chart TF for the CLOSED bar opening at t (never the forming bar)
bool CFPSignals::AtrAt(const datetime t, double &atr)
{
   atr = 0.0;
   if(m_hATR == INVALID_HANDLE)
      return false;
   int s = iBarShift(m_cfg.symbol, m_cfg.timeframe, t, true);
   if(s < 1)
      return false;
   if(BarsCalculated(m_hATR) <= s)
      return false;
   double buf[];
   if(CopyBuffer(m_hATR, 0, s, 1, buf) != 1)
      return false;
   if(buf[0] <= 0.0 || buf[0] == EMPTY_VALUE)
      return false;
   atr = buf[0];
   return true;
}

// ATR of bar T and r = ATR / SMA(ATR, atrBaseLen) (the SMA includes T); regime from r
bool CFPSignals::ReadAtrContext(const datetime T, FPContext &ctx)
{
   if(m_hATR == INVALID_HANDLE)
      return false;
   int s = iBarShift(m_cfg.symbol, m_cfg.timeframe, T, true);
   if(s < 1)
      return false;                                   // T is not a closed chart bar: refuse (never shift 0)
   int len = m_cfg.atrBaseLen;
   if(BarsCalculated(m_hATR) < s + len)
      return false;
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(m_hATR, 0, s, len, buf) != len)
      return false;
   double sum = 0.0;
   for(int i = 0; i < len; i++)
   {
      if(buf[i] <= 0.0 || buf[i] == EMPTY_VALUE)
         return false;
      sum += buf[i];
   }
   double base = sum / (double)len;
   if(base <= 0.0)
      return false;
   ctx.atr = buf[0];
   ctx.atrRatio = ctx.atr / base;
   if(ctx.atrRatio > m_cfg.atrTrend)
      ctx.regime = FP_REG_TREND;
   else
      if(ctx.atrRatio < m_cfg.atrChop)
         ctx.regime = FP_REG_CHOP;
      else
         ctx.regime = FP_REG_BASE;
   return true;
}

// last HTF bar fully closed at T's close (live: HTF shift 1); htfBias 0 when unknown
void CFPSignals::ReadHtf(const datetime T, FPContext &ctx)
{
   if(m_hEMA == INVALID_HANDLE)
      return;
   datetime closeT = T + m_period;
   int hs = iBarShift(m_cfg.symbol, m_cfg.htf, closeT, false);
   if(hs < 0)
      return;
   datetime bt = iTime(m_cfg.symbol, m_cfg.htf, hs);
   if(bt == 0)
      return;
   if(bt + PeriodSeconds(m_cfg.htf) > closeT)
      hs++;                                           // that HTF bar was still forming at T's close
   if(hs < 1 || BarsCalculated(m_hEMA) <= hs)
      return;
   double e[];
   if(CopyBuffer(m_hEMA, 0, hs, 1, e) != 1 || e[0] <= 0.0 || e[0] == EMPTY_VALUE)
      return;
   double c = iClose(m_cfg.symbol, m_cfg.htf, hs);
   if(c <= 0.0)
      return;
   ctx.htfClose = c;
   ctx.htfEma = e[0];
   ctx.htfBias = (c > e[0]) ? 1 : ((c < e[0]) ? -1 : 0);
}

// previous SERVER day's high/low (D1 bar strictly before T's day); 0 = unknown
void CFPSignals::ReadPrevDay(const datetime T, FPContext &ctx)
{
   datetime dayStart = T - (T % 86400);
   int ds = iBarShift(m_cfg.symbol, PERIOD_D1, dayStart - 1, false);
   if(ds < 0)
      return;
   datetime dt = iTime(m_cfg.symbol, PERIOD_D1, ds);
   if(dt == 0 || dt >= dayStart)
      return;
   double h = iHigh(m_cfg.symbol, PERIOD_D1, ds);
   double l = iLow(m_cfg.symbol, PERIOD_D1, ds);
   if(h > 0.0 && l > 0.0 && h >= l)
   {
      ctx.prevDayHigh = h;
      ctx.prevDayLow = l;
   }
}

void CFPSignals::ReadSpread(FPContext &ctx)
{
   MqlTick tk;
   double sp = 0.0;
   if(SymbolInfoTick(m_cfg.symbol, tk) && tk.ask > 0.0 && tk.bid > 0.0)
      sp = tk.ask - tk.bid;
   else
      sp = (double)SymbolInfoInteger(m_cfg.symbol, SYMBOL_SPREAD) * m_point;
   if(sp < 0.0)
      sp = 0.0;
   ctx.spreadPrice = sp;
   ctx.spreadPts = (m_point > 0.0) ? sp / m_point : 0.0;
}

// SMA over the len usable held bars before T (bars with state != 0 are skipped, walk <= 2*len); 0 = unknown
double CFPSignals::PriorSma(const datetime T, const int len, const bool useRange)
{
   if(len <= 0 || CheckPointer(m_engine) == POINTER_INVALID)
      return 0.0;
   double sum = 0.0;
   int got = 0, steps = 0;
   datetime t = m_engine.PrevBarTime(T);
   while(t != 0 && got < len && steps < 2 * len)
   {
      steps++;
      CFPBar *b = m_engine.ByTime(t);
      if(b != NULL && b.closed && b.state == 0 && b.rows > 0)
      {
         sum += useRange ? (b.high - b.low) : b.volume;
         got++;
      }
      t = m_engine.PrevBarTime(t);
   }
   return (got == len) ? sum / (double)len : 0.0;
}

// accumulates the footprint rows of the given held bars into an absolute-row profile
void CFPSignals::FillProfile(const datetime &times[], const int n, FPProfile &p)
{
   p.rows = 0;
   p.total = 0.0;
   p.pocIdx = -1;
   p.vahIdx = -1;
   p.valIdx = -1;
   long lo = 0, hi = 0;
   bool any = false;
   for(int i = 0; i < n; i++)
   {
      CFPBar *b = m_engine.ByTime(times[i]);
      if(!BarUsable(b))
         continue;
      long bl = b.rowLow;
      long bh = b.rowLow + b.rows - 1;
      if(!any || bl < lo)
         lo = bl;
      if(!any || bh > hi)
         hi = bh;
      any = true;
   }
   if(!any || hi - lo + 1 > 1000000)
      return;
   p.rowLow = lo;
   p.rows = (int)(hi - lo + 1);
   ArrayResize(p.sell, p.rows);
   ArrayResize(p.buy, p.rows);
   ArrayInitialize(p.sell, 0.0);
   ArrayInitialize(p.buy, 0.0);
   for(int i = 0; i < n; i++)
   {
      CFPBar *b = m_engine.ByTime(times[i]);
      if(!BarUsable(b))
         continue;
      int off = (int)(b.rowLow - lo);
      for(int r = 0; r < b.rows; r++)
      {
         p.sell[off + r] += b.sellVol[r];
         p.buy[off + r] += b.buyVol[r];
         p.total += b.sellVol[r] + b.buyVol[r];
      }
   }
}

//+------------------------------------------------------------------+
//| Session profile of T's session from bars <= T only (NOT           |
//| engine.SessionProfile, which may include later bars) and the POC  |
//| of the previous session. POC tie -> row closest to T's close,     |
//| then the lower row; VA via CFPAnalytics::ValueArea.               |
//| sessPOC = mid of the POC row; VAH = top edge; VAL = bottom edge.  |
//+------------------------------------------------------------------+
void CFPSignals::BuildProfiles(const datetime T, const double closeT, FPContext &ctx)
{
   datetime ss = m_engine.SessionStart(T);
   datetime ps = (ss > 0) ? m_engine.SessionStart(ss - 1) : 0;
   datetime cur[];
   datetime prv[];
   int nc = 0, np = 0;
   datetime t = T;
   int steps = 0;
   while(t != 0 && steps < FP_WALK_LIMIT)
   {
      steps++;
      if(t >= ss)
      {
         ArrayResize(cur, nc + 1, 512);
         cur[nc] = t;
         nc++;
      }
      else
         if(ps > 0 && t >= ps)
         {
            ArrayResize(prv, np + 1, 512);
            prv[np] = t;
            np++;
         }
         else
            break;
      t = m_engine.PrevBarTime(t);
   }
   double rs = m_engine.RowSize();
   if(rs <= 0.0)
      return;
   FPProfile p;
   FillProfile(cur, nc, p);
   if(p.rows > 0 && p.total > 0.0)
   {
      long closeRow = m_engine.PriceToRow(closeT);
      int best = -1;
      double bv = -1.0;
      for(int i = 0; i < p.rows; i++)
      {
         double v = p.sell[i] + p.buy[i];
         if(v > bv)
         {
            bv = v;
            best = i;
         }
         else
            if(v == bv && best >= 0)
            {
               long dNew = MathAbs(p.rowLow + i - closeRow);
               long dOld = MathAbs(p.rowLow + best - closeRow);
               if(dNew < dOld)
                  best = i;
            }
      }
      p.pocIdx = best;
      if(CFPAnalytics::ValueArea(p, m_cfg.valueAreaPct) && p.pocIdx >= 0 && p.vahIdx >= 0 && p.valIdx >= 0)
      {
         ctx.sessPOC = m_engine.RowToPrice(p.rowLow + p.pocIdx) + rs * 0.5;
         ctx.sessVAH = m_engine.RowToPrice(p.rowLow + p.vahIdx + 1);
         ctx.sessVAL = m_engine.RowToPrice(p.rowLow + p.valIdx);
      }
   }
   FPProfile q;
   FillProfile(prv, np, q);
   if(q.rows > 0 && q.total > 0.0)
   {
      q.pocIdx = -1;                                  // max volume, tie -> lower row
      if(CFPAnalytics::ValueArea(q, m_cfg.valueAreaPct) && q.pocIdx >= 0)
         ctx.prevSessPOC = m_engine.RowToPrice(q.rowLow + q.pocIdx) + rs * 0.5;
   }
}

//+------------------------------------------------------------------+
//| Context of closed bar T, as of T's close. valid == ATR and the    |
//| ATR ratio are known (every setup needs them). Other fields are 0  |
//| when unknown (htfBias 0 makes the SZR HTF filter fail).           |
//+------------------------------------------------------------------+
bool CFPSignals::BuildContext(const datetime closedBarTime, FPContext &ctx)
{
   ctx.Reset();
   ctx.barTime = closedBarTime;
   if(CheckPointer(m_engine) == POINTER_INVALID)
      return false;
   ctx.source = m_engine.ActiveSource();
   CFPBar *bar = m_engine.ByTime(closedBarTime);
   if(bar == NULL || !bar.closed)
      return false;
   double closeT = bar.close;
   ReadSpread(ctx);
   bool atrOk = ReadAtrContext(closedBarTime, ctx);
   ReadHtf(closedBarTime, ctx);
   ReadPrevDay(closedBarTime, ctx);
   BuildProfiles(closedBarTime, closeT, ctx);
   ctx.volSMA = PriorSma(closedBarTime, m_cfg.volSmaLen, false);
   ctx.valid = atrOk;
   return ctx.valid;
}

double CFPSignals::StopBuffer(void) const
{
   return MathMax(m_cfg.slBufferATR * m_ctx.atr, 2.0 * m_ctx.spreadPrice);
}

//+------------------------------------------------------------------+
//| Small formatting helpers                                          |
//+------------------------------------------------------------------+
string FPSigD(const double v, const int digits = 3)
{
   return DoubleToString(v, digits);
}

string FPSigRegimeName(const int regime)
{
   if(regime == FP_REG_TREND)
      return "TREND";
   if(regime == FP_REG_CHOP)
      return "CHOP";
   return "BASE";
}

string FPSigTime(const datetime t)
{
   return TimeToString(t, TIME_DATE | TIME_MINUTES);
}

//+------------------------------------------------------------------+
//| DIV window: the held bars ending at T, OLDEST first, long enough  |
//| for a P1 search of divMaxBars plus the [T-3, T] confluence shift. |
//+------------------------------------------------------------------+
int CFPSignals::BuildDivWindow(const datetime &times[], const int nWin, FPDivBar &w[])
{
   int need = m_cfg.divMaxBars + 2 * m_cfg.divPivot + 1 + FP_DIV_CONF_BARS;
   int n = MathMin(nWin, need);
   ArrayResize(w, n);
   for(int i = 0; i < n; i++)
   {
      datetime t = times[n - 1 - i];
      CFPBar *b = m_engine.ByTime(t);
      bool ok = (b != NULL);
      if(ok)
         ok = (b.closed && b.state == 0 && b.rows > 0);
      w[i].time = t;
      w[i].ok = ok;
      w[i].high = ok ? b.high : 0.0;
      w[i].low = ok ? b.low : 0.0;
      w[i].delta = ok ? b.delta : 0.0;
      w[i].cumDelta = ok ? b.cumDelta : 0.0;
      w[i].cvdValid = ok ? b.cvdValid : false;
      w[i].sessionStart = m_engine.SessionStart(t);
   }
   return n;
}

// a DIV of direction dir confirmed at T, T-1, ..., T-maxBack bars (each judged as of its own confirming bar)
bool CFPSignals::DivNear(const FPDivBar &w[], const int nw, const int dir, const int maxBack, string &where)
{
   where = "";
   for(int j = 0; j <= maxBack; j++)
   {
      int cnt = nw - j;
      if(cnt < 2 * m_cfg.divPivot + 1)
         break;
      int p1 = -1, p2 = -1;
      if(DetectDivergence(w, cnt, dir, m_cfg.divPivot, m_cfg.divMaxBars, p1, p2))
      {
         where = FPSigTime(w[cnt - 1].time);
         return true;
      }
   }
   return false;
}

void CFPSignals::Append(FPSignal &out[], const FPSignal &s)
{
   int n = ArraySize(out);
   ArrayResize(out, n + 1, 8);
   out[n] = s;
}

// SZR de-duplication: higher points first, then the newer zone
bool CFPSignals::Better(const FPSignal &a, const FPSignal &b)
{
   if(a.points != b.points)
      return a.points > b.points;
   return a.zoneOrigin > b.zoneOrigin;
}

void CFPSignals::PushBest(FPSignal &best[], bool &have[], const FPSignal &s)
{
   int idx = (s.dir > 0) ? 0 : 1;
   if(!have[idx] || Better(s, best[idx]))
   {
      best[idx] = s;
      have[idx] = true;
   }
}

// out[] order: grade desc, points desc, setup (SZR, ABS, EXH, DIV), long before short
void CFPSignals::SortSignals(FPSignal &a[])
{
   int n = ArraySize(a);
   for(int i = 1; i < n; i++)
   {
      FPSignal key = a[i];
      int j = i - 1;
      while(j >= 0)
      {
         bool after = false;
         if(a[j].grade != key.grade)
            after = a[j].grade < key.grade;
         else
            if(a[j].points != key.points)
               after = a[j].points < key.points;
            else
               if(a[j].type != key.type)
                  after = (int)a[j].type > (int)key.type;
               else
                  after = a[j].dir < key.dir;
         if(!after)
            break;
         a[j + 1] = a[j];
         j--;
      }
      a[j + 1] = key;
   }
}

//+------------------------------------------------------------------+
//| SZR signal fields + s6 grading. Qualification is the caller's job |
//| (real: ZoneQualifies with ATR(origin); placebo: PlaceboZone).     |
//+------------------------------------------------------------------+
bool CFPSignals::MakeSZRSignal(const FPZone &z, CFPBar *origin, CFPBar *bar, const datetime T, const bool limit,
                               const int age, const int touchesBefore, FPSignal &s)
{
   if(CheckPointer(origin) == POINTER_INVALID || CheckPointer(bar) == POINTER_INVALID)
      return false;
   bool placebo = m_cfg.placeboPriceOnly;
   int dir = z.dir;
   double buf = StopBuffer();
   s.Reset();
   s.type = FP_SIG_ZONE_RETEST;
   s.dir = dir;
   s.barTime = T;
   s.refLow = z.priceLow;
   s.refHigh = z.priceHigh;
   s.stopPrice = Px((dir > 0) ? z.priceLow - buf : z.priceHigh + buf);
   if(limit)
   {
      s.orderKind = FP_ORD_LIMIT;
      s.entryPrice = Px((dir > 0) ? z.priceHigh : z.priceLow);
      s.validBars = m_cfg.szrMaxAgeBars;
      s.invalidPrice = (dir > 0) ? z.priceLow : z.priceHigh;
   }
   else
   {
      s.orderKind = FP_ORD_MARKET;
      s.entryPrice = 0.0;
      s.validBars = 0;
      s.invalidPrice = 0.0;
   }
   s.atr = m_ctx.atr;
   s.closeFrac = CloseFrac(bar, dir);
   s.stackRows = z.rowsCount;
   s.zoneOrigin = z.originTime;
   //--- structure target: the opposite VA edge, only when it lies on the profit side
   double ref = limit ? s.entryPrice : bar.close;
   double tgt = (dir > 0) ? m_ctx.sessVAH : m_ctx.sessVAL;
   if(tgt > 0.0 && ((dir > 0 && tgt > ref) || (dir < 0 && tgt < ref)))
      s.tpStructure = tgt;
   //--- grading (s6 SZR); hard requirements never score
   int pts = 0;
   string items = "";
   bool t3 = false, odpOk = false, rdpOk = false;
   double odp = (origin.volume > 0.0) ? origin.delta / origin.volume : 0.0;
   double rdp = (bar.volume > 0.0) ? bar.delta / bar.volume : 0.0;
   if(!placebo)
   {
      t3 = StackHasTier(z, origin, 3);
      odpOk = (dir > 0) ? (odp >= 2.0 * m_cfg.szrMinDeltaPct) : (odp <= -2.0 * m_cfg.szrMinDeltaPct);
      rdpOk = !limit && ((dir > 0) ? (rdp >= FP_SZR_RETEST_DPCT) : (rdp <= -FP_SZR_RETEST_DPCT));
   }
   double lv[5];
   lv[0] = m_ctx.sessVAL;
   lv[1] = m_ctx.sessVAH;
   lv[2] = m_ctx.prevDayHigh;
   lv[3] = m_ctx.prevDayLow;
   lv[4] = m_ctx.prevSessPOC;
   bool loc = NearAnyLevel(z.priceLow, z.priceHigh, lv, m_cfg.levelTolATR * m_ctx.atr);
   bool trend = (m_ctx.regime == FP_REG_TREND);
   if(t3)    { pts++; items += "t3+"; }
   if(loc)   { pts++; items += "loc+"; }
   if(trend) { pts++; items += "trend+"; }
   if(odpOk) { pts++; items += "odp+"; }
   if(rdpOk) { pts++; items += "rdp+"; }
   if(StringLen(items) > 0)
      items = StringSubstr(items, 0, StringLen(items) - 1);
   s.points = pts;
   s.grade = placebo ? (int)MathMax(FP_GRADE_C, MathMin(FP_GRADE_A, m_cfg.minGrade)) : GradeFromPoints(pts);
   s.info = (placebo ? "placebo=1;" : "") + "entry=" + (limit ? "LIMIT" : "CONFIRM") +
            ";origin=" + FPSigTime(z.originTime) + ";age=" + IntegerToString(age) +
            ";touchesBefore=" + IntegerToString(touchesBefore) + ";rows=" + IntegerToString(z.rowsCount) +
            ";odp=" + FPSigD(odp) + ";rdp=" + FPSigD(rdp) + ";regime=" + FPSigRegimeName(m_ctx.regime) +
            ";pts=" + items;
   return true;
}

//+------------------------------------------------------------------+
//| SZR (real): engine zones, as-of T                                 |
//+------------------------------------------------------------------+
void CFPSignals::EvalSZR(const datetime T, CFPBar *bar, const datetime &times[], const int nWin, FPSignal &out[])
{
   if(m_cfg.placeboPriceOnly)
   {
      EvalSZRPlacebo(T, bar, times, nWin, out);
      return;
   }
   FPZone zs[];
   int nz = m_engine.Zones(zs, true);
   FPSignal best[2];
   bool have[2] = {false, false};
   bool limit = (m_cfg.szrEntry == FP_SZR_LIMIT_AT_ZONE);
   int maxAge = MathMin(m_cfg.szrMaxAgeBars, nWin - 1);
   for(int i = 0; i < nz; i++)
   {
      if(zs[i].dir != 1 && zs[i].dir != -1)
         continue;
      if(zs[i].originTime > T)
         continue;                                    // as-of: zones born after T do not exist yet
      FPSignal s;
      if(limit)
      {
         //--- LIMIT_AT_ZONE: one LIMIT signal when the zone qualifies at its origin-bar close (origin == T)
         if(zs[i].originTime != T)
            continue;
         double atrT = 0.0;
         if(!AtrAt(T, atrT) || !ZoneQualifies(zs[i], bar, atrT, m_cfg))
            continue;
         if(MakeSZRSignal(zs[i], bar, bar, T, true, 0, 0, s))
            PushBest(best, have, s);
         continue;
      }
      //--- CONFIRM_CLOSE: T is a later bar, within szrMaxAgeBars HELD bars of the origin
      int age = -1;
      for(int a = 1; a <= maxAge; a++)
      {
         if(times[a] == zs[i].originTime)
         {
            age = a;
            break;
         }
      }
      if(age < 0)
         continue;
      if(!ZoneOpenAsOf(zs[i], T))
         continue;
      int tb = ZoneTouchesBefore(zs[i], T);
      if(tb < 0 || tb >= m_cfg.szrMaxTouches)
         continue;
      if(!SzrRetest(zs[i], bar, false))
         continue;
      CFPBar *o = m_engine.ByTime(zs[i].originTime);
      double atrO = 0.0;
      if(o == NULL || !AtrAt(zs[i].originTime, atrO))
         continue;
      if(!ZoneQualifies(zs[i], o, atrO, m_cfg))
         continue;
      if(MakeSZRSignal(zs[i], o, bar, T, false, age, tb, s))
         PushBest(best, have, s);
   }
   for(int d = 0; d < 2; d++)
      if(have[d])
         Append(out, best[d]);
}

//+------------------------------------------------------------------+
//| SZR (placebo): price zones at the base of impulse bars; lifecycle |
//| (fill / touches) rebuilt as of T from the bars between origin and |
//| T with the engine's rules (BUY: filled low < priceLow, touched    |
//| low <= priceHigh; SELL mirrors).                                  |
//+------------------------------------------------------------------+
void CFPSignals::EvalSZRPlacebo(const datetime T, CFPBar *bar, const datetime &times[], const int nWin, FPSignal &out[])
{
   double rs = m_engine.RowSize();
   if(rs <= 0.0 || nWin < 1)
      return;
   FPSignal best[2];
   bool have[2] = {false, false};
   bool limit = (m_cfg.szrEntry == FP_SZR_LIMIT_AT_ZONE);
   int aFrom = limit ? 0 : 1;
   int aTo = limit ? 0 : MathMin(m_cfg.szrMaxAgeBars, nWin - 1);
   for(int a = aFrom; a <= aTo; a++)
   {
      CFPBar *o = m_engine.ByTime(times[a]);
      if(o == NULL || !o.closed || o.state != 0 || o.rows <= 0)
         continue;
      double atrO = 0.0;
      if(!AtrAt(times[a], atrO))
         continue;
      long openRow = m_engine.PriceToRow(o.open);
      for(int dir = 1; dir >= -1; dir -= 2)
      {
         FPZone z;
         if(!PlaceboZone(o, dir, openRow, rs, atrO, m_cfg, z))
            continue;
         z.priceLow = m_engine.RowToPrice(z.rowFrom);
         z.priceHigh = m_engine.RowToPrice(z.rowTo + 1);
         FPSignal s;
         if(limit)
         {
            if(MakeSZRSignal(z, o, bar, T, true, 0, 0, s))
               PushBest(best, have, s);
            continue;
         }
         bool filled = false;
         int touches = 0;
         for(int j = a - 1; j >= 1; j--)
         {
            CFPBar *b = m_engine.ByTime(times[j]);
            if(b == NULL || b.rows <= 0)
               continue;
            if(dir > 0)
            {
               if(b.low < z.priceLow - FP_PX_EPS)
               {
                  filled = true;
                  break;
               }
               if(b.low <= z.priceHigh + FP_PX_EPS)
                  touches++;
            }
            else
            {
               if(b.high > z.priceHigh + FP_PX_EPS)
               {
                  filled = true;
                  break;
               }
               if(b.high >= z.priceLow - FP_PX_EPS)
                  touches++;
            }
         }
         if(filled || touches >= m_cfg.szrMaxTouches)
            continue;
         if(!SzrRetest(z, bar, true))
            continue;
         if(MakeSZRSignal(z, o, bar, T, false, a, touches, s))
            PushBest(best, have, s);
      }
   }
   for(int d = 0; d < 2; d++)
      if(have[d])
         Append(out, best[d]);
}

//+------------------------------------------------------------------+
//| ABS / EXH at bar T in direction dir (location + shape required)   |
//+------------------------------------------------------------------+
void CFPSignals::EvalRev(const datetime T, CFPBar *bar, const int dir, const datetime &times[], const int nWin,
                         const FPDivBar &w[], const int nw, FPSignal &out[])
{
   int L = m_cfg.revLookback;
   if(nWin < L + 1)
      return;                                         // not enough held bars: location cannot be proven
   double prior[];
   ArrayResize(prior, L);
   for(int j = 1; j <= L; j++)
   {
      CFPBar *b = m_engine.ByTime(times[j]);
      if(b == NULL || !b.closed || b.state != 0 || b.rows <= 0)
         return;                                      // conservative: unknown extremes in the lookback
      prior[j - 1] = (dir > 0) ? b.low : b.high;
   }
   double extreme = (dir > 0) ? bar.low : bar.high;
   if(!LocationOK(extreme, prior, dir))
      return;
   bool placebo = m_cfg.placeboPriceOnly;
   double mA[];
   double mE[];
   ArrayResize(mA, FP_M_COUNT);
   ArrayResize(mE, FP_M_COUNT);
   ArrayInitialize(mA, 0.0);
   ArrayInitialize(mE, 0.0);
   bool isAbs = false, isExh = false;
   if(placebo)
   {
      mA[FP_M_RANGESMA] = PriorSma(T, m_cfg.volSmaLen, true);
      isAbs = DetectAbsorptionPlacebo(bar, dir, m_cfg, mA);
      isExh = DetectExhaustionPlacebo(bar, dir, m_cfg, mE);
   }
   else
   {
      mA[FP_M_VOLSMA] = m_ctx.volSMA;
      isAbs = DetectAbsorption(bar, dir, m_cfg, mA);
      isExh = DetectExhaustion(bar, dir, m_cfg, mE);
   }
   ENUM_FP_SIGNAL type = ResolveRevType(isAbs, isExh);
   if(type == FP_SIG_NONE)
      return;
   FPSignal s;
   s.Reset();
   s.type = type;
   s.dir = dir;
   s.barTime = T;
   double off = (double)m_cfg.revEntryOffsetPts * m_point;
   double buf = StopBuffer();
   s.orderKind = FP_ORD_STOP;
   s.entryPrice = Px((dir > 0) ? bar.high + off : bar.low - off);
   s.stopPrice = Px((dir > 0) ? bar.low - buf : bar.high + buf);
   s.validBars = m_cfg.revValidBars;
   s.invalidPrice = (dir > 0) ? bar.low : bar.high;
   s.refLow = bar.low;
   s.refHigh = bar.high;
   s.atr = m_ctx.atr;
   s.closeFrac = CloseFrac(bar, dir);
   if(!placebo)
   {
      s.share = mA[FP_M_SHARE];
      s.concentration = mA[FP_M_CONC];
      s.exhaustionPct = mE[FP_M_EXHPCT];
   }
   double poc = m_ctx.sessPOC;
   if(poc > 0.0 && ((dir > 0 && poc > s.entryPrice) || (dir < 0 && poc < s.entryPrice)))
      s.tpStructure = poc;
   //--- grading (s6 ABS/EXH)
   int pts = 0;
   string items = "";
   double lv[3];
   lv[0] = (dir > 0) ? m_ctx.sessVAL : m_ctx.sessVAH;
   lv[1] = (dir > 0) ? m_ctx.prevDayLow : m_ctx.prevDayHigh;
   lv[2] = m_ctx.prevSessPOC;
   bool htf = (m_ctx.htfBias == dir);
   bool loc = NearAnyLevel(extreme, extreme, lv, m_cfg.levelTolATR * m_ctx.atr);
   bool imb = !placebo && ExtremeImbalance(bar, dir, m_cfg.revRows, 2);
   string divAt = "";
   bool div = !placebo && DivNear(w, nw, dir, FP_DIV_CONF_BARS, divAt);
   bool base = (m_ctx.regime == FP_REG_BASE);
   if(htf)  { pts++; items += "htf+"; }
   if(loc)  { pts++; items += "loc+"; }
   if(imb)  { pts++; items += "imb+"; }
   if(div)  { pts++; items += "div+"; }
   if(base) { pts++; items += "base+"; }
   if(StringLen(items) > 0)
      items = StringSubstr(items, 0, StringLen(items) - 1);
   s.divConfluence = div;
   s.points = pts;
   s.grade = placebo ? (int)MathMax(FP_GRADE_C, MathMin(FP_GRADE_A, m_cfg.minGrade)) : GradeFromPoints(pts);
   if(placebo)
      s.info = "placebo=1;abs=" + (isAbs ? "1" : "0") + ";exh=" + (isExh ? "1" : "0") +
               ";wick=" + FPSigD(mA[FP_M_WICK]) + ";cf=" + FPSigD(s.closeFrac) +
               ";rangeSMA=" + FPSigD(mA[FP_M_RANGESMA], m_digits) + ";regime=" + FPSigRegimeName(m_ctx.regime) +
               ";pts=" + items;
   else
      s.info = "abs=" + (isAbs ? "1" : "0") + ";exh=" + (isExh ? "1" : "0") +
               ";share=" + FPSigD(mA[FP_M_SHARE]) + ";conc=" + FPSigD(mA[FP_M_CONC]) +
               ";cf=" + FPSigD(s.closeFrac) + ";volx=" + FPSigD(mA[FP_M_VOLMULT]) +
               ";exhPct=" + FPSigD(mE[FP_M_EXHPCT], 4) + (div ? ";divAt=" + divAt : "") +
               ";regime=" + FPSigRegimeName(m_ctx.regime) + ";pts=" + items;
   Append(out, s);
}

//+------------------------------------------------------------------+
//| Standalone DIV (InpDIVStandalone=true; never in placebo): stamped |
//| at the confirming bar T; ABS-style stop entry beyond T; stop and  |
//| invalidation beyond the P2 pivot extreme.                         |
//+------------------------------------------------------------------+
void CFPSignals::EvalDivStandalone(const datetime T, CFPBar *bar, const int dir, const FPDivBar &w[], const int nw,
                                   FPSignal &out[])
{
   int p1 = -1, p2 = -1;
   if(nw < 2 * m_cfg.divPivot + 1 || w[nw - 1].time != T)
      return;
   if(!DetectDivergence(w, nw, dir, m_cfg.divPivot, m_cfg.divMaxBars, p1, p2))
      return;
   double ext = (dir > 0) ? w[p2].low : w[p2].high;
   double off = (double)m_cfg.revEntryOffsetPts * m_point;
   double buf = StopBuffer();
   FPSignal s;
   s.Reset();
   s.type = FP_SIG_DELTA_DIVERGENCE;
   s.dir = dir;
   s.barTime = T;
   s.orderKind = FP_ORD_STOP;
   s.entryPrice = Px((dir > 0) ? bar.high + off : bar.low - off);
   s.stopPrice = Px((dir > 0) ? ext - buf : ext + buf);
   s.validBars = m_cfg.revValidBars;
   s.invalidPrice = ext;
   s.refLow = w[p2].low;
   s.refHigh = w[p2].high;
   s.atr = m_ctx.atr;
   s.closeFrac = CloseFrac(bar, dir);
   s.divConfluence = true;
   double poc = m_ctx.sessPOC;
   if(poc > 0.0 && ((dir > 0 && poc > s.entryPrice) || (dir < 0 && poc < s.entryPrice)))
      s.tpStructure = poc;
   int pts = 0;
   string items = "";
   double lv[3];
   lv[0] = (dir > 0) ? m_ctx.sessVAL : m_ctx.sessVAH;
   lv[1] = (dir > 0) ? m_ctx.prevDayLow : m_ctx.prevDayHigh;
   lv[2] = m_ctx.prevSessPOC;
   if(m_ctx.htfBias == dir) { pts++; items += "htf+"; }
   if(NearAnyLevel(ext, ext, lv, m_cfg.levelTolATR * m_ctx.atr)) { pts++; items += "loc+"; }
   if(m_ctx.regime == FP_REG_BASE) { pts++; items += "base+"; }
   if(StringLen(items) > 0)
      items = StringSubstr(items, 0, StringLen(items) - 1);
   s.points = pts;
   s.grade = GradeFromPoints(pts);
   bool cvdCmp = (w[p1].sessionStart == w[p2].sessionStart && w[p1].cvdValid && w[p2].cvdValid);
   s.info = "p1=" + FPSigTime(w[p1].time) + ";p2=" + FPSigTime(w[p2].time) + ";cvdCompared=" + (cvdCmp ? "1" : "0") +
            ";cvd1=" + FPSigD(w[p1].cumDelta, 0) + ";cvd2=" + FPSigD(w[p2].cumDelta, 0) +
            ";delta2=" + FPSigD(w[p2].delta, 0) + ";regime=" + FPSigRegimeName(m_ctx.regime) + ";pts=" + items;
   Append(out, s);
}

//+------------------------------------------------------------------+
//| Evaluate(T): every graded signal of closed bar T (grade C         |
//| included), as of T. Stateless: nothing is remembered between      |
//| calls, so a logged signal can never be re-graded.                 |
//+------------------------------------------------------------------+
int CFPSignals::Evaluate(const datetime closedBarTime, FPSignal &out[])
{
   ArrayResize(out, 0);
   datetime T = closedBarTime;
   m_haveCtx = true;
   if(!BuildContext(T, m_ctx))
      return 0;
   CFPBar *bar = m_engine.ByTime(T);
   if(bar == NULL || !bar.closed)
      return 0;
   int need = 1 + MathMax(MathMax(m_cfg.szrMaxAgeBars, m_cfg.revLookback),
                          m_cfg.divMaxBars + 2 * m_cfg.divPivot + 1 + FP_DIV_CONF_BARS);
   datetime times[];
   int nWin = CollectBack(T, need, times);
   if(nWin < 1)
      return 0;
   FPDivBar w[];
   int nw = 0;
   if(!m_cfg.placeboPriceOnly && (m_cfg.revEnable || m_cfg.divStandalone))
      nw = BuildDivWindow(times, nWin, w);
   if(m_cfg.szrEnable)
      EvalSZR(T, bar, times, nWin, out);
   if(m_cfg.revEnable)
   {
      EvalRev(T, bar, 1, times, nWin, w, nw, out);
      EvalRev(T, bar, -1, times, nWin, w, nw, out);
   }
   if(m_cfg.divStandalone && !m_cfg.placeboPriceOnly)
   {
      EvalDivStandalone(T, bar, 1, w, nw, out);
      EvalDivStandalone(T, bar, -1, w, nw, out);
   }
   SortSignals(out);
   return ArraySize(out);
}
//+------------------------------------------------------------------+
