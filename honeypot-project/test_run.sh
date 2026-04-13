#!/usr/bin/env bash
# =============================================================================
# test_run.sh — One-shot demo orchestration (WSL2 Ubuntu / Linux host)
# =============================================================================
# From the honeypot-project/ directory, this script:
#   1) Reminds you that Ollama must already be listening (Windows or WSL).
#   2) Starts the Streamlit analytics dashboard in the background.
#   3) Starts the Python host interceptor (Firecracker vsock UDS) in the background.
#   4) Waits briefly so sockets come up, then launches Firecracker via infra/03_run_vm.sh.
#   5) Blocks on the interceptor until you press Ctrl+C, then tears down children.
#
# Assumptions (typical WSL2 + AMD x86_64):
#   - You ran infra/01_setup_firecracker.sh and sudo infra/02_build_rootfs.sh first.
#   - Your user can read/write /dev/kvm (kvm group); see infra/01 for WSL2 hints.
#   - python3, streamlit, and pip deps are installed (pip install -r host-interceptor/requirements.txt).
#
# Working directory: always switched to the directory containing this script so
# relative paths ./infra/... and analytics/dashboard.py resolve correctly even
# when invoked as ~/honeypot/honeypot-project/test_run.sh from elsewhere.
# =============================================================================
set -euo pipefail

# --- Resolve project root (directory of this script) -------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# PIDs captured after background starts (empty until spawned).
STREAMLIT_PID=""
INTERCEPTOR_PID=""

# Idempotent guard so a signal storm does not re-enter cleanup recursively.
CLEANUP_DONE=0

cleanup() {
  # Kills must not trip `set -e` if a process is already gone.
  set +e
  if [[ "${CLEANUP_DONE}" -eq 1 ]]; then
    return 0
  fi
  CLEANUP_DONE=1

  echo ""
  echo "[test_run] Teardown (Ctrl+C or shutdown): stopping Streamlit, interceptor, Firecracker..."

  # Streamlit may fork workers; if we launched via setsid(1), the session PGID
  # equals STREAMLIT_PID and `kill -- -PID` terminates the whole group.
  if [[ -n "${STREAMLIT_PID}" ]]; then
    if kill -0 "${STREAMLIT_PID}" 2>/dev/null; then
      kill -- -"${STREAMLIT_PID}" 2>/dev/null || kill "${STREAMLIT_PID}" 2>/dev/null
      wait "${STREAMLIT_PID}" 2>/dev/null || true
    fi
  fi

  if [[ -n "${INTERCEPTOR_PID}" ]]; then
    if kill -0 "${INTERCEPTOR_PID}" 2>/dev/null; then
      kill "${INTERCEPTOR_PID}" 2>/dev/null
      wait "${INTERCEPTOR_PID}" 2>/dev/null || true
    fi
  fi

  # Firecracker writes its PID to this file when 03_run_vm.sh starts it.
  FC_PID_FILE="${SCRIPT_DIR}/infra/run/firecracker.pid"
  if [[ -f "${FC_PID_FILE}" ]]; then
    FC_PID="$(tr -d '[:space:]' <"${FC_PID_FILE}" || true)"
    if [[ -n "${FC_PID}" ]] && kill -0 "${FC_PID}" 2>/dev/null; then
      kill "${FC_PID}" 2>/dev/null
      wait "${FC_PID}" 2>/dev/null || true
    fi
  fi

  echo "[test_run] Teardown complete."
  set -e
}

# After `cleanup` is defined: handle Ctrl+C / kill, and any shell exit (so a
# failed 03_run_vm.sh still tears down Streamlit + interceptor if they started).
trap cleanup INT TERM EXIT

# =============================================================================
# Step 1 — Ollama must be reachable from this environment
# =============================================================================
echo "========================================================================"
echo "[test_run] WARNING: Ollama MUST be running before you continue."
echo "[test_run]   The interceptor calls http://localhost:11434/api/chat"
echo "[test_run]   Start it on Windows or in WSL (e.g. 'ollama serve') so that"
echo "[test_run]   URL resolves from this Ubuntu session."
echo "========================================================================"
echo ""

# =============================================================================
# Step 2 — Streamlit dashboard (background, new session for clean group kill)
# =============================================================================
# setsid(1): makes STREAMLIT_PID the leader of a new process group so cleanup
# can signal the whole Streamlit tree with kill -- -PID.
if ! command -v setsid >/dev/null 2>&1; then
  echo "[test_run] ERROR: setsid not found (unexpected on Ubuntu/WSL2)." >&2
  exit 1
fi

echo "[test_run] Starting Streamlit dashboard (background)..."
setsid streamlit run analytics/dashboard.py --server.headless true </dev/null &
STREAMLIT_PID=$!
echo "[test_run]   Streamlit session PGID/PID: ${STREAMLIT_PID}"

# =============================================================================
# Step 3 — Host interceptor (must match Firecracker vsock uds_path base)
# =============================================================================
export HONEYPOT_VSOCK_UDS=/tmp/honeypot-fc-vsock
echo "[test_run] Starting host interceptor (background)..."
echo "[test_run]   HONEYPOT_VSOCK_UDS=${HONEYPOT_VSOCK_UDS}"
python3 host-interceptor/interceptor.py </dev/null &
INTERCEPTOR_PID=$!
echo "[test_run]   Interceptor PID: ${INTERCEPTOR_PID}"

# =============================================================================
# Step 4 — Brief pause then boot the microVM
# =============================================================================
echo "[test_run] Waiting 2s for listener sockets..."
sleep 2

echo "[test_run] Launching Firecracker (infra/03_run_vm.sh)..."
./infra/03_run_vm.sh

# =============================================================================
# Step 5 — Stay attached until the operator stops the demo
# =============================================================================
echo ""
echo "[test_run] Demo is running. Open the Streamlit URL printed above (usually"
echo "[test_run]   http://localhost:8501). Press Ctrl+C here to stop everything."
echo ""

# Block until the interceptor exits (normally it runs forever). Ctrl+C runs
# cleanup via trap, which kills the interceptor and unblocks wait with a signal.
wait "${INTERCEPTOR_PID}" || true

# EXIT trap invokes cleanup before the shell process terminates.
exit 0
