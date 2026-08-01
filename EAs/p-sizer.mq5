//+------------------------------------------------------------------+
//|                                            PositionSizerEA.mq5   |
//|   Position-sizing trade panel with draggable Entry/TP/SL lines  |
//|   - 6 order types: Buy/Sell Market, Buy/Sell Stop, Buy/Sell Limit|
//|   - Risk sizing modes: Lots, $/Pip, % of Balance, Fixed Amount   |
//|   - RRR auto-calculates TP from SL (or shows RRR when you drag  |
//|     TP yourself)                                                 |
//|   - Lines <-> edit boxes stay in sync both directions            |
//|   - Market orders: Entry line is LOCKED and follows live Bid/Ask |
//|   - Pending orders: Entry line is draggable and stays put        |
//+------------------------------------------------------------------+
#property copyright "Position Sizer (Sverfund)"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//--------------------------------------------------------------------
// INPUTS
//--------------------------------------------------------------------
input ulong  InpMagic            = 990011;
input int    InpSlippagePoints   = 5;
input string InpOrderComment     = "PositionSizerEA";
input double InpDefaultSLPoints  = 5000;     // default SL distance on init
input double InpDefaultRRR       = 1.0;     // default risk:reward ratio
input double InpDefaultRiskValue = 0.01;    // default value in the risk box

//--------------------------------------------------------------------
// RISK MODES
//--------------------------------------------------------------------
enum RiskMode
  {
   RISK_LOTS    = 0,   // fixed lot size
   RISK_PIPS    = 1,   // fixed $ risk per pip
   RISK_PERCENT = 2,   // % of account balance
   RISK_AMOUNT  = 3    // fixed money amount
  };
string RiskModeLabel(RiskMode m)
  {
   switch(m)
     {
      case RISK_LOTS:    return "Lots";
      case RISK_PIPS:    return "$/Pip";
      case RISK_PERCENT: return "% Balance";
      case RISK_AMOUNT:  return "Amount $";
     }
   return "Lots";
  }

//--------------------------------------------------------------------
// ORDER TYPES (panel selection, -1 = none chosen yet)
//--------------------------------------------------------------------
#define OT_BUY        0
#define OT_SELL       1
#define OT_BUYSTOP    2
#define OT_SELLSTOP   3
#define OT_BUYLIMIT   4
#define OT_SELLLIMIT  5

bool IsBuyType(int t)  { return (t==OT_BUY || t==OT_BUYSTOP || t==OT_BUYLIMIT); }
bool IsMarketType(int t){ return (t==OT_BUY || t==OT_SELL); }

//--------------------------------------------------------------------
// GLOBAL STATE
//--------------------------------------------------------------------
string   PFX = "PSZ_";
RiskMode g_riskMode   = RISK_LOTS;
int      g_orderType  = -1;
double   g_riskValue;
double   g_rrr;
double   g_entryPrice, g_slPrice, g_tpPrice;
bool     g_syncing   = false;   // guard against feedback loops
bool     g_linesExist = false;  // lines only exist once an order type is picked

// z-order: panel controls must sit ABOVE the price lines or clicks on the
// panel get intercepted by an OBJ_HLINE crossing underneath it.
#define ZORDER_LINE  1
#define ZORDER_TEXT  2
#define ZORDER_RECT  10
#define ZORDER_LABEL 20
#define ZORDER_CTRL  50

//--------------------------------------------------------------------
// OBJECT NAME HELPERS
//--------------------------------------------------------------------
string N(string s){ return PFX+s; }

string LineEntry(){ return N("LineEntry"); }
string LineSL()   { return N("LineSL");    }
string LineTP()   { return N("LineTP");    }
string TxtEntry() { return N("TxtEntry");  }
string TxtSL()    { return N("TxtSL");     }
string TxtTP()    { return N("TxtTP");     }
string BgEntry()  { return N("BgEntry");   }
string BgSL()     { return N("BgSL");      }
string BgTP()     { return N("BgTP");      }

string EditRisk()  { return N("EditRisk");  }
string EditRRR()   { return N("EditRRR");   }
string EditEntry() { return N("EditEntry"); }
string EditSL()    { return N("EditSL");    }
string EditTP()    { return N("EditTP");    }

string BtnRiskMode(){ return N("BtnRiskMode"); }
string LblRiskMode(){ return N("LblRiskMode"); }
string LblInfo()    { return N("LblInfo");     }

string BtnBuy()       { return N("BtnBuy");       }
string BtnSell()      { return N("BtnSell");      }
string BtnBuyStop()   { return N("BtnBuyStop");   }
string BtnSellStop()  { return N("BtnSellStop");  }
string BtnBuyLimit()  { return N("BtnBuyLimit");  }
string BtnSellLimit() { return N("BtnSellLimit"); }
string BtnSend()      { return N("BtnSend");      }
string BtnCancel()    { return N("BtnCancel");    }

