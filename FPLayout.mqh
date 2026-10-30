//+------------------------------------------------------------------+
//| FPLayout.mqh - OrderFlowFP UI: settings, view state, layout        |
//| rectangles (02 §7), button hit-testing, scaling, and the shared    |
//| UI context passed to the renderer/panels/analyst.                  |
//+------------------------------------------------------------------+
#ifndef ORDERFLOWFP_UI_FPLAYOUT_MQH
#define ORDERFLOWFP_UI_FPLAYOUT_MQH

#include "..\FPEngine.mqh"
#include "FPCanvas.mqh"

//--- button ids
#define FPB_NONE        -1
#define FPB_SD           1
#define FPB_FUND         2
#define FPB_MINI         3
#define FPB_RESET        4
#define FPB_ZOOMIN       5
#define FPB_ZOOMOUT      6
#define FPB_UP           7
#define FPB_DOWN         8
#define FPB_BARVP        9
#define FPB_DELTA       10
#define FPB_SIDE        11
#define FPB_LIVE        12
#define FPB_TABS_TOGGLE 13
#define FPB_TABLE_TOGGLE 14
#define FPB_TAB0        20     // 20..28 = style tabs

//+------------------------------------------------------------------+
//| rectangle                                                         |
//+------------------------------------------------------------------+
struct FPRect
{
   int x, y, w, h;
};
void   FPRectSet(FPRect &r, const int x, const int y, const int w, const int h) { r.x = x; r.y = y; r.w = (w < 0) ? 0 : w; r.h = (h < 0) ? 0 : h; }
bool   FPRectHit(const FPRect &r, const int px, const int py) { return (px >= r.x && px < r.x + r.w && py >= r.y && py < r.y + r.h); }
int    FPRight(const FPRect &r)  { return r.x + r.w; }
int    FPBottom(const FPRect &r) { return r.y + r.h; }

struct FPButton
{
   int    id;
   FPRect r;
   bool   enabled;
};

//+------------------------------------------------------------------+
//| All indicator inputs the UI needs (filled by FootprintChart.mq5)   |
//+------------------------------------------------------------------+
struct FPUISettings
{
   //--- imbalance styling
   bool     imbBold;
   int      imbBoost[4];
   color    buyImbColor, sellImbColor;
   color    buyImbTier[4], sellImbTier[4];
   bool     themeOverridesImb;
   bool     showStackZones;
   int      stackZoneBars;
   bool     showFilledZones;
   //--- display
   int      style;
   int      panelTheme, colorTheme;
   int      barWidth, barSpacing, rowHeight, minCellHeight;
   string   fontNumbers, fontUI;
   int      numberFontPt;
   int      uiScalePct;
   bool     showSide, showTable, showMini, showSessionPOC, showPerBarPOC;
   bool     showDeltaBars, showBarVP, showSD, showFund, hideNative;
   //--- panels
   int      vpMode, vpBars, tasRows;
   bool     tasAggregate;
   double   tasBigSize;
   bool     useBook;
   int      domLevels, analystRefreshSec;
   //--- studies
   int      ma1, ma2, ma3, rsiPeriod, macdFast, macdSlow, macdSignal, atrPeriod, atrBaseLen;
   double   atrTrend, atrChop;
   int      pocAccBars;
   double   pocAccTicks;
   //--- supply & demand
   int      sdSwing, sdLookback, sdVolLen, sdAtrLen, sdMaxZones;
   double   sdVolRatio, sdWidthDiv;
   //--- performance
   int      redrawMs, loadBudgetMs;
   //--- alerts
   bool     alertStack;
   double   alertDeltaAbove, alertDeltaBelow;
   bool     alertPopup;
   string   alertSound;
   //--- trade overlay
   bool     showTrades;
   long     tradeMagic;
};

//+------------------------------------------------------------------+
//| View state (changed by buttons, mouse and keys)                   |
//+------------------------------------------------------------------+
struct FPView
{
   int      zoom;          // row height in unscaled px (6..40)
   int      scroll;        // bars back from the newest (0 = live)
   datetime anchor;        // newest visible bar time while scrolled (keeps the view on new bars)
   bool     live;
   double   centerRow;     // row coordinate at the vertical middle of the plot
   bool     vAuto;         // vertical auto-follow
   bool     centred;       // first centring done
   bool     sideOn, sideForced;
   bool     miniOn, deltaOn, barVPOn, sdOn, tabsOn, tableOn;
   int      panelTheme, colorTheme;
};

