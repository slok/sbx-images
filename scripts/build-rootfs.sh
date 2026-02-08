#!/usr/bin/env bash
set -euo pipefail

# Builds an Alpine ext4 rootfs image for SBX Firecracker sandboxes.
# Simplified version of sbx/scripts/images/alpine/build-rootfs.sh for CI use.
#
# Usage:
#   sudo ./scripts/build-rootfs.sh --arch x86_64 --profile balanced --branch v3.23 \
#     --profiles-dir alpine/profiles --files-dir alpine/files --output-dir build

ARCH=""
PROFILE=""
ALPINE_BRANCH=""
PROFILES_DIR=""
FILES_DIR=""
OUTPUT_DIR=""
OVERHEAD_PERCENT="35"
MIN_OVERHEAD_MB="256"
SHRINK_IMAGE="true"

REQUIRED_PACKAGES=(openssh openrc e2fsprogs-extra)

log() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)            ARCH="$2";           shift 2 ;;
    --profile)         PROFILE="$2";        shift 2 ;;
    --branch)          ALPINE_BRANCH="$2";  shift 2 ;;
    --profiles-dir)    PROFILES_DIR="$2";   shift 2 ;;
    --files-dir)       FILES_DIR="$2";      shift 2 ;;
    --output-dir)      OUTPUT_DIR="$2";     shift 2 ;;
    --overhead-percent) OVERHEAD_PERCENT="$2"; shift 2 ;;
    --min-overhead-mb) MIN_OVERHEAD_MB="$2"; shift 2 ;;
    --no-shrink)       SHRINK_IMAGE="false"; shift ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -n "${ARCH}" ]]         || die "--arch is required"
[[ -n "${PROFILE}" ]]      || die "--profile is required"
[[ -n "${ALPINE_BRANCH}" ]] || die "--branch is required"
[[ -n "${PROFILES_DIR}" ]] || die "--profiles-dir is required"
[[ -n "${FILES_DIR}" ]]    || die "--files-dir is required"
[[ -n "${OUTPUT_DIR}" ]]   || die "--output-dir is required"

PROFILE_FILE="${PROFILES_DIR}/${PROFILE}.txt"
[[ -f "${PROFILE_FILE}" ]] || die "Unknown profile '${PROFILE}'. Expected file: ${PROFILE_FILE}"
[[ -d "${FILES_DIR}" ]]    || die "Missing files directory: ${FILES_DIR}"

IMAGE_NAME="rootfs-${ARCH}.ext4"
WORKDIR="$(mktemp -d -t sbx-rootfs-XXXXXX)"
MOUNT_DIR="${WORKDIR}/mnt"
ROOTFS_DIR="${WORKDIR}/rootfs"
EXT4_PATH="${WORKDIR}/${IMAGE_NAME}"
OUTPUT_PATH="${OUTPUT_DIR}/${IMAGE_NAME}"

cleanup() {
  if mountpoint -q "${MOUNT_DIR}" 2>/dev/null; then
    umount "${MOUNT_DIR}" >/dev/null 2>&1 || true
  fi
  rm -rf "${WORKDIR}" 2>/dev/null || true
}
trap cleanup EXIT

if [[ ${EUID} -ne 0 ]]; then
  die "This script must be run as root (use sudo)"
fi

# --- Resolve alpine-make-rootfs ---

resolve_alpine_make_rootfs() {
  if [[ -n "${ALPINE_MAKE_ROOTFS_BIN:-}" ]]; then
    [[ -x "${ALPINE_MAKE_ROOTFS_BIN}" ]] || die "ALPINE_MAKE_ROOTFS_BIN is not executable: ${ALPINE_MAKE_ROOTFS_BIN}"
    printf '%s' "${ALPINE_MAKE_ROOTFS_BIN}"
    return
  fi

  if command -v alpine-make-rootfs >/dev/null 2>&1; then
    command -v alpine-make-rootfs
    return
  fi

  local tool_dir="${WORKDIR}/alpine-make-rootfs"
  log "alpine-make-rootfs not found, cloning from GitHub"
  git clone --depth 1 https://github.com/alpinelinux/alpine-make-rootfs.git "${tool_dir}" >/dev/null 2>&1
  chmod +x "${tool_dir}/alpine-make-rootfs"
  printf '%s' "${tool_dir}/alpine-make-rootfs"
}

# --- Read profile packages ---

read_profile_packages() {
  local file="$1"
  local packages=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line//[$'\t\r\n ']/}"
    [[ -z "${line}" ]] && continue
    packages+=("${line}")
  done <"${file}"
  printf '%s\n' "${packages[@]}"
}

# --- Helper functions ---

append_if_missing() {
  local pattern="$1"
  local line="$2"
  local file="$3"
  if ! grep -Eq "${pattern}" "${file}"; then
    printf '%s\n' "${line}" | tee -a "${file}" >/dev/null
  fi
}

install_image_file() {
  local src="$1"
  local dst_rel="$2"
  local mode="$3"
  local dst="${MOUNT_DIR}/${dst_rel}"

  install -d -m 0755 "$(dirname "${dst}")"
  install -m "${mode}" "${src}" "${dst}"
}

