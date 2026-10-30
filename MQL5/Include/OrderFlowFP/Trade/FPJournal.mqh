//+------------------------------------------------------------------+
//| FPJournal.mqh - FootprintTrader journal + VIRTUAL simulator       |
//|                                                                    |
//|  CFPJournal  signals_<sym>_<tf>.csv / trades_<sym>_<tf>.csv in     |
//|              EXACTLY the EA_ARCHITECTURE §7 formats (append, header|
//|              only for a new file, '.' decimals, yyyy.mm.dd hh:mi:ss|
//|              times), bar dumps through the engine's CFPDumpWriter, |
//|              per-position R list for OnTester (03 §9).             |
//|  CFPVirtual  VIRTUAL mode: entries, stops, targets, partials, BE,  |
//|              trailing, time stops simulated tick by tick, bid/ask  |
//|              aware, fills stressed by InpStressSpreadMult and      |
//|              InpStressSlipPts. Management decisions come from the  |
//|              SAME CFTTradeLogic routine as LIVE; plans from the    |
//|              SAME CFTPlanner. Rows look like LIVE rows (ticket=0). |
//+------------------------------------------------------------------+
#include "FPExecution.mqh"
#include "..\FPDump.mqh"

#define FT_SIGNALS_HEADER "signalId,barTime,setup,dir,grade,points,entryPrice,stopPrice,refLow,refHigh,open,high,low,close,volume,delta,deltaPct,cumDelta,imbBuyCount,imbSellCount,stackRows,sellShare,concentration,closeFrac,exhaustionPct,atr,atrRatio,spreadPts,htfBias,source,mode,decision,info"
#define FT_TRADES_HEADER  "tradeId,signalId,ticket,setup,dir,grade,mode,entryTime,entryPrice,sl,tp,lots,riskMoney,exitTime,exitPrice,exitReason,rMultiple,maeR,mfeR,barsHeld,spreadAtEntry,slippagePts,profitMoney,partialDone"

//+------------------------------------------------------------------+
//| CFPJournal                                                        |
//+------------------------------------------------------------------+
class CFPJournal
{
private:
   string          m_sym;
   ENUM_TIMEFRAMES m_tf;
   bool            m_common;
   string          m_mode;
   bool            m_flush;       // live: flush every row; tester: on close only
   int             m_digits;
   int             m_hSig;
   int             m_hTrd;
   CFPDumpWriter   m_dump;
   bool            m_dumpOn;
   double          m_r[];         // rMultiple of every FILLED position journaled in this run (OnTester)
   int             m_writeErrors;

   string          Time(const datetime t) const { return (t > 0) ? TimeToString(t, TIME_DATE | TIME_SECONDS) : ""; }
   string          Px(const double v) const     { return DoubleToString(v, m_digits); }

   string          Clean(const string s) const
   {
      string c = s;
      StringReplace(c, ",", ";");
      StringReplace(c, "\r", " ");
      StringReplace(c, "\n", " ");
      return c;
   }

   int             OpenAppend(const string name, const string header)
   {
      int flags = FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_SHARE_READ | FILE_SHARE_WRITE;
      if(m_common)
         flags |= FILE_COMMON;
      string path = "OrderFlowFP\\" + name;
      ResetLastError();
      int h = FileOpen(path, flags);
      if(h == INVALID_HANDLE)
      {
         Print("FT JOURNAL: cannot open ", path, (m_common ? " (common folder)" : ""), ", err=", GetLastError());
         return INVALID_HANDLE;
      }
      if(FileSize(h) == 0)
         WriteLine(h, header);
      else
      {
         FileSeek(h, 0, SEEK_SET);
         string first = FileReadString(h);
         if(first != header)
            Print("FT JOURNAL: WARNING ", path, " has a different header (old format?) - rows are appended anyway; move the old file away to start clean");
         FileSeek(h, 0, SEEK_END);
      }
      Print("FT JOURNAL: ", m_common ? "<common>\\Files\\" : "MQL5\\Files\\", path,
            MQLInfoInteger(MQL_TESTER) != 0 ? "  (tester: inside the agent sandbox Tester\\Agent-...\\MQL5\\Files)" : "");
      return h;
   }

   void            WriteLine(const int h, const string line)
   {
      if(h == INVALID_HANDLE)
         return;
      uint n = FileWriteString(h, line + "\r\n");
      if(n == 0 && m_writeErrors++ < 5)
         Print("FT JOURNAL: write failed, err=", GetLastError());
      if(m_flush)
         FileFlush(h);
   }

