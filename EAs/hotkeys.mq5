//+------------------------------------------------------------------+
//|                                       HotkeyTrader_AutoTPSL.mq5   |
//|   Combined EA: Hotkey trading panel (Long/Short/Flat/RiskFree/   |
//|   Hedge) + Automatic Take Profit / Stop Loss + SL Cover, with a  |
//|   single ON/OFF button for the Auto TPSL engine docked at the    |
//|   bottom of the panel box.                                       |
//|                                                                    |
//|   NOTE (hotkey actions): Long/Short/Flat/RiskFree/Hedge act on   |
//|   ALL open positions on the current chart symbol, regardless of  |
//|   which terminal/device opened them. The magic number is only    |
//|   stamped on NEW orders sent by the hotkey panel.                |
//|                                                                    |
//|   NOTE (Auto TPSL): manages TP/SL (and SL Cover) across ALL open |
//|   positions matching InpTPSLMagicFilter (0 = every position,     |
//|   any symbol) - independent of the hotkey panel's magic number.  |
//+------------------------------------------------------------------+
#property copyright "HotkeyTrader + Auto TPSL"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//====================================================================
// ENUMS (Auto TPSL)
//====================================================================
enum ENUM_TPSL_MODE
  {
   MODE_POSITION    = 0,   // Position Mode (Averaging)
   MODE_TRANSACTION = 1    // Transaction Mode (Individual)
  };

enum ENUM_VALUE_TYPE
  {
   VALUE_PERCENT = 0,      // Percentage of account BALANCE (money-based)
   VALUE_PIPS    = 1,      // Fixed pips
   VALUE_MONEY   = 2       // Fixed amount of money (account currency)
  };

//====================== INPUTS ======================================
input group "=== Trading Settings ==="
input double InpLotSize          = 0.01;      // Starting lot size (editable live in the panel)
input int    InpSlippagePoints   = 5;         // Slippage (points) - hotkey orders
input int    InpMagicNumber      = 202607;    // Magic number (stamped on new hotkey orders only)
input double InpMaxOpenLots      = 0.05;      // Max open size in one direction (0 = unlimited)

input group "=== Hotkeys (type a single letter) ==="
input string InpKeyLong          = "L";       // Long hotkey
input string InpKeyShort         = "S";       // Short hotkey
input string InpKeyFlat          = "F";       // Flat (close all) hotkey
input string InpKeyRiskFree      = "R";       // Risk Free hotkey (profitable positions only)
input string InpKeyHedge         = "H";       // Hedge hotkey (opens one order for the net exposure)

input group "=== Market Switcher ==="
input int    InpMaxMarketListRows = 12;             // Max symbols shown in the dropdown (from Market Watch)
input color  InpMarketColor       = clrKhaki;       // Market button / list text color
input color  InpMarketActiveColor = clrDodgerBlue;  // Highlight color for the current symbol in the list

input group "=== Auto TP/SL Settings ==="
input ENUM_TPSL_MODE  TPSL_Mode          = MODE_POSITION;  // TP/SL Mode
input ENUM_VALUE_TYPE ValueType          = VALUE_MONEY;    // Value Type
input double          TakeProfitValue    = 30;             // Take Profit Value (%, pips, or money)
input double          StopLossValue      = 10;             // Stop Loss Value (%, pips, or money)
input bool            ApplyOnStartup     = true;            // Apply to Existing Positions on Startup
input bool            AutoTPSL_StartEnabled = false;        // Auto TPSL Enabled at Startup

input group "=== SL Cover Settings ==="
input bool   EnableSLCover         = true;    // Enable SL Cover Feature
input double CoverProfitThreshold  = 50;      // Cover When Profit Reaches (%)
input double CoverSLValue          = 0;       // Cover SL Value (%)

input group "=== Auto TP/SL Filter ==="
input ulong  InpTPSLMagicFilter    = 0;       // Magic filter for Auto TPSL (0 = manage all positions, any symbol)
input int    InpTPSLSlippage       = 5;       // Slippage (points) used by the Auto TPSL trade object

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
input color  InpToggleOnColor    = clrForestGreen;  // Auto TPSL button color when ON
input color  InpToggleOffColor   = clrFireBrick;    // Auto TPSL button color when OFF

//====================== GLOBALS ======================================
CTrade trade;

string PFX = "HKT_";  // shared object name prefix for every object this EA creates

string g_status = "Ready - press a key";

