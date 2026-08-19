import numpy as np
import pandas as pd
import statsmodels.api as sm
from dataProvider import get_df

df = get_df('2020-01-01')

# -------------------------------------------------

n_chunks = [i for i in range(20, 1000)]

results = {}

for n in n_chunks:
    results[n] = []

    for chunk in (df.iloc[i:i+n] for i in range(0, len(df), n)):
        if len(chunk) < n: continue

        col_a = "A"
        col_b = "B"

        Y = chunk[col_a]
        X = sm.add_constant(chunk[col_b])

        fit = sm.OLS(Y,X).fit()

        beta = fit.params[col_b]

        results[n].append(beta)

# -------------------------------------------------

stability = {}

for n, betas in results.items():

    betas = np.asarray(betas)

    mean_beta = np.mean(betas)
    std_beta = np.std(betas, ddof=1)

    # Relative variability
    cv = std_beta / abs(mean_beta)

    # Total spread of beta
    beta_range = np.max(betas) - np.min(betas)

    # Average change from one period to the next
    avg_drift = np.mean(np.abs(np.diff(betas)))

    stability[n] = {
        "mean_beta": mean_beta,
        "std_beta": std_beta,
        "cv_pct": cv * 100,
        "min_beta": np.min(betas),
        "max_beta": np.max(betas),
        "range": beta_range,
        "avg_drift": avg_drift,
        "n_periods": len(betas),
    }

stability_df = pd.DataFrame(stability).T

stability_df.to_csv("stability.csv", index=True)