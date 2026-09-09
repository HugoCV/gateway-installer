# Alrotek Gateway Installer

Instalador gráfico y por terminal para preparar un equipo Linux que ejecutará
Alrotek Gateway con su interfaz de diagnóstico.

## Instalación con doble clic

El archivo distribuible se genera en `dist/`:

```text
alrotek-gateway-installer_1.1.0_all.deb
```

Transfiera ese archivo al equipo Ubuntu/Debian y ábralo con doble clic. El
centro de software mostrará la aplicación y solicitará confirmación para
instalarla.

Después de instalar el paquete:

1. Abra el menú de aplicaciones.
2. Busque **Alrotek Gateway Installer**.
3. Abra la aplicación.
4. Seleccione el archivo de configuración y las opciones deseadas.
5. Presione **Iniciar instalación**.

Cuando una operación necesita permisos administrativos, Linux muestra la
ventana gráfica de PolicyKit. No es necesario abrir una terminal.

También puede instalar el paquete manualmente:

```bash
sudo apt install ./alrotek-gateway-installer_1.1.0_all.deb
```

## Construir el paquete

Desde macOS o Linux:

```bash
./build-deb.sh
```

El generador lee la versión desde el archivo `VERSION`. Para publicar una nueva
versión, cambie su contenido, por ejemplo de `1.1.0` a `1.1.1`.

Para una construcción puntual también puede sobrescribirla sin modificar el
archivo:

```bash
./build-deb.sh --version 1.1.1
```

El paquete es `Architecture: all` porque contiene Python y Bash, por lo que el
mismo `.deb` puede utilizarse en equipos Linux `x86_64` y `arm64`.

## Interfaz gráfica

En el equipo Linux, abra una terminal dentro de este proyecto y ejecute:

```bash
./launcher.sh
```

El launcher instala `python3-tk` cuando sea necesario y abre la interfaz sin
ejecutarla como usuario `root`.

La interfaz permite:

- instalar, reparar, actualizar o desinstalar Gateway;
- ejecutar Gateway como un servicio `systemd` en segundo plano;
- elegir una rama, tag o commit;
- seleccionar el archivo `.env`;
- configurar el inicio automático de la interfaz;
- activar opcionalmente el autologin de LightDM;
- ejecutar Gateway o reiniciar el equipo al finalizar;
- ver el progreso y los errores sin ocultar la salida de los scripts.

El servicio en segundo plano está seleccionado inicialmente. En este modo,
Gateway arranca con el equipo, se reinicia si falla y continúa activo al cerrar
la interfaz o la sesión del escritorio. El autostart gráfico no puede activarse
al mismo tiempo porque ambos procesos competirían por los puertos Modbus.

Para comprobar el servicio en el equipo Linux:

```bash
systemctl status alrotek-gateway
journalctl -u alrotek-gateway -f
```

El autologin y el reinicio permanecen desactivados hasta que el usuario los
seleccione.

La opción **Autorizar recuperación de Wi-Fi** permite que el monitor del Gateway
reinicie `wlan0`, desbloquee Wi-Fi y solicite un reinicio del equipo cuando se
cumpla su tiempo de desconexión. Está desactivada inicialmente. Por terminal se
activa con `--network-recovery` durante Instalar o Reparar. Instala una regla
validada con `visudo` en `/etc/sudoers.d/alrotek-gateway-network`, limitada a esos
comandos exactos. Este permiso se aplica a la cuenta del Gateway; no concede
acceso general a sudo. Reparar sin esta opción elimina el permiso, y Actualizar
conserva la elección existente. Sin este permiso, el monitor puede detectar la
pérdida de red, pero no ejecutar esas acciones privilegiadas.

## Uso por terminal

Instalación:

```bash
./scripts/install.sh \
  --ref main \
  --env-file ./.env
```

Actualización:

```bash
./scripts/update.sh --ref main
```

Reparación de la instalación sin volver a ejecutar `apt`:

```bash
./scripts/install.sh \
  --ref main \
  --env-file ./.env \
  --skip-system-packages
```

Para usar únicamente la interfaz gráfica, sin servicio en segundo plano:

```bash
./scripts/install.sh \
  --ref main \
  --env-file ./.env \
  --no-service \
  --autostart
```

Desinstalación:

```bash
./scripts/uninstall.sh \
  --remove-autostart \
  --remove-autologin \
  --yes
```

Cada script ofrece el detalle completo mediante `--help`.

Gateway requiere Python 3.10 o superior. El instalador valida la versión antes
de crear el entorno virtual y se detiene con un mensaje claro si el sistema no
dispone de una versión compatible. Puede seleccionarse otro intérprete con
`--python-bin` o mediante la variable `GATEWAY_PYTHON_BIN`.

## Archivos de configuración

Para trabajar desde el repositorio, copie `.env.example` como `.env` y complete
sus valores:

```bash
cp .env.example .env
```

`.env` contiene credenciales y está excluido de Git. El instalador nunca imprime
su contenido y lo copia con permisos `600`.

La aplicación instalada desde el paquete propone inicialmente:

```text
~/gateway.env
```

Puede crear ese archivo desde `.env.example` o seleccionar cualquier `.env`
existente mediante la interfaz.

## Comportamiento de seguridad

- No modifica LightDM si no se selecciona explícitamente `autologin`.
- La configuración de LightDM se guarda en un archivo independiente:
  `/etc/lightdm/lightdm.conf.d/90-gateway-autologin.conf`.
- No reinicia el equipo salvo que se seleccione esa opción.
- Rechaza actualizaciones cuando la instalación contiene cambios locales.
- La desinstalación exige confirmación y valida el directorio antes de eliminarlo.
- La rama o versión que se instala siempre queda visible y configurable.
- Las rutas deben ser subdirectorios del home del usuario o de `/opt`; se resuelven
  enlaces simbólicos y componentes `..` antes de aceptarlas.
- Instalar y Actualizar registran la ruta en
  `/var/lib/alrotek-gateway-installer/app-dir`. Desinstalar exige que coincida con
  ese registro y que contenga la aplicación. Para instalaciones anteriores sin
  registro, ejecute Reparar primero. La identidad en `/var/lib/alrotek-gateway`
  se conserva tras desinstalar, incluidos los respaldos de configuración anterior.
- Un bloqueo global impide ejecutar dos operaciones simultáneamente.
- Si una actualización falla después de comenzar a modificar el runtime, el
  servicio queda detenido y deshabilitado, también para el próximo arranque.
  Ejecute Reparar con la opción de servicio y revise el error antes de volver a
  iniciarlo. No hay rollback automático del código ni del entorno virtual.
- Actualizar regenera el comando de inicio y la unidad systemd para aplicar la
  ruta de identidad externa; conserva si el servicio estaba activo o detenido.
- Antes de activar el servicio, se verifica que la aplicación se importe, admita
  headless y tenga `organizationId` y `gatewayId`. Estas comprobaciones se ejecutan
  con la cuenta del Gateway y no abren conexiones a dispositivos.

## Validación para desarrollo

```bash
bash -n launcher.sh install-gateway.sh scripts/*.sh
python3 -m py_compile installer_gui.py packaging/build_deb.py
python3 -m unittest discover -s tests -v
```

Si `shellcheck` está disponible:

```bash
shellcheck -x launcher.sh install-gateway.sh build-deb.sh scripts/*.sh
```

Las pruebas usan directorios temporales y funciones aisladas; no ejecutan los
entrypoints de instalación ni requieren sudo. La prueba de exclusión mutua
requiere `flock` de `util-linux` (se omite si no está disponible).
