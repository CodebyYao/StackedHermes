#!/usr/bin/env bash
#
# Upgrade the NVIDIA driver so recent Ollama builds will use your GPUs.
#
# Why you might need this: current ollama/ollama images refuse any GPU on a
# driver older than 550 and silently fall back to CPU. The symptom is
# `ollama ps` reporting "100% CPU" while `nvidia-smi` inside the container
# looks perfectly healthy. Check the ollama logs for:
#
#   WARN cuda_compat.go "NVIDIA driver too old" required_driver="550 or newer"
#
# Defaults to driver 580. Override:  DRIVER_VERSION=595 sudo -E ./upgrade-driver.sh
# Run `ubuntu-drivers devices` first to see what your card supports.
#
# Requires a REBOOT. Containers with restart: unless-stopped return on their own.
#
# Usage:  sudo ./upgrade-driver.sh
set -euo pipefail

c_info=$'\033[36m'; c_ok=$'\033[32m'; c_warn=$'\033[33m'; c_err=$'\033[31m'; c_off=$'\033[0m'
info() { echo "${c_info}==>${c_off} $*"; }
ok()   { echo "${c_ok}  ok${c_off} $*"; }
warn() { echo "${c_warn}  !!${c_off} $*"; }
die()  { echo "${c_err}FATAL:${c_off} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "must run as root:  sudo $0"

TARGET="${DRIVER_VERSION:-580}"   # override: DRIVER_VERSION=595 sudo -E ./upgrade-driver.sh

info "current driver: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)"
info "installed driver packages:"
dpkg -l | grep -E '^ii\s+nvidia-driver-[0-9]+' | awk '{print "       "$2" "$3}'

# The box carries a stale transitional nvidia-driver-520 (525.147.05) alongside
# 535. Leaving both in place makes apt's dependency resolution unpredictable
# during the upgrade, so drop the transitional metapackages first. This removes
# only the metapackages, not the actual driver libraries.
info "removing stale transitional driver metapackages"
for p in nvidia-driver-520 nvidia-driver-525 nvidia-driver-530; do
    if dpkg -l "$p" >/dev/null 2>&1; then
        apt-get remove -y "$p" || warn "could not remove $p, continuing"
    fi
done

info "stopping the Hermes stack before touching the driver"
if command -v docker >/dev/null; then
    su - "${TARGET_USER:-${SUDO_USER:-root}}" -c "cd '$(dirname "$(readlink -f "$0")")' && docker compose down" \
        || warn "compose down failed; continuing anyway"
fi

info "installing nvidia-driver-${TARGET}"
apt-get update || warn "apt update reported errors (likely the dead webupd8team PPA); continuing"
apt-get install -y "nvidia-driver-${TARGET}"

ok "driver ${TARGET} installed"
echo
echo "${c_warn}REBOOT REQUIRED.${c_off} The running kernel still has 535 loaded."
echo
echo "  sudo reboot"
echo
echo "After the reboot, verify with:"
echo "  nvidia-smi                       # expect Driver Version: ${TARGET}.x"
echo "  cd $(dirname "$(readlink -f "$0")")"
echo "  docker compose up -d             # if not already back up"
echo "  docker compose exec ollama ollama run qwen3.5:27b 'hi'"
echo "  docker compose exec ollama ollama ps    # expect 100% GPU, not 100% CPU"
