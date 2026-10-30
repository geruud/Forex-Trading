//+------------------------------------------------------------------+
//| FPSignalTests.mq5 - unit tests of the pure signal detectors and   |
//| filter helpers with HAND-BUILT CFPBar objects (03 section 12 E3). |
//| Needs no engine history, no ticks and no indicator: runs on any   |
//| chart. Prints PASS/FAIL per test and a total.                     |
//| Row size 1.0 and rowLow 100 throughout, so price == row number:   |
//| row i spans [100+i, 101+i); low = 100, high = 100 + rows - 1.     |
//+------------------------------------------------------------------+
#property script_show_inputs
#property strict

#include <OrderFlowFP\Trade\FPRisk.mqh>

int g_pass = 0;
int g_fail = 0;

void Check(const string name, const bool cond)
{
   if(cond)
   {
      g_pass++;
      Print("PASS ", name);
   }
   else
   {
      g_fail++;
      Print("FAIL ", name);
   }
}

bool Near(const double a, const double b, const double tol = 1e-6)
{
   return MathAbs(a - b) <= tol;
}

//--- a closed bar from per-row volumes; volume, delta, low, high derived from the rows
CFPBar *NewBar(const datetime t, const long rowLow, const double &sell[], const double &buy[],
               const double open, const double close)
{
   int rows = ArraySize(sell);
   CFPBar *b = new CFPBar();
   b.time = t;
   b.rowLow = rowLow;
   b.rows = rows;
   ArrayResize(b.sellVol, rows);
   ArrayResize(b.buyVol, rows);
   ArrayResize(b.imbSell, rows);
   ArrayResize(b.imbBuy, rows);
   double vol = 0.0, dl = 0.0;
   for(int i = 0; i < rows; i++)
   {
      b.sellVol[i] = sell[i];
      b.buyVol[i] = buy[i];
      b.imbSell[i] = (char)0;
      b.imbBuy[i] = (char)0;
      vol += sell[i] + buy[i];
      dl += buy[i] - sell[i];
   }
   b.volume = vol;
   b.delta = dl;
   b.low = (double)rowLow;
   b.high = (double)(rowLow + rows - 1);
   b.open = open;
   b.close = close;
   b.ticks = 100;
   b.closed = true;
   b.state = 0;
   b.cvdValid = true;
   b.pocIdx = 0;
   return b;
}

CFPBar *UniformBar(const datetime t, const long rowLow, const int rows, const double sellEach, const double buyEach,
                   const double open, const double close)
{
   double s[];
   double b[];
   ArrayResize(s, rows);
   ArrayResize(b, rows);
   ArrayInitialize(s, sellEach);
   ArrayInitialize(b, buyEach);
   return NewBar(t, rowLow, s, b, open, close);
}

bool RunAbs(CFPBar *bar, const int dir, const double volSma, const FPSignalConfig &cfg, double &m[])
{
   ArrayResize(m, FP_M_COUNT);
   ArrayInitialize(m, 0.0);
   m[FP_M_VOLSMA] = volSma;
   return CFPSignals::DetectAbsorption(bar, dir, cfg, m);
}

bool RunExh(CFPBar *bar, const int dir, const FPSignalConfig &cfg)
{
   double m[];
   ArrayResize(m, FP_M_COUNT);
   ArrayInitialize(m, 0.0);
   return CFPSignals::DetectExhaustion(bar, dir, cfg, m);
}

FPZone MakeZone(const int dir, const datetime origin, const long rowFrom, const long rowTo)
{
   FPZone z;
   z.dir = dir;
   z.originTime = origin;
   z.rowFrom = rowFrom;
   z.rowTo = rowTo;
   z.priceLow = (double)rowFrom;
   z.priceHigh = (double)(rowTo + 1);
   z.rowsCount = (int)(rowTo - rowFrom + 1);
   z.volume = 0.0;
   z.filledTime = 0;
   z.touches = 0;
   z.lastTouchTime = 0;
   return z;
}

