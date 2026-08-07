//+------------------------------------------------------------------+
//|                          30-Min Session Breakout EA.mq5           |
//|  Buy Stop above candle High / Sell Stop below candle Low          |
//|  at a chosen candle's close time. OCO: fill cancels the other.    |
//+------------------------------------------------------------------+
#property copyright "Custom EA"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//──────────────────────────────
// Inputs
//──────────────────────────────
input group "Strategy Inputs"
input ENUM_TIMEFRAMES InpTimeframe    = PERIOD_M30;   // Strategy Timeframe
input int             InpCandleHour   = 19;           // Candle Close Hour   (0-23, broker/server time)
input int             InpCandleMinute = 30;           // Candle Close Minute (0-59, broker/server time)
input double          InpRR           = 3.0;          // Risk Reward Ratio
input double          InpLotSize      = 0.10;         // Lot Size (fixed — sizing left to you, no $-risk calc)
input ulong           InpMagic        = 20260807;     // Magic Number

//──────────────────────────────
// Globals
//──────────────────────────────
datetime lastBarTime   = 0;
ulong    buyStopTicket  = 0;
ulong    sellStopTicket = 0;
int      targetOpenHour   = -1;
int      targetOpenMinute = -1;

//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagic);

   // Convert the candle's CLOSE time to its OPEN time, same idea as the Pine version
   int tfMinutes      = PeriodSeconds(InpTimeframe) / 60;
   int closeTotalMin  = InpCandleHour * 60 + InpCandleMinute;
   int openTotalMin   = ((closeTotalMin - tfMinutes) % 1440 + 1440) % 1440;
   targetOpenHour      = openTotalMin / 60;
   targetOpenMinute    = openTotalMin % 60;

   PrintFormat("Target candle OPEN time = %02d:%02d (server time), close time = %02d:%02d",
               targetOpenHour, targetOpenMinute, InpCandleHour, InpCandleMinute);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   datetime currentBarTime = iTime(_Symbol, InpTimeframe, 0);
   if(currentBarTime != lastBarTime)
     {
      lastBarTime = currentBarTime;
      CheckTriggerCandle();
     }
  }

//+------------------------------------------------------------------+
//| Called once per new bar — checks if the bar that JUST CLOSED     |
//| (index 1) is our target candle, and if so places the bracket.    |
//+------------------------------------------------------------------+
void CheckTriggerCandle()
  {
   datetime closedBarOpenTime = iTime(_Symbol, InpTimeframe, 1);
   MqlDateTime dt;
   TimeToStruct(closedBarOpenTime, dt);

   if(dt.hour == targetOpenHour && dt.min == targetOpenMinute)
     {
      double high  = iHigh(_Symbol, InpTimeframe, 1);
      double low   = iLow(_Symbol, InpTimeframe, 1);
      double risk  = high - low;

      if(risk <= 0)
        {
         Print("Invalid candle range (High <= Low), skipping.");
         return;
        }

      // Cancel any leftover pending orders from a previous unfilled setup
      DeleteExistingPendingOrders();

      double point       = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      int    digits       = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      double buyPrice     = NormalizeDouble(high, digits);
      double sellPrice    = NormalizeDouble(low, digits);
      double buySL        = NormalizeDouble(low, digits);
      double buyTP        = NormalizeDouble(high + risk * InpRR, digits);
      double sellSL        = NormalizeDouble(high, digits);
      double sellTP        = NormalizeDouble(low - risk * InpRR, digits);

      // Respect broker's minimum stop distance
      double minStopPts = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

      if(MathAbs(buyPrice - ask) < minStopPts || MathAbs(sellPrice - bid) < minStopPts)
        {
         Print("Entry too close to current price for broker's stop level, skipping this setup.");
         return;
        }

      // Place Buy Stop
      if(trade.BuyStop(InpLotSize, buyPrice, _Symbol, buySL, buyTP, ORDER_TIME_GTC, 0,
                        "BreakoutBuyStop"))
        {
         buyStopTicket = trade.ResultOrder();
         PrintFormat("Buy Stop placed @ %.5f  SL=%.5f  TP=%.5f  ticket=%I64u",
                     buyPrice, buySL, buyTP, buyStopTicket);
        }
      else
         Print("Buy Stop failed: ", trade.ResultRetcodeDescription());

      // Place Sell Stop
      if(trade.SellStop(InpLotSize, sellPrice, _Symbol, sellSL, sellTP, ORDER_TIME_GTC, 0,
                         "BreakoutSellStop"))
        {
         sellStopTicket = trade.ResultOrder();
         PrintFormat("Sell Stop placed @ %.5f  SL=%.5f  TP=%.5f  ticket=%I64u",
                     sellPrice, sellSL, sellTP, sellStopTicket);
        }
      else
         Print("Sell Stop failed: ", trade.ResultRetcodeDescription());

      DrawLevelLines(high, low);
     }
  }

//+------------------------------------------------------------------+
//| Delete any still-pending orders placed by this EA (this symbol)  |
//+------------------------------------------------------------------+
void DeleteExistingPendingOrders()
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC) != (long)InpMagic) continue;

      trade.OrderDelete(ticket);
     }
   buyStopTicket  = 0;
   sellStopTicket = 0;
  }

//+------------------------------------------------------------------+
//| OCO logic: when one stop order fills (becomes a position),       |
//| delete the other one immediately.                                |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                         const MqlTradeRequest      &request,
                         const MqlTradeResult       &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;

   if(!HistoryDealSelect(trans.deal))
      return;

   long dealMagic = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
   long dealEntry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);

   if(dealMagic != (long)InpMagic || dealEntry != DEAL_ENTRY_IN)
      return;

   ulong filledOrderTicket = HistoryDealGetInteger(trans.deal, DEAL_ORDER);

   if(filledOrderTicket == buyStopTicket && sellStopTicket != 0)
     {
      if(trade.OrderDelete(sellStopTicket))
         PrintFormat("Buy Stop filled — cancelled opposite Sell Stop ticket=%I64u", sellStopTicket);
      sellStopTicket = 0;
      buyStopTicket   = 0;
     }
   else if(filledOrderTicket == sellStopTicket && buyStopTicket != 0)
     {
      if(trade.OrderDelete(buyStopTicket))
         PrintFormat("Sell Stop filled — cancelled opposite Buy Stop ticket=%I64u", buyStopTicket);
      buyStopTicket   = 0;
      sellStopTicket = 0;
     }
  }

//+------------------------------------------------------------------+
//| Simple visual: draw High/Low level lines on chart                |
//+------------------------------------------------------------------+
void DrawLevelLines(double high, double low)
  {
   string hiName = "BreakoutHigh_" + IntegerToString((long)TimeCurrent());
   string loName = "BreakoutLow_"  + IntegerToString((long)TimeCurrent());

   ObjectDelete(0, "BreakoutHighLine");
   ObjectDelete(0, "BreakoutLowLine");

   ObjectCreate(0, "BreakoutHighLine", OBJ_HLINE, 0, 0, high);
   ObjectSetInteger(0, "BreakoutHighLine", OBJPROP_COLOR, clrGreen);
   ObjectSetInteger(0, "BreakoutHighLine", OBJPROP_STYLE, STYLE_DASH);

   ObjectCreate(0, "BreakoutLowLine", OBJ_HLINE, 0, 0, low);
   ObjectSetInteger(0, "BreakoutLowLine", OBJPROP_COLOR, clrRed);
   ObjectSetInteger(0, "BreakoutLowLine", OBJPROP_STYLE, STYLE_DASH);
  }
//+------------------------------------------------------------------+