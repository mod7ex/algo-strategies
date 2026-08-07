//+------------------------------------------------------------------+
//|                                      StochATR_Pyramid_EA.mq5      |
//|  Stochastic-triggered, ATR-stop, ratcheting pyramid EA            |
//|                                                                    |
//|  Logic summary                                                    |
//|  ---------------------------------------------------------------  |
//|  BUY  if Stoch %K (signal TF) < InpBuyLevel  AND close > EMA200   |
//|  SELL if Stoch %K (signal TF) > InpSellLevel AND close < EMA200   |
//|       (all three read off the just-closed signal-TF bar); entry   |
//|       fires on the tick the next bar opens (as close as live      |
//|       execution gets to "open of next candle").                   |
//|                                                                    |
//|  SL distance = InpATR_Mult * ATR(InpATR_TF, InpATRPeriod), taken  |
//|  ONCE when the sequence starts and reused for every leg.          |
//|                                                                    |
//|  Whenever price advances InpRR * SLdistance beyond the last       |
//|  entry, a new leg is added at market and the stop loss of EVERY   |
//|  open leg in the sequence is moved to (new entry - SLdistance)    |
//|  for buys / (new entry + SLdistance) for sells. The sequence ends |
//|  when price finally hits that shared stop and all legs close.     |
//+------------------------------------------------------------------+
#property copyright "Generated EA"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//--- Inputs -----------------------------------------------------------
input group "=== Signal (Stochastic) ==="
input ENUM_TIMEFRAMES InpSignalTF   = PERIOD_M1;   // Signal timeframe
input int    InpStochK              = 5;           // %K period
input int    InpStochD              = 5;           // %D period
input int    InpStochSlow           = 14;          // Slowing
input double InpBuyLevel            = 15.0;        // Buy if %K < this  (b)
input double InpSellLevel           = 85.0;        // Sell if %K > this (s)

input group "=== Trend Filter (EMA) ==="
input int    InpEMAPeriod           = 200;         // EMA period (signal TF)

input group "=== Stop Loss (ATR) ==="
input ENUM_TIMEFRAMES InpATR_TF     = PERIOD_M3;   // ATR timeframe
input int    InpATRPeriod           = 14;          // ATR period
input double InpATR_Mult            = 2.0;         // SL = m * ATR   (m)

input group "=== Pyramiding ==="
input double InpRR                  = 3.0;         // r : add-on trigger multiple
input int    InpMaxAdds             = 500;          // safety cap on number of legs

input group "=== Risk / Sizing ==="
input double InpRiskMoney           = 10.0;        // fixed risk ($) PER ENTRY

input group "=== Misc ==="
input ulong  InpMagic               = 20260806;
input int    InpSlippage            = 20;          // points

CTrade trade;

int      hStoch = INVALID_HANDLE;
int      hATR   = INVALID_HANDLE;
int      hEMA   = INVALID_HANDLE;

datetime lastSignalBarTime = 0;

//--- sequence state -----------------------------------------------------
enum SeqDir { SEQ_NONE = 0, SEQ_BUY = 1, SEQ_SELL = -1 };

SeqDir   seqDir        = SEQ_NONE;
double   seqSLDistance = 0.0;   // fixed SL distance for the whole sequence
double   seqLastEntry  = 0.0;   // entry_n
double   seqNextTarget = 0.0;   // entry_n + r*SL (buy) / entry_n - r*SL (sell)
double   seqCurrentSL  = 0.0;   // shared SL currently applied to all legs
int      seqAdds       = 0;     // number of legs opened in this sequence

//+------------------------------------------------------------------+
int OnInit()
  {
   hStoch = iStochastic(_Symbol, InpSignalTF, InpStochK, InpStochD, InpStochSlow,
                         MODE_SMA, STO_LOWHIGH);
   hATR   = iATR(_Symbol, InpATR_TF, InpATRPeriod);
   hEMA   = iMA(_Symbol, InpSignalTF, InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);

   if(hStoch == INVALID_HANDLE || hATR == INVALID_HANDLE || hEMA == INVALID_HANDLE)
     {
      Print("Failed to create indicator handle(s)");
      return(INIT_FAILED);
     }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(hStoch != INVALID_HANDLE) IndicatorRelease(hStoch);
   if(hATR   != INVALID_HANDLE) IndicatorRelease(hATR);
   if(hEMA   != INVALID_HANDLE) IndicatorRelease(hEMA);
  }

