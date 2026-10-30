//+------------------------------------------------------------------+
//| FootprintChart.mq5 - OrderFlowFP footprint & order-flow workspace  |
//| (02_PROMPT_Footprint_Indicator.md §6-§10). Thin: inputs, events,   |
//| wiring. Engine = Include\OrderFlowFP (frozen), UI = ...\UI\*.      |
//|                                                                    |
//| DISPLAY ONLY. No trading calls. The Chart Analyst and the Signal   |
//| Meter are rule-generated text; they are NOT the EA's entry logic.  |
//+------------------------------------------------------------------+
#property copyright   "OrderFlowFP"
#property version     "1.00"
#property description "Footprint & order-flow workspace (Minimalist style) with side panels and EA trade overlay."
#property description "Display only: Chart Analyst / Signal Meter are rule text, not the EA's entry logic."
#property indicator_chart_window
#property indicator_buffers 8
#property indicator_plots   8
#property indicator_label1  "FP Volume"
#property indicator_type1   DRAW_NONE
#property indicator_label2  "FP Delta"
#property indicator_type2   DRAW_NONE
#property indicator_label3  "FP CumDelta"
#property indicator_type3   DRAW_NONE
#property indicator_label4  "FP POC price"
#property indicator_type4   DRAW_NONE
#property indicator_label5  "FP BuyImb count"
#property indicator_type5   DRAW_NONE
#property indicator_label6  "FP SellImb count"
#property indicator_type6   DRAW_NONE
#property indicator_label7  "FP BuyStack rows"
#property indicator_type7   DRAW_NONE
#property indicator_label8  "FP SellStack rows"
#property indicator_type8   DRAW_NONE

#include <OrderFlowFP\UI\FPRenderer.mqh>
#include <OrderFlowFP\UI\FPPanels.mqh>

//--- inputs (02 §10)
input group "Data"
input ENUM_FP_SOURCE      InpSource             = FP_SRC_AUTO;      // Volume source (set explicitly for exact EA equality)
input int                 InpBucketPoints       = 0;                // Row size in points (0 = auto)
input ENUM_FP_QUOTE_PRICE InpQuotePrice         = FP_QP_BID;        // Quote-mode row price
input int                 InpHistoryBars        = 300;              // Closed bars to build (minimum)
input string              InpSessionStart       = "00:00";          // Session start, server time HH:MM
input double              InpValueAreaPct       = 70;               // Value area, percent
input group "Imbalance"
input double              InpImbRatio1          = 2.0;              // Imbalance ratio tier 1
input double              InpImbRatio2          = 3.0;              // Imbalance ratio tier 2
input double              InpImbRatio3          = 4.0;              // Imbalance ratio tier 3
input double              InpImbMinVolume       = 10;               // Min dominant volume
input bool                InpImbBold            = true;             // Imbalanced numbers bold
input int                 InpImbBoost1          = 1;                // Font boost tier 1, px
input int                 InpImbBoost2          = 2;                // Font boost tier 2, px
input int                 InpImbBoost3          = 3;                // Font boost tier 3, px
input color               InpBuyImbColor        = C'34,197,94';     // Buyer imbalance colour
input color               InpSellImbColor       = C'239,68,68';     // Seller imbalance colour
input color               InpBuyImbColorT1      = clrNONE;          // Buyer tier 1 colour (None = base)
input color               InpBuyImbColorT2      = clrNONE;          // Buyer tier 2 colour (None = base)
input color               InpBuyImbColorT3      = clrNONE;          // Buyer tier 3 colour (None = base)
input color               InpSellImbColorT1     = clrNONE;          // Seller tier 1 colour (None = base)
input color               InpSellImbColorT2     = clrNONE;          // Seller tier 2 colour (None = base)
input color               InpSellImbColorT3     = clrNONE;          // Seller tier 3 colour (None = base)
input bool                InpThemeOverridesImbalance = false;       // Theme bull/bear colours for imbalances
input int                 InpStackMinRows       = 3;                // Stacked imbalance min rows
input bool                InpShowStackZones     = true;             // Show stacked-imbalance zones
input int                 InpStackZoneBars      = 20;               // Zone length, bars
input bool                InpShowFilledZones    = false;            // Show filled zones (faint)
input group "Display"
input ENUM_FP_STYLE       InpStyle              = FP_STYLE_MINIMALIST; // Footprint style
input ENUM_FP_PANEL_THEME InpPanelTheme         = FP_PANEL_DARK;    // Panel theme
input ENUM_FP_COLOR_THEME InpColorTheme         = FP_CT_ORANGE_DARK_GREY; // Bull/bear colour theme
input int                 InpBarWidth           = 55;               // Bar column width, px
input int                 InpBarSpacing         = 14;               // Bar spacing, px
input int                 InpRowHeight          = 16;               // Row height, px (zoom 6-40)
input int                 InpMinCellHeight      = 14;               // Below this: compact candles
input string              InpFontNumbers        = "Consolas";       // Numbers font
input string              InpFontUI             = "Segoe UI";       // UI font
input int                 InpNumberFontSize     = 10;               // Numbers font size, pt
input int                 InpUIScalePct         = 100;              // UI scale, % (x screen DPI/96)
input bool                InpShowSidePanels     = true;             // Side panels (auto-hidden below 1500 px)
input bool                InpShowSummaryTable   = true;             // Summary table
input bool                InpShowMiniChart      = true;             // Mini session chart
input bool                InpShowSessionPOC     = true;             // Session POC line
input bool                InpShowPerBarPOC      = false;            // Per-bar POC outline
input bool                InpShowDeltaBars      = false;            // Delta bars
input bool                InpShowBarVP          = false;            // Bar volume profile
input bool                InpShowSDZones        = false;            // Supply & demand zones
input bool                InpShowFundamentals   = false;            // Fundamentals panel (not implemented)
input bool                InpHideNativeChart    = false;            // Hide the native chart (CHART_SHOW=false)
input group "Panels"
input ENUM_FP_VP_MODE     InpVPMode             = FP_VP_BARS;       // VP Total mode
input int                 InpVPBars             = 50;               // VP Total bars
input int                 InpTasRows            = 30;               // Time & Sales rows (max)
input bool                InpTasAggregate       = true;             // T&S: merge same side/price/second
input double              InpTasBigSize         = 0;                // T&S bold size (0 = auto 95th pct)
input bool                InpUseMarketBook      = true;             // Subscribe to the market book
input int                 InpDomLevels          = 12;               // DOM levels above/below
input int                 InpAnalystRefreshSec  = 30;               // Chart Analyst refresh, s
input group "Studies"
input int                 InpMA1                = 9;                // MA 1 (EMA)
input int                 InpMA2                = 21;               // MA 2 (EMA)
input int                 InpMA3                = 50;               // MA 3 (EMA)
input int                 InpRSIPeriod          = 14;               // RSI period
input int                 InpMACDFast           = 12;               // MACD fast
input int                 InpMACDSlow           = 26;               // MACD slow
input int                 InpMACDSignal         = 9;                // MACD signal
input int                 InpATRPeriod          = 14;               // ATR period
input int                 InpATRBaseLen         = 50;               // ATR regime base length
input double              InpATRTrend           = 1.15;             // ATR regime TREND above
input double              InpATRChop            = 0.85;             // ATR regime CHOP below
input int                 InpPOCAccBars         = 3;                // POC acceptance bars
input double              InpPOCAccTicks        = 1.5;              // AT POC within ticks
input group "S&D"
input int                 InpSDSwing            = 8;                // Pivot strength
input int                 InpSDLookback         = 200;              // Lookback bars
input int                 InpSDVolLen           = 20;               // Volume SMA length
input double              InpSDVolRatio         = 1.2;              // Pivot volume >= ratio x SMA
input int                 InpSDATRLen           = 50;               // ATR length
input double              InpSDWidthDiv         = 4.0;              // Zone height = ATR / this
input int                 InpSDMaxZones         = 4;                // Max zones
input group "Performance"
input int                 InpRedrawMs           = 100;              // Min ms between redraws
input int                 InpLoadBudgetMs       = 40;               // History load budget per timer, ms
input group "Alerts"
input bool                InpAlertStack         = false;            // Alert: stacked imbalance on close
input double              InpAlertDeltaAbove    = 0;                // Alert: bar delta >= value (0 = off)
input double              InpAlertDeltaBelow    = 0;                // Alert: bar delta <= -|value| (0 = off)
input bool                InpAlertPopup         = true;             // Alert popup (else log + sound)
input string              InpAlertSound         = "alert.wav";      // Alert sound file
input group "Trades"
input bool                InpShowTrades         = true;             // Show EA trades on the footprint
input long                InpTradeMagic         = 240611;           // Magic of the trades (-1 = all)

