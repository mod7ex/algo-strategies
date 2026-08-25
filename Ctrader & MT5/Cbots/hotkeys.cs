// =====================================================================
//  HotkeyTraderAutoTPSL.cs
//  cTrader (cAlgo) cBot port of HotkeyTrader_AutoTPSL.mq5 (MT5 EA)
//
//  Combines:
//   - A hotkey trading panel (Long / Short / Flat / RiskFree / Hedge)
//   - An automatic Take Profit / Stop Loss manager with SL Cover
//   - A single ON/OFF toggle for the Auto TP/SL engine
//
//  PORTING NOTES (read before using on a live account):
//
//  1. No "magic number" concept exists in cTrader. The MT5 magic
//     number is replaced by the Position/Order `Label` string:
//       - HotkeyLabel is stamped on new orders opened by the panel.
//       - TpslLabelFilter is the equivalent of InpTPSLMagicFilter
//         (blank = manage every open position, any symbol).
//
//  2. cTrader has no per-order "slippage in points" parameter exposed
//     via ExecuteMarketOrder in the same way MT5 does - execution
//     slippage is handled by the broker/platform. There is nothing to
//     configure here.
//
//  3. A cBot instance is NOT torn down when you change the chart's
//     symbol or timeframe the way an MT5 EA is (MT5's OnDeinit/OnInit
//     dance). Because of that, the GlobalVariableTemp() persistence
//     trick from the MT5 version is unnecessary here - g_enabled and
//     g_lotSize simply live as normal instance fields for the life of
//     the cBot run.
//
//  4. Money-based TP/SL sizing (ValueMode.Money / ValueMode.Percent)
//     uses Symbol.TickValue and Symbol.TickSize to convert a monetary
//     amount into a price distance, mirroring the MT5
//     SYMBOL_TRADE_TICK_VALUE / SYMBOL_TRADE_TICK_SIZE approach.
//     cTrader's documentation is notoriously thin on whether
//     TickValue is already normalised for a specific volume - TEST
//     this thoroughly on a demo account (compare the SL/TP price the
//     bot sets against the money amount you expect) before trusting
//     it with real funds. Pip-based sizing (ValueMode.Pips) does not
//     depend on this and is safe to use as-is.
//
//  5. cTrader positions are typically not subject to MT5-style
//     "minimum stop distance" (SYMBOL_TRADE_STOPS_LEVEL) restrictions
//     since most cTrader brokers are STP/ECN, so that clamp was
//     dropped. If your broker rejects a ModifyPosition/order because
//     the SL/TP is too close to price, the failure is logged via
//     Print() and the TradeResult.Error.
//
//  5b. SL/TP updates use the newer ModifyPosition(..., ProtectionType)
//      overload with ProtectionType.Absolute. Multiple cTrader forum
//      threads report this overload crashing with a TypeLoadException
//      when a cBot runs on cTrader's cloud/VPS hosting - it's used here
//      because this bot is only ever run locally in the terminal. If
//      you later move this bot to cTrader Cloud, drop the
//      ProtectionType argument and go back to the 3-arg overload.
//
//  6. UI is built with the native cAlgo Controls API (Grid /
//     StackPanel / Border / Button / TextBlock / TextBox) instead of
//     manually managed chart objects - this is the idiomatic cTrader
//     approach and needs far less bookkeeping code than the MQL5
//     ObjectCreate/ObjectSet plumbing.
//
//  7. Hotkeys use Chart.KeyDown. cTrader will not raise this event for
//     keys/keystrokes it already treats as native hotkeys.
//
//  8. The panel is movable with the mouse via cTrader's native
//     "chart area draggable control" (Chart.Draggables.Add()). Rather
//     than hand-rolling MouseDown/MouseMove math against the panel's
//     Margin (fragile, and easy to fight with the panel's own button
//     clicks), the whole panel Border is set as the Child of a
//     ChartDraggable, which is the idiomatic/supported way to get a
//     draggable floating panel in cAlgo. The panel can be dragged by
//     clicking and holding anywhere on it (not just a title bar).
// =====================================================================

using System;
using System.Collections.Generic;
using System.Linq;
using cAlgo.API;
using cAlgo.API.Internals;

namespace cAlgo.Robots
{
    public enum TpslMode
    {
        Position = 0,       // Averaging: one shared TP/SL per symbol+direction group
        Transaction = 1     // Individual: each position gets its own TP/SL
    }

    public enum ValueMode
    {
        Percent = 0,        // % of account balance, converted to a money amount
        Pips = 1,           // Fixed pips
        Money = 2            // Fixed amount of money (account currency)
    }

