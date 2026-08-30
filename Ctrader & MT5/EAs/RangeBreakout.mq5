//+------------------------------------------------------------------+
//|                                                RangeBreakout.mq5 |
//|                Converted from cAlgo (cTrader) RangeBreakout cBot |
//|                Same range/breakout/OCO/risk logic, ported to MT5 |
//+------------------------------------------------------------------+
#property copyright "Converted from cAlgo cBot"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//--- Risk type enum (mirrors cAlgo's RiskType enum)
enum ENUM_RISK_TYPE
{
   RISK_FIXED_LOTS,       // Fixed Lots
   RISK_MONEY_AMOUNT,     // Money Amount
   RISK_BALANCE_PERCENT   // Balance Percentage
};

//--- Inputs (mirrors cAlgo [Parameter] attributes)
input group "Trade Management"
input string          InpRangeStart    = "09:30:00";  // Range Start Time (HH:MM:SS, server time)
input string          InpRangeEnd      = "10:30:00";  // Range End Time (HH:MM:SS, server time)
input string          InpMaxLookAhead  = "02:00:00";  // Max Look Ahead Time (HH:MM:SS, 00:00:00 = disabled)

input group "Risk / Reward"
input double          InpRRR           = 2.0;         // Risk Reward Ratio
input ENUM_RISK_TYPE  InpRiskType      = RISK_MONEY_AMOUNT; // Risk Type

input group "Risk Sizing"
input double          InpFixedLots     = 0.01;        // Fixed Volume (Lots)
input double          InpRiskMoney     = 10.0;         // Risk Amount (account currency)
input double          InpRiskPercent   = 1.0;          // Risk Percent of Balance

input group "Display / Behaviour"
input color           InpBoxColor      = clrRed;      // Range Box Color
input bool             InpUseOCO        = true;        // Use OCO (cancel opposite order)

#define MAGIC_NUMBER 20260830

CTrade         trade;
CPositionInfo  posInfo;

//--- parsed time-of-day values, in seconds since midnight
int RangeStartSec   = 0;
int RangeEndSec     = 0;
int MaxLookAheadSec = 0;

//--- state (mirrors cAlgo private fields)
double   rangeHigh      = 0;
double   rangeLow       = 0;
bool     rangeActive    = false;
bool     ordersPlaced   = false;
string   rangeBoxName   = "";
datetime rangeDate      = 0;

ulong    buyStopTicket  = 0;   // pending order ticket for the Buy Stop
ulong    sellStopTicket = 0;   // pending order ticket for the Sell Stop

//+------------------------------------------------------------------+
//| Parse "HH:MM:SS" into seconds since midnight                     |
//+------------------------------------------------------------------+
int TimeStrToSeconds(string s)
{
   string parts[];
   int n = StringSplit(s, ':', parts);
   int h = 0, m = 0, sec = 0;
   if(n > 0) h   = (int)StringToInteger(parts[0]);
   if(n > 1) m   = (int)StringToInteger(parts[1]);
   if(n > 2) sec = (int)StringToInteger(parts[2]);
   return h * 3600 + m * 60 + sec;
}

//+------------------------------------------------------------------+
//| Seconds-since-midnight for a given datetime (server time)        |
//+------------------------------------------------------------------+
int TimeOfDaySec(datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return dt.hour * 3600 + dt.min * 60 + dt.sec;
}

//+------------------------------------------------------------------+
//| Midnight of the given datetime                                   |
//+------------------------------------------------------------------+
datetime DateOnly(datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   return StructToTime(dt);
}

//+------------------------------------------------------------------+
//| Opposite stop-order type for a given position type                |
//| (mirrors cAlgo's TwinTradeType, adapted to order types)          |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE OppositeStopType(ENUM_POSITION_TYPE posType)
{
   if(posType == POSITION_TYPE_BUY)
      return ORDER_TYPE_SELL_STOP;
   else
      return ORDER_TYPE_BUY_STOP;
}

//+------------------------------------------------------------------+
//| Draw / update the range rectangle on chart                       |
//| Note: MT5 chart objects don't support per-object alpha/opacity   |
//| like cAlgo's Color.FromArgb - InpBoxColor is used as a flat fill |
//| color instead. Use a lighter shade if you want a "faded" look.   |
//+------------------------------------------------------------------+
void DrawRangeBox()
{
   datetime t1 = rangeDate + RangeStartSec;
   datetime t2 = rangeDate + RangeEndSec;

   if(ObjectFind(0, rangeBoxName) < 0)
   {
      ObjectCreate(0, rangeBoxName, OBJ_RECTANGLE, 0, t1, rangeHigh, t2, rangeLow);
      ObjectSetInteger(0, rangeBoxName, OBJPROP_FILL, true);
      ObjectSetInteger(0, rangeBoxName, OBJPROP_BACK, true);
      ObjectSetInteger(0, rangeBoxName, OBJPROP_SELECTABLE, false);
   }
   else
   {
      ObjectMove(0, rangeBoxName, 0, t1, rangeHigh);
      ObjectMove(0, rangeBoxName, 1, t2, rangeLow);
   }

   ObjectSetInteger(0, rangeBoxName, OBJPROP_COLOR, InpBoxColor);
}