   //--- open,high,low,close,volume,delta,deltaPct,cumDelta,imbBuyCount,imbSellCount
   string          BarFields(CFPBar *bar) const
   {
      if(bar == NULL)
         return "0,0,0,0,0,0,0,0,0,0";
      int nb = 0;
      int ns = 0;
      int rows = MathMin(bar.rows, MathMin(ArraySize(bar.imbBuy), ArraySize(bar.imbSell)));
      for(int i = 0; i < rows; i++)
      {
         if(bar.imbBuy[i] > 0)
            nb++;
         if(bar.imbSell[i] > 0)
            ns++;
      }
      double dp = (bar.volume > 0.0) ? bar.delta / bar.volume : 0.0;
      return StringFormat("%s,%s,%s,%s,%s,%s,%s,%s,%d,%d", Px(bar.open), Px(bar.high), Px(bar.low), Px(bar.close),
                          FTNumTrim(bar.volume), FTNumTrim(bar.delta), DoubleToString(dp, 4), FTNumTrim(bar.cumDelta), nb, ns);
   }

public:
                   CFPJournal(void)
   {
      m_hSig = INVALID_HANDLE; m_hTrd = INVALID_HANDLE; m_dumpOn = false; m_common = false; m_flush = true;
      m_digits = 5; m_writeErrors = 0; m_tf = PERIOD_CURRENT;
   }

   bool            Init(const string sym, const ENUM_TIMEFRAMES tf, const bool common, const int mode, const bool dumpBars, CFPEngine *engine)
   {
      m_sym = sym;
      m_tf = tf;
      m_common = common;
      m_mode = FTModeName(mode);
      m_flush = (MQLInfoInteger(MQL_TESTER) == 0);
      m_digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      ArrayResize(m_r, 0);
      FolderCreate("OrderFlowFP", common ? FILE_COMMON : 0);
      string suffix = sym + "_" + FPTfName(tf) + ".csv";
      m_hSig = OpenAppend("signals_" + suffix, FT_SIGNALS_HEADER);
      m_hTrd = OpenAppend("trades_" + suffix, FT_TRADES_HEADER);
      m_dumpOn = false;
      if(dumpBars)
      {
         m_dumpOn = m_dump.Open(sym, tf, common);
         Print("FT JOURNAL: bar dump (FPDumpBars format) ", m_dumpOn ? "open" : "FAILED to open",
               engine != NULL ? "" : " (no engine)");
      }
      return (m_hSig != INVALID_HANDLE && m_hTrd != INVALID_HANDLE);
   }

   void            Deinit(void)
   {
      if(m_hSig != INVALID_HANDLE)
         FileClose(m_hSig);
      if(m_hTrd != INVALID_HANDLE)
         FileClose(m_hTrd);
      m_hSig = INVALID_HANDLE;
      m_hTrd = INVALID_HANDLE;
      if(m_dumpOn)
         m_dump.Close();
      m_dumpOn = false;
   }

   //--- one signal row; extra = trade-layer key=value pairs appended to 'info'
   void            LogSignal(const long sid, const FPSignal &sig, CFPBar *bar, const FPContext &ctx, const string decision, const string extra)
   {
      string info = sig.info;
      if(extra != "")
         info = (info == "") ? extra : info + ";" + extra;
      //--- 24 fields; BarFields expands to 10 columns -> 33 columns = FT_SIGNALS_HEADER
      string line = StringFormat("%I64d,%s,%s,%d,%s,%d,%s,%s,%s,%s,%s,%d,%s,%s,%s,%s,%s,%s,%s,%d,%s,%s,%s,%s",
                                 sid, Time(sig.barTime), FPSetupName(sig.type), sig.dir, FPGradeName(sig.grade), sig.points,
                                 Px(sig.entryPrice), Px(sig.stopPrice), Px(sig.refLow), Px(sig.refHigh), BarFields(bar),
                                 sig.stackRows, DoubleToString(sig.share, 4), DoubleToString(sig.concentration, 4),
                                 DoubleToString(sig.closeFrac, 4), DoubleToString(sig.exhaustionPct, 4),
                                 DoubleToString(ctx.atr, m_digits + 1), DoubleToString(ctx.atrRatio, 4), DoubleToString(ctx.spreadPts, 1),
                                 ctx.htfBias, FTSourceName(ctx.source), m_mode, Clean(decision), Clean(info));
      WriteLine(m_hSig, line);
   }