//--- data-window buffers (02 §5.8)
double g_bVol[], g_bDelta[], g_bCum[], g_bPoc[], g_bBuyImb[], g_bSellImb[], g_bBuyStk[], g_bSellStk[];

//--- components
CFPEngine     g_engine;
CFPContext    g_ctx;
CFPRenderer   g_ren;
CFPPanels     g_pan;
CFPStudies    g_st;
CFPBook       g_book;
CFPMeter      g_meter;
CFPAnalyst    g_ana;
CFPTrades     g_trades;
FPFlowStats   g_flow;

//--- state
string   g_objName = "";
bool     g_canvasOk = false;
bool     g_draw = true;          // false in the non-visual tester
bool     g_ready = false;
bool     g_dirty = true;
bool     g_bufFull = true;
bool     g_bookDirty = false;
int      g_W = 0, g_H = 0;
ulong    g_lastDrawMs = 0, g_lastStudyMs = 0, g_lastMeterMs = 0, g_lastAnalystMs = 0, g_lastBookMs = 0, g_lastMktMs = 0;
ulong    g_lastStatusMs = 0;
long     g_lastSecond = 0;
ulong    g_drawSumUs = 0, g_drawMaxUs = 0, g_drawLastUs = 0;
ulong    g_secUs[4];             // per-section draw time accumulators (footprint, table+chrome, side, canvas update)
int      g_drawFrames = 0, g_drawTotal = 0;
double   g_drawAvgMs = 0.0;
int      g_lastLoaded = -1;
ulong    g_initMs = 0, g_loadStepUs = 0, g_loadStepMaxUs = 0;   // responsiveness while history loads
int      g_loadSteps = 0;
string   g_worstStep = "", g_periodicNote = "";
bool     g_analystDue = true;
//--- drag
bool     g_drag = false, g_dragMoved = false;
int      g_dragX0 = 0, g_dragY0 = 0, g_dragScroll0 = 0;
double   g_dragCenter0 = 0.0;
//--- saved chart properties
bool     g_saved = false;
long     g_pFore = 0, g_pGrid = 0, g_pOHLC = 0, g_pOneClick = 0, g_pMouseScroll = 0, g_pEvMove = 0, g_pEvWheel = 0, g_pKeys = 0, g_pShow = 1;

//+------------------------------------------------------------------+
int ParseSessionMin(const string s)
{
   string p[];
   if(StringSplit(s, ':', p) != 2)
      return 0;
   int h = (int)StringToInteger(p[0]), m = (int)StringToInteger(p[1]);
   if(h < 0 || h > 23 || m < 0 || m > 59)
      return 0;
   return h * 60 + m;
}

void FillConfig(FPConfig &cfg)
{
   cfg.symbol          = _Symbol;
   cfg.timeframe       = (ENUM_TIMEFRAMES)_Period;
   cfg.bucketPoints    = InpBucketPoints;
   cfg.source          = InpSource;
   cfg.quotePrice      = InpQuotePrice;
   cfg.historyBars     = MathMax(1, InpHistoryBars);
   cfg.sessionStartMin = ParseSessionMin(InpSessionStart);
   cfg.imbRatio1       = InpImbRatio1;
   cfg.imbRatio2       = InpImbRatio2;
   cfg.imbRatio3       = InpImbRatio3;
   cfg.imbMinVolume    = InpImbMinVolume;
   cfg.stackMinRows    = InpStackMinRows;
   cfg.valueAreaPct    = InpValueAreaPct / 100.0;
}

