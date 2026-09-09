#!/usr/bin/env bash
# Shared variables are also consumed by the scripts sourcing this file.
# shellcheck disable=SC2034

INSTALLER_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_REPO_URL="https://github.com/HugoCV/gateway.git"
DEFAULT_REF="main"
MIN_PYTHON_MAJOR=3
MIN_PYTHON_MINOR=10
LIGHTDM_AUTLOGIN_FILE="/etc/lightdm/lightdm.conf.d/90-gateway-autologin.conf"
GATEWAY_SERVICE_NAME="alrotek-gateway.service"
GATEWAY_SERVICE_FILE="/etc/systemd/system/$GATEWAY_SERVICE_NAME"
GATEWAY_STATE_DIR="${GATEWAY_STATE_DIR:-/var/lib/alrotek-gateway}"
GATEWAY_CONFIG_FILE="$GATEWAY_STATE_DIR/gateway.json"
NETWORK_RECOVERY_RULE="/etc/sudoers.d/alrotek-gateway-network"

log() {
  printf '%s\n' "$*"
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

python_is_supported() {
  run_as_install_user "$1" -c "import sys; raise SystemExit(0 if sys.version_info >= ($MIN_PYTHON_MAJOR, $MIN_PYTHON_MINOR) else 1)" \
    >/dev/null 2>&1
}

require_supported_python() {
  local python_bin="$1"
  local detected_version

  command -v "$python_bin" >/dev/null 2>&1 ||
    fail "No se encontró el intérprete de Python: $python_bin."
  detected_version="$(run_as_install_user "$python_bin" -c 'import platform; print(platform.python_version())')"
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
  INSTALL_GROUP="$(id -gn "$INSTALL_USER")"
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
  APP_DIR="$(python3 - "$APP_DIR" "$INSTALL_HOME" <<'PY'
from pathlib import Path
import sys

raw, home = sys.argv[1:]
path = Path(raw)
home = Path(home).resolve()
if not raw or not path.is_absolute() or any(c in raw for c in '\n\r\x00'):
    sys.exit('ERROR: Indique una ruta absoluta válida.')
path = path.resolve()
# Only application subdirectories under the deployment home or /opt.
if not any(root in path.parents for root in (home, Path('/opt'))):
    sys.exit('ERROR: El directorio debe estar dentro del home del usuario o /opt.')
if path == home or path in home.parents or path == Path('/opt'):
    sys.exit('ERROR: Directorio de instalación inseguro.')
print(path)
PY
)" || fail "Directorio de instalación inseguro."
}

acquire_installer_lock() {
  # Re-execute with privilege before opening a root-owned, shared lock.
  if [ "$(id -u)" -ne 0 ]; then
    exec sudo -- env GATEWAY_STATE_DIR="$GATEWAY_STATE_DIR" \
      GATEWAY_PYTHON_BIN="${GATEWAY_PYTHON_BIN:-python3}" \
      "$0" "$@" --install-user "$INSTALL_USER"
  fi
  command -v flock >/dev/null || fail "Instale util-linux (flock)."
  install -d -m 755 -o root -g root /run/alrotek-gateway-installer
  lock_installer_file /run/alrotek-gateway-installer/operation.lock
}

lock_installer_file() {
  exec 9>"$1"
  flock -n 9 || fail "Ya hay otra operación del instalador en curso."
}

mark_installation() {
  as_root install -d -m 755 -o root -g root /var/lib/alrotek-gateway-installer
  printf '%s\n' "$APP_DIR" | as_root tee /var/lib/alrotek-gateway-installer/app-dir >/dev/null
}

require_registered_installation() {
  local registered
  registered="$(as_root cat /var/lib/alrotek-gateway-installer/app-dir 2>/dev/null)" ||
    fail "Instalación sin registrar. Ejecute Reparar antes de desinstalar."
  [ "$registered" = "$APP_DIR" ] ||
    fail "El directorio no coincide con la instalación registrada."
  if [ ! -d "$APP_DIR/.git" ] || [ ! -f "$APP_DIR/main.py" ]; then
    fail "El directorio no contiene una instalación Gateway reconocible."
  fi
}

