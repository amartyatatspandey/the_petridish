#!/usr/bin/env python3
"""
The Petridish — operator console (Streamlit).

Reads JSONL telemetry written by host-interceptor/interceptor.py.
Supports optional offline sample data for demos without a live VM.
"""
from __future__ import annotations

import io
import json
from datetime import timedelta
from pathlib import Path

import pandas as pd
import streamlit as st

_PROJECT_ROOT = Path(__file__).resolve().parent.parent
_REPO_ROOT = _PROJECT_ROOT.parent
_TELEMETRY_FILE = _PROJECT_ROOT / "logs" / "telemetry.json"
_SAMPLE_FILE = _REPO_ROOT / "docs" / "sample_telemetry.jsonl"

_TERMINAL_PREVIEW_CHARS = 4000

_ALL_COLS = [
    "timestamp",
    "session_id",
    "command_index",
    "latency_ms",
    "status",
    "error_type",
    "attacker_command",
    "llm_response",
]

_SOC_CSS = """
<style>
    @import url('https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;600&family=Space+Grotesk:wght@400;600&display=swap');
    html, body, [class*="css"] { font-family: 'Space Grotesk', sans-serif; }
    .block-container { padding-top: 1.2rem; }
    .petridish-hero {
        background: linear-gradient(135deg, #0d1117 0%, #161b22 45%, #21262d 100%);
        border: 1px solid #30363d;
        border-radius: 12px;
        padding: 1.25rem 1.5rem;
        margin-bottom: 1rem;
        color: #e6edf3;
    }
    .petridish-hero h1 { font-size: 1.55rem; margin: 0 0 0.35rem 0; color: #f0f6fc; }
    .petridish-hero p { margin: 0; color: #8b949e; font-size: 0.95rem; }
    .metric-card { background: #161b22; border: 1px solid #30363d; border-radius: 8px; padding: 0.75rem; }
    div[data-testid="stMetricValue"] { font-family: 'JetBrains Mono', monospace; }
</style>
"""


def _inject_soc_theme() -> None:
    st.markdown(_SOC_CSS, unsafe_allow_html=True)


def heuristic_tag(command: str) -> str:
    c = (command or "").strip().lower()
    if not c:
        return "empty"
    if any(
        k in c
        for k in (
            "curl ",
            "wget ",
            "nc ",
            "netcat",
            "ssh ",
            "scp ",
            "/etc/passwd",
            "/etc/shadow",
        )
    ):
        return "network_creds"
    if any(c.startswith(p) for p in ("ls", "dir ", "find", "locate", "tree")):
        return "recon"
    if any(c.startswith(p) for p in ("cat ", "head ", "tail ", "less ", "more ")):
        return "file_read"
    if any(c.startswith(p) for p in ("cd ", "pwd", "pushd", "popd")):
        return "navigation"
    if any(c.startswith(p) for p in ("whoami", "id ", "uname", "hostname")):
        return "identity"
    if any(c.startswith(p) for p in ("chmod", "chown", "sudo", "su ")):
        return "privilege"
    if any(c.startswith(p) for p in ("ps ", "top", "htop")):
        return "process"
    return "other"


def _load_jsonl_to_df(path: Path) -> pd.DataFrame:
    if not path.is_file():
        return pd.DataFrame(columns=_ALL_COLS)
    raw = path.read_bytes()
    if not raw.strip():
        return pd.DataFrame(columns=_ALL_COLS)
    try:
        df = pd.read_json(
            raw.decode("utf-8", errors="replace"),
            lines=True,
            dtype=False,
        )
    except (ValueError, json.JSONDecodeError):
        return pd.DataFrame(columns=_ALL_COLS)
    for col in _ALL_COLS:
        if col not in df.columns:
            df[col] = pd.NA
    df = df[_ALL_COLS]
    df["session_id"] = df["session_id"].fillna("legacy").astype(str)
    df["heuristic_tag"] = df["attacker_command"].astype(str).map(heuristic_tag)
    return df


