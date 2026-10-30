//+------------------------------------------------------------------+
//| FPAnalytics.mqh - per-bar analytics (02 §5.6)                     |
//| imbalances (diagonal, 3 tiers), stacks -> FPZone, POC, value area |
//+------------------------------------------------------------------+
#ifndef ORDERFLOWFP_FPANALYTICS_MQH
#define ORDERFLOWFP_FPANALYTICS_MQH

#include "FPTypes.mqh"

//+------------------------------------------------------------------+
//| Engine helper: POC over per-row arrays.                           |
//| Max sell+buy; tie -> row closest to closeIdx (row index of the    |
//| close, may be fractional); still tied -> the lower row.           |
//+------------------------------------------------------------------+
int FPPocIndexArrays(const double &sell[], const double &buy[], const int rows, const double closeIdx)
{
   if(rows <= 0 || ArraySize(sell) < rows || ArraySize(buy) < rows)
      return -1;
   int    best     = -1;
   double bestVol  = 0.0;
   double bestDist = 0.0;
   for(int i = 0; i < rows; i++)
     {
      double v = sell[i] + buy[i];
      double d = MathAbs((double)i - closeIdx);
      if(best < 0 || v > bestVol)
        {
         best = i;
         bestVol = v;
         bestDist = d;
        }
      else
         if(v == bestVol && d < bestDist)
           {
            best = i;
            bestDist = d;
           }
     }
   return best;
}

//--- engine helper: POC of a bar with a known (exact) close row index
int FPPocIndexNear(CFPBar *bar, const double closeIdx)
{
   if(bar == NULL)
      return -1;
   return FPPocIndexArrays(bar.sellVol, bar.buyVol, bar.rows, closeIdx);
}

//+------------------------------------------------------------------+
//| Engine helper: zone lifecycle test of ONE closed bar (02 §5.6),   |
//| in integer points so no float edge matching is needed.            |
//| lowPts/highPts = round(bar.low/point), round(bar.high/point).     |
//| Zone edges: bottom = rowFrom*bucket, top = (rowTo+1)*bucket.      |
//| BUY : low <  bottom -> 2 (filled); low  <= top    -> 1 (touched)  |
//| SELL: high > top    -> 2 (filled); high >= bottom -> 1 (touched)  |
//| otherwise 0. (Touch = the bar entered the zone without filling.)  |
//+------------------------------------------------------------------+
int FPZoneHitTest(const FPZone &z, const long lowPts, const long highPts, const int bucketPoints)
{
   long bottom = z.rowFrom * (long)bucketPoints;
   long top    = (z.rowTo + 1) * (long)bucketPoints;
   if(z.dir > 0)
     {
      if(lowPts < bottom)
         return 2;
      if(lowPts <= top)
         return 1;
      return 0;
     }
   if(highPts > top)
      return 2;
   if(highPts >= bottom)
      return 1;
   return 0;
}

class CFPAnalytics
{
private:
   static int        Tier(const double dom, const double opp, const FPConfig &cfg)
     {
      if(dom <= 0.0)
         return 0;
      if(opp <= 0.0)
         return 3;
      double r = dom / opp;
      if(r >= cfg.imbRatio3)
         return 3;
      if(r >= cfg.imbRatio2)
         return 2;
      if(r >= cfg.imbRatio1)
         return 1;
      return 0;
     }

public:
   //+---------------------------------------------------------------+
   //| Diagonal imbalances. BUY at i>=1: buy[i] vs sell[i-1].         |
   //| SELL at i<=n-2: sell[i] vs buy[i+1]. Dominant >= imbMinVolume, |
   //| opposite 0 -> tier 3, ratios inclusive. Edge rows: none.       |
   //+---------------------------------------------------------------+
   static void       ComputeImbalances(CFPBar *bar, const FPConfig &cfg)
     {
      if(bar == NULL)
         return;
      int n = bar.rows;
      if(n < 0)
         n = 0;
      ArrayResize(bar.imbSell, n);
      ArrayResize(bar.imbBuy, n);
      if(n == 0)
         return;
      ArrayInitialize(bar.imbSell, 0);
      ArrayInitialize(bar.imbBuy, 0);
      if(ArraySize(bar.sellVol) < n || ArraySize(bar.buyVol) < n)
         return;
      for(int i = 0; i < n; i++)
        {
         if(i >= 1)
           {
            double b = bar.buyVol[i];
            if(b >= cfg.imbMinVolume)
               bar.imbBuy[i] = (char)Tier(b, bar.sellVol[i - 1], cfg);
           }
         if(i <= n - 2)
           {
            double s = bar.sellVol[i];
            if(s >= cfg.imbMinVolume)
               bar.imbSell[i] = (char)Tier(s, bar.buyVol[i + 1], cfg);
           }
        }
     }

