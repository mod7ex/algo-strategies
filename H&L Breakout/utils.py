import pandas as pd

def get_data(p):
    df = pd.read_csv(p)
    df["Datetime"] = pd.to_datetime(
        df["DATE"].astype(str) + " " + df["TIME"].astype(str)
    )
    df = df[["Datetime", "Open", "High", "Low", "Close"]]
    df.set_index("Datetime", inplace=True)
    return df