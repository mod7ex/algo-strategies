import pandas as pd
import numpy as np

INITIAL_BALANCE = 1000
RISK_PER_TRADE = 10

def get_data(p):
    df = pd.read_csv(p)
    df["Datetime"] = pd.to_datetime(
        df["DATE"].astype(str) + " " + df["TIME"].astype(str)
    )
    df = df[["Datetime", "Open", "High", "Low", "Close"]]
    df.set_index("Datetime", inplace=True)
    return df

def simulate_trade(
    high,
    low,
    close,
    start_i,
    end_i,
    range_high,
    range_low,
    rrr,
) -> float:
    _range_delta = range_high - range_low

    entry = None
    sl = None
    tp = None

    for i in range(start_i, end_i):
        if entry is None:
            if high[i] >= range_high and low[i] > range_low:
                entry = range_high
                sl = range_low
                tp = entry + rrr*_range_delta

            elif low[i] <= range_low and high[i] < range_high:
                entry = range_low
                sl = range_high
                tp = entry - rrr*_range_delta

            elif low[i] > range_low and high[i] < range_high: continue

            else: return -1, i

        is_long = entry > sl

        if is_long:
            if low[i] <= sl: return -1, i
            if high[i] > tp: return rrr, i
        else:
            if high[i] >= sl: return -1, i
            if tp > low[i]: return rrr, i

    if entry is None: return 0, i # no trade was triggered within the lookahead window

    # loop exhausted (either max_lookahead or end of data)
    exit_price = close[end_i - 1]
    outcome_r = (exit_price - entry) / _range_delta if (tp > sl) else (entry - exit_price) / _range_delta
    return outcome_r, i

def compute_range(high, low, root, range_length):
    _range_high = high[root-range_length+1:root+1].max()
    _range_low = low[root-range_length+1:root+1].min()
    return _range_high, _range_low

def run_range_breakout(
    df,
    range_length,
    max_range_delta,
    rrr,
    max_lookahead,
    balance=INITIAL_BALANCE,
    risk_per_trade=RISK_PER_TRADE,
):
    PnL = np.full(len(df), 0.0)
    cum_pnl = 0.0

    high = df["High"].to_numpy()
    low = df["Low"].to_numpy()
    close = df["Close"].to_numpy()

    # for root in range(range_length - 1, len(high) - max_lookahead):
    root = range_length - 1
    while root < len(high) - max_lookahead:
        root += 1
        if balance + cum_pnl * risk_per_trade < balance * 0.7: break

        _range_high, _range_low = compute_range(high, low, root, range_length)
        _range_delta = _range_high - _range_low
        
        if _range_delta < 0: continue
        if _range_delta > max_range_delta: continue

        _outcom, last_i = simulate_trade(
            high=high,
            low=low,
            close=close,
            start_i=root+1,
            end_i=root + max_lookahead,
            range_high=_range_high,
            range_low=_range_low,
            rrr=rrr,
        )

        root = last_i
        PnL[root] = _outcom
        cum_pnl += _outcom

    return pd.DataFrame(
        {
            "PnL": PnL,
            "Cumulative_PnL": np.cumsum(PnL),
            "Balance": balance + np.cumsum(PnL) * risk_per_trade,
        },
        index=df.index,
    )

def zdiv(a, b):
    return a / b if b != 0 else 0

def backtest_stats(result_df):
    result_df = result_df.copy()

    # --------------------------------------------------
    # Return %
    # --------------------------------------------------
    final_balance = result_df["Balance"].iloc[-1]
    net_profit = final_balance - INITIAL_BALANCE
    total_return = net_profit / INITIAL_BALANCE

    # --------------------------------------------------
    # Sharp ratio
    # --------------------------------------------------
    returns = result_df["Balance"].pct_change().dropna()
    vol = returns.std()

    # --------------------------------------------------
    # Drawdown
    # --------------------------------------------------
    balance_peak = result_df["Balance"].cummax()

    balance_dd = balance_peak - result_df["Balance"]
    balance_dd_pct = balance_dd / balance_peak * 100

    max_balance_dd = balance_dd.max()
    max_balance_dd_pct = balance_dd_pct.max()

    # --------------------------------------------------
    # Win rate
    # --------------------------------------------------
    _winning_trades = result_df["PnL"][result_df["PnL"] > 0].count()
    _losing_trades = result_df["PnL"][result_df["PnL"] < 0].count()

    # --------------------------------------------------
    # Win rate
    # --------------------------------------------------
    s = result_df["PnL"][result_df["PnL"] != 0]

    wins = s > 0
    losses = s < 0

    win_streaks = wins.groupby((wins != wins.shift()).cumsum()).sum()
    loss_streaks = losses.groupby((losses != losses.shift()).cumsum()).sum()

    # --------------------------------------------------
    # Return results
    # --------------------------------------------------
    return {
        "Return %": round(total_return * 100, 2),
        "Sharp ratio": round(zdiv(total_return, vol), 2),

        "Max Balance DD": round(max_balance_dd, 2),
        "Max Balance DD %": round(max_balance_dd_pct, 2),

        "Win rate %": round(100 * zdiv(_winning_trades, _winning_trades + _losing_trades), 2),

        "Winning trades": _winning_trades,
        "Losing trades": _losing_trades,
        "N° trades": _losing_trades + _winning_trades,

        "Max win streak": win_streaks.max(),
        "Max loss streak": loss_streaks.max()
    }

def print_stats(d):
    for key, value in d.items():
        print(f"{key}: {value}")