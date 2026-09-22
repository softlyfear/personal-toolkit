# claude-auto-ping

> Sends Claude Code one short message on a schedule (MSK: **07:00, 12:01, 17:02, 22:03**) — each one opens
> a new **5-hour subscription session window**. No API key needed.

Every `claude -p` call is a new session, so the window starts over. Pings run with
`--no-session-persistence`: sessions are not written to `~/.claude` and don't pile up.

---

## Install — automatic (use this one)

One command does everything: installs `uv` and the Claude CLI if missing, fetches the four files this tool
actually needs into `~/.local/share/claude-auto-ping` (override with `CLAUDE_AUTO_PING_DIR`) — no repository
clone — sends a test ping, sets up the systemd user unit with linger, then verifies all of it. Run it as
your normal user, **never root**:

```bash
bash <(wget -qO- https://raw.githubusercontent.com/softlyfear/personal-toolkit/main/cli/claude-auto-ping/install.sh)
```

It runs in two steps, the same command both times, because the interactive login is the one thing it cannot
do for you:

1. **Tools and login.** Installs `uv` and the Claude CLI, then sends one real message to check the login.
   If the CLI is not logged in, it prints what `claude` said and stops right there — nothing downloaded,
   nothing installed, exit code 0. Run `claude`, log in, go to step 2.
2. **Application and unit.** Re-run the same command: it fetches the files, renders the unit, enables
   linger and prints the checks.

Re-running is also how you update: it refetches the four files and restarts the unit.

Expected tail of a finished run:

```
[OK]    Test ping delivered
[OK]    Unit installed and started
[OK]    check: unit enabled
[OK]    check: unit active
[OK]    check: linger enabled (survives logout and reboot)
[OK]    check: schedule armed — next ping 17.09 22:03 MSK
```

## Install — manual (only from a clone)

Nothing here is needed if the installer above finished. This path exists for developing on a clone, where
you want the repository copy running rather than the fetched one.

**1. Claude CLI, logged in once, interactively:**

```bash
curl -fsSL https://claude.ai/install.sh | bash   # installs to ~/.local/bin/claude
claude                                            # log in: subscription
claude -p "hi" --model haiku                      # check: must reply
```

**2. Dependencies and a test message:**

```bash
cd cli/claude-auto-ping
uv sync                 # creates .venv
uv run main.py --once   # check: one message now, then exit
```

**3. The systemd user unit.** It goes to `~/.config/systemd/user/` — the system is untouched, no root
needed. `@reboot` in crontab won't do: `configuring_server.sh` from this repository restricts cron to root
only.

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

---

## Logs

Two sources with the same lines: stdout goes to journald, and the same formatter writes `ping.log` next to
`main.py` — `~/.local/share/claude-auto-ping/` after the installer, the project directory when run from a
clone.

```bash
systemctl --user status claude-auto-ping                     # state plus the last few lines
journalctl --user -u claude-auto-ping -f                     # follow
journalctl --user -u claude-auto-ping --no-pager             # everything journald still keeps
journalctl --user -u claude-auto-ping -p err --no-pager      # failed pings and missed slots only
journalctl --user -u claude-auto-ping --since "2026-09-17"   # from a date
```

Without `--no-pager` the output opens in `less`: `q` quits, `/window opened` searches.

The file log is capped at 1 MB × 3 and survives reinstalling the unit. `.2` is the oldest part, `.1` the
middle one, the suffixless file is current:

```bash
cd ~/.local/share/claude-auto-ping
ls -l ping.log*               # which parts exist — .1 and .2 appear only after rotation
cat ping.log                  # current
cat ping.log.{2,1} ping.log   # everything, oldest first
```

What the lines mean:

| Line                          | Meaning                                                    |
| ----------------------------- | ------------------------------------------------------------ |
| `window opened in N.Ns`       | Ping delivered, a fresh 5-hour window started              |
| `next ping DD.MM HH:MM MSK`   | Schedule armed, the process is waiting                     |
| `exit N after N.Ns · <text>`  | `claude` refused; the text is its own message              |
| `slot missed: all 3 attempts` | The slot is lost, the next one is still scheduled          |
| `file logging off (<path>)`   | `ping.log` is unwritable — journald is the only copy left  |

Timestamps inside a line are MSK; journald prefixes its own in the host time zone, so on a non-MSK server
the two differ by the offset — expected, the schedule is computed in `Europe/Moscow` either way.

## Without systemd (alternative)

```bash
nohup uv run main.py >/dev/null 2>&1 &   # does not survive a reboot
tmux new -s ping 'uv run main.py'
```

---

## Configuration

All in `main.py`:

| What             | Where                       | Default                           |
| ---------------- | --------------------------- | ----------------------------------- |
| Send slots (MSK) | `SLOTS`                     | `07:00, 12:01, 17:02, 22:03`      |
| Model            | `--model` / `DEFAULT_MODEL` | `haiku` alias — always the latest |
| Message text     | `MESSAGE`                   | `hi`                              |
| Path to claude   | `--claude`                  | `claude` from PATH                |

On failure (network, timeout) — up to 3 attempts, 2 minutes apart. The server time zone doesn't matter: the
schedule is computed in `Europe/Moscow`. A slot missed while the machine was off is skipped, not caught up —
the next ping waits for the following slot.
