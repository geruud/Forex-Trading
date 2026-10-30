//+------------------------------------------------------------------+
//| FPTests.mq5 - OrderFlowFP engine unit tests (02 §11)              |
//| Every engine gets an in-memory CFPTickSource BEFORE Init and runs |
//| with historyBars = 0, so no test touches the real tick base.      |
//| Prices are integer multiples of the chart symbol's point, so the  |
//| results do not depend on the chart the script is dropped on.     |
//+------------------------------------------------------------------+
#property script_show_inputs
#property version   "1.00"

#include <OrderFlowFP\FPEngine.mqh>

input bool InpVerbose = true;   // print every PASS line (FAIL lines are always printed)

#define TF_BA (TICK_FLAG_BID | TICK_FLAG_ASK)

int    g_pass  = 0;
int    g_fail  = 0;
double g_point = 0.0;

//+------------------------------------------------------------------+
//| helpers                                                           |
//+------------------------------------------------------------------+
void Check(const bool cond, const string name, const string detail = "")
{
   if(cond)
     {
      g_pass++;
      if(InpVerbose)
         Print("PASS ", name);
     }
   else
     {
      g_fail++;
      Print("FAIL ", name, (detail != "") ? (" - " + detail) : "");
     }
}

double P(const double pts) { return pts * g_point; }
bool   PxEq(const double a, const double b) { return (MathAbs(a - b) <= g_point * 1e-6); }
bool   VEq(const double a, const double b) { return (MathAbs(a - b) <= 1e-9); }

MqlTick Q(const long msc, const double bidPts, const double askPts, const uint flags)
{
   MqlTick t;
   ZeroMemory(t);
   t.time = (datetime)(msc / 1000);
   t.time_msc = msc;
   t.bid = P(bidPts);
   t.ask = P(askPts);
   t.flags = flags;
   return t;
}

MqlTick T(const long msc, const double bidPts, const double askPts, const double lastPts, const ulong vol,
          const double volReal, const uint flags)
{
   MqlTick t;
   ZeroMemory(t);
   t.time = (datetime)(msc / 1000);
   t.time_msc = msc;
   t.bid = P(bidPts);
   t.ask = P(askPts);
   t.last = P(lastPts);
   t.volume = vol;
   t.volume_real = volReal;
   t.flags = flags;
   return t;
}

void Push(MqlTick &arr[], const MqlTick &t)
{
   int n = ArraySize(arr);
   ArrayResize(arr, n + 1, 64);
   arr[n] = t;
}
void AddQ(MqlTick &arr[], const long msc, const double bidPts, const double askPts, const uint flags)
{
   MqlTick t = Q(msc, bidPts, askPts, flags);
   Push(arr, t);
}
void AddT(MqlTick &arr[], const long msc, const double bidPts, const double askPts, const double lastPts,
          const ulong vol, const double volReal, const uint flags)
{
   MqlTick t = T(msc, bidPts, askPts, lastPts, vol, volReal, flags);
   Push(arr, t);
}
void Slice(const MqlTick &src[], const int from, const int count, MqlTick &dst[])
{
   ArrayResize(dst, count);
   for(int i = 0; i < count; i++)
      dst[i] = src[from + i];
}

//+------------------------------------------------------------------+
//| In-memory tick source: serves Since() and Range() from the same   |
//| hand-made ticks; m_visible simulates ticks arriving over time.    |
//+------------------------------------------------------------------+
class CFPMemTickSource : public CFPTickSource
{
public:
   MqlTick           m_ticks[];
   int               m_total;
   int               m_visible;
   bool              m_zeroFrom;
   int               m_sinceCalls;
   int               m_rangeCalls;

                     CFPMemTickSource(void) : m_total(0), m_visible(0), m_zeroFrom(false), m_sinceCalls(0), m_rangeCalls(0) {}
   void              SetTicks(const MqlTick &arr[])
     {
      m_total = ArraySize(arr);
      ArrayResize(m_ticks, m_total);
      for(int i = 0; i < m_total; i++)
         m_ticks[i] = arr[i];
      m_visible = m_total;
     }
   void              ResetCounters(void)
     {
      m_zeroFrom = false;
      m_sinceCalls = 0;
      m_rangeCalls = 0;
     }
   virtual int       Since(const string symbol, const ulong fromMsc, const uint count, MqlTick &out[]) override
     {
      m_sinceCalls++;
      ArrayResize(out, 0);
      int vis = (m_visible < m_total) ? m_visible : m_total;
      if(fromMsc == 0)
        {
         m_zeroFrom = true;
         int n = ((int)count < vis) ? (int)count : vis;
         ArrayResize(out, n);
         for(int i = 0; i < n; i++)
            out[i] = m_ticks[vis - n + i];
         return n;
        }
      int c = 0;
      for(int i = 0; i < vis && c < (int)count; i++)
        {
         if(m_ticks[i].time_msc < (long)fromMsc)
            continue;
         ArrayResize(out, c + 1, 64);
         out[c] = m_ticks[i];
         c++;
        }
      return c;
     }
   virtual int       Range(const string symbol, const ulong fromMsc, const ulong toMsc, MqlTick &out[]) override
     {
      m_rangeCalls++;
      ArrayResize(out, 0);
      int vis = (m_visible < m_total) ? m_visible : m_total;
      int c = 0;
      for(int i = 0; i < vis; i++)
        {
         long ms = m_ticks[i].time_msc;
         if(ms < (long)fromMsc || ms > (long)toMsc)
            continue;
         ArrayResize(out, c + 1, 64);
         out[c] = m_ticks[i];
         c++;
        }
      return c;
     }
};

void MakeCfg(FPConfig &c, const ENUM_FP_SOURCE src, const int bucket, const int sessMin, const double minVol)
{
   c.symbol = _Symbol;
   c.timeframe = PERIOD_M1;
   c.bucketPoints = bucket;
   c.source = src;
   c.quotePrice = FP_QP_BID;
   c.historyBars = 0;          // live-only / test mode: no history, no bootstrap, no CopyTime
   c.sessionStartMin = sessMin;
   c.imbRatio1 = 2.0;
   c.imbRatio2 = 3.0;
   c.imbRatio3 = 4.0;
   c.imbMinVolume = minVol;
   c.stackMinRows = 3;
   c.valueAreaPct = 0.70;
}

bool InitEngine(CFPEngine &e, CFPMemTickSource &src, const ENUM_FP_SOURCE s, const int bucket, const int sessMin, const double minVol)
{
   FPConfig c;
   MakeCfg(c, s, bucket, sessMin, minVol);
   e.SetTickSource(GetPointer(src));       // installed BEFORE Init: Init never sees the real tick base
   return e.Init(c);
}

CFPBar *MkBar(const double &sell[], const double &buy[], const long rowLow, const datetime t)
{
   CFPBar *b = new CFPBar();
   int n = ArraySize(sell);
   b.time = t;
   b.rowLow = rowLow;
   b.rows = n;
   ArrayResize(b.sellVol, n);
   ArrayResize(b.buyVol, n);
   ArrayResize(b.imbSell, n);
   ArrayResize(b.imbBuy, n);
   double v = 0.0, d = 0.0;
   for(int i = 0; i < n; i++)
     {
      b.sellVol[i] = sell[i];
      b.buyVol[i] = buy[i];
      b.imbSell[i] = 0;
      b.imbBuy[i] = 0;
      v += sell[i] + buy[i];
      d += buy[i] - sell[i];
     }
   b.volume = v;
   b.delta = d;
   b.closed = true;
   return b;
}

