//+------------------------------------------------------------------+
//| FPRenderer.mqh - OrderFlowFP UI: footprint panel (02 §8.1),        |
//| overlays (§8.2), own price scale + price tag, summary table        |
//| (§8.7), status line and the trade overlay (EA trades, read-only).  |
//|                                                                    |
//| Row geometry: row r covers the price bucket [r*rs, (r+1)*rs) and   |
//| is drawn in the band [Y(r+1), Y(r)) with Y(rc) = midY -            |
//| (rc - centerRow) * rowPx. Price labels show the bucket bottom at   |
//| the band centre (reference look); exact prices (trade levels, S&D  |
//| edges) use Y(price / rs).                                          |
//+------------------------------------------------------------------+
#ifndef ORDERFLOWFP_UI_FPRENDERER_MQH
#define ORDERFLOWFP_UI_FPRENDERER_MQH

#include "FPLayout.mqh"
#include "FPTrades.mqh"

struct FPSDZone
{
   datetime start;     // pivot bar
   double   top, bottom;
   int      role;      // +1 demand, -1 supply (flips when a bar closes beyond the far edge)
   bool     touched;   // middle touched -> grey
};

class CFPRenderer
{
private:
   CFPContext       *m_ctx;
   CFPTrades        *m_tr;
   CFPTextBatch      m_batch;
   //--- per frame
   int               m_nVis;
   int               m_visShift[];
   int               m_rowPx;
   int               m_midY;
   int               m_plotBottom;
   long              m_rTop, m_rBot;     // visible row range
   //--- supply & demand zones
   FPSDZone          m_sd[];
   int               m_nSD;
   datetime          m_sdBar;

public:
                     CFPRenderer(void) : m_ctx(NULL), m_tr(NULL), m_nVis(0), m_rowPx(16), m_midY(0), m_plotBottom(0), m_rTop(0), m_rBot(0), m_nSD(0), m_sdBar(0) {}
   void              Init(CFPContext *ctx, CFPTrades *tr) { m_ctx = ctx; m_tr = tr; }

   //=================================================================
   //  geometry
   //=================================================================
   int               ColRight(const int shift) const { return m_ctx.lay.plotRight - (shift - m_ctx.view.scroll) * m_ctx.lay.pitch; }
   int               ColLeft(const int shift) const  { return ColRight(shift) - m_ctx.lay.barW; }
   int               ColMid(const int shift) const   { return ColRight(shift) - m_ctx.lay.barW / 2; }
   double            YRow(const double rc) const     { return m_midY - (rc - m_ctx.view.centerRow) * m_rowPx; }
   int               RowTop(const long r) const      { return (int)MathRound(YRow((double)r + 1.0)); }
   int               RowMid(const long r) const      { return (int)MathRound(YRow((double)r + 0.5)); }
   int               RowBot(const long r) const      { return (int)MathRound(YRow((double)r)) - 1; }
   int               YPrice(const double p) const    { return (int)MathRound(YRow(p / m_ctx.rowSize)); }
   long              RowAtY(const int y) const       { return (long)MathFloor(m_ctx.view.centerRow + (double)(m_midY - y) / m_rowPx); }
   int               VisibleCount(void) const        { return m_nVis; }
   int               OldestShift(void)
     {
      int n = m_ctx.engine.Total();
      return (m_ctx.engine.At(0) == NULL) ? n : n - 1;
     }
   int               MaxScroll(void)
     {
      CFPContext *c = m_ctx;
      int fit = MathMax(1, (c.lay.plotRight - c.lay.plot.x) / MathMax(1, c.lay.pitch));
      return MathMax(0, OldestShift() - fit + 1);
     }

