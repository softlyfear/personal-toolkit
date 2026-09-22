# dev-tools

> Two unrelated things that both belong to setting up a working environment.

| File                                             | What it is                                                                                 |
| ------------------------------------------------ | ------------------------------------------------------------------------------------------ |
| [`install-dev-tools.sh`](install-dev-tools.sh)  | A wget-piped installer for the packages a new Ubuntu box needs before any work starts      |
| [`Makefile`](Makefile)                           | A template to **copy into a FastAPI project** — not part of this repository's own build    |

---

## install-dev-tools.sh

Installs `git`, `uv`, `make`, `postgresql` and `docker` on Ubuntu (latest LTS). A missing `apt-get` is
fatal; a non-`ubuntu` `/etc/os-release` `ID` only warns. Needs root or `sudo`.

```bash
# everything
bash <(wget -qO- https://raw.githubusercontent.com/softlyfear/personal-toolkit/main/dev-tools/install-dev-tools.sh)

# only these two
bash <(wget -qO- https://raw.githubusercontent.com/softlyfear/personal-toolkit/main/dev-tools/install-dev-tools.sh) git uv

# ask y/N per tool
bash <(wget -qO- https://raw.githubusercontent.com/softlyfear/personal-toolkit/main/dev-tools/install-dev-tools.sh) --interactive

bash <(wget -qO- https://raw.githubusercontent.com/softlyfear/personal-toolkit/main/dev-tools/install-dev-tools.sh) --help
```

No argument means `--all`. `postgres` and `pg` are accepted as aliases for `postgresql`; an unknown name
aborts the run and prints the allowed list.

`--interactive` needs a real terminal, and the check for one happens in `main()` rather than inside the
prompt loop — that loop runs in a process substitution, where `err`'s exit would only kill the subshell and
leave the script exiting 0.

### What each tool actually does

| Tool         | Package                             | Side effects                                                                                              |
| ------------ | ----------------------------------- | --------------------------------------------------------------------------------------------------------- |
| `git`        | `git`                               | —                                                                                                         |
| `uv`         | astral.sh installer                 | Lands in `~/.local/bin`; the script reminds you to have it on `PATH`                                      |
| `make`       | `make`                              | —                                                                                                         |
| `postgresql` | `postgresql`, `postgresql-contrib`  | `systemctl enable --now postgresql`                                                                       |
| `docker`     | `docker.io`                         | `systemctl enable --now docker`, plus `usermod -aG docker` for `$SUDO_USER`/`$USER` — **re-login required** |

`apt-get update` runs at most once per invocation (`apt_update_once`), no matter how many apt-backed tools
were selected.

### The uv installer is deliberately not checksum-pinned

Unlike `install_svcctl.sh` / `install_sysupdate.sh` in `server-scripts/`, which pin the SHA256 of a file
living in this repository, `install_uv()` fetches `https://astral.sh/uv/install.sh` — a third-party script
that changes upstream whenever Astral releases. A pin here would break on every upstream release rather than
catch anything.

What it does instead: downloads to a `mktemp` file, prints a warning naming where the code comes from, runs
`bash -n` on it, and only then executes it. The temp file is removed by a self-clearing `RETURN` trap.

Keep that distinction in mind if this file is ever "hardened" further.

---

## Makefile

A copy-paste template for a FastAPI project using `uv`. It assumes `uv`, `ruff`, `ty`, `pytest` and
optionally `alembic` / `docker compose` **in the target project** — none of those are dependencies of this
repository.

```bash
wget -O Makefile https://raw.githubusercontent.com/softlyfear/personal-toolkit/main/dev-tools/Makefile
make help
```

Then replace the `<PROJECT_NAME>` placeholder on line 3 — it is used as the `docker build` tag and in the
`help` banner. `help` is the default goal, so a bare `make` prints the menu.

| Target                                | Runs                                                                                          |
| ------------------------------------- | ----------------------------------------------------------------------------------------------- |
| `install` · `update`                  | `uv sync` · `uv lock --upgrade && uv sync`                                                     |
| `run`                                 | Applies Alembic migrations when `alembic/` or `alembic.ini` exists, then `python main.py`      |
| `fmt` · `type` · `check`              | `ruff format` + `ruff check --fix` · `ty check` · both                                         |
| `pre-commit`                          | `pre-commit run --all-files`                                                                   |
| `test` · `-v` · `-cov` · `-watch`     | `pytest` variants; `test` fails early with a clear message if `tests/` is missing              |
| `migrate` · `migrate-create`          | Prompt for a message, refuse an empty one, `alembic revision --autogenerate` (+ `upgrade head`) |
| `db-upgrade` · `db-downgrade`         | `alembic upgrade head` · `alembic downgrade -1`                                                |
| `docker-build` · `-up` · `-down` · `-logs` · `-restart` | `docker build` / `docker compose` equivalents                                |
| `clean`                               | Removes `__pycache__`, `.pytest_cache`, `.ruff_cache`, `.mypy_cache`, `htmlcov`, `*.egg-info`, `*.pyc`, `.coverage` |
| `clean-all`                           | `clean` + `rm -rf .venv` + `docker compose down`                                               |

> ⚠️ RISK: `clean-all` stops the Compose services of the project it is run in. Rollback:
> `docker compose up -d`. Named volumes are not removed, so database contents survive.

`test-cov` hardcodes `--cov=app`; change it if the package is not called `app`.

---

## Checks

Before any change to `install-dev-tools.sh` is done:

```bash
bash .claude/lint.sh    # shfmt -d → shellcheck -x -S style → bats
```

Container scenarios for it live in `.claude/testing/devsetup/`.