maybe_shrink_image() {
  local image_path="$1"
  if [[ "${SHRINK_IMAGE}" != "true" ]]; then
    return
  fi

  if ! command -v e2fsck >/dev/null 2>&1 || ! command -v resize2fs >/dev/null 2>&1 || ! command -v dumpe2fs >/dev/null 2>&1; then
    warn "Skipping image shrink (missing required host tools: e2fsck/resize2fs/dumpe2fs)"
    return
  fi

  log "Shrinking filesystem to minimum size"
  e2fsck -fy "${image_path}" >/dev/null 2>&1
  resize2fs -M "${image_path}" >/dev/null

  local block_count
  local block_size
  block_count="$(dumpe2fs -h "${image_path}" 2>/dev/null | awk -F: '/Block count:/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}')"
  block_size="$(dumpe2fs -h "${image_path}" 2>/dev/null | awk -F: '/Block size:/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}')"

  if [[ -z "${block_count}" || -z "${block_size}" ]]; then
    warn "Could not determine ext4 geometry for truncate, leaving sparse image as-is"
    return
  fi

  local fs_bytes pad_bytes final_bytes
  fs_bytes=$((block_count * block_size))
  pad_bytes=$((8 * 1024 * 1024))
  final_bytes=$((fs_bytes + pad_bytes))
  truncate -s "${final_bytes}" "${image_path}"

  log "Shrunk image size to $((final_bytes / 1024 / 1024)) MB"
}

# --- Main build ---

ALPINE_MAKE_ROOTFS="$(resolve_alpine_make_rootfs)"

mapfile -t PROFILE_PACKAGES < <(read_profile_packages "${PROFILE_FILE}")

declare -A seen=()
ALL_PACKAGES=()
for p in "${REQUIRED_PACKAGES[@]}" "${PROFILE_PACKAGES[@]}"; do
  if [[ -z "${seen[$p]:-}" ]]; then
    seen[$p]=1
    ALL_PACKAGES+=("$p")
  fi
done
PACKAGES_STR="${ALL_PACKAGES[*]}"

log "Profile: ${PROFILE}"
log "Alpine branch: ${ALPINE_BRANCH}"
log "Arch: ${ARCH}"
log "Output: ${OUTPUT_PATH}"
log "Using alpine-make-rootfs: ${ALPINE_MAKE_ROOTFS}"

mkdir -p "${ROOTFS_DIR}" "${MOUNT_DIR}" "${OUTPUT_DIR}"

log "Building rootfs with alpine-make-rootfs"
"${ALPINE_MAKE_ROOTFS}" --branch "${ALPINE_BRANCH}" --packages "${PACKAGES_STR}" "${ROOTFS_DIR}"

SIZE_MB="$(du -sm "${ROOTFS_DIR}" | cut -f1)"
EXTRA_MB=$((SIZE_MB * OVERHEAD_PERCENT / 100))
if (( EXTRA_MB < MIN_OVERHEAD_MB )); then
  EXTRA_MB=${MIN_OVERHEAD_MB}
fi
TOTAL_MB=$((SIZE_MB + EXTRA_MB))

log "Rootfs size: ${SIZE_MB} MB"
log "Image overhead: ${EXTRA_MB} MB (${OVERHEAD_PERCENT}%, min ${MIN_OVERHEAD_MB} MB)"
log "Creating ext4 image (${TOTAL_MB} MB)"
dd if=/dev/zero of="${EXT4_PATH}" bs=1M count="${TOTAL_MB}" status=none
mkfs.ext4 -q "${EXT4_PATH}"

log "Copying rootfs into ext4 image"
mount "${EXT4_PATH}" "${MOUNT_DIR}"
cp -a "${ROOTFS_DIR}"/. "${MOUNT_DIR}/"

log "Configuring OpenSSH and SBX hook directories"
chroot "${MOUNT_DIR}" rc-update add sshd default >/dev/null
chroot "${MOUNT_DIR}" passwd -d root >/dev/null

if ! chroot "${MOUNT_DIR}" /bin/sh -c 'command -v apk >/dev/null 2>&1'; then
  die "apk not found in built rootfs. Ensure apk-tools is available in selected profile."
fi

SSHD_CONFIG="${MOUNT_DIR}/etc/ssh/sshd_config"
append_if_missing '^PermitRootLogin[[:space:]]+yes$' 'PermitRootLogin yes' "${SSHD_CONFIG}"
append_if_missing '^PermitEmptyPasswords[[:space:]]+yes$' 'PermitEmptyPasswords yes' "${SSHD_CONFIG}"
append_if_missing '^PermitUserRC[[:space:]]+yes$' 'PermitUserRC yes' "${SSHD_CONFIG}"

install_image_file "${FILES_DIR}/etc/resolv.conf" "etc/resolv.conf" 0644
install_image_file "${FILES_DIR}/usr/sbin/sbx-init" "usr/sbin/sbx-init" 0755
install_image_file "${FILES_DIR}/etc/sbx/session-env.sh" "etc/sbx/session-env.sh" 0644
install_image_file "${FILES_DIR}/etc/profile.d/sbx-session-env.sh" "etc/profile.d/sbx-session-env.sh" 0644
install_image_file "${FILES_DIR}/root/.ssh/rc" "root/.ssh/rc" 0700
install_image_file "${FILES_DIR}/usr/local/bin/sbx-start-hooks" "usr/local/bin/sbx-start-hooks" 0755
mkdir -p "${MOUNT_DIR}/etc/sbx/hooks/start.d"

umount "${MOUNT_DIR}"

maybe_shrink_image "${EXT4_PATH}"

mv "${EXT4_PATH}" "${OUTPUT_PATH}"

log "Built image: ${OUTPUT_PATH}"
log "Done"
