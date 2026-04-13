#!/usr/bin/env python3
# =============================================================================
# analytics/dashboard.py — Real-time honeypot telemetry (Streamlit)
# =============================================================================
# Purpose
# -------
# Operators running the Firecracker honeypot on WSL2 or bare Linux can watch
# attacker activity without tailing JSONL in a terminal. This app is read-only
# toward telemetry: the interceptor remains the single writer to the log file.
#
# Data source
# ------------
# Reads JSON Lines (JSONL) from ../logs/telemetry.json — one JSON object per
# line, written by host-interceptor/interceptor.py via append_telemetry().
# Expected keys per record:
#   - timestamp: ISO-8601 UTC string from the interceptor
#   - attacker_command: single line from the guest (may contain hostile text)
#   - llm_response: model output returned to the guest (shown as "AI Response")
#
# Refresh model
# --------------
# Streamlit reruns the whole script on interaction; for timer-driven updates we
# use @st.fragment(run_every=...) (Streamlit >= 1.33) so only the fragment body
# re-executes every few seconds. That keeps metrics/tables fresh while the rest
# of the page (title, page_config) stays stable.
#
# Run (typical)
# -------------
#   pip install -r host-interceptor/requirements.txt
#   streamlit run analytics/dashboard.py
# Or use ../test_run.sh which starts this dashboard in the background.
# =============================================================================
from __future__ import annotations

import json
from datetime import timedelta
from pathlib import Path

import pandas as pd
import streamlit as st

# -----------------------------------------------------------------------------
# Paths
# -----------------------------------------------------------------------------
# This file: honeypot-project/analytics/dashboard.py  →  project root is parent.
_PROJECT_ROOT = Path(__file__).resolve().parent.parent
_TELEMETRY_FILE = _PROJECT_ROOT / "logs" / "telemetry.json"

# Large model payloads: show a preview in the terminal box; full text in expander.
_TERMINAL_PREVIEW_CHARS = 4000


def _load_telemetry_dataframe() -> pd.DataFrame:
    """
    Load all JSONL records from the telemetry file into a DataFrame.

    The interceptor opens the file in append mode; for a demo-sized log, reading
    the whole file each refresh is simple and correct. Empty or missing files
    yield zero rows (never crash the dashboard).
    """
    path = _TELEMETRY_FILE
    if not path.is_file():
        return pd.DataFrame(
            columns=["timestamp", "attacker_command", "llm_response"]
        )

    raw = path.read_bytes()
    if not raw.strip():
        return pd.DataFrame(
            columns=["timestamp", "attacker_command", "llm_response"]
        )

    # pandas.read_json accepts a JSON string; lines=True => one object per line.
    try:
        df = pd.read_json(
            raw.decode("utf-8", errors="replace"),
            lines=True,
            dtype=False,
        )
    except (ValueError, json.JSONDecodeError):
        # Malformed tail while a line is being written — return last good state empty.
        return pd.DataFrame(
            columns=["timestamp", "attacker_command", "llm_response"]
        )

    # Normalize expected columns (ignore unexpected keys from future schema versions).
    for col in ("timestamp", "attacker_command", "llm_response"):
        if col not in df.columns:
            df[col] = ""
    return df[["timestamp", "attacker_command", "llm_response"]]


@st.fragment(run_every=timedelta(seconds=2))
def _render_live_dashboard() -> None:
    """
    Fragment body: re-runs every `run_every` interval for near real-time updates.

    Everything inside should be cheap enough for a 2-second cadence on a laptop.
    We intentionally re-read the entire JSONL file each tick: the log is append-
    only and small for a classroom demo; partial tail reads would be faster but
    add complexity for marginal benefit here.
    """
    df = _load_telemetry_dataframe()

    # --- Metric: total intercepted commands (one JSONL row per command) --------
    total = len(df)
    st.metric(
        label="Total Commands Intercepted",
        value=total,
        help="Count of JSONL rows in logs/telemetry.json (one per guest command).",
    )

    # --- Table: newest first (string ISO timestamps sort correctly for UTC) ---
    display_df = df.copy()
    if not display_df.empty:
        display_df = display_df.sort_values(
            by="timestamp", ascending=False, kind="mergesort"
        )
    display_df = display_df.rename(
        columns={
            "timestamp": "Timestamp",
            "attacker_command": "Attacker Command",
            "llm_response": "AI Response",
        }
    )

    st.subheader("Intercept log (live)")
    st.dataframe(
        display_df,
        use_container_width=True,
        hide_index=True,
    )

    # --- Simulated terminal: latest AI / LLM payload shown as "screen" output -
    st.subheader("Latest AI payload (terminal view)")
    if display_df.empty:
        st.info(
            "No telemetry yet. Start the host interceptor and generate guest "
            "commands — rows will appear here automatically."
        )
        return

    latest_response = str(display_df.iloc[0]["AI Response"])
    preview = latest_response
    truncated = False
    if len(preview) > _TERMINAL_PREVIEW_CHARS:
        preview = preview[:_TERMINAL_PREVIEW_CHARS]
        truncated = True

    # Dark container + monospace mimics a shell transcript (Streamlit themes vary).
    with st.container():
        st.code(preview, language="bash")

    if truncated or len(latest_response) > _TERMINAL_PREVIEW_CHARS:
        with st.expander("Show full latest AI response"):
            st.text(latest_response)


def main() -> None:
    """Configure the page once; delegate live widgets to the auto-refresh fragment."""
    st.set_page_config(
        page_title="Honeypot Telemetry",
        layout="wide",
        initial_sidebar_state="collapsed",
    )

    st.title("Firecracker honeypot — live analytics")
    st.caption(
        f"Telemetry file: `{_TELEMETRY_FILE}` — auto-refresh every 2 seconds."
    )

    # Single call: the fragment schedules its own reruns.
    _render_live_dashboard()


if __name__ == "__main__":
    main()