   //--- a skipped bar: setup NONE, decision SKIPPED:<why>
   void            LogSkip(const datetime T, CFPBar *bar, const ENUM_FP_SOURCE src, const string why, const string info)
   {
      string line = StringFormat("0,%s,NONE,0,,0,0,0,0,0,%s,0,0,0,0,0,0,0,0,0,%s,%s,SKIPPED:%s,%s",
                                 Time(T), BarFields(bar), FTSourceName(src), m_mode, why, Clean(info));
      WriteLine(m_hSig, line);
   }

   //--- an unfilled pending (EXPIRED) has no exit price, R, MAE or MFE: those fields stay EMPTY (n/a),
   //--- so R statistics can never count it as a 0 R trade
   void            LogTrade(const FTTradeRecord &r)
   {
      string exitPx = r.filled ? Px(r.exitPrice) : "";
      string rm     = r.filled ? DoubleToString(r.rMultiple, 4) : "";
      string mae    = r.filled ? DoubleToString(r.maeR, 4) : "";
      string mfe    = r.filled ? DoubleToString(r.mfeR, 4) : "";
      string line = StringFormat("%I64d,%I64d,%I64u,%s,%d,%s,%s,%s,%s,%s,%s,%s,%.2f,%s,%s,%s,%s,%s,%s,%d,%.1f,%.1f,%.2f,%d",
                                 r.tradeId, r.signalId, r.ticket, FPSetupName((ENUM_FP_SIGNAL)r.setup), r.dir, FPGradeName(r.grade),
                                 r.mode, Time(r.entryTime), Px(r.entryPrice), Px(r.sl), Px(r.tp), FTNumTrim(r.lots), r.riskMoney,
                                 Time(r.exitTime), exitPx, r.exitReason, rm, mae, mfe, r.barsHeld,
                                 r.spreadAtEntry, r.slippagePts, r.profitMoney, r.partialDone ? 1 : 0);
      WriteLine(m_hTrd, line);
      if(r.filled)
      {
         int n = ArraySize(m_r);
         ArrayResize(m_r, n + 1);
         m_r[n] = r.rMultiple;
      }
   }

   bool            DumpBar(CFPBar *bar, CFPEngine *engine)
   {
      if(!m_dumpOn || bar == NULL || engine == NULL)
         return false;
      return m_dump.Write(bar, engine);
   }

   int             Positions(void) const { return ArraySize(m_r); }

   //+---------------------------------------------------------------+
   //| OnTester criterion (03 §9), from this EA's own per-position   |
   //| records (partials merged): n < 30 -> 0; PF_R = sum(R>0) /     |
   //| |sum(R<0)| capped at 5 (5 without losers);                    |
   //| (PF_R - 1) * sqrt(n) / max(1, equity DD %).                   |
   //+---------------------------------------------------------------+
   double          TesterCriterion(const double ddRelPct, string &summary) const
   {
      int    n = ArraySize(m_r);
      double gp = 0.0;
      double gl = 0.0;
      double sum = 0.0;
      int    wins = 0;
      for(int i = 0; i < n; i++)
      {
         sum += m_r[i];
         if(m_r[i] > 0.0)
         {
            gp += m_r[i];
            wins++;
         }
         else if(m_r[i] < 0.0)
            gl += -m_r[i];
      }
      double pf = (gl > 0.0) ? gp / gl : ((gp > 0.0) ? 5.0 : 1.0);
      if(pf > 5.0)
         pf = 5.0;
      double crit = (n < 30) ? 0.0 : (pf - 1.0) * MathSqrt((double)n) / MathMax(1.0, ddRelPct);
      summary = StringFormat("positions %d, win %.1f%%, avgR %.3f, PF_R %.3f, equityDD %.2f%% -> criterion %.4f%s",
                             n, (n > 0) ? 100.0 * wins / n : 0.0, (n > 0) ? sum / n : 0.0, pf, ddRelPct, crit,
                             (n < 30) ? " (n < 30 -> 0)" : "");
      return crit;
   }
};

