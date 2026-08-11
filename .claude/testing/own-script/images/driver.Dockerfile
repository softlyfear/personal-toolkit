# Orchestrator: docker CLI + expect, controls target containers over the
# mounted host socket. Never runs configuring_server.sh itself.
FROM debian:12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      expect docker.io ca-certificates coreutils util-linux openssh-client \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /work
