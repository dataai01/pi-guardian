# Pi Guardian: A One-Script Safety Layer for Headless Raspberry Pis

Running a Raspberry Pi as a small server is easy until it is not. The hard part usually starts after the Pi is deployed somewhere without a monitor, keyboard, or easy physical access. Remote access needs to be secure. SSH needs to be reliable. Backups need to happen without manual effort. Health problems should be visible before the device silently disappears.

Pi Guardian was built for that exact problem.

It is a small Raspberry Pi hardening and monitoring toolkit designed around one goal: make a headless Pi safer and easier to operate with a single installer script.

The source and future updates are available on GitHub: [github.com/dataai01/pi-guardian](https://github.com/dataai01/pi-guardian).

The application combines four practical pieces:

- Secure remote access through Tailscale
- SSH hardening and firewall rules
- Health monitoring with optional alerts
- A lightweight dashboard and nightly backups

The newest version is self-contained. You can copy only `install.sh` to a Pi and run it. The installer writes the Python application, configuration, backup script, and systemd units into place automatically.

```bash
sudo bash ./install.sh
```

For a headless setup, the recommended path is to use a Tailscale auth key:

```bash
export TS_AUTHKEY=<your-tailscale-auth-key>
sudo -E bash ./install.sh --ts-hostname my-pi
```

That avoids needing to open a browser on the Pi itself.

## Why Tailscale?

A lot of Raspberry Pi guides still rely on port forwarding, dynamic DNS, or exposing SSH to the public internet. Pi Guardian intentionally avoids that.

Instead, it uses an overlay network. By default, the installer sets up Tailscale and allows SSH and dashboard access only through the `tailscale0` interface.

That means the Pi can be reached from your private tailnet without opening inbound ports on your router.

The installer also avoids a common failure mode: locking yourself out. If Tailscale is not authenticated yet, Pi Guardian skips UFW firewall changes rather than blindly enabling restrictive rules.

That behavior is intentional. A secure installer should not make the machine unreachable during setup.

## What the Installer Does

The heart of the project is `install.sh`.

The script is now self-installing. It does not depend on the rest of the repository being present on the Pi. Internally, it writes the application files using embedded heredocs, creates directories under `/opt/pi-guardian`, installs systemd units, and prepares configuration under `/etc/pi-guardian`.

The major steps are:

```bash
install_dependencies
ensure_app_user
write_application_files
write_config
install_python_env
configure_ssh
install_tailscale
write_systemd_units
enable_services
configure_firewall
```

This keeps the install process readable while still allowing the script to be distributed as a single file.

The installer creates an unprivileged service user:

```bash
APP_USER="pi-guardian"
APP_GROUP="pi-guardian"
```

The dashboard and health agent run as that user, not as root. Backup still runs as root because it needs to read `/etc` and `/home`.

## Tailscale Setup

Tailscale configuration is one of the most important parts of the script because it is also where headless installs often fail.

Pi Guardian supports several flows:

```bash
--ts-authkey KEY
--ts-authkey-file PATH
--ts-hostname NAME
--tailscale-tags tag:server
--no-tailscale-ssh
--skip-tailscale-up
```

If an auth key is provided, the installer runs `tailscale up` non-interactively. If no key is provided and a terminal is available, it starts the interactive login flow. If neither is possible, it installs Tailscale and prints the command to run later.

```bash
sudo tailscale up --ssh
```

The intention is simple: the installer should support both automated provisioning and manual setup without hiding what is happening.

## Health Monitoring

The health agent lives in `health.py`.

It checks:

- CPU temperature
- Disk usage
- Raspberry Pi undervoltage state
- Configured systemd services

Service names come from the environment file:

```bash
SERVICES=ssh tailscaled
TEMP_MAX=80
DISK_PCT_MAX=90
```

The agent reads Raspberry Pi temperature from sysfs when available, with a fallback to `vcgencmd`. It also checks undervoltage bits, which is useful because power problems are one of the most common Raspberry Pi reliability issues.

When something is wrong, Pi Guardian can send alerts through Slack, Telegram, or SMTP email.

The script is deliberately conservative. It avoids shell interpolation for service checks and validates service names before calling systemd. That matters because service names are configuration input, and configuration input should not become shell code.

## The Dashboard

The dashboard is intentionally small. It is a Flask application served on port `8080`.

It shows:

- Hostname and uptime
- Tailscale IP
- LAN IP
- Watched service status
- Last backup timestamp
- Recent health log output

The dashboard is not meant to be a full observability system. It is meant to answer the first questions you ask when a remote Pi feels unhealthy:

- Is it online?
- What IP does it have?
- Are the important services running?
- Did backups happen?
- What did the last health checks report?

The dashboard escapes rendered output before returning HTML. That is important because logs and service output should never be trusted as safe markup.

## Backups

The backup script is `backup.sh`.

It looks for a USB drive with a configurable filesystem label:

```bash
BACKUP_LABEL=PI_BACKUP
BACKUP_MOUNT=/mnt/backup
```

If the drive exists, the script mounts it and creates a compressed archive:

```bash
tar --warning=no-file-changed --ignore-failed-read -czf "$ARCHIVE" /etc /home
```

Backups are retained for seven days.

Older versions could mark a backup as successful even after a hard `tar` failure. The new version checks the tar exit code and verifies that the archive exists before writing `last_backup.txt`.

That small detail matters. A backup system should not create false confidence.

## Systemd as the Runtime

Pi Guardian uses systemd timers instead of cron.

The health timer runs every five minutes:

```ini
[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true
```

The backup timer runs nightly:

```ini
[Timer]
OnCalendar=*-*-* 03:30:00
Persistent=true
```

The dashboard runs as a normal service and restarts on failure.

Using systemd gives the application predictable logs, restart behavior, and status inspection through familiar commands:

```bash
systemctl status pidash.service
journalctl -u pihealth.service -n 100 --no-pager
```

## The Intention

Pi Guardian is not trying to be a large platform. It is a practical safety layer for small devices.

The design priorities are:

- One command should install the system
- Remote access should not require public SSH
- Firewall rules should not lock users out during setup
- Services should run with only the privileges they need
- Health status should be visible without installing a full monitoring stack
- Backups should be automatic and easy to understand

For many Raspberry Pi projects, that is enough.

A Pi running in a closet, garage, lab, or remote site does not always need Kubernetes, Prometheus, or a complex deployment pipeline. Sometimes it needs a secure overlay connection, a dashboard, health checks, and a backup archive on a USB drive.

That is what Pi Guardian provides.

## Final Thoughts

The project started from a common frustration: setting up Tailscale, SSH, firewall rules, health checks, and backups manually on a headless Raspberry Pi is repetitive and easy to get wrong.

Pi Guardian turns that setup into a single script with safer defaults.

It is still intentionally transparent. The installer is just Bash. The monitor and dashboard are small Python files. The services are plain systemd units. Everything can be inspected, modified, or removed.

That is the kind of tooling I prefer for small infrastructure: boring, readable, and useful when something goes wrong.
