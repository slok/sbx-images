#!/usr/bin/env bash
set -euo pipefail

# Downloads a Linux kernel binary from the Firecracker CI S3 bucket.
#
# Usage:
#   ./scripts/download-kernel.sh --arch x86_64 --kernel-version 6.1.155 --ci-version v1.15 --output-dir build

ARCH=""
KERNEL_VERSION=""
CI_VERSION=""
OUTPUT_DIR=""

log() { printf '[INFO] %s\n' "$*"; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)          ARCH="$2";           shift 2 ;;
    --kernel-version) KERNEL_VERSION="$2"; shift 2 ;;
    --ci-version)    CI_VERSION="$2";     shift 2 ;;
    --output-dir)    OUTPUT_DIR="$2";     shift 2 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -n "${ARCH}" ]]           || die "--arch is required"
[[ -n "${KERNEL_VERSION}" ]] || die "--kernel-version is required"
[[ -n "${CI_VERSION}" ]]     || die "--ci-version is required"
[[ -n "${OUTPUT_DIR}" ]]     || die "--output-dir is required"

command -v curl >/dev/null 2>&1 || die "curl is required"

S3_URL="https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/${CI_VERSION}/${ARCH}/vmlinux-${KERNEL_VERSION}"
OUTPUT_FILE="${OUTPUT_DIR}/vmlinux-${ARCH}"

mkdir -p "${OUTPUT_DIR}"

if [[ -f "${OUTPUT_FILE}" ]]; then
  log "Kernel already exists: ${OUTPUT_FILE}"
  exit 0
fi

log "Downloading kernel: ${S3_URL}"
curl --fail --silent --show-error --location --output "${OUTPUT_FILE}" "${S3_URL}"

log "Downloaded kernel: ${OUTPUT_FILE} ($(du -h "${OUTPUT_FILE}" | cut -f1))"
