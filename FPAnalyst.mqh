//+------------------------------------------------------------------+
//| FPAnalyst.mqh - OrderFlowFP UI: studies (MA/RSI/MACD/ATR handles), |
//| market book reader, Signal Meter maths (02 §8.8e) and the Chart    |
//| Analyst rule engine + text layout (02 §8.8f).                      |
//|                                                                    |
//| DISPLAY ONLY: these rules are NOT the EA's entry logic.            |
//+------------------------------------------------------------------+
#ifndef ORDERFLOWFP_UI_FPANALYST_MQH
#define ORDERFLOWFP_UI_FPANALYST_MQH

#include "FPLayout.mqh"

#define FPS_NTF 5

//--- sentence tones (colour chosen at draw time, so theme changes apply at once)
#define FPTONE_TEXT    0
#define FPTONE_BULL    1
#define FPTONE_BEAR    2
#define FPTONE_NEUTRAL 3
#define FPTONE_LEVEL   4
#define FPTONE_CAUTION 5
#define FPTONE_HEAD    6

uint FPToneColor(const FPPalette &p, const int tone)
{
   switch(tone)
     {
      case FPTONE_BULL:    return p.bull;
      case FPTONE_BEAR:    return p.bear;
      case FPTONE_NEUTRAL: return p.dark ? p.neutral : p.text2;
      case FPTONE_LEVEL:   return p.dark ? p.levelBlue : p.blue;
      case FPTONE_CAUTION: return p.dark ? p.gold : p.cdYellow;
     }
   return p.text;
}

//+------------------------------------------------------------------+
//| Panel frame shared by all side panels: bg, 1 px border, 26 px      |
//| title strip (Segoe UI semibold 11 pt)                              |
//+------------------------------------------------------------------+
void FPPanelFrame(CFPContext *c, const FPRect &r, const string title, const string sub)
{
   c.cv.Box(r.x, r.y, r.w, r.h, c.pal.panelBg);
   c.cv.Frame(r.x, r.y, r.w, r.h, c.pal.border);
   if(title == "")
      return;
   int th = c.lay.titleH;
   c.cv.HL(r.x, r.x + r.w - 1, r.y + th, c.pal.border);
   int ty = r.y + th / 2;
   if(sub != "")
      ty = r.y + th / 2 - c.Px(3);
   c.cv.Txt(c.fTitle, r.x + c.Px(8), ty, title, c.pal.text, TA_LEFT | TA_VCENTER);
   if(sub != "")
      c.cv.Txt(c.fTiny, r.x + c.Px(9), r.y + th - c.Px(5), sub, c.pal.text2, TA_LEFT | TA_VCENTER);
}

//+------------------------------------------------------------------+
//| Studies: indicator handles created once (02 §8.8c/e)               |
//+------------------------------------------------------------------+
class CFPStudies
{
private:
   CFPContext       *m_ctx;
   int               m_hMA[3];
   int               m_hRSI, m_hMACD, m_hATR;
   int               m_hTF1[FPS_NTF], m_hTF2[FPS_NTF];

   static bool       One(const int h, const int buf, const int shift, double &v)
     {
      if(h == INVALID_HANDLE || BarsCalculated(h) <= shift)
         return false;
      double a[];
      if(CopyBuffer(h, buf, shift, 1, a) != 1)
         return false;
      v = a[0];
      return (v != EMPTY_VALUE);
     }

public:
   ENUM_TIMEFRAMES   tfs[FPS_NTF];
   string            tfLabel[FPS_NTF];
   int               tfTrend[FPS_NTF];   // +1 bull, -1 bear, 0 unknown
   bool              ok;                 // chart-TF studies available
   double            ma[3], maPrev[3];   // last closed bar and 3 bars before it
   double            close1;
   double            closes[];           // [0] = shift 1, [1] = shift 2 ...
   double            rsi, macdMain, macdSig, atr, atrRatio;
   bool              atrOk;
   double            d1Open, dayHigh, dayLow, last;
   int               chartTrend;

                     CFPStudies(void) : m_ctx(NULL), m_hRSI(INVALID_HANDLE), m_hMACD(INVALID_HANDLE), m_hATR(INVALID_HANDLE), ok(false), atrOk(false), chartTrend(0)
     {
      for(int i = 0; i < 3; i++)
         m_hMA[i] = INVALID_HANDLE;
      for(int i = 0; i < FPS_NTF; i++)
        {
         m_hTF1[i] = INVALID_HANDLE;
         m_hTF2[i] = INVALID_HANDLE;
         tfTrend[i] = 0;
        }
     }

