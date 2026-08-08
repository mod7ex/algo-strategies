//+------------------------------------------------------------------+
//|                                        DailyCandleBreakout.mq5   |
//|                                                                    |
//|  Strategy:                                                        |
//|   Each day, pick one "root" candle (a chosen timeframe + a        |
//|   chosen candle-open time). Its range (High-Low) defines risk.    |
//|     - BuyStop  at root High, SL at root Low                       |
//|     - SellStop at root Low,  SL at root High                      |
//|   Whichever triggers first, the other pending order is deleted.   |
//|   TP = entry +/- RiskRewardRatio * risk.                          |
//|   Position size is derived from a fixed USD risk amount.          |
//|                                                                    |
//|  NOTE on fidelity to the python reference:                        |
//|   The python backtest logic assumes candle-by-candle sequencing   |
//|   and treats a candle that pierces BOTH root High and root Low    |
//|   simultaneously as "triggered then stopped out immediately"      |
//|   (no trade counted). In live/tick trading this exact scenario    |
//|   (a gap through both stop levels in one tick) is rare and is not |
//|   perfectly reproducible via pending orders - both could           |
//|   theoretically fill. This is a known, unavoidable limitation of  |
//|   translating bar-based backtest logic into live order execution.|
//+------------------------------------------------------------------+
#property copyright "Custom EA"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//--------------------------- Inputs ----------------------------------
input ENUM_TIMEFRAMES InpTimeframe            = PERIOD_H1;   // Strategy timeframe (root candle)
input string          InpCandleTime           = "14:00";     // Candle time (HH:MM, terminal/broker time)
input double          InpRRR                  = 3.0;         // Risk:Reward ratio
input double          InpRiskUSD              = 10.0;        // Risk per trade (account currency)
input bool            InpCancelUnfilledNextDay= true;        // Cancel any unfilled pending order before next day's setup
input ulong           InpMagic                = 20260808;    // Magic number
input int             InpSlippage             = 10;          // Max slippage / deviation (points)

//--------------------------- Globals ----------------------------------
CTrade   trade;
ulong    buyStopTicket   = 0;
ulong    sellStopTicket  = 0;
datetime lastProcessedDay = 0;   // midnight timestamp of last day we placed orders for
datetime lastBarTime      = 0;   // last seen bar-open time on InpTimeframe
int      targetHour = 14, targetMinute = 0;

//+------------------------------------------------------------------+
bool ParseTime(const string s, int &h, int &m)
  {
   string parts[];
   int n = StringSplit(s, ':', parts);
   if(n < 2) return false;
   h = (int)StringToInteger(parts[0]);
   m = (int)StringToInteger(parts[1]);
   if(h < 0 || h > 23 || m < 0 || m > 59) return false;
   return true;
  }

//+------------------------------------------------------------------+
void RecoverExistingOrders()
  {
   int total = OrdersTotal();
   for(int i = 0; i < total; i++)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != (long)InpMagic) continue;

      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type == ORDER_TYPE_BUY_STOP)  buyStopTicket  = ticket;
      else if(type == ORDER_TYPE_SELL_STOP) sellStopTicket = ticket;
     }

   if(buyStopTicket > 0 || sellStopTicket > 0)
     {
      MqlDateTime dtNow;
      TimeToStruct(TimeCurrent(), dtNow);
      dtNow.hour = 0; dtNow.min = 0; dtNow.sec = 0;
      lastProcessedDay = StructToTime(dtNow);
      Print("Recovered existing pending order(s) for today, will not re-arm until next matching candle.");
     }
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   if(!ParseTime(InpCandleTime, targetHour, targetMinute))
     {
      Print("Invalid InpCandleTime format ('", InpCandleTime, "'), expected HH:MM. Falling back to 14:00.");
      targetHour = 14; targetMinute = 0;
     }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);

   RecoverExistingOrders();

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
  }

//+------------------------------------------------------------------+
void CancelPendingOrders()
  {
   if(buyStopTicket > 0)
     {
      if(OrderSelect(buyStopTicket))
         trade.OrderDelete(buyStopTicket);
      buyStopTicket = 0;
     }
   if(sellStopTicket > 0)
     {
      if(OrderSelect(sellStopTicket))
         trade.OrderDelete(sellStopTicket);
      sellStopTicket = 0;
     }
  }

//+------------------------------------------------------------------+
//| Once one stop order stops being an active pending order, it must |
//| have been triggered (we control cancellations ourselves, so any  |
//| other disappearance is treated the same way). Cancel the sibling.|
//+------------------------------------------------------------------+
void CheckOrderTriggers()
  {
   if(buyStopTicket > 0 && !OrderSelect(buyStopTicket))
     {
      buyStopTicket = 0;
      if(sellStopTicket > 0 && OrderSelect(sellStopTicket))
        {
         trade.OrderDelete(sellStopTicket);
        }
      sellStopTicket = 0;
     }

   if(sellStopTicket > 0 && !OrderSelect(sellStopTicket))
     {
      sellStopTicket = 0;
      if(buyStopTicket > 0 && OrderSelect(buyStopTicket))
        {
         trade.OrderDelete(buyStopTicket);
        }
      buyStopTicket = 0;
     }
  }

