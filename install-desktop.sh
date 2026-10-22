#!/usr/bin/env bash
# Launcher for Raspberry Pi OS desktops. Keep this beside install.sh.
set -uo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")" || exit 1
bash ./install.sh "$@"
result=$?
echo
if [[ "$result" -ne 0 ]]; then
  echo "Setup did not finish. The error and recovery instructions are above."
fi
if [[ -t 0 ]]; then
  read -r -p "Press Enter to close this window..." || true
fi
exit "$result"
