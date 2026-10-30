//+------------------------------------------------------------------+
//| FPSignalTypes.mqh - types shared by the EA layers                 |
//|   signals (FPSignals.mqh) -> filters/grading (Trade\FPFilters)     |
//|   -> risk/execution/journal (Trade\FPRisk, FPExecution, FPJournal) |
//| Not part of the engine: the five engine files never include it.   |
//| Ownership: additive changes only (new fields/enums at the end);   |
//| never rename or remove a member. Record additions in DECISIONS.   |
//+------------------------------------------------------------------+
#include "FPEngine.mqh"

//--- setups (03 §4)
enum ENUM_FP_SIGNAL
{
   FP_SIG_NONE             = 0,
   FP_SIG_ZONE_RETEST      = 1,
   FP_SIG_ABSORPTION       = 2,
   FP_SIG_EXHAUSTION       = 3,
   FP_SIG_DELTA_DIVERGENCE = 4
};

//--- how a signal is entered
enum ENUM_FP_ORDER_KIND
{
   FP_ORD_MARKET = 0,     // market at the next bar open (entryPrice == 0)
   FP_ORD_STOP   = 1,     // buy-stop / sell-stop at entryPrice (ABS/EXH, standalone DIV)
   FP_ORD_LIMIT  = 2      // buy-limit / sell-limit at entryPrice (SZR LIMIT_AT_ZONE)
};

enum ENUM_FP_SZR_ENTRY
{
   FP_SZR_CONFIRM_CLOSE = 0,
   FP_SZR_LIMIT_AT_ZONE = 1
};

enum ENUM_FP_GRADE
{
   FP_GRADE_C = 0,
   FP_GRADE_B = 1,
   FP_GRADE_A = 2
};

enum ENUM_FP_TRADE_MODE
{
   FP_MODE_SIGNALS_ONLY = 0,
   FP_MODE_VIRTUAL      = 1,
   FP_MODE_LIVE         = 2
};

enum ENUM_FP_REQUIRE_SOURCE
{
   FP_REQ_ANY           = 0,
   FP_REQ_EXCHANGE_ONLY = 1
};

enum ENUM_FP_TP_MODE
{
   FP_TP_R_MULTIPLE = 0,
   FP_TP_STRUCTURE  = 1
};

enum ENUM_FP_TRAIL_MODE
{
   FP_TRAIL_ATR = 0,
   FP_TRAIL_BAR = 1
};

//--- ATR regime: r = ATR(14) / SMA(ATR(14), 50); TREND r > atrTrend, CHOP r < atrChop, else BASE
enum ENUM_FP_REGIME
{
   FP_REG_CHOP  = -1,
   FP_REG_BASE  = 0,
   FP_REG_TREND = 1
};

//--- metric slots of the pure detectors' m[] array (callers size it to FP_M_COUNT)
#define FP_M_SHARE      0   // out: sell share (long) / buy share (short) over the extreme k rows
#define FP_M_CONC       1   // out: concentration = vol(k rows) / (k * bar.volume / bar.rows)
#define FP_M_CLOSEFRAC  2   // out: close location in the signal direction, 0..1
#define FP_M_EXHPCT     3   // out: extreme row volume / bar.volume
#define FP_M_VOLSMA     4   // IN : SMA(bar volume, volSmaLen) of the bars before the signal bar (0 = unknown -> volume test fails)
#define FP_M_VOLMULT    5   // out: bar.volume / m[FP_M_VOLSMA]
#define FP_M_RANGESMA   6   // IN (placebo only): SMA(bar high-low, volSmaLen) of the bars before the signal bar (0 = unknown -> range test fails)
#define FP_M_WICK       7   // out (placebo only): rejection-wick fraction in the signal direction (long: (min(open,close)-low)/(high-low))
#define FP_M_COUNT      8

//+------------------------------------------------------------------+
//| One setup occurrence on a CLOSED bar (03 §4)                      |
//+------------------------------------------------------------------+
struct FPSignal
{
   ENUM_FP_SIGNAL     type;
   int                dir;            // +1 long, -1 short
   datetime           barTime;        // CLOSED bar that produced it; ALWAYS < open time of the forming bar
   double             entryPrice;     // stop/limit trigger price (bid-based level), or 0 = market at next bar open
   double             stopPrice;      // initial protective stop (bid-based level, before spread adjustment)
   double             refLow, refHigh;// zone or bar extremes used by the setup
   int                grade;          // 2 = A, 1 = B, 0 = C
   int                points;         // grade points (03 §6)
   string             info;           // "key=value;..." metrics for the CSV
   //--- additions to the 03 §4 struct (DECISIONS.md "EA interface")
   ENUM_FP_ORDER_KIND orderKind;      // MARKET when entryPrice == 0
   int                validBars;      // pending validity in chart-TF bars (0 = not a pending entry)
   double             invalidPrice;   // pending invalidation: long -> cancel when bid < invalidPrice; short -> when bid > invalidPrice; 0 = none
   double             tpStructure;    // structure target (bid-based level) for InpTPMode=STRUCTURE; 0 = none
   double             atr;            // ATR of the chart TF at signal time (price units)
   double             share;          // ABS: sell share (long) / buy share (short) of the extreme rows; 0 = n/a
   double             concentration;  // ABS concentration; 0 = n/a
   double             closeFrac;      // close location in the signal direction (0..1)
   double             exhaustionPct;  // EXH: extreme row volume / bar volume; 0 = n/a
   int                stackRows;      // SZR: zone rowsCount; 0 = n/a
   bool               divConfluence;  // a DIV confirmed within [T - 3 bars, T] in the same direction
   datetime           zoneOrigin;     // SZR: zone origin bar time; 0 = n/a

