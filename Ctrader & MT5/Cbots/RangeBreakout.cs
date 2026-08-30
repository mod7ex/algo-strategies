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
    public class RangeBreakout : Robot
    {
        [Parameter("Range Start Time", DefaultValue = "09:30:00", Group = "Trade Management")]
        public TimeSpan RangeStart { get; set; }

        [Parameter("Range End Time", DefaultValue = "10:30:00", Group = "Trade Management")]
        public TimeSpan RangeEnd { get; set; }

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
        private DateTime rangeDate;

        private PendingOrder buyStopOrder;
        private PendingOrder sellStopOrder;

        private void UpdateRange()
        {
            DateTime now = Server.Time;
            TimeSpan currentTime = now.TimeOfDay;

            double currentHigh = Bars.HighPrices.Last(0);
            double currentLow = Bars.LowPrices.Last(0);

            if (!rangeActive && currentTime >= RangeStart && currentTime < RangeEnd)
            {
                rangeActive = true;
                ordersPlaced = false;

                rangeDate = now.Date;
                rangeHigh = currentHigh;
                rangeLow = currentLow;

                rangeBoxName = "RangeBox_" + rangeDate.ToString("yyyyMMdd");

                DrawRangeBox();
            }

            if (rangeActive && currentTime >= RangeStart && currentTime < RangeEnd)
            {
                rangeHigh = Math.Max(rangeHigh, currentHigh);
                rangeLow = Math.Min(rangeLow, currentLow);

                DrawRangeBox();
            }

            if (rangeActive && currentTime >= RangeEnd)
            {
                rangeActive = false;

                DrawRangeBox();

                if (!ordersPlaced)
                {
                    PlaceOcoOrders();
                    ordersPlaced = true;
                }
            }
        }

        // Money lost per 1 unit of volume if price moves 'slDistance' against you.
        private double LossPerUnit(double slDistance)
        {
            return (slDistance / Symbol.TickSize) * Symbol.TickValue;
        }

        private TradeType TwinTradeType(TradeType tradeType)
        {
            if (tradeType == TradeType.Buy)
                return TradeType.Sell;
            else
                return TradeType.Buy;
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

        private void DrawRangeBox()
        {
            var rectangle = Chart.DrawRectangle(
                rangeBoxName,
                rangeDate + RangeStart,
                rangeHigh,
                rangeDate + RangeEnd,
                rangeLow,
                Color.FromArgb((int)(BoxOpacity * 255), Color.Red)
            );

            rectangle.IsFilled = true;
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

        private void OnPositionClosedHandler(PositionClosedEventArgs args)
        {
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

            // TimeSpan openDuration = Server.Time - position.EntryTime;
            TimeSpan openDuration = Server.Time - (rangeDate + RangeEnd);

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
            rangeActive = false;
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