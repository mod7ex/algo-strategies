import pandas as pd
from itertools import product
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent

# ---------------------------------------------------------- 
df = pd.read_csv(BASE_DIR / 'XAUUSD_M5_01-01-2025_to_24-08-2026.csv')
df["Datetime"] = pd.to_datetime(
    df["DATE"].astype(str) + " " + df["TIME"].astype(str)
)
df = df[["Datetime", "Open", "High", "Low", "Close"]]
df.set_index("Datetime", inplace=True)
# ---------------------------------------------------------- 

def optimize(window, zscore):
    # BB 
    df["bb_middle"] = df["Close"].ewm(span=window, adjust=False, min_periods=window).mean()
    rolling_std = df["Close"].rolling(window).std()
    df["bb_upper"] = df["bb_middle"] + zscore * rolling_std
    df["bb_lower"] = df["bb_middle"] - zscore * rolling_std
    df.dropna(inplace=True)

    # calcl
    num_of_upper_single_touches = 0
    num_of_lower_single_touches = 0

    for i in range(1, len(df)-1):
        # One touch

        # check upper
        if df.iloc[i]["High"] > df.iloc[i]["bb_upper"]:
            if df.iloc[i-1]["High"] <= df.iloc[i]["bb_upper"] and df.iloc[i+1]["High"] <= df.iloc[i]["bb_upper"]: num_of_upper_single_touches += 1

        # check lower
        if df.iloc[i]["Low"] < df.iloc[i]["bb_lower"]:
            if df.iloc[i-1]["Low"] >= df.iloc[i]["bb_lower"] and df.iloc[i+1]["Low"] >= df.iloc[i]["bb_lower"]: num_of_lower_single_touches += 1

    return {
        "num_of_upper_single_touches": num_of_upper_single_touches,
        "num_of_lower_single_touches": num_of_lower_single_touches
    }

# -----------------------------------------------------------------------------------------------

windows = [i for i in range(14, 150)]
zscores = [round(i*0.1, 2) for i in range(20, 51)]
# windows = [14]
# zscores = [2]

# --------------------------------------------

test_results = {}

def phrase(w, z):
    return f"Window: {w}, Zscore: {z}"

for w, z  in product(windows, zscores):
    print(f"\n --------- {phrase(w, z)} --------- ")
    test_results[(w, z)] = optimize(w, z)

test_results_df = pd.DataFrame.from_dict(test_results, orient="index")
test_results_df.index = pd.MultiIndex.from_tuples(
    test_results_df.index,
    names=["w", "z"]
)
test_results_df.to_csv("bb-inputs-5m-optimizer.csv", index=True)