using System;
using cAlgo.API;

namespace cAlgo.Robots
{
    public enum RiskType
    {
        FixedLots,
        MoneyAmount,
        BalancePercentage
    }

    [Robot(TimeZone = TimeZones.UTC, AccessRights = AccessRights.None)]
    public class ContractedRB : Robot
    {
        [Parameter("Max Range Delta", DefaultValue = 10.0, Group = "Trade Management")]
        public double MaxRangeDelta { get; set; }

        [Parameter("Range Length", DefaultValue = 5, Group = "Trade Management")]
        public int RangeLength { get; set; }

        [Parameter("Max Look Ahead Time", DefaultValue = "02:00:00", Group = "Trade Management")]
        public TimeSpan MaxLookAheadTime { get; set; }

        [Parameter("Risk Reward Ratio", DefaultValue = 2.0, MinValue = 0.1)]
        public double RRR { get; set; }

        [Parameter("Risk Type", DefaultValue = RiskType.MoneyAmount)]
        public RiskType SelectedRiskType { get; set; }

        [Parameter("Fixed Volume (Lots)", DefaultValue = 0.01, MinValue = 0.01, Group = "Risk")]
        public double FixedLots { get; set; }

        [Parameter("Risk Amount (Money)", DefaultValue = 10.0, MinValue = 0.01, Group = "Risk")]
        public double RiskMoney { get; set; }

        [Parameter("Risk Percent of Balance", DefaultValue = 1.0, MinValue = 0.01, MaxValue = 100, Group = "Risk")]
        public double RiskPercent { get; set; }

        [Parameter("Box Opacity (0-1)", DefaultValue = 0.5, MinValue = 0, MaxValue = 1)]
        public double BoxOpacity { get; set; }

        [Parameter("Use OCO (cancel opposite order)", DefaultValue = true)]
        public bool UseOCO { get; set; }

        private double rangeHigh;
        private double rangeLow;
        private bool rangeActive;
        private bool ordersPlaced;
        private string rangeBoxName;

        private DateTime rangeStart;
        private DateTime rangeEnd;

        private PendingOrder buyStopOrder;
        private PendingOrder sellStopOrder;

        private double RangeDelta()
        {
            rangeHigh = Bars.HighPrices.Maximum(RangeLength);
            rangeLow = Bars.LowPrices.Minimum(RangeLength);
            
            return rangeHigh - rangeLow;
        }

        private void DrawRangeBox()
        {
            var box = Chart.DrawRectangle(
                rangeBoxName,
                rangeStart,
                rangeHigh,
                rangeEnd,
                rangeLow,
                Color.FromArgb((int)(BoxOpacity * 255), Color.Red),
                1,
                LineStyle.Solid
            );

            box.IsFilled = true;
        }

        private void UpdateRange()
        {
            if (ordersPlaced)
                return;

            double _range_delta = RangeDelta();
            Print(_range_delta);

            if (_range_delta > MaxRangeDelta)
                // Chart.RemoveObject(rangeBoxName);
                return;

            int lastBar = Bars.Count - 1;
            int firstBar = Math.Max(0, Bars.Count - RangeLength);

            rangeStart = Bars.OpenTimes[firstBar];
            rangeEnd = Bars.OpenTimes[lastBar];
            
            DrawRangeBox();

            PlaceOcoOrders();
            ordersPlaced = true;
        }

        // Money lost per 1 unit of volume if price moves 'slDistance' against you.
        private double LossPerUnit(double slDistance)
        {
            return (slDistance / Symbol.TickSize) * Symbol.TickValue;
        }

        private double CalculateVolumeInUnits(double slDistance)
        {
            if (slDistance <= 0)
                return 0;

            double volumeInUnits;

            switch (SelectedRiskType)
            {
                case RiskType.FixedLots:
                    volumeInUnits = Symbol.QuantityToVolumeInUnits(FixedLots);
                    break;

                case RiskType.MoneyAmount:
                {
                    double costPerUnit = LossPerUnit(slDistance);
                    volumeInUnits = costPerUnit > 0 ? RiskMoney / costPerUnit : 0;
                    break;
                }

                case RiskType.BalancePercentage:
                {
                    double riskAmount = Account.Balance * (RiskPercent / 100.0);
                    double costPerUnit = LossPerUnit(slDistance);
                    volumeInUnits = costPerUnit > 0 ? riskAmount / costPerUnit : 0;
                    break;
                }

                default:
                    volumeInUnits = Symbol.QuantityToVolumeInUnits(FixedLots);
                    break;
            }

            return Symbol.NormalizeVolumeInUnits(volumeInUnits, RoundingMode.Down);
        }
        
