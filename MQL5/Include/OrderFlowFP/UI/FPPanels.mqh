//+------------------------------------------------------------------+
//| FPPanels.mqh - OrderFlowFP UI: header (§8.3), style tabs (§8.4),   |
//| mini session chart (§8.6) and the right-side panels (§8.8 a-e):    |
//| VP Total, Time & Sales + Bar Totals, RSI/MACD minis, DOM ladder,   |
//| Signal Meter. The Chart Analyst lives in FPAnalyst.mqh.            |
//+------------------------------------------------------------------+
#ifndef ORDERFLOWFP_UI_FPPANELS_MQH
#define ORDERFLOWFP_UI_FPPANELS_MQH

#include "FPAnalyst.mqh"
#include "..\FPStatus.mqh"

class CFPPanels
{
private:
   CFPContext       *m_ctx;
   CFPStudies       *m_st;
   CFPBook          *m_book;
   CFPMeter         *m_meter;
   CFPAnalyst       *m_ana;
   //--- mini chart cache
   double            m_miniC[];
   int               m_miniN;
   double            m_miniOpen;
   ulong             m_miniMs;
   datetime          m_miniSess;
   //--- VP cache
   FPProfile         m_vp;
   bool              m_vpOk;
   ulong             m_vpMs;
   //--- RSI / MACD cache
   double            m_rsi[];
   double            m_mm[];
   double            m_ms[];
   int               m_rsiN, m_macdN;
   ulong             m_studyMs;
   //--- T&S auto big size
   double            m_bigAuto;
   ulong             m_bigMs;

   //--- header button: bordered box, active text blue, disabled greyed
   int               Button(const int x, const int y, const int h, const string text, const int id,
                            const bool active, const bool enabled, const int minW)
     {
      CFPContext *c = m_ctx;
      int w = MathMax(minW, c.cv.TxtW(c.fBtn, text) + 2 * c.Px(12));
      c.cv.Box(x, y, w, h, c.pal.btnBg);
      c.cv.Frame(x, y, w, h, c.pal.border);
      uint col = c.pal.text2;
      if(!enabled || c.tester)       // tester: indicators get no chart events -> buttons shown inactive
         col = c.pal.textOff;
      else
         if(active)
            col = c.pal.blue;
      c.cv.Txt(c.fBtn, x + w / 2, y + h / 2, text, col, TA_CENTER | TA_VCENTER);
      c.lay.AddButton(id, x, y, w, h, enabled && !c.tester);
      return w;
     }
   //--- FootprintTrader status (FPStatus.mqh heartbeat of the EA with the overlay magic): filled badge,
   //--- green = live and trading, blue = signals only / virtual, orange = entries blocked now, red = off/stopped.
   //--- Read-only: the indicator never trades and the EA never reads the indicator.
   int               DrawEABadge(const int x, const int y, const int h)
     {
      CFPContext *c = m_ctx;
      if(c.set.tradeMagic < 0)
         return 0;
      FTStatus st;
      FTSRead(c.sym, c.set.tradeMagic, st);
      int sev = FTS_SEV_BAD;
      string text = FTSDescribe(st, sev);
      uint bg = c.pal.cdRed;
      if(sev == FTS_SEV_OK)
         bg = FPRGB(22, 163, 74);
      else
         if(sev == FTS_SEV_INFO)
            bg = c.pal.blue;
         else
            if(sev == FTS_SEV_WARN)
               bg = c.pal.cdOrange;
      int w = c.cv.TxtW(c.fBtn, text) + 2 * c.Px(12);
      c.cv.Box(x, y, w, h, bg);
      c.cv.Txt(c.fBtn, x + w / 2, y + h / 2, text, FPRGB(255, 255, 255), TA_CENTER | TA_VCENTER);
      return w;
     }
   int               BtnW(const string text, const int minW)
     {
      return MathMax(minW, m_ctx.cv.TxtW(m_ctx.fBtn, text) + 2 * m_ctx.Px(12));
     }

public:
                     CFPPanels(void) : m_ctx(NULL), m_st(NULL), m_book(NULL), m_meter(NULL), m_ana(NULL), m_miniN(0), m_miniOpen(0.0),
                                       m_miniMs(0), m_miniSess(0), m_vpOk(false), m_vpMs(0), m_rsiN(0), m_macdN(0), m_studyMs(0),
                                       m_bigAuto(0.0), m_bigMs(0) {}

   void              Init(CFPContext *ctx, CFPStudies *st, CFPBook *book, CFPMeter *meter, CFPAnalyst *ana)
     {
      m_ctx = ctx;
      m_st = st;
      m_book = book;
      m_meter = meter;
      m_ana = ana;
     }
   void              Invalidate(void) { m_vpMs = 0; m_miniMs = 0; m_studyMs = 0; }

