# Hermes Agent container.
#
# Base image: CUDA 12.6.3 on Ubuntu 24.04.
#
# CHANGE ME if your host differs. Pick a tag your NVIDIA driver supports:
#   CUDA 12.x  -> driver >= 525   (12.6.3 is the lowest tag NVIDIA ships for ubuntu24.04)
#   CUDA 13.x  -> driver >= 580
# Check yours with `nvidia-smi`. Choosing a CUDA major newer than your driver
# supports makes the GPU invisible to CUDA workloads inside the container.
#
# Note the actual LLM inference happens in the ollama container, which bundles
# its own CUDA runtime -- this toolkit is here for your own GPU work in the agent.
ARG CUDA_IMAGE=nvidia/cuda:12.6.3-devel-ubuntu24.04
FROM ${CUDA_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Etc/UTC \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
        openssh-server \
        fail2ban \
        rsyslog \
        iptables \
        sudo \
        nano \
        vim \
        less \
        git \
        curl \
        wget \
        ca-certificates \
        gnupg \
        xz-utils \
        zstd \
        unzip \
        build-essential \
        python3 \
        python3-pip \
        python3-venv \
        python3-dev \
        pipx \
        jq \
        ripgrep \
        tmux \
        htop \
        iputils-ping \
        dnsutils \
        net-tools \
        iproute2 \
        rsync \
        locales \
    && rm -rf /var/lib/apt/lists/*

# Ubuntu 24.04 marks the system Python as "externally managed" (PEP 668), so a bare
# `pip install` fails. A venv first on PATH makes pip behave normally for the user.
RUN python3 -m venv /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir --upgrade pip setuptools wheel
ENV PATH="/opt/venv/bin:${PATH}" \
    VIRTUAL_ENV=/opt/venv

# Ollama CLI only. The server runs in its own container; OLLAMA_HOST points there,
# so `ollama list` / `ollama pull` from here operate on the remote daemon.
RUN curl -fsSL https://ollama.com/install.sh | sh \
    && rm -rf /root/.ollama

# Hermes Agent. Running as root on Linux, the installer uses the FHS layout:
#   code    -> /usr/local/lib/hermes-agent
#   command -> /usr/local/bin/hermes
#   data    -> /root/.hermes        <-- mounted as a volume at runtime, so baking the
#                                       install into the image does not get masked.
# --skip-browser omits Playwright/Chromium (~500MB): Camofox is the browser here.
RUN curl -fsSL https://hermes-agent.nousresearch.com/install.sh \
    | bash -s -- --skip-setup --non-interactive --skip-browser --skip-computer-use

# --- sshd -------------------------------------------------------------------
# sshd listens on 22 inside the container; the host port is set by SSH_PORT in
# .env. If you publish it beyond loopback (SSH_BIND=0.0.0.0) this listener is
# reachable from your network, so the tight auth limits and fail2ban below are
# the brute-force defence. Prefer key auth if you expose it -- see the README.
RUN mkdir -p /run/sshd /var/run/fail2ban \
    && printf '%s\n' \
        'PermitRootLogin yes' \
        'PasswordAuthentication yes' \
        'PubkeyAuthentication yes' \
        'PermitEmptyPasswords no' \
        'MaxAuthTries 3' \
        'LoginGraceTime 20' \
        'ClientAliveInterval 60' \
        'ClientAliveCountMax 3' \
        'X11Forwarding no' \
        'PrintMotd no' \
        'AcceptEnv LANG LC_*' \
        > /etc/ssh/sshd_config.d/10-hermes.conf

# fail2ban defaults to reading sshd's systemd journal, which does not exist here.
# Instead: rsyslog (started by entrypoint.sh) writes sshd's auth facility to
# /var/log/auth.log, and the jail watches that file. Without rsyslog running,
# sshd's syslog output goes nowhere and the jail would silently never fire.
RUN sed -i 's|^\(module(load="imklog".*\)|#\1|' /etc/rsyslog.conf \
    && printf '%s\n' \
        '[sshd]' \
        'enabled  = true' \
        'port     = ssh' \
        'backend  = auto' \
        'logpath  = /var/log/auth.log' \
        'maxretry = 3' \
        'findtime = 600' \
        'bantime  = 3600' \
        > /etc/fail2ban/jail.d/hermes-sshd.conf

# An SSH login is a fresh shell that does NOT inherit the Docker `environment:` block,
# so the service endpoints have to live in a profile script to be visible over SSH.
RUN printf '%s\n' \
        'export OLLAMA_HOST=http://ollama:11434' \
        'export OPENAI_BASE_URL=http://ollama:11434/v1' \
        'export CAMOFOX_URL=http://camofox:9377' \
        'export NVIDIA_VISIBLE_DEVICES=all' \
        'export NVIDIA_DRIVER_CAPABILITIES=compute,utility' \
        'export VIRTUAL_ENV=/opt/venv' \
        'export PATH="/opt/venv/bin:/usr/local/bin:$PATH"' \
        'cd /workspace 2>/dev/null || true' \
        > /etc/profile.d/hermes-env.sh \
    && chmod 644 /etc/profile.d/hermes-env.sh

# --- message of the day ------------------------------------------------------
# Shown on SSH login (printed by pam_motd, which is why sshd's PrintMotd stays no).
RUN printf '%s\n' \
        '' \
        '  Hermes Agent container' \
        '  ----------------------' \
        '  Inference : http://ollama:11434   (sibling container)' \
        '  Browser   : http://camofox:9377   (sibling container)' \
        '  Workdir   : /workspace            (persistent volume)' \
        '  Config    : /root/.hermes         (persistent volume)' \
        '' \
        '  gw status | gw log | gw restart   -- manage the Hermes gateway' \
        '' \
        > /etc/motd

# --- gateway supervisor ------------------------------------------------------
# gw-supervisor.sh keeps `hermes gateway` running and restarts it if it dies.
# `gw` is the operator front-end (gw status|start|stop|restart|log).
COPY gw-supervisor.sh /usr/local/bin/gw-supervisor.sh
COPY gw               /usr/local/bin/gw
RUN chmod +x /usr/local/bin/gw-supervisor.sh /usr/local/bin/gw

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /workspace
EXPOSE 22

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
