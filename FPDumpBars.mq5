//+------------------------------------------------------------------+
//| FPDumpBars.mq5 - builds bars with the OrderFlowFP engine and      |
//| writes MQL5\Files\OrderFlowFP\dump_<sym>_<tf>_bars.csv / _rows.csv|
//| through CFPDumpWriter (the same writer the EA uses, InpDumpBars). |
//| For exact EA equality use the same Engine inputs as the EA        |
//| (InpSource, InpBucketPoints, InpSessionStart, InpQuotePrice,      |
//|  imbalance/stack params) and InpBars = the EA's InpWarmupBars.    |
//| Blocking is fine in a script: CopyTicksRange waits for the data.  |
//+------------------------------------------------------------------+
#property script_show_inputs
#property version   "1.00"

#include <OrderFlowFP\FPEngine.mqh>
#include <OrderFlowFP\FPDump.mqh>

input group "Dump"
input string              InpSymbol       = "";              // symbol ("" = chart symbol)
input ENUM_TIMEFRAMES     InpTF           = PERIOD_CURRENT;  // tf (M1..D1)
input int                 InpBars         = 300;             // bars (closed bars to build; whole sessions are added)
input bool                InpCommonFiles  = false;           // write to the common Files folder
input int                 InpTimeoutSec   = 600;             // give up loading after N seconds
input group "Engine (same names and defaults as the EA)"
input ENUM_FP_SOURCE      InpSource       = FP_SRC_AUTO;     // source
input int                 InpBucketPoints = 0;               // bucketPoints (0 = auto)
input ENUM_FP_QUOTE_PRICE InpQuotePrice   = FP_QP_BID;
input string              InpSessionStart = "00:00";         // session start, server time HH:MM
input double              InpImbRatio1    = 2.0;
input double              InpImbRatio2    = 3.0;
input double              InpImbRatio3    = 4.0;
input double              InpImbMinVolume = 10.0;
input int                 InpStackMinRows = 3;

//--- "HH:MM" -> minutes after 00:00; -1 on error (local helper; FPParseHHMM lives in FPSignalTypes.mqh)
int DumpParseHHMM(const string hhmm)
{
   string s = hhmm;
   StringTrimLeft(s);
   StringTrimRight(s);
   string parts[];
   if(StringSplit(s, ':', parts) != 2)
      return -1;
   int h = (int)StringToInteger(parts[0]);
   int m = (int)StringToInteger(parts[1]);
   if(h < 0 || h > 23 || m < 0 || m > 59)
      return -1;
   return h * 60 + m;
}

void OnStart()
{
   string sym = (InpSymbol == "") ? _Symbol : InpSymbol;
   ENUM_TIMEFRAMES tf = (InpTF == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)Period() : InpTF;
   int sess = DumpParseHHMM(InpSessionStart);
   if(sess < 0)
     {
      Print("FPDumpBars: invalid InpSessionStart '", InpSessionStart, "' (expected HH:MM)");
      return;
     }
   if(InpBars < 1)
     {
      Print("FPDumpBars: InpBars must be >= 1");
      return;
     }
   FPConfig cfg;
   cfg.symbol = sym;
   cfg.timeframe = tf;
   cfg.bucketPoints = InpBucketPoints;
   cfg.source = InpSource;
   cfg.quotePrice = InpQuotePrice;
   cfg.historyBars = InpBars;
   cfg.sessionStartMin = sess;
   cfg.imbRatio1 = InpImbRatio1;
   cfg.imbRatio2 = InpImbRatio2;
   cfg.imbRatio3 = InpImbRatio3;
   cfg.imbMinVolume = InpImbMinVolume;
   cfg.stackMinRows = InpStackMinRows;
   cfg.valueAreaPct = 0.70;

   CFPEngine engine;
   if(!engine.Init(cfg))
     {
      Print("FPDumpBars: engine Init failed: ", engine.LastError());
      return;
     }
   ulong t0 = GetTickCount64();
   bool ready = false;
   while(!IsStopped())
     {
      ready = engine.LoadStep(1000);
      if(ready)
         break;
      if(GetTickCount64() - t0 > (ulong)InpTimeoutSec * 1000)
         break;
     }
   if(!ready)
     {
      Print("FPDumpBars: history not ready after ", (GetTickCount64() - t0) / 1000, " s (", engine.LastError(), ") - nothing written");
      engine.Deinit();
      return;
     }

   CFPDumpWriter writer;
   if(!writer.Open(sym, tf, InpCommonFiles))
     {
      engine.Deinit();
      return;
     }
   //--- every held CLOSED bar, oldest first
   int written = 0, nodata = 0, sumMismatch = 0;
   long sumTicks = 0, sumTickVol = 0;
   int total = engine.Total();
   for(int s = total; s >= 1; s--)
     {
      CFPBar *b = engine.At(s);
      if(b == NULL || !b.closed)
         continue;
      if(!writer.Write(b, GetPointer(engine)))
        {
         Print("FPDumpBars: write failed at ", TimeToString(b.time));
         break;
        }
      written++;
      if(b.state == 2)
        {
         nodata++;
         continue;
        }
      //--- diagnostics: in QUOTE mode sum(sell+buy) must equal the counted ticks
      if(engine.ActiveSource() == FP_SRC_QUOTE_TICKS && MathAbs(b.volume - (double)b.ticks) > 1e-9)
         sumMismatch++;
      int sh = iBarShift(sym, tf, b.time, true);
      if(sh >= 0)
        {
         sumTicks += b.ticks;
         sumTickVol += iVolume(sym, tf, sh);
        }
     }
   writer.Close();
   string tfs = EnumToString(tf);
   if(StringFind(tfs, "PERIOD_") == 0)
      tfs = StringSubstr(tfs, 7);
   Print("FPDumpBars: wrote ", written, " closed bars (nodata ", nodata, ") of ", sym, " ", tfs, " to ",
         InpCommonFiles ? "<Common>\\Files" : "MQL5\\Files", "\\OrderFlowFP\\dump_", sym, "_", tfs, "_bars.csv / _rows.csv",
         " | source=", EnumToString(engine.ActiveSource()), " row=", DoubleToString(engine.RowSize(), (int)SymbolInfoInteger(sym, SYMBOL_DIGITS)),
         " | ", (GetTickCount64() - t0), " ms");
   if(engine.ActiveSource() == FP_SRC_QUOTE_TICKS)
      Print("FPDumpBars: QUOTE check sum(sell+buy) == ticks: ", (sumMismatch == 0) ? "OK on every bar" : (IntegerToString(sumMismatch) + " bars differ"));
   if(sumTickVol > 0)
      Print("FPDumpBars: diagnostic counted ticks / iVolume = ", DoubleToString((double)sumTicks / (double)sumTickVol, 3));
   engine.Deinit();
}
//+------------------------------------------------------------------+
