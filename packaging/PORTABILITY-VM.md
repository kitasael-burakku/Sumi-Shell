# Aceptación de portabilidad en Arch Linux

Esta prueba es para una VM desechable con una cuenta nueva y un compositor Hyprland propio. Tomar una instantánea antes de cada perfil. Mantener otra TTY del invitado disponible para recuperar la VM. El host queda fuera de los montajes, del portapapeles compartido y de todas las órdenes de sesión.

## Preparar los perfiles

- **Directo mínimo.** Arch, systemd/logind del invitado, Hyprland con Lua, Quickshell con sus módulos, Qt Wayland, Python, herramientas básicas y un terminal (`foot` en el ejemplo). Dejar ausentes Matugen, cliphist, un backend de fondos, grabadora, Sumi SDDM y Qt Multimedia si el grafo de paquetes de la imagen lo permite. Registrar cualquier opcional que llegue como dependencia transitiva. Los módulos QML del núcleo siguen siendo necesarios.
- **Gestionado.** Misma base con gestor systemd de usuario, login1, `luac` compatible y `readelf` para el fragmento automático. Instalar desde una instantánea separada. Para bloqueo añadir hyprlock funcional y opcionalmente hypridle. Preparar un usuario de VM con contraseña conocida y probar su PAM en la TTY.
- **Paquete Arch.** En otra instantánea, comprobar la resolución de dependencias del paquete preparado, su instalación, el runtime de sólo lectura, actualización y retirada con pacman. Evitar que una copia de usuario tape al paquete. Registrar los resultados por separado.