//+------------------------------------------------------------------+
void TestAbsorption(const FPSignalConfig &cfg)
{
   datetime t = D'2025.01.06 10:00';
   double m[];
   //--- long true: bottom 3 rows heavy with sells, close held
   double sA[] = {30, 30, 25, 5, 5, 5, 5, 5, 5};
   double bA[] = {10, 10, 15, 5, 5, 5, 5, 5, 5};
   CFPBar *a = NewBar(t, 100, sA, bA, 104, 106);
   Check("ABS.long.true", RunAbs(a, 1, 150, cfg, m));
   Check("ABS.long.metrics(share=0.708,conc=2.0,cf=0.75,volx=1.2)",
         Near(m[FP_M_SHARE], 85.0 / 120.0) && Near(m[FP_M_CONC], 2.0) && Near(m[FP_M_CLOSEFRAC], 0.75) &&
         Near(m[FP_M_VOLMULT], 1.2));
   Check("ABS.long.false.volumeBelowSMA", !RunAbs(a, 1, 200, cfg, m));
   Check("ABS.long.false.volumeSMAUnknown", !RunAbs(a, 1, 0, cfg, m));
   Check("ABS.short.false.mirrorOfLongBar", !RunAbs(a, -1, 150, cfg, m));
   a.close = 103;
   Check("ABS.long.false.closeFrac(0.375)", !RunAbs(a, 1, 150, cfg, m));
   delete a;
   //--- share fails (0.5), concentration still 2.0
   double sB[] = {20, 20, 20, 5, 5, 5, 5, 5, 5};
   double bB[] = {20, 20, 20, 5, 5, 5, 5, 5, 5};
   CFPBar *b = NewBar(t, 100, sB, bB, 104, 106);
   Check("ABS.long.false.sellShare(0.5)", !RunAbs(b, 1, 150, cfg, m) && Near(m[FP_M_CONC], 2.0));
   delete b;
   //--- concentration fails (1.33), share 0.75
   double sC[] = {12, 12, 12, 5, 5, 5, 5, 5, 5};
   double bC[] = {4, 4, 4, 5, 5, 5, 5, 5, 5};
   CFPBar *c = NewBar(t, 100, sC, bC, 104, 106);
   Check("ABS.long.false.concentration(1.33)", !RunAbs(c, 1, 100, cfg, m) && Near(m[FP_M_SHARE], 0.75));
   delete c;
   //--- shape fails: 6 rows < 2*3+1 (all other conditions pass)
   double sD[] = {30, 30, 25, 5, 5, 5};
   double bD[] = {10, 10, 15, 5, 5, 5};
   CFPBar *d = NewBar(t, 100, sD, bD, 102, 104);
   Check("ABS.long.false.shape(rows=6)", !RunAbs(d, 1, 100, cfg, m));
   delete d;
   //--- short true: top rows heavy with buys, close low in the bar
   double sE[] = {5, 5, 5, 5, 5, 5, 15, 10, 10};
   double bE[] = {5, 5, 5, 5, 5, 5, 25, 30, 30};
   CFPBar *e = NewBar(t, 100, sE, bE, 104, 102);
   Check("ABS.short.true", RunAbs(e, -1, 150, cfg, m) && Near(m[FP_M_SHARE], 85.0 / 120.0) &&
         Near(m[FP_M_CLOSEFRAC], 0.75));
   Check("ABS.long.false.mirrorOfShortBar", !RunAbs(e, 1, 150, cfg, m));
   delete e;
}

