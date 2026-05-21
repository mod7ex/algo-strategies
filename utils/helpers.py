# https://github.com/mod7ex/macro/blob/master/utils/helpers.py

import random
from scipy.stats import describe
import plotly.express as px
import pandas as pd

# --------------------------------------------------------------------------

def describe_data(df_col: pd.Series):
    stats = describe(df_col)

    obj = {
        'nobs': str(stats.nobs),
        'Min %': stats.minmax[0],
        'Max %': stats.minmax[1],
        'Mean %': stats.mean,
        'Median %': df_col.median(),
        'Mode %': df_col.mode(dropna=True)[0],
        'Variance': stats.variance,
        'Skewness': stats.skewness,
        'Kurtosis': stats.kurtosis
    }

    df_stats = (
        pd.DataFrame(list(obj.items()), columns=["Metric", "Value"])
        .set_index("Metric")
    )

    return df_stats, stats

# --------------------------------------------------------------------------

def generate_random_rgb_color():
    return (
        random.randint(0, 255),
        random.randint(0, 255),
        random.randint(0, 255)
    )

def generate_random_hex_color():
    return "#{:02X}{:02X}{:02X}".format(
        random.randint(0, 255),
        random.randint(0, 255),
        random.randint(0, 255)
    )

# --------------------------------------------------------------------------

def plot_df_chart(
        df,
        chart_title: str = "Chart Title",
        chart_type: str = "line",   # 🔥 new parameter ("line" or "bar")
        yaxis_title: str = "",
        draw=True,
        save_to_html=False,
        save_file_name="plot",
        use_markers=True,
        width=1300,
        height=600,
        show_rangeslider=True,
        fill=False
):
    if chart_type == "line":
        fig = px.line(df, markers=use_markers)
    elif chart_type == "bar":
        fig = px.bar(df)
    else:
        raise ValueError("chart_type must be 'line' or 'bar'")

    fig.update_layout(
        title=chart_title,
        template="plotly_dark",
        paper_bgcolor="black",
        plot_bgcolor="black",
        height=height,
        width=width,
        dragmode="zoom",
        font=dict(color="white", size=12),
        legend=dict(
            itemclick="toggle",
            itemdoubleclick="toggleothers",
            bgcolor="rgba(0,0,0,0)"
        ),
        xaxis=dict(
            showgrid=True,
            gridcolor="rgba(255,255,255,0.08)",
            rangeslider=dict(visible=show_rangeslider),  # 🔥 only for line
            # rangeslider=dict(visible=(chart_type == "line")),  # 🔥 only for line
        ),
        yaxis=dict(
            title=yaxis_title,
            showgrid=True,
            gridcolor="rgba(255,255,255,0.08)",
            fixedrange=False
        )
    )

    # 🔥 Only update traces for line charts
    if chart_type == "line":
        fig.update_traces(
            mode=f"lines{'+markers' if use_markers else ''}",
            line=dict(width=1),
            fill="tozeroy" if fill else None,   # 👈 fills area to y=0
            hovertemplate="<b>%{fullData.name}</b><br>%{y:.2f}<extra></extra>"
        )
    else:  # bar
        fig.update_traces(
            hovertemplate="<b>%{fullData.name}</b><br>%{y:.2f}<extra></extra>"
        )

    if save_to_html:
        fig.write_html(f"plots/{save_file_name}.html")

    if draw:
        return fig.show()
    else:
        return fig