Transferir un bundle o clon Git de Sumi Shell y fijar el commit. Si se evalúa una revisión de trabajo, transferir también un parche con SHA-256, verificarlo y aplicarlo sobre el commit base en el invitado. Guardar `git rev-parse HEAD`, el hash del parche, la lista de paquetes y la identificación de la imagen. Usar sólo el repositorio de Sumi Shell en esta VM. El ejemplo usa Hyprland **0.57.x** y Quickshell **0.3.2** con Qt **6.12**. [Integración systemd de Hyprland 0.57](https://wiki.hypr.land/0.57.0/configuring/extra/systemd/)

En la TTY del invitado, como usuario de prueba:

```bash
set -eu
umask 077
evidence="$HOME/sumi-vm-evidence"
install -d -m 700 "$evidence" "$HOME/.config/hypr"
test ! -e "$HOME/.config/hypr/hyprland.lua"
test ! -e "$HOME/.config/quickshell/sumi"
test ! -e "$HOME/.config/sumi-shell"
test ! -e "$HOME/Projects/dotfiles"
test ! -e "$HOME/.config/fish"
cat > "$HOME/.config/hypr/hyprland.lua" <<'LUA'
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 1 })
hl.config({ debug = { disable_logs = false } })
hl.bind("SUPER + RETURN", hl.dsp.exec_cmd("foot"))
LUA
Hyprland --verify-config --config "$HOME/.config/hypr/hyprland.lua"
Hyprland --version-json > "$evidence/hyprland-version.json"
qs --version > "$evidence/quickshell-version.txt"
python3 --version > "$evidence/python-version.txt"
pacman -Q > "$evidence/packages.txt"
exec start-hyprland > "$evidence/hyprland-console.log" 2>&1
```

Abrir `foot` con Super+Enter dentro del Hyprland invitado. Ejecutar **un** perfil desde el clon. Para el directo:

```bash
cd "$HOME/Sumi-Shell"
./install.sh check --install --no-units --json > "$HOME/sumi-vm-evidence/check.json"
./install.sh install --no-units --dry-run
./install.sh install --no-units
qs --log-times -c sumi --no-duplicate > "$HOME/sumi-vm-evidence/direct.log" 2>&1
```

Dejar ese proceso abierto y usar otra terminal del invitado para el IPC. En el perfil gestionado:

```bash
cd "$HOME/Sumi-Shell"
evidence="$HOME/sumi-vm-evidence"
: "${WAYLAND_DISPLAY:?missing Wayland socket}" "${HYPRLAND_INSTANCE_SIGNATURE:?missing Hyprland instance}"
systemctl --user is-active graphical-session.target > "$evidence/target.txt"
systemctl --user show-environment |
    grep -E '^(WAYLAND_DISPLAY|HYPRLAND_INSTANCE_SIGNATURE)=' > "$evidence/unit-environment.txt"
./install.sh check --install --enable --json > "$evidence/check.json"
./install.sh install --enable --dry-run
./install.sh install --enable
systemctl --user start sumi-shell.service
systemctl --user show sumi-shell.service -p MainPID -p ActiveState -p NRestarts -p FragmentPath > "$evidence/unit.txt"
```

Comparar el entorno del gestor con el de la terminal. Si difiere o el target está inactivo, registrar el fallo del perfil original antes de ensayar un mecanismo de arranque de sesión adicional. `install` coloca archivos y, con `--enable`, crea el enlace para la siguiente sesión. El éxito de la instalación y la preparación del gestor se verifican por separado.

## Demostrar el núcleo y los opcionales

En cada perfil, esperar hasta 15 segundos después del arranque a que se pueda analizar `qs -c sumi ipc call sumi api` como JSON. Guardar `api`, `status`, `caps` y `lockStatus` con sus salidas completas. Comparar versión, API y build con el `build.json` instalado y el PID con `qs list` y, en el perfil gestionado, con `MainPID`. Conservar también `hyprctl -j monitors`, `hyprctl -j layers` y el log de Hyprland de la instancia. Si `qs` devuelve 0 y el contenido es `false` o un error textual, evaluar el contenido.

| Prueba | Aceptación |
| --- | --- |
| Arranque en frío | Una sola instancia, salida Wayland visible, `Configuration Loaded` sin error de carga, IPC JSON y `NRestarts=0` en systemd. |
| Barra, Island y notch | Usar Settings → Shell → Layout para alternar barra e Island y habilitar la variante con notch. Adjuntar una captura por presentación en la VM desbloqueada, las capas y el estado IPC. El foco regresa a la aplicación después de cerrar un panel. |
| Acciones e IPC | Abrir launcher, Settings, calendario, mixer y Login screen por IPC. El lanzador abre una entrada `.desktop` local de prueba. Con el fragmento Lua instalado, ejecutar `hyprctl dispatch 'hl.dsp.global("sumi:launcher")'` y guardar binds y globalshortcuts. `hyprctl configerrors` queda vacío. |
| Persistencia | El perfil nuevo genera `settings.json` v4 bajo config. Ajustar un valor, salir de la sesión y volver a entrar. El valor persiste y los hashes del runtime se conservan. Las configuraciones de tareas, web y proveedores sólo aparecen si se importan. |
| Tema estático | Sin Matugen, aplicar `qs -c sumi ipc call sumi themePreset gruvbox-dark` y luego `themeSet static`. Esperar ambos cambios y comprobar color y origen en `status.palette`, escritura en `$XDG_STATE_HOME/sumi-shell/colors.json` y ausencia de escrituras al código. |
| Opcionales | Revisar Settings → System → Environment. Abrir fondos, portapapeles, grabadora y Login screen con sus herramientas ausentes. Registrar mensajes comprensibles y verificar que el proceso, las demás superficies y el IPC siguen disponibles. Si falta Qt Multimedia, verificar específicamente que el primer arranque sigue funcionando. |
| Ciclo de la unidad | Cerrar la sesión del invitado y volver a entrar. La unidad se detiene con su sesión y arranca una sola vez cuando vuelve `graphical-session.target`. Guardar los journals de ambos momentos y los PIDs. |
| Recuperación normal | Desde una instantánea, introducir JSON truncado en el perfil de prueba y verificar aviso, respaldo y bytes intactos. Desde otra instantánea desbloqueada, usar un drop-in temporal con una plataforma Qt inexistente para observar el fallo de arranque. Retirar ese drop-in, recargar el gestor del invitado, limpiar el límite de arranques y volver a verificar IPC, build y salida visible. |

## Bloqueo y rescate

Esta parte exige la VM, una instantánea recuperable y una TTY alternativa. Separar los ensayos positivos de cada fallo provocado.

1. **Preparación.** Consultar desde el clon `python3 sumi/scripts/pam_stack.py login` y el servicio PAM de hyprlock. Verificar la configuración efectiva de cada locker. Leer `hyprctl -j getoption misc:allow_session_lock_restore` y comprobar el socket y la firma que ve el gestor de usuario. Instalar el fragmento de Sumi en el invitado y usar `./install.sh hyprland --verify`. Comprobar primero que hyprlock por sí solo cierra todas las salidas y permite autenticar.
2. **Lock de Sumi.** Ejecutar el helper instalado desde la sesión de la VM o accionar Lock en la UI. Mantener una aplicación de prueba con texto antes del bloqueo y verificar visualmente que no recibe teclado ni puntero durante éste. `hyprctl locked` debe ser `true` y `lockStatus` debe indicar `phase=locked` y `secure=true`. Probar un único intento incorrecto y después la contraseña de prueba válida. Confirmar que todas las salidas vuelven y que el estado pasa a `unlocked`. No capturar imágenes ni registrar credenciales durante el bloqueo.
3. **Caída, perfil gestionado.** Repetir el bloqueo confirmado. Desde la TTY alternativa, detener sólo `sumi-shell.service` para impedir que su auto-restart se adelante al rescate. Medir la transición a hyprlock mediante el journal de `sumi-lock-rescue.service` y el estado del compositor. La sesión debe permanecer cubierta y sólo volver al escritorio después de autenticar. Si falla el rescate, recuperar desde la TTY con el locker de reserva ya validado o volver a la instantánea. Repetir desde una instantánea con un cierre inesperado del cliente para medir el camino de reinicio de systemd. Anotar qué cliente se hizo cargo.
4. **Ruta directa e inactividad.** Con `--no-units` verificar el bloqueo manual autenticado y el rescate manual desde la TTY. En una instantánea con hypridle, probar también `loginctl lock-session` y el timeout de inactividad con su fragmento. Confirmar que una solicitud de logind sin oyente no se contabiliza como bloqueo efectivo.

Registrar fallos de cobertura, de autenticación o de recuperación como **bloqueantes**, aunque el escritorio arranque. Guardar en VM los journals de Sumi, del rescate y de hypridle y el log de Hyprland. Las pruebas de PAM se observan en el invitado. Un `check` estático de binarios o configuraciones sólo confirma precondiciones.

## Salida

En la VM desbloqueada, revertir las integraciones añadidas y probar un locker independiente antes de retirar el helper de Sumi. En el perfil directo, parar la instancia de prueba. En el gestionado, verificar primero los hashes de testigos bajo config, estado, datos y una unidad ajena. Guardar `./install.sh uninstall --dry-run`, ejecutar `./install.sh uninstall` y comparar los hashes. El runtime y las unidades propias desaparecen y las preferencias y testigos permanecen.

Archivar por perfil: versión y lista de paquetes, hash del candidato, logs, IPC, estado de unidades, capturas desbloqueadas y hashes. Marcar cada punto como aprobado, fallido u omitido con su razón. La calificación **Fully Portable** requiere la ejecución observada del procedimiento con el candidato auditado.
