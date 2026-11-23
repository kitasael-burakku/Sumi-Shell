pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

/**
 * Unidades de systemd para las superficies `services` / `serviceDetail` / `serviceJournal`
 * (Fase 10.c; ámbitos y tipos desde el rediseño 11F-1, futuresystemd-unitssurface).
 *
 * DOS ÁMBITOS, NUNCA MEZCLADOS: `user` (`systemctl --user`) y `system`. Cada fila, ficha y journal
 * se identifica por ÁMBITO + NOMBRE (`key()`: "user:foo.service", "system:sshd.service"); una clave
 * sin prefijo es de usuario (lo que había antes de la 11F-1).
 *
 * TIPOS: la lista trae `.service`, `.timer`, `.socket`, `.mount` y `.automount`. El resto
 * (`.path`, `.target`, `.device`, `.scope`, `.slice`, `.swap`) no se lista, pero su ficha de sólo
 * lectura se abre por nombre exacto o desde un aviso del Dashboard.
 *
 * ACCIONES: Start/Stop/Restart sobre `.service` de usuario (10.c) y, desde la 11F-2, de sistema
 * con autorización, confirmación, servicios protegidos y verificación (ver «acciones»).
 *
 * EN VIVO MIENTRAS SE MIRA (QS-FUNC-007): con una reclamación la lista del ÁMBITO RECLAMADO se
 * relee cada 5 s (sólo ese: la de sistema tiene ~230 unidades y no se lee si nadie la mira), y tras
 * una acción también a 0,5 y 2 s. El journal es `journalctl -f`. Sin reclamaciones, cero.
 *
 * AUSENCIA ≠ VACÍO: una lectura que falla deja el ámbito en `error` con el motivo y conserva la
 * última lista buena (antigua), para que la vista diga «Unknown state» en vez de «0 unidades».
 */
