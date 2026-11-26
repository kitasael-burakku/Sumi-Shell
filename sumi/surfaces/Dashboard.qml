import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "../theme"
import "../services"
import "../components"
import "../lib/accent-zones.js" as Zones

/**
 * Dashboard — centro de control del sistema (Fase 10.a).
 *
 * Sustituye a la superficie `status` (y a su atajo, que pasa a `SUPER+CTRL+D`):
 * absorbe sus 10 pares de diagnóstico, ahora detrás de un pliegue. Añade el
 * panorama de estado que no vive en ninguna otra superficie —actualizaciones,
 * unidades caídas, último backup— y las acciones que 9.d dejó fuera de
 * `rofi/scripts/dashboard.sh`: actualizar, ver servicios caídos, `dotbackup`,
 * `diskbackup` y limpieza.
 *
 * NO reproduce lo que ya tienen otras superficies (sensores → `system`, red →
 * `wifi`, audio → `mixer`): decisión del usuario, 2026-09-09.
 *
 * Estado de las acciones (2026-09-09):
 *  - `diskbackup` corre EN EL PANEL: sus dos lecturas (la confirmación inicial
 *    de 2026-09-21 y la pausa final) están tras `isatty stdin`, así que con la
 *    tubería no pregunta nada — un `read` aquí colgaría el panel, que lo lanza
 *    con `StdioCollector` y sin stdin. Por eso la confirmación del panel la
 *    hace ESTA superficie (`askAction`) antes de arrancarlo. La salida se
 *    captura y su ANSI (`set_color` truecolor) se traduce a tokens del tema
 *    (lib/ansi.js).
 *  - Fase 6B (2026-09-25): dotbackup y diskbackup corren en `services/Jobs`,
 *    no aquí. Cerrar el panel ya no los mata; al reabrir, la consola vuelve a
 *    ellos. Esta superficie pide la confirmación y la passphrase, y mira.
 *  - `dotbackup` corre EN EL PANEL con su diálogo completo (SPIKE-DOTBACKUP.md):
 *    `Process { stdinEnabled }` + `SplitParser` leen la salida línea a línea,
 *    una máquina de estados detecta cada prompt por patrón y se responde con
 *    `Process.write()`. `edit_readme` se contesta SIEMPRE `n` (un `y` lanza
 *    `nvim`, que no cabe en el panel — renuncia anotada). `commit_msg` es un
 *    campo; `confirm_start` (2026-09-21), `show_diff`, `confirm_commit` y
 *    `confirm_push`, botones y/n.
 *  - «Downed services» lista las unidades caídas en el panel, sólo lectura.
 *  - «Upgrade system» abre terminal (`Updates.update()`): es pacman + sudo +
 *    ~692 líneas, no cabe en un panel. Mismo on-click que el aviso de updates.
 *  - `clean` abre terminal: `quickcache` usa `_rui_confirm`, que hace
 *    `read --prompt-str` — y fish NO imprime ese prompt cuando stdin es una
 *    tubería (medido: sale vacío), así que el panel se quedaría bloqueado sin
 *    prompt visible. `--deep` además pide `sudo`. Mismo motivo por el que
 *    «Upgrade system» abre terminal (`sysupdate` también usa `_rui_confirm`).
 *
 * Rediseño 11A-1 (2026-09-27, futureDashboardsurface): tres pestañas arriba —Overview,
 * Performance, Tasks— en un panel de tamaño fijo (familia Consulta, DESIGN §5), así que
 * cambiar de pestaña no deforma el panel. Por ahora es una MUDANZA de lo que ya había:
 *  - Overview: estado, health/doctor, mantenimiento, unidades caídas y diagnósticos;
 *  - Performance: los modos (motor Modes y tarjetas 2×2 desde la 11D) y el perfil de
 *    energía, con el acceso a System Monitor; no muestrea nada;
 *  - Tasks: la consola de dotbackup/diskbackup (pregunta, passphrase, salida) y las descargas.
 * Etapa B (2026-11-09, docs/SUMI-DASHBOARD-B-2026-11-09.md): la pestaña Tasks —la consola, el diálogo de
 * dotbackup, la passphrase, la confirmación de diskbackup, los informes, los trabajos y las descargas— se mudó a la
 * ventana flotante `core/TasksLayer` (nombre `tasks`). Lo de arriba sobre la consola describe ahora esa capa; aquí
 * quedan Overview y Performance, y lo que lanzaba la pestaña abre la capa (`openTasks`).
 * Las tres existen siempre (cambiar de pestaña no recrea nada); lo que CUESTA sólo corre con su
 * pestaña a la vista: la reclamación de `Units` y la relectura de salud son de Overview.
 * La pestaña inicial la da el nombre con que se abre (`dashboard` → Overview; `performance`,
 * `tasks`: Screens.dashboardTabs); Back/Forward la devuelven con `saveContext`.
 */