   void              Init(CFPContext *ctx)
     {
      m_ctx = ctx;
      string sy = ctx.sym;
      ENUM_TIMEFRAMES tf = ctx.tf;
      int per[3];
      per[0] = ctx.set.ma1;
      per[1] = ctx.set.ma2;
      per[2] = ctx.set.ma3;
      for(int i = 0; i < 3; i++)
         m_hMA[i] = iMA(sy, tf, MathMax(1, per[i]), 0, MODE_EMA, PRICE_CLOSE);
      m_hRSI  = iRSI(sy, tf, MathMax(2, ctx.set.rsiPeriod), PRICE_CLOSE);
      m_hMACD = iMACD(sy, tf, MathMax(1, ctx.set.macdFast), MathMax(2, ctx.set.macdSlow), MathMax(1, ctx.set.macdSignal), PRICE_CLOSE);
      m_hATR  = iATR(sy, tf, MathMax(1, ctx.set.atrPeriod));
      tfs[0] = PERIOD_M5;  tfLabel[0] = "5M";
      tfs[1] = PERIOD_M15; tfLabel[1] = "15M";
      tfs[2] = PERIOD_H1;  tfLabel[2] = "1H";
      tfs[3] = PERIOD_H4;  tfLabel[3] = "4H";
      tfs[4] = PERIOD_D1;  tfLabel[4] = "D1";
      for(int i = 0; i < FPS_NTF; i++)
        {
         m_hTF1[i] = iMA(sy, tfs[i], MathMax(1, ctx.set.ma1), 0, MODE_EMA, PRICE_CLOSE);
         m_hTF2[i] = iMA(sy, tfs[i], MathMax(1, ctx.set.ma2), 0, MODE_EMA, PRICE_CLOSE);
        }
     }

   void              Deinit(void)
     {
      for(int i = 0; i < 3; i++)
        {
         if(m_hMA[i] != INVALID_HANDLE)
            IndicatorRelease(m_hMA[i]);
         m_hMA[i] = INVALID_HANDLE;
        }
      if(m_hRSI != INVALID_HANDLE)
         IndicatorRelease(m_hRSI);
      if(m_hMACD != INVALID_HANDLE)
         IndicatorRelease(m_hMACD);
      if(m_hATR != INVALID_HANDLE)
         IndicatorRelease(m_hATR);
      m_hRSI = m_hMACD = m_hATR = INVALID_HANDLE;
      for(int i = 0; i < FPS_NTF; i++)
        {
         if(m_hTF1[i] != INVALID_HANDLE)
            IndicatorRelease(m_hTF1[i]);
         if(m_hTF2[i] != INVALID_HANDLE)
            IndicatorRelease(m_hTF2[i]);
         m_hTF1[i] = m_hTF2[i] = INVALID_HANDLE;
        }
     }

   //--- copy the values of the last CLOSED chart bar (cheap: a few CopyBuffer calls)
   void              Refresh(void)
     {
      string sy = m_ctx.sym;
      ENUM_TIMEFRAMES tf = m_ctx.tf;
      //--- higher-timeframe trend boxes
      for(int i = 0; i < FPS_NTF; i++)
        {
         double a = 0.0, b = 0.0;
         if(One(m_hTF1[i], 0, 1, a) && One(m_hTF2[i], 0, 1, b))
            tfTrend[i] = (a > b) ? 1 : -1;
         else
            tfTrend[i] = 0;
        }
      //--- daily values
      d1Open  = iOpen(sy, PERIOD_D1, 0);
      dayHigh = iHigh(sy, PERIOD_D1, 0);
      dayLow  = iLow(sy, PERIOD_D1, 0);
      last    = SymbolInfoDouble(sy, SYMBOL_BID);
      CFPBar *f = m_ctx.engine.At(0);
      if(f != NULL && f.state == 0 && f.rows > 0 && f.close > 0.0)
         last = f.close;
      //--- chart timeframe
      ok = true;
      for(int i = 0; i < 3; i++)
        {
         double v[];
         if(m_hMA[i] == INVALID_HANDLE || BarsCalculated(m_hMA[i]) < 5 || CopyBuffer(m_hMA[i], 0, 1, 4, v) != 4)
           {
            ok = false;
            continue;
           }
         ma[i] = v[3];
         maPrev[i] = v[0];
        }
      double c[];
      int nc = MathMax(3, m_ctx.set.pocAccBars);
      if(CopyClose(sy, tf, 1, nc, c) == nc)
        {
         ArrayResize(closes, nc);
         for(int k = 0; k < nc; k++)
            closes[k] = c[nc - 1 - k];
         close1 = closes[0];
        }
      else
         ok = false;
      if(!One(m_hRSI, 0, 1, rsi))
         ok = false;
      if(!One(m_hMACD, 0, 1, macdMain) || !One(m_hMACD, 1, 1, macdSig))
         ok = false;
      atrOk = false;
      int base = MathMax(2, m_ctx.set.atrBaseLen);
      double av[];
      if(m_hATR != INVALID_HANDLE && BarsCalculated(m_hATR) > base + 1 && CopyBuffer(m_hATR, 0, 1, base, av) == base)
        {
         double sum = 0.0;
         for(int k = 0; k < base; k++)
            sum += av[k];
         atr = av[base - 1];
         atrRatio = (sum > 0.0) ? atr / (sum / base) : 1.0;
         atrOk = true;
        }
      else
         if(One(m_hATR, 0, 1, atr))
           {
            atrRatio = 1.0;
            atrOk = true;
           }
      chartTrend = 0;
      if(ok)
         chartTrend = (ma[0] > ma[1]) ? 1 : -1;
     }

