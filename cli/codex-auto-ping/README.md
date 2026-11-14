# codex-auto-ping

Sends Codex CLI a short message at **06:00, 11:01, 16:02 and 21:03 Moscow time**, matching
`claude-auto-ping`. Uses your saved **ChatGPT login**, without an API key or root.

Runs as a systemd user service on Ubuntu (latest LTS). Logs show whether a request completed;
a successful ping does not prove that a new usage window started or change subscription limits.

## Install

Run as your normal user on the machine that will send the pings:

```bash
bash <(wget -qO- https://raw.githubusercontent.com/user/personal-toolkit/main/cli/codex-auto-ping/install.sh)
```

If Codex is not signed in through ChatGPT, the installer stops successfully before installing a service.
Sign in as that same user, then run the installer again:

```bash
codex login --device-auth
```

Open the printed link in your browser and enter the one-time code. Device login must be enabled for
your account or workspace. If unavailable, use `codex login` and the normal browser flow.
Codex manages its own credentials and refreshes them during use; no Claude-style token file is needed.
See the [official authentication guide](https://learn.chatgpt.com/docs/auth).

The installer checks the login, copies or downloads only four application files, sends one real test
ping, and then installs and starts the service. It enables linger and checks the service and schedule.
If a logged-in account cannot complete the test request, setup fails before installing the unit.
An API-key login is rejected; the tool never falls back to API billing.

## Check it

```bash
systemctl --user status codex-auto-ping
journalctl --user -u codex-auto-ping -n 20 --no-pager
journalctl --user -u codex-auto-ping -f
```

- `next ping … MSK`: the scheduler is waiting.
- `ping sent … input=… output=… reply: OK`: Codex completed a request.
- `attempt … failed`: a temporary failure; up to three attempts, two minutes apart.
- `login needs attention, no retry`: sign in again with `codex login --device-auth`.
- `slot missed`: all attempts failed; the next scheduled slot remains active.

The same lines go to `ping.log` in the application directory, rotating at 1 MB with two backups.
If file logging is unavailable, the journal still receives the logs.

## Update or remove

Re-run the installer to update. It restarts the service after a successful test ping. To remove:

```bash
systemctl --user disable --now codex-auto-ping
rm ~/.config/systemd/user/codex-auto-ping.service
systemctl --user daemon-reload
rm -rf ~/.local/share/codex-auto-ping
```

Your Codex installation and login are kept. `CODEX_AUTO_PING_DIR` changes the application directory;
the systemd unit uses `${XDG_CONFIG_HOME:-~/.config}/systemd/user`. A custom `CODEX_HOME` is retained
in the unit so it uses the same authentication storage as the installer.

## Settings and development

Defaults in `main.py`: `SLOTS` as above, `DEFAULT_MODEL = "gpt-6-luna"`, `MESSAGE = "hi"`.
`--model` selects another available model; `--codex` accepts an explicit executable path.
Model reasoning is `low`. Local changes to installed files are replaced by an update.

From a clone:

```bash
cd cli/codex-auto-ping
uv sync --locked
uv run --locked main.py --once
bash install.sh                       # installs from these local application files
```

Each request uses a fresh temporary directory, `--ephemeral`, `--ignore-user-config`, a read-only
sandbox, a short replacement instruction file, and disabled tools, plugins and skills. It preserves
the normal authentication storage and removes API-key environment variables from the child process.
The CLI still includes some runtime context: this is a small real model request, not a zero-token
keepalive. Input/output token counts are logged. See the
[non-interactive CLI guide](https://learn.chatgpt.com/docs/non-interactive-mode).

No service is installed just by cloning this project or running `--once`.

From the repository root, run the additional Python tests and the shared gate:

```bash
uv run --project cli/codex-auto-ping --with pytest pytest -q .opencode/testing/codex-auto-ping
uvx ruff check .opencode/testing/codex-auto-ping
bash .opencode/lint.sh
```