//+------------------------------------------------------------------+
//| Market values shared by several components (recomputed on closed  |
//| bars / history ready, never per frame)                            |
//+------------------------------------------------------------------+
struct FPMarket
{
   bool     ready;          // engine HistoryReady()
   datetime sessStart;      // session of the newest bar
   bool     pocOk;
   long     pocRow;         // absolute row of the session POC (closed bars)
   double   pocPrice;       // bottom edge of the POC row
   double   sessBuy, sessSell;   // closed bars of the session
   double   vwap;
   datetime lastClosed;     // time of At(1) when computed
   int      loaded, total;  // history progress
};

//+------------------------------------------------------------------+
//| Layout rectangles (02 §7)                                          |
//+------------------------------------------------------------------+
class CFPLayout
{
public:
   double            s;
   int               W, H;
   bool              sideOn;
   FPRect            header, tabs, fp, plot, scale, table, mini, side;
   FPRect            analyst, meter, dom, tas, tasList, barTotals, rsi, macd, vp;
   int               barW, spacing, pitch, gap, scaleW;
   int               plotRight;      // right edge (exclusive) of the newest column
   int               headerH, tabsH, tableH, tableHeadH, tableRowH, titleH;
   FPButton          btn[];
   int               nBtn;

   int               Px(const double v) const { return (int)MathRound(v * s); }

   void              Compute(const int width, const int height, const double scl, FPView &v, const FPUISettings &st)
     {
      s = scl;
      W = width;
      H = height;
      headerH = Px(34);
      tabsH   = v.tabsOn ? Px(26) : 0;
      titleH  = Px(26);
      int top = headerH + tabsH;
      sideOn = v.sideOn && (v.sideForced || W >= Px(1500));
      int sideW = sideOn ? Px(690) : 0;
      int fpRight = W - sideW - Px(20);
      if(fpRight < Px(200))
         fpRight = MathMax(Px(200), W - Px(20));
      tableHeadH = Px(22);
      tableRowH  = Px(20);
      tableH = (v.tableOn ? tableHeadH + 5 * tableRowH : tableHeadH) + Px(4);
      FPRectSet(header, 0, 0, W, headerH);
      FPRectSet(tabs, 0, headerH, W, tabsH);
      FPRectSet(fp, 0, top, fpRight, H - top - tableH);
      scaleW = Px(64);
      gap    = Px(75);
      FPRectSet(scale, fpRight - scaleW, fp.y, scaleW, fp.h);
      FPRectSet(plot, fp.x, fp.y, scale.x - fp.x, fp.h);
      plotRight = scale.x - gap;
      FPRectSet(table, 0, FPBottom(fp), fpRight, tableH);
      FPRectSet(mini, Px(8), fp.y + Px(6), Px(330), Px(230));
      //--- columns (compact mode narrows the columns with the zoom)
      int bw = MathMax(1, st.barWidth);
      int sp = MathMax(0, st.barSpacing);
      if(v.zoom < st.minCellHeight && st.minCellHeight > 0)
        {
         double f = (double)v.zoom / (double)st.minCellHeight;
         bw = MathMax(3, (int)MathRound(bw * f));
         sp = MathMax(2, (int)MathRound(sp * f));
        }
      barW    = Px(bw);
      spacing = MathMax(1, Px(sp));
      pitch   = barW + spacing;
      //--- side column
      FPRectSet(side, W - sideW, top, sideW, H - top);
      if(sideOn)
        {
         int m = Px(5);
         int ix = side.x + m, iw = side.w - 2 * m, iy = side.y + m;
         int avail = side.h - 3 * m;
         int topH = MathMin(Px(470), (int)MathRound(avail * 0.49));
         int meterW = Px(180);
         int anaW = iw - m - meterW;
         FPRectSet(analyst, ix, iy, anaW, topH);
         FPRectSet(meter, ix + anaW + m, iy, meterW, topH);
         int by = iy + topH + m;
         int bh = FPBottom(side) - m - by;
         int vpW = Px(180), tasW = Px(185);
         int domW = iw - 2 * m - vpW - tasW;
         FPRectSet(dom, ix, by, domW, bh);
         FPRectSet(tas, ix + domW + m, by, tasW, bh);
         FPRectSet(vp, tas.x + tasW + m, by, vpW, bh);
         int miniH = Px(100);
         FPRectSet(macd, tas.x, FPBottom(tas) - miniH, tasW, miniH);
         FPRectSet(rsi, tas.x, macd.y - miniH, tasW, miniH);
         int btH = Px(44);
         FPRectSet(barTotals, tas.x, rsi.y - btH, tasW, btH);
         FPRectSet(tasList, tas.x, tas.y, tasW, barTotals.y - tas.y);
        }
      else
        {
         FPRectSet(analyst, 0, 0, 0, 0);
         FPRectSet(meter, 0, 0, 0, 0);
         FPRectSet(dom, 0, 0, 0, 0);
         FPRectSet(tas, 0, 0, 0, 0);
         FPRectSet(vp, 0, 0, 0, 0);
         FPRectSet(macd, 0, 0, 0, 0);
         FPRectSet(rsi, 0, 0, 0, 0);
         FPRectSet(barTotals, 0, 0, 0, 0);
         FPRectSet(tasList, 0, 0, 0, 0);
        }
     }

