#!/usr/bin/env bash
# =============================================================================
# 03_run_vm.sh — Boot the honeypot Firecracker microVM via the HTTP API
# =============================================================================
# - Configures boot source (pinned vmlinux), virtio root drive, vsock (guest CID 3).
# - Does NOT attach any virtio-net device (no eth0 / no guest Internet).
# - Waits until the Firecracker API unix socket exists before issuing PUTs
#   (avoids races right after process spawn).
#
# Firecracker vsock host side: guest -> host port P is proxied to a host AF_UNIX
# socket at "${uds_path}_P". Start the Python interceptor with:
#   HONEYPOT_VSOCK_UDS=<uds_path>  (same base path as below, without _1234)
# so it listens on AF_UNIX at "${uds_path}_1234" before the guest agent connects.
# =============================================================================
set -euo pipefail

echo "[03] Honeypot Firecracker VM launch — starting"

ARCH="$(uname -m)"

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${INFRA_DIR}/.." && pwd)"
RUN_DIR="${INFRA_DIR}/run"
mkdir -p "${RUN_DIR}"

FC_BIN="${INFRA_DIR}/firecracker/firecracker"
KERNEL="${INFRA_DIR}/vmlinux"
ROOTFS="${INFRA_DIR}/rootfs.ext4"
API_SOCK="${RUN_DIR}/firecracker.socket"
FC_LOG="${RUN_DIR}/firecracker.log"
FC_PID_FILE="${RUN_DIR}/firecracker.pid"

# Short path: AF_UNIX max length is small; keep vsock base under /tmp.
# Override to match host-interceptor's HONEYPOT_VSOCK_UDS (must match Firecracker uds_path).
VSOCK_UDS_BASE="${HONEYPOT_VSOCK_UDS:-/tmp/honeypot-fc-vsock}"

echo "[03] INFRA_DIR=${INFRA_DIR}"
echo "[03] API socket: ${API_SOCK}"
echo "[03] vsock UDS base (host): ${VSOCK_UDS_BASE}"
echo "[03]   -> start interceptor with: export HONEYPOT_VSOCK_UDS='${VSOCK_UDS_BASE}'"

# --- KVM check (same expectations as 01; WSL2 often needs kvm group + newgrp) --
if [[ ! -e /dev/kvm ]]; then
  echo "[03] ERROR: /dev/kvm missing. Run ${INFRA_DIR}/01_setup_firecracker.sh for full diagnostics." >&2
  echo "[03] On WSL2: ensure nested virtualization is enabled if /dev/kvm never appears." >&2
  exit 1