// live-editable lot size, seeded from InpLotSize at init, changed via the panel edit box
double g_lotSize;

// resolved from the string inputs at init time
int    g_vkLong, g_vkShort, g_vkFlat, g_vkRiskFree, g_vkHedge;
string g_letterLong, g_letterShort, g_letterFlat, g_letterRiskFree, g_letterHedge;

// Auto TPSL master switch (toggled via the panel button)
bool g_Enabled = true;

// Tracks tickets already handled so we can detect newly-opened positions
ulong knownTickets[];

// Button object name for the Auto TPSL toggle
#define ATP_BTN_NAME (PFX + "toggleBtn")

// Button object name for the market (symbol) dropdown, and whether it's open
#define MKT_BTN_NAME (PFX + "btnMarket")
bool g_marketOpen  = false;
int  g_marketRows  = 0;   // how many list rows are currently drawn (for cleanup/positioning)

// Panel geometry (computed once in BuildPanel, reused by UpdatePanelInfo)
int g_panelW = 190;
int g_panelH = 322;

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

//====================================================================
// PANEL BUILDING HELPERS
//====================================================================
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
//| Chart-scoped terminal global variable name used to persist the   |
//| Auto TPSL on/off state. Switching timeframe (or symbol) on the   |
//| same chart tears down and re-creates the EA (OnDeinit->OnInit    |
//| with reason REASON_CHARTCHANGE), which would otherwise reset     |
//| g_Enabled back to the AutoTPSL_StartEnabled input every time.    |
//| GlobalVariableTemp() keeps it in-memory only for this terminal   |
//| session (not written to disk), scoped to this chart via          |
//| ChartID() so multiple charts/instances don't collide.            |
//+------------------------------------------------------------------+
string GetAutoTPSLGVName()
  {
   return PFX + "Enabled_" + (string)ChartID();
  }

//+------------------------------------------------------------------+
//| Same idea as GetAutoTPSLGVName(), but for the live-editable lot  |
//| size: persists across symbol/timeframe changes on this chart     |
//| (which reinit the EA), but resets to InpLotSize on a genuine     |
//| terminal restart or a fresh EA attach, since GlobalVariableTemp  |
//| values are in-memory only for the current terminal session.      |
//+------------------------------------------------------------------+
string GetLotSizeGVName()
  {
   return PFX + "LotSize_" + (string)ChartID();
  }

//+------------------------------------------------------------------+
//| Auto TPSL toggle button - lives INSIDE the panel box, docked to  |
//| the bottom. Uses its own bg color (green/off=red) instead of the |
//| plain panel background used by the hotkey row buttons.           |
//+------------------------------------------------------------------+
void CreateToggleButton(int x,int y,int w,int h)
  {
   if(ObjectFind(0,ATP_BTN_NAME)<0)
      ObjectCreate(0,ATP_BTN_NAME,OBJ_BUTTON,0,0,0);
   ObjectSetInteger(0,ATP_BTN_NAME,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,ATP_BTN_NAME,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,ATP_BTN_NAME,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,ATP_BTN_NAME,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,ATP_BTN_NAME,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,ATP_BTN_NAME,OBJPROP_FONTSIZE,9);
   ObjectSetString(0,ATP_BTN_NAME,OBJPROP_FONT,"Arial Bold");
   ObjectSetInteger(0,ATP_BTN_NAME,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,ATP_BTN_NAME,OBJPROP_SELECTED,false);
   ObjectSetInteger(0,ATP_BTN_NAME,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,ATP_BTN_NAME,OBJPROP_ZORDER,10);
   ObjectSetInteger(0,ATP_BTN_NAME,OBJPROP_STATE,false); // keep un-pressed visually

   UpdateToggleButtonVisual();
  }

