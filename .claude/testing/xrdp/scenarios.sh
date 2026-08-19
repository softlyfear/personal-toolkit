# shellcheck shell=bash
# .claude/testing/xrdp/scenarios.sh — scenario matrix for add_xfce_xrdp.sh and
# add_gnome_xrdp.sh. Source-only, via run.sh (after lib.sh). Ubuntu only, real
# apt-get/ufw/systemctl in a real systemd container, including a real (heavy) desktop
# environment install. SSH_PORT=22 is injected by lib.sh's run_interactive so
# ensure_ssh_ufw_rule() has something to find (no real sshd session exists in the
# container). Everything runs as root (docker exec default) — both scripts' non-root
# path (setup_sudo/SUDO=) is already covered by the near-identical pattern in the
# svcctl/sysupdate suites, not duplicated here.
set -euo pipefail

readonly TAB=$'\t'
readonly XFCE_SCRIPT="/opt/repo/server-scripts/add_xfce_xrdp.sh"
readonly GNOME_SCRIPT="/opt/repo/server-scripts/add_gnome_xrdp.sh"
# ensure_sudo_user() runs `passwd "$NEW_USER"` for a NEWLY created user (skipped
# entirely when the user already exists via presetup) — that's the external passwd(1)
# binary prompting over the same /dev/tty, not a `read` in the script itself. Every
# scenario that creates a new user needs these two extra prompts after the username.
readonly TEST_PASSWORD='Str0ngP@ssword!1'

# --- Shared verify implementations, parameterized by desktop-specific bits ---

verify_impl_fresh_open() {
  local name="$1" log="$2" session_marker="$3" session_cmd="$4" user="$5"
  local rc=0
  assert_shell "xrdp active" "docker exec ${name} systemctl is-active --quiet xrdp" || rc=1
  assert_shell "xrdp enabled" "docker exec ${name} systemctl is-enabled --quiet xrdp" || rc=1
  assert_shell "ufw active" "docker exec ${name} bash -c 'ufw status | grep -q \"Status: active\"'" || rc=1
  assert_shell "ufw allows RDP 3389/tcp from anywhere" \
    "docker exec ${name} bash -c \"ufw status | grep -E '3389/tcp[[:space:]]+ALLOW[[:space:]]+Anywhere'\"" || rc=1
  assert_shell "ufw allows SSH 22/tcp" \
    "docker exec ${name} bash -c \"ufw status | grep -E '22/tcp[[:space:]]+ALLOW'\"" || rc=1
  assert_shell "user ${user} exists" "docker exec ${name} id ${user}" || rc=1
  assert_shell "user ${user} in sudo group" "docker exec ${name} id -nG ${user} | grep -qw sudo" || rc=1
  assert_shell ".xsession has ${session_cmd}" \
    "docker exec ${name} bash -c 'grep -qx ${session_cmd} /home/${user}/.xsession'" || rc=1
  assert_shell ".xsessionrc has ${session_marker}" \
    "docker exec ${name} grep -q '${session_marker}' /home/${user}/.xsessionrc" || rc=1
  assert_shell "PAM root-deny line present" \
    "docker exec ${name} grep -qF 'pam_succeed_if.so user != root' /etc/pam.d/xrdp-sesman" || rc=1
  assert_shell "\$session_cmd binary present" "docker exec ${name} bash -c 'command -v ${session_cmd}'" || rc=1
  return "${rc}"
}

verify_impl_restricted_ip() {
  local name="$1" log="$2" ip="$3"
  assert_shell "ufw restricts RDP 3389/tcp to ${ip}" \
    "docker exec ${name} bash -c \"ufw status | grep -E '3389/tcp[[:space:]]+ALLOW[[:space:]]+${ip//./\\\\.}'\""
}

verify_invalid_rdp_ip() { assert_shell "log contains 'Invalid IPv4 address'" "grep -q 'Invalid IPv4 address' '$2'"; }

verify_impl_username_retry() {
  local name="$1" log="$2" final_user="$3"
  local rc=0
  assert_shell "log shows a retry warning" "grep -q 'Invalid username' '${log}'" || rc=1
  assert_shell "final user ${final_user} exists" "docker exec ${name} id ${final_user}" || rc=1
  assert_shell "rejected candidate '123bad' was NOT created" "! docker exec ${name} id 123bad" || rc=1
  return "${rc}"
}

verify_impl_existing_user() {
  local name="$1" log="$2" user="$3"
  local rc=0
  assert_shell "log warns user already exists" "grep -q 'already exists' '${log}'" || rc=1
  assert_shell "user ${user} still in sudo group after skip-create" "docker exec ${name} id -nG ${user} | grep -qw sudo" || rc=1
  return "${rc}"
}

# --- XFCE wrappers ---
verify_xfce_fresh_open() { verify_impl_fresh_open "$1" "$2" "XDG_CURRENT_DESKTOP=XFCE" "startxfce4" xfcetester; }
verify_xfce_restricted_ip() { verify_impl_restricted_ip "$1" "$2" "203.0.113.10"; }
verify_xfce_username_retry() { verify_impl_username_retry "$1" "$2" gooduser; }
verify_xfce_existing_user() { verify_impl_existing_user "$1" "$2" xfcetester; }

