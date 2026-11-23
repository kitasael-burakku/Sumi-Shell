pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "../lib/xdg.js" as Xdg

/**
 * La cuenta de Wallhaven (rediseño 10E-1a; futureSettingssurface «Integración de Wallhaven
 * existente», §15 «Secretos fuera del JSON»).
 *
 *   · La CLAVE vive en `$XDG_STATE_HOME/sumi-shell/secrets/wallhaven.key`: carpeta 0700,
 *     archivo 0600, escritura atómica (temporal 0600 en la misma carpeta + mv). Llega al `sh`
 *     que la escribe POR STDIN: nunca en argumentos (se verían en `ps`), URLs ni logs. Fuera de
 *     `settings.json` (que se exporta y que `dotbackup` sube a GitHub). La UI nunca la enseña.
 *   · El USUARIO es una preferencia normal (`Settings.wallhavenUser`): la lectura de colecciones
 *     lo pide en la ruta.
 *   · Estado: none (Not configured) · pending (guardada, sin comprobar o sin red) · configured
 *     (Wallhaven la aceptó) · rejected (401). Una caída NO es una clave inválida. Se guarda con la
 *     hora de la comprobación en `secrets/wallhaven-account.json` (0600).
 *   · Test connection pide `/api/v1/settings` SÓLO al pulsarlo: con la clave válida devuelve los
 *     filtros de la cuenta, que Wallpaper List enseña para que el resultado no dependa de ajustes
 *     invisibles.
 *   · Cambiar o quitar la clave (o que la rechacen) avisa a `Wallhaven` (`identityChanged`): se
 *     cancelan sus peticiones y se invalidan los resultados en memoria.
 *
 * Pruebas: `testDir` (IPC `whTestAccountDir`, sólo bajo /tmp/) lleva la carpeta de secretos allí.
 */
