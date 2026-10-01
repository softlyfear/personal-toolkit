# CLAUDE.md — dev-tools/

Loaded when work touches this directory; the repository-wide rules are in `/.claude/CLAUDE.md`.

- `install-dev-tools.sh` — installs `git`/`uv`/`make`/`postgresql`/`docker` on apt-based systems, with
  `--all` (default), `--interactive`, or an explicit tool list. `install_uv()` downloads astral.sh's own
  installer to a temp file and runs `bash -n` on it before executing — it is **not** checksum-pinned like
  `service-manager.sh`/`update_system_all.sh` are, since it's a third-party script that changes upstream; keep
  that distinction in mind if asked to "harden" this file further.
- `dev-tools/Makefile` is not part of this repo's own build — it's a template meant to be copied into
  external FastAPI projects (see README "Copy into your project"). It assumes `uv`, `ruff`, `ty`, `pytest`,
  and optionally `alembic`/`docker compose` in the *target* project, not here. `PROJECT_NAME` is a placeholder
  (`<PROJECT_NAME>`) meant to be filled in by whoever copies it.
