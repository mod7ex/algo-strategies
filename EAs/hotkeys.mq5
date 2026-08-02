//+------------------------------------------------------------------+
//|                                                HotkeyTrader.mq5   |
//|   Hotkey trading panel EA (Long Market / Short Market / Flat All)|
//|   Mimics a compact on-chart panel with keyboard shortcuts and    |
//|   live lot size / open position monitoring.                     |
//|                                                                    |
//|   NOTE: Position management (Flat/RiskFree/Hedge/stats) acts on  |
//|   ALL open positions on the current chart symbol, regardless of  |
//|   which terminal/device opened them (desktop, mobile, manual,    |
//|   or another EA). The magic number is still stamped on NEW       |
//|   orders sent by this EA, but it is no longer used as a filter   |
//|   when selecting positions to close/modify/count.                |
//+------------------------------------------------------------------+
#property copyright "HotkeyTrader"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//====================== INPUTS ======================================
input group "=== Trading Settings ==="
input double InpLotSize          = 0.01;      // Starting lot size (editable live in the panel)
input int    InpSlippagePoints   = 5;         // Slippage (points)
input int    InpMagicNumber      = 202607;    // Magic number (stamped on new orders only)
input double InpMaxOpenLots      = 0.05;       // Max open size in one direction (0 = unlimited)

input group "=== Hotkeys (type a single letter) ==="
input string InpKeyLong          = "L";       // Long hotkey
input string InpKeyShort         = "S";       // Short hotkey
input string InpKeyFlat          = "F";       // Flat (close all) hotkey
input string InpKeyRiskFree      = "R";       // Risk Free hotkey (profitable positions only)
input string InpKeyHedge         = "H";       // Hedge hotkey (opens one order for the net exposure)

input group "=== Panel Appearance ==="
input int    InpPanelX           = 10;              // Panel X position (pixels)
input int    InpPanelY           = 10;              // Panel Y position (pixels)
input color  InpPanelBgColor     = C'20,22,28';     // Panel background color
input color  InpPanelBorderColor = C'60,120,200';   // Panel border color
input color  InpTitleColor       = clrDodgerBlue;   // Title text color
input color  InpLongColor        = clrDeepSkyBlue;  // Long row color
input color  InpShortColor       = clrTomato;       // Short row color
input color  InpFlatColor        = clrOrange;       // Flat row color
input color  InpRiskFreeColor    = clrYellowGreen;  // Risk Free row color
input color  InpHedgeColor       = clrGold;         // Hedge row color
input color  InpInfoColor        = clrSilver;       // Info text color
input color  InpStatusColor      = clrLightGray;    // Status line color
input color  InpEditBgColor      = clrBlack;        // Lot size edit box background
input color  InpEditTextColor    = clrWhite;        // Lot size edit box text color

//====================== GLOBALS ======================================
CTrade trade;

string PFX = "HKT_";  // object name prefix, avoids collisions with other EAs

string g_status = "Ready - press a key";

// live-editable lot size, seeded from InpLotSize at init, changed via the panel edit box
double g_lotSize;

