# shellcheck shell=bash
# .claude/testing/own-script/scenarios.sh — scenario matrix for configuring_server.sh.
# Source-only, via run.sh (after lib.sh). Ubuntu only, full run only, in a real systemd
# container — even the branches that fail on argument parsing use the same image as the
# end-to-end scenarios.
#
# Prompt line format: "<regexp-pattern><TAB><response>". TAB must be a real 0x09 byte
# (the TAB variable, not "\t" — bash doesn't expand that as an escape outside $'...').
# Patterns are short substrings without ( ) [ ] . * + ? to avoid escaping Tcl regexp
# metacharacters.
set -euo pipefail

readonly TAB=$'\t'
readonly MANUAL_TEST_PASSWORD='Str0ngP@ssword!1'

# --- Verify functions ---

verify_help() { assert_shell "log contains Usage:" "grep -q 'Usage:' '$2'"; }
verify_bad_port() { assert_shell "log contains Invalid SSH port" "grep -q 'Invalid SSH port' '$2'"; }
verify_unknown_flag() { assert_shell "log contains Unknown option" "grep -q 'Unknown option' '$2'"; }
verify_user_root_rejected() { assert_shell "log contains 'root is not allowed'" "grep -q 'root is not allowed' '$2'"; }
verify_password_file_missing() { assert_shell "log contains 'password-file not found'" "grep -q 'password-file not found' '$2'"; }
verify_invalid_key_rsa() { assert_shell "log contains ssh-rsa rejection" "grep -q 'ssh-rsa is not supported' '$2'"; }
verify_inline_private_key() { assert_shell "log contains PRIVATE key rejection (not the generic error)" "grep -q 'This is a PRIVATE key' '$2'"; }