void SnapBar(CFPBar *dst, CFPBar *src)
{
   dst.time = src.time;
   dst.open = src.open;
   dst.high = src.high;
   dst.low = src.low;
   dst.close = src.close;
   dst.rowLow = src.rowLow;
   dst.rows = src.rows;
   ArrayResize(dst.sellVol, src.rows);
   ArrayResize(dst.buyVol, src.rows);
   ArrayResize(dst.imbSell, src.rows);
   ArrayResize(dst.imbBuy, src.rows);
   for(int i = 0; i < src.rows; i++)
     {
      dst.sellVol[i] = src.sellVol[i];
      dst.buyVol[i] = src.buyVol[i];
      dst.imbSell[i] = src.imbSell[i];
      dst.imbBuy[i] = src.imbBuy[i];
     }
   dst.volume = src.volume;
   dst.delta = src.delta;
   dst.deltaMax = src.deltaMax;
   dst.deltaMin = src.deltaMin;
   dst.ticks = src.ticks;
   dst.pocIdx = src.pocIdx;
   dst.cumDelta = src.cumDelta;
   dst.cvdValid = src.cvdValid;
}

//--- exact equality (same ticks + same code path => bit-identical doubles)
bool BarsEqual(CFPBar *a, CFPBar *b, string &why)
{
   why = "";
   if(a == NULL || b == NULL)
     {
      why = "NULL bar";
      return false;
     }
   if(a.time != b.time)
      why += "time ";
   if(a.ticks != b.ticks)
      why += "ticks(" + IntegerToString(a.ticks) + "/" + IntegerToString(b.ticks) + ") ";
   if(a.rowLow != b.rowLow || a.rows != b.rows)
      why += "rows ";
   if(a.volume != b.volume || a.delta != b.delta || a.deltaMax != b.deltaMax || a.deltaMin != b.deltaMin)
      why += "vol/delta ";
   if(a.open != b.open || a.high != b.high || a.low != b.low || a.close != b.close)
      why += "ohlc ";
   if(a.pocIdx != b.pocIdx)
      why += "poc ";
   if(a.cumDelta != b.cumDelta || a.cvdValid != b.cvdValid)
      why += "cvd ";
   if(a.rows == b.rows)
      for(int i = 0; i < a.rows; i++)
         if(a.sellVol[i] != b.sellVol[i] || a.buyVol[i] != b.buyVol[i] ||
            a.imbSell[i] != b.imbSell[i] || a.imbBuy[i] != b.imbBuy[i])
           {
            why += "row" + IntegerToString(i) + " ";
            break;
           }
   return (why == "");
}

string BarStr(CFPBar *b)
{
   if(b == NULL)
      return "NULL";
   string s = "t=" + TimeToString(b.time, TIME_DATE | TIME_SECONDS) + " ticks=" + IntegerToString(b.ticks) +
              " vol=" + DoubleToString(b.volume, 2) + " delta=" + DoubleToString(b.delta, 2) +
              " rowLow=" + IntegerToString(b.rowLow) + " rows=" + IntegerToString(b.rows) + " [";
   for(int i = 0; i < b.rows; i++)
      s += DoubleToString(b.sellVol[i], 1) + "x" + DoubleToString(b.buyVol[i], 1) + " ";
   return s + "]";
}