   //--- visible bars, scroll anchoring and vertical auto-follow
   void              Prepare(void)
     {
      CFPContext *c = m_ctx;
      m_rowPx = MathMax(2, c.Px(c.view.zoom));
      m_midY = c.lay.plot.y + c.lay.plot.h / 2;
      m_plotBottom = FPBottom(c.lay.plot) - 1;
      //--- keep a scrolled view on the same bars when new bars arrive
      if(c.view.scroll > 0 && c.view.anchor != 0)
        {
         int s = c.ShiftOfTime(c.view.anchor);
         if(s >= 0)
            c.view.scroll = s;
        }
      int ms = MaxScroll();
      if(c.view.scroll > ms)
         c.view.scroll = ms;
      if(c.view.scroll < 0)
         c.view.scroll = 0;
      c.view.live = (c.view.scroll == 0);
      if(c.view.scroll > 0)
        {
         CFPBar *ab = c.engine.At(c.view.scroll);
         c.view.anchor = (ab != NULL) ? ab.time : 0;
        }
      else
         c.view.anchor = 0;
      //--- visible columns
      m_nVis = 0;
      int maxCols = (c.lay.plotRight - c.lay.plot.x) / MathMax(1, c.lay.pitch) + 2;
      ArrayResize(m_visShift, maxCols);
      int oldest = OldestShift();
      for(int i = 0; i < maxCols; i++)
        {
         int sh = c.view.scroll + i;
         if(sh > oldest)
            break;
         if(ColRight(sh) <= c.lay.plot.x)
            break;
         m_visShift[m_nVis] = sh;
         m_nVis++;
        }
      //--- vertical
      double lastP = LastPrice();
      if(!c.view.centred && lastP > 0.0)
        {
         c.view.centerRow = c.engine.PriceToRow(lastP) + 0.5;
         c.view.centred = true;
        }
      if(c.view.vAuto && c.view.centred)
        {
         if(c.view.scroll == 0)
           {
            if(lastP > 0.0)
              {
               double lr = c.engine.PriceToRow(lastP) + 0.5;
               if(MathAbs(lr - c.view.centerRow) * m_rowPx > 0.30 * c.lay.plot.h)
                  c.view.centerRow = lr;
              }
           }
         else
           {
            long lo = LONG_MAX, hi = LONG_MIN;
            for(int i = 0; i < m_nVis; i++)
              {
               CFPBar *b = c.engine.At(m_visShift[i]);
               if(b == NULL || b.state != 0 || b.rows <= 0)
                  continue;
               lo = MathMin(lo, b.rowLow);
               hi = MathMax(hi, b.rowLow + b.rows - 1);
              }
            if(lo <= hi)
               c.view.centerRow = (lo + hi + 1) / 2.0;
           }
        }
      m_rTop = RowAtY(c.lay.plot.y) + 1;
      m_rBot = RowAtY(m_plotBottom) - 1;
     }

   double            LastPrice(void)
     {
      CFPBar *f = m_ctx.engine.At(0);
      if(f != NULL && f.state == 0 && f.rows > 0 && f.close > 0.0)
         return f.close;
      double b = SymbolInfoDouble(m_ctx.sym, SYMBOL_BID);
      if(b > 0.0)
         return b;
      CFPBar *l = m_ctx.engine.At(1);
      return (l != NULL && l.state == 0) ? l.close : 0.0;
     }

   //=================================================================
   //  FOOTPRINT PANEL (draw order 02 §6: bg, zones, grid, cells,
   //  overlays, session POC, price scale + tag)
   //=================================================================
   void              DrawFootprint(void)
     {
      CFPContext *c = m_ctx;
      FPRect fp = c.lay.fp;
      c.cv.Box(fp.x, fp.y, fp.w, fp.h, c.pal.bg);
      if(c.set.showStackZones)
         DrawStackZones();
      if(c.view.sdOn)
         DrawSDZones();
      DrawGrid();
      if(c.set.showTrades)
         DrawTradeLines();
      if(c.view.barVPOn && c.view.zoom >= c.set.minCellHeight)
         DrawBarVP();
      DrawCells();
      if(c.view.deltaOn)
         DrawDeltaBars();
      if(c.set.showSessionPOC)
         DrawSessionPOC();
      if(c.set.showTrades)
         DrawTradeMarks();
      DrawPriceScale();
     }

   //--- stacked-imbalance zones (02 §8.2)
   void              DrawStackZones(void)
     {
      CFPContext *c = m_ctx;
      FPZone z[];
      int nz = c.engine.Zones(z, c.set.showFilledZones);
      if(nz <= 0 || m_nVis <= 0)
         return;
      int newestVis = m_visShift[0], oldestVis = m_visShift[m_nVis - 1];
      for(int i = 0; i < nz; i++)
        {
         int os = c.ShiftOfTime(z[i].originTime);
         if(os < 0)
            continue;
         bool filled = (z[i].filledTime != 0);
         int es = os - c.set.stackZoneBars;
         if(filled)
           {
            int fs = c.ShiftOfTime(z[i].filledTime);
            if(fs >= 0)
               es = MathMax(es, fs);
           }
         //--- the zone spans shifts [es, os]; skip it unless that overlaps the visible shifts
         if(os < newestVis || es > oldestVis)
            continue;
         int x1 = MathMax(ColLeft(os), c.lay.plot.x);
         int x2 = MathMin(ColRight(es) - 1, c.lay.scale.x - 1);
         if(x2 <= x1)
            continue;
         int y1 = RowTop(z[i].rowTo), y2 = RowBot(z[i].rowFrom);
         if(y2 < c.lay.plot.y || y1 > m_plotBottom)
            continue;
         y1 = MathMax(y1, c.lay.plot.y);
         y2 = MathMin(y2, m_plotBottom);
         uint col = (z[i].dir > 0) ? c.pal.bull : c.pal.bear;
         c.cv.Box(x1, y1, x2 - x1 + 1, y2 - y1 + 1, FPBlend(c.pal.bg, col, filled ? 0.06 : 0.16));
         uint bc = FPBlend(c.pal.bg, col, filled ? 0.25 : 0.6);
         c.cv.Frame(x1, y1, x2 - x1 + 1, y2 - y1 + 1, bc);
         if(x1 == ColLeft(os) && y2 - y1 > c.Px(10))
            c.cv.Txt(c.fTiny, x1 + c.Px(3), y1 + c.Px(1), (z[i].dir > 0) ? "STACKED BUYERS" : "STACKED SELLERS",
                     FPBlend(c.pal.bg, col, filled ? 0.35 : 0.9), TA_LEFT | TA_TOP);
        }
     }

