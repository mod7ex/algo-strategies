//+------------------------------------------------------------------+
//|                                              BollingerBands.mq5   |
//|              Ported from TradingView Pine Script v6 (built-in BB) |
//+------------------------------------------------------------------+
#property copyright ""
#property link      ""
#property version   "1.00"
#property description "Bollinger Bands - ported from Pine Script v6"
#property indicator_chart_window

#property indicator_buffers 3
#property indicator_plots   3

//--- Basis (middle) line
#property indicator_label1  "Basis"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrDodgerBlue
#property indicator_style1  STYLE_SOLID
#property indicator_width1  1

//--- Upper band
#property indicator_label2  "Upper"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrCrimson
#property indicator_style2  STYLE_SOLID
#property indicator_width2  1

//--- Lower band
#property indicator_label3  "Lower"
#property indicator_type3   DRAW_LINE
#property indicator_color3  clrSeaGreen
#property indicator_style3  STYLE_SOLID
#property indicator_width3  1

//--- MA type choices
enum ENUM_MA_TYPE_BB
  {
   MA_SMA = 0,   // SMA
   MA_EMA = 1,   // EMA
   MA_SMMA = 2,  // SMMA (RMA)
   MA_WMA = 3,   // WMA
   MA_VWMA = 4   // VWMA
  };

//--- Source choices (matches the requested price-source list)
enum ENUM_SOURCE_BB
  {
   SRC_OPEN  = 0,  // Open
   SRC_HIGH  = 1,  // High
   SRC_LOW   = 2,  // Low
   SRC_CLOSE = 3,  // Close
   SRC_HL2   = 4,  // (H+L)/2
   SRC_HLC3  = 5,  // (H+L+C)/3
   SRC_OHLC4 = 6,  // (O+H+L+C)/4
   SRC_HLCC4 = 7   // (H+L+C+C)/4
  };

input int               InpLength = 20;              // Length
input ENUM_MA_TYPE_BB    InpMaType = MA_SMA;          // Basis MA Type
input ENUM_SOURCE_BB     InpSource = SRC_CLOSE;       // Source
input double             InpMult   = 2.0;             // StdDev multiplier
input int                InpOffset = 0;                // Offset (shift, bars)

double basisBuffer[];
double upperBuffer[];
double lowerBuffer[];