   //--- buttons are registered by the drawers every frame (immediate-mode GUI)
   void              ClearButtons(void) { nBtn = 0; }
   void              AddButton(const int id, const int x, const int y, const int w, const int h, const bool enabled)
     {
      if(ArraySize(btn) <= nBtn)
         ArrayResize(btn, nBtn + 16);
      btn[nBtn].id = id;
      FPRectSet(btn[nBtn].r, x, y, w, h);
      btn[nBtn].enabled = enabled;
      nBtn++;
     }
   int               HitTest(const int x, const int y) const
     {
      for(int i = nBtn - 1; i >= 0; i--)
         if(FPRectHit(btn[i].r, x, y))
            return btn[i].enabled ? btn[i].id : FPB_NONE;
      return FPB_NONE;
     }
                     CFPLayout(void) : s(1.0), W(0), H(0), sideOn(false), nBtn(0) {}
};

//+------------------------------------------------------------------+
//| Batched text: collect, then draw grouped by font (one switch per   |
//| font per frame)                                                    |
//+------------------------------------------------------------------+
class CFPTextBatch
{
private:
   int               m_font[];
   int               m_x[];
   int               m_y[];
   string            m_s[];
   uint              m_c[];
   uint              m_a[];
   int               m_n;
   int               m_maxFont;
public:
                     CFPTextBatch(void) : m_n(0), m_maxFont(0) {}
   void              Clear(void) { m_n = 0; m_maxFont = 0; }
   void              Add(const int font, const int x, const int y, const string s, const uint c, const uint align)
     {
      if(ArraySize(m_x) <= m_n)
        {
         int sz = m_n + 512;
         ArrayResize(m_font, sz);
         ArrayResize(m_x, sz);
         ArrayResize(m_y, sz);
         ArrayResize(m_s, sz);
         ArrayResize(m_c, sz);
         ArrayResize(m_a, sz);
        }
      m_font[m_n] = font;
      m_x[m_n] = x;
      m_y[m_n] = y;
      m_s[m_n] = s;
      m_c[m_n] = c;
      m_a[m_n] = align;
      if(font > m_maxFont)
         m_maxFont = font;
      m_n++;
     }
   void              Flush(CFPCanvas &cv)
     {
      for(int f = 0; f <= m_maxFont; f++)
         for(int i = 0; i < m_n; i++)
            if(m_font[i] == f)
               cv.Txt(f, m_x[i], m_y[i], m_s[i], m_c[i], m_a[i]);
      m_n = 0;
      m_maxFont = 0;
     }
   int               Count(void) const { return m_n; }
};

//+------------------------------------------------------------------+
//| Shared UI context                                                 |
//+------------------------------------------------------------------+
class CFPContext
{
public:
   CFPCanvas         cv;
   CFPLayout         lay;
   FPPalette         pal;
   FPUISettings      set;
   FPView            view;
   FPMarket          mkt;
   FPConfig          cfg;
   CFPEngine        *engine;
   //--- symbol
   string            sym;
   ENUM_TIMEFRAMES   tf;
   int               period;
   int               digits;
   double            point, tickSize, rowSize;
   int               volDigits;      // 0 in QUOTE mode; digits of SYMBOL_VOLUME_STEP otherwise
   string            tfName;
   bool              tester;
   //--- fonts
   int               fNum, fX, fNumB[4], fScale, fScaleB, fSmall, fTiny, fUI, fUIB, fBtn, fTab, fTitle, fTicker, fTickerPx, fMono, fMonoB, fTable, fTag, fGauge;
   double            s;

   int               Px(const double v) const { return (int)MathRound(v * s); }
   int               PtPx(const double pt) const { return MathMax(6, (int)MathRound(pt * 96.0 / 72.0 * s)); }