# verify_common_hardening <container> <log> <user> <port> <key|password>
#
# Runs in EVERY scenario expected to finish successfully. The per-scenario verifiers
# below assert only what makes their scenario distinct; this one re-checks the complete
# set of settings configuring_server.sh claims to apply (Steps 2-8 plus the final
# summary), against the live container rather than against the script's own log. A
# scenario therefore only passes when the whole hardening stack actually landed — not
# just the slice that scenario is about.
verify_common_hardening() {
  local name="$1" log="$2" user="$3" port="$4" auth_mode="$5" rc=0
  local cfg
  cfg="$(sshd_effective "${name}")"

  # --- Step 2: security packages ---
  assert_shell "security packages installed (sudo/ufw/fail2ban/unattended-upgrades)" \
    "docker exec ${name} bash -c 'for b in sudo ufw fail2ban-client unattended-upgrade; do command -v \$b >/dev/null || exit 1; done'" || rc=1
  assert_shell "sshd binary present" "docker exec ${name} test -x /usr/sbin/sshd" || rc=1

  # --- Step 3: unattended-upgrades + NTP ---
  assert_shell "20auto-upgrades: unattended upgrades enabled" \
    "docker exec ${name} grep -qF 'APT::Periodic::Unattended-Upgrade \"1\";' /etc/apt/apt.conf.d/20auto-upgrades" || rc=1
  assert_shell "20auto-upgrades: package-list refresh enabled" \
    "docker exec ${name} grep -qF 'APT::Periodic::Update-Package-Lists \"1\";' /etc/apt/apt.conf.d/20auto-upgrades" || rc=1
  assert_shell "51custom: automatic reboot disabled" \
    "docker exec ${name} grep -qF 'Unattended-Upgrade::Automatic-Reboot \"false\";' /etc/apt/apt.conf.d/51custom-unattended-upgrades" || rc=1
  # systemd-timesyncd ships ConditionVirtualization=!container, so inside Docker the unit
  # is enabled but deliberately never started ("skipped, unmet condition check"), which
  # also leaves timedatectl reporting NTP=no; NTPSynchronized=yes there is merely the
  # host clock showing through. The persistent effect the script is responsible for — and
  # the one that actually takes hold on a real VPS — is the unit being enabled.
  assert_shell "time-sync daemon enabled (chrony/chronyd/systemd-timesyncd)" \
    "docker exec ${name} bash -c 'systemctl is-enabled --quiet chrony || systemctl is-enabled --quiet chronyd || systemctl is-enabled --quiet systemd-timesyncd'" || rc=1
  assert_shell "script selected an NTP daemon (not the 'none found' branch)" \
    "grep -q 'NTP daemon:' '${log}'" || rc=1

  # --- Step 4: sshd drop-in, effective config, listener ---
  assert_shell "sshd drop-in 00-hardening.conf written" \
    "docker exec ${name} test -s /etc/ssh/sshd_config.d/00-hardening.conf" || rc=1
  assert_shell "legacy sshd 99-hardening.conf removed" \
    "! docker exec ${name} test -e /etc/ssh/sshd_config.d/99-hardening.conf" || rc=1
  assert_shell "sshd_config backup created" \
    "docker exec ${name} bash -c 'ls /etc/ssh/sshd_config.bak_* >/dev/null 2>&1'" || rc=1
  assert_match "effective port ${port}" "${cfg}" "^port ${port}$" || rc=1
  assert_match "effective AllowUsers ${user}" "${cfg}" "^allowusers ${user}$" || rc=1
  assert_match "PermitRootLogin no" "${cfg}" '^permitrootlogin no$' || rc=1
  assert_match "AddressFamily inet" "${cfg}" '^addressfamily inet$' || rc=1
  assert_match "PermitEmptyPasswords no" "${cfg}" '^permitemptypasswords no$' || rc=1
  assert_match "KbdInteractiveAuthentication no" "${cfg}" '^kbdinteractiveauthentication no$' || rc=1
  assert_match "HostbasedAuthentication no" "${cfg}" '^hostbasedauthentication no$' || rc=1
  assert_match "GSSAPIAuthentication no" "${cfg}" '^gssapiauthentication no$' || rc=1
  assert_match "X11Forwarding no" "${cfg}" '^x11forwarding no$' || rc=1
  assert_match "AllowAgentForwarding no" "${cfg}" '^allowagentforwarding no$' || rc=1
  assert_match "AllowTcpForwarding no" "${cfg}" '^allowtcpforwarding no$' || rc=1
  assert_match "PermitTunnel no" "${cfg}" '^permittunnel no$' || rc=1
  assert_match "PermitUserEnvironment no" "${cfg}" '^permituserenvironment no$' || rc=1
  assert_match "Compression no" "${cfg}" '^compression no$' || rc=1
  assert_match "MaxAuthTries 3" "${cfg}" '^maxauthtries 3$' || rc=1
  assert_match "MaxSessions 3" "${cfg}" '^maxsessions 3$' || rc=1
  assert_match "MaxStartups 10:30:60" "${cfg}" '^maxstartups 10:30:60$' || rc=1
  assert_match "ClientAliveInterval 300" "${cfg}" '^clientaliveinterval 300$' || rc=1
  assert_match "ClientAliveCountMax 2" "${cfg}" '^clientalivecountmax 2$' || rc=1
  assert_match "LoginGraceTime 30" "${cfg}" '^logingracetime 30$' || rc=1
  assert_match "UsePAM yes" "${cfg}" '^usepam yes$' || rc=1
  assert_shell "sshd listening on :${port}" "docker exec ${name} ss -tln | grep -q ':${port} '" || rc=1
  assert_shell "no IPv6 sshd listener on :${port}" \
    "! docker exec ${name} ss -tln | grep -q '\\[::\\]:${port} '" || rc=1
  # On port 22 sshd stays socket-activated, so ssh.service itself may be inactive —
  # accept either the service or the socket being up.
  assert_shell "ssh service or socket active" \
    "docker exec ${name} bash -c 'systemctl is-active --quiet ssh || systemctl is-active --quiet sshd || systemctl is-active --quiet ssh.socket'" || rc=1
  if [[ "${port}" == "22" ]]; then
    assert_shell "ssh.socket left intact on port 22" \
      "docker exec ${name} systemctl is-active --quiet ssh.socket" || rc=1
  else
    assert_shell "ssh.socket masked (port != 22)" \
      "docker exec ${name} bash -c 'systemctl is-enabled ssh.socket 2>&1 | grep -q masked'" || rc=1
  fi

  case "${auth_mode}" in
    key)
      assert_match "AuthenticationMethods publickey" "${cfg}" '^authenticationmethods publickey$' || rc=1
      assert_match "PubkeyAuthentication yes" "${cfg}" '^pubkeyauthentication yes$' || rc=1
      assert_match "PasswordAuthentication no" "${cfg}" '^passwordauthentication no$' || rc=1
      assert_shell "drop-in disables ssh-rsa algorithms" \
        "docker exec ${name} grep -qF 'PubkeyAcceptedAlgorithms -ssh-rsa' /etc/ssh/sshd_config.d/00-hardening.conf" || rc=1
      assert_shell "effective PubkeyAcceptedAlgorithms has no ssh-rsa" \
        "! docker exec ${name} sshd -T | grep '^pubkeyacceptedalgorithms ' | grep -q 'ssh-rsa'" || rc=1
      assert_shell "authorized_keys non-empty for ${user}" \
        "docker exec ${name} test -s /home/${user}/.ssh/authorized_keys" || rc=1
      assert_shell "authorized_keys holds an ed25519 key" \
        "docker exec ${name} grep -q '^ssh-ed25519 ' /home/${user}/.ssh/authorized_keys" || rc=1
      assert_shell ".ssh mode 700" \
        "docker exec ${name} bash -c '[[ \$(stat -c %a /home/${user}/.ssh) == 700 ]]'" || rc=1
      assert_shell "authorized_keys mode 600" \
        "docker exec ${name} bash -c '[[ \$(stat -c %a /home/${user}/.ssh/authorized_keys) == 600 ]]'" || rc=1
      assert_shell "authorized_keys owned by ${user}:${user}" \
        "docker exec ${name} bash -c '[[ \$(stat -c %U:%G /home/${user}/.ssh/authorized_keys) == ${user}:${user} ]]'" || rc=1
      ;;
    password)
      assert_match "AuthenticationMethods password" "${cfg}" '^authenticationmethods password$' || rc=1
      assert_match "PubkeyAuthentication no" "${cfg}" '^pubkeyauthentication no$' || rc=1
      assert_match "PasswordAuthentication yes" "${cfg}" '^passwordauthentication yes$' || rc=1
      assert_shell "password actually set for ${user}" \
        "docker exec ${name} bash -c 'getent shadow ${user} | cut -d: -f2 | grep -vqE \"^[!*]\"'" || rc=1
      ;;
    *)
      err_ "verify_ssh_stack: unknown auth_mode '${auth_mode}'"
      rc=1
      ;;
  esac

  # --- Step 5: UFW ---
  local ufw_verbose
  ufw_verbose="$(docker exec "${name}" ufw status verbose 2> /dev/null || true)"
  assert_match "UFW active" "${ufw_verbose}" '^Status: active' || rc=1
  assert_match "UFW logging on" "${ufw_verbose}" '^Logging: on' || rc=1
  assert_match "UFW default deny in / allow out" "${ufw_verbose}" '^Default: deny \(incoming\), allow \(outgoing\)' || rc=1
  assert_shell "UFW persists across reboot (ENABLED=yes)" \
    "docker exec ${name} grep -q '^ENABLED=yes' /etc/ufw/ufw.conf" || rc=1
  # Exactly one: the v6 twin renders as "<port>/tcp (v6)  LIMIT" and must not match,
  # so a second match here means a duplicated rule, not the IPv6 counterpart.
  assert_shell "exactly one LIMIT rule for ${port}/tcp" \
    "[[ \$(docker exec ${name} ufw status numbered | grep -cE '${port}/tcp[[:space:]]+LIMIT') == 1 ]]" || rc=1
  # The rollback-only UFW backup must not pile up in /root, one dir per run.
  assert_shell "no UFW rollback backup left behind after success" \
    "[[ \$(docker exec ${name} bash -c 'ls -d /root/.ufw-backup_* 2>/dev/null | wc -l') == 0 ]]" || rc=1

  # --- Step 6: Fail2Ban ---
  assert_shell "Fail2Ban active" "docker exec ${name} systemctl is-active --quiet fail2ban" || rc=1
  assert_shell "Fail2Ban enabled" "docker exec ${name} systemctl is-enabled --quiet fail2ban" || rc=1
  assert_shell "jail.local: banaction = ufw" \
    "docker exec ${name} grep -qE '^banaction[[:space:]]*=[[:space:]]*ufw$' /etc/fail2ban/jail.local" || rc=1
  assert_shell "jail.local: bantime = 3600" \
    "docker exec ${name} grep -qE '^bantime[[:space:]]*=[[:space:]]*3600$' /etc/fail2ban/jail.local" || rc=1
  assert_shell "jail.local: findtime = 600" \
    "docker exec ${name} grep -qE '^findtime[[:space:]]*=[[:space:]]*600$' /etc/fail2ban/jail.local" || rc=1
  assert_shell "jail.local: maxretry = 3" \
    "docker exec ${name} grep -qE '^maxretry[[:space:]]*=[[:space:]]*3$' /etc/fail2ban/jail.local" || rc=1
  assert_shell "jail.local: sshd jail on port ${port}" \
    "docker exec ${name} grep -qE '^port[[:space:]]*=[[:space:]]*${port}$' /etc/fail2ban/jail.local" || rc=1
  assert_shell "sshd jail really loaded (fail2ban-client status sshd)" \
    "docker exec ${name} fail2ban-client status sshd" || rc=1

  # --- Step 7: sysctl ---
  assert_shell "98-hardening.conf written" "docker exec ${name} test -s /etc/sysctl.d/98-hardening.conf" || rc=1
  assert_shell "legacy sysctl 99-hardening.conf removed" \
    "! docker exec ${name} test -e /etc/sysctl.d/99-hardening.conf" || rc=1
  assert_shell "runtime net.ipv4.tcp_syncookies=1" \
    "docker exec ${name} bash -c '[[ \$(sysctl -n net.ipv4.tcp_syncookies) == 1 ]]'" || rc=1
  assert_shell "runtime net.ipv4.conf.all.accept_redirects=0" \
    "docker exec ${name} bash -c '[[ \$(sysctl -n net.ipv4.conf.all.accept_redirects) == 0 ]]'" || rc=1
  assert_shell "runtime net.ipv4.conf.all.rp_filter=1" \
    "docker exec ${name} bash -c '[[ \$(sysctl -n net.ipv4.conf.all.rp_filter) == 1 ]]'" || rc=1
  assert_shell "no partial-sysctl warning in log" \
    "grep -q 'Kernel/network hardening applied' '${log}'" || rc=1

  # --- Step 8: journald + cron/at ---
  assert_shell "journald: SystemMaxUse=200M" \
    "docker exec ${name} grep -qF 'SystemMaxUse=200M' /etc/systemd/journald.conf.d/99-vps-limits.conf" || rc=1
  assert_shell "journald: RuntimeMaxUse=100M" \
    "docker exec ${name} grep -qF 'RuntimeMaxUse=100M' /etc/systemd/journald.conf.d/99-vps-limits.conf" || rc=1
  assert_shell "journald: MaxRetentionSec=14day" \
    "docker exec ${name} grep -qF 'MaxRetentionSec=14day' /etc/systemd/journald.conf.d/99-vps-limits.conf" || rc=1
  assert_shell "journald drop-in mode 644" \
    "docker exec ${name} bash -c '[[ \$(stat -c %a /etc/systemd/journald.conf.d/99-vps-limits.conf) == 644 ]]'" || rc=1
  assert_shell "systemd-journald active" "docker exec ${name} systemctl is-active --quiet systemd-journald" || rc=1
  assert_shell "/etc/cron.allow is root-only, mode 600" \
    "docker exec ${name} bash -c '[[ \$(cat /etc/cron.allow) == root && \$(stat -c %a /etc/cron.allow) == 600 ]]'" || rc=1
  assert_shell "/etc/at.allow is root-only, mode 600" \
    "docker exec ${name} bash -c '[[ \$(cat /etc/at.allow) == root && \$(stat -c %a /etc/at.allow) == 600 ]]'" || rc=1

  # --- Sudo user and end state ---
  assert_shell "${user} exists" "docker exec ${name} id ${user}" || rc=1
  assert_shell "${user} in sudo group" "docker exec ${name} id -nG ${user} | grep -qw sudo" || rc=1
  assert_shell "provider default user 'user' absent" "! docker exec ${name} id user" || rc=1
  assert_shell "final summary printed" "grep -q 'SERVER HARDENING COMPLETE' '${log}'" || rc=1
  assert_shell "reconnect command shown (ssh -p ${port} ${user}@)" \
    "grep -q 'ssh -p ${port} ${user}@' '${log}'" || rc=1
  assert_shell "no rollback was triggered" "! grep -q 'Rolling back critical changes' '${log}'" || rc=1

  return "${rc}"
}

