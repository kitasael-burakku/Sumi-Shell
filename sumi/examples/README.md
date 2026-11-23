# Ejemplos de configuración (portabilidad F3)

La shell lee su configuración de `$XDG_CONFIG_HOME/sumi-shell/` (normalmente `~/.config/sumi-shell/`).
Estos archivos son puntos de partida. Cópialos allí y edítalos si quieres activar esas funciones.
La primera carga y las conversiones de ajustes v2/v3 dejan estos archivos a tu elección.

- **`websites.conf`:** los marcadores del web hub (Super+Ctrl+/).
  - Sin él, el hub dice «No websites.conf yet» y la ruta.
  - Formato: `[Categoría]` y líneas `Nombre | URL`.
- **`tasks.json`:** las tareas de mantenimiento del Dashboard y de la paleta.
  - El ejemplo ejecuta `df -h` para mostrar el espacio local. Declara en `requires` los programas y
    archivos imprescindibles de tus propias tareas. Settings → System → Environment muestra los motivos de ausencia.
  - Para reutilizar tus tareas de una instalación anterior, copia su `tasks.json` al directorio de
    configuración de Sumi mientras la shell está detenida. Revisa los comandos y rutas antes de activarlas.
  - **Rutas con `~`:** la shell expande `~/` en `argv[0]`, `requires`, `lastRun`, `sshKey` y `summary`. Dentro de
    una línea para un intérprete (`fish -c "…"`, `sh -c "…"`) la expande ese intérprete al ejecutarse, así que
    `~/` o `$HOME/` ahí también siguen al usuario. Un argumento suelto `~/…` sin intérprete llega tal cual al
    programa. No escribas rutas con tu usuario (`/home/<nombre>/…`): el archivo deja de servir con otro HOME.
  - Formato v1 (lo valida `lib/tasks-schema.js`). Cada tarea lleva `id`, `label`, `argv` en lista
    (nunca una línea para `sh -c` que construya la shell) y `runs` (`panel` o `terminal`).
  - Campos opcionales: `desc`, `console`, `glyph`, `title`, `output` (`plain` | `jsonl-report`),
    `prompts` (`none` | `dotbackup`), `confirm`, `successText`, `sshAgent`, `sshKey`, `palette`,
    `requires`, `lastRun` (`git` o `newest`), `summary` y `role` (`system-upgrade`).
  - **Seguridad:** el archivo se ignora entero si no es tuyo o lo pueden escribir otros usuarios
    (`chmod go-w`). No se exporta ni se importa con «Export/Import settings».
  - **Sin `tasks.json`** no hay mantenimiento: el Dashboard sólo enseña «Failed services».
  - La frecuencia esperada de una copia no va aquí: es un ajuste (Settings → Dashboard).

La terminal y el navegador no son archivos: están en Settings → Shell → Apps (`apps.terminal` y
`apps.browser` en `settings.json`). Con «Auto», se detectan.

## hypridle (portabilidad F5d)

- **`hypridle/sumi.conf`:** para que el bloqueo por inactividad, antes de suspender y por `loginctl lock-session`
  lo haga la shell. Inclúyelo con `source =` desde tu `hypridle.conf` (o copia el bloque `general`) y reinicia hypridle.
- Sin hypridle, el botón Lock bloquea igual (directo), pero nada bloquea por inactividad ni antes de suspender salvo el
  botón Suspend de la shell. Settings → Shell → Lock screen → «Handled by» dice quién atiende el bloqueo.
- Con un hypridle cuyo `lock_cmd` es hyprlock, la shell lo respeta: el botón pide el bloqueo a logind y bloquea hyprlock.

## Hyprland (portabilidad F5h)

- **`hyprland/sumi.lua`** (config Lua) y **`hyprland/sumi.conf`** (hyprland.conf, **sólo Hyprland ≤ 0.56**: desde
  0.57 Hyprland sólo lee Lua; el `.conf` queda congelado para versiones anteriores): los atajos de la shell (puedes cambiar las teclas), las opciones del Lock (`allow_session_lock_restore`,
  `session_lock_xray`), el vidrio de la capa principal y de las UIs flotantes (reinicia la shell una vez para que la principal lo reciba) y el arranque por `exec-once` comentado (lo normal es la unidad de systemd).
- Las teclas son las **por defecto** de la shell (`lib/shortcuts.json`, las mismas que usa `install.sh`), no
  necesariamente las del autor. En Lua cada atajo lleva `{ description = "Sumi Shell: <nombre>" }`: con Hyprland 0.57
  es lo único que permite a la ayuda de atajos (Settings → Shell → Interaction → Keyboard shortcuts) reconocer la
  tecla. Si cambias una tecla, deja la descripción.
- Cópialo a `~/.config/hypr/` y añade UNA línea al final de tu config: `require("sumi")` (Lua) o
  `source = ~/.config/hypr/sumi.conf` (hyprlang). La shell no edita tu config de Hyprland.
- Validados con `Hyprland --verify-config` y cargados en un Hyprland anidado. Comprueba los tuyos igual:
  `Hyprland --verify-config --config ~/.config/hypr/hyprland.lua` (o `.conf` hasta 0.56; con 0.57 un `.conf` se lee como
  Lua y falla en la primera línea).
- Para probar el bloqueo y su rescate usa la [guía de VM](../../packaging/PORTABILITY-VM.md).
