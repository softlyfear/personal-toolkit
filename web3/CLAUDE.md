# CLAUDE.md — web3/

Read only when the user names a file here — see the `web3/` note in `/.claude/CLAUDE.md`.

`web3/geth+beacon.sh` pins
`GETH_VERSION`/`GETH_ARCHIVE_SHA256` and `PRYSM_VERSION`/`PRYSM_SCRIPT_COMMIT`/`PRYSM_SCRIPT_SHA256`, so
bumping either binary version requires updating its paired hash from the upstream release — the same
lockstep-checksum discipline as the `server-scripts/` installers.