void UpdateToggleButtonVisual()
  {
   if(ObjectFind(0,ATP_BTN_NAME)<0)
      return;

   if(g_Enabled)
     {
      ObjectSetString(0,ATP_BTN_NAME,OBJPROP_TEXT,"Auto TPSL: ON");
      ObjectSetInteger(0,ATP_BTN_NAME,OBJPROP_BGCOLOR,InpToggleOnColor);
      ObjectSetInteger(0,ATP_BTN_NAME,OBJPROP_COLOR,clrWhite);
     }
   else
     {
      ObjectSetString(0,ATP_BTN_NAME,OBJPROP_TEXT,"Auto TPSL: OFF");
      ObjectSetInteger(0,ATP_BTN_NAME,OBJPROP_BGCOLOR,InpToggleOffColor);
      ObjectSetInteger(0,ATP_BTN_NAME,OBJPROP_COLOR,clrWhite);
     }

   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Market (symbol) dropdown - a button showing the active symbol    |
//| that, when clicked, drops an overlay list of Market Watch        |
//| symbols on top of the panel. Picking one switches the chart's    |
//| symbol (keeping the current timeframe); the panel's other rows   |
//| are untouched underneath since the list is destroyed again on    |
//| selection/close rather than permanently shifting the layout.     |
//+------------------------------------------------------------------+
void CreateMarketButton(int x,int y,int w,int h)
  {
   if(ObjectFind(0,MKT_BTN_NAME)<0)
      ObjectCreate(0,MKT_BTN_NAME,OBJ_BUTTON,0,0,0);
   ObjectSetInteger(0,MKT_BTN_NAME,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,MKT_BTN_NAME,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,MKT_BTN_NAME,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,MKT_BTN_NAME,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,MKT_BTN_NAME,OBJPROP_YSIZE,h);
   ObjectSetString(0,MKT_BTN_NAME,OBJPROP_FONT,"Consolas Bold");
   ObjectSetInteger(0,MKT_BTN_NAME,OBJPROP_FONTSIZE,9);
   ObjectSetInteger(0,MKT_BTN_NAME,OBJPROP_COLOR,InpMarketColor);
   ObjectSetInteger(0,MKT_BTN_NAME,OBJPROP_BGCOLOR,InpPanelBgColor);
   ObjectSetInteger(0,MKT_BTN_NAME,OBJPROP_BORDER_COLOR,InpPanelBorderColor);
   ObjectSetInteger(0,MKT_BTN_NAME,OBJPROP_STATE,false);
   ObjectSetInteger(0,MKT_BTN_NAME,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,MKT_BTN_NAME,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,MKT_BTN_NAME,OBJPROP_ZORDER,10);

   UpdateMarketButtonVisual();
  }

void UpdateMarketButtonVisual()
  {
   if(ObjectFind(0,MKT_BTN_NAME)<0)
      return;
   string arrow = g_marketOpen ? ShortToString(0x25B4) : ShortToString(0x25BE); // small up/down triangle
   ObjectSetString(0,MKT_BTN_NAME,OBJPROP_TEXT, StringFormat("%s  %s", _Symbol, arrow));
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Build the overlay list of Market Watch symbols under the market  |
//| button. Rendered with a high ZORDER so it sits visually on top   |
//| of whatever panel rows it overlaps.                              |
//+------------------------------------------------------------------+
void OpenMarketList()
  {
   CloseMarketList(); // clear any stale rows first

   int x = InpPanelX;
   int y = InpPanelY;
   int w = g_panelW;
   int rowH = 20;
   int baseY = y + 58; // directly under the market button

   int total = SymbolsTotal(true); // symbols currently in Market Watch
   int n = MathMin(total, InpMaxMarketListRows);

   for(int i=0;i<n;i++)
     {
      string sym  = SymbolName(i,true);
      string name = StringFormat("%s%s", PFX, "mktRow" + IntegerToString(i));
      bool   isCurrent = (sym == _Symbol);

      if(ObjectFind(0,name)<0)
         ObjectCreate(0,name,OBJ_BUTTON,0,0,0);
      ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x+10);
      ObjectSetInteger(0,name,OBJPROP_YDISTANCE,baseY + i*rowH);
      ObjectSetInteger(0,name,OBJPROP_XSIZE,w-20);
      ObjectSetInteger(0,name,OBJPROP_YSIZE,rowH-2);
      ObjectSetString(0,name,OBJPROP_TEXT, (isCurrent ? "> " : "   ") + sym);
      ObjectSetString(0,name,OBJPROP_FONT,"Consolas");
      ObjectSetInteger(0,name,OBJPROP_FONTSIZE,9);
      ObjectSetInteger(0,name,OBJPROP_COLOR, isCurrent ? InpMarketActiveColor : InpMarketColor);
      ObjectSetInteger(0,name,OBJPROP_BGCOLOR,InpPanelBgColor);
      ObjectSetInteger(0,name,OBJPROP_BORDER_COLOR,InpPanelBorderColor);
      ObjectSetInteger(0,name,OBJPROP_STATE,false);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
      ObjectSetInteger(0,name,OBJPROP_ZORDER,50); // draw above the regular panel rows
     }

   if(total > n)
     {
      string moreName = PFX+"mktMore";
      if(ObjectFind(0,moreName)<0)
         ObjectCreate(0,moreName,OBJ_LABEL,0,0,0);
      ObjectSetInteger(0,moreName,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,moreName,OBJPROP_XDISTANCE,x+12);
      ObjectSetInteger(0,moreName,OBJPROP_YDISTANCE,baseY + n*rowH + 2);
      ObjectSetString(0,moreName,OBJPROP_TEXT, StringFormat("+%d more - narrow Market Watch", total-n));
      ObjectSetString(0,moreName,OBJPROP_FONT,"Consolas");
      ObjectSetInteger(0,moreName,OBJPROP_FONTSIZE,8);
      ObjectSetInteger(0,moreName,OBJPROP_COLOR,InpInfoColor);
      ObjectSetInteger(0,moreName,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,moreName,OBJPROP_HIDDEN,true);
      ObjectSetInteger(0,moreName,OBJPROP_ZORDER,50);
     }

   g_marketRows = n;
   g_marketOpen = true;
   UpdateMarketButtonVisual();
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Remove the overlay list (selection made, or user closed it)      |
//+------------------------------------------------------------------+
void CloseMarketList()
  {
   for(int i=0;i<g_marketRows;i++)
      ObjectDelete(0, PFX+"mktRow"+IntegerToString(i));
   ObjectDelete(0, PFX+"mktMore");

   g_marketRows = 0;
   if(g_marketOpen)
     {
      g_marketOpen = false;
      UpdateMarketButtonVisual();
     }
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Switch the chart to a different symbol (same timeframe). This    |
//| triggers MT5 to reinit the EA, same as a timeframe change, so    |
//| the persisted Auto TPSL state carries over automatically.        |
//+------------------------------------------------------------------+
void SwitchMarket(string sym)
  {
   CloseMarketList();

   if(sym == "" || sym == _Symbol)
      return;

   if(!ChartSetSymbolPeriod(0, sym, _Period))
      Print("SwitchMarket: failed to switch to ", sym, " - error ", GetLastError());
  }

//+------------------------------------------------------------------+
//| Build the whole panel (hotkey rows + Auto TPSL button at bottom) |
//+------------------------------------------------------------------+
void BuildPanel()
  {
   int x = InpPanelX;
   int y = InpPanelY;
   int w = g_panelW;
   int h = g_panelH;
   int rowH = 22;

   CreatePanelBg(PFX+"bg", x, y, w, h, InpPanelBgColor, InpPanelBorderColor);

   CreateLabel(PFX+"title", x+12, y+10, "HOTKEY TRADER", InpTitleColor, 10, "Consolas Bold");

   // Market (symbol) dropdown - shows the active symbol, click to switch
   CreateMarketButton(x+10, y+34, w-20, rowH);

   CreateButton(PFX+"btnLong",    x+10, y+58, w-20, rowH, "[ "+g_letterLong    +" ]   Long Market",   InpLongColor);
   CreateButton(PFX+"btnShort",   x+10, y+82, w-20, rowH, "[ "+g_letterShort   +" ]   Short Market",  InpShortColor);
   CreateButton(PFX+"btnFlat",    x+10, y+106,w-20, rowH, "[ "+g_letterFlat    +" ]   Flat All",      InpFlatColor);
   CreateButton(PFX+"btnRiskFree",x+10, y+130,w-20, rowH, "[ "+g_letterRiskFree+" ]   Risk Free",     InpRiskFreeColor);
   CreateButton(PFX+"btnHedge",   x+10, y+154,w-20, rowH, "[ "+g_letterHedge   +" ]   Hedge",         InpHedgeColor);

   CreateLabel(PFX+"sep", x+10, y+182, StringRepeat("-", 26), clrGray, 8);

   // Editable lot size field (double-click to type a new value, press Enter to confirm)
   CreateLabel(PFX+"lotLabel", x+12, y+197, "Lot Size:", InpInfoColor, 9);
   CreateEdit(PFX+"lotEdit", x+92, y+193, 86, 18, DoubleToString(g_lotSize, LotDigits()), InpEditTextColor, InpEditBgColor);

   // Max open size in one direction (read-only display of the input)
   CreateLabel(PFX+"maxLabel", x+12, y+217, MaxOpenLotsText(), InpInfoColor, 9);

   CreateLabel(PFX+"pos",  x+12, y+237, "Open positions: --", InpInfoColor, 9);

   CreateLabel(PFX+"status", x+12, y+257, g_status, InpStatusColor, 8);

   CreateLabel(PFX+"sep2", x+10, y+274, StringRepeat("-", 26), clrGray, 8);

   // Auto TPSL ON/OFF toggle - docked at the bottom of the box
   CreateToggleButton(x+10, y+282, w-20, 28);

   ChartRedraw();
  }

string MaxOpenLotsText()
  {
   if(InpMaxOpenLots <= 0)
      return "Max/Dir: Unlimited";
   return StringFormat("Max/Dir: %s lots", DoubleToString(InpMaxOpenLots, LotDigits()));
  }

string StringRepeat(string s,int n)
  {
   string r="";
   for(int i=0;i<n;i++) r+=s;
   return r;
  }

//+------------------------------------------------------------------+
//| Remove all panel objects (hotkey rows + toggle button)           |
//+------------------------------------------------------------------+
void DeletePanel()
  {
   ObjectsDeleteAll(0, PFX);
   ChartRedraw();
  }

//====================================================================
// HOTKEY PANEL: POSITION SELECTION / SIZING (symbol-only filter)
//====================================================================
bool PositionMatchesSymbol()
  {
   return (PositionGetString(POSITION_SYMBOL) == _Symbol);
  }

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

double ClampToMaxOpen(double requestedVol,double netExposure,bool isLong)
  {
   if(InpMaxOpenLots <= 0)
      return requestedVol; // unlimited

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

   string posTxt = StringFormat("Open positions: %d", count);
   ObjectSetString(0, PFX+"pos", OBJPROP_TEXT, posTxt);
   ObjectSetString(0, PFX+"maxLabel", OBJPROP_TEXT, MaxOpenLotsText());
   ObjectSetString(0, PFX+"status", OBJPROP_TEXT, g_status);
   ChartRedraw();
  }

void ApplyLotEdit()
  {
   string txt = ObjectGetString(0, PFX+"lotEdit", OBJPROP_TEXT);
   double val = StringToDouble(txt);

   if(val <= 0)
      g_status = "Invalid lot size entered - keeping previous value";
   else
     {
      g_lotSize = NormalizeLots(val);
      GlobalVariableSet(GetLotSizeGVName(), g_lotSize);
      g_status  = StringFormat("Lot size set to %s", DoubleToString(g_lotSize, LotDigits()));
     }

   ObjectSetString(0, PFX+"lotEdit", OBJPROP_TEXT, DoubleToString(g_lotSize, LotDigits()));
   UpdatePanelInfo();
  }

//====================================================================
// HOTKEY TRADING ACTIONS
//====================================================================
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

   double net  = longLots - shortLots;
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
      double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      ok = trade.Sell(vol, _Symbol, price, 0, 0, "HotkeyTrader Hedge");
      if(ok)
         g_status = StringFormat("HEDGE: SELL %.2f @ %s (net long %.2f)", vol, DoubleToString(price,_Digits), net);
      else
         g_status = StringFormat("HEDGE error: %d - %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
     }
   else
     {
      double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      ok = trade.Buy(vol, _Symbol, price, 0, 0, "HotkeyTrader Hedge");
      if(ok)
         g_status = StringFormat("HEDGE: BUY %.2f @ %s (net short %.2f)", vol, DoubleToString(price,_Digits), -net);
      else
         g_status = StringFormat("HEDGE error: %d - %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
     }

   UpdatePanelInfo();
  }

//====================================================================
// AUTO TPSL: symbol / pip math
//====================================================================
double PipSize(const string symbol)
  {
   double point  = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   if(digits == 3 || digits == 5)
      return(point * 10.0);
   return(point);
  }

double NormalizePriceValue(const string symbol, double price)
  {
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   return(NormalizeDouble(price, digits));
  }

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

   return(NormalizePriceValue(symbol, price));
  }

//--- Checks whether a position passes the Auto TPSL magic number filter
bool PassesFilter(ulong ticket)
  {
   if(InpTPSLMagicFilter == 0)
      return(true);
   if(!PositionSelectByTicket(ticket))
      return(false);
   return(PositionGetInteger(POSITION_MAGIC) == (long)InpTPSLMagicFilter);
  }

//====================================================================
// AUTO TPSL: TP / SL CALCULATION
//====================================================================
double MoneyToPriceDistance(const string symbol, double money, double volume)
  {
   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);

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

   double moneyPerPriceUnit = (tickValue / tickSize) * volume;
   if(moneyPerPriceUnit <= 0)
      return(0);

   double dist = money / moneyPerPriceUnit;

   Print("MoneyToPriceDistance: ", symbol, " money=", money, " volume=", volume,
         " tickValue=", tickValue, " tickSize=", tickSize, " -> distance=", dist);

   return(dist);
  }

void CalculateTPSL(const string symbol, double entryPrice, double volume, bool isBuy, double &tp, double &sl)
  {
   double tpDist = 0, slDist = 0;

   if(ValueType == VALUE_PERCENT)
     {
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);

      if(TakeProfitValue > 0)
         tpDist = MoneyToPriceDistance(symbol, balance * (TakeProfitValue / 100.0), volume);
      if(StopLossValue > 0)
         slDist = MoneyToPriceDistance(symbol, balance * (StopLossValue / 100.0), volume);
     }
   else if(ValueType == VALUE_MONEY)
     {
      if(TakeProfitValue > 0)
         tpDist = MoneyToPriceDistance(symbol, TakeProfitValue, volume);
      if(StopLossValue > 0)
         slDist = MoneyToPriceDistance(symbol, StopLossValue, volume);
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
      tp = NormalizePriceValue(symbol, tp);
   if(sl != 0)
      sl = NormalizePriceValue(symbol, sl);
  }

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

bool ModifyPositionTPSL(ulong ticket, double tp, double sl)
  {
   if(!PositionSelectByTicket(ticket))
      return(false);

   double currentTP = PositionGetDouble(POSITION_TP);
   double currentSL = PositionGetDouble(POSITION_SL);
   double posPoint  = SymbolInfoDouble(PositionGetString(POSITION_SYMBOL), SYMBOL_POINT);

   if(MathAbs(currentTP - tp) < posPoint && MathAbs(currentSL - sl) < posPoint)
      return(true);

   if(!trade.PositionModify(ticket, sl, tp))
     {
      Print("Failed to modify position #", ticket, " Error: ", GetLastError());
      return(false);
     }

   return(true);
  }

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
// AUTO TPSL: NEW POSITION DETECTION
//====================================================================
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

bool WasKnown(ulong ticket)
  {
   for(int i = 0; i < ArraySize(knownTickets); i++)
     {
      if(knownTickets[i] == ticket)
         return(true);
     }
   return(false);
  }

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
// AUTO TPSL: SL COVER PROTECTION
//====================================================================
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

double ProfitPercent(double entryPrice, double currentPrice, bool isBuy)
  {
   if(entryPrice <= 0)
      return(0);

   if(isBuy)
      return((currentPrice - entryPrice) / entryPrice * 100.0);
   else
      return((entryPrice - currentPrice) / entryPrice * 100.0);
  }

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
   newSL = NormalizePriceValue(symbol, newSL);
   newSL = EnforceMinStopDistance(symbol, newSL, currentPrice, true, isBuy);

   bool improves;
   if(isBuy)
      improves = (currentSL == 0) || (newSL > currentSL);
   else
      improves = (currentSL == 0) || (newSL < currentSL);

   if(!improves)
      return;

   if(isBuy && newSL >= currentPrice)
      return;
   if(!isBuy && newSL <= currentPrice)
      return;

   ModifyPositionTPSL(ticket, currentTP, newSL);
  }

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
   newSL = NormalizePriceValue(symbol, newSL);
   newSL = EnforceMinStopDistance(symbol, newSL, currentPrice, true, isBuy);

   if(isBuy && newSL >= currentPrice)
      return;
   if(!isBuy && newSL <= currentPrice)
      return;

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