//+------------------------------------------------------------------+
int OnInit()
  {
   SetIndexBuffer(0, basisBuffer, INDICATOR_DATA);
   SetIndexBuffer(1, upperBuffer, INDICATOR_DATA);
   SetIndexBuffer(2, lowerBuffer, INDICATOR_DATA);

   PlotIndexSetInteger(0, PLOT_SHIFT, InpOffset);
   PlotIndexSetInteger(1, PLOT_SHIFT, InpOffset);
   PlotIndexSetInteger(2, PLOT_SHIFT, InpOffset);

   PlotIndexSetInteger(0, PLOT_DRAW_BEGIN, InpLength - 1);
   PlotIndexSetInteger(1, PLOT_DRAW_BEGIN, InpLength - 1);
   PlotIndexSetInteger(2, PLOT_DRAW_BEGIN, InpLength - 1);

   IndicatorSetString(INDICATOR_SHORTNAME,
      StringFormat("BB(%d,%.2f)", InpLength, InpMult));
   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Applied price helper                                              |
//+------------------------------------------------------------------+
double GetAppliedPrice(ENUM_SOURCE_BB ap, int i,
                       const double &open[], const double &high[],
                       const double &low[],  const double &close[])
  {
   switch(ap)
     {
      case SRC_OPEN:  return open[i];
      case SRC_HIGH:  return high[i];
      case SRC_LOW:   return low[i];
      case SRC_HL2:   return (high[i] + low[i]) / 2.0;
      case SRC_HLC3:  return (high[i] + low[i] + close[i]) / 3.0;
      case SRC_OHLC4: return (open[i] + high[i] + low[i] + close[i]) / 4.0;
      case SRC_HLCC4: return (high[i] + low[i] + 2.0 * close[i]) / 4.0;
      default:        return close[i]; // SRC_CLOSE
     }
  }

//+------------------------------------------------------------------+
//| SMA over the window ending at bar i                                |
//+------------------------------------------------------------------+
double CalcSMA(int i, int length, ENUM_SOURCE_BB ap,
               const double &open[], const double &high[],
               const double &low[],  const double &close[])
  {
   double sum = 0.0;
   for(int k = 0; k < length; k++)
      sum += GetAppliedPrice(ap, i - k, open, high, low, close);
   return sum / length;
  }

//+------------------------------------------------------------------+
//| WMA: most recent bar gets weight = length, oldest gets weight = 1  |
//+------------------------------------------------------------------+
double CalcWMA(int i, int length, ENUM_SOURCE_BB ap,
               const double &open[], const double &high[],
               const double &low[],  const double &close[])
  {
   double sumW = 0.0, sumWP = 0.0;
   for(int k = 0; k < length; k++)
     {
      double w = length - k;
      sumWP += GetAppliedPrice(ap, i - k, open, high, low, close) * w;
      sumW  += w;
     }
   return sumWP / sumW;
  }

//+------------------------------------------------------------------+
//| VWMA                                                                |
//+------------------------------------------------------------------+
double CalcVWMA(int i, int length, ENUM_SOURCE_BB ap,
                const double &open[], const double &high[],
                const double &low[],  const double &close[],
                const long &volume[])
  {
   double sumPV = 0.0, sumV = 0.0;
   for(int k = 0; k < length; k++)
     {
      double v = (double)volume[i - k];
      sumPV += GetAppliedPrice(ap, i - k, open, high, low, close) * v;
      sumV  += v;
     }
   if(sumV == 0.0)
      return CalcSMA(i, length, ap, open, high, low, close);
   return sumPV / sumV;
  }

//+------------------------------------------------------------------+
//| Population standard deviation, mean is always the plain SMA        |
//| (matches Pine's ta.stdev, independent of the chosen basis MA type) |
//+------------------------------------------------------------------+
double CalcStdev(int i, int length, ENUM_SOURCE_BB ap,
                 const double &open[], const double &high[],
                 const double &low[],  const double &close[])
  {
   double mean = CalcSMA(i, length, ap, open, high, low, close);
   double sumSq = 0.0;
   for(int k = 0; k < length; k++)
     {
      double d = GetAppliedPrice(ap, i - k, open, high, low, close) - mean;
      sumSq += d * d;
     }
   return MathSqrt(sumSq / length);
  }

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
  {
   if(rates_total < InpLength)
      return 0;

   int start = (prev_calculated > 1) ? prev_calculated - 1 : InpLength - 1;
   if(start < InpLength - 1)
      start = InpLength - 1;

   for(int i = start; i < rates_total; i++)
     {
      double basis = 0.0;

      switch(InpMaType)
        {
         case MA_EMA:
           {
            double alpha = 2.0 / (InpLength + 1.0);
            if(i == InpLength - 1)
               basis = CalcSMA(i, InpLength, InpSource, open, high, low, close);
            else
               basis = GetAppliedPrice(InpSource, i, open, high, low, close) * alpha
                       + basisBuffer[i - 1] * (1.0 - alpha);
            break;
           }
         case MA_SMMA:
           {
            if(i == InpLength - 1)
               basis = CalcSMA(i, InpLength, InpSource, open, high, low, close);
            else
               basis = (basisBuffer[i - 1] * (InpLength - 1)
                        + GetAppliedPrice(InpSource, i, open, high, low, close)) / InpLength;
            break;
           }
         case MA_WMA:
            basis = CalcWMA(i, InpLength, InpSource, open, high, low, close);
            break;
         case MA_VWMA:
            basis = CalcVWMA(i, InpLength, InpSource, open, high, low, close, tick_volume);
            break;
         default: // MA_SMA
            basis = CalcSMA(i, InpLength, InpSource, open, high, low, close);
            break;
        }

      basisBuffer[i] = basis;

      double dev = InpMult * CalcStdev(i, InpLength, InpSource, open, high, low, close);
      upperBuffer[i] = basis + dev;
      lowerBuffer[i] = basis - dev;
     }

   return rates_total;
  }
//+------------------------------------------------------------------+