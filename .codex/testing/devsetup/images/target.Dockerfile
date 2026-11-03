# System under test: systemd as PID 1 (jrei/systemd-ubuntu) so install-dev-tools.sh's
# own systemctl enable/start calls (postgresql, docker) work. No docker CLI or socket
# access — controlled externally via `docker exec`. None of git/uv/make/postgresql/docker
# are preinstalled — the tested script installs them itself. wget IS preinstalled since
# it's a base OS utility on real target VPS images, not something install-dev-tools.sh
# installs itself (it only checks for it via need_cmd before the uv installer runs).
# ca-certificates is likewise a base-image assumption: --no-install-recommends means
# wget's usual Recommends: ca-certificates does NOT pull it in automatically, and the
# jrei/systemd-ubuntu base does not ship it preinstalled — without it, wget's HTTPS
# fetch of the real astral.sh uv installer fails with a certificate-trust error. Every
# real cloud VPS image ships ca-certificates already; this is purely a minimal-image gap.
ARG JREI_TAG=latest
FROM jrei/systemd-ubuntu:${JREI_TAG}

RUN apt-get update && apt-get upgrade -y && apt-get install -y --no-install-recommends \
      iproute2 procps wget ca-certificates \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
