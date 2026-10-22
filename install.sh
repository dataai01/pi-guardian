#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="0.3.0"
APP_USER="pi-guardian"
APP_GROUP="pi-guardian"
APP_DIR="/opt/pi-guardian"
ENV_DIR="/etc/pi-guardian"
ENV_FILE="$ENV_DIR/pi-guardian.env"
STATE_DIR="/var/lib/pi-guardian"
LOG_FILE="/var/log/pi-guardian-install.log"

VPN="tailscale"
TS_AUTHKEY="${TS_AUTHKEY:-${TS_AUTH_KEY:-}}"
TS_AUTHKEY_FILE=""
TS_HOSTNAME="${TS_HOSTNAME:-}"
TS_ADVERTISE_TAGS="${TS_ADVERTISE_TAGS:-}"
# Preserve an existing SSH mode; new installs use OpenSSH over the VPN.
TAILSCALE_SSH=""
TS_LOGIN_TIMEOUT=300
SKIP_TAILSCALE_UP=0
FORCE_TAILSCALE_RESET=0

PUBKEY=""
PUBKEY_FILE=""
SSH_HARDEN=1
SERVICES="ssh tailscaled"
SERVICES_REQUESTED=0
BACKUP_LABEL="PI_BACKUP"
BACKUP_LABEL_REQUESTED=0
DASH_BIND="0.0.0.0"
DASH_BIND_REQUESTED=0
DASH_PORT="8080"
DASH_PORT_REQUESTED=0
ALLOW_LAN_DASH=0
ALLOW_LAN_SSH=0
SKIP_FIREWALL=0
TAILSCALE_READY=0
TAILSCALE_IP=""
SSH_PORTS=()
RECOVERY_IP=""
RECOVERY_PORT=""
INSTALL_TMP=""

usage() {
  cat <<EOF
Pi Guardian self-contained installer v$VERSION

Usage:
  bash ./install.sh [options]

Recommended non-interactive Tailscale install:
  export TS_AUTHKEY=<tailscale-auth-key>
  bash ./install.sh --ts-hostname my-pi

Options:
  --vpn tailscale|wireguard|none   VPN mode (default: tailscale)
  --ts-authkey KEY                 Tailscale auth key (env TS_AUTHKEY is preferred)
  --ts-authkey-file PATH           Read Tailscale auth key from a root-readable file
  --ts-hostname NAME               Tailscale MagicDNS hostname for this Pi
  --tailscale-tags TAGS            Tailscale advertise tags, for example tag:server
  --tailscale-ssh                  Opt in to Tailscale-managed SSH (requires SSH policy)
  --no-tailscale-ssh               Use OpenSSH instead of Tailscale-managed SSH
  --login-timeout SECONDS          Time to finish browser login (default: 300)
  --skip-tailscale-up              Install Tailscale but do not authenticate/connect it
  --reset-tailscale                Pass --reset to tailscale up when authenticating
  --pubkey "ssh-ed25519 AAAA..."   Install an SSH public key for the primary user
  --pubkey-file PATH               Read an SSH public key from a file
  --no-ssh-hardening               Do not disable SSH password login
  --services "ssh tailscaled"      Services for Pi Guardian to monitor
  --backup-label NAME              USB filesystem label for backups
  --dashboard-bind ADDR            Flask bind address (default: 0.0.0.0)
  --dashboard-port PORT            Dashboard port (default: 8080)
  --allow-lan-dashboard            Also allow dashboard access on LAN
  --allow-lan-ssh                  Keep LAN SSH allowed in UFW
  --skip-firewall                  Do not change UFW rules
  -h|--help                        Show this help

Notes:
  The installer asks for sudo when needed. Without an auth key, open the printed
  login URL on your computer or phone; setup continues automatically after login.
  Your connecting SSH address is kept as a firewall recovery rule.
EOF
}

log() {
  printf '[*] %s\n' "$*"
}

warn() {
  printf '[!] %s\n' "$*" >&2
}

die() {
  warn "$*"
  exit 1
}

on_error() {
  local line="$1"
  local code="$2"
  warn "Install failed at line $line with exit code $code. See $LOG_FILE."
  exit "$code"
}

cleanup() {
  if [[ -n "$INSTALL_TMP" && -d "$INSTALL_TMP" ]]; then
    rm -f -- "$INSTALL_TMP/authkey" "$INSTALL_TMP/tailscale-install.sh"
    rmdir -- "$INSTALL_TMP" || true
  fi
}

require_value() {
  local flag="$1"
  local value="${2:-}"
  if [[ -z "$value" || "$value" == --* ]]; then
    die "$flag requires a value."
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --vpn) require_value "$1" "${2:-}"; VPN="$2"; shift 2;;
      --ts-authkey) require_value "$1" "${2:-}"; TS_AUTHKEY="$2"; shift 2;;
      --ts-authkey-file) require_value "$1" "${2:-}"; TS_AUTHKEY_FILE="$2"; shift 2;;
      --ts-hostname) require_value "$1" "${2:-}"; TS_HOSTNAME="$2"; shift 2;;
      --tailscale-tags|--advertise-tags) require_value "$1" "${2:-}"; TS_ADVERTISE_TAGS="$2"; shift 2;;
      --tailscale-ssh) TAILSCALE_SSH=true; shift;;
      --no-tailscale-ssh) TAILSCALE_SSH=false; shift;;
      --login-timeout) require_value "$1" "${2:-}"; TS_LOGIN_TIMEOUT="$2"; shift 2;;
      --skip-tailscale-up) SKIP_TAILSCALE_UP=1; shift;;
      --reset-tailscale) FORCE_TAILSCALE_RESET=1; shift;;
      --pubkey) require_value "$1" "${2:-}"; PUBKEY="$2"; shift 2;;
      --pubkey-file) require_value "$1" "${2:-}"; PUBKEY_FILE="$2"; shift 2;;
      --no-ssh-hardening) SSH_HARDEN=0; shift;;
      --services) require_value "$1" "${2:-}"; SERVICES="$2"; SERVICES_REQUESTED=1; shift 2;;
      --backup-label) require_value "$1" "${2:-}"; BACKUP_LABEL="$2"; BACKUP_LABEL_REQUESTED=1; shift 2;;
      --dashboard-bind) require_value "$1" "${2:-}"; DASH_BIND="$2"; DASH_BIND_REQUESTED=1; shift 2;;
      --dashboard-port) require_value "$1" "${2:-}"; DASH_PORT="$2"; DASH_PORT_REQUESTED=1; shift 2;;
      --allow-lan-dashboard) ALLOW_LAN_DASH=1; shift;;
      --allow-lan-ssh) ALLOW_LAN_SSH=1; shift;;
      --skip-firewall) SKIP_FIREWALL=1; shift;;
      -h|--help) usage; exit 0;;
      *) die "Unknown option: $1";;
    esac
  done
}

