using System;
using System.Globalization;
using cAlgo.API;
using cAlgo.API.Internals;

namespace cAlgo.Robots
{
    public enum RiskMode
    {
        Lots = 0,          // fixed lot size
        MoneyPerPip = 1,   // fixed $ risk per pip
        PercentBalance = 2,// % of account balance
        FixedAmount = 3    // fixed money amount
    }

    public enum OrderKind
    {
        None = -1,
        Buy = 0,
        Sell = 1,
        BuyStop = 2,
        SellStop = 3,
        BuyLimit = 4,
        SellLimit = 5
    }

    [Robot(TimeZone = TimeZones.UTC, AccessRights = AccessRights.FullAccess)]
    public class PositionSizerCBot : Robot
    {
        #region Inputs

        [Parameter("Default SL (pips)", DefaultValue = 200, MinValue = 1, Group = "Defaults")]
        public double InpDefaultSlPips { get; set; }

        [Parameter("Default RRR", DefaultValue = 1.0, MinValue = 0.01, Group = "Defaults")]
        public double InpDefaultRrr { get; set; }

        [Parameter("Default risk value", DefaultValue = 10.0, MinValue = 0, Group = "Defaults")]
        public double InpDefaultRiskValue { get; set; }

        [Parameter("Label", DefaultValue = "PositionSizerCBot", Group = "Orders")]
        public string InpLabel { get; set; }

        [Parameter("Slippage (pips, market orders)", DefaultValue = 1, MinValue = 0, Group = "Orders")]
        public double InpSlippagePips { get; set; }

        [Parameter("Commission override per lot (one-way, account ccy, 0 = auto)", DefaultValue = 0.0, MinValue = 0, Group = "Commission")]
        public double InpCommissionOverridePerLot { get; set; }

        #endregion

        #region Constants

        private const string PFX = "PSZ_";
        private const double MIN_STOP_DISTANCE_PIPS = 2.0; // see header note on stops-level approximation

        #endregion

        #region State

        private RiskMode _riskMode = RiskMode.FixedAmount;
        private OrderKind _orderKind = OrderKind.None;

        private double _riskValue;
        private double _rrr;
        private double _entryPrice, _slPrice, _tpPrice;

        private bool _linesExist;
        private bool _syncing; // guard against feedback loops between lines <-> textboxes

        private ChartHorizontalLine _lineEntry, _lineSl, _lineTp;

        // Panel controls we need to reach after creation
        private TextBlock _bidAskLabel;
        private TextBlock _infoLabel;
        private Button _riskModeButton;
        private TextBox _riskValueBox, _rrrBox, _entryBox, _slBox, _tpBox;
        private Button _buyBtn, _sellBtn, _buyStopBtn, _sellStopBtn, _buyLimitBtn, _sellLimitBtn;

        private readonly Color _clrBuy = Color.FromHex("#2E8B57");
        private readonly Color _clrBuyHi = Color.FromHex("#FFA500");
        private readonly Color _clrSell = Color.FromHex("#B22222");
        private readonly Color _clrSellHi = Color.FromHex("#FFA500");

        // Drag state - the panel is repositioned by editing its own Margin
        // (Left/Top) while it stays pinned to the chart's top-left corner via
        // HorizontalAlignment/VerticalAlignment, so it doesn't scroll/zoom
        // with price the way a chart object would.
        private Border _rootPanel;
        private const double PANEL_WIDTH_PX = 300;   // approx. rendered width, for title-bar hit testing
        private const double TITLE_BAR_HEIGHT_PX = 22;
        private double _panelLeft = 6, _panelTop = 6;
        private bool _dragging;
        private double _dragOffsetX, _dragOffsetY;

        #endregion

        #region Lifecycle

        protected override void OnStart()
        {
            _riskMode = RiskMode.FixedAmount;
            _riskValue = InpDefaultRiskValue;
            _rrr = InpDefaultRrr;
            _orderKind = OrderKind.None;
            _linesExist = false;

            double price = Symbol.Bid > 0 ? Symbol.Bid : Symbol.Ask;
            _entryPrice = price;
            _slPrice = price - InpDefaultSlPips * Symbol.PipSize;
            RecalcTpFromRrr();

            BuildPanel();
            RefreshTextBoxes();
            UpdateBidAskLabel();
            UpdateInfoLabel();
            HighlightOrderTypeButtons();

            Chart.ObjectsUpdated += OnChartObjectsUpdated;
            Symbol.Tick += OnSymbolTick;
            Chart.MouseDown += Chart_MouseDown;
            Chart.MouseMove += Chart_MouseMove;
            Chart.MouseUp += Chart_MouseUp;
        }

