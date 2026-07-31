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

## Uso por terminal

Instalación:

```bash
./scripts/install.sh \
  --ref master \
  --env-file ./.env
```

Actualización:

```bash
./scripts/update.sh --ref master
```

Reparación de la instalación sin volver a ejecutar `apt`:

```bash
./scripts/install.sh \
  --ref master \
  --env-file ./.env \
  --skip-system-packages
```

Para usar únicamente la interfaz gráfica, sin servicio en segundo plano:

```bash
./scripts/install.sh \
  --ref master \
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

## Validación para desarrollo

```bash
bash -n launcher.sh install-gateway.sh scripts/*.sh
python3 -m py_compile installer_gui.py packaging/build_deb.py
```

Si `shellcheck` está disponible:

```bash
shellcheck launcher.sh install-gateway.sh build-deb.sh scripts/*.sh
```
