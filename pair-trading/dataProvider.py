import pandas as pd
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent

def get_df(before="'2020-01-01'"):

    a_df = pd.read_csv(BASE_DIR / "gbpusd-h1-bid-2017-01-01-2026-08-18.csv")
    b_df = pd.read_csv(BASE_DIR / "eurusd-h1-bid-2017-01-01-2026-08-18.csv")

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

    return df[df.index < before]