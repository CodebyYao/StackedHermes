#!/usr/bin/env bash
# Runs on every container boot. Keeps all secrets out of the image.
set -euo pipefail

log() { printf '\033[36m[hermes-entrypoint]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[hermes-entrypoint] FATAL:\033[0m %s\n' "$*" >&2; exit 1; }

# --- 1. root password -------------------------------------------------------
if [[ -z "${SSH_PASSWORD:-}" ]]; then
    die "SSH_PASSWORD is not set. Populate it in .env before starting the stack."
fi
echo "root:${SSH_PASSWORD}" | chpasswd
log "root password set from SSH_PASSWORD"

# --- 2. ssh host keys -------------------------------------------------------
# Regenerated only if missing, so the host key stays stable across restarts and
# your client does not scream about a changed fingerprint.
ssh-keygen -A >/dev/null
mkdir -p /run/sshd
touch /var/log/auth.log

# --- 3. seed ~/.hermes/.env (first boot only, never clobber) ----------------
HERMES_HOME=/root/.hermes
mkdir -p "$HERMES_HOME"

if [[ ! -f "$HERMES_HOME/.env" ]]; then
    cat > "$HERMES_HOME/.env" <<EOF
# Seeded by entrypoint.sh on first boot. Edit freely; never overwritten again.
CAMOFOX_URL=${CAMOFOX_URL:-http://camofox:9377}
# Ollama ignores the key, but Hermes' custom (OpenAI-compatible) provider wants one.
OPENAI_API_KEY=ollama
EOF
    chmod 600 "$HERMES_HOME/.env"
    log "seeded $HERMES_HOME/.env"
else
    log "$HERMES_HOME/.env exists, leaving it alone"
fi

# --- 4. seed ~/.hermes/config.yaml (first boot only) ------------------------
if [[ ! -f "$HERMES_HOME/config.yaml" ]]; then
    cat > "$HERMES_HOME/config.yaml" <<'EOF'
# Seeded by entrypoint.sh on first boot. Edit freely; never overwritten again.

# Inference is served by the sibling `ollama` container over its
# OpenAI-compatible endpoint. Set `model:` to something you have pulled:
#   docker compose exec ollama ollama pull <model>
# ...or just run `hermes model` and pick interactively.
model:
  provider: custom
  base_url: http://ollama:11434/v1
  api_key: ${OPENAI_API_KEY}
  model: ""

browser:
  cloud_provider: camofox
  camofox:
    # NOTE: Hermes reads browser.camofox.managed_persistence, NOT a top-level
    # managed_persistence. Wrong placement silently disables it.
    managed_persistence: true
    rewrite_loopback_urls: true
    # Deliberately NOT host.docker.internal: this container must not be able to
    # reach the host. Camofox resolves loopback URLs back to this container.
    loopback_host_alias: hermes-agent
EOF
    log "seeded $HERMES_HOME/config.yaml"
else
    log "$HERMES_HOME/config.yaml exists, leaving it alone"
fi

mkdir -p /workspace

# --- 5. rsyslog + fail2ban --------------------------------------------------
# rsyslog must run first: it is what actually populates /var/log/auth.log from
# sshd's syslog output. The fail2ban sshd jail watches that file, so with no
# rsyslog the jail loads fine but never sees a single failed login.
if rsyslogd 2>/dev/null; then
    log "rsyslog started (sshd auth -> /var/log/auth.log)"
else
    log "WARNING: rsyslog failed to start; fail2ban will not see login attempts"
fi

# Mirror auth.log to stdout so `docker compose logs hermes-agent` still shows
# SSH activity, which we lose by routing sshd through syslog instead of -e.
tail -F /var/log/auth.log 2>/dev/null | sed 's/^/[sshd] /' &

# Best-effort: without NET_ADMIN this fails, and that must not take down sshd.
if fail2ban-server -b >/dev/null 2>&1; then
    log "fail2ban started (sshd jail: 3 tries / 10 min -> 1 h ban)"
else
    log "WARNING: fail2ban failed to start; sshd continues without ban protection"
fi

# --- 6. gateway supervisor --------------------------------------------------
# Starts `hermes gateway` on boot and restarts it whenever it exits. Runs in
# the background; sshd stays PID 1 so container lifecycle is unchanged.
# Note the supervisor is NOT named "hermes*" on purpose -- see the script.
if [ -f /root/.hermes/.gateway-disabled ]; then
    log "gateway is disabled (.gateway-disabled present); not starting supervisor"
else
    nohup /usr/local/bin/gw-supervisor.sh >/dev/null 2>&1 &
    log "gateway supervisor started -- 'gw status' to inspect, 'gw log' to follow"
fi

# --- 7. sshd as PID 1 -------------------------------------------------------
log "starting sshd on port 22 (published to host as ${SSH_PORT:-22022})"
exec /usr/sbin/sshd -D