//+------------------------------------------------------------------+
//| CFPVirtual - VIRTUAL trades (03 §9)                               |
//|                                                                    |
//| Prices: vBid = bid, vAsk = bid + (ask - bid) * InpStressSpreadMult |
//| (the plan is built from the same stressed quote).                  |
//| Fills:  market      long vAsk + slip      short vBid - slip       |
//|         stop entry  long vAsk + slip      short vBid - slip       |
//|                     (triggered when vAsk >= / vBid <= the price)   |
//|         limit entry at the limit price    (no price improvement)   |
//|         stop loss   long vBid - slip      short vAsk + slip       |
//|                     (triggered when vBid <= SL / vAsk >= SL)       |
//|         take profit at the TP price                                |
//|         EA closes   long vBid - slip      short vAsk + slip       |
//| Money via OrderCalcProfit; no commission or swap (documented).     |
//| A new order/position ignores ticks at or before its creation tick. |
//+------------------------------------------------------------------+
struct FTVirtConfig
{
   string          symbol;
   ENUM_TIMEFRAMES tf;
   double          spreadMult;    // InpStressSpreadMult (>= 1)
   int             slipPts;       // InpStressSlipPts (>= 0)
};

class CFPVirtual
{
private:
   FTVirtConfig  m_c;
   FTMgmtConfig  m_mc;
   CFTPlanner   *m_planner;
   CFPRisk      *m_risk;
   CFPFilters   *m_filters;
   FTPend        m_pend[];
   FTPosState    m_pos[];
   FTTradeRecord m_done[];
   double        m_startBalance;
   double        m_realised;
   double        m_point;
   int           m_digits;
   bool          m_tester;
   long          m_lastMsc;
   int           m_lastK;
   double        m_atr;

   double        Slip(void) const { return m_c.slipPts * m_point; }

   void          PushRecord(const FTTradeRecord &r)
   {
      int n = ArraySize(m_done);
      ArrayResize(m_done, n + 1);
      m_done[n] = r;
   }
   void          RemovePend(const int i)
   {
      int n = ArraySize(m_pend);
      for(int j = i; j < n - 1; j++)
         m_pend[j] = m_pend[j + 1];
      ArrayResize(m_pend, n - 1);
   }
   void          RemovePos(const int i)
   {
      int n = ArraySize(m_pos);
      for(int j = i; j < n - 1; j++)
         m_pos[j] = m_pos[j + 1];
      ArrayResize(m_pos, n - 1);
   }

   void          Market(FTMarket &m, const MqlTick &raw)
   {
      MqlTick t;
      Stress(raw, t);
      m_planner.FillMarket(m, t.bid, t.ask, m_atr, (datetime)(raw.time_msc / 1000));
   }

   //--- a pending order or a market entry is filled at 'fill'
   void          Fill(const FTPlan &p, const double fill, const datetime now, const long msc, const double spreadPts)
   {
      FTPosState st;
      st.Reset();
      st.id = p.signalId;
      st.ticket = 0;
      st.signalId = p.signalId;
      st.setup = p.setup;
      st.grade = p.grade;
      st.dir = p.dir;
      st.entryTime = now;
      st.entryBar = FTBarOpen(now, m_c.tf);
      st.entryMsc = msc;
      st.plannedEntry = p.entry;
      st.entryPrice = NormalizeDouble(fill, m_digits);
      st.slInit = p.sl;
      st.sl = p.sl;
      st.tpInit = p.tp;
      st.tp = p.tp;
      st.rPrice = (st.entryPrice - st.slInit) * st.dir;
      if(st.rPrice <= 0.0)
         st.rPrice = p.rPrice;
      st.lotsInit = p.lots;
      st.lots = p.lots;
      st.riskMoney = p.riskMoney;
      st.riskTarget = p.riskTarget;
      st.spreadPts = spreadPts;
      int n = ArraySize(m_pos);
      ArrayResize(m_pos, n + 1);
      m_pos[n] = st;
      m_risk.AddEntry();
      Print(StringFormat("FT VIRT FILL sid %I64d %s %s lots %s @ %s (planned %s, slip %.1f pts) sl %s tp %s R %.1f pts risk %.2f",
                         st.signalId, FPSetupName((ENUM_FP_SIGNAL)st.setup), st.dir > 0 ? "BUY" : "SELL", FTNumTrim(st.lots),
                         DoubleToString(st.entryPrice, m_digits), DoubleToString(st.plannedEntry, m_digits),
                         (st.entryPrice - st.plannedEntry) * st.dir / m_point, DoubleToString(st.sl, m_digits),
                         DoubleToString(st.tp, m_digits), st.rPrice / m_point, st.riskMoney));
   }

