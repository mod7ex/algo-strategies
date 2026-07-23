//+------------------------------------------------------------------+
//|                                                HotkeyTrader.mq5   |
//|   Hotkey trading panel EA (Buy Market / Sell Market / Close All) |
//|   Mimics a compact on-chart panel with keyboard shortcuts and    |
//|   live lot size / open position monitoring.                     |
//+------------------------------------------------------------------+
#property copyright "HotkeyTrader"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//====================== INPUTS ======================================
input group "=== Trading Settings ==="
input double InpLotSize          = 0.01;      // Lot size for market orders
input int    InpSlippagePoints   = 10;        // Slippage (points)
input int    InpMagicNumber      = 202607;    // Magic number
input bool   InpOnlyThisSymbol   = true;      // Manage only current chart symbol
input bool   InpUseMagicFilter   = true;      // Only count/close positions with this Magic

input group "=== Hotkeys (type a single letter) ==="
input string InpKeyBuy           = "B";       // Buy hotkey
input string InpKeySell          = "S";       // Sell hotkey
input string InpKeyCloseAll      = "C";       // Close-all hotkey
input string InpKeyBreakEven     = "E";       // Break-even hotkey (profitable positions only)

input group "=== Panel Appearance ==="
input int    InpPanelX           = 20;        // Panel X position (pixels)
input int    InpPanelY           = 20;        // Panel Y position (pixels)
input color  InpPanelBgColor     = C'20,22,28';    // Panel background color
input color  InpPanelBorderColor = C'60,120,200';  // Panel border color
input color  InpTitleColor       = clrDodgerBlue;  // Title text color
input color  InpBuyColor         = clrDeepSkyBlue; // Buy row color
input color  InpSellColor        = clrTomato;      // Sell row color
input color  InpCloseColor       = clrOrange;      // Close-all row color
input color  InpBreakEvenColor   = clrYellowGreen;  // Break-even row color
input color  InpInfoColor        = clrSilver;      // Info text color
input color  InpStatusColor      = clrLightGray;   // Status line color

//====================== GLOBALS ======================================
CTrade trade;

string PFX = "HKT_";  // object name prefix, avoids collisions with other EAs

string g_status = "Ready - press a key";

// resolved from the string inputs at init time
int    g_vkBuy, g_vkSell, g_vkClose, g_vkBreakEven;
string g_letterBuy, g_letterSell, g_letterClose, g_letterBreakEven;

//+------------------------------------------------------------------+
//| Convert a one-letter input string (e.g. "b") into a virtual-key  |
//| code and its clean uppercase display letter.                     |
//+------------------------------------------------------------------+
int ResolveKey(string rawKey,string &displayLetter)
  {
   string s = rawKey;
   StringTrimLeft(s);
   StringTrimRight(s);
   StringToUpper(s);

   if(StringLen(s)==0)
     {
      displayLetter = "?";
      return 0;
     }

   s = StringSubstr(s,0,1);      // keep only the first character
   displayLetter = s;
   ushort ch = StringGetCharacter(s,0);
   return (int)ch;
  }

//+------------------------------------------------------------------+
//| Helper: create a background rectangle                            |
//+------------------------------------------------------------------+
void CreatePanelBg(string name,int x,int y,int w,int h,color bg,color border)
  {
   if(ObjectFind(0,name)<0)
      ObjectCreate(0,name,OBJ_RECTANGLE_LABEL,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(0,name,OBJPROP_BORDER_TYPE,BORDER_FLAT);
   ObjectSetInteger(0,name,OBJPROP_COLOR,border);
   ObjectSetInteger(0,name,OBJPROP_STYLE,STYLE_SOLID);
   ObjectSetInteger(0,name,OBJPROP_WIDTH,1);
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_BACK,false);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
  }

//+------------------------------------------------------------------+
//| Helper: create a text label                                      |
//+------------------------------------------------------------------+
void CreateLabel(string name,int x,int y,string text,color clr,int fontSize=9,string font="Consolas")
  {
   if(ObjectFind(0,name)<0)
      ObjectCreate(0,name,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetString(0,name,OBJPROP_TEXT,text);
   ObjectSetString(0,name,OBJPROP_FONT,font);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,fontSize);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
  }

