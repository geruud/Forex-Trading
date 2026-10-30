//+------------------------------------------------------------------+
//| FPStatus.mqh - EA status heartbeat shared by FootprintTrader       |
//| (writer) and the FootprintChart indicator / EA label (readers).    |
//|                                                                    |
//| The EA writes temporary GlobalVariables FTS_<symbol>_<magic>_* once |
//| a second (OnTimer) and on bar work. Temporary variables vanish when |
//| the terminal closes, so a stale heartbeat always means "EA off".    |
//| The heartbeat is TimeLocal(): it keeps moving while the market is   |
//| closed, unlike TimeCurrent().                                       |
//| No trading calls, no engine or UI dependencies.                     |
//+------------------------------------------------------------------+
#ifndef ORDERFLOWFP_FPSTATUS_MQH
#define ORDERFLOWFP_FPSTATUS_MQH

//--- state flags (bit mask in _FLAGS)
#define FTS_ALGO_OFF      1      // LIVE: AutoTrading / EA trading / account trading disabled
#define FTS_DISCONNECTED  2      // terminal has no server connection
#define FTS_LOADING       4      // engine history or indicators not ready yet
#define FTS_KILL          8      // kill switch fired (persists until reset)
#define FTS_DAY_LOSS      16     // daily loss limit reached
#define FTS_PAUSE         32     // consecutive-loss pause
#define FTS_DAY_CAP       64     // max entries per day reached
#define FTS_HALTED        128    // look-ahead assertion stopped the EA
#define FTS_WARMUP        256    // warm-up bars: signals logged, no trades
#define FTS_FEED_STALL    512    // the last tick fetch failed or blocked >= 5 s

#define FTS_STALE_SEC     15     // heartbeat older than this = EA not running

//--- severity of the decoded state
#define FTS_SEV_OK        0      // trading normally
#define FTS_SEV_INFO      1      // running, but no live orders (SIGNALS_ONLY / VIRTUAL)
#define FTS_SEV_WARN      2      // running, entries blocked for now
#define FTS_SEV_BAD       3      // not running or stopped for good

struct FTStatus
{
   bool     present;     // a heartbeat exists
   datetime heartbeat;   // TimeLocal() of the last write
   int      mode;        // 0 SIGNALS_ONLY, 1 VIRTUAL, 2 LIVE (ENUM_FP_TRADE_MODE values)
   int      flags;
   int      tradesToday;
   int      maxTrades;   // 0 = no cap
   int      open;        // positions + pending entries of this magic
   datetime pauseUntil;  // server time; 0 = none
};

string FTSName(const string symbol, const long magic, const string field)
{
   return "FTS_" + symbol + "_" + IntegerToString(magic) + "_" + field;
}

void FTSSet(const string symbol, const long magic, const string field, const double v)
{
   string n = FTSName(symbol, magic, field);
   if(!GlobalVariableCheck(n))
      GlobalVariableTemp(n);
   GlobalVariableSet(n, v);
}

double FTSGet(const string symbol, const long magic, const string field)
{
   string n = FTSName(symbol, magic, field);
   return GlobalVariableCheck(n) ? GlobalVariableGet(n) : 0.0;
}

//--- writer (EA)
void FTSWrite(const string symbol, const long magic, const FTStatus &s)
{
   FTSSet(symbol, magic, "MODE", (double)s.mode);
   FTSSet(symbol, magic, "FLAGS", (double)s.flags);
   FTSSet(symbol, magic, "TRADES", (double)s.tradesToday);
   FTSSet(symbol, magic, "MAXTR", (double)s.maxTrades);
   FTSSet(symbol, magic, "OPEN", (double)s.open);
   FTSSet(symbol, magic, "PAUSE", (double)(long)s.pauseUntil);
   FTSSet(symbol, magic, "HB", (double)(long)TimeLocal());   // last, so a reader never sees a fresh beat with old fields
}

//--- EA removed: delete the heartbeat so readers show "EA OFF" at once
void FTSClear(const string symbol, const long magic)
{
   string f[] = {"HB", "MODE", "FLAGS", "TRADES", "MAXTR", "OPEN", "PAUSE"};
   for(int i = 0; i < ArraySize(f); i++)
      GlobalVariableDel(FTSName(symbol, magic, f[i]));
}

//--- reader (indicator / EA label)
bool FTSRead(const string symbol, const long magic, FTStatus &s)
{
   ZeroMemory(s);
   string hb = FTSName(symbol, magic, "HB");
   if(!GlobalVariableCheck(hb))
      return false;
   s.present     = true;
   s.heartbeat   = (datetime)(long)GlobalVariableGet(hb);
   s.mode        = (int)FTSGet(symbol, magic, "MODE");
   s.flags       = (int)FTSGet(symbol, magic, "FLAGS");
   s.tradesToday = (int)FTSGet(symbol, magic, "TRADES");
   s.maxTrades   = (int)FTSGet(symbol, magic, "MAXTR");
   s.open        = (int)FTSGet(symbol, magic, "OPEN");
   s.pauseUntil  = (datetime)(long)FTSGet(symbol, magic, "PAUSE");
   return true;
}

//+------------------------------------------------------------------+
//| One badge text + severity. The first matching state wins, most     |
//| severe first, so the text always names what stops trading now.    |
//+------------------------------------------------------------------+
string FTSDescribe(const FTStatus &s, int &severity)
{
   severity = FTS_SEV_BAD;
   if(!s.present)
      return "EA OFF";
   long age = (long)TimeLocal() - (long)s.heartbeat;
   if(age > FTS_STALE_SEC || age < -FTS_STALE_SEC)
      return "EA OFF (no heartbeat " + IntegerToString(age) + " s)";
   if((s.flags & FTS_HALTED) != 0)
      return "EA HALTED (assert)";
   if((s.flags & FTS_KILL) != 0)
      return "EA STOPPED: KILL SWITCH";
   if(s.mode == 2 && (s.flags & FTS_ALGO_OFF) != 0)
      return "EA: ALGO TRADING OFF";
   if((s.flags & FTS_DISCONNECTED) != 0)
      return "EA: NO CONNECTION";
   severity = FTS_SEV_WARN;
   if((s.flags & FTS_FEED_STALL) != 0)
      return "EA: FEED STALLED";
   if((s.flags & FTS_LOADING) != 0)
      return "EA LOADING";
   if((s.flags & FTS_WARMUP) != 0)
      return "EA WARM-UP (no trades)";
   if(s.mode == 0)
     {
      severity = FTS_SEV_INFO;
      return "EA SIGNALS ONLY (no orders)";
     }
   string cnt = IntegerToString(s.tradesToday) + ((s.maxTrades > 0) ? "/" + IntegerToString(s.maxTrades) : "") + " today";
   if((s.flags & FTS_DAY_LOSS) != 0)
      return "EA PAUSED: DAILY LOSS - " + cnt;
   if((s.flags & FTS_PAUSE) != 0)
      return "EA PAUSED: LOSS STREAK" + ((s.pauseUntil > 0) ? " to " + TimeToString(s.pauseUntil, TIME_MINUTES) : "") + " - " + cnt;
   if((s.flags & FTS_DAY_CAP) != 0)
      return "EA PAUSED: DAY CAP - " + cnt;
   severity = (s.mode == 2) ? FTS_SEV_OK : FTS_SEV_INFO;
   string md = (s.mode == 2) ? "EA LIVE" : "EA VIRTUAL";
   return md + " - " + cnt + ((s.open > 0) ? ", " + IntegerToString(s.open) + " open" : "");
}

#endif // ORDERFLOWFP_FPSTATUS_MQH
//+------------------------------------------------------------------+
