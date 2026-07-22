//+------------------------------------------------------------------+
//|                                                    Auto_TPSL.mq5 |
//|         Automatic Take Profit / Stop Loss + SL Cover Protection  |
//+------------------------------------------------------------------+
#property copyright "Auto TPSL EA"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//====================================================================
// ENUMS
//====================================================================
enum ENUM_TPSL_MODE
  {
   MODE_POSITION    = 0,   // Position Mode (Averaging)
   MODE_TRANSACTION = 1    // Transaction Mode (Individual)
  };

enum ENUM_VALUE_TYPE
  {
   VALUE_PERCENT = 0,      // Percentage of account BALANCE (money-based)
   VALUE_PIPS    = 1       // Fixed pips
  };

//====================================================================
// INPUTS
//====================================================================
input string Sep0 = "=========== Auto TPSL Settings ===========";  // ---
input ENUM_TPSL_MODE   TPSL_Mode              = MODE_POSITION;    // TP/SL Mode
input ENUM_VALUE_TYPE  ValueType              = VALUE_PERCENT;    // Value Type
input double           TakeProfitValue        = 2.0;              // Take Profit Value (% of balance, or pips)
input double           StopLossValue          = 1.0;              // Stop Loss Value (% of balance, or pips)
input bool             ApplyOnStartup         = true;              // Apply to Existing Orders on Startup

input string Sep1 = "=========== SL Cover Settings ===========";   // ---
input bool              EnableSLCover         = true;              // Enable SL Cover Feature
input double            CoverProfitThreshold  = 0.5;               // Cover When Profit Reaches (%)
input double            CoverSLValue          = 0.1;               // Cover SL Value (%)

input string Sep2 = "=========== General Settings ===========";    // ---
input ulong             MagicNumber           = 0;                 // Magic Number Filter (0 = manage all)
input int                Slippage             = 10;                // Slippage (points)

//====================================================================
// GLOBALS
//====================================================================
CTrade trade;

// Tracks tickets already handled so we can detect newly-opened positions
ulong knownTickets[];

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetDeviationInPoints(Slippage);
   trade.SetTypeFillingBySymbol(_Symbol);

   ArrayResize(knownTickets, 0);

   // Snapshot current tickets so we don't treat them as "new" unless requested
   if(ApplyOnStartup)
     {
      ApplyToAllExistingPositions();
     }

   RefreshKnownTickets();

   Print("Auto TPSL EA initialized. Mode=", EnumToString(TPSL_Mode),
         " ValueType=", EnumToString(ValueType));

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
  }

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
  {
   ProcessNewPositions();

   if(EnableSLCover)
      ProcessSLCover();
  }

//====================================================================
// HELPERS: symbol / pip math
//====================================================================

//--- Returns pip size for a symbol (handles 3/5-digit brokers)
double PipSize(const string symbol)
  {
   double point  = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   if(digits == 3 || digits == 5)
      return(point * 10.0);
   return(point);
  }

//--- Normalizes a price to the symbol's tick size / digits
double NormalizePrice(const string symbol, double price)
  {
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   return(NormalizeDouble(price, digits));
  }

//--- Ensures a stop level respects the broker's minimum stop distance
double EnforceMinStopDistance(const string symbol, double price, double currentPrice, bool isSL, bool isBuy)
  {
   double point      = SymbolInfoDouble(symbol, SYMBOL_POINT);
   long   stopsLevel = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist     = stopsLevel * point;

   if(minDist <= 0)
      return(price);

   if(isBuy)
     {
      if(isSL && (currentPrice - price) < minDist)
         price = currentPrice - minDist;
      if(!isSL && (price - currentPrice) < minDist)
         price = currentPrice + minDist;
     }
   else
     {
      if(isSL && (price - currentPrice) < minDist)
         price = currentPrice + minDist;
      if(!isSL && (currentPrice - price) < minDist)
         price = currentPrice - minDist;
     }

   return(NormalizePrice(symbol, price));
  }

//--- Checks whether a position passes the magic number filter
bool PassesFilter(ulong ticket)
  {
   if(MagicNumber == 0)
      return(true);
   if(!PositionSelectByTicket(ticket))
      return(false);
   return(PositionGetInteger(POSITION_MAGIC) == (long)MagicNumber);
  }

//====================================================================
// TP / SL CALCULATION
//====================================================================