//+------------------------------------------------------------------+
//| true exactly once, on the first tick of a new signal-TF bar       |
//+------------------------------------------------------------------+
bool IsNewSignalBar()
  {
   datetime t = iTime(_Symbol, InpSignalTF, 0);
   if(t != lastSignalBarTime)
     {
      lastSignalBarTime = t;
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
int CountSequencePositions()
  {
   int cnt = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      cnt++;
     }
   return cnt;
  }

//+------------------------------------------------------------------+
//| risk-based lot size for a given SL distance (in price units)      |
//+------------------------------------------------------------------+
double CalcLotSize(double slDistance)
  {
   double riskMoney = InpRiskMoney;

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double volMin    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double volMax    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double volStep   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(tickSize <= 0 || tickValue <= 0 || slDistance <= 0)
      return volMin;

   double lossPerLot = (slDistance / tickSize) * tickValue;
   if(lossPerLot <= 0) return volMin;

   double lots = riskMoney / lossPerLot;

   lots = MathFloor(lots / volStep) * volStep;
   lots = MathMax(volMin, MathMin(volMax, lots));
   return NormalizeDouble(lots, 2);
  }

//+------------------------------------------------------------------+
//| clamp a proposed SL so it respects broker stop/freeze levels      |
//| (this check was missing on the sibling HotkeyTrader EA's          |
//| DoRiskFree() - added here from the start)                         |
//+------------------------------------------------------------------+
double SafeStopLoss(bool isBuy, double proposedSL)
  {
   double point       = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   long   stopLevel   = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long   freezeLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   long   minDistPts  = MathMax(stopLevel, freezeLevel);
   double minDist     = minDistPts * point;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(isBuy)
     {
      double maxAllowed = bid - minDist;
      if(proposedSL > maxAllowed) proposedSL = maxAllowed;
     }
   else
     {
      double minAllowed = ask + minDist;
      if(proposedSL < minAllowed) proposedSL = minAllowed;
     }
   return NormalizeDouble(proposedSL, _Digits);
  }

//+------------------------------------------------------------------+
//| apply newSL to every open leg of the current sequence             |
//+------------------------------------------------------------------+
void UpdateAllStops(double newSL, bool isBuy)
  {
   newSL = SafeStopLoss(isBuy, newSL);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      double curSL = PositionGetDouble(POSITION_SL);
      if(MathAbs(curSL - newSL) < _Point) continue; // already at target

      if(!trade.PositionModify(ticket, newSL, 0))
         PrintFormat("PositionModify failed for #%I64u, err=%d", ticket, GetLastError());
     }
   seqCurrentSL = newSL;
  }

//+------------------------------------------------------------------+
void ResetSequence()
  {
   seqDir        = SEQ_NONE;
   seqSLDistance = 0.0;
   seqLastEntry  = 0.0;
   seqNextTarget = 0.0;
   seqCurrentSL  = 0.0;
   seqAdds       = 0;
  }

//+------------------------------------------------------------------+
//| open the first leg of a new sequence                              |
//+------------------------------------------------------------------+
bool StartSequence(bool isBuy)
  {
   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(hATR, 0, 1, 1, atrBuf) < 1) return false;
   double atr = atrBuf[0];
   if(atr <= 0) return false;

   double slDist = InpATR_Mult * atr;
   double price  = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                          : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double lots = CalcLotSize(slDist);
   double sl   = isBuy ? price - slDist : price + slDist;
   sl = SafeStopLoss(isBuy, sl);

   bool ok = isBuy ? trade.Buy(lots, _Symbol, 0.0, sl, 0.0, "seq-1")
                    : trade.Sell(lots, _Symbol, 0.0, sl, 0.0, "seq-1");

   if(!ok)
     {
      PrintFormat("Initial entry failed: %d", GetLastError());
      return false;
     }

   seqDir        = isBuy ? SEQ_BUY : SEQ_SELL;
   seqSLDistance = slDist;
   seqLastEntry  = price;
   seqCurrentSL  = sl;
   seqAdds       = 1;
   seqNextTarget = isBuy ? price + InpRR * slDist : price - InpRR * slDist;

   return true;
  }

//+------------------------------------------------------------------+
//| add another leg once price reaches seqNextTarget                  |
//+------------------------------------------------------------------+
void TryAddLeg()
  {
   if(seqDir == SEQ_NONE) return;
   if(seqAdds >= InpMaxAdds) return;

   bool isBuy = (seqDir == SEQ_BUY);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   bool hit = isBuy ? (bid >= seqNextTarget) : (ask <= seqNextTarget);
   if(!hit) return;

   double price = isBuy ? ask : bid;
   double lots  = CalcLotSize(seqSLDistance);
   double newSL = isBuy ? price - seqSLDistance : price + seqSLDistance;

   bool ok = isBuy ? trade.Buy(lots, _Symbol, 0.0, 0.0, 0.0, "seq-add")
                    : trade.Sell(lots, _Symbol, 0.0, 0.0, 0.0, "seq-add");

   if(!ok)
     {
      PrintFormat("Add-on entry failed: %d", GetLastError());
      return;
     }

   seqAdds++;
   seqLastEntry  = price;
   seqNextTarget = isBuy ? price + InpRR * seqSLDistance : price - InpRR * seqSLDistance;

   // ratchet the stop loss on EVERY leg (old + new) to the new shared level
   UpdateAllStops(newSL, isBuy);
  }

//+------------------------------------------------------------------+
void CheckEntrySignal()
  {
   double kBuf[], emaBuf[];
   ArraySetAsSeries(kBuf, true);
   ArraySetAsSeries(emaBuf, true);

   if(CopyBuffer(hStoch, 0, 1, 1, kBuf)  < 1) return; // %K of the just-closed bar
   if(CopyBuffer(hEMA,   0, 1, 1, emaBuf) < 1) return; // EMA of the just-closed bar

   double k         = kBuf[0];
   double ema       = emaBuf[0];
   double closePrice = iClose(_Symbol, InpSignalTF, 1); // close of that same bar

   bool aboveEMA = closePrice > ema;
   bool belowEMA = closePrice < ema;

   if(k < InpBuyLevel && aboveEMA)
      StartSequence(true);
   else
      if(k > InpSellLevel && belowEMA)
         StartSequence(false);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   // did the sequence just get stopped out?
   if(seqDir != SEQ_NONE && CountSequencePositions() == 0)
      ResetSequence();

   // manage an active sequence every tick (target can be hit intrabar)
   if(seqDir != SEQ_NONE)
      TryAddLeg();

   // only look for a fresh signal while flat
   if(seqDir == SEQ_NONE && IsNewSignalBar())
      CheckEntrySignal();
  }
//+------------------------------------------------------------------+