void TestExhaustion(const FPSignalConfig &cfg)
{
   datetime t = D'2025.01.06 10:05';
   //--- long true: tiny lowest row, sells increasing upward 1 < 5 < 10
   double sA[] = {1, 5, 10, 10, 10, 10, 10, 10, 10};
   double bA[] = {1, 5, 8, 12, 12, 12, 12, 12, 12};
   CFPBar *a = NewBar(t, 100, sA, bA, 103, 105);
   double m[];
   ArrayResize(m, FP_M_COUNT);
   ArrayInitialize(m, 0.0);
   Check("EXH.long.true", CFPSignals::DetectExhaustion(a, 1, cfg, m) && Near(m[FP_M_EXHPCT], 2.0 / 162.0));
   Check("EXH.short.false.mirrorOfLongBar", !RunExh(a, -1, cfg));
   a.close = 103;
   Check("EXH.long.false.closeFrac(0.375)", !RunExh(a, 1, cfg));
   delete a;
   double sB[] = {4, 5, 10, 10, 10, 10, 10, 10, 10};
   double bB[] = {4, 5, 8, 12, 12, 12, 12, 12, 12};
   CFPBar *b = NewBar(t, 100, sB, bB, 103, 105);
   Check("EXH.long.false.extremeRowTooBig(4.8%)", !RunExh(b, 1, cfg));
   delete b;
   double sC[] = {1, 1, 10, 10, 10, 10, 10, 10, 10};
   double bC[] = {1, 5, 8, 12, 12, 12, 12, 12, 12};
   CFPBar *c = NewBar(t, 100, sC, bC, 103, 105);
   Check("EXH.long.false.sellNotIncreasing", !RunExh(c, 1, cfg));
   delete c;
   double sD[] = {1, 5, 10, 10, 10, 10};
   double bD[] = {1, 5, 8, 12, 12, 12};
   CFPBar *d = NewBar(t, 100, sD, bD, 102, 104);
   Check("EXH.long.false.shape(rows=6)", !RunExh(d, 1, cfg));
   delete d;
   double sE[] = {12, 12, 12, 12, 12, 12, 8, 5, 1};
   double bE[] = {10, 10, 10, 10, 10, 10, 10, 5, 1};
   CFPBar *e = NewBar(t, 100, sE, bE, 105, 103);
   Check("EXH.short.true", RunExh(e, -1, cfg));
   e.close = 106;
   Check("EXH.short.false.closeFrac(0.25)", !RunExh(e, -1, cfg));
   delete e;
   //--- a bar that is BOTH absorption and exhaustion -> one ABS signal
   double sF[] = {1, 40, 50, 5, 5, 5, 5, 5, 5};
   double bF[] = {1, 10, 10, 5, 5, 5, 5, 5, 5};
   CFPBar *f = NewBar(t, 100, sF, bF, 104, 106);
   double mA[];
   bool isAbs = RunAbs(f, 1, 150, cfg, mA);
   bool isExh = RunExh(f, 1, cfg);
   Check("REV.both.true", isAbs && isExh);
   Check("REV.both.typeIsABS", CFPSignals::ResolveRevType(isAbs, isExh) == FP_SIG_ABSORPTION);
   Check("REV.exhOnly.typeIsEXH", CFPSignals::ResolveRevType(false, true) == FP_SIG_EXHAUSTION);
   Check("REV.none", CFPSignals::ResolveRevType(false, false) == FP_SIG_NONE);
   delete f;
}

void TestLocationAndGrade(void)
{
   double lows[] = {100.0, 101.0, 99.5};
   Check("LOC.long.true(newLow)", CFPSignals::LocationOK(99.0, lows, 1));
   Check("LOC.long.true(equalLow)", CFPSignals::LocationOK(99.5, lows, 1));
   Check("LOC.long.false", !CFPSignals::LocationOK(99.6, lows, 1));
   double highs[] = {109.0, 108.0, 110.0};
   Check("LOC.short.true", CFPSignals::LocationOK(110.0, highs, -1));
   Check("LOC.short.false", !CFPSignals::LocationOK(109.5, highs, -1));
   double none[];
   Check("LOC.false.noPriorBars", !CFPSignals::LocationOK(99.0, none, 1));
   Check("GRADE.5=A", CFPSignals::GradeFromPoints(5) == FP_GRADE_A);
   Check("GRADE.4=A", CFPSignals::GradeFromPoints(4) == FP_GRADE_A);
   Check("GRADE.3=B", CFPSignals::GradeFromPoints(3) == FP_GRADE_B);
   Check("GRADE.2=C", CFPSignals::GradeFromPoints(2) == FP_GRADE_C);
   Check("GRADE.0=C", CFPSignals::GradeFromPoints(0) == FP_GRADE_C);
   double lv[] = {101.2, 0.0};
   Check("LEVEL.near.true", CFPSignals::NearAnyLevel(100.0, 101.0, lv, 0.25));
   lv[0] = 101.3;
   Check("LEVEL.near.false", !CFPSignals::NearAnyLevel(100.0, 101.0, lv, 0.25));
   lv[0] = 99.8;
   Check("LEVEL.near.below.true", CFPSignals::NearAnyLevel(100.0, 101.0, lv, 0.25));
}

void TestExtremeImbalance(void)
{
   datetime t = D'2025.01.06 10:10';
   CFPBar *a = UniformBar(t, 100, 9, 5, 5, 103, 105);
   a.imbSell[4] = (char)3;
   Check("IMB.long.false(tier3 outside bottom rows)", !CFPSignals::ExtremeImbalance(a, 1, 3, 2));
   a.imbSell[1] = (char)2;
   Check("IMB.long.true(sell tier2 in bottom rows)", CFPSignals::ExtremeImbalance(a, 1, 3, 2));
   a.imbBuy[7] = (char)2;
   Check("IMB.short.true(buy tier2 in top rows)", CFPSignals::ExtremeImbalance(a, -1, 3, 2));
   a.imbBuy[7] = (char)1;
   Check("IMB.short.false(tier1)", !CFPSignals::ExtremeImbalance(a, -1, 3, 2));
   delete a;
}

