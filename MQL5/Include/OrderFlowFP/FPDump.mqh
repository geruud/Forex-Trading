//+------------------------------------------------------------------+
//| FPDump.mqh - CFPDumpWriter: the ONE writer of the dump CSV format |
//| (02 §11), used by Scripts\OrderFlowFP\FPDumpBars.mq5 and the EA.  |
//| Files: MQL5\Files\OrderFlowFP\dump_<sym>_<tf>_bars.csv / _rows.csv|
//|        (FILE_COMMON when commonFolder). Overwritten on Open().    |
//| Format (fixed, locale-free, UTF-8, CRLF line ends):               |
//|  bars: time,open,high,low,close,volume,delta,cumDelta,pocPrice,   |
//|        ticks,buyImbCount,sellImbCount,state,cvdValid              |
//|  rows: time,rowPrice,sell,buy,imbSell,imbBuy  (one line per row,  |
//|        lowest row first, every row of the bar's range)            |
//|  time = yyyy.mm.dd hh:mi:ss; prices with SYMBOL_DIGITS decimals;  |
//|  volumes/deltas with up to 4 decimals, trailing zeros removed;    |
//|  pocPrice/rowPrice = bottom edge of the row; pocPrice=0 if no rows|
//+------------------------------------------------------------------+
#ifndef ORDERFLOWFP_FPDUMP_MQH
#define ORDERFLOWFP_FPDUMP_MQH

#include "FPEngine.mqh"

class CFPDumpWriter
{
private:
   int               m_hBars;
   int               m_hRows;
   int               m_digits;

   //--- "M5", "H1", ... (same text as FPTfName in FPSignalTypes.mqh)
   static string     TfLabel(const ENUM_TIMEFRAMES tf)
     {
      ENUM_TIMEFRAMES t = (tf == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)Period() : tf;
      string s = EnumToString(t);
      if(StringFind(s, "PERIOD_") == 0)
         s = StringSubstr(s, 7);
      return s;
     }
   //--- characters that are illegal in Windows file names -> '_'
   static string     SafeName(const string s)
     {
      string r = s;
      StringReplace(r, "\\", "_");
      StringReplace(r, "/", "_");
      StringReplace(r, ":", "_");
      StringReplace(r, "*", "_");
      StringReplace(r, "?", "_");
      StringReplace(r, "\"", "_");
      StringReplace(r, "<", "_");
      StringReplace(r, ">", "_");
      StringReplace(r, "|", "_");
      return r;
     }
   //--- fixed 4 decimals, trailing zeros and '.' removed, never "-0"
   static string     Num(const double v)
     {
      string s = DoubleToString(v, 4);
      if(StringFind(s, ".") >= 0)
        {
         int n = StringLen(s);
         while(n > 0 && StringGetCharacter(s, n - 1) == '0')
            n--;
         if(n > 0 && StringGetCharacter(s, n - 1) == '.')
            n--;
         s = StringSubstr(s, 0, n);
        }
      if(s == "-0" || s == "")
         s = "0";
      return s;
     }
   string            Px(const double p) const { return DoubleToString(p, m_digits); }

   static bool       WriteLine(const int h, const string s)
     {
      uchar buf[];
      int n = StringToCharArray(s + "\r\n", buf, 0, WHOLE_ARRAY, CP_UTF8);
      if(n <= 1)
         return false;
      return (FileWriteArray(h, buf, 0, n - 1) == (uint)(n - 1));
     }
   static int        OpenFile(const string name, const bool common)
     {
      int flags = FILE_WRITE | FILE_BIN | FILE_SHARE_READ;
      if(common)
         flags |= FILE_COMMON;
      return FileOpen(name, flags);
     }

public:
                     CFPDumpWriter(void) : m_hBars(INVALID_HANDLE), m_hRows(INVALID_HANDLE), m_digits(5) {}
                    ~CFPDumpWriter(void) { Close(); }

   bool              Open(const string symbol, const ENUM_TIMEFRAMES tf, const bool commonFolder)
     {
      Close();
      string sym = (symbol == "") ? _Symbol : symbol;
      m_digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      string base = "OrderFlowFP\\dump_" + SafeName(sym) + "_" + TfLabel(tf);
      m_hBars = OpenFile(base + "_bars.csv", commonFolder);
      m_hRows = OpenFile(base + "_rows.csv", commonFolder);
      if(m_hBars == INVALID_HANDLE || m_hRows == INVALID_HANDLE)
        {
         Print("OrderFlowFP: dump open failed for ", base, " (err ", GetLastError(), ")");
         Close();
         return false;
        }
      bool ok = WriteLine(m_hBars, "time,open,high,low,close,volume,delta,cumDelta,pocPrice,ticks,buyImbCount,sellImbCount,state,cvdValid");
      ok = WriteLine(m_hRows, "time,rowPrice,sell,buy,imbSell,imbBuy") && ok;
      FileFlush(m_hBars);
      FileFlush(m_hRows);
      return ok;
     }

   //--- one CLOSED bar: one line in _bars, one line per row in _rows
   bool              Write(CFPBar *bar, CFPEngine *engine)
     {
      if(m_hBars == INVALID_HANDLE || m_hRows == INVALID_HANDLE)
         return false;
      if(bar == NULL || engine == NULL || !bar.closed)
         return false;
      string t = TimeToString(bar.time, TIME_DATE | TIME_SECONDS);
      int buyImb = 0, sellImb = 0;
      for(int i = 0; i < bar.rows; i++)
        {
         if(i < ArraySize(bar.imbBuy) && bar.imbBuy[i] > 0)
            buyImb++;
         if(i < ArraySize(bar.imbSell) && bar.imbSell[i] > 0)
            sellImb++;
        }
      double poc = (bar.rows > 0 && bar.pocIdx >= 0 && bar.pocIdx < bar.rows) ? engine.RowToPrice(bar.rowLow + bar.pocIdx) : 0.0;
      string line = t + "," + Px(bar.open) + "," + Px(bar.high) + "," + Px(bar.low) + "," + Px(bar.close) + "," +
                    Num(bar.volume) + "," + Num(bar.delta) + "," + Num(bar.cumDelta) + "," + Px(poc) + "," +
                    IntegerToString(bar.ticks) + "," + IntegerToString(buyImb) + "," + IntegerToString(sellImb) + "," +
                    IntegerToString(bar.state) + "," + (bar.cvdValid ? "1" : "0");
      bool ok = WriteLine(m_hBars, line);
      for(int i = 0; i < bar.rows; i++)
        {
         int is = (i < ArraySize(bar.imbSell)) ? (int)bar.imbSell[i] : 0;
         int ib = (i < ArraySize(bar.imbBuy)) ? (int)bar.imbBuy[i] : 0;
         string r = t + "," + Px(engine.RowToPrice(bar.rowLow + i)) + "," + Num(bar.sellVol[i]) + "," + Num(bar.buyVol[i]) + "," +
                    IntegerToString(is) + "," + IntegerToString(ib);
         ok = WriteLine(m_hRows, r) && ok;
        }
      FileFlush(m_hBars);
      FileFlush(m_hRows);
      return ok;
     }

   void              Close(void)
     {
      if(m_hBars != INVALID_HANDLE)
         FileClose(m_hBars);
      if(m_hRows != INVALID_HANDLE)
         FileClose(m_hRows);
      m_hBars = INVALID_HANDLE;
      m_hRows = INVALID_HANDLE;
     }
};

#endif // ORDERFLOWFP_FPDUMP_MQH
//+------------------------------------------------------------------+
