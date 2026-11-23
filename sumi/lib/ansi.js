.pragma library

/*
 * Traduce la salida ANSI de los scripts de fish del rice (`set_color`, que
 * emite truecolor `ESC[38;2;r;g;b` y `ESC[1m`) a segmentos que la superficie
 * pinta con tokens de Minimaru.
 *
 * Mapa FIJO (decisión del usuario, 2026-09-09): los seis RGB de la paleta
 * "stone" que usan `dotbackup` y `diskbackup` → tokens del tema; cualquier
 * otro color cae a `fg`. Se comprobó ejecutando `diskbackup --check`:
 *   ESC[38;2;255;255;255;1m  blanco+negrita  → C_BOLD
 *   ESC[38;2;160;152;120m    beige apagado   → C_DIM
 *   ESC[38;2;106;171;122m    verde           → C_GREEN
 *   ESC[38;2;168;90;72m      rojo            → C_RED
 *   ESC[38;2;184;148;88m     ámbar           → C_YELLOW
 *   ESC[38;2;106;150;176m    azul/cian       → C_CYAN / C_BLUE
 *   ESC[m                    reset
 */

var RGB_TO_TOKEN = {
    "255;255;255": "fg",
    "160;152;120": "fgVariant",
    "106;171;122": "primary",
    "168;90;72":   "error",
    "184;148;88":  "secondary",
    "106;150;176": "fgVariant"
};

// Colores ANSI clásicos (30-37 / 90-97), por si algún script los usa.
var BASIC = ["fgVariant", "error", "primary", "secondary", "fgVariant",
             "fgVariant", "fgVariant", "fg"];

/**
 * Divide `text` en un array de { text, token, bold }. Descarta toda secuencia
 * CSI que no sea SGR (`m`) — mover cursor, borrar línea — para que no ensucie
 * la salida si algún día aparece.
 */
function parse(text) {
    var out = [];
    var token = "fg";
    var bold = false;
    var buf = "";
    var i = 0;

    function flush() {
        if (buf.length > 0) {
            out.push({ text: buf, token: token, bold: bold });
            buf = "";
        }
    }

    function applySgr(body) {
        var parts = (body.length === 0) ? ["0"] : body.split(";");
        for (var k = 0; k < parts.length; k++) {
            var n = parseInt(parts[k], 10);
            if (isNaN(n) || n === 0) { token = "fg"; bold = false; }
            else if (n === 1) bold = true;
            else if (n === 22) bold = false;
            else if (n === 39) token = "fg";
            else if (n === 38) {
                if (parts[k + 1] === "2") {
                    var key = parts[k + 2] + ";" + parts[k + 3] + ";" + parts[k + 4];
                    token = RGB_TO_TOKEN[key] || "fg";
                    k += 4;
                } else if (parts[k + 1] === "5") {
                    token = "fg";
                    k += 2;
                }
            }
            else if (n >= 30 && n <= 37) token = BASIC[n - 30];
            else if (n >= 90 && n <= 97) token = BASIC[n - 90];
        }
    }

    while (i < text.length) {
        var c = text.charCodeAt(i);
        if (c === 0x1b && text[i + 1] === "[") {
            var j = i + 2;
            while (j < text.length && !/[A-Za-z]/.test(text[j])) j++;
            var fin = text[j];
            if (fin === "m") { flush(); applySgr(text.slice(i + 2, j)); }
            i = j + 1;
            continue;
        }
        if (c !== 0x0d) buf += text[i];   // se ignora \r
        i++;
    }
    flush();
    return out;
}

/**
 * Igual que `parse` pero por líneas: devuelve un array de líneas, cada una un
 * array de segmentos. Útil para pintar con una línea por fila.
 */
function parseLines(text) {
    var lines = String(text).split("\n");
    var out = [];
    for (var i = 0; i < lines.length; i++)
        out.push(parse(lines[i]));
    return out;
}