   void          Unfilled(const int i, const string why, const datetime now)
   {
      FTTradeRecord r;
      int alive = FTBarsBetween(m_c.symbol, m_c.tf, FTBarOpen(m_pend[i].placed, m_c.tf), FTBarOpen(now, m_c.tf));
      CFTTradeLogic::FillUnfilled(m_pend[i], "VIRTUAL", now, alive, r);
      PushRecord(r);
      Print("FT VIRT: pending sid ", m_pend[i].plan.signalId, " cancelled (", why, ") -> EXPIRED");
      RemovePend(i);
   }

   void          Partial(const int k, const double vol, const double px)
   {
      double v = MathMin(vol, m_pos[k].lots);
      double money = FTMoney(m_c.symbol, m_pos[k].dir, v, m_pos[k].entryPrice, px);
      m_pos[k].realised += money;
      m_pos[k].exitPxVol += px * v;
      m_pos[k].exitVol += v;
      m_pos[k].lots = NormalizeDouble(m_pos[k].lots - v, 8);
      m_pos[k].partialDone = true;
      m_realised += money;
      m_risk.AddClosedMoney(money);
      Print(StringFormat("FT VIRT PARTIAL sid %I64d %s lots @ %s = %.2f", m_pos[k].signalId, FTNumTrim(v), DoubleToString(px, m_digits), money));
   }

   void          Close(const int k, const double px, const string reason, const datetime now)
   {
      double v = m_pos[k].lots;
      double money = FTMoney(m_c.symbol, m_pos[k].dir, v, m_pos[k].entryPrice, px);
      m_pos[k].realised += money;
      m_pos[k].exitPxVol += px * v;
      m_pos[k].exitVol += v;
      m_realised += money;
      m_risk.AddClosedMoney(money);
      double profit = m_pos[k].realised;
      m_risk.AddPositionResult(profit);
      double vwap = (m_pos[k].exitVol > 0.0) ? m_pos[k].exitPxVol / m_pos[k].exitVol : px;
      int held = FTBarsBetween(m_c.symbol, m_c.tf, m_pos[k].entryBar, FTBarOpen(now, m_c.tf));
      FTTradeRecord r;
      CFTTradeLogic::FillRecord(m_pos[k], "VIRTUAL", now, vwap, px, reason, profit, held, m_point, r);
      PushRecord(r);
      Print(StringFormat("FT VIRT CLOSED sid %I64d %s exit %s @ %s  P/L %.2f = %.2f R  MAE %.2f MFE %.2f",
                         r.signalId, FPSetupName((ENUM_FP_SIGNAL)r.setup), reason, DoubleToString(px, m_digits),
                         r.profitMoney, r.rMultiple, r.maeR, r.mfeR));
      if(reason == "SL" && r.riskMoney > 0.0)
         Print(StringFormat("FT RISKCHECK sid %I64d: full-stop loss %.2f vs riskMoney %.2f (%+.1f%%), riskTarget %.2f",
                            r.signalId, -r.profitMoney, r.riskMoney, (-r.profitMoney / r.riskMoney - 1.0) * 100.0, m_pos[k].riskTarget));
      RemovePos(k);
   }

   //--- apply a CFTTradeLogic action to the simulated book (fills at the stressed quote)
   void          Apply(const int k, const FTAction &a, const FTMarket &m)
   {
      int dir = m_pos[k].dir;
      double exitPx = (dir > 0) ? m.bid - Slip() : m.ask + Slip();
      if(a.close)
      {
         Close(k, exitPx, a.reason, m.now);
         return;
      }
      if(a.partialStage)
      {
         if(a.partialLots > 0.0)
            Partial(k, a.partialLots, exitPx);
         else
            Print("FT VIRT sid ", m_pos[k].signalId, ": partial close skipped (volume cannot be split within step/min) - break-even only");
         m_pos[k].partStage = true;
      }
      if(a.newSL > 0.0)
      {
         m_pos[k].sl = a.newSL;
         if(a.newStage > m_pos[k].slStage)
            m_pos[k].slStage = a.newStage;
      }
   }