//--------------------------------------------------------------------
// GENERIC OBJECT CREATION HELPERS
//--------------------------------------------------------------------
void CreateRect(string name,int x,int y,int w,int h,color bg,color border)
  {
   ObjectCreate(0,name,OBJ_RECTANGLE_LABEL,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(0,name,OBJPROP_COLOR,border);
   ObjectSetInteger(0,name,OBJPROP_BORDER_TYPE,BORDER_FLAT);
   ObjectSetInteger(0,name,OBJPROP_STYLE,STYLE_SOLID);
   ObjectSetInteger(0,name,OBJPROP_BACK,false);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,name,OBJPROP_ZORDER,ZORDER_RECT);
  }

void CreateLabel(string name,int x,int y,string text,color clr,int fontsize=9,string font="Arial")
  {
   ObjectCreate(0,name,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetString(0,name,OBJPROP_TEXT,text);
   ObjectSetString(0,name,OBJPROP_FONT,font);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,fontsize);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,name,OBJPROP_ZORDER,ZORDER_LABEL);
  }

void CreateEdit(string name,int x,int y,int w,int h,string text)
  {
   ObjectCreate(0,name,OBJ_EDIT,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,h);
   ObjectSetString(0,name,OBJPROP_TEXT,text);
   ObjectSetInteger(0,name,OBJPROP_ALIGN,ALIGN_CENTER);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clrBlack);
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,clrWhite);
   ObjectSetInteger(0,name,OBJPROP_BORDER_COLOR,clrGray);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,9);
   ObjectSetInteger(0,name,OBJPROP_READONLY,false);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,name,OBJPROP_ZORDER,ZORDER_CTRL);
  }

void CreateButton(string name,int x,int y,int w,int h,string text,color bg,color txtclr)
  {
   ObjectCreate(0,name,OBJ_BUTTON,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,h);
   ObjectSetString(0,name,OBJPROP_TEXT,text);
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(0,name,OBJPROP_COLOR,txtclr);
   ObjectSetInteger(0,name,OBJPROP_BORDER_COLOR,clrBlack);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,9);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_STATE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,name,OBJPROP_ZORDER,ZORDER_CTRL);
  }

void CreateHLine(string name,double price,color clr,int style,int width)
  {
   ObjectCreate(0,name,OBJ_HLINE,0,0,price);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,name,OBJPROP_STYLE,style);
   ObjectSetInteger(0,name,OBJPROP_WIDTH,width);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,true);
   ObjectSetInteger(0,name,OBJPROP_SELECTED,true);   // pre-selected -> draggable immediately, no extra click needed
   ObjectSetInteger(0,name,OBJPROP_BACK,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,false);
   ObjectSetInteger(0,name,OBJPROP_ZORDER,ZORDER_LINE);
  }

void CreatePriceText(string name,double price,color clr)
  {
   datetime t = iTime(_Symbol,PERIOD_CURRENT,0) + PeriodSeconds(PERIOD_CURRENT)*4;
   ObjectCreate(0,name,OBJ_TEXT,0,t,price);
   ObjectSetString(0,name,OBJPROP_TEXT,"");
   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,8);
   ObjectSetInteger(0,name,OBJPROP_ANCHOR,ANCHOR_LEFT);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,name,OBJPROP_ZORDER,ZORDER_TEXT);
  }

void MovePriceText(string name,double price)
  {
   datetime t = iTime(_Symbol,PERIOD_CURRENT,0) + PeriodSeconds(PERIOD_CURRENT)*4;
   ObjectMove(0,name,0,t,price);
  }

// small pixel-anchored backing rectangle that sits behind ONE text tag
// (not the whole horizontal line) so the price/risk readout stays legible
// over candles. Must be created BEFORE its matching CreatePriceText() call
// so the text paints on top of it (foreground objects paint in creation order).
void CreateTextBg(string name,color bg)
  {
   ObjectCreate(0,name,OBJ_RECTANGLE_LABEL,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,0);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,0);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,10);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,10);
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(0,name,OBJPROP_COLOR,bg);
   ObjectSetInteger(0,name,OBJPROP_BORDER_TYPE,BORDER_FLAT);
   ObjectSetInteger(0,name,OBJPROP_BACK,false);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,name,OBJPROP_ZORDER,ZORDER_TEXT);
  }

// resizes/repositions a text's backing rectangle to exactly fit the text's
// current pixel size and screen location (tracks scroll/zoom correctly)
void PositionTextBg(string bgName,string txtName,double price)
  {
   datetime t = iTime(_Symbol,PERIOD_CURRENT,0) + PeriodSeconds(PERIOD_CURRENT)*4;
   int x=0, y=0;
   if(!ChartTimePriceToXY(0,0,t,price,x,y)) return;

   string txt = ObjectGetString(0,txtName,OBJPROP_TEXT);
   int fontsize = (int)ObjectGetInteger(0,txtName,OBJPROP_FONTSIZE);
   TextSetFont("Arial",-(fontsize*10));
   uint tw=0, th=0;
   TextGetSize(txt,tw,th);

   int padX=4, padY=2;
   int w = (int)tw + padX*2;
   int h = (int)th + padY*2;
   if(w<4) w=4;
   if(h<4) h=4;

   ObjectSetInteger(0,bgName,OBJPROP_XDISTANCE,x-padX);
   ObjectSetInteger(0,bgName,OBJPROP_YDISTANCE,y-h/2);
   ObjectSetInteger(0,bgName,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,bgName,OBJPROP_YSIZE,h);
  }

