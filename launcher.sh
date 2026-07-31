#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif command -v pkexec >/dev/null 2>&1; then
    pkexec "$@"
  else
    sudo "$@"
  fi
}

if [ "$(uname -s)" != "Linux" ]; then
  printf 'El instalador gráfico solo puede ejecutarse en Linux.\n' >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  as_root apt-get update
  as_root apt-get install -y python3
fi

if ! python3 -c 'import tkinter' >/dev/null 2>&1; then
  as_root apt-get update
  as_root apt-get install -y python3-tk
fi

exec python3 "$SCRIPT_DIR/installer_gui.py"
