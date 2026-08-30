import pandas as pd
from itertools import product
from pathlib import Path

from utils import get_data, backtest_stats, run_range_breakout

# --------------------------------------------------------------------------------

df = get_data(Path(__file__).resolve().parent / "../data/XAUUSD_M5_01-01-2025_to_24-08-2026.csv")

# df = df.tail(10000)

# --------------------------------------------------------------------------------

range_lengths = [i for i in range(2, 31)]
rrrs = [0.5 + u*0.5 for u in range(2, 8)]
max_range_deltas = [0.5, 1, 1.5, 2, 2.5, 3]
max_look_aheads = [i for i in range(12, 100)]

# range_lengths = [5, 12]
# rrrs = [2]
# max_range_deltas = [2, 4]
# max_look_aheads = [50, 20]

high = df["High"].to_numpy()
low = df["Low"].to_numpy()
close = df["Close"].to_numpy()

test_results = {}

def phrase(rl, rr, mrd, mlh):
    return f"Range length: {rl}, RRR: {rr}, Max range delta: {mrd}, Max lookahead {mlh}"

for rl, rr, mrd, mlh in product(range_lengths, rrrs, max_range_deltas, max_look_aheads):
    print(f"\n---------- Running test for {phrase(rl, rr, mrd, mlh)} ----------")
    _stats = backtest_stats(
        run_range_breakout(df, max_range_delta=mrd, max_lookahead=mlh, range_length=rl, rrr=rr)
    )
    if _stats["Return %"] > 0: test_results[(rl, rr, mrd, mlh)] = _stats

test_results_df = pd.DataFrame.from_dict(test_results, orient="index")
test_results_df.index = pd.MultiIndex.from_tuples(
    test_results_df.index,
    names=["rl", "rr", "mrd", "mlh"]
)
test_results_df.to_csv("performance-test.csv", index=True)