//--------------------------------------------------------------------
// SYMBOL MATH HELPERS
//--------------------------------------------------------------------
double PointVal()  { return SymbolInfoDouble(_Symbol,SYMBOL_POINT); }
int    DigitsVal() { return (int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS); }

double PipSize()
  {
   int d = DigitsVal();
   double p = PointVal();
   return (d==3 || d==5) ? p*10.0 : p;
  }

// money earned/lost per 1.0 lot per 1 point of price movement
double MoneyPerPoint()
  {
   double tickValue = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tickSize<=0) tickSize = PointVal();
   return tickValue/tickSize*PointVal();
  }

double MoneyPerPip() { return MoneyPerPoint() * (PipSize()/PointVal()); }

double NormalizeLots(double lots)
  {
   double minLot = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(step<=0) step = 0.01;
   lots = MathRound(lots/step)*step;
   lots = MathMax(minLot,MathMin(maxLot,lots));
   return NormalizeDouble(lots,2);
  }

double CalcLots()
  {
   double slPoints = MathAbs(g_entryPrice-g_slPrice)/PointVal();
   double moneyPerPt = MoneyPerPoint();
   double lots = 0;

   switch(g_riskMode)
     {
      case RISK_LOTS:
         lots = g_riskValue;
         break;
      case RISK_PIPS:
        {
         double mpp = MoneyPerPip();
         if(mpp>0) lots = g_riskValue/mpp;
         break;
        }
      case RISK_PERCENT:
        {
         double bal = AccountInfoDouble(ACCOUNT_BALANCE);
         double riskMoney = bal*g_riskValue/100.0;
         if(slPoints>0 && moneyPerPt>0) lots = riskMoney/(slPoints*moneyPerPt);
         break;
        }
      case RISK_AMOUNT:
         if(slPoints>0 && moneyPerPt>0) lots = g_riskValue/(slPoints*moneyPerPt);
         break;
     }
   return NormalizeLots(lots);
  }

//--------------------------------------------------------------------
// STRING <-> DOUBLE HELPERS
//--------------------------------------------------------------------
double EditVal(string name) { return StringToDouble(ObjectGetString(0,name,OBJPROP_TEXT)); }
void   SetEditVal(string name,double v,int digits) { ObjectSetString(0,name,OBJPROP_TEXT,DoubleToString(v,digits)); }
void   SetEditText(string name,string s) { ObjectSetString(0,name,OBJPROP_TEXT,s); }

//--------------------------------------------------------------------
// PANEL BUILD
//--------------------------------------------------------------------
// MT5 draws foreground objects in creation order (ZORDER only affects
// click priority, not paint order). The panel is built once in OnInit,
// but the price lines are created later - so they'd normally paint on
// top of the panel. DeletePanelObjects()+BuildPanel() recreates every
// panel object fresh, making the panel the most-recently-created
// foreground object again so it paints above the lines.
void DeletePanelObjects()
  {
   ObjectDelete(0,N("BG"));
   ObjectDelete(0,N("Title"));
   ObjectDelete(0,N("LblBidAsk"));
   ObjectDelete(0,BtnRiskMode());
   ObjectDelete(0,EditRisk());
   ObjectDelete(0,N("LblRRR"));
   ObjectDelete(0,EditRRR());
   ObjectDelete(0,N("LblEntry"));
   ObjectDelete(0,EditEntry());
   ObjectDelete(0,N("LblSL"));
   ObjectDelete(0,EditSL());
   ObjectDelete(0,N("LblTP"));
   ObjectDelete(0,EditTP());
   ObjectDelete(0,LblInfo());
   ObjectDelete(0,BtnBuy());
   ObjectDelete(0,BtnSell());
   ObjectDelete(0,BtnBuyStop());
   ObjectDelete(0,BtnSellStop());
   ObjectDelete(0,BtnBuyLimit());
   ObjectDelete(0,BtnSellLimit());
   ObjectDelete(0,BtnSend());
   ObjectDelete(0,BtnCancel());
  }

void RaisePanelToFront()
  {
   DeletePanelObjects();
   BuildPanel();              // recreated last -> paints on top of the lines
   RefreshEdits();
   UpdateBidAskLabel();
   UpdateInfoLabel();
   HighlightOrderTypeButtons();
   ChartRedraw(0);
  }

