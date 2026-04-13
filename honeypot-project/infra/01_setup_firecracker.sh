#!/usr/bin/env bash
# =============================================================================
# 01_setup_firecracker.sh — Honeypot Firecracker host prerequisites
# =============================================================================
# Debian/Ubuntu Linux host with KVM. Downloads:
#   1) Latest Firecracker release (GitHub) into infra/firecracker/
#   2) Prebuilt uncompressed vmlinux 5.10 from spec.ccfc.min (hardcoded URLs)
# Idempotent: skips downloads if targets already exist (delete files to refresh).
# =============================================================================
set -euo pipefail

echo "[01] Honeypot Firecracker setup — starting"

# --- Path layout --------------------------------------------------------------
# This file lives in honeypot-project/infra/; project root is one level up.
INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${INFRA_DIR}/.." && pwd)"
FC_INSTALL_DIR="${INFRA_DIR}/firecracker"
FC_SYMLINK="${FC_INSTALL_DIR}/firecracker"
VMLINUX_DEST="${INFRA_DIR}/vmlinux"

echo "[01] INFRA_DIR=${INFRA_DIR}"
echo "[01] PROJECT_DIR=${PROJECT_DIR}"

ARCH="$(uname -m)"
if [[ "${ARCH}" != "x86_64" && "${ARCH}" != "aarch64" ]]; then
  echo "[01] ERROR: unsupported architecture '${ARCH}' (need x86_64 or aarch64)." >&2
  exit 1
fi

# --- KVM availability (required for Firecracker) ----------------------------
# WSL2 (Ubuntu on Windows): /dev/kvm often exists once nested virtualization is
# enabled for the WSL VM, but the default user may lack read/write until they
# join the "kvm" group. uname -m is still x86_64 on typical AMD/Intel hosts.
# Apply group changes with newgrp(1) or a full shell restart after usermod.
echo "[01] Checking /dev/kvm (KVM must be enabled in BIOS/UEFI and module loaded)..."
if [[ ! -e /dev/kvm ]]; then
  echo "[01] ERROR: /dev/kvm missing. Install kvm modules and ensure virtualization is enabled:" >&2
  echo "        sudo apt install qemu-kvm cpu-checker && sudo kvm-ok" >&2
  echo "        sudo modprobe kvm (and kvm_intel or kvm_amd)" >&2
  echo "[01] On WSL2: enable nested virtualization in Windows / .wslconfig if /dev/kvm never appears." >&2
  exit 1