   //--- mini-chart series, oldest first, the forming bar included
   int               RSISeries(double &out[], const int n)
     {
      if(m_hRSI == INVALID_HANDLE || BarsCalculated(m_hRSI) < n)
         return 0;
      return CopyBuffer(m_hRSI, 0, 0, n, out);
     }
   int               MACDSeries(double &mainv[], double &sigv[], const int n)
     {
      if(m_hMACD == INVALID_HANDLE || BarsCalculated(m_hMACD) < n)
         return 0;
      int a = CopyBuffer(m_hMACD, 0, 0, n, mainv);
      int b = CopyBuffer(m_hMACD, 1, 0, n, sigv);
      return (a == n && b == n) ? n : 0;
     }
   double            RSINow(void) { double v = 0.0; return One(m_hRSI, 0, 0, v) ? v : 0.0; }
   double            MACDNow(void) { double v = 0.0; return One(m_hMACD, 0, 0, v) ? v : 0.0; }
};

//+------------------------------------------------------------------+
//| Market book (never invented: empty = no book)                     |
//+------------------------------------------------------------------+
class CFPBook
{
private:
   string            m_sym;
   bool              m_sub;
public:
   bool              available;
   double            bidP[], bidV[], askP[], askV[];
   int               nBid, nAsk;

                     CFPBook(void) : m_sub(false), available(false), nBid(0), nAsk(0) {}
   void              Init(const string sym, const bool use, const bool tester)
     {
      m_sym = sym;
      m_sub = false;
      if(use && !tester)
         m_sub = MarketBookAdd(sym);
     }
   void              Deinit(void)
     {
      if(m_sub)
         MarketBookRelease(m_sym);
      m_sub = false;
     }
   void              Refresh(void)
     {
      nBid = 0;
      nAsk = 0;
      available = false;
      if(!m_sub)
         return;
      MqlBookInfo b[];
      if(!MarketBookGet(m_sym, b))
         return;
      int n = ArraySize(b);
      if(n <= 0)
         return;
      ArrayResize(bidP, n);
      ArrayResize(bidV, n);
      ArrayResize(askP, n);
      ArrayResize(askV, n);
      for(int i = 0; i < n; i++)
        {
         double v = (b[i].volume_real > 0.0) ? b[i].volume_real : (double)b[i].volume;
         if(b[i].price <= 0.0 || v <= 0.0)
            continue;
         if(b[i].type == BOOK_TYPE_BUY || b[i].type == BOOK_TYPE_BUY_MARKET)
           {
            bidP[nBid] = b[i].price;
            bidV[nBid] = v;
            nBid++;
           }
         else
           {
            askP[nAsk] = b[i].price;
            askV[nAsk] = v;
            nAsk++;
           }
        }
      //--- nearest first: bids descending, asks ascending (insertion sort; books are short)
      for(int i = 1; i < nBid; i++)
         for(int j = i; j > 0 && bidP[j] > bidP[j - 1]; j--)
           {
            double tp = bidP[j]; bidP[j] = bidP[j - 1]; bidP[j - 1] = tp;
            double tv = bidV[j]; bidV[j] = bidV[j - 1]; bidV[j - 1] = tv;
           }
      for(int i = 1; i < nAsk; i++)
         for(int j = i; j > 0 && askP[j] < askP[j - 1]; j--)
           {
            double tp = askP[j]; askP[j] = askP[j - 1]; askP[j - 1] = tp;
            double tv = askV[j]; askV[j] = askV[j - 1]; askV[j - 1] = tv;
           }
      available = (nBid + nAsk > 0);
     }
   //--- sum bid depth / sum ask depth over the 10 nearest levels (0 = n/a)
   double            Ratio10(void) const
     {
      if(!available)
         return 0.0;
      double sb = 0.0, sa = 0.0;
      for(int i = 0; i < nBid && i < 10; i++)
         sb += bidV[i];
      for(int i = 0; i < nAsk && i < 10; i++)
         sa += askV[i];
      if(sa <= 0.0)
         return (sb > 0.0) ? 99.0 : 0.0;
      return sb / sa;
     }
};

//+------------------------------------------------------------------+
//| Shared order-flow numbers of the last closed bars                  |
//+------------------------------------------------------------------+
struct FPFlowStats
{
   bool     ok;
   datetime barTime;     // last closed ok bar
   double   close1;
   double   deltaPct;    // delta / volume of the last closed bar
   double   cvdSlope;    // sum of delta of the last 5 closed bars
   double   cvdVol;      // sum of volume of the same bars
   int      cvdDir;      // +1 rising, -1 falling, 0 flat
   int      imbB, imbS;  // imbalance rows over the last 5 closed bars
   double   formDelta;   // forming bar delta
   double   formCvd;     // session CVD incl. the forming bar
   bool     formCvdOk;
   double   formBuy, formSell;
   double   tapeBuyPct;  // buy % of the last 200 prints (size weighted); <0 = n/a
};