void BuildPanel()
  {
   color panelBg = C'20,22,30';
   color panelBorder = clrDimGray;
   int px=10, py=10, pw=340, ph=430;

   CreateRect(N("BG"),px,py,pw,ph,panelBg,panelBorder);
   CreateLabel(N("Title"),px+10,py+7,"Position Sizer (Sverfund)",clrWhite,11,"Arial Bold");
   CreateLabel(N("LblBidAsk"),px+10,py+25,"Bid --   Ask --",clrSilver,8);

   int rowY = py+46;
   // Risk mode button + value edit
   CreateButton(BtnRiskMode(),px+10,rowY,140,24,"Risk: "+RiskModeLabel(g_riskMode),clrSteelBlue,clrWhite);
   CreateEdit(EditRisk(),px+158,rowY,160,24,DoubleToString(g_riskValue,2));
   rowY += 32;

   CreateLabel(N("LblRRR"),px+10,rowY+5,"RRR",clrSilver,9);
   CreateEdit(EditRRR(),px+158,rowY,160,24,DoubleToString(g_rrr,2));
   rowY += 32;

   CreateLabel(N("LblEntry"),px+10,rowY+5,"Entry",clrSilver,9);
   CreateEdit(EditEntry(),px+158,rowY,160,24,DoubleToString(g_entryPrice,DigitsVal()));
   rowY += 32;

   CreateLabel(N("LblSL"),px+10,rowY+5,"SL (Stop Loss)",clrSilver,9);
   CreateEdit(EditSL(),px+158,rowY,160,24,DoubleToString(g_slPrice,DigitsVal()));
   rowY += 32;

   CreateLabel(N("LblTP"),px+10,rowY+5,"TP (Take Profit)",clrSilver,9);
   CreateEdit(EditTP(),px+158,rowY,160,24,DoubleToString(g_tpPrice,DigitsVal()));
   rowY += 34;

   CreateLabel(LblInfo(),px+10,rowY,"Lots: --  Risk: --  RRR: --",clrKhaki,9);
   rowY += 26;

   // order type buttons (2 x 3 grid)
   int bw=155, bh=30, gap=10;
   CreateButton(BtnBuy(),      px+10,          rowY,       bw,bh,"Buy (Market)", clrForestGreen, clrWhite);
   CreateButton(BtnSell(),     px+10+bw+gap,   rowY,       bw,bh,"Sell (Market)",clrFireBrick,   clrWhite);
   rowY += bh+6;
   CreateButton(BtnBuyStop(),  px+10,          rowY,       bw,bh,"Buy Stop",     clrDarkGreen,   clrWhite);
   CreateButton(BtnSellStop(), px+10+bw+gap,   rowY,       bw,bh,"Sell Stop",    clrDarkRed,     clrWhite);
   rowY += bh+6;
   CreateButton(BtnBuyLimit(), px+10,          rowY,       bw,bh,"Buy Limit",    clrDarkGreen,   clrWhite);
   CreateButton(BtnSellLimit(),px+10+bw+gap,   rowY,       bw,bh,"Sell Limit",   clrDarkRed,     clrWhite);
   rowY += bh+14;

   CreateButton(BtnSend(),   px+10,        rowY,bw,32,"SEND ORDER",clrDodgerBlue,clrWhite);
   CreateButton(BtnCancel(), px+10+bw+gap, rowY,bw,32,"CANCEL",clrSlateGray,clrWhite);

   ChartRedraw(0);
  }

void HighlightOrderTypeButtons()
  {
   string names[6] = {BtnBuy(),BtnSell(),BtnBuyStop(),BtnSellStop(),BtnBuyLimit(),BtnSellLimit()};
   for(int i=0;i<6;i++)
     {
      bool isBuyBtn = (i%2==0);
      color normalClr = isBuyBtn ? (i==0?clrForestGreen:clrDarkGreen) : (i==1?clrFireBrick:clrDarkRed);
      color hiClr = clrOrange;
      ObjectSetInteger(0,names[i],OBJPROP_BGCOLOR, (g_orderType==i) ? hiClr : normalClr);
     }
   ChartRedraw(0);
  }

//--------------------------------------------------------------------
// LINES / TEXT SYNC
//--------------------------------------------------------------------
void BuildLines()
  {
   CreateHLine(LineEntry(), g_entryPrice, clrYellow,     STYLE_DASH, 2);
   CreateHLine(LineSL(),    g_slPrice,    clrRed,        STYLE_DASH, 2);
   CreateHLine(LineTP(),    g_tpPrice,    clrLimeGreen,  STYLE_DASH, 2);

   color tagBg = C'25,25,25';
   CreateTextBg(BgEntry(),tagBg);
   CreatePriceText(TxtEntry(), g_entryPrice, clrYellow);
   CreateTextBg(BgSL(),tagBg);
   CreatePriceText(TxtSL(),    g_slPrice,    clrRed);
   CreateTextBg(BgTP(),tagBg);
   CreatePriceText(TxtTP(),    g_tpPrice,    clrLimeGreen);

   // force a redraw so the chart's internal time/price->pixel mapping is
   // up to date before we measure pixel positions for the backgrounds
   ChartRedraw(0);

   PositionTextBg(BgEntry(),TxtEntry(),g_entryPrice);
   PositionTextBg(BgSL(),TxtSL(),g_slPrice);
   PositionTextBg(BgTP(),TxtTP(),g_tpPrice);
  }

void RemoveLines()
  {
   ObjectDelete(0,LineEntry());
   ObjectDelete(0,LineSL());
   ObjectDelete(0,LineTP());
   ObjectDelete(0,TxtEntry());
   ObjectDelete(0,TxtSL());
   ObjectDelete(0,TxtTP());
   ObjectDelete(0,BgEntry());
   ObjectDelete(0,BgSL());
   ObjectDelete(0,BgTP());
   g_linesExist = false;
   ChartRedraw(0);
  }