void TestZones(const FPSignalConfig &cfg)
{
   datetime t = D'2025.01.06 11:00';
   //--- BUY zone rows 102..104 (index 2..4) in a 10-row bar, delta% +0.20, close 107 above the zone
   CFPBar *o = UniformBar(t, 100, 10, 4, 6, 101, 107);
   o.imbBuy[2] = (char)1;
   o.imbBuy[3] = (char)2;
   o.imbBuy[4] = (char)1;
   FPZone z = MakeZone(1, t, 102, 104);
   Check("ZONE.buy.true", CFPSignals::ZoneQualifies(z, o, 10.0, cfg));
   Check("ZONE.buy.false.height(3 > 0.6*4)", !CFPSignals::ZoneQualifies(z, o, 4.0, cfg));
   Check("ZONE.buy.false.atrUnknown", !CFPSignals::ZoneQualifies(z, o, 0.0, cfg));
   Check("ZONE.stackTier3.false", !CFPSignals::StackHasTier(z, o, 3));
   FPZone z2 = MakeZone(1, t, 102, 103);
   Check("ZONE.buy.false.rows(2)", !CFPSignals::ZoneQualifies(z2, o, 10.0, cfg));
   FPZone z3 = MakeZone(1, t, 108, 111);
   Check("ZONE.false.stackOutsideBar(index)", !CFPSignals::StackHasTier(z3, o, 1));
   FPZone z4 = MakeZone(1, t + 300, 102, 104);
   Check("ZONE.false.originMismatch", !CFPSignals::ZoneQualifies(z4, o, 10.0, cfg));
   o.close = 104.0;
   Check("ZONE.buy.false.closeNotBeyond(104 < 105)", !CFPSignals::ZoneQualifies(z, o, 10.0, cfg));
   o.close = 107.0;
   o.imbBuy[3] = (char)1;
   o.imbBuy[7] = (char)3;                             // tier 3 OUTSIDE the stack rows must not count
   Check("ZONE.buy.false.tier(index-based)", !CFPSignals::ZoneQualifies(z, o, 10.0, cfg));
   o.imbBuy[4] = (char)3;
   Check("ZONE.buy.true.tier3", CFPSignals::ZoneQualifies(z, o, 10.0, cfg) && CFPSignals::StackHasTier(z, o, 3));
   delete o;
   CFPBar *w = UniformBar(t, 100, 10, 4.6, 5.4, 101, 107);
   w.imbBuy[3] = (char)2;
   Check("ZONE.buy.false.deltaPct(0.08)", !CFPSignals::ZoneQualifies(z, w, 10.0, cfg));
   delete w;
   //--- SELL zone rows 105..107 (index 5..7), delta% -0.20, close 103 below the zone
   CFPBar *s = UniformBar(t, 100, 10, 6, 4, 108, 103);
   s.imbSell[6] = (char)2;
   FPZone zs = MakeZone(-1, t, 105, 107);
   Check("ZONE.sell.true", CFPSignals::ZoneQualifies(zs, s, 10.0, cfg));
   s.close = 106.0;
   Check("ZONE.sell.false.closeNotBeyond", !CFPSignals::ZoneQualifies(zs, s, 10.0, cfg));
   delete s;
}

