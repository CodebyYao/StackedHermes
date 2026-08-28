#!/usr/bin/env bash
#
# One-time host preparation for the Hermes stack:
#   1. Docker Engine + Compose plugin
#   2. NVIDIA Container Toolkit (GPU passthrough)
#   3. DOCKER-USER firewall rule isolating the agent network from this host
#
# Idempotent — safe to re-run.
#
# Usage:  sudo ./install-prereqs.sh
set -euo pipefail

# The user who will run `docker compose` (added to the docker group).
# Defaults to whoever invoked sudo. Override:  TARGET_USER=alice sudo -E ./install-prereqs.sh
TARGET_USER="${TARGET_USER:-${SUDO_USER:-$(logname 2>/dev/null || echo root)}}"

# Must match HERMES_SUBNET / HERMES_GATEWAY in .env (and therefore the
# hermes-net block in docker-compose.yml). Read from .env when present so the
# firewall rule and the Docker network can never drift apart.
ENV_FILE="$(dirname "$(readlink -f "$0")")/.env"
if [ -f "$ENV_FILE" ]; then
    HERMES_SUBNET=$(grep -E '^HERMES_SUBNET=' "$ENV_FILE" | cut -d= -f2- | tr -d '"' || true)
    HERMES_GATEWAY=$(grep -E '^HERMES_GATEWAY=' "$ENV_FILE" | cut -d= -f2- | tr -d '"' || true)
fi
HERMES_SUBNET="${HERMES_SUBNET:-172.28.0.0/16}"
HERMES_GATEWAY="${HERMES_GATEWAY:-172.28.0.1}"

c_info=$'\033[36m'; c_ok=$'\033[32m'; c_warn=$'\033[33m'; c_err=$'\033[31m'; c_off=$'\033[0m'
info() { echo "${c_info}==>${c_off} $*"; }
ok()   { echo "${c_ok}  ok${c_off} $*"; }
warn() { echo "${c_warn}  !!${c_off} $*"; }
die()  { echo "${c_err}FATAL:${c_off} $*" >&2; exit 1; }

# Many machines carry a stale third-party apt repo that 404s (an abandoned PPA,
# a repo for an older Ubuntu release, ...). A broken *unrelated* repo must not
# abort this install: apt still refreshes every repo that works, and the
# `apt-get install` calls below are the real gate — they fail loudly if a
# package is genuinely unavailable. Failing repos are named so you can fix them.
apt_update() {
    local log rc
    log=$(mktemp)
    set +e
    apt-get update 2>&1 | tee "$log"
    rc=${PIPESTATUS[0]}
    set -e

    if [[ $rc -ne 0 ]]; then
        warn "apt-get update reported errors from these repositories:"
        grep -oP "^E: The repository '\K[^']+" "$log" | sed 's/^/       /' || true
        warn "continuing — package installs below will fail loudly if anything is truly missing"
        echo "       to silence these permanently, disable the dead repo, e.g.:"
        grep -oP "^E: The repository '\K[^ ]+" "$log" \
            | sed 's#.*/\([^/]*\)/ubuntu.*#       mv /etc/apt/sources.list.d/*\1* /root/#' \
            | sort -u || true
    fi
    rm -f "$log"
}

[[ $EUID -eq 0 ]] || die "must run as root:  sudo $0"
command -v nvidia-smi >/dev/null || die "nvidia-smi not found — install the NVIDIA driver first"

. /etc/os-release
[[ "${ID}" == "ubuntu" ]] || warn "expected Ubuntu, found ${ID} — continuing anyway"
info "host: ${PRETTY_NAME} (${VERSION_CODENAME})"

# ---------------------------------------------------------------------------
# 1. Docker Engine
# ---------------------------------------------------------------------------
if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
    ok "Docker + Compose plugin already installed ($(docker --version))"
else
    info "installing Docker Engine"
    apt_update
    apt-get install -y ca-certificates curl gnupg

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable
EOF

    apt_update
    apt-get install -y docker-ce docker-ce-cli containerd.io \
                       docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
    ok "Docker installed: $(docker --version)"
fi