    [Robot(TimeZone = TimeZones.UTC, AccessRights = AccessRights.None)]
    public class HotkeyTraderAutoTPSL : Robot
    {
        // ============================= PARAMETERS =============================

        [Parameter("Starting Lot Size", Group = "Trading Settings", DefaultValue = 0.01, MinValue = 0.001)]
        public double InitialLotSize { get; set; }

        [Parameter("Order Label (stamped on new hotkey orders)", Group = "Trading Settings", DefaultValue = "HotkeyTrader")]
        public string HotkeyLabel { get; set; }

        [Parameter("Max Open Lots / Direction (0 = unlimited)", Group = "Trading Settings", DefaultValue = 0.05, MinValue = 0)]
        public double MaxOpenLots { get; set; }

        [Parameter("Long Key", Group = "Hotkeys", DefaultValue = "L")]
        public string KeyLongStr { get; set; }

        [Parameter("Short Key", Group = "Hotkeys", DefaultValue = "S")]
        public string KeyShortStr { get; set; }

        [Parameter("Flat (Close All) Key", Group = "Hotkeys", DefaultValue = "F")]
        public string KeyFlatStr { get; set; }

        [Parameter("Risk Free Key", Group = "Hotkeys", DefaultValue = "R")]
        public string KeyRiskFreeStr { get; set; }

        [Parameter("Hedge Key", Group = "Hotkeys", DefaultValue = "H")]
        public string KeyHedgeStr { get; set; }

        [Parameter("TP/SL Mode", Group = "Auto TP/SL Settings", DefaultValue = TpslMode.Position)]
        public TpslMode TpMode { get; set; }

        [Parameter("Value Type", Group = "Auto TP/SL Settings", DefaultValue = ValueMode.Money)]
        public ValueMode ValueType { get; set; }

        [Parameter("Take Profit Value (%, pips, or money)", Group = "Auto TP/SL Settings", DefaultValue = 30)]
        public double TakeProfitValue { get; set; }

        [Parameter("Stop Loss Value (%, pips, or money)", Group = "Auto TP/SL Settings", DefaultValue = 10)]
        public double StopLossValue { get; set; }

        [Parameter("Apply To Existing Positions On Start", Group = "Auto TP/SL Settings", DefaultValue = true)]
        public bool ApplyOnStartup { get; set; }

        [Parameter("Auto TP/SL Enabled At Start", Group = "Auto TP/SL Settings", DefaultValue = false)]
        public bool AutoTpslStartEnabled { get; set; }

        [Parameter("Enable SL Cover", Group = "SL Cover Settings", DefaultValue = true)]
        public bool EnableSlCover { get; set; }

        [Parameter("Cover When Profit Reaches (%)", Group = "SL Cover Settings", DefaultValue = 50)]
        public double CoverProfitThresholdPercent { get; set; }

        [Parameter("Cover SL Value (%)", Group = "SL Cover Settings", DefaultValue = 0)]
        public double CoverSlValuePercent { get; set; }

        [Parameter("Auto TP/SL Label Filter (blank = every position, any symbol)", Group = "Auto TP/SL Filter", DefaultValue = "HotkeyTrader")]
        public string TpslLabelFilter { get; set; }

        [Parameter("Panel Vertical Position", Group = "Panel Appearance", DefaultValue = VerticalAlignment.Top)]
        public VerticalAlignment PanelVerticalAlignment { get; set; }

        [Parameter("Panel Horizontal Position", Group = "Panel Appearance", DefaultValue = HorizontalAlignment.Left)]
        public HorizontalAlignment PanelHorizontalAlignment { get; set; }

        // ============================= STATE =============================

        private double _lotSize;
        private bool _autoTpslEnabled;
        private string _status = "Ready - press a hotkey";

        private Key? _keyLong, _keyShort, _keyFlat, _keyRiskFree, _keyHedge;
        private string _letterLong, _letterShort, _letterFlat, _letterRiskFree, _letterHedge;

        // UI controls we need to update later
        private TextBlock _statusLabel;
        private TextBlock _posLabel;
        private TextBlock _maxLabel;
        private TextBox _lotTextBox;
        private Button _toggleButton;

        // The draggable wrapper that hosts the panel Border, letting the user
        // move the whole panel around the chart with the mouse. See porting
        // note 8 above.
        private ChartDraggable _panelDraggable;