verify_key_nopasswd() {
  local name="$1" log="$2" rc=0
  # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
  verify_common_hardening "${name}" "${log}" tester6 2244 key || rc=1
  assert_shell "sudoers: NOPASSWD for tester6" "docker exec ${name} grep -q NOPASSWD /etc/sudoers.d/tester6" || rc=1
  assert_shell "sudoers.d/tester6 mode 440" "docker exec ${name} bash -c '[[ \$(stat -c %a /etc/sudoers.d/tester6) == 440 ]]'" || rc=1
  return "${rc}"
}

verify_key_password_autogen() {
  local name="$1" log="$2" rc=0
  # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
  verify_common_hardening "${name}" "${log}" tester7 2255 key || rc=1
  assert_shell "sudoers.d/tester7 has no NOPASSWD file" "! docker exec ${name} test -f /etc/sudoers.d/tester7" || rc=1
  assert_shell "password actually set for tester7 (auto-generated)" \
    "docker exec ${name} bash -c 'getent shadow tester7 | cut -d: -f2 | grep -vqE \"^[!*]\"'" || rc=1
  assert_shell "generated password shown in final summary" "grep -q 'Password:' '${log}'" || rc=1
  assert_shell "generated password mirrored to /root/.tester7-credentials" \
    "docker exec ${name} test -f /root/.tester7-credentials" || rc=1
  assert_shell "credentials file is root-only (600)" \
    "test \"\$(docker exec ${name} stat -c '%a %U' /root/.tester7-credentials)\" = '600 root'" || rc=1
  assert_shell "credentials file records a non-empty password" \
    "test -n \"\$(docker exec ${name} sed -n 's/^password=//p' /root/.tester7-credentials | tr -d '[:cntrl:]')\"" || rc=1
  # assert_shell runs the command in a fresh `bash -c`, so this has to strip the
  # transcript's colour codes inline rather than call a helper from lib.sh.
  assert_shell "credentials file holds the same password the summary printed" \
    "test \"\$(docker exec ${name} sed -n 's/^password=//p' /root/.tester7-credentials | tr -d '[:cntrl:]')\" = \"\$(sed -E 's/\x1b\[[0-9;]*m//g' '${log}' | sed -n 's/^ *Password: *//p' | head -n1 | tr -d '[:cntrl:]')\"" || rc=1
  return "${rc}"
}