# ---------------------------------------------------------------------------
# 2. NVIDIA Container Toolkit
# ---------------------------------------------------------------------------
if command -v nvidia-ctk >/dev/null; then
    ok "NVIDIA Container Toolkit already installed ($(nvidia-ctk --version | head -1))"
else
    info "installing NVIDIA Container Toolkit"
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        > /etc/apt/sources.list.d/nvidia-container-toolkit.list

    apt_update
    apt-get install -y nvidia-container-toolkit
    ok "toolkit installed"
fi

info "wiring the nvidia runtime into Docker"
nvidia-ctk runtime configure --runtime=docker
systemctl restart docker
ok "docker restarted with nvidia runtime"

# ---------------------------------------------------------------------------
# 3. docker group
# ---------------------------------------------------------------------------
if id -nG "$TARGET_USER" | grep -qw docker; then
    ok "${TARGET_USER} already in the docker group"
else
    usermod -aG docker "$TARGET_USER"
    ok "added ${TARGET_USER} to the docker group (needs a re-login)"
    NEEDS_RELOGIN=1
fi

# ---------------------------------------------------------------------------
# 4. Host isolation for the agent network
#
# Docker's bridge rules already stop the agent from reaching other containers'
# host-published loopback ports. But a container can still reach the HOST itself
# via the bridge gateway ($HERMES_GATEWAY) — SSH, Portainer, anything bound there.
# This closes that last gap while leaving outbound internet intact.
# ---------------------------------------------------------------------------
info "installing DOCKER-USER rule: ${HERMES_SUBNET} -/-> host ${HERMES_GATEWAY}"

iptables -C DOCKER-USER -s "$HERMES_SUBNET" -d "$HERMES_GATEWAY" \
    -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN 2>/dev/null \
  || iptables -I DOCKER-USER 1 -s "$HERMES_SUBNET" -d "$HERMES_GATEWAY" \
        -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN

iptables -C DOCKER-USER -s "$HERMES_SUBNET" -d "$HERMES_GATEWAY" -j DROP 2>/dev/null \
  || iptables -I DOCKER-USER 2 -s "$HERMES_SUBNET" -d "$HERMES_GATEWAY" -j DROP

ok "rule installed"

# The INPUT chain catches traffic addressed to the host that never traverses
# DOCKER-USER (which only sees FORWARDed packets).
iptables -C INPUT -s "$HERMES_SUBNET" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
  || iptables -I INPUT 1 -s "$HERMES_SUBNET" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -C INPUT -s "$HERMES_SUBNET" -j DROP 2>/dev/null \
  || iptables -I INPUT 2 -s "$HERMES_SUBNET" -j DROP
ok "INPUT chain hardened against ${HERMES_SUBNET}"

info "persisting iptables rules across reboots"
DEBIAN_FRONTEND=noninteractive \
    debconf-set-selections <<< 'iptables-persistent iptables-persistent/autosave_v4 boolean false'
DEBIAN_FRONTEND=noninteractive \
    debconf-set-selections <<< 'iptables-persistent iptables-persistent/autosave_v6 boolean false'
DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent
netfilter-persistent save
ok "rules saved"

# ---------------------------------------------------------------------------
# 5. Verify GPU passthrough end to end
# ---------------------------------------------------------------------------
# Uses a -base image (small) purely to prove the runtime wiring works. Pick a
# CUDA major your driver supports; see the README's compatibility table.
VERIFY_IMAGE="${VERIFY_IMAGE:-nvidia/cuda:12.6.3-base-ubuntu24.04}"
info "verifying GPU passthrough (pulls $VERIFY_IMAGE)"
if docker run --rm --gpus all "$VERIFY_IMAGE" nvidia-smi -L; then
    ok "GPUs visible inside containers"
else
    die "GPU passthrough check failed — inspect 'docker run --gpus all' output above"
fi

echo
echo "${c_ok}All prerequisites installed.${c_off}"
if [[ -n "${NEEDS_RELOGIN:-}" ]]; then
    echo
    echo "${c_warn}One more step:${c_off} ${TARGET_USER} was added to the 'docker' group."
    echo "Log out and back in, or run:  newgrp docker"
fi
echo
echo "Next:"
echo "  cd $(dirname "$(readlink -f "$0")")"
echo "  docker compose up -d --build"
