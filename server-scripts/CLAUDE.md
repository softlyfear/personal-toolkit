# CLAUDE.md — server-scripts/

Loaded when work touches this directory; the repository-wide rules are in `/.claude/CLAUDE.md`.

## Checksum pinning — update in lockstep

Two installer scripts pin a SHA256 of the script they fetch and install to `/usr/local/bin`:

- `server-scripts/install_svcctl.sh` pins the checksum of `server-scripts/service-manager.sh` (installs as
  `svcctl`)
- `server-scripts/install_sysupdate.sh` pins the checksum of `server-scripts/update_system_all.sh` (installs
  as `sysupdate`)

**Any edit to `service-manager.sh` or `update_system_all.sh` requires recomputing and updating
`EXPECTED_SHA256` in the corresponding `install_*.sh`**, or the installer will fail closed (by design — this
is a supply-chain integrity check, not a bug). Recompute with:

```bash
sha256sum server-scripts/service-manager.sh
sha256sum server-scripts/update_system_all.sh
```

Both installers also validate `EXPECTED_SHA256` itself against `^[[:xdigit:]]{64}$` before comparing, and run
`bash -n` on the downloaded script before installing it.

## `configuring_server.sh` — architecture notes

The flagship script: a full VPS hardening flow (`server-scripts/configuring_server.sh`). Key structural
points to preserve when modifying it:

- **Execution order matters and is documented in the header**: system update → SSH/sudo user hardening → UFW
  → Fail2Ban → sysctl → journald → cron/at → final cleanup. SSH hardening happens before the firewall is
  locked down; the new user's key is verified (`verify_ssh_authorized_key`) *before* root login is disabled,
  so a bad key can't lock the operator out.
- **Rollback via `trap rollback_on_failure EXIT`**: every risky mutation (sshd config, sudoers, UFW rules,
  Fail2Ban config, `ssh.socket` mask/disable, `ssh.service` enablement) records enough state (`ROLLBACK_*`
  globals) to be undone if the
  script exits before `SCRIPT_SUCCEEDED=true` is set. If you add a new mutating step before that point, add
  matching rollback state and handle it in `rollback_on_failure()`. **Set the `ROLLBACK_*` flag before the
  first mutation it guards, not after the last one** — the UFW step used to set `ROLLBACK_UFW_MODIFIED=true`
  only after `ufw --force enable`, which left the whole block unprotected on failure. UFW is rolled back by
  restoring `UFW_STATE_FILES` (`user.rules`, `user6.rules`, `ufw.conf`, `/etc/default/ufw`), because
  `ufw delete` has no inverse.
- **`ufw_enforce_single_open_port()` asks before touching rules the script did not write.**
  `ufw_rule_is_ours()` claims only its own `LIMIT` rules on other `N/tcp` ports and the blanket `ALLOW` on
  `22/tcp` that `add_*_xrdp.sh` leaves; anything else (an operator's 80/443, a bare `80`, udp, ranges,
  app profiles) needs an explicit yes. This was verified the hard way — the earlier
  `ufw_prune_stale_ssh_limit_rules()` silently deleted 80/tcp and 443/tcp on a re-run. `UFW_NUMBERED_RULE_RE`
  parses every rule shape, not only `N/tcp`: the narrower regex let a bare `ufw allow 80` slip past both the
  prompt and the "only SSH open" summary. The SSH `LIMIT` rule is re-checked after `ufw --force enable` and
  its absence is fatal (rollback still armed).
- **`--confirm-window MINUTES`** arms `hardening-autorevert.timer` before the first access-affecting change; it
  restores the pre-hardening `/etc/ssh` *and* UFW rules/state from the same snapshot (not a blanket
  `ufw disable`, which would open everything the operator had closed) unless the operator runs
  `/usr/local/sbin/hardening-confirm`. `rearm_lockout_autorevert()` restarts the timer after each prompt and
  before the final summary, so time spent answering prompts never eats the window. It is the only mechanism
  that recovers a server nobody can log into — the printed "test in a new terminal" warning is advice, not
  recovery.
- **`save_user_credentials()`** mirrors the password into `/root/.<user>-credentials` (mode 600). An
  auto-generated password otherwise exists only in the operator's scrollback, which strands a reachable
  server with unusable sudo.
- **`SCRIPT_SUCCEEDED=true` is set before the final cleanup steps** (removing the provider's default user,
  clearing password history), not at the very end of the script. This is intentional: those steps run after
  all critical hardening has already succeeded, so their failure must not roll back working SSH/UFW/Fail2Ban
  config — it's surfaced instead as a non-zero exit *after* `print_final_summary` has already shown the
  operator their credentials and reconnect command.
- `is_reserved_username()` rejects `root` as the sudo username (checked in both the interactive prompt and
  `--user`). This isn't cosmetic: `PermitRootLogin no` blocks root SSH regardless of `AllowUsers`, so allowing
  `root` here would let the script "succeed" while leaving the operator with no working account.
  `ensure_sudo_user()` also requires an explicit confirmation before granting sudo/SSH access to an *existing*
  system account (uid < 1000), to avoid silently escalating a service account.
- `remove_provider_default_user()` (removes the cloud provider's default account, e.g. `user`) retries
  `pkill` → `pkill -9` → `userdel -rf`, verifying via `id` that the account is actually gone rather than
  trusting a single command's exit code. Keep `pkill` *before* `userdel`: `userdel -f` succeeds with the
  account's processes still alive, and they keep a uid the next `useradd` may reuse. It refuses (return 1,
  manual-removal hint at exit) when `SUDO_USER`/`logname` is that account — `pkill` would kill the operator's
  own session and the script before the summary shows the credentials. `whoami` is useless here (always root).
- Functions are grouped by section banners (`UI`, prompts, SSH keys, network/systemd, rollback, users, sshd,
  other services) — keep new functions under the matching banner rather than appending at the end.
- `verify_ssh_port_available`, `verify_sshd_port`, and `verify_ssh_ipv4_only` re-check the *effective* runtime
  config via `sshd -T` after writing config, rather than trusting the written file — don't replace these with
  static file checks.
- All inline comments in this file are in English (see "Language convention" in `/.claude/CLAUDE.md`) — e.g. the rationale for
  the `00-hardening.conf` drop-in ordering. Don't reintroduce Russian comments here.
