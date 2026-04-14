#!/usr/bin/env bash
# Preflight checks before ./honeypot-project/test_run.sh (Linux / WSL2).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
HP="${REPO_ROOT}/honeypot-project"
FC="${HP}/infra/firecracker/firecracker"
VML="${HP}/infra/vmlinux"
ROOTFS="${HP}/infra/rootfs.ext4"
VSOCK_BASE="${HONEYPOT_VSOCK_UDS:-/tmp/honeypot-fc-vsock}"
VSOCK_SOCK="${VSOCK_BASE}_1234"
OLLAMA_TAGS_URL="${OLLAMA_TAGS_URL:-http://localhost:11434/api/tags}"

echo "[preflight] Repo root: ${REPO_ROOT}"
echo "[preflight] Honeypot project: ${HP}"

fail() {
  echo "[preflight] ERROR: $*" >&2
  exit 1
}

warn() {
  echo "[preflight] WARN: $*" >&2
}

if [[ ! -d "${HP}" ]]; then
  fail "honeypot-project directory missing at ${HP}"
fi

if [[ ! -e /dev/kvm ]]; then
  fail "/dev/kvm missing. Enable KVM (Linux) or WSL2 nested virtualization, then retry."
fi
if [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
  fail "/dev/kvm not readable/writable by this user. Try: sudo usermod -aG kvm \"\$USER\" then newgrp kvm"
fi

ARCH="$(uname -m)"
if [[ "${ARCH}" != "x86_64" && "${ARCH}" != "aarch64" ]]; then
  warn "Architecture is ${ARCH}; Firecracker scripts expect x86_64 or aarch64."
fi

if [[ ! -x "${FC}" ]]; then
  fail "Firecracker binary missing. Run: ${HP}/infra/01_setup_firecracker.sh"
fi
if [[ ! -f "${VML}" ]]; then
  fail "Kernel missing at ${VML}. Run: ${HP}/infra/01_setup_firecracker.sh"
fi
if [[ ! -f "${ROOTFS}" ]]; then
  fail "Rootfs missing at ${ROOTFS}. Run: sudo ${HP}/infra/02_build_rootfs.sh"
fi

if command -v curl >/dev/null 2>&1; then
  if ! curl -fsS --max-time 3 "${OLLAMA_TAGS_URL}" >/dev/null; then
    fail "Ollama not reachable at ${OLLAMA_TAGS_URL}. Start with: ollama serve  (same environment as the interceptor)"
  fi
else
  warn "curl not installed; skipping Ollama HTTP check."
fi

if command -v ss >/dev/null 2>&1; then
  if ss -ltn 2>/dev/null | grep -q ':8501'; then
    warn "Something is already listening on TCP 8501 (Streamlit default). Stop it or change Streamlit port."
  fi
fi

if [[ -S "${VSOCK_SOCK}" ]]; then
  warn "Unix socket already exists: ${VSOCK_SOCK} (stale from a prior run?). Remove if needed: rm -f '${VSOCK_SOCK}'"
fi

echo "[preflight] vsock UDS base matches test_run.sh / 03_run_vm default: ${VSOCK_BASE}"
echo "[preflight] OK — environment looks ready for ./honeypot-project/test_run.sh"
