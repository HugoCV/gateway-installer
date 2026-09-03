#!/usr/bin/env bash

INSTALLER_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_REPO_URL="https://github.com/HugoCV/gateway.git"
DEFAULT_REF="main"
MIN_PYTHON_MAJOR=3
MIN_PYTHON_MINOR=10
LIGHTDM_AUTLOGIN_FILE="/etc/lightdm/lightdm.conf.d/90-gateway-autologin.conf"
GATEWAY_SERVICE_NAME="alrotek-gateway.service"
GATEWAY_SERVICE_FILE="/etc/systemd/system/$GATEWAY_SERVICE_NAME"

log() {
  printf '%s\n' "$*"
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

python_is_supported() {
  "$1" -c "import sys; raise SystemExit(0 if sys.version_info >= ($MIN_PYTHON_MAJOR, $MIN_PYTHON_MINOR) else 1)" \
    >/dev/null 2>&1
}

require_supported_python() {
  local python_bin="$1"
  local detected_version

  command -v "$python_bin" >/dev/null 2>&1 ||
    fail "No se encontró el intérprete de Python: $python_bin."
  detected_version="$($python_bin -c 'import platform; print(platform.python_version())')"
  python_is_supported "$python_bin" ||
    fail "Gateway requiere Python ${MIN_PYTHON_MAJOR}.${MIN_PYTHON_MINOR} o superior; se encontró $detected_version."
  log "Python compatible detectado: $detected_version ($python_bin)."
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

remove_autostart() {
  run_as_install_user rm -f -- "$INSTALL_HOME/.config/autostart/gateway.desktop"
}

service_is_installed() {
  [ -f "$GATEWAY_SERVICE_FILE" ]
}

service_is_active() {
  service_is_installed &&
    as_root systemctl is-active --quiet "$GATEWAY_SERVICE_NAME"
}

configure_systemd_service() {
  local temporary

  command -v systemctl >/dev/null 2>&1 ||
    fail "No se encontró systemd en este equipo."
  if getent group dialout >/dev/null 2>&1 &&
    ! id -nG "$INSTALL_USER" | tr ' ' '\n' | grep -qx dialout; then
    as_root usermod -aG dialout "$INSTALL_USER"
    log "Usuario $INSTALL_USER agregado al grupo dialout para acceder a Modbus RTU."
  fi
  temporary="$(mktemp)"
  python3 - \
    "$INSTALLER_ROOT/templates/alrotek-gateway.service" \
    "$temporary" \
    "$INSTALL_USER" \
    "$APP_DIR" <<'PY'
from pathlib import Path
import sys

source, destination, install_user, app_dir = sys.argv[1:]
content = Path(source).read_text(encoding="utf-8")
content = content.replace("@INSTALL_USER@", install_user)
escaped_app_dir = (
    app_dir.replace("\\", "\\\\").replace('"', '\\"').replace("%", "%%")
)
content = content.replace("@APP_DIR@", escaped_app_dir)
Path(destination).write_text(content, encoding="utf-8")
PY

  as_root install -m 644 "$temporary" "$GATEWAY_SERVICE_FILE"
  as_root systemctl daemon-reload
  as_root systemctl enable --now "$GATEWAY_SERVICE_NAME"
  rm -f -- "$temporary"
  log "Servicio $GATEWAY_SERVICE_NAME habilitado y activo."
}

remove_systemd_service() {
  if ! service_is_installed; then
    return
  fi

  as_root systemctl disable --now "$GATEWAY_SERVICE_NAME" || true
  as_root rm -f -- "$GATEWAY_SERVICE_FILE"
  as_root systemctl daemon-reload
  as_root systemctl reset-failed "$GATEWAY_SERVICE_NAME" 2>/dev/null || true
  log "Servicio $GATEWAY_SERVICE_NAME eliminado."
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