   //--- supply & demand zones (02 §8.2), recomputed once per new chart bar
   void              ComputeSD(void)
     {
      CFPContext *c = m_ctx;
      datetime t0 = iTime(c.sym, c.tf, 0);
      if(t0 == m_sdBar && m_nSD >= 0 && m_sdBar != 0)
         return;
      m_sdBar = t0;
      m_nSD = 0;
      int sw = MathMax(1, c.set.sdSwing);
      int look = MathMax(sw * 2 + 1, c.set.sdLookback);
      int vl = MathMax(1, c.set.sdVolLen), al = MathMax(1, c.set.sdAtrLen);
      int need = look + sw + MathMax(vl, al) + 2;
      MqlRates r[];
      int n = CopyRates(c.sym, c.tf, 1, need, r);
      if(n < MathMax(vl, al) + 2 * sw + 2)
         return;
      //--- ATR(sdAtrLen) of the newest closed bars
      double trs = 0.0;
      int cnt = 0;
      for(int i = n - 1; i >= 1 && cnt < al; i--, cnt++)
         trs += MathMax(r[i].high, r[i - 1].close) - MathMin(r[i].low, r[i - 1].close);
      if(cnt <= 0)
         return;
      double atr = trs / cnt;
      double h = atr / MathMax(0.1, c.set.sdWidthDiv);
      int maxZ = MathMax(1, c.set.sdMaxZones);
      ArrayResize(m_sd, maxZ);
      int iMin = MathMax(sw, MathMax(vl - 1, n - look));
      for(int i = n - 1 - sw; i >= iMin && m_nSD < maxZ; i--)
        {
         bool ph = true, pl = true;
         for(int k = 1; k <= sw; k++)
           {
            if(r[i - k].high >= r[i].high || r[i + k].high > r[i].high)
               ph = false;
            if(r[i - k].low <= r[i].low || r[i + k].low < r[i].low)
               pl = false;
           }
         if(!ph && !pl)
            continue;
         double vs = 0.0;
         for(int k = i - vl + 1; k <= i; k++)
            vs += (double)r[k].tick_volume;
         if((double)r[i].tick_volume < c.set.sdVolRatio * vs / vl)
            continue;
         for(int pass = 0; pass < 2 && m_nSD < maxZ; pass++)
           {
            bool isDemand = (pass == 0);
            if((isDemand && !pl) || (!isDemand && !ph))
               continue;
            FPSDZone zz;
            zz.start = r[i].time;
            zz.role = isDemand ? 1 : -1;
            zz.bottom = isDemand ? r[i].low : r[i].high - h;
            zz.top = isDemand ? r[i].low + h : r[i].high;
            zz.touched = false;
            double mid = (zz.top + zz.bottom) / 2.0;
            for(int j = i + 1; j < n; j++)
              {
               if(zz.role > 0)
                 {
                  if(r[j].close < zz.bottom)
                     zz.role = -1;
                  else
                     if(j > i + sw && r[j].low <= mid)
                        zz.touched = true;
                 }
               else
                 {
                  if(r[j].close > zz.top)
                     zz.role = 1;
                  else
                     if(j > i + sw && r[j].high >= mid)
                        zz.touched = true;
                 }
              }
            m_sd[m_nSD] = zz;
            m_nSD++;
           }
        }
     }
   void              InvalidateSD(void) { m_sdBar = 0; }

   void              DrawSDZones(void)
     {
      CFPContext *c = m_ctx;
      ComputeSD();
      for(int i = 0; i < m_nSD; i++)
        {
         int sh = c.ShiftOfTime(m_sd[i].start);
         int x1 = (sh >= 0) ? MathMax(c.lay.plot.x, ColLeft(sh)) : c.lay.plot.x;
         int x2 = c.lay.scale.x - 1;
         if(x1 >= x2)
            continue;
         int y1 = YPrice(m_sd[i].top), y2 = YPrice(m_sd[i].bottom);
         if(y2 < c.lay.plot.y || y1 > m_plotBottom)
            continue;
         y1 = MathMax(y1, c.lay.plot.y);
         y2 = MathMin(y2, m_plotBottom);
         uint col = m_sd[i].touched ? c.pal.sdGrey : ((m_sd[i].role > 0) ? c.pal.bull : c.pal.bear);
         c.cv.Box(x1, y1, x2 - x1 + 1, MathMax(1, y2 - y1 + 1), FPBlend(c.pal.bg, col, 0.16));
         c.cv.Frame(x1, y1, x2 - x1 + 1, MathMax(1, y2 - y1 + 1), col);
        }
     }

