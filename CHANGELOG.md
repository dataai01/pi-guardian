# Changelog

## v0.3.0
- Added a Raspberry Pi OS desktop launcher and automatic sudo for one-command setup.
- Fixed browser login being skipped because installer logging made stdout non-interactive.
- Waits for login with a deadline and verifies online state, kernel tunnel, and dashboard responses.
- Uses OpenSSH over Tailscale on fresh installs; changing to Tailscale-managed SSH is explicit.
- Installs/enables OpenSSH and preserves the connecting SSH address/port in UFW for recovery.
- Reuses connected Tailscale profiles and resumes stopped profiles without resetting preferences.
- Reads saved dashboard ports on reruns so checks, firewall rules, and printed URLs agree.
- Uses private temporary auth-key files, removes them after use, and protects installer logs.
- Added mocked regression tests for login, failed setup, repeat installs, and firewall recovery.

## v0.2.0
- Replaced the layout-dependent installer with a self-contained `install.sh`.
- Added guided Tailscale setup with auth-key, hostname, tag, and interactive flows.
- Skips UFW changes when Tailscale is not authenticated to avoid SSH lockout.
- Runs Pi Guardian services as an unprivileged `pi-guardian` user.
- Removed shell interpolation from the Python app command execution.
- Escapes dashboard output before rendering HTML.
- Fixed the health agent syntax error in CPU temperature fallback handling.
- Improved backup success/failure handling.

## v0.1.0
- First release with installer, health agent, dashboard, backup timer, and UFW rules.
