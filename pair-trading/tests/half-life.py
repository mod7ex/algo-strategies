import numpy as np
import pandas as pd
import statsmodels.api as sm
from statsmodels.regression.rolling import RollingOLS
from dataProvider import get_df


df = get_df('2020-01-01')

# --------------------------------------------------------------------

sample_windows = [i for i in range(60, 1001, 5)]

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

def half_life(spread):
    spread = spread.dropna()

    lagged = spread.shift(1)
    delta = spread - lagged

    data = sm.add_constant(lagged)

    model = sm.OLS(delta, data, missing="drop").fit()

    lambda_ = model.params.iloc[1]

    if lambda_ >= 0: return np.inf

    return -np.log(2) / lambda_

hal_life_test_results = {}

for window in sample_windows:
    # Example
    alpha, beta, spread = pair_spread_mean_reversion_model(window)

    hl = half_life(spread)

    hal_life_test_results[window] = hl

    print(f"For {window} - Half-life: {hl:.2f} periods ie: {hl*4:.2f} hours")

half_life_results_df = pd.Series(hal_life_test_results, name="half_life").to_frame()
half_life_results_df.index.name = "window"
half_life_results_df.to_csv("half_life_results.csv", index=True)