   //--- grid: faint column separators, fainter lines every 2 rows
   void              DrawGrid(void)
     {
      CFPContext *c = m_ctx;
      int y1 = c.lay.plot.y, y2 = m_plotBottom;
      for(int i = 0; i < m_nVis; i++)
        {
         int x = ColLeft(m_visShift[i]) - c.lay.spacing / 2 - 1;
         if(x > c.lay.plot.x)
            c.cv.VL(x, y1, y2, c.pal.grid);
        }
      if(m_rowPx >= 6)
         for(long r = m_rBot; r <= m_rTop; r++)
           {
            if((r % 2) != 0)
               continue;
            int y = RowBot(r) + 1;
            if(y >= y1 && y <= y2)
               c.cv.HL(c.lay.plot.x, c.lay.scale.x - 1, y, c.pal.gridFaint);
           }
     }

   //--- bar volume profile behind the numbers (02 §8.2)
   void              DrawBarVP(void)
     {
      CFPContext *c = m_ctx;
      uint cs = FPBlend(c.pal.bg, c.pal.vpSell, 0.25), cb = FPBlend(c.pal.bg, c.pal.vpBuy, 0.25);
      uint cp = FPBlend(c.pal.bg, c.pal.gold, 0.35);
      for(int i = 0; i < m_nVis; i++)
        {
         CFPBar *b = c.engine.At(m_visShift[i]);
         if(b == NULL || b.state != 0 || b.rows <= 0)
            continue;
         double mx = 0.0;
         for(int k = 0; k < b.rows; k++)
            mx = MathMax(mx, b.sellVol[k] + b.buyVol[k]);
         if(mx <= 0.0)
            continue;
         int xl = ColLeft(m_visShift[i]);
         int bw = c.lay.barW;
         long k0 = MathMax(0, m_rBot - b.rowLow), k1 = MathMin((long)b.rows - 1, m_rTop - b.rowLow);
         for(long k = k0; k <= k1; k++)
           {
            int ki = (int)k;
            int yt = RowTop(b.rowLow + k) + 1, yb = RowBot(b.rowLow + k);
            int ws = (int)MathRound(b.sellVol[ki] / mx * bw), wb = (int)MathRound(b.buyVol[ki] / mx * bw);
            if(ki == b.pocIdx)
               c.cv.Box(xl, yt, ws + wb, yb - yt + 1, cp);
            else
              {
               c.cv.Box(xl, yt, ws, yb - yt + 1, cs);
               c.cv.Box(xl + ws, yt, wb, yb - yt + 1, cb);
              }
           }
        }
     }

   //--- Minimalist cells "SELL x BUY", or compact candles below the minimum cell height
   void              DrawCells(void)
     {
      CFPContext *c = m_ctx;
      bool compact = (c.view.zoom < c.set.minCellHeight);
      int half = c.Px(6);
      uint xCol = FPBlend(c.pal.bg, c.pal.text2, 0.75);
      uint zeroCol = c.pal.textOff;
      m_batch.Clear();
      for(int i = 0; i < m_nVis; i++)
        {
         int sh = m_visShift[i];
         CFPBar *b = c.engine.At(sh);
         if(b == NULL)
            continue;
         int cx = ColMid(sh);
         if(b.state == 1)
           {
            m_batch.Add(c.fSmall, cx, m_midY, "loading", c.pal.textOff, TA_CENTER | TA_VCENTER);
            continue;
           }
         if(b.state == 2)
           {
            m_batch.Add(c.fSmall, cx, m_midY, "no data", c.pal.textOff, TA_CENTER | TA_VCENTER);
            continue;
           }
         if(b.rows <= 0)
            continue;
         if(compact)
           {
            DrawCandle(b, sh);
            continue;
           }
         long k0 = MathMax(0, m_rBot - b.rowLow), k1 = MathMin((long)b.rows - 1, m_rTop - b.rowLow);
         for(long k = k0; k <= k1; k++)
           {
            int ki = (int)k;
            int y = RowMid(b.rowLow + k);
            double sv = b.sellVol[ki], bv = b.buyVol[ki];
            int ts = (int)b.imbSell[ki], tb = (int)b.imbBuy[ki];
            if(ts < 0 || ts > 3)
               ts = 0;
            if(tb < 0 || tb > 3)
               tb = 0;
            bool zero = (sv + bv <= 0.0);
            uint lc = zero ? zeroCol : ((ts > 0) ? c.pal.sellImb[ts] : c.pal.text);
            uint rc = zero ? zeroCol : ((tb > 0) ? c.pal.buyImb[tb] : c.pal.text);
            string ls = c.Vol(sv), rs = c.Vol(bv);
            m_batch.Add(c.fNumB[ts], cx - half, y, ls, lc, TA_RIGHT | TA_VCENTER);
            m_batch.Add(c.fX, cx, y, "x", xCol, TA_CENTER | TA_VCENTER);
            m_batch.Add(c.fNumB[tb], cx + half, y, rs, rc, TA_LEFT | TA_VCENTER);
            //--- per-bar POC outline (02 §8.1, optional): one box around each number
            if(c.set.showPerBarPOC && ki == b.pocIdx)
              {
               int wl = StringLen(ls) * c.cv.CharW(c.fNumB[ts]);
               int wr = StringLen(rs) * c.cv.CharW(c.fNumB[tb]);
               int yt = RowTop(b.rowLow + k) + 1, hh = MathMax(4, m_rowPx - 2);
               c.cv.Frame(cx - half - wl - c.Px(2), yt, wl + c.Px(4), hh, c.pal.fuchsia);
               c.cv.Frame(cx + half - c.Px(2), yt, wr + c.Px(4), hh, c.pal.fuchsia);
              }
           }
        }
      m_batch.Flush(c.cv);
     }