   //=================================================================
   //  HEADER (02 §8.3)
   //=================================================================
   void              DrawHeader(void)
     {
      CFPContext *c = m_ctx;
      FPRect hr = c.lay.header;
      c.cv.Box(hr.x, hr.y, hr.w, hr.h, c.pal.headerBg);
      c.cv.HL(0, hr.w - 1, hr.h - 1, c.pal.border);
      int bh = c.Px(24), by = (hr.h - bh) / 2, gp = c.Px(6), minW = c.Px(40);
      //--- right-aligned buttons
      string rt[9] = {"RESET", "ZOOM IN", "ZOOM OUT", "UP", "DOWN", "BAR VOLUME PROFILE", "DELTA BARS", "SIDE PANELS", "LIVE"};
      int    ri[9] = {FPB_RESET, FPB_ZOOMIN, FPB_ZOOMOUT, FPB_UP, FPB_DOWN, FPB_BARVP, FPB_DELTA, FPB_SIDE, FPB_LIVE};
      bool   ra[9];
      ra[0] = false;
      ra[1] = false;
      ra[2] = false;
      ra[3] = false;
      ra[4] = false;
      ra[5] = c.view.barVPOn;
      ra[6] = c.view.deltaOn;
      ra[7] = c.lay.sideOn;
      ra[8] = (c.view.scroll == 0);
      int x = hr.w - c.Px(8);
      for(int i = 8; i >= 0; i--)
        {
         int w = BtnW(rt[i], minW);
         x -= w;
         Button(x, by, bh, rt[i], ri[i], ra[i], true, minW);
         x -= gp;
        }
      if(!c.view.tabsOn)
        {
         int w = c.Px(26);
         x -= w;
         Button(x, by, bh, "+", FPB_TABS_TOGGLE, false, true, w);
         x -= gp;
        }
      int rightStart = x - c.Px(10);
      //--- left: FootprintTrader status badge, then the toggles
      x = c.Px(8);
      x += DrawEABadge(x, by, bh) + gp;
      x += Button(x, by, bh, "SUPPLY & DEMAND ZONES", FPB_SD, c.view.sdOn, true, minW) + gp;
      x += Button(x, by, bh, "FUNDAMENTALS", FPB_FUND, false, false, minW) + gp;
      x += Button(x, by, bh, "MINI SESSION CHART", FPB_MINI, c.view.miniOn, true, minW) + gp;
      x += c.Px(26);
      int cy = hr.h / 2;
      //--- ticker: symbol gold, price blue, daily change bull/bear
      double lastP = (m_st != NULL && m_st.last > 0.0) ? m_st.last : SymbolInfoDouble(c.sym, SYMBOL_BID);
      int w1 = c.cv.TxtW(c.fTicker, c.sym);
      if(x + w1 > rightStart)
         return;
      c.cv.Txt(c.fTicker, x, cy, c.sym, c.pal.gold, TA_LEFT | TA_VCENTER);
      x += w1 + c.Px(16);
      string ps = c.Price(lastP);
      int w2 = c.cv.TxtW(c.fTickerPx, ps);
      if(x + w2 > rightStart)
         return;
      c.cv.Txt(c.fTickerPx, x, cy, ps, c.pal.blue, TA_LEFT | TA_VCENTER);
      x += w2 + c.Px(14);
      if(m_st != NULL && m_st.d1Open > 0.0 && lastP > 0.0)
        {
         double ch = lastP - m_st.d1Open;
         string cs = ((ch >= 0.0) ? "+" : "") + DoubleToString(ch, c.digits) + " (" + ((ch >= 0.0) ? "+" : "") + DoubleToString(100.0 * ch / m_st.d1Open, 2) + "%)";
         int w3 = c.cv.TxtW(c.fMono, cs);
         if(x + w3 + c.Px(28) > rightStart)
            return;
         c.cv.VL(x, cy - c.Px(10), cy + c.Px(10), c.pal.border);
         x += c.Px(14);
         c.cv.Txt(c.fMono, x, cy, cs, (ch >= 0.0) ? c.pal.bull : c.pal.bear, TA_LEFT | TA_VCENTER);
         x += w3 + c.Px(14);
        }
      //--- trend boxes 5M 15M 1H 4H D1
      if(m_st == NULL)
         return;
      int stepT = c.Px(26);
      int needT = 0;
      for(int i = 0; i < FPS_NTF; i++)
         needT += c.cv.TxtW(c.fSmall, m_st.tfLabel[i] + ":") + stepT;
      if(x + needT + c.Px(14) > rightStart)
         return;
      c.cv.VL(x, cy - c.Px(10), cy + c.Px(10), c.pal.border);
      x += c.Px(14);
      for(int i = 0; i < FPS_NTF; i++)
        {
         string lb = m_st.tfLabel[i] + ":";
         int lw = c.cv.TxtW(c.fSmall, lb);
         c.cv.Txt(c.fSmall, x, cy, lb, c.pal.text2, TA_LEFT | TA_VCENTER);
         int ax = x + lw + c.Px(7);
         int tr = m_st.tfTrend[i];
         if(tr != 0)
            c.cv.Arrow(ax, cy, c.Px(4), tr, (tr > 0) ? c.pal.bull : c.pal.bear);
         else
            c.cv.HL(ax - c.Px(3), ax + c.Px(3), cy, c.pal.textOff);
         x += lw + stepT;
        }
      //--- bias labels
      string hb = (m_st.tfTrend[3] > 0) ? "BULL" : ((m_st.tfTrend[3] < 0) ? "BEAR" : "--");
      string cb = (m_st.chartTrend > 0) ? "BULL" : ((m_st.chartTrend < 0) ? "BEAR" : "--");
      string s1 = "HTF: " + hb, s2 = c.tfName + ": " + cb;
      int wb = c.cv.TxtW(c.fUIB, s1) + c.cv.TxtW(c.fUIB, s2) + c.Px(40);
      if(x + wb > rightStart)
         return;
      c.cv.VL(x, cy - c.Px(10), cy + c.Px(10), c.pal.border);
      x += c.Px(14);
      uint hc = (m_st.tfTrend[3] > 0) ? c.pal.bull : ((m_st.tfTrend[3] < 0) ? c.pal.bear : c.pal.text2);
      uint cc = (m_st.chartTrend > 0) ? c.pal.bull : ((m_st.chartTrend < 0) ? c.pal.bear : c.pal.text2);
      c.cv.Txt(c.fUIB, x, cy, s1, hc, TA_LEFT | TA_VCENTER);
      x += c.cv.TxtW(c.fUIB, s1) + c.Px(18);
      c.cv.Txt(c.fUIB, x, cy, s2, cc, TA_LEFT | TA_VCENTER);
     }

