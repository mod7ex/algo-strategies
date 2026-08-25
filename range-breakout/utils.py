import pandas as pd
import numpy as np
from bisect import bisect_right
from collections import defaultdict

INITIAL_BALANCE = 1000
RISK_PER_TRADE = 10

def get_time_to_roots(df):
    times_arr = df.index.strftime("%H:%M").to_numpy()

    time_to_roots = defaultdict(list)
    for i, t in enumerate(times_arr):
        time_to_roots[t].append(i)

    return {t: np.array(idxs) for t, idxs in time_to_roots.items()}

def get_data(p):
    df = pd.read_csv(p)
    df["Datetime"] = pd.to_datetime(
        df["DATE"].astype(str) + " " + df["TIME"].astype(str)
    )
    df = df[["Datetime", "Open", "High", "Low", "Close"]]
    df.set_index("Datetime", inplace=True)
    return df

def compute_range(high, low, root, range_length):
    range_high = high[root - range_length + 1:root + 1].max()
    range_low = low[root - range_length + 1:root + 1].min()
    return range_high, range_low

def simulate_trade(
    high,
    low,
    close,
    start_i,
    range_high,
    range_low,
    rrr,
    max_lookahead,
):
    range_delta = range_high - range_low

    entry = None
    sl = None
    tp = None

    end_i = len(high)

    if max_lookahead is not None:
        end_i = min(end_i, start_i + max_lookahead)

    for i in range(start_i, end_i):
        if entry is None:
            if high[i] >= range_high and low[i] > range_low:
                entry = range_high
                sl = range_low
                tp = entry + rrr*range_delta

            elif low[i] <= range_low and high[i] < range_high:
                entry = range_low
                sl = range_high
                tp = entry - rrr*range_delta

            elif low[i] > range_low and high[i] < range_high: continue

            else: return -1

        is_long = entry > sl

        if is_long:
            if low[i] <= sl: return -1
            if high[i] > tp: return rrr
        else:
            if high[i] >= sl: return -1
            if tp > low[i]: return rrr

    if entry is None: return None # no trade was triggered within the lookahead window

    # loop exhausted (either max_lookahead or end of data)
    exit_price = close[end_i - 1]
    outcome_r = (exit_price - entry) / range_delta if (tp > sl) else (entry - exit_price) / range_delta
    return outcome_r

def run_range_breakout(
    df,
    root_indices,
    range_length,
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

    for root in root_indices:
        if root < range_length - 1: continue
        if balance + cum_pnl * risk_per_trade < balance * 0.7: break

        range_high, range_low = compute_range(high, low, root, range_length)

        outcome = simulate_trade(
            high,
            low,
            close,
            root + 1,
            range_high,
            range_low,
            rrr,
            max_lookahead=max_lookahead,
        )

        if outcome is not None:
            PnL[root] = outcome
            cum_pnl += outcome

    return pd.DataFrame(
        {   
            "PnL": PnL,
            "Cumulative_PnL": np.cumsum(PnL),
            "Balance": balance + np.cumsum(PnL) * risk_per_trade,
        },
        index=df.index,
    )
# --------------------------------------------------------------------------------
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
        "Sharp ratio": round(total_return/vol, 2),

        "Max Balance DD": round(max_balance_dd, 2),
        "Max Balance DD %": round(max_balance_dd_pct, 2),

        "Win rate %": round(100 * _winning_trades/(_winning_trades + _losing_trades), 2),

        "Winning trades": int(_winning_trades),
        "Losing trades": int(_losing_trades),
        "N° trades": int(_losing_trades + _winning_trades),

        "Max win streak": int(win_streaks.max()),
        "Max loss streak": int(loss_streaks.max())
    }