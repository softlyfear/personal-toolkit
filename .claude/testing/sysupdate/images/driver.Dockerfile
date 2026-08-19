# Orchestrator: docker CLI, controls target containers over the mounted host socket.
# No expect needed — update_system_all.sh and install_sysupdate.sh take no /dev/tty input.
# CLI comes from the upstream image: the distro package ships API 1.41, which
# Docker Engine >= 26 refuses.
FROM docker:cli AS dockercli

FROM ubuntu:latest

RUN DEBIAN_FRONTEND=noninteractive apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates coreutils util-linux openssh-client \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

COPY --from=dockercli /usr/local/bin/docker /usr/local/bin/docker

WORKDIR /work