   void Reset()
   {
      type = FP_SIG_NONE; dir = 0; barTime = 0; entryPrice = 0.0; stopPrice = 0.0;
      refLow = 0.0; refHigh = 0.0; grade = FP_GRADE_C; points = 0; info = "";
      orderKind = FP_ORD_MARKET; validBars = 0; invalidPrice = 0.0; tpStructure = 0.0; atr = 0.0;
      share = 0.0; concentration = 0.0; closeFrac = 0.0; exhaustionPct = 0.0; stackRows = 0;
      divConfluence = false; zoneOrigin = 0;
   }
};

//+------------------------------------------------------------------+
//| Market context of closed bar T, built AS OF the close of T        |
//| (indicator values at shift 1, never shift 0; 03 §4 as-of rule)    |
//+------------------------------------------------------------------+
struct FPContext
{
   datetime       barTime;        // T
   bool           valid;          // false if any required input was unavailable
   double         atr;            // ATR(atrPeriod) of the chart TF for bar T (price units)
   double         atrRatio;       // atr / SMA(ATR, atrBaseLen)
   int            regime;         // ENUM_FP_REGIME
   int            htfBias;        // +1 last closed HTF close > EMA, -1 below, 0 unknown
   double         htfClose;       // last closed HTF bar close
   double         htfEma;         // EMA(htfEma) on that HTF bar
   double         spreadPts;      // current spread in points at evaluation time
   double         spreadPrice;    // current ask - bid
   double         sessPOC;        // session profile of T's session, bars <= T only
   double         sessVAH;
   double         sessVAL;
   double         prevSessPOC;    // POC of the previous session (0 = unknown)
   double         prevDayHigh;    // previous server day's high/low (0 = unknown)
   double         prevDayLow;
   double         volSMA;         // SMA(bar volume, volSmaLen) of the bars BEFORE T (0 = unknown)
   ENUM_FP_SOURCE source;         // engine ActiveSource()

   void Reset()
   {
      barTime = 0; valid = false; atr = 0.0; atrRatio = 0.0; regime = FP_REG_BASE; htfBias = 0;
      htfClose = 0.0; htfEma = 0.0; spreadPts = 0.0; spreadPrice = 0.0;
      sessPOC = 0.0; sessVAH = 0.0; sessVAL = 0.0; prevSessPOC = 0.0;
      prevDayHigh = 0.0; prevDayLow = 0.0; volSMA = 0.0; source = FP_SRC_AUTO;
   }
};

