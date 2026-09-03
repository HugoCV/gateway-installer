#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

REPO_URL="$DEFAULT_REPO_URL"
REF="$DEFAULT_REF"
APP_DIR=""
REBOOT_AFTER_UPDATE=false
INSTALL_USER_OVERRIDE=""

usage() {
  cat <<'EOF'
Uso: update.sh [opciones]

  --repo-url URL        Repositorio del gateway.
  --ref RAMA_O_VERSION  Rama, tag o commit.
  --app-dir RUTA        Directorio instalado.
  --reboot              Reiniciar el equipo al terminar.
  --install-user USUARIO
                        Usuario propietario de la instalación.
  --help                Mostrar esta ayuda.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo-url) REPO_URL="${2:?Falta URL}"; shift 2 ;;
    --ref) REF="${2:?Falta rama o versión}"; shift 2 ;;
    --app-dir) APP_DIR="${2:?Falta ruta}"; shift 2 ;;
    --reboot) REBOOT_AFTER_UPDATE=true; shift ;;
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
[ -d "$APP_DIR/.git" ] || fail "No existe una instalación en $APP_DIR."
require_sudo

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

log "[1/3] Descargando la versión $REF..."
checkout_ref "$REPO_URL" "$REF"

log "[2/3] Actualizando dependencias..."
[ -x "$APP_DIR/venv/bin/pip" ] ||
  fail "No existe el entorno virtual. Use la opción Reparar."
require_supported_python "$APP_DIR/venv/bin/python"
[ -f "$APP_DIR/requirements.txt" ] ||
  fail "El repositorio no contiene requirements.txt."
run_as_install_user "$APP_DIR/venv/bin/pip" install -r "$APP_DIR/requirements.txt"

log "[3/3] Actualización terminada."
show_installed_version
if [ "$SERVICE_WAS_ACTIVE" = true ]; then
  log "Reiniciando $GATEWAY_SERVICE_NAME..."
  as_root systemctl start "$GATEWAY_SERVICE_NAME"
  SERVICE_WAS_ACTIVE=false
else
  log "Reinicie la aplicación Gateway para cargar el código nuevo."
fi

if [ "$REBOOT_AFTER_UPDATE" = true ]; then
  log "Reiniciando el equipo..."
  as_root reboot
fi