//====================================================================
// EXPERT LIFECYCLE
//====================================================================
int OnInit()
  {
   // Purge any stale panel objects left over from a previous run (EA
   // removed without a clean deinit, terminal crash, etc.) - MT5 can
   // otherwise restore old HKT_ objects from a saved chart layout.
   ObjectsDeleteAll(0, PFX);

   g_vkLong     = ResolveKey(InpKeyLong,     g_letterLong);
   g_vkShort    = ResolveKey(InpKeyShort,    g_letterShort);
   g_vkFlat     = ResolveKey(InpKeyFlat,     g_letterFlat);
   g_vkRiskFree = ResolveKey(InpKeyRiskFree, g_letterRiskFree);
   g_vkHedge    = ResolveKey(InpKeyHedge,    g_letterHedge);

   // Restore the live-edited lot size if this chart already had one
   // (e.g. we're re-initializing because the user switched symbol or
   // timeframe). Only a brand-new attach of the EA, or a fresh restart
   // of the terminal, falls back to the InpLotSize input default.
   string lotGvName = GetLotSizeGVName();
   if(GlobalVariableCheck(lotGvName))
      g_lotSize = NormalizeLots(GlobalVariableGet(lotGvName));
   else
     {
      g_lotSize = NormalizeLots(InpLotSize);
      GlobalVariableTemp(lotGvName);
      GlobalVariableSet(lotGvName, g_lotSize);
     }

   trade.SetDeviationInPoints(InpTPSLSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);

   // Restore the Auto TPSL on/off state if this chart already had one
   // (e.g. we're re-initializing because the user switched timeframe).
   // Only a brand-new attach of the EA falls back to the input default.
   string gvName = GetAutoTPSLGVName();
   if(GlobalVariableCheck(gvName))
      g_Enabled = (GlobalVariableGet(gvName) != 0);
   else
     {
      g_Enabled = AutoTPSL_StartEnabled;
      GlobalVariableTemp(gvName);
      GlobalVariableSet(gvName, g_Enabled ? 1.0 : 0.0);
     }

   ChartSetInteger(0, CHART_EVENT_OBJECT_DELETE, true);
   BuildPanel();
   UpdatePanelInfo();

   ArrayResize(knownTickets, 0);
   if(ApplyOnStartup && g_Enabled)
      ApplyToAllExistingPositions();
   RefreshKnownTickets();

   EventSetTimer(1); // refresh panel info once per second

   Print("HotkeyTrader + Auto TPSL initialized. Mode=", EnumToString(TPSL_Mode),
         " ValueType=", EnumToString(ValueType),
         " Auto TPSL Enabled=", g_Enabled);

   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   DeletePanel();

   // Only forget the saved Auto TPSL state when the EA is genuinely
   // removed from the chart - a timeframe/symbol change (REASON_CHARTCHANGE)
   // or a recompile/parameter change should keep it around so the next
   // OnInit picks the state back up instead of reverting to the input.
   if(reason == REASON_REMOVE)
     {
      string gvName = GetAutoTPSLGVName();
      if(GlobalVariableCheck(gvName))
         GlobalVariableDel(gvName);

      string lotGvName = GetLotSizeGVName();
      if(GlobalVariableCheck(lotGvName))
         GlobalVariableDel(lotGvName);
     }
  }

