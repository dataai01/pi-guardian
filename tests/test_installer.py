"""Exercise the installer with fake system commands; never change the host OS.

Run with python -m unittest discover -s tests -v (requires Bash and Python 3).
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
BASH = os.environ.get("BASH") or (
    "C:/Program Files/Git/bin/bash.exe" if os.name == "nt" else shutil.which("bash")
)
ONLINE = {"BackendState": "Running", "TUN": True, "Self": {"Online": True},
          "TailscaleIPs": ["100.100.1.2"]}

HARNESS = r'''
set -Eeuo pipefail
source "$REPO/install.sh"
INSTALL_TMP="$TEST_TMP"
LOG_FILE="$TEST_TMP/install.log"
ENV_FILE="$TEST_TMP/config.env"
SSH_PORTS=(22)
python3() { "$TEST_PYTHON" "$@"; }
sleep() { :; }
timeout() {
  [[ "$1" != --foreground ]] || shift
  shift
  "$@"
}
tailscale() {
  printf 'tailscale %s\n' "$*" >> "$TEST_TMP/calls"
  case "$1" in
    status) cat "$TEST_TMP/status.json";;
    up)
      for argument in "$@"; do
        if [[ "$argument" == --auth-key=file:* ]]; then
          key_file="${argument#--auth-key=file:}"
          [[ -s "$key_file" ]] || return 9
          printf 'key-mode %s\n' "$(stat -c %a "$key_file")" >> "$TEST_TMP/calls"
        fi
      done
      if [[ "${UP_RESULT:-0}" -ne 0 ]]; then return "$UP_RESULT"; fi
      cp "$TEST_TMP/after.json" "$TEST_TMP/status.json"
      ;;
    set) return "${SET_RESULT:-0}";;
    *) return 8;;
  esac
}
ip() { return "${IP_RESULT:-0}"; }
ufw() { printf 'ufw %s\n' "$*" >> "$TEST_TMP/calls"; }
systemctl() { printf 'systemctl %s\n' "$*" >> "$TEST_TMP/calls"; return "${SERVICE_RESULT:-0}"; }
curl() {
  printf 'curl %s\n' "$*" >> "$TEST_TMP/calls"
  local count=0
  [[ ! -f "$TEST_TMP/curl-count" ]] || read -r count < "$TEST_TMP/curl-count"
  count=$((count + 1))
  printf '%s\n' "$count" > "$TEST_TMP/curl-count"
  [[ "$count" -ge "${CURL_READY_AT:-1}" ]] || return 7
  return "${CURL_RESULT:-0}"
}
tailscale_diagnostics() { echo 'Tailscale diagnostics'; }
'''


class InstallerTests(unittest.TestCase):
    def run_shell(self, script, *, state=None, after=None, env=None, success=True):
        with tempfile.TemporaryDirectory(prefix="pi-guardian-test-") as directory:
            folder = Path(directory)
            (folder / "status.json").write_text(json.dumps(ONLINE if state is None else state))
            (folder / "after.json").write_text(json.dumps(ONLINE if after is None else after))
            process_env = {**os.environ, "REPO": ROOT.as_posix(),
                           "TEST_TMP": folder.as_posix(), "TEST_PYTHON": Path(sys.executable).as_posix()}
            for key in ("TS_AUTHKEY", "TS_AUTH_KEY", "TS_HOSTNAME", "TS_ADVERTISE_TAGS", "SSH_CONNECTION"):
                process_env.pop(key, None)
            process_env.update(env or {})
            result = subprocess.run([BASH, "-c", HARNESS + "\n" + script], env=process_env,
                                    capture_output=True, text=True, timeout=30, cwd=ROOT)
            calls = (folder / "calls").read_text() if (folder / "calls").exists() else ""
            output = result.stdout + result.stderr
            if success:
                self.assertEqual(result.returncode, 0, output + calls)
            else:
                self.assertNotEqual(result.returncode, 0, output + calls)
            return output, calls

    def test_browser_login_with_redirected_output(self):
        output, calls = self.run_shell('exec > >(tee "$TEST_TMP/session.log") 2>&1\nconnect_tailscale',
                                       state={"BackendState": "NeedsLogin"})
        self.assertIn("tailscale up\n", calls)
        self.assertIn("Open the Tailscale login link", output)
        self.assertIn("Tailscale connected: 100.100.1.2", output)
        self.assertNotIn("--ssh", calls)

    def test_existing_connection_is_not_reauthenticated(self):
        _, calls = self.run_shell("TS_AUTHKEY=unused-secret\nconnect_tailscale")
        self.assertNotIn("tailscale up", calls)
        self.assertNotIn("tailscale set", calls)

    def test_stopped_profile_resumes_with_no_preference_flags(self):
        _, calls = self.run_shell("connect_tailscale", state={**ONLINE, "BackendState": "Stopped"})
        self.assertIn("tailscale up\n", calls)
        self.assertNotIn("--timeout", calls)
        self.assertNotIn("--reset", calls)

    def test_requested_hostname_applied_after_login(self):
        _, calls = self.run_shell('TS_HOSTNAME=my-pi\nconnect_tailscale', state={"BackendState": "NeedsLogin"})
        self.assertLess(calls.index("tailscale up\n"), calls.index("tailscale set --hostname=my-pi"))

    def test_existing_hostname_and_explicit_ssh_change(self):
        _, calls = self.run_shell('TS_HOSTNAME=my-pi\nTAILSCALE_SSH=false\nconnect_tailscale')
        self.assertIn("tailscale set --hostname=my-pi --ssh=false", calls)
        self.assertNotIn("tailscale up", calls)

    def test_ssh_preference_failure_is_not_ignored(self):
        output, _ = self.run_shell('TAILSCALE_SSH=true\nSET_RESULT=1\nconnect_tailscale', success=False)
        self.assertIn("Could not apply", output)

    def test_auth_key_never_appears_in_arguments_and_is_removed(self):
        output, calls = self.run_shell('TS_AUTHKEY=test-secret\nconnect_tailscale\n[[ ! -e "$INSTALL_TMP/authkey" ]]',
                                       state={"BackendState": "NeedsLogin"})
        self.assertIn("--auth-key=file:", calls)
        self.assertNotIn("test-secret", output + calls)
        if os.name != "nt":
            self.assertIn("key-mode 600", calls)

    def test_failed_auth_removes_key_and_does_not_report_success(self):
        output, _ = self.run_shell('''
TS_AUTHKEY=test-secret
UP_RESULT=1
trap '[[ ! -e "$INSTALL_TMP/authkey" ]] && echo key-cleaned' EXIT
connect_tailscale
''', state={"BackendState": "NeedsLogin"}, success=False)
        self.assertIn("key-cleaned", output)
        self.assertIn("setup did not finish", output)
        self.assertNotIn("Tailscale connected:", output)

    def test_login_timeout_reports_incomplete_setup(self):
        output, _ = self.run_shell('UP_RESULT=124\nconnect_tailscale',
                                   state={"BackendState": "NeedsLogin"}, success=False)
        self.assertIn("setup did not finish", output)

    def test_stale_ip_offline_userspace_and_pending_approval_are_not_ready(self):
        for change in ({"BackendState": "Stopped"}, {"BackendState": "NeedsMachineAuth"},
                       {"Self": {"Online": False}}, {"TUN": False}, {"TailscaleIPs": []}):
            with self.subTest(change=change):
                self.run_shell('! refresh_tailscale_status\n[[ "$TAILSCALE_READY" == 0 ]]',
                               state={**ONLINE, **change})

    def test_missing_tunnel_interface_is_not_ready(self):
        self.run_shell('IP_RESULT=1\n! refresh_tailscale_status\n[[ "$TAILSCALE_READY" == 0 ]]')

    def test_malformed_status_is_not_ready(self):
        self.run_shell('echo invalid > "$TEST_TMP/status.json"\n! refresh_tailscale_status')

    def test_pending_approval_after_up_is_failure(self):
        output, _ = self.run_shell('connect_tailscale', state={"BackendState": "NeedsLogin"},
                                   after={**ONLINE, "BackendState": "NeedsMachineAuth"}, success=False)
        self.assertIn("not online with a usable tunnel", output)

    def test_reset_only_when_explicitly_requested(self):
        _, calls = self.run_shell('FORCE_TAILSCALE_RESET=1\nTS_HOSTNAME=pi-new\nconnect_tailscale')
        self.assertIn("tailscale up --reset --hostname=pi-new", calls)

    def test_firewall_preserves_connecting_ip_and_custom_port_before_policy(self):
        _, calls = self.run_shell('SSH_PORTS=(2222)\nDASH_PORT=9090\nconfigure_firewall',
                                  env={"SSH_CONNECTION": "192.168.1.42 50000 192.168.1.10 2222"})
        recovery = "ufw insert 1 allow proto tcp from 192.168.1.42 to any port 2222"
        self.assertIn(recovery, calls)
        self.assertLess(calls.index(recovery), calls.index("default deny incoming"))
        self.assertIn("allow in on tailscale0 to any port 2222", calls)
        self.assertIn("allow in on tailscale0 to any port 9090", calls)
        self.assertNotIn("ufw allow 22/tcp", calls)

    def test_ipv6_recovery_address(self):
        _, calls = self.run_shell('configure_firewall',
                                  env={"SSH_CONNECTION": "2001:db8::42 50000 2001:db8::10 22"})
        self.assertIn("from 2001:db8::42 to any port 22", calls)

    def test_invalid_recovery_address_does_not_change_firewall(self):
        _, calls = self.run_shell('configure_firewall', env={"SSH_CONNECTION": "malformed"}, success=False)
        self.assertNotIn("ufw ", calls)

    def test_skipped_login_does_not_change_firewall_when_offline(self):
        _, calls = self.run_shell('SKIP_TAILSCALE_UP=1\nconfigure_firewall', state={"BackendState": "NeedsLogin"})
        self.assertNotIn("ufw ", calls)

    def test_lost_connection_does_not_change_firewall(self):
        _, calls = self.run_shell('configure_firewall', state={**ONLINE, "Self": {"Online": False}}, success=False)
        self.assertNotIn("ufw ", calls)

    def test_unconfigured_wireguard_and_no_vpn_do_not_lock_out_ssh(self):
        for script in ("VPN=wireguard\nIP_RESULT=1", "VPN=none"):
            with self.subTest(script=script):
                _, calls = self.run_shell(script + "\nconfigure_firewall")
                self.assertNotIn("ufw ", calls)

    def test_dashboard_checks_actual_port_and_overlay_address(self):
        _, calls = self.run_shell('DASH_PORT=9090\nTAILSCALE_READY=1\nTAILSCALE_IP=100.100.1.2\nverify_dashboard')
        self.assertIn("http://127.0.0.1:9090/", calls)
        self.assertIn("http://100.100.1.2:9090/", calls)

    def test_dashboard_last_attempt_can_succeed(self):
        self.run_shell('CURL_READY_AT=10\nverify_dashboard')

    def test_broken_dashboard_is_failure(self):
        output, _ = self.run_shell('CURL_RESULT=7\nverify_dashboard', success=False)
        self.assertIn("dashboard did not respond", output)

    def test_saved_dashboard_port_controls_firewall_and_summary(self):
        output, calls = self.run_shell('''
chown() { :; }
chmod() { :; }
printf 'DASH_PORT=9090\nDASH_BIND=0.0.0.0\n' > "$ENV_FILE"
write_config
configure_firewall
print_summary
''')
        self.assertIn("to any port 9090", calls)
        self.assertIn("http://100.100.1.2:9090/", output)

    def test_input_validation_handles_decimal_ports_and_invalid_deadlines(self):
        self.run_shell('parse_args --dashboard-port 08080 --login-timeout 060\nvalidate_options\n[[ "$DASH_PORT" == 8080 && "$TS_LOGIN_TIMEOUT" == 60 ]]')
        for arguments in ("--dashboard-port 0", "--dashboard-port 65536", "--login-timeout 0", "--login-timeout nope"):
            with self.subTest(arguments=arguments):
                self.run_shell(f'parse_args {arguments}\nvalidate_options', success=False)

    def test_failed_remote_setup_never_reaches_hardening_or_firewall(self):
        output, calls = self.run_shell('''
prepare_install() { :; }
install_dependencies() { :; }
ensure_app_user() { :; }
write_application_files() { :; }
write_config() { :; }
install_python_env() { :; }
enable_ssh() { :; }
install_tailscale() { connect_tailscale; }
configure_ssh() { echo hardened >> "$TEST_TMP/calls"; }
UP_RESULT=1
main
''', state={"BackendState": "NeedsLogin"}, success=False)
        self.assertNotIn("hardened", calls)
        self.assertNotIn("ufw ", calls)
        self.assertNotIn("Installation complete", output)

    def test_skipped_remote_setup_summary_is_explicit(self):
        output, _ = self.run_shell('SKIP_TAILSCALE_UP=1\nprint_summary')
        self.assertIn("Remote access is NOT ready", output)
        self.assertNotIn("Dashboard URL:", output)

    def test_desktop_launcher_paths_and_failed_install_exit_status(self):
        desktop = (ROOT / "Pi-Guardian-Install.desktop").read_text()
        command = shlex.split(next(line[5:] for line in desktop.splitlines() if line.startswith("Exec=")))
        command[0] = sys.executable
        if os.name == "nt":
            # Windows searches System32 before PATH for bash.exe (the WSL shim).
            # Exercise the Linux launcher's command with the Git Bash test runtime.
            command[2] = command[2].replace("['bash',", f"[{BASH!r},")
        with tempfile.TemporaryDirectory(prefix="pi-guardian-launcher-") as directory:
            folder = Path(directory) / "Pi Guardian ' $ folder"
            folder.mkdir()
            launcher = folder / "Pi-Guardian-Install.desktop"
            launcher.write_text(desktop)
            shutil.copyfile(ROOT / "install-desktop.sh", folder / "install-desktop.sh")
            (folder / "install.sh").write_text('#!/usr/bin/env bash\necho INSTALLER-STARTED\nexit 23\n')
            env = {**os.environ, "PATH": str(Path(BASH).parent) + os.pathsep + os.environ["PATH"]}
            result = subprocess.run([arg if arg != "%k" else str(launcher) for arg in command],
                                    capture_output=True, text=True, env=env, timeout=15)
            self.assertEqual(result.returncode, 23, result.stdout + result.stderr)
            self.assertIn("INSTALLER-STARTED", result.stdout)
            self.assertIn("Setup did not finish", result.stdout)


    def test_embedded_sources_match_repository(self):
        installer = (ROOT / "install.sh").read_text()
        for marker, relative in (("PY_HEALTH", "src/pi_guardian/health.py"),
                                 ("PY_DASH", "src/pi_guardian/dash.py"),
                                 ("SH_BACKUP", "scripts/backup.sh")):
            embedded = installer.split(f"<<'{marker}'\n", 1)[1].split(f"\n{marker}\n", 1)[0]
            self.assertEqual(embedded + "\n", (ROOT / relative).read_text(), relative)

    def test_bash_syntax_and_help(self):
        for script in ("install.sh", "install-desktop.sh", "uninstall.sh", "scripts/backup.sh"):
            result = subprocess.run([BASH, "-n", script], cwd=ROOT, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
        result = subprocess.run([BASH, "install.sh", "--help"], cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--login-timeout", result.stdout)


if __name__ == "__main__":
    unittest.main()