void FillSettings(FPUISettings &s)
{
   s.imbBold = InpImbBold;
   s.imbBoost[0] = 0;
   s.imbBoost[1] = InpImbBoost1;
   s.imbBoost[2] = InpImbBoost2;
   s.imbBoost[3] = InpImbBoost3;
   s.buyImbColor = InpBuyImbColor;
   s.sellImbColor = InpSellImbColor;
   s.buyImbTier[0] = clrNONE;
   s.buyImbTier[1] = InpBuyImbColorT1;
   s.buyImbTier[2] = InpBuyImbColorT2;
   s.buyImbTier[3] = InpBuyImbColorT3;
   s.sellImbTier[0] = clrNONE;
   s.sellImbTier[1] = InpSellImbColorT1;
   s.sellImbTier[2] = InpSellImbColorT2;
   s.sellImbTier[3] = InpSellImbColorT3;
   s.themeOverridesImb = InpThemeOverridesImbalance;
   s.showStackZones = InpShowStackZones;
   s.stackZoneBars = MathMax(1, InpStackZoneBars);
   s.showFilledZones = InpShowFilledZones;
   s.style = (int)InpStyle;
   s.panelTheme = (int)InpPanelTheme;
   s.colorTheme = (int)InpColorTheme;
   s.barWidth = MathMax(20, InpBarWidth);
   s.barSpacing = MathMax(0, InpBarSpacing);
   s.rowHeight = MathMax(6, MathMin(40, InpRowHeight));
   s.minCellHeight = MathMax(6, InpMinCellHeight);
   s.fontNumbers = InpFontNumbers;
   s.fontUI = InpFontUI;
   s.numberFontPt = MathMax(6, InpNumberFontSize);
   s.uiScalePct = MathMax(50, MathMin(300, InpUIScalePct));
   s.showSide = InpShowSidePanels;
   s.showTable = InpShowSummaryTable;
   s.showMini = InpShowMiniChart;
   s.showSessionPOC = InpShowSessionPOC;
   s.showPerBarPOC = InpShowPerBarPOC;
   s.showDeltaBars = InpShowDeltaBars;
   s.showBarVP = InpShowBarVP;
   s.showSD = InpShowSDZones;
   s.showFund = InpShowFundamentals;
   s.hideNative = InpHideNativeChart;
   s.vpMode = (int)InpVPMode;
   s.vpBars = MathMax(1, InpVPBars);
   s.tasRows = MathMax(1, InpTasRows);
   s.tasAggregate = InpTasAggregate;
   s.tasBigSize = InpTasBigSize;
   s.useBook = InpUseMarketBook;
   s.domLevels = MathMax(1, MathMin(60, InpDomLevels));
   s.analystRefreshSec = MathMax(1, InpAnalystRefreshSec);
   s.ma1 = InpMA1;
   s.ma2 = InpMA2;
   s.ma3 = InpMA3;
   s.rsiPeriod = InpRSIPeriod;
   s.macdFast = InpMACDFast;
   s.macdSlow = InpMACDSlow;
   s.macdSignal = InpMACDSignal;
   s.atrPeriod = InpATRPeriod;
   s.atrBaseLen = InpATRBaseLen;
   s.atrTrend = InpATRTrend;
   s.atrChop = InpATRChop;
   s.pocAccBars = InpPOCAccBars;
   s.pocAccTicks = InpPOCAccTicks;
   s.sdSwing = InpSDSwing;
   s.sdLookback = InpSDLookback;
   s.sdVolLen = InpSDVolLen;
   s.sdVolRatio = InpSDVolRatio;
   s.sdAtrLen = InpSDATRLen;
   s.sdWidthDiv = InpSDWidthDiv;
   s.sdMaxZones = InpSDMaxZones;
   s.redrawMs = MathMax(20, InpRedrawMs);
   s.loadBudgetMs = MathMax(5, InpLoadBudgetMs);
   s.alertStack = InpAlertStack;
   s.alertDeltaAbove = InpAlertDeltaAbove;
   s.alertDeltaBelow = InpAlertDeltaBelow;
   s.alertPopup = InpAlertPopup;
   s.alertSound = InpAlertSound;
   s.showTrades = InpShowTrades;
   s.tradeMagic = InpTradeMagic;
}

void BuildPalette(void)
{
   CFPTheme::Build(g_ctx.view.panelTheme, g_ctx.view.colorTheme, g_ctx.set.buyImbColor, g_ctx.set.sellImbColor,
                   g_ctx.set.buyImbTier, g_ctx.set.sellImbTier, g_ctx.set.themeOverridesImb, g_ctx.pal);
}

//+------------------------------------------------------------------+
//| chart properties: save, set, restore (02 §6)                      |
//+------------------------------------------------------------------+
void SaveAndSetChart(void)
{
   g_pFore        = ChartGetInteger(0, CHART_FOREGROUND);
   g_pGrid        = ChartGetInteger(0, CHART_SHOW_GRID);
   g_pOHLC        = ChartGetInteger(0, CHART_SHOW_OHLC);
   g_pOneClick    = ChartGetInteger(0, CHART_SHOW_ONE_CLICK);
   g_pMouseScroll = ChartGetInteger(0, CHART_MOUSE_SCROLL);
   g_pEvMove      = ChartGetInteger(0, CHART_EVENT_MOUSE_MOVE);
   g_pEvWheel     = ChartGetInteger(0, CHART_EVENT_MOUSE_WHEEL);
   g_pKeys        = ChartGetInteger(0, CHART_KEYBOARD_CONTROL);
   g_pShow        = ChartGetInteger(0, CHART_SHOW);
   g_saved = true;
   ChartSetInteger(0, CHART_FOREGROUND, false);
   ChartSetInteger(0, CHART_SHOW_GRID, false);
   ChartSetInteger(0, CHART_SHOW_OHLC, false);
   ChartSetInteger(0, CHART_SHOW_ONE_CLICK, false);
   ChartSetInteger(0, CHART_MOUSE_SCROLL, false);
   ChartSetInteger(0, CHART_EVENT_MOUSE_MOVE, true);
   ChartSetInteger(0, CHART_EVENT_MOUSE_WHEEL, true);
   ChartSetInteger(0, CHART_KEYBOARD_CONTROL, false);
   if(InpHideNativeChart)
      ChartSetInteger(0, CHART_SHOW, false);
}

void RestoreChart(void)
{
   if(!g_saved)
      return;
   ChartSetInteger(0, CHART_FOREGROUND, g_pFore);
   ChartSetInteger(0, CHART_SHOW_GRID, g_pGrid);
   ChartSetInteger(0, CHART_SHOW_OHLC, g_pOHLC);
   ChartSetInteger(0, CHART_SHOW_ONE_CLICK, g_pOneClick);
   ChartSetInteger(0, CHART_MOUSE_SCROLL, g_pMouseScroll);
   ChartSetInteger(0, CHART_EVENT_MOUSE_MOVE, g_pEvMove);
   ChartSetInteger(0, CHART_EVENT_MOUSE_WHEEL, g_pEvWheel);
   ChartSetInteger(0, CHART_KEYBOARD_CONTROL, g_pKeys);
   if(InpHideNativeChart)
      ChartSetInteger(0, CHART_SHOW, g_pShow);
   g_saved = false;
}

//+------------------------------------------------------------------+
//| canvas size                                                       |
//+------------------------------------------------------------------+
bool CheckSize(void)
{
   if(!g_canvasOk)
      return false;
   int w = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
   int h = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS, 0);
   if(w <= 0 || h <= 0)
      return false;
   if(w == g_W && h == g_H)
      return false;
   if(!g_ctx.cv.Resize(w, h))
      return false;
   g_W = w;
   g_H = h;
   return true;
}