//--- Converts a money amount into a price distance for a given symbol/volume
double MoneyToPriceDistance(const string symbol, double money, double volume)
  {
   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);

   // Some brokers/symbols report 0 here until the symbol is fully synced;
   // fall back to the "profit" tick value, which is usually populated.
   if(tickValue <= 0)
      tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE_PROFIT);

   if(tickSize <= 0)
      tickSize = SymbolInfoDouble(symbol, SYMBOL_POINT);

   if(volume <= 0 || tickValue <= 0 || tickSize <= 0)
     {
      Print("MoneyToPriceDistance: bad inputs for ", symbol,
            " volume=", volume, " tickValue=", tickValue, " tickSize=", tickSize);
      return(0);
     }

   double moneyPerPriceUnit = (tickValue / tickSize) * volume; // account currency per 1.0 price move
   if(moneyPerPriceUnit <= 0)
      return(0);

   double dist = money / moneyPerPriceUnit;

   Print("MoneyToPriceDistance: ", symbol, " money=", money, " volume=", volume,
         " tickValue=", tickValue, " tickSize=", tickSize, " -> distance=", dist);

   return(dist);
  }

//--- Calculates TP and SL price levels given an entry price, direction and volume.
//    NOTE: 'volume' must be the TOTAL volume of the position/group the entry
//    price represents (individual volume in Transaction Mode, combined
//    weighted volume in Position Mode) so the risk scales with the basket size.
void CalculateTPSL(const string symbol, double entryPrice, double volume, bool isBuy, double &tp, double &sl)
  {
   double tpDist = 0, slDist = 0;

   if(ValueType == VALUE_PERCENT)
     {
      // Percentage = % of ACCOUNT BALANCE (money-based risk/target), converted
      // into a price distance using the position's (combined) volume.
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);

      if(TakeProfitValue > 0)
         tpDist = MoneyToPriceDistance(symbol, balance * (TakeProfitValue / 100.0), volume);
      if(StopLossValue > 0)
         slDist = MoneyToPriceDistance(symbol, balance * (StopLossValue / 100.0), volume);
     }
   else // VALUE_PIPS
     {
      double pip = PipSize(symbol);
      tpDist = TakeProfitValue * pip;
      slDist = StopLossValue   * pip;
     }

   if(isBuy)
     {
      tp = (TakeProfitValue > 0) ? entryPrice + tpDist : 0;
      sl = (StopLossValue   > 0) ? entryPrice - slDist : 0;
     }
   else
     {
      tp = (TakeProfitValue > 0) ? entryPrice - tpDist : 0;
      sl = (StopLossValue   > 0) ? entryPrice + slDist : 0;
     }

   if(tp != 0)
      tp = NormalizePrice(symbol, tp);
   if(sl != 0)
      sl = NormalizePrice(symbol, sl);
  }

//--- Computes the volume-weighted average entry price for all positions
//    matching symbol + direction (used in Position Mode)
double WeightedAveragePrice(const string symbol, ENUM_POSITION_TYPE posType, double &totalVolume)
  {
   double sumPriceVol = 0;
   totalVolume = 0;

   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(!PassesFilter(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol)
         continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != posType)
         continue;

      double vol   = PositionGetDouble(POSITION_VOLUME);
      double price = PositionGetDouble(POSITION_PRICE_OPEN);

      sumPriceVol += price * vol;
      totalVolume += vol;
     }

   if(totalVolume <= 0)
      return(0);

   return(sumPriceVol / totalVolume);
  }

//--- Sends a TP/SL modification request for a single ticket
bool ModifyPositionTPSL(ulong ticket, double tp, double sl)
  {
   if(!PositionSelectByTicket(ticket))
      return(false);

   double currentTP = PositionGetDouble(POSITION_TP);
   double currentSL = PositionGetDouble(POSITION_SL);
   double posPoint  = SymbolInfoDouble(PositionGetString(POSITION_SYMBOL), SYMBOL_POINT);

   // Avoid redundant modify requests
   if(MathAbs(currentTP - tp) < posPoint && MathAbs(currentSL - sl) < posPoint)
      return(true);

   if(!trade.PositionModify(ticket, sl, tp))
     {
      Print("Failed to modify position #", ticket, " Error: ", GetLastError());
      return(false);
     }

   return(true);
  }