void TestAsOfAndRetest(void)
{
   datetime T = D'2025.01.06 12:00';
   FPZone z = MakeZone(1, T - 1800, 102, 104);
   Check("ASOF.open.unfilled", CFPSignals::ZoneOpenAsOf(z, T));
   z.filledTime = T + 300;
   Check("ASOF.open.filledAfterT", CFPSignals::ZoneOpenAsOf(z, T));
   z.filledTime = T;
   Check("ASOF.closed.filledAtT", !CFPSignals::ZoneOpenAsOf(z, T));
   z.filledTime = T - 300;
   Check("ASOF.closed.filledBeforeT", !CFPSignals::ZoneOpenAsOf(z, T));
   z.filledTime = 0;
   z.originTime = T + 300;
   Check("ASOF.ignored.originAfterT", !CFPSignals::ZoneOpenAsOf(z, T));
   z.originTime = T - 1800;
   z.touches = 1;
   z.lastTouchTime = T;
   Check("ASOF.touchesBefore.excludesT", CFPSignals::ZoneTouchesBefore(z, T) == 0);
   z.lastTouchTime = T - 600;
   Check("ASOF.touchesBefore.earlierTouch", CFPSignals::ZoneTouchesBefore(z, T) == 1);
   z.lastTouchTime = T + 300;
   Check("ASOF.touchesBefore.unknownAfterT", CFPSignals::ZoneTouchesBefore(z, T) == -1);
   //--- retest bar conditions: BUY zone [102,105), mid 103.5
   CFPBar *r = UniformBar(T, 103, 6, 4, 6, 104, 106);  // low 103 high 108, delta +
   Check("RETEST.buy.true", CFPSignals::SzrRetest(z, r, false));
   r.close = 103.0;
   Check("RETEST.buy.false.closeBelowMid", !CFPSignals::SzrRetest(z, r, false));
   delete r;
   CFPBar *r2 = UniformBar(T, 103, 6, 6, 4, 104, 106);  // delta -
   Check("RETEST.buy.false.deltaNegative", !CFPSignals::SzrRetest(z, r2, false));
   Check("RETEST.buy.placebo.true(close>=open)", CFPSignals::SzrRetest(z, r2, true));
   r2.open = 107.0;
   Check("RETEST.buy.placebo.false(close<open)", !CFPSignals::SzrRetest(z, r2, true));
   delete r2;
   CFPBar *r3 = UniformBar(T, 106, 6, 4, 6, 107, 109);  // low 106 > 105: did not enter
   Check("RETEST.buy.false.notEntered", !CFPSignals::SzrRetest(z, r3, false));
   delete r3;
   CFPBar *r4 = UniformBar(T, 101, 6, 4, 6, 104, 105);  // low 101 < 102: filled
   Check("RETEST.buy.false.filled", !CFPSignals::SzrRetest(z, r4, false));
   delete r4;
   FPZone zs = MakeZone(-1, T - 1800, 105, 107);       // SELL zone [105,108), mid 106.5
   CFPBar *r5 = UniformBar(T, 101, 6, 6, 4, 104, 104);  // high 106, close 104, delta -
   Check("RETEST.sell.true", CFPSignals::SzrRetest(zs, r5, false));
   delete r5;
}

//--- FPDivBar series helper: all ok, same session, cvdValid, delta +10
void DivSeries(FPDivBar &b[], const double &highs[], const double &lows[], const datetime sess)
{
   int n = ArraySize(highs);
   ArrayResize(b, n);
   for(int i = 0; i < n; i++)
   {
      b[i].time = sess + 3600 + i * 300;
      b[i].high = highs[i];
      b[i].low = lows[i];
      b[i].delta = 10.0;
      b[i].cumDelta = 0.0;
      b[i].sessionStart = sess;
      b[i].cvdValid = true;
      b[i].ok = true;
   }
}