        protected override void OnStop()
        {
            Chart.ObjectsUpdated -= OnChartObjectsUpdated;
            Symbol.Tick -= OnSymbolTick;
            Chart.MouseDown -= Chart_MouseDown;
            Chart.MouseMove -= Chart_MouseMove;
            Chart.MouseUp -= Chart_MouseUp;
            RemoveLines();
        }

        protected override void OnTick()
        {
            // Market orders: entry isn't user-chosen, it's whatever the market
            // gives you at send time - keep the entry line/price locked to
            // live Ask (buy side) / Bid (sell side).
            if (_linesExist && IsMarketType(_orderKind))
            {
                double live = IsBuyType(_orderKind) ? Symbol.Ask : Symbol.Bid;
                if (live > 0 && Math.Abs(live - _entryPrice) > double.Epsilon)
                {
                    _entryPrice = live;
                    OnEntryChanged();
                }
            }

            // Pending orders: re-clamp in case price moved through the entry
            if (_linesExist && _orderKind != OrderKind.None && !IsMarketType(_orderKind))
            {
                if (ClampEntryForOrderKind())
                {
                    RecalcRrrFromTp();
                    SyncAll();
                }
            }

            UpdateBidAskLabel();
            UpdateInfoLabel();
        }

        private void OnSymbolTick(SymbolTickEventArgs args)
        {
            // Kept separate from OnTick (which only fires for the chart's own
            // symbol/timeframe pair) purely for clarity; OnTick above already
            // covers everything needed since the cBot only trades its own chart symbol.
        }

        #endregion

        #region Panel dragging

        // The panel has no native "draggable" flag (that's a chart-object
        // concept, not a Controls-API one), so dragging is hand-rolled: track
        // mouse-down inside the title-bar strip, then on every mouse-move
        // while dragging, shift the panel's Margin by the same delta the
        // cursor moved. MouseX/MouseY are pixel coordinates within the chart
        // area, which lines up with how Margin positions a Left/Top-anchored
        // control.
        private void Chart_MouseDown(ChartMouseEventArgs obj)
        {
            if (IsOverTitleBar(obj.MouseX, obj.MouseY))
            {
                _dragging = true;
                _dragOffsetX = obj.MouseX - _panelLeft;
                _dragOffsetY = obj.MouseY - _panelTop;
            }
        }

        private void Chart_MouseMove(ChartMouseEventArgs obj)
        {
            if (!_dragging || _rootPanel == null) return;

            _panelLeft = Math.Max(0, obj.MouseX - _dragOffsetX);
            _panelTop = Math.Max(0, obj.MouseY - _dragOffsetY);
            _rootPanel.Margin = new Thickness(_panelLeft, _panelTop, 0, 0);
        }

        private void Chart_MouseUp(ChartMouseEventArgs obj)
        {
            _dragging = false;
        }

        private bool IsOverTitleBar(double x, double y)
        {
            return x >= _panelLeft && x <= _panelLeft + PANEL_WIDTH_PX
                && y >= _panelTop && y <= _panelTop + TITLE_BAR_HEIGHT_PX;
        }

        #endregion

        #region Panel construction (Controls API)

