//+------------------------------------------------------------------+
//|                                              SpreadMonitor.mq5   |
//|   Measures spread (points & pips), displays it on chart, and     |
//|   logs it to the Experts journal / optional CSV file.            |
//+------------------------------------------------------------------+
#property copyright "SpreadMonitor"
#property version   "1.00"
#property strict

//----------------------- Inputs --------------------------------------
input int    CornerXOffset   = 10;      // Distance from left edge (px)
input int    CornerYOffset   = 10;      // Distance from bottom edge (px)
input color  TextColor       = clrLime; // Label color
input int    FontSize        = 10;      // Font size
input string FontName        = "Consolas";

input bool   LogToJournal    = true;    // Print spread to Experts journal
input int    LogIntervalSec  = 5;       // Journal log throttle (seconds)
input bool   LogToCSV        = false;   // Also log to a CSV file
input string CSVFileName     = "SpreadLog.csv";

//----------------------- Globals --------------------------------------
string   labelName   = "SpreadMonitor_Label";
datetime lastLogTime = 0;

//+------------------------------------------------------------------+
int OnInit()
  {
   CreateLabel();
   if(LogToCSV)
     {
      int h = FileOpen(CSVFileName, FILE_WRITE|FILE_CSV|FILE_COMMON, ',');
      if(h != INVALID_HANDLE)
        {
         FileWrite(h, "Time", "Symbol", "SpreadPoints", "SpreadPips", "Bid", "Ask");
         FileClose(h);
        }
     }
   EventSetTimer(1);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   ObjectDelete(0, labelName);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   UpdateSpreadDisplay();
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   UpdateSpreadDisplay();
  }

//+------------------------------------------------------------------+
//| Create the on-chart label, anchored to lower-left corner         |
//+------------------------------------------------------------------+
void CreateLabel()
  {
   if(ObjectFind(0, labelName) < 0)
     {
      ObjectCreate(0, labelName, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, labelName, OBJPROP_CORNER, CORNER_LEFT_LOWER);
      ObjectSetInteger(0, labelName, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
      ObjectSetInteger(0, labelName, OBJPROP_XDISTANCE, CornerXOffset);
      ObjectSetInteger(0, labelName, OBJPROP_YDISTANCE, CornerYOffset);
      ObjectSetInteger(0, labelName, OBJPROP_COLOR, TextColor);
      ObjectSetInteger(0, labelName, OBJPROP_FONTSIZE, FontSize);
      ObjectSetString(0, labelName, OBJPROP_FONT, FontName);
      ObjectSetInteger(0, labelName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, labelName, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, labelName, OBJPROP_BACK, false);
     }
  }

//+------------------------------------------------------------------+
//| Points-per-pip: 10 for 3/5-digit symbols, 1 for 2/4-digit ones   |
//+------------------------------------------------------------------+
double PointsPerPip()
  {
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   return (digits == 3 || digits == 5) ? 10.0 : 1.0;
  }

//+------------------------------------------------------------------+
//| Compute current spread, update the label, and throttle-log it    |
//+------------------------------------------------------------------+
void UpdateSpreadDisplay()
  {
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   long   spreadPoints = (point > 0.0) ? (long)MathRound((ask - bid) / point)
                                        : SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   double spreadPips   = spreadPoints / PointsPerPip();

   string text = StringFormat("%s Spread: %d pts (%.1f pips)", _Symbol, (int)spreadPoints, spreadPips);
   ObjectSetString(0, labelName, OBJPROP_TEXT, text);
   ChartRedraw(0);

   if((LogToJournal || LogToCSV) && TimeCurrent() - lastLogTime >= LogIntervalSec)
     {
      lastLogTime = TimeCurrent();

      if(LogToJournal)
         PrintFormat("%s | Spread: %d pts | %.1f pips | Bid=%.5f Ask=%.5f",
                     _Symbol, (int)spreadPoints, spreadPips, bid, ask);

      if(LogToCSV)
        {
         int h = FileOpen(CSVFileName, FILE_READ|FILE_WRITE|FILE_CSV|FILE_COMMON, ',');
         if(h != INVALID_HANDLE)
           {
            FileSeek(h, 0, SEEK_END);
            FileWrite(h, TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
                       _Symbol, (int)spreadPoints, DoubleToString(spreadPips, 1),
                       DoubleToString(bid, 5), DoubleToString(ask, 5));
            FileClose(h);
           }
        }
     }
  }
//+------------------------------------------------------------------+