//--- Applies TP/SL to a whole Position-Mode group (same symbol + direction)
void ApplyGroupTPSL(const string symbol, ENUM_POSITION_TYPE posType)
  {
   double totalVolume = 0;
   double avgPrice = WeightedAveragePrice(symbol, posType, totalVolume);
   if(avgPrice <= 0)
     {
      Print("ApplyGroupTPSL: no valid avgPrice for ", symbol, " (totalVolume=", totalVolume, ")");
      return;
     }

   bool isBuy = (posType == POSITION_TYPE_BUY);
   double tp, sl;
   CalculateTPSL(symbol, avgPrice, totalVolume, isBuy, tp, sl);

   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double currentPrice = isBuy ? bid : ask;

   if(tp != 0)
      tp = EnforceMinStopDistance(symbol, tp, currentPrice, false, isBuy);
   if(sl != 0)
      sl = EnforceMinStopDistance(symbol, sl, currentPrice, true, isBuy);

   Print("ApplyGroupTPSL: ", symbol, " ", EnumToString(posType),
         " avgPrice=", avgPrice, " totalVolume=", totalVolume,
         " -> TP=", tp, " SL=", sl);

   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(!PassesFilter(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol)
         continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != posType)
         continue;

      ModifyPositionTPSL(ticket, tp, sl);
     }
  }

//--- Applies TP/SL to a single position independently (Transaction Mode)
void ApplyIndividualTPSL(ulong ticket)
  {
   if(!PositionSelectByTicket(ticket))
      return;

   string symbol     = PositionGetString(POSITION_SYMBOL);
   double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double volume     = PositionGetDouble(POSITION_VOLUME);
   bool   isBuy      = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);

   double tp, sl;
   CalculateTPSL(symbol, entryPrice, volume, isBuy, tp, sl);

   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double currentPrice = isBuy ? bid : ask;

   if(tp != 0)
      tp = EnforceMinStopDistance(symbol, tp, currentPrice, false, isBuy);
   if(sl != 0)
      sl = EnforceMinStopDistance(symbol, sl, currentPrice, true, isBuy);

   Print("ApplyIndividualTPSL: #", ticket, " ", symbol,
         " entry=", entryPrice, " volume=", volume,
         " -> TP=", tp, " SL=", sl);

   ModifyPositionTPSL(ticket, tp, sl);
  }

//====================================================================
// NEW POSITION DETECTION
//====================================================================

//--- Rebuilds the snapshot of currently-open ticket numbers
void RefreshKnownTickets()
  {
   int total = PositionsTotal();
   ArrayResize(knownTickets, total);

   for(int i = 0; i < total; i++)
     {
      ulong ticket = PositionGetTicket(i);
      knownTickets[i] = ticket;
     }
  }

//--- Returns true if a ticket was already present in the last snapshot
bool WasKnown(ulong ticket)
  {
   for(int i = 0; i < ArraySize(knownTickets); i++)
     {
      if(knownTickets[i] == ticket)
         return(true);
     }
   return(false);
  }

//--- Detects newly opened positions and applies Auto TPSL logic to them
void ProcessNewPositions()
  {
   int total = PositionsTotal();
   bool anyNew = false;

   for(int i = 0; i < total; i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(WasKnown(ticket))
         continue;
      if(!PassesFilter(ticket))
         continue;

      anyNew = true;

      if(TPSL_Mode == MODE_TRANSACTION)
        {
         ApplyIndividualTPSL(ticket);
        }
      else // MODE_POSITION
        {
         if(!PositionSelectByTicket(ticket))
            continue;
         string symbol           = PositionGetString(POSITION_SYMBOL);
         ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         ApplyGroupTPSL(symbol, type);
        }
     }

   if(anyNew)
      RefreshKnownTickets();
   else if(total != ArraySize(knownTickets))
      RefreshKnownTickets(); // a position was closed elsewhere; resync
  }

//--- Applies TP/SL to every currently open position (used on startup)
void ApplyToAllExistingPositions()
  {
   if(TPSL_Mode == MODE_TRANSACTION)
     {
      for(int i = 0; i < PositionsTotal(); i++)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !PassesFilter(ticket))
            continue;
         ApplyIndividualTPSL(ticket);
        }
     }
   else // MODE_POSITION -- process each unique symbol/direction group once
     {
      string processedSymbols[];
      int    processedTypes[];
      int    count = 0;

      for(int i = 0; i < PositionsTotal(); i++)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !PassesFilter(ticket))
            continue;
         if(!PositionSelectByTicket(ticket))
            continue;

         string symbol = PositionGetString(POSITION_SYMBOL);
         int    type   = (int)PositionGetInteger(POSITION_TYPE);

         bool already = false;
         for(int j = 0; j < count; j++)
           {
            if(processedSymbols[j] == symbol && processedTypes[j] == type)
              {
               already = true;
               break;
              }
           }
         if(already)
            continue;

         ArrayResize(processedSymbols, count + 1);
         ArrayResize(processedTypes, count + 1);
         processedSymbols[count] = symbol;
         processedTypes[count]   = type;
         count++;

         ApplyGroupTPSL(symbol, (ENUM_POSITION_TYPE)type);
        }
     }
  }

//====================================================================
// SL COVER PROTECTION
//====================================================================