// Locks/unlocks the Entry line for dragging. Market orders (Buy/Sell) are
// locked because the entry price isn't user-chosen - it's whatever the
// live market gives you. Pending orders (Stop/Limit) stay draggable.
void SetEntryLineDraggable(bool draggable)
  {
   if(!g_linesExist) return;
   ObjectSetInteger(0,LineEntry(),OBJPROP_SELECTABLE,draggable);
   ObjectSetInteger(0,LineEntry(),OBJPROP_SELECTED,draggable);
   // dashed = editable (pending), solid = locked/following (market) - quick visual cue
   ObjectSetInteger(0,LineEntry(),OBJPROP_STYLE, draggable ? STYLE_DASH : STYLE_SOLID);
  }

void EnsureLinesExist()
  {
   if(!g_linesExist)
     {
      BuildLines();
      g_linesExist = true;
      RaisePanelToFront();   // panel was just outdrawn by the new lines - repaint it on top
     }
   // re-applied every time an order type is (re)selected, so switching
   // e.g. Buy -> Buy Stop correctly unlocks the entry line even though
   // the lines already existed
   SetEntryLineDraggable(!IsMarketType(g_orderType));
  }

// Bid/Ask readout - always safe to call, independent of lines/order type
void UpdateBidAskLabel()
  {
   double bid = SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   int    d   = DigitsVal();
   double spreadPts = (PointVal()>0) ? (ask-bid)/PointVal() : 0;
   string txt = StringFormat("Bid %s   Ask %s   Spread %.1f pt",
                DoubleToString(bid,d),DoubleToString(ask,d),spreadPts);
   ObjectSetString(0,N("LblBidAsk"),OBJPROP_TEXT,txt);
  }

// Lots / risk $ / RRR readout - always safe to call even before lines exist
void UpdateInfoLabel()
  {
   double lots = CalcLots();
   double moneyPerPt = MoneyPerPoint();
   double slPts = MathAbs(g_entryPrice-g_slPrice)/PointVal();
   double riskMoney = lots*slPts*moneyPerPt;
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskPct = (bal>0) ? riskMoney/bal*100.0 : 0;

   string infoTxt = (g_orderType==-1)
      ? "Select an order type below to place the Entry/SL/TP lines"
      : StringFormat("Lots: %.2f   Risk: %s USD (%.2f%%)   RRR: %s",
                      lots, DoubleToString(riskMoney,2), riskPct, DoubleToString(g_rrr,2));
   ObjectSetString(0,LblInfo(),OBJPROP_TEXT,infoTxt);
  }

// Floating price tags next to each line - only relevant once lines exist
void UpdatePriceTags()
  {
   if(!g_linesExist) return;

   int d = DigitsVal();
   double moneyPerPt = MoneyPerPoint();
   double lots = CalcLots();

   double slPts = MathAbs(g_entryPrice-g_slPrice)/PointVal();
   double tpPts = MathAbs(g_tpPrice-g_entryPrice)/PointVal();
   double riskMoney = lots*slPts*moneyPerPt;
   double rewardMoney = lots*tpPts*moneyPerPt;
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskPct = (bal>0) ? riskMoney/bal*100.0 : 0;
   double rewardPct = (bal>0) ? rewardMoney/bal*100.0 : 0;

   string entryTag = IsMarketType(g_orderType)
      ? StringFormat("Entry %s (live)",DoubleToString(g_entryPrice,d))
      : StringFormat("Entry %s",DoubleToString(g_entryPrice,d));

   ObjectSetString(0,TxtEntry(),OBJPROP_TEXT,entryTag);
   ObjectSetString(0,TxtSL(),OBJPROP_TEXT,
      StringFormat("SL %s | -%s USD | -%.2f%%",DoubleToString(g_slPrice,d),DoubleToString(riskMoney,2),riskPct));
   ObjectSetString(0,TxtTP(),OBJPROP_TEXT,
      StringFormat("TP %s | +%s USD | +%.2f%%",DoubleToString(g_tpPrice,d),DoubleToString(rewardMoney,2),rewardPct));

   MovePriceText(TxtEntry(),g_entryPrice);
   MovePriceText(TxtSL(),g_slPrice);
   MovePriceText(TxtTP(),g_tpPrice);

   // force a redraw so the time/price->pixel mapping reflects the moved
   // lines/text and any chart rescale before we measure pixel positions -
   // otherwise the background rectangles compute against stale geometry
   // and visibly lag behind the line/text they're supposed to sit under
   ChartRedraw(0);

   PositionTextBg(BgEntry(),TxtEntry(),g_entryPrice);
   PositionTextBg(BgSL(),TxtSL(),g_slPrice);
   PositionTextBg(BgTP(),TxtTP(),g_tpPrice);
  }

