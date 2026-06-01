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
