.pragma library
/*
 * Cómo se abre una orden en la terminal del usuario (portabilidad F3b, 2026-10-05; H-28, HC-30…33).
 *
 * La terminal la eligen `apps.terminal` (`auto` = la que detecta scripts/capabilities.py:
 * xdg-terminal-exec → $TERMINAL → LIST) y `apps.terminalExec` (cómo se le pasa la orden). Este
 * archivo sólo CONSTRUYE el argv: no lanza, no mira el PATH ni lee nada. Lo usan `services/Apps`
 * (y a través de él Jobs, Commands, Updates y Calendar) y el verbo de prueba `terminalArgv`.
 *
 * Un perfil por terminal conocida (el nombre del ejecutable, sin ruta):
 *   pre      lo que va justo detrás del ejecutable (wezterm: `start`)
 *   title    cómo se pone el título (%t), o nada si no se puede desde la orden
 *   cwd      cómo se fija el directorio (%d); sin él, se antepone `env -C <dir>`
 *   exec     lo que separa las opciones de la orden («auto»)
 *   execAfterTitle  kitty: `-e` sólo cuando hay título. Así lanzaba la shell hasta F3b (con título,
 *            `kitty --title X -e …`; sin él, `kitty …`): los argv del autor no cambian.
 * Una terminal desconocida: sin título, directorio por `env -C`, y `-e` salvo que se diga otra cosa.
 */

var PROFILES = {
    "kitty":             { title: ["--title", "%t"], cwd: ["--directory", "%d"], exec: [], execAfterTitle: ["-e"] },
    "foot":              { title: ["--title=%t"], cwd: ["--working-directory=%d"], exec: [] },
    "alacritty":         { title: ["--title", "%t"], cwd: ["--working-directory", "%d"], exec: ["-e"] },
    "wezterm":           { pre: ["start"], cwd: ["--cwd", "%d"], exec: ["--"] },
    "ghostty":           { title: ["--title=%t"], cwd: ["--working-directory=%d"], exec: ["-e"] },
    "konsole":           { cwd: ["--workdir", "%d"], exec: ["-e"] },
    "gnome-terminal":    { cwd: ["--working-directory=%d"], exec: ["--"] },
    "xdg-terminal-exec": { title: ["--title=%t"], cwd: ["--dir=%d"], exec: [] }
};

/** El orden de la detección automática (scripts/capabilities.py tiene la misma lista). */
var LIST = ["foot", "kitty", "alacritty", "wezterm", "ghostty", "konsole", "gnome-terminal"];

/** El nombre que ve el usuario («Opens in Kitty»); una desconocida, su ejecutable. */
var LABELS = { "kitty": "Kitty", "foot": "foot", "alacritty": "Alacritty", "wezterm": "WezTerm",
               "ghostty": "Ghostty", "konsole": "Konsole", "gnome-terminal": "GNOME Terminal",
               "xdg-terminal-exec": "the terminal" };

/** Los valores de `apps.terminalExec`. */
var EXEC = { "-e": ["-e"], "--": ["--"], "none": [] };

function baseName(bin) { return String(bin || "").replace(/^.*\//, ""); }

function label(bin) { return LABELS[baseName(bin)] || baseName(bin); }

function profileOf(bin) {
    var p = PROFILES[baseName(bin)];
    return p || null;
}

function fill(parts, key, value) {
    var out = [];
    for (var i = 0; i < parts.length; i++) out.push(parts[i].split(key).join(value));
    return out;
}

/**
 * El argv para abrir `argv` en la terminal `bin`.
 *   exec   el valor de apps.terminalExec («auto» = lo del perfil, o `-e` si no hay perfil)
 *   opts   { title, cwd }; los dos opcionales
 * Devuelve { argv, profile, title } con `title` = si se pudo poner el título.
 */
function build(bin, exec, argv, opts) {
    opts = opts || {};
    var p = profileOf(bin);
    var title = typeof opts.title === "string" && opts.title.length > 0 ? opts.title : "";
    var cwd = typeof opts.cwd === "string" && opts.cwd.length > 0 ? opts.cwd : "";
    var head = [bin];
    var lead = [];
    if (p && p.pre) head = head.concat(p.pre);
    var titled = false;
    if (title && p && p.title) { head = head.concat(fill(p.title, "%t", title)); titled = true; }
    if (cwd) {
        if (p && p.cwd) head = head.concat(fill(p.cwd, "%d", cwd));
        else lead = ["env", "-C", cwd];
    }
    var sep;
    if (exec && exec !== "auto" && EXEC[exec] !== undefined) sep = EXEC[exec];
    else if (p) sep = titled && p.execAfterTitle ? p.execAfterTitle : p.exec;
    else sep = ["-e"];
    return { argv: lead.concat(head, sep, argv), profile: p ? baseName(bin) : "", title: titled };
}

/**
 * Pegar en una terminal (selector de emojis, 2026-11-17): las terminales pegan con Ctrl+Shift+V, porque
 * Ctrl+V es un carácter de control para el programa que corre dentro. Clases de ventana (appId de
 * Hyprland), en minúsculas; se compara sin distinguir mayúsculas.
 */
var PASTE_SHIFT = ["kitty", "foot", "footclient", "alacritty", "org.wezfurlong.wezterm", "com.mitchellh.ghostty",
                   "ghostty", "org.kde.konsole", "konsole", "org.gnome.terminal", "gnome-terminal-server",
                   "org.gnome.ptyxis", "org.gnome.console", "xfce4-terminal", "tilix", "com.gexperts.tilix",
                   "terminator", "st", "st-256color", "rio", "contour", "warp", "dev.warp.warp"];

/** Los modificadores de «pegar» para la ventana de clase `appId`: "CTRL SHIFT" en una terminal, "CTRL" si no. */
function pasteMods(appId) {
    var a = String(appId || "").toLowerCase();
    return PASTE_SHIFT.indexOf(a) >= 0 ? "CTRL SHIFT" : "CTRL";
}

if (typeof module !== "undefined")
    module.exports = { PROFILES: PROFILES, LIST: LIST, EXEC: EXEC, LABELS: LABELS, baseName: baseName, label: label,
                       profileOf: profileOf, build: build, PASTE_SHIFT: PASTE_SHIFT, pasteMods: pasteMods };