# --- GNOME wrappers ---
verify_gnome_fresh_open() { verify_impl_fresh_open "$1" "$2" "XDG_CURRENT_DESKTOP=ubuntu:GNOME" "gnome-session" gnometester; }
verify_gnome_restricted_ip() { verify_impl_restricted_ip "$1" "$2" "203.0.113.10"; }
verify_gnome_username_retry() { verify_impl_username_retry "$1" "$2" gooduser; }
verify_gnome_existing_user() { verify_impl_existing_user "$1" "$2" gnometester; }

# --- Presetup ---
presetup_xfce_existing_user() { docker exec "$1" useradd -m -s /bin/bash xfcetester; }
presetup_gnome_existing_user() { docker exec "$1" useradd -m -s /bin/bash gnometester; }

# --- Orchestration ---

run_all_scenarios() {
  sep
  info "add_xfce_xrdp.sh"
  sep
  run_xfce_scenarios

  sep
  info "add_gnome_xrdp.sh"
  sep
  run_gnome_scenarios
}

run_xfce_scenarios() {
  # Real prompt order in the script: RDP source IP fires during Step 2 (firewall config),
  # BEFORE the heavy desktop/xrdp apt install (Step 3); the username prompt only fires in
  # Step 4, after that install completes. Sending responses out of this order leaves
  # expect stalled on a pattern that will never appear until the 1200s scenario timeout.
  local -a prompts

  prompts=("restrict RDP access${TAB}__NL__" "Enter new sudo username${TAB}xfcetester" "New password${TAB}${TEST_PASSWORD}" "Retype new password${TAB}${TEST_PASSWORD}")
  run_heavy_scenario 01_XFCE_FRESH_OPEN_RDP "${XFCE_SCRIPT}" 0 verify_xfce_fresh_open - prompts || true

  prompts=("restrict RDP access${TAB}203.0.113.10" "Enter new sudo username${TAB}xfcetester2" "New password${TAB}${TEST_PASSWORD}" "Retype new password${TAB}${TEST_PASSWORD}")
  run_heavy_scenario 02_XFCE_RESTRICTED_RDP_IP "${XFCE_SCRIPT}" 0 verify_xfce_restricted_ip - prompts || true

  prompts=("restrict RDP access${TAB}not-an-ip")
  run_heavy_scenario 03_XFCE_INVALID_RDP_IP "${XFCE_SCRIPT}" 1 verify_invalid_rdp_ip - prompts || true

  prompts=("restrict RDP access${TAB}__NL__" "Enter new sudo username${TAB}123bad" "try again${TAB}gooduser" "New password${TAB}${TEST_PASSWORD}" "Retype new password${TAB}${TEST_PASSWORD}")
  run_heavy_scenario 04_XFCE_USERNAME_RETRY "${XFCE_SCRIPT}" 0 verify_xfce_username_retry - prompts || true

  prompts=("restrict RDP access${TAB}__NL__" "Enter new sudo username${TAB}xfcetester")
  run_heavy_scenario 05_XFCE_EXISTING_USER "${XFCE_SCRIPT}" 0 verify_xfce_existing_user presetup_xfce_existing_user prompts || true
}

run_gnome_scenarios() {
  # Same prompt order as XFCE: RDP IP (Step 2) before username (Step 4) — see comment above.
  local -a prompts

  prompts=("restrict RDP access${TAB}__NL__" "Enter new sudo username${TAB}gnometester" "New password${TAB}${TEST_PASSWORD}" "Retype new password${TAB}${TEST_PASSWORD}")
  run_heavy_scenario 06_GNOME_FRESH_OPEN_RDP "${GNOME_SCRIPT}" 0 verify_gnome_fresh_open - prompts || true

  prompts=("restrict RDP access${TAB}203.0.113.10" "Enter new sudo username${TAB}gnometester2" "New password${TAB}${TEST_PASSWORD}" "Retype new password${TAB}${TEST_PASSWORD}")
  run_heavy_scenario 07_GNOME_RESTRICTED_RDP_IP "${GNOME_SCRIPT}" 0 verify_gnome_restricted_ip - prompts || true

  prompts=("restrict RDP access${TAB}not-an-ip")
  run_heavy_scenario 08_GNOME_INVALID_RDP_IP "${GNOME_SCRIPT}" 1 verify_invalid_rdp_ip - prompts || true

  prompts=("restrict RDP access${TAB}__NL__" "Enter new sudo username${TAB}123bad" "try again${TAB}gooduser" "New password${TAB}${TEST_PASSWORD}" "Retype new password${TAB}${TEST_PASSWORD}")
  run_heavy_scenario 09_GNOME_USERNAME_RETRY "${GNOME_SCRIPT}" 0 verify_gnome_username_retry - prompts || true

  # shellcheck disable=SC2034 # assigned here, consumed by name (nameref) in the helper below
  prompts=("restrict RDP access${TAB}__NL__" "Enter new sudo username${TAB}gnometester")
  run_heavy_scenario 10_GNOME_EXISTING_USER "${GNOME_SCRIPT}" 0 verify_gnome_existing_user presetup_gnome_existing_user prompts || true
}