        private static readonly Color ToggleOnColor = Color.FromHex("#228B22");   // ForestGreen
        private static readonly Color ToggleOffColor = Color.FromHex("#B22222");  // FireBrick
        private static readonly Color PanelBg = Color.FromHex("#14161C");
        private static readonly Color PanelBorder = Color.FromHex("#3C78C8");

        // ============================= LIFECYCLE =============================

        protected override void OnStart()
        {
            _keyLong = ResolveKey(KeyLongStr, out _letterLong);
            _keyShort = ResolveKey(KeyShortStr, out _letterShort);
            _keyFlat = ResolveKey(KeyFlatStr, out _letterFlat);
            _keyRiskFree = ResolveKey(KeyRiskFreeStr, out _letterRiskFree);
            _keyHedge = ResolveKey(KeyHedgeStr, out _letterHedge);

            _lotSize = NormalizeLots(Symbol, InitialLotSize);
            _autoTpslEnabled = AutoTpslStartEnabled;

            BuildPanel();
            UpdatePanelInfo();

            Chart.KeyDown += OnChartKeyDown;
            Positions.Opened += OnPositionOpened;
            Positions.Closed += OnPositionClosedOrModified;
            Positions.Modified += OnPositionClosedOrModified;

            if (ApplyOnStartup && _autoTpslEnabled)
                ApplyToAllExistingPositions();

            Timer.Start(1); // refresh the panel info once per second, like the MT5 version

            Print("HotkeyTrader + Auto TPSL started. Mode={0} ValueType={1} Auto TPSL Enabled={2}",
                TpMode, ValueType, _autoTpslEnabled);
        }

        protected override void OnTick()
        {
            if (_autoTpslEnabled && EnableSlCover)
                ProcessSlCover();
        }

        protected override void OnTimer()
        {
            UpdatePanelInfo();
        }

        protected override void OnStop()
        {
            Timer.Stop();
            Chart.KeyDown -= OnChartKeyDown;
            Positions.Opened -= OnPositionOpened;
            Positions.Closed -= OnPositionClosedOrModified;
            Positions.Modified -= OnPositionClosedOrModified;
            // The draggable (and the panel Border nested inside it) is torn
            // down automatically with the chart when the cBot stops, so
            // there's nothing else to unhook here now that the panel is no
            // longer added via Chart.AddControl directly.
        }

        // ============================= HOTKEYS =============================

        private void OnChartKeyDown(ChartKeyboardEventArgs args)
        {
            if (args.Key == _keyLong) DoLong();
            else if (args.Key == _keyShort) DoShort();
            else if (args.Key == _keyFlat) DoFlat();
            else if (args.Key == _keyRiskFree) DoRiskFree();
            else if (args.Key == _keyHedge) DoHedge();
        }

        private static Key? ResolveKey(string rawKey, out string displayLetter)
        {
            string s = (rawKey ?? "").Trim().ToUpperInvariant();
            if (s.Length == 0)
            {
                displayLetter = "?";
                return null;
            }
            s = s.Substring(0, 1);
            displayLetter = s;

            Key parsed;
            return Enum.TryParse(s, true, out parsed) ? (Key?)parsed : null;
        }

        // ============================= NEW POSITION DETECTION (Auto TP/SL) =============================
        // Unlike the MT5 version (which had to poll PositionsTotal() every tick to spot new
        // tickets), cTrader gives us a proper event for this.

        private void OnPositionOpened(PositionOpenedEventArgs args)
        {
            if (!_autoTpslEnabled) return;

            var position = args.Position;
            if (!PassesFilter(position)) return;

            if (TpMode == TpslMode.Transaction)
                ApplyIndividualTpSl(position);
            else
                ApplyGroupTpSl(position.SymbolName, position.TradeType);
        }

        private void OnPositionClosedOrModified(object args)
        {
            UpdatePanelInfo();
        }

        // ============================= HOTKEY TRADING ACTIONS =============================

        private IEnumerable<Position> CurrentSymbolPositions()
        {
            return Positions.Where(p => p.SymbolName == SymbolName);
        }

        private void GetPositionStats(out int count, out double lots)
        {
            count = 0;
            lots = 0;
            foreach (var p in CurrentSymbolPositions())
            {
                count++;
                lots += VolumeToLots(Symbol, p.VolumeInUnits);
            }
        }

        private void GetNetExposure(out double longLots, out double shortLots)
        {
            longLots = 0;
            shortLots = 0;
            foreach (var p in CurrentSymbolPositions())
            {
                double lots = VolumeToLots(Symbol, p.VolumeInUnits);
                if (p.TradeType == TradeType.Buy) longLots += lots;
                else shortLots += lots;
            }
        }

