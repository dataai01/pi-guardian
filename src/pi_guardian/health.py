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
