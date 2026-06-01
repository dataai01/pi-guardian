#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Please run with sudo/root."
  exit 1
fi

echo "[*] Disabling services..."
systemctl disable --now pihealth.timer || true
systemctl stop pihealth.service || true
systemctl disable --now pidash.service || true
systemctl disable --now pibackup.timer || true
systemctl stop pibackup.service || true

echo "[*] Removing systemd unit files..."
rm -f /etc/systemd/system/pihealth.service
rm -f /etc/systemd/system/pihealth.timer
rm -f /etc/systemd/system/pidash.service
rm -f /etc/systemd/system/pibackup.service
rm -f /etc/systemd/system/pibackup.timer
systemctl daemon-reload

echo "[*] Removing application..."
rm -rf /opt/pi-guardian

echo "[*] Preserving config at /etc/pi-guardian/pi-guardian.env and backups in /var/lib/pi-guardian."
echo "[*] Leaving UFW rules, Tailscale, SSH hardening, and the pi-guardian user unchanged."
echo "[OK] Uninstall complete."