// push internal state -> edit boxes (without re-triggering events)
void RefreshEdits()
  {
   int d = DigitsVal();
   SetEditVal(EditEntry(),g_entryPrice,d);
   SetEditVal(EditSL(),g_slPrice,d);
   SetEditVal(EditTP(),g_tpPrice,d);
   SetEditVal(EditRRR(),g_rrr,2);
   SetEditVal(EditRisk(),g_riskValue,2);
   ObjectSetString(0,BtnRiskMode(),OBJPROP_TEXT,"Risk: "+RiskModeLabel(g_riskMode));
   // for market orders the entry box just mirrors the live price - grey it out visually
   ObjectSetInteger(0,EditEntry(),OBJPROP_READONLY, IsMarketType(g_orderType));
   ObjectSetInteger(0,EditEntry(),OBJPROP_BGCOLOR, IsMarketType(g_orderType) ? clrGainsboro : clrWhite);
  }

void MoveLine(string name,double price)
  {
   ObjectSetDouble(0,name,OBJPROP_PRICE,price);
  }

//--------------------------------------------------------------------
// REACTION LOGIC (keeps Entry/SL/TP/RRR consistent)
//--------------------------------------------------------------------
// Keeps a pending order's entry on the side of price it's required to be
// on: Buy/Sell Stop must sit beyond current Ask/Bid, Buy/Sell Limit must
// sit inside it. Also respects the broker's minimum stop distance where
// available. Returns true if g_entryPrice was moved. No-op for market
// orders (they already track live price every tick) and when no order
// type is selected.
bool ClampEntryForOrderType()
  {
   if(g_orderType==-1 || IsMarketType(g_orderType)) return false;

   double bid = SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double stopsPts = (double)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = MathMax(stopsPts,1.0)*PointVal();   // at least 1 point clear of price
   double before = g_entryPrice;

   switch(g_orderType)
     {
      case OT_BUYSTOP:                                   // entry must stay ABOVE Ask
         if(g_entryPrice < ask+minDist)  g_entryPrice = ask+minDist;
         break;
      case OT_SELLSTOP:                                  // entry must stay BELOW Bid
         if(g_entryPrice > bid-minDist)  g_entryPrice = bid-minDist;
         break;
      case OT_BUYLIMIT:                                  // entry must stay BELOW Bid
         if(g_entryPrice > bid-minDist)  g_entryPrice = bid-minDist;
         break;
      case OT_SELLLIMIT:                                 // entry must stay ABOVE Ask
         if(g_entryPrice < ask+minDist)  g_entryPrice = ask+minDist;
         break;
     }
   return (g_entryPrice != before);
  }

void RecalcTPFromRRR()
  {
   double risk = MathAbs(g_entryPrice-g_slPrice);
   double reward = risk*g_rrr;
   bool buyBias = IsBuyType(g_orderType);
   if(g_orderType==-1) buyBias = (g_slPrice < g_entryPrice); // infer direction
   g_tpPrice = buyBias ? g_entryPrice+reward : g_entryPrice-reward;
  }

void RecalcRRRFromTP()
  {
   double risk = MathAbs(g_entryPrice-g_slPrice);
   double reward = MathAbs(g_tpPrice-g_entryPrice);
   g_rrr = (risk>0) ? reward/risk : 0;
  }

void OnEntryChanged()
  {
   ClampEntryForOrderType();   // snap back onto the valid side before syncing
   RecalcRRRFromTP();
   SyncAll();
  }

void OnSLChanged()
  {
   RecalcTPFromRRR();
   SyncAll();
  }

void OnTPChanged()
  {
   RecalcRRRFromTP();
   SyncAll();
  }

void OnRRRChanged()
  {
   RecalcTPFromRRR();
   SyncAll();
  }

void OnRiskValueChanged()
  {
   SyncAll();
  }

// full refresh: move lines (if they exist), update edit boxes, update info text
void SyncAll()
  {
   if(g_syncing) return;
   g_syncing = true;

   if(g_linesExist)
     {
      MoveLine(LineEntry(),g_entryPrice);
      MoveLine(LineSL(),g_slPrice);
      MoveLine(LineTP(),g_tpPrice);
      // let the chart's internal geometry (and any auto-rescale triggered
      // by these new prices) settle BEFORE UpdatePriceTags() measures pixel
      // positions for the label backgrounds - otherwise the backgrounds
      // are positioned against stale geometry and visibly lag behind the
      // lines/text while dragging
      ChartRedraw(0);
     }

   RefreshEdits();
   UpdateInfoLabel();
   UpdatePriceTags();
   ChartRedraw(0);

   g_syncing = false;
  }

//--------------------------------------------------------------------
// ORDER SENDING
//--------------------------------------------------------------------
void ResetPanel();   // forward declaration - defined below, used in SendOrder()

