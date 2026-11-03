# System under test: systemd as PID 1 (jrei/systemd-ubuntu) so the script's own
# systemctl/ufw/fail2ban calls work. No docker CLI or socket access — controlled
# externally via `docker exec`. sudo/openssh-server/ufw/fail2ban are NOT
# preinstalled — the tested script installs them itself.
ARG JREI_TAG=latest
FROM jrei/systemd-ubuntu:${JREI_TAG}

# Upgrade base packages at BUILD time, not container runtime: upgrading systemd itself
# while it's running as PID 1 kills the container (postinst restarts/reexecs it). The
# tested script's own `apt-get upgrade -y` still runs for real inside the container —
# this just keeps it from landing on systemd specifically.
RUN apt-get update && apt-get upgrade -y && apt-get install -y --no-install-recommends \
      iproute2 procps \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