   void              DrawCandle(CFPBar *b, const int sh)
     {
      CFPContext *c = m_ctx;
      int cx = ColMid(sh);
      bool up = (b.close >= b.open);
      uint col = up ? c.pal.bull : c.pal.bear;
      int yh = RowTop(c.engine.PriceToRow(b.high)), yl = RowBot(c.engine.PriceToRow(b.low));
      int wk = MathMax(1, c.Px(3));
      c.cv.Box(cx - wk / 2, yh, wk, MathMax(1, yl - yh + 1), col);
      int yo = RowMid(c.engine.PriceToRow(b.open)), yc = RowMid(c.engine.PriceToRow(b.close));
      int bw = MathMax(wk + 2, c.lay.barW * 2 / 3);
      int top = MathMin(yo, yc), bot = MathMax(yo, yc);
      int half = MathMax(1, m_rowPx / 2);
      c.cv.Box(cx - bw / 2, top - half, bw, MathMax(1, bot - top + 2 * half), col);
     }

   //--- delta bars: rounded box with the signed delta under the lowest row
   void              DrawDeltaBars(void)
     {
      CFPContext *c = m_ctx;
      for(int i = 0; i < m_nVis; i++)
        {
         int sh = m_visShift[i];
         CFPBar *b = c.engine.At(sh);
         if(b == NULL || b.state != 0 || b.rows <= 0)
            continue;
         int y = RowBot(b.rowLow) + c.Px(5);
         int h = c.Px(16);
         if(y > m_plotBottom - h || y < c.lay.plot.y)
            continue;
         int w = c.lay.barW - c.Px(4);
         int x = ColLeft(sh) + c.Px(2);
         uint col = (b.delta >= 0.0) ? c.pal.bull : c.pal.bear;
         c.cv.RoundBox(x, y, w, h, c.Px(3), c.pal.bg);
         c.cv.RoundFrame(x, y, w, h, c.Px(3), col);
         c.cv.Txt(c.fTable, x + w / 2, y + h / 2, c.SVol(b.delta), col, TA_CENTER | TA_VCENTER);
        }
     }

   //--- session POC: dashed purple line + "POC" label (02 §8.2)
   void              DrawSessionPOC(void)
     {
      CFPContext *c = m_ctx;
      if(!c.mkt.pocOk)
         return;
      int y = RowMid(c.mkt.pocRow);
      if(y < c.lay.plot.y || y > m_plotBottom)
         return;
      c.cv.HDash(c.lay.plot.x, c.lay.scale.x - c.Px(4), y, c.pal.purple, c.Px(6), c.Px(4));
      c.cv.Txt(c.fUI, c.lay.scale.x - c.Px(8), y - c.Px(2), "POC", c.pal.purple, TA_RIGHT | TA_BOTTOM);
     }

   //--- own price scale, trade tags, current price tag
   void              DrawPriceScale(void)
     {
      CFPContext *c = m_ctx;
      FPRect sc = c.lay.scale;
      c.cv.Box(sc.x, sc.y, sc.w, sc.h, c.pal.bg);
      int steps[14] = {1, 2, 4, 5, 10, 20, 25, 50, 100, 200, 250, 500, 1000, 2000};
      int N = steps[13];
      for(int i = 0; i < 14; i++)
         if(steps[i] * m_rowPx >= c.Px(28))
           {
            N = steps[i];
            break;
           }
      for(long r = m_rBot; r <= m_rTop; r++)
        {
         if((r % N) != 0)
            continue;
         int y = RowMid(r);
         if(y < sc.y + c.Px(6) || y > FPBottom(sc) - c.Px(6))
            continue;
         c.cv.Txt(c.fScale, sc.x + c.Px(6), y, c.Price(c.engine.RowToPrice(r)), c.pal.text2, TA_LEFT | TA_VCENTER);
        }
      if(c.set.showTrades)
         DrawTradeTags();
      //--- current price tag
      double lastP = LastPrice();
      if(lastP <= 0.0)
         return;
      CFPBar *f = c.engine.At(0);
      bool up = true;
      if(f != NULL && f.state == 0 && f.rows > 0)
         up = (f.close >= f.open);
      uint col = up ? c.pal.bull : c.pal.bear;
      int ty = RowMid(c.engine.PriceToRow(lastP));
      int th = c.Px(18);
      if(ty < sc.y + th / 2 || ty > FPBottom(sc) - th / 2)
         return;
      if(f != NULL && c.view.scroll == 0)
         c.cv.HL(ColRight(0), sc.x - 1, ty, col);
      c.cv.Box(sc.x, ty - th / 2, sc.w, th, col);
      uint tc = (FPLuma(col) > 0.6) ? c.pal.darkText : FPRGB(255, 255, 255);
      c.cv.Txt(c.fScaleB, sc.x + sc.w / 2, ty, c.Price(lastP), tc, TA_CENTER | TA_VCENTER);
      string basis = "LAST";
      ENUM_FP_SOURCE src = c.engine.ActiveSource();
      if(src == FP_SRC_QUOTE_TICKS || src == FP_SRC_AUTO)
         basis = (c.cfg.quotePrice == FP_QP_MID) ? "MID" : "BID";
      c.cv.Txt(c.fTiny, sc.x - c.Px(4), ty - c.Px(1), basis, c.pal.text2, TA_RIGHT | TA_BOTTOM);
     }