        private double ClampToMaxOpen(double requestedLots, double netExposureLots, bool isLong)
        {
            if (MaxOpenLots <= 0) return requestedLots; // unlimited

            double room = isLong ? (MaxOpenLots - netExposureLots) : (MaxOpenLots + netExposureLots);
            if (room <= 0) return 0;

            return NormalizeLots(Symbol, Math.Min(requestedLots, room));
        }

        private void DoLong()
        {
            double longLots, shortLots;
            GetNetExposure(out longLots, out shortLots);
            double net = longLots - shortLots;

            double lots = ClampToMaxOpen(_lotSize, net, true);
            if (lots <= 0)
            {
                _status = string.Format("LONG blocked - net long already at max ({0})", MaxOpenLots);
                UpdatePanelInfo();
                return;
            }

            double volume = LotsToVolume(Symbol, lots);
            var result = ExecuteMarketOrder(TradeType.Buy, SymbolName, volume, HotkeyLabel, (double?)null, (double?)null, "HotkeyTrader Long");
            if (result.IsSuccessful)
                _status = string.Format("LONG {0} @ {1} executed{2}", lots, result.Position.EntryPrice,
                    lots < _lotSize ? " (clamped by max/dir)" : "");
            else
                _status = string.Format("LONG error: {0}", result.Error);

            UpdatePanelInfo();
        }

        private void DoShort()
        {
            double longLots, shortLots;
            GetNetExposure(out longLots, out shortLots);
            double net = longLots - shortLots;

            double lots = ClampToMaxOpen(_lotSize, net, false);
            if (lots <= 0)
            {
                _status = string.Format("SHORT blocked - net short already at max ({0})", MaxOpenLots);
                UpdatePanelInfo();
                return;
            }

            double volume = LotsToVolume(Symbol, lots);
            var result = ExecuteMarketOrder(TradeType.Sell, SymbolName, volume, HotkeyLabel, (double?)null, (double?)null, "HotkeyTrader Short");
            if (result.IsSuccessful)
                _status = string.Format("SHORT {0} @ {1} executed{2}", lots, result.Position.EntryPrice,
                    lots < _lotSize ? " (clamped by max/dir)" : "");
            else
                _status = string.Format("SHORT error: {0}", result.Error);

            UpdatePanelInfo();
        }

        private void DoFlat()
        {
            var positions = CurrentSymbolPositions().ToList();
            if (positions.Count == 0)
            {
                _status = "Flat: no open positions";
                UpdatePanelInfo();
                return;
            }

            int closed = 0, failed = 0, pending = positions.Count;

            foreach (var p in positions)
            {
                ClosePositionAsync(p, result =>
                {
                    if (result.IsSuccessful) closed++;
                    else failed++;
                    pending--;

                    if (pending == 0)
                    {
                        _status = failed == 0
                            ? string.Format("Flattened {0} position(s)", closed)
                            : string.Format("Flat: {0} closed, {1} failed", closed, failed);
                        UpdatePanelInfo();
                    }
                });
            }

            _status = string.Format("Flattening {0} position(s)...", positions.Count);
            UpdatePanelInfo();
        }

        private void DoRiskFree()
        {
            int moved = 0, failed = 0, skipped = 0;

            foreach (var p in CurrentSymbolPositions().ToList())
            {
                double profit = p.NetProfit; // includes swap/commission already
                if (profit <= 0) { skipped++; continue; }

                double openPrice = p.EntryPrice;
                double? currentSl = p.StopLoss;
                bool isBuy = p.TradeType == TradeType.Buy;

                if (isBuy && currentSl.HasValue && currentSl.Value >= openPrice) { skipped++; continue; }
                if (!isBuy && currentSl.HasValue && currentSl.Value <= openPrice) { skipped++; continue; }

                var result = ModifyPosition(p, openPrice, p.TakeProfit, ProtectionType.Absolute);
                if (result.IsSuccessful) moved++;
                else failed++;
            }

            _status = failed == 0
                ? string.Format("Risk-free set on {0} position(s), {1} skipped", moved, skipped)
                : string.Format("RF: {0} set, {1} failed, {2} skipped", moved, failed, skipped);

            UpdatePanelInfo();
        }