void FPComputeFlow(CFPContext *c, FPFlowStats &fs)
{
   fs.ok = false;
   fs.imbB = 0;
   fs.imbS = 0;
   fs.cvdSlope = 0.0;
   fs.cvdVol = 0.0;
   fs.cvdDir = 0;
   fs.deltaPct = 0.0;
   fs.formDelta = 0.0;
   fs.formCvd = 0.0;
   fs.formCvdOk = false;
   fs.formBuy = 0.0;
   fs.formSell = 0.0;
   fs.tapeBuyPct = -1.0;
   CFPEngine *e = c.engine;
   CFPBar *f = e.At(0);
   if(f != NULL && f.state == 0)
     {
      fs.formDelta = f.delta;
      fs.formCvd = f.cumDelta;
      fs.formCvdOk = (c.mkt.ready && f.cvdValid);
      for(int k = 0; k < f.rows; k++)
        {
         fs.formBuy += f.buyVol[k];
         fs.formSell += f.sellVol[k];
        }
     }
   int used = 0;
   int n = e.Total();
   for(int sh = 1; sh <= n && used < 5; sh++)
     {
      CFPBar *b = e.At(sh);
      if(b == NULL)
         break;
      if(b.state != 0 || b.rows <= 0)
         continue;
      if(used == 0)
        {
         fs.ok = true;
         fs.barTime = b.time;
         fs.close1 = b.close;
         fs.deltaPct = (b.volume > 0.0) ? b.delta / b.volume : 0.0;
        }
      fs.cvdSlope += b.delta;
      fs.cvdVol += b.volume;
      for(int k = 0; k < b.rows; k++)
        {
         if(b.imbBuy[k] >= 1)
            fs.imbB++;
         if(b.imbSell[k] >= 1)
            fs.imbS++;
        }
      used++;
     }
   if(fs.cvdVol > 0.0 && MathAbs(fs.cvdSlope) >= 0.02 * fs.cvdVol)
      fs.cvdDir = (fs.cvdSlope > 0.0) ? 1 : -1;
   //--- tape
   FPPrint pr[];
   int np = e.Prints(pr, 200);
   double bv = 0.0, sv = 0.0;
   for(int i = 0; i < np; i++)
     {
      if(pr[i].side > 0)
         bv += pr[i].size;
      else
         if(pr[i].side < 0)
            sv += pr[i].size;
         else
           {
            bv += pr[i].size * 0.5;
            sv += pr[i].size * 0.5;
           }
     }
   if(bv + sv > 0.0)
      fs.tapeBuyPct = 100.0 * bv / (bv + sv);
}

//+------------------------------------------------------------------+
//| Signal Meter (02 §8.8e) - DISPLAY ONLY                             |
//+------------------------------------------------------------------+
#define FPM_ROWS 11
class CFPMeter
{
public:
   string            label[FPM_ROWS];
   string            value[FPM_ROWS];
   int               tone[FPM_ROWS];
   int               score;
   string            verdict;
   int               verdictTone;
   bool              ok;
   ulong             computedMs;

                     CFPMeter(void) : score(0), verdict("WAITING"), verdictTone(FPTONE_NEUTRAL), ok(false), computedMs(0)
     {
      string l[FPM_ROWS] = {"RSI", "MACD", "MA 9", "MA 21", "MA 50", "VWAP", "ATR Reg", "POC Pos", "Delta", "Cum Delta", "Vol B/S"};
      for(int i = 0; i < FPM_ROWS; i++)
        {
         label[i] = l[i];
         value[i] = "-";
         tone[i] = FPTONE_NEUTRAL;
        }
     }

   static string     MAText(const bool rising, const bool above, int &vote)
     {
      if(rising && above)
        {
         vote = 1;
         return "UP ABOVE";
        }
      if(!rising && !above)
        {
         vote = -1;
         return "DOWN BELOW";
        }
      vote = 0;
      return rising ? "UP BELOW" : "DOWN ABOVE";
     }
   static int        ToneOf(const int v) { return (v > 0) ? FPTONE_BULL : ((v < 0) ? FPTONE_BEAR : FPTONE_NEUTRAL); }