   void          ProcessTick(const MqlTick &raw)
   {
      FTMarket m;
      Market(m, raw);
      long msc = raw.time_msc;
      double vb = m.bid;
      double va = m.ask;
      double slip = Slip();
      //--- pending entries: trigger first (the broker would fill before the EA reacts), then invalidation / live filters
      bool   liveChecked = false;
      bool   liveOk = true;
      string why = "";
      for(int i = ArraySize(m_pend) - 1; i >= 0; i--)
      {
         if(msc <= m_pend[i].placedMsc)
            continue;
         int    dir = m_pend[i].plan.dir;
         double e = m_pend[i].plan.entry;
         double fill = 0.0;
         if(m_pend[i].plan.kind == FP_ORD_STOP)
         {
            if(dir > 0 && va >= e)
               fill = va + slip;
            else if(dir < 0 && vb <= e)
               fill = vb - slip;
         }
         else if(m_pend[i].plan.kind == FP_ORD_LIMIT)
         {
            if((dir > 0 && va <= e) || (dir < 0 && vb >= e))
               fill = e;
         }
         if(fill > 0.0)
         {
            FTPlan p = m_pend[i].plan;
            RemovePend(i);
            Fill(p, fill, m.now, msc, (va - vb) / m_point);
            continue;
         }
         double inv = m_pend[i].plan.invalidPrice;
         if(inv > 0.0 && ((dir > 0 && raw.bid < inv) || (dir < 0 && raw.bid > inv)))
         {
            Unfilled(i, StringFormat("INVALID bid %s vs %s", DoubleToString(raw.bid, m_digits), DoubleToString(inv, m_digits)), m.now);
            continue;
         }
         if(!liveChecked)
         {
            liveOk = m_filters.CheckLive(m.now, (m_atr > 0.0) ? m_atr : m_pend[i].plan.atr, why);
            liveChecked = true;
         }
         if(!liveOk)
            Unfilled(i, "LIVE_FILTER:" + why, m.now);
      }
      //--- positions: broker-side SL/TP first, then the shared management decision
      for(int k = ArraySize(m_pos) - 1; k >= 0; k--)
      {
         if(msc <= m_pos[k].entryMsc)
            continue;
         CFTTradeLogic::Excursion(m_pos[k], vb, va);
         int dir = m_pos[k].dir;
         double sl = m_pos[k].sl;
         double tp = m_pos[k].tp;
         if(dir > 0)
         {
            if(sl > 0.0 && vb <= sl)
            {
               Close(k, vb - slip, CFTTradeLogic::StopReason(m_pos[k]), m.now);
               continue;
            }
            if(tp > 0.0 && vb >= tp)
            {
               Close(k, tp, "TP", m.now);
               continue;
            }
         }
         else
         {
            if(sl > 0.0 && va >= sl)
            {
               Close(k, va + slip, CFTTradeLogic::StopReason(m_pos[k]), m.now);
               continue;
            }
            if(tp > 0.0 && va <= tp)
            {
               Close(k, tp, "TP", m.now);
               continue;
            }
         }
         FTAction a;
         if(CFTTradeLogic::DecideTick(m_mc, m_pos[k], m, a))
            Apply(k, a, m);
      }
   }

public:
                 CFPVirtual(void)
   {
      m_planner = NULL; m_risk = NULL; m_filters = NULL; m_startBalance = 0.0; m_realised = 0.0;
      m_point = 0.0; m_digits = 0; m_tester = false; m_lastMsc = 0; m_lastK = 0; m_atr = 0.0;
   }

   bool          Init(const FTVirtConfig &c, const FTMgmtConfig &mc, CFTPlanner *planner, CFPRisk *risk, CFPFilters *filters)
   {
      m_c = c;
      m_mc = mc;
      m_planner = planner;
      m_risk = risk;
      m_filters = filters;
      m_point = SymbolInfoDouble(m_c.symbol, SYMBOL_POINT);
      m_digits = (int)SymbolInfoInteger(m_c.symbol, SYMBOL_DIGITS);
      m_tester = (MQLInfoInteger(MQL_TESTER) != 0);
      m_startBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      m_realised = 0.0;
      m_lastMsc = 0;
      m_lastK = 0;
      ArrayResize(m_pend, 0);
      ArrayResize(m_pos, 0);
      ArrayResize(m_done, 0);
      return (m_planner != NULL && m_risk != NULL && m_filters != NULL && m_point > 0.0);
   }