//+------------------------------------------------------------------+
//| 1. classification cascade per source (+ AUTO source decision)    |
//+------------------------------------------------------------------+
void Group1()
{
   CFPClassifier c;
   double px, sz;
   int sd;
   bool ok;
   MqlTick t;
   //--- QUOTE_TICKS, BID basis
   c.Setup(FP_SRC_QUOTE_TICKS, FP_QP_BID);
   t = Q(1000, 1000, 1002, TF_BA);
   ok = c.Classify(t, px, sz, sd);
   Check(ok && sd == 0 && VEq(sz, 1.0) && PxEq(px, P(1000)), "1.01 QUOTE unseeded first tick -> split 50/50, size 1, price=bid");
   t = Q(2000, 1001, 1003, TF_BA);
   ok = c.Classify(t, px, sz, sd);
   Check(ok && sd == 1, "1.02 QUOTE mid up -> BUY");
   t = Q(3000, 1001, 1003, TICK_FLAG_ASK);
   ok = c.Classify(t, px, sz, sd);
   Check(ok && sd == 1, "1.03 QUOTE mid flat -> previous side (BUY)");
   t = Q(4000, 1000, 1002, TICK_FLAG_BID);
   ok = c.Classify(t, px, sz, sd);
   Check(ok && sd == -1, "1.04 QUOTE mid down -> SELL");
   t = T(5000, 1000, 1002, 1001, 5, 5.0, TICK_FLAG_LAST | TICK_FLAG_VOLUME);
   ok = c.Classify(t, px, sz, sd);
   Check(!ok, "1.05 QUOTE tick without BID/ASK flag is not counted");
   t = Q(6000, 1000, 1004, TICK_FLAG_ASK);
   ok = c.Classify(t, px, sz, sd);
   Check(ok && sd == 1 && PxEq(px, P(1000)), "1.06 QUOTE ask-only change: counted at bid, mid rule (1001->1002) -> BUY");
   c.Reset();
   t = Q(1000, 1000, 1002, TF_BA);
   c.Classify(t, px, sz, sd);
   t = Q(2000, 1000, 1002, TF_BA);
   ok = c.Classify(t, px, sz, sd);
   Check(ok && sd == 0, "1.07 QUOTE flat mid while side still unknown -> split");
   c.Setup(FP_SRC_QUOTE_TICKS, FP_QP_MID);
   t = Q(1000, 1000, 1003, TF_BA);
   ok = c.Classify(t, px, sz, sd);
   Check(ok && PxEq(px, P(1001.5)), "1.08 QUOTE MID basis: row price = mid");
   //--- TRADE_TICKS
   c.Setup(FP_SRC_TRADE_TICKS, FP_QP_BID);
   t = Q(1000, 1000, 1002, TF_BA);
   ok = c.Classify(t, px, sz, sd);
   Check(!ok, "1.09 TRADE quote tick is not counted");
   t = T(2000, 1002, 1004, 1002, 3, 0.0, TICK_FLAG_LAST | TICK_FLAG_VOLUME);
   ok = c.Classify(t, px, sz, sd);
   Check(ok && sd == 1 && VEq(sz, 3.0) && PxEq(px, P(1002)),
         "1.10 TRADE quote rule uses the PREVIOUS tick's ask (last 1002 >= prev ask 1002 -> BUY; own bid is 1002)");
   t = T(3000, 1002, 1004, 1003, 1, 1.5, TICK_FLAG_LAST);
   ok = c.Classify(t, px, sz, sd);
   Check(ok && sd == 1 && VEq(sz, 1.5), "1.11 TRADE inside spread -> tick rule up -> BUY; size = volume_real");
   t = T(4000, 1002, 1004, 1003, 1, 0.0, TICK_FLAG_LAST);
   ok = c.Classify(t, px, sz, sd);
   Check(ok && sd == 1, "1.12 TRADE inside spread, flat price -> previous side (BUY)");
   t = T(5000, 1000, 1004, 1001, 2, 0.0, TICK_FLAG_LAST | TICK_FLAG_VOLUME);
   ok = c.Classify(t, px, sz, sd);
   Check(ok && sd == -1 && VEq(sz, 2.0), "1.13 TRADE last <= previous bid -> SELL");
   t = T(6000, 1000, 1004, 1002, 1, 0.0, TICK_FLAG_LAST);
   ok = c.Classify(t, px, sz, sd);
   Check(ok && sd == 1, "1.14 TRADE inside spread, up-tick -> BUY");
   t = T(7000, 1000, 1004, 1001, 1, 0.0, TICK_FLAG_LAST);
   ok = c.Classify(t, px, sz, sd);
   Check(ok && sd == -1, "1.15 TRADE inside spread, down-tick -> SELL");
   c.Reset();
   t = T(1000, 0, 0, 1000, 1, 0.0, TICK_FLAG_LAST);
   ok = c.Classify(t, px, sz, sd);
   Check(ok && sd == 0, "1.16 TRADE unseeded (no quote, no previous trade) -> split");
   c.Reset();
   t = Q(1000, 1000, 1004, TF_BA);
   c.Classify(t, px, sz, sd);
   t = T(2000, 1000, 1004, 1002, 1, 0.0, TICK_FLAG_LAST);
   ok = c.Classify(t, px, sz, sd);
   Check(ok && sd == 0, "1.17 TRADE inside spread with no previous trade -> split");
   //--- EXCHANGE_FLAGS
   c.Setup(FP_SRC_EXCHANGE_FLAGS, FP_QP_BID);
   t = Q(1000, 1000, 1002, TF_BA);
   ok = c.Classify(t, px, sz, sd);
   Check(!ok, "1.18 EXCHANGE quote tick is not counted");
   t = T(2000, 1000, 1002, 1000, 1, 0.0, TICK_FLAG_LAST | TICK_FLAG_BUY);
   ok = c.Classify(t, px, sz, sd);
   Check(ok && sd == 1, "1.19 EXCHANGE BUY flag wins over the quote rule");
   t = T(3000, 1000, 1002, 1002, 2, 0.0, TICK_FLAG_LAST | TICK_FLAG_SELL);
   ok = c.Classify(t, px, sz, sd);
   Check(ok && sd == -1 && VEq(sz, 2.0), "1.20 EXCHANGE SELL flag wins over the quote rule");
   t = T(4000, 1000, 1002, 1002, 1, 0.0, TICK_FLAG_LAST | TICK_FLAG_BUY | TICK_FLAG_SELL);
   ok = c.Classify(t, px, sz, sd);
   Check(ok && sd == 1, "1.21 EXCHANGE both flags -> quote rule (last >= prev ask) -> BUY");
   t = T(5000, 1000, 1002, 1001, 1, 0.0, TICK_FLAG_LAST);
   ok = c.Classify(t, px, sz, sd);
   Check(ok && sd == -1, "1.22 EXCHANGE no side flag, inside spread -> tick rule down -> SELL");
   t = T(6000, 1000, 1002, 1001, 1, 0.0, TICK_FLAG_LAST | TICK_FLAG_VOLUME);
   ok = c.Classify(t, px, sz, sd);
   Check(ok && sd == -1, "1.23 EXCHANGE no side flag, flat price -> previous side (SELL)");
   //--- trade detection by flags only
   t = T(7000, 1000, 1002, 1001, 9, 9.0, TICK_FLAG_BID);
   Check(!CFPClassifier::IsTradeTick(t), "1.24 a BID tick with stale volume/last is NOT a trade tick");
   //--- AUTO source decision (engine Init samples the injected source)
   for(int k = 0; k < 4; k++)
     {
      MqlTick arr[];
      for(int i = 0; i < 10; i++)
        {
         long ms = 1709546400000 + (long)i * 100;
         bool trade = false;
         uint fl = 0;
         if(k == 0 && i < 3)
           {
            trade = true;
            fl = TICK_FLAG_LAST | TICK_FLAG_BUY;
           }
         if(k == 1 && i < 5)
           {
            trade = true;
            fl = TICK_FLAG_LAST | TICK_FLAG_VOLUME;
           }
         if(k == 3 && i < 1)
           {
            trade = true;
            fl = TICK_FLAG_LAST | TICK_FLAG_SELL;
           }
         if(trade)
            AddT(arr, ms, 1000, 1002, 1001, 1, 0.0, fl);
         else
            AddT(arr, ms, 1000 + i, 1002 + i, 1001, 5, 5.0, TICK_FLAG_BID);   // quote tick with STALE volume/last
        }
      CFPMemTickSource src;
      src.SetTicks(arr);
      CFPEngine e;
      bool init = InitEngine(e, src, FP_SRC_AUTO, 10, 0, 1.0);
      ENUM_FP_SOURCE got = e.ActiveSource();
      ENUM_FP_SOURCE want = (k == 0) ? FP_SRC_EXCHANGE_FLAGS : (k == 1) ? FP_SRC_TRADE_TICKS : FP_SRC_QUOTE_TICKS;
      string nm[] = {"30% flagged trades -> EXCHANGE_FLAGS", "50% unflagged trades with last>0 -> TRADE_TICKS",
                     "quote ticks with stale volume -> QUOTE_TICKS", "10% trades (<20%) -> QUOTE_TICKS"};
      Check(init && got == want, "1.25." + IntegerToString(k + 1) + " AUTO: " + nm[k], "got " + EnumToString(got));
      e.Deinit();
     }
}

