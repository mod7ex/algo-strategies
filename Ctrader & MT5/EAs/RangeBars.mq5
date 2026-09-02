//+------------------------------------------------------------------+
//|                                              RangeBarBuilder.mq5 |
//|   Builds a synthetic "range bar" custom symbol from the ticks    |
//|   of a source symbol, preloaded with historical bars and kept    |
//|   live (including a working Bid/Ask quote) as new ticks arrive.  |
//|                                                                    |
//|   True range bars (NOT Renko): a bar tracks its running high and |
//|   low across ticks in EITHER direction (reversals/wicks allowed) |
//|   and closes the instant high - low reaches EXACTLY              |
//|   InpRangePoints - never more, never less. The close is whichever|
//|   extreme (high or low) was just touched, and that price becomes |
//|   the next bar's open. Formation is driven purely by price,      |
//|   never by time.                                                 |
//+------------------------------------------------------------------+
#property copyright "RangeBarBuilder"
#property version   "2.10"
#property description "Generates a true exact-range range-bar custom symbol (not Renko) from a source symbol, with live Bid/Ask."

//--- Inputs
input string InpSourceSymbol   = "";    // Source symbol (empty = current chart symbol)
input int    InpRangePoints    = 100;   // Range size, in points (exact size of every bar)
input string InpCustomSymbol   = "";    // Custom symbol name (empty = auto: <source>.Range<N>)
input int    InpHistoryDays    = 2;     // Days of history to preload (0 = none)
input bool   InpResetHistory   = true;  // Clear existing custom-symbol history on start
input bool   InpDeleteOnRemove = false; // Delete the custom symbol when EA is removed
input int    InpTimerMs        = 50;    // Polling interval, ms (fallback tick source)