verify_key_password_manual() {
  local name="$1" log="$2" rc=0
  # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
  verify_common_hardening "${name}" "${log}" tester8 2244 key || rc=1
  assert_shell "sudoers.d/tester8 has no NOPASSWD file" "! docker exec ${name} test -f /etc/sudoers.d/tester8" || rc=1
  assert_shell "password actually set for tester8 (manual entry)" \
    "docker exec ${name} bash -c 'getent shadow tester8 | cut -d: -f2 | grep -vqE \"^[!*]\"'" || rc=1
  return "${rc}"
}

verify_password_only_preset() {
  local name="$1" log="$2" rc=0
  # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
  verify_common_hardening "${name}" "${log}" tester9 2244 password || rc=1
  assert_shell "sudoers.d/tester9 has no NOPASSWD file" "! docker exec ${name} test -f /etc/sudoers.d/tester9" || rc=1
  return "${rc}"
}

verify_password_only_interactive() {
  local name="$1" log="$2" rc=0
  # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
  verify_common_hardening "${name}" "${log}" tester10 2244 password || rc=1
  return "${rc}"
}

verify_port22_edge() {
  local name="$1" log="$2" rc=0
  # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
  verify_common_hardening "${name}" "${log}" tester11 22 key || rc=1
  return "${rc}"
}

