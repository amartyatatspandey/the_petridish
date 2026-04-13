#!/usr/bin/env bash
# =============================================================================
# 02_build_rootfs.sh — Build minimal ext4 rootfs for the honeypot guest
# =============================================================================
# Requires root: loop mount + mkfs.ext4.
# Always rebuilds rootfs from scratch (removes stale agent binaries / dirty ext4).
# Populates:
#   - Statically linked guest agent (see ../guest-agent/Makefile)
#   - Static busybox (from pinned Alpine minirootfs tarball) for mount/ip/sh
#   - /sbin/init: mount pseudo-fs, bring up lo only, respawn agent forever
#
# WSL2 note: Ubuntu on WSL2 provides a normal Linux syscall surface; loop mounts,
# mkfs.ext4, and g++ behave like bare-metal Ubuntu for this script. If
# "mount -o loop" fails after a WSL update, upgrade WSL / the WSL kernel package
# (rare on current releases).
# =============================================================================
set -euo pipefail

echo "[02] Honeypot rootfs build — starting"

if [[ "${EUID}" -ne 0 ]]; then
  echo "[02] ERROR: this script must run as root (needed for mkfs.ext4 and mount)." >&2
  echo "        Example:" >&2
  echo "        sudo \"${BASH_SOURCE[0]}\"" >&2
  exit 1
fi

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${INFRA_DIR}/.." && pwd)"
ROOTFS_IMG="${INFRA_DIR}/rootfs.ext4"
CACHE_DIR="${INFRA_DIR}/.cache"
GUEST_DIR="${PROJECT_DIR}/guest-agent"

ARCH="$(uname -m)"
if [[ "${ARCH}" != "x86_64" && "${ARCH}" != "aarch64" ]]; then
  echo "[02] ERROR: unsupported architecture '${ARCH}'." >&2
  exit 1
fi

echo "[02] INFRA_DIR=${INFRA_DIR}"
echo "[02] PROJECT_DIR=${PROJECT_DIR}"

# --- Host tool checks ---------------------------------------------------------
for bin in dd mkfs.ext4 mount umount chmod mkdir cp tar curl make; do
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "[02] ERROR: required host command '${bin}' not found in PATH." >&2
    exit 1
  fi
done

if ! command -v g++ >/dev/null 2>&1; then
  echo "[02] ERROR: g++ not found. On Debian/Ubuntu install:" >&2
  echo "        sudo apt install build-essential" >&2
  exit 1
fi

# --- Extract static busybox from pinned Alpine minirootfs -------------------
# Single approach for x86_64 and aarch64: Alpine's /bin/busybox is statically linked.
ALPINE_VER="3.19.4"
case "${ARCH}" in
  x86_64)
    ALPINE_URL="https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/x86_64/alpine-minirootfs-${ALPINE_VER}-x86_64.tar.gz"
    ;;
  aarch64)
    ALPINE_URL="https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/aarch64/alpine-minirootfs-${ALPINE_VER}-aarch64.tar.gz"
    ;;
esac

mkdir -p "${CACHE_DIR}"
ALPINE_TAR="${CACHE_DIR}/alpine-minirootfs-${ALPINE_VER}-${ARCH}.tar.gz"

if [[ -s "${ALPINE_TAR}" ]]; then
  echo "[02] Using cached Alpine minirootfs tarball: ${ALPINE_TAR}"
else
  echo "[02] Downloading Alpine minirootfs (${ALPINE_VER}, ${ARCH}) for busybox..."
  curl -fL --retry 3 --retry-delay 1 -o "${ALPINE_TAR}" "${ALPINE_URL}"
fi

BUSYBOX_HOST_TMP="$(mktemp)"
BB_EXTRACT="$(mktemp -d)"
tar xzf "${ALPINE_TAR}" -C "${BB_EXTRACT}" bin/busybox
cp -f "${BB_EXTRACT}/bin/busybox" "${BUSYBOX_HOST_TMP}"
chmod +x "${BUSYBOX_HOST_TMP}"
rm -rf "${BB_EXTRACT}"
echo "[02] Prepared static busybox at ${BUSYBOX_HOST_TMP}"