void TestDivergence(void)
{
   datetime S = D'2025.01.06 00:00';
   //--- bearish: P1 = index 3 (15), P2 = index 10 (17), confirmed at index 13 (pivot 3)
   double h[] = {10, 11, 12, 15, 12, 11, 10, 11, 12, 13, 17, 13, 12, 11};
   double l[];
   ArrayResize(l, ArraySize(h));
   for(int i = 0; i < ArraySize(h); i++)
      l[i] = h[i] - 2.0;
   FPDivBar b[];
   DivSeries(b, h, l, S);
   b[3].cumDelta = 500.0;
   b[10].cumDelta = 400.0;
   b[10].delta = 50.0;                                // positive: only the CVD condition can fire
   int p1 = -1, p2 = -1;
   bool ok = CFPSignals::DetectDivergence(b, 14, -1, 3, 30, p1, p2);
   Check("DIV.bear.cvd.sameSession.true", ok && p1 == 3 && p2 == 10);
   Check("DIV.bear.stampedAtConfirmingBar(p2+pivot == last)", ok && p2 + 3 == 13);
   bool early = false;
   for(int cnt = 11; cnt <= 13; cnt++)
      early = early || CFPSignals::DetectDivergence(b, cnt, -1, 3, 30, p1, p2);
   Check("DIV.bear.invisibleBeforeConfirmation", !early);
   Check("DIV.bear.series.noBullish", !CFPSignals::DetectDivergence(b, 14, 1, 3, 30, p1, p2));
   Check("DIV.bear.false.maxBars(5)", !CFPSignals::DetectDivergence(b, 14, -1, 3, 5, p1, p2));
   //--- CVD compared only within the same session and with cvdValid
   b[3].cvdValid = false;
   Check("DIV.bear.false.cvdInvalid(barDeltaOnly)", !CFPSignals::DetectDivergence(b, 14, -1, 3, 30, p1, p2));
   b[3].cvdValid = true;
   for(int i = 0; i <= 5; i++)
      b[i].sessionStart = S - 86400;
   Check("DIV.bear.false.otherSession(barDeltaOnly)", !CFPSignals::DetectDivergence(b, 14, -1, 3, 30, p1, p2));
   b[10].delta = -20.0;
   Check("DIV.bear.true.otherSession.negativeDelta", CFPSignals::DetectDivergence(b, 14, -1, 3, 30, p1, p2));
   for(int i = 0; i <= 5; i++)
      b[i].sessionStart = S;
   b[10].delta = 50.0;
   b[12].ok = false;
   Check("DIV.bear.false.badBarInPivotWindow", !CFPSignals::DetectDivergence(b, 14, -1, 3, 30, p1, p2));
   b[12].ok = true;
   b[10].high = 14.0;
   Check("DIV.bear.false.lowerHigh", !CFPSignals::DetectDivergence(b, 14, -1, 3, 30, p1, p2));
   //--- bullish mirror: P1 low 85 (index 3), P2 low 83 (index 10), CVD higher at P2
   double l2[] = {90, 89, 88, 85, 88, 89, 90, 89, 88, 87, 83, 87, 88, 89};
   double h2[];
   ArrayResize(h2, ArraySize(l2));
   for(int i = 0; i < ArraySize(l2); i++)
      h2[i] = l2[i] + 2.0;
   FPDivBar c[];
   DivSeries(c, h2, l2, S);
   c[3].cumDelta = -500.0;
   c[10].cumDelta = -400.0;
   c[10].delta = -50.0;
   Check("DIV.bull.cvd.sameSession.true", CFPSignals::DetectDivergence(c, 14, 1, 3, 30, p1, p2) && p1 == 3 && p2 == 10);
   Check("DIV.bull.invisibleBeforeConfirmation", !CFPSignals::DetectDivergence(c, 13, 1, 3, 30, p1, p2));
   for(int i = 0; i <= 5; i++)
      c[i].sessionStart = S - 86400;
   Check("DIV.bull.false.otherSession(barDeltaOnly)", !CFPSignals::DetectDivergence(c, 14, 1, 3, 30, p1, p2));
   c[10].delta = 5.0;
   Check("DIV.bull.true.otherSession.positiveDelta", CFPSignals::DetectDivergence(c, 14, 1, 3, 30, p1, p2));
}

void TestPlacebo(const FPSignalConfig &cfg)
{
   datetime t = D'2025.01.06 13:00';
   double m[];
   ArrayResize(m, FP_M_COUNT);
   ArrayInitialize(m, 0.0);
   CFPBar *a = UniformBar(t, 100, 9, 5, 5, 104, 106);   // low 100 high 108: wick 0.5, cf 0.75, range 8
   m[FP_M_RANGESMA] = 6.0;
   Check("PLACEBO.abs.true", CFPSignals::DetectAbsorptionPlacebo(a, 1, cfg, m) && Near(m[FP_M_WICK], 0.5));
   m[FP_M_RANGESMA] = 10.0;
   Check("PLACEBO.abs.false.range", !CFPSignals::DetectAbsorptionPlacebo(a, 1, cfg, m));
   m[FP_M_RANGESMA] = 6.0;
   a.open = 102.0;
   Check("PLACEBO.abs.false.wick(0.25)", !CFPSignals::DetectAbsorptionPlacebo(a, 1, cfg, m));
   a.open = 103.0;
   a.close = 105.0;
   Check("PLACEBO.exh.true", CFPSignals::DetectExhaustionPlacebo(a, 1, cfg, m));
   a.open = 106.0;
   Check("PLACEBO.exh.false.bearishBody", !CFPSignals::DetectExhaustionPlacebo(a, 1, cfg, m));
   delete a;
   //--- price-only zone at the base of an impulse bar
   CFPBar *o = UniformBar(t, 100, 10, 5, 5, 101, 108);  // body 7 >= 0.6*10
   FPZone z;
   bool okz = CFPSignals::PlaceboZone(o, 1, 101, 1.0, 10.0, cfg, z);
   Check("PLACEBO.zone.buy.true", okz && z.rowFrom == 101 && z.rowTo == 103 && Near(z.priceLow, 101.0) &&
         Near(z.priceHigh, 104.0) && z.rowsCount == 3);
   o.close = 106.0;
   Check("PLACEBO.zone.false.body(5 < 6)", !CFPSignals::PlaceboZone(o, 1, 101, 1.0, 10.0, cfg, z));
   delete o;
   CFPBar *s = UniformBar(t, 100, 10, 5, 5, 108, 101);
   Check("PLACEBO.zone.sell.true", CFPSignals::PlaceboZone(s, -1, 108, 1.0, 10.0, cfg, z) && z.rowFrom == 106 &&
         Near(z.priceHigh, 109.0));
   delete s;
}