   void          Describe(void) const
   {
      Print(StringFormat("FT VIRT: virtual balance %.2f, spread x%.2f, slippage %d pts per fill, %s",
                         m_startBalance, m_c.spreadMult, m_c.slipPts,
                         m_tester ? "every tester tick" : "every quote tick replayed with CopyTicks"));
   }

   //--- stressed quote: bid unchanged, ask = bid + spread * InpStressSpreadMult
   void          Stress(const MqlTick &raw, MqlTick &out) const
   {
      out = raw;
      double spr = raw.ask - raw.bid;
      if(spr < 0.0)
         spr = 0.0;
      out.ask = raw.bid + spr * m_c.spreadMult;
   }

   double        Floating(const MqlTick &raw) const
   {
      MqlTick t;
      Stress(raw, t);
      double f = 0.0;
      int n = ArraySize(m_pos);
      for(int k = 0; k < n; k++)
         f += FTMoney(m_c.symbol, m_pos[k].dir, m_pos[k].lots, m_pos[k].entryPrice, (m_pos[k].dir > 0) ? t.bid : t.ask);
      return f;
   }
   double        Equity(const MqlTick &raw) const     { return m_startBalance + m_realised + Floating(raw); }
   double        FreeMargin(const MqlTick &raw) const
   {
      double used = 0.0;
      int n = ArraySize(m_pos);
      for(int k = 0; k < n; k++)
      {
         double mg = 0.0;
         if(OrderCalcMargin(m_pos[k].dir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, m_c.symbol, m_pos[k].lots, m_pos[k].entryPrice, mg))
            used += mg;
      }
      return Equity(raw) - used;
   }
   double        Realised(void) const    { return m_realised; }
   int           PendingCount(void) const { return ArraySize(m_pend); }
   int           OpenCount(void) const   { return ArraySize(m_pos); }
   bool          Busy(const int maxPositions) const
   {
      return (ArraySize(m_pend) + ArraySize(m_pos) >= maxPositions);
   }

   //--- plan was built by CFTPlanner from the STRESSED quote of 'raw'
   bool          Submit(const FPSignal &sig, const long sid, const FTPlan &plan, const MqlTick &raw)
   {
      if(sig.dir != plan.dir || sid != plan.signalId)
         return false;
      MqlTick t;
      Stress(raw, t);
      datetime now = (datetime)(raw.time_msc / 1000);
      if(plan.kind == FP_ORD_MARKET)
      {
         double fill = (plan.dir > 0) ? t.ask + Slip() : t.bid - Slip();
         Fill(plan, fill, now, raw.time_msc, (t.ask - t.bid) / m_point);
         return true;
      }
      FTPend p;
      p.Reset();
      p.ticket = 0;
      p.market = false;
      p.plan = plan;
      p.placed = now;
      p.placedMsc = raw.time_msc;
      int n = ArraySize(m_pend);
      ArrayResize(m_pend, n + 1);
      m_pend[n] = p;
      Print(StringFormat("FT VIRT PLACED sid %I64d %s %s %s @ %s sl %s tp %s lots %s valid %d bars inv %s",
                         sid, FPSetupName((ENUM_FP_SIGNAL)plan.setup), plan.dir > 0 ? "BUY" : "SELL", FTKindName(plan.kind),
                         DoubleToString(plan.entry, m_digits), DoubleToString(plan.sl, m_digits), DoubleToString(plan.tp, m_digits),
                         FTNumTrim(plan.lots), plan.validBars, DoubleToString(plan.invalidPrice, m_digits)));
      return true;
   }

