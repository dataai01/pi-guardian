# Pi Guardian (v0.2.0)

Pi Guardian is a one-script Raspberry Pi hardening and monitoring installer for
headless devices.

Repository: https://github.com/dataai01/pi-guardian

- Overlay access with Tailscale by default. No port forwarding required.
- Optional SSH key installation and password-login hardening.
- UFW rules that restrict SSH and dashboard access to the overlay interface.
- Health checks for CPU temperature, disk usage, undervoltage, and services.
- Alert delivery through Slack, Telegram, or SMTP.
- A small Flask dashboard on port 8080.
- Nightly `/etc` and `/home` backups to a USB drive labeled `PI_BACKUP`.

Tested target: Raspberry Pi OS / Debian-style systems with `apt` and systemd.

## One-script install

Copy only `install.sh` to the Pi and run it:

```bash
sudo bash ./install.sh
```

The installer is self-contained. It writes the Python app, backup script,
configuration, and systemd units into place.

## Recommended Tailscale install

For a headless Pi, use a Tailscale auth key so the installer can connect the
device without requiring browser login on the Pi:

```bash
export TS_AUTHKEY=<your-tailscale-auth-key>
sudo -E bash ./install.sh --ts-hostname my-pi
```

You can also pass a root-readable key file:

```bash
sudo bash ./install.sh --ts-authkey-file /root/ts-authkey --ts-hostname my-pi
```

If no auth key is provided and the installer has a terminal, it runs
`tailscale up --ssh` interactively and shows the login URL. If there is no
interactive terminal, it installs everything and prints the command to run
later:

```bash
sudo tailscale up --ssh
```

## Common flags

- `--vpn tailscale|wireguard|none` (default: `tailscale`)
- `--ts-hostname my-pi`
- `--tailscale-tags tag:server`
- `--no-tailscale-ssh`
- `--pubkey "<ssh-ed25519 ...>"` or `--pubkey-file "$HOME/.ssh/id_ed25519.pub"`
- `--no-ssh-hardening`
- `--services "ssh tailscaled docker"`
- `--backup-label PI_BACKUP`
- `--dashboard-port 8080`
- `--allow-lan-ssh`
- `--allow-lan-dashboard`
- `--skip-firewall`

## Tailscale troubleshooting

If Tailscale is not authenticated, the installer skips UFW changes by default
to avoid locking you out of SSH. Authenticate Tailscale, then rerun the
installer or configure UFW manually.

Useful diagnostics:

```bash
sudo systemctl status tailscaled --no-pager
sudo tailscale status
sudo tailscale ip
sudo journalctl -u tailscaled -n 100 --no-pager
ls -l /dev/net/tun
```

If an auth key fails, check that it is not expired or revoked, that device
approval is satisfied if your tailnet requires it, and that any requested
`--tailscale-tags` are allowed by your tailnet policy.

## Runtime files

- `/opt/pi-guardian/` - app sources, venv, and scripts
- `/etc/pi-guardian/pi-guardian.env` - configuration
- `/var/lib/pi-guardian/` - runtime state
- `/var/log/pi-guardian-install.log` - installer log
- `pihealth.timer` - health checks every 5 minutes
- `pibackup.timer` - nightly backup at 03:30
- `pidash.service` - dashboard on the configured dashboard port

## Uninstall

```bash
sudo bash ./uninstall.sh
```

The uninstaller removes the app and systemd units, but preserves
`/etc/pi-guardian/pi-guardian.env` and `/var/lib/pi-guardian`.

## Security notes

- By default, UFW only allows SSH and dashboard access on the overlay interface
  after Tailscale is authenticated.
- Use `--allow-lan-ssh` only when you need LAN SSH during setup.
- Use `--allow-lan-dashboard` only on a trusted LAN.
- SSH password login is disabled only after a public key is installed.
- Tailscale auth keys should be treated as secrets. Prefer `TS_AUTHKEY` or
  `--ts-authkey-file` over putting the key directly in shell history.

## License

MIT. See `LICENSE`.