def _normalize_for_display(df: pd.DataFrame) -> pd.DataFrame:
    if df.empty:
        return df
    out = df.copy()
    if "session_id" in out.columns:
        out["session_id"] = out["session_id"].fillna("legacy").astype(str)
    if "command_index" in out.columns:
        out["command_index"] = pd.to_numeric(out["command_index"], errors="coerce")
    if "latency_ms" in out.columns:
        out["latency_ms"] = pd.to_numeric(out["latency_ms"], errors="coerce")
    return out


@st.fragment(run_every=timedelta(seconds=2))
def _live_fragment(
    data_path: Path,
    session_filter: list[str],
) -> None:
    df = _normalize_for_display(_load_jsonl_to_df(data_path))
    if session_filter:
        df = df[df["session_id"].isin(session_filter)]

    total = len(df)
    sessions = int(df["session_id"].nunique()) if not df.empty else 0
    lat_mean = (
        float(df["latency_ms"].dropna().mean())
        if not df.empty and df["latency_ms"].notna().any()
        else 0.0
    )
    degraded = int((df["status"] == "degraded").sum()) if not df.empty else 0

    c1, c2, c3, c4 = st.columns(4)
    with c1:
        st.metric("Commands logged", total)
    with c2:
        st.metric("Sessions", sessions)
    with c3:
        st.metric("Avg latency (ms)", f"{lat_mean:.0f}" if lat_mean else "—")
    with c4:
        st.metric("Degraded responses", degraded)

    if not df.empty and df["latency_ms"].notna().any():
        tail = df.sort_values("timestamp").tail(40)
        st.subheader("Recent latency (ms)")
        chart_series = tail.reset_index(drop=True)["latency_ms"]
        st.line_chart(chart_series)

    st.subheader("Intercept log")
    if df.empty:
        st.info("No rows yet. Run the interceptor and guest, or switch to **Sample (offline)** in the sidebar.")
        return

    show = df.sort_values(by="timestamp", ascending=False, kind="mergesort")
    display_cols = [
        "timestamp",
        "session_id",
        "command_index",
        "latency_ms",
        "status",
        "heuristic_tag",
        "attacker_command",
        "llm_response",
    ]
    st.dataframe(
        show[display_cols].rename(
            columns={
                "timestamp": "Time",
                "session_id": "Session",
                "command_index": "#",
                "latency_ms": "ms",
                "status": "Status",
                "heuristic_tag": "Tag",
                "attacker_command": "Command",
                "llm_response": "AI output",
            }
        ),
        use_container_width=True,
        hide_index=True,
    )

    st.subheader("Latest AI output")
    latest = str(show.iloc[0]["llm_response"])
    preview = latest[:_TERMINAL_PREVIEW_CHARS]
    truncated = len(latest) > _TERMINAL_PREVIEW_CHARS
    st.code(preview, language="bash")
    if truncated:
        with st.expander("Full latest response"):
            st.text(latest)

    csv_buf = io.StringIO()
    show.to_csv(csv_buf, index=False)
    st.download_button(
        label="Download visible table as CSV",
        data=csv_buf.getvalue(),
        file_name="honeypot_telemetry_export.csv",
        mime="text/csv",
    )


def main() -> None:
    st.set_page_config(
        page_title="The Petridish — SOC Console",
        layout="wide",
        initial_sidebar_state="expanded",
    )
    _inject_soc_theme()

    st.markdown(
        '<div class="petridish-hero"><h1>The Petridish</h1>'
        "<p>Live deception telemetry · Firecracker guest → vsock → local LLM → JSONL</p></div>",
        unsafe_allow_html=True,
    )

    with st.sidebar:
        st.header("Data source")
        mode = st.radio(
            "Telemetry",
            ("Live (logs/telemetry.json)", "Sample (offline demo)"),
            index=0,
            help="Use sample data for portfolio walkthrough when no VM is running.",
        )
        path = _SAMPLE_FILE if mode.startswith("Sample") else _TELEMETRY_FILE
        st.caption(f"Reading: `{path}`")

        df0 = _normalize_for_display(_load_jsonl_to_df(path))
        sessions = sorted(df0["session_id"].dropna().unique().tolist()) if not df0.empty else []
        session_filter: list[str] = []
        if sessions:
            session_filter = st.multiselect(
                "Filter sessions",
                options=sessions,
                default=[],
                help="Empty = show all sessions.",
            )

    _live_fragment(path, session_filter)


if __name__ == "__main__":
    main()