   //=================================================================
   //  STYLE TABS (02 §8.4) - only MINIMALIST works, the rest are greyed
   //  The status text (source, bucket, history, draw ms) sits in the
   //  free space right of the tabs; returns false when it did not fit.
   //=================================================================
   bool              DrawTabs(const string status)
     {
      CFPContext *c = m_ctx;
      if(!c.view.tabsOn || c.lay.tabs.h <= 0)
         return false;
      FPRect t = c.lay.tabs;
      c.cv.Box(t.x, t.y, t.w, t.h, c.pal.bg);
      c.cv.HL(0, t.w - 1, t.y + t.h - 1, c.pal.border);
      string nm[9] = {"MINIMALIST", "BACKGROUND CELLS", "CANDLE FRAME", "VOLUME PROFILE CANDLE", "FRAMELESS",
                      "MIDDLE CANDLE", "DELTA CELLS", "BID x ASK PROFILE", "BID x ASK CELLS"};
      string shortNm[9] = {"MINIMALIST", "BG CELLS", "CANDLE FRAME", "VP CANDLE", "FRAMELESS",
                           "MID CANDLE", "DELTA CELLS", "BxA PROFILE", "BxA CELLS"};
      int g = c.Px(4);
      int collapseW = c.Px(24);
      int avail = c.lay.fp.w - c.Px(8) - collapseW - c.Px(16);
      int tw = MathMin(c.Px(118), (avail - 8 * g) / 9);
      int th = t.h - c.Px(6);
      int ty = t.y + c.Px(2);
      int x = c.Px(4);
      if(tw >= c.Px(30))
         for(int i = 0; i < 9; i++)
           {
            bool active = (i == FP_STYLE_MINIMALIST);
            c.cv.Box(x, ty, tw, th, c.pal.panelBg);
            c.cv.Frame(x, ty, tw, th, c.pal.border);
            uint col = active ? c.pal.blue : c.pal.textOff;
            //--- letter-spaced label; fall back to no spacing, then to a short label
            string lb = nm[i];
            int sp = (StringLen(lb) <= 12) ? c.Px(2.5) : c.Px(1);
            int sw = c.cv.SpacedW(c.fTab, lb, sp);
            if(sw > tw - c.Px(6))
              {
               sp = 0;
               sw = c.cv.SpacedW(c.fTab, lb, sp);
              }
            if(sw > tw - c.Px(4))
              {
               lb = shortNm[i];
               sp = c.Px(1);
               sw = c.cv.SpacedW(c.fTab, lb, sp);
               if(sw > tw - c.Px(4))
                 {
                  sp = 0;
                  sw = c.cv.SpacedW(c.fTab, lb, sp);
                 }
              }
            if(sw <= tw - c.Px(2))
               c.cv.SpacedTxt(c.fTab, x + (tw - sw) / 2, ty + th / 2, lb, col, sp);
            c.lay.AddButton(FPB_TAB0 + i, x, ty, tw, th, active);
            x += tw + g;
           }
      //--- collapse button at the right end of the footprint panel
      int bx = c.lay.fp.w - collapseW - c.Px(8);
      c.cv.Box(bx, ty, collapseW, th, c.pal.panelBg);
      c.cv.Frame(bx, ty, collapseW, th, c.pal.border);
      c.cv.HL(bx + collapseW / 2 - c.Px(4), bx + collapseW / 2 + c.Px(3), ty + th / 2, c.pal.text2);
      c.lay.AddButton(FPB_TABS_TOGGLE, bx, ty, collapseW, th, !c.tester);
      //--- status text between the last tab and the collapse button
      int sw2 = c.cv.TxtW(c.fTiny, status);
      if(x + c.Px(10) + sw2 <= bx - c.Px(10))
        {
         c.cv.Txt(c.fTiny, bx - c.Px(10), ty + th / 2, status, c.pal.text2, TA_RIGHT | TA_VCENTER);
         return true;
        }
      return false;
     }