   void              BuildFonts(void)
     {
      cv.ResetFonts();
      string fn = set.fontNumbers, fu = set.fontUI;
      int np = PtPx(set.numberFontPt);
      fNum   = cv.AddFont(fn, np, FW_NORMAL);
      fX     = cv.AddFont(fn, MathMax(6, np - 1), FW_NORMAL);
      fNumB[0] = fNum;
      for(int t = 1; t <= 3; t++)
         fNumB[t] = cv.AddFont(fn, np + (set.imbBold ? set.imbBoost[t] : 0), set.imbBold ? FW_BOLD : FW_NORMAL);
      //--- UI sizes calibrated against the reference frames (positive TextSetFont sizes are cell heights,
      //    so Segoe UI renders ~20 % smaller than its nominal point size; see docs\decisions\ui.md)
      fScale  = cv.AddFont(fn, PtPx(9), FW_NORMAL);
      fScaleB = cv.AddFont(fn, PtPx(9), FW_BOLD);
      fTable  = cv.AddFont(fn, PtPx(9), FW_NORMAL);
      fSmall  = cv.AddFont(fu, PtPx(8.5), FW_NORMAL);
      fTiny   = cv.AddFont(fu, PtPx(7.5), FW_NORMAL);
      fUI     = cv.AddFont(fu, PtPx(9.5), FW_NORMAL);
      fUIB    = cv.AddFont(fu, PtPx(9.5), FW_SEMIBOLD);
      fBtn    = cv.AddFont(fu, PtPx(8.8), FW_NORMAL);
      fTab    = cv.AddFont(fu, PtPx(7.5), FW_SEMIBOLD);
      fTitle  = cv.AddFont(fu, PtPx(10.5), FW_SEMIBOLD);
      fTicker = cv.AddFont(fu, PtPx(12.5), FW_BOLD);
      fTickerPx = cv.AddFont(fn, PtPx(12.5), FW_NORMAL);
      fMono   = cv.AddFont(fn, PtPx(9.5), FW_NORMAL);
      fMonoB  = cv.AddFont(fn, PtPx(9.5), FW_BOLD);
      fTag    = cv.AddFont(fn, PtPx(9), FW_BOLD);
      fGauge  = cv.AddFont(fu, PtPx(10.5), FW_SEMIBOLD);
     }

   //--- engine bar of a time (binary search over shifts; -1 = not held)
   int               ShiftOfTime(const datetime t)
     {
      int n = engine.Total();
      if(n <= 0)
         return -1;
      CFPBar *bNew = engine.At(0);
      int lo = (bNew == NULL) ? 1 : 0;          // shift 0 = forming bar
      int hi = (bNew == NULL) ? n : n - 1;      // oldest held shift
      if(lo > hi)
         return -1;
      CFPBar *bOld = engine.At(hi);
      CFPBar *bLo = engine.At(lo);
      if(bOld == NULL || bLo == NULL)
         return -1;
      if(t < bOld.time)
         return -1;
      if(t >= bLo.time)
         return lo;
      //--- find the smallest shift whose time <= t
      while(hi - lo > 1)
        {
         int mid = (lo + hi) / 2;
         CFPBar *bm = engine.At(mid);
         if(bm == NULL)
            return -1;
         if(bm.time <= t)
            hi = mid;
         else
            lo = mid;
        }
      return hi;
     }

   //--- volume formatting (02 §8.1)
   string            Vol(const double v) const
     {
      double a = MathAbs(v);
      string sign = (v < 0.0) ? "-" : "";
      if(a >= 1000000.0)
         return sign + DoubleToString(a / 1000000.0, 1) + "M";
      if(a >= 10000.0)
         return sign + DoubleToString(a / 1000.0, 1) + "k";
      if(volDigits <= 0)
         return sign + DoubleToString(MathRound(a), 0);
      //--- fractional volumes (EXCHANGE/TRADE mode): rounded to the volume step, trailing zeros dropped
      string t = DoubleToString(a, volDigits);
      if(StringFind(t, ".") >= 0)
        {
         while(StringLen(t) > 1 && StringGetCharacter(t, StringLen(t) - 1) == '0')
            t = StringSubstr(t, 0, StringLen(t) - 1);
         if(StringGetCharacter(t, StringLen(t) - 1) == '.')
            t = StringSubstr(t, 0, StringLen(t) - 1);
        }
      return sign + t;
     }
   string            SVol(const double v) const   // signed, '+' for positive
     {
      if(v > 0.0)
         return "+" + Vol(v);
      return Vol(v);
     }
   string            Price(const double p) const { return DoubleToString(p, digits); }

                     CFPContext(void) : engine(NULL), volDigits(0), s(1.0) {}
};

//--- timeframe text (M5, H1 ...) - own name: FPTfName belongs to the EA layer
string FPUITfName(const ENUM_TIMEFRAMES tf)
{
   string t = EnumToString(tf);
   if(StringFind(t, "PERIOD_") == 0)
      t = StringSubstr(t, 7);
   return t;
}

#endif // ORDERFLOWFP_UI_FPLAYOUT_MQH
//+------------------------------------------------------------------+
