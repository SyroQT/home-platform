import json

import plotly.graph_objects as go
import plotly.utils


def fig_json(fig: go.Figure) -> str:
    return json.dumps(fig, cls=plotly.utils.PlotlyJSONEncoder)

def scatter_plot(times, values, title, yaxis):

    fig = go.Figure(go.Scatter(x=times, y=values, mode="lines", name=title))
    fig.update_layout(
        title=None,
        height=200,
        margin=dict(l=40, r=20, t=10, b=40),
        xaxis_title=None,
        yaxis_title=yaxis,
    )
    return {"title": title, "chart": fig_json(fig)}