   //=================================================================
   //  MINI SESSION CHART (02 §8.6)
   //=================================================================
   void              DrawMini(void)
     {
      CFPContext *c = m_ctx;
      if(!c.view.miniOn)
         return;
      FPRect r = c.lay.mini;
      if(r.w <= 0 || FPBottom(r) > FPBottom(c.lay.fp) || FPRight(r) > c.lay.scale.x)
         return;
      datetime now = TimeTradeServer();
      datetime ss = c.engine.SessionStart(now);
      CFPBar *f = c.engine.At(0);
      if(f != NULL)
         ss = c.engine.SessionStart(f.time);
      ulong nowMs = GetTickCount64();
      if(m_miniMs == 0 || nowMs - m_miniMs >= 2000 || ss != m_miniSess)
        {
         m_miniMs = nowMs;
         m_miniSess = ss;
         MqlRates rt[];
         int n = CopyRates(c.sym, PERIOD_M1, ss, now + 60, rt);
         m_miniN = 0;
         if(n > 0)
           {
            ArrayResize(m_miniC, n);
            for(int i = 0; i < n; i++)
               m_miniC[i] = rt[i].close;
            m_miniN = n;
            m_miniOpen = rt[0].open;
           }
        }
      c.cv.Box(r.x, r.y, r.w, r.h, c.pal.panelBg);
      c.cv.Frame(r.x, r.y, r.w, r.h, c.pal.border);
      int capH = c.Px(18);
      int px1 = r.x + c.Px(8), px2 = r.x + r.w - c.Px(8);
      int py1 = r.y + c.Px(10), py2 = r.y + r.h - capH - c.Px(6);
      c.cv.Frame(px1 - 1, py1 - 1, px2 - px1 + 3, py2 - py1 + 3, c.pal.grid);
      if(m_miniN < 2)
        {
         c.cv.Txt(c.fSmall, r.x + r.w / 2, (py1 + py2) / 2, "No M1 data for this session yet", c.pal.text2, TA_CENTER | TA_VCENTER);
         return;
        }
      double lo = m_miniOpen, hi = m_miniOpen;
      for(int i = 0; i < m_miniN; i++)
        {
         lo = MathMin(lo, m_miniC[i]);
         hi = MathMax(hi, m_miniC[i]);
        }
      double pad = (hi - lo) * 0.06;
      if(pad <= 0.0)
         pad = c.point * 10.0;
      lo -= pad;
      hi += pad;
      double ky = (py2 - py1) / (hi - lo);
      double kx = (double)(px2 - px1) / (double)(m_miniN - 1);
      uint lineC = c.pal.bull;
      uint areaC = FPBlend(c.pal.panelBg, c.pal.bull, 0.25);
      //--- area: one vertical line per pixel column (interpolated close)
      for(int x = px1; x <= px2; x++)
        {
         double fi = (x - px1) / kx;
         int i0 = (int)MathFloor(fi);
         if(i0 >= m_miniN - 1)
            i0 = m_miniN - 2;
         double fr = fi - i0;
         double v = m_miniC[i0] + (m_miniC[i0 + 1] - m_miniC[i0]) * fr;
         int y = py2 - (int)MathRound((v - lo) * ky);
         c.cv.VL(x, y, py2, areaC);
        }
      //--- session open (dashed)
      int yo = py2 - (int)MathRound((m_miniOpen - lo) * ky);
      c.cv.HDash(px1, px2, yo, c.pal.text2, c.Px(4), c.Px(3));
      //--- line
      int xp = px1, yp = py2 - (int)MathRound((m_miniC[0] - lo) * ky);
      for(int i = 1; i < m_miniN; i++)
        {
         int xx = px1 + (int)MathRound(i * kx);
         int yy = py2 - (int)MathRound((m_miniC[i] - lo) * ky);
         c.cv.Line(xp, yp, xx, yy, lineC);
         xp = xx;
         yp = yy;
        }
      c.cv.DiscAA(xp, yp, c.Px(2.5), FPRGB(255, 255, 255));
      //--- caption
      double mv = (m_miniOpen > 0.0) ? 100.0 * (m_miniC[m_miniN - 1] - m_miniOpen) / m_miniOpen : 0.0;
      long off = (long)TimeLocal() - (long)TimeTradeServer();
      off = (long)MathRound(off / 900.0) * 900;   // whole quarter hours
      datetime l1 = (datetime)((long)ss + off), l2 = (datetime)((long)ss + 86400 + off);
      string cap = "Session Move: " + ((mv >= 0.0) ? "+" : "") + DoubleToString(mv, 2) + "%    Local " +
                   TimeToString(l1, TIME_MINUTES) + "-" + TimeToString(l2, TIME_MINUTES) + "    M1 Bars: " + IntegerToString(m_miniN);
      c.cv.Txt(c.fSmall, r.x + c.Px(8), r.y + r.h - capH / 2 - c.Px(2), cap, (mv >= 0.0) ? c.pal.bull : c.pal.bear, TA_LEFT | TA_VCENTER);
     }

   //=================================================================
   //  SIDE PANELS (02 §8.8)
   //=================================================================
   void              DrawSide(void)
     {
      CFPContext *c = m_ctx;
      if(!c.lay.sideOn)
         return;
      FPRect sd = c.lay.side;
      c.cv.Box(sd.x, sd.y, sd.w, sd.h, c.pal.bg);
      m_ana.Draw(c.lay.analyst);
      DrawMeter(c.lay.meter);
      DrawDOM(c.lay.dom);
      DrawTAS();
      DrawStudies();
      DrawVP(c.lay.vp);
     }

   //--- (a) VP Total
   void              DrawVP(const FPRect &r)
     {
      CFPContext *c = m_ctx;
      bool sess = (c.set.vpMode == FP_VP_SESSION);
      FPPanelFrame(c, r, "VP Total", sess ? "(session)" : "(" + IntegerToString(c.set.vpBars) + " bars)");
      ulong nowMs = GetTickCount64();
      if(m_vpMs == 0 || nowMs - m_vpMs >= 1000)
        {
         m_vpMs = nowMs;
         int toShift = MathMax(1, c.set.vpBars) - 1;
         if(sess)
           {
            CFPBar *f = c.engine.At(0);
            datetime ss = c.engine.SessionStart((f != NULL) ? f.time : TimeTradeServer());
            toShift = 0;
            int n = c.engine.Total();
            for(int sh = 1; sh <= n; sh++)
              {
               CFPBar *b = c.engine.At(sh);
               if(b == NULL || b.time < ss)
                  break;
               toShift = sh;
              }
           }
         m_vpOk = c.engine.RangeProfile(0, toShift, m_vp);
        }
      int th = c.lay.titleH;
      int ax1 = r.x + c.Px(2), ax2 = r.x + r.w - c.Px(2);
      int ay1 = r.y + th + c.Px(6), ay2 = r.y + r.h - c.Px(6);
      if(!m_vpOk || m_vp.rows <= 0 || m_vp.total <= 0.0)
        {
         c.cv.Txt(c.fSmall, r.x + r.w / 2, (ay1 + ay2) / 2, "loading...", c.pal.text2, TA_CENTER | TA_VCENTER);
         return;
        }
      int n = m_vp.rows;
      double mx = 0.0;
      for(int i = 0; i < n; i++)
         mx = MathMax(mx, m_vp.sell[i] + m_vp.buy[i]);
      if(mx <= 0.0)
         return;
      double rp = (double)(ay2 - ay1) / n;
      int maxLen = (ax2 - ax1) - c.Px(26);
      uint barC = FPBlend(c.pal.panelBg, c.pal.bull, 0.85);
      for(int i = 0; i < n; i++)
        {
         double v = m_vp.sell[i] + m_vp.buy[i];
         if(v <= 0.0)
            continue;
         int yb = ay2 - (int)MathRound(i * rp);
         int yt = ay2 - (int)MathRound((i + 1) * rp);
         int hh = MathMax(1, yb - yt - ((rp >= 3.0) ? 1 : 0));
         int len = MathMax(1, (int)MathRound(v / mx * maxLen));
         c.cv.Box(ax1, yb - hh, len, hh, barC);
        }
      //--- POC / VAH / VAL
      int lines[3];
      lines[0] = m_vp.pocIdx;
      lines[1] = m_vp.vahIdx;
      lines[2] = m_vp.valIdx;
      string lbl[3] = {"POC", "VAH", "VAL"};
      for(int k = 0; k < 3; k++)
        {
         int idx = lines[k];
         if(idx < 0 || idx >= n)
            continue;
         int y = ay2 - (int)MathRound((idx + 0.5) * rp);
         uint col = (k == 0) ? c.pal.gold : c.pal.slate;
         c.cv.HL(ax1, ax2 - c.Px(2), y, col);
         c.cv.Txt(c.fTiny, ax2 - c.Px(3), y - c.Px(2), lbl[k], col, TA_RIGHT | TA_BOTTOM);
        }
     }

