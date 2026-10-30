//+------------------------------------------------------------------+
//| FPEngine.mqh - OrderFlowFP footprint engine (02 §5)               |
//| One engine for indicator, Expert Advisor, script and tester.      |
//| Public API = ENGINE API CONTRACT v1 + PrevBarTime() (DECISIONS).  |
//| No chart / object / canvas / indicator calls; no per-tick Print.  |
//|                                                                    |
//| POINTER RULE: pointers returned by At()/ByTime() are valid only    |
//| until the next Update(), LoadStep(), FeedTicks() or Deinit().      |
//|                                                                    |
//| Determinism: every bar (history chunk, per-bar history, live       |
//| finalisation rebuild) is built by ONE function, BuildBarFromTicks, |
//| from the ticks of [t0-300 s, t0+period) located by time_msc in     |
//| whatever array holds them. The 300 s before t0 seed the classifier |
//| (classified, not accumulated). The live path seeds every new bar   |
//| from a ring buffer holding the same 300 s of raw ticks, so live    |
//| bars equal rebuilt bars; closed bars are always the rebuilt ones.  |
//+------------------------------------------------------------------+
#ifndef ORDERFLOWFP_FPENGINE_MQH
#define ORDERFLOWFP_FPENGINE_MQH

#include "FPAnalytics.mqh"
#include "FPClassifier.mqh"
#include "FPPresets.mqh"

#define FPE_SEED_SEC        300        // classifier seeding window before every bar open
#define FPE_FETCH_MAX       100000     // CopyTicks batch size of Update()
#define FPE_PRINTS_CAP      4096       // Prints() ring buffer (>= 2000)
#define FPE_CHUNK_MAX_SEC   604800     // warm-up chunk: at most 7 days per CopyTicksRange call
#define FPE_CHUNK_MAX_TICKS 500000     // ... and about 500k raw ticks (~30 MB of MqlTick), budgeted through bar
                                       //     tick_volume x the measured ticks-per-tick_volume ratio (first chunk assumes 5x)
#define FPE_PENDING_MAX_MS  120000     // live: pending -> nodata after 120 s since the first attempt
#define FPE_MAX_ROWS        100000     // safety cap on the row span of one bar / profile
#define FPE_MISMATCH_EVERY  50         // live-vs-rebuild summary every N live-closed bars
#define FPE_RECONNECT_GRACE_MS 5000    // EA: no tick fetch for this long after the terminal reconnects
#define FPE_RECONNECT_SYNC_MAX_MS 30000 // EA: after a reconnect, wait at most this long for SymbolIsSynchronized

enum ENUM_FPE_LOADMODE
{
   FPE_LOAD_PERBAR   = 0,   // indicator: non-blocking, one CopyTicksRange per bar, stability rules
   FPE_LOAD_BLOCKING = 1,   // Expert Advisor (live): chunked, calls may block ~45 s, time-gated retries
   FPE_LOAD_SCRIPT   = 2,   // script/service: chunked, blocking, immediate retries (max 3 attempts)
   FPE_LOAD_TESTER   = 3    // strategy tester: chunked, no wall-time waits, missing data -> nodata promptly
};

struct FPELoadInfo
{
   long  tickVolume;
   int   attempts;
   ulong firstMs;
   ulong lastMs;
   int   lastCount;
   ulong lastCountMs;
};

class CFPEngine
{
private:
   //--- configuration / symbol
   FPConfig          m_cfg;
   bool              m_inited;
   string            m_lastError;
   string            m_symbol;
   ENUM_TIMEFRAMES   m_tf;
   int               m_period;
   double            m_point;
   int               m_digits;
   int               m_bucket;
   double            m_rowSize;
   //--- volume source
   ENUM_FP_SOURCE    m_source;
   bool              m_srcDecided;
   int               m_srcAttempts;
   ulong             m_srcFirstMs;
   datetime          m_srcFirstSim;
   //--- context
   int               m_loadMode;
   bool              m_tester;
   CFPTickSource     m_defaultSrc;
   CFPTickSource    *m_src;
   CFPClassifier     m_liveCls;
   CFPClassifier     m_buildCls;
   //--- bars: chronological (oldest first); the forming bar is last when m_hasForming
   CFPBar           *m_bars[];
   int               m_count;
   bool              m_hasForming;
   bool              m_formingDirty;
   CFPBar           *m_tmpBar;
   //--- history loading
   int               m_histCount;     // history bars occupy [0, m_histCount) while loading
   FPELoadInfo       m_load[];
   int               m_pending;
   bool              m_listDone;
   int               m_listAttempts;
   ulong             m_listFirstMs;
   ulong             m_listLastMs;
   bool              m_bootstrapped;
   datetime          m_initFOpen;
   datetime          m_minBarOpen;    // ticks of earlier bars only feed the seed ring
   bool              m_chronoDone;
   ulong             m_loadStartMs;
   bool              m_wasConnected;
   bool              m_misalignWarned;
   //--- EA feed guard: CopyTicks in an EA blocks (up to ~45 s per call) while the terminal re-synchronises
   //--- its tick history, e.g. during a burst of reconnects. Never fetch while disconnected or right after a
   //--- reconnect; the ticks are not lost, the next allowed fetch reads them from m_lastMsc.
   bool              m_feedConn;
   ulong             m_feedReconnMs;
   bool              m_feedHeld;
   long              m_feedHolds;
   //--- warm-up chunk in progress
   MqlTick           m_chunk[];
   bool              m_chunkActive;
   int               m_chunkLo;
   int               m_chunkPos;
   int               m_chunkN;
   double            m_chunkRatio;    // measured CopyTicks(ALL) ticks per unit of bar tick_volume (starts pessimistic)
   //--- live stream
   long              m_lastMsc;
   int               m_lastK;
   MqlTick           m_lastTicks[];   // the m_lastK ticks already processed at m_lastMsc (de-dup check)
   MqlTick           m_fetch[];
   MqlTick           m_tmpTicks[];
   MqlTick           m_ring[];
   int               m_ringStart;
   int               m_ringEnd;
   long              m_ringCutoff;
   //--- prints ring
   FPPrint           m_prints[];
   int               m_printHead;
   int               m_printCount;
   //--- closed-bar queue (live path only)
   datetime          m_queue[];
   int               m_qHead;
   int               m_qTail;
   //--- chronological state (CVD, zones)
   datetime          m_cvdSession;
   double            m_cvd;
   bool              m_cvdOk;
   FPZone            m_zones[];
   int               m_zoneCount;
   //--- diagnostics
   int               m_liveClosed;
   int               m_liveCompared;
   int               m_mismatch;
   int               m_mismatchWin;
   int               m_rebuildFail;
   int               m_mismatchPrinted;
   long              m_staleTicks;
   long              m_rejectedTicks;

   //=================================================================
   //  small helpers
   //=================================================================
   void              ResetState(void)
     {
      m_inited = false;
      m_lastError = "";
      m_symbol = "";
      m_tf = PERIOD_CURRENT;
      m_period = 0;
      m_point = 0.0;
      m_digits = 0;
      m_bucket = 1;
      m_rowSize = 0.0;
      m_source = FP_SRC_AUTO;
      m_srcDecided = false;
      m_srcAttempts = 0;
      m_srcFirstMs = 0;
      m_srcFirstSim = 0;
      m_loadMode = FPE_LOAD_SCRIPT;
      m_tester = false;
      m_count = 0;
      m_hasForming = false;
      m_formingDirty = false;
      m_histCount = 0;
      m_pending = 0;
      m_listDone = false;
      m_listAttempts = 0;
      m_listFirstMs = 0;
      m_listLastMs = 0;
      m_bootstrapped = false;
      m_initFOpen = 0;
      m_minBarOpen = 0;
      m_chronoDone = false;
      m_loadStartMs = 0;
      m_wasConnected = true;
      m_misalignWarned = false;
      m_feedConn = true;
      m_feedReconnMs = 0;
      m_feedHeld = false;
      m_feedHolds = 0;
      m_chunkActive = false;
      m_chunkLo = 0;
      m_chunkPos = -1;
      m_chunkN = 0;
      m_chunkRatio = 5.0;
      m_lastMsc = 0;
      m_lastK = 0;
      m_ringStart = 0;
      m_ringEnd = 0;
      m_ringCutoff = 0;
      m_printHead = 0;
      m_printCount = 0;
      m_qHead = 0;
      m_qTail = 0;
      m_cvdSession = 0;
      m_cvd = 0.0;
      m_cvdOk = true;
      m_zoneCount = 0;
      m_liveClosed = 0;
      m_liveCompared = 0;
      m_mismatch = 0;
      m_mismatchWin = 0;
      m_rebuildFail = 0;
      m_mismatchPrinted = 0;
      m_staleTicks = 0;
      m_rejectedTicks = 0;
     }