   void              Compute(CFPContext *c, CFPStudies &st, const FPFlowStats &fs)
     {
      computedMs = GetTickCount64();
      label[2] = "MA " + IntegerToString(c.set.ma1);
      label[3] = "MA " + IntegerToString(c.set.ma2);
      label[4] = "MA " + IntegerToString(c.set.ma3);
      if(!st.ok)
        {
         ok = false;
         verdict = "WAITING";
         verdictTone = FPTONE_NEUTRAL;
         score = 0;
         return;
        }
      ok = true;
      int sum = 0, v = 0;
      double cl = st.close1;
      //--- RSI
      v = (st.rsi > 55.0) ? 1 : ((st.rsi < 45.0) ? -1 : 0);
      value[0] = DoubleToString(st.rsi, 1);
      tone[0] = ToneOf(v);
      sum += v;
      //--- MACD
      v = (st.macdMain > st.macdSig) ? 1 : -1;
      value[1] = DoubleToString(st.macdMain, 2);
      tone[1] = ToneOf(v);
      sum += v;
      //--- MAs
      for(int i = 0; i < 3; i++)
        {
         value[2 + i] = MAText(st.ma[i] > st.maPrev[i], cl > st.ma[i], v);
         tone[2 + i] = ToneOf(v);
         sum += v;
        }
      //--- VWAP
      if(c.mkt.ready && c.mkt.vwap > 0.0)
        {
         v = (cl > c.mkt.vwap) ? 1 : -1;
         value[5] = (v > 0) ? "UP ABOVE" : "DOWN BELOW";
        }
      else
        {
         v = 0;
         value[5] = "n/a";
        }
      tone[5] = ToneOf(v);
      sum += v;
      //--- ATR regime (no vote)
      double mult = 0.85;
      string reg = "BASE";
      if(st.atrOk && st.atrRatio > c.set.atrTrend)
        {
         mult = 1.0;
         reg = "TREND";
        }
      else
         if(st.atrOk && st.atrRatio < c.set.atrChop)
           {
            mult = 0.6;
            reg = "CHOP";
           }
      value[6] = reg + " " + DoubleToString(st.atrOk ? st.atrRatio : 1.0, 2) + "x";
      tone[6] = FPTONE_NEUTRAL;
      //--- POC position
      v = 0;
      if(c.mkt.pocOk && c.tickSize > 0.0)
        {
         double pocMid = c.mkt.pocPrice + c.rowSize * 0.5;
         double d = (cl - pocMid) / c.tickSize;
         if(MathAbs(d) < c.set.pocAccTicks)
            value[7] = "AT POC";
         else
           {
            bool allSame = true;
            int nb = MathMin(MathMax(1, c.set.pocAccBars), ArraySize(st.closes));
            for(int k = 0; k < nb; k++)
               if((st.closes[k] - pocMid) * d <= 0.0)
                  allSame = false;
            string sd = (d > 0.0) ? "ABV" : "BLW";
            if(allSame)
              {
               v = (d > 0.0) ? 1 : -1;
               value[7] = sd + " ACC " + DoubleToString(MathAbs(d), 1) + "t";
              }
            else
               value[7] = sd + " TEST " + DoubleToString(MathAbs(d), 1) + "t";
           }
        }
      else
         value[7] = "n/a";
      tone[7] = ToneOf(v);
      sum += v;
      //--- Delta: vote on the last closed bar, display the forming bar
      v = 0;
      if(fs.ok)
         v = (fs.deltaPct >= 0.10) ? 1 : ((fs.deltaPct <= -0.10) ? -1 : 0);
      value[8] = c.SVol(fs.formDelta);
      tone[8] = ToneOf(v);
      sum += v;
      //--- Cum delta: vote = CVD slope over 5 closed bars, display = session CVD
      v = fs.ok ? fs.cvdDir : 0;
      value[9] = fs.formCvdOk ? c.SVol(fs.formCvd) : "n/a";
      tone[9] = ToneOf(v);
      sum += v;
      //--- Vol B/S of the session (closed bars + forming bar)
      double sb = c.mkt.sessBuy + fs.formBuy, ss = c.mkt.sessSell + fs.formSell;
      v = 0;
      if(ss > 0.0)
        {
         double r = sb / ss;
         v = (r > 1.10) ? 1 : ((r < 0.90) ? -1 : 0);
         value[10] = DoubleToString(r, 2);
        }
      else
         value[10] = "n/a";
      tone[10] = ToneOf(v);
      sum += v;
      //--- score
      double raw = sum / 10.0 * mult;
      score = (int)MathRound(100.0 * raw);
      if(score >= 60)
        {
         verdict = "STRONG BUY";
         verdictTone = FPTONE_BULL;
        }
      else
         if(score >= 20)
           {
            verdict = "BUY";
            verdictTone = FPTONE_BULL;
           }
         else
            if(score > -20)
              {
               verdict = "NEUTRAL";
               verdictTone = FPTONE_NEUTRAL;
              }
            else
               if(score > -60)
                 {
                  verdict = "SELL";
                  verdictTone = FPTONE_BEAR;
                 }
               else
                 {
                  verdict = "STRONG SELL";
                  verdictTone = FPTONE_BEAR;
                 }
     }
};

//+------------------------------------------------------------------+
//| Chart Analyst (02 §8.8f) - DISPLAY ONLY rule text                  |
//+------------------------------------------------------------------+
class CFPAnalyst
{
private:
   CFPContext       *m_ctx;
   string            m_txt[];
   int               m_tone[];
   int               m_kind[];     // 0 heading, 1 sentence, 2 box start (summary)
   int               m_n;
   ulong             m_updatedMs;
   //--- wrapped cache
   string            m_wTxt[];
   int               m_wTone[];
   int               m_wKind[];    // 0 heading, 1 text, 2 box start marker, 3 section gap
   int               m_wN;
   int               m_wChars;
   bool              m_wDirty;