//+------------------------------------------------------------------+
//| 2. floorDiv, PriceToRow, RowToPrice (+ presets, pure helpers)     |
//+------------------------------------------------------------------+
void Group2()
{
   Check(FPFloorDiv(7, 5) == 1 && FPFloorDiv(5, 5) == 1 && FPFloorDiv(4, 5) == 0 && FPFloorDiv(0, 5) == 0,
         "2.01 floorDiv positive numerators");
   Check(FPFloorDiv(-1, 5) == -1 && FPFloorDiv(-5, 5) == -1 && FPFloorDiv(-6, 5) == -2 && FPFloorDiv(-7, 5) == -2 &&
         FPFloorDiv(-6, 3) == -2 && FPFloorDiv(-1234, 5) == -247, "2.02 floorDiv negative numerators (floor, not truncation)");
   CFPMemTickSource src;
   CFPEngine e5, e40, e1;
   bool i5 = InitEngine(e5, src, FP_SRC_QUOTE_TICKS, 5, 0, 1.0);
   bool i40 = InitEngine(e40, src, FP_SRC_QUOTE_TICKS, 40, 0, 1.0);
   bool i1 = InitEngine(e1, src, FP_SRC_QUOTE_TICKS, 1, 0, 1.0);
   Check(i5 && i40 && i1, "2.03 engines init (bucket 5/40/1)", e5.LastError());
   Check(PxEq(e5.RowSize(), P(5)) && PxEq(e40.RowSize(), P(40)) && PxEq(e1.RowSize(), P(1)), "2.04 RowSize = bucket x point");
   Check(e5.PriceToRow(P(1234)) == 246 && e5.PriceToRow(P(1235)) == 247 && e5.PriceToRow(P(1239)) == 247 &&
         e5.PriceToRow(P(1240)) == 248 && e5.PriceToRow(P(0)) == 0 && e5.PriceToRow(P(4)) == 0,
         "2.05 PriceToRow bucket 5, positive prices");
   Check(e5.PriceToRow(P(-1)) == -1 && e5.PriceToRow(P(-5)) == -1 && e5.PriceToRow(P(-6)) == -2 &&
         e5.PriceToRow(P(-1234)) == -247 && e5.PriceToRow(P(-1235)) == -247 && e5.PriceToRow(P(-1236)) == -248,
         "2.06 PriceToRow bucket 5, negative prices");
   Check(PxEq(e5.RowToPrice(246), P(1230)) && PxEq(e5.RowToPrice(-247), P(-1235)) && PxEq(e5.RowToPrice(0), 0.0),
         "2.07 RowToPrice = bottom edge (bucket 5)");
   long rs[] = {-100000, -247, -2, -1, 0, 1, 246, 400000};
   bool rt = true;
   for(int i = 0; i < ArraySize(rs); i++)
      if(e5.PriceToRow(e5.RowToPrice(rs[i])) != rs[i] || e40.PriceToRow(e40.RowToPrice(rs[i])) != rs[i])
         rt = false;
   Check(rt, "2.08 PriceToRow(RowToPrice(r)) == r for +/- rows (bucket 5 and 40)");
   Check(e40.PriceToRow(P(200039)) == 5000 && e40.PriceToRow(P(200040)) == 5001 && e40.PriceToRow(P(-40)) == -1 &&
         e40.PriceToRow(P(-41)) == -2 && PxEq(e40.RowToPrice(5001), P(200040)), "2.09 PriceToRow/RowToPrice bucket 40");
   Check(e1.PriceToRow(P(-1)) == -1 && e1.PriceToRow(P(123456)) == 123456 && e1.PriceToRow(P(1234.4)) == 1234 &&
         e1.PriceToRow(P(1234.6)) == 1235, "2.10 PriceToRow bucket 1 (rounds to the nearest point first)");
   //--- presets (pure: no symbol access)
   double v;
   string key;
   int kind = CFPPresets::MatchPreset(CFPPresets::CleanSymbol("XAUUSD.m"), v, key);
   Check(kind == 1 && key == "XAUUSD" && MathAbs(v - 0.40) < 1e-12, "2.11 preset XAUUSD.m -> step 0.40");
   kind = CFPPresets::MatchPreset(CFPPresets::CleanSymbol("#US30.cash"), v, key);
   Check(kind == 1 && key == "US30", "2.12 preset #US30.cash -> US30");
   kind = CFPPresets::MatchPreset(CFPPresets::CleanSymbol("EURUSD-ECN"), v, key);
   Check(kind == 1 && key == "EURUSD" && MathAbs(v - 0.00005) < 1e-12, "2.13 preset EURUSD-ECN -> 0.00005");
   kind = CFPPresets::MatchPreset(CFPPresets::CleanSymbol("@GCE"), v, key);
   Check(kind == 2 && key == "GCE" && MathAbs(v - 5.0) < 1e-12, "2.14 preset @GCE -> 5 ticks");
   kind = CFPPresets::MatchPreset(CFPPresets::CleanSymbol("ESZ4"), v, key);
   Check(kind == 2 && key == "ES", "2.15 preset ESZ4 -> ES (1 tick)");
   kind = CFPPresets::MatchPreset(CFPPresets::CleanSymbol("ESP35"), v, key);
   Check(kind == 0, "2.16 ESP35 is not the ES future");
   Check(CFPPresets::NiceRound(17.3) == 20 && CFPPresets::NiceRound(23.0) == 25 && CFPPresets::NiceRound(0.4) == 1 &&
         CFPPresets::NiceRound(1.2) == 1 && CFPPresets::NiceRound(240.0) == 250 && CFPPresets::NiceRound(140.0) == 100,
         "2.17 niceRound");
}

//+------------------------------------------------------------------+
//| 3. imbalance anchors (02 §5.6)                                    |
//+------------------------------------------------------------------+
void Group3()
{
   FPConfig c;
   MakeCfg(c, FP_SRC_QUOTE_TICKS, 10, 0, 10.0);
   {
      double s[] = {18, 0}, b[] = {0, 96};
      CFPBar *x = MkBar(s, b, 100, 0);
      CFPAnalytics::ComputeImbalances(x, c);
      Check(x.imbBuy[1] == 3 && x.imbSell[0] == 0, "3.01 buy 96 vs sell 18 below -> BUY tier 3 (5.3x)");
      delete x;
   }
   {
      double s[] = {20, 0}, b[] = {0, 75};
      CFPBar *x = MkBar(s, b, 100, 0);
      CFPAnalytics::ComputeImbalances(x, c);
      Check(x.imbBuy[1] == 2, "3.02 buy 75 vs sell 20 below -> BUY tier 2 (3.75x)");
      delete x;
   }
   {
      double s[] = {463, 0}, b[] = {0, 237};
      CFPBar *x = MkBar(s, b, 100, 0);
      CFPAnalytics::ComputeImbalances(x, c);
      Check(x.imbSell[0] == 0 && x.imbBuy[1] == 0, "3.03 sell 463 vs buy 237 above -> none (1.95x)");
      delete x;
   }
   {
      double s[] = {3, 0}, b[] = {0, 7};
      CFPBar *x = MkBar(s, b, 100, 0);
      CFPAnalytics::ComputeImbalances(x, c);
      Check(x.imbBuy[1] == 0, "3.04 buy 7 vs sell 3 below -> none (min volume 10)");
      delete x;
   }
   {
      double s[] = {0, 0}, b[] = {0, 10};
      CFPBar *x = MkBar(s, b, 100, 0);
      CFPAnalytics::ComputeImbalances(x, c);
      Check(x.imbBuy[1] == 3, "3.05 opposite side 0 -> tier 3");
      delete x;
   }
   {
      double s[] = {10, 10, 10, 10}, b[] = {0, 20, 30, 40};
      CFPBar *x = MkBar(s, b, 100, 0);
      CFPAnalytics::ComputeImbalances(x, c);
      Check(x.imbBuy[1] == 1 && x.imbBuy[2] == 2 && x.imbBuy[3] == 3, "3.06 ratios are inclusive: 2.0x->1, 3.0x->2, 4.0x->3");
      delete x;
   }
   {
      double s[] = {40, 0}, b[] = {0, 10};
      CFPBar *x = MkBar(s, b, 100, 0);
      CFPAnalytics::ComputeImbalances(x, c);
      Check(x.imbSell[0] == 3 && x.imbBuy[1] == 0, "3.07 SELL: sell 40 vs buy 10 above -> SELL tier 3");
      delete x;
   }
   {
      double s[] = {0, 50}, b[] = {50, 0};
      CFPBar *x = MkBar(s, b, 100, 0);
      CFPAnalytics::ComputeImbalances(x, c);
      Check(x.imbBuy[0] == 0 && x.imbSell[1] == 0, "3.08 edge rows: no BUY at the bottom row, no SELL at the top row");
      delete x;
   }
   //--- POC tie-break (closest to the close, then the lower row)
   {
      double s[] = {5, 9, 9, 3}, b[] = {0, 0, 0, 0};
      CFPBar *x = MkBar(s, b, 100, 0);
      x.low = P(1000);
      x.high = P(1030);
      x.close = P(1030);
      int p1 = CFPAnalytics::PocIndex(x);
      x.close = P(1000);
      int p2 = CFPAnalytics::PocIndex(x);
      Check(p1 == 2 && p2 == 1, "3.09 POC tie -> row closest to the close", "got " + IntegerToString(p1) + "/" + IntegerToString(p2));
      delete x;
   }
   {
      double s[] = {9, 5, 9}, b[] = {0, 0, 0};
      CFPBar *x = MkBar(s, b, 100, 0);
      x.low = P(1000);
      x.high = P(1020);
      x.close = P(1010);
      Check(CFPAnalytics::PocIndex(x) == 0, "3.10 POC tie at equal distance -> lower row");
      delete x;
   }
}

