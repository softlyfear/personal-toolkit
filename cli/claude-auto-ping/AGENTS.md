# AGENTS.md — cli/claude-auto-ping

The repository-wide rules are in `/AGENTS.md`.

`claude-auto-ping` is a user-level systemd unit, never root: `cron` is off the
table because `configuring_server.sh` restricts it to root. It sleeps in short wall-clock steps
(`sleep_until`) — a single long `time.sleep()` is monotonic and fires hours late after a suspend.
`cli/claude-auto-ping/install.sh` is the exception to "cli/ runs from a clone": it is Bash, inside
`.codex/lint.sh`, and *is* wget-piped, so it must stay single-file. It fetches only `APP_FILES`
(`main.py`, `pyproject.toml`, `uv.lock`, the unit template) into `~/.local/share/claude-auto-ping` —
**don't turn this back into a `git clone`**, the user removed the full-repo copy on purpose. It
installs nothing as root and asks nothing. The interactive `claude` login is the one step it can't do,
so it runs in two passes of the same command: `verify_login()` sends one real message *before*
anything is downloaded, and a logged-out CLI ends pass 1 with `return 0` and instructions — not an
error, and not a half-installed unit that would fail every slot.

Auth: a saved `/login` dies ~28 days after it was made (fixed refresh-token lifetime), so the
supported credential is a `claude setup-token` token in `~/.config/claude-auto-ping/oauth-token`
(`TOKEN_PATH` in `main.py`, `TOKEN_FILE` in `install.sh` — keep them equal). It goes to `claude` as
`CLAUDE_CODE_OAUTH_TOKEN` in the environment, never argv. Don't add `--bare` to the ping: bare mode
ignores that variable. Auth refusals are matched on `AUTH_FAILURES` text and skip the retries.