   //+---------------------------------------------------------------+
   //| Tick by tick. Tester: OnTick sees every tick. Live: every     |
   //| quote tick since the last processed one is replayed           |
   //| (CopyTicks COPY_TICKS_INFO, same-msc de-duplication).         |
   //+---------------------------------------------------------------+
   void          OnTick(const MqlTick &cur, const double atr)
   {
      m_atr = atr;
      bool busy = (ArraySize(m_pend) + ArraySize(m_pos) > 0);
      if(m_tester)
      {
         if(busy)
            ProcessTick(cur);                    // the tester calls OnTick for every tick
         return;
      }
      if(m_lastMsc == 0 || !busy)
      {
         //--- live, nothing to simulate: only keep our place in the tick stream
         if(cur.time_msc != m_lastMsc)
         {
            m_lastMsc = cur.time_msc;
            m_lastK = 1;
         }
         else
            m_lastK++;
         return;
      }
      MqlTick arr[];
      int n = CopyTicks(m_c.symbol, arr, COPY_TICKS_INFO, (ulong)m_lastMsc, 2000);
      if(n <= 0)
      {
         if(cur.time_msc > m_lastMsc)
         {
            ProcessTick(cur);
            m_lastMsc = cur.time_msc;
            m_lastK = 1;
         }
         return;
      }
      int skip = 0;
      while(skip < n && arr[skip].time_msc == m_lastMsc && skip < m_lastK)
         skip++;
      for(int i = skip; i < n; i++)
         ProcessTick(arr[i]);
      long last = arr[n - 1].time_msc;
      int  k = 0;
      for(int i = n - 1; i >= 0 && arr[i].time_msc == last; i--)
         k++;
      m_lastMsc = last;
      m_lastK = k;
   }

   //--- closed bar T: pending expiry/invalidation, time stop, opposite grade A, BAR trailing
   void          OnBarClosed(const datetime T, const double barLow, const double barHigh, const bool longA, const bool shortA,
                             const MqlTick &cur, const double atr)
   {
      m_atr = atr;
      FTMarket m;
      Market(m, cur);
      for(int i = ArraySize(m_pend) - 1; i >= 0; i--)
      {
         int    dir = m_pend[i].plan.dir;
         double inv = m_pend[i].plan.invalidPrice;
         bool   fired = (T > m_pend[i].plan.signalBar && inv > 0.0 &&
                         ((dir > 0 && barLow > 0.0 && barLow < inv) || (dir < 0 && barHigh > 0.0 && barHigh > inv)));
         if(fired)
            Unfilled(i, "INVALID_BAR", m.now);
         else if(FTBarsBetween(m_c.symbol, m_c.tf, m_pend[i].plan.signalBar, T) >= m_pend[i].plan.validBars)
            Unfilled(i, StringFormat("EXPIRY %d bars", m_pend[i].plan.validBars), m.now);
      }
      double spr = m.ask - m.bid;
      for(int k = ArraySize(m_pos) - 1; k >= 0; k--)
      {
         //--- only bars at/after the entry bar count (same rule as LIVE)
         bool   held = (T >= m_pos[k].entryBar);
         int    done = held ? FTBarsBetween(m_c.symbol, m_c.tf, m_pos[k].entryBar, T) + 1 : 0;
         double tl = (barLow > 0.0) ? m_planner.LongExit(barLow, spr) : 0.0;
         double ts = (barHigh > 0.0) ? m_planner.ShortExit(barHigh, spr) : 0.0;
         bool   opp = held && ((m_pos[k].dir > 0) ? shortA : longA);
         FTAction a;
         if(CFTTradeLogic::DecideBar(m_mc, m_pos[k], m, done, tl, ts, opp, a))
            Apply(k, a, m);
      }
   }

   void          CloseAll(const string reason, const MqlTick &cur)
   {
      FTMarket m;
      Market(m, cur);
      for(int k = ArraySize(m_pos) - 1; k >= 0; k--)
         Close(k, (m_pos[k].dir > 0) ? m.bid - Slip() : m.ask + Slip(), reason, m.now);
   }

   void          CancelAll(const string reason, const MqlTick &cur)
   {
      datetime now = (datetime)(cur.time_msc / 1000);
      for(int i = ArraySize(m_pend) - 1; i >= 0; i--)
         Unfilled(i, reason, now);
   }

   bool          PopRecord(FTTradeRecord &r)
   {
      int n = ArraySize(m_done);
      if(n == 0)
         return false;
      r = m_done[0];
      for(int i = 0; i < n - 1; i++)
         m_done[i] = m_done[i + 1];
      ArrayResize(m_done, n - 1);
      return true;
   }

   //--- EA stop: virtual trades are memory-only and are discarded (not journaled)
   void          Discard(void)
   {
      int np = ArraySize(m_pos);
      int no = ArraySize(m_pend);
      if(np + no > 0)
         Print("FT VIRT: ", np, " open and ", no, " pending virtual trade(s) discarded at EA stop (memory only, not journaled)");
      ArrayResize(m_pos, 0);
      ArrayResize(m_pend, 0);
   }
};
//+------------------------------------------------------------------+