//+------------------------------------------------------------------+
//| 4. stacks and the zone fill/touch lifecycle                       |
//+------------------------------------------------------------------+
void Group4()
{
   FPConfig c;
   MakeCfg(c, FP_SRC_QUOTE_TICKS, 10, 0, 10.0);
   double rowSize = P(10);
   {
      double s[] = {10, 10, 10, 10, 50}, b[] = {0, 40, 40, 40, 5};
      CFPBar *x = MkBar(s, b, 100, D'2024.03.04 09:00');
      CFPAnalytics::ComputeImbalances(x, c);
      FPZone z[];
      int n = CFPAnalytics::FindStacks(x, c, rowSize, z);
      Check(n == 1 && z[0].dir == 1 && z[0].rowFrom == 101 && z[0].rowTo == 103 && z[0].rowsCount == 3 &&
            VEq(z[0].volume, 120.0) && PxEq(z[0].priceLow, P(1010)) && PxEq(z[0].priceHigh, P(1040)) &&
            z[0].originTime == D'2024.03.04 09:00' && z[0].filledTime == 0 && z[0].touches == 0,
            "4.01 BUY stack rows 101..103 -> one support zone (edges = bottom of rowFrom / top of rowTo)",
            "n=" + IntegerToString(n));
      c.stackMinRows = 4;
      n = CFPAnalytics::FindStacks(x, c, rowSize, z);
      Check(n == 0, "4.02 a 3-row run is not a stack when stackMinRows = 4");
      c.stackMinRows = 3;
      delete x;
   }
   {
      double s[] = {50, 50, 50, 0}, b[] = {0, 0, 0, 0};
      CFPBar *x = MkBar(s, b, 100, 0);
      CFPAnalytics::ComputeImbalances(x, c);
      FPZone z[];
      int n = CFPAnalytics::FindStacks(x, c, rowSize, z);
      Check(n == 1 && z[0].dir == -1 && z[0].rowFrom == 100 && z[0].rowTo == 102 && VEq(z[0].volume, 150.0),
            "4.03 SELL stack rows 100..102 -> one resistance zone");
      delete x;
   }
   //--- pure lifecycle test in integer points (bucket 10: zone rows 101..103 -> edges 1010 / 1040 points)
   FPZone zb;
   ZeroMemory(zb);
   zb.dir = 1;
   zb.rowFrom = 101;
   zb.rowTo = 103;
   Check(FPZoneHitTest(zb, 1050, 1060, 10) == 0 && FPZoneHitTest(zb, 1040, 1060, 10) == 1 &&
         FPZoneHitTest(zb, 1010, 1060, 10) == 1 && FPZoneHitTest(zb, 1009, 1060, 10) == 2,
         "4.04 BUY zone: above -> none, low <= top -> touch, low < bottom -> filled");
   FPZone zs = zb;
   zs.dir = -1;
   Check(FPZoneHitTest(zs, 990, 1000, 10) == 0 && FPZoneHitTest(zs, 990, 1010, 10) == 1 &&
         FPZoneHitTest(zs, 990, 1040, 10) == 1 && FPZoneHitTest(zs, 990, 1041, 10) == 2,
         "4.05 SELL zone: below -> none, high >= bottom -> touch, high > top -> filled");
   //--- engine integration: A forms a BUY stack, B touches, C stays away, D fills, E closes D
   MqlTick tk[];
   long b0 = (long)D'2024.03.05 09:00:00' * 1000;
   AddQ(tk, b0 + 1000, 1000, 1002, TF_BA);     // A: split
   AddQ(tk, b0 + 2000, 1010, 1012, TF_BA);     //    BUY row 101
   AddQ(tk, b0 + 3000, 1020, 1022, TF_BA);     //    BUY row 102
   AddQ(tk, b0 + 4000, 1030, 1032, TF_BA);     //    BUY row 103
   AddQ(tk, b0 + 61000, 1045, 1047, TF_BA);    // B
   AddQ(tk, b0 + 62000, 1035, 1037, TF_BA);    //    low 1035 inside the zone -> touch
   AddQ(tk, b0 + 63000, 1050, 1052, TF_BA);
   AddQ(tk, b0 + 121000, 1060, 1062, TF_BA);   // C: above the zone
   AddQ(tk, b0 + 122000, 1065, 1067, TF_BA);
   AddQ(tk, b0 + 181000, 1005, 1007, TF_BA);   // D: low 1005 < 1010 -> filled
   AddQ(tk, b0 + 241000, 1005, 1007, TF_BA);   // E: closes D
   CFPMemTickSource src;
   src.SetTicks(tk);
   CFPEngine e;
   bool init = InitEngine(e, src, FP_SRC_QUOTE_TICKS, 10, 0, 1.0);
   Check(init && e.HistoryReady(), "4.06 engine init (historyBars=0) -> HistoryReady immediately");
   datetime tA = (datetime)(b0 / 1000);
   MqlTick one[1];
   FPZone z[];
   for(int i = 0; i < ArraySize(tk); i++)
     {
      one[0] = tk[i];
      e.FeedTicks(one, 1);
      if(i == 4)
        {
         CFPBar *A = e.ByTime(tA);
         Check(A != NULL && A.closed && A.rows == 4 && A.imbBuy[1] == 1 && A.imbBuy[2] == 3 && A.imbBuy[3] == 3 && A.imbSell[0] == 0,
               "4.07 bar A finalised with BUY tiers 1/3/3 on rows 101..103", BarStr(A));
         int n = e.Zones(z, false);
         Check(n == 1 && z[0].rowFrom == 101 && z[0].rowTo == 103 && z[0].touches == 0 && z[0].filledTime == 0 && z[0].originTime == tA,
               "4.08 A's stack became an open zone during A's finalisation (origin bar does not touch itself)");
        }
      if(i == 7)
        {
         int n = e.Zones(z, false);
         Check(n == 1 && z[0].touches == 1 && z[0].lastTouchTime == tA + 60 && z[0].filledTime == 0,
               "4.09 B entered the zone without filling it -> touches 1, lastTouchTime = B");
        }
      if(i == 9)
        {
         int n = e.Zones(z, false);
         Check(n == 1 && z[0].touches == 1 && z[0].lastTouchTime == tA + 60, "4.10 C stayed above the zone -> no touch");
        }
     }
   int nOpen = e.Zones(z, false);
   int nAll = e.Zones(z, true);
   Check(nOpen == 0 && nAll == 1 && z[0].filledTime == tA + 180 && z[0].touches == 1 && z[0].lastTouchTime == tA + 60,
         "4.11 D traded below the zone -> filledTime = D; Zones(false) hides it, Zones(true) keeps it");
   CFPBar *D = e.ByTime(tA + 180);
   Check(D != NULL && VEq(D.cumDelta, 5.0) && D.cvdValid, "4.12 session cumDelta through A..D = 3+1+2-1 = 5",
         (D != NULL) ? DoubleToString(D.cumDelta, 2) : "NULL");
}

