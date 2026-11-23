.pragma library
/*
 * El `Exec=` de un `.desktop`, troceado como dice la especificación (ADR-32, 2026-10-11).
 *
 * `DesktopEntry.command` de Quickshell 0.3.2 trata el apóstrofe como comilla AUNQUE vaya dentro de
 * comillas dobles. Medido con un juego en `~/Downloads/games/Slave's Nightmare [Final]/`:
 *   Exec=… umu-run "/…/Slave's Nightmare [Final]/Game_en.exe"
 * llegaba como `umu-run /…/Slaves Nightmare [Final]/Game_en.exe` partido en TRES argumentos (sin el
 * apóstrofe), Proton no encontraba el .exe y salía en ~2 s. `gio launch` (GLib) lo abre bien.
 *
 * Desktop Entry Specification §«The Exec key»:
 *   - los argumentos se separan por espacio sin comillas; las comillas son SÓLO dobles;
 *   - dentro de comillas dobles, `\` escapa `"`, `` ` ``, `$` y `\`; el resto es literal (el
 *     apóstrofe incluido);
 *   - códigos de campo: `%%` = `%`; `%f %F %u %U` = los archivos/URLs (aquí nunca hay: se quitan,
 *     como hacía Quickshell); `%i` = `--icon <Icon>`; `%c` = el nombre; `%k` = la ruta del
 *     `.desktop`; `%d %D %n %N %v %m`, obsoletos, se quitan. Un código desconocido se quita.
 * Fuera de comillas el apóstrofe es un carácter reservado que la especificación no permite: se toma
 * literal (igual que GLib), nunca como comilla.
 *
 * No lanza, no lee nada. Lo usa `services/Apps` (`argvOf`) y el verbo de prueba `appArgv`; la prueba
 * sin sesión es `tools/apps/desktop-exec-test.js` (del repo Quickshell).
 *
 * parse(exec, ctx) -> { argv: [..], error: "" }   ctx = { icon, name, location } (todos opcionales)
 * Con `error` no vacío (comilla sin cerrar, `\` final) `argv` va vacío: quien llama decide.
 */

function _fields(word, quoted, ctx, out) {
    // `word` es el argumento ya sin comillas. Un `%` entre comillas también es código de campo: la
    // especificación no distingue. `quoted` sólo sirve para conservar un `""` (argumento vacío).
    if (word.length === 2 && word.charAt(0) === "%") {
        const c = word.charAt(1);
        if (c === "i") { if (ctx.icon) out.push("--icon", String(ctx.icon)); return; }
        if (c === "c") { out.push(String(ctx.name || "")); return; }
        if (c === "k") { out.push(String(ctx.location || "")); return; }
        if (c === "%") { out.push("%"); return; }
        return;                       // %f %F %u %U y obsoletos/desconocidos: fuera el argumento
    }
    let s = "";
    for (let i = 0; i < word.length; i++) {
        const ch = word.charAt(i);
        if (ch !== "%" || i + 1 >= word.length) { s += ch; continue; }
        const c = word.charAt(++i);
        if (c === "%") s += "%";
        else if (c === "c") s += String(ctx.name || "");
        else if (c === "k") s += String(ctx.location || "");
        // %i dentro de una palabra no tiene sentido (son dos argumentos): se quita, como el resto
    }
    if (s.length > 0 || quoted) out.push(s);
}

function parse(exec, ctx) {
    ctx = ctx || {};
    const src = String(exec || "");
    const argv = [];
    let word = "", inWord = false, quoted = false, inQuote = false;
    for (let i = 0; i < src.length; i++) {
        const ch = src.charAt(i);
        if (inQuote) {
            if (ch === "\\") {
                if (i + 1 >= src.length) return { argv: [], error: "trailing backslash" };
                const nx = src.charAt(i + 1);
                if (nx === "\"" || nx === "`" || nx === "$" || nx === "\\") { word += nx; i++; }
                else word += ch;
            } else if (ch === "\"") inQuote = false;
            else word += ch;
            continue;
        }
        if (ch === " " || ch === "\t" || ch === "\n") {
            if (inWord) _fields(word, quoted, ctx, argv);
            word = ""; inWord = false; quoted = false;
            continue;
        }
        inWord = true;
        if (ch === "\"") { inQuote = true; quoted = true; }
        else if (ch === "\\") {
            if (i + 1 >= src.length) return { argv: [], error: "trailing backslash" };
            word += src.charAt(++i);
        } else word += ch;
    }
    if (inQuote) return { argv: [], error: "unterminated quote" };
    if (inWord) _fields(word, quoted, ctx, argv);
    return { argv: argv, error: "" };
}

if (typeof module !== "undefined")
    module.exports = { parse: parse };
