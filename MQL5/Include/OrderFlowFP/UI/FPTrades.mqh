//+------------------------------------------------------------------+
//| FPTrades.mqh - OrderFlowFP UI: trade overlay data (READ-ONLY).     |
//| Polls positions, pending orders and history deals of the chart     |
//| symbol (optionally one magic) so the renderer can draw them.       |
//| No OrderSend / CTrade / any trading call (02 §2).                  |
//+------------------------------------------------------------------+
#ifndef ORDERFLOWFP_UI_FPTRADES_MQH
#define ORDERFLOWFP_UI_FPTRADES_MQH

#define FPT_ENTRY 0
#define FPT_SL    1
#define FPT_TP    2

struct FPTradeLine
{
   int      kind;       // FPT_ENTRY / FPT_SL / FPT_TP
   bool     pending;    // pending order -> dashed
   int      dir;        // +1 buy, -1 sell
   double   price;
   string   tag;        // price-scale tag: "BUY 0.05", "SL", "TP", "BUY STOP 0.05"
   string   info;       // label at the left end of the line
   double   profit;     // floating P/L (positions)
};

struct FPTradeMark
{
   ulong    posId;
   int      dir;        // +1 buy, -1 sell
   datetime tIn;
   double   pIn;
   datetime tOut;       // 0 = still open
   double   pOut;
   double   volume;
   double   profit;     // profit + swap + commission of the exit deal
};

class CFPTrades
{
private:
   string            m_sym;
   long              m_magic;          // -1 = all
   int               m_digits;
   ulong             m_lastPollMs;
   ulong             m_sig;
   bool              m_hasPositions;

   bool              MagicOk(const long magic) const { return (m_magic < 0 || magic == m_magic); }
   static ulong      Mix(const ulong h, const ulong v) { return (h ^ (v + 0x9E3779B97F4A7C15 + (h << 6) + (h >> 2))); }
   static ulong      MixD(const ulong h, const double v) { return Mix(h, (ulong)(long)MathRound(v * 100000.0)); }

   static string     OrderTypeText(const ENUM_ORDER_TYPE t)
     {
      switch(t)
        {
         case ORDER_TYPE_BUY:             return "BUY";
         case ORDER_TYPE_SELL:            return "SELL";
         case ORDER_TYPE_BUY_LIMIT:       return "BUY LIMIT";
         case ORDER_TYPE_SELL_LIMIT:      return "SELL LIMIT";
         case ORDER_TYPE_BUY_STOP:        return "BUY STOP";
         case ORDER_TYPE_SELL_STOP:       return "SELL STOP";
         case ORDER_TYPE_BUY_STOP_LIMIT:  return "BUY STOP LMT";
         case ORDER_TYPE_SELL_STOP_LIMIT: return "SELL STOP LMT";
         default:                         return "ORDER";
        }
     }
   static int        OrderDir(const ENUM_ORDER_TYPE t)
     {
      if(t == ORDER_TYPE_BUY || t == ORDER_TYPE_BUY_LIMIT || t == ORDER_TYPE_BUY_STOP || t == ORDER_TYPE_BUY_STOP_LIMIT)
         return 1;
      return -1;
     }
   string            Lots(const double v) const
     {
      double step = SymbolInfoDouble(m_sym, SYMBOL_VOLUME_STEP);
      int d = 2;
      if(step >= 1.0)
         d = 0;
      else
         if(step >= 0.1)
            d = 1;
      return DoubleToString(v, d);
     }
   void              AddLine(const int kind, const bool pending, const int dir, const double price,
                             const string tag, const string info, const double profit)
     {
      if(price <= 0.0)
         return;
      int n = nLines;
      ArrayResize(lines, n + 1, 16);
      lines[n].kind = kind;
      lines[n].pending = pending;
      lines[n].dir = dir;
      lines[n].price = price;
      lines[n].tag = tag;
      lines[n].info = info;
      lines[n].profit = profit;
      nLines = n + 1;
     }

