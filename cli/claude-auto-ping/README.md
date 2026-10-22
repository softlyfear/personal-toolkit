# claude-auto-ping

A Claude subscription counts usage in **5-hour windows**, and a window starts with your first message.
This tool sends Claude one short message four times a day, so a fresh window is already running when you
sit down to work.

- Sends at **07:00, 12:01, 17:02, 22:03 Moscow time**, whatever time zone the server is in.
- Runs in the background on a Linux server and starts again by itself after a reboot.
- Uses your Claude subscription. You don't need an API key or root.

---

## Install in 3 steps

Log in to the server over SSH as your **normal user, not root**.

**1. Run the installer.**

```bash
bash <(wget -qO- https://raw.githubusercontent.com/softlyfear/personal-toolkit/main/cli/claude-auto-ping/install.sh)
```

On the first run it installs the Claude CLI and `uv`. Then it stops with a message asking for a login.
That stop is expected and is not an error.

**2. Give it a login token.**

```bash
claude setup-token
```

It prints a link. Open it in a browser on any computer, sign in to your Claude account, and paste the
code back into the terminal. It prints a long token. Save it to a file that only
you can read:

```bash
mkdir -p ~/.config/claude-auto-ping
(umask 077 && cat > ~/.config/claude-auto-ping/oauth-token)
```

Paste the token, press **Enter**, then **Ctrl-D**.

**3. Run the same installer command again.**

```bash
bash <(wget -qO- https://raw.githubusercontent.com/softlyfear/personal-toolkit/main/cli/claude-auto-ping/install.sh)
```

It sends a test message, sets up the background service and checks it. A successful run ends like this:

```
[OK]    check: unit enabled
[OK]    check: unit active
[OK]    check: linger enabled (survives logout and reboot)
[OK]    check: schedule armed — next ping 22.10 22:03 MSK
```

That's it. You can close the SSH session now.

> **Why a token and not the normal `claude` login?** The normal login stops working after about four
> weeks, and every ping fails from then on. The `setup-token` token is made for servers and lasts much
> longer.

---

## Is it working?

```bash
journalctl --user -u claude-auto-ping -n 20 --no-pager
```

| You see                     | Meaning                                                    |
| --------------------------- | ---------------------------------------------------------- |
| `window opened in 3.9s`     | A message went through and a new window has started.       |
| `next ping 22.10 22:03 MSK` | Waiting for the next send time.                            |
| `attempt 1/3 failed`        | A temporary error. It retries in 2 minutes, up to 3 times. |
| `login is dead, no retry`   | The token stopped working. See below.                      |
| `slot missed`               | This send was lost. The next one is still scheduled.       |

To watch it live, run `journalctl --user -u claude-auto-ping -f` (Ctrl-C to quit). To list only the
failures, run `journalctl --user -u claude-auto-ping -p err --no-pager`.

## Common problems

**`login is dead` or `Failed to authenticate` in the log.** The token has expired or was revoked. Repeat
step 2 and overwrite the file. You don't need to restart anything: the new token is used from the next
send.

**`... is readable by others — chmod 600 it`.** The token file has open permissions. Fix them with:

```bash
chmod 600 ~/.config/claude-auto-ping/oauth-token
```

**`Not logged in`.** The token file is missing. Do step 2.

**Nothing in the log after a reboot.** Run `loginctl enable-linger` once, then run the installer again.

## Update, renew, remove

- **Update to the latest version:** run the installer command again.
- **Renew the token:** repeat step 2.
- **Remove it completely:**

  ```bash
  systemctl --user disable --now claude-auto-ping
  rm ~/.config/systemd/user/claude-auto-ping.service
  rm -rf ~/.local/share/claude-auto-ping ~/.config/claude-auto-ping
  ```

---

## Settings

Change them at the top of `~/.local/share/claude-auto-ping/main.py`, then run
`systemctl --user restart claude-auto-ping`. Running the installer again overwrites your edits.

| What                 | Where                       | Default                                  |
| -------------------- | --------------------------- | ---------------------------------------- |
| Send times (MSK)     | `SLOTS`                     | `07:00, 12:01, 17:02, 22:03`             |
| Model                | `--model` / `DEFAULT_MODEL` | `haiku`, which is always the latest one  |
| Message text         | `MESSAGE`                   | `hi`                                     |
| Token file           | `--token-file`              | `~/.config/claude-auto-ping/oauth-token` |
| Path to `claude`     | `--claude`                  | `claude` from `PATH`                     |

A send time missed while the server was off is skipped, not sent late.

<details>
<summary><b>Technical details</b></summary>

### What the installer does

It installs `uv` and the Claude CLI if they are missing. It downloads only the four files the tool needs
(`main.py`, `pyproject.toml`, `uv.lock`, the unit template) into `~/.local/share/claude-auto-ping`, and
you can change that path with `CLAUDE_AUTO_PING_DIR`. It doesn't clone the repository. It installs a
systemd **user** unit in `~/.config/systemd/user/` and turns on linger so the unit keeps running after
logout. Nothing is installed system-wide.

The login check in step 1 sends one real message, so it already starts a window.

### How the token is used

`main.py` reads the token file before every send and passes it to `claude` as the environment variable
`CLAUDE_CODE_OAUTH_TOKEN`. It never puts the token on the command line, where `ps` would show it. A file
readable by group or others is refused. Without the file, the saved `claude` login in `~/.claude` is used.
The token can only send model requests, and a ping needs nothing more.

Each send is a new session (`claude -p`) that loads no tools or project context and is not saved in
`~/.claude`.

### Log file

The log also goes to `~/.local/share/claude-auto-ping/ping.log`, with the same lines as the journal. The
file is capped at 1 MB × 3: `ping.log` is current, `.1` is older and `.2` is the oldest. Times inside a
line are always MSK. The journal adds its own prefix in the server's time zone, so the two can differ.

```bash
cat ~/.local/share/claude-auto-ping/ping.log.{2,1} ~/.local/share/claude-auto-ping/ping.log 2>/dev/null
```

### Running from a clone (for development)

```bash
cd cli/claude-auto-ping
uv sync
uv run main.py --once   # one message now, then exit
mkdir -p ~/.config/systemd/user
UV_BIN="$(command -v uv)"
sed "s|__DIR__|$PWD|; s|__UV__|${UV_BIN:?uv not found in PATH}|" \
  claude-auto-ping.service.in > ~/.config/systemd/user/claude-auto-ping.service
systemctl --user daemon-reload
systemctl --user enable --now claude-auto-ping
loginctl enable-linger
```

A user unit is used instead of cron because `configuring_server.sh` from this repository limits cron to
root.

</details>