   void              Add(const int kind, const int tone, const string s)
     {
      ArrayResize(m_txt, m_n + 1, 32);
      ArrayResize(m_tone, m_n + 1, 32);
      ArrayResize(m_kind, m_n + 1, 32);
      m_txt[m_n] = s;
      m_tone[m_n] = tone;
      m_kind[m_n] = kind;
      m_n++;
     }
   void              WAdd(const int kind, const int tone, const string s)
     {
      ArrayResize(m_wTxt, m_wN + 1, 64);
      ArrayResize(m_wTone, m_wN + 1, 64);
      ArrayResize(m_wKind, m_wN + 1, 64);
      m_wTxt[m_wN] = s;
      m_wTone[m_wN] = tone;
      m_wKind[m_wN] = kind;
      m_wN++;
     }
   void              Wrap(const int maxChars)
     {
      m_wN = 0;
      int mc = MathMax(10, maxChars);
      for(int i = 0; i < m_n; i++)
        {
         if(m_kind[i] == 0 || m_kind[i] == 2)
           {
            if(i > 0)
               WAdd(3, 0, "");
            if(m_kind[i] == 2)
               WAdd(2, 0, "");
            WAdd(0, FPTONE_HEAD, m_txt[i]);
            continue;
           }
         string rest = m_txt[i];
         while(StringLen(rest) > mc)
           {
            int cut = mc;
            for(int k = mc; k > mc / 2; k--)
               if(StringGetCharacter(rest, k) == ' ')
                 {
                  cut = k;
                  break;
                 }
            WAdd(1, m_tone[i], StringSubstr(rest, 0, cut));
            rest = StringSubstr(rest, cut);
            while(StringLen(rest) > 0 && StringGetCharacter(rest, 0) == ' ')
               rest = StringSubstr(rest, 1);
           }
         if(StringLen(rest) > 0)
            WAdd(1, m_tone[i], rest);
        }
      m_wChars = maxChars;
      m_wDirty = false;
     }
   static string     Sgn(const double v, const int d) { return ((v >= 0.0) ? "+" : "") + DoubleToString(v, d); }

public:
                     CFPAnalyst(void) : m_ctx(NULL), m_n(0), m_updatedMs(0), m_wN(0), m_wChars(0), m_wDirty(true) {}
   void              Init(CFPContext *ctx) { m_ctx = ctx; }
   ulong             UpdatedMs(void) const { return m_updatedMs; }