//+------------------------------------------------------------------+
//| shared market values (session POC, VWAP, session buy/sell)        |
//+------------------------------------------------------------------+
void RefreshMarket(void)
{
   g_ctx.mkt.ready = g_engine.HistoryReady();
   CFPBar *f = g_engine.At(0);
   datetime ref = (f != NULL) ? f.time : TimeTradeServer();
   g_ctx.mkt.sessStart = g_engine.SessionStart(ref);
   g_ctx.mkt.pocOk = false;
   g_ctx.mkt.sessBuy = 0.0;
   g_ctx.mkt.sessSell = 0.0;
   g_ctx.mkt.vwap = 0.0;
   if(g_ctx.mkt.ready)
     {
      FPProfile p;
      if(g_engine.SessionProfile(g_ctx.mkt.sessStart, p) && p.pocIdx >= 0 && p.rows > 0)
        {
         g_ctx.mkt.pocOk = true;
         g_ctx.mkt.pocRow = p.rowLow + p.pocIdx;
         g_ctx.mkt.pocPrice = g_engine.RowToPrice(g_ctx.mkt.pocRow);
         for(int k = 0; k < p.rows; k++)
           {
            g_ctx.mkt.sessBuy += p.buy[k];
            g_ctx.mkt.sessSell += p.sell[k];
           }
        }
      g_ctx.mkt.vwap = g_engine.SessionVWAP(g_ctx.mkt.sessStart);
     }
   CFPBar *l = g_engine.At(1);
   g_ctx.mkt.lastClosed = (l != NULL) ? l.time : 0;
   //--- history progress
   int n = g_engine.Total(), pend = 0;
   int oldest = (f == NULL) ? n : n - 1;
   for(int sh = 1; sh <= oldest; sh++)
     {
      CFPBar *b = g_engine.At(sh);
      if(b != NULL && b.state == 1)
         pend++;
     }
   g_ctx.mkt.total = MathMax(0, oldest);
   g_ctx.mkt.loaded = g_ctx.mkt.total - pend;
   if(g_ctx.mkt.loaded != g_lastLoaded)
     {
      g_lastLoaded = g_ctx.mkt.loaded;
      g_bufFull = true;
     }
   g_lastMktMs = GetTickCount64();
}

//+------------------------------------------------------------------+
//| data-window buffers                                               |
//+------------------------------------------------------------------+
void FillOne(CFPBar *b)
{
   int sz = ArraySize(g_bVol);
   int shift = iBarShift(_Symbol, _Period, b.time, true);
   if(shift < 0)
      return;
   int idx = sz - 1 - shift;
   if(idx < 0 || idx >= sz)
      return;
   if(b.state != 0)
     {
      g_bVol[idx] = EMPTY_VALUE;
      g_bDelta[idx] = EMPTY_VALUE;
      g_bCum[idx] = EMPTY_VALUE;
      g_bPoc[idx] = EMPTY_VALUE;
      g_bBuyImb[idx] = EMPTY_VALUE;
      g_bSellImb[idx] = EMPTY_VALUE;
      g_bBuyStk[idx] = EMPTY_VALUE;
      g_bSellStk[idx] = EMPTY_VALUE;
      return;
     }
   g_bVol[idx] = b.volume;
   g_bDelta[idx] = b.delta;
   g_bCum[idx] = (g_ready && b.cvdValid) ? b.cumDelta : EMPTY_VALUE;
   g_bPoc[idx] = (b.pocIdx >= 0 && b.rows > 0) ? g_engine.RowToPrice(b.rowLow + b.pocIdx) : EMPTY_VALUE;
   int bi = 0, si = 0;
   for(int k = 0; k < b.rows; k++)
     {
      if(b.imbBuy[k] >= 1)
         bi++;
      if(b.imbSell[k] >= 1)
         si++;
     }
   g_bBuyImb[idx] = bi;
   g_bSellImb[idx] = si;
   FPZone z[];
   int nz = CFPAnalytics::FindStacks(b, g_ctx.cfg, g_engine.RowSize(), z);
   int bs = 0, ss = 0;
   for(int i = 0; i < nz; i++)
     {
      if(z[i].dir > 0)
         bs += z[i].rowsCount;
      else
         ss += z[i].rowsCount;
     }
   g_bBuyStk[idx] = bs;
   g_bSellStk[idx] = ss;
}

void FillBuffers(const bool full)
{
   int sz = ArraySize(g_bVol);
   if(sz <= 0)
      return;
   if(iBars(_Symbol, _Period) != sz)
      return;   // a new chart bar is not in the buffers yet; the next OnCalculate fills it
   int n = g_engine.Total();
   int oldest = (g_engine.At(0) == NULL) ? n : n - 1;
   int last = full ? oldest : MathMin(oldest, 2);
   for(int sh = 0; sh <= last; sh++)
     {
      CFPBar *b = g_engine.At(sh);
      if(b != NULL)
         FillOne(b);
     }
   if(full)
      g_bufFull = false;
}

//+------------------------------------------------------------------+
//| alerts: once per closed bar per type, live bars only (02 §10)     |
//+------------------------------------------------------------------+
void Fire(const string msg)
{
   if(InpAlertPopup)
      Alert(msg);
   else
     {
      Print(msg);
      if(InpAlertSound != "")
         PlaySound(InpAlertSound);
     }
}

void BarAlerts(const datetime t)
{
   if(!InpAlertStack && InpAlertDeltaAbove <= 0.0 && InpAlertDeltaBelow == 0.0)
      return;
   if((long)TimeTradeServer() - ((long)t + PeriodSeconds()) > 2L * PeriodSeconds())
      return;   // stale (e.g. after a reconnect): never alert from history
   CFPBar *b = g_engine.ByTime(t);
   if(b == NULL || b.state != 0 || b.rows <= 0)
      return;
   string head = _Symbol + " " + g_ctx.tfName + " - ";
   string hm = TimeToString(t, TIME_MINUTES);
   if(InpAlertStack)
     {
      FPZone z[];
      int nz = CFPAnalytics::FindStacks(b, g_ctx.cfg, g_engine.RowSize(), z);
      int best[2] = {-1, -1};
      for(int i = 0; i < nz; i++)
        {
         int k = (z[i].dir > 0) ? 0 : 1;
         if(best[k] < 0 || z[i].rowsCount > z[best[k]].rowsCount)
            best[k] = i;
        }
      for(int k = 0; k < 2; k++)
         if(best[k] >= 0)
           {
            int i = best[k];
            Fire(head + "Stacked imbalance, " + hm + " candle: " + ((z[i].dir > 0) ? "STACKED BUYERS " : "STACKED SELLERS ") +
                 IntegerToString(z[i].rowsCount) + " rows " + DoubleToString(z[i].priceLow, _Digits) + "-" + DoubleToString(z[i].priceHigh, _Digits));
           }
     }
   if(InpAlertDeltaAbove > 0.0 && b.delta >= InpAlertDeltaAbove)
      Fire(head + "Delta above " + DoubleToString(InpAlertDeltaAbove, 0) + ", " + hm + " candle: delta " + g_ctx.SVol(b.delta));
   if(InpAlertDeltaBelow != 0.0 && b.delta <= -MathAbs(InpAlertDeltaBelow))
      Fire(head + "Delta below -" + DoubleToString(MathAbs(InpAlertDeltaBelow), 0) + ", " + hm + " candle: delta " + g_ctx.SVol(b.delta));
}

