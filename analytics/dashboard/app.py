
import duckdb
import plotly.graph_objects as go
import plotly.utils
import json
from fastapi import FastAPI, Request
from fastapi.templating import Jinja2Templates
from fastapi.responses import HTMLResponse

from pathlib import Path

app = FastAPI()

BASE_DIR = Path(__file__).parent
templates = Jinja2Templates(directory=BASE_DIR / "templates")

DB_PATH = "/tmp/analytics_dev_s3.duckdb"


def get_host_status() -> dict | None:
    try:
        con = duckdb.connect(DB_PATH, read_only=True)
        row = con.execute("""
            SELECT cpu_load_1m, cpu_load_5m, cpu_load_15m,
                   mem_used_pct, disk_root_used_pct, uptime_days
            FROM mart_host_status_history
            ORDER BY collected_at DESC
            LIMIT 1
        """).fetchone()
        con.close()
        if row:
            return {
                "cpu_1m": row[0],
                "cpu_5m": row[1],
                "cpu_15m": row[2],
                "memory": row[3],
                "disk": row[4],
                "uptime_days": row[5],
            }
    except Exception as e:
        print(f"[dashboard] get_host_status failed: {e}")
        return None


def get_cpu_sparkline() -> str | None:
    try:
        con = duckdb.connect(DB_PATH, read_only=True)
        rows = con.execute("""
            SELECT collected_at, cpu_load_1m
            FROM mart_host_status_history
            ORDER BY collected_at DESC LIMIT 48
        """).fetchall()
        con.close()
    except Exception:
        return None

    if not rows:
        return None

    times = [r[0] for r in reversed(rows)]
    values = [r[1] for r in reversed(rows)]

    fig = go.Figure(go.Scatter(x=times, y=values, mode="lines"))
    fig.update_layout(height=80, margin=dict(l=0, r=0, t=0, b=0))
    return json.dumps(fig, cls=plotly.utils.PlotlyJSONEncoder)


@app.get("/", response_class=HTMLResponse)
async def index(request: Request):
    return templates.TemplateResponse(
        request=request,
        name="dashboard.html",
        context={
            "host": get_host_status(),
            "cpu_sparkline": get_cpu_sparkline(),
        }
    )
