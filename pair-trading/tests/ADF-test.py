import pandas as pd
from statsmodels.tsa.stattools import adfuller
from statsmodels.regression.rolling import RollingOLS
import statsmodels.api as sm
from dataProvider import get_df

df = get_df('2020-01-01')

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

def ADF_test(_spread):
    return adfuller(_spread, autolag="AIC")

sample_windows = [i for i in range(50, 151)] # check tests ran on VPS

adf_test_results = {}

for mw in sample_windows:
    _alpha, _beta, _spread = pair_spread_mean_reversion_model(mw)

    _test_result = ADF_test(_spread.dropna())

    stat, pvalue, lags, nobs, crit_values, _ = _test_result

    _is_valid = pvalue < 0.05

    if not _is_valid: continue

    adf_test_results[mw] = {
        "stat":stat ,
        "p-value":pvalue 
    }

    log_phrase =  f"For windows: {mw}, ADF test: statistic={stat:.4f}, p-value={pvalue:.4g}, lags={lags}, nobs={nobs}"

    print(log_phrase)

adf_test_results_df = pd.DataFrame.from_dict(adf_test_results, orient='index')
adf_test_results_df.index.name = 'window'
adf_test_results_df.to_csv("adf-test.csv", index=True)