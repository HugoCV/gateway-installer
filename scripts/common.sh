#!/usr/bin/env bash

INSTALLER_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_REPO_URL="https://github.com/HugoCV/gateway.git"
DEFAULT_REF="master"
LIGHTDM_AUTLOGIN_FILE="/etc/lightdm/lightdm.conf.d/90-gateway-autologin.conf"

log() {
  printf '%s\n' "$*"
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

detect_install_user() {
  if [ -n "${GATEWAY_INSTALL_USER:-}" ]; then
    INSTALL_USER="$GATEWAY_INSTALL_USER"
  elif [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    INSTALL_USER="$SUDO_USER"
  else
    INSTALL_USER="$(id -un)"
  fi

  INSTALL_HOME="$(getent passwd "$INSTALL_USER" | cut -d: -f6)"
  [ -n "$INSTALL_HOME" ] || fail "No se encontró el home de $INSTALL_USER."
}

run_as_install_user() {
  if [ "$(id -un)" = "$INSTALL_USER" ]; then
    "$@"
  else
    sudo -u "$INSTALL_USER" "$@"
  fi
}

as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

require_linux() {
  [ "$(uname -s)" = "Linux" ] ||
    fail "El instalador solo puede ejecutarse en Linux."
  command -v apt-get >/dev/null 2>&1 ||
    fail "Este instalador requiere una distribución basada en apt."
}

require_sudo() {
  if [ "$(id -u)" -eq 0 ]; then
    return
  fi
  sudo -v || fail "No se pudieron obtener privilegios administrativos."
}

validate_app_dir() {
  case "$APP_DIR" in
    ""|"/"|"$INSTALL_HOME"|"/home"|"/opt"|"/usr"|"/var")
      fail "Directorio de instalación inseguro: $APP_DIR"
      ;;
  esac
}

ensure_clean_repository() {
  configure_repository_excludes
  if [ -n "$(run_as_install_user git -C "$APP_DIR" status --porcelain)" ]; then
    fail "La instalación tiene cambios locales. Guárdelos antes de continuar."
  fi
}

configure_repository_excludes() {
  local exclude_file="$APP_DIR/.git/info/exclude"
  local pattern

  for pattern in "/start.sh" "/gateway.log" "/venv/" "/.env"; do
    if ! run_as_install_user grep -qxF "$pattern" "$exclude_file"; then
      printf '%s\n' "$pattern" |
        run_as_install_user tee -a "$exclude_file" >/dev/null
    fi
  done
}

checkout_ref() {
  local repo_url="$1"
  local ref="$2"

  if [ -d "$APP_DIR/.git" ]; then
    ensure_clean_repository
    run_as_install_user git -C "$APP_DIR" remote set-url origin "$repo_url"
    run_as_install_user git -C "$APP_DIR" fetch --prune --tags origin
  else
    [ ! -e "$APP_DIR" ] ||
      fail "$APP_DIR existe, pero no es un repositorio Git."
    run_as_install_user git clone "$repo_url" "$APP_DIR"
    run_as_install_user git -C "$APP_DIR" fetch --prune --tags origin
  fi
  configure_repository_excludes

  if run_as_install_user git -C "$APP_DIR" show-ref \
    --verify --quiet "refs/remotes/origin/$ref"; then
    run_as_install_user git -C "$APP_DIR" checkout -B "$ref" "origin/$ref"
  else
    run_as_install_user git -C "$APP_DIR" checkout --detach "$ref"
  fi
}

create_start_script() {
  local start_script="$APP_DIR/start.sh"
  local venv_dir="$APP_DIR/venv"

  as_root tee "$start_script" >/dev/null <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "$APP_DIR"
exec "$venv_dir/bin/python" main.py >> "$APP_DIR/gateway.log" 2>&1
EOF
  as_root chown "$INSTALL_USER:$INSTALL_USER" "$start_script"
  as_root chmod 755 "$start_script"
}

configure_autostart() {
  local autostart_dir="$INSTALL_HOME/.config/autostart"
  local destination="$autostart_dir/gateway.desktop"
  local start_script="$APP_DIR/start.sh"
  local temporary

  temporary="$(mktemp)"
  python3 - \
    "$INSTALLER_ROOT/templates/gateway.desktop" \
    "$temporary" \
    "$start_script" <<'PY'
from pathlib import Path
import sys

source, destination, start_script = sys.argv[1:]
content = Path(source).read_text(encoding="utf-8")
Path(destination).write_text(
    content.replace("@START_SCRIPT@", start_script),
    encoding="utf-8",
)
PY

  run_as_install_user mkdir -p "$autostart_dir"
  as_root install -m 644 -o "$INSTALL_USER" -g "$INSTALL_USER" \
    "$temporary" "$destination"
  rm -f "$temporary"
  log "Autostart gráfico configurado en $destination"
}

configure_autologin() {
  local temporary
  temporary="$(mktemp)"
  python3 - \
    "$INSTALLER_ROOT/templates/lightdm-autologin.conf" \
    "$temporary" \
    "$INSTALL_USER" <<'PY'
from pathlib import Path
import sys

source, destination, username = sys.argv[1:]
content = Path(source).read_text(encoding="utf-8")
Path(destination).write_text(
    content.replace("@USER@", username),
    encoding="utf-8",
)
PY

  as_root install -d -m 755 /etc/lightdm/lightdm.conf.d
  as_root install -m 644 "$temporary" "$LIGHTDM_AUTLOGIN_FILE"
  rm -f "$temporary"
  log "Autologin de LightDM configurado para $INSTALL_USER"
}

show_installed_version() {
  local revision
  revision="$(run_as_install_user git -C "$APP_DIR" rev-parse --short HEAD)"
  log "Gateway instalado en $APP_DIR (commit $revision)"
}
