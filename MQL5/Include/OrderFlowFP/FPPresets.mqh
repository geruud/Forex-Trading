//+------------------------------------------------------------------+
//| FPPresets.mqh - bucket presets per symbol + auto bucket (02 §5.4) |
//| Presets are PRICE STEPS (points x point of the reference feed),   |
//| futures roots are TICK multiples. ATR(14) comes from CopyRates    |
//| (no indicator handles in the engine).                             |
//+------------------------------------------------------------------+
#ifndef ORDERFLOWFP_FPPRESETS_MQH
#define ORDERFLOWFP_FPPRESETS_MQH

#include "FPAnalytics.mqh"

class CFPPresets
{
private:
   static bool       IsMonthCode(const ushort c)
     {
      return (c == 'F' || c == 'G' || c == 'H' || c == 'J' || c == 'K' || c == 'M' ||
              c == 'N' || c == 'Q' || c == 'U' || c == 'V' || c == 'X' || c == 'Z');
     }
   static bool       IsDigitChar(const ushort c) { return (c >= '0' && c <= '9'); }
   static bool       IsAlphaChar(const ushort c) { return (c >= 'A' && c <= 'Z'); }

   //--- CFD/FX key: cleaned == key, or key + a short alphabetic broker suffix (m, PRO, ECN, CASH, MICRO ...)
   static bool       MatchCfd(const string cleaned, const string key)
     {
      int lk = StringLen(key);
      int lc = StringLen(cleaned);
      if(lc < lk || StringSubstr(cleaned, 0, lk) != key)
         return false;
      if(lc == lk)
         return true;
      int rem = lc - lk;
      if(rem > 6)
         return false;
      return IsAlphaChar(StringGetCharacter(cleaned, lk));
     }
   //--- futures root: cleaned == root, or root + month code + 1..4 digits (ESZ4, GCEZ24, MNQH2025)
   static bool       MatchFut(const string cleaned, const string root)
     {
      int lr = StringLen(root);
      int lc = StringLen(cleaned);
      if(lc < lr || StringSubstr(cleaned, 0, lr) != root)
         return false;
      if(lc == lr)
         return true;
      int rem = lc - lr;
      if(rem < 2 || rem > 5)
         return false;
      if(!IsMonthCode(StringGetCharacter(cleaned, lr)))
         return false;
      for(int i = lr + 1; i < lc; i++)
         if(!IsDigitChar(StringGetCharacter(cleaned, i)))
            return false;
      return true;
     }

public:
   //--- upper case, only A-Z and 0-9 (drops '.', '-', '#', '@', '_', '+', '!' ...)
   static string     CleanSymbol(const string symbol)
     {
      string u = symbol;
      StringToUpper(u);
      string r = "";
      int n = StringLen(u);
      for(int i = 0; i < n; i++)
        {
         ushort c = StringGetCharacter(u, i);
         if(IsAlphaChar(c) || IsDigitChar(c))
            r += ShortToString(c);
        }
      return r;
     }

   //+---------------------------------------------------------------+
   //| Pure preset lookup on a CLEANED symbol.                        |
   //| Returns 1 = price step (value in price units), 2 = tick count  |
   //| (value = ticks per row), 0 = no preset.                        |
   //+---------------------------------------------------------------+
   static int        MatchPreset(const string cleaned, double &value, string &key)
     {
      value = 0.0;
      key = "";
      //--- futures roots first (longer roots before shorter ones)
      string futRoots[] = {"GCE", "GC", "MES", "ES", "MNQ", "ENQ", "NQ"};
      double futTicks[] = { 5.0,  5.0,  1.0,  1.0,  4.0,   4.0,   4.0};
      for(int i = 0; i < ArraySize(futRoots); i++)
         if(MatchFut(cleaned, futRoots[i]))
           {
            value = futTicks[i];
            key = futRoots[i];
            return 2;
           }
      //--- CFD / FX: step = preset points x point of the reference feed
      string keys[]  = {"XAUUSD", "GOLD", "BTCUSD", "US30", "DJ30", "NAS100", "USTEC", "DE40", "GER40",
                        "SP500", "US500", "UK100", "EURUSD", "GBPUSD", "USDCAD", "USDCHF", "AUDUSD",
                        "EURGBP", "AUDCAD", "GBPCAD", "USDJPY", "EURJPY", "GBPJPY", "AUDJPY", "CADJPY"};
      double steps[] = { 0.40,     0.40,   10.0,     10.0,   10.0,   10.0,     10.0,    10.0,   10.0,
                         3.0,     3.0,     3.0,     0.00005,  0.00005,  0.00005,  0.00005,  0.00006,
                         0.00003,  0.00005,  0.00005,  0.010,    0.010,    0.010,    0.005,    0.005};
      for(int i = 0; i < ArraySize(keys); i++)
         if(MatchCfd(cleaned, keys[i]))
           {
            value = steps[i];
            key = keys[i];
            return 1;
           }
      return 0;
     }