void SendOrder()
  {
   if(g_orderType==-1)
     {
      Alert("Pick an order type first (Buy, Sell, Buy Stop, ...)");
      return;
     }

   double lots = CalcLots();
   if(lots<=0)
     {
      Alert("Computed lot size is 0 - check your risk value / SL distance.");
      return;
     }

   double sl = g_slPrice;
   double tp = g_tpPrice;
   int d = DigitsVal();
   sl = NormalizeDouble(sl,d);
   tp = NormalizeDouble(tp,d);

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);

   bool ok=false;
   double ask = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol,SYMBOL_BID);

   switch(g_orderType)
     {
      case OT_BUY:
         ok = trade.Buy(lots,_Symbol,0,sl,tp,InpOrderComment);
         break;
      case OT_SELL:
         ok = trade.Sell(lots,_Symbol,0,sl,tp,InpOrderComment);
         break;
      case OT_BUYSTOP:
         if(g_entryPrice<=ask) { Alert("Buy Stop entry must be ABOVE current Ask ("+DoubleToString(ask,d)+")"); return; }
         ok = trade.BuyStop(lots,NormalizeDouble(g_entryPrice,d),_Symbol,sl,tp,ORDER_TIME_GTC,0,InpOrderComment);
         break;
      case OT_SELLSTOP:
         if(g_entryPrice>=bid) { Alert("Sell Stop entry must be BELOW current Bid ("+DoubleToString(bid,d)+")"); return; }
         ok = trade.SellStop(lots,NormalizeDouble(g_entryPrice,d),_Symbol,sl,tp,ORDER_TIME_GTC,0,InpOrderComment);
         break;
      case OT_BUYLIMIT:
         if(g_entryPrice>=bid) { Alert("Buy Limit entry must be BELOW current Bid ("+DoubleToString(bid,d)+")"); return; }
         ok = trade.BuyLimit(lots,NormalizeDouble(g_entryPrice,d),_Symbol,sl,tp,ORDER_TIME_GTC,0,InpOrderComment);
         break;
      case OT_SELLLIMIT:
         if(g_entryPrice<=ask) { Alert("Sell Limit entry must be ABOVE current Ask ("+DoubleToString(ask,d)+")"); return; }
         ok = trade.SellLimit(lots,NormalizeDouble(g_entryPrice,d),_Symbol,sl,tp,ORDER_TIME_GTC,0,InpOrderComment);
         break;
     }

   if(!ok)
      Alert("Order failed: ",trade.ResultRetcodeDescription()," (",trade.ResultRetcode(),")");
   else
     {
      Print("Order sent OK. Lots=",lots," Entry=",g_entryPrice," SL=",sl," TP=",tp);
      // order is away - clear the lines/order-type selection until the
      // user picks another order type. Keep them on a failed send so
      // they can see and adjust before retrying.
      ResetPanel();
     }
  }

void ResetPanel()
  {
   g_orderType = -1;
   RemoveLines();          // lines only appear again once a type is picked
   HighlightOrderTypeButtons();

   double price = SymbolInfoDouble(_Symbol,SYMBOL_BID);
   g_entryPrice = price;
   g_slPrice    = price - InpDefaultSLPoints*PointVal();
   g_rrr        = InpDefaultRRR;
   RecalcTPFromRRR();
   RefreshEdits();
   SyncAll();
  }

//--------------------------------------------------------------------
// EXPERT LIFECYCLE
//--------------------------------------------------------------------
int OnInit()
  {
   g_riskMode  = RISK_LOTS;
   g_riskValue = InpDefaultRiskValue;
   g_rrr       = InpDefaultRRR;
   g_orderType = -1;
   g_linesExist = false;

   double price = SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(price<=0) price = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   g_entryPrice = price;
   g_slPrice    = price - InpDefaultSLPoints*PointVal();
   RecalcTPFromRRR();

   BuildPanel();          // no lines yet - only appear once you pick a type
   HighlightOrderTypeButtons();
   RefreshEdits();
   UpdateBidAskLabel();
   UpdateInfoLabel();
   ChartRedraw(0);

   // Object drag competes with chart-drag-to-scroll; turning scroll off
   // means a click-drag on a line always moves the line, not the chart.
   ChartSetInteger(0,CHART_MOUSE_SCROLL,false);

   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   ObjectsDeleteAll(0,PFX);
   ChartSetInteger(0,CHART_MOUSE_SCROLL,true);   // restore normal chart behavior
   ChartRedraw(0);
  }

void OnTick()
  {
   // keep Bid/Ask and the $ / % readouts current
   static datetime lastRefresh=0;
   if(TimeCurrent()!=lastRefresh)
     {
      lastRefresh = TimeCurrent();

      // Market orders: the entry price isn't something you choose, it's
      // whatever the market gives you when SEND is pressed. So keep the
      // entry line/price locked to live Ask (buy) or Bid (sell) instead
      // of letting it sit stale. SL/TP are left where they are; only
      // the entry - and the RRR/lots figures derived from it - update.
      if(g_linesExist && IsMarketType(g_orderType))
        {
         double livePrice = IsBuyType(g_orderType)
                             ? SymbolInfoDouble(_Symbol,SYMBOL_ASK)
                             : SymbolInfoDouble(_Symbol,SYMBOL_BID);
         if(livePrice>0)
           {
            g_entryPrice = livePrice;
            OnEntryChanged();   // recalcs RRR from TP, moves the line, refreshes edits/tags
           }
        }
      // Pending orders: the entry you set can become invalid if price
      // moves through it (e.g. a Buy Stop placed above Ask, then price
      // rallies past it). Re-clamp every tick so the line/edit box never
      // sits on the wrong side of the market.
      else if(g_linesExist && g_orderType!=-1 && ClampEntryForOrderType())
        {
         RecalcRRRFromTP();
         SyncAll();
        }

      UpdateBidAskLabel();
      UpdateInfoLabel();
      UpdatePriceTags();
      ChartRedraw(0);
     }
  }

