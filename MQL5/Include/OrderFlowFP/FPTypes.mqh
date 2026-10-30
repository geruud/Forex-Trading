//+------------------------------------------------------------------+
//| FPTypes.mqh - OrderFlowFP engine: ALL shared types                |
//| ENGINE API CONTRACT v1 (02 §5.7 = 03 §3). Do not change names.    |
//| Engine file: no chart, object, canvas, indicator calls in here.   |
//+------------------------------------------------------------------+
#ifndef ORDERFLOWFP_FPTYPES_MQH
#define ORDERFLOWFP_FPTYPES_MQH

enum ENUM_FP_SOURCE      { FP_SRC_AUTO=0, FP_SRC_EXCHANGE_FLAGS=1, FP_SRC_TRADE_TICKS=2, FP_SRC_QUOTE_TICKS=3 };
enum ENUM_FP_QUOTE_PRICE { FP_QP_BID=0, FP_QP_MID=1 };

struct FPConfig
{
   string              symbol;
   ENUM_TIMEFRAMES     timeframe;        // M1..D1 supported; W1/MN -> Init() fails with a clear message
   int                 bucketPoints;     // row height in points (>=1); 0 = auto (FPPresets)
   ENUM_FP_SOURCE      source;           // default FP_SRC_AUTO
   ENUM_FP_QUOTE_PRICE quotePrice;       // default FP_QP_BID (MT5 charts are bid-based)
   int                 historyBars;      // closed bars to build, default 300
   int                 sessionStartMin;  // minutes after 00:00 SERVER time, default 0
   double              imbRatio1;        // 2.0
   double              imbRatio2;        // 3.0
   double              imbRatio3;        // 4.0
   double              imbMinVolume;     // 10 (dominant side, volume units of the active source)
   int                 stackMinRows;     // 3
   double              valueAreaPct;     // 0.70
};

struct FPZone
{
   int      dir;            // +1 = BUY stack (support), -1 = SELL stack (resistance)
   datetime originTime;     // open time of the bar that formed the stack
   long     rowFrom;        // absolute row index of the lowest stacked row
   long     rowTo;          // absolute row index of the highest stacked row
   double   priceLow;       // bottom edge of rowFrom
   double   priceHigh;      // top edge of rowTo
   int      rowsCount;      // rowTo - rowFrom + 1
   double   volume;         // dominant-side volume inside the stack
   datetime filledTime;     // 0 while open; else open time of the bar that filled it
   int      touches;        // closed bars that entered the zone without filling it
   datetime lastTouchTime;  // open time of the most recent touching bar (0 = none)
};

struct FPProfile
{
   long     rowLow;         // absolute row index of element 0
   int      rows;
   double   sell[];         // per-row sell volume
   double   buy[];          // per-row buy volume
   double   total;
   int      pocIdx, vahIdx, valIdx;
};

struct FPPrint              // one classified print (ring buffer in the engine)
{
   long     time_msc;
   double   price;          // row-price basis of the active source
   double   size;
   int      side;           // +1 buy, -1 sell, 0 = split 50/50
};

//+------------------------------------------------------------------+
//| Tick source. The default implementation wraps CopyTicks /         |
//| CopyTicksRange (COPY_TICKS_ALL); tests inject in-memory ticks.     |
//| Since(): ticks with time_msc >= fromMsc, at most count            |
//|          (fromMsc == 0 -> the LAST count ticks; used only by the  |
//|          AUTO source sample, never by Update()).                  |
//| Range(): ticks with fromMsc <= time_msc <= toMsc (both inclusive) |
//| Both return the number of ticks copied, or -1 (GetLastError()).   |
//+------------------------------------------------------------------+
class CFPTickSource         // default implementation wraps CopyTicks / CopyTicksRange; tests inject in-memory ticks
{
public:
   virtual          ~CFPTickSource(void) {}
   virtual int Since(const string symbol, const ulong fromMsc, const uint count, MqlTick &out[])
   {
      return CopyTicks(symbol, out, COPY_TICKS_ALL, fromMsc, count);
   }
   virtual int Range(const string symbol, const ulong fromMsc, const ulong toMsc, MqlTick &out[])
   {
      return CopyTicksRange(symbol, out, COPY_TICKS_ALL, fromMsc, toMsc);
   }
};

//+------------------------------------------------------------------+
//| One footprint bar. Row index i = 0 is the lowest row.             |
//| The constructor only zero-initialises (not an API addition).      |
//+------------------------------------------------------------------+
class CFPBar
{
public:
   datetime time;               // bar open time (server)
   double   open, high, low, close;   // row-price basis of counted ticks only
   long     rowLow;             // absolute row index of element 0
   int      rows;
   double   sellVol[];          // [rows]  left number  (volume that hit the bid)
   double   buyVol[];           // [rows]  right number (volume that lifted the ask)
   char     imbSell[];          // [rows]  0..3 tier of SELL imbalance at this row; write with (char)tier
   char     imbBuy[];           // [rows]  0..3 tier of BUY imbalance at this row; write with (char)tier
   double   volume;             // sum of sell+buy
   double   delta;              // buy - sell
   double   deltaMax, deltaMin; // running intrabar extremes of delta
   int      ticks;              // ticks counted into this bar
   int      pocIdx;             // index of the bar POC row
   double   cumDelta;           // session cumulative delta at bar end
   bool     cvdValid;           // false if a 'nodata' bar precedes it in the same session
   bool     closed;             // true = finalised and locked
   int      state;              // 0 ok, 1 pending (loading), 2 nodata
   double   RowVolume(const int i) const { return sellVol[i] + buyVol[i]; }
   double   RowPrice(const int i, const double rowSize) const { return (double)(rowLow + i) * rowSize; }

                     CFPBar(void) : time(0), open(0.0), high(0.0), low(0.0), close(0.0), rowLow(0), rows(0),
                                    volume(0.0), delta(0.0), deltaMax(0.0), deltaMin(0.0), ticks(0), pocIdx(-1),
                                    cumDelta(0.0), cvdValid(false), closed(false), state(0)
     {
      ArraySetAsSeries(sellVol, false);
      ArraySetAsSeries(buyVol, false);
      ArraySetAsSeries(imbSell, false);
      ArraySetAsSeries(imbBuy, false);
     }
};

//+------------------------------------------------------------------+
//| Engine helper: floor division (correct for negative numerators).  |
//| Row of a price: FPFloorDiv((long)MathRound(price/point), bucket). |
//+------------------------------------------------------------------+
long FPFloorDiv(const long a, const long b)
{
   if(b == 0)
      return 0;
   long q = a / b;
   if((a % b) != 0 && ((a < 0) != (b < 0)))
      q--;
   return q;
}

#endif // ORDERFLOWFP_FPTYPES_MQH
//+------------------------------------------------------------------+