// resolved from the string inputs at init time
int    g_vkLong, g_vkShort, g_vkFlat, g_vkRiskFree, g_vkHedge;
string g_letterLong, g_letterShort, g_letterFlat, g_letterRiskFree, g_letterHedge;

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
//| Number of decimal digits implied by the symbol's volume step     |
//| (e.g. step 0.01 -> 2 digits, step 0.001 -> 3 digits)              |
//+------------------------------------------------------------------+
int LotDigits()
  {
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step<=0) return 2;

   int digits = 0;
   double v = step;
   while(v < 0.999999 && digits < 6)
     {
      v *= 10;
      digits++;
     }
   return digits;
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
//| Helper: create an editable lot-size text box                     |
//+------------------------------------------------------------------+
void CreateEdit(string name,int x,int y,int w,int h,string text,color txtClr,color bgClr)
  {
   if(ObjectFind(0,name)<0)
      ObjectCreate(0,name,OBJ_EDIT,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetString(0,name,OBJPROP_TEXT,text);
   ObjectSetString(0,name,OBJPROP_FONT,"Consolas");
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,9);
   ObjectSetInteger(0,name,OBJPROP_COLOR,txtClr);
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,bgClr);
   ObjectSetInteger(0,name,OBJPROP_BORDER_COLOR,InpPanelBorderColor);
   ObjectSetInteger(0,name,OBJPROP_ALIGN,ALIGN_CENTER);
   ObjectSetInteger(0,name,OBJPROP_READONLY,false);
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
   int h = 258;
   int rowH = 22;

   CreatePanelBg(PFX+"bg", x, y, w, h, InpPanelBgColor, InpPanelBorderColor);

   CreateLabel(PFX+"title", x+12, y+10, "HOTKEY TRADER", InpTitleColor, 10, "Consolas Bold");

   CreateButton(PFX+"btnLong",    x+10, y+34, w-20, rowH, "[ "+g_letterLong    +" ]   Long Market",   InpLongColor);
   CreateButton(PFX+"btnShort",   x+10, y+58, w-20, rowH, "[ "+g_letterShort   +" ]   Short Market",  InpShortColor);
   CreateButton(PFX+"btnFlat",    x+10, y+82, w-20, rowH, "[ "+g_letterFlat    +" ]   Flat All",      InpFlatColor);
   CreateButton(PFX+"btnRiskFree",x+10, y+106,w-20, rowH, "[ "+g_letterRiskFree+" ]   Risk Free",     InpRiskFreeColor);
   CreateButton(PFX+"btnHedge",   x+10, y+130,w-20, rowH, "[ "+g_letterHedge   +" ]   Hedge",         InpHedgeColor);

   CreateLabel(PFX+"sep", x+10, y+158, StringRepeat("-", 26), clrGray, 8);

   // Editable lot size field (double-click to type a new value, press Enter to confirm)
   CreateLabel(PFX+"lotLabel", x+12, y+173, "Lot Size:", InpInfoColor, 9);
   CreateEdit(PFX+"lotEdit", x+92, y+169, 86, 18, DoubleToString(g_lotSize, LotDigits()), InpEditTextColor, InpEditBgColor);

   // Max open size in one direction (read-only display of the input)
   CreateLabel(PFX+"maxLabel", x+12, y+193, MaxOpenLotsText(), InpInfoColor, 9);

   CreateLabel(PFX+"pos",  x+12, y+213, "Open positions: --", InpInfoColor, 9);

   CreateLabel(PFX+"status", x+12, y+235, g_status, InpStatusColor, 8);

   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Text for the "Max/Dir" display field                             |
//+------------------------------------------------------------------+
string MaxOpenLotsText()
  {
   if(InpMaxOpenLots <= 0)
      return "Max/Dir: Unlimited";
   return StringFormat("Max/Dir: %s lots", DoubleToString(InpMaxOpenLots, LotDigits()));
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
//| Does the currently-selected position belong to this symbol?      |
//| This is the ONLY filter applied when selecting positions to      |
//| count/close/modify - it intentionally ignores magic number and   |
//| origin (desktop, mobile, manual) so every position on the        |
//| instrument you're trading (e.g. XAUUSD, EURUSD) is managed.      |
//+------------------------------------------------------------------+
bool PositionMatchesSymbol()
  {
   return (PositionGetString(POSITION_SYMBOL) == _Symbol);
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
      if(!PositionMatchesSymbol()) continue;

      count++;
      lots += PositionGetDouble(POSITION_VOLUME);
     }
  }

//+------------------------------------------------------------------+
//| Sum long lots vs short lots separately (for hedging and the      |
//| max-open-size-in-one-direction cap)                               |
//+------------------------------------------------------------------+
void GetNetExposure(double &longLots,double &shortLots)
  {
   longLots  = 0.0;
   shortLots = 0.0;
   int total = PositionsTotal();
   for(int i=0;i<total;i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(!PositionMatchesSymbol()) continue;

      long posType = PositionGetInteger(POSITION_TYPE);
      double vol   = PositionGetDouble(POSITION_VOLUME);

      if(posType==POSITION_TYPE_BUY)
         longLots += vol;
      else if(posType==POSITION_TYPE_SELL)
         shortLots += vol;
     }
  }

//+------------------------------------------------------------------+
//| Round/clamp a lot size to the symbol's volume step/min/max        |
//+------------------------------------------------------------------+
double NormalizeLots(double vol)
  {
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   if(step>0)
      vol = MathRound(vol/step)*step;

   if(vol<minVol) vol = minVol;
   if(vol>maxVol) vol = maxVol;

   return vol;
  }