//+------------------------------------------------------------------+
//| Builds and maintains a range-bar synthetic symbol                |
//+------------------------------------------------------------------+
class CRangeBarBuilder
  {
private:
   string   m_source;
   string   m_custom;
   double   m_range;
   double   m_point;
   int      m_spreadPoints;
   bool     m_active;
   datetime m_lastBarTime;
   long     m_lastTickMsc;
   MqlRates m_bar;

   //--- Anchors the synthetic bar clock so the first bar lands on 'anchor'.
   void ResetClock(const datetime anchor)
     {
      const int step = PeriodSeconds(PERIOD_M1);
      m_lastBarTime = (datetime)((anchor / step) * step) - step;
     }

   //--- Each bar occupies its own artificial M1 slot so the custom
   //--- symbol displays 1 bar : 1 range-bar when viewed on M1.
   datetime NextBarTime()
     {
      m_lastBarTime += PeriodSeconds(PERIOD_M1);
      return m_lastBarTime;
     }

   void StartBar(const double price)
     {
      m_bar.time        = NextBarTime();
      m_bar.open        = price;
      m_bar.high        = price;
      m_bar.low         = price;
      m_bar.close       = price;
      m_bar.tick_volume = 0;
      m_bar.real_volume = 0;
      m_bar.spread      = m_spreadPoints;
      m_active          = true;
     }

   //--- Tracks the live bid/ask spread (in points) of the source, used
   //--- to stamp bars and to build the custom symbol's own live quote.
   void SetSpread(const double bid, const double ask)
     {
      if(m_point > 0.0 && ask > bid)
         m_spreadPoints = (int)MathRound((ask - bid) / m_point);
     }

   //--- Closes the forming bar at 'close' (equal to its own high or
   //--- low, whichever was just touched), appends it, and opens the
   //--- next bar there - so a bar's close always equals the next
   //--- bar's open, per the standard range-bar definition.
   void CloseBar(const double close, MqlRates &closedBars[])
     {
      m_bar.close = close;

      const int n = ArraySize(closedBars);
      ArrayResize(closedBars, n + 1, 256);
      closedBars[n] = m_bar;

      StartBar(close);
     }

   //--- Core state machine, shared by historical seeding and live ticks.
   //--- True range-bar formation: the forming bar's high and low can
   //--- move in EITHER direction as ticks arrive (unlike Renko, a
   //--- reversal inside the bar is normal and produces a real wick).
   //--- The bar closes the instant (high - low) reaches m_range; the
   //--- close is capped exactly at that boundary - never more, never
   //--- less - and any leftover excess from a tick that overshoots
   //--- (e.g. a gap) rolls into as many further bars as needed.
   void Advance(const double price, const long volume, MqlRates &closedBars[])
     {
      if(!m_active)
         StartBar(price);

      bool firstPass = true;

      while(true)
        {
         if(firstPass)
           {
            m_bar.tick_volume += 1;
            m_bar.real_volume += volume;
            firstPass = false;
           }
         m_bar.spread = m_spreadPoints;

         if(price > m_bar.high)
           {
            double newHigh = price;
            const bool closes = (newHigh - m_bar.low >= m_range);
            if(closes)
               newHigh = m_bar.low + m_range; // cap exactly on the boundary
            m_bar.high = newHigh;
            if(closes)
              {
               CloseBar(newHigh, closedBars);
               continue; // any excess beyond newHigh rolls into the next bar
              }
           }
         else if(price < m_bar.low)
           {
            double newLow = price;
            const bool closes = (m_bar.high - newLow >= m_range);
            if(closes)
               newLow = m_bar.high - m_range; // cap exactly on the boundary
            m_bar.low = newLow;
            if(closes)
              {
               CloseBar(newLow, closedBars);
               continue;
              }
           }

         // Absorbed without closing: keep the forming bar's live close
         // updated, high/low unchanged (or just extended above).
         m_bar.close = price;
         break;
        }
     }

   //--- Pushes the current (still forming) bar so the chart updates live.
   void PushFormingBar()
     {
      MqlRates forming[1];
      forming[0] = m_bar;
      CustomRatesUpdate(m_custom, forming);
     }

   //--- Feeds a synthetic tick with a real bid/ask spread so Market
   //--- Watch and the chart's Bid/Ask lines update live.
   void PushTick(const double bid, const double ask)
     {
      MqlTick t;
      ZeroMemory(t);
      t.time     = TimeCurrent();
      t.time_msc = (long)t.time * 1000;
      t.bid      = bid;
      t.ask      = ask;
      t.last     = bid;
      t.flags    = TICK_FLAG_BID | TICK_FLAG_ASK | TICK_FLAG_LAST;

      MqlTick arr[1];
      arr[0] = t;
      CustomTicksAdd(m_custom, arr);
     }

   //--- Historical seeding: prefer real ticks; fall back to M1 bars
   //--- (approximating the intrabar path) if tick history is unavailable.
   int SeedFromTicks(const datetime from, const datetime to, MqlRates &closed[])
     {
      MqlTick ticks[];
      const int copied = CopyTicksRange(m_source, ticks, COPY_TICKS_ALL,
                                         (ulong)from * 1000, (ulong)to * 1000);
      if(copied <= 0)
         return 0;

      for(int i = 0; i < copied; i++)
        {
         const double price = (ticks[i].bid > 0.0) ? ticks[i].bid : ticks[i].last;
         if(price <= 0.0)
            continue;
         if(ticks[i].ask > 0.0)
            SetSpread(ticks[i].bid, ticks[i].ask);
         Advance(price, (long)ticks[i].volume, closed);
         m_lastTickMsc = ticks[i].time_msc;
        }
      return ArraySize(closed);
     }

   int SeedFromMinuteBars(const datetime from, const datetime to, MqlRates &closed[])
     {
      MqlRates bars[];
      const int copied = CopyRates(m_source, PERIOD_M1, from, to, bars);
      if(copied <= 0)
         return 0;

      for(int i = 0; i < copied; i++)
        {
         if(bars[i].spread > 0)
            m_spreadPoints = bars[i].spread;

         const bool bullish = bars[i].close >= bars[i].open;
         Advance(bars[i].open, 0, closed);
         Advance(bullish ? bars[i].low  : bars[i].high, 0, closed);
         Advance(bullish ? bars[i].high : bars[i].low,  0, closed);
         Advance(bars[i].close, (long)bars[i].tick_volume, closed);
        }
      return ArraySize(closed);
     }

   int BuildHistory(const datetime from, const datetime to)
     {
      MqlRates closed[];
      int built = SeedFromTicks(from, to, closed);
      if(built <= 0)
         built = SeedFromMinuteBars(from, to, closed);

      if(built > 0)
         CustomRatesUpdate(m_custom, closed);

      PrintFormat("RangeBarBuilder: preloaded %d historical range bar(s) for %s",
                  built, m_custom);
      return built;
     }

public:
                  CRangeBarBuilder() : m_range(0.0), m_point(0.0), m_spreadPoints(0),
                                       m_active(false), m_lastBarTime(0), m_lastTickMsc(0) {}

   bool Init(const string source, const int rangePoints, const string customName,
             const bool resetHistory, const int historyDays)
     {
      m_source = (source == "") ? _Symbol : source;

      if(!SymbolSelect(m_source, true))
        {
         PrintFormat("RangeBarBuilder: failed to select source symbol %s", m_source);
         return false;
        }

      m_point = SymbolInfoDouble(m_source, SYMBOL_POINT);
      if(rangePoints <= 0 || m_point <= 0.0)
        {
         Print("RangeBarBuilder: invalid range points / source point value");
         return false;
        }
      m_range = rangePoints * m_point;
      m_spreadPoints = (int)SymbolInfoInteger(m_source, SYMBOL_SPREAD);

      m_custom = (customName == "")
                 ? StringFormat("%s.Range%d", m_source, rangePoints)
                 : customName;

      bool isCustom = false;
      if(!CustomSymbolCreate(m_custom, "Custom\\RangeBars\\" + m_source, m_source) &&
         !(SymbolExist(m_custom, isCustom) && isCustom))
        {
         PrintFormat("RangeBarBuilder: CustomSymbolCreate(%s) failed, error %d",
                     m_custom, GetLastError());
         return false;
        }

      SymbolSelect(m_custom, true);

      if(resetHistory)
         CustomRatesDelete(m_custom, 0, D'2100.01.01');

      m_active      = false;
      m_lastTickMsc = 0;

      const datetime to     = TimeCurrent();
      const datetime anchor = (historyDays > 0) ? to - historyDays * 86400 : to;
      ResetClock(anchor);

      if(historyDays > 0)
         BuildHistory(anchor, to);

      return true;
     }

   void Deinit(const bool deleteSymbol)
     {
      if(deleteSymbol)
         CustomSymbolDelete(m_custom);
     }

   string SourceSymbol() const { return m_source; }
   string CustomSymbol() const { return m_custom; }

   //--- Pulls the latest tick from the source symbol and, if it is
   //--- new, advances the range-bar state machine and updates the
   //--- custom symbol (bars + live Bid/Ask quote).
   void Update()
     {
      MqlTick tick;
      if(!SymbolInfoTick(m_source, tick) || tick.time_msc <= m_lastTickMsc)
         return;
      m_lastTickMsc = tick.time_msc;

      const double bid = (tick.bid > 0.0) ? tick.bid : tick.last;
      if(bid <= 0.0)
         return;
      const double ask = (tick.ask > 0.0) ? tick.ask : bid;

      SetSpread(bid, ask);

      MqlRates closed[];
      Advance(bid, (long)tick.volume, closed);

      if(ArraySize(closed) > 0)
         CustomRatesUpdate(m_custom, closed);

      PushFormingBar();
      PushTick(bid, ask);
     }
  };

CRangeBarBuilder g_builder;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(!g_builder.Init(InpSourceSymbol, InpRangePoints, InpCustomSymbol,
                       InpResetHistory, InpHistoryDays))
      return INIT_FAILED;

   const int timerMs = (InpTimerMs < 10) ? 10 : InpTimerMs;
   EventSetMillisecondTimer(timerMs);

   g_builder.Update(); // prime the live quote / Bid-Ask line immediately

   PrintFormat("RangeBarBuilder started: %s -> %s (%d pts)",
               g_builder.SourceSymbol(), g_builder.CustomSymbol(), InpRangePoints);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   g_builder.Deinit(InpDeleteOnRemove);
  }

//+------------------------------------------------------------------+
//| Fires on ticks of the chart's own symbol (fast path when the EA  |
//| is attached to a chart of the source symbol itself)              |
//+------------------------------------------------------------------+
void OnTick()
  {
   g_builder.Update();
  }

//+------------------------------------------------------------------+
//| Fires on the timer, guaranteeing updates even when the EA runs   |
//| on a chart whose symbol differs from the source symbol           |
//+------------------------------------------------------------------+
void OnTimer()
  {
   g_builder.Update();
  }
//+------------------------------------------------------------------+