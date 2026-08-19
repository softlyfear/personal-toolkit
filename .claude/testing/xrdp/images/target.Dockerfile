# System under test: systemd as PID 1 (jrei/systemd-ubuntu) so add_xfce_xrdp.sh /
# add_gnome_xrdp.sh's own apt-get/ufw/systemctl calls work for real, including a real
# (heavy) desktop-environment install. psmisc (fuser) is a base-OS assumption used by
# wait_for_dpkg_lock(); ca-certificates covers any HTTPS-sourced apt mirror. ufw and the
# desktop/xrdp packages themselves are installed BY the tested script, not preinstalled.
ARG JREI_TAG=latest
FROM jrei/systemd-ubuntu:${JREI_TAG}

RUN apt-get update && apt-get upgrade -y && apt-get install -y --no-install-recommends \
      iproute2 procps psmisc ca-certificates \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