Singleton {
    id: root

    readonly property bool userSupported: Capabilities.userManagerState === "available"
    readonly property bool systemSupported: Capabilities.systemManagerState === "available"
    readonly property bool supported: root.userSupported || root.systemSupported
    function scopeSupported(scope) { return scope === "system" ? root.systemSupported : root.userSupported; }
    Connections {
        target: Capabilities
        function onUserManagerStateChanged() { root.managerChanged(); }
        function onSystemManagerStateChanged() { root.managerChanged(); }
    }
    function managerChanged() {
        if (!root.scopeSupported(root.journalScope)) root.closeJournal();
        const ls = Object.assign({}, root.lists);
        for (const sc of root.scopes)
            if (!root.scopeSupported(sc)) ls[sc] = { rows: [], state: "unavailable",
                error: "Systemd service manager is unavailable", at: 0, stale: false };
        root.lists = ls;
        if (!root.supported) {
            root.failed = [];
            root.failedTotal = -1;
            root.failedError = "";
        } else {
            root.refresh();
        }
    }

    readonly property var scopes: ["user", "system"]
    readonly property var listedTypes: ["service", "timer", "socket", "mount", "automount"]
    readonly property var allTypes: ["service", "timer", "socket", "mount", "automount",
                                     "path", "target", "device", "scope", "slice", "swap"]

    /** Clave estable de una unidad: ámbito + nombre. */
    function key(scope, unit) { return (scope === "system" ? "system" : "user") + ":" + unit; }
    /** { scope, unit } de una clave; sin prefijo, de usuario (compatibilidad con la 10.c). */
    function parseKey(k) {
        const s = String(k || "");
        if (s.indexOf("system:") === 0) return { scope: "system", unit: s.slice(7) };
        if (s.indexOf("user:") === 0) return { scope: "user", unit: s.slice(5) };
        return { scope: "user", unit: s };
    }
    function typeOf(unit) {
        const i = String(unit).lastIndexOf(".");
        return i >= 0 ? String(unit).slice(i + 1) : "";
    }
    function scopeArgs(scope) { return scope === "system" ? [] : ["--user"]; }

    // --- listas por ámbito ------------------------------------------------

    /**
     * { user: {…}, system: {…} }, cada una { rows, state, error, at, stale }:
     *   rows   [{ scope, unit, type, load, active, sub, desc }] — fallidas primero
     *   state  loading · ready · error
     *   error  el motivo de la última lectura fallida ("" si fue buena)
     *   at     hora (ms) de la última lectura buena; stale = hay filas de antes de un fallo
     */
    property var lists: ({
        user: { rows: [], state: "loading", error: "", at: 0, stale: false },
        system: { rows: [], state: "loading", error: "", at: 0, stale: false }
    })
    property int rev: 0
    function listOf(scope) { return root.lists[scope === "system" ? "system" : "user"]; }
    /** Compatibilidad (10.c, IPC `unitsList`): los servicios de usuario. */
    readonly property var units: root.lists.user.rows.filter(r => r.type === "service")
    readonly property bool ready: root.lists.user.state !== "loading"

    /**
     * RECLAMACIONES CON NOMBRE (fase 6A). El valor dice QUÉ ámbito se mira: "user" / "system";
     * `true` (lo de antes de la 11F-1) es "user". Clave con el monitor (QS-FUNC-003).
     */
    property var claims: ({})
    readonly property bool wanted: root.supported && Object.keys(root.claims).length > 0
    readonly property var wantedScopes: {
        const out = [];
        for (const k in root.claims) {
            const v = root.claims[k] === "system" ? "system" : "user";
            if (out.indexOf(v) < 0) out.push(v);
        }
        return out;
    }

    function claim(who, on) {
        const v = on === "system" ? "system" : (on ? "user" : false);
        if (v === (root.claims[who] || false)) return;
        // Objeto NUEVO: reasignar el mismo no emite la señal de cambio.
        const c = Object.assign({}, root.claims);
        if (v) c[who] = v; else delete c[who];
        root.claims = c;
        if (root.wanted)
            root.refresh();
    }

    function refresh() {
        if (!root.supported) return;
        for (const sc of root.wantedScopes) root.refreshScope(sc);
        root.refreshFailed();
    }
    function refreshScope(scope) {
        if (!root.scopeSupported(scope)) return;
        const p = scope === "system" ? listSysProc : listUsrProc;
        if (p.running) return;
        root._listFail[scope] = root.listFailReads[scope] > 0;
        if (root.listFailReads[scope] > 0) {
            const f = Object.assign({}, root.listFailReads);
            f[scope]--;
            root.listFailReads = f;
        }
        p.running = true;
    }
    /** Pruebas (IPC `unitsListFailTest <scope> <n>`): las próximas n lecturas de ese ámbito fallan. */
    property var listFailReads: ({ user: 0, system: 0 })
    property var _listFail: ({ user: false, system: false })

    /** Mientras alguien mira, la foto se renueva sola. */
    Timer {
        interval: 5000
        repeat: true
        running: root.wanted
        onTriggered: root.refresh()
    }

    function _parseList(scope, text) {
        const out = [];
        const lines = String(text || "").split("\n");
        for (let i = 0; i < lines.length; i++) {
            const t = lines[i].trim();
            if (t.length === 0) continue;
            const f = t.split(/\s+/);
            if (f.length < 4) continue;
            const type = root.typeOf(f[0]);
            if (root.listedTypes.indexOf(type) < 0) continue;
            // referencias a unidades que no existen (not-found, inactivas): ruido, salvo si fallan
            if (f[1] === "not-found" && f[2] !== "failed") continue;
            out.push({ scope: scope, unit: f[0], type: type, load: f[1], active: f[2], sub: f[3],
                       desc: f.slice(4).join(" ") });
        }
        out.sort(function (a, b) {
            function rank(u) { return u.active === "failed" ? 0 : u.active === "active" ? 1 : 2; }
            const r = rank(a) - rank(b);
            return r !== 0 ? r : a.unit.toLowerCase().localeCompare(b.unit.toLowerCase());
        });
        return out;
    }

    function _listDone(scope, code, text, err) {
        const cur = root.listOf(scope);
        let next;
        if (code !== 0 || root._listFail[scope]) {
            const why = root._listFail[scope] ? "test failure"
                : (String(err || "").trim().split("\n")[0] || "systemctl exited " + code);
            if (code !== 0) console.warn("units: list", scope, "failed:", why);
            next = { rows: cur.rows, state: "error", error: why, at: cur.at, stale: cur.rows.length > 0 };
        } else {
            const rows = root._parseList(scope, text);
            // Sólo si cambió: reasignar lo mismo reiniciaría el ListView de la lista sin motivo.
            if (cur.state === "ready" && JSON.stringify(rows) === JSON.stringify(cur.rows)) {
                if (cur.at === 0) return;
                next = Object.assign({}, cur, { at: Date.now() });
                const l0 = Object.assign({}, root.lists); l0[scope] = next; root.lists = l0;
                return;
            }
            next = { rows: rows, state: "ready", error: "", at: Date.now(), stale: false };
        }
        const l = Object.assign({}, root.lists);
        l[scope] = next;
        root.lists = l;
        root.rev++;
        // si hay fichas abiertas de ese ámbito, refresca también sus cabeceras
        for (const k of root.watchedUnits())
            if (root.parseKey(k).scope === scope) root.loadDetail(k);
    }

    Process {
        id: listUsrProc
        command: ["systemctl", "--user", "list-units", "--type=service,timer,socket,mount,automount",
                  "--all", "--no-legend", "--plain", "--no-pager"]
        stdout: StdioCollector { id: listUsrOut }
        stderr: StdioCollector { id: listUsrErr }
        onExited: (code) => root._listDone("user", code, listUsrOut.text, listUsrErr.text)
    }
    Process {
        id: listSysProc
        command: ["systemctl", "list-units", "--type=service,timer,socket,mount,automount",
                  "--all", "--no-legend", "--plain", "--no-pager"]
        stdout: StdioCollector { id: listSysOut }
        stderr: StdioCollector { id: listSysErr }
        onExited: (code) => root._listDone("system", code, listSysOut.text, listSysErr.text)
    }

    /**
     * Fallidas **de la lista de usuario** (servicios): lo que la cabecera pintaba en rojo antes de
     * la 11F-1. Para «¿cuántas unidades han caído?» la respuesta es `failedTotal` / `failedIn()`.
     */
    readonly property int failedCount: root.units.filter(u => u.active === "failed").length
    /** Caídas de un ámbito, de la MISMA fuente que el Dashboard (`failed`). */
    function failedIn(scope) { return root.failed.filter(f => f.scope === scope); }

    // --- unidades caídas: una sola respuesta (QS-FUNC-008) -------------

    /**
     * Había TRES mecanismos para el mismo dato, y podían discrepar a la vez:
     * `Sysmon.healthProc` (un `sh -c` con dos `systemctl --failed | wc -l`),
     * los dos `systemctl --failed` propios del Dashboard, y `failedCount`, que
     * sólo cuenta servicios de usuario. Ahora los tres leen de aquí.
     *
     * Sistema Y usuario, de todos los tipos (un `.mount` o un `.timer` caídos
     * también cuentan) — lo que ya contaban `Sysmon` y el Dashboard. **Sólo
     * lectura** de las de sistema: actuar sigue siendo `--user` y nada más.
     */
    /** [{ scope: "system"|"user", unit, load, active, sub, desc }] */
    property var failed: []
    /** -1 hasta la primera lectura: «no se sabe» no es «ninguna». */
    property int failedTotal: -1
    signal failedRead()
    /**
     * 11A-2: una lectura que FALLA ya no es «cero caídas». Se conserva la última lista buena
     * (`failed`, `failedTotal`) y aquí queda el motivo; `failedAt` es la hora (ms) de la última
     * lectura buena y `failedErrorAt` la del fallo. Vacío = la última lectura fue buena.
     */
    property string failedError: ""
    property double failedAt: 0
    property double failedErrorAt: 0

    property var _failedSys: null
    property var _failedUsr: null

    function refreshFailed() {
        if (!root.supported) return;
        root._failedSys = root.systemSupported ? null : { rows: [], error: "" };
        root._failedUsr = root.userSupported ? null : { rows: [], error: "" };
        if (failedSysProc.running || failedUsrProc.running) return;
        root._failTest = root.failReads > 0;
        if (root.failReads > 0) root.failReads--;
        if (root.systemSupported && !failedSysProc.running)
            failedSysProc.running = true;
        if (root.userSupported && !failedUsrProc.running)
            failedUsrProc.running = true;
    }

    function _parseFailed(scope, text) {
        const out = [];
        const lines = String(text || "").split("\n");
        for (let i = 0; i < lines.length; i++) {
            const f = lines[i].trim().split(/\s+/);
            if (f.length < 4 || f[0].length === 0)
                continue;
            out.push({ scope: scope, unit: f[0], load: f[1], active: f[2], sub: f[3],
                       desc: f.slice(4).join(" ") });
        }
        return out;
    }

    function _joinFailed() {
        if (!root.supported) return;
        if (root._failedSys === null || root._failedUsr === null)
            return;
        const sys = root._failedSys, usr = root._failedUsr;
        root._failedSys = null;
        root._failedUsr = null;
        const err = (sys.error || "") + (sys.error && usr.error ? " · " : "") + (usr.error || "");
        if (err.length > 0) {
            // el dato viejo se queda (antiguo), nunca se convierte en cero
            root.failedError = err;
            root.failedErrorAt = Date.now();
            root.failedRead();
            return;
        }
        // pruebas (IPC `unitsFailedTest`): caídas de mentira que se SUMAN a las reales, marcadas
        const all = sys.rows.concat(usr.rows).concat(root.failedTest);
        if (JSON.stringify(all) !== JSON.stringify(root.failed))
            root.failed = all;
        root.failedTotal = all.length;
        root.failedError = "";
        root.failedAt = Date.now();
        root.failedRead();
    }
    /**
     * Pruebas (11F-1, IPC `unitsFailedTest "system:foo.timer user:bar.service"`): unidades que se
     * suman a las caídas reales para probar el enlace del Dashboard sin romper nada. [] = ninguna.
     */
    property var failedTest: []
    /** Pruebas (IPC `unitsFailTest <n>`): las próximas n lecturas fallan como si systemctl no respondiera. */
    property int failReads: 0
    property bool _failTest: false

    Process {
        id: failedSysProc
        command: ["systemctl", "--failed", "--no-legend", "--plain", "--no-pager"]
        stdout: StdioCollector { id: failedSysOut }
        stderr: StdioCollector { id: failedSysErr }
        onExited: (code) => {
            if (!root.systemSupported) return;
            const bad = code !== 0 || root._failTest;
            if (code !== 0)
                console.warn("units: systemctl --failed exited", code, failedSysErr.text.trim());
            root._failedSys = bad ? { rows: [], error: "system: " + (root._failTest ? "test failure"
                                        : (failedSysErr.text.trim().split("\n")[0] || "exit " + code)) }
                                  : { rows: root._parseFailed("system", failedSysOut.text), error: "" };
            root._joinFailed();
        }
    }

    Process {
        id: failedUsrProc
        command: ["systemctl", "--user", "--failed", "--no-legend", "--plain", "--no-pager"]
        stdout: StdioCollector { id: failedUsrOut }
        stderr: StdioCollector { id: failedUsrErr }
        onExited: (code) => {
            if (!root.userSupported) return;
            const bad = code !== 0 || root._failTest;
            if (code !== 0)
                console.warn("units: systemctl --user --failed exited", code, failedUsrErr.text.trim());
            root._failedUsr = bad ? { rows: [], error: "user: " + (root._failTest ? "test failure"
                                        : (failedUsrErr.text.trim().split("\n")[0] || "exit " + code)) }
                                  : { rows: root._parseFailed("user", failedUsrOut.text), error: "" };
            root._joinFailed();
        }
    }

    // --- validación ---------------------------------------------------
    /**
     * Nombres de unidad: letras, cifras, `@ : . _ -` y la barra invertida de los escapes de systemd
     * (`dev-disk-by\x2duuid-….mount`), con un tipo conocido. Nunca se construye una línea de shell:
     * todo va por argv (SECURITY regla 3).
     */
    readonly property var _unitRe: /^[A-Za-z0-9@:._\\-]+\.(service|timer|socket|mount|automount|path|target|device|scope|slice|swap)$/
    readonly property var _serviceRe: /^[A-Za-z0-9@:._\\-]+\.service$/

    function _valid(u) {
        if (typeof u === "string" && root._unitRe.test(u))
            return true;
        console.warn("units: refusing unit name", JSON.stringify(u));
        return false;
    }
    /** Si un texto tiene forma de nombre de unidad completo (para abrirla por nombre exacto). */
    function looksLikeUnit(u) { return typeof u === "string" && root._unitRe.test(u); }

    // --- acciones -----------------------------------------------------
    /**
     * Start / Stop / Restart de un `.service`, de usuario o (desde la 11F-2) de SISTEMA.
     *
     * SISTEMA (futuresystemd-unitssurface «Acciones recomendadas»): `systemctl <verbo> <unidad>`
     * sin `--user` pide la autorización del sistema, y la presenta el agente polkit del shell (la
     * surface `auth`); el shell nunca corre como administrador. La vista confirma ANTES (unidad
     * exacta, ámbito, efecto); aquí se vuelve a comprobar la política con la ficha más reciente.
     *
     * POLÍTICA (`policy()`): lo que systemd rechazaría se desactiva con su motivo (CanStart/CanStop,
     * RefuseManualStart/Stop), y los servicios ESENCIALES de la sesión no se paran ni reinician desde
     * aquí (`protectedNames`, por nombre y alias reales —`display-manager.service` es sddm,
     * `dbus.service` es dbus-broker—, nunca por parecido). Los que pueden cortar la red se confirman
     * avisándolo.
     *
     * VERIFICACIÓN: `systemctl` que sale con 0 sólo dice «aceptado». El resultado se da después de
     * releer la unidad (0,5 y 2 s): `verified`, y la vista lo cuenta con el estado leído. Una
     * autorización cancelada o denegada es `denied` y no cambia nada.
     */
    property string lastVerb: ""
    property string lastUnit: ""
    property string lastKey: ""
    property string lastScope: "user"
    property string lastResult: ""      // "" | "ok" | "denied" | "exit N"
    property string lastError: ""
    property bool lastVerified: false
    property bool busy: false
    /** Pruebas (IPC `unitsActTestCommand`): argv que sustituye a `systemctl` en las de SISTEMA. */
    property var actTestCommand: []
    signal actionFinished(string key, string screen)
    property string _actScreen: ""

    readonly property var protectedNames: ["sddm.service", "display-manager.service",
        "systemd-logind.service", "dbus-broker.service", "dbus.service", "polkit.service",
        "systemd-journald.service", "systemd-udevd.service"]
    readonly property var networkNames: ["NetworkManager.service", "systemd-resolved.service",
        "systemd-networkd.service", "wpa_supplicant.service", "iwd.service"]

    /**
     * Qué se puede hacer con una unidad, y por qué no:
     *   { start, stop, restart: { ok, reason, label, verb }, confirm, warn, protected }
     * `confirm`: pide confirmación (todas las de sistema); `warn`: el aviso de la confirmación.
     */
    /** «Sun 2026-09-27 12:03:02 CST» → ms (hora local; la zona la ignora). 0 si no se entiende. */
    function _tsMs(t) {
        const m = /(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})/.exec(String(t || ""));
        return m ? new Date(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6]).getTime() : 0;
    }
    /** Cuándo se lanzó la última acción (ms), para saber si lo que se lee es de después. */
    property double lastActAt: 0

    function policy(k) {
        const p = root.parseKey(k);
        if (!root.scopeSupported(p.scope)) {
            const no = { ok: false, reason: "Systemd services are unavailable in this session" };
            return { start: no, stop: no, restart: no, confirm: false, warn: "", protected: false };
        }
        const info = root.infoFor(k);
        const lrow = root.listRow(k);
        const active = info.active || (lrow ? lrow.active : "");
        const names = [p.unit].concat(info.names || []);
        const isService = root._serviceRe.test(p.unit);
        const system = p.scope === "system";
        const prot = system && names.some(n => root.protectedNames.indexOf(n) >= 0
            || /^user(?:-runtime-dir)?@\d+\.service$/.test(n));
        const net = system && names.some(n => root.networkNames.indexOf(n) >= 0);
        const known = info.load !== undefined && !info.error;
        const no = function (why) { return { ok: false, reason: why }; };
        const out = { confirm: system, protected: prot, warn: "" };
        if (!isService) {
            out.start = no("Only services"); out.stop = no("Only services"); out.restart = no("Only services");
            return out;
        }
        if (!known) {
            out.start = no("Reading the unit…"); out.stop = no("Reading the unit…"); out.restart = no("Reading the unit…");
            return out;
        }
        if (info.notFound) {
            out.start = no("Unit not found"); out.stop = no("Unit not found"); out.restart = no("Unit not found");
            return out;
        }
        const failed = active === "failed";
        const running = active === "active" || active === "activating" || active === "reloading";
        // Start (o Retry start en una caída)
        out.start = failed || !running
            ? (info.refuseStart ? no("systemd refuses manual start for this unit")
               : !info.canStart ? no("systemd cannot start this unit")
               : { ok: true, reason: "" })
            : no("Already running");
        out.start.label = failed ? "Retry start" : "Start";
        out.start.verb = "start";
        out.stop = !running ? no("Not running")
            : prot ? no("Protected: stopping it would break the session")
            : info.refuseStop ? no("systemd refuses manual stop for this unit")
            : !info.canStop ? no("systemd cannot stop this unit")
            : { ok: true, reason: "" };
        out.stop.label = "Stop";
        out.stop.verb = "stop";
        out.restart = !running ? no(failed ? "Failed: use Retry start" : "Not running")
            : prot ? no("Protected: restarting it would break the session")
            : info.refuseStop || info.refuseStart ? no("systemd refuses manual restart for this unit")
            : !info.canStop || !info.canStart ? no("systemd cannot restart this unit")
            : { ok: true, reason: "" };
        out.restart.label = "Restart";
        out.restart.verb = "restart";
        if (net) out.warn = "It may cut network connectivity until it is running again.";
        return out;
    }

    /**
     * Ejecuta una acción YA confirmada por la vista. `screen`: la pantalla que la pidió (la ficha
     * vuelve allí al terminar la autorización). false si la política no lo permite.
     */
    function act(verb, k, screen) {
        if (["start", "stop", "restart"].indexOf(verb) < 0)
            return false;
        const p = root.parseKey(k);
        if (!root.scopeSupported(p.scope)) return false;
        if (!root._serviceRe.test(p.unit)) {
            console.warn("units: refusing action", verb, "on", JSON.stringify(k));
            return false;
        }
        const key = root.key(p.scope, p.unit);
        // la política, con la ficha más reciente (la vista confirmó sobre la que tenía)
        const pol = root.policy(key)[verb];
        if (p.scope === "system" && (!pol || !pol.ok)) {
            console.warn("units: policy refuses", verb, key, pol ? pol.reason : "");
            return false;
        }
        if (actProc.running)
            return false;
        root.lastVerb = verb;
        root.lastUnit = p.unit;
        root.lastKey = key;
        root.lastScope = p.scope;
        root.lastResult = "";
        root.lastError = "";
        root.lastVerified = false;
        root.lastRanLines = 0;
        root.lastActAt = Date.now();
        root._actScreen = screen || "";
        root.busy = true;
        actProc.command = p.scope === "system" && root.actTestCommand.length > 0
            ? root.actTestCommand.concat([verb, p.unit])
            : ["systemctl"].concat(root.scopeArgs(p.scope), [verb, p.unit]);
        actProc.running = true;
        return true;
    }

    Process {
        id: actProc
        stderr: StdioCollector { id: actErr }
        onExited: function (code) {
            root.busy = false;
            const err = actErr.text.trim().split("\n").filter(l => l.length > 0)[0] || "";
            root.lastError = err;
            // polkit cancelado o denegado: «Access denied», «Interactive authentication required»…
            root.lastResult = code === 0 ? "ok"
                : /access denied|authentication|not authorized|permission denied/i.test(actErr.text) ? "denied"
                : "exit " + code;
            root.refresh();
            root.loadDetail(root.lastKey);
            settleShort.restart();
            settleLong.restart();
            actReturn.restart();
        }
    }
    // Tras la autorización (o su cancelación) la surface `auth` se cierra; la ficha vuelve si no se
    // abrió otra cosa en esa pantalla (shell.qml escucha `actionFinished`).
    Timer { id: actReturn; interval: 600; onTriggered: root.actionFinished(root.lastKey, root._actScreen) }

    /** Relecturas tras una acción: la unidad aún está arrancando cuando `systemctl` vuelve. */
    Timer { id: settleShort; interval: 500;  onTriggered: { root.refresh(); root.loadDetail(root.lastKey); } }
    Timer {
        id: settleLong
        interval: 2000
        onTriggered: { root.refresh(); root.loadDetail(root.lastKey); verifyDone.restart(); }
    }
    // la segunda relectura ya volvió: se mira además si la unidad escribió en el journal DESPUÉS de la
    // acción (un servicio de un solo disparo que corrió bien acaba inactivo, y el gestor puede haberlo
    // descargado sin marcas de tiempo: su journal es la prueba de que corrió)
    Timer {
        id: verifyDone
        interval: 400
        onTriggered: {
            if (root.lastResult !== "ok") return;
            const p = root.parseKey(root.lastKey);
            ranProc.command = ["journalctl"].concat(root.scopeArgs(p.scope), ["-u", p.unit, "--since",
                "@" + Math.floor(root.lastActAt / 1000 - 1), "-q", "--no-pager", "-o", "cat"]);
            ranProc.running = true;
        }
    }
    /** Líneas que la unidad escribió desde la acción (la prueba de que corrió). */
    property int lastRanLines: 0
    Process {
        id: ranProc
        stdout: StdioCollector { id: ranOut }
        onExited: (code) => {
            root.lastRanLines = code === 0 ? ranOut.text.split("\n").filter(l => l.trim().length > 0).length : 0;
            root.lastVerified = true;
        }
    }

    // --- ficha de una unidad ----------------------------------------
    /**
     * **Una caché por CLAVE (ámbito + unidad)**, no una ficha «actual» (2026-09-22; ámbito desde la
     * 11F-1). Cada pantalla mira la suya (`core/SurfaceHost` §`sel`); `show` es un proceso y lo que
     * se encola son las claves pendientes, sin repetir.
     */
    property var infoByUnit: ({})
    property bool detailBusy: false
    property string _showKey: ""
    property var _showQueue: []

    /**
     * { description, load, active, sub, fileState, since, result, notFound, … } o `{}` si aún no
     * volvió. Por tipo: `nextRun`, `lastRun`, `triggers` (timer); `listen`, `triggers` (socket);
     * `what`, `where` (mount/automount); `triggeredBy`; `canStart`, `canStop`, `refuseStart`,
     * `refuseStop` (para las acciones de la 11F-2).
     */
    function infoFor(k) {
        const v = root.infoByUnit[root.normKey(k)];
        return v === undefined ? ({}) : v;
    }
    /** La clave canónica (con prefijo) de lo que llegue: "foo.service" → "user:foo.service". */
    function normKey(k) { const p = root.parseKey(k); return root.key(p.scope, p.unit); }

    /** Claves con ficha viva: las que hay que refrescar tras un cambio. */
    function watchedUnits() {
        const out = [];
        for (const u in root.infoByUnit)
            out.push(u);
        return out;
    }

    readonly property string _showProps: "Id,Description,LoadState,ActiveState,SubState,UnitFileState,"
        + "ActiveEnterTimestamp,Result,CanStart,CanStop,RefuseManualStart,RefuseManualStop,"
        + "NextElapseUSecRealtime,LastTriggerUSec,Unit,Triggers,TriggeredBy,Listen,What,Where,Names,ExecMainStartTimestamp"

    function loadDetail(k) {
        const p = root.parseKey(k);
        if (!root.scopeSupported(p.scope)) return false;
        if (!root._valid(p.unit))
            return false;
        const nk = root.key(p.scope, p.unit);
        if (showProc.running) {
            if (nk !== root._showKey && root._showQueue.indexOf(nk) < 0)
                root._showQueue = root._showQueue.concat([nk]);
            return true;
        }
        root.detailBusy = true;
        root._showKey = nk;
        showProc.command = ["systemctl"].concat(root.scopeArgs(p.scope),
            ["show", p.unit, "--property=" + root._showProps]);
        showProc.running = true;
        return true;
    }

    /** Una ficha se cierra: su entrada deja de refrescarse. */
    function dropDetail(k) {
        const nk = root.normKey(k);
        if (root.infoByUnit[nk] === undefined)
            return;
        const next = ({});
        for (const u in root.infoByUnit)
            if (u !== nk)
                next[u] = root.infoByUnit[u];
        root.infoByUnit = next;
    }

    Process {
        id: showProc
        stdout: StdioCollector { id: showOut }
        stderr: StdioCollector { id: showErr }
        onExited: function (code) {
            root.detailBusy = false;
            var kv = ({});
            var lines = showOut.text.split("\n");
            for (var i = 0; i < lines.length; i++) {
                var eq = lines[i].indexOf("=");
                if (eq > 0)
                    kv[lines[i].slice(0, eq)] = lines[i].slice(eq + 1);
            }
            const clean = function (v) { return v === undefined || v === "n/a" || v === "[not set]" ? "" : v; };
            const info = code !== 0 ? { error: showErr.text.trim().split("\n")[0] || "systemctl show exited " + code } : {
                description: kv["Description"] || "",
                load: kv["LoadState"] || "",
                active: kv["ActiveState"] || "",
                sub: kv["SubState"] || "",
                fileState: kv["UnitFileState"] || "",
                result: kv["Result"] || "",
                since: kv["ActiveEnterTimestamp"] || "",
                notFound: kv["LoadState"] === "not-found",
                canStart: kv["CanStart"] === "yes",
                canStop: kv["CanStop"] === "yes",
                refuseStart: kv["RefuseManualStart"] === "yes",
                refuseStop: kv["RefuseManualStop"] === "yes",
                nextRun: clean(kv["NextElapseUSecRealtime"]),
                lastRun: clean(kv["LastTriggerUSec"]),
                // un timer activa `Unit`; un socket, lo de `Triggers`
                triggers: clean(kv["Unit"]) || clean(kv["Triggers"]),
                triggeredBy: clean(kv["TriggeredBy"]),
                listen: clean(kv["Listen"]),
                what: clean(kv["What"]),
                where: clean(kv["Where"]),
                names: String(kv["Names"] || "").split(/\s+/).filter(n => n.length > 0),
                // cuándo arrancó su proceso por última vez (ms; 0 = nunca / no se sabe)
                execStartMs: root._tsMs(clean(kv["ExecMainStartTimestamp"]))
            };
            // Igual que la lista: sin cambio no hay señal (la ficha re-enfoca con ella).
            const k = root._showKey;
            if (k.length > 0 && JSON.stringify(info) !== JSON.stringify(root.infoByUnit[k])) {
                const next = ({});
                for (const u in root.infoByUnit)
                    next[u] = root.infoByUnit[u];
                next[k] = info;
                root.infoByUnit = next;
            }
            root._showKey = "";
            if (root._showQueue.length > 0) {
                const q = root._showQueue.slice();
                const nextKey = q.shift();
                root._showQueue = q;
                root.loadDetail(nextKey);
            }
        }
    }

    /** Datos de la unidad en la lista, para cuando `show` aún no volvió. */
    function listRow(k) {
        const p = root.parseKey(k);
        const rows = root.listOf(p.scope).rows;
        for (var i = 0; i < rows.length; i++)
            if (rows[i].unit === p.unit)
                return rows[i];
        return null;
    }

    // --- journal: en vivo, con tope ----------------------------------

    /**
     * `journalctl [--user] -u <unidad> -f -n 200` mientras la ficha o el journal lo reclaman (decisión
     * del usuario del 2026-09-14): arranca con las últimas 200 y nunca guarda más de `journalCap`.
     * UNO para todo el shell; lo posee quien lo abrió el último, por CLAVE (ámbito + unidad).
     *
     * LAS LÍNEAS SE VUELCAN POR LOTES (BUG-10a-1): se apilan en `_jPending` y un timer de 50 ms las
     * vuelca en una sola reasignación. La reclamación se suelta con 2 s de margen (el salto
     * ficha → journal no reinicia el proceso).
     *
     * PERMISOS (11F-1): sin acceso al journal del sistema, journalctl no da error: avisa («not seeing
     * messages from other users and the system», «insufficient permissions») y no enseña nada. Eso
     * es `journalPermission`, y la vista dice «Permission required», nunca «No entries». Esas líneas
     * de aviso no entran como entradas.
     */
    readonly property int journalCap: 400
    signal journalAppended(var lines, int dropped)
    signal journalReset()
    property string journalUnit: ""
    property string journalScope: "user"
    readonly property string journalKey: root.journalUnit.length > 0 ? root.key(root.journalScope, root.journalUnit) : ""
    property var journalLines: []
    property bool journalBusy: false
    property bool journalPermission: false
    readonly property bool journalFollowing: jProc.running
    /** Pruebas (IPC `journalTestCommand`): argv que sustituye a journalctl; "" = el real. */
    property var journalTestCommand: []

    property var journalClaims: ({})
    readonly property bool journalWanted: root.scopeSupported(root.journalScope)
        && Object.keys(root.journalClaims).length > 0

    property var _jPending: []
    property bool _jRestart: false
    property int jRestarts: 0

    function claimJournal(who, on) {
        if (on === !!root.journalClaims[who]) return;
        const c = Object.assign({}, root.journalClaims);
        if (on) c[who] = true; else delete c[who];
        root.journalClaims = c;
        if (root.journalWanted) {
            jStopGrace.stop();
            root._syncJournal();
        } else {
            jStopGrace.restart();
        }
    }

    /** Elige la unidad a seguir (por clave). El proceso vive mientras haya reclamaciones. */
    function loadJournal(k) {
        const p = root.parseKey(k);
        if (!root.scopeSupported(p.scope)) return false;
        if (!root._valid(p.unit))
            return false;
        if (root.key(p.scope, p.unit) === root.journalKey && (jProc.running || root._jRestart))
            return true;   // ya la está siguiendo: no se relee
        root.journalUnit = p.unit;
        root.journalScope = p.scope;
        root.jRestarts = 0;
        root.journalLines = [];
        root._jPending = [];
        root.journalPermission = false;
        root.journalReset();
        if (jProc.running) {
            // Otra unidad: se para y `onExited` arranca la nueva (arrancar encima confundiría el
            // `onExited` del viejo con una caída del nuevo).
            root._jRestart = true;
            jProc.running = false;
        } else {
            root._syncJournal();
        }
        return true;
    }

    function closeJournal() {
        root.journalUnit = "";
        root.journalLines = [];
        root._jPending = [];
        root.journalReset();
        root.journalBusy = false;
        root.journalPermission = false;
        root._jRestart = false;
        jRespawn.stop();
        jProc.running = false;
    }

    function _syncJournal() {
        if (root.journalWanted && root.journalUnit.length > 0 && !jProc.running && !root._jRestart)
            root._startJournal();
    }

    function _startJournal() {
        if (!root.scopeSupported(root.journalScope)) return;
        root.journalLines = [];
        root._jPending = [];
        root.journalPermission = false;
        root.journalReset();
        root.journalBusy = true;
        const real = ["journalctl"].concat(root.scopeArgs(root.journalScope),
            ["-u", root.journalUnit, "-f", "-n", "200", "--no-pager", "-o", "short-iso"]);
        jProc.command = root.journalTestCommand.length > 0
            ? root.journalTestCommand.concat([root.journalScope, root.journalUnit]) : real;
        jProc.running = true;
        jSettle.restart();
    }

    readonly property var _jPermRe: /not seeing messages from other users|insufficient permissions|No journal files were (opened|found)/i
    function _jLine(l) {
        if (l.length === 0)
            return;
        if (root._jPermRe.test(l)) { root.journalPermission = true; return; }
        // los avisos de journalctl a quién puede leer, y el marcador de vacío, no son entradas
        const t = l.trim();
        if (/^Hint: /.test(t) || /^Users in groups/.test(t) || /^Pass -q to turn off/.test(t)
                || /^-- No entries --$/.test(t)) return;
        root._jPending.push(l);
        if (!jFlush.running)
            jFlush.start();
    }

    function flushJournal() {
        if (root._jPending.length === 0)
            return;
        const added = root._jPending;
        const all = root.journalLines.concat(added);
        const dropped = Math.max(0, all.length - root.journalCap);
        root._jPending = [];
        root.journalLines = dropped > 0 ? all.slice(dropped) : all;
        root.journalBusy = false;
        root.journalAppended(added, dropped);
    }

    /** Las últimas `n` líneas, para la vista previa de la ficha. */
    function journalTail(n) {
        var l = root.journalLines;
        return l.length > n ? l.slice(l.length - n) : l;
    }

    Process {
        id: jProc
        stdout: SplitParser { onRead: (l) => root._jLine(l) }
        stderr: SplitParser { onRead: (l) => root._jLine(l) }
        onStarted: jStable.restart()
        onExited: function (code) {
            jStable.stop();
            root.flushJournal();
            root.journalBusy = false;
            if (root._jRestart) {
                root._jRestart = false;
                root._syncJournal();
                return;
            }
            // Parado a propósito: nadie lo reclama o se cerró la unidad.
            if (!root.journalWanted || root.journalUnit.length === 0)
                return;
            // Sin permiso no hay nada que reintentar: lo dirá la vista.
            if (root.journalPermission)
                return;
            // Murió solo. Mismo freno que Session (QS-FUNC-002).
            if (root.jRestarts >= 5) {
                console.warn("units: journalctl -f keeps dying, giving up on", root.journalKey);
                return;
            }
            root.jRestarts++;
            jRespawn.restart();
        }
    }

    Timer { id: jFlush; interval: 50; onTriggered: root.flushJournal() }
    /** Un journal vacío no manda nada: sin esto se quedaría en «reading…». */
    Timer { id: jSettle; interval: 1500; onTriggered: root.journalBusy = false }
    Timer { id: jStable; interval: 10000; onTriggered: root.jRestarts = 0 }
    Timer { id: jRespawn; interval: 2000; onTriggered: root._syncJournal() }
    Timer {
        id: jStopGrace
        interval: 2000
        onTriggered: if (!root.journalWanted) jProc.running = false
    }

    function summary() {
        const lsum = function (sc) {
            const l = root.listOf(sc);
            return { state: l.state, error: l.error, stale: l.stale, count: l.rows.length,
                     failed: l.rows.filter(r => r.active === "failed").length };
        };
        return {
            supported: root.supported,
            ready: root.ready,
            count: root.units.length,
            failed: root.failedCount,
            failedTotal: root.failedTotal,
            failedError: root.failedError, failedAt: root.failedAt,
            failedUnits: root.failed.map(function (f) { return f.scope + ":" + f.unit; }),
            lists: { user: lsum("user"), system: lsum("system") },
            scopesRead: root.wantedScopes,
            watched: root.watchedUnits(),
            detailBusy: root.detailBusy,
            claims: root.claims,
            journal: {
                key: root.journalKey, following: root.journalFollowing, permission: root.journalPermission,
                lines: root.journalLines.length, claims: Object.keys(root.journalClaims),
                restarts: root.jRestarts, testing: root.journalTestCommand.length > 0
            },
            action: { verb: root.lastVerb, key: root.lastKey, result: root.lastResult, error: root.lastError,
                      verified: root.lastVerified, ranLines: root.lastRanLines, busy: root.busy, testing: root.actTestCommand.length > 0 },
            units: root.units.map(function (u) {
                return { unit: u.unit, active: u.active, sub: u.sub };
            })
        };
    }
}