verify_provider_cleanup() {
  local name="$1" log="$2" rc=0
  # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
  verify_common_hardening "${name}" "${log}" tester13 2244 key || rc=1
  assert_shell "provider home /home/user removed too" "! docker exec ${name} test -d /home/user" || rc=1
  assert_shell "sudoers: NOPASSWD for tester13" "docker exec ${name} grep -q NOPASSWD /etc/sudoers.d/tester13" || rc=1
  return "${rc}"
}

verify_existing_system_account() {
  local name="$1" log="$2" rc=0
  # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
  verify_common_hardening "${name}" "${log}" svcacct 2244 key || rc=1
  assert_shell "sudoers: NOPASSWD for svcacct" "docker exec ${name} grep -q NOPASSWD /etc/sudoers.d/svcacct" || rc=1
  assert_shell "log warned before escalating a system account (uid<1000)" \
    "grep -q 'already exists as a SYSTEM account' '${log}'" || rc=1
  return "${rc}"
}

verify_foreign_ufw_rules_kept() {
  local name="$1" log="$2" rc=0
  # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
  verify_common_hardening "${name}" "${log}" tester17 2244 key || rc=1
  assert_shell "operator was asked before touching rules the script did not write" \
    "grep -q 'Remove these existing ALLOW rules too' '${log}'" || rc=1
  assert_shell "answering no keeps 80/tcp" "docker exec ${name} ufw status | grep -qE '^80/tcp'" || rc=1
  assert_shell "answering no keeps 443/tcp" "docker exec ${name} ufw status | grep -qE '^443/tcp'" || rc=1
  assert_shell "stale LIMIT rule on the old SSH port still pruned" \
    "! docker exec ${name} ufw status | grep -qE '^2255/tcp'" || rc=1
  return "${rc}"
}

verify_confirm_window() {
  local name="$1" log="$2" rc=0
  # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
  verify_common_hardening "${name}" "${log}" tester18 2244 key || rc=1
  assert_shell "auto-revert timer armed" \
    "docker exec ${name} systemctl is-active --quiet hardening-autorevert.timer" || rc=1
  assert_shell "pre-hardening /etc/ssh snapshot taken" \
    "docker exec ${name} test -s /root/.pre-hardening-ssh.tar" || rc=1
  assert_shell "confirm helper installed and executable" \
    "docker exec ${name} test -x /usr/local/sbin/hardening-confirm" || rc=1
  assert_shell "summary tells the operator how to cancel" \
    "grep -q 'hardening-confirm' '${log}'" || rc=1
  # The point of the window is that confirming it disarms everything.
  assert_shell "hardening-confirm cancels the timer" \
    "docker exec ${name} /usr/local/sbin/hardening-confirm > /dev/null && ! docker exec ${name} systemctl is-active --quiet hardening-autorevert.timer" || rc=1
  # The snapshot is a copy of this host's private SSH keys — it must not outlive its use.
  assert_shell "hardening-confirm removes the snapshot" \
    "! docker exec ${name} test -e /root/.pre-hardening-ssh.tar" || rc=1
  assert_shell "hardening-confirm leaves no dead units or helpers behind" \
    "docker exec ${name} bash -c '! test -e /etc/systemd/system/hardening-autorevert.timer && ! test -e /etc/systemd/system/hardening-autorevert.service && ! test -e /usr/local/sbin/hardening-autorevert'" || rc=1
  assert_shell "sshd still hardened after confirming" \
    "docker exec ${name} sshd -T | grep -qE '^port 2244$'" || rc=1
  return "${rc}"
}

# The only scenario that exercises rollback_on_failure. Everything else here proves
# the script works; this one proves that when it doesn't, it puts the box back.
verify_rollback_on_failure() {
  local name="$1" log="$2" rc=0

  assert_shell "rollback actually ran" "grep -q 'Rolling back critical changes' '${log}'" || rc=1
  assert_shell "sshd port restored to 22" "docker exec ${name} sshd -T | grep -qE '^port 22$'" || rc=1
  assert_shell "no hardening drop-in left behind" \
    "! docker exec ${name} test -e /etc/ssh/sshd_config.d/00-hardening.conf" || rc=1
  assert_shell "root login no longer forced off" \
    "! docker exec ${name} sshd -T | grep -qE '^permitrootlogin no$'" || rc=1
  assert_shell "ssh.socket unmasked again" \
    "! docker exec ${name} systemctl is-enabled ssh.socket 2>/dev/null | grep -q '^masked$'" || rc=1
  assert_shell "sudoers drop-in for tester19 removed" \
    "! docker exec ${name} test -e /etc/sudoers.d/tester19" || rc=1
  assert_shell "newly created jail.local removed" \
    "! docker exec ${name} test -e /etc/fail2ban/jail.local" || rc=1
  assert_shell "sysctl re-apply unit removed" \
    "! docker exec ${name} test -e /etc/systemd/system/sysctl-hardening.service" || rc=1
  # The strongest assertion available: the firewall is byte-for-byte what it was.
  assert_shell "UFW rules and default policies restored exactly" \
    "docker exec ${name} bash -c 'ufw status verbose > /tmp/ufw-after.txt; diff -q /root/ufw-before.txt /tmp/ufw-after.txt'" || rc=1
  assert_shell "no LIMIT rule for the port that was being configured" \
    "! docker exec ${name} ufw status | grep -qE '^2244/tcp'" || rc=1
  assert_shell "UFW rollback backup cleaned up" \
    "[[ \$(docker exec ${name} bash -c 'ls -d /root/.ufw-backup_* 2>/dev/null | wc -l') == 0 ]]" || rc=1
  return "${rc}"
}