   //+---------------------------------------------------------------+
   //| Runs of >= stackMinRows consecutive rows with tier >= 1.       |
   //| out[] is overwritten: BUY stacks bottom-up, then SELL stacks.  |
   //+---------------------------------------------------------------+
   static int        FindStacks(CFPBar *bar, const FPConfig &cfg, const double rowSize, FPZone &out[])
     {
      ArrayResize(out, 0);
      if(bar == NULL || bar.rows <= 0)
         return 0;
      int n = bar.rows;
      if(ArraySize(bar.imbBuy) < n || ArraySize(bar.imbSell) < n ||
         ArraySize(bar.buyVol) < n || ArraySize(bar.sellVol) < n)
         return 0;
      int minRows = (cfg.stackMinRows < 1) ? 1 : cfg.stackMinRows;
      int cnt = 0;
      for(int pass = 0; pass < 2; pass++)
        {
         int dir = (pass == 0) ? 1 : -1;
         int i = 0;
         while(i < n)
           {
            int t = (dir > 0) ? (int)bar.imbBuy[i] : (int)bar.imbSell[i];
            if(t < 1)
              {
               i++;
               continue;
              }
            int j = i;
            while(j + 1 < n)
              {
               int t2 = (dir > 0) ? (int)bar.imbBuy[j + 1] : (int)bar.imbSell[j + 1];
               if(t2 < 1)
                  break;
               j++;
              }
            int len = j - i + 1;
            if(len >= minRows)
              {
               FPZone z;
               ZeroMemory(z);
               z.dir        = dir;
               z.originTime = bar.time;
               z.rowFrom    = bar.rowLow + i;
               z.rowTo      = bar.rowLow + j;
               z.priceLow   = (double)z.rowFrom * rowSize;
               z.priceHigh  = (double)(z.rowTo + 1) * rowSize;
               z.rowsCount  = len;
               double v = 0.0;
               for(int k = i; k <= j; k++)
                  v += (dir > 0) ? bar.buyVol[k] : bar.sellVol[k];
               z.volume        = v;
               z.filledTime    = 0;
               z.touches       = 0;
               z.lastTouchTime = 0;
               ArrayResize(out, cnt + 1, 8);
               out[cnt] = z;
               cnt++;
              }
            i = j + 1;
           }
        }
      return cnt;
     }

   //+---------------------------------------------------------------+
   //| POC of a bar. A CFPBar does not carry its row size, so the     |
   //| close row used by the tie-break is estimated by interpolating  |
   //| the close between low (row 0) and high (row rows-1). The       |
   //| engine stores bar.pocIdx computed with the EXACT close row.    |
   //+---------------------------------------------------------------+
   static int        PocIndex(CFPBar *bar)
     {
      if(bar == NULL || bar.rows <= 0)
         return -1;
      double ci = 0.0;
      if(bar.rows > 1 && bar.high > bar.low)
         ci = (bar.close - bar.low) / (bar.high - bar.low) * (double)(bar.rows - 1);
      return FPPocIndexNear(bar, ci);
     }

   //+---------------------------------------------------------------+
   //| Value area. Uses p.pocIdx when it is a valid index, otherwise  |
   //| computes the POC (max; tie -> lower row). Recomputes p.total.  |
   //| Expands from the POC by comparing the next two rows above with |
   //| the next two below; adds the larger pair (tie -> above) until  |
   //| the accumulated volume >= pct * total.                         |
   //+---------------------------------------------------------------+
   static bool       ValueArea(FPProfile &p, const double pct)
     {
      int n = p.rows;
      if(n <= 0 || ArraySize(p.sell) < n || ArraySize(p.buy) < n)
        {
         p.total = 0.0;
         p.pocIdx = -1;
         p.vahIdx = -1;
         p.valIdx = -1;
         return false;
        }
      double total = 0.0;
      for(int i = 0; i < n; i++)
         total += p.sell[i] + p.buy[i];
      p.total = total;
      if(total <= 0.0)
        {
         p.pocIdx = -1;
         p.vahIdx = -1;
         p.valIdx = -1;
         return false;
        }
      if(p.pocIdx < 0 || p.pocIdx >= n)
         p.pocIdx = FPPocIndexArrays(p.sell, p.buy, n, -1.0);
      double q = pct;
      if(q > 1.0)
         q = 1.0;
      if(q < 0.0)
         q = 0.0;
      double target = q * total;
      int lo = p.pocIdx;
      int hi = p.pocIdx;
      double acc = p.sell[lo] + p.buy[lo];
      while(acc < target)
        {
         bool canUp = (hi < n - 1);
         bool canDn = (lo > 0);
         if(!canUp && !canDn)
            break;
         double up = 0.0, dn = 0.0;
         int upCnt = 0, dnCnt = 0;
         for(int k = 1; k <= 2; k++)
           {
            if(hi + k <= n - 1)
              {
               up += p.sell[hi + k] + p.buy[hi + k];
               upCnt++;
              }
            if(lo - k >= 0)
              {
               dn += p.sell[lo - k] + p.buy[lo - k];
               dnCnt++;
              }
           }
         if(canUp && (!canDn || up >= dn))
           {
            acc += up;
            hi  += upCnt;
           }
         else
           {
            acc += dn;
            lo  -= dnCnt;
           }
        }
      p.vahIdx = hi;
      p.valIdx = lo;
      return true;
     }
};

#endif // ORDERFLOWFP_FPANALYTICS_MQH
//+------------------------------------------------------------------+