validate_options() {
  case "$VPN" in
    tailscale|wireguard|none) ;;
    *) die "--vpn must be one of: tailscale, wireguard, none";;
  esac

  if ! [[ "$DASH_PORT" =~ ^[0-9]{1,5}$ ]] || (( 10#$DASH_PORT < 1 || 10#$DASH_PORT > 65535 )); then
    die "--dashboard-port must be a TCP port from 1 to 65535."
  fi
  DASH_PORT=$((10#$DASH_PORT))

  if ! [[ "$TS_LOGIN_TIMEOUT" =~ ^[0-9]{1,4}$ ]] || (( 10#$TS_LOGIN_TIMEOUT < 1 || 10#$TS_LOGIN_TIMEOUT > 3600 )); then
    die "--login-timeout must be from 1 to 3600 seconds."
  fi
  TS_LOGIN_TIMEOUT=$((10#$TS_LOGIN_TIMEOUT))
}

prepare_install() {
  if [[ $EUID -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || die "Run this installer as root (sudo is not installed)."
    [[ -f "$0" ]] || die "Download install.sh to a file, then run: bash ./install.sh"
    log "Requesting administrator access..."
    exec sudo --preserve-env=TS_AUTHKEY,TS_AUTH_KEY,TS_HOSTNAME,TS_ADVERTISE_TAGS,SSH_CONNECTION bash "$0" "$@"
  fi

  command -v apt-get >/dev/null 2>&1 || die "This installer supports Raspberry Pi OS and Debian/Ubuntu with apt-get."
  [[ -d /run/systemd/system ]] || die "Boot the Pi into a systemd-based OS before running this installer."
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
  INSTALL_TMP="$(mktemp -d /tmp/pi-guardian.XXXXXXXX)"
  trap cleanup EXIT

  if [[ -n "$TS_AUTHKEY_FILE" ]]; then
    [[ -r "$TS_AUTHKEY_FILE" ]] || die "Cannot read --ts-authkey-file: $TS_AUTHKEY_FILE"
    TS_AUTHKEY="$(tr -d '\r\n' < "$TS_AUTHKEY_FILE")"
    [[ -n "$TS_AUTHKEY" ]] || die "The Tailscale auth key file is empty."
  fi

  if [[ "$SERVICES_REQUESTED" -eq 0 && "$VPN" != "tailscale" ]]; then
    SERVICES="ssh"
  fi
}

write_file() {
  local path="$1"
  local mode="$2"
  local owner="$3"
  install -D -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" /dev/null "$path"
  cat > "$path"
  chmod "$mode" "$path"
  chown "$owner" "$path"
}

ensure_env() {
  local key="$1"
  local value="$2"
  if ! grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
    printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
  fi
}

set_env() {
  local key="$1"
  local value="$2"
  local escaped
  escaped="$(printf '%s' "$value" | sed -e 's/[\/&|\\]/\\&/g')"
  if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${escaped}|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
  fi
}

detect_primary_user() {
  local candidate="${SUDO_USER:-}"
  if [[ -z "$candidate" || "$candidate" == "root" ]]; then
    candidate="$(getent passwd 1000 | cut -d: -f1 || true)"
  fi
  if [[ -z "$candidate" ]]; then
    candidate="pi"
  fi
  printf '%s\n' "$candidate"
}

install_dependencies() {
  command -v apt-get >/dev/null 2>&1 || die "This installer currently supports Debian/Raspberry Pi OS systems with apt-get."

  log "Installing OS dependencies..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get -o Acquire::Retries=3 update -y
  apt-get -o Acquire::Retries=3 install -y ca-certificates curl ufw python3 python3-venv python3-pip iproute2 util-linux openssh-server
  if ! apt-get install -y python3-flask; then
    warn "python3-flask was not available from apt; the installer will use pip in the venv."
  fi
}

ensure_app_user() {
  log "Creating application user and directories..."
  if ! getent group "$APP_GROUP" >/dev/null 2>&1; then
    groupadd --system "$APP_GROUP"
  fi
  if ! id -u "$APP_USER" >/dev/null 2>&1; then
    useradd --system --gid "$APP_GROUP" --home-dir "$APP_DIR" --shell /usr/sbin/nologin "$APP_USER"
  else
    usermod -aG "$APP_GROUP" "$APP_USER" || true
  fi
  if getent group systemd-journal >/dev/null 2>&1; then
    usermod -aG systemd-journal "$APP_USER" || true
  fi

  install -d -m 755 "$APP_DIR" "$APP_DIR/src" "$APP_DIR/src/pi_guardian" "$APP_DIR/scripts"
  install -d -m 750 "$ENV_DIR"
  install -d -o root -g "$APP_GROUP" -m 2750 "$STATE_DIR"
}

write_application_files() {
  log "Writing Pi Guardian application files..."

  write_file "$APP_DIR/src/pi_guardian/health.py" 0755 root:root <<'PY_HEALTH'
#!/usr/bin/env python3
"""Pi Guardian health agent.

Checks CPU temperature, disk usage, undervoltage status, and configured
systemd services. Alerts can be sent through Slack, Telegram, and SMTP.
"""
from __future__ import annotations

import datetime as dt
import json
import os
import pathlib
import re
import shutil
import smtplib
import socket
import ssl
import subprocess
import sys
import urllib.parse
import urllib.request


HOST = socket.gethostname()
STATE_DIR = pathlib.Path(os.getenv("PI_GUARDIAN_STATE_DIR", "/var/lib/pi-guardian"))
SERVICE_RE = re.compile(r"^[A-Za-z0-9_.@:-]+$")


def getenv_float(name: str, default: float) -> float:
    try:
        return float(os.getenv(name, str(default)))
    except (TypeError, ValueError):
        return float(default)


TEMP_MAX = getenv_float("TEMP_MAX", 80)
DISK_PCT_MAX = getenv_float("DISK_PCT_MAX", 90)
SERVICES = [s for s in os.getenv("SERVICES", "ssh tailscaled").split() if s]

SLACK_WEBHOOK = os.getenv("SLACK_WEBHOOK_URL", "")
TG_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN", "")
TG_CHAT = os.getenv("TELEGRAM_CHAT_ID", "")

SMTP_HOST = os.getenv("SMTP_HOST", "")
SMTP_PORT = int(os.getenv("SMTP_PORT", "587") or "587")
SMTP_USER = os.getenv("SMTP_USER", "")
SMTP_PASS = os.getenv("SMTP_PASS", "")
ALERT_TO = os.getenv("ALERT_EMAIL_TO", "")


def ensure_state_dir() -> None:
    try:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        print(f"Could not create {STATE_DIR}: {exc}", file=sys.stderr)


def read_text(path: str) -> str:
    try:
        return pathlib.Path(path).read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def run_cmd(args: list[str], timeout: int = 10) -> tuple[int, str, str]:
    try:
        proc = subprocess.run(
            args,
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
        )
        return proc.returncode, proc.stdout.strip(), proc.stderr.strip()
    except FileNotFoundError as exc:
        return 127, "", str(exc)
    except subprocess.TimeoutExpired:
        return 124, "", "command timed out"


def cpu_temp_c() -> float:
    raw = read_text("/sys/class/thermal/thermal_zone0/temp")
    if raw:
        try:
            return round(int(raw) / 1000.0, 1)
        except ValueError:
            pass

    _, out, _ = run_cmd(["vcgencmd", "measure_temp"])
    match = re.search(r"(-?\d+(?:\.\d+)?)", out)
    return float(match.group(1)) if match else 0.0


def throttled_bits() -> int:
    raw = read_text("/sys/devices/platform/soc/soc:firmware/get_throttled")
    if not raw:
        _, raw, _ = run_cmd(["vcgencmd", "get_throttled"])
        raw = raw.split("=", 1)[-1].strip()

    if raw.startswith("0x"):
        raw = raw[2:]
    try:
        return int(raw, 16)
    except ValueError:
        return 0


def undervolt_status(bits: int) -> dict[str, bool]:
    return {
        "undervolt_now": bool(bits & (1 << 0)),
        "undervolt_ever": bool(bits & (1 << 16)),
    }


def disk_pct(path: str = "/") -> float:
    total, used, _ = shutil.disk_usage(path)
    return round(used / total * 100, 1)


def valid_service_name(service: str) -> bool:
    return bool(SERVICE_RE.fullmatch(service))


def service_bad(service: str) -> bool:
    rc, out, _ = run_cmd(["systemctl", "is-active", service], timeout=5)
    return rc != 0 or out != "active"


def send_slack(msg: str) -> None:
    if not SLACK_WEBHOOK:
        return
    data = json.dumps({"text": msg}).encode("utf-8")
    req = urllib.request.Request(
        SLACK_WEBHOOK,
        data=data,
        headers={"Content-Type": "application/json"},
    )
    urllib.request.urlopen(req, timeout=10).read()


def send_telegram(msg: str) -> None:
    if not (TG_TOKEN and TG_CHAT):
        return
    url = f"https://api.telegram.org/bot{TG_TOKEN}/sendMessage"
    data = urllib.parse.urlencode({"chat_id": TG_CHAT, "text": msg}).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    urllib.request.urlopen(req, timeout=10).read()


def send_email(msg: str) -> None:
    if not (SMTP_HOST and ALERT_TO):
        return

    sender = SMTP_USER or f"pi@{HOST}"
    body = (
        f"From: {sender}\r\n"
        f"To: {ALERT_TO}\r\n"
        f"Subject: Pi Guardian alert ({HOST})\r\n"
        "\r\n"
        f"{msg}"
    )

    ctx = ssl.create_default_context()
    with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=10) as smtp:
        try:
            smtp.starttls(context=ctx)
        except smtplib.SMTPException:
            pass
        if SMTP_USER:
            smtp.login(SMTP_USER, SMTP_PASS)
        smtp.sendmail(sender, [ALERT_TO], body.encode("utf-8"))


def notify(msg: str) -> None:
    print(msg, flush=True)
    for name, fn in (
        ("slack", send_slack),
        ("telegram", send_telegram),
        ("email", send_email),
    ):
        try:
            fn(msg)
        except Exception as exc:
            print(f"{name} notification failed: {exc}", file=sys.stderr)


def main() -> None:
    ensure_state_dir()

    ts = dt.datetime.now().isoformat(timespec="seconds")
    temp = cpu_temp_c()
    disk = disk_pct("/")
    bits = throttled_bits()
    uv = undervolt_status(bits)

    invalid_svcs = [s for s in SERVICES if not valid_service_name(s)]
    checked_svcs = [s for s in SERVICES if valid_service_name(s)]
    bad_svcs = [s for s in checked_svcs if service_bad(s)]

    problems = []
    if temp >= TEMP_MAX:
        problems.append(f"High temp: {temp} C (>= {TEMP_MAX})")
    if disk >= DISK_PCT_MAX:
        problems.append(f"Disk usage: {disk}% (>= {DISK_PCT_MAX}%)")
    if uv["undervolt_now"]:
        problems.append("Undervoltage: ACTIVE")
    elif uv["undervolt_ever"]:
        problems.append("Undervoltage: occurred previously")
    if invalid_svcs:
        problems.append("Invalid service names ignored: " + ", ".join(invalid_svcs))
    if bad_svcs:
        problems.append("Services down: " + ", ".join(bad_svcs))

    summary = (
        f"[{ts}] {HOST} OK. temp={temp} C disk={disk}% "
        f"uv={uv} services={'OK' if not bad_svcs else bad_svcs}"
    )
    if problems:
        notify(
            "Pi Guardian alert on "
            + HOST
            + "\n"
            + "\n".join(f"- {p}" for p in problems)
            + f"\n(temp={temp} C, disk={disk}%)"
        )
    else:
        print(summary)


if __name__ == "__main__":
    main()
PY_HEALTH

  write_file "$APP_DIR/src/pi_guardian/dash.py" 0755 root:root <<'PY_DASH'
#!/usr/bin/env python3
"""Pi Guardian dashboard."""
from __future__ import annotations

import html
import os
import pathlib
import re
import subprocess

from flask import Flask, Response


app = Flask(__name__)
STATE = pathlib.Path(os.getenv("PI_GUARDIAN_STATE_DIR", "/var/lib/pi-guardian"))
SERVICE_RE = re.compile(r"^[A-Za-z0-9_.@:-]+$")


def run_cmd(args: list[str], timeout: int = 8) -> str:
    try:
        proc = subprocess.run(
            args,
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
        )
    except FileNotFoundError:
        return "n/a"
    except subprocess.TimeoutExpired:
        return "timed out"

    out = proc.stdout.strip()
    err = proc.stderr.strip()
    return out if out else err


def esc(value: object) -> str:
    return html.escape(str(value), quote=True)


def first_token(value: str) -> str:
    return value.split()[0] if value.split() else ""


def service_status(service: str) -> str:
    if not SERVICE_RE.fullmatch(service):
        return "invalid name"
    status = run_cmd(["systemctl", "is-active", service], timeout=5)
    return status or "unknown"


def read_last_backup() -> str:
    path = STATE / "last_backup.txt"
    try:
        return path.read_text(encoding="utf-8").strip() or "never"
    except OSError:
        return "never"


@app.route("/")
def index() -> Response:
    tailscale_ip = first_token(run_cmd(["tailscale", "ip", "-4"], timeout=5))
    lan_ip = first_token(run_cmd(["hostname", "-I"], timeout=5))
    host = run_cmd(["hostname"], timeout=5) or "unknown"
    uptime = run_cmd(["uptime", "-p"], timeout=5) or "n/a"
    services = [s for s in os.getenv("SERVICES", "ssh tailscaled").split() if s]
    svc_rows = [(s, service_status(s)) for s in services]
    last_backup = read_last_backup()
    log = run_cmd(["journalctl", "-u", "pihealth.service", "-n", "100", "--no-pager"])

    rows = "".join(
        f"<tr><td>{esc(service)}</td><td>{esc(status)}</td></tr>"
        for service, status in svc_rows
    )
    html_doc = f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Pi Guardian Dashboard</title>
  <style>
    body {{
      color: #17202a;
      font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      line-height: 1.45;
      margin: 0 auto;
      max-width: 960px;
      padding: 2rem 1rem;
    }}
    table {{ border-collapse: collapse; width: 100%; }}
    th, td {{ border: 1px solid #cfd6dd; padding: .55rem .7rem; text-align: left; }}
    th {{ background: #f1f4f7; }}
    code, pre {{
      background: #f6f8fa;
      border: 1px solid #d8dee4;
      border-radius: 6px;
      overflow: auto;
      padding: .75rem;
    }}
    .muted {{ color: #65717e; }}
  </style>
</head>
<body>
  <h1>Pi Guardian</h1>
  <p><strong>Host:</strong> {esc(host)} &nbsp;|&nbsp; <strong>Uptime:</strong> {esc(uptime)}</p>

  <h2>Network</h2>
  <ul>
    <li><strong>Tailscale:</strong> {esc(tailscale_ip or "n/a")}</li>
    <li><strong>LAN:</strong> {esc(lan_ip or "n/a")}</li>
  </ul>

  <h2>Services</h2>
  <table>
    <tr><th>Service</th><th>Status</th></tr>
    {rows}
  </table>

  <h2>Last backup</h2>
  <pre>{esc(last_backup)}</pre>

  <h2>Recent health log</h2>
  <pre>{esc(log)}</pre>

  <p class="muted">The installer restricts port 8080 to the overlay interface unless LAN dashboard access is enabled.</p>
</body>
</html>"""
    return Response(html_doc, mimetype="text/html")


def port_from_env() -> int:
    try:
        return int(os.getenv("DASH_PORT", "8080"))
    except ValueError:
        return 8080


if __name__ == "__main__":
    app.run(host=os.getenv("DASH_BIND", "0.0.0.0"), port=port_from_env())
PY_DASH

  write_file "$APP_DIR/scripts/backup.sh" 0755 root:root <<'SH_BACKUP'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

LABEL="${BACKUP_LABEL:-PI_BACKUP}"
DEST="${BACKUP_MOUNT:-/mnt/backup}"
STATE="${PI_GUARDIAN_STATE_DIR:-/var/lib/pi-guardian}"
MOUNTED=0

cleanup() {
  if [[ "$MOUNTED" == "1" ]]; then
    umount "$DEST" || true
  fi
}
trap cleanup EXIT

mkdir -p "$STATE"

if ! mountpoint -q "$DEST"; then
  DEV="$(blkid -L "$LABEL" || true)"
  if [[ -z "$DEV" ]]; then
    echo "No device labeled $LABEL; skipping backup."
    exit 0
  fi

  mkdir -p "$DEST"
  mount "$DEV" "$DEST"
  MOUNTED=1
fi

STAMP="$(date +%F-%H%M)"
ARCHIVE="$DEST/pi-backup-$STAMP.tgz"

set +e
tar --warning=no-file-changed --ignore-failed-read -czf "$ARCHIVE" /etc /home
TAR_STATUS=$?
set -e

if (( TAR_STATUS > 1 )); then
  rm -f "$ARCHIVE"
  echo "Backup failed; tar exited with status $TAR_STATUS."
  exit "$TAR_STATUS"
fi

if [[ ! -s "$ARCHIVE" ]]; then
  rm -f "$ARCHIVE"
  echo "Backup failed; archive was not created."
  exit 1
fi

find "$DEST" -name "pi-backup-*.tgz" -type f -mtime +7 -delete
{
  printf 'timestamp=%s\n' "$(date -Is)"
  printf 'archive=%s\n' "$ARCHIVE"
  printf 'status=ok\n'
} > "$STATE/last_backup.txt"
SH_BACKUP
}

write_config() {
  log "Writing configuration..."
  if [[ ! -f "$ENV_FILE" ]]; then
    write_file "$ENV_FILE" 0640 root:"$APP_GROUP" <<'ENV_DEFAULT'
# Pi Guardian configuration
TEMP_MAX=80
DISK_PCT_MAX=90

# services to monitor (space-separated)
SERVICES=ssh tailscaled

# dashboard
DASH_BIND=0.0.0.0
DASH_PORT=8080

# notifications (optional)
SLACK_WEBHOOK_URL=
TELEGRAM_BOT_TOKEN=
TELEGRAM_CHAT_ID=

# SMTP email (optional)
SMTP_HOST=
SMTP_PORT=587
SMTP_USER=
SMTP_PASS=
ALERT_EMAIL_TO=

# backups
BACKUP_LABEL=PI_BACKUP
BACKUP_MOUNT=/mnt/backup
PI_GUARDIAN_STATE_DIR=/var/lib/pi-guardian
ENV_DEFAULT
  else
    chown root:"$APP_GROUP" "$ENV_FILE"
    chmod 0640 "$ENV_FILE"
  fi

  ensure_env TEMP_MAX 80
  ensure_env DISK_PCT_MAX 90
  ensure_env SERVICES "ssh tailscaled"
  ensure_env DASH_BIND "0.0.0.0"
  ensure_env DASH_PORT 8080
  ensure_env SLACK_WEBHOOK_URL ""
  ensure_env TELEGRAM_BOT_TOKEN ""
  ensure_env TELEGRAM_CHAT_ID ""
  ensure_env SMTP_HOST ""
  ensure_env SMTP_PORT 587
  ensure_env SMTP_USER ""
  ensure_env SMTP_PASS ""
  ensure_env ALERT_EMAIL_TO ""
  ensure_env BACKUP_LABEL "PI_BACKUP"
  ensure_env BACKUP_MOUNT "/mnt/backup"
  ensure_env PI_GUARDIAN_STATE_DIR "$STATE_DIR"

  if [[ "$SERVICES_REQUESTED" -eq 1 || "$VPN" != "tailscale" ]]; then
    set_env SERVICES "$SERVICES"
  fi
  if [[ "$BACKUP_LABEL_REQUESTED" -eq 1 ]]; then
    set_env BACKUP_LABEL "$BACKUP_LABEL"
  fi
  if [[ "$DASH_BIND_REQUESTED" -eq 1 ]]; then
    set_env DASH_BIND "$DASH_BIND"
  fi
  if [[ "$DASH_PORT_REQUESTED" -eq 1 ]]; then
    set_env DASH_PORT "$DASH_PORT"
  fi

  # Read only dashboard values, never execute the environment file as shell code.
  local key value
  while IFS='=' read -r key value; do
    value="${value%$'\r'}"
    value="${value%\"}"; value="${value#\"}"
    value="${value%\'}"; value="${value#\'}"
    case "$key" in
      DASH_PORT) DASH_PORT="$value";;
      DASH_BIND) DASH_BIND="$value";;
    esac
  done < "$ENV_FILE"
  validate_options
}

write_systemd_units() {
  log "Writing systemd units..."

  write_file /etc/systemd/system/pihealth.service 0644 root:root <<'UNIT_HEALTH'
[Unit]
Description=Pi Guardian health checks
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=pi-guardian
Group=pi-guardian
EnvironmentFile=-/etc/pi-guardian/pi-guardian.env
ExecStart=/opt/pi-guardian/.venv/bin/python /opt/pi-guardian/src/pi_guardian/health.py
Nice=10
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/var/lib/pi-guardian

[Install]
WantedBy=multi-user.target
UNIT_HEALTH

  write_file /etc/systemd/system/pihealth.timer 0644 root:root <<'UNIT_HEALTH_TIMER'
[Unit]
Description=Run Pi Guardian health checks every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
UNIT_HEALTH_TIMER

  write_file /etc/systemd/system/pidash.service 0644 root:root <<'UNIT_DASH'
[Unit]
Description=Pi Guardian dashboard (Flask)
After=network-online.target
Wants=network-online.target

[Service]
User=pi-guardian
Group=pi-guardian
EnvironmentFile=-/etc/pi-guardian/pi-guardian.env
WorkingDirectory=/opt/pi-guardian
ExecStart=/opt/pi-guardian/.venv/bin/python /opt/pi-guardian/src/pi_guardian/dash.py
Restart=on-failure
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadOnlyPaths=/var/lib/pi-guardian

[Install]
WantedBy=multi-user.target
UNIT_DASH

  write_file /etc/systemd/system/pibackup.service 0644 root:root <<'UNIT_BACKUP'
[Unit]
Description=Pi Guardian nightly backup

[Service]
Type=oneshot
EnvironmentFile=-/etc/pi-guardian/pi-guardian.env
ExecStart=/bin/bash /opt/pi-guardian/scripts/backup.sh
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
UNIT_BACKUP

  write_file /etc/systemd/system/pibackup.timer 0644 root:root <<'UNIT_BACKUP_TIMER'
[Unit]
Description=Run Pi Guardian backup nightly

[Timer]
OnCalendar=*-*-* 03:30:00
Persistent=true

[Install]
WantedBy=timers.target
UNIT_BACKUP_TIMER
}

install_python_env() {
  log "Preparing Python virtual environment..."
  python3 -m venv --system-site-packages "$APP_DIR/.venv"

  if ! "$APP_DIR/.venv/bin/python" - <<'PY_CHECK'
import flask
PY_CHECK
  then
    "$APP_DIR/.venv/bin/python" -m pip install --upgrade pip
    "$APP_DIR/.venv/bin/python" -m pip install 'Flask>=3,<4'
  fi

  "$APP_DIR/.venv/bin/python" -m py_compile \
    "$APP_DIR/src/pi_guardian/health.py" \
    "$APP_DIR/src/pi_guardian/dash.py"
}

enable_ssh() {
  log "Enabling OpenSSH..."
  # sshd -t needs the privilege-separation directory even on a fresh install.
  install -d -m 0755 /run/sshd
  sshd -t
  systemctl enable --now ssh
  systemctl is-active --quiet ssh || die "OpenSSH did not start. See: journalctl -u ssh -n 50"
  mapfile -t SSH_PORTS < <(sshd -T | awk '$1 == "port" {print $2}')
  [[ ${#SSH_PORTS[@]} -gt 0 ]] || die "Could not determine the OpenSSH listening port."
}

configure_ssh() {
  local primary_user
  local home_dir
  local key_installed=0
  primary_user="$(detect_primary_user)"

  if [[ -n "$PUBKEY_FILE" && -z "$PUBKEY" ]]; then
    if [[ -r "$PUBKEY_FILE" ]]; then
      PUBKEY="$(cat "$PUBKEY_FILE")"
    else
      warn "--pubkey-file specified but not readable: $PUBKEY_FILE"
    fi
  fi

  if [[ -n "$PUBKEY" ]]; then
    if id -u "$primary_user" >/dev/null 2>&1; then
      home_dir="$(getent passwd "$primary_user" | cut -d: -f6)"
      if [[ -n "$home_dir" && -d "$home_dir" ]]; then
        log "Installing SSH public key for $primary_user..."
        install -d -m 700 -o "$primary_user" -g "$primary_user" "$home_dir/.ssh"
        touch "$home_dir/.ssh/authorized_keys"
        if ! grep -Fxq "$PUBKEY" "$home_dir/.ssh/authorized_keys"; then
          printf '%s\n' "$PUBKEY" >> "$home_dir/.ssh/authorized_keys"
        fi
        chown "$primary_user:$primary_user" "$home_dir/.ssh/authorized_keys"
        chmod 600 "$home_dir/.ssh/authorized_keys"
        key_installed=1
      else
        warn "Could not find a home directory for $primary_user; skipping SSH key install."
      fi
    else
      warn "Primary user $primary_user does not exist; skipping SSH key install."
    fi
  else
    warn "No --pubkey provided. SSH key installation skipped."
  fi

  if [[ "$SSH_HARDEN" -eq 1 ]]; then
    if [[ "$key_installed" -eq 1 ]]; then
      log "Disabling SSH password authentication..."
      mkdir -p /etc/ssh/sshd_config.d
      cat >/etc/ssh/sshd_config.d/10-pi-guardian.conf <<'SSH_CONFIG'
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
SSH_CONFIG
      if command -v sshd >/dev/null 2>&1; then
        sshd -t
      fi
      systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
    else
      warn "SSH passwords were not disabled because no public key was installed."
    fi
  fi
}

tailscale_diagnostics() {
  warn "Tailscale diagnostics:"
  timeout 10 systemctl --no-pager --full status tailscaled || true
  timeout 10 tailscale status || true
  ls -l /dev/net/tun || true
}

refresh_tailscale_status() {
  local status
  TAILSCALE_READY=0
  TAILSCALE_IP=""
  status="$(timeout 10 tailscale status --json 2>/dev/null)" || return 1
  if ! TAILSCALE_IP="$(printf '%s' "$status" | python3 -c '
import ipaddress, json, sys
try:
    status = json.load(sys.stdin)
    if status.get("BackendState") != "Running" or not status.get("TUN"):
        sys.exit(1)
    if not (status.get("Self") or {}).get("Online"):
        sys.exit(1)
    address = next(ipaddress.ip_address(value) for value in status.get("TailscaleIPs", [])
                   if ipaddress.ip_address(value).version == 4)
    print(address)
except (ValueError, TypeError, AttributeError, StopIteration):
    sys.exit(1)
')"; then
    return 1
  fi
  ip link show tailscale0 >/dev/null 2>&1 || return 1
  TAILSCALE_READY=1
}

wait_for_tailscale() {
  local attempt
  for attempt in {1..15}; do
    if refresh_tailscale_status; then
      return 0
    fi
    sleep 2
  done
  return 1
}

install_tailscale() {
  if [[ "$VPN" != "tailscale" ]]; then
    return
  fi

  if ! command -v tailscale >/dev/null 2>&1; then
    log "Installing Tailscale..."
    curl --fail --show-error --silent --location --retry 3 --connect-timeout 15 --max-time 120 \
      https://tailscale.com/install.sh -o "$INSTALL_TMP/tailscale-install.sh"
    sh "$INSTALL_TMP/tailscale-install.sh"
  else
    log "Tailscale is already installed."
  fi

  if [[ ! -e /dev/net/tun ]]; then
    log "Loading the tun kernel module..."
    modprobe tun || die "The tun kernel module is unavailable; cannot set up remote access."
  fi
  [[ -c /dev/net/tun ]] || die "/dev/net/tun is missing. Remote access needs a kernel TUN device."
  systemctl enable --now tailscaled

  local attempt daemon_ready=0
  for attempt in {1..15}; do
    if timeout 10 tailscale status --json >/dev/null 2>&1; then
      daemon_ready=1
      break
    fi
    sleep 2
  done
  [[ "$daemon_ready" -eq 1 ]] || die "tailscaled did not become ready. See: journalctl -u tailscaled -n 50"

  if [[ "$SKIP_TAILSCALE_UP" -eq 1 ]]; then
    refresh_tailscale_status || true
    warn "Skipping Tailscale login as requested."
    return
  fi

  connect_tailscale
}

connect_tailscale() {
  # Keep a resumed 'up' completely flag-free. Even --timeout prevents Tailscale's
  # preserve-existing-preferences shortcut; enforce the deadline externally.
  local up_args=(up)
  local set_args=(set)
  local connected=0
  if refresh_tailscale_status; then
    connected=1
  fi

  # A plain 'up' resumes an existing profile without resetting DNS/routes/etc.
  # --reset is used only when explicitly requested by the caller.
  if [[ "$FORCE_TAILSCALE_RESET" -eq 1 ]]; then
    up_args+=(--reset)
    [[ -z "$TS_HOSTNAME" ]] || up_args+=("--hostname=$TS_HOSTNAME")
    [[ -z "$TAILSCALE_SSH" ]] || up_args+=("--ssh=$TAILSCALE_SSH")
  else
    [[ -z "$TS_HOSTNAME" ]] || set_args+=("--hostname=$TS_HOSTNAME")
    [[ -z "$TAILSCALE_SSH" ]] || set_args+=("--ssh=$TAILSCALE_SSH")
  fi
  [[ -z "$TS_ADVERTISE_TAGS" ]] || up_args+=("--advertise-tags=$TS_ADVERTISE_TAGS")
  if [[ "$connected" -eq 0 || "$FORCE_TAILSCALE_RESET" -eq 1 || -n "$TS_ADVERTISE_TAGS" ]]; then
    if [[ -n "$TS_AUTHKEY" && "$connected" -eq 0 ]]; then
      log "Connecting Tailscale with the supplied auth key..."
      # Keep the secret out of process arguments and remove it immediately after use.
      (umask 077; printf '%s' "$TS_AUTHKEY" > "$INSTALL_TMP/authkey")
      up_args+=("--auth-key=file:$INSTALL_TMP/authkey")
    else
      log "Open the Tailscale login link below on your computer or phone if prompted."
      log "Waiting up to $TS_LOGIN_TIMEOUT seconds for login/device approval..."
    fi
    local result=0
    timeout --foreground "$TS_LOGIN_TIMEOUT" tailscale "${up_args[@]}" || result=$?
    rm -f -- "$INSTALL_TMP/authkey"
    unset TS_AUTHKEY TS_AUTH_KEY
    if [[ "$result" -ne 0 ]]; then
      tailscale_diagnostics
      die "Tailscale setup did not finish. Complete the login/device approval and rerun this installer. Check the key or tags if supplied. Existing profile preferences are preserved; any required flags are shown above."
    fi
  else
    log "Using the existing Tailscale connection."
  fi

  if [[ ${#set_args[@]} -gt 1 ]]; then
    timeout 30 tailscale "${set_args[@]}" || die "Could not apply the requested Tailscale preferences. Existing SSH sessions may require reconnecting if you explicitly changed SSH mode."
  fi
  unset TS_AUTHKEY TS_AUTH_KEY
  if ! wait_for_tailscale; then
    tailscale_diagnostics
    die "Tailscale is not online with a usable tunnel. Check login, device approval, key expiry, and network connectivity, then rerun this installer."
  fi
  log "Tailscale connected: $TAILSCALE_IP"
}

install_wireguard_tools() {
  if [[ "$VPN" != "wireguard" ]]; then
    return
  fi
  log "Installing WireGuard tools..."
  apt-get install -y wireguard-tools
  warn "WireGuard tools are installed, but Pi Guardian does not generate a wg0 tunnel configuration."
}

detect_recovery_connection() {
  [[ -n "${SSH_CONNECTION:-}" ]] || return 0
  local connection
  connection="$(python3 -c '
import ipaddress, os, sys
try:
    client, client_port, server, server_port = os.environ["SSH_CONNECTION"].split()
    client = ipaddress.ip_address(client)
    ipaddress.ip_address(server)
    port = int(server_port)
    if not 1 <= port <= 65535:
        raise ValueError("invalid port")
    print(client, port)
except (ValueError, KeyError):
    sys.exit(1)
')" || die "Cannot identify the current SSH connection; refusing to change the firewall."
  read -r RECOVERY_IP RECOVERY_PORT <<< "$connection"
}

configure_firewall() {
  if [[ "$SKIP_FIREWALL" -eq 1 ]]; then
    warn "Skipping firewall configuration as requested."
    return
  fi

  if [[ "$VPN" == "tailscale" ]] && ! refresh_tailscale_status; then
    warn "Tailscale is not connected; skipping UFW changes to preserve current access."
    if [[ "$SKIP_TAILSCALE_UP" -ne 1 ]]; then
      die "The Tailscale connection was lost. Check connectivity and rerun the installer."
    fi
    return
  fi
  if [[ "$VPN" == "wireguard" ]] && ! ip link show wg0 >/dev/null 2>&1; then
    warn "wg0 is not configured; skipping UFW changes to preserve current access."
    return
  fi
  if [[ "$VPN" == "none" && "$ALLOW_LAN_SSH" -ne 1 ]]; then
    warn "No VPN selected; skipping UFW changes. Use --allow-lan-ssh to configure LAN access."
    return
  fi

  detect_recovery_connection
  log "Configuring UFW..."
  # Add recovery/allow rules before changing policy or enabling UFW. Inserting
  # recovery first also handles an existing broad deny rule for the SSH port.
  if [[ -n "$RECOVERY_IP" ]]; then
    ufw insert 1 allow proto tcp from "$RECOVERY_IP" to any port "$RECOVERY_PORT" comment 'Pi Guardian installer recovery'
    log "Keeping SSH from $RECOVERY_IP on port $RECOVERY_PORT for recovery."
  fi

  local overlay_interface="" port
  case "$VPN" in
    tailscale) overlay_interface=tailscale0;;
    wireguard) overlay_interface=wg0;;
  esac
  if [[ -n "$overlay_interface" ]]; then
    for port in "${SSH_PORTS[@]}" 22; do
      ufw allow in on "$overlay_interface" to any port "$port" proto tcp
    done
    ufw allow in on "$overlay_interface" to any port "$DASH_PORT" proto tcp
  fi

  if [[ "$ALLOW_LAN_SSH" -eq 1 ]]; then
    for port in "${SSH_PORTS[@]}"; do
      ufw allow "$port/tcp"
    done
  fi

  if [[ "$ALLOW_LAN_DASH" -eq 1 ]]; then
    warn "Allowing dashboard on LAN port $DASH_PORT."
    ufw allow "$DASH_PORT/tcp"
  fi

  ufw --force default deny incoming
  ufw --force default allow outgoing
  ufw --force enable
  ufw status verbose || true
}

enable_services() {
  log "Enabling systemd services..."
  systemctl daemon-reload
  systemctl enable --now pihealth.timer
  systemctl enable --now pibackup.timer
  systemctl enable --now pidash.service
  systemctl restart pidash.service
  systemctl start pihealth.service || warn "Initial health check failed; inspect with: journalctl -u pihealth.service -n 100 --no-pager"
}

verify_dashboard() {
  local host="$DASH_BIND" attempt ready=0
  case "$host" in
    0.0.0.0) host=127.0.0.1;;
    ::) host='[::1]';;
    *:*) host="[$host]";;
  esac
  for attempt in {1..10}; do
    if curl --noproxy '*' --fail --silent --max-time 10 "http://$host:$DASH_PORT/" >/dev/null; then
      ready=1
      break
    fi
    sleep 2
  done
  [[ "$ready" -eq 1 ]] || die "The dashboard did not respond on $host:$DASH_PORT. See: journalctl -u pidash.service -n 50"
  systemctl is-active --quiet pidash.service || die "The dashboard service stopped unexpectedly."
  if [[ "$VPN" == "tailscale" && "$TAILSCALE_READY" -eq 1 ]]; then
    curl --noproxy '*' --fail --silent --show-error --max-time 20 "http://$TAILSCALE_IP:$DASH_PORT/" >/dev/null \
      || die "The dashboard is not reachable at the Tailscale address. Check DASH_BIND in $ENV_FILE (normally 0.0.0.0)."
  fi
}

print_summary() {
  echo
  log "Installation complete."
  echo "    Health checks:   pihealth.timer (every 5 minutes)"
  echo "    Dashboard:       pidash.service (port $DASH_PORT)"
  echo "    Backups:         pibackup.timer (03:30)"
  echo "    Config:          $ENV_FILE"
  echo "    Install log:     $LOG_FILE"
  if [[ "$VPN" == "tailscale" && "$TAILSCALE_READY" -eq 1 ]]; then
    echo "    Dashboard URL:   http://$TAILSCALE_IP:$DASH_PORT/"
    echo "    SSH:             ssh -p ${SSH_PORTS[0]} $(detect_primary_user)@$TAILSCALE_IP"
    echo "    Connect your computer/phone to the same Tailscale network first."
    echo "    Local tunnel and dashboard checks passed; access from another device depends on your tailnet policy."
  elif [[ "$VPN" == "tailscale" ]]; then
    warn "Remote access is NOT ready (--skip-tailscale-up was requested). Rerun without that flag to finish."
  elif [[ "$VPN" == "wireguard" ]]; then
    echo "    Remote access:   configure and test wg0 separately."
  fi
  if [[ -n "$RECOVERY_IP" ]]; then
    echo "    Recovery SSH:    $RECOVERY_IP -> port $RECOVERY_PORT (UFW rule retained)"
  fi
}

main() {
  parse_args "$@"
  validate_options
  trap 'on_error "$LINENO" "$?"' ERR
  prepare_install "$@"
  log "Starting Pi Guardian installer v$VERSION..."
  install_dependencies
  ensure_app_user
  write_application_files
  write_config
  install_python_env
  enable_ssh
  install_tailscale
  install_wireguard_tools
  write_systemd_units
  enable_services
  verify_dashboard
  configure_ssh
  configure_firewall
  print_summary
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