   //--- (b) Time & Sales + Bar Totals
   void              DrawTAS(void)
     {
      CFPContext *c = m_ctx;
      FPRect r = c.lay.tasList;
      FPPanelFrame(c, c.lay.tas, "Time & Sales", "");
      int th = c.lay.titleH;
      int rh = c.Px(16);
      int hy = r.y + th + rh / 2 + c.Px(2);
      int cx1 = r.x + c.Px(6), cx2 = r.x + (int)(r.w * 0.47), cx3 = r.x + (int)(r.w * 0.80);
      c.cv.Txt(c.fSmall, cx1, hy, "Time", c.pal.text2, TA_LEFT | TA_VCENTER);
      c.cv.Txt(c.fSmall, cx2, hy, "Price", c.pal.text2, TA_LEFT | TA_VCENTER);
      c.cv.Txt(c.fSmall, cx3, hy, "Size", c.pal.text2, TA_LEFT | TA_VCENTER);
      c.cv.HL(r.x + 1, r.x + r.w - 2, hy + rh / 2 + c.Px(1), c.pal.grid);
      int y0 = hy + rh + c.Px(2);
      int rows = MathMin(MathMax(1, c.set.tasRows), (FPBottom(r) - c.Px(4) - y0 + rh / 2) / rh);
      //--- prints, newest first, aggregated (same side + price + second)
      FPPrint pr[];
      int np = c.engine.Prints(pr, 2000);
      long   aT[];
      double aP[], aS[];
      int    aSide[];
      int na = 0;
      ArrayResize(aT, rows);
      ArrayResize(aP, rows);
      ArrayResize(aS, rows);
      ArrayResize(aSide, rows);
      for(int i = 0; i < np && na <= rows; i++)
        {
         long sec = pr[i].time_msc / 1000;
         if(c.set.tasAggregate && na > 0 && aSide[na - 1] == pr[i].side && aT[na - 1] == sec && MathAbs(aP[na - 1] - pr[i].price) < c.point * 0.5)
           {
            aS[na - 1] += pr[i].size;
            continue;
           }
         if(na == rows)
            break;
         aT[na] = sec;
         aP[na] = pr[i].price;
         aS[na] = pr[i].size;
         aSide[na] = pr[i].side;
         na++;
        }
      //--- big size threshold
      double big = c.set.tasBigSize;
      if(big <= 0.0)
        {
         ulong nowMs = GetTickCount64();
         if(m_bigMs == 0 || nowMs - m_bigMs >= 2000)
           {
            m_bigMs = nowMs;
            m_bigAuto = AutoBig(pr, MathMin(np, 500));
           }
         big = m_bigAuto;
        }
      for(int i = 0; i < na; i++)
        {
         int y = y0 + i * rh;
         uint col = (aSide[i] > 0) ? c.pal.bull : ((aSide[i] < 0) ? c.pal.bear : c.pal.neutral);
         bool isBig = (big > 0.0 && aS[i] >= big);
         int fnt = isBig ? c.fScaleB : c.fTable;
         c.cv.Txt(c.fTable, cx1, y, TimeToString((datetime)aT[i], TIME_SECONDS), c.pal.text2, TA_LEFT | TA_VCENTER);
         c.cv.Txt(fnt, cx2, y, c.Price(aP[i]), col, TA_LEFT | TA_VCENTER);
         c.cv.Txt(fnt, cx3, y, c.Vol(aS[i]), col, TA_LEFT | TA_VCENTER);
         c.cv.HL(r.x + 1, r.x + r.w - 2, y + rh / 2, FPBlend(c.pal.panelBg, c.pal.grid, 0.6));
        }
      if(na == 0)
         c.cv.Txt(c.fSmall, r.x + r.w / 2, y0 + rh, "waiting for prints...", c.pal.text2, TA_CENTER | TA_VCENTER);
      //--- Bar Totals of the forming bar
      FPRect bt = c.lay.barTotals;
      c.cv.HL(bt.x + 1, bt.x + bt.w - 2, bt.y, c.pal.border);
      c.cv.Txt(c.fUIB, bt.x + c.Px(6), bt.y + c.Px(10), "Bar Totals:", c.pal.text, TA_LEFT | TA_VCENTER);
      double fb = 0.0, fsv = 0.0;
      CFPBar *f = c.engine.At(0);
      if(f != NULL && f.state == 0)
         for(int k = 0; k < f.rows; k++)
           {
            fb += f.buyVol[k];
            fsv += f.sellVol[k];
           }
      int bw = (bt.w - c.Px(16)) / 2;
      int by = bt.y + c.Px(20), bhh = c.Px(18);
      uint bfill = FPBlend(c.pal.panelBg, c.pal.bull, 0.55);
      uint sfill = FPBlend(c.pal.panelBg, c.pal.bear, 0.55);
      c.cv.Box(bt.x + c.Px(6), by, bw, bhh, bfill);
      c.cv.Box(bt.x + c.Px(10) + bw, by, bw, bhh, sfill);
      c.cv.Txt(c.fScaleB, bt.x + c.Px(10), by + bhh / 2, "B:" + c.Vol(fb), CFPTheme::TextOn(c.pal, bfill), TA_LEFT | TA_VCENTER);
      c.cv.Txt(c.fScaleB, bt.x + c.Px(14) + bw, by + bhh / 2, "S:" + c.Vol(fsv), CFPTheme::TextOn(c.pal, sfill), TA_LEFT | TA_VCENTER);
     }