//--- Runs the SL Cover check across all open positions
void ProcessSLCover()
  {
   if(TPSL_Mode == MODE_TRANSACTION)
     {
      for(int i = 0; i < PositionsTotal(); i++)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !PassesFilter(ticket))
            continue;
         CheckAndCoverIndividual(ticket);
        }
     }
   else // MODE_POSITION -- evaluate each unique symbol/direction group once
     {
      string processedSymbols[];
      int    processedTypes[];
      int    count = 0;

      for(int i = 0; i < PositionsTotal(); i++)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !PassesFilter(ticket))
            continue;
         if(!PositionSelectByTicket(ticket))
            continue;

         string symbol = PositionGetString(POSITION_SYMBOL);
         int    type   = (int)PositionGetInteger(POSITION_TYPE);

         bool already = false;
         for(int j = 0; j < count; j++)
           {
            if(processedSymbols[j] == symbol && processedTypes[j] == type)
              {
               already = true;
               break;
              }
           }
         if(already)
            continue;

         ArrayResize(processedSymbols, count + 1);
         ArrayResize(processedTypes, count + 1);
         processedSymbols[count] = symbol;
         processedTypes[count]   = type;
         count++;

         CheckAndCoverGroup(symbol, (ENUM_POSITION_TYPE)type);
        }
     }
  }

//--- Computes profit percentage relative to entry price
double ProfitPercent(double entryPrice, double currentPrice, bool isBuy)
  {
   if(entryPrice <= 0)
      return(0);

   if(isBuy)
      return((currentPrice - entryPrice) / entryPrice * 100.0);
   else
      return((entryPrice - currentPrice) / entryPrice * 100.0);
  }

//--- Evaluates and applies SL Cover for a single independent position
void CheckAndCoverIndividual(ulong ticket)
  {
   if(!PositionSelectByTicket(ticket))
      return;

   string symbol     = PositionGetString(POSITION_SYMBOL);
   double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   bool   isBuy      = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
   double currentSL  = PositionGetDouble(POSITION_SL);
   double currentTP  = PositionGetDouble(POSITION_TP);

   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double currentPrice = isBuy ? bid : ask;

   double profitPct = ProfitPercent(entryPrice, currentPrice, isBuy);
   if(profitPct < CoverProfitThreshold)
      return;

   double newSL = isBuy
                  ? entryPrice * (1.0 + CoverSLValue / 100.0)
                  : entryPrice * (1.0 - CoverSLValue / 100.0);
   newSL = NormalizePrice(symbol, newSL);
   newSL = EnforceMinStopDistance(symbol, newSL, currentPrice, true, isBuy);

   // Only apply if it improves the current SL
   bool improves;
   if(isBuy)
      improves = (currentSL == 0) || (newSL > currentSL);
   else
      improves = (currentSL == 0) || (newSL < currentSL);

   if(!improves)
      return;

   // Sanity check: new SL must sit on the correct side of the current price
   if(isBuy && newSL >= currentPrice)
      return;
   if(!isBuy && newSL <= currentPrice)
      return;

   ModifyPositionTPSL(ticket, currentTP, newSL);
  }

//--- Evaluates and applies SL Cover for a Position-Mode group
void CheckAndCoverGroup(const string symbol, ENUM_POSITION_TYPE posType)
  {
   double totalVolume = 0;
   double avgPrice = WeightedAveragePrice(symbol, posType, totalVolume);
   if(avgPrice <= 0)
      return;

   bool isBuy = (posType == POSITION_TYPE_BUY);
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double currentPrice = isBuy ? bid : ask;

   double profitPct = ProfitPercent(avgPrice, currentPrice, isBuy);
   if(profitPct < CoverProfitThreshold)
      return;

   double newSL = isBuy
                  ? avgPrice * (1.0 + CoverSLValue / 100.0)
                  : avgPrice * (1.0 - CoverSLValue / 100.0);
   newSL = NormalizePrice(symbol, newSL);
   newSL = EnforceMinStopDistance(symbol, newSL, currentPrice, true, isBuy);

   if(isBuy && newSL >= currentPrice)
      return;
   if(!isBuy && newSL <= currentPrice)
      return;

   // Apply to every position in the group, only where it improves the SL
   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(!PassesFilter(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol)
         continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != posType)
         continue;

      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);

      bool improves;
      if(isBuy)
         improves = (currentSL == 0) || (newSL > currentSL);
      else
         improves = (currentSL == 0) || (newSL < currentSL);

      if(improves)
         ModifyPositionTPSL(ticket, currentTP, newSL);
     }
  }
//+------------------------------------------------------------------+