   //=================================================================
   //  TRADE OVERLAY (read-only; positions, pending orders, deals)
   //=================================================================
   uint              LineColor(const FPTradeLine &l) const
     {
      if(l.kind == FPT_SL)
         return m_ctx.pal.trSL;
      if(l.kind == FPT_TP)
         return m_ctx.pal.trTP;
      return (l.dir > 0) ? m_ctx.pal.trBuy : m_ctx.pal.trSell;
     }

   void              DrawTradeLines(void)
     {
      CFPContext *c = m_ctx;
      if(m_tr == NULL)
         return;
      for(int i = 0; i < m_tr.nLines; i++)
        {
         int y = YPrice(m_tr.lines[i].price);
         if(y < c.lay.plot.y || y > m_plotBottom)
            continue;
         uint col = LineColor(m_tr.lines[i]);
         if(m_tr.lines[i].pending)
            c.cv.HDash(c.lay.plot.x, c.lay.scale.x - 1, y, col, c.Px(6), c.Px(4));
         else
            c.cv.HL(c.lay.plot.x, c.lay.scale.x - 1, y, col);
         int lx = c.lay.plot.x + c.Px(8);
         if(c.view.miniOn && y >= c.lay.mini.y - c.Px(4) && y <= FPBottom(c.lay.mini) + c.Px(14))
            lx = FPRight(c.lay.mini) + c.Px(8);
         c.cv.Txt(c.fSmall, lx, y - c.Px(1), m_tr.lines[i].info, col, TA_LEFT | TA_BOTTOM);
        }
     }

   void              DrawTradeMarks(void)
     {
      CFPContext *c = m_ctx;
      if(m_tr == NULL)
         return;
      int xMin = c.lay.plot.x, xMax = c.lay.scale.x - 1;
      for(int i = 0; i < m_tr.nMarks; i++)
        {
         int si = c.ShiftOfTime(m_tr.marks[i].tIn);
         if(si < 0)
            continue;
         int xi = ColMid(si), yi = YPrice(m_tr.marks[i].pIn);
         int dir = m_tr.marks[i].dir;
         if(m_tr.marks[i].tOut == 0)
           {
            if(xi >= xMin && xi <= xMax && yi >= c.lay.plot.y && yi <= m_plotBottom)
               c.cv.Arrow(xi, yi, c.Px(5), dir, (dir > 0) ? c.pal.trBuy : c.pal.trSell);
            continue;
           }
         int so = c.ShiftOfTime(m_tr.marks[i].tOut);
         if(so < 0)
            continue;
         int xo = ColMid(so), yo = YPrice(m_tr.marks[i].pOut);
         if((xi < xMin && xo < xMin) || (xi > xMax && xo > xMax))
            continue;
         uint col = (m_tr.marks[i].profit > 0.0) ? c.pal.bull : c.pal.bear;
         if(MathAbs(xo - xi) + MathAbs(yo - yi) < 20000)
            c.cv.DashSeg(xi, yi, xo, yo, col, c.Px(4), c.Px(3));
         if(xi >= xMin && xi <= xMax && yi >= c.lay.plot.y && yi <= m_plotBottom)
            c.cv.Arrow(xi, yi, c.Px(5), dir, col);
         if(xo >= xMin && xo <= xMax && yo >= c.lay.plot.y && yo <= m_plotBottom)
           {
            int q = c.Px(4);
            c.cv.Box(xo - q, yo - q, 2 * q + 1, 2 * q + 1, col);
            c.cv.Box(xo - q + 2, yo - q + 2, 2 * q - 3, 2 * q - 3, c.pal.bg);
           }
        }
     }