finish_service_operation() {
  local result=$?
  if [ "$result" -ne 0 ] && [ "${RUNTIME_MUTATED:-false}" = true ] && service_is_installed; then
    as_root systemctl stop "$GATEWAY_SERVICE_NAME" || true
    as_root systemctl disable "$GATEWAY_SERVICE_NAME" || true
    log "ERROR: Servicio deshabilitado para impedir arrancar una actualización incompleta tras reiniciar. Ejecute Reparar."
    return "$result"
  fi
  if [ "${SERVICE_WAS_ACTIVE:-false}" = true ]; then
    if [ "${RUNTIME_MUTATED:-false}" = false ]; then
      as_root systemctl start "$GATEWAY_SERVICE_NAME" || true
    else
      log "ERROR: Gateway permanece detenido: la operación no terminó. Ejecute Reparar antes de iniciarlo."
    fi
  fi
  return "$result"
}

prepare_gateway_state() {
  local legacy_config="$APP_DIR/data/gateway.json"
  local source_config=""
  local temporary

  as_root install -d -m 700 -o "$INSTALL_USER" -g "$INSTALL_GROUP" \
    "$GATEWAY_STATE_DIR"

  if [ ! -f "$GATEWAY_CONFIG_FILE" ]; then
    if [ -f "$legacy_config" ]; then
      source_config="$legacy_config"
    fi

    temporary="$(mktemp)"
    python3 - "$source_config" "$temporary" <<'PY'
import json
from pathlib import Path
import sys

source, destination = sys.argv[1:]
data = {}
if source:
    try:
        data = json.loads(Path(source).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        sys.exit('No se pudo leer la identidad anterior. Corrija gateway.json antes de continuar.')
if not isinstance(data, dict):
    sys.exit('La configuración anterior debe ser un objeto JSON.')

identity = {
    key: data[key]
    for key in ("organizationId", "gatewayId")
    if data.get(key)
}
Path(destination).write_text(
    json.dumps(identity, indent=2, ensure_ascii=False) + "\n",
    encoding="utf-8",
)
PY
    as_root install -m 600 -o "$INSTALL_USER" -g "$INSTALL_GROUP" \
      "$temporary" "$GATEWAY_CONFIG_FILE"
    rm -f -- "$temporary"
    log "Identidad del gateway guardada fuera del repositorio."
  fi

  if [ -d "$APP_DIR/.git" ] &&
    run_as_install_user git -C "$APP_DIR" ls-files --error-unmatch \
      data/gateway.json >/dev/null 2>&1 &&
    [ -n "$(run_as_install_user git -C "$APP_DIR" status --porcelain -- data/gateway.json)" ]; then
    if [ -f "$legacy_config" ]; then
      local backup
      backup="$(as_root mktemp "$GATEWAY_STATE_DIR/legacy-backup.XXXXXX")"
      as_root install -m 600 -o "$INSTALL_USER" -g "$INSTALL_GROUP" "$legacy_config" "$backup"
      log "Configuración anterior respaldada en $backup."
    fi
    run_as_install_user git -C "$APP_DIR" restore --worktree -- data/gateway.json
  fi
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

  local quoted_app quoted_config quoted_python quoted_log
  printf -v quoted_app '%q' "$APP_DIR"
  printf -v quoted_config '%q' "$GATEWAY_CONFIG_FILE"
  printf -v quoted_python '%q' "$venv_dir/bin/python"
  printf -v quoted_log '%q' "$APP_DIR/gateway.log"
  run_as_install_user tee "$start_script" >/dev/null <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd $quoted_app
export GATEWAY_CONFIG_PATH=$quoted_config
exec $quoted_python main.py >> $quoted_log 2>&1
EOF
  run_as_install_user chmod 755 "$start_script"
}

verify_runtime() {
  run_as_install_user env GATEWAY_CONFIG_PATH="$GATEWAY_CONFIG_FILE" \
    "$APP_DIR/venv/bin/python" - "$APP_DIR" <<'PY'
import os
import sys
os.chdir(sys.argv[1])
sys.path.insert(0, sys.argv[1])
from application.app_controller import AppController
from infrastructure.config.loader import get_gateway
config = get_gateway()
if not config.get('organizationId') or not config.get('gatewayId'):
    sys.exit('ERROR: Configure GATEWAY_ORGANIZATION_ID y GATEWAY_ID en .env o la identidad externa antes de iniciar.')
if not callable(getattr(AppController, 'run', None)):
    sys.exit('ERROR: La versión seleccionada no admite el servicio headless. Use una versión compatible.')
PY
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
  as_root install -m 644 -o "$INSTALL_USER" -g "$INSTALL_GROUP" \
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
    "$APP_DIR" "$GATEWAY_CONFIG_FILE" <<'PY'
from pathlib import Path
import sys

source, destination, install_user, app_dir, config_file = sys.argv[1:]
content = Path(source).read_text(encoding="utf-8")
content = content.replace("@INSTALL_USER@", install_user)
escaped_app_dir = (
    app_dir.replace("\\", "\\\\").replace('"', '\\"').replace("%", "%%")
)
content = content.replace("@APP_DIR@", escaped_app_dir)
content = content.replace('@CONFIG_FILE@', config_file.replace('\\', '\\\\').replace('"', '\\"').replace('%', '%%'))
Path(destination).write_text(content, encoding="utf-8")
PY

  as_root install -m 644 "$temporary" "$GATEWAY_SERVICE_FILE"
  as_root systemctl daemon-reload
  if [ "${1:-true}" = true ]; then
    as_root systemctl enable --now "$GATEWAY_SERVICE_NAME"
  fi
  rm -f -- "$temporary"
  log "Configuración del servicio $GATEWAY_SERVICE_NAME actualizada."
}

configure_network_recovery() {
  local ip_bin rfkill_bin reboot_bin temporary binary
  command -v visudo >/dev/null || fail "No se encontró visudo (paquete sudo)."
  ip_bin="$(command -v ip)" || fail "Instale iproute2 para la recuperación de red."
  rfkill_bin="$(command -v rfkill)" || fail "Instale rfkill para la recuperación de red."
  reboot_bin="$(command -v reboot)" || fail "No se encontró reboot."
  [[ "$INSTALL_USER" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*\$?$ ]] || fail "Usuario no válido para sudoers."
  for binary in "$ip_bin" "$rfkill_bin" "$reboot_bin"; do
    case "$binary" in /usr/sbin/*|/usr/bin/*|/sbin/*|/bin/*) ;; *) fail "Comando fuera de las rutas del sistema: $binary" ;; esac
  done
  temporary="$(mktemp)"
  printf '%s ALL=(root) NOPASSWD: %s link set wlan0 down, %s link set wlan0 up, %s unblock wifi, %s ""\n' \
    "$INSTALL_USER" "$ip_bin" "$ip_bin" "$rfkill_bin" "$reboot_bin" > "$temporary"
  if ! as_root visudo -cf "$temporary"; then
    rm -f -- "$temporary"
    fail "Regla de recuperación de red inválida."
  fi
  as_root install -m 440 -o root -g root "$temporary" "$NETWORK_RECOVERY_RULE"
  rm -f -- "$temporary"
  log "Recuperación autorizada: reiniciar wlan0, desbloquear Wi-Fi y reiniciar el equipo."
}

remove_systemd_service() {
  if ! service_is_installed; then
    return
  fi

  as_root systemctl disable --now "$GATEWAY_SERVICE_NAME" ||
    fail "No se pudo detener el servicio. Se conservan la unidad y los archivos."
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
