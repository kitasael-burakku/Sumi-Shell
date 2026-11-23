-- Sumi Shell para Hyprland con config Lua (0.56+; desde 0.57, el único dialecto que Hyprland lee). Portabilidad F5h;
-- validado con `Hyprland --verify-config` y cargado en un Hyprland anidado (tools/f5/acceptance-check.py), en 0.56.2 y 0.57.0.
--
-- Cópialo a ~/.config/hypr/sumi.lua y añade AL FINAL de tu hyprland.lua:
--     require("sumi")
-- (Medido en 0.56.2: un error DENTRO de este archivo se informa igual con `pcall(require, "sumi")`; pcall sólo
-- calla que el archivo falte. Sin pcall, que falte también se ve.)
-- La shell no edita tu config: este archivo es tuyo. Cambia las teclas que choquen con las tuyas.
-- Qué abre cada atajo y con qué tecla: Settings → Shell → Interaction → Keyboard shortcuts (o «keyboard» en el
-- launcher).

-- Arranque. Lo normal es la unidad de systemd del proyecto (sumi/systemd/sumi-shell.service), que necesita
-- WAYLAND_DISPLAY y HYPRLAND_INSTANCE_SIGNATURE en el gestor de usuario: Hyprland las exporta solo al arrancar (salvo
-- con HYPRLAND_NO_SD_VARS) y uwsm también. Si NO usas la unidad, quita el comentario:
-- hl.on("hyprland.start", function()
--     hl.exec_cmd("qs -c sumi --no-duplicate")
-- end)

-- Bloqueo: retomar el bloqueo si la shell cae con la sesión bloqueada, y transiciones con el escritorio vivo.
hl.config({ misc = { allow_session_lock_restore = true, session_lock_xray = true } })

-- Vidrio (opcional): la capa principal (barra, paneles, Settings…) y las UIs flotantes, cada una en su capa.
-- ignore_alpha deja fuera lo transparente y casi toda la sombra; tiene que quedar por debajo de tu Glass opacity.
-- Hyprland aplica el blur al CREARSE la capa: tras añadirlo, reinicia la shell una vez para que lo reciba la principal.
hl.layer_rule({ name = "sumi-shell", match = { namespace = "sumi-shell" }, blur = true, ignore_alpha = 0.40 })
hl.layer_rule({ name = "sumi-shell-uis", match = { namespace = "^sumi-(audio|calendar|keybinds|login|monitor|notifications|settings|tasks|wallhaven)$" }, blur = true, ignore_alpha = 0.40 })

-- Movimiento: la shell anima sus capas en QML (y respeta su Animations: Off). Sin esta regla, tus animaciones de
-- capas (layersIn/layersOut, fadeLayersIn/Out) se suman a las suyas al abrir y cerrar cada ventana flotante.
hl.layer_rule({ name = "sumi-shell-motion", match = { namespace = "^sumi-.*$" }, no_anim = true })

-- Los 29 atajos globales (appid sumi; core/Shortcuts.qml) con sus teclas POR DEFECTO, las oficiales de la shell
-- (sumi/lib/shortcuts.json: la misma tabla que usa `install.sh hyprland --apply`; no tienen por qué ser las del autor).
-- La `description` no es decorativa: Hyprland 0.57 no dice qué atajo global llama un bind de Lua (`hyprctl binds -j`
-- sólo da «HL.Dispatcher(global)»), y la ayuda de atajos de la shell (Settings → Shell → Interaction → Keyboard
-- shortcuts) reconoce la tecla de cada acción por esa descripción. Sin ella dice «Key not identifiable».
-- Si cambias una tecla, deja la descripción tal cual.
local function shell(keys, name)
    hl.bind(keys, hl.dsp.global("sumi:" .. name), { description = "Sumi Shell: " .. name })
end
shell("SUPER + SPACE", "launcher")
shell("SUPER + W", "wallpaper")
shell("SUPER + CTRL + W", "wallhaven")
shell("SUPER + CTRL + R", "wallRandom")
shell("SUPER + CTRL + S", "settings")
shell("SUPER + Y", "system")
shell("SUPER + CTRL + Y", "monitor")
shell("SUPER + A", "mixer")
shell("SUPER + SHIFT + A", "audio")
shell("SUPER + SHIFT + SLASH", "web")
shell("SUPER + ESCAPE", "power")
shell("SUPER + SHIFT + V", "clipboard")
shell("SUPER + PERIOD", "emoji")
shell("SUPER + N", "wifi")
shell("SUPER + CTRL + N", "controlCenter")
shell("SUPER + CTRL + B", "bluetooth")
shell("SUPER + C", "calendar")
shell("SUPER + CTRL + C", "calendarUi")
shell("SUPER + CTRL + L", "loginScreen")
shell("SUPER + R", "recorder")
shell("SUPER + CTRL + D", "dashboard")
shell("SUPER + CTRL + T", "tasks")
shell("ALT + TAB", "minimizer")
shell("SUPER + U", "services")
shell("SUPER + T", "theme")
shell("SUPER + CTRL + P", "barToggle")
shell("SUPER + CTRL + SPACE", "peek")
shell("SUPER + CTRL + X", "cli")
shell("SUPER + CTRL + K", "keepAwake")
shell("SUPER + CTRL + A", "notifications")
shell("SUPER + F1", "keybinds")