        private void BuildPanel()
        {
            var root = new Border
            {
                BackgroundColor = Color.FromHex("#14161E"),
                BorderColor = Color.FromHex("#555555"),
                BorderThickness = 1,
                CornerRadius = 4,
                Padding = 8,
                HorizontalAlignment = HorizontalAlignment.Left,
                VerticalAlignment = VerticalAlignment.Top,
                Margin = new Thickness(_panelLeft, _panelTop, 0, 0)
            };
            _rootPanel = root;

            var outer = new StackPanel { Orientation = Orientation.Vertical };

            // Title - also doubles as the drag handle (see Chart_MouseDown);
            // the "::" hints that it's grabbable, same idea as a title-bar drag cue.
            outer.AddChild(new TextBlock
            {
                Text = ":: Position Sizer (drag here to move)",
                ForegroundColor = Color.White,
                FontWeight = FontWeight.Bold,
                FontSize = 12,
                Margin = new Thickness(0, 0, 0, 4)
            });

            // Bid/Ask readout
            _bidAskLabel = new TextBlock { Text = "Bid -- Ask --", ForegroundColor = Color.Silver, FontSize = 10, Margin = new Thickness(0, 0, 0, 6) };
            outer.AddChild(_bidAskLabel);

            // Risk mode + value
            _riskModeButton = new Button { Text = RiskModeLabel(_riskMode), BackgroundColor = Color.SteelBlue, ForegroundColor = Color.White, Width = 110, Height = 24 };
            _riskModeButton.Click += RiskModeButton_Click;
            _riskValueBox = new TextBox { Text = _riskValue.ToString("0.##", CultureInfo.InvariantCulture), BackgroundColor = Color.White, ForegroundColor = Color.Black, Width = 150, Height = 22, Margin = new Thickness(6, 0, 0, 0) };
            _riskValueBox.TextChanged += RiskValueBox_TextChanged;
            outer.AddChild(MakeRow(_riskModeButton, _riskValueBox));

            // RRR / Entry / SL / TP - label + text box, each on its own row
            _rrrBox = new TextBox { Text = _rrr.ToString("0.##", CultureInfo.InvariantCulture), BackgroundColor = Color.White, ForegroundColor = Color.Black };
            _rrrBox.TextChanged += RrrBox_TextChanged;
            outer.AddChild(MakeFieldRow("RRR", _rrrBox));

            _entryBox = new TextBox { Text = FormatPrice(_entryPrice), BackgroundColor = Color.White, ForegroundColor = Color.Black };
            _entryBox.TextChanged += EntryBox_TextChanged;
            outer.AddChild(MakeFieldRow("Entry", _entryBox));

            _slBox = new TextBox { Text = FormatPrice(_slPrice), BackgroundColor = Color.White, ForegroundColor = Color.Black };
            _slBox.TextChanged += SlBox_TextChanged;
            outer.AddChild(MakeFieldRow("SL (Stop Loss)", _slBox));

            _tpBox = new TextBox { Text = FormatPrice(_tpPrice), BackgroundColor = Color.White, ForegroundColor = Color.Black };
            _tpBox.TextChanged += TpBox_TextChanged;
            outer.AddChild(MakeFieldRow("TP (Take Profit)", _tpBox));

            // Info readout
            _infoLabel = new TextBlock { Text = "Select an order type below", ForegroundColor = Color.Khaki, FontSize = 10, Margin = new Thickness(0, 4, 0, 6) };
            outer.AddChild(_infoLabel);

            // Order type buttons, 2 per row x 3 rows, each with real spacing
            _buyBtn = MakeOrderButton("Buy (Market)", _clrBuy);
            _sellBtn = MakeOrderButton("Sell (Market)", _clrSell);
            _buyStopBtn = MakeOrderButton("Buy Stop", _clrBuy);
            _sellStopBtn = MakeOrderButton("Sell Stop", _clrSell);
            _buyLimitBtn = MakeOrderButton("Buy Limit", _clrBuy);
            _sellLimitBtn = MakeOrderButton("Sell Limit", _clrSell);

            _buyBtn.Click += (a) => SelectOrderKind(OrderKind.Buy);
            _sellBtn.Click += (a) => SelectOrderKind(OrderKind.Sell);
            _buyStopBtn.Click += (a) => SelectOrderKind(OrderKind.BuyStop);
            _sellStopBtn.Click += (a) => SelectOrderKind(OrderKind.SellStop);
            _buyLimitBtn.Click += (a) => SelectOrderKind(OrderKind.BuyLimit);
            _sellLimitBtn.Click += (a) => SelectOrderKind(OrderKind.SellLimit);

            outer.AddChild(MakeRow(_buyBtn, _sellBtn));
            outer.AddChild(MakeRow(_buyStopBtn, _sellStopBtn));
            outer.AddChild(MakeRow(_buyLimitBtn, _sellLimitBtn));

            // Send / Cancel row
            var sendBtn = new Button { Text = "SEND ORDER", BackgroundColor = Color.DodgerBlue, ForegroundColor = Color.White, Width = 132, Height = 30, Margin = new Thickness(0, 6, 4, 0) };
            sendBtn.Click += (a) => SendOrder();
            var cancelBtn = new Button { Text = "CANCEL", BackgroundColor = Color.SlateGray, ForegroundColor = Color.White, Width = 132, Height = 30, Margin = new Thickness(4, 6, 0, 0) };
            cancelBtn.Click += (a) => ResetPanel();
            var actionRow = new StackPanel { Orientation = Orientation.Horizontal };
            actionRow.AddChild(sendBtn);
            actionRow.AddChild(cancelBtn);
            outer.AddChild(actionRow);

            root.Child = outer;
            Chart.AddControl(root);
        }