void TestFilters(void)
{
   Check("FILTER.window.inside", CFPFilters::InTimeWindow(600, 480, 1200));
   Check("FILTER.window.endExclusive", !CFPFilters::InTimeWindow(1200, 480, 1200));
   Check("FILTER.window.beforeStart", !CFPFilters::InTimeWindow(479, 480, 1200));
   Check("FILTER.window.wrap.late", CFPFilters::InTimeWindow(1380, 1320, 120));
   Check("FILTER.window.wrap.early", CFPFilters::InTimeWindow(60, 1320, 120));
   Check("FILTER.window.wrap.outside", !CFPFilters::InTimeWindow(600, 1320, 120));
   Check("FILTER.window.equal=wholeDay", CFPFilters::InTimeWindow(5, 600, 600));
   Check("FILTER.window.off", CFPFilters::InTimeWindow(5, -1, -1));
   Check("FILTER.window.malformed=closed", !CFPFilters::InTimeWindow(600, -2, 1200));
   Check("FILTER.friday.afterCutoff", CFPFilters::FridayBlocked(D'2025.01.03 19:00', 1080));
   Check("FILTER.friday.beforeCutoff", !CFPFilters::FridayBlocked(D'2025.01.03 17:59', 1080));
   Check("FILTER.friday.thursday", !CFPFilters::FridayBlocked(D'2025.01.02 19:00', 1080));
   Check("FILTER.friday.off", !CFPFilters::FridayBlocked(D'2025.01.03 19:00', -1));
   Check("FILTER.spread.atrEdge", CFPFilters::SpreadOk(0.30, 30, 2.0, 0.15, 0));
   Check("FILTER.spread.atrFail", !CFPFilters::SpreadOk(0.31, 31, 2.0, 0.15, 0));
   Check("FILTER.spread.ptsFail", !CFPFilters::SpreadOk(0.30, 30, 2.0, 0.15, 20));
   Check("FILTER.spread.ptsOffWhenZero", CFPFilters::SpreadOk(0.30, 300, 2.0, 0.15, 0));
   Check("FILTER.spread.atrUnknown", !CFPFilters::SpreadOk(0.10, 10, 0.0, 0.15, 0));
}

//--- staleness guard + late-pending extension (docs\decisions\frequency.md, side issue)
void TestStaleness(void)
{
   Check("STALE.onTime", CFPFilters::Staleness(true, 3, 10, 0) == FP_BAR_ON_TIME);
   Check("STALE.onTime.edge10", CFPFilters::Staleness(true, 10, 10, 180) == FP_BAR_ON_TIME);
   Check("STALE.late.specOff", CFPFilters::Staleness(true, 124, 10, 0) == FP_BAR_STALE);
   Check("STALE.late.pendingOnly", CFPFilters::Staleness(true, 124, 10, 180) == FP_BAR_LATE_PENDING);
   Check("STALE.late.edge180", CFPFilters::Staleness(true, 180, 10, 180) == FP_BAR_LATE_PENDING);
   Check("STALE.late.beyond", CFPFilters::Staleness(true, 181, 10, 180) == FP_BAR_STALE);
   Check("STALE.breakBar.alwaysStale", CFPFilters::Staleness(false, 2, 10, 180) == FP_BAR_STALE);
   Check("STALE.lateTolBelowLag.off", CFPFilters::Staleness(true, 12, 10, 5) == FP_BAR_STALE);
}