   static double     AutoBig(const FPPrint &pr[], const int n)
     {
      if(n < 20)
         return 0.0;
      double v[];
      ArrayResize(v, n);
      for(int i = 0; i < n; i++)
         v[i] = pr[i].size;
      ArraySort(v);
      double p95 = v[(int)MathFloor(0.95 * (n - 1))];
      double mn = v[0];
      return (p95 > mn) ? p95 : 0.0;   // all prints the same size (QUOTE ticks) -> nothing is "big"
     }

   //--- (c) RSI and MACD minis
   void              DrawStudies(void)
     {
      CFPContext *c = m_ctx;
      FPRect rr = c.lay.rsi, mr = c.lay.macd;
      int npts = MathMax(10, (rr.w - c.Px(12)) / c.Px(2));
      ulong nowMs = GetTickCount64();
      if(m_studyMs == 0 || nowMs - m_studyMs >= 1000)
        {
         m_studyMs = nowMs;
         m_rsiN = m_st.RSISeries(m_rsi, npts);
         m_macdN = m_st.MACDSeries(m_mm, m_ms, npts);
        }
      //--- RSI
      c.cv.HL(rr.x + 1, rr.x + rr.w - 2, rr.y, c.pal.border);
      c.cv.Txt(c.fUIB, rr.x + c.Px(6), rr.y + c.Px(11), "RSI(" + IntegerToString(c.set.rsiPeriod) + ")", c.pal.text, TA_LEFT | TA_VCENTER);
      int x1 = rr.x + c.Px(6), x2 = rr.x + rr.w - c.Px(6);
      int y1 = rr.y + c.Px(22), y2 = rr.y + rr.h - c.Px(6);
      if(m_rsiN >= 2)
        {
         c.cv.Txt(c.fTable, x2, rr.y + c.Px(11), DoubleToString(m_rsi[m_rsiN - 1], 1), c.pal.purple, TA_RIGHT | TA_VCENTER);
         int y70 = y2 - (int)MathRound(0.70 * (y2 - y1)), y30 = y2 - (int)MathRound(0.30 * (y2 - y1));
         c.cv.Box(x1, y70, x2 - x1 + 1, y30 - y70 + 1, FPBlend(c.pal.panelBg, c.pal.purple, 0.07));
         int y50 = y2 - (int)MathRound(0.50 * (y2 - y1));
         c.cv.HDash(x1, x2, y50, c.pal.text2, c.Px(3), c.Px(3));
         double kx = (double)(x2 - x1) / (m_rsiN - 1);
         int xp = x1, yp = y2 - (int)MathRound(m_rsi[0] / 100.0 * (y2 - y1));
         for(int i = 1; i < m_rsiN; i++)
           {
            int xx = x1 + (int)MathRound(i * kx);
            int yy = y2 - (int)MathRound(m_rsi[i] / 100.0 * (y2 - y1));
            c.cv.Line(xp, yp, xx, yy, c.pal.purple);
            xp = xx;
            yp = yy;
           }
        }
      //--- MACD (histogram of the MACD line, bull/bear by sign)
      c.cv.HL(mr.x + 1, mr.x + mr.w - 2, mr.y, c.pal.border);
      c.cv.Txt(c.fUIB, mr.x + c.Px(6), mr.y + c.Px(11), "MACD", c.pal.text, TA_LEFT | TA_VCENTER);
      x1 = mr.x + c.Px(6);
      x2 = mr.x + mr.w - c.Px(6);
      y1 = mr.y + c.Px(22);
      y2 = mr.y + mr.h - c.Px(6);
      if(m_macdN >= 2)
        {
         c.cv.Txt(c.fTable, x2, mr.y + c.Px(11), DoubleToString(m_mm[m_macdN - 1], c.digits), c.pal.bull, TA_RIGHT | TA_VCENTER);
         double mx = 0.0;
         for(int i = 0; i < m_macdN; i++)
            mx = MathMax(mx, MathMax(MathAbs(m_mm[i]), MathAbs(m_ms[i])));
         if(mx > 0.0)
           {
            int y0 = (y1 + y2) / 2;
            double ky = (y2 - y1) / 2.0 / mx;
            double kx = (double)(x2 - x1 + 1) / m_macdN;
            for(int i = 0; i < m_macdN; i++)
              {
               int xa = x1 + (int)MathFloor(i * kx);
               int xb = MathMax(xa, x1 + (int)MathFloor((i + 1) * kx) - 1);
               int yv = y0 - (int)MathRound(m_mm[i] * ky);
               uint col = (m_mm[i] >= 0.0) ? c.pal.bull : c.pal.bear;
               c.cv.FillRectangle(xa, MathMin(y0, yv), xb, MathMax(y0, yv), col);
              }
            //--- signal line
            int xp = x1, yp = y0 - (int)MathRound(m_ms[0] * ky);
            for(int i = 1; i < m_macdN; i++)
              {
               int xx = x1 + (int)MathRound((i + 0.5) * kx);
               int yy = y0 - (int)MathRound(m_ms[i] * ky);
               c.cv.Line(xp, yp, xx, yy, c.pal.text2);
               xp = xx;
               yp = yy;
              }
            c.cv.HL(x1, x2, y0, c.pal.border);
           }
        }
     }

