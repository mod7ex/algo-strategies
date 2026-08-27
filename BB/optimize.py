import pandas as pd
from pathlib import Path
from itertools import product
from utils import get_data, prep_data, bb_scalp, backtest_stats

# --------------------------------------------------------------------------------

data = get_data(Path(__file__).resolve().parent / "../data/XAUUSD_M5_01-01-2025_to_24-08-2026.csv")

# ---------------------------------------------------------------------------

INITIAL_BALANCE = 1000
RISK_PER_TRADE = 10

bb_windows = [i for i in range(10, 200)]
bb_zscores = [2 + u*0.5 for u in range(0, 5)]
atr_windows = [l for l in range(3, 15)]
rrrs = [0.5 + 0.5 * j for j in range(0, 8)]
atr_mults = [1, 1.5, 2]
max_look_aheads = [i for i in range(3, 19)]

# bb_windows = [20, 73]
# bb_zscores = [3]
# atr_windows = [7]
# rrrs = [2, 1]
# atr_mults = [1, 2]
# max_look_aheads = [20]

test_results = {}

def phrase(bbw, bbz, aw, rr, am, mlh):
    return f"bbw={bbw}, bbz={bbz}, aw={aw}, rr={rr}, am={am}, mlh={mlh}"

for bbw, bbz, aw in product(bb_windows, bb_zscores, atr_windows):
    df = prep_data(
        data.copy(),
        atr_window=aw,
        bb_window=bbw,
        bb_zscore=bbz
    )

    for rr, am, mlh in product(rrrs, atr_mults, max_look_aheads):

        print(f"\n---------- Running test for {phrase(bbw, bbz, aw, rr, am, mlh)} ----------")

        _result = bb_scalp(
            df,
            rrr=rr,
            atr_mult=am,
            max_lookahead=mlh,
            initial_balance=INITIAL_BALANCE,
            risk_per_trade=RISK_PER_TRADE
        )

        _stats = backtest_stats(_result, initial_balance=INITIAL_BALANCE)

        if _stats["Return %"] > 0: test_results[(bbw, bbz, aw, rr, am, mlh)] = _stats

test_results_df = pd.DataFrame.from_dict(test_results, orient="index")
test_results_df.index = pd.MultiIndex.from_tuples(
    test_results_df.index,
    names=["bbw", "bbz", "aw", "rr", "am", "mlh"]
)
test_results_df.to_csv("test-result.csv", index=True)