        private void DoHedge()
        {
            double longLots, shortLots;
            GetNetExposure(out longLots, out shortLots);
            double net = longLots - shortLots;

            double step = Symbol.VolumeInUnitsStep > 0 ? VolumeToLots(Symbol, Symbol.VolumeInUnitsStep) : 0.0000001;
            if (Math.Abs(net) <= step / 2.0)
            {
                _status = "Already hedged - net exposure is flat";
                UpdatePanelInfo();
                return;
            }

            double lots = NormalizeLots(Symbol, Math.Abs(net));
            double volume = LotsToVolume(Symbol, lots);

            TradeResult result;
            if (net > 0)
            {
                result = ExecuteMarketOrder(TradeType.Sell, SymbolName, volume, HotkeyLabel, (double?)null, (double?)null, "HotkeyTrader Hedge");
                _status = result.IsSuccessful
                    ? string.Format("HEDGE: SELL {0} (net long {1})", lots, net)
                    : string.Format("HEDGE error: {0}", result.Error);
            }
            else
            {
                result = ExecuteMarketOrder(TradeType.Buy, SymbolName, volume, HotkeyLabel, (double?)null, (double?)null, "HotkeyTrader Hedge");
                _status = result.IsSuccessful
                    ? string.Format("HEDGE: BUY {0} (net short {1})", lots, -net)
                    : string.Format("HEDGE error: {0}", result.Error);
            }

            UpdatePanelInfo();
        }

        // ============================= VOLUME HELPERS =============================
        // cTrader trades in "volume units" (e.g. 100000 units = 1 standard lot for most FX
        // symbols), not lots directly, so every lot figure is converted at the boundary.

        private static double NormalizeLots(Symbol symbol, double lots)
        {
            double units = symbol.QuantityToVolumeInUnits(lots);
            units = symbol.NormalizeVolumeInUnits(units, RoundingMode.ToNearest);
            return symbol.VolumeInUnitsToQuantity(units);
        }

        private static double LotsToVolume(Symbol symbol, double lots)
        {
            double units = symbol.QuantityToVolumeInUnits(lots);
            return symbol.NormalizeVolumeInUnits(units, RoundingMode.ToNearest);
        }

        private static double VolumeToLots(Symbol symbol, double volumeInUnits)
        {
            return symbol.VolumeInUnitsToQuantity(volumeInUnits);
        }

        // ============================= AUTO TP/SL: FILTER =============================

        private bool PassesFilter(Position position)
        {
            return string.IsNullOrEmpty(TpslLabelFilter) || position.Label == TpslLabelFilter;
        }

        // ============================= AUTO TP/SL: CALCULATION =============================

        private double MoneyToPriceDistance(Symbol symbol, double money, double volumeInUnits)
        {
            double tickValue = symbol.TickValue;
            double tickSize = symbol.TickSize;

            if (volumeInUnits <= 0 || tickValue <= 0 || tickSize <= 0)
            {
                Print("MoneyToPriceDistance: bad inputs for {0} volume={1} tickValue={2} tickSize={3}",
                    symbol.Name, volumeInUnits, tickValue, tickSize);
                return 0;
            }

            // NOTE: see the porting notes at the top of this file re: verifying
            // Symbol.TickValue's volume normalisation against your broker on demo first.
            double moneyPerPriceUnit = (tickValue / tickSize) * volumeInUnits;
            if (moneyPerPriceUnit <= 0) return 0;

            return money / moneyPerPriceUnit;
        }

        private void CalculateTpSl(Symbol symbol, double entryPrice, double volumeInUnits, bool isBuy, out double? tp, out double? sl)
        {
            double tpDist = 0, slDist = 0;

            if (ValueType == ValueMode.Percent)
            {
                double balance = Account.Balance;
                if (TakeProfitValue > 0) tpDist = MoneyToPriceDistance(symbol, balance * (TakeProfitValue / 100.0), volumeInUnits);
                if (StopLossValue > 0) slDist = MoneyToPriceDistance(symbol, balance * (StopLossValue / 100.0), volumeInUnits);
            }
            else if (ValueType == ValueMode.Money)
            {
                if (TakeProfitValue > 0) tpDist = MoneyToPriceDistance(symbol, TakeProfitValue, volumeInUnits);
                if (StopLossValue > 0) slDist = MoneyToPriceDistance(symbol, StopLossValue, volumeInUnits);
            }
            else // Pips
            {
                double pip = symbol.PipSize;
                tpDist = TakeProfitValue * pip;
                slDist = StopLossValue * pip;
            }

            tp = null;
            sl = null;

            if (TakeProfitValue > 0)
                tp = NormalizePrice(symbol, isBuy ? entryPrice + tpDist : entryPrice - tpDist);
            if (StopLossValue > 0)
                sl = NormalizePrice(symbol, isBuy ? entryPrice - slDist : entryPrice + slDist);
        }