Surface {
    id: root

    // 11A-1: tamaño fijo (Metrics.dashboardW/H); el contenido de cada pestaña hace scroll

    // --- pestañas (11A-1) ---------------------------------------------------
    readonly property var tabs: [
        { id: "overview", label: "Overview", glyph: "info" },
        { id: "performance", label: "Performance", glyph: "gauge" }
    ]
    property string tab: "overview"
    readonly property int tabIndex: Math.max(0, root.tabs.findIndex(t => t.id === root.tab))
    /** La sección de entrada de cada pestaña. */
    function firstSection(t) {
        if (t === "performance") return "mode";
        return root.issueRows.length > 0 ? "issues" : "actions";
    }
    /**
     * Cambiar de pestaña: la vista, nada más (no lanza ni cancela). Lo usan el clic, el teclado,
     * el IPC y `Screen.openSurface` cuando el Dashboard ya está abierto.
     */
    function showTab(t, keepSection) {
        if (root.tabs.findIndex(x => x.id === t) < 0) return false;
        const dir = root.tabs.findIndex(x => x.id === t) - root.tabIndex;
        if (t !== root.tab) {
            root.tab = t;
            root.playEnter(dir >= 0 ? 1 : -1);
        }
        if (keepSection !== true) root.section = root.firstSection(t);
        return true;
    }
    function stepTab(d) {
        const n = root.tabs.length;
        root.showTab(root.tabs[(root.tabIndex + d + n) % n].id, false);
    }
    /** Back/Forward (DESIGN §3): pestaña, sección, pliegue y scroll de cada pestaña. */
    function saveContext() {
        return { tab: root.tab, section: root.section, more: root.moreOpen,
                 downed: root.downedWatch, downSel: root.downSel,
                 modeSelected: performance.selected, modeAction: performance.action,
                 y: { overview: ovFlick.contentY, performance: pfFlick.contentY } };
    }
    function restoreContext(ctx) {
        if (!ctx || !ctx.tab) return true;
        root.moreOpen = ctx.more === true;
        // 11F-1: volver de la ficha de una unidad devuelve la lista de caídas y la fila de la que se salió
        root.downedWatch = ctx.downed === true;
        root.downSel = Math.max(0, Math.min(ctx.downSel || 0, root.downedRows.length - 1));
        root.showTab(ctx.tab, false);
        if (typeof ctx.section === "string" && ctx.section !== "jobs"
                && !(ctx.section === "downed" && !(root.downedWatch && root.downedRows.length > 0)))
            root.section = ctx.section;
        if (Number.isInteger(ctx.modeSelected)) performance.selected = Math.max(0, Math.min(3, ctx.modeSelected));
        if (Number.isInteger(ctx.modeAction)) performance.action = Math.max(0, Math.min(performance.actions.length - 1, ctx.modeAction));
        const y = ctx.y || {};
        Qt.callLater(() => {
            ovFlick.contentY = Math.max(0, Math.min(y.overview || 0, ovFlick.contentHeight - ovFlick.height));
            pfFlick.contentY = Math.max(0, Math.min(y.performance || 0, pfFlick.contentHeight - pfFlick.height));
        });
        return true;
    }

    // entrada de la pestaña: deslizamiento corto y fundido (ANIMATIONS «cambio de vista interna»)
    property real slideX: 0
    property real paneOpacity: 1
    function playEnter(dir) {
        const interrupted = enterAnim.running;
        enterAnim.stop();
        root.slideX = Motion.still ? 0 : interrupted
            ? Math.max(-8 * root.s, Math.min(8 * root.s, root.slideX)) : dir * 8 * root.s;
        root.paneOpacity = Motion.off ? 1 : interrupted ? Math.max(0.65, root.paneOpacity) : 0.65;
        enterAnim.start();
    }
    Connections {
        target: Motion
        function onModeChanged() {
            enterAnim.stop(); root.slideX = 0; root.paneOpacity = 1;
        }
    }
    ParallelAnimation {
        id: enterAnim
        NumberAnimation {
            target: root; property: "slideX"; to: 0
            duration: Motion.still ? 0 : Motion.page
            easing.type: Easing.OutCubic
        }
        NumberAnimation {
            target: root; property: "paneOpacity"; to: 1
            duration: Motion.page
            easing.type: Easing.OutCubic
        }
    }

    /**
     * Sección con el foco de teclado (10.f). Arriba/abajo cruza entre secciones
     * cuando el grupo interno llega a su borde; izquierda/derecha se mueve
     * dentro. Antes sólo la columna de acciones era navegable y ←/→ abría el
     * pliegue (ahora es la tecla D).
     *   "tabs"    (11A-1) la barra de pestañas: ←→ cambian, ↓ / ⏎ entran
     *   Overview:    (11A-2) "issues" los asuntos y «N more»; "actions" el mantenimiento;
     *                "activity" la actividad reciente; "diag" el pliegue y health/doctor
     *   Performance: "mode" el perfil de escritorio; "profile" la energía; "monitor" el acceso
     *   Tasks:       "jobs" la consola mientras pregunta (y/n, texto, passphrase);
     *                (11B) "search" el buscador y el catálogo (↑↓ eligen, ⏎ ejecuta, Tab / ↓ al
     *                final → seguimiento); "tracked" los trabajos en seguimiento: ↑↓, ⏎ su acción
     */
    property string section: "actions"

    // --- Overview (11A-2): asuntos, actividad y diagnósticos -------------------
    /** Asuntos y lo que no se pudo comprobar, en ese orden (services/Issues). */
    readonly property var issueRows: Issues.issues.concat(Issues.problems)
    property bool moreOpen: false
    readonly property var issueRowsShown: root.moreOpen ? root.issueRows : root.issueRows.slice(0, 3)
    /** Filas navegables: las visibles y, si hay más de tres, «N more». */
    readonly property int issueCount: root.issueRowsShown.length + (root.issueRows.length > 3 ? 1 : 0)
    property int issueSel: 0
    onIssueCountChanged: {
        if (root.issueSel >= root.issueCount) root.issueSel = Math.max(0, root.issueCount - 1);
        if (root.issueCount === 0 && root.section === "issues") root.section = "actions";
    }
    /** Alto reservado del resumen: cabecera + tres asuntos (+ «N more» sólo si existe; antes, un hueco). */
    readonly property real summaryH: (24 + 2 + 3 * 30 + (root.issueRows.length > 3 ? 22 : 0)) * root.s
    readonly property string headlineText: {
        const n = Issues.issues.length;
        switch (Issues.headline) {
        case "issues": return n + (n === 1 ? " issue to look at" : " issues to look at")
                              + (Issues.problems.length > 0 ? " · could not check everything" : "");
        case "problems": return "Could not check everything";
        case "loading": return "Checking…";
        default: return "All clear";
        }
    }
    /** All clear: lo que SÍ se comprobó; lo que sólo informa (backups sin frecuencia) se dice aparte. */
    readonly property string clearText: {
        // F3d-1: las fuentes de tareas se nombran por su id, y una «copia» es una tarea con lastRun (antes,
        // una tabla fija y «el nombre contiene backup»: con otras tareas rompía). Para el autor, igual.
        const names = { units: "services", updates: "updates" };
        const name = id => names[id] || id;
        const backups = Issues.backupTasks.map(t => t.id);
        const ok = Issues.sources.filter(x => x.state === "ok").map(x => name(x.id));
        const infoX = Issues.sources.filter(x => x.state === "info");
        const list = ok.length > 1 ? ok.slice(0, -1).join(", ") + " and " + ok[ok.length - 1] : ok.join("");
        let t = list.length > 0 ? "Nothing to look at in " + list + "." : "";
        const infoB = infoX.filter(x => backups.indexOf(x.id) >= 0).map(x => name(x.id));
        const infoC = infoX.filter(x => backups.indexOf(x.id) < 0).map(x => name(x.id));
        if (infoB.length > 0) t += " Backup age is only shown: no expected frequency is set.";
        if (infoC.length > 0) t += " " + infoC.join(" and ") + (infoC.length > 1 ? " have" : " has") + " not run yet.";
        return t.trim();
    }
    function issueDetail(x) {
        const bits = [];
        if (x.detail) bits.push(x.detail);
        if (x.state === "error" || x.state === "unchecked") {
            if (x.at > 0) bits.push("data from " + root.whenOf(x.at));
        } else if (x.at > 0 && x.dataAt === undefined) {
            bits.push("checked " + root.clockOf(x.at));
        }
        return bits.join(" · ");
    }
    function issueActivate(i) {
        if (i === root.issueRowsShown.length) {
            root.moreOpen = !root.moreOpen;
            root.issueSel = root.issueRowsShown.length;   // el foco sigue en «N more / Show fewer»
            return;
        }
        const x = root.issueRowsShown[i];
        if (!x) return;
        switch (x.action) {
        case "retry": Issues.retry(x.id); break;
        case "update": if (root.upgradeTask) root.runAction(root.upgradeTask.id); break;
        // 11F-1: con UNA caída, directo a su ficha; con varias, la lista (navegable) para elegir
        // etapa A: «Failed services» ya no está en Maintenance; el asunto abre y también cierra la lista
        case "units":
            if (root.downedWatch) root.downedWatch = false;
            else if (Units.failed.length === 1) root.openUnit(Units.failed[0]);
            else root.runDowned();
            break;
        // F3d-2: «run-<id>» (las tareas con resumen) y «<id>» (las copias), de cualquier tarea
        default:
            if (x.action.indexOf("run-") === 0) root.runCheck(x.action.slice(4));
            else if (Tasks.has(x.action)) root.runAction(x.action);
        }
    }

    /**
     * Etapa C (2026-11-10): la actividad es UNA línea —lo último que corrió y cuántos trabajos siguen vivos— con el
     * acceso a la ventana Tasks, donde está el historial completo de cada tarea («Recent runs»).
     */
    readonly property var lastActivity: Activity.entries.length > 0 ? Activity.entries[0] : null
    readonly property int liveJobs: Jobs.runners.filter(r => r.busy || r.state === "needs-input").length
    /** Sólo el ÚLTIMO trabajo de cada tipo conserva su salida (la de Jobs): ése tiene «Output». */
    function activityHasOutput(e) {
        const r = Jobs.runner(e.kind);
        return !!r && e.jobId.length > 0 && e.jobId === r.jobId;
    }
    /** La línea de actividad: la ventana Tasks, en lo último que corrió si aún tiene su salida. */
    function activityActivate() {
        const e = root.lastActivity;
        root.openTasks(e && root.activityHasOutput(e) ? e.kind : "", false);
    }
    /**
     * Etapa B (2026-11-09): la capa Tasks en esta pantalla, con la tarea `id` elegida y, con `start`, arrancada
     * (su confirmación, su diálogo o su passphrase, allí). Este panel se cierra después: la ventana pide el
     * teclado cuando el island lo suelta (TasksLayer, `waitIsland`). Desde surfaces/ no se ve `Screens`.
     */
    function openTasks(id, start) {
        if (!TasksUi.show(root.screenName, id, start === true)) return false;
        root.requestClose();
        return true;
    }
    function resultWord(r) {
        return ({ succeeded: "Completed", failed: "Failed", cancelled: "Cancelled",
                  unknown: "Result unknown", opened: "Opened in terminal" })[r] || r;
    }
    function resultGlyph(r) {
        return r === "succeeded" ? "check" : r === "failed" ? "alert" : r === "opened" ? "terminal"
             : r === "unknown" ? "x-circle" : "chevron-right";
    }
    function resultColor(r) {
        return r === "succeeded" ? Theme.primary : r === "failed" ? Theme.errorColor
             : r === "unknown" ? Theme.warn : Theme.fgVariant;
    }
    /** Hora con el formato del usuario (Settings → Calendar → Clock). */
    function clockOf(ms) {
        return Qt.formatDateTime(new Date(ms), Settings.clockFormat === "12h" ? "h:mm AP" : "HH:mm");
    }
    /** «today 10:42» · «yesterday 18:10» · «Sep 25 18:10». */
    function whenOf(ms) {
        if (!(ms > 0)) return "";
        void Issues.now;
        const d = new Date(ms), t = new Date();
        const day = x => new Date(x.getFullYear(), x.getMonth(), x.getDate()).getTime();
        const diff = Math.round((day(t) - day(d)) / 86400000);
        const pre = diff === 0 ? "today" : diff === 1 ? "yesterday" : Qt.formatDate(d, "MMM d");
        return pre + " " + root.clockOf(ms);
    }

    /**
     * Lo enfocado con el teclado, a la vista: el Overview es más alto que su hueco y el foco
     * puede bajar a la actividad o a los diagnósticos. Sólo se mueve si queda fuera.
     */
    function revealFocus() {
        if (!root.active) return;
        if (root.tab === "performance") {
            if (root.section === "tabs") { pfFlick.contentY = 0; return; }
            const focusItem = performance.focusItem();
            if (!focusItem) return;
            const y = focusItem.mapToItem(performance, 0, 0).y, h = focusItem.height;
            const pad = 8 * root.s;
            if (y - pad < pfFlick.contentY) pfFlick.contentY = Math.max(0, y - pad);
            else if (y + h + pad > pfFlick.contentY + pfFlick.height)
                pfFlick.contentY = Math.max(0, Math.min(pfFlick.contentHeight - pfFlick.height, y + h + pad - pfFlick.height));
            return;
        }
        if (root.tab !== "overview") return;
        let it = null;
        if (root.section === "actions") it = actions;
        else if (root.section === "activity") it = acLine;
        else if (root.section === "downed") it = downRep.itemAt(root.downSel);
        else if (root.section === "issues" || root.section === "tabs") { ovFlick.contentY = 0; return; }
        if (!it) return;
        const p = it.mapToItem(ovCol, 0, 0);
        let y = p.y, h = it.height;
        if (it === actions && actions.count > 0) {
            const rows = Math.ceil(actions.count / actions.columns);
            h = actions.height / rows;
            y += Math.floor(actions.current / actions.columns) * h;
        }
        const pad = 8 * root.s;
        if (y - pad < ovFlick.contentY) ovFlick.contentY = Math.max(0, y - pad);
        else if (y + h + pad > ovFlick.contentY + ovFlick.height)
            ovFlick.contentY = Math.min(ovFlick.contentHeight - ovFlick.height, y + h + pad - ovFlick.height);
    }
    onSectionChanged: Qt.callLater(root.revealFocus)
    Connections {
        target: actions
        function onCurrentChanged() { Qt.callLater(root.revealFocus); }
    }
    /**
     * F3d-2: las tareas, por su papel en esta vista (para el autor: update; dotbackup y diskbackup;
     * clean; health y doctor). Sin tasks.json, ninguna.
     */
    readonly property var upgradeTask: Updates.upgradeTask
    readonly property var reportTasks: Tasks.tasks.filter(t => t.runs === "panel" && t.output === "jsonl-report")
    readonly property var panelTasks: Tasks.tasks.filter(t => t.runs === "panel" && t.output !== "jsonl-report")
    readonly property var terminalTasks: Tasks.tasks.filter(t => t.runs === "terminal" && t.role !== "system-upgrade")
    /** Diagnósticos: las tareas con informe (antes, health y doctor fijos). */
    readonly property var checkRows: root.reportTasks.map(t => ({ id: t.id, d: Checks.of(t.id) }))

    /**
     * Mientras el panel está abierto reclama `Units` (QS-FUNC-008): las
     * unidades caídas se releen cada 5 s y el recuento, la fila de salud y la
     * consola de «downed» dicen lo mismo a la vez. Clave con el monitor; vacía
     * mientras se construye, y entonces no se reclama (QS-FUNC-003).
     */
    readonly property string claimKey: root.screenName.length > 0 ? "dashboard@" + root.screenName : ""
    Claim { target: Units; key: root.claimKey; value: root.active && root.tab === "overview" && Units.supported }

    onActiveChanged: {
        if (root.active) {
            actions.reset();                 // el foco vuelve a la 1ª acción
            performance.reset();             // selecciona el modo solicitado sin volver a aplicarlo
            root.moreOpen = false;
            root.issueSel = 0;
            // 11A-1: la pestaña del nombre con que se abrió; sin animación de entrada
            const hint = root.host ? root.host.selOf("dashboard") : "";
            const back = root.host && root.host._returning;   // Esc desde System Monitor: la misma pestaña
            if (!back) {
                root.tab = hint === "performance" ? hint : "overview";
                root.section = root.firstSection(root.tab);
            }
            root.slideX = 0;
            root.paneOpacity = 1;
            if (!back) Qt.callLater(root.scrollTop);   // los hijos pueden no existir aún (se construye)
            if (root.tab === "overview") Issues.refresh();   // una lectura, sin abrir sensores
            if (root.tab === "performance") { PowerProfile.refresh(); Modes.refresh(); }
        } else {
            root.resetView();                // la vista, no el trabajo (fase 6B)
        }
    }
    function scrollTop() { ovFlick.contentY = 0; pfFlick.contentY = 0; }
    onTabChanged: {
        if (root.active && root.tab === "overview") Issues.refresh();
        if (root.active && root.tab === "performance") { PowerProfile.refresh(); Modes.refresh(); }
    }
    /** Limpia la VISTA (la lista de caídas). Los trabajos y la capa Tasks siguen. */
    function resetView() { root.downedWatch = false; }


    /** La consola enseña las unidades caídas y se repinta con cada lectura de `Units`. */
    property bool downedWatch: false
    /** El texto plano de lo último que pintó `renderDowned`, para el IPC. */
    property string downedText: ""

    /**
     * Ya no lanza sus propios `systemctl --failed` (QS-FUNC-008): pinta
     * `Units.failed`, con el mismo formato que la salida `--plain` que
     * enseñaba antes, y se repinta en cada lectura mientras esté a la vista.
     */
    /**
     * 11F-1: una unidad caída se abre en Systemd Units, en SU ámbito (una de sistema nunca manda a la
     * lista de usuario). Su ficha se abre aunque su tipo no esté en la lista principal.
     */
    signal requestDetail(string name, string key)
    property int downSel: 0
    readonly property var downedRows: { void Units.failed; return Units.failed; }
    onDownedRowsChanged: if (root.downSel >= root.downedRows.length) root.downSel = Math.max(0, root.downedRows.length - 1)
    function openUnit(f) {
        if (!f || !Units.scopeSupported(f.scope)) return;
        const k = Units.key(f.scope, f.unit);
        Units.loadDetail(k);
        root.requestDetail("serviceDetail", k);
    }

    function runDowned() {
        if (!Units.supported) return;
        root.resetView();
        root.showTab("overview", true);
        root.downedWatch = true;
        root.downSel = 0;
        if (Units.failedTotal > 0) { root.section = "downed"; Qt.callLater(root.revealFocus); }
        if (Units.failedTotal >= 0)
            root.renderDowned();
        Units.refreshFailed();
    }

    function renderDowned() {
        const blocks = [];
        for (const scope of ["system", "user"]) {
            const rows = Units.failed.filter(function (f) { return f.scope === scope; });
            if (rows.length === 0)
                continue;
            blocks.push("── " + scope + " ──\n" + rows.map(function (f) {
                return [f.unit, f.load, f.active, f.sub, f.desc].join(" ");
            }).join("\n"));
        }
        root.downedText = blocks.length > 0 ? blocks.join("\n") : "No failed units.";
    }

    Connections {
        target: Units
        function onFailedRead() { if (root.downedWatch) root.renderDowned(); }
    }

    /** Etapa C: lo que mide el banco (¿cabe el Overview sin scroll?). */
    function layoutState() {
        return { overview: { content: Math.round(ovFlick.contentHeight), view: Math.round(ovFlick.height) },
                 performance: { content: Math.round(pfFlick.contentHeight), view: Math.round(pfFlick.height) },
                 panel: { w: Math.round(root.width), h: Math.round(root.height) } };
    }
    // 11D-2: estado de la vista para IPC; el motor sigue siendo la única autoridad.
    function performanceState() { return performance.summary(); }
    function performanceTestPower(value) {
        if (!Modes.testing) return false;
        performance.powerTest = value;
        return true;
    }

    // --- acciones -------------------------------------------------------
    /**
     * 11A-2: el ORDEN es fijo (futureDashboardsurface: actualizar, dotbackup, diskbackup, servicios
     * caídos, limpiar) y no depende de los asuntos; sólo cambian el texto y si está disponible, y
     * uno inactivo dice por qué.
     */
    /**
     * 11A-2 → F3d-2: las acciones salen de las tareas, en un orden estable por papel: actualizar (la tarea
     * system-upgrade), las del panel que no son informes (las copias), los servicios caídos (siempre:
     * no es una tarea) y las de terminal. Para el autor, el de antes: update, dotbackup, diskbackup,
     * downed, clean. Sin tasks.json, sólo los servicios caídos.
     */
    /**
     * Etapa A (2026-11-09): cada acción es una casilla con `title` y, debajo, `status` (antes, una fila con
     * todo junto y las apagadas en gris). `tone`: "" · warn · bad · busy. `label` (título · estado) queda
     * para el IPC. «Failed services» sale de aquí: ya es un asunto con su acción (Details), y una casilla
     * «none» apagada sólo ocupaba sitio.
     */
    readonly property var actionList: {
        void Issues.now;
        const out = [];
        const item = o => Object.assign(o, { label: o.title + (o.status ? " · " + o.status : "") });
        const term = Apps.terminalLabel;
        const up = root.upgradeTask;
        if (up) {
            const n = Updates.count;
            const blocked = Updates.notSetUp.length > 0 || Updates.upgradeWhy.length > 0;
            out.push(item({
                id: up.id, glyph: up.glyph || "update", title: up.label,
                // F2d (visto en pantalla): sin tubería no hay «nothing pending» que decir
                status: Updates.notSetUp.length > 0 ? Updates.notSetUp
                    : Updates.upgradeWhy.length > 0 ? Updates.upgradeWhy
                    : Updates.stale || Updates.failed ? "Status unknown · opens " + term
                    : n > 0 && Updates.risky ? n + " pending · " + Updates.riskShort
                    : n > 0 ? n + " pending · opens " + term : "Nothing pending",
                // 2026-11-25: con riesgo (sysupdate), en rojo; sigue activa: la decisión es del usuario
                tone: n > 0 && !blocked ? (Updates.risky ? "bad" : "warn") : "",
                enabled: !blocked && (Updates.any || Updates.stale)
            }));
            // 2026-11-25: «Safe upgrade» sólo existe con riesgo y sysupdate (retiene lo que éste propone)
            if (n > 0 && Updates.risky && Updates.safeWhy.length === 0) {
                const held = Updates.riskIgnore;
                out.push(item({
                    id: "update-safe", glyph: "update", title: "Safe upgrade",
                    status: "Holds back " + held.slice(0, 2).join(", ") + (held.length > 2 ? "…" : "") + " · opens " + term,
                    tone: "", enabled: true
                }));
            }
        }
        for (const t of root.panelTasks) {
            // 11A-1: en curso sigue activa: lleva a su consola en Tasks, no lanza otro
            const why = Jobs.whyNot(t.id), r = Jobs.runner(t.id), at = Issues.ageOf(t.id).at;
            let status = "", tone = "";
            if (why.length > 0) status = why;
            else if (r && r.state === "needs-input") { status = "Waiting for you · open in Tasks"; tone = "warn"; }
            else if (r && r.busy) { status = "Running · open in Tasks"; tone = "busy"; }
            else if (root.unseen(r)) {
                status = ({ succeeded: "Done", failed: "Failed", cancelled: "Cancelled", unknown: "Result unknown" })[r.state]
                    + " · see Tasks";
                tone = r.state === "succeeded" ? "busy" : "bad";
            } else {
                status = at > 0 ? "Last run " + Issues.ago(at) : "Not run yet";
                if (Issues.issues.some(x => x.id === t.id)) { status += " · overdue"; tone = "warn"; }
            }
            out.push(item({ id: t.id, glyph: t.glyph || "folder", title: t.label, status: status, tone: tone,
                            enabled: why.length === 0 }));
        }
        for (const t of root.terminalTasks) {
            const why = Jobs.whyNot(t.id);
            out.push(item({ id: t.id, glyph: t.glyph || "cog", title: t.label,
                            status: why.length > 0 ? why : "Opens " + term, tone: "", enabled: why.length === 0 }));
        }
        return out;
    }

    /** Para el IPC (pruebas por teclado): la acción de mantenimiento con el foco. */
    function focusedAction() {
        const a = root.actionList[actions.current];
        return root.section === "actions" && a ? a.id : "";
    }

    /** Terminado y sin ver: la acción lo enseña en la capa Tasks en vez de lanzar otro. */
    function unseen(r) { return r && !r.busy && !r.seen && r.state !== "idle"; }
    /** Las de terminal (update, clean): el ejecutor de la paleta; la terminal nueva necesita el teclado. */
    function runCommand(id) {
        const c = Commands.get(id);
        if (c && c.runs === "panel") { root.openTasks(id, true); return; }
        const r = Commands.run(id);
        if (r.ok) root.requestClose();
    }

    function runAction(id) {
        const a = root.actionList.find(x => x.id === id);
        if (a && a.enabled === false) return;           // F2d: apagada con su motivo en la etiqueta
        if (id === "downed") { if (root.downedWatch) root.downedWatch = false; else root.runDowned(); return; }
        if (id === "update-safe") { if (Updates.updateSafe()) root.requestClose(); return; }
        const t = Tasks.byId(id);
        if (!t) return;
        // etapa B: lo del panel se sigue (o se arranca, con su pregunta) en la capa Tasks
        if (t.runs === "panel") { root.openTasks(id, !root.unseen(Jobs.runner(id)) && !Jobs.runner(id).busy
                                                     && Jobs.runner(id).state !== "needs-input"); return; }
        if (t.runs === "terminal") { root.runCommand(id); return; }   // 11B: Commands (Upgrade incluido)
    }

    /** La línea de health / doctor en los diagnósticos: cuándo corrió y qué encontró. */
    function checkLine(d) {
        if (!d || !d.ran || d.ran <= 0 || d.findings < 0) return "not run yet";
        const f = d.findings === 0 ? "no findings" : d.findings + (d.findings === 1 ? " finding" : " findings");
        const u = d.unknown > 0 ? " · " + d.unknown + " could not answer" : "";
        return f + u + " · " + root.whenOf(d.ran * 1000);
    }
    function checkColor(d) {
        return (d && d.ran > 0 && (d.findings > 0 || d.unknown > 0)) ? Theme.errorColor : Theme.fgVariant;
    }

    /** health / doctor (los asuntos «Run …»): se corren en la capa Tasks, con su informe. */
    function runCheck(id) { root.openTasks(id, !Jobs.runner(id).busy); }

    function keyPressed(event) {
        const K = event.key;
        const ctrl = (event.modifiers & Qt.ControlModifier) !== 0;
        // 11A-1: pestañas desde cualquier sitio: Ctrl+Tab / Ctrl+⇧Tab y Ctrl+RePág / Ctrl+AvPág, como en un navegador.
        if (ctrl && (K === Qt.Key_Tab || K === Qt.Key_PageDown)) { root.stepTab(1); event.accepted = true; return; }
        if (ctrl && (K === Qt.Key_Backtab || K === Qt.Key_PageUp)) { root.stepTab(-1); event.accepted = true; return; }

        const up = K === Qt.Key_Up,    down  = K === Qt.Key_Down;
        const left = K === Qt.Key_Left, right = K === Qt.Key_Right;
        const enter = K === Qt.Key_Return || K === Qt.Key_Enter;

        // etapa A: sin tecla D (nadie la descubría); el pliegue se alcanza con las flechas y se abre con ⏎

        if (root.section === "tabs") {
            if (root.tab === "performance" && (K === Qt.Key_Tab || K === Qt.Key_Backtab)) {
                if (K === Qt.Key_Tab) { performance.selected = 0; root.section = "mode"; }
                else root.section = "monitor";
                event.accepted = true; return;
            }
            if (left || right) { root.stepTab(right ? 1 : -1); root.section = "tabs"; event.accepted = true; }
            else if (down || enter) {
                const f = root.firstSection(root.tab);
                if (f !== "tabs") root.section = f;
                event.accepted = true;
            } else if (up) event.accepted = true;
            return;
        }

        // --- Overview (11A-2; etapa C sin pliegue): issues → actions → downed → activity ---------------
        const ovOrder = ["issues", "actions", "downed", "activity"];
        const ovHas = function (sec) {
            return sec === "issues" ? root.issueCount > 0
                 : sec === "downed" ? root.downedWatch && root.downedRows.length > 0 : true;
        };
        const ovStep = function (from, d) {
            let i = ovOrder.indexOf(from) + d;
            while (i >= 0 && i < ovOrder.length && !ovHas(ovOrder[i])) i += d;
            if (i < 0) return "tabs";
            return i < ovOrder.length ? ovOrder[i] : "";
        };
        const ovEnter = function (sec, fromBelow) {
            root.section = sec;
            if (sec === "issues") root.issueSel = fromBelow ? root.issueCount - 1 : 0;
            else if (sec === "actions") actions.current = fromBelow ? actions.count - 1 : 0;
            else if (sec === "downed") root.downSel = fromBelow ? root.downedRows.length - 1 : 0;
        };
        if (root.section === "issues") {
            if (up && root.issueSel > 0) root.issueSel--;
            else if (up) root.section = "tabs";
            else if (down && root.issueSel < root.issueCount - 1) root.issueSel++;
            else if (down) ovEnter(ovStep("issues", 1), false);
            else if (enter) root.issueActivate(root.issueSel);
            else if (!(left || right)) return;
            event.accepted = true;
            return;
        }
        if (root.section === "actions") {
            // el grupo vertical se queda ↑/↓ y ⏎ dentro; en sus bordes se cruza de sección
            if (actions.handleKey(event)) { event.accepted = true; return; }
            if (up) { const t = ovStep("actions", -1); if (t === "tabs") root.section = "tabs"; else ovEnter(t, true); event.accepted = true; return; }
            if (down) { const t = ovStep("actions", 1); if (t.length > 0) ovEnter(t, false); event.accepted = true; return; }
            if (left || right) { event.accepted = true; return; }
            return;
        }
        // 11F-1: la lista de caídas, navegable: ⏎ abre la unidad en Systemd Units, en su ámbito
        if (root.section === "downed") {
            if (up && root.downSel > 0) root.downSel--;
            else if (up) ovEnter("actions", true);
            else if (down && root.downSel < root.downedRows.length - 1) root.downSel++;
            else if (down) { const t = ovStep("downed", 1); if (t.length > 0) ovEnter(t, false); }
            else if (enter) root.openUnit(root.downedRows[root.downSel]);
            else if (!(left || right)) return;
            event.accepted = true;
            return;
        }
        if (root.section === "activity") {
            if (up) ovEnter(ovStep("activity", -1), true);
            else if (enter) root.activityActivate();
            else if (!(down || left || right)) return;
            event.accepted = true;
            return;
        }

        // --- Performance: rejilla 2×2, recuperación y energía independientes ---
        if (root.tab === "performance" && performance.key(event)) { event.accepted = true; return; }
    }

    /** Performance → System Monitor: se apila (Back / Esc vuelven aquí). */
    function openMonitor() { root.requestSurface("system"); }
    /** La UI de inspección en esta pantalla; el Dashboard (encima, en Overlay) se cierra para dejarla ver. */
    function openInspector() {
        if (MonitorUi.show(root.screenName, "overview")) root.requestClose();
    }
    signal requestSurface(string name)

    Column {
        id: col
        anchors.fill: parent
        spacing: 8 * root.s

        // -- cabecera (etapa C, 2026-11-10): el título y las pestañas en UNA fila (antes, dos: ~44 px menos) --
        Item {
            id: tabBar
            width: parent.width
            height: 36 * root.s
            readonly property real tabW: 150 * root.s
            Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "Dashboard"
                color: Theme.fg
                font.family: Typography.ui
                font.pixelSize: Typography.display * root.s
                font.weight: Typography.wStrong
                Accessible.role: Accessible.Heading
            }
            // -- pestañas (11A-1): icono, nombre y una marca bajo la activa, además del color --
            Row {
                id: tabRow
                anchors.right: parent.right
                height: parent.height
                Accessible.role: Accessible.PageTabList
                Repeater {
                    model: root.tabs
                    delegate: Item {
                        id: tabItem
                        required property var modelData
                        required property int index
                        readonly property bool current: root.tab === tabItem.modelData.id
                        readonly property bool kbd: root.section === "tabs" && tabItem.current
                        width: tabBar.tabW
                        height: tabBar.height
                        Accessible.role: Accessible.PageTab
                        Accessible.name: tabItem.modelData.label
                        Accessible.selected: tabItem.current
                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: 2 * root.s
                            radius: Metrics.r(8) * root.s
                            // etapa A: la activa se distingue por color y marca, sin fondo
                            color: tabArea.containsMouse && !tabItem.current ? Theme.hoverBg : "transparent"
                            Behavior on color { ColorAnimation { duration: Motion.fast } }
                            border.width: tabItem.kbd ? Metrics.focusWidth * root.s : 0
                            border.color: Theme.selBorder
                        }
                        Row {
                            anchors.centerIn: parent
                            spacing: 6 * root.s
                            Icon {
                                anchors.verticalCenter: parent.verticalCenter
                                name: tabItem.modelData.glyph
                                size: 13 * root.s
                                // cada pestaña con su color (lib/accent-zones.js)
                                color: tabItem.current ? Theme.famNamed(Zones.nth(tabItem.index)).accent : Theme.fgVariant
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: tabItem.modelData.label
                                color: tabItem.current ? Theme.fg : Theme.fgVariant
                                font.family: Typography.ui
                                font.pixelSize: Typography.body * root.s
                                font.weight: tabItem.current ? Typography.wStrong : Font.Normal
                            }
                        }
                        MouseArea {
                            id: tabArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.showTab(tabItem.modelData.id, false)
                        }
                    }
                }
            }
            // la marca: se desliza a la pestaña activa (sin rebote; quieta con Reduced/Off)
            Rectangle {
                y: parent.height - height
                x: tabRow.x + root.tabIndex * tabBar.tabW + 18 * root.s
                width: tabBar.tabW - 36 * root.s
                height: 2 * root.s
                radius: Metrics.pill(height)
                color: Theme.famNamed(Zones.nth(root.tabIndex)).fill
                Behavior on color { ColorAnimation { duration: Motion.fast } }
                Behavior on x {
                    enabled: !Motion.still
                    NumberAnimation { duration: Motion.page; easing.type: Easing.OutCubic }
                }
            }
        }
        Rectangle { width: parent.width; height: 1; color: Theme.hair }

        // -- el contenido de la pestaña: alto fijo, cada una con su scroll --
        Item {
            id: pane
            width: parent.width
            height: col.height - y - footer.height - col.spacing
            clip: true
            opacity: root.paneOpacity
            transform: Translate { x: root.slideX }

        // ---- overview ----
        Item {
            width: parent.width
            height: parent.height
            visible: root.tab === "overview"
            Flickable {
                id: ovFlick
                anchors.fill: parent
                // la barra va fuera, a 6·s de las tarjetas, y la página recorta: su hueco entero aquí
                anchors.rightMargin: 10 * root.s
                contentWidth: width
                contentHeight: ovCol.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                interactive: contentHeight > height
                Column {
                    id: ovCol
                    width: ovFlick.width
                    spacing: 8 * root.s

                    // -- resumen: ¿hay algo que atender? (11A-2). Alto RESERVADO para la cabecera y
                    //    tres asuntos: que lleguen datos no mueve el mantenimiento de debajo --
                    Item {
                        width: parent.width
                        height: root.moreOpen ? sumCol.implicitHeight : Math.max(sumCol.implicitHeight, root.summaryH)
                        Column {
                            id: sumCol
                            width: parent.width
                            spacing: 2 * root.s

                            Item {
                                width: parent.width
                                height: 24 * root.s
                                Row {
                                    anchors.left: parent.left
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 7 * root.s
                                    Icon {
                                        anchors.verticalCenter: parent.verticalCenter
                                        name: Issues.headline === "clear" ? "check-circle"
                                            : Issues.headline === "loading" ? "reload" : "alert"
                                        size: 14 * root.s
                                        color: Issues.headline === "clear" ? Theme.primary
                                            : Issues.headline === "issues" ? Theme.errorColor
                                            : Issues.headline === "problems" ? Theme.warn : Theme.fgVariant
                                    }
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: root.headlineText
                                        color: Theme.fg
                                        font.family: Typography.ui
                                        font.pixelSize: Typography.body * root.s
                                        font.weight: Typography.wStrong
                                    }
                                }
                                Text {
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: Issues.lastChecked > 0 ? "Last checked " + root.clockOf(Issues.lastChecked) : ""
                                    color: Theme.fgVariant
                                    font.family: Typography.ui
                                    font.pixelSize: Typography.caption * root.s
                                    font.features: ({ "tnum": 1 })
                                }
                            }

                            Repeater {
                                model: root.issueRowsShown
                                delegate: Item {
                                    id: isRow
                                    required property var modelData
                                    required property int index
                                    readonly property bool sel: root.section === "issues" && root.issueSel === isRow.index
                                    readonly property bool bad: isRow.modelData.state === "issue"
                                    width: sumCol.width
                                    height: 28 * root.s
                                    Accessible.role: Accessible.ListItem
                                    Accessible.name: isRow.modelData.text + ". " + root.issueDetail(isRow.modelData)
                                    Rectangle {
                                        anchors.fill: parent
                                        radius: Metrics.r(7) * root.s
                                        color: isRow.sel ? Theme.selBg : "transparent"
                                        border.width: isRow.sel ? 1 : 0
                                        border.color: Theme.selBorder
                                    }
                                    Item {
                                        id: isIcon
                                        anchors.left: parent.left
                                        anchors.leftMargin: 8 * root.s
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 14 * root.s
                                        height: width
                                        Icon {
                                            anchors.centerIn: parent
                                            name: isRow.bad ? "alert" : "x-circle"
                                            size: 12 * root.s
                                            color: isRow.bad ? Theme.errorColor : Theme.warn
                                        }
                                    }
                                    Text {
                                        id: isText
                                        anchors.left: isIcon.right
                                        anchors.leftMargin: 8 * root.s
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: Math.min(implicitWidth, sumCol.width * 0.42)
                                        elide: Text.ElideRight
                                        text: isRow.modelData.text
                                        color: Theme.fg
                                        font.family: Typography.ui
                                        font.pixelSize: Typography.caption * root.s
                                        font.weight: Font.DemiBold
                                    }
                                    Text {
                                        anchors.left: isText.right
                                        anchors.leftMargin: 8 * root.s
                                        anchors.right: isBtn.visible ? isBtn.left : parent.right
                                        anchors.rightMargin: 8 * root.s
                                        anchors.verticalCenter: parent.verticalCenter
                                        elide: Text.ElideRight
                                        text: root.issueDetail(isRow.modelData)
                                        color: Theme.fgVariant
                                        font.family: Typography.ui
                                        font.pixelSize: Typography.caption * root.s
                                    }
                                    ActionButton {
                                        id: isBtn
                                        anchors.right: parent.right
                                        anchors.rightMargin: 4 * root.s
                                        anchors.verticalCenter: parent.verticalCenter
                                        visible: isRow.modelData.actionLabel.length > 0
                                        s: root.s
                                        label: isRow.modelData.action === "units" && root.downedWatch ? "Hide"
                                             : isRow.modelData.actionLabel
                                        focused: isRow.sel
                                        ringless: true
                                        onTriggered: { root.section = "issues"; root.issueSel = isRow.index; root.issueActivate(isRow.index); }
                                    }
                                }
                            }

                            // «N more»: el resto, plegado (una expansión explícita sí mueve lo de debajo)
                            Item {
                                id: moreRow
                                width: parent.width
                                height: 20 * root.s
                                visible: root.issueRows.length > 3
                                readonly property bool sel: root.section === "issues" && root.issueSel === root.issueRowsShown.length
                                Rectangle {
                                    anchors.fill: parent
                                    radius: Metrics.r(6) * root.s
                                    color: moreRow.sel ? Theme.selBg : "transparent"
                                    border.width: moreRow.sel ? 1 : 0
                                    border.color: Theme.selBorder
                                }
                                Row {
                                    anchors.left: parent.left
                                    anchors.leftMargin: 8 * root.s
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 6 * root.s
                                    Icon {
                                        anchors.verticalCenter: parent.verticalCenter
                                        name: root.moreOpen ? "chevron-down" : "chevron-right"
                                        size: 11 * root.s
                                        color: Theme.fgVariant
                                    }
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: root.moreOpen ? "Show fewer" : (root.issueRows.length - 3) + " more"
                                        color: Theme.fgVariant
                                        font.family: Typography.ui
                                        font.pixelSize: Typography.caption * root.s
                                    }
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: { root.section = "issues"; root.issueSel = root.issueRowsShown.length; root.moreOpen = !root.moreOpen; }
                                }
                            }

                            // Todo bien (o leyendo): una línea tranquila
                            Text {
                                width: parent.width
                                leftPadding: 8 * root.s
                                visible: root.issueRows.length === 0
                                wrapMode: Text.WordWrap
                                text: Issues.headline === "loading"
                                    ? Issues.sources.filter(x => x.state === "loading").map(x => x.text).join(" · ")
                                    : root.clearText
                                color: Theme.fgVariant
                                font.family: Typography.ui
                                font.pixelSize: Typography.caption * root.s
                            }
                        }
                    }

                    Rectangle { width: parent.width; height: 1; color: Theme.hair }

                    // -- mantenimiento: posiciones ESTABLES (el orden no depende de los asuntos) --
                    Text {
                        text: "MAINTENANCE"
                        color: Theme.outlineText
                        font.family: Typography.ui
                        font.pixelSize: Typography.micro * root.s
                        font.weight: Typography.wStrong
                        font.letterSpacing: Typography.tracking * root.s
                    }
                    // Etapa A: casillas en dos columnas, cada una con su estado debajo. El hover sólo pinta;
                    // el foco de teclado es `current` y sólo lo mueven el teclado y el clic (DESIGN §3, 11F-1).
                    Item {
                        id: actions
                        width: parent.width
                        height: actionGrid.implicitHeight
                        readonly property int columns: 2
                        readonly property int count: root.actionList.length
                        property int current: 0
                        onCountChanged: if (actions.current >= actions.count) actions.current = Math.max(0, actions.count - 1)
                        function reset() { actions.current = 0; }
                        /** ←→ en la fila, ↑↓ entre filas; en el borde de arriba/abajo devuelve false (cruza). */
                        function handleKey(event) {
                            const k = event.key, c = actions.current, n = actions.count, cols = actions.columns;
                            if (n === 0) return false;
                            if (k === Qt.Key_Left) { if (c % cols > 0) actions.current = c - 1; return true; }
                            if (k === Qt.Key_Right) { if (c % cols < cols - 1 && c + 1 < n) actions.current = c + 1; return true; }
                            if (k === Qt.Key_Up) { if (c >= cols) { actions.current = c - cols; return true; } return false; }
                            if (k === Qt.Key_Down) {
                                if (c + cols < n) { actions.current = c + cols; return true; }
                                // la última fila puede estar incompleta: se baja a su última casilla
                                if (Math.floor(c / cols) < Math.floor((n - 1) / cols)) { actions.current = n - 1; return true; }
                                return false;
                            }
                            if (k === Qt.Key_Return || k === Qt.Key_Enter) { actions.activate(c); return true; }
                            return false;
                        }
                        function activate(i) {
                            const a = root.actionList[i];
                            root.section = "actions";
                            actions.current = i;
                            if (a && a.enabled !== false) root.runAction(a.id);
                        }
                        Grid {
                            id: actionGrid
                            width: parent.width
                            columns: actions.columns
                            spacing: 8 * root.s
                            Repeater {
                                model: root.actionList
                                delegate: Rectangle {
                                    id: tile
                                    required property var modelData
                                    required property int index
                                    readonly property bool sel: root.section === "actions" && actions.current === tile.index
                                    readonly property bool on: tile.modelData.enabled !== false
                                    readonly property string tone: tile.modelData.tone || ""
                                    /** Cada acción con su color, en rotación (lib/accent-zones.js): la rejilla deja de ser gris. */
                                    palette.accent: Theme.zone(Zones.nth(tile.index))
                                    readonly property var acc: Theme.fam(palette.accent)
                                    width: (actionGrid.width - actionGrid.spacing * (actions.columns - 1)) / actions.columns
                                    height: 50 * root.s
                                    radius: Metrics.r(10) * root.s
                                    color: Theme.controlBg(tile.on ? tile.acc.container : Theme.tileBg, tileArea.containsMouse && tile.on, tileArea.pressed && tileArea.containsMouse && tile.on, false, tile.acc)
                                    Behavior on color { ColorAnimation { duration: Motion.fast } }
                                    border.width: tile.sel ? Metrics.focusWidth * root.s : 0
                                    border.color: tile.acc.selBorder
                                    Accessible.role: Accessible.Button
                                    Accessible.name: tile.modelData.title
                                    Accessible.description: tile.modelData.status
                                    Accessible.focusable: true
                                    Accessible.focused: tile.sel
                                    Accessible.onPressAction: actions.activate(tile.index)
                                    // hueco fijo: los glifos miden distinto y el texto no debe bailar
                                    Item {
                                        id: tileIcon
                                        anchors.left: parent.left
                                        anchors.leftMargin: 12 * root.s
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 18 * root.s
                                        height: width
                                        Icon {
                                            anchors.centerIn: parent
                                            name: tile.modelData.glyph
                                            size: 16 * root.s
                                            color: tile.on ? tile.acc.accent : Theme.disabledFg
                                        }
                                    }
                                    Column {
                                        anchors.left: tileIcon.right
                                        anchors.leftMargin: 10 * root.s
                                        anchors.right: parent.right
                                        anchors.rightMargin: 12 * root.s
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: 2 * root.s
                                        Text {
                                            width: parent.width
                                            elide: Text.ElideRight
                                            text: tile.modelData.title
                                            color: tile.on ? Theme.fg : Theme.disabledFg
                                            font.family: Typography.ui
                                            font.pixelSize: Typography.body * root.s
                                            font.weight: Font.DemiBold
                                        }
                                        Text {
                                            width: parent.width
                                            elide: Text.ElideRight
                                            text: tile.modelData.status
                                            color: tile.tone === "bad" ? Theme.errorColor : tile.tone === "warn" ? Theme.warn
                                                 : tile.tone === "busy" ? tile.acc.text : Theme.fgVariant
                                            font.family: Typography.ui
                                            font.pixelSize: Typography.caption * root.s
                                            font.features: ({ "tnum": 1 })
                                        }
                                    }
                                    MouseArea {
                                        id: tileArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: tile.on ? Qt.PointingHandCursor : Qt.ArrowCursor
                                        onClicked: actions.activate(tile.index)
                                    }
                                }
                            }
                        }
                    }

                    // -- unidades caídas: la lista, en Overview (11A-1; antes en la consola) --
                    Column {
                        width: parent.width
                        spacing: 2 * root.s
                        visible: root.downedWatch && Units.supported
                        Repeater {
                            id: downRep
                            model: root.downedWatch ? root.downedRows : []
                            delegate: Item {
                                id: dnRow
                                required property var modelData
                                required property int index
                                readonly property bool sel: root.section === "downed" && root.downSel === dnRow.index
                                width: ovCol.width
                                height: 24 * root.s
                                Accessible.role: Accessible.ListItem
                                Accessible.name: dnRow.modelData.scope + " unit " + dnRow.modelData.unit + ", " + dnRow.modelData.sub
                                Rectangle {
                                    anchors.fill: parent
                                    radius: Metrics.r(6) * root.s
                                    color: dnRow.sel ? Theme.selBg : dnArea.containsMouse ? Theme.hoverBg : "transparent"
                                    border.width: dnRow.sel ? 1 : 0
                                    border.color: Theme.selBorder
                                }
                                Row {
                                    anchors.left: parent.left
                                    anchors.leftMargin: 8 * root.s
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 8 * root.s
                                    Text {
                                        text: dnRow.modelData.scope === "system" ? "System" : "User"
                                        width: 44 * root.s
                                        color: Theme.outlineText
                                        font.family: Typography.ui
                                        font.pixelSize: Typography.micro * root.s
                                    }
                                    Text {
                                        text: dnRow.modelData.unit
                                        color: Theme.errorColor
                                        font.family: Typography.mono
                                        font.pixelSize: Typography.caption * root.s
                                    }
                                    Text {
                                        text: dnRow.modelData.sub + (dnRow.modelData.desc ? " · " + dnRow.modelData.desc : "")
                                        color: Theme.fgVariant
                                        font.family: Typography.ui
                                        font.pixelSize: Typography.caption * root.s
                                    }
                                }
                                Text {
                                    anchors.right: parent.right
                                    anchors.rightMargin: 8 * root.s
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: "Open in Units ›"
                                    visible: dnRow.sel || dnArea.containsMouse
                                    color: Theme.fgVariant
                                    font.family: Typography.ui
                                    font.pixelSize: Typography.caption * root.s
                                }
                                MouseArea {
                                    id: dnArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: { root.section = "downed"; root.downSel = dnRow.index; root.openUnit(dnRow.modelData); }
                                }
                            }
                        }
                        Text {
                            visible: Units.failedTotal === 0
                            text: "No failed units."
                            color: Theme.fgVariant
                            font.family: Typography.ui
                            font.pixelSize: Typography.caption * root.s
                        }
                    }
                    Rectangle { width: parent.width; height: 1; color: Theme.hair }

                    // -- actividad (etapa C): lo último que corrió desde la shell y los trabajos vivos; el historial
                    //    entero de cada tarea está en la ventana Tasks («Recent runs») --
                    Item {
                        id: acLine
                        width: ovCol.width
                        height: 28 * root.s
                        readonly property var e: root.lastActivity
                        readonly property bool sel: root.section === "activity"
                        Accessible.role: Accessible.ListItem
                        Accessible.name: acLine.e ? "Last run: " + acLine.e.label + ", " + root.resultWord(acLine.e.result)
                                                    + ", " + root.whenOf(acLine.e.at) : "Nothing run from the shell yet"
                        Rectangle {
                            anchors.fill: parent
                            radius: Metrics.r(7) * root.s
                            color: acLine.sel ? Theme.selBg : "transparent"
                            border.width: acLine.sel ? 1 : 0
                            border.color: Theme.selBorder
                        }
                        Item {
                            id: acIcon
                            anchors.left: parent.left
                            anchors.leftMargin: 8 * root.s
                            anchors.verticalCenter: parent.verticalCenter
                            width: 14 * root.s
                            height: width
                            Icon {
                                anchors.centerIn: parent
                                name: acLine.e ? root.resultGlyph(acLine.e.result) : "terminal"
                                size: 12 * root.s
                                color: acLine.e ? root.resultColor(acLine.e.result) : Theme.fgVariant
                            }
                        }
                        Text {
                            anchors.left: acIcon.right
                            anchors.leftMargin: 8 * root.s
                            anchors.right: acBtn.left
                            anchors.rightMargin: 10 * root.s
                            anchors.verticalCenter: parent.verticalCenter
                            elide: Text.ElideRight
                            textFormat: Text.PlainText
                            text: !acLine.e ? (Activity.loaded ? "Nothing run from the shell yet" : "Loading…")
                                : "Last: " + acLine.e.label + " · " + root.resultWord(acLine.e.result) + " · " + root.whenOf(acLine.e.at)
                            color: acLine.e ? Theme.fg : Theme.fgVariant
                            font.family: Typography.ui
                            font.pixelSize: Typography.caption * root.s
                            font.features: ({ "tnum": 1 })
                        }
                        ActionButton {
                            id: acBtn
                            anchors.right: parent.right
                            anchors.rightMargin: 4 * root.s
                            anchors.verticalCenter: parent.verticalCenter
                            s: root.s
                            label: root.liveJobs > 0 ? root.liveJobs + (root.liveJobs === 1 ? " job running" : " jobs running") + " · Tasks ›"
                                                     : "Tasks ›"
                            focused: acLine.sel
                            ringless: true
                            onTriggered: { root.section = "activity"; root.activityActivate(); }
                        }
                    }
                }
            }
            ScrollHint { view: ovFlick; s: root.s }
        }
        // ---- performance ----
        Item {
            width: parent.width
            height: parent.height
            visible: root.tab === "performance"
            Flickable {
                id: pfFlick
                anchors.fill: parent
                anchors.rightMargin: 10 * root.s
                contentWidth: width
                contentHeight: performance.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                interactive: contentHeight > height
                DashboardPerformance {
                    id: performance
                    width: pfFlick.width
                    height: implicitHeight
                    s: root.s
                    section: root.tab === "performance" ? root.section : ""
                    onNavigate: section => root.section = section
                    onMonitor: root.openMonitor()
                    onRevealRequested: Qt.callLater(root.revealFocus)
                }
            }
            ScrollHint { view: pfFlick; s: root.s }
        }
        }

        Text {
            id: footer
            topPadding: 2 * root.s
            width: parent.width
            elide: Text.ElideRight
            text: "↑↓ ←→ move · ⏎ activate · Ctrl+Tab · next tab · Esc close"
            color: Theme.fgVariant
            font.family: Typography.ui
            font.pixelSize: Typography.caption * root.s
        }
    }
}
