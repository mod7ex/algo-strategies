import numpy as np
import pandas as pd
from statsmodels.tsa.stattools import adfuller
from statsmodels.regression.rolling import RollingOLS
import statsmodels.api as sm
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent

a_df = pd.read_csv(BASE_DIR / "gbpusd-m15-bid-2020-01-01-2026-08-18.csv")
b_df = pd.read_csv(BASE_DIR / "eurusd-m15-bid-2020-01-01-2026-08-18.csv")

a_df.set_index("Datetime", inplace=True)
b_df.set_index("Datetime", inplace=True)

a_df = a_df[["Open", "High", "Low", "Close"]]
b_df = b_df[["Open", "High", "Low", "Close"]]

a_df.index = pd.to_datetime(a_df.index, unit="ms")
b_df.index = pd.to_datetime(b_df.index, unit="ms")

df = pd.concat(
    [
        a_df["Close"].rename("A"),
        b_df["Close"].rename("B")
    ],
    axis=1,
    join="inner"
)

df = df[df.index < "2022-01-01"]

returns_df = df.pct_change().dropna()

# -------------- Model --------------
def pair_spread_mean_reversion_model(window):
    Y = df["A"]

    X = sm.add_constant(df["B"])
    rolling_model = RollingOLS(Y, X, window=window)
    fit = rolling_model.fit()

    _beta = fit.params["B"]
    _alpha = fit.params["const"]
    _spread = (df["A"] - (_alpha + _beta * df["B"])).dropna()
    _beta = _beta.reindex(_spread.index)

    return _alpha, _beta, _spread

def ADF_test_model(_spread):
    stat, pvalue, lags, nobs, crit_values, _ = adfuller(_spread.dropna(), autolag="AIC")
    return stat, pvalue

#  ---------------------------------------------- Strategy ---------------------------------------------- 
def pair_spread_mean_reversion( spread, beta, z_window, z_entry, z_flat, z_stop ):
    # --- Z-score of the spread ---
    spread_mean = spread.rolling(z_window).mean()
    spread_std = spread.rolling(z_window).std()
    zscore = (spread - spread_mean) / spread_std

    # --- State machine: -1 = short spread, 0 = flat, 1 = long spread ---
    state = np.zeros(len(zscore), dtype=int)
    current = 0

    z_vals = zscore.to_numpy()
    for i, z in enumerate(z_vals):
        if current == 0:
            if z < -z_entry: current = 1
            elif z > z_entry: current = -1
        elif abs(z) < z_flat: current = 0
        elif abs(z) > z_stop: current = 0
        state[i] = current

    state = pd.Series(state, index=zscore.index)

    # --- Positions (lagged by 1 to avoid lookahead) ---
    position_A = state.shift(1).fillna(0)
    position_B = (-state * beta).shift(1).fillna(0)

    # --- Returns ---
    ret_A = returns_df["A"]
    ret_B = returns_df["B"]

    strategy_returns = position_A * ret_A + position_B * ret_B
    equity = (1 + strategy_returns).cumprod()

    return strategy_returns, equity

def evaluate_equity(equity: pd.Series, trade_epsilon: float = 1e-12) -> dict:
    equity = equity.dropna().astype(float)
    equity = equity.sort_index()

    # --- Return ---
    total_return_pct = (equity.iloc[-1] / equity.iloc[0] - 1)

    # --- Max Drawdown % ---
    running_max = equity.cummax()
    drawdown = (equity - running_max) / running_max
    max_drawdown_pct = drawdown.min() * 100  # negative number

    # --- Sharp ratio ---
    returns = equity.pct_change().dropna()
    vol = returns.std()

    # --- Trades: inferred from nonzero equity changes ---
    equity_diff = equity.diff().dropna()
    trade_pnls = equity_diff[equity_diff.abs() > trade_epsilon]

    num_trades = len(trade_pnls)
    wins = trade_pnls[trade_pnls > 0]
    losses = trade_pnls[trade_pnls < 0]

    win_rate_pct = (len(wins) / num_trades * 100) if num_trades > 0 else np.nan
    max_win = wins.max() if len(wins) > 0 else np.nan
    max_loss = losses.min() if len(losses) > 0 else np.nan

    return {
        "Return %": round(total_return_pct * 100, 4),
        "Max Drawdown %": round(max_drawdown_pct, 4),
        "Sharpe ratio": round(total_return_pct, 2) if not np.isnan(total_return_pct) else np.nan,
        "Win Rate %": round(win_rate_pct, 2) if not np.isnan(win_rate_pct) else np.nan,
        "Number of trades": num_trades,
        "Max win": round(max_win, 6) if not np.isnan(max_win) else np.nan,
        "Max loss": round(max_loss, 6) if not np.isnan(max_loss) else np.nan,
    }

def print_metrics(_result): 
    for k, v in _result.items(): print(f"{k}: {v}")

# -------------------------------------------- TEST --------------------------------------------

model_windows = [60, 86, 103] # [60, 105]
def z_windows(n):
    return [w for w in range(7, n)]
z_entries = [2 + i*0.1 for i in range(0, 21)]
z_flats = [k*0.1 for k in range(0, 31)]
z_stops = [3 + k*0.1 for k in range(0, 31)]
# --------------------------------------------
# z_entries = [2 + i*0.5 for i in range(0, 3)]
# z_flats = [k for k in range(0, 3)]
# z_stops = [k for k in range(3, 7)]
# --------------------------------------------
# model_windows = [22*60, 100]
# def z_windows(n):
#     return [w for w in range(n, n+1)]
# z_entries = [4]
# z_flats = [0]
# z_stops = [5]

# --------------------------------------------

test_results = {}

def phrase(mw, zw, ze, zf, zs):
    return f"Model rolling window: {mw}, Zscore rolling window: {zw}, Zscore entry: {ze}, Zscore flat: {zf}, Zscore stop: {zs}"

def print_metrics(_result): 
    for k, v in _result.items(): print(f"{k}: {v}")

for mw in model_windows:
    _alpha, _beta, _spread = pair_spread_mean_reversion_model(mw)

    _stat, _pvalue = ADF_test_model(_spread.dropna())

    _is_valid = _pvalue < 0.05

    if not _is_valid: continue

    for zw in z_windows(mw):
        for (ze, zf, zs)  in [(ze, zf, zs) for ze in z_entries for zf in z_flats for zs in z_stops if zf < ze < zs]:

            print(f"\n\n---------- Running test for {phrase(mw, zw, ze, zf, zs)} ----------")

            _, _equity = pair_spread_mean_reversion(
                _spread,
                _beta,
                z_window=zw,
                z_entry=ze,
                z_flat=zf,
                z_stop=zs
            )

            _metrics = evaluate_equity(_equity)
            _metrics["p-value"] = _pvalue
            _metrics["stat"] = _stat
            print("  ======> Test Results")
            print_metrics(_metrics)

            if _metrics["Return %"] < 0: continue
            test_results[(mw, zw, ze, zf, zs)] = _metrics

test_results_df = pd.DataFrame.from_dict(test_results, orient="index")
test_results_df.index = pd.MultiIndex.from_tuples(
    test_results_df.index,
    names=["mw", "zw", "ze", "zf", "zs"]
)
test_results_df.to_csv("performance-test.csv", index=True)