# Guards the specific regression this suite was extended for: the UFW rollback flag used
# to be set only after `ufw --force enable`, so a failure anywhere earlier in step 5 left
# the default policies flipped and pruned rules gone, with the rollback skipping UFW
# entirely. Scenario 19 fails later and would not catch a reordering.
verify_rollback_ufw_midstep() {
  local name="$1" log="$2" rc=0

  assert_shell "the run died inside step 5, before UFW was enabled" \
    "grep -q 'Configuring UFW firewall' '${log}' && ! grep -q 'UFW enabled (logging on)' '${log}'" || rc=1
  assert_shell "rollback still covered UFW" \
    "grep -qE 'Restored previous UFW rules|UFW disabled and rules restored' '${log}'" || rc=1
  assert_shell "default policies and rules restored exactly" \
    "docker exec ${name} bash -c 'ufw status verbose > /tmp/ufw-after.txt; diff -q /root/ufw-before.txt /tmp/ufw-after.txt'" || rc=1
  assert_shell "permissive incoming default was put back, not left denying" \
    "docker exec ${name} ufw status verbose | grep -qE '^Default: allow \\(incoming\\)'" || rc=1
  assert_shell "operator rule for 80/tcp survived the failed run" \
    "docker exec ${name} ufw status | grep -qE '^80/tcp'" || rc=1
  assert_shell "no LIMIT rule for the port that was being configured" \
    "! docker exec ${name} ufw status | grep -qE '^2244/tcp'" || rc=1
  assert_shell "UFW rollback backup cleaned up" \
    "[[ \$(docker exec ${name} bash -c 'ls -d /root/.ufw-backup_* 2>/dev/null | wc -l') == 0 ]]" || rc=1
  return "${rc}"
}

# --- Presetup functions: container state before the interactive run ---

presetup_password_file() { docker exec "$1" bash -c 'printf "Str0ngP@ssphrase!23\n" > /root/.testpass && chmod 600 /root/.testpass'; }
presetup_provider_user() { docker exec "$1" useradd -m -s /bin/bash user; }
presetup_system_account() { docker exec "$1" useradd -r -m -d /home/svcacct -s /bin/bash svcacct; }

# A firewall that already carries operator rules (80/443) plus a LIMIT rule this
# script itself left on a different port during an earlier run. ufw has to be
# installed here: the target image ships without it, the script adds it in step 2.
presetup_foreign_ufw_rules() {
  docker exec "$1" bash -c '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq && apt-get install -y -qq ufw \
      && ufw --force enable && ufw allow 80/tcp && ufw allow 443/tcp && ufw limit 2255/tcp' > /dev/null
}

# Arms a deterministic failure in step 6 and records the firewall the rollback has to
# put back. The drop-in is written before fail2ban exists; systemd picks it up when the
# script installs the unit, so `systemctl restart fail2ban` fails and set -e fires the trap.
presetup_fail_at_fail2ban() {
  docker exec "$1" bash -c '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq && apt-get install -y -qq ufw
    ufw --force enable && ufw allow 80/tcp
    ufw status verbose > /root/ufw-before.txt
    mkdir -p /etc/systemd/system/fail2ban.service.d
    printf "[Service]\nExecStartPre=/bin/false\n" > /etc/systemd/system/fail2ban.service.d/force-failure.conf
    systemctl daemon-reload' > /dev/null
}

# Makes the FIRST `ufw ... enable` fail and every later call succeed, so the script dies
# mid-step-5 while the rollback's own re-enable still works. ufw is installed here so that
# step 2's apt-get leaves this wrapper in place instead of unpacking over it.
presetup_fail_at_ufw_enable() {
  docker exec "$1" bash -c '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq && apt-get install -y -qq ufw
    # A permissive default is what makes the old bug an outage: the script flips it to
    # deny, and without the rollback nothing ever flips it back.
    ufw default allow incoming
    ufw --force enable && ufw allow 80/tcp
    ufw status verbose > /root/ufw-before.txt
    mv /usr/sbin/ufw /usr/sbin/ufw.real
    cat > /usr/sbin/ufw << "WRAP"
#!/bin/sh
for a in "$@"; do
  if [ "$a" = enable ] && [ ! -e /run/ufw-enable-failed ]; then
    touch /run/ufw-enable-failed
    echo "injected ufw enable failure" >&2
    exit 1
  fi
done
exec /usr/sbin/ufw.real "$@"
WRAP
    chmod 755 /usr/sbin/ufw' > /dev/null
}

# --- Orchestration ---

