import pandas as pd
import numpy as np

BB_UPPER = "bb_upper"
BB_LOWER = "bb_lower"
BB_MIDDLE = "bb_middle"
ATR = "ATR"
LONG_SIGNAL = 1
SHORT_SIGNAL = -1

def get_data(p):
    df = pd.read_csv(p)
    df["Datetime"] = pd.to_datetime(
        df["DATE"].astype(str) + " " + df["TIME"].astype(str)
    )
    df = df[["Datetime", "Open", "High", "Low", "Close"]]
    df.set_index("Datetime", inplace=True)

    return df

def prep_data(df, atr_window, bb_window, bb_zscore):
    # ATR
    df[ATR] = (df["High"] - df["Low"]).rolling(atr_window).mean()
    df[ATR] = df[ATR].shift()

    # BB
    df[BB_MIDDLE] = df["Close"].ewm(span=bb_window, adjust=False, min_periods=bb_window).mean()
    rolling_std = df["Close"].rolling(bb_window).std()
    df[BB_UPPER] = df[BB_MIDDLE] + bb_zscore * rolling_std
    df[BB_LOWER] = df[BB_MIDDLE] - bb_zscore * rolling_std

    df.dropna(inplace=True)

    # Signal
    df["Signal"] = 0
    df.loc[df["High"] > df["bb_upper"], "Signal"] = SHORT_SIGNAL
    df.loc[df["Low"] < df["bb_lower"], "Signal"] = LONG_SIGNAL
    df["Signal"] = df["Signal"].where(
        df["Signal"].ne(df["Signal"].shift()) | df["Signal"].eq(0),
        0
    )

    return df

def bb_scalp(
        df,
        rrr,
        atr_mult,
        max_lookahead,
        initial_balance=1000,
        risk_per_trade=10
):
    N = len(df)
    signal = df["Signal"].to_numpy()
    high = df["High"].to_numpy()
    low = df["Low"].to_numpy()
    atr = df[ATR].to_numpy()
    bb_upper = df[BB_UPPER].to_numpy()
    bb_lower = df[BB_LOWER].to_numpy()
    pnl = np.zeros(N)
    cum_pnl = 0

    for i in range(N):
        if cum_pnl < -30: break
        
        if signal[i] == LONG_SIGNAL:
            entry = bb_lower[i]
            sl = entry - atr[i] * atr_mult
            tp = entry + rrr * (entry - sl)
            if low[i] < sl:
                pnl[i] = -1
                cum_pnl += -1
                continue
            for j in range(i+1, min(i+max_lookahead, N)):
                if low[j] < sl:
                    pnl[i] = -1
                    cum_pnl += -1
                    break
                if high[j] > tp:
                    pnl[i] = rrr
                    cum_pnl += rrr
                    break

        if signal[i] == SHORT_SIGNAL:
            entry = bb_upper[i]
            sl = entry + atr[i] * atr_mult
            tp = entry + rrr * (entry - sl)
            if high[i] > sl:
                pnl[i] = -1
                cum_pnl += -1
                continue
            for j in range(i+1, min(i+max_lookahead, N)):
                if high[j] > sl:
                    pnl[i] = -1
                    cum_pnl += -1
                    break
                if low[j] < tp:
                    pnl[i] = rrr
                    cum_pnl += rrr
                    break

    return pd.DataFrame(
        {
            "PnL": pnl,
            "Cumulative_PnL": np.cumsum(pnl),
            "Balance": initial_balance + np.cumsum(pnl) * risk_per_trade,
        },
        index=df.index,
    )

def backtest_stats(result_df, initial_balance):
    result_df = result_df.copy()

    # --------------------------------------------------
    # Return %
    # --------------------------------------------------
    final_balance = result_df["Balance"].iloc[-1]
    net_profit = final_balance - initial_balance
    total_return = net_profit / initial_balance

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