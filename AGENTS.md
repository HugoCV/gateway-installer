# Project Notes

This directory contains the graphical and CLI Gateway installer for deploying
the application on a Linux desktop device.

## Current Files

- `launcher.sh`: validates Python, Tkinter, and sudo before opening the GUI.
- `installer_gui.py`: Tkinter interface for install, repair, update, and uninstall.
- `build-deb.sh`: builds the architecture-independent Debian package.
- `VERSION`: source of truth for the Debian package version.
- `packaging/`: package builder, application launcher, and desktop entry.
- `install-gateway.sh`: compatibility wrapper for the CLI installer.
- `scripts/`: CLI implementation shared by the GUI and terminal workflows.
- `templates/`: desktop autostart and optional LightDM configuration templates.
- `templates/alrotek-gateway.service`: systemd unit used for headless operation.
- `.env.example`: credential-free configuration template.
- `.env`: Local environment settings. Treat as secret-bearing and do not print values in logs or chat.

## Safety Notes

- `scripts/install.sh` may write the user's `.config/autostart/gateway.desktop` file when `--autostart` is selected.
- The systemd service and graphical autostart are mutually exclusive because both processes would access the same device ports.
- LightDM may only be changed through the explicit `--autologin` option. Keep its configuration isolated in `/etc/lightdm/lightdm.conf.d/90-gateway-autologin.conf`.
- The installer uses `apt-get` for system packages. Do not add other desktop-session, login-manager, display-manager, LXDE, or unrelated `/etc` changes.
- Do not run the script automatically during routine code changes or analysis.
- Ask before changing target system paths, desktop/login behavior, service restart behavior, or the hard-coded deployment user.
- Preserve executable bits on `launcher.sh`, `install-gateway.sh`, and `scripts/*.sh`.
- Never include `.env` or another credential-bearing file in the Debian package.
- The current `.env` contains duplicate `RS485` keys. Check intended precedence before editing.

## Verification

- Static checks:
  - `bash -n launcher.sh install-gateway.sh scripts/*.sh`
  - `python3 -m py_compile installer_gui.py packaging/build_deb.py`
  - `./build-deb.sh`
- Shell lint, if available: `shellcheck launcher.sh install-gateway.sh build-deb.sh scripts/*.sh`

## Style

- Keep shell scripts POSIX-ish where practical, but Bash is acceptable because the script already uses `#!/usr/bin/env bash` and `set -euo pipefail`.
- Prefer explicit variables at the top of the script for deployment paths, users, and entrypoints.
- Keep comments focused on operational intent and system side effects.
