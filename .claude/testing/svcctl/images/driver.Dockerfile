# Orchestrator: docker CLI, controls target containers over the mounted host socket.
# No expect needed — service-manager.sh and install_svcctl.sh take no /dev/tty input.
FROM debian:12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      docker.io ca-certificates coreutils util-linux openssh-client \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /work