   //--- (d) DOM ladder
   void              DrawDOM(const FPRect &r)
     {
      CFPContext *c = m_ctx;
      c.cv.Box(r.x, r.y, r.w, r.h, c.pal.panelBg);
      c.cv.Frame(r.x, r.y, r.w, r.h, c.pal.border);
      int th = c.lay.titleH;
      c.cv.HL(r.x, r.x + r.w - 1, r.y + th, c.pal.border);
      //--- columns Bid | Sold | Price | Bot | Ask | D | Vol
      double fr[8] = {0.0, 0.15, 0.28, 0.49, 0.62, 0.75, 0.87, 1.0};
      int cx[8];
      for(int i = 0; i < 8; i++)
         cx[i] = r.x + (int)MathRound(fr[i] * r.w);
      string hd[7] = {"Bid", "Sold", "Price", "Bot", "Ask", "D", "Vol"};
      uint hc[7];
      hc[0] = c.pal.bull;
      hc[1] = c.pal.bear;
      hc[2] = c.pal.text;
      hc[3] = c.pal.bull;
      hc[4] = c.pal.bear;
      hc[5] = c.pal.text2;
      hc[6] = c.pal.text;
      for(int i = 0; i < 7; i++)
         c.cv.Txt(c.fUIB, (cx[i] + cx[i + 1]) / 2, r.y + th / 2, hd[i], hc[i], TA_CENTER | TA_VCENTER);
      int y0 = r.y + th + 1;
      bool book = m_book.available;
      if(!book)
        {
         c.cv.Txt(c.fTiny, r.x + r.w / 2, y0 + c.Px(8), "NO BOOK - FOOTPRINT ONLY", c.pal.text2, TA_CENTER | TA_VCENTER);
         y0 += c.Px(16);
        }
      int lv = MathMax(1, c.set.domLevels);
      int nrows = 2 * lv + 1;
      int rh = MathMax(c.Px(10), (FPBottom(r) - 2 - y0) / nrows);
      CFPBar *f = c.engine.At(0);
      double lastP = (m_st != NULL && m_st.last > 0.0) ? m_st.last : SymbolInfoDouble(c.sym, SYMBOL_BID);
      long cRow = c.engine.PriceToRow(lastP);
      //--- book per row
      double bidR[], askR[];
      ArrayResize(bidR, nrows);
      ArrayResize(askR, nrows);
      ArrayInitialize(bidR, 0.0);
      ArrayInitialize(askR, 0.0);
      double bmax = 0.0;
      if(book)
        {
         for(int i = 0; i < m_book.nBid; i++)
           {
            long k = cRow + lv - c.engine.PriceToRow(m_book.bidP[i]);
            if(k >= 0 && k < nrows)
               bidR[(int)k] += m_book.bidV[i];
           }
         for(int i = 0; i < m_book.nAsk; i++)
           {
            long k = cRow + lv - c.engine.PriceToRow(m_book.askP[i]);
            if(k >= 0 && k < nrows)
               askR[(int)k] += m_book.askV[i];
           }
         for(int i = 0; i < nrows; i++)
            bmax = MathMax(bmax, MathMax(bidR[i], askR[i]));
        }
      uint lineC = FPBlend(c.pal.panelBg, c.pal.grid, 0.7);
      for(int i = 0; i < nrows; i++)
        {
         long row = cRow + lv - i;
         int yt = y0 + i * rh;
         if(yt + rh > FPBottom(r) - 1)
            break;
         int yc = yt + rh / 2;
         double sv = 0.0, bv = 0.0;
         bool traded = false;
         if(f != NULL && f.state == 0 && f.rows > 0)
           {
            long k = row - f.rowLow;
            if(k >= 0 && k < f.rows)
              {
               sv = f.sellVol[(int)k];
               bv = f.buyVol[(int)k];
               traded = (sv + bv > 0.0);
              }
           }
         double d = bv - sv;
         //--- row tints
         if(row == cRow)
            c.cv.Box(r.x + 1, yt, r.w - 2, rh, FPBlend(c.pal.panelBg, c.pal.gold, 0.25));
         else
            if(traded)
               c.cv.Box(r.x + 1, yt, r.w - 2, rh, FPBlend(c.pal.panelBg, (d >= 0.0) ? c.pal.bull : c.pal.bear, 0.16));
         c.cv.HL(r.x + 1, r.x + r.w - 2, yt + rh - 1, lineC);
         //--- book bars + numbers
         if(book && bmax > 0.0)
           {
            int cw = cx[1] - cx[0] - c.Px(4);
            if(bidR[i] > 0.0)
              {
               int wv = MathMax(2, (int)MathRound(bidR[i] / bmax * cw));
               c.cv.Box(cx[0] + c.Px(2), yt + 2, wv, rh - 4, FPBlend(c.pal.panelBg, c.pal.bull, 0.65));
               c.cv.Txt(c.fTable, cx[0] + c.Px(4), yc, c.Vol(bidR[i]), c.pal.text, TA_LEFT | TA_VCENTER);
              }
            int cw4 = cx[5] - cx[4] - c.Px(4);
            if(askR[i] > 0.0)
              {
               int wv = MathMax(2, (int)MathRound(askR[i] / bmax * cw4));
               c.cv.Box(cx[4] + c.Px(2), yt + 2, wv, rh - 4, FPBlend(c.pal.panelBg, c.pal.bear, 0.65));
               c.cv.Txt(c.fTable, cx[4] + c.Px(4), yc, c.Vol(askR[i]), c.pal.text, TA_LEFT | TA_VCENTER);
              }
           }
         //--- price
         c.cv.Txt(c.fTable, (cx[2] + cx[3]) / 2, yc, c.Price(c.engine.RowToPrice(row)), (row == cRow) ? c.pal.gold : c.pal.text, TA_CENTER | TA_VCENTER);
         if(traded)
           {
            c.cv.Txt(c.fTable, (cx[1] + cx[2]) / 2, yc, c.Vol(sv), c.pal.bear, TA_CENTER | TA_VCENTER);
            c.cv.Txt(c.fTable, (cx[3] + cx[4]) / 2, yc, c.Vol(bv), c.pal.bull, TA_CENTER | TA_VCENTER);
            c.cv.Txt(c.fTable, (cx[5] + cx[6]) / 2, yc, c.SVol(d), (d >= 0.0) ? c.pal.bull : c.pal.bear, TA_CENTER | TA_VCENTER);
            c.cv.Txt(c.fTable, (cx[6] + cx[7]) / 2, yc, c.Vol(sv + bv), c.pal.text, TA_CENTER | TA_VCENTER);
           }
        }
      //--- column separators
      for(int i = 1; i < 7; i++)
         c.cv.VL(cx[i], r.y + th + 1, FPBottom(r) - 2, lineC);
     }