//+------------------------------------------------------------------+
//| Event-driven trigger check: fires the instant the terminal        |
//| confirms an order was added/removed/executed, so the sibling      |
//| pending order is cancelled the same instant one is filled -       |
//| it does not wait for the next price tick or the next day's setup. |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                         const MqlTradeRequest      &request,
                         const MqlTradeResult       &result)
  {
   if(trans.type == TRADE_TRANSACTION_ORDER_ADD  ||
      trans.type == TRADE_TRANSACTION_ORDER_DELETE ||
      trans.type == TRADE_TRANSACTION_DEAL_ADD)
      CheckOrderTriggers();
  }

//+------------------------------------------------------------------+
double CalcLots(double riskPriceDistance)
  {
   if(riskPriceDistance <= 0) return 0.0;

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0) tickSize = _Point;
   if(tickValue <= 0) { Print("Could not read tick value for ", _Symbol); return 0.0; }

   double valuePerPriceUnit = tickValue / tickSize;
   double lots = InpRiskUSD / (riskPriceDistance * valuePerPriceUnit);

   double volMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double volMax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double volStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(volStep <= 0) volStep = 0.01;

   lots = MathFloor(lots / volStep) * volStep;
   lots = MathMax(volMin, MathMin(volMax, lots));
   lots = NormalizeDouble(lots, 2);

   return lots;
  }

//+------------------------------------------------------------------+
void PlaceDailyOrders(double rootHigh, double rootLow)
  {
   double risk = rootHigh - rootLow;
   if(risk <= 0)
     {
      Print("Root candle risk <= 0, skipping today's setup.");
      return;
     }

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double lots = CalcLots(risk);

   double volMin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(lots < volMin)
     {
      Print("Computed lot size (", lots, ") below broker minimum (", volMin, "). Skipping today's setup.");
      return;
     }

   double buyEntry = NormalizeDouble(rootHigh, digits);
   double buySL    = NormalizeDouble(rootLow, digits);
   double buyTP    = NormalizeDouble(rootHigh + InpRRR * risk, digits);

   double sellEntry = NormalizeDouble(rootLow, digits);
   double sellSL    = NormalizeDouble(rootHigh, digits);
   double sellTP    = NormalizeDouble(rootLow - InpRRR * risk, digits);

   if(trade.BuyStop(lots, buyEntry, _Symbol, buySL, buyTP, ORDER_TIME_GTC, 0, "DailyCandleBreakout"))
      buyStopTicket = trade.ResultOrder();
   else
      Print("BuyStop failed: ", trade.ResultRetcodeDescription());

   if(trade.SellStop(lots, sellEntry, _Symbol, sellSL, sellTP, ORDER_TIME_GTC, 0, "DailyCandleBreakout"))
      sellStopTicket = trade.ResultOrder();
   else
      Print("SellStop failed: ", trade.ResultRetcodeDescription());

   PrintFormat("Root candle High=%.5f Low=%.5f Risk=%.5f Lots=%.2f -> BuyStop#%I64u SellStop#%I64u",
               rootHigh, rootLow, risk, lots, buyStopTicket, sellStopTicket);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   datetime currentBarTime = iTime(_Symbol, InpTimeframe, 0);

   if(currentBarTime != lastBarTime)
     {
      lastBarTime = currentBarTime;

      // A new bar just opened on InpTimeframe -> bar at shift 1 has just closed.
      datetime closedBarTime = iTime(_Symbol, InpTimeframe, 1);
      MqlDateTime dtClosed;
      TimeToStruct(closedBarTime, dtClosed);

      if(dtClosed.hour == targetHour && dtClosed.min == targetMinute)
        {
         MqlDateTime dtDay = dtClosed;
         dtDay.hour = 0; dtDay.min = 0; dtDay.sec = 0;
         datetime dayStart = StructToTime(dtDay);

         if(dayStart != lastProcessedDay)
           {
            lastProcessedDay = dayStart;

            if(InpCancelUnfilledNextDay)
               CancelPendingOrders();

            double rootHigh = iHigh(_Symbol, InpTimeframe, 1);
            double rootLow  = iLow(_Symbol, InpTimeframe, 1);

            PlaceDailyOrders(rootHigh, rootLow);
           }
        }
     }

   CheckOrderTriggers();
  }
//+------------------------------------------------------------------+