//+------------------------------------------------------------------+
//| Update the breakout range each tick (mirrors UpdateRange)        |
//+------------------------------------------------------------------+
void UpdateRange()
{
   datetime now = TimeCurrent();
   int currentTimeSec = TimeOfDaySec(now);

   double currentHigh = iHigh(_Symbol, PERIOD_CURRENT, 0);
   double currentLow  = iLow(_Symbol, PERIOD_CURRENT, 0);

   if(!rangeActive && currentTimeSec >= RangeStartSec && currentTimeSec < RangeEndSec)
   {
      rangeActive  = true;
      ordersPlaced = false;

      rangeDate = DateOnly(now);
      rangeHigh = currentHigh;
      rangeLow  = currentLow;

      string dateTag = TimeToString(rangeDate, TIME_DATE);
      StringReplace(dateTag, ".", "");
      rangeBoxName = "RangeBox_" + dateTag;

      DrawRangeBox();
   }

   if(rangeActive && currentTimeSec >= RangeStartSec && currentTimeSec < RangeEndSec)
   {
      rangeHigh = MathMax(rangeHigh, currentHigh);
      rangeLow  = MathMin(rangeLow, currentLow);

      DrawRangeBox();
   }

   if(rangeActive && currentTimeSec >= RangeEndSec)
   {
      rangeActive = false;

      DrawRangeBox();

      if(!ordersPlaced)
      {
         PlaceOcoOrders();
         ordersPlaced = true;
      }
   }
}

//+------------------------------------------------------------------+
//| Money lost per 1.0 lot if price moves slDistance against you     |
//+------------------------------------------------------------------+
double LossPerLot(double slDistance)
{
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0) return 0;
   return (slDistance / tickSize) * tickValue;
}

//+------------------------------------------------------------------+
//| Calculate order volume in lots (mirrors CalculateVolumeInUnits)  |
//+------------------------------------------------------------------+
double CalculateVolume(double slDistance)
{
   if(slDistance <= 0) return 0;

   double volume;

   switch(InpRiskType)
   {
      case RISK_FIXED_LOTS:
         volume = InpFixedLots;
         break;

      case RISK_MONEY_AMOUNT:
      {
         double costPerLot = LossPerLot(slDistance);
         volume = (costPerLot > 0) ? InpRiskMoney / costPerLot : 0;
         break;
      }

      case RISK_BALANCE_PERCENT:
      {
         double riskAmount = AccountInfoDouble(ACCOUNT_BALANCE) * (InpRiskPercent / 100.0);
         double costPerLot = LossPerLot(slDistance);
         volume = (costPerLot > 0) ? riskAmount / costPerLot : 0;
         break;
      }

      default:
         volume = InpFixedLots;
         break;
   }

   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double maxV = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   // Round DOWN to the nearest volume step (mirrors RoundingMode.Down)
   if(step > 0)
      volume = MathFloor(volume / step) * step;

   volume = MathMax(0.0, volume);
   volume = MathMin(volume, maxV);

   return volume;
}