   void              DrawTradeTags(void)
     {
      CFPContext *c = m_ctx;
      if(m_tr == NULL || m_tr.nLines <= 0)
         return;
      int n = m_tr.nLines;
      int ys[], idx[];
      ArrayResize(ys, n);
      ArrayResize(idx, n);
      int th = c.Px(16);
      int top = c.lay.scale.y + th / 2, bot = FPBottom(c.lay.scale) - th / 2;
      for(int i = 0; i < n; i++)
        {
         ys[i] = MathMax(top, MathMin(bot, YPrice(m_tr.lines[i].price)));
         idx[i] = i;
        }
      //--- sort by y, then push overlapping tags apart
      for(int i = 1; i < n; i++)
         for(int j = i; j > 0 && ys[j] < ys[j - 1]; j--)
           {
            int t = ys[j]; ys[j] = ys[j - 1]; ys[j - 1] = t;
            int u = idx[j]; idx[j] = idx[j - 1]; idx[j - 1] = u;
           }
      for(int i = 1; i < n; i++)
         if(ys[i] < ys[i - 1] + th)
            ys[i] = ys[i - 1] + th;
      int right = FPRight(c.lay.scale);
      for(int i = 0; i < n; i++)
        {
         int k = idx[i];
         uint col = LineColor(m_tr.lines[k]);
         string tx = m_tr.lines[k].tag;
         int w = MathMax(c.lay.scale.w - c.Px(4), c.cv.TxtW(c.fTag, tx) + c.Px(10));
         int x = right - w;
         int y = ys[i];
         if(m_tr.lines[k].pending)
           {
            c.cv.Box(x, y - th / 2, w, th, c.pal.bg);
            c.cv.Frame(x, y - th / 2, w, th, col);
            c.cv.Txt(c.fTag, x + w / 2, y, tx, col, TA_CENTER | TA_VCENTER);
           }
         else
           {
            c.cv.Box(x, y - th / 2, w, th, col);
            uint tc = (FPLuma(col) > 0.6) ? c.pal.darkText : FPRGB(255, 255, 255);
            c.cv.Txt(c.fTag, x + w / 2, y, tx, tc, TA_CENTER | TA_VCENTER);
           }
        }
     }

   //=================================================================
   //  SUMMARY TABLE (02 §8.7) + countdown
   //=================================================================
   void              DrawTable(void)
     {
      CFPContext *c = m_ctx;
      FPRect t = c.lay.table;
      if(t.h <= 0)
         return;
      c.cv.Box(t.x, t.y, t.w, t.h, c.pal.bg);
      c.cv.HL(t.x, t.x + t.w - 1, t.y, c.pal.border);
      int hh = c.lay.tableHeadH;
      int hy = t.y + hh / 2;
      //--- times
      for(int i = 0; i < m_nVis; i++)
        {
         CFPBar *b = c.engine.At(m_visShift[i]);
         if(b == NULL)
            continue;
         int cx = ColMid(m_visShift[i]);
         if(cx - c.Px(18) < c.lay.plot.x)
            continue;
         c.cv.Txt(c.fTable, cx, hy, TimeToString(b.time, TIME_MINUTES), c.pal.text2, TA_CENTER | TA_VCENTER);
        }
      //--- countdown + collapse button
      int bw = c.Px(22);
      int bx = t.x + t.w - bw - c.Px(6);
      c.cv.Box(bx, t.y + c.Px(3), bw, hh - c.Px(6), c.pal.panelBg);
      c.cv.Frame(bx, t.y + c.Px(3), bw, hh - c.Px(6), c.pal.border);
      int mx = bx + bw / 2;
      c.cv.HL(mx - c.Px(4), mx + c.Px(3), hy, c.pal.text2);
      if(!c.view.tableOn)
         c.cv.VL(mx, hy - c.Px(4), hy + c.Px(3), c.pal.text2);
      c.lay.AddButton(FPB_TABLE_TOGGLE, bx, t.y + c.Px(3), bw, hh - c.Px(6), !c.tester);
      string cd;
      uint cdc;
      Countdown(cd, cdc);
      c.cv.Txt(c.fScaleB, bx - c.Px(10), hy, cd, cdc, TA_RIGHT | TA_VCENTER);
      if(!c.view.tableOn)
         return;
      //--- maxima over the visible bars
      double mVol = 0.0, mDel = 0.0, mCum = 0.0, mBuy = 0.0, mSell = 0.0;
      bool cumOk = c.mkt.ready;
      for(int i = 0; i < m_nVis; i++)
        {
         CFPBar *b = c.engine.At(m_visShift[i]);
         if(b == NULL || b.state != 0)
            continue;
         double bb = 0.0, ss = 0.0;
         BuySell(b, bb, ss);
         mVol = MathMax(mVol, b.volume);
         mDel = MathMax(mDel, MathAbs(b.delta));
         mCum = MathMax(mCum, MathAbs(b.cumDelta));
         mBuy = MathMax(mBuy, bb);
         mSell = MathMax(mSell, ss);
        }
      int rh = c.lay.tableRowH;
      int y0 = t.y + hh;
      string lbl[5] = {"Volume", "Delta", "Cum Delta", "Ask", "Bid"};
      int lx = c.lay.plotRight + c.Px(14), lw = t.x + t.w - c.Px(6) - lx;
      for(int r = 0; r < 5; r++)
        {
         int y = y0 + r * rh;
         if(lw > c.Px(30))
           {
            c.cv.Box(lx, y + 1, lw, rh - 2, c.pal.panelBg);
            c.cv.Frame(lx, y + 1, lw, rh - 2, c.pal.border);
            c.cv.Txt(c.fUI, lx + lw / 2, y + rh / 2, lbl[r], c.pal.text, TA_CENTER | TA_VCENTER);
           }
        }
      for(int i = 0; i < m_nVis; i++)
        {
         int sh = m_visShift[i];
         CFPBar *b = c.engine.At(sh);
         if(b == NULL || b.state != 0)
            continue;
         int cx = ColMid(sh);
         int x1 = cx - c.lay.pitch / 2 + 1;
         int w = c.lay.pitch - 2;
         if(x1 < c.lay.plot.x)
            continue;
         double bb = 0.0, ss = 0.0;
         BuySell(b, bb, ss);
         for(int r = 0; r < 5; r++)
           {
            double v = 0.0, k = 0.0;
            uint col = c.pal.bull;
            bool show = true;
            switch(r)
              {
               case 0:
                  v = b.volume;
                  k = (mVol > 0.0) ? v / mVol : 0.0;
                  col = (b.delta >= 0.0) ? c.pal.bull : c.pal.bear;
                  break;
               case 1:
                  v = b.delta;
                  k = (mDel > 0.0) ? MathAbs(v) / mDel : 0.0;
                  col = (v >= 0.0) ? c.pal.bull : c.pal.bear;
                  break;
               case 2:
                  v = b.cumDelta;
                  k = (mCum > 0.0) ? MathAbs(v) / mCum : 0.0;
                  col = (v >= 0.0) ? c.pal.bull : c.pal.bear;
                  show = cumOk;
                  break;
               case 3:
                  v = bb;
                  k = (mBuy > 0.0) ? v / mBuy : 0.0;
                  col = c.pal.bull;
                  break;
               default:
                  v = ss;
                  k = (mSell > 0.0) ? v / mSell : 0.0;
                  col = c.pal.bear;
                  break;
              }
            int y = y0 + r * rh;
            if(!show)
              {
               c.cv.Box(x1, y + 1, w, rh - 2, c.pal.panelBg);
               continue;
              }
            uint bgc = FPBlend(c.pal.panelBg, col, 0.15 + 0.85 * k);
            c.cv.Box(x1, y + 1, w, rh - 2, bgc);
            uint tc = CFPTheme::TextOn(c.pal, bgc);
            if(r == 2 && !b.cvdValid)
               tc = FPBlend(bgc, tc, 0.5);
            c.cv.Txt(c.fTable, cx, y + rh / 2, TableNum(v), tc, TA_CENTER | TA_VCENTER);
           }
        }
     }

