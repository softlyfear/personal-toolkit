# claude-auto-ping

Sends Claude Code one short message on a schedule (MSK: **07:00, 12:01, 17:02, 22:03**) — each one
opens a new **5-hour subscription session window**. No API key needed.

Every `claude -p` call is a new session, so the window starts over. Pings run with
`--no-session-persistence`: sessions are not written to `~/.claude` and don't pile up.

## Install on a server (one line)

Run as your normal user, never root. Installs `uv` and the Claude CLI if missing, fetches the four
files this tool actually needs into `~/.local/share/claude-auto-ping` (override with
`CLAUDE_AUTO_PING_DIR`) — no repository clone — sends a test ping, sets up the systemd user unit with
linger, then verifies all of it:

```bash
bash <(wget -qO- https://raw.githubusercontent.com/softlyfear/personal-toolkit/main/cli/claude-auto-ping/install.sh)
```

It runs in two steps, same command both times, because the interactive login is the one thing it
cannot do for you:

1. **Tools and login.** Installs `uv` and the Claude CLI, then sends one real message to check the
   login. If the CLI is not logged in, it prints what `claude` said and stops right there — nothing
   is downloaded, nothing is installed, exit code 0. Run `claude`, log in, go to step 2.
2. **Application and unit.** Re-run the same command: it fetches the files, renders the unit, enables
   linger and prints the checks.

Re-running is also how you update: it refetches the four files and restarts the unit.

## Prerequisites (manual setup)

Claude CLI installed and logged in (once, interactively):

```bash
curl -fsSL https://claude.ai/install.sh | bash   # installs to ~/.local/bin/claude
claude                                            # log in: subscription
claude -p "hi" --model haiku                      # check: must reply
```

## Setup

```bash
cd cli/claude-auto-ping
uv sync                 # creates .venv
uv run main.py --once   # check: one message now, then exit
```

## Start on boot (systemd user unit)

The unit goes to `~/.config/systemd/user/` — the system is untouched, no root needed.
`@reboot` in crontab won't do: `configuring_server.sh` from this repository restricts cron to
root only.

```bash
cd cli/claude-auto-ping
mkdir -p ~/.config/systemd/user
UV_BIN="$(command -v uv)"
sed "s|__DIR__|$PWD|; s|__UV__|${UV_BIN:?uv not found in PATH}|" \
  claude-auto-ping.service.in > ~/.config/systemd/user/claude-auto-ping.service
systemctl --user daemon-reload
systemctl --user enable --now claude-auto-ping
loginctl enable-linger   # the unit starts after a reboot without a manual login
```

Status and logs:

```bash
systemctl --user status claude-auto-ping
journalctl --user -u claude-auto-ping -f   # also in ping.log next to the script (rotated, 1 MB × 3)
```

## Without systemd (alternative)

```bash
nohup uv run main.py >/dev/null 2>&1 &   # does not survive a reboot
tmux new -s ping 'uv run main.py'
```

## Configuration

All in `main.py`:

| What             | Where                       | Default                           |
| ---------------- | --------------------------- | --------------------------------- |
| Send slots (MSK) | `SLOTS`                     | `07:00, 12:01, 17:02, 22:03`      |
| Model            | `--model` / `DEFAULT_MODEL` | `haiku` alias — always the latest |
| Message text     | `MESSAGE`                   | `hi`                              |
| Path to claude   | `--claude`                  | `claude` from PATH                |

On failure (network, timeout) — up to 3 attempts, 2 minutes apart. The server time zone doesn't
matter: the schedule is computed in `Europe/Moscow`. A slot missed while the machine was off is
skipped, not caught up — the next ping waits for the following slot.
