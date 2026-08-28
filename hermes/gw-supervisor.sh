#!/usr/bin/env bash
#
# Keeps `hermes gateway` alive inside the container.
#
# NAMING IS DELIBERATE: this file contains no occurrence of the string
# "hermes" in its own path or process name. A workshop participant asking the
# agent to "kill hermes" will produce `pkill -f hermes`, which matches the
# gateway child but NOT this supervisor -- so the supervisor survives and
# restarts it. Do not rename this to hermes-supervisor.sh.
#
# Controlled by the `gw` helper (gw start|stop|status|log).
set -u

LOG=/var/log/hermes-gateway.log
FLAG=/root/.hermes/.gateway-disabled
LOCK=/var/run/gw-supervisor.lock
MAX_LOG_BYTES=$((50 * 1024 * 1024))

# Single instance only. Without this, an entrypoint start plus a manual
# `gw start` would run two gateways and the bot would answer twice.
exec 9>"$LOCK"
if ! flock -n 9; then
    echo "supervisor already running; exiting" >&2
    exit 0
fi

log() { printf '%s [supervisor] %s\n' "$(date -Is)" "$*" >> "$LOG"; }

# Service endpoints (OLLAMA_HOST, CAMOFOX_URL, ...) live here. A background
# process started from the entrypoint inherits them from the container env,
# but sourcing keeps this correct when run by hand from an SSH shell.
[ -r /etc/profile.d/hermes-env.sh ] && . /etc/profile.d/hermes-env.sh

backoff=2
log "supervisor started (pid $$)"

while true; do
    if [ -f "$FLAG" ]; then
        sleep 10
        continue
    fi

    # Crude rotation: this log is unattended and would otherwise fill the disk.
    if [ -f "$LOG" ] && [ "$(stat -c%s "$LOG" 2>/dev/null || echo 0)" -gt "$MAX_LOG_BYTES" ]; then
        mv -f "$LOG" "$LOG.1"
        log "rotated log"
    fi

    log "starting: hermes gateway"
    start=$(date +%s)
    hermes gateway >> "$LOG" 2>&1
    rc=$?
    ran=$(( $(date +%s) - start ))

    # Re-check the flag: `gw stop` kills the gateway, and we must not treat
    # that deliberate kill as a crash worth restarting.
    if [ -f "$FLAG" ]; then
        log "gateway exited rc=$rc after ${ran}s; stop flag set, standing down"
        continue
    fi

    # A run that lasted a while was healthy, so reset the backoff. Otherwise a
    # single crash hours later would inherit a stale 60s delay.
    if [ "$ran" -ge 120 ]; then
        backoff=2
    fi

    log "gateway exited rc=$rc after ${ran}s; restarting in ${backoff}s"
    sleep "$backoff"
    backoff=$(( backoff * 2 ))
    [ "$backoff" -gt 60 ] && backoff=60
done