   void              Compute(CFPStudies &st, CFPBook &book, const FPFlowStats &fs)
     {
      CFPContext *c = m_ctx;
      m_n = 0;
      m_updatedMs = GetTickCount64();
      m_wDirty = true;
      int dg = c.digits;
      int fBull = 0, fBear = 0;   // advisor factors: trend, HTF, DOM, T&S, order flow, volume
      //--- 1 PAIR INFO
      Add(0, FPTONE_HEAD, "PAIR INFO");
      Add(1, FPTONE_TEXT, c.sym + " | " + c.tfName);
      if(st.d1Open > 0.0 && st.last > 0.0)
        {
         double ch = st.last - st.d1Open;
         Add(1, (ch >= 0.0) ? FPTONE_BULL : FPTONE_BEAR, "Daily: " + Sgn(ch, dg) + " (" + Sgn(100.0 * ch / st.d1Open, 2) + "%)");
        }
      else
         Add(1, FPTONE_NEUTRAL, "Daily: n/a");
      //--- 2 TREND + HIGHER TF
      Add(0, FPTONE_HEAD, "TREND + HIGHER TF | ATR: " + (st.atrOk ? DoubleToString(st.atr, dg) : "n/a"));
      if(st.ok)
        {
         double cl = st.close1;
         if(cl > st.ma[0] && st.ma[0] > st.ma[1] && st.ma[1] > st.ma[2])
           {
            Add(1, FPTONE_BULL, "Strong bullish trend. Price above all MAs with bullish alignment.");
            fBull++;
           }
         else
            if(cl < st.ma[0] && st.ma[0] < st.ma[1] && st.ma[1] < st.ma[2])
              {
               Add(1, FPTONE_BEAR, "Strong bearish trend. Price below all MAs with bearish alignment.");
               fBear++;
              }
            else
               if(cl > st.ma[1])
                 {
                  Add(1, FPTONE_BULL, "Moderate bullish bias. Price holding above medium-term MA.");
                  fBull++;
                 }
               else
                 {
                  Add(1, FPTONE_BEAR, "Moderate bearish bias. Price trading below medium-term MA.");
                  fBear++;
                 }
        }
      else
         Add(1, FPTONE_NEUTRAL, "Waiting for moving averages...");
      int h4 = st.tfTrend[3], d1 = st.tfTrend[4];
      if(h4 > 0 && d1 > 0)
        {
         Add(1, FPTONE_BULL, "H4 and Daily aligned bullish. Higher timeframes support upside.");
         fBull++;
        }
      else
         if(h4 < 0 && d1 < 0)
           {
            Add(1, FPTONE_BEAR, "H4 and Daily aligned bearish. Higher timeframes support downside.");
            fBear++;
           }
         else
            Add(1, FPTONE_NEUTRAL, "Mixed HTF signals. H4/Daily showing divergence. Trade with caution.");
      //--- 3 DOM ANALYSIS
      Add(0, FPTONE_HEAD, "DOM ANALYSIS");
      if(!book.available)
         Add(1, FPTONE_NEUTRAL, "No market depth from broker. DOM analysis unavailable.");
      else
        {
         double r = book.Ratio10();
         if(r >= 1.5)
           {
            Add(1, FPTONE_BULL, "Strong BID support. Buyers stacked " + DoubleToString(r, 1) + ":1 vs asks. Near levels favor bulls.");
            fBull++;
           }
         else
            if(r > 0.0 && r <= 1.0 / 1.5)
              {
               Add(1, FPTONE_BEAR, "Heavy ASK pressure. Sellers stacked " + DoubleToString(1.0 / r, 1) + ":1 vs bids. Near levels favor bears.");
               fBear++;
              }
            else
               Add(1, FPTONE_NEUTRAL, "Balanced DOM. Bid/Ask ratio near 1:1. No clear directional bias from order book.");
        }
      //--- 4 TIME & SALES
      Add(0, FPTONE_HEAD, "TIME & SALES");
      double p = fs.tapeBuyPct;
      if(p < 0.0)
         Add(1, FPTONE_NEUTRAL, "No prints yet.");
      else
        {
         int pi = (int)MathRound(p), qi = 100 - pi;
         if(p >= 65.0)
           {
            Add(1, FPTONE_BULL, "Strong buy pressure (" + IntegerToString(pi) + "%). Buyers clearly dominating the tape.");
            fBull++;
           }
         else
            if(p >= 55.0)
              {
               Add(1, FPTONE_BULL, "Moderate buy pressure (" + IntegerToString(pi) + "%). Buyers slightly more active.");
               fBull++;
              }
            else
               if(p <= 35.0)
                 {
                  Add(1, FPTONE_BEAR, "Strong sell pressure (" + IntegerToString(qi) + "%). Sellers clearly dominating the tape.");
                  fBear++;
                 }
               else
                  if(p <= 45.0)
                    {
                     Add(1, FPTONE_BEAR, "Moderate sell pressure (" + IntegerToString(qi) + "%). Sellers slightly more active.");
                     fBear++;
                    }
                  else
                     Add(1, FPTONE_NEUTRAL, "Balanced tape. Buy/Sell near 50/50. No clear aggressor dominance.");
        }
      //--- 5 ORDER FLOW
      Add(0, FPTONE_HEAD, "ORDER FLOW");
      if(!fs.ok)
         Add(1, FPTONE_NEUTRAL, "Waiting for closed bars...");
      else
        {
         double d = fs.deltaPct;
         int cv = fs.cvdDir;
         if(d >= 0.15 && cv > 0)
           {
            Add(1, FPTONE_BULL, "Active aggressive buying detected. Delta positive, cumulative delta rising.");
            fBull++;
           }
         else
            if(d >= 0.05 && cv > 0)
              {
               Add(1, FPTONE_BULL, "Active moderate buying detected. Delta positive, cumulative delta rising.");
               fBull++;
              }
            else
               if(d <= -0.15 && cv < 0)
                 {
                  Add(1, FPTONE_BEAR, "Active aggressive selling detected. Delta negative, cumulative delta falling.");
                  fBear++;
                 }
               else
                  if(d <= -0.05 && cv < 0)
                    {
                     Add(1, FPTONE_BEAR, "Active moderate selling detected. Delta negative, cumulative delta falling.");
                     fBear++;
                    }
                  else
                     if(cv < 0)
                       {
                        Add(1, FPTONE_BEAR, "Sellers in control. Monitor for potential breakdown.");
                        fBear++;
                       }
                     else
                        if(cv > 0)
                          {
                           Add(1, FPTONE_BULL, "Buyers in control. Monitor for potential breakout.");
                           fBull++;
                          }
                        else
                           Add(1, FPTONE_NEUTRAL, "Neutral order flow. No clear aggressor.");
        }
      //--- 6 VOLUME
      Add(0, FPTONE_HEAD, "VOLUME");
      double sb = c.mkt.sessBuy + fs.formBuy, ss = c.mkt.sessSell + fs.formSell;
      if(ss <= 0.0 || sb <= 0.0)
         Add(1, FPTONE_NEUTRAL, "Session volume not available yet.");
      else
        {
         double R = sb / ss;
         if(R >= 1.15)
           {
            Add(1, FPTONE_BULL, "Buyers leading (ratio: " + DoubleToString(R, 2) + "). Healthy buying pressure.");
            fBull++;
           }
         else
            if(R <= 0.87)
              {
               Add(1, FPTONE_BEAR, "Sellers leading (ratio: " + DoubleToString(R, 2) + "). Healthy selling pressure.");
               fBear++;
              }
            else
               Add(1, FPTONE_NEUTRAL, "Balanced volume (ratio: " + DoubleToString(R, 2) + "). Neither side dominant.");
        }
      //--- 7 IMBALANCES
      Add(0, FPTONE_HEAD, "IMBALANCES");
      int B = fs.imbB, S = fs.imbS;
      if(S >= 2 * B && S >= 5)
         Add(1, FPTONE_BEAR, "Multiple sell imbalances (" + IntegerToString(S) + ") detected. Institutional selling likely.");
      else
         if(B >= 2 * S && B >= 5)
            Add(1, FPTONE_BULL, "Multiple buy imbalances (" + IntegerToString(B) + ") detected. Institutional buying likely.");
         else
            Add(1, FPTONE_NEUTRAL, "Buy imb: " + IntegerToString(B) + " | Sell imb: " + IntegerToString(S) + ". Mixed institutional activity.");
      //--- 8 KEY LEVELS
      Add(0, FPTONE_HEAD, "KEY LEVELS");
      string poc = c.mkt.pocOk ? DoubleToString(c.mkt.pocPrice, dg) : "n/a";
      Add(1, FPTONE_LEVEL, "Session POC: " + poc + ". Daily range: " + DoubleToString(st.dayLow, dg) + " - " + DoubleToString(st.dayHigh, dg) + ".");
      //--- 9 SETUP + ADVISOR SUMMARY
      Add(2, FPTONE_HEAD, "SETUP + ADVISOR SUMMARY");
      double rng = st.dayHigh - st.dayLow;
      double cl1 = st.last;
      if(rng > 0.0 && cl1 > 0.0)
        {
         if(cl1 >= st.dayHigh - 0.10 * rng)
            Add(1, FPTONE_CAUTION, "CAUTION: Price near daily high. Watch for rejection or breakout above " + DoubleToString(st.dayHigh, dg) + ".");
         else
            if(cl1 <= st.dayLow + 0.10 * rng)
               Add(1, FPTONE_CAUTION, "CAUTION: Price near daily low. Watch for rejection or breakdown below " + DoubleToString(st.dayLow, dg) + ".");
        }
      if(fBull >= 4)
         Add(1, FPTONE_BULL, "BULLISH BIAS (" + IntegerToString(fBull) + "/6 factors). Consider long positions with proper risk management.");
      else
         if(fBear >= 4)
            Add(1, FPTONE_BEAR, "BEARISH BIAS (" + IntegerToString(fBear) + "/6 factors). Consider short positions with proper risk management.");
         else
            if(fBull + fBear <= 1)
               Add(1, FPTONE_CAUTION, "NEUTRAL: Wait for clearer setup. Price in middle of range with mixed signals.");
            else
               Add(1, FPTONE_CAUTION, "MIXED SIGNALS (" + IntegerToString(fBull) + " bull, " + IntegerToString(fBear) + " bear). Wait for alignment before committing.");
     }