//+------------------------------------------------------------------+
//| 5. value area on known profiles                                   |
//+------------------------------------------------------------------+
void Group5()
{
   FPProfile p;
   double v1[] = {5, 10, 20, 40, 100, 30, 25, 10, 5, 5};
   p.rowLow = 0;
   p.rows = ArraySize(v1);
   ArrayResize(p.sell, p.rows);
   ArrayResize(p.buy, p.rows);
   for(int i = 0; i < p.rows; i++)
     {
      p.sell[i] = 0.0;
      p.buy[i] = v1[i];
     }
   p.pocIdx = -1;
   bool ok = CFPAnalytics::ValueArea(p, 0.70);
   Check(ok && p.pocIdx == 4 && p.valIdx == 2 && p.vahIdx == 6 && VEq(p.total, 250.0),
         "5.01 VA 70%: POC 4, pairs below (60) then above (55) -> VAL 2, VAH 6",
         "poc " + IntegerToString(p.pocIdx) + " val " + IntegerToString(p.valIdx) + " vah " + IntegerToString(p.vahIdx));
   double v2[] = {10, 10, 50, 10, 10};
   p.rows = ArraySize(v2);
   ArrayResize(p.sell, p.rows);
   ArrayResize(p.buy, p.rows);
   for(int i = 0; i < p.rows; i++)
     {
      p.sell[i] = v2[i] * 0.5;
      p.buy[i] = v2[i] * 0.5;
     }
   p.pocIdx = -1;
   ok = CFPAnalytics::ValueArea(p, 0.70);
   Check(ok && p.pocIdx == 2 && p.vahIdx == 4 && p.valIdx == 2, "5.02 VA tie between pairs -> above wins");
   double v3[] = {10, 20, 30, 100};
   p.rows = ArraySize(v3);
   ArrayResize(p.sell, p.rows);
   ArrayResize(p.buy, p.rows);
   for(int i = 0; i < p.rows; i++)
     {
      p.sell[i] = v3[i];
      p.buy[i] = 0.0;
     }
   p.pocIdx = -1;
   ok = CFPAnalytics::ValueArea(p, 0.70);
   Check(ok && p.pocIdx == 3 && p.vahIdx == 3 && p.valIdx == 1, "5.03 VA with the POC on the top row expands downward only");
}

//+------------------------------------------------------------------+
//| 6. de-duplication of same-millisecond ticks across batches       |
//+------------------------------------------------------------------+
void Group6()
{
   MqlTick tk[];
   long b0 = (long)D'2024.03.06 10:00:00' * 1000;
   AddQ(tk, b0 + 100, 1000, 1002, TF_BA);   // t1
   AddQ(tk, b0 + 200, 1001, 1003, TF_BA);   // t2
   AddQ(tk, b0 + 200, 1002, 1004, TF_BA);   // t3 (same ms)
   AddQ(tk, b0 + 200, 1003, 1005, TF_BA);   // t4 (same ms)
   AddQ(tk, b0 + 300, 1004, 1006, TF_BA);   // t5
   CFPMemTickSource sa, sb, sc, sd;
   sa.SetTicks(tk);
   sb.SetTicks(tk);
   sc.SetTicks(tk);
   sd.SetTicks(tk);
   CFPEngine ea, eb, ec, ed;
   bool init = InitEngine(ea, sa, FP_SRC_QUOTE_TICKS, 10, 0, 1.0) && InitEngine(eb, sb, FP_SRC_QUOTE_TICKS, 10, 0, 1.0) &&
               InitEngine(ec, sc, FP_SRC_QUOTE_TICKS, 10, 0, 1.0) && InitEngine(ed, sd, FP_SRC_QUOTE_TICKS, 10, 0, 1.0);
   Check(init, "6.01 engines init");
   //--- reference: one batch
   int rb = eb.FeedTicks(tk, 5);
   Check(rb == 5 && eb.At(0) != NULL && eb.At(0).ticks == 5, "6.02 one batch of 5 ticks -> 5 counted");
   //--- batch 1 = [t1,t2,t3]; batch 2 = CopyTicks(from=t2.ms) = [t2,t3,t4,t5]
   MqlTick b1[], b2[];
   Slice(tk, 0, 3, b1);
   Slice(tk, 1, 4, b2);
   int r1 = ea.FeedTicks(b1, 3);
   int r2 = ea.FeedTicks(b2, 4);
   string why;
   Check(r1 == 3 && r2 == 2, "6.03 second batch skips the 2 already-processed ticks of the same ms",
         IntegerToString(r1) + "/" + IntegerToString(r2));
   Check(BarsEqual(ea.At(0), eb.At(0), why), "6.04 two overlapping batches == one batch", why);
   MqlTick b3[];
   Slice(tk, 4, 1, b3);
   Check(ea.FeedTicks(b3, 1) == 0 && ea.At(0).ticks == 5, "6.05 re-fetching the last ms adds nothing");
   //--- a batch made only of last-ms ticks, some new: [t1,t2] then [t2,t3] then [t2,t3,t4,t5]
   MqlTick c1[], c2[], c3[];
   Slice(tk, 0, 2, c1);
   Slice(tk, 1, 2, c2);
   Slice(tk, 1, 4, c3);
   int q1 = ed.FeedTicks(c1, 2);
   int q2 = ed.FeedTicks(c2, 2);
   int q3 = ed.FeedTicks(c3, 4);
   Check(q1 == 2 && q2 == 1 && q3 == 2 && BarsEqual(ed.At(0), eb.At(0), why), "6.06 k grows inside the same ms (2,1,2 new ticks)",
         IntegerToString(q1) + "/" + IntegerToString(q2) + "/" + IntegerToString(q3) + " " + why);
   //--- the real Update() path through the injected source, ticks becoming visible over time
   sc.ResetCounters();
   MqlTick f1[];
   Slice(tk, 0, 1, f1);
   ec.FeedTicks(f1, 1);
   sc.m_visible = 3;
   int u1 = ec.Update();
   sc.m_visible = 5;
   int u2 = ec.Update();
   int u3 = ec.Update();
   Check(u1 == 2 && u2 == 2 && u3 == 0 && BarsEqual(ec.At(0), eb.At(0), why), "6.07 Update(): CopyTicks(from=lastMsc) re-delivers same-ms ticks, de-dup keeps 5",
         IntegerToString(u1) + "/" + IntegerToString(u2) + "/" + IntegerToString(u3) + " " + why);
   Check(sc.m_sinceCalls >= 3 && !sc.m_zeroFrom, "6.08 Update() never calls CopyTicks with from = 0");
   //--- disjoint slices (no re-delivery): a NEW tick of the same ms must not be mistaken for a duplicate
   CFPMemTickSource se;
   se.SetTicks(tk);
   CFPEngine ee;
   InitEngine(ee, se, FP_SRC_QUOTE_TICKS, 10, 0, 1.0);
   MqlTick one[1];
   int fed = 0;
   for(int i = 0; i < 5; i++)
     {
      one[0] = tk[i];
      fed += ee.FeedTicks(one, 1);
     }
   Check(fed == 5 && BarsEqual(ee.At(0), eb.At(0), why), "6.09 one tick per FeedTicks (t2,t3,t4 share a ms) -> all 5 counted",
         IntegerToString(fed) + " " + why);
}

