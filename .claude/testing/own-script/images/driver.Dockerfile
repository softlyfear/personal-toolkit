# Orchestrator: docker CLI + expect, controls target containers over the
# mounted host socket. Never runs configuring_server.sh itself.

# Debian's docker.io package ships CLI 20.10 (API 1.41), which Docker Engine
# >= 26 rejects outright ("client version 1.41 is too old, minimum supported
# API version is 1.44"). Take the CLI binary from the upstream image so the
# harness keeps working against current engines on any host.
FROM docker:cli AS dockercli

FROM debian:12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      expect ca-certificates coreutils util-linux openssh-client \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

COPY --from=dockercli /usr/local/bin/docker /usr/local/bin/docker

WORKDIR /work