fi
if [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
  echo "[03] ERROR: current user cannot read/write /dev/kvm." >&2
  echo "        sudo usermod -aG kvm \"\$USER\"  then log out/in or: newgrp kvm" >&2
  echo "If /dev/kvm permission is denied in WSL2, run: sudo usermod -aG kvm ${USER} && newgrp kvm" >&2
  exit 1
fi

# --- Preflight artifacts ------------------------------------------------------
for f in "${FC_BIN}" "${KERNEL}" "${ROOTFS}"; do
  if [[ ! -f "${f}" ]]; then
    echo "[03] ERROR: required file missing: ${f}" >&2
    echo "        Run ${INFRA_DIR}/01_setup_firecracker.sh and sudo ${INFRA_DIR}/02_build_rootfs.sh first." >&2
    exit 1
  fi
done

KERNEL_ABS="$(readlink -f "${KERNEL}")"
ROOTFS_ABS="$(readlink -f "${ROOTFS}")"
FC_BIN_ABS="$(readlink -f "${FC_BIN}")"

BOOT_ARGS="console=ttyS0 reboot=k panic=1 pci=off root=/dev/vda rw init=/sbin/init"

# --- Start Firecracker API server --------------------------------------------
rm -f "${API_SOCK}"
rm -f "${FC_PID_FILE}"

echo "[03] Starting Firecracker (logs -> ${FC_LOG})..."
nohup "${FC_BIN_ABS}" --api-sock "${API_SOCK}" >>"${FC_LOG}" 2>&1 &
FC_PID="$!"
echo "${FC_PID}" >"${FC_PID_FILE}"

# Wait for API unix socket (Firecracker creates it shortly after startup).
echo "[03] Waiting for API socket ${API_SOCK} ..."
api_ready=0
for ((i = 0; i < 200; i++)); do
  if [[ -S "${API_SOCK}" ]]; then
    api_ready=1
    break
  fi
  if ! kill -0 "${FC_PID}" 2>/dev/null; then
    echo "[03] ERROR: Firecracker exited before API socket appeared. Last log lines:" >&2
    tail -n 50 "${FC_LOG}" >&2 || true
    exit 1
  fi
  sleep 0.1
done

if [[ "${api_ready}" -ne 1 ]]; then
  echo "[03] ERROR: timed out waiting for API socket (20s)." >&2
  kill "${FC_PID}" 2>/dev/null || true
  exit 1
fi
echo "[03] API socket is ready."

# --- JSON helpers (python3 — always available on target hosts) ---------------
put_json() {
  # $1 = API path (e.g. /machine-config), $2 = JSON body string
  local api_path="$1"
  local body="$2"
  curl -fsS --unix-socket "${API_SOCK}" \
    -H 'Content-Type: application/json' \
    -X PUT "http://localhost${api_path}" \
    -d "${body}" >/dev/null
}

# `smt` is x86-only in Firecracker; omit on aarch64 to avoid API validation errors.
if [[ "${ARCH}" == "x86_64" ]]; then
  MACHINE_CFG="$(
    python3 -c 'import json; print(json.dumps({"vcpu_count":1,"mem_size_mib":128,"smt":False}))'
  )"
else
  MACHINE_CFG="$(
    python3 -c 'import json; print(json.dumps({"vcpu_count":1,"mem_size_mib":128}))'
  )"
fi
BOOT_JSON="$(
  python3 -c 'import json,sys; print(json.dumps({"kernel_image_path":sys.argv[1],"boot_args":sys.argv[2]}))' \
    "${KERNEL_ABS}" "${BOOT_ARGS}"
)"
DRIVE_JSON="$(
  python3 -c 'import json,sys; print(json.dumps({"drive_id":"rootfs","path_on_host":sys.argv[1],"is_root_device":True,"is_read_only":False}))' \
    "${ROOTFS_ABS}"
)"
VSOCK_JSON="$(
  python3 -c 'import json,sys; print(json.dumps({"guest_cid":3,"uds_path":sys.argv[1]}))' "${VSOCK_UDS_BASE}"
)"
ACTION_JSON="$(
  python3 -c 'import json; print(json.dumps({"action_type":"InstanceStart"}))'
)"

echo "[03] PUT /machine-config ..."
put_json "/machine-config" "${MACHINE_CFG}"

echo "[03] PUT /boot-source ..."
put_json "/boot-source" "${BOOT_JSON}"

echo "[03] PUT /drives/rootfs ..."
put_json "/drives/rootfs" "${DRIVE_JSON}"

echo "[03] PUT /vsock ..."
put_json "/vsock" "${VSOCK_JSON}"

echo "[03] PUT /actions (InstanceStart) ..."
put_json "/actions" "${ACTION_JSON}"

echo "[03] InstanceStart issued — microVM should be running."
echo "[03] Firecracker PID: ${FC_PID} (stop with: kill ${FC_PID})"
echo "[03]"
echo "[03] On the host, start the interceptor so it listens for guest vsock:"
echo "[03]   export HONEYPOT_VSOCK_UDS='${VSOCK_UDS_BASE}'"
echo "[03]   python3 ${PROJECT_DIR}/host-interceptor/interceptor.py"
echo "[03] (This binds Unix socket ${VSOCK_UDS_BASE}_1234 per Firecracker vsock rules.)"
echo "[03] Done."