run_all_scenarios() {
  sep
  info "Argument parsing (full container, dialog never reaches a prompt)"
  sep

  local -a args prompts

  args=(--help)
  prompts=()
  run_heavy_scenario 01_HELP ubuntu:latest 0 verify_help - args prompts || true

  args=(99999)
  prompts=()
  run_heavy_scenario 02_BAD_PORT ubuntu:latest 1 verify_bad_port - args prompts || true

  args=(--bogus)
  prompts=()
  run_heavy_scenario 03_UNKNOWN_FLAG ubuntu:latest 1 verify_unknown_flag - args prompts || true

  args=(--user root)
  prompts=()
  run_heavy_scenario 04_USER_ROOT_REJECTED ubuntu:latest 1 verify_user_root_rejected - args prompts || true

  args=(--password-file /nonexistent/path)
  prompts=()
  run_heavy_scenario 05_PASSWORD_FILE_MISSING ubuntu:latest 1 verify_password_file_missing - args prompts || true

  sep
  info "End-to-end scenarios (full dialog, real systemctl/ufw/fail2ban)"
  sep

  args=(--user tester6)
  # shellcheck disable=SC2154 # FIXTURE_* are assigned by lib.sh:generate_fixture_keys, sourced by run.sh before this file
  prompts=(
    "Use SSH key-only access${TAB}__NL__"
    "Enable passwordless sudo${TAB}y"
    "Paste your SSH PUBLIC KEY${TAB}${FIXTURE_ED25519_PUB}"
  )
  run_heavy_scenario 06_KEY_NOPASSWD ubuntu:latest 0 verify_key_nopasswd - args prompts || true

  args=(2255 --user tester7)
  prompts=(
    "Use SSH key-only access${TAB}y"
    "Enable passwordless sudo${TAB}n"
    "Generate secure password automatically${TAB}__NL__"
    "Paste your SSH PUBLIC KEY${TAB}${FIXTURE_ED25519_PUB}"
  )
  run_heavy_scenario 07_KEY_PASSWORD_AUTOGEN ubuntu:latest 0 verify_key_password_autogen - args prompts || true

  args=(--user tester8)
  prompts=(
    "Use SSH key-only access${TAB}y"
    "Enable passwordless sudo${TAB}n"
    "Generate secure password automatically${TAB}n"
    "Set password for${TAB}${MANUAL_TEST_PASSWORD}"
    "Confirm password${TAB}${MANUAL_TEST_PASSWORD}"
    "Paste your SSH PUBLIC KEY${TAB}${FIXTURE_ED25519_PUB}"
  )
  run_heavy_scenario 08_KEY_PASSWORD_MANUAL ubuntu:latest 0 verify_key_password_manual - args prompts || true

  args=(--user tester9 --password-file /root/.testpass)
  prompts=("Use SSH key-only access${TAB}n")
  run_heavy_scenario 09_PASSWORD_ONLY_PRESET ubuntu:latest 0 verify_password_only_preset presetup_password_file args prompts || true

  args=()
  prompts=(
    "Use SSH key-only access${TAB}n"
    "Enter sudo username${TAB}tester10"
    "Generate secure password automatically${TAB}__NL__"
  )
  run_heavy_scenario 10_PASSWORD_ONLY_INTERACTIVE ubuntu:latest 0 verify_password_only_interactive - args prompts || true

  args=(22 --user tester11)
  prompts=(
    "Use SSH key-only access${TAB}__NL__"
    "Enable passwordless sudo${TAB}y"
    "Paste your SSH PUBLIC KEY${TAB}${FIXTURE_ED25519_PUB}"
  )
  run_heavy_scenario 11_PORT_22_EDGE ubuntu:latest 0 verify_port22_edge - args prompts || true

  args=(--user tester12)
  # shellcheck disable=SC2154 # FIXTURE_* are assigned by lib.sh:generate_fixture_keys, sourced by run.sh before this file
  prompts=(
    "Use SSH key-only access${TAB}__NL__"
    "Enable passwordless sudo${TAB}y"
    "Paste your SSH PUBLIC KEY${TAB}${FIXTURE_RSA_PUB}"
  )
  run_heavy_scenario 12_INVALID_KEY_RSA ubuntu:latest 1 verify_invalid_key_rsa - args prompts || true

  # Regression check: a single-line paste of a PRIVATE key header (what a real terminal
  # paste collapses to, since read -r only consumes the first line) must be caught with
  # the specific PRIVATE key message, not fall through to the generic "Invalid SSH public
  # key" error. See load_ssh_pubkey() in configuring_server.sh.
  args=(--user tester16)
  prompts=(
    "Use SSH key-only access${TAB}__NL__"
    "Enable passwordless sudo${TAB}y"
    "Paste your SSH PUBLIC KEY${TAB}-----BEGIN OPENSSH PRIVATE KEY-----"
  )
  run_heavy_scenario 16_SSH_KEY_INLINE_PRIVATE_KEY_REJECTED ubuntu:latest 1 verify_inline_private_key - args prompts || true

  args=(--user tester13)
  prompts=(
    "Use SSH key-only access${TAB}__NL__"
    "Enable passwordless sudo${TAB}y"
    "Paste your SSH PUBLIC KEY${TAB}${FIXTURE_ED25519_PUB}"
  )
  run_heavy_scenario 13_PROVIDER_USER_CLEANUP ubuntu:latest 0 verify_provider_cleanup presetup_provider_user args prompts || true

  args=(--user svcacct)
  prompts=(
    "Use SSH key-only access${TAB}__NL__"
    "Grant sudo and SSH key access${TAB}y"
    "Enable passwordless sudo${TAB}y"
    "Paste your SSH PUBLIC KEY${TAB}${FIXTURE_ED25519_PUB}"
  )
  run_heavy_scenario 14_EXISTING_SYSTEM_ACCOUNT ubuntu:latest 0 verify_existing_system_account presetup_system_account args prompts || true

  args=(--user tester17)
  prompts=(
    "Use SSH key-only access${TAB}y"
    "Enable passwordless sudo${TAB}y"
    "Paste your SSH PUBLIC KEY${TAB}${FIXTURE_ED25519_PUB}"
    "Remove these existing ALLOW rules too${TAB}n"
  )
  run_heavy_scenario 17_FOREIGN_UFW_RULES_KEPT ubuntu:latest 0 verify_foreign_ufw_rules_kept presetup_foreign_ufw_rules args prompts || true

  args=(--user tester18 --confirm-window 30)
  prompts=(
    "Use SSH key-only access${TAB}y"
    "Enable passwordless sudo${TAB}y"
    "Paste your SSH PUBLIC KEY${TAB}${FIXTURE_ED25519_PUB}"
  )
  run_heavy_scenario 18_CONFIRM_WINDOW ubuntu:latest 0 verify_confirm_window - args prompts || true

  args=(--user tester19)
  prompts=(
    "Use SSH key-only access${TAB}y"
    "Enable passwordless sudo${TAB}y"
    "Paste your SSH PUBLIC KEY${TAB}${FIXTURE_ED25519_PUB}"
    "Remove these existing ALLOW rules too${TAB}n"
  )
  run_heavy_scenario 19_ROLLBACK_ON_FAILURE ubuntu:latest 1 verify_rollback_on_failure presetup_fail_at_fail2ban args prompts || true

  args=(--user tester20)
  prompts=(
    "Use SSH key-only access${TAB}y"
    "Enable passwordless sudo${TAB}y"
    "Paste your SSH PUBLIC KEY${TAB}${FIXTURE_ED25519_PUB}"
    "Remove these existing ALLOW rules too${TAB}n"
  )
  run_heavy_scenario 20_ROLLBACK_UFW_MIDSTEP ubuntu:latest 1 verify_rollback_ufw_midstep presetup_fail_at_ufw_enable args prompts || true

  sep
  info "15 — idempotency: re-run on the same container"
  sep
  # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
  run_idempotent_rerun || true
}

