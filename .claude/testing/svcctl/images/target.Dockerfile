# System under test: systemd as PID 1 (jrei/systemd-ubuntu) so service-manager.sh's own
# systemctl calls work. wget/sudo preinstalled as base-OS utilities (a real target VPS
# has these already; install_svcctl.sh only checks for them, it doesn't install them).
# postgresql/docker themselves are NOT preinstalled — scenarios that need a real service
# to manage install it via apt-get as a presetup step.
# ca-certificates is likewise a base-image assumption: --no-install-recommends means
# wget's usual Recommends: ca-certificates does NOT pull it in automatically, and the
# jrei/systemd-ubuntu base does not ship it preinstalled — without it, wget's HTTPS
# fetch of service-manager.sh from raw.githubusercontent.com fails with a
# certificate-trust error. Every real cloud VPS image ships ca-certificates already;
# this is purely a minimal-image gap.
ARG JREI_TAG=26.04
FROM jrei/systemd-ubuntu:${JREI_TAG}

RUN apt-get update && apt-get upgrade -y && apt-get install -y --no-install-recommends \
      iproute2 procps wget sudo ca-certificates \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