# --- Compile guest agent (must be fully static) -----------------------------
echo "[02] Building guest agent (g++ -static via Makefile)..."
make -C "${GUEST_DIR}" clean all

AGENT_BIN="${GUEST_DIR}/agent"
if [[ ! -x "${AGENT_BIN}" ]]; then
  echo "[02] ERROR: guest build did not produce executable ${AGENT_BIN}" >&2
  rm -f "${BUSYBOX_HOST_TMP}"
  exit 1
fi

# Verify static link (warn only if ldd exists and reports dynamic)
if command -v ldd >/dev/null 2>&1; then
  if ldd "${AGENT_BIN}" 2>&1 | grep -q 'not a dynamic executable'; then
    echo "[02] guest agent: OK (static binary)"
  else
    echo "[02] WARNING: ldd suggests ${AGENT_BIN} is not fully static; guest may fail in minimal rootfs." >&2
  fi
fi

# --- Fresh ext4 image (always rebuild) ----------------------------------------
MNT=""
cleanup() {
  if [[ -n "${MNT}" && -d "${MNT}" ]]; then
    echo "[02] cleanup: unmounting ${MNT} ..."
    umount -lf "${MNT}" 2>/dev/null || true
    rmdir "${MNT}" 2>/dev/null || true
  fi
  rm -f "${BUSYBOX_HOST_TMP}"
}
trap cleanup EXIT

if [[ -f "${ROOTFS_IMG}" ]]; then
  echo "[02] Removing existing rootfs image (clean rebuild): ${ROOTFS_IMG}"
  rm -f "${ROOTFS_IMG}"
fi

echo "[02] Creating 50MiB sparse image..."
dd if=/dev/zero of="${ROOTFS_IMG}" bs=1M count=50 status=none

echo "[02] Formatting ext4..."
mkfs.ext4 -F -L honeypot-root "${ROOTFS_IMG}" >/dev/null

MNT="$(mktemp -d)"
echo "[02] Mounting ${ROOTFS_IMG} at ${MNT} ..."
mount -o loop "${ROOTFS_IMG}" "${MNT}"

mkdir -p "${MNT}/"{bin,sbin,etc,proc,sys,dev,root}

echo "[02] Installing busybox and guest agent into rootfs..."
cp -f "${BUSYBOX_HOST_TMP}" "${MNT}/bin/busybox"
chmod 0755 "${MNT}/bin/busybox"
cp -f "${AGENT_BIN}" "${MNT}/sbin/agent"
chmod 0755 "${MNT}/sbin/agent"

# Busybox provides /bin/sh via explicit path in shebang; no dynamic linker needed.
cat >"${MNT}/sbin/init" <<'INITEOF'
#!/bin/busybox sh
# Honeypot guest init — no network devices beyond loopback; vsock is virtio (not configured here).
/bin/busybox mount -t proc proc /proc
/bin/busybox mount -t sysfs sysfs /sys
# devtmpfs preferred; fall back to tmpfs-only /dev if kernel lacks devtmpfs.
if ! /bin/busybox mount -t devtmpfs devtmpfs /dev 2>/dev/null; then
  /bin/busybox mount -t tmpfs tmpfs /dev
  /bin/busybox ln -sf /proc/self/fd /dev/fd
  /bin/busybox ln -sf /proc/self/fd/0 /dev/stdin
  /bin/busybox ln -sf /proc/self/fd/1 /dev/stdout
  /bin/busybox ln -sf /proc/self/fd/2 /dev/stderr
fi
/bin/busybox ip link set lo up
# Respawn agent forever so a crash does not terminate the microVM session.
while true; do
  /sbin/agent || /bin/busybox sleep 1
done
INITEOF
chmod +x "${MNT}/sbin/init"

echo "[02] Unmounting rootfs..."
umount "${MNT}"
MNT=""
trap - EXIT
rm -f "${BUSYBOX_HOST_TMP}"

echo "[02] Done. Root filesystem image: ${ROOTFS_IMG}"
echo "[02] Next: ${INFRA_DIR}/03_run_vm.sh"