   //--- text layout: word-wrap to the panel width (Consolas is monospace)
   void              Draw(const FPRect &r)
     {
      CFPContext *c = m_ctx;
      FPPanelFrame(c, r, "Chart Analyst", "");
      int th = c.lay.titleH;
      //--- "Updated: Ns ago"
      if(m_updatedMs > 0)
        {
         long ago = (long)((GetTickCount64() - m_updatedMs) / 1000);
         c.cv.Txt(c.fSmall, r.x + r.w - c.Px(8), r.y + th / 2, "Updated: " + IntegerToString(ago) + "s ago", c.pal.text2, TA_RIGHT | TA_VCENTER);
        }
      if(m_n == 0)
        {
         c.cv.Txt(c.fMono, r.x + c.Px(10), r.y + th + c.Px(16), "Waiting for data...", c.pal.text2, TA_LEFT | TA_VCENTER);
         return;
        }
      int pad = c.Px(10);
      int cw = MathMax(1, c.cv.CharW(c.fMono));
      int chars = (r.w - 2 * pad - c.Px(8)) / cw;
      if(m_wDirty || chars != m_wChars)
         Wrap(chars);
      int lh = c.cv.CharH(c.fMono) + c.Px(2);
      int y = r.y + th + c.Px(8) + lh / 2;
      int yMax = r.y + r.h - c.Px(4);
      int boxY = -1;
      for(int i = 0; i < m_wN; i++)
        {
         if(m_wKind[i] == 3)
           {
            y += c.Px(6);
            continue;
           }
         if(m_wKind[i] == 2)
           {
            boxY = y - lh / 2 - c.Px(3);
            y += c.Px(3);
            continue;
           }
         if(y + lh / 2 > yMax)
            break;
         if(m_wKind[i] == 0)
            c.cv.Txt(c.fMono, r.x + pad, y, m_wTxt[i], c.pal.text, TA_LEFT | TA_VCENTER);
         else
            c.cv.Txt(c.fMono, r.x + pad + c.Px(2), y, m_wTxt[i], FPToneColor(c.pal, m_wTone[i]), TA_LEFT | TA_VCENTER);
         y += lh;
        }
      if(boxY >= 0)
        {
         int bh = MathMin(y + c.Px(4), yMax) - boxY;
         c.cv.Frame(r.x + pad - c.Px(4), boxY, r.w - 2 * pad + c.Px(8) - c.Px(2), MathMax(bh, c.Px(20)), c.pal.border);
        }
     }
};

#endif // ORDERFLOWFP_UI_FPANALYST_MQH
//+------------------------------------------------------------------+