//+------------------------------------------------------------------+
//| periodic work (timer, or OnCalculate in the tester)               |
//+------------------------------------------------------------------+
void OnHistoryReady(void)
{
   RefreshMarket();
   g_bufFull = true;
   g_analystDue = true;
   g_lastMeterMs = 0;
   g_pan.Invalidate();
   g_ren.InvalidateSD();
   g_dirty = true;
}

void ProcessClosedBars(void)
{
   datetime t;
   bool any = false;
   while(g_engine.PopClosedBar(t))
     {
      any = true;
      if(g_ready)
         BarAlerts(t);
     }
   if(any)
     {
      RefreshMarket();
      g_lastStudyMs = 0;
      g_lastMeterMs = 0;
      g_analystDue = true;
      g_pan.Invalidate();
      g_ren.InvalidateSD();
      g_dirty = true;
     }
}

datetime OldestHeldTime(void)
{
   int n = g_engine.Total();
   int oldest = (g_engine.At(0) == NULL) ? n : n - 1;
   CFPBar *b = g_engine.At(oldest);
   if(b == NULL)
      return TimeTradeServer() - 2 * 86400;
   return b.time;
}

void Periodic(void)
{
   ulong now = GetTickCount64();
   ulong p0 = GetMicrosecondCount();
   if(g_lastMktMs == 0 || now - g_lastMktMs >= (g_ready ? 5000UL : 1000UL))
     {
      RefreshMarket();
      g_dirty = true;
     }
   ulong p1 = GetMicrosecondCount();
   if(g_lastStudyMs == 0 || now - g_lastStudyMs >= 1000)
     {
      g_lastStudyMs = now;
      g_st.Refresh();
      FPComputeFlow(GetPointer(g_ctx), g_flow);
      g_dirty = true;
     }
   ulong p2 = GetMicrosecondCount();
   if(g_lastMeterMs == 0 || now - g_lastMeterMs >= 2000)
     {
      g_lastMeterMs = now;
      g_meter.Compute(GetPointer(g_ctx), g_st, g_flow);
      g_dirty = true;
     }
   if(g_lastBookMs == 0 || (g_bookDirty && now - g_lastBookMs >= 200) || now - g_lastBookMs >= 2000)
     {
      g_lastBookMs = now;
      g_bookDirty = false;
      g_book.Refresh();
      g_dirty = true;
     }
   ulong p3 = GetMicrosecondCount();
   if(g_analystDue || g_lastAnalystMs == 0 || now - g_lastAnalystMs >= (ulong)g_ctx.set.analystRefreshSec * 1000)
     {
      g_analystDue = false;
      g_lastAnalystMs = now;
      FPComputeFlow(GetPointer(g_ctx), g_flow);
      g_ana.Compute(g_st, g_book, g_flow);
      g_dirty = true;
     }
   ulong p4 = GetMicrosecondCount();
   if(g_ctx.set.showTrades && g_trades.Poll(OldestHeldTime(), false))
      g_dirty = true;
   ulong p5 = GetMicrosecondCount();
   g_periodicNote = StringFormat("market %.1f, studies %.1f, meter+book %.1f, analyst %.1f, trades %.1f",
                                 (p1 - p0) / 1000.0, (p2 - p1) / 1000.0, (p3 - p2) / 1000.0, (p4 - p3) / 1000.0, (p5 - p4) / 1000.0);
   long sec = (long)TimeLocal();
   if(sec != g_lastSecond)
     {
      g_lastSecond = sec;
      g_dirty = true;   // countdown, "Updated Ns ago"
     }
}

string StatusText(void)
{
   string src;
   switch(g_engine.ActiveSource())
     {
      case FP_SRC_EXCHANGE_FLAGS: src = "EXCHANGE flags"; break;
      case FP_SRC_TRADE_TICKS:    src = "TRADE ticks"; break;
      case FP_SRC_QUOTE_TICKS:    src = "QUOTE ticks (volume = tick count)"; break;
      default:                    src = "source pending"; break;
     }
   string s = src + "  |  row " + DoubleToString(g_engine.RowSize(), _Digits) + "  |  ";
   if(g_ready)
      s += IntegerToString(g_ctx.mkt.total) + " bars";
   else
      s += "loading " + IntegerToString(g_ctx.mkt.loaded) + "/" + IntegerToString(g_ctx.mkt.total);
   s += "  |  " + DoubleToString(g_drawLastUs / 1000.0, 1) + " ms";
   if(g_ctx.view.scroll > 0)
      s += "  |  " + IntegerToString(g_ctx.view.scroll) + " bars back";
   if(g_ctx.tester)
      s += "  |  tester: buttons inactive";
   return s;
}

void Draw(void)
{
   if(!g_draw || !g_canvasOk)
      return;
   ulong us0 = GetMicrosecondCount();
   CheckSize();
   if(g_W <= 0 || g_H <= 0)
      return;
   g_ctx.lay.ClearButtons();
   g_ctx.lay.Compute(g_W, g_H, g_ctx.s, g_ctx.view, g_ctx.set);
   g_ctx.cv.Erase(g_ctx.pal.bg);
   g_ren.Prepare();
   g_ren.DrawFootprint();
   ulong us1 = GetMicrosecondCount();
   string status = StatusText();
   bool statusInTabs = g_ctx.view.tabsOn && g_ctx.cv.TxtW(g_ctx.fTiny, status) < g_ctx.lay.fp.w / 3;
   if(!statusInTabs)
      g_ren.DrawStatus(status);
   g_ren.DrawTable();
   g_pan.DrawMini();
   g_pan.DrawHeader();
   if(!g_pan.DrawTabs(status) && statusInTabs)
      g_ren.DrawStatus(status);
   ulong us2 = GetMicrosecondCount();
   g_pan.DrawSide();
   ulong us3 = GetMicrosecondCount();
   g_ctx.cv.Update(true);
   ulong us = GetMicrosecondCount() - us0;
   g_secUs[0] += us1 - us0;
   g_secUs[1] += us2 - us1;
   g_secUs[2] += us3 - us2;
   g_secUs[3] += GetMicrosecondCount() - us3;
   g_drawLastUs = us;
   g_drawSumUs += us;
   g_drawMaxUs = MathMax(g_drawMaxUs, us);
   g_drawFrames++;
   g_drawTotal++;
   if(g_drawFrames >= 100)
     {
      g_drawAvgMs = g_drawSumUs / 1000.0 / g_drawFrames;
      double fdiv = 1000.0 * g_drawFrames;
      PrintFormat("OrderFlowFP UI: draw avg %.2f ms, max %.2f ms over %d frames (%dx%d, %d bars visible, zoom %d) | footprint %.2f, table+chrome %.2f, side %.2f, update %.2f ms",
                  g_drawAvgMs, g_drawMaxUs / 1000.0, g_drawFrames, g_W, g_H, g_ren.VisibleCount(), g_ctx.view.zoom,
                  g_secUs[0] / fdiv, g_secUs[1] / fdiv, g_secUs[2] / fdiv, g_secUs[3] / fdiv);
      ArrayInitialize(g_secUs, 0);
      g_drawSumUs = 0;
      g_drawMaxUs = 0;
      g_drawFrames = 0;
     }
   g_lastDrawMs = GetTickCount64();
   g_dirty = false;
   //--- machine-readable status on the canvas object (read by the FPShot script)
   if(g_lastDrawMs - g_lastStatusMs >= 1000)
     {
      g_lastStatusMs = g_lastDrawMs;
      double avg = (g_drawFrames > 0) ? g_drawSumUs / 1000.0 / g_drawFrames : g_drawAvgMs;
      ObjectSetString(0, g_objName, OBJPROP_TEXT, "ready=" + (g_ready ? "1" : "0") + " frames=" + IntegerToString(g_drawTotal) +
                      " avgms=" + DoubleToString(avg, 2) + " lastms=" + DoubleToString(us / 1000.0, 2) +
                      " loaded=" + IntegerToString(g_ctx.mkt.loaded) + "/" + IntegerToString(g_ctx.mkt.total));
     }
}