//--- consecutive-loss protection: spec (pause to the next day) and pause mode (InpConsecPauseMin)
void TestRiskPause(void)
{
   FTRiskConfig rc;
   rc.symbol = _Symbol;
   rc.magic = 999001;
   rc.tag = "TEST";
   rc.persist = false;                      // memory only: no GlobalVariables touched
   rc.riskPct = 0.5;
   rc.allowMinLot = false;
   rc.maxTradesPerDay = 0;
   rc.maxDailyLossPct = 0.0;
   rc.maxConsecLosses = 3;
   rc.consecPauseMin = 60;
   rc.maxDDPct = 0.0;
   rc.testDailyLossAt = 0;
   rc.testConsecLossAt = 0;
   rc.testKillAt = 0;
   rc.testResetKill = false;
   datetime d0 = D'2025.01.07 00:00';
   CFPRisk p;
   p.Init(rc, 10000.0);
   p.BeginDay(d0 + 3600, 10000.0);
   string r = "";
   p.AddPositionResult(-50.0);
   p.AddPositionResult(-50.0);
   p.Monitor(d0 + 7200, 10000.0, 0.0);
   p.Gates(0, r);
   Check("PAUSE.twoLosses.noBlock", r == "");
   p.AddPositionResult(-50.0);
   int ev = p.Monitor(d0 + 7300, 10000.0, 0.0);
   r = "";
   p.Gates(0, r);
   Check("PAUSE.third.loss.fires", (ev & FT_RISK_EV_CONSEC) != 0 && r == "RISK_CONSEC_LOSSES");
   Check("PAUSE.counterRestarts", p.ConsecLosses() == 0);
   p.Monitor(d0 + 7300 + 59 * 60, 10000.0, 0.0);
   r = "";
   p.Gates(0, r);
   Check("PAUSE.blocked.at59min", r == "RISK_CONSEC_LOSSES" && p.EntriesBlocked());
   p.Monitor(d0 + 7300 + 60 * 60, 10000.0, 0.0);
   r = "";
   p.Gates(0, r);
   Check("PAUSE.free.at60min", r == "" && !p.EntriesBlocked());
   p.AddPositionResult(-50.0);
   p.AddPositionResult(25.0);              // a win resets the streak
   p.AddPositionResult(-50.0);
   p.AddPositionResult(-50.0);
   ev = p.Monitor(d0 + 4 * 3600, 10000.0, 0.0);
   Check("PAUSE.winResetsStreak", (ev & FT_RISK_EV_CONSEC) == 0 && p.ConsecLosses() == 2);
   //--- spec mode: pause until the next server day
   rc.consecPauseMin = 0;
   CFPRisk s;
   s.Init(rc, 10000.0);
   s.BeginDay(d0 + 3600, 10000.0);
   s.AddPositionResult(-50.0);
   s.AddPositionResult(-50.0);
   s.AddPositionResult(-50.0);
   ev = s.Monitor(d0 + 7200, 10000.0, 0.0);
   r = "";
   s.Gates(0, r);
   Check("SPEC.consec.fires", (ev & FT_RISK_EV_CONSEC) != 0 && r == "RISK_CONSEC_LOSSES");
   s.Monitor(d0 + 23 * 3600, 10000.0, 0.0);
   r = "";
   s.Gates(0, r);
   Check("SPEC.consec.stillBlocked.lateSameDay", r == "RISK_CONSEC_LOSSES");
   s.BeginDay(d0 + 86400 + 60, 10000.0);
   s.Monitor(d0 + 86400 + 60, 10000.0, 0.0);
   r = "";
   s.Gates(0, r);
   Check("SPEC.consec.nextDay.free", r == "");
}

//+------------------------------------------------------------------+
void OnStart()
{
   FPSignalConfig cfg;
   CFPSignals::DefaultConfig(cfg);
   Print("FPSignalTests: start");
   TestAbsorption(cfg);
   TestExhaustion(cfg);
   TestLocationAndGrade();
   TestExtremeImbalance();
   TestZones(cfg);
   TestAsOfAndRetest();
   TestDivergence();
   TestPlacebo(cfg);
   TestFilters();
   TestStaleness();
   TestRiskPause();
   PrintFormat("FPSignalTests: %d passed, %d failed, %d total -> %s", g_pass, g_fail, g_pass + g_fail,
               (g_fail == 0 ? "ALL PASS" : "FAILURES"));
}
//+------------------------------------------------------------------+