//+------------------------------------------------------------------+
//| Place the Buy Stop / Sell Stop OCO pair (mirrors PlaceOcoOrders) |
//+------------------------------------------------------------------+
void PlaceOcoOrders()
{
   double slDistance = rangeHigh - rangeLow;
   if(slDistance <= 0) return;

   double tpDistance = slDistance * InpRRR;

   double volume = CalculateVolume(slDistance);
   double minVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   if(volume < minVol)
   {
      PrintFormat("Calculated volume %.2f is below minimum %.2f. Orders not placed.", volume, minVol);
      return;
   }

   double buySl = rangeLow;
   double buyTp = rangeHigh + tpDistance;

   double sellSl = rangeHigh;
   double sellTp = rangeLow - tpDistance;

   double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   double buyEntry  = NormalizeDouble(rangeHigh, digits);
   double sellEntry = NormalizeDouble(rangeLow, digits);

   if(trade.BuyStop(volume, buyEntry, _Symbol,
                     NormalizeDouble(buySl, digits), NormalizeDouble(buyTp, digits),
                     ORDER_TIME_GTC, 0, "BuyStop_" + rangeBoxName))
      buyStopTicket = trade.ResultOrder();
   else
   {
      buyStopTicket = 0;
      PrintFormat("Failed to place Buy Stop: %d - %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }

   if(trade.SellStop(volume, sellEntry, _Symbol,
                      NormalizeDouble(sellSl, digits), NormalizeDouble(sellTp, digits),
                      ORDER_TIME_GTC, 0, "SellStop_" + rangeBoxName))
      sellStopTicket = trade.ResultOrder();
   else
   {
      sellStopTicket = 0;
      PrintFormat("Failed to place Sell Stop: %d - %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Cancel a pending order by type (mirrors RemovePendingOrder)      |
//+------------------------------------------------------------------+
void RemovePendingOrder(ENUM_ORDER_TYPE type)
{
   if(type == ORDER_TYPE_BUY_STOP && buyStopTicket != 0)
   {
      if(trade.OrderDelete(buyStopTicket))
      {
         Print("Buy Stop order cancelled.");
         buyStopTicket = 0;
      }
      else
         PrintFormat("Failed to cancel Buy Stop order: %d", GetLastError());
   }

   if(type == ORDER_TYPE_SELL_STOP && sellStopTicket != 0)
   {
      if(trade.OrderDelete(sellStopTicket))
      {
         Print("Sell Stop order cancelled.");
         sellStopTicket = 0;
      }
      else
         PrintFormat("Failed to cancel Sell Stop order: %d", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Close/cancel everything once Max Look Ahead Time is reached      |
//| (mirrors CheckMaxLookAheadTime)                                   |
//+------------------------------------------------------------------+
void CheckMaxLookAheadTime()
{
   if(MaxLookAheadSec <= 0) return;
   if(rangeDate == 0) return;

   datetime referenceTime = rangeDate + RangeEndSec;
   int openDurationSec = (int)(TimeCurrent() - referenceTime);

   if(openDurationSec < MaxLookAheadSec) return;

   RemovePendingOrder(ORDER_TYPE_BUY_STOP);
   RemovePendingOrder(ORDER_TYPE_SELL_STOP);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != _Symbol) continue;
      if(posInfo.Magic() != MAGIC_NUMBER) continue;

      PrintFormat("Closing position %I64u because Max Look Ahead Time (%s) was reached.",
                  posInfo.Ticket(), InpMaxLookAhead);
      trade.PositionClose(posInfo.Ticket());
   }
}

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   RangeStartSec   = TimeStrToSeconds(InpRangeStart);
   RangeEndSec     = TimeStrToSeconds(InpRangeEnd);
   MaxLookAheadSec = TimeStrToSeconds(InpMaxLookAhead);

   trade.SetExpertMagicNumber(MAGIC_NUMBER);
   trade.SetTypeFillingBySymbol(_Symbol);

   rangeActive  = false;
   ordersPlaced = false;

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Chart objects are intentionally left in place, matching the original cBot behaviour.
}

//+------------------------------------------------------------------+
//| Expert tick function (mirrors OnTick)                            |
//+------------------------------------------------------------------+
void OnTick()
{
   UpdateRange();
   CheckMaxLookAheadTime();
}

//+------------------------------------------------------------------+
//| Trade transaction handler                                        |
//| Replaces cAlgo's Positions.Opened / Positions.Closed events.     |
//| - DEAL_ENTRY_IN  => a pending order of ours was filled (opened)  |
//| - DEAL_ENTRY_OUT => a position of ours was closed                |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                         const MqlTradeRequest      &request,
                         const MqlTradeResult       &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

   ulong dealTicket = trans.deal;
   if(!HistoryDealSelect(dealTicket)) return;

   long magic = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
   if(magic != MAGIC_NUMBER) return;

   long dealEntry  = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
   ulong orderTicket = (ulong)HistoryDealGetInteger(dealTicket, DEAL_ORDER);

   //--- Position opened (one of our pending orders was triggered)
   if(dealEntry == DEAL_ENTRY_IN)
   {
      bool wasBuy = false;

      if(orderTicket == buyStopTicket)
      {
         buyStopTicket = 0;
         wasBuy = true;
      }
      else if(orderTicket == sellStopTicket)
      {
         sellStopTicket = 0;
         wasBuy = false;
      }
      else
      {
         return; // not one of our tracked pending orders
      }

      if(InpUseOCO)
         RemovePendingOrder(wasBuy ? ORDER_TYPE_SELL_STOP : ORDER_TYPE_BUY_STOP);
   }
   //--- Position closed
   else if(dealEntry == DEAL_ENTRY_OUT)
   {
      if(InpUseOCO) return; // OCO already handled cancellation at open time

      long reason = HistoryDealGetInteger(dealTicket, DEAL_REASON);
      if(reason != DEAL_REASON_TP) return;

      // The DEAL_TYPE of the closing deal is the opposite of the position it closed:
      // a SELL deal closes a BUY position, a BUY deal closes a SELL position.
      long closingDealType = HistoryDealGetInteger(dealTicket, DEAL_TYPE);

      if(closingDealType == DEAL_TYPE_SELL)
         RemovePendingOrder(ORDER_TYPE_SELL_STOP); // a Buy position hit TP -> cancel Sell Stop
      else if(closingDealType == DEAL_TYPE_BUY)
         RemovePendingOrder(ORDER_TYPE_BUY_STOP);  // a Sell position hit TP -> cancel Buy Stop
   }
}
//+------------------------------------------------------------------+