   //--- (e) Signal Meter
   void              DrawMeter(const FPRect &r)
     {
      CFPContext *c = m_ctx;
      FPPanelFrame(c, r, "Signal Meter", "");
      int th = c.lay.titleH;
      int rowMin = c.Px(20);
      int ring = c.Px(14);
      int R = MathMin(c.Px(56), (r.w - c.Px(24)) / 2 - ring);
      int avail = r.h - th - c.Px(16);
      if(avail - 2 * (R + ring) < FPM_ROWS * rowMin)
         R = MathMax(c.Px(26), (avail - FPM_ROWS * rowMin) / 2 - ring);
      int cxg = r.x + r.w / 2;
      int cyg = r.y + th + c.Px(8) + R + ring;
      //--- outer circle
      c.cv.RingAA(cxg, cyg, R + ring, 1.0, c.pal.border);
      //--- coloured arc: bear -100..-20, neutral -20..+20, bull +20..+100
      double thick = c.Px(10);
      double r0 = R - thick, r1 = (double)R;
      uint nC = FPBlend(c.pal.panelBg, c.pal.neutral, c.pal.dark ? 0.45 : 0.6);
      int ri = R + 2;
      for(int yy = -ri; yy <= 1; yy++)
         for(int xx = -ri; xx <= ri; xx++)
           {
            double dd = MathSqrt((double)(xx * xx + yy * yy));
            double a = MathMin(dd - r0 + 0.5, r1 + 0.5 - dd);
            if(a <= 0.0)
               continue;
            double ang = MathArctan2((double)(-yy), (double)xx);   // 0 = right, pi = left
            if(ang < 0.0)
               continue;
            double sc = 100.0 - 200.0 * ang / M_PI;
            uint col = (sc <= -20.0) ? c.pal.bear : ((sc >= 20.0) ? c.pal.bull : nC);
            c.cv.BlendPixel(cxg + xx, cyg + yy, col, (a >= 1.0) ? 1.0 : a);
           }
      //--- ticks every 20 points
      for(int k = -100; k <= 100; k += 20)
        {
         double ang = M_PI * (100.0 - k) / 200.0;
         double ca = MathCos(ang), sa = MathSin(ang);
         c.cv.ThickLineAA(cxg + ca * (r0 - c.Px(3)), cyg - sa * (r0 - c.Px(3)), cxg + ca * (r0 - c.Px(8)), cyg - sa * (r0 - c.Px(8)), 1.0, c.pal.text2);
        }
      //--- needle + hub
      int sc0 = m_meter.ok ? m_meter.score : 0;
      double na = M_PI * (100.0 - MathMax(-100, MathMin(100, sc0))) / 200.0;
      double nl = r0 - c.Px(6);
      c.cv.ThickLineAA(cxg, cyg, cxg + MathCos(na) * nl, cyg - MathSin(na) * nl, c.Px(2.5), c.pal.gold);
      c.cv.DiscAA(cxg, cyg, c.Px(6), c.pal.gold);
      c.cv.DiscAA(cxg, cyg, c.Px(2.5), c.pal.panelBg);
      //--- verdict + score
      uint vc = FPToneColor(c.pal, m_meter.verdictTone);
      c.cv.Txt(c.fGauge, cxg, cyg + c.Px(22), m_meter.verdict, vc, TA_CENTER | TA_VCENTER);
      string scs = m_meter.ok ? (((m_meter.score > 0) ? "+" : "") + IntegerToString(m_meter.score)) : "--";
      c.cv.Txt(c.fTable, cxg, cyg + c.Px(40), scs, c.pal.text2, TA_CENTER | TA_VCENTER);
      //--- 11 rows
      int ry = cyg + R + ring + c.Px(8);
      int rh = MathMax(c.Px(14), (FPBottom(r) - c.Px(4) - ry) / FPM_ROWS);
      int lx = r.x + c.Px(4), lw = r.w - c.Px(8);
      int split = lx + (int)(lw * 0.40);
      for(int i = 0; i < FPM_ROWS; i++)
        {
         int y = ry + i * rh;
         if(y + rh > FPBottom(r))
            break;
         c.cv.Frame(lx, y + 1, lw, rh - 3, c.pal.border);
         c.cv.VL(split, y + 1, y + rh - 3, c.pal.border);
         c.cv.Txt(c.fUI, lx + c.Px(6), y + rh / 2 - 1, m_meter.label[i], c.pal.text, TA_LEFT | TA_VCENTER);
         c.cv.Txt(c.fTable, (split + lx + lw) / 2, y + rh / 2 - 1, m_meter.value[i], FPToneColor(c.pal, m_meter.tone[i]), TA_CENTER | TA_VCENTER);
        }
     }
};

#endif // ORDERFLOWFP_UI_FPPANELS_MQH
//+------------------------------------------------------------------+