//--- one scheduling step: load/update, events, periodic work, throttled draw
void Step(void)
{
   ulong stepUs0 = GetMicrosecondCount();
   bool wasLoading = !g_ready;
   ulong now = GetTickCount64();
   ulong interval = g_ready ? (ulong)g_ctx.set.redrawMs : 250UL;
   bool drawDue = g_dirty && (now - g_lastDrawMs >= interval);
   uint budget = (uint)(drawDue ? MathMin(15, g_ctx.set.loadBudgetMs) : g_ctx.set.loadBudgetMs);
   ulong tA = GetMicrosecondCount();
   bool r = g_engine.LoadStep(budget);
   ulong tB = GetMicrosecondCount();
   if(r && !g_ready)
     {
      g_ready = true;
      OnHistoryReady();
      if(g_loadSteps > 0)
         PrintFormat("OrderFlowFP UI: history ready after %.1f s | %d timer steps while loading: avg %.1f ms, max %.1f ms (load budget %d ms) | worst step: %s",
                     (GetTickCount64() - g_initMs) / 1000.0, g_loadSteps, g_loadStepUs / 1000.0 / g_loadSteps, g_loadStepMaxUs / 1000.0,
                     g_ctx.set.loadBudgetMs, g_worstStep);
     }
   else
      if(!r && g_ready)
        {
         g_ready = false;   // reconnect: nodata bars are being retried
         g_dirty = true;
        }
   if(!g_ready)
      g_dirty = true;
   ProcessClosedBars();
   ulong tC = GetMicrosecondCount();
   Periodic();
   ulong tD = GetMicrosecondCount();
   if(!g_ctx.tester && CheckSize())
      g_dirty = true;
   if(g_bufFull && g_ready)
      FillBuffers(true);
   now = GetTickCount64();
   if(g_dirty && now - g_lastDrawMs >= interval)
      Draw();
   if(wasLoading && !g_ready)
     {
      ulong us = GetMicrosecondCount() - stepUs0;
      g_loadSteps++;
      g_loadStepUs += us;
      if(us > g_loadStepMaxUs)
        {
         g_loadStepMaxUs = us;
         g_worstStep = StringFormat("engine LoadStep %.1f, closed bars %.1f, periodic %.1f (%s), buffers+draw %.1f ms",
                                    (tB - tA) / 1000.0, (tC - tB) / 1000.0, (tD - tC) / 1000.0, g_periodicNote,
                                    (GetMicrosecondCount() - tD) / 1000.0);
        }
     }
}

//+------------------------------------------------------------------+
//| view actions                                                      |
//+------------------------------------------------------------------+
void ResetView(void)
{
   g_ctx.view.zoom = g_ctx.set.rowHeight;
   g_ctx.view.scroll = 0;
   g_ctx.view.anchor = 0;
   g_ctx.view.live = true;
   g_ctx.view.vAuto = true;
   g_ctx.view.centred = false;
}

void SetZoom(const int z)
{
   g_ctx.view.zoom = MathMax(6, MathMin(40, z));
}

void ScrollBars(const int d)
{
   int ns = g_ctx.view.scroll + d;
   int ms = g_ren.MaxScroll();
   ns = MathMax(0, MathMin(ms, ns));
   g_ctx.view.scroll = ns;
   CFPBar *b = g_engine.At(ns);
   g_ctx.view.anchor = (ns > 0 && b != NULL) ? b.time : 0;
   g_ctx.view.live = (ns == 0);
}

void MoveVertical(const int px)
{
   int rp = MathMax(2, g_ctx.Px(g_ctx.view.zoom));
   g_ctx.view.centerRow += (double)px / rp;
   g_ctx.view.vAuto = false;
}

void OnButton(const int id)
{
   switch(id)
     {
      case FPB_SD:
         g_ctx.view.sdOn = !g_ctx.view.sdOn;
         g_ren.InvalidateSD();
         break;
      case FPB_MINI:
         g_ctx.view.miniOn = !g_ctx.view.miniOn;
         break;
      case FPB_RESET:
        {
         ResetView();
         //--- RESET also retries 'nodata' bars (02 §5.5): rebuild the engine when any exists
         bool nod = false;
         int n = g_engine.Total();
         for(int sh = 1; sh <= n && !nod; sh++)
           {
            CFPBar *b = g_engine.At(sh);
            if(b != NULL && b.state == 2)
               nod = true;
           }
         if(nod)
           {
            Print("OrderFlowFP UI: RESET - rebuilding history to retry nodata bars");
            if(g_engine.Init(g_ctx.cfg))
              {
               g_ready = false;
               g_bufFull = true;
               g_lastLoaded = -1;
              }
           }
         break;
        }
      case FPB_ZOOMIN:
         SetZoom(g_ctx.view.zoom + 2);
         break;
      case FPB_ZOOMOUT:
         SetZoom(g_ctx.view.zoom - 2);
         break;
      case FPB_UP:
         MoveVertical(g_ctx.Px(80));
         break;
      case FPB_DOWN:
         MoveVertical(-g_ctx.Px(80));
         break;
      case FPB_BARVP:
         g_ctx.view.barVPOn = !g_ctx.view.barVPOn;
         break;
      case FPB_DELTA:
         g_ctx.view.deltaOn = !g_ctx.view.deltaOn;
         break;
      case FPB_SIDE:
        {
         bool eff = g_ctx.lay.sideOn;
         g_ctx.view.sideOn = !eff;
         g_ctx.view.sideForced = !eff;
         break;
        }
      case FPB_LIVE:
         g_ctx.view.scroll = 0;
         g_ctx.view.anchor = 0;
         g_ctx.view.live = true;
         g_ctx.view.vAuto = true;
         g_ctx.view.centred = false;
         break;
      case FPB_TABS_TOGGLE:
         g_ctx.view.tabsOn = !g_ctx.view.tabsOn;
         break;
      case FPB_TABLE_TOGGLE:
         g_ctx.view.tableOn = !g_ctx.view.tableOn;
         break;
      default:
         break;   // style tabs: only MINIMALIST is implemented
     }
   g_dirty = true;
   Draw();
}

