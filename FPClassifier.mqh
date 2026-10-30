//+------------------------------------------------------------------+
//| FPClassifier.mqh - aggressor classification cascade (02 §5.3)     |
//| Internal engine helper class (its API is not part of contract v1).|
//| Ticks must be fed strictly in time order. The state (previous     |
//| quote, previous mid, previous trade price, previous side) is      |
//| updated by EVERY tick, counted or not, so seeding = classifying   |
//| the seed ticks without accumulating their results.                |
//+------------------------------------------------------------------+
#ifndef ORDERFLOWFP_FPCLASSIFIER_MQH
#define ORDERFLOWFP_FPCLASSIFIER_MQH

#include "FPTypes.mqh"

class CFPClassifier
{
private:
   ENUM_FP_SOURCE      m_source;
   ENUM_FP_QUOTE_PRICE m_quotePrice;
   bool                m_hasMid;
   double              m_prevMid;
   bool                m_hasTrade;
   double              m_prevTradePrice;
   bool                m_hasQuote;
   double              m_prevBid;
   double              m_prevAsk;
   int                 m_prevSide;

   int               QuoteRule(const double px) const
     {
      if(!m_hasQuote)
         return 0;
      if(px >= m_prevAsk)
         return 1;
      if(px <= m_prevBid)
         return -1;
      return 0;
     }
   int               TickRule(const double px) const
     {
      if(!m_hasTrade)
         return m_prevSide;
      if(px > m_prevTradePrice)
         return 1;
      if(px < m_prevTradePrice)
         return -1;
      return m_prevSide;
     }

public:
                     CFPClassifier(void) : m_source(FP_SRC_QUOTE_TICKS), m_quotePrice(FP_QP_BID)
     {
      Reset();
     }
   void              Setup(const ENUM_FP_SOURCE source, const ENUM_FP_QUOTE_PRICE quotePrice)
     {
      m_source     = source;
      m_quotePrice = quotePrice;
      Reset();
     }
   //--- back to the unseeded state
   void              Reset(void)
     {
      m_hasMid = false;   m_prevMid = 0.0;
      m_hasTrade = false; m_prevTradePrice = 0.0;
      m_hasQuote = false; m_prevBid = 0.0; m_prevAsk = 0.0;
      m_prevSide = 0;
     }
   ENUM_FP_SOURCE    Source(void) const { return m_source; }

   //--- a trade tick is recognised ONLY by its flags (never by volume / last)
   static bool       IsTradeTick(const MqlTick &t)
     {
      return ((t.flags & (TICK_FLAG_LAST | TICK_FLAG_VOLUME | TICK_FLAG_BUY | TICK_FLAG_SELL)) != 0);
     }
   static double     TradeSize(const MqlTick &t)
     {
      return (t.volume_real > 0.0) ? t.volume_real : (double)t.volume;
     }
   static double     MidOf(const MqlTick &t)
     {
      if(t.bid > 0.0 && t.ask > 0.0)
         return (t.bid + t.ask) * 0.5;
      if(t.bid > 0.0)
         return t.bid;
      return t.ask;
     }

   //+---------------------------------------------------------------+
   //| Classify one tick. Returns true when the tick is COUNTED, with |
   //| its row price, size and side (+1 buy, -1 sell, 0 split 50/50). |
   //| The state is always updated.                                   |
   //+---------------------------------------------------------------+
   bool              Classify(const MqlTick &t, double &price, double &size, int &side)
     {
      bool counted = false;
      price = 0.0;
      size  = 0.0;
      side  = 0;
      if(m_source == FP_SRC_QUOTE_TICKS)
        {
         if((t.flags & (TICK_FLAG_BID | TICK_FLAG_ASK)) != 0)
           {
            double mid = MidOf(t);
            double px  = (m_quotePrice == FP_QP_MID) ? mid : t.bid;
            if(px > 0.0 && mid > 0.0)
              {
               if(m_hasMid)
                 {
                  if(mid > m_prevMid)
                     side = 1;
                  else
                     if(mid < m_prevMid)
                        side = -1;
                     else
                        side = m_prevSide;
                 }
               else
                  side = m_prevSide;
               price   = px;
               size    = 1.0;
               counted = true;
               m_prevMid = mid;
               m_hasMid  = true;
              }
           }
        }
      else
         if(IsTradeTick(t))
           {
            double sz = TradeSize(t);
            if(t.last > 0.0 && sz > 0.0)
              {
               if(m_source == FP_SRC_EXCHANGE_FLAGS)
                 {
                  bool fb = ((t.flags & TICK_FLAG_BUY) != 0);
                  bool fs = ((t.flags & TICK_FLAG_SELL) != 0);
                  if(fb && !fs)
                     side = 1;
                  else
                     if(fs && !fb)
                        side = -1;
                     else
                       {
                        side = QuoteRule(t.last);
                        if(side == 0)
                           side = TickRule(t.last);
                       }
                 }
               else // FP_SRC_TRADE_TICKS
                 {
                  side = QuoteRule(t.last);
                  if(side == 0)
                     side = TickRule(t.last);
                 }
               price   = t.last;
               size    = sz;
               counted = true;
               m_prevTradePrice = t.last;
               m_hasTrade       = true;
              }
           }
      if(counted && side != 0)
         m_prevSide = side;
      //--- the quote prevailing BEFORE the next tick = this tick's bid/ask
      if(t.bid > 0.0 && t.ask > 0.0)
        {
         m_prevBid  = t.bid;
         m_prevAsk  = t.ask;
         m_hasQuote = true;
        }
      return counted;
     }
};

#endif // ORDERFLOWFP_FPCLASSIFIER_MQH
//+------------------------------------------------------------------+