        private static double NormalizePrice(Symbol symbol, double price)
        {
            return Math.Round(price, symbol.Digits);
        }

        private double WeightedAveragePrice(string symbolName, TradeType tradeType, out double totalVolume)
        {
            double sumPriceVol = 0;
            totalVolume = 0;

            foreach (var p in Positions.Where(p => p.SymbolName == symbolName && p.TradeType == tradeType && PassesFilter(p)))
            {
                sumPriceVol += p.EntryPrice * p.VolumeInUnits;
                totalVolume += p.VolumeInUnits;
            }

            return totalVolume > 0 ? sumPriceVol / totalVolume : 0;
        }

        // NOTE: this uses the newer ModifyPosition(Position, double?, double?, ProtectionType?)
        // overload. ProtectionType.Absolute is used because this bot always computes a fixed
        // SL/TP price up front (via NormalizePrice/CalculateTpSl) rather than a distance that
        // should float with entry price - that matches the behaviour of the older, now-obsolete
        // overload exactly. NOTE: multiple cTrader forum threads report this overload throwing a
        // TypeLoadException when a cBot runs on cTrader's cloud/VPS hosting - it is only used
        // here because this bot is run locally in the terminal. If you ever move this bot to
        // cTrader Cloud, revert to ModifyPosition(position, sl, tp) (drop the ProtectionType arg).
        private void ModifyPositionTpSl(Position position, double? tp, double? sl)
        {
            var symbol = Symbols.GetSymbol(position.SymbolName);
            double tick = symbol.TickSize;

            double curTp = position.TakeProfit ?? double.NaN;
            double curSl = position.StopLoss ?? double.NaN;
            double newTp = tp ?? double.NaN;
            double newSl = sl ?? double.NaN;

            bool tpSame = (double.IsNaN(curTp) && double.IsNaN(newTp)) || (!double.IsNaN(curTp) && !double.IsNaN(newTp) && Math.Abs(curTp - newTp) < tick);
            bool slSame = (double.IsNaN(curSl) && double.IsNaN(newSl)) || (!double.IsNaN(curSl) && !double.IsNaN(newSl) && Math.Abs(curSl - newSl) < tick);
            if (tpSame && slSame) return;

            var result = ModifyPosition(position, sl, tp, ProtectionType.Absolute);
            if (!result.IsSuccessful)
                Print("Failed to modify position #{0}: {1}", position.Id, result.Error);
        }

        private void ApplyGroupTpSl(string symbolName, TradeType tradeType)
        {
            double totalVolume;
            double avgPrice = WeightedAveragePrice(symbolName, tradeType, out totalVolume);
            if (avgPrice <= 0) return;

            var symbol = Symbols.GetSymbol(symbolName);
            bool isBuy = tradeType == TradeType.Buy;

            double? tp, sl;
            CalculateTpSl(symbol, avgPrice, totalVolume, isBuy, out tp, out sl);

            foreach (var p in Positions.Where(p => p.SymbolName == symbolName && p.TradeType == tradeType && PassesFilter(p)).ToList())
                ModifyPositionTpSl(p, tp, sl);
        }

        private void ApplyIndividualTpSl(Position position)
        {
            var symbol = Symbols.GetSymbol(position.SymbolName);
            bool isBuy = position.TradeType == TradeType.Buy;

            double? tp, sl;
            CalculateTpSl(symbol, position.EntryPrice, position.VolumeInUnits, isBuy, out tp, out sl);
            ModifyPositionTpSl(position, tp, sl);
        }

        private void ApplyToAllExistingPositions()
        {
            var filtered = Positions.Where(PassesFilter).ToList();

            if (TpMode == TpslMode.Transaction)
            {
                foreach (var p in filtered)
                    ApplyIndividualTpSl(p);
            }
            else
            {
                var groups = filtered
                    .GroupBy(p => new { p.SymbolName, p.TradeType })
                    .ToList();

                foreach (var g in groups)
                    ApplyGroupTpSl(g.Key.SymbolName, g.Key.TradeType);
            }
        }

        // ============================= AUTO TP/SL: SL COVER =============================

        private void ProcessSlCover()
        {
            var filtered = Positions.Where(PassesFilter).ToList();

            if (TpMode == TpslMode.Transaction)
            {
                foreach (var p in filtered)
                    CheckAndCoverIndividual(p);
            }
            else
            {
                var groups = filtered.GroupBy(p => new { p.SymbolName, p.TradeType });
                foreach (var g in groups)
                    CheckAndCoverGroup(g.Key.SymbolName, g.Key.TradeType);
            }
        }