   void              BuySell(CFPBar *b, double &bb, double &ss) const
     {
      bb = 0.0;
      ss = 0.0;
      for(int k = 0; k < b.rows; k++)
        {
         bb += b.buyVol[k];
         ss += b.sellVol[k];
        }
     }
   string            TableNum(const double v) const
     {
      if(MathAbs(v) >= 1000000.0)
         return m_ctx.Vol(v);
      return DoubleToString(v, m_ctx.volDigits > 0 ? 1 : 0);
     }

   void              Countdown(string &text, uint &col)
     {
      CFPContext *c = m_ctx;
      CFPBar *f = c.engine.At(0);
      datetime open = (f != NULL) ? f.time : iTime(c.sym, c.tf, 0);
      long rem = (long)open + c.period - (long)TimeTradeServer();
      col = c.pal.text2;
      if(open <= 0 || rem < 0 || rem > c.period)
        {
         text = "--:--";
         return;
        }
      long hh = rem / 3600, mm = (rem % 3600) / 60, ss = rem % 60;
      if(hh > 0)
         text = IntegerToString(hh) + ":" + StringFormat("%02d:%02d", (int)mm, (int)ss);
      else
         text = StringFormat("%02d:%02d", (int)mm, (int)ss);
      if(rem <= 10)
         col = c.pal.cdRed;
      else
         if(rem <= 20)
            col = c.pal.cdOrange;
         else
            if(rem <= 30)
               col = c.pal.cdYellow;
            else
               col = c.pal.cdGreen;
     }

   //--- status line (source, bucket, history, draw time) at the bottom-left of the plot
   void              DrawStatus(const string text)
     {
      CFPContext *c = m_ctx;
      int x = c.lay.plot.x + c.Px(8);
      int y = m_plotBottom - c.Px(4);
      int w = c.cv.TxtW(c.fTiny, text);
      c.cv.Box(x - c.Px(3), y - c.Px(12), w + c.Px(6), c.Px(13), c.pal.bg);
      c.cv.Txt(c.fTiny, x, y, text, c.pal.text2, TA_LEFT | TA_BOTTOM);
     }
};

#endif // ORDERFLOWFP_UI_FPRENDERER_MQH
//+------------------------------------------------------------------+
