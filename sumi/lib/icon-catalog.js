.pragma library

// Un catálogo inmutable para todos los iconos de este motor QML.
var glyphs = Object.freeze({
    "clock":        "󰅐",
    // More de la barra (8C-2): md-dots_horizontal, comprobado por nombre en el cmap
    "dots":         String.fromCodePoint(0xF01D8),
    // clima (7D), comprobados por nombre en el cmap de IosevkaTerm NF Propo
    "weather-sunny":        String.fromCodePoint(0xF0599),
    "weather-night":        String.fromCodePoint(0xF0594),
    "weather-partly":       String.fromCodePoint(0xF0595),
    "weather-night-partly": String.fromCodePoint(0xF0F31),
    "weather-cloudy":       String.fromCodePoint(0xF0590),
    "weather-fog":          String.fromCodePoint(0xF0591),
    "weather-rain":         String.fromCodePoint(0xF0597),
    "weather-pouring":      String.fromCodePoint(0xF0596),
    "weather-snow":         String.fromCodePoint(0xF0598),
    "weather-sleet":        String.fromCodePoint(0xF067F),
    "weather-storm":        String.fromCodePoint(0xF067E),
    "humidity":             String.fromCodePoint(0xF058E),
    "rain-chance":          String.fromCodePoint(0xF054B),
    "place":                String.fromCodePoint(0xF07D9),
    "brightness":           String.fromCodePoint(0xF00DF),   // md-brightness_6 (7E-1)
    // Centro de control (2026-11-15, comprobados con fontTools en IosevkaTerm Nerd Font Propo)
    "dismiss":              String.fromCodePoint(0xF015A),   // md-close_circle_outline: el ⊗ de un aviso (botón: trazo fino)
    "clear-all":            String.fromCodePoint(0xF039F),   // md-notification_clear_all: el ≡ de Clear all
    // nivel de batería en décimas (md-battery_10…90, md-battery; _outline = vacía) y cargando (md-battery_charging_*)
    "battery-0": String.fromCodePoint(0xF008E), "battery-10": String.fromCodePoint(0xF007A), "battery-20": String.fromCodePoint(0xF007B),
    "battery-30": String.fromCodePoint(0xF007C), "battery-40": String.fromCodePoint(0xF007D), "battery-50": String.fromCodePoint(0xF007E),
    "battery-60": String.fromCodePoint(0xF007F), "battery-70": String.fromCodePoint(0xF0080), "battery-80": String.fromCodePoint(0xF0081),
    "battery-90": String.fromCodePoint(0xF0082), "battery-100": String.fromCodePoint(0xF0079),
    "battery-charging-0": String.fromCodePoint(0xF089F), "battery-charging-10": String.fromCodePoint(0xF089C),
    "battery-charging-20": String.fromCodePoint(0xF0086), "battery-charging-30": String.fromCodePoint(0xF0087),
    "battery-charging-40": String.fromCodePoint(0xF0088), "battery-charging-50": String.fromCodePoint(0xF089D),
    "battery-charging-60": String.fromCodePoint(0xF0089), "battery-charging-70": String.fromCodePoint(0xF089E),
    "battery-charging-80": String.fromCodePoint(0xF008A), "battery-charging-90": String.fromCodePoint(0xF008B),
    "battery-charging-100": String.fromCodePoint(0xF0085),
    "star":                 String.fromCodePoint(0xF04CE),   // md-star (9D-1, comprobado por nombre)
    "star-outline":         String.fromCodePoint(0xF04D2),   // md-star_outline
    "wallpaper":    "󰸉",
    "image":        "󰥶",
    "info":         "󰋽",
    "cog":          "󰢻",
    "power":        "󰐥",
    "target": "\u{f04fe}", // md-target, verificado en IosevkaTerm Nerd Font Propo
    "monitor":      "󰍹",
    "palette":      "󰸌",
    "awake":        "󰛊",
    "eye":          "󰛐",
    "volume-high":  "󰕾",
    "volume-mid":   "󰖀",
    "volume-low":   "󰕿",
    "volume-off":   "󰖁",
    "play":         "󰐊",
    "pause":        "󰏤",
    "next":         "󰒭",
    "prev":         "󰒮",
    "music":        "󰽴",
    "search":       "󰍉",
    "mixer":        "󰙪",
    "calc":         "󰃬",
    "bell":         "󰂚",
    "bell-off":     "󰂛",
    "mic":          "󰍬",
    "screenshare":  "󰹑",
    "update":       "󰚰",
    "check":        "󰄬",
    /** md-close (U+F0156), comprobado por nombre con fontTools (2026-09-24). */
    "close":        "󰅖",
    "alert":        "󰀦",
    "gauge":        "󰍛",
    "calendar":     "󰭧",
    "terminal":     "󰞷",
    "wifi":         "󰖩",
    "wifi-1":       "󰤟",
    "wifi-2":       "󰤢",
    "wifi-3":       "󰤥",
    "wifi-4":       "󰤨",
    "wifi-none":    "󰤯",
    "wifi-off":     "󰤭",
    "wifi-alert":   "󰤠",
    "ethernet":     "󰈀",
    "net-off":      "󰈂",
    "bt":           "󰂯",
    "bt-on":        "󰂱",
    "bt-off":       "󰂲",
    "bt-search":    "󰂰",
    "headset":      "󰋎",
    "headphones":   "󰋋",
    "speaker":      "󰓃",
    "keyboard":     "󰌌",
    "mouse":        "󰍽",
    "controller":   "󰊴",
    "cellphone":    "󰄜",
    "laptop":       "󰌢",
    "tv":           "󰔂",
    "printer":      "󰐪",
    "watch":        "󰖉",
    "battery":      "󰁹",
    "battery-alert":"󰂃",
    "lock":         "󰍁",
    "logout":       "󰗽",
    "suspend":      "󰤄",
    "restart":      "󰜉",
    "hibernate":    "󰼪",
    "chevron-left": "󰅁",
    "chevron-right":"󰅂",
    "chevron-down": "󰅀",
    "clipboard":    "󰆒",
    // selector de emojis (2026-11-17): md-emoticon_outline, comprobado por nombre en el cmap
    "emoji":        String.fromCodePoint(0xF01F2),
    "web":          "󰖟",
    "folder":       "󰉖",
    // la tienda de Wallhaven (W3), comprobados por nombre con fontTools (2026-09-26)
    "download":     String.fromCodePoint(0xF0B8F),   // md-download_outline
    // Eventos locales del calendario, comprobados por nombre con fontTools (2026-10-27)
    "plus":         String.fromCodePoint(0xF0415),   // md-plus
    "edit":         String.fromCodePoint(0xF0CB6),   // md-pencil_outline
    "delete":       String.fromCodePoint(0xF0A7A),   // md-trash_can_outline
    "open-external": String.fromCodePoint(0xF03CC),  // md-open_in_new
    // Grabador de pantalla, comprobados por nombre con fontTools (2026-10-29). El botón es de trazo
    // (md-record_circle_outline); la región y «elegir pantalla», también de trazo
    "recorder":     String.fromCodePoint(0xF0EC3),   // md-record_circle_outline
    "region":       String.fromCodePoint(0xF0A6D),   // md-selection_drag
    "monitor-multiple": String.fromCodePoint(0xF037A), // md-monitor_multiple
    // el estado «se graba» (barra), relleno como las alarmas: md-record
    "record":       String.fromCodePoint(0xF044A),
    // copiar la grabación al portapapeles (segunda entrega), de trazo como los botones: md-content_copy
    "copy":         String.fromCodePoint(0xF018F),
    // Speed test (2026-11-14), comprobados por nombre con fontTools en IosevkaTerm Nerd Font Propo
    "rocket":       String.fromCodePoint(0xF14DE),   // md-rocket_launch
    "upload":       String.fromCodePoint(0xF0E07),   // md-upload_outline
    "timer":        String.fromCodePoint(0xF051B),   // md-timer_outline
    "stop":         "󰓛",
    "reload":       "󰑓",
    "history":      "󰋚",
    "check-circle": "󰄴",
    "x-circle":     "󰅜",
    "window":       "󰖲",
    "server":       "󰆧",
    "file":         "󰈤",
    "folder-open":  "󰷏",
    // Pantalla de bloqueo (docs/lock/INTERFAZ.md §4), comprobados con fontTools
    // el 2026-09-17: md-apple_keyboard_caps (U+F0632, el ⇪ que pide el plan;
    // md-caps_lock era una «A» en un recuadro y no se leía a 15 px) y
    // md-numeric_1_box (U+F03A4, relleno: es estado, como la batería).
    "caps-lock":    "󰘲",
    "num-lock":     "󰎤"
})