        private static double ProfitPercent(double entryPrice, double currentPrice, bool isBuy)
        {
            if (entryPrice <= 0) return 0;
            return isBuy
                ? (currentPrice - entryPrice) / entryPrice * 100.0
                : (entryPrice - currentPrice) / entryPrice * 100.0;
        }

        private void CheckAndCoverIndividual(Position position)
        {
            var symbol = Symbols.GetSymbol(position.SymbolName);
            bool isBuy = position.TradeType == TradeType.Buy;
            double entryPrice = position.EntryPrice;
            double currentPrice = isBuy ? symbol.Bid : symbol.Ask;

            double profitPct = ProfitPercent(entryPrice, currentPrice, isBuy);
            if (profitPct < CoverProfitThresholdPercent) return;

            double newSl = isBuy
                ? entryPrice * (1.0 + CoverSlValuePercent / 100.0)
                : entryPrice * (1.0 - CoverSlValuePercent / 100.0);
            newSl = NormalizePrice(symbol, newSl);

            double? currentSl = position.StopLoss;
            bool improves = !currentSl.HasValue || (isBuy ? newSl > currentSl.Value : newSl < currentSl.Value);
            if (!improves) return;

            if (isBuy && newSl >= currentPrice) return;
            if (!isBuy && newSl <= currentPrice) return;

            ModifyPositionTpSl(position, position.TakeProfit, newSl);
        }

        private void CheckAndCoverGroup(string symbolName, TradeType tradeType)
        {
            double totalVolume;
            double avgPrice = WeightedAveragePrice(symbolName, tradeType, out totalVolume);
            if (avgPrice <= 0) return;

            var symbol = Symbols.GetSymbol(symbolName);
            bool isBuy = tradeType == TradeType.Buy;
            double currentPrice = isBuy ? symbol.Bid : symbol.Ask;

            double profitPct = ProfitPercent(avgPrice, currentPrice, isBuy);
            if (profitPct < CoverProfitThresholdPercent) return;

            double newSl = isBuy
                ? avgPrice * (1.0 + CoverSlValuePercent / 100.0)
                : avgPrice * (1.0 - CoverSlValuePercent / 100.0);
            newSl = NormalizePrice(symbol, newSl);

            if (isBuy && newSl >= currentPrice) return;
            if (!isBuy && newSl <= currentPrice) return;

            foreach (var p in Positions.Where(p => p.SymbolName == symbolName && p.TradeType == tradeType && PassesFilter(p)).ToList())
            {
                double? currentSl = p.StopLoss;
                bool improves = !currentSl.HasValue || (isBuy ? newSl > currentSl.Value : newSl < currentSl.Value);
                if (improves)
                    ModifyPositionTpSl(p, p.TakeProfit, newSl);
            }
        }

        // ============================= PANEL UI (cAlgo Controls) =============================

        private Border _rootControl;

        private void BuildPanel()
        {
            var stack = new StackPanel
            {
                Orientation = Orientation.Vertical,
                Margin = 6
            };

            stack.AddChild(new TextBlock
            {
                Text = "HOTKEY TRADER",
                ForegroundColor = Color.DodgerBlue,
                FontWeight = FontWeight.Bold,
                FontSize = 12,
                Margin = new Thickness(0, 0, 0, 6)
            });

            stack.AddChild(MakeHotkeyButton("btnLong", string.Format("[ {0} ]  Long Market", _letterLong), Color.DeepSkyBlue, DoLong));
            stack.AddChild(MakeHotkeyButton("btnShort", string.Format("[ {0} ]  Short Market", _letterShort), Color.Tomato, DoShort));
            stack.AddChild(MakeHotkeyButton("btnFlat", string.Format("[ {0} ]  Flat All", _letterFlat), Color.Orange, DoFlat));
            stack.AddChild(MakeHotkeyButton("btnRiskFree", string.Format("[ {0} ]  Risk Free", _letterRiskFree), Color.YellowGreen, DoRiskFree));
            stack.AddChild(MakeHotkeyButton("btnHedge", string.Format("[ {0} ]  Hedge", _letterHedge), Color.Gold, DoHedge));

            // --- Lot size row (TextBox + explicit Set button, instead of MT5's blur/Enter EndEdit) ---
            var lotRow = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 8, 0, 4) };
            lotRow.AddChild(new TextBlock { Text = "Lot Size:", ForegroundColor = Color.Silver, Width = 60, VerticalAlignment = VerticalAlignment.Center });
            _lotTextBox = new TextBox { Text = _lotSize.ToString("0.####"), Width = 70, ForegroundColor = Color.White, BackgroundColor = Color.Black };
            lotRow.AddChild(_lotTextBox);
            var setLotBtn = new Button { Text = "Set", Width = 64, Margin = new Thickness(4, 0, 0, 0) };
            setLotBtn.Click += args => ApplyLotEdit();
            lotRow.AddChild(setLotBtn);
            stack.AddChild(lotRow);

