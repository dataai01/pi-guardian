# Changelog

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
