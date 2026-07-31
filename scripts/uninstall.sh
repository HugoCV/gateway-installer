#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

APP_DIR=""
REMOVE_AUTOSTART=false
REMOVE_AUTOLOGIN=false
REBOOT_AFTER_UNINSTALL=false
CONFIRMED=false
INSTALL_USER_OVERRIDE=""

usage() {
  cat <<'EOF'
Uso: uninstall.sh [opciones]

  --app-dir RUTA         Directorio que se eliminará.
  --remove-autostart     Eliminar el autostart gráfico.
  --remove-autologin     Eliminar la configuración creada para LightDM.
  --reboot               Reiniciar el equipo al terminar.
  --yes                  Confirmar la eliminación.
  --install-user USUARIO Usuario propietario de la instalación.
  --help                 Mostrar esta ayuda.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --app-dir) APP_DIR="${2:?Falta ruta}"; shift 2 ;;
    --remove-autostart) REMOVE_AUTOSTART=true; shift ;;
    --remove-autologin) REMOVE_AUTOLOGIN=true; shift ;;
    --reboot) REBOOT_AFTER_UNINSTALL=true; shift ;;
    --yes) CONFIRMED=true; shift ;;
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
[ "$CONFIRMED" = true ] ||
  fail "La desinstalación requiere confirmación mediante --yes."
require_sudo

log "Eliminando instalación en $APP_DIR..."
if [ -e "$APP_DIR" ]; then
  as_root rm -rf -- "$APP_DIR"
fi

if [ "$REMOVE_AUTOSTART" = true ]; then
  rm -f -- "$INSTALL_HOME/.config/autostart/gateway.desktop"
fi

if [ "$REMOVE_AUTOLOGIN" = true ]; then
  as_root rm -f -- "$LIGHTDM_AUTLOGIN_FILE"
fi

log "Gateway desinstalado."
if [ "$REBOOT_AFTER_UNINSTALL" = true ]; then
  log "Reiniciando el equipo..."
  as_root reboot
fi