   //--- nearest value of {1,2,3,5,10,20,25,50,100,200,250,500,1000,...} on a log scale; minimum 1
   static int        NiceRound(const double x)
     {
      if(!(x > 1.0))
         return 1;
      int    best = 1;
      double bestErr = MathAbs(MathLog(x));
      double cand[] = {2.0, 3.0, 5.0};
      for(int i = 0; i < ArraySize(cand); i++)
        {
         double e = MathAbs(MathLog(x / cand[i]));
         if(e < bestErr)
           {
            bestErr = e;
            best = (int)cand[i];
           }
        }
      double mant[] = {1.0, 2.0, 2.5, 5.0};
      for(double dec = 10.0; dec <= 1.0e8; dec *= 10.0)
         for(int j = 0; j < ArraySize(mant); j++)
           {
            double c = mant[j] * dec;
            double e = MathAbs(MathLog(x / c));
            if(e < bestErr)
              {
               bestErr = e;
               best = (int)MathRound(c);
              }
           }
      return best;
     }

   //--- ATR(period) of closed bars (shift 1..period) from CopyRates; simple mean of true ranges; 0 = unavailable
   static double     ATR(const string symbol, const ENUM_TIMEFRAMES tf, const int period)
     {
      if(period <= 0)
         return 0.0;
      MqlRates r[];
      ArraySetAsSeries(r, false);
      int n = CopyRates(symbol, tf, 1, period + 1, r);
      if(n < period + 1)
         return 0.0;
      double sum = 0.0;
      for(int i = 1; i <= period; i++)
        {
         double pc = r[i - 1].close;
         double h  = MathMax(r[i].high, pc);
         double l  = MathMin(r[i].low, pc);
         sum += h - l;
        }
      return sum / (double)period;
     }

   //+---------------------------------------------------------------+
   //| Auto bucket in points (>= 1). logLine gets one summary line.   |
   //+---------------------------------------------------------------+
   static int        AutoBucket(const string symbol, const ENUM_TIMEFRAMES tf, string &logLine)
     {
      double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
      int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
      if(point <= 0.0)
        {
         logLine = "auto bucket: no SYMBOL_POINT, using 1";
         return 1;
        }
      double atr = ATR(symbol, tf, 14);
      double v = 0.0;
      string key = "";
      int kind = MatchPreset(CleanSymbol(symbol), v, key);
      int bucket = 0;
      string how = "";
      if(kind == 1)
        {
         bucket = (int)MathMax(1.0, MathRound(v / point));
         how = "preset " + key;
        }
      else
         if(kind == 2)
           {
            double ts = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
            if(ts <= 0.0)
               ts = point;
            bucket = (int)MathMax(1.0, MathRound(v * ts / point));
            how = "preset " + key + " (" + DoubleToString(v, 0) + " ticks)";
           }
      int atrBucket = 0;
      if(atr > 0.0)
         atrBucket = NiceRound(atr / (20.0 * point));
      if(bucket > 0)
        {
         if(atr > 0.0)
           {
            double ratio = atr / ((double)bucket * point);
            if(ratio < 6.0 || ratio > 80.0)
              {
               how = how + " rejected (ATR/row=" + DoubleToString(ratio, 1) + ", preset " + IntegerToString(bucket) +
                     " pts) -> ATR rule";
               bucket = atrBucket;
              }
           }
        }
      else
        {
         if(atrBucket > 0)
           {
            bucket = atrBucket;
            how = "ATR rule (ATR14=" + DoubleToString(atr, digits) + ")";
           }
         else
           {
            //--- last resort when neither a preset nor ATR is available: ~2 bp of price per row
            double px = SymbolInfoDouble(symbol, SYMBOL_BID);
            bucket = (px > 0.0) ? NiceRound(px * 0.0002 / point) : 1;
            how = "fallback 2bp of price (no preset, no ATR)";
           }
        }
      if(bucket < 1)
         bucket = 1;
      logLine = "bucket=" + IntegerToString(bucket) + " pts (" + DoubleToString((double)bucket * point, digits) +
                ") [" + how + "]";
      return bucket;
     }
};

#endif // ORDERFLOWFP_FPPRESETS_MQH
//+------------------------------------------------------------------+
