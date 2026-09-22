# cli

> Small personal Python tools. Unlike `server-scripts/` and `dev-tools/`, these are **projects, not single
> files**: each is a `uv` project with its own `pyproject.toml` and `uv.lock`.

| Tool                                            | What it does                                                                                            | Install from                | Details                                      |
| ----------------------------------------------- | -------------------------------------------------------------------------------------------------------- | --------------------------- | -------------------------------------------- |
| [`claude-auto-ping`](claude-auto-ping/)        | Sends Claude Code one short message at four fixed times a day, so each opens a fresh 5-hour window       | wget-piped installer        | [README](claude-auto-ping/README.md)         |
| [`pdf-prep`](pdf-prep/)                         | Local PDF toolbox: compress, split into upload-ready parts for a Claude Project, translate               | a clone only                | [README](pdf-prep/README.md)                 |

Each tool's own README has the full story — this file only covers what they share and where they differ.

## What they have in common

- **`uv` manages Python.** No system Python, no `pip install`, no root. Dependencies live in a `.venv`
  inside the tool's own directory.
- **Nothing is installed system-wide.** `claude-auto-ping` uses a *user* systemd unit in
  `~/.config/systemd/user/`; `pdf-prep` drops a launcher into `~/.local/bin/`. Neither asks for `sudo`.
- **Claude by default, no API key.** Both drive the `claude` CLI on your subscription. `pdf-prep` can use
  API providers instead, and then reads the key from an environment variable only — never a flag or a file.
- **Nothing private is committable.** `.venv`, `__pycache__`, `*.log` and rotated `*.log.[0-9]` are
  gitignored. The rotated-log rule is separate on purpose: `*.log` does not match `ping.log.1`.

## How they differ

### claude-auto-ping — non-packaged

`package = false`, so `main.py` is run directly by the systemd unit. Its `install.sh` is the exception to
"`cli/` runs from a clone": it is wget-piped, so it must stay single-file, and it fetches only the four
files the tool needs (`main.py`, `pyproject.toml`, `uv.lock`, the unit template) into
`~/.local/share/claude-auto-ping`. It never clones the repository.

Because the interactive `claude` login is the one thing it cannot do for you, it runs as two passes of the
same command: a logged-out CLI ends pass 1 with instructions and exit code 0 — not with a half-installed
unit that would fail every slot.

### pdf-prep — packaged

Hatchling, `src/pdfprep/`, a `pdf-prep` console script, because the launcher needs an entry point. Its
`install.sh` refuses a wget-piped invocation outright: it resolves the project directory from
`BASH_SOURCE[0]`, so it only works from a copy on disk. `task/`, `result/`, `.work/` and `config.toml` are
gitignored so that your own documents cannot end up in a commit.

> **Why systemd and not cron?** `configuring_server.sh` from `server-scripts/` restricts `cron` and `at` to
> root — which is exactly why `claude-auto-ping` is a systemd *user* unit with linger enabled.

## Checks

Python, so `.claude/lint.sh` and `.claude/RULES.md` do not apply here — with one exception, the two
`install.sh` files, which are Bash and *are* inside the gate.

```bash
uvx ruff format --check
uvx ruff check
bash .claude/lint.sh      # covers cli/*/install.sh
```