//+------------------------------------------------------------------+
//| OnInit                                                            |
//+------------------------------------------------------------------+
int OnInit(void)
{
   g_initMs = GetTickCount64();
   g_ctx.tester = (MQLInfoInteger(MQL_TESTER) != 0);
   g_draw = !g_ctx.tester || (MQLInfoInteger(MQL_VISUAL_MODE) != 0);
   FPConfig cfg;
   FillConfig(cfg);
   if(!g_engine.Init(cfg))
     {
      Print("OrderFlowFP UI: engine Init failed: ", g_engine.LastError());
      return INIT_FAILED;
     }
   //--- buffers
   SetIndexBuffer(0, g_bVol, INDICATOR_DATA);
   SetIndexBuffer(1, g_bDelta, INDICATOR_DATA);
   SetIndexBuffer(2, g_bCum, INDICATOR_DATA);
   SetIndexBuffer(3, g_bPoc, INDICATOR_DATA);
   SetIndexBuffer(4, g_bBuyImb, INDICATOR_DATA);
   SetIndexBuffer(5, g_bSellImb, INDICATOR_DATA);
   SetIndexBuffer(6, g_bBuyStk, INDICATOR_DATA);
   SetIndexBuffer(7, g_bSellStk, INDICATOR_DATA);
   for(int i = 0; i < 8; i++)
      PlotIndexSetDouble(i, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   ArraySetAsSeries(g_bVol, false);
   ArraySetAsSeries(g_bDelta, false);
   ArraySetAsSeries(g_bCum, false);
   ArraySetAsSeries(g_bPoc, false);
   ArraySetAsSeries(g_bBuyImb, false);
   ArraySetAsSeries(g_bSellImb, false);
   ArraySetAsSeries(g_bBuyStk, false);
   ArraySetAsSeries(g_bSellStk, false);
   IndicatorSetString(INDICATOR_SHORTNAME, "OrderFlowFP Footprint");
   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);
   //--- context
   g_ctx.engine   = GetPointer(g_engine);
   g_ctx.cfg      = cfg;
   g_ctx.cfg.bucketPoints = (int)MathRound(g_engine.RowSize() / MathMax(_Point, 1e-12));
   g_ctx.sym      = _Symbol;
   g_ctx.tf       = (ENUM_TIMEFRAMES)_Period;
   g_ctx.period   = PeriodSeconds(g_ctx.tf);
   g_ctx.digits   = _Digits;
   g_ctx.point    = _Point;
   g_ctx.tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(g_ctx.tickSize <= 0.0)
      g_ctx.tickSize = _Point;
   g_ctx.rowSize  = g_engine.RowSize();
   g_ctx.tfName   = FPUITfName(g_ctx.tf);
   FillSettings(g_ctx.set);
   double dpi = (double)TerminalInfoInteger(TERMINAL_SCREEN_DPI);
   if(dpi <= 0.0)
      dpi = 96.0;
   g_ctx.s = g_ctx.set.uiScalePct / 100.0 * dpi / 96.0;
   //--- view
   g_ctx.view.zoom = g_ctx.set.rowHeight;
   g_ctx.view.scroll = 0;
   g_ctx.view.anchor = 0;
   g_ctx.view.live = true;
   g_ctx.view.centerRow = 0.0;
   g_ctx.view.vAuto = true;
   g_ctx.view.centred = false;
   g_ctx.view.sideOn = g_ctx.set.showSide;
   g_ctx.view.sideForced = false;
   g_ctx.view.miniOn = g_ctx.set.showMini;
   g_ctx.view.deltaOn = g_ctx.set.showDeltaBars;
   g_ctx.view.barVPOn = g_ctx.set.showBarVP;
   g_ctx.view.sdOn = g_ctx.set.showSD;
   g_ctx.view.tabsOn = true;
   g_ctx.view.tableOn = g_ctx.set.showTable;
   g_ctx.view.panelTheme = g_ctx.set.panelTheme;
   g_ctx.view.colorTheme = g_ctx.set.colorTheme;
   ZeroMemory(g_ctx.mkt);
   BuildPalette();
   if(InpStyle != FP_STYLE_MINIMALIST)
      Print("OrderFlowFP UI: style ", EnumToString(InpStyle), " is not implemented - drawing MINIMALIST");
   if(InpShowFundamentals)
      Print("OrderFlowFP UI: the Fundamentals panel is not implemented (MAY item)");
   //--- components
   g_st.Init(GetPointer(g_ctx));
   g_book.Init(_Symbol, InpUseMarketBook, g_ctx.tester);
   g_trades.Init(_Symbol, InpTradeMagic);
   g_ana.Init(GetPointer(g_ctx));
   g_pan.Init(GetPointer(g_ctx), GetPointer(g_st), GetPointer(g_book), GetPointer(g_meter), GetPointer(g_ana));
   g_ren.Init(GetPointer(g_ctx), GetPointer(g_trades));
   //--- canvas: one bitmap label over the whole chart area
   if(g_draw)
     {
      SaveAndSetChart();
      g_W = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
      g_H = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS, 0);
      if(g_W <= 0)
         g_W = 800;
      if(g_H <= 0)
         g_H = 600;
      g_objName = "OFPFC_" + IntegerToString((long)(GetMicrosecondCount() % 100000000));
      g_canvasOk = g_ctx.cv.CreateBitmapLabel(0, 0, g_objName, 0, 0, g_W, g_H, COLOR_FORMAT_XRGB_NOALPHA);
      if(!g_canvasOk)
        {
         Print("OrderFlowFP UI: canvas creation failed (", GetLastError(), ")");
         RestoreChart();
         g_engine.Deinit();
         return INIT_FAILED;
        }
      ObjectSetInteger(0, g_objName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, g_objName, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, g_objName, OBJPROP_BACK, false);
      ObjectSetString(0, g_objName, OBJPROP_TOOLTIP, "\n");
      ObjectSetString(0, g_objName, OBJPROP_TEXT, "ready=0 frames=0");
      g_ctx.BuildFonts();
     }
   if(!g_ctx.tester)
      EventSetMillisecondTimer(50);
   Print("OrderFlowFP UI: started on ", _Symbol, " ", g_ctx.tfName, " | scale ", DoubleToString(g_ctx.s, 2),
         " (DPI ", DoubleToString(dpi, 0), ") | trades overlay ", (InpShowTrades ? ("magic " + IntegerToString(InpTradeMagic)) : "off"));
   g_dirty = true;
   Draw();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   g_st.Deinit();
   g_book.Deinit();
   if(g_canvasOk)
      g_ctx.cv.Destroy();
   g_canvasOk = false;
   RestoreChart();
   g_engine.Deinit();
   if(g_drawTotal > 0)
      PrintFormat("OrderFlowFP UI: stopped (reason %d) after %d frames", reason, g_drawTotal);
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total, const int prev_calculated, const datetime &time[], const double &open[],
                const double &high[], const double &low[], const double &close[], const long &tick_volume[],
                const long &volume[], const int &spread[])
{
   if(prev_calculated <= 0 || rates_total - prev_calculated > 1)
     {
      ArrayInitialize(g_bVol, EMPTY_VALUE);
      ArrayInitialize(g_bDelta, EMPTY_VALUE);
      ArrayInitialize(g_bCum, EMPTY_VALUE);
      ArrayInitialize(g_bPoc, EMPTY_VALUE);
      ArrayInitialize(g_bBuyImb, EMPTY_VALUE);
      ArrayInitialize(g_bSellImb, EMPTY_VALUE);
      ArrayInitialize(g_bBuyStk, EMPTY_VALUE);
      ArrayInitialize(g_bSellStk, EMPTY_VALUE);
      g_bufFull = true;
     }
   else
      if(rates_total > prev_calculated)
        {
         //--- new chart bar: its slot starts empty
         int i = rates_total - 1;
         g_bVol[i] = EMPTY_VALUE;
         g_bDelta[i] = EMPTY_VALUE;
         g_bCum[i] = EMPTY_VALUE;
         g_bPoc[i] = EMPTY_VALUE;
         g_bBuyImb[i] = EMPTY_VALUE;
         g_bSellImb[i] = EMPTY_VALUE;
         g_bBuyStk[i] = EMPTY_VALUE;
         g_bSellStk[i] = EMPTY_VALUE;
        }
   if(g_ctx.tester)
      Step();   // indicators get no timer events in the tester
   else
      if(g_engine.Update() > 0)
         g_dirty = true;
   FillBuffers(g_bufFull && g_ready);
   return rates_total;
}