Singleton {
    id: root

    readonly property string stateDir: Xdg.base(Quickshell.env("XDG_STATE_HOME"), Quickshell.env("HOME") + "/.local/state") + "/sumi-shell"
    property string testDir: ""
    readonly property string secretsDir: (root.testDir.length > 0 ? root.testDir : root.stateDir) + "/secrets"
    readonly property string keyPath: root.secretsDir + "/wallhaven.key"
    readonly property string statePath: root.secretsDir + "/wallhaven-account.json"

    /** La clave en memoria ("" = no hay). Nunca sale de este servicio salvo hacia la cabecera. */
    property string key: ""
    readonly property bool hasKeyFile: root.key.length > 0
    /** none · pending · configured · rejected */
    property string status: "none"
    property real checkedAt: 0
    property string reason: ""
    /** Los filtros de la cuenta que dio `/settings` ({ purity: [...], categories: [...], … }). */
    property var accountSettings: ({})
    property bool testing: false
    readonly property string username: Settings.wallhavenUser

    /** La clave vale para NSFW y colecciones privadas. */
    readonly property bool usable: root.hasKeyFile && root.status === "configured"
    /** Se manda la cabecera con cualquier clave que no esté rechazada. */
    readonly property string header: root.hasKeyFile && root.status !== "rejected" ? root.key : ""

    signal identityChanged()

    readonly property string statusText: root.status === "configured" ? "Configured"
        : root.status === "pending" ? "Pending validation"
        : root.status === "rejected" ? "Rejected" : "Not configured"

    // ---- guardar y quitar ----------------------------------------------------------

    /**
     * Guardar una clave nueva: queda «pending» hasta Test connection. Formato de Wallhaven:
     * 32 caracteres alfanuméricos; se rechaza antes de escribir si no lo parece.
     */
    function save(k) {
        const v = String(k || "").trim();
        if (!/^[A-Za-z0-9]{16,64}$/.test(v)) { root.reason = "That doesn't look like a Wallhaven API key"; return false; }
        if (writer.running) return false;
        writer.pendingKey = v;
        writer.stdinEnabled = true;          // no se reabre solo (memoria del proyecto)
        writer.command = ["sh", "-c", 'umask 077; mkdir -p -- "$1" && chmod 700 -- "$1" && t=$(mktemp -- "$1/.wallhaven.key.XXXXXX") '
            + '&& cat > "$t" && chmod 600 -- "$t" && mv -f -- "$t" "$1/wallhaven.key"', "_", root.secretsDir];
        writer.running = true;
        return true;
    }
    Process {
        id: writer
        property string pendingKey: ""
        onStarted: {
            writer.write(writer.pendingKey);
            writer.stdinEnabled = false;     // EOF: cat termina
        }
        onExited: function (code) {
            const v = writer.pendingKey;
            writer.pendingKey = "";
            if (code !== 0) { root.reason = "Could not save the key"; return; }
            root.key = v;
            root.setStatus("pending", "Saved · press Test connection", {});
            root.identityChanged();
        }
    }

    /** Quitar la clave: el archivo fuera, los resultados restringidos invalidados. */
    function remove() {
        Quickshell.execDetached(["rm", "-f", "--", root.keyPath]);
        root.key = "";
        root.setStatus("none", "", {});
        root.identityChanged();
        return true;
    }

    function setStatus(s, why, acct) {
        root.status = s;
        root.reason = why;
        root.checkedAt = Date.now();
        root.accountSettings = acct;
        stateFile.setText(JSON.stringify({ version: 1, status: s, checkedAt: root.checkedAt, account: acct }) + "\n");
    }

    // ---- comprobar ---------------------------------------------------------------------

    property var xhr: null
    function test() {
        if (!root.hasKeyFile) { root.reason = "Save a key first"; return false; }
        if (root.xhr) { try { root.xhr.abort(); } catch (e) {} }
        const x = new XMLHttpRequest();
        root.xhr = x;
        root.testing = true;
        root.reason = "Checking…";
        Wallhaven.requests++;
        x.onreadystatechange = function () {
            if (x.readyState !== XMLHttpRequest.DONE || x !== root.xhr) return;
            testDeadline.stop();
            root.xhr = null;
            root.testing = false;
            if (x.status === 401) {
                root.setStatus("rejected", "Wallhaven rejected this key", {});
                root.identityChanged();
            } else if (x.status === 200) {
                let o = null;
                try { o = JSON.parse((x.responseText || "").substring(0, 65536)); } catch (e) { o = null; }
                const d = o && o.data ? o.data : {};
                // la API real manda listas con un texto vacío (`resolutions: [""]`, medido): fuera
                const pick = (v) => Array.isArray(v) ? v.filter(s => typeof s === "string" && s.length > 0).map(s => s.substring(0, 20)).slice(0, 12) : [];
                root.setStatus("configured", "", { purity: pick(d.purity), categories: pick(d.categories),
                                                   resolutions: pick(d.resolutions), ratios: pick(d.aspect_ratios),
                                                   toplist: typeof d.toplist_range === "string" ? d.toplist_range.substring(0, 4) : "" });
                root.identityChanged();
            } else {
                // sin red o Wallhaven caído: la clave NO es inválida; se queda pendiente
                root.setStatus("pending", x.status === 0 ? "Wallhaven unavailable · try again later"
                                                         : "Wallhaven answered HTTP " + x.status + " · try again later", {});
            }
        };
        x.open("GET", Wallhaven.apiBase + "/settings");
        x.setRequestHeader("Accept", "application/json");
        x.setRequestHeader("X-API-Key", root.key);
        x.send();
        testDeadline.restart();
        return true;
    }
    Timer {
        id: testDeadline
        interval: 15000
        onTriggered: {
            if (!root.xhr) return;
            try { root.xhr.abort(); } catch (e) {}
            root.xhr = null;
            root.testing = false;
            root.setStatus("pending", "Wallhaven did not answer · try again later", {});
        }
    }

    /** Los filtros de la cuenta en una línea («SFW + Sketchy · General, Anime»). */
    function accountText() {
        const a = root.accountSettings || {};
        if (!a.purity) return "";
        const clean = (l) => Array.isArray(l) ? l.filter(x => typeof x === "string" && x.length > 0) : [];
        const cap = (s) => s.charAt(0).toUpperCase() + s.substring(1);
        const pur = clean(a.purity).map(p => p === "sfw" ? "SFW" : p === "nsfw" ? "NSFW" : cap(p)).join(" + ");
        const cat = clean(a.categories).map(cap).join(", ");
        const res = clean(a.resolutions);
        return pur + (cat ? " · " + cat : "") + (res.length ? " · " + res.join(", ") : "");
    }

    // ---- leer -------------------------------------------------------------------------------

    FileView {
        id: keyFile
        path: root.keyPath
        blockLoading: true
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            const v = keyFile.text().trim();
            const changed = v !== root.key;
            root.key = /^[A-Za-z0-9]{16,64}$/.test(v) ? v : "";
            if (changed && root.loaded) root.identityChanged();
        }
        onLoadFailed: { root.key = ""; }
    }
    property bool loaded: false
    /** Estado sin secretos: sólo qué se sabe de la clave y cuándo se comprobó. */
    FileView {
        id: stateFile
        path: root.statePath
        /**
         * FileView crea en 0644 (memoria del proyecto) y la escritura es asíncrona: un chmod justo
         * tras setText llegaba ANTES de que el archivo existiera (medido: quedó 0644). Aquí, cuando
         * ya está escrito.
         */
        onSaved: Quickshell.execDetached(["chmod", "600", "--", root.statePath])
        blockLoading: true
        printErrors: false
        onLoaded: {
            try {
                const o = JSON.parse(stateFile.text());
                if (["pending", "configured", "rejected"].indexOf(o.status) >= 0) root.status = o.status;
                root.checkedAt = typeof o.checkedAt === "number" ? o.checkedAt : 0;
                root.accountSettings = o.account && typeof o.account === "object" ? o.account : {};
            } catch (e) {}
            root.loaded = true;
        }
        onLoadFailed: { root.loaded = true; }
    }
    /** Sin archivo de clave, el estado no puede ser otro que «none». */
    onKeyChanged: if (root.key.length === 0 && root.status !== "none") { root.status = "none"; root.accountSettings = {}; }

    function setTestDir(dir) {
        const d = String(dir || "");
        if (d.length > 0 && (d.indexOf("/tmp/") !== 0 || d.indexOf("..") >= 0)) return false;
        // la misma carpeta: nada que cambiar (vaciar sin que cambie la ruta dejaba el estado en blanco
        // hasta reiniciar, porque FileView no relee; con la cuenta, la clave desaparecía de memoria)
        if (d === root.testDir) return true;
        root.loaded = false;
        root.key = "";
        root.status = "none";
        root.accountSettings = {};
        root.testDir = d;
        root.identityChanged();
        return true;
    }

    /** Para el IPC: NUNCA la clave; sólo si hay una, su estado y la cuenta. */
    function summary() {
        return { hasKey: root.hasKeyFile, status: root.status, statusText: root.statusText, reason: root.reason,
                 checkedAt: root.checkedAt, username: root.username, account: root.accountText(),
                 usable: root.usable, keyPath: root.keyPath, testing: root.testing };
    }
}
