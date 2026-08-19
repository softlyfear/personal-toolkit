# System under test: systemd as PID 1 (jrei/systemd-ubuntu). wget/sudo preinstalled as
# base-OS utilities (a real target VPS has these already; install_sysupdate.sh only
# checks for them, it doesn't install them). snap/flatpak are intentionally NOT
# preinstalled — update_system_all.sh's "not found, skipping" branches are the
# realistic default for a minimal server image.
# ca-certificates is likewise a base-image assumption: --no-install-recommends means
# wget's usual Recommends: ca-certificates does NOT pull it in automatically, and the
# jrei/systemd-ubuntu base does not ship it preinstalled — without it, wget's HTTPS
# fetch of update_system_all.sh from raw.githubusercontent.com fails with a
# certificate-trust error. Every real cloud VPS image ships ca-certificates already;
# this is purely a minimal-image gap.
ARG JREI_TAG=latest
FROM jrei/systemd-ubuntu:${JREI_TAG}

RUN apt-get update && apt-get upgrade -y && apt-get install -y --no-install-recommends \
      iproute2 procps wget sudo ca-certificates \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