//+------------------------------------------------------------------+
//| Helper: create a clickable button row                            |
//+------------------------------------------------------------------+
void CreateButton(string name,int x,int y,int w,int h,string text,color txtClr)
  {
   if(ObjectFind(0,name)<0)
      ObjectCreate(0,name,OBJ_BUTTON,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetString(0,name,OBJPROP_TEXT,text);
   ObjectSetString(0,name,OBJPROP_FONT,"Consolas");
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,9);
   ObjectSetInteger(0,name,OBJPROP_COLOR,txtClr);
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,InpPanelBgColor);
   ObjectSetInteger(0,name,OBJPROP_BORDER_COLOR,InpPanelBgColor);
   ObjectSetInteger(0,name,OBJPROP_STATE,false);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,name,OBJPROP_ZORDER,10);
  }

//+------------------------------------------------------------------+
//| Build the whole panel                                            |
//+------------------------------------------------------------------+
void BuildPanel()
  {
   int x = InpPanelX;
   int y = InpPanelY;
   int w = 190;
   int h = 216;
   int rowH = 22;

   CreatePanelBg(PFX+"bg", x, y, w, h, InpPanelBgColor, InpPanelBorderColor);

   CreateLabel(PFX+"title", x+12, y+10, "HOTKEY TRADER", InpTitleColor, 10, "Consolas Bold");

   CreateButton(PFX+"btnBuy",  x+10, y+34, w-20, rowH, "[ "+g_letterBuy +" ]   Buy Market",   InpBuyColor);
   CreateButton(PFX+"btnSell", x+10, y+58, w-20, rowH, "[ "+g_letterSell+" ]   Sell Market",  InpSellColor);
   CreateButton(PFX+"btnClose",x+10, y+82, w-20, rowH, "[ "+g_letterClose+" ]   Close All",InpCloseColor);
   CreateButton(PFX+"btnBE",   x+10, y+106,w-20, rowH, "[ "+g_letterBreakEven+" ]   Break Even",InpBreakEvenColor);

   CreateLabel(PFX+"sep", x+10, y+134, StringRepeat("-", 26), clrGray, 8);

   CreateLabel(PFX+"lot",  x+12, y+148, "Lot: --",            InpInfoColor, 9);
   CreateLabel(PFX+"pos",  x+12, y+166, "Open positions: --", InpInfoColor, 9);

   CreateLabel(PFX+"status", x+12, y+190, g_status, InpStatusColor, 8);

   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Utility: repeat a character string                               |
//+------------------------------------------------------------------+
string StringRepeat(string s,int n)
  {
   string r="";
   for(int i=0;i<n;i++) r+=s;
   return r;
  }

//+------------------------------------------------------------------+
//| Remove all panel objects                                         |
//+------------------------------------------------------------------+
void DeletePanel()
  {
   ObjectsDeleteAll(0, PFX);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Count open positions and summed lot size                         |
//+------------------------------------------------------------------+
void GetPositionStats(int &count,double &lots)
  {
   count = 0;
   lots  = 0.0;
   int total = PositionsTotal();
   for(int i=0;i<total;i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      if(InpOnlyThisSymbol && PositionGetString(POSITION_SYMBOL)!=_Symbol)
         continue;
      if(InpUseMagicFilter && PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber)
         continue;

      count++;
      lots += PositionGetDouble(POSITION_VOLUME);
     }
  }

//+------------------------------------------------------------------+
//| Refresh the info / status labels                                 |
//+------------------------------------------------------------------+
void UpdatePanelInfo()
  {
   int count; double lots;
   GetPositionStats(count, lots);

   string lotTxt = StringFormat("Lot: %.2f", InpLotSize);
   string posTxt = StringFormat("Open positions: %d", count);
   ObjectSetString(0, PFX+"lot", OBJPROP_TEXT, lotTxt);
   ObjectSetString(0, PFX+"pos", OBJPROP_TEXT, posTxt);
   ObjectSetString(0, PFX+"status", OBJPROP_TEXT, g_status);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Trading actions                                                  |
//+------------------------------------------------------------------+
void DoBuy()
  {
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);
   double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(trade.Buy(InpLotSize, _Symbol, price, 0, 0, "HotkeyTrader Buy"))
      g_status = StringFormat("BUY %.2f @ %s executed", InpLotSize, DoubleToString(price,_Digits));
   else
      g_status = StringFormat("BUY error: %d - %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());

   UpdatePanelInfo();
  }

void DoSell()
  {
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(trade.Sell(InpLotSize, _Symbol, price, 0, 0, "HotkeyTrader Sell"))
      g_status = StringFormat("SELL %.2f @ %s executed", InpLotSize, DoubleToString(price,_Digits));
   else
      g_status = StringFormat("SELL error: %d - %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());

   UpdatePanelInfo();
  }

void DoCloseAll()
  {
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);

   int closed = 0, failed = 0;
   int total = PositionsTotal();
   // iterate backwards since closing changes the list
   for(int i=total-1;i>=0;i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      if(InpOnlyThisSymbol && PositionGetString(POSITION_SYMBOL)!=_Symbol)
         continue;
      if(InpUseMagicFilter && PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber)
         continue;

      if(trade.PositionClose(ticket))
         closed++;
      else
         failed++;
     }

   if(failed==0)
      g_status = StringFormat("Closed %d position(s)", closed);
   else
      g_status = StringFormat("Closed %d, failed %d", closed, failed);

   UpdatePanelInfo();
  }

void DoBreakEven()
  {
   trade.SetExpertMagicNumber(InpMagicNumber);

   int moved = 0, failed = 0, skipped = 0;
   int total = PositionsTotal();

   for(int i=total-1;i>=0;i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      if(InpOnlyThisSymbol && PositionGetString(POSITION_SYMBOL)!=_Symbol)
         continue;
      if(InpUseMagicFilter && PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber)
         continue;

      double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(profit <= 0)
        {
         skipped++;
         continue;
        }

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL  = PositionGetDouble(POSITION_SL);
      double currentTP  = PositionGetDouble(POSITION_TP);
      long   posType    = PositionGetInteger(POSITION_TYPE);

      // Skip if SL is already at (or better than) breakeven
      if(posType==POSITION_TYPE_BUY  && currentSL >= openPrice && currentSL > 0) { skipped++; continue; }
      if(posType==POSITION_TYPE_SELL && currentSL <= openPrice && currentSL > 0) { skipped++; continue; }

      if(trade.PositionModify(ticket, openPrice, currentTP))
         moved++;
      else
         failed++;
     }

   if(failed==0)
      g_status = StringFormat("Break-even set on %d position(s), %d skipped", moved, skipped);
   else
      g_status = StringFormat("BE: %d set, %d failed, %d skipped", moved, failed, skipped);

   UpdatePanelInfo();
  }


int OnInit()
  {
   g_vkBuy   = ResolveKey(InpKeyBuy,   g_letterBuy);
   g_vkSell  = ResolveKey(InpKeySell,  g_letterSell);
   g_vkClose = ResolveKey(InpKeyCloseAll, g_letterClose);
   g_vkBreakEven = ResolveKey(InpKeyBreakEven, g_letterBreakEven);

   ChartSetInteger(0, CHART_EVENT_OBJECT_DELETE, true);
   BuildPanel();
   UpdatePanelInfo();
   EventSetTimer(1); // refresh info once per second
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   DeletePanel();
  }

//+------------------------------------------------------------------+
//| Expert tick function (kept minimal - panel updates via timer)    |
//+------------------------------------------------------------------+
void OnTick()
  {
  }

//+------------------------------------------------------------------+
//| Timer - keep the panel numbers live                              |
//+------------------------------------------------------------------+
void OnTimer()
  {
   UpdatePanelInfo();
  }

//+------------------------------------------------------------------+
//| Chart event handler - hotkeys & button clicks                    |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   // --- Keyboard hotkeys ---
   if(id == CHARTEVENT_KEYDOWN)
     {
      int key = (int)lparam;
      if(key == g_vkBuy)          DoBuy();
      else if(key == g_vkSell)    DoSell();
      else if(key == g_vkClose)   DoCloseAll();
      else if(key == g_vkBreakEven) DoBreakEven();
     }

   // --- Button clicks (mouse) ---
   if(id == CHARTEVENT_OBJECT_CLICK)
     {
      if(sparam == PFX+"btnBuy")
        {
         DoBuy();
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
        }
      else if(sparam == PFX+"btnSell")
        {
         DoSell();
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
        }
      else if(sparam == PFX+"btnClose")
        {
         DoCloseAll();
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
        }
      else if(sparam == PFX+"btnBE")
        {
         DoBreakEven();
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
        }
      ChartRedraw();
     }
  }
//+------------------------------------------------------------------+