/**
 * ── UN COLOR POR GLIFO, 2026-09-16 ─────────────────────────────────────
 *
 * Petición del usuario. No son colores inventados: son **roles de Material
 * que matugen ya generaba** y que el shell no leía (`secondary`,
 * `primary_fixed`, `secondary_fixed`, `tertiary_fixed`), así que siguen al
 * wallpaper como todo lo demás. Medido con `matugen --dry-run --json` sobre
 * el fondo actual: los cuatro tonos fuertes caen a **la misma luminancia
 * (0,77)** y los tres suaves a 0,88 — o sea que separan por TONO y no por
 * brillo, que es lo que deja que una fila de veinte iconos siga leyéndose
 * como una fila y no como una guirnalda.
 *
 * El reparto sigue los bloques de la cara hover, y dentro de cada bloque
 * alterna fuerte/suave para que no haya dos seguidos iguales:
 *
 *   buscar    primary · primary suave · tertiary · tertiary suave
 *   medios    secondary · secondary suave · tertiary · primary
 *   sistema   tertiary suave · primary · secondary · primary suave
 *   sesión    secondary suave · neutro · tertiary · peligro
 *
 * Y hay dos familias que NO entran en el reparto, a propósito:
 *   · las **alarmas** (aviso, micro, pantalla compartida, mute, batería
 *     baja) van todas en `tintDanger`: si el rojo fuera un color más, dejaría
 *     de querer decir algo;
 *   · el **estado** (wifi, bluetooth, batería, bandeja) no se toca aquí
 *     porque sus llamadores ya le ponen `color:` según el estado, y quien
 *     pone `color:` gana.
 *
 * Retocarlo es editar esta tabla y nada más.
 */