            _maxLabel = new TextBlock { Text = MaxOpenLotsText(), ForegroundColor = Color.Silver, Margin = new Thickness(0, 0, 0, 2) };
            stack.AddChild(_maxLabel);

            _posLabel = new TextBlock { Text = "Open positions: --", ForegroundColor = Color.Silver, Margin = new Thickness(0, 0, 0, 2) };
            stack.AddChild(_posLabel);

            _statusLabel = new TextBlock { Text = _status, ForegroundColor = Color.LightGray, FontSize = 9, Margin = new Thickness(0, 0, 0, 8) };
            stack.AddChild(_statusLabel);

            _toggleButton = new Button { Text = "Auto TPSL: OFF", Width = 200, Height = 28 };
            _toggleButton.Click += args => OnToggleClicked();
            stack.AddChild(_toggleButton);
            UpdateToggleButtonVisual();

            _rootControl = new Border
            {
                BackgroundColor = PanelBg,
                BorderColor = PanelBorder,
                BorderThickness = 1,
                CornerRadius = 4,
                Padding = 6,
                VerticalAlignment = PanelVerticalAlignment,
                HorizontalAlignment = PanelHorizontalAlignment,
                Child = stack
            };

            // Wrap the panel in cTrader's native draggable control so the whole
            // box can be picked up and moved anywhere on the chart with the
            // mouse. See porting note 8 at the top of this file.
            _panelDraggable = Chart.Draggables.Add();
            _panelDraggable.Child = _rootControl;
        }

        private Button MakeHotkeyButton(string name, string text, Color color, Action onClick)
        {
            var btn = new Button
            {
                Text = text,
                ForegroundColor = color,
                Width = 200,
                Height = 22,
                Margin = new Thickness(0, 0, 0, 3),
                HorizontalContentAlignment = HorizontalAlignment.Left
            };
            btn.Click += args => onClick();
            return btn;
        }

        private string MaxOpenLotsText()
        {
            return MaxOpenLots <= 0 ? "Max/Dir: Unlimited" : string.Format("Max/Dir: {0} lots", MaxOpenLots);
        }

        private void UpdateToggleButtonVisual()
        {
            if (_toggleButton == null) return;
            _toggleButton.Text = _autoTpslEnabled ? "Auto TPSL: ON" : "Auto TPSL: OFF";
            _toggleButton.BackgroundColor = _autoTpslEnabled ? ToggleOnColor : ToggleOffColor;
            _toggleButton.ForegroundColor = Color.White;
        }

        private void OnToggleClicked()
        {
            _autoTpslEnabled = !_autoTpslEnabled;
            UpdateToggleButtonVisual();

            _status = string.Format("Auto TPSL {0}", _autoTpslEnabled ? "ENABLED" : "DISABLED");
            Print("Auto TPSL {0} via panel button.", _autoTpslEnabled ? "ENABLED" : "DISABLED");

            if (_autoTpslEnabled)
                ApplyToAllExistingPositions(); // apply immediately instead of waiting for the next new position

            UpdatePanelInfo();
        }

        private void ApplyLotEdit()
        {
            double val;
            if (!double.TryParse(_lotTextBox.Text, out val) || val <= 0)
            {
                _status = "Invalid lot size entered - keeping previous value";
            }
            else
            {
                _lotSize = NormalizeLots(Symbol, val);
                _status = string.Format("Lot size set to {0}", _lotSize);
            }

            _lotTextBox.Text = _lotSize.ToString("0.####");
            UpdatePanelInfo();
        }

        private void UpdatePanelInfo()
        {
            int count;
            double lots;
            GetPositionStats(out count, out lots);

            if (_posLabel != null) _posLabel.Text = string.Format("Open positions: {0}", count);
            if (_maxLabel != null) _maxLabel.Text = MaxOpenLotsText();
            if (_statusLabel != null) _statusLabel.Text = _status;
        }
    }
}