void OnTick()
  {
   if(!g_Enabled)
     {
      if(PositionsTotal() != ArraySize(knownTickets))
         RefreshKnownTickets();
      return;
     }

   ProcessNewPositions();

   if(EnableSLCover)
      ProcessSLCover();
  }

void OnTimer()
  {
   UpdatePanelInfo();
  }

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
      else if(sparam == MKT_BTN_NAME)
        {
         // Toggle the symbol dropdown list open/closed
         if(g_marketOpen)
            CloseMarketList();
         else
            OpenMarketList();
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
        }
      else if(StringFind(sparam, PFX+"mktRow") == 0)
        {
         // One of the dropdown's symbol rows was clicked
         int idx = (int)StringToInteger(StringSubstr(sparam, StringLen(PFX+"mktRow")));
         string sym = SymbolName(idx, true);
         SwitchMarket(sym);
        }
      else if(sparam == ATP_BTN_NAME)
        {
         g_Enabled = !g_Enabled;
         GlobalVariableSet(GetAutoTPSLGVName(), g_Enabled ? 1.0 : 0.0);
         ObjectSetInteger(0, ATP_BTN_NAME, OBJPROP_STATE, false);
         UpdateToggleButtonVisual();

         g_status = StringFormat("Auto TPSL %s", g_Enabled ? "ENABLED" : "DISABLED");
         Print("Auto TPSL ", (g_Enabled ? "ENABLED" : "DISABLED"), " via panel button.");

         if(g_Enabled)
            ApplyToAllExistingPositions(); // apply immediately instead of waiting for the next new position

         RefreshKnownTickets(); // resync so re-enabling doesn't treat everything as "new"
         UpdatePanelInfo();
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