//+------------------------------------------------------------------+
//| Every Inp* of 03 §4.1-4.3 and §6, copied 1:1, plus the context    |
//| constants the spec fixes (ATR 14/50, regime 1.15/0.85, SMA 20).   |
//+------------------------------------------------------------------+
struct FPSignalConfig
{
   string            symbol;
   ENUM_TIMEFRAMES   timeframe;
   //--- SZR (§4.1)
   bool              szrEnable;           // InpSZREnable       true
   ENUM_FP_SZR_ENTRY szrEntry;            // InpSZREntry        CONFIRM_CLOSE
   int               szrMinRows;          // InpSZRMinRows      3
   int               szrMinTier;          // InpSZRMinTier      2
   double            szrMinDeltaPct;      // InpSZRMinDeltaPct  0.10
   double            szrMaxHeightATR;     // InpSZRMaxHeightATR 0.6
   int               szrMaxAgeBars;       // InpSZRMaxAgeBars   30
   int               szrMaxTouches;       // InpSZRMaxTouches   1
   //--- ABS / EXH (§4.2)
   bool              revEnable;           // InpRevEnable         true
   int               revLookback;         // InpRevLookback       20
   int               revRows;             // InpRevRows           3
   double            absSellShare;        // InpABSSellShare      0.60
   double            absConcentration;    // InpABSConcentration  1.5
   double            absCloseFrac;        // InpABSCloseFrac      0.50
   double            exhMaxPct;           // InpEXHMaxPct         0.03
   double            revMinVolMult;       // InpRevMinVolMult     1.0
   int               revEntryOffsetPts;   // InpRevEntryOffsetPts 0
   int               revValidBars;        // InpRevValidBars      2
   double            levelTolATR;         // InpLevelTolATR       0.25
   //--- DIV (§4.3)
   int               divPivot;            // InpDIVPivot      3
   int               divMaxBars;          // InpDIVMaxBars    30
   bool              divStandalone;       // InpDIVStandalone false
   //--- grade (§6)
   int               minGrade;            // InpMinGrade      B (1)
   //--- shared
   double            slBufferATR;         // InpSLBufferATR       0.10
   bool              placeboPriceOnly;    // InpPlaceboPriceOnly  false
   ENUM_TIMEFRAMES   htf;                 // InpHTF    H1 (HTF agreement grade point)
   int               htfEma;              // InpHTFEMA 50
   //--- fixed by the spec (not inputs)
   int               atrPeriod;           // 14
   int               atrBaseLen;          // 50
   double            atrTrend;            // 1.15
   double            atrChop;             // 0.85
   int               volSmaLen;           // 20
   double            exhCloseFrac;        // 0.40
   //--- additions (signals agent; a value <= 0 means: use the default shown)
   double            valueAreaPct;        // 0.70  session value area; must equal the engine's FPConfig.valueAreaPct
   double            placeboWickFrac;     // 0.40  placebo ABS: rejection wick >= this fraction of the bar range
   double            placeboSzrBodyATR;   // 0.60  placebo SZR: origin-bar body >= this x ATR(origin bar)
};

//+------------------------------------------------------------------+
//| Filter inputs (03 §5)                                             |
//+------------------------------------------------------------------+
struct FPFilterConfig
{
   string                 symbol;
   ENUM_TIMEFRAMES        timeframe;
   int                    minTicksPerBar;    // InpMinTicksPerBar 60
   ENUM_FP_REQUIRE_SOURCE requireSource;     // InpRequireSource  ANY
   int                    tradeStartMin;     // InpTradeStart  "08:00" -> 480 (minutes after 00:00 server time)
   int                    tradeEndMin;       // InpTradeEnd    "20:00" -> 1200
   int                    fridayCutoffMin;   // InpFridayCutoff "18:00" -> 1080 (-1 = off)
   int                    maxSpreadPts;      // InpMaxSpreadPts 0 = off
   double                 maxSpreadATR;      // InpMaxSpreadATR 0.15
   double                 minATRPts;         // InpMinATRPts    0
   double                 szrMinAtrRatio;    // 0.85 (SZR requires r >= this)
   double                 revMaxAtrRatio;    // 1.30 (ABS/EXH require r <= this)
   ENUM_TIMEFRAMES        htf;               // InpHTF    H1
   int                    htfEma;            // InpHTFEMA 50
   int                    newsMin;           // InpNewsMin 15
   int                    maxPositions;      // InpMaxPositions 1
};

//+------------------------------------------------------------------+
//| Small shared helpers                                              |
//+------------------------------------------------------------------+
// "M5", "H1", ... (EnumToString without the PERIOD_ prefix). Used in every CSV file name.
string FPTfName(const ENUM_TIMEFRAMES tf)
{
   ENUM_TIMEFRAMES t = (tf == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)Period() : tf;
   string s = EnumToString(t);
   if(StringFind(s, "PERIOD_") == 0)
      s = StringSubstr(s, 7);
   return s;
}

// "HH:MM" -> minutes after 00:00; "" -> -1 (off); malformed -> -2
int FPParseHHMM(const string hhmm)
{
   string s = hhmm;
   StringTrimLeft(s);
   StringTrimRight(s);
   if(s == "")
      return -1;
   string parts[];
   if(StringSplit(s, ':', parts) != 2)
      return -2;
   int h = (int)StringToInteger(parts[0]);
   int m = (int)StringToInteger(parts[1]);
   if(h < 0 || h > 23 || m < 0 || m > 59)
      return -2;
   return h * 60 + m;
}

string FPSetupName(const ENUM_FP_SIGNAL type)
{
   switch(type)
   {
      case FP_SIG_ZONE_RETEST:      return "SZR";
      case FP_SIG_ABSORPTION:       return "ABS";
      case FP_SIG_EXHAUSTION:       return "EXH";
      case FP_SIG_DELTA_DIVERGENCE: return "DIV";
      default:                      return "NONE";
   }
}

string FPGradeName(const int grade)
{
   if(grade >= FP_GRADE_A)
      return "A";
   if(grade == FP_GRADE_B)
      return "B";
   return "C";
}
//+------------------------------------------------------------------+
