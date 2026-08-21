import pandas as pd
import numpy as np
from itertools import product
from pathlib import Path
from collections import defaultdict

# --------------------------------------------------------------------------------
BASE_DIR = Path(__file__).resolve().parent

df = pd.read_csv(BASE_DIR / "usdjpy-m15-bid-2020-01-01-2026-08-21.csv")
df.set_index("Datetime", inplace=True)
df = df[["Open", "High", "Low", "Close"]]
df.index = pd.to_datetime(df.index, unit="ms", utc=True).tz_convert("Etc/GMT+4")

df = df[df.index < "2023-01-01"].dropna()

# --------------------------------------------------------------------------------
MAX_LOOKAHEAD = 86
INITIAL_BALANCE = 1000
RISK_PER_TRADE = 10
# --------------------------------------------------------------------------------
times_arr = df.index.strftime("%H:%M").to_numpy()

# Map each unique time -> array of row positions where it occurs

time_to_roots = defaultdict(list)
for i, t in enumerate(times_arr):
    time_to_roots[t].append(i)
time_to_roots = {t: np.array(idxs) for t, idxs in time_to_roots.items()}
# --------------------------------------------------------------------------------

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
    max_lookahead=None,
):
    range_delta = range_high - range_low

    entry = None
    sl = None
    tp = None

    end_i = len(high) if max_lookahead is None else min(len(high), start_i + max_lookahead)

    for i in range(start_i, end_i):
        if entry is None:
            if high[i] >= range_high and low[i] > range_low:
                entry = range_high
                sl = range_low
                tp = entry + rrr*range_delta

            elif low[i] <= range_low and high[i] < range_high:
                is_short = True
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
    high,
    low,
    close,
    root_indices,
    range_length,
    rrr,
    balance=INITIAL_BALANCE,
    risk_per_trade=RISK_PER_TRADE,
    max_lookahead=MAX_LOOKAHEAD,
):
    PnL = np.full(len(df), 0.0)
    cum_pnl = 0.0

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

        "Win rate": round(100 * _winning_trades/(_winning_trades + _losing_trades), 2),

        "Winning trades": int(_winning_trades),
        "Losing trades": int(_losing_trades),
        "N° trades": int(_losing_trades + _winning_trades),

        "Max win streak": int(win_streaks.max()),
        "Max loss streak": int(loss_streaks.max())
    }

# --------------------------------------------------------------------------------
range_lengths = [i for i in range(1, 10)]
rrrs = [u for u in range(1, 4)]
candle_time = df.head(100).index.strftime("%H:%M").unique().tolist()

# range_lengths = [5]
# rrrs = [2]
# candle_time = df.head(5).index.strftime("%H:%M").unique().tolist()

high = df["High"].to_numpy()
low = df["Low"].to_numpy()
close = df["Close"].to_numpy()

test_results = {}

def phrase(rl, rr, ct):
    return f"Range length: {rl}, RRR: {rr}, Candle time: {ct}"

for rl, rr, ct  in product(range_lengths, rrrs, candle_time):
    print(f"\n---------- Running test for {phrase(rl, rr, ct)} ----------")
    root_indices = time_to_roots.get(ct)
    _result = run_range_breakout(df, high, low, close, root_indices, range_length=rl, rrr=rr)
    _stats = backtest_stats(_result)
    if _stats["Return %"] > 0:
        test_results[(rl, rr, ct)] = _stats

test_results_df = pd.DataFrame.from_dict(test_results, orient="index")
test_results_df.index = pd.MultiIndex.from_tuples(
    test_results_df.index,
    names=["rl", "rr", "ct"]
)
test_results_df.to_csv("performance-test.csv", index=True)