//+------------------------------------------------------------------+
//| Given the lot size the panel wants to send and the current NET   |
//| exposure (longLots - shortLots), return how much of the request  |
//| is allowed under InpMaxOpenLots (0 = unlimited), where the cap   |
//| applies to net long / net short - not gross lots in that         |
//| direction. E.g. 0.05 long + 0.02 short = net long 0.03; with a   |
//| cap of 0.05 you still have 0.02 of room to go further long.      |
//| isLong=true checks the cap on net long, false checks net short.  |
//| allowed <= 0 means the net cap is already reached/exceeded.       |
//+------------------------------------------------------------------+
double ClampToMaxOpen(double requestedVol,double netExposure,bool isLong)
  {
   if(InpMaxOpenLots <= 0)
      return requestedVol; // unlimited

   // Buying moves net exposure up (more long); selling moves it down (more short).
   // Room is how much you can move in that direction before hitting +/-InpMaxOpenLots.
   double room = isLong ? (InpMaxOpenLots - netExposure) : (InpMaxOpenLots + netExposure);

   if(room <= 0)
      return 0.0;

   double allowed = MathMin(requestedVol, room);
   return NormalizeLots(allowed);
  }

//+------------------------------------------------------------------+
//| Refresh the info / status labels                                 |
//+------------------------------------------------------------------+
void UpdatePanelInfo()
  {
   int count; double lots;
   GetPositionStats(count, lots);

   // NOTE: the lot-size edit box is intentionally NOT rewritten here on
   // every timer tick - only on init and after the user confirms an edit -
   // so typing into it isn't clobbered by the 1-second refresh.
   string posTxt = StringFormat("Open positions: %d", count);
   ObjectSetString(0, PFX+"pos", OBJPROP_TEXT, posTxt);
   ObjectSetString(0, PFX+"maxLabel", OBJPROP_TEXT, MaxOpenLotsText());
   ObjectSetString(0, PFX+"status", OBJPROP_TEXT, g_status);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Read the lot-size edit box, validate/normalize it, and apply it  |
//+------------------------------------------------------------------+
void ApplyLotEdit()
  {
   string txt = ObjectGetString(0, PFX+"lotEdit", OBJPROP_TEXT);
   double val = StringToDouble(txt);

   if(val <= 0)
      g_status = "Invalid lot size entered - keeping previous value";
   else
     {
      g_lotSize = NormalizeLots(val);
      g_status  = StringFormat("Lot size set to %s", DoubleToString(g_lotSize, LotDigits()));
     }

   // reflect the normalized value back into the box either way
   ObjectSetString(0, PFX+"lotEdit", OBJPROP_TEXT, DoubleToString(g_lotSize, LotDigits()));
   UpdatePanelInfo();
  }

//+------------------------------------------------------------------+
//| Trading actions                                                  |
//+------------------------------------------------------------------+
void DoLong()
  {
   double longLots, shortLots;
   GetNetExposure(longLots, shortLots);
   double net = longLots - shortLots;

   double vol = ClampToMaxOpen(g_lotSize, net, true);
   if(vol <= 0)
     {
      g_status = StringFormat("LONG blocked - net long already at max (%s)", DoubleToString(InpMaxOpenLots, LotDigits()));
      UpdatePanelInfo();
      return;
     }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);
   double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(trade.Buy(vol, _Symbol, price, 0, 0, "HotkeyTrader Long"))
     {
      if(vol < g_lotSize)
         g_status = StringFormat("LONG %s @ %s executed (clamped by max/dir)", DoubleToString(vol,LotDigits()), DoubleToString(price,_Digits));
      else
         g_status = StringFormat("LONG %s @ %s executed", DoubleToString(vol,LotDigits()), DoubleToString(price,_Digits));
     }
   else
      g_status = StringFormat("LONG error: %d - %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());

   UpdatePanelInfo();
  }

void DoShort()
  {
   double longLots, shortLots;
   GetNetExposure(longLots, shortLots);
   double net = longLots - shortLots;

   double vol = ClampToMaxOpen(g_lotSize, net, false);
   if(vol <= 0)
     {
      g_status = StringFormat("SHORT blocked - net short already at max (%s)", DoubleToString(InpMaxOpenLots, LotDigits()));
      UpdatePanelInfo();
      return;
     }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(trade.Sell(vol, _Symbol, price, 0, 0, "HotkeyTrader Short"))
     {
      if(vol < g_lotSize)
         g_status = StringFormat("SHORT %s @ %s executed (clamped by max/dir)", DoubleToString(vol,LotDigits()), DoubleToString(price,_Digits));
      else
         g_status = StringFormat("SHORT %s @ %s executed", DoubleToString(vol,LotDigits()), DoubleToString(price,_Digits));
     }
   else
      g_status = StringFormat("SHORT error: %d - %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());

   UpdatePanelInfo();
  }

void DoFlat()
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
      if(!PositionMatchesSymbol()) continue;

      if(trade.PositionClose(ticket))
         closed++;
      else
         failed++;
     }

   if(failed==0)
      g_status = StringFormat("Flattened %d position(s)", closed);
   else
      g_status = StringFormat("Flat: %d closed, %d failed", closed, failed);

   UpdatePanelInfo();
  }

