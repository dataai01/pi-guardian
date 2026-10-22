# Pi Guardian (v0.3.0)

![Pi Guardian hero image](assets/pi-guardian-hero.png)

Pi Guardian sets up remote access, health monitoring, and nightly backups for a
Raspberry Pi. It targets Raspberry Pi OS and Debian-style Linux systems with
`apt` and systemd.

Repository: https://github.com/dataai01/pi-guardian

- Tailscale remote access without router port forwarding.
- OpenSSH, optional public-key installation, and firewall rules for remote access.
- Temperature, disk usage, undervoltage, and service checks every five minutes.
- Optional Slack, Telegram, and email alerts.
- A small Flask dashboard, normally on port 8080.
- Nightly `/etc` and `/home` backups to a USB drive labeled `PI_BACKUP`.

## Install on the Pi

From this repository's folder, run one command:

```bash
bash ./install.sh
```

The installer requests sudo if necessary, installs dependencies, and starts
Tailscale. Open the login link it prints on your computer or phone. Once you
authorize the Pi, installation continues automatically and prints the dashboard
address and SSH command. Your computer or phone must also be connected to the
same Tailscale network to use those addresses.

On Raspberry Pi OS Desktop, you can instead open **Pi-Guardian-Install.desktop**
from the downloaded repository folder. If the file manager asks, mark it as
trusted/executable and choose **Execute** or **Allow Launching**. Keep it beside
`install-desktop.sh` and `install.sh`. It opens a terminal and keeps the result
visible. The desktop launcher uses the desktop OS's Python 3 installation.

An initial Tailscale account login is required unless you supply an auth key.
Setup waits five minutes by default; use `--login-timeout 600` for more time.
If your tailnet requires device approval, approve the Pi while setup is waiting.

Only `install.sh` is needed for terminal installation. To download the published
version directly from GitHub and run it:

```bash
curl -fL --retry 3 https://raw.githubusercontent.com/dataai01/pi-guardian/main/install.sh -o pi-guardian-install.sh && bash ./pi-guardian-install.sh
```

The download must complete successfully before the installer runs. The script
contains the application, configuration defaults, backup script, and systemd
units; no repository clone is needed.

## Unattended installation

Provide a root-readable Tailscale auth-key file to skip browser login:

```bash
bash ./install.sh --ts-authkey-file /root/ts-authkey --ts-hostname my-pi
```

An exported `TS_AUTHKEY` (or `TS_AUTH_KEY`) is also supported and is preserved
when the installer requests sudo. Do not put secret keys directly into shell
history. The installer passes keys to Tailscale through a temporary private file
and removes its temporary copy after use; your original key file is retained.

For an already connected Pi, rerunning the installer reuses the connection.
Normal reruns preserve existing Tailscale preferences and SSH mode. Fresh
installs use regular OpenSSH over the Tailscale network, with the Pi's existing
user password or SSH key.

## Common options

- `--ts-hostname my-pi`
- `--login-timeout 600`
- `--pubkey-file "$HOME/.ssh/id_ed25519.pub"`
- `--pubkey "<ssh-ed25519 ...>"`
- `--no-ssh-hardening`
- `--services "ssh tailscaled docker"`
- `--backup-label PI_BACKUP`
- `--dashboard-port 8080`
- `--allow-lan-ssh`
- `--allow-lan-dashboard`
- `--skip-firewall`
- `--tailscale-ssh` to explicitly enable Tailscale-managed SSH
- `--no-tailscale-ssh` to explicitly switch back to OpenSSH
- `--tailscale-tags tag:server` for enrollment under your tailnet's tag policy
- `--skip-tailscale-up` to deliberately leave login for later
- `--vpn tailscale|wireguard|none` (default: `tailscale`)

Tailscale-managed SSH needs SSH access rules in your tailnet policy. Changing
SSH mode can interrupt an SSH session over Tailscale; make that change from a
LAN connection or local console. See the [Tailscale SSH documentation](https://tailscale.com/docs/features/tailscale-ssh).

WireGuard mode installs tools but requires an existing `wg0` configuration.
It is not an automatic alternative to Tailscale setup.

## Recovery and troubleshooting

Setup checks the running Tailscale state, a kernel tunnel, and the dashboard's
HTTP response before reporting the default installation complete. These are
checks on the Pi; connectivity from a second device still depends on the client
being online and your tailnet access policy.

When installing over SSH, the installer retains a UFW allow rule for the
connecting IP address and SSH port before restricting incoming traffic. This
recovery rule persists across reboots. Existing firewall rules are retained.
After verifying access from another device, you can review/remove the recovery
rule using `sudo ufw status numbered` and `sudo ufw delete <rule-number>`.

Failed Tailscale login stops setup before SSH password hardening and firewall
changes. Rerun the same install command after correcting the reported issue.
With `--skip-tailscale-up`, setup explicitly reports that remote access is not
ready and leaves the firewall unchanged if Tailscale is offline.

Useful diagnostics:

```bash
sudo tailscale status
sudo systemctl status tailscaled ssh pidash --no-pager
sudo journalctl -u tailscaled -n 50 --no-pager
sudo journalctl -u pidash.service -n 50 --no-pager
sudo ufw status verbose
sudo cat /var/log/pi-guardian-install.log
```

If authentication fails, check the auth key's validity, device approval, and tag
permissions. If Tailscale asks for existing non-default flags when you supply
new tags or reauthenticate an expired profile, follow its printed command and
rerun the installer. The installer does not silently reset those preferences.
`--reset-tailscale` is available only for an intentional reset.

If the dashboard works locally but fails its Tailscale-address check, ensure
`DASH_BIND=0.0.0.0` in `/etc/pi-guardian/pi-guardian.env`, then rerun setup.
Saved custom dashboard ports are reused for checks, firewall rules, and URLs.

## Runtime files

- `/opt/pi-guardian/` - app sources, virtual environment, and scripts
- `/etc/pi-guardian/pi-guardian.env` - configuration
- `/var/lib/pi-guardian/` - runtime state
- `/var/log/pi-guardian-install.log` - root-readable installer log
- `pihealth.timer` - health checks every five minutes
- `pibackup.timer` - nightly backup at 03:30
- `pidash.service` - dashboard

SSH password login is disabled only when a public key is installed by the
installer. Notification credentials and the backup drive are optional setup.
Use LAN dashboard access only on a trusted network.

## Development checks

```bash
python3 -m unittest discover -s tests -v
```

Tests use fake Tailscale, systemd, HTTP, and firewall commands; they do not modify
the host's services or network. They cover login with redirected output,
timeouts, stale connection state, reruns, saved dashboard ports, and recovery
rules. A live Raspberry Pi test is still needed to verify OS integration and
access from another Tailscale device.

## Uninstall

```bash
sudo bash ./uninstall.sh
```

The uninstaller removes the app and systemd units but preserves configuration,
runtime state, Tailscale, OpenSSH settings, and firewall rules.

## License

MIT. See `LICENSE`.