//+------------------------------------------------------------------+
//| 7. a BID-only quote tick with stale volume adds nothing           |
//|    in EXCHANGE / TRADE mode                                       |
//+------------------------------------------------------------------+
void Group7()
{
   CFPClassifier c;
   double px, sz;
   int sd;
   MqlTick t = T(1000, 1000, 1002, 1001, 5, 5.0, TICK_FLAG_BID);
   MqlTick ta = T(1000, 1000, 1002, 1001, 5, 5.0, TICK_FLAG_ASK);
   c.Setup(FP_SRC_EXCHANGE_FLAGS, FP_QP_BID);
   bool e1 = c.Classify(t, px, sz, sd);
   bool e2 = c.Classify(ta, px, sz, sd);
   c.Setup(FP_SRC_TRADE_TICKS, FP_QP_BID);
   bool t1 = c.Classify(t, px, sz, sd);
   bool t2 = c.Classify(ta, px, sz, sd);
   Check(!e1 && !e2 && !t1 && !t2, "7.01 classifier: BID/ASK-only tick with stale volume>0 and last>0 is not a print");
   for(int mode = 0; mode < 2; mode++)
     {
      ENUM_FP_SOURCE s = (mode == 0) ? FP_SRC_EXCHANGE_FLAGS : FP_SRC_TRADE_TICKS;
      uint fb = (mode == 0) ? (TICK_FLAG_LAST | TICK_FLAG_BUY) : (TICK_FLAG_LAST | TICK_FLAG_VOLUME);
      uint fs = (mode == 0) ? (TICK_FLAG_LAST | TICK_FLAG_SELL) : TICK_FLAG_LAST;
      MqlTick tk[];
      long b0 = (long)D'2024.03.07 10:00:00' * 1000;
      AddQ(tk, b0 + 100, 1000, 1002, TF_BA);                         // quote
      AddT(tk, b0 + 200, 1000, 1002, 1002, 2, 0.0, fb);              // trade 2 (BUY)
      AddT(tk, b0 + 300, 1001, 1003, 1002, 2, 2.0, TICK_FLAG_BID);   // quote, STALE volume 2 / last
      AddT(tk, b0 + 400, 1001, 1003, 1001, 3, 0.0, fs);              // trade 3 (SELL)
      AddT(tk, b0 + 500, 1001, 1004, 1001, 3, 3.0, TICK_FLAG_ASK);   // quote, STALE volume 3 / last
      CFPMemTickSource src;
      src.SetTicks(tk);
      CFPEngine e;
      InitEngine(e, src, s, 1, 0, 1.0);
      e.FeedTicks(tk, ArraySize(tk));
      CFPBar *f = e.At(0);
      double sb = 0.0, ss = 0.0;
      if(f != NULL)
         for(int i = 0; i < f.rows; i++)
           {
            sb += f.buyVol[i];
            ss += f.sellVol[i];
           }
      Check(f != NULL && f.ticks == 2 && VEq(f.volume, 5.0) && VEq(sb, 2.0) && VEq(ss, 3.0) && VEq(f.delta, -1.0),
            "7.0" + IntegerToString(mode + 2) + " engine " + ((mode == 0) ? "EXCHANGE" : "TRADE") +
            ": only the 2 trade ticks count (volume 5 = 2 buy + 3 sell)", BarStr(f));
     }
}