   static string     SourceName(const ENUM_FP_SOURCE s)
     {
      switch(s)
        {
         case FP_SRC_EXCHANGE_FLAGS: return "EXCHANGE_FLAGS";
         case FP_SRC_TRADE_TICKS:    return "TRADE_TICKS";
         case FP_SRC_QUOTE_TICKS:    return "QUOTE_TICKS";
         default:                    return "AUTO";
        }
     }
   string            ModeName(void) const
     {
      switch(m_loadMode)
        {
         case FPE_LOAD_PERBAR:   return "indicator(per-bar, non-blocking)";
         case FPE_LOAD_BLOCKING: return "expert(chunked, blocking)";
         case FPE_LOAD_TESTER:   return "tester(chunked, no waits)";
         default:                return "script(chunked, blocking)";
        }
     }
   string            TfText(void) const
     {
      string s = EnumToString(m_tf);
      if(StringFind(s, "PERIOD_") == 0)
         s = StringSubstr(s, 7);
      return s;
     }

   datetime          BarOpenOfMsc(const long msc) const
     {
      long s = msc / 1000;
      return (datetime)(s - s % (long)m_period);
     }

   static int        LowerBoundMsc(const MqlTick &arr[], const int n, const long msc)
     {
      int lo = 0, hi = n;
      while(lo < hi)
        {
         int mid = (lo + hi) >> 1;
         if(arr[mid].time_msc < msc)
            lo = mid + 1;
         else
            hi = mid;
        }
      return lo;
     }

   //--- first index with time >= t (m_count if none)
   int               LowerIndex(const datetime t) const
     {
      int lo = 0, hi = m_count;
      while(lo < hi)
        {
         int mid = (lo + hi) >> 1;
         if(m_bars[mid].time < t)
            lo = mid + 1;
         else
            hi = mid;
        }
      return lo;
     }
   int               IndexOf(const datetime t) const
     {
      int i = LowerIndex(t);
      if(i < m_count && m_bars[i].time == t)
         return i;
      return -1;
     }

   static void       ResetBarData(CFPBar *b, const datetime t)
     {
      b.time = t;
      b.open = 0.0;
      b.high = 0.0;
      b.low = 0.0;
      b.close = 0.0;
      b.rowLow = 0;
      b.rows = 0;
      ArrayResize(b.sellVol, 0, 32);
      ArrayResize(b.buyVol, 0, 32);
      ArrayResize(b.imbSell, 0, 32);
      ArrayResize(b.imbBuy, 0, 32);
      b.volume = 0.0;
      b.delta = 0.0;
      b.deltaMax = 0.0;
      b.deltaMin = 0.0;
      b.ticks = 0;
      b.pocIdx = -1;
      b.cumDelta = 0.0;
      b.cvdValid = false;
     }