   //--- signature of everything that changes the drawing except floating P/L
   ulong             Signature(const datetime from)
     {
      ulong h = 1469598103934665603;
      int np = PositionsTotal();
      for(int i = 0; i < np; i++)
        {
         ulong tk = PositionGetTicket(i);
         if(tk == 0 || PositionGetString(POSITION_SYMBOL) != m_sym || !MagicOk(PositionGetInteger(POSITION_MAGIC)))
            continue;
         h = Mix(h, tk);
         h = MixD(h, PositionGetDouble(POSITION_VOLUME));
         h = MixD(h, PositionGetDouble(POSITION_SL));
         h = MixD(h, PositionGetDouble(POSITION_TP));
         h = MixD(h, PositionGetDouble(POSITION_PRICE_OPEN));
        }
      int no = OrdersTotal();
      for(int i = 0; i < no; i++)
        {
         ulong tk = OrderGetTicket(i);
         if(tk == 0 || OrderGetString(ORDER_SYMBOL) != m_sym || !MagicOk(OrderGetInteger(ORDER_MAGIC)))
            continue;
         h = Mix(h, tk);
         h = MixD(h, OrderGetDouble(ORDER_VOLUME_CURRENT));
         h = MixD(h, OrderGetDouble(ORDER_PRICE_OPEN));
         h = MixD(h, OrderGetDouble(ORDER_SL));
         h = MixD(h, OrderGetDouble(ORDER_TP));
        }
      if(HistorySelect(from, TimeTradeServer() + 86400))
        {
         int nd = HistoryDealsTotal();
         h = Mix(h, (ulong)nd);
         if(nd > 0)
            h = Mix(h, HistoryDealGetTicket(nd - 1));
        }
      h = Mix(h, (ulong)from);
      return h;
     }

