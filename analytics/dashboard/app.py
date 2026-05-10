import json
from pathlib import Path

import duckdb
import plotly.graph_objects as go
import plotly.utils
from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates

import plot_templates as prepped_plots

app = FastAPI()

BASE_DIR = Path(__file__).parent
templates = Jinja2Templates(directory=BASE_DIR / "templates")

DB_PATH = "/tmp/analytics_dev_s3.duckdb"

SIZE_CONIFG = {
    "margin":  dict(l=40, r=20, t=10, b=40),
    "height": 200,
}

def query(sql: str, params=None):
    result = None
    try:
        con = duckdb.connect(DB_PATH, read_only=True)
        result = con.execute(sql, params or []).fetchall()
        con.close()
        return [] or result
    except Exception as e:
        print(f"params \n {e}")
        return [] 


def fig_json(fig: go.Figure) -> str:
    return json.dumps(fig, cls=plotly.utils.PlotlyJSONEncoder)


# --- panels -------------------------------------------------------------------
# Each panel function returns {"title": str, "chart": str (Plotly JSON)}

def panel_cpu_sparkline():
    rows = query("""
            SELECT collected_at, cpu_load_1m
            FROM mart_host_status_history
            ORDER BY collected_at DESC 
        """)

    times = [r[0] for r in reversed(rows)]
    values = [r[1] for r in reversed(rows)]

    return prepped_plots.scatter_plot(times, values, "CPU Load (1m)", "cores")


def panel_mem_usage():
    rows = query("""
            SELECT collected_at, mem_used_pct
            FROM mart_host_status_history
            ORDER BY collected_at DESC 
        """)

    times = [r[0] for r in reversed(rows)]
    values = [r[1] for r in reversed(rows)]

    return prepped_plots.scatter_plot(times, values, "Memory Use (%)", "percentage")


def panel_data_disk_usage():
    rows = query("""
            SELECT collected_at, disk_data_used_pct
            FROM mart_host_status_history
            ORDER BY collected_at DESC 
        """)

    times = [r[0] for r in reversed(rows)]
    values = [r[1] for r in reversed(rows)]

    return prepped_plots.scatter_plot(times, values, "Data Disk Usage (%)", "percentage")

def panel_root_disk_usage():
    rows = query("""
            SELECT collected_at, disk_root_used_pct,
            FROM mart_host_status_history
            ORDER BY collected_at DESC 
        """)

    times = [r[0] for r in reversed(rows)]
    values = [r[1] for r in reversed(rows)]

    return prepped_plots.scatter_plot(
        times, values, "Root Disk Usage (%)", "percentage"
    )

def panel_cpu_usage_sparkline():
    rows = query("""
        SELECT collected_at, cpu_load_1m, cpu_load_5m, cpu_load_15m
        FROM mart_host_status_history
        ORDER BY collected_at ASC
    """)
    if not rows:
        return None

    times  = [r[0] for r in rows]
    load1  = [r[1] for r in rows]
    load5  = [r[2] for r in rows]
    load15 = [r[3] for r in rows]

    fig = go.Figure()
    fig.add_trace(go.Scatter(x=times, y=load1,  mode="lines", name="1m"))
    fig.add_trace(go.Scatter(x=times, y=load5,  mode="lines", name="5m"))
    fig.add_trace(go.Scatter(x=times, y=load15, mode="lines", name="15m"))
    fig.update_layout(
        height=SIZE_CONIFG["height"],
        margin=SIZE_CONIFG["margin"],
        xaxis_title=None,
        yaxis_title="load",
    )
    return {"title": "CPU Load", "chart": fig_json(fig)}

# Add new panel functions here and register them in PANELS below.

PANELS = [
    panel_mem_usage,
    panel_cpu_usage_sparkline,
    panel_root_disk_usage,
    panel_data_disk_usage
]


# --- route --------------------------------------------------------------------


@app.get("/", response_class=HTMLResponse)
async def index(request: Request):
    panels = [p for fn in PANELS if (p := fn()) is not None]
    return templates.TemplateResponse(
        request=request,
        name="dashboard.html",
        context={"panels": panels},
    )