        private void PlaceOcoOrders()
        {
            double slDistance = rangeHigh - rangeLow;

            if (slDistance <= 0)
                return;

            double tpDistance = slDistance * RRR;

            double volumeInUnits = CalculateVolumeInUnits(slDistance);

            if (volumeInUnits < Symbol.VolumeInUnitsMin)
            {
                Print("Calculated volume {0} is below minimum {1}. Orders not placed.",
                    volumeInUnits, Symbol.VolumeInUnitsMin);
                return;
            }

            double buySl = rangeLow;
            double buyTp = rangeHigh + tpDistance;

            double sellSl = rangeHigh;
            double sellTp = rangeLow - tpDistance;

            PlaceStopLimitOrder(
                TradeType.Buy,
                SymbolName,
                1000,
                Symbol.Ask + (Symbol.PipSize * 10),
                2,
                "",
                10,
                10,
                null,
                "",
                false
            );

            var buyResult = PlaceStopOrder(
                TradeType.Buy, SymbolName, volumeInUnits, rangeHigh,
                "BuyStop_" + rangeBoxName, buySl, buyTp,
                ProtectionType.Absolute);

            var sellResult = PlaceStopOrder(
                TradeType.Sell, SymbolName, volumeInUnits, rangeLow,
                "SellStop_" + rangeBoxName, sellSl, sellTp,
                ProtectionType.Absolute);

            buyStopOrder = buyResult.IsSuccessful ? buyResult.PendingOrder : null;
            sellStopOrder = sellResult.IsSuccessful ? sellResult.PendingOrder : null;
        }

        private TradeType TwinTradeType(TradeType tradeType)
        {
            if (tradeType == TradeType.Buy)
                return TradeType.Sell;
            else
                return TradeType.Buy;
        }

        private void RemovePendingOrder(TradeType tradeType)
        {
            if (tradeType == TradeType.Buy && buyStopOrder != null)
            {
                var result = CancelPendingOrder(buyStopOrder);

                if (result.IsSuccessful)
                {
                    buyStopOrder = null;
                    Print("Buy Stop order cancelled.");
                }
                else
                {
                    Print("Failed to cancel Buy Stop order: {0}", result.Error);
                }
            }

            if (tradeType == TradeType.Sell && sellStopOrder != null)
            {
                var result = CancelPendingOrder(sellStopOrder);

                if (result.IsSuccessful)
                {
                    sellStopOrder = null;
                    Print("Sell Stop order cancelled.");
                }
                else
                {
                    Print("Failed to cancel Sell Stop order: {0}", result.Error);
                }
            }
        }

        private void OnPositionOpenedHandler(PositionOpenedEventArgs args)
        {
            Position position = args.Position;

            if (buyStopOrder != null && position.Label == buyStopOrder.Label)
            {
                buyStopOrder = null;
            }
            else if (sellStopOrder != null && position.Label == sellStopOrder.Label)
            {
                sellStopOrder = null;
            }

            if (UseOCO)
                RemovePendingOrder(TwinTradeType(position.TradeType));
        }

        private void OnPositionClosedHandler(PositionClosedEventArgs args)
        {
            if (Positions.Count == 0)
            {
                ordersPlaced = false;
            }

            if (UseOCO)
                return;

            Position position = args.Position;

            if (args.Reason != PositionCloseReason.TakeProfit)
                return;

                RemovePendingOrder(TwinTradeType(position.TradeType));
        }

        private void CheckMaxLookAheadTime()
        {
            if (MaxLookAheadTime <= TimeSpan.Zero)
                return;

            if (Positions.Count == 0)
                return;

            // TimeSpan openDuration = Server.Time - position.EntryTime;
            TimeSpan openDuration = Server.Time - rangeEnd;

            if (openDuration < MaxLookAheadTime)
                return;

            RemovePendingOrder(TradeType.Buy);
            RemovePendingOrder(TradeType.Sell);

            foreach (var position in Positions)
            {
                // Only manage positions belonging to this robot and symbol.
                if (position.SymbolName != SymbolName)
                    continue;

                if (position.Label == null)
                    continue;

                // Only manage positions created by this strategy.
                if (!position.Label.StartsWith("BuyStop_") &&
                    !position.Label.StartsWith("SellStop_"))
                    continue;

                Print("Closing position {0} because Max Look Ahead Time ({1}) was reached.", position.Id, MaxLookAheadTime);
                ClosePosition(position);
            }
        }

        protected override void OnStart()
        {
            rangeBoxName = "RangeBox_RB";
            // rangeActive = false;
            ordersPlaced = false;

            Positions.Opened += OnPositionOpenedHandler;
            Positions.Closed += OnPositionClosedHandler;
        }

        protected override void OnBar()
        {
        }

        protected override void OnTick()
        {
            UpdateRange();
            CheckMaxLookAheadTime();
        }

        protected override void OnStop()
        {
            Positions.Opened -= OnPositionOpenedHandler;
            Positions.Closed -= OnPositionClosedHandler;
        }
    }
}