fi
if [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
  echo "[01] ERROR: current user cannot read/write /dev/kvm." >&2
  echo "        Add your user to the 'kvm' group, then log out/in (or use newgrp):" >&2
  echo "        sudo usermod -aG kvm \"\$USER\"" >&2
  # Exact WSL2 hint requested for demos (stderr so it is visible next to the error).
  echo "If /dev/kvm permission is denied in WSL2, run: sudo usermod -aG kvm ${USER} && newgrp kvm" >&2
  exit 1
fi
echo "[01] /dev/kvm is present and accessible — OK"

# --- Firecracker binary (latest GitHub release, idempotent) ------------------
mkdir -p "${FC_INSTALL_DIR}"

if [[ -x "${FC_SYMLINK}" ]]; then
  echo "[01] Firecracker already present at ${FC_SYMLINK} — skipping GitHub download."
else
  echo "[01] Resolving latest Firecracker release from GitHub API..."
  RELEASE_JSON="$(mktemp)"
  cleanup_release_json() { rm -f "${RELEASE_JSON}"; }
  trap cleanup_release_json EXIT

  curl -fsSL -H 'Accept: application/vnd.github+json' -H 'User-Agent: honeypot-infra-01' \
    'https://api.github.com/repos/firecracker-microvm/firecracker/releases/latest' \
    -o "${RELEASE_JSON}"

  # Pick a release .tgz for this host arch (avoid debug/symbols assets).
  TGZ_URL="$(
    python3 - "${RELEASE_JSON}" "${ARCH}" <<'PY'
import json, sys, pathlib
arch = sys.argv[2]
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
assets = data.get("assets") or []
candidates = []
for a in assets:
    url = a.get("browser_download_url") or ""
    name = (a.get("name") or "").lower()
    if not url.endswith(".tgz"):
        continue
    if arch not in name:
        continue
    if "debug" in name or "symbols" in name:
        continue
    candidates.append(url)
if not candidates:
    print("ERROR: no suitable .tgz asset found for this arch", file=sys.stderr)
    sys.exit(1)
# Prefer shortest name (usually the main tarball)
candidates.sort(key=len)
print(candidates[0])
PY
  )"

  echo "[01] Downloading Firecracker tarball:"
  echo "       ${TGZ_URL}"

  TGZ_PATH="${FC_INSTALL_DIR}/firecracker-download.tgz"
  curl -fL --retry 3 --retry-delay 1 -o "${TGZ_PATH}" "${TGZ_URL}"

  echo "[01] Extracting Firecracker into ${FC_INSTALL_DIR} ..."
  EXTRACT_TMP="$(mktemp -d)"
  tar xzf "${TGZ_PATH}" -C "${EXTRACT_TMP}"

  FC_REAL="$(
    find "${EXTRACT_TMP}" -type f \( -name 'firecracker-*' -o -name 'firecracker' \) ! -name '*.tgz' \
      | head -n 1 || true
  )"
  if [[ -z "${FC_REAL}" || ! -f "${FC_REAL}" ]]; then
    echo "[01] ERROR: could not locate firecracker binary inside tarball." >&2
    rm -rf "${EXTRACT_TMP}"
    exit 1
  fi

  # If the tarball unpacks flat (binary next to tar root), avoid using the mktemp dirname.
  FC_PARENT="$(dirname "${FC_REAL}")"
  REL_NAME="$(basename "${FC_PARENT}")"
  if [[ "${REL_NAME}" == "$(basename "${EXTRACT_TMP}")" ]]; then
    REL_NAME="firecracker-flat-${ARCH}"
  fi
  VERSION_DIR="${FC_INSTALL_DIR}/${REL_NAME}"
  mkdir -p "${VERSION_DIR}"
  cp -f "${FC_REAL}" "${VERSION_DIR}/$(basename "${FC_REAL}")"
  chmod +x "${VERSION_DIR}/$(basename "${FC_REAL}")"
  # Stable launcher path for scripts (absolute symlink target survives cwd changes).
  ln -sfn "${VERSION_DIR}/$(basename "${FC_REAL}")" "${FC_SYMLINK}"
  rm -rf "${EXTRACT_TMP}" "${TGZ_PATH}"
  trap - EXIT
  rm -f "${RELEASE_JSON}"
  echo "[01] Installed Firecracker -> ${FC_SYMLINK}"
fi

# --- vmlinux (pinned CI URLs — do not scrape S3) ----------------------------
# Verified objects; x86_64 and aarch64 5.10 images used widely with Firecracker.
case "${ARCH}" in
  x86_64)
    VMLINUX_URL="https://s3.amazonaws.com/spec.ccfc.min/ci-artifacts/kernels/x86_64/vmlinux-5.10.bin"
    ;;
  aarch64)
    VMLINUX_URL="https://s3.amazonaws.com/spec.ccfc.min/ci-artifacts/kernels/aarch64/vmlinux-5.10.bin"
    ;;
esac

if [[ -s "${VMLINUX_DEST}" ]]; then
  echo "[01] vmlinux already present at ${VMLINUX_DEST} — skipping download."
else
  echo "[01] Downloading prebuilt vmlinux (5.10) for ${ARCH}..."
  curl -fL --retry 3 --retry-delay 1 -o "${VMLINUX_DEST}" "${VMLINUX_URL}"
  echo "[01] Saved kernel to ${VMLINUX_DEST}"
fi

echo "[01] Done."
echo "[01] Next: sudo ${INFRA_DIR}/02_build_rootfs.sh"
echo "[01] Then: ${INFRA_DIR}/03_run_vm.sh"