//--------------------------------------------------------------------
// CHART EVENTS
//--------------------------------------------------------------------
void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
  {
   // Fired on resize, scroll, zoom, and other geometry changes - including
   // while the market is closed and no ticks are coming in. Without this,
   // the price-tag background rectangles (which are pixel-anchored, unlike
   // the time/price-anchored line/text objects) never get repositioned
   // after a resize when there's no tick to trigger OnTick()'s refresh.
   if(id==CHARTEVENT_CHART_CHANGE)
     {
      if(g_linesExist)
        {
         UpdatePriceTags();
         ChartRedraw(0);
        }
      return;
     }

   if(id==CHARTEVENT_OBJECT_DRAG)
     {
      // Entry line is locked (not selectable) for market orders, so this
      // branch only ever fires for entry when it's a pending order.
      if(sparam==LineEntry())
        {
         g_entryPrice = ObjectGetDouble(0,LineEntry(),OBJPROP_PRICE);
         OnEntryChanged();
        }
      else if(sparam==LineSL())
        {
         g_slPrice = ObjectGetDouble(0,LineSL(),OBJPROP_PRICE);
         OnSLChanged();
        }
      else if(sparam==LineTP())
        {
         g_tpPrice = ObjectGetDouble(0,LineTP(),OBJPROP_PRICE);
         OnTPChanged();
        }
      return;
     }

   if(id==CHARTEVENT_OBJECT_ENDEDIT)
     {
      if(sparam==EditEntry())
        {
         // entry box is read-only for market orders (see RefreshEdits),
         // so this only takes effect for pending orders
         if(!IsMarketType(g_orderType))
           {
            g_entryPrice = EditVal(EditEntry());
            OnEntryChanged();
           }
        }
      else if(sparam==EditSL())
        {
         g_slPrice = EditVal(EditSL());
         OnSLChanged();
        }
      else if(sparam==EditTP())
        {
         g_tpPrice = EditVal(EditTP());
         OnTPChanged();
        }
      else if(sparam==EditRRR())
        {
         g_rrr = EditVal(EditRRR());
         OnRRRChanged();
        }
      else if(sparam==EditRisk())
        {
         g_riskValue = EditVal(EditRisk());
         OnRiskValueChanged();
        }
      return;
     }

   if(id==CHARTEVENT_OBJECT_CLICK)
     {
      if(sparam==BtnRiskMode())
        {
         int m = (int)g_riskMode;
         m = (m+1) % 4;
         g_riskMode = (RiskMode)m;
         ObjectSetInteger(0,BtnRiskMode(),OBJPROP_STATE,false);
         RefreshEdits();
         UpdateInfoLabel();
         UpdatePriceTags();
         ChartRedraw(0);
         return;
        }

      if(sparam==BtnSend())
        {
         ObjectSetInteger(0,BtnSend(),OBJPROP_STATE,false);
         SendOrder();
         return;
        }
      if(sparam==BtnCancel())
        {
         ObjectSetInteger(0,BtnCancel(),OBJPROP_STATE,false);
         ResetPanel();
         return;
        }

      bool isTypeBtn = (sparam==BtnBuy() || sparam==BtnSell() || sparam==BtnBuyStop() ||
                         sparam==BtnSellStop() || sparam==BtnBuyLimit() || sparam==BtnSellLimit());
      if(!isTypeBtn) return;

      double bid = SymbolInfoDouble(_Symbol,SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      double off = InpDefaultSLPoints*PointVal();

      // pick the order type and place a sensible default Entry relative to
      // the CURRENT Bid/Ask, respecting which side pending orders must sit on
      if(sparam==BtnBuy())            { g_orderType=OT_BUY;       g_entryPrice=ask;      }
      else if(sparam==BtnSell())      { g_orderType=OT_SELL;      g_entryPrice=bid;      }
      else if(sparam==BtnBuyStop())   { g_orderType=OT_BUYSTOP;   g_entryPrice=ask+off;  }
      else if(sparam==BtnSellStop())  { g_orderType=OT_SELLSTOP;  g_entryPrice=bid-off;  }
      else if(sparam==BtnBuyLimit())  { g_orderType=OT_BUYLIMIT;  g_entryPrice=bid-off;  }
      else if(sparam==BtnSellLimit()) { g_orderType=OT_SELLLIMIT; g_entryPrice=ask+off;  }

      ObjectSetInteger(0,sparam,OBJPROP_STATE,false);

      ClampEntryForOrderType();   // guard in case broker's min stop distance > InpDefaultSLPoints

      // default SL/TP relative to the new entry, in the right direction
      bool buyBias = IsBuyType(g_orderType);
      g_slPrice = buyBias ? g_entryPrice-InpDefaultSLPoints*PointVal()
                           : g_entryPrice+InpDefaultSLPoints*PointVal();
      RecalcTPFromRRR();

      EnsureLinesExist();     // <-- lines are (re)created here, on selection,
                              //     and entry-line lock state is set here too
      HighlightOrderTypeButtons();
      SyncAll();
     }
  }
//+------------------------------------------------------------------+