run_idempotent_rerun() {
  local scen_id="15_IDEMPOTENT_RERUN"
  # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
  scenario_selected "${scen_id}" || return 0
  local tag="cfgsrv-test:${scen_id,,}" cname="cfgsrv-test-${scen_id,,}"
  # shellcheck disable=SC2154 # set as readonly by run.sh before this file is sourced
  local log1="${RESULTS_DIR}/${scen_id}_run1.log" log2="${RESULTS_DIR}/${scen_id}_run2.log"
  local -a args=(--user tester15)
  local -a prompts=(
    "Use SSH key-only access${TAB}__NL__"
    "Enable passwordless sudo${TAB}y"
    "Paste your SSH PUBLIC KEY${TAB}${FIXTURE_ED25519_PUB}"
  )
  local prompts_file
  prompts_file="$(mktemp)"
  printf '%s\n' "${prompts[@]}" > "${prompts_file}"

  build_target_image ubuntu:latest "${tag}"
  start_target_container "${tag}" "${cname}"

  if ! wait_for_boot "${cname}" 60; then
    record_result "${scen_id}" FAIL "systemd did not come up"
    cleanup_scenario "${cname}" "${tag}" "${prompts_file}"
    return 1
  fi

  local rc1=0 rc2=0
  run_interactive "${cname}" "${args[@]}" -- "${prompts_file}" "${log1}" 600 || rc1=$?
  run_interactive "${cname}" "${args[@]}" -- "${prompts_file}" "${log2}" 600 || rc2=$?

  local status="PASS" note=""
  # shellcheck disable=SC2094,SC2310 # the log is appended to and inspected by the same helper on purpose; the helper's return code is handled by this conditional
  if [[ "${rc1}" != 0 || "${rc2}" != 0 ]]; then
    status="FAIL"
    note="run1=${rc1} run2=${rc2} (expected both 0)"
  # The second run must leave the box in exactly the same hardened state as the first —
  # not just avoid errors. verify_common_hardening also asserts a single UFW LIMIT rule,
  # which is where a non-idempotent re-run would show up first.
  elif ! verify_common_hardening "${cname}" "${log2}" tester15 2244 key >> "${log2}" 2>&1; then
    status="FAIL"
    note="post-rerun verification failed, see ${log2}"
  elif ! assert_shell "sudoers: NOPASSWD for tester15" \
    "docker exec ${cname} grep -q NOPASSWD /etc/sudoers.d/tester15" >> "${log2}" 2>&1; then
    status="FAIL"
    note="sudoers NOPASSWD missing after re-run, see ${log2}"
  fi

  record_result "${scen_id}" "${status}" "${note}"
  cleanup_scenario "${cname}" "${tag}" "${prompts_file}"
}