var tints = Object.freeze({
    // buscar
    "search": "p",  "clipboard": "ps", "web": "t",  "window": "ts",  "emoji": "t",
    "calc": "p",    "history": "ps",   "file": "ps", "folder": "ps",
    "folder-open": "p",
    // medios
    "music": "s",   "pause": "s",  "play": "s",  "next": "s", "prev": "s",
    "wallpaper": "ss", "image": "ss", "palette": "t", "mixer": "p",
    "monitor": "t", "eye": "t",    "speaker": "ts", "headphones": "ts",
    "headset": "ts", "recorder": "s", "region": "t", "monitor-multiple": "t", "copy": "ps",
    // sistema
    "calendar": "ts", "clock": "ts", "gauge": "p", "server": "s",
    "rocket": "p", "download": "p", "upload": "s", "timer": "t",
    "terminal": "ps", "update": "s", "reload": "s", "stop": "s",
    "check": "p",     "check-circle": "p",  "plus": "p", "edit": "ps",
    // sesión
    "awake": "ss", "cog": "n", "info": "t", "power": "d",
    "lock": "ps",  "logout": "n", "suspend": "n", "restart": "n",
    "hibernate": "ts",
    // alarmas — el rojo sólo quiere decir una cosa
    "alert": "d", "bell-off": "d", "mic": "d", "screenshare": "d",
    "battery-alert": "d", "volume-off": "d", "x-circle": "d", "record": "d"
})
