#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

REPO_URL="$DEFAULT_REPO_URL"
REF="$DEFAULT_REF"
ENV_FILE="$INSTALLER_ROOT/.env"
APP_DIR=""
ENABLE_AUTOSTART=false
ENABLE_SERVICE=true
ENABLE_AUTOLOGIN=false
RUN_AFTER_INSTALL=false
REBOOT_AFTER_INSTALL=false
INSTALL_SYSTEM_PACKAGES=true
INSTALL_USER_OVERRIDE=""
PYTHON_BIN="${GATEWAY_PYTHON_BIN:-python3}"

usage() {
  cat <<'EOF'
Uso: install.sh [opciones]

  --repo-url URL             Repositorio del gateway.
  --ref RAMA_O_VERSION       Rama, tag o commit (predeterminado: main).
  --python-bin RUTA          Python 3.10+ utilizado para crear el entorno.
  --app-dir RUTA             Directorio de instalación.
  --env-file RUTA            Archivo .env que se copiará.
  --autostart                Iniciar la interfaz al abrir el escritorio.
  --service                  Ejecutar Gateway como servicio (predeterminado).
  --no-service               No crear el servicio en segundo plano.
  --autologin                Configurar autologin de LightDM.
  --run                      Ejecutar el gateway al terminar.
  --reboot                   Reiniciar el equipo al terminar.
  --skip-system-packages     No ejecutar apt.
  --install-user USUARIO     Usuario propietario de la instalación.
  --help                     Mostrar esta ayuda.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo-url) REPO_URL="${2:?Falta URL}"; shift 2 ;;
    --ref) REF="${2:?Falta rama o versión}"; shift 2 ;;
    --python-bin) PYTHON_BIN="${2:?Falta intérprete}"; shift 2 ;;
    --app-dir) APP_DIR="${2:?Falta ruta}"; shift 2 ;;
    --env-file) ENV_FILE="${2:?Falta ruta}"; shift 2 ;;
    --autostart) ENABLE_AUTOSTART=true; shift ;;
    --service) ENABLE_SERVICE=true; shift ;;
    --no-service) ENABLE_SERVICE=false; shift ;;
    --autologin) ENABLE_AUTOLOGIN=true; shift ;;
    --run) RUN_AFTER_INSTALL=true; shift ;;
    --reboot) REBOOT_AFTER_INSTALL=true; shift ;;
    --skip-system-packages) INSTALL_SYSTEM_PACKAGES=false; shift ;;
    --install-user) INSTALL_USER_OVERRIDE="${2:?Falta usuario}"; shift 2 ;;
    --help) usage; exit 0 ;;
    *) fail "Opción desconocida: $1" ;;
  esac
done

require_linux
if [ -n "$INSTALL_USER_OVERRIDE" ]; then
  export GATEWAY_INSTALL_USER="$INSTALL_USER_OVERRIDE"
fi
detect_install_user
APP_DIR="${APP_DIR:-$INSTALL_HOME/gateway}"
validate_app_dir
[ -f "$ENV_FILE" ] || fail "No existe el archivo de configuración: $ENV_FILE"
require_sudo

if [ "$ENABLE_SERVICE" = true ] && [ "$ENABLE_AUTOSTART" = true ]; then
  fail "No active --service y --autostart juntos; crearían dos procesos Gateway."
fi

SERVICE_WAS_ACTIVE=false
restore_service() {
  if [ "$SERVICE_WAS_ACTIVE" = true ]; then
    as_root systemctl start "$GATEWAY_SERVICE_NAME" || true
  fi
}
trap restore_service EXIT

if service_is_active; then
  SERVICE_WAS_ACTIVE=true
  log "Deteniendo temporalmente $GATEWAY_SERVICE_NAME..."
  as_root systemctl stop "$GATEWAY_SERVICE_NAME"
fi

if [ "$INSTALL_SYSTEM_PACKAGES" = true ]; then
  log "[1/7] Instalando dependencias del sistema..."
  as_root apt-get update
  as_root apt-get install -y git python3 python3-venv python3-pip python3-tk
else
  log "[1/7] Omitiendo dependencias del sistema."
fi
require_supported_python "$PYTHON_BIN"

log "[2/7] Descargando la versión $REF..."
prepare_gateway_state
checkout_ref "$REPO_URL" "$REF"

log "[3/7] Copiando configuración..."
as_root install -m 600 -o "$INSTALL_USER" -g "$INSTALL_USER" \
  "$ENV_FILE" "$APP_DIR/.env"

log "[4/7] Preparando entorno virtual..."
if [ -x "$APP_DIR/venv/bin/python" ] &&
  ! python_is_supported "$APP_DIR/venv/bin/python"; then
  log "El entorno existente usa una versión incompatible; se volverá a crear."
  run_as_install_user "$PYTHON_BIN" -m venv --clear "$APP_DIR/venv"
elif [ ! -x "$APP_DIR/venv/bin/python" ]; then
  run_as_install_user "$PYTHON_BIN" -m venv "$APP_DIR/venv"
fi
run_as_install_user "$APP_DIR/venv/bin/pip" install --upgrade pip
[ -f "$APP_DIR/requirements.txt" ] ||
  fail "El repositorio no contiene requirements.txt."
run_as_install_user "$APP_DIR/venv/bin/pip" install -r "$APP_DIR/requirements.txt"

log "[5/7] Creando comando de inicio..."
create_start_script

log "[6/7] Aplicando opciones de escritorio..."
if [ "$ENABLE_SERVICE" = true ]; then
  remove_autostart
  configure_systemd_service
  SERVICE_WAS_ACTIVE=false
else
  remove_systemd_service
  SERVICE_WAS_ACTIVE=false
fi
if [ "$ENABLE_AUTOSTART" = true ] && [ "$ENABLE_SERVICE" = false ]; then
  configure_autostart
fi
if [ "$ENABLE_AUTOLOGIN" = true ]; then
  configure_autologin
fi

log "[7/7] Instalación terminada."
show_installed_version

if [ "$RUN_AFTER_INSTALL" = true ] && [ "$ENABLE_SERVICE" = false ]; then
  log "Iniciando Gateway..."
  run_as_install_user nohup "$APP_DIR/start.sh" >/dev/null 2>&1 &
fi

if [ "$REBOOT_AFTER_INSTALL" = true ]; then
  log "Reiniciando el equipo..."
  as_root reboot
fi