   void              Rebuild(const datetime from)
     {
      nLines = 0;
      ArrayResize(lines, 0, 16);
      nMarks = 0;
      ArrayResize(marks, 0, 16);
      m_hasPositions = false;
      //--- open positions: entry / SL / TP lines
      int np = PositionsTotal();
      for(int i = 0; i < np; i++)
        {
         ulong tk = PositionGetTicket(i);
         if(tk == 0 || PositionGetString(POSITION_SYMBOL) != m_sym || !MagicOk(PositionGetInteger(POSITION_MAGIC)))
            continue;
         m_hasPositions = true;
         int dir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
         double vol = PositionGetDouble(POSITION_VOLUME);
         double po = PositionGetDouble(POSITION_PRICE_OPEN);
         double pl = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         string side = (dir > 0) ? "BUY" : "SELL";
         string info = side + " " + Lots(vol) + " @ " + DoubleToString(po, m_digits) + "   P/L " +
                       ((pl >= 0.0) ? "+" : "") + DoubleToString(pl, 2) + "   #" + IntegerToString((long)tk);
         AddLine(FPT_ENTRY, false, dir, po, side + " " + Lots(vol), info, pl);
         double sl = PositionGetDouble(POSITION_SL), tp = PositionGetDouble(POSITION_TP);
         if(sl > 0.0)
            AddLine(FPT_SL, false, dir, sl, "SL", "SL " + DoubleToString(sl, m_digits) + "  #" + IntegerToString((long)tk), 0.0);
         if(tp > 0.0)
            AddLine(FPT_TP, false, dir, tp, "TP", "TP " + DoubleToString(tp, m_digits) + "  #" + IntegerToString((long)tk), 0.0);
         //--- entry marker of the open position
         long pid = PositionGetInteger(POSITION_IDENTIFIER);
         datetime tIn = (datetime)PositionGetInteger(POSITION_TIME);
         int k = nMarks;
         ArrayResize(marks, k + 1, 16);
         marks[k].posId = (ulong)pid;
         marks[k].dir = dir;
         marks[k].tIn = tIn;
         marks[k].pIn = po;
         marks[k].tOut = 0;
         marks[k].pOut = 0.0;
         marks[k].volume = vol;
         marks[k].profit = pl;
         nMarks = k + 1;
        }
      //--- pending orders: dashed entry / SL / TP lines
      int no = OrdersTotal();
      for(int i = 0; i < no; i++)
        {
         ulong tk = OrderGetTicket(i);
         if(tk == 0 || OrderGetString(ORDER_SYMBOL) != m_sym || !MagicOk(OrderGetInteger(ORDER_MAGIC)))
            continue;
         ENUM_ORDER_TYPE ot = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
         if(ot == ORDER_TYPE_BUY || ot == ORDER_TYPE_SELL)
            continue;   // market orders in flight
         int dir = OrderDir(ot);
         double vol = OrderGetDouble(ORDER_VOLUME_CURRENT);
         double po = OrderGetDouble(ORDER_PRICE_OPEN);
         string tx = OrderTypeText(ot) + " " + Lots(vol);
         AddLine(FPT_ENTRY, true, dir, po, tx, tx + " @ " + DoubleToString(po, m_digits) + "   #" + IntegerToString((long)tk), 0.0);
         double sl = OrderGetDouble(ORDER_SL), tp = OrderGetDouble(ORDER_TP);
         if(sl > 0.0)
            AddLine(FPT_SL, true, dir, sl, "SL", "SL " + DoubleToString(sl, m_digits) + "  #" + IntegerToString((long)tk), 0.0);
         if(tp > 0.0)
            AddLine(FPT_TP, true, dir, tp, "TP", "TP " + DoubleToString(tp, m_digits) + "  #" + IntegerToString((long)tk), 0.0);
        }
      //--- closed trades from the deal history of the window
      if(!HistorySelect(from, TimeTradeServer() + 86400))
         return;
      int nd = HistoryDealsTotal();
      //--- entries first (position id -> entry)
      ulong    eId[];
      int      eDir[];
      datetime eT[];
      double   eP[];
      double   eV[];
      int ne = 0;
      for(int i = 0; i < nd; i++)
        {
         ulong dt = HistoryDealGetTicket(i);
         if(dt == 0 || HistoryDealGetString(dt, DEAL_SYMBOL) != m_sym)
            continue;
         ENUM_DEAL_TYPE ty = (ENUM_DEAL_TYPE)HistoryDealGetInteger(dt, DEAL_TYPE);
         if(ty != DEAL_TYPE_BUY && ty != DEAL_TYPE_SELL)
            continue;
         ENUM_DEAL_ENTRY en = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dt, DEAL_ENTRY);
         ulong pid = (ulong)HistoryDealGetInteger(dt, DEAL_POSITION_ID);
         int dir = (ty == DEAL_TYPE_BUY) ? 1 : -1;
         datetime t = (datetime)HistoryDealGetInteger(dt, DEAL_TIME);
         double pr = HistoryDealGetDouble(dt, DEAL_PRICE);
         if(en == DEAL_ENTRY_IN)
           {
            if(!MagicOk(HistoryDealGetInteger(dt, DEAL_MAGIC)))
               continue;
            ArrayResize(eId, ne + 1, 16);
            ArrayResize(eDir, ne + 1, 16);
            ArrayResize(eT, ne + 1, 16);
            ArrayResize(eP, ne + 1, 16);
            ArrayResize(eV, ne + 1, 16);
            eId[ne] = pid;
            eDir[ne] = dir;
            eT[ne] = t;
            eP[ne] = pr;
            eV[ne] = HistoryDealGetDouble(dt, DEAL_VOLUME);
            ne++;
            continue;
           }
         if(en != DEAL_ENTRY_OUT && en != DEAL_ENTRY_OUT_BY && en != DEAL_ENTRY_INOUT)
            continue;
         //--- exit: find the latest entry of this position
         int ei = -1;
         for(int j = ne - 1; j >= 0; j--)
            if(eId[j] == pid)
              {
               ei = j;
               break;
              }
         if(ei < 0)
            continue;
         double pl = HistoryDealGetDouble(dt, DEAL_PROFIT) + HistoryDealGetDouble(dt, DEAL_SWAP) + HistoryDealGetDouble(dt, DEAL_COMMISSION);
         int k = nMarks;
         ArrayResize(marks, k + 1, 16);
         marks[k].posId = pid;
         marks[k].dir = eDir[ei];
         marks[k].tIn = eT[ei];
         marks[k].pIn = eP[ei];
         marks[k].tOut = t;
         marks[k].pOut = pr;
         marks[k].volume = HistoryDealGetDouble(dt, DEAL_VOLUME);
         marks[k].profit = pl;
         nMarks = k + 1;
         if(en == DEAL_ENTRY_INOUT)
           {
            //--- netting reversal: the same deal opens the opposite position
            eDir[ei] = dir;
            eT[ei] = t;
            eP[ei] = pr;
           }
        }
     }

public:
   FPTradeLine       lines[];
   int               nLines;
   FPTradeMark       marks[];
   int               nMarks;

                     CFPTrades(void) : m_magic(-1), m_digits(5), m_lastPollMs(0), m_sig(0), m_hasPositions(false), nLines(0), nMarks(0) {}

   void              Init(const string sym, const long magic)
     {
      m_sym = sym;
      m_magic = magic;
      m_digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      m_lastPollMs = 0;
      m_sig = 0;
      nLines = 0;
      nMarks = 0;
     }

   //--- at most every 500 ms; true when the drawing must be refreshed
   bool              Poll(const datetime from, const bool force)
     {
      ulong now = GetTickCount64();
      if(!force && m_lastPollMs != 0 && now - m_lastPollMs < 500)
         return false;
      m_lastPollMs = now;
      ulong sg = Signature(from);
      if(sg != m_sig || m_hasPositions || force)
        {
         m_sig = sg;
         Rebuild(from);
         return true;
        }
      return false;
     }
};

#endif // ORDERFLOWFP_UI_FPTRADES_MQH
//+------------------------------------------------------------------+