        // Label + text box on one row, with a gap between them and a gap
        // under the row so consecutive rows don't visually merge.
        private StackPanel MakeFieldRow(string labelText, TextBox box)
        {
            box.Width = 150;
            box.Height = 22;
            box.Margin = new Thickness(6, 0, 0, 0);

            var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 6) };
            row.AddChild(new TextBlock { Text = labelText, ForegroundColor = Color.Silver, FontSize = 10, Width = 110, VerticalAlignment = VerticalAlignment.Center });
            row.AddChild(box);
            return row;
        }

        // Two arbitrary controls side by side with a gap between them and a
        // gap under the row.
        private StackPanel MakeRow(ControlBase left, ControlBase right)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 4) };
            row.AddChild(left);
            row.AddChild(right);
            return row;
        }

        private Button MakeOrderButton(string text, Color bg)
        {
            return new Button { Text = text, BackgroundColor = bg, ForegroundColor = Color.White, Width = 132, Height = 30, Margin = new Thickness(0, 0, 4, 0) };
        }

        #endregion

        #region Panel event handlers

        // NOTE: cAlgo's TextBox only exposes a TextChanged event (no LostFocus/
        // Validated on that control), so - unlike the MQL5 original, which reacted
        // on OBJECT_ENDEDIT once the user tabbed away - these fire on every
        // keystroke. _syncing guards against the programmatic Text assignments in
        // RefreshTextBoxes() re-triggering these same handlers, and an unparsable
        // (incomplete) value is simply ignored rather than reverted, so the box
        // isn't fighting the user mid-edit.

        private void RiskModeButton_Click(ButtonClickEventArgs obj)
        {
            _riskMode = (RiskMode)(((int)_riskMode + 1) % 4);
            _riskModeButton.Text = RiskModeLabel(_riskMode);
            UpdateInfoLabel();
        }

        private void RiskValueBox_TextChanged(TextChangedEventArgs obj)
        {
            if (_syncing) return;
            if (TryParse(_riskValueBox.Text, out var v))
            {
                _riskValue = v;
                UpdateInfoLabel();
            }
        }

        private void RrrBox_TextChanged(TextChangedEventArgs obj)
        {
            if (_syncing) return;
            if (TryParse(_rrrBox.Text, out var v))
            {
                _rrr = v;
                RecalcTpFromRrr();
                SyncAll();
            }
        }

        private void EntryBox_TextChanged(TextChangedEventArgs obj)
        {
            if (_syncing || IsMarketType(_orderKind)) return; // read-only for market orders
            if (TryParse(_entryBox.Text, out var v))
            {
                _entryPrice = v;
                OnEntryChanged();
            }
        }

        private void SlBox_TextChanged(TextChangedEventArgs obj)
        {
            if (_syncing) return;
            if (TryParse(_slBox.Text, out var v))
            {
                _slPrice = v;
                OnSlChanged();
            }
        }

        private void TpBox_TextChanged(TextChangedEventArgs obj)
        {
            if (_syncing) return;
            if (TryParse(_tpBox.Text, out var v))
            {
                _tpPrice = v;
                OnTpChanged();
            }
        }

        private static bool TryParse(string s, out double v)
        {
            return double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out v);
        }

        #endregion

        #region Order type selection

        private void SelectOrderKind(OrderKind kind)
        {
            double bid = Symbol.Bid, ask = Symbol.Ask;
            double off = InpDefaultSlPips * Symbol.PipSize;

            _orderKind = kind;
            switch (kind)
            {
                case OrderKind.Buy: _entryPrice = ask; break;
                case OrderKind.Sell: _entryPrice = bid; break;
                case OrderKind.BuyStop: _entryPrice = ask + off; break;
                case OrderKind.SellStop: _entryPrice = bid - off; break;
                case OrderKind.BuyLimit: _entryPrice = bid - off; break;
                case OrderKind.SellLimit: _entryPrice = ask + off; break;
            }

            ClampEntryForOrderKind(); // guard in case default offset is inside the min-distance buffer

            bool buyBias = IsBuyType(_orderKind);
            _slPrice = buyBias ? _entryPrice - off : _entryPrice + off;
            RecalcTpFromRrr();

            EnsureLinesExist();
            HighlightOrderTypeButtons();
            SyncAll();
        }

        private void HighlightOrderTypeButtons()
        {
            _buyBtn.BackgroundColor = _orderKind == OrderKind.Buy ? _clrBuyHi : _clrBuy;
            _sellBtn.BackgroundColor = _orderKind == OrderKind.Sell ? _clrSellHi : _clrSell;
            _buyStopBtn.BackgroundColor = _orderKind == OrderKind.BuyStop ? _clrBuyHi : _clrBuy;
            _sellStopBtn.BackgroundColor = _orderKind == OrderKind.SellStop ? _clrSellHi : _clrSell;
            _buyLimitBtn.BackgroundColor = _orderKind == OrderKind.BuyLimit ? _clrBuyHi : _clrBuy;
            _sellLimitBtn.BackgroundColor = _orderKind == OrderKind.SellLimit ? _clrSellHi : _clrSell;
        }

        private static bool IsBuyType(OrderKind k) => k == OrderKind.Buy || k == OrderKind.BuyStop || k == OrderKind.BuyLimit;
        private static bool IsMarketType(OrderKind k) => k == OrderKind.Buy || k == OrderKind.Sell;

        #endregion

        #region Lines (Entry / SL / TP)

        private void EnsureLinesExist()
        {
            if (!_linesExist)
            {
                _lineEntry = Chart.DrawHorizontalLine(PFX + "Entry", _entryPrice, Color.Yellow, 2, LineStyle.Dots);
                _lineSl = Chart.DrawHorizontalLine(PFX + "SL", _slPrice, Color.Red, 2, LineStyle.Dots);
                _lineTp = Chart.DrawHorizontalLine(PFX + "TP", _tpPrice, Color.LimeGreen, 2, LineStyle.Dots);
                _lineEntry.IsInteractive = true;
                _lineSl.IsInteractive = true;
                _lineTp.IsInteractive = true;
                _linesExist = true;
            }

            // Market orders: entry price isn't user-chosen, lock the line and
            // switch it to a solid style as a visual "locked" cue. Pending
            // orders keep it draggable and dotted.
            bool draggable = !IsMarketType(_orderKind);
            _lineEntry.IsInteractive = draggable;
            _lineEntry.LineStyle = draggable ? LineStyle.Dots : LineStyle.Solid;
        }

        private void RemoveLines()
        {
            if (!_linesExist) return;
            Chart.RemoveObject(PFX + "Entry");
            Chart.RemoveObject(PFX + "SL");
            Chart.RemoveObject(PFX + "TP");
            _lineEntry = _lineSl = _lineTp = null;
            _linesExist = false;
        }

        private void OnChartObjectsUpdated(ChartObjectsUpdatedEventArgs args)
        {
            if (!_linesExist) return;

            foreach (var obj in args.ChartObjects)
            {
                if (obj.Name == PFX + "Entry" && _lineEntry != null && !IsMarketType(_orderKind))
                {
                    _entryPrice = _lineEntry.Y;
                    OnEntryChanged();
                }
                else if (obj.Name == PFX + "SL" && _lineSl != null)
                {
                    _slPrice = _lineSl.Y;
                    OnSlChanged();
                }
                else if (obj.Name == PFX + "TP" && _lineTp != null)
                {
                    _tpPrice = _lineTp.Y;
                    OnTpChanged();
                }
            }
        }

        #endregion

        #region Reaction logic (keeps Entry/SL/TP/RRR consistent)

        // Keeps a pending order's entry on the side of price it's required to
        // be on. Buy/Sell Stop must sit beyond current Ask/Bid; Buy/Sell Limit
        // must sit inside it. See MIN_STOP_DISTANCE_PIPS note in the header.
        private bool ClampEntryForOrderKind()
        {
            if (_orderKind == OrderKind.None || IsMarketType(_orderKind)) return false;

            double bid = Symbol.Bid, ask = Symbol.Ask;
            double minDist = MIN_STOP_DISTANCE_PIPS * Symbol.PipSize;
            double before = _entryPrice;

            switch (_orderKind)
            {
                case OrderKind.BuyStop:
                    if (_entryPrice < ask + minDist) _entryPrice = ask + minDist;
                    break;
                case OrderKind.SellStop:
                    if (_entryPrice > bid - minDist) _entryPrice = bid - minDist;
                    break;
                case OrderKind.BuyLimit:
                    if (_entryPrice > bid - minDist) _entryPrice = bid - minDist;
                    break;
                case OrderKind.SellLimit:
                    if (_entryPrice < ask + minDist) _entryPrice = ask + minDist;
                    break;
            }

            return Math.Abs(_entryPrice - before) > double.Epsilon;
        }

        private void RecalcTpFromRrr()
        {
            double risk = Math.Abs(_entryPrice - _slPrice);
            double reward = risk * _rrr;
            bool buyBias = IsBuyType(_orderKind);
            if (_orderKind == OrderKind.None) buyBias = _slPrice < _entryPrice; // infer direction
            _tpPrice = buyBias ? _entryPrice + reward : _entryPrice - reward;
        }

        private void RecalcRrrFromTp()
        {
            double risk = Math.Abs(_entryPrice - _slPrice);
            double reward = Math.Abs(_tpPrice - _entryPrice);
            _rrr = risk > 0 ? reward / risk : 0;
        }

        private void OnEntryChanged()
        {
            ClampEntryForOrderKind();
            RecalcRrrFromTp();
            SyncAll();
        }

        private void OnSlChanged()
        {
            RecalcTpFromRrr();
            SyncAll();
        }

        private void OnTpChanged()
        {
            RecalcRrrFromTp();
            SyncAll();
        }

        private void SyncAll()
        {
            if (_syncing) return;
            _syncing = true;

            if (_linesExist)
            {
                _lineEntry.Y = _entryPrice;
                _lineSl.Y = _slPrice;
                _lineTp.Y = _tpPrice;
            }

            RefreshTextBoxes();
            UpdateInfoLabel();

            _syncing = false;
        }

        private void RefreshTextBoxes()
        {
            _entryBox.Text = FormatPrice(_entryPrice);
            _slBox.Text = FormatPrice(_slPrice);
            _tpBox.Text = FormatPrice(_tpPrice);
            _rrrBox.Text = _rrr.ToString("0.00", CultureInfo.InvariantCulture);
            _riskValueBox.Text = _riskValue.ToString("0.##", CultureInfo.InvariantCulture);
            _riskModeButton.Text = RiskModeLabel(_riskMode);

            // For market orders the entry box just mirrors the live price - grey it out
            _entryBox.IsReadOnly = IsMarketType(_orderKind);
            _entryBox.BackgroundColor = IsMarketType(_orderKind) ? Color.Gainsboro : Color.White;
        }

        #endregion

        #region Sizing math (commission-aware)

        private string FormatPrice(double p) => p.ToString("F" + Symbol.Digits, CultureInfo.InvariantCulture);

        private string RiskModeLabel(RiskMode m)
        {
            switch (m)
            {
                case RiskMode.Lots: return "Risk: Lots";
                case RiskMode.MoneyPerPip: return "Risk: $/Pip";
                case RiskMode.PercentBalance: return "Risk: % Balance";
                case RiskMode.FixedAmount: return "Risk: Amount $";
            }
            return "Risk: Lots";
        }

        // Money value of one pip for ONE unit of volume, in account currency.
        // Symbol.PipValue is already account-currency-converted by cAlgo.
        private double PipValuePerLot => Symbol.PipValue * Symbol.LotSize;

        // One-way commission per lot, in account currency, at the current price.
        // See the header comment for the accuracy caveat on the two
        // notional-based commission types.
        private double CommissionPerLotOneWay()
        {
            if (InpCommissionOverridePerLot > 0)
                return InpCommissionOverridePerLot;

            double notionalPerLot = Symbol.LotSize * Symbol.Bid; // approx notional value of 1 lot

            switch (Symbol.CommissionType)
            {
                case SymbolCommissionType.UsdPerOneLot:
                    return Symbol.Commission;
                case SymbolCommissionType.QuoteCurrencyPerOneLot:
                    // Assumes quote currency ~= account currency; use the
                    // override input above if that assumption doesn't hold.
                    return Symbol.Commission;
                case SymbolCommissionType.UsdPerMillionUsdVolume:
                    return Symbol.Commission * (notionalPerLot / 1_000_000.0);
                case SymbolCommissionType.PercentageOfTradingVolume:
                    return notionalPerLot * (Symbol.Commission / 100.0);
                default:
                    return 0;
            }
        }

        private double CommissionPerLotRoundTrip() => CommissionPerLotOneWay() * 2.0;

        private double CalcLots()
        {
            double slPips = Math.Abs(_entryPrice - _slPrice) / Symbol.PipSize;
            double pipValuePerLot = PipValuePerLot;
            double commissionRtPerLot = CommissionPerLotRoundTrip();
            double lots;

            switch (_riskMode)
            {
                case RiskMode.Lots:
                    lots = _riskValue;
                    break;
                case RiskMode.MoneyPerPip:
                    lots = pipValuePerLot > 0 ? _riskValue / pipValuePerLot : 0;
                    break;
                case RiskMode.PercentBalance:
                    {
                        double riskMoney = Account.Balance * _riskValue / 100.0;
                        double perLotCost = slPips * pipValuePerLot + commissionRtPerLot;
                        lots = perLotCost > 0 ? riskMoney / perLotCost : 0;
                        break;
                    }
                case RiskMode.FixedAmount:
                    {
                        double perLotCost = slPips * pipValuePerLot + commissionRtPerLot;
                        lots = perLotCost > 0 ? _riskValue / perLotCost : 0;
                        break;
                    }
                default:
                    lots = 0;
                    break;
            }

            double volumeUnits = Symbol.QuantityToVolumeInUnits(Math.Max(lots, 0));
            volumeUnits = Symbol.NormalizeVolumeInUnits(volumeUnits, RoundingMode.ToNearest);
            return Symbol.VolumeInUnitsToQuantity(volumeUnits);
        }

        private void UpdateBidAskLabel()
        {
            double spreadPips = Symbol.PipSize > 0 ? Symbol.Spread / Symbol.PipSize : 0;
            _bidAskLabel.Text = string.Format(CultureInfo.InvariantCulture,
                "Bid {0}   Ask {1}   Spread {2:0.0} pips",
                FormatPrice(Symbol.Bid), FormatPrice(Symbol.Ask), spreadPips);
        }

        private void UpdateInfoLabel()
        {
            if (_orderKind == OrderKind.None)
            {
                _infoLabel.Text = "Select an order type below to place the Entry/SL/TP lines";
                return;
            }

            double lots = CalcLots();
            double slPips = Math.Abs(_entryPrice - _slPrice) / Symbol.PipSize;
            double priceRisk = lots * slPips * PipValuePerLot;
            double commissionRt = lots * CommissionPerLotRoundTrip();
            double totalRisk = priceRisk + commissionRt;
            double balance = Account.Balance;
            double riskPct = balance > 0 ? totalRisk / balance * 100.0 : 0;

            _infoLabel.Text = string.Format(CultureInfo.InvariantCulture,
                "Lots: {0:0.00}   Risk: {1:0.00} {5} ({2:0.00}%)   Commission (RT): {3:0.00} {5}   RRR: {4:0.00}",
                lots, totalRisk, riskPct, commissionRt, _rrr, Account.Asset.Name);
        }

        #endregion

        #region Order sending

        // slPips/tpPips below are distances in pips, not prices.
        // ExecuteMarketOrder's stopLoss/takeProfit parameters are pip
        // offsets by design (no ProtectionType there - its 9th parameter is
        // StopTriggerMethod?, unrelated), so those two calls need no change.
        // PlaceStopOrder/PlaceLimitOrder, however, now take an explicit
        // ProtectionType: passing ProtectionType.Relative tells cAlgo to
        // interpret stopLoss/takeProfit as pip offsets from the fill price,
        // same as before (ProtectionType.Absolute would mean actual prices
        // instead). This replaces the older stopLossPips/takeProfitPips-
        // named overload, which is obsolete but was already pip-based - so
        // behavior is unchanged, only the parameter names/shape are.
        // NOTE: a handful of forum reports describe PlaceStopOrder/
        // PlaceLimitOrder throwing a TypeLoadException on cAlgo's cloud
        // runners specifically when ProtectionType is passed (local/terminal
        // execution is unaffected). If you hit that running this in the
        // cloud, drop the trailing ProtectionType.Relative argument from
        // those two calls to fall back to the older overload.
        private void SendOrder()
        {
            if (_orderKind == OrderKind.None)
            {
                Print("Pick an order type first (Buy, Sell, Buy Stop, ...)");
                return;
            }

            double lots = CalcLots();
            double volumeUnits = Symbol.NormalizeVolumeInUnits(Symbol.QuantityToVolumeInUnits(lots), RoundingMode.ToNearest);
            if (volumeUnits <= 0)
            {
                Print("Computed volume is 0 - check your risk value / SL distance.");
                return;
            }

            double slPips = Math.Abs(_entryPrice - _slPrice) / Symbol.PipSize;
            double tpPips = Math.Abs(_tpPrice - _entryPrice) / Symbol.PipSize;

            TradeResult result;
            double bid = Symbol.Bid, ask = Symbol.Ask;

            switch (_orderKind)
            {
                case OrderKind.Buy:
                    result = ExecuteMarketOrder(TradeType.Buy, SymbolName, volumeUnits, InpLabel, slPips, tpPips, null, false);
                    break;
                case OrderKind.Sell:
                    result = ExecuteMarketOrder(TradeType.Sell, SymbolName, volumeUnits, InpLabel, slPips, tpPips, null, false);
                    break;
                case OrderKind.BuyStop:
                    if (_entryPrice <= ask) { Print("Buy Stop entry must be ABOVE current Ask ({0})", FormatPrice(ask)); return; }
                    result = PlaceStopOrder(TradeType.Buy, SymbolName, volumeUnits, _entryPrice, InpLabel, slPips, tpPips, ProtectionType.Relative);
                    break;
                case OrderKind.SellStop:
                    if (_entryPrice >= bid) { Print("Sell Stop entry must be BELOW current Bid ({0})", FormatPrice(bid)); return; }
                    result = PlaceStopOrder(TradeType.Sell, SymbolName, volumeUnits, _entryPrice, InpLabel, slPips, tpPips, ProtectionType.Relative);
                    break;
                case OrderKind.BuyLimit:
                    if (_entryPrice >= bid) { Print("Buy Limit entry must be BELOW current Bid ({0})", FormatPrice(bid)); return; }
                    result = PlaceLimitOrder(TradeType.Buy, SymbolName, volumeUnits, _entryPrice, InpLabel, slPips, tpPips, ProtectionType.Relative);
                    break;
                case OrderKind.SellLimit:
                    if (_entryPrice <= ask) { Print("Sell Limit entry must be ABOVE current Ask ({0})", FormatPrice(ask)); return; }
                    result = PlaceLimitOrder(TradeType.Sell, SymbolName, volumeUnits, _entryPrice, InpLabel, slPips, tpPips, ProtectionType.Relative);
                    break;
                default:
                    return;
            }

            if (result == null || !result.IsSuccessful)
            {
                Print("Order failed: {0}", result?.Error);
            }
            else
            {
                Print("Order sent OK. Lots={0} Entry={1} SL={2} TP={3}", lots, FormatPrice(_entryPrice), FormatPrice(_slPrice), FormatPrice(_tpPrice));
                ResetPanel();
            }
        }

        private void ResetPanel()
        {
            _orderKind = OrderKind.None;
            RemoveLines();
            HighlightOrderTypeButtons();

            double price = Symbol.Bid;
            _entryPrice = price;
            _slPrice = price - InpDefaultSlPips * Symbol.PipSize;
            _rrr = InpDefaultRrr;
            RecalcTpFromRrr();
            SyncAll();
        }

        #endregion
    }
}