   static void       CopyBarData(CFPBar *dst, CFPBar *src)
     {
      dst.time = src.time;
      dst.open = src.open;
      dst.high = src.high;
      dst.low = src.low;
      dst.close = src.close;
      dst.rowLow = src.rowLow;
      dst.rows = src.rows;
      int n = src.rows;
      ArrayResize(dst.sellVol, n, 32);
      ArrayResize(dst.buyVol, n, 32);
      ArrayResize(dst.imbSell, n, 32);
      ArrayResize(dst.imbBuy, n, 32);
      for(int i = 0; i < n; i++)
        {
         dst.sellVol[i] = src.sellVol[i];
         dst.buyVol[i]  = src.buyVol[i];
         dst.imbSell[i] = (i < ArraySize(src.imbSell)) ? src.imbSell[i] : (char)0;
         dst.imbBuy[i]  = (i < ArraySize(src.imbBuy)) ? src.imbBuy[i] : (char)0;
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

   //--- exact equality of the accumulated footprint (live bar vs rebuilt bar)
   static bool       SameBar(CFPBar *a, CFPBar *b)
     {
      if(a.time != b.time || a.ticks != b.ticks || a.rows != b.rows || a.rowLow != b.rowLow)
         return false;
      if(a.volume != b.volume || a.delta != b.delta || a.deltaMax != b.deltaMax || a.deltaMin != b.deltaMin)
         return false;
      if(a.open != b.open || a.high != b.high || a.low != b.low || a.close != b.close)
         return false;
      for(int i = 0; i < a.rows; i++)
         if(a.sellVol[i] != b.sellVol[i] || a.buyVol[i] != b.buyVol[i])
            return false;
      return true;
     }

   //--- grow the row arrays so that 'row' is inside the bar
   bool              EnsureRow(CFPBar *b, const long row)
     {
      if(b.rows <= 0)
        {
         b.rowLow = row;
         b.rows = 1;
         ArrayResize(b.sellVol, 1, 32);
         ArrayResize(b.buyVol, 1, 32);
         ArrayResize(b.imbSell, 1, 32);
         ArrayResize(b.imbBuy, 1, 32);
         b.sellVol[0] = 0.0;
         b.buyVol[0] = 0.0;
         b.imbSell[0] = 0;
         b.imbBuy[0] = 0;
         return true;
        }
      if(row < b.rowLow)
        {
         long dl = b.rowLow - row;
         if(dl + b.rows > FPE_MAX_ROWS)
            return false;
         int d = (int)dl;
         int old = b.rows;
         int nn = old + d;
         ArrayResize(b.sellVol, nn, 32);
         ArrayResize(b.buyVol, nn, 32);
         ArrayResize(b.imbSell, nn, 32);
         ArrayResize(b.imbBuy, nn, 32);
         for(int k = old - 1; k >= 0; k--)
           {
            b.sellVol[k + d] = b.sellVol[k];
            b.buyVol[k + d]  = b.buyVol[k];
            b.imbSell[k + d] = b.imbSell[k];
            b.imbBuy[k + d]  = b.imbBuy[k];
           }
         for(int k = 0; k < d; k++)
           {
            b.sellVol[k] = 0.0;
            b.buyVol[k] = 0.0;
            b.imbSell[k] = 0;
            b.imbBuy[k] = 0;
           }
         b.rowLow = row;
         b.rows = nn;
         return true;
        }
      long top = b.rowLow + b.rows - 1;
      if(row > top)
        {
         long span = row - b.rowLow + 1;
         if(span > FPE_MAX_ROWS)
            return false;
         int old = b.rows;
         int nn = (int)span;
         ArrayResize(b.sellVol, nn, 32);
         ArrayResize(b.buyVol, nn, 32);
         ArrayResize(b.imbSell, nn, 32);
         ArrayResize(b.imbBuy, nn, 32);
         for(int k = old; k < nn; k++)
           {
            b.sellVol[k] = 0.0;
            b.buyVol[k] = 0.0;
            b.imbSell[k] = 0;
            b.imbBuy[k] = 0;
           }
         b.rows = nn;
        }
      return true;
     }

   //--- accumulate one classified print into a bar
   bool              AddPrint(CFPBar *b, const double price, const double size, const int side)
     {
      long row = PriceToRow(price);
      if(!EnsureRow(b, row))
         return false;
      int i = (int)(row - b.rowLow);
      if(side > 0)
         b.buyVol[i] += size;
      else
         if(side < 0)
            b.sellVol[i] += size;
         else
           {
            double h = size * 0.5;
            b.sellVol[i] += h;
            b.buyVol[i]  += h;
           }
      if(b.ticks == 0)
        {
         b.open = price;
         b.high = price;
         b.low = price;
        }
      else
        {
         if(price > b.high)
            b.high = price;
         if(price < b.low)
            b.low = price;
        }
      b.close = price;
      b.volume += size;
      if(side > 0)
         b.delta += size;
      else
         if(side < 0)
            b.delta -= size;
      if(b.delta > b.deltaMax)
         b.deltaMax = b.delta;
      if(b.delta < b.deltaMin)
         b.deltaMin = b.delta;
      b.ticks++;
      return true;
     }

   //+---------------------------------------------------------------+
   //| THE bar builder (history chunk, history per-bar, live rebuild).|
   //| arr[0..n) sorted by time_msc; must contain [t0-300 s, t1).     |
   //| Returns the raw number of ticks inside [t0, t1).               |
   //+---------------------------------------------------------------+
   int               BuildBarFromTicks(CFPBar *dst, const datetime t0, const MqlTick &arr[], const int n)
     {
      long seedFrom = ((long)t0 - FPE_SEED_SEC) * 1000;
      long barFrom  = (long)t0 * 1000;
      long barTo    = ((long)t0 + m_period) * 1000;
      int iS = LowerBoundMsc(arr, n, seedFrom);
      int iB = LowerBoundMsc(arr, n, barFrom);
      int iE = LowerBoundMsc(arr, n, barTo);
      ResetBarData(dst, t0);
      m_buildCls.Reset();
      double px, sz;
      int sd;
      for(int i = iS; i < iB; i++)
         m_buildCls.Classify(arr[i], px, sz, sd);
      for(int i = iB; i < iE; i++)
         if(m_buildCls.Classify(arr[i], px, sz, sd))
            if(!AddPrint(dst, px, sz, sd))
               m_rejectedTicks++;
      return iE - iB;
     }

   //--- imbalances + POC with the exact close row
   void              FinishBarAnalytics(CFPBar *b)
     {
      CFPAnalytics::ComputeImbalances(b, m_cfg);
      if(b.rows > 0)
         b.pocIdx = FPPocIndexNear(b, (double)(PriceToRow(b.close) - b.rowLow));
      else
         b.pocIdx = -1;
     }

   void              AppendBar(CFPBar *b)
     {
      if(m_count >= ArraySize(m_bars))
         ArrayResize(m_bars, m_count + 1, 512);
      m_bars[m_count] = b;
      m_count++;
     }

   //--- seed ring of raw ticks (live path)
   void              RingTrim(void)
     {
      while(m_ringStart < m_ringEnd && m_ring[m_ringStart].time_msc < m_ringCutoff)
         m_ringStart++;
      if(m_ringStart >= m_ringEnd)
        {
         m_ringStart = 0;
         m_ringEnd = 0;
        }
     }
   void              RingAppend(const MqlTick &t)
     {
      if(m_ringEnd >= ArraySize(m_ring))
        {
         if(m_ringStart > 0)
           {
            int k = 0;
            for(int i = m_ringStart; i < m_ringEnd; i++)
               m_ring[k++] = m_ring[i];
            m_ringEnd = k;
            m_ringStart = 0;
           }
         if(m_ringEnd >= ArraySize(m_ring))
            ArrayResize(m_ring, (ArraySize(m_ring) < 1024) ? 1024 : ArraySize(m_ring) * 2);
        }
      m_ring[m_ringEnd] = t;
      m_ringEnd++;
      RingTrim();
     }

   void              PushPrint(const long msc, const double price, const double size, const int side)
     {
      m_prints[m_printHead].time_msc = msc;
      m_prints[m_printHead].price = price;
      m_prints[m_printHead].size = size;
      m_prints[m_printHead].side = side;
      m_printHead = (m_printHead + 1) % FPE_PRINTS_CAP;
      if(m_printCount < FPE_PRINTS_CAP)
         m_printCount++;
     }

   void              QueuePush(const datetime t)
     {
      if(m_qTail >= ArraySize(m_queue))
        {
         if(m_qHead > 0)
           {
            int k = 0;
            for(int i = m_qHead; i < m_qTail; i++)
               m_queue[k++] = m_queue[i];
            m_qTail = k;
            m_qHead = 0;
           }
         if(m_qTail >= ArraySize(m_queue))
            ArrayResize(m_queue, (ArraySize(m_queue) < 64) ? 64 : ArraySize(m_queue) * 2);
        }
      m_queue[m_qTail] = t;
      m_qTail++;
     }

   //=================================================================
   //  live path
   //=================================================================
   void              StartForming(const datetime bo)
     {
      CFPBar *b = new CFPBar();
      ResetBarData(b, bo);
      b.state = 0;
      b.closed = false;
      AppendBar(b);
      m_hasForming = true;
      //--- re-derive the classifier state from the raw ticks of [bo-300 s, bo): never carry state across a boundary
      m_liveCls.Reset();
      long sFrom = ((long)bo - FPE_SEED_SEC) * 1000;
      long sTo   = (long)bo * 1000;
      double px, sz;
      int sd;
      for(int i = m_ringStart; i < m_ringEnd; i++)
        {
         long ms = m_ring[i].time_msc;
         if(ms < sFrom)
            continue;
         if(ms >= sTo)
            break;
         m_liveCls.Classify(m_ring[i], px, sz, sd);
        }
      //--- the next boundary is >= bo+period, so its seed window starts >= bo+period-300 s
      m_ringCutoff = ((long)bo + m_period - FPE_SEED_SEC) * 1000;
      RingTrim();
     }

   //+---------------------------------------------------------------+
   //| EA only (FPE_LOAD_BLOCKING): may we call CopyTicks* now?        |
   //| False while the terminal is disconnected, and for               |
   //| FPE_RECONNECT_GRACE_MS after it reconnects (and until the       |
   //| symbol reports synchronised), because that is when the tick     |
   //| history re-sync makes CopyTicks block OnTick for minutes.       |
   //| The indicator, scripts and the tester are not affected.         |
   //+---------------------------------------------------------------+
   bool              FetchAllowed(void)
     {
      if(m_loadMode != FPE_LOAD_BLOCKING)
         return true;
      bool c = (TerminalInfoInteger(TERMINAL_CONNECTED) != 0);
      string why = "";
      if(!c)
        {
         m_feedConn = false;
         why = "terminal disconnected";
        }
      else
        {
         if(!m_feedConn)
           {
            m_feedConn = true;
            m_feedReconnMs = GetTickCount64();
           }
         if(m_feedReconnMs > 0)
           {
            ulong since = GetTickCount64() - m_feedReconnMs;
            if(since < FPE_RECONNECT_GRACE_MS)
               why = "reconnect grace";
            else
               //--- wait for the symbol to report synchronised, but never longer than FPE_RECONNECT_SYNC_MAX_MS
               if(!SymbolIsSynchronized(m_symbol) && since < FPE_RECONNECT_SYNC_MAX_MS)
                  why = "symbol not synchronised after reconnect";
               else
                  m_feedReconnMs = 0;
           }
        }
      if(why == "")
        {
         if(m_feedHeld)
            Print("OrderFlowFP: tick feed resumed after ", m_feedHolds, " held fetch(es)");
         m_feedHeld = false;
         m_feedHolds = 0;
         return true;
        }
      if(!m_feedHeld)
         Print("OrderFlowFP: tick feed held (", why, ") - no CopyTicks until the connection is stable");
      m_feedHeld = true;
      m_feedHolds++;
      m_lastError = "feed held: " + why;
      return false;
     }

   //--- first tick of a new bar: rebuild the forming bar from a fresh CopyTicksRange, compare, lock
   void              FinalizeLive(void)
     {
      if(!m_hasForming || m_count <= 0)
         return;
      CFPBar *b = m_bars[m_count - 1];
      datetime t0 = b.time;
      long fromMsc = ((long)t0 - FPE_SEED_SEC) * 1000;
      long toMsc   = ((long)t0 + m_period) * 1000 - 1;
      ResetLastError();
      int n = m_src.Range(m_symbol, (ulong)fromMsc, (ulong)toMsc, m_tmpTicks);
      bool rebuilt = false;
      if(n > 0)
        {
         int raw = BuildBarFromTicks(m_tmpBar, t0, m_tmpTicks, n);
         if(raw > 0 || b.ticks == 0)
           {
            m_liveCompared++;
            if(!SameBar(b, m_tmpBar))
              {
               m_mismatch++;
               m_mismatchWin++;
               if(m_mismatchPrinted < 5)
                 {
                  m_mismatchPrinted++;
                  Print("OrderFlowFP: live-vs-rebuild mismatch at ", TimeToString(t0, TIME_DATE | TIME_SECONDS),
                        ": live ticks=", b.ticks, " vol=", DoubleToString(b.volume, 2), " delta=", DoubleToString(b.delta, 2),
                        " | rebuild ticks=", m_tmpBar.ticks, " vol=", DoubleToString(m_tmpBar.volume, 2),
                        " delta=", DoubleToString(m_tmpBar.delta, 2), " (rebuild kept)");
                 }
              }
            CopyBarData(b, m_tmpBar);
            rebuilt = true;
           }
        }
      if(!rebuilt)
        {
         m_rebuildFail++;
         if(m_rebuildFail <= 5)
            Print("OrderFlowFP: rebuild of ", TimeToString(t0, TIME_DATE | TIME_SECONDS), " failed (n=", n,
                  ", err=", GetLastError(), "); live-accumulated bar kept");
        }
      b.state = 0;
      FinishBarAnalytics(b);
      b.closed = true;
      m_hasForming = false;
      m_liveClosed++;
      if(m_liveClosed % FPE_MISMATCH_EVERY == 0)
        {
         Print("OrderFlowFP: live-vs-rebuild ", m_symbol, " ", TfText(), ": last ", FPE_MISMATCH_EVERY, " bars mismatches=",
               m_mismatchWin, " | total ", m_mismatch, "/", m_liveCompared, " compared, rebuild failures ", m_rebuildFail);
         m_mismatchWin = 0;
        }
      if(m_chronoDone)
         ProcessChronoBar(b);
      QueuePush(t0);
      if(m_chronoDone && m_listDone && m_pending == 0)
         TrimHistory();
     }

   void              ProcessOneTick(const MqlTick &t)
     {
      long msc = t.time_msc;
      datetime bo = BarOpenOfMsc(msc);
      if(bo < m_minBarOpen)
        {
         RingAppend(t);          // seed-only tick (before the bootstrap bar)
         return;
        }
      if(!m_hasForming)
         StartForming(bo);
      else
        {
         datetime ft = m_bars[m_count - 1].time;
         if(bo > ft)
           {
            FinalizeLive();
            StartForming(bo);
           }
         else
            if(bo < ft)
              {
               m_staleTicks++;
               return;
              }
        }
      double px, sz;
      int sd;
      if(m_liveCls.Classify(t, px, sz, sd))
        {
         if(AddPrint(m_bars[m_count - 1], px, sz, sd))
            PushPrint(msc, px, sz, sd);
         else
            m_rejectedTicks++;
        }
      RingAppend(t);
      m_formingDirty = true;
     }

   static bool       SameTick(const MqlTick &a, const MqlTick &b)
     {
      return (a.time_msc == b.time_msc && a.bid == b.bid && a.ask == b.ask && a.last == b.last &&
              a.volume == b.volume && a.volume_real == b.volume_real && a.flags == b.flags);
     }

   //--- remember the ticks already processed at m_lastMsc (in order; m_lastK of them)
   void              NoteProcessed(const MqlTick &t)
     {
      if(t.time_msc != m_lastMsc)
        {
         m_lastMsc = t.time_msc;
         m_lastK = 0;
        }
      if(m_lastK >= ArraySize(m_lastTicks))
         ArrayResize(m_lastTicks, m_lastK + 1, 16);
      m_lastTicks[m_lastK] = t;
      m_lastK++;
     }

   //+---------------------------------------------------------------+
   //| Shared by Update() (after fetching) and FeedTicks().           |
   //| De-duplication: CopyTicks(from = lastMsc) re-delivers the k    |
   //| ticks already processed at lastMsc first; skip those leading   |
   //| ticks - but only while each one is identical to the processed  |
   //| tick at the same position. On a real CopyTicks result this is  |
   //| exactly "skip the first k ticks with time_msc == lastMsc"; a   |
   //| batch that does not re-deliver them (a disjoint FeedTicks      |
   //| slice starting with a NEW tick of the same ms) loses nothing.  |
   //+---------------------------------------------------------------+
   int               ProcessTicks(const MqlTick &arr[], const int n)
     {
      int start = 0;
      if(m_lastMsc > 0 && m_lastK > 0)
        {
         while(start < n && start < m_lastK && arr[start].time_msc == m_lastMsc &&
               SameTick(arr[start], m_lastTicks[start]))
            start++;
        }
      int processed = 0;
      for(int i = start; i < n; i++)
        {
         if(arr[i].time_msc < m_lastMsc)
           {
            m_staleTicks++;
            continue;
           }
         ProcessOneTick(arr[i]);
         NoteProcessed(arr[i]);
         processed++;
        }
      return processed;
     }

   //--- forming-bar extras after a batch (O(rows) once per call, not per tick)
   void              AfterTicks(void)
     {
      if(!m_hasForming || !m_formingDirty || m_count <= 0)
         return;
      CFPBar *f = m_bars[m_count - 1];
      FinishBarAnalytics(f);
      if(m_chronoDone)
        {
         if(SessionStart(f.time) == m_cvdSession)
           {
            f.cumDelta = m_cvd + f.delta;
            f.cvdValid = m_cvdOk;
           }
         else
           {
            f.cumDelta = f.delta;
            f.cvdValid = true;
           }
        }
      else
        {
         f.cumDelta = 0.0;
         f.cvdValid = false;
        }
      m_formingDirty = false;
     }

   //=================================================================
   //  source decision, bootstrap, bar list
   //=================================================================
   void              TryDecideSource(void)
     {
      if(m_srcDecided)
         return;
      if(m_cfg.source != FP_SRC_AUTO)
        {
         m_source = m_cfg.source;
         m_srcDecided = true;
         m_liveCls.Setup(m_source, m_cfg.quotePrice);
         m_buildCls.Setup(m_source, m_cfg.quotePrice);
         Print("OrderFlowFP: source=", SourceName(m_source), " (explicit)");
         return;
        }
      MqlTick s[];
      ArraySetAsSeries(s, false);
      ResetLastError();
      int n = m_src.Since(m_symbol, 0, 5000, s);
      m_srcAttempts++;
      if(m_srcAttempts == 1)
        {
         m_srcFirstMs = GetTickCount64();
         m_srcFirstSim = TimeCurrent();
        }
      //--- tester without pre-test ticks: the first samples hold only a handful of ticks;
      //    wait for >= 1000 ticks or 30 s of simulated time before freezing the decision
      if(n > 0 && n < 1000 && m_loadMode == FPE_LOAD_TESTER && (long)TimeCurrent() - (long)m_srcFirstSim < 30)
         return;
      if(n > 0)
        {
         int trades = 0, flagged = 0, lastPos = 0;
         for(int i = 0; i < n; i++)
           {
            if(!CFPClassifier::IsTradeTick(s[i]))
               continue;
            trades++;
            if((s[i].flags & (TICK_FLAG_BUY | TICK_FLAG_SELL)) != 0)
               flagged++;
            if(s[i].last > 0.0)
               lastPos++;
           }
         bool enough = ((double)trades >= 0.20 * (double)n);
         if(enough && (double)flagged >= 0.80 * (double)trades)
            m_source = FP_SRC_EXCHANGE_FLAGS;
         else
            if(enough && (double)lastPos >= 0.95 * (double)trades)
               m_source = FP_SRC_TRADE_TICKS;
            else
               m_source = FP_SRC_QUOTE_TICKS;
         m_srcDecided = true;
         m_liveCls.Setup(m_source, m_cfg.quotePrice);
         m_buildCls.Setup(m_source, m_cfg.quotePrice);
         Print("OrderFlowFP: source=", SourceName(m_source), " (sample ", n, ", trades ",
               DoubleToString(100.0 * (double)trades / (double)n, 0), "%)",
               (m_source == FP_SRC_QUOTE_TICKS) ? " - QUOTE mode: volumes are tick counts = relative activity" : "");
         return;
        }
      //--- empty sample: tick base not synchronised yet
      bool giveUp = false;
      if(m_loadMode == FPE_LOAD_TESTER)
         giveUp = ((long)TimeCurrent() - (long)m_srcFirstSim >= 30);
      else
         if(m_loadMode == FPE_LOAD_SCRIPT)
            giveUp = (m_srcAttempts >= 3);
         else
            giveUp = (GetTickCount64() - m_srcFirstMs >= 30000);
      if(giveUp)
        {
         m_source = FP_SRC_QUOTE_TICKS;
         m_srcDecided = true;
         m_liveCls.Setup(m_source, m_cfg.quotePrice);
         m_buildCls.Setup(m_source, m_cfg.quotePrice);
         Print("OrderFlowFP: WARNING source sample empty after ", m_srcAttempts,
               " attempts - falling back to QUOTE_TICKS (volumes are tick counts)");
        }
     }

   //--- forming-bar bootstrap: stream from fOpen-300 s; ticks before fOpen only seed the ring
   void              Bootstrap(void)
     {
      if(m_bootstrapped)
         return;
      m_bootstrapped = true;
      if(m_cfg.historyBars <= 0)
         return;
      datetime f = iTime(m_symbol, m_tf, 0);
      if(f <= 0)
        {
         MqlTick tk;
         if(SymbolInfoTick(m_symbol, tk) && tk.time > 0)
            f = BarOpenOfMsc((long)tk.time * 1000);
         else
            f = BarOpenOfMsc((long)TimeCurrent() * 1000);
        }
      m_initFOpen  = f;
      m_minBarOpen = f;
      m_lastMsc    = ((long)f - FPE_SEED_SEC) * 1000;
      m_lastK      = 0;
      m_ringCutoff = m_lastMsc;
      Update();
     }

   bool              ListFailed(const string why)
     {
      m_lastError = why;
      bool giveUp;
      if(m_loadMode == FPE_LOAD_TESTER || m_loadMode == FPE_LOAD_SCRIPT)
         giveUp = (m_listAttempts >= 3);
      else
         giveUp = (GetTickCount64() - m_listFirstMs >= FPE_PENDING_MAX_MS);
      if(giveUp)
        {
         m_listDone = true;
         Print("OrderFlowFP: WARNING bar list unavailable (", why, ") - continuing without history");
        }
      return false;
     }

   //--- bar list: N closed bars before fOpen, extended back to SessionStart(oldest) + the previous session with bars
   bool              FetchBarList(void)
     {
      ulong now = GetTickCount64();
      if(m_listFirstMs == 0)
         m_listFirstMs = now;
      if(m_listAttempts > 0 && (m_loadMode == FPE_LOAD_BLOCKING || m_loadMode == FPE_LOAD_PERBAR) &&
         now - m_listLastMs < 1000)
         return false;
      m_listAttempts++;
      m_listLastMs = now;
      datetime fOpen = m_initFOpen;
      datetime before = (datetime)((long)fOpen - 1);
      datetime t[];
      ArraySetAsSeries(t, false);
      ResetLastError();
      int n = CopyTime(m_symbol, m_tf, before, m_cfg.historyBars, t);
      if(n < 0)
         return ListFailed("CopyTime failed (" + IntegerToString(GetLastError()) + ")");
      if(n == 0)
        {
         m_listDone = true;
         Print("OrderFlowFP: no closed bars before ", TimeToString(fOpen), " - no history");
         return true;
        }
      datetime oldest = t[0];
      for(int i = 1; i < n; i++)
         if(t[i] < oldest)
            oldest = t[i];
      datetime s0 = SessionStart(oldest);
      datetime cover = s0;
      datetime tp[];
      ArraySetAsSeries(tp, false);
      if(CopyTime(m_symbol, m_tf, (datetime)((long)s0 - 1), 1, tp) == 1 && tp[0] < s0)
         cover = SessionStart(tp[0]);
      MqlRates r[];
      ArraySetAsSeries(r, false);
      ResetLastError();
      int nr = CopyRates(m_symbol, m_tf, cover, before, r);
      if(nr <= 0)
         return ListFailed("CopyRates failed (" + IntegerToString(GetLastError()) + ")");
      //--- valid, strictly ascending times in [cover, fOpen)
      datetime tv[];
      long     vol[];
      ArrayResize(tv, nr);
      ArrayResize(vol, nr);
      int nh = 0;
      int misaligned = 0;
      for(int i = 0; i < nr; i++)
        {
         datetime bt = r[i].time;
         if(bt < cover || bt >= fOpen)
            continue;
         if(nh > 0 && bt <= tv[nh - 1])
            continue;
         if(((long)bt % (long)m_period) != 0)
            misaligned++;
         tv[nh] = bt;
         vol[nh] = r[i].tick_volume;
         nh++;
        }
      if(misaligned > 0 && !m_misalignWarned)
        {
         m_misalignWarned = true;
         Print("OrderFlowFP: WARNING ", misaligned, " bar times are not multiples of PeriodSeconds - ticks are assigned by t - t % period");
        }
      CFPBar *nb[];
      ArrayResize(nb, nh + m_count);
      for(int i = 0; i < nh; i++)
        {
         CFPBar *b = new CFPBar();
         ResetBarData(b, tv[i]);
         b.state = 1;
         b.closed = false;
         nb[i] = b;
        }
      for(int j = 0; j < m_count; j++)
         nb[nh + j] = m_bars[j];
      ArrayResize(m_bars, nh + m_count, 512);
      for(int i = 0; i < nh + m_count; i++)
         m_bars[i] = nb[i];
      m_count += nh;
      m_histCount = nh;
      ArrayResize(m_load, nh);
      for(int i = 0; i < nh; i++)
        {
         m_load[i].tickVolume = vol[i];
         m_load[i].attempts = 0;
         m_load[i].firstMs = 0;
         m_load[i].lastMs = 0;
         m_load[i].lastCount = 0;
         m_load[i].lastCountMs = 0;
        }
      m_pending = nh;
      m_listDone = true;
      return true;
     }

   //=================================================================
   //  history loading
   //=================================================================
   bool              Due(const int i) const
     {
      if(m_load[i].lastMs == 0)
         return true;
      ulong now = GetTickCount64();
      if(m_loadMode == FPE_LOAD_BLOCKING)
         return (now - m_load[i].lastMs >= 2000);
      if(m_loadMode == FPE_LOAD_PERBAR)
         return (now - m_load[i].lastMs >= 1000);
      return true;
     }
   bool              GiveUp(const int i, const bool isError) const
     {
      if(m_loadMode == FPE_LOAD_TESTER)
         return isError ? (m_load[i].attempts >= 3) : true;    // past ticks cannot arrive later in the tester
      if(m_loadMode == FPE_LOAD_SCRIPT)
         return (m_load[i].attempts >= 3);
      return (GetTickCount64() - m_load[i].firstMs >= FPE_PENDING_MAX_MS);
     }
   void              MarkAttempt(const int i)
     {
      ulong now = GetTickCount64();
      m_load[i].attempts++;
      if(m_load[i].firstMs == 0)
         m_load[i].firstMs = now;
      m_load[i].lastMs = now;
     }
   void              SetLoaded(const int i)
     {
      CFPBar *b = m_bars[i];
      b.state = 0;
      FinishBarAnalytics(b);
      b.closed = true;
      m_pending--;
     }
   void              SetNoData(const int i)
     {
      CFPBar *b = m_bars[i];
      ResetBarData(b, b.time);
      b.state = 2;
      b.closed = true;
      m_pending--;
     }
   void              BarMiss(const int i, const bool isError)
     {
      if(GiveUp(i, isError))
         SetNoData(i);
     }

   void              EndChunk(void)
     {
      m_chunkActive = false;
      m_chunkN = 0;
      m_chunkPos = -1;
      ArrayFree(m_chunk);
     }

   //--- one CopyTicksRange over a run of pending bars (<= 7 days, <= ~500k ticks by tick volume)
   bool              StartChunk(void)
     {
      int hi = -1;
      for(int i = m_histCount - 1; i >= 0; i--)
         if(m_bars[i].state == 1 && Due(i))
           {
            hi = i;
            break;
           }
      if(hi < 0)
         return false;
      int lo = hi;
      long sumTv = (m_load[hi].tickVolume > 0) ? m_load[hi].tickVolume : 0;
      long tEnd = (long)m_bars[hi].time + m_period;
      //--- tick budget in tick_volume units: ~FPE_CHUNK_MAX_TICKS raw ticks per call (memory bound)
      long budgetTv = (long)((double)FPE_CHUNK_MAX_TICKS / m_chunkRatio);
      if(budgetTv < 1)
         budgetTv = 1;
      while(lo - 1 >= 0)
        {
         int k = lo - 1;
         if(m_bars[k].state != 1 || !Due(k))
            break;
         if(tEnd - (long)m_bars[k].time > FPE_CHUNK_MAX_SEC)
            break;
         long tv = (m_load[k].tickVolume > 0) ? m_load[k].tickVolume : 0;
         if(sumTv + tv > budgetTv)
            break;
         sumTv += tv;
         lo = k;
        }
      for(int k = lo; k <= hi; k++)
         MarkAttempt(k);
      long fromMsc = ((long)m_bars[lo].time - FPE_SEED_SEC) * 1000;
      long toMsc   = tEnd * 1000 - 1;
      ResetLastError();
      int n = m_src.Range(m_symbol, (ulong)fromMsc, (ulong)toMsc, m_chunk);
      if(n < 0)
        {
         int err = GetLastError();
         m_lastError = "CopyTicksRange failed (" + IntegerToString(err) +
                       ((err == ERR_HISTORY_TIMEOUT) ? ", history timeout" : "") + ")";
         for(int k = hi; k >= lo; k--)
            BarMiss(k, true);
         ArrayFree(m_chunk);
         return true;
        }
      m_chunkActive = true;
      m_chunkLo = lo;
      m_chunkPos = hi;
      m_chunkN = n;
      if(sumTv > 0 && n > 0)
        {
         m_chunkRatio = (double)n / (double)sumTv;
         if(m_chunkRatio < 1.0)
            m_chunkRatio = 1.0;
        }
      return true;
     }

   void              ProcessChunkBar(const int i)
     {
      CFPBar *b = m_bars[i];
      if(b.state != 1)
         return;
      int raw = BuildBarFromTicks(b, b.time, m_chunk, m_chunkN);
      if(raw > 0 || m_load[i].tickVolume <= 0)
         SetLoaded(i);
      else
        {
         ResetBarData(b, b.time);
         BarMiss(i, false);      // short result: tick volume > 0 but no ticks
        }
     }

   void              LoadChunked(const ulong deadline)
     {
      for(int guard = 0; guard < 100000; guard++)
        {
         if(!m_chunkActive)
           {
            if(!StartChunk())
               return;
            if(GetTickCount64() >= deadline)
               return;
            if(!m_chunkActive)
               continue;
           }
         while(m_chunkPos >= m_chunkLo)
           {
            int i = m_chunkPos;
            m_chunkPos--;
            ProcessChunkBar(i);
            if(GetTickCount64() >= deadline)
              {
               if(m_chunkPos < m_chunkLo)
                  EndChunk();
               return;
              }
           }
         EndChunk();
        }
     }

   //--- indicator: a tick at/after t1 exists (the tick base covers bar i completely)
   bool              TickAfter(const int i, const datetime t1)
     {
      if(i + 1 < m_count)
        {
         CFPBar *nb = m_bars[i + 1];
         if(nb.state == 0 && nb.ticks > 0)
            return true;
        }
      MqlTick tk[];
      ArraySetAsSeries(tk, false);
      long fromMsc = (long)t1 * 1000;
      int n = m_src.Since(m_symbol, (ulong)fromMsc, 1, tk);
      return (n > 0 && tk[0].time_msc >= fromMsc);
     }

   //--- indicator: one non-blocking CopyTicksRange per bar with the 02 §5.5 acceptance rules
   void              LoadOneBar(const int i)
     {
      CFPBar *b = m_bars[i];
      MarkAttempt(i);
      datetime t0 = b.time;
      datetime t1 = (datetime)((long)t0 + m_period);
      long fromMsc = ((long)t0 - FPE_SEED_SEC) * 1000;
      long toMsc   = (long)t1 * 1000 - 1;
      ResetLastError();
      int n = m_src.Range(m_symbol, (ulong)fromMsc, (ulong)toMsc, m_tmpTicks);
      if(n < 0)
        {
         BarMiss(i, true);
         return;
        }
      int iB = LowerBoundMsc(m_tmpTicks, n, (long)t0 * 1000);
      int iE = LowerBoundMsc(m_tmpTicks, n, (long)t1 * 1000);
      int raw = iE - iB;
      if(raw <= 0)
        {
         if(m_load[i].tickVolume <= 0)
           {
            BuildBarFromTicks(b, t0, m_tmpTicks, n);
            SetLoaded(i);
           }
         else
            BarMiss(i, false);
         return;
        }
      ulong now = GetTickCount64();
      bool expired = (now - m_load[i].firstMs >= FPE_PENDING_MAX_MS);
      bool stable = (m_load[i].lastCount == raw && now - m_load[i].lastCountMs >= 1000);
      if(m_load[i].lastCount != raw)
        {
         m_load[i].lastCount = raw;
         m_load[i].lastCountMs = now;
        }
      if(!stable && !expired)
         return;
      if(!expired && i != m_histCount - 1 && !TickAfter(i, t1))
         return;
      BuildBarFromTicks(b, t0, m_tmpTicks, n);
      SetLoaded(i);
     }

   void              LoadPerBar(const ulong deadline)
     {
      for(int i = m_histCount - 1; i >= 0; i--)
        {
         if(m_bars[i].state != 1 || !Due(i))
            continue;
         LoadOneBar(i);
         if(GetTickCount64() >= deadline)
            return;
        }
     }

   //--- indicator only: retry nodata bars after a reconnect
   void              CheckReconnect(void)
     {
      bool c = (TerminalInfoInteger(TERMINAL_CONNECTED) != 0);
      bool rising = (c && !m_wasConnected);
      m_wasConnected = c;
      if(!rising)
         return;
      int last = m_hasForming ? m_count - 1 : m_count;
      int cnt = 0;
      for(int i = 0; i < last; i++)
         if(m_bars[i].state == 2)
            cnt++;
      if(cnt == 0)
         return;
      m_histCount = last;
      ArrayResize(m_load, last);
      for(int i = 0; i < last; i++)
        {
         m_load[i].tickVolume = 1;
         m_load[i].attempts = 0;
         m_load[i].firstMs = 0;
         m_load[i].lastMs = 0;
         m_load[i].lastCount = 0;
         m_load[i].lastCountMs = 0;
         if(m_bars[i].state == 2)
           {
            m_bars[i].state = 1;
            m_bars[i].closed = false;
            m_pending++;
           }
        }
      m_chronoDone = false;
      Print("OrderFlowFP: reconnected - retrying ", cnt, " nodata bars");
     }

   //=================================================================
   //  chronological pass (CVD, zone lifecycle) and trimming
   //=================================================================
   void              ProcessChronoBar(CFPBar *b)
     {
      datetime s = SessionStart(b.time);
      if(s != m_cvdSession)
        {
         m_cvdSession = s;
         m_cvd = 0.0;
         m_cvdOk = true;
        }
      if(b.state == 2)
        {
         m_cvdOk = false;
         b.cumDelta = m_cvd;
         b.cvdValid = false;
         return;
        }
      m_cvd += b.delta;
      b.cumDelta = m_cvd;
      b.cvdValid = m_cvdOk;
      if(b.rows <= 0)
         return;
      //--- lifecycle of the existing zones (origin bars strictly before b)
      long lowPts  = (long)MathRound(b.low / m_point);
      long highPts = (long)MathRound(b.high / m_point);
      for(int z = 0; z < m_zoneCount; z++)
        {
         if(m_zones[z].filledTime != 0 || m_zones[z].originTime >= b.time)
            continue;
         int hit = FPZoneHitTest(m_zones[z], lowPts, highPts, m_bucket);
         if(hit == 2)
            m_zones[z].filledTime = b.time;
         else
            if(hit == 1)
              {
               m_zones[z].touches++;
               m_zones[z].lastTouchTime = b.time;
              }
        }
      //--- the bar's own stacks become new zones
      FPZone found[];
      int nf = CFPAnalytics::FindStacks(b, m_cfg, m_rowSize, found);
      for(int k = 0; k < nf; k++)
        {
         ArrayResize(m_zones, m_zoneCount + 1, 64);
         m_zones[m_zoneCount] = found[k];
         m_zoneCount++;
        }
     }

   void              ChronoPass(void)
     {
      m_zoneCount = 0;
      ArrayResize(m_zones, 0, 64);
      m_cvdSession = 0;
      m_cvd = 0.0;
      m_cvdOk = true;
      int last = m_hasForming ? m_count - 1 : m_count;
      for(int i = 0; i < last; i++)
         ProcessChronoBar(m_bars[i]);
      m_chronoDone = true;
     }

   //--- keep the newest historyBars closed bars + their session + the previous session; trim whole sessions
   void              TrimHistory(void)
     {
      int closedCount = m_hasForming ? m_count - 1 : m_count;
      int keep = (m_cfg.historyBars > 0) ? m_cfg.historyBars : 300;
      if(closedCount <= keep)
         return;
      int oIdx = closedCount - keep;
      datetime s0 = SessionStart(m_bars[oIdx].time);
      int firstInS0 = LowerIndex(s0);
      datetime cover = s0;
      if(firstInS0 > 0)
         cover = SessionStart(m_bars[firstInS0 - 1].time);
      int cut = LowerIndex(cover);
      if(cut <= 0)
         return;
      for(int i = 0; i < cut; i++)
         if(CheckPointer(m_bars[i]) == POINTER_DYNAMIC)
            delete m_bars[i];
      int k = 0;
      for(int i = cut; i < m_count; i++)
         m_bars[k++] = m_bars[i];
      m_count = k;
      ArrayResize(m_bars, m_count, 512);
      int zk = 0;
      for(int z = 0; z < m_zoneCount; z++)
         if(m_zones[z].originTime >= cover)
            m_zones[zk++] = m_zones[z];
      m_zoneCount = zk;
      ArrayResize(m_zones, m_zoneCount, 64);
     }

   void              ReportReady(void)
     {
      int last = m_hasForming ? m_count - 1 : m_count;
      int ok = 0, nod = 0;
      for(int i = 0; i < last; i++)
        {
         if(m_bars[i].state == 2)
            nod++;
         else
            ok++;
        }
      int total = ok + nod;
      Print("OrderFlowFP: history ready ", m_symbol, " ", TfText(), ": ", total, " closed bars (ok ", ok, ", nodata ", nod,
            (total > 0) ? (" = " + DoubleToString(100.0 * (double)nod / (double)total, 1) + "%") : "",
            "), zones ", m_zoneCount, ", source=", SourceName(m_source), ", ",
            (GetTickCount64() - m_loadStartMs), " ms");
      if(total > 0 && nod * 2 > total)
         Print("OrderFlowFP: WARNING most history bars have no tick data",
               m_tester ? " (tester: no real ticks before the test start? warm up on the first live bars)" : "");
     }

   //--- aggregate bars [iFrom, iTo] (ok bars with rows; closedOnly skips the forming bar)
   bool              ProfileFromIndices(const int iFrom, const int iTo, const bool closedOnly, FPProfile &out)
     {
      out.rowLow = 0;
      out.rows = 0;
      ArrayResize(out.sell, 0);
      ArrayResize(out.buy, 0);
      out.total = 0.0;
      out.pocIdx = -1;
      out.vahIdx = -1;
      out.valIdx = -1;
      long lo = LONG_MAX, hi = LONG_MIN;
      int newest = -1;
      for(int i = iFrom; i <= iTo; i++)
        {
         if(i < 0 || i >= m_count)
            continue;
         CFPBar *b = m_bars[i];
         if(b.state != 0 || b.rows <= 0 || (closedOnly && !b.closed))
            continue;
         if(b.rowLow < lo)
            lo = b.rowLow;
         if(b.rowLow + b.rows - 1 > hi)
            hi = b.rowLow + b.rows - 1;
         newest = i;
        }
      if(newest < 0 || hi - lo + 1 > FPE_MAX_ROWS)
         return false;
      int rows = (int)(hi - lo + 1);
      out.rowLow = lo;
      out.rows = rows;
      ArrayResize(out.sell, rows);
      ArrayResize(out.buy, rows);
      ArrayInitialize(out.sell, 0.0);
      ArrayInitialize(out.buy, 0.0);
      for(int i = iFrom; i <= iTo; i++)
        {
         if(i < 0 || i >= m_count)
            continue;
         CFPBar *b = m_bars[i];
         if(b.state != 0 || b.rows <= 0 || (closedOnly && !b.closed))
            continue;
         int off = (int)(b.rowLow - lo);
         for(int k = 0; k < b.rows; k++)
           {
            out.sell[off + k] += b.sellVol[k];
            out.buy[off + k]  += b.buyVol[k];
           }
        }
      double closeIdx = (double)(PriceToRow(m_bars[newest].close) - lo);
      out.pocIdx = FPPocIndexArrays(out.sell, out.buy, rows, closeIdx);
      return CFPAnalytics::ValueArea(out, m_cfg.valueAreaPct);
     }

   int               ShiftToIndex(const int shift) const
     {
      return m_hasForming ? (m_count - 1 - shift) : (m_count - shift);
     }

public:
                     CFPEngine(void)
     {
      m_tmpBar = new CFPBar();
      m_src = GetPointer(m_defaultSrc);
      ArraySetAsSeries(m_fetch, false);
      ArraySetAsSeries(m_lastTicks, false);
      ArraySetAsSeries(m_tmpTicks, false);
      ArraySetAsSeries(m_chunk, false);
      ArraySetAsSeries(m_ring, false);
      ResetState();
     }
                    ~CFPEngine(void)
     {
      Deinit();
      if(CheckPointer(m_tmpBar) == POINTER_DYNAMIC)
         delete m_tmpBar;
      m_tmpBar = NULL;
     }

   //+---------------------------------------------------------------+
   //| Init: config, symbol properties, bucket, source decision when  |
   //| possible, forming-bar bootstrap. Heavy loading -> LoadStep().  |
   //| historyBars == 0: live-only/test mode (no history list, no     |
   //| bootstrap; the stream starts at the first tick given to        |
   //| FeedTicks(), or at TimeCurrent()-300 s on the first Update()). |
   //+---------------------------------------------------------------+
   bool              Init(const FPConfig &cfg)
     {
      Deinit();
      m_cfg = cfg;
      m_symbol = (cfg.symbol == "") ? _Symbol : cfg.symbol;
      m_cfg.symbol = m_symbol;
      m_tf = (cfg.timeframe == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)Period() : cfg.timeframe;
      m_cfg.timeframe = m_tf;
      m_period = PeriodSeconds(m_tf);
      if(m_period <= 0 || m_period > 86400)
        {
         m_lastError = "timeframe " + EnumToString(m_tf) + " not supported (M1..D1 only; W1/MN are rejected)";
         Print("OrderFlowFP: Init failed: ", m_lastError);
         return false;
        }
      SymbolSelect(m_symbol, true);
      m_point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      if(m_point <= 0.0)
        {
         m_lastError = "unknown symbol '" + m_symbol + "' (no SYMBOL_POINT)";
         Print("OrderFlowFP: Init failed: ", m_lastError);
         return false;
        }
      m_digits = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);
      if(cfg.bucketPoints < 0)
        {
         m_lastError = "bucketPoints must be >= 0 (0 = auto)";
         Print("OrderFlowFP: Init failed: ", m_lastError);
         return false;
        }
      if(cfg.sessionStartMin < 0 || cfg.sessionStartMin > 1439)
        {
         m_lastError = "sessionStartMin must be 0..1439";
         Print("OrderFlowFP: Init failed: ", m_lastError);
         return false;
        }
      if(!(cfg.valueAreaPct > 0.0 && cfg.valueAreaPct <= 1.0))
        {
         m_lastError = "valueAreaPct must be in (0, 1] (pass 0.70, not 70)";
         Print("OrderFlowFP: Init failed: ", m_lastError);
         return false;
        }
      if(!(cfg.imbRatio1 > 0.0 && cfg.imbRatio2 > 0.0 && cfg.imbRatio3 > 0.0))
        {
         m_lastError = "imbRatio1..3 must be > 0";
         Print("OrderFlowFP: Init failed: ", m_lastError);
         return false;
        }
      if(m_cfg.historyBars < 0)
         m_cfg.historyBars = 0;
      if(m_cfg.stackMinRows < 1)
         m_cfg.stackMinRows = 1;
      if(m_cfg.imbMinVolume < 0.0)
         m_cfg.imbMinVolume = 0.0;
      string bucketLog;
      if(cfg.bucketPoints > 0)
        {
         m_bucket = cfg.bucketPoints;
         bucketLog = "bucket=" + IntegerToString(m_bucket) + " pts (" + DoubleToString((double)m_bucket * m_point, m_digits) + ") [explicit]";
        }
      else
         m_bucket = CFPPresets::AutoBucket(m_symbol, m_tf, bucketLog);
      if(m_bucket < 1)
         m_bucket = 1;
      m_cfg.bucketPoints = m_bucket;
      m_rowSize = (double)m_bucket * m_point;
      //--- runtime context
      m_tester = (MQLInfoInteger(MQL_TESTER) != 0 || MQLInfoInteger(MQL_OPTIMIZATION) != 0);
      ENUM_PROGRAM_TYPE pt = (ENUM_PROGRAM_TYPE)MQLInfoInteger(MQL_PROGRAM_TYPE);
      if(m_tester)
         m_loadMode = FPE_LOAD_TESTER;
      else
         if(pt == PROGRAM_INDICATOR)
            m_loadMode = FPE_LOAD_PERBAR;
         else
            if(pt == PROGRAM_EXPERT)
               m_loadMode = FPE_LOAD_BLOCKING;
            else
               m_loadMode = FPE_LOAD_SCRIPT;
      ArrayResize(m_prints, FPE_PRINTS_CAP);
      m_inited = true;
      m_loadStartMs = GetTickCount64();
      m_wasConnected = (TerminalInfoInteger(TERMINAL_CONNECTED) != 0);
      Print("OrderFlowFP: init ", m_symbol, " ", TfText(), " | ", bucketLog, " | history=", m_cfg.historyBars,
            " | session start ", m_cfg.sessionStartMin, " min | ", ModeName());
      if(m_cfg.historyBars <= 0)
        {
         m_listDone = true;
         m_bootstrapped = true;
         m_chronoDone = true;
        }
      TryDecideSource();
      if(m_srcDecided && !m_bootstrapped)
         Bootstrap();
      return true;
     }

   void              Deinit(void)
     {
      for(int i = 0; i < m_count; i++)
         if(CheckPointer(m_bars[i]) == POINTER_DYNAMIC)
            delete m_bars[i];
      ArrayFree(m_bars);
      ArrayFree(m_load);
      ArrayFree(m_chunk);
      ArrayFree(m_fetch);
      ArrayFree(m_lastTicks);
      ArrayFree(m_tmpTicks);
      ArrayFree(m_ring);
      ArrayFree(m_prints);
      ArrayFree(m_queue);
      ArrayFree(m_zones);
      ResetState();
     }

   void              SetTickSource(CFPTickSource *src)
     {
      if(src == NULL)
         m_src = GetPointer(m_defaultSrc);
      else
         m_src = src;
     }

   //--- one time-budgeted loading step; always processes live ticks (Update) before returning
   bool              LoadStep(const uint budgetMs)
     {
      if(!m_inited)
         return false;
      ulong deadline = GetTickCount64() + (ulong)budgetMs;
      if(!FetchAllowed())
         return HistoryReady();
      if(!m_srcDecided)
        {
         TryDecideSource();
         if(!m_srcDecided)
            return false;
        }
      if(!m_bootstrapped)
         Bootstrap();
      if(!m_listDone)
         FetchBarList();
      if(m_listDone && m_pending > 0)
        {
         if(m_loadMode == FPE_LOAD_PERBAR)
            LoadPerBar(deadline);
         else
            LoadChunked(deadline);
        }
      if(m_loadMode == FPE_LOAD_PERBAR && m_chronoDone)
         CheckReconnect();
      if(m_listDone && m_pending == 0 && !m_chronoDone)
        {
         if(m_chunkActive)
            EndChunk();
         ChronoPass();
         m_histCount = 0;
         ArrayFree(m_load);
         ReportReady();
        }
      Update();
      return HistoryReady();
     }

   bool              HistoryReady(void) const
     {
      return (m_inited && m_srcDecided && m_listDone && m_pending == 0 && m_chronoDone);
     }

   //--- EA only: true while tick fetches are held by the feed guard (disconnected / just reconnected)
   bool              FeedHeld(void) const { return m_feedHeld; }

   //--- pull new ticks: CopyTicks(from = lastMsc) in batches of 100000, de-duplicated
   int               Update(void)
     {
      if(!m_inited)
        {
         m_lastError = "not initialised";
         return -1;
        }
      if(!m_srcDecided)
         return 0;
      if(m_lastMsc <= 0)
        {
         if(m_cfg.historyBars > 0)
            return 0;
         datetime now = TimeCurrent();
         if(now <= 0)
            return 0;
         m_lastMsc = ((long)now - FPE_SEED_SEC) * 1000;   // live-only mode start point (never from = 0)
         m_lastK = 0;
         m_ringCutoff = m_lastMsc;
        }
      if(!FetchAllowed())
         return 0;
      int total = 0;
      for(int guard = 0; guard < 64; guard++)
        {
         ResetLastError();
         int n = m_src.Since(m_symbol, (ulong)m_lastMsc, (uint)FPE_FETCH_MAX, m_fetch);
         if(n < 0)
           {
            m_lastError = "CopyTicks failed (" + IntegerToString(GetLastError()) + ")";
            if(total == 0)
              {
               AfterTicks();
               return -1;
              }
            break;
           }
         if(n == 0)
            break;
         long pm = m_lastMsc;
         int pk = m_lastK;
         total += ProcessTicks(m_fetch, n);
         if(n < FPE_FETCH_MAX)
            break;
         if(m_lastMsc == pm && m_lastK == pk)
            break;
        }
      AfterTicks();
      return total;
     }

   //--- test hook: same code path as Update() after fetching (de-dup included)
   int               FeedTicks(const MqlTick &ticks[], const int count)
     {
      if(!m_inited || !m_srcDecided)
        {
         m_lastError = "FeedTicks: engine not initialised or source not decided";
         return -1;
        }
      int n = count;
      if(n > ArraySize(ticks))
         n = ArraySize(ticks);
      if(n <= 0)
         return 0;
      int p = ProcessTicks(ticks, n);
      AfterTicks();
      return p;
     }

   bool              PopClosedBar(datetime &barTime)
     {
      if(m_qHead >= m_qTail)
         return false;
      barTime = m_queue[m_qHead];
      m_qHead++;
      if(m_qHead >= m_qTail)
        {
         m_qHead = 0;
         m_qTail = 0;
        }
      return true;
     }

   int               Total(void) const { return m_count; }

   CFPBar           *At(const int shift)
     {
      if(shift < 0)
         return NULL;
      if(!m_hasForming && shift == 0)
         return NULL;
      int idx = ShiftToIndex(shift);
      if(idx < 0 || idx >= m_count)
         return NULL;
      return m_bars[idx];
     }

   CFPBar           *ByTime(const datetime barTime)
     {
      int i = IndexOf(barTime);
      if(i < 0)
         return NULL;
      return m_bars[i];
     }

   //--- engine addition: open time of the held bar immediately before barTime (0 = none / barTime not held)
   datetime          PrevBarTime(const datetime barTime) const
     {
      int i = IndexOf(barTime);
      if(i <= 0)
         return 0;
      return m_bars[i - 1].time;
     }

   ENUM_FP_SOURCE    ActiveSource(void) const { return m_srcDecided ? m_source : FP_SRC_AUTO; }
   double            RowSize(void) const { return m_rowSize; }

   long              PriceToRow(const double price) const
     {
      if(m_point <= 0.0 || m_bucket <= 0)
         return 0;
      long pts = (long)MathRound(price / m_point);
      return FPFloorDiv(pts, (long)m_bucket);
     }
   double            RowToPrice(const long row) const { return (double)row * m_rowSize; }

   datetime          SessionStart(const datetime t) const
     {
      long tt = (long)t;
      long day = tt - tt % 86400;
      long s = day + (long)m_cfg.sessionStartMin * 60;
      if(s > tt)
         s -= 86400;
      return (datetime)s;
     }

   //--- CLOSED ok bars of the session (forming bar excluded); false until HistoryReady()
   bool              SessionProfile(const datetime sessionStart, FPProfile &out)
     {
      if(!HistoryReady())
        {
         out.rows = 0;
         out.total = 0.0;
         out.pocIdx = -1;
         out.vahIdx = -1;
         out.valIdx = -1;
         return false;
        }
      datetime s = SessionStart(sessionStart);
      int iFrom = LowerIndex(s);
      int iTo = LowerIndex((datetime)((long)s + 86400)) - 1;
      return ProfileFromIndices(iFrom, iTo, true, out);
     }

   //--- bars with shift in [min, max] of the two shifts (forming bar included when shift 0 is in range)
   bool              RangeProfile(const int fromShift, const int toShift, FPProfile &out)
     {
      int a = (fromShift < toShift) ? fromShift : toShift;
      int b = (fromShift < toShift) ? toShift : fromShift;
      if(a < 0)
         a = 0;
      int idxNew = ShiftToIndex(a);
      int idxOld = ShiftToIndex(b);
      if(idxNew > m_count - 1)
         idxNew = m_count - 1;
      if(idxOld < 0)
         idxOld = 0;
      if(b < 0 || idxOld > idxNew)
        {
         out.rows = 0;
         out.total = 0.0;
         out.pocIdx = -1;
         out.vahIdx = -1;
         out.valIdx = -1;
         return false;
        }
      return ProfileFromIndices(idxOld, idxNew, false, out);
     }

   //--- sum(rowMid x rowVol) / sum(rowVol) over the CLOSED ok bars of the session; 0 until HistoryReady()
   double            SessionVWAP(const datetime sessionStart)
     {
      if(!HistoryReady())
         return 0.0;
      datetime s = SessionStart(sessionStart);
      int iFrom = LowerIndex(s);
      int iTo = LowerIndex((datetime)((long)s + 86400)) - 1;
      double pv = 0.0, v = 0.0;
      double half = m_rowSize * 0.5;
      for(int i = iFrom; i <= iTo; i++)
        {
         if(i < 0 || i >= m_count)
            continue;
         CFPBar *b = m_bars[i];
         if(b.state != 0 || !b.closed || b.rows <= 0)
            continue;
         for(int k = 0; k < b.rows; k++)
           {
            double rv = b.sellVol[k] + b.buyVol[k];
            if(rv <= 0.0)
               continue;
            pv += (RowToPrice(b.rowLow + k) + half) * rv;
            v  += rv;
           }
        }
      return (v > 0.0) ? pv / v : 0.0;
     }

   //--- zones in creation order (origin time ascending); open only unless includeFilled
   int               Zones(FPZone &out[], const bool includeFilled = false) const
     {
      ArrayResize(out, 0);
      int c = 0;
      for(int z = 0; z < m_zoneCount; z++)
        {
         if(!includeFilled && m_zones[z].filledTime != 0)
            continue;
         ArrayResize(out, c + 1, 16);
         out[c] = m_zones[z];
         c++;
        }
      return c;
     }

   //--- newest first
   int               Prints(FPPrint &out[], const int maxCount) const
     {
      int n = (maxCount < m_printCount) ? maxCount : m_printCount;
      if(n < 0)
         n = 0;
      ArrayResize(out, n);
      for(int k = 0; k < n; k++)
        {
         int idx = (m_printHead - 1 - k + FPE_PRINTS_CAP) % FPE_PRINTS_CAP;
         out[k] = m_prints[idx];
        }
      return n;
     }

   string            LastError(void) const { return m_lastError; }
};

#endif // ORDERFLOWFP_FPENGINE_MQH
//+------------------------------------------------------------------+