void OnTimer(void)
{
   Step();
}

void OnBookEvent(const string &symbol)
{
   if(symbol == _Symbol)
      g_bookDirty = true;
}

//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(!g_canvasOk)
      return;
   if(id == CHARTEVENT_CHART_CHANGE)
     {
      if(CheckSize())
         g_dirty = true;
      g_dirty = true;
      Draw();
      return;
     }
   if(id == CHARTEVENT_CLICK)
     {
      if(g_dragMoved)
        {
         g_dragMoved = false;
         return;
        }
      int b = g_ctx.lay.HitTest((int)lparam, (int)dparam);
      if(b != FPB_NONE)
         OnButton(b);
      return;
     }
   if(id == CHARTEVENT_MOUSE_MOVE)
     {
      int x = (int)lparam, y = (int)dparam;
      uint st = (uint)StringToInteger(sparam);
      bool left = ((st & 1) != 0);
      if(!left)
        {
         g_drag = false;
         return;
        }
      if(!g_drag)
        {
         if(!FPRectHit(g_ctx.lay.plot, x, y))
            return;
         g_drag = true;
         g_dragMoved = false;
         g_dragX0 = x;
         g_dragY0 = y;
         g_dragScroll0 = g_ctx.view.scroll;
         g_dragCenter0 = g_ctx.view.centerRow;
         return;
        }
      int dx = x - g_dragX0, dy = y - g_dragY0;
      if(MathAbs(dx) + MathAbs(dy) > 3)
         g_dragMoved = true;
      if(!g_dragMoved)
         return;
      int pitch = MathMax(1, g_ctx.lay.pitch);
      int target = g_dragScroll0 + (int)MathRound((double)dx / pitch);
      ScrollBars(target - g_ctx.view.scroll);
      if(MathAbs(dy) > 4)
        {
         int rp = MathMax(2, g_ctx.Px(g_ctx.view.zoom));
         g_ctx.view.centerRow = g_dragCenter0 + (double)dy / rp;
         g_ctx.view.vAuto = false;
        }
      g_dirty = true;
      if(GetTickCount64() - g_lastDrawMs >= 30)
         Draw();
      return;
     }
   if(id == CHARTEVENT_MOUSE_WHEEL)
     {
      int x = (int)(short)lparam;
      int y = (int)(short)(lparam >> 16);
      int keys = (int)(lparam >> 32);
      int delta = (int)dparam;
      if(!FPRectHit(g_ctx.lay.fp, x, y))
         return;
      int notches = delta / 120;
      if(notches == 0)
         notches = (delta > 0) ? 1 : -1;
      if((keys & 0x0004) != 0)
         ScrollBars(notches * 3);
      else
         SetZoom(g_ctx.view.zoom + notches);
      g_dirty = true;
      Draw();
      return;
     }
   //--- test hooks (used by Scripts\OrderFlowFP\FPShot): EventChartCustom(chart, 7701, buttonId) / (chart, 7702, keyCode)
   if(id == CHARTEVENT_CUSTOM + 7701)
     {
      OnButton((int)lparam);
      return;
     }
   if(id == CHARTEVENT_CUSTOM + 7702)
     {
      HandleKey((int)lparam);
      return;
     }
   if(id == CHARTEVENT_KEYDOWN)
      HandleKey((int)lparam);
}

void HandleKey(const int key)
{
      bool handled = true;
      switch(key)
        {
         case 36:   // Home
            OnButton(FPB_LIVE);
            return;
         case 84:   // T: next bull/bear theme
            g_ctx.view.colorTheme = (g_ctx.view.colorTheme + 1) % FP_COLOR_THEMES;
            BuildPalette();
            Print("OrderFlowFP UI: theme ", CFPTheme::AccentName(g_ctx.view.colorTheme), (g_ctx.view.panelTheme == FP_PANEL_LIGHT) ? " / Light" : " / Dark");
            break;
         case 76:   // L: Dark <-> Light
            g_ctx.view.panelTheme = (g_ctx.view.panelTheme == FP_PANEL_LIGHT) ? FP_PANEL_DARK : FP_PANEL_LIGHT;
            BuildPalette();
            break;
         case 37:   // Left: older bars
            ScrollBars(1);
            break;
         case 39:   // Right: newer bars
            ScrollBars(-1);
            break;
         case 38:   // Up
            MoveVertical(g_ctx.Px(80));
            break;
         case 40:   // Down
            MoveVertical(-g_ctx.Px(80));
            break;
         case 107:  // numpad +
         case 187:  // '=' / '+'
            SetZoom(g_ctx.view.zoom + 2);
            break;
         case 109:  // numpad -
         case 189:  // '-'
            SetZoom(g_ctx.view.zoom - 2);
            break;
         default:
            handled = false;
            break;
        }
      if(handled)
        {
         g_dirty = true;
         Draw();
        }
}
//+------------------------------------------------------------------+