void DoRiskFree()
  {
   trade.SetExpertMagicNumber(InpMagicNumber);

   int moved = 0, failed = 0, skipped = 0;
   int total = PositionsTotal();

   for(int i=total-1;i>=0;i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(!PositionMatchesSymbol()) continue;

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

      // Skip if SL is already at (or better than) risk-free (breakeven)
      if(posType==POSITION_TYPE_BUY  && currentSL >= openPrice && currentSL > 0) { skipped++; continue; }
      if(posType==POSITION_TYPE_SELL && currentSL <= openPrice && currentSL > 0) { skipped++; continue; }

      if(trade.PositionModify(ticket, openPrice, currentTP))
         moved++;
      else
         failed++;
     }

   if(failed==0)
      g_status = StringFormat("Risk-free set on %d position(s), %d skipped", moved, skipped);
   else
      g_status = StringFormat("RF: %d set, %d failed, %d skipped", moved, failed, skipped);

   UpdatePanelInfo();
  }

void DoHedge()
  {
   double longLots, shortLots;
   GetNetExposure(longLots, shortLots);

   double net  = longLots - shortLots;   // >0 = net long, <0 = net short
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double eps  = (step>0 ? step/2.0 : 0.0000001);

   if(MathAbs(net) <= eps)
     {
      g_status = "Already hedged - net exposure is flat";
      UpdatePanelInfo();
      return;
     }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);

   double vol = NormalizeLots(MathAbs(net));
   bool   ok;

   if(net > 0)
     {
      // net long -> hedge by selling the net amount
      double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      ok = trade.Sell(vol, _Symbol, price, 0, 0, "HotkeyTrader Hedge");
      if(ok)
         g_status = StringFormat("HEDGE: SELL %.2f @ %s (net long %.2f)", vol, DoubleToString(price,_Digits), net);
      else
         g_status = StringFormat("HEDGE error: %d - %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
     }
   else
     {
      // net short -> hedge by buying the net amount
      double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      ok = trade.Buy(vol, _Symbol, price, 0, 0, "HotkeyTrader Hedge");
      if(ok)
         g_status = StringFormat("HEDGE: BUY %.2f @ %s (net short %.2f)", vol, DoubleToString(price,_Digits), -net);
      else
         g_status = StringFormat("HEDGE error: %d - %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
     }

   UpdatePanelInfo();
  }

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   // FIX: purge any stale panel objects left over from a previous run
   // (e.g. EA removed without a clean deinit, or terminal closed/crashed
   // while the panel was on the chart). Without this, MT5 can restore
   // the saved chart layout - including old HKT_ objects - even after
   // the EA is gone or the terminal is restarted.
   ObjectsDeleteAll(0, PFX);

   g_vkLong     = ResolveKey(InpKeyLong,     g_letterLong);
   g_vkShort    = ResolveKey(InpKeyShort,    g_letterShort);
   g_vkFlat     = ResolveKey(InpKeyFlat,     g_letterFlat);
   g_vkRiskFree = ResolveKey(InpKeyRiskFree, g_letterRiskFree);
   g_vkHedge    = ResolveKey(InpKeyHedge,    g_letterHedge);

   g_lotSize = NormalizeLots(InpLotSize);

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
//| Timer - keep the panel numbers live                               |
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
      if(key == g_vkLong)          DoLong();
      else if(key == g_vkShort)    DoShort();
      else if(key == g_vkFlat)     DoFlat();
      else if(key == g_vkRiskFree) DoRiskFree();
      else if(key == g_vkHedge)    DoHedge();
     }

   // --- Button clicks (mouse) ---
   if(id == CHARTEVENT_OBJECT_CLICK)
     {
      if(sparam == PFX+"btnLong")
        {
         DoLong();
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
        }
      else if(sparam == PFX+"btnShort")
        {
         DoShort();
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
        }
      else if(sparam == PFX+"btnFlat")
        {
         DoFlat();
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
        }
      else if(sparam == PFX+"btnRiskFree")
        {
         DoRiskFree();
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
        }
      else if(sparam == PFX+"btnHedge")
        {
         DoHedge();
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
        }
      ChartRedraw();
     }

   // --- Lot size edit box: fires when the user presses Enter or the box loses focus ---
   if(id == CHARTEVENT_OBJECT_ENDEDIT)
     {
      if(sparam == PFX+"lotEdit")
         ApplyLotEdit();
     }
  }
//+------------------------------------------------------------------+