//+------------------------------------------------------------------+
//| 8. live-incremental vs rebuild equality across bar boundaries,   |
//|    incl. the exact 300 s seeding window (+ engine API checks)    |
//+------------------------------------------------------------------+
void Group8()
{
   datetime T8 = D'2024.03.04 10:00:00';
   long b0 = (long)T8 * 1000;
   MqlTick tk[];
   AddQ(tk, b0 + 1000, 1000, 1002, TF_BA);          // A 10:00  a1 split
   AddQ(tk, b0 + 2000, 1005, 1007, TF_BA);          //          a2 BUY  row 100
   AddQ(tk, b0 + 3000, 1012, 1014, TF_BA);          //          a3 BUY  row 101
   AddQ(tk, b0 + 4000, 1008, 1010, TF_BA);          //          a4 SELL row 100
   AddQ(tk, b0 + 5000, 1008, 1010, TICK_FLAG_ASK);  //          a5 flat -> SELL
   AddQ(tk, b0 + 6000, 1015, 1017, TF_BA);          //          a6 BUY  row 101 (mid 1016)
   AddQ(tk, b0 + 61000, 1015, 1017, TF_BA);         // B 10:01  b1 mid 1016 == seed mid -> seed side BUY
   AddQ(tk, b0 + 62000, 1020, 1022, TF_BA);         //          b2 BUY  row 102
   AddQ(tk, b0 + 62000, 1018, 1020, TF_BA);         //          b3 SELL row 101 (same ms)
   AddQ(tk, b0 + 63500, 1018, 1022, TICK_FLAG_ASK); //          b4 BUY  row 101 (mid 1020)
   AddQ(tk, b0 + 299999, 990, 992, TF_BA);          // W 10:04  1 ms OUTSIDE C's seed window
   AddQ(tk, b0 + 300000, 1000, 1002, TF_BA);        // X 10:05  exactly C-300 s: INSIDE C's seed window
   AddQ(tk, b0 + 600500, 1000, 1002, TF_BA);        // C 10:10  c1 mid == X mid; X alone is unseeded -> split
   AddQ(tk, b0 + 601000, 1003, 1005, TF_BA);        //          c2 BUY
   AddQ(tk, b0 + 660100, 1003, 1005, TF_BA);        // D 10:11  closes C
   int N = ArraySize(tk);
   datetime tA = T8, tB = T8 + 60, tW = T8 + 240, tX = T8 + 300, tC = T8 + 600, tD = T8 + 660;
   CFPMemTickSource s1, s2, s3;
   s1.SetTicks(tk);
   s2.SetTicks(tk);
   s3.SetTicks(tk);
   CFPEngine e1, e2, e3;
   bool init = InitEngine(e1, s1, FP_SRC_QUOTE_TICKS, 10, 0, 1.0) && InitEngine(e2, s2, FP_SRC_QUOTE_TICKS, 10, 0, 1.0) &&
               InitEngine(e3, s3, FP_SRC_QUOTE_TICKS, 10, 0, 1.0);
   Check(init, "8.01 engines init");
   //--- E1: one tick at a time; snapshot the live forming bar just before each boundary
   CFPBar *snap = new CFPBar();
   int boundaries = 0, equalCnt = 0;
   string firstWhy = "";
   MqlTick one[1];
   for(int i = 0; i < N; i++)
     {
      CFPBar *f = e1.At(0);
      datetime bo = (datetime)((tk[i].time_msc / 1000) - (tk[i].time_msc / 1000) % 60);
      bool boundary = (f != NULL && bo > f.time);
      datetime st = 0;
      if(boundary)
        {
         SnapBar(snap, f);
         st = f.time;
        }
      one[0] = tk[i];
      e1.FeedTicks(one, 1);
      if(boundary)
        {
         boundaries++;
         CFPBar *cb = e1.ByTime(st);
         string why;
         if(cb != NULL && cb.closed && BarsEqual(cb, snap, why))
            equalCnt++;
         else
            if(firstWhy == "")
               firstWhy = TimeToString(st, TIME_DATE | TIME_SECONDS) + ": " + why;
        }
     }
   delete snap;
   Check(boundaries == 5 && equalCnt == 5, "8.02 live-accumulated bar == bar rebuilt from Range at every boundary (5/5)",
         IntegerToString(equalCnt) + "/" + IntegerToString(boundaries) + " " + firstWhy);
   //--- E2: everything in one batch
   e2.FeedTicks(tk, N);
   //--- E3: first tick fed, then the real Update() path with ticks appearing in uneven groups
   MqlTick f1[];
   Slice(tk, 0, 1, f1);
   e3.FeedTicks(f1, 1);
   int steps[] = {2, 3, 1, 4, 2, 3, 15};
   int vis = 1, got = 0;
   for(int k = 0; k < ArraySize(steps); k++)
     {
      vis += steps[k];
      if(vis > N)
         vis = N;
      s3.m_visible = vis;
      got += e3.Update();
     }
   Check(got == N - 1, "8.03 Update() path consumed every tick exactly once", IntegerToString(got));
   datetime times[] = {tA, tB, tW, tX, tC, tD};
   bool same = true;
   string why12 = "";
   for(int k = 0; k < ArraySize(times); k++)
     {
      string w1, w2;
      if(!BarsEqual(e1.ByTime(times[k]), e2.ByTime(times[k]), w1) || !BarsEqual(e1.ByTime(times[k]), e3.ByTime(times[k]), w2))
        {
         same = false;
         if(why12 == "")
            why12 = TimeToString(times[k]) + " " + w1 + "|" + w2;
        }
     }
   Check(same, "8.04 tick-by-tick == one batch == Update() with arrival in groups (all 6 bars)", why12);
   //--- expected values computed by hand
   CFPBar *A = e1.ByTime(tA);
   Check(A != NULL && A.closed && A.rowLow == 100 && A.rows == 2 && VEq(A.sellVol[0], 2.5) && VEq(A.buyVol[0], 1.5) &&
         VEq(A.sellVol[1], 0.0) && VEq(A.buyVol[1], 2.0) && A.ticks == 6 && VEq(A.delta, 1.0) && VEq(A.deltaMax, 2.0) &&
         VEq(A.deltaMin, 0.0) && PxEq(A.open, P(1000)) && PxEq(A.high, P(1015)) && PxEq(A.low, P(1000)) && PxEq(A.close, P(1015)),
         "8.05 bar A (unseeded start) = 2.5x1.5 | 0x2, delta +1, max 2, min 0", BarStr(A));
   CFPBar *B = e1.ByTime(tB);
   Check(B != NULL && B.rowLow == 101 && B.rows == 2 && VEq(B.sellVol[0], 1.0) && VEq(B.buyVol[0], 2.0) &&
         VEq(B.buyVol[1], 1.0) && B.ticks == 4 && VEq(B.delta, 2.0),
         "8.06 bar B: first tick (mid unchanged) takes the side seeded from A's ticks (BUY 1.0, not a 50/50 split)", BarStr(B));
   CFPBar *W = e1.ByTime(tW);
   CFPBar *X = e1.ByTime(tX);
   Check(W != NULL && X != NULL && VEq(W.sellVol[0], 1.0) && W.rowLow == 99 && VEq(X.buyVol[0], 1.0) && X.rowLow == 100,
         "8.07 W is a SELL (seeded by B), X is a BUY (seeded by W, 1 ms before it)");
   CFPBar *C = e1.ByTime(tC);
   Check(C != NULL && C.rows == 1 && C.rowLow == 100 && VEq(C.sellVol[0], 0.5) && VEq(C.buyVol[0], 1.5) && VEq(C.delta, 1.0),
         "8.08 bar C: seed window [C-300 s, C) holds only X (W is 1 ms outside) and X's own BUY state is NOT carried -> c1 split",
         BarStr(C));
   //--- engine API semantics (PopClosedBar, PrevBarTime, At, Total, Prints)
   datetime q[];
   datetime pt;
   while(e1.PopClosedBar(pt))
     {
      int n = ArraySize(q);
      ArrayResize(q, n + 1);
      q[n] = pt;
     }
   datetime pt2;
   Check(ArraySize(q) == 5 && q[0] == tA && q[1] == tB && q[2] == tW && q[3] == tX && q[4] == tC && !e1.PopClosedBar(pt2),
         "9.01 PopClosedBar: each live-closed bar exactly once, FIFO, then empty", "n=" + IntegerToString(ArraySize(q)));
   Check(e1.PrevBarTime(tC) == tX && e1.PrevBarTime(tX) == tW && e1.PrevBarTime(tB) == tA && e1.PrevBarTime(tA) == 0 &&
         e1.PrevBarTime(T8 + 30) == 0 && e1.PrevBarTime(tD) == tC, "9.02 PrevBarTime walks held bars (gaps skipped; 0 for oldest / not held)");
   Check(e1.Total() == 6 && e1.At(0) != NULL && e1.At(0).time == tD && !e1.At(0).closed && e1.At(1).time == tC &&
         e1.At(5).time == tA && e1.At(6) == NULL && e1.ByTime(T8 + 120) == NULL, "9.03 At()/ByTime()/Total()");
   FPPrint pr[];
   int np = e1.Prints(pr, 3);
   Check(np == 3 && pr[0].time_msc == b0 + 660100 && pr[0].side == 1 && pr[1].side == 1 && pr[2].side == 0 &&
         PxEq(pr[2].price, P(1000)) && VEq(pr[2].size, 1.0), "9.04 Prints(): newest first (d1 BUY, c2 BUY, c1 split)");
   FPProfile prof;
   bool rp = e1.RangeProfile(1, 2, prof);
   Check(rp && prof.rows == 1 && prof.rowLow == 100 && VEq(prof.total, 3.0), "9.05 RangeProfile(shift 1..2) = C + X");
   //--- sessions & CVD reset: session start 10:05 splits the same ticks into two sessions
   CFPMemTickSource s4;
   s4.SetTicks(tk);
   CFPEngine e4;
   InitEngine(e4, s4, FP_SRC_QUOTE_TICKS, 10, 10 * 60 + 5, 1.0);
   e4.FeedTicks(tk, N);
   datetime S1 = D'2024.03.03 10:05:00', S2 = D'2024.03.04 10:05:00';
   Check(e4.SessionStart(tA) == S1 && e4.SessionStart(tW) == S1 && e4.SessionStart(tX) == S2 && e4.SessionStart(tC) == S2,
         "9.06 SessionStart = latest time <= t at the session time-of-day");
   CFPBar *A4 = e4.ByTime(tA), *B4 = e4.ByTime(tB), *W4 = e4.ByTime(tW), *X4 = e4.ByTime(tX), *C4 = e4.ByTime(tC);
   Check(A4 != NULL && B4 != NULL && W4 != NULL && X4 != NULL && C4 != NULL &&
         VEq(A4.cumDelta, 1.0) && VEq(B4.cumDelta, 3.0) && VEq(W4.cumDelta, 2.0) && VEq(X4.cumDelta, 1.0) && VEq(C4.cumDelta, 2.0) &&
         A4.cvdValid && C4.cvdValid, "9.07 cumDelta accumulates per session and resets at the session start");
   FPProfile sp;
   bool okS1 = e4.SessionProfile(S1, sp);
   Check(okS1 && sp.rowLow == 99 && sp.rows == 4 && VEq(sp.total, 11.0) && sp.pocIdx == 2 && sp.valIdx == 0 && sp.vahIdx == 2,
         "9.08 SessionProfile(S1): rows 99..102 = [1,4,5,1], POC row 101, VA rows 99..101",
         "rows " + IntegerToString(sp.rows) + " poc " + IntegerToString(sp.pocIdx) + " val " + IntegerToString(sp.valIdx) + " vah " + IntegerToString(sp.vahIdx));
   Check(PxEq(e4.SessionVWAP(S2), P(1005)), "9.09 SessionVWAP(S2) = mid of row 100 (closed bars X, C only)",
         DoubleToString(e4.SessionVWAP(S2) / g_point, 3));
   //--- unsupported timeframe
   CFPMemTickSource s5;
   CFPEngine e5;
   FPConfig cw;
   MakeCfg(cw, FP_SRC_QUOTE_TICKS, 10, 0, 1.0);
   cw.timeframe = PERIOD_W1;
   e5.SetTickSource(GetPointer(s5));
   bool w1 = e5.Init(cw);
   Check(!w1 && StringLen(e5.LastError()) > 0, "9.10 W1 timeframe -> Init() fails with a message");
}

//+------------------------------------------------------------------+
void OnStart()
{
   g_point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(g_point <= 0.0)
     {
      Print("FPTests: chart symbol has no SYMBOL_POINT - cannot run");
      return;
     }
   Print("FPTests: start (chart ", _Symbol, ", point ", DoubleToString(g_point, 10), "; all ticks are injected, no tick base access)");
   Group1();
   Group2();
   Group3();
   Group4();
   Group5();
   Group6();
   Group7();
   Group8();
   Print("FPTests: ", g_pass, " passed, ", g_fail, " failed, ", g_pass + g_fail, " total -> ", (g_fail == 0) ? "ALL PASS" : "FAILURES");
}
//+------------------------------------------------------------------+
