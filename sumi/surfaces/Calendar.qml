pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import "../theme"
import "../services"
import "../components"

/**
 * Calendario (Fase 9.d; rediseño, fase 7C — spec `futurecalendarsurface.md`).
 *
 * Arriba el reloj y la fecha (el reloj compartido, `services/Clock`: ni un
 * temporizador propio); debajo el mes en seis semanas fijas —la altura no cambia
 * al navegar—, con la semana ISO a la derecha (por su JUEVES, puerta P2 de 9.d);
 * y la agenda del día seleccionado, leída de `calcurse` por `services/Agenda`.
 *
 *   · HOY y SELECCIÓN son distintos: hoy, marca sólida; seleccionado, contorno;
 *     la semana de hoy, un fondo tenue. Abrir por atajo selecciona hoy; Back /
 *     Forward devuelven la fecha, el evento y el scroll (`saveContext`).
 *   · Un punto bajo el día si tiene algo; con dos o más, el número.
 *   · La agenda se consulta UNA vez por rango de 42 días (abrir, cambiar de mes,
 *     Retry); cambiar de día sólo filtra. Loading / No events / Could not load
 *     (+ Retry) / calcurse is not installed son estados distintos: «No events»
 *     sólo tras una consulta válida vacía. Sin calcurse, el mes sigue funcionando.
 *   · Detalle de sólo lectura en el mismo panel; Back o Esc vuelven a la agenda.
 *     Se busca por identificador de OCURRENCIA: si desaparece, «Event no longer
 *     available», nunca otro que ocupe su índice.
 *
 * Teclado (spec, tabla «Navegación e interacción»):
 *   ← → día (cruza de mes)   ↑ ↓ semana      RePág AvPág mes    Inicio hoy
 *   Tab / ⇧Tab  cuadrícula ↔ agenda (en la agenda ↑ ↓ recorren eventos, ⏎ abre)
 *   Esc  del detalle a la agenda; desde la raíz, cierra
 * Detalle: ↑ ↓ / RePág AvPág desplazan la nota; Inicio/Fin van a sus extremos.
 * Ratón: clic en un día lo selecciona; « ‹ › » año y mes; la rueda cambia de mes.
 *
 * «Open calcurse» abre la herramienta como hacía el reloj de Waybar (la misma
 * orden: si ya está abierta, la cierra). No se promete ir al evento concreto.
 *
 * Eventos locales (2026-10-27, sólo en la UI amplia): **New event** (o N) abre el
 * formulario `CalendarEditor` para el día seleccionado; en el detalle de un evento
 * local, **Edit** (E) y **Delete** (Supr, con confirmación: Cancel enfocado). Las citas
 * de calcurse siguen en la lista, marcadas como tales y de sólo lectura. El borrador vive
 * en `CalendarEdit` (sobrevive a cerrar/mover la tarjeta); tras guardar se selecciona el
 * evento por su identidad cuando la agenda releída lo trae. Un fallo de una fuente se
 * dice en un aviso con Retry, nunca como «No events».
 *
 * 2026-10-28: las series locales enseñan su repetición y su aviso en el detalle; editar o
 * borrar una ocurrencia pregunta el alcance (sólo ésta, ésta y siguientes, toda la serie).
 * **Import / Export** (pie) abre `CalendarData` en la misma columna.
 *
 * Clima (7D, `services/Weather`, opt-in): el calendario lo RECLAMA mientras está
 * abierto (una lectura compartida con el Lock). Bajo la fecha, condición y
 * temperatura con la ciudad —y la antigüedad si el dato está vencido o falló la
 * última actualización—; si nunca hubo dato válido, la línea no ocupa sitio. En
 * la agenda, máxima, mínima y lluvia del día seleccionado sólo si hay pronóstico
 * para esa fecha (civil de la ciudad): un día pasado o lejano no enseña cifras.
 * La agenda no depende del clima ni el clima de la agenda.
 */
Surface {
    id: root
    property bool expanded: false
    property var initialContext: null
    readonly property bool splitLayout: root.expanded && root.width >= 720 * root.s
    readonly property bool previewOfUi: !root.expanded && root.open && !root.engaged && CalendarUi.open
    /** El formulario de un evento local ocupa la columna de la agenda (y la página entera si apila). */
    readonly property bool editing: root.expanded && CalendarEdit.editor !== null
    /** Import & export (2026-10-28): ocupa la columna como el formulario, que tiene prioridad. */
    readonly property bool transferring: root.expanded && CalendarTransfer.open && !root.editing
    /** Accounts & sync (CalDAV, 2026-10-28): también ocupa la columna; el formulario manda. */
    readonly property bool syncPanel: root.expanded && CalendarSync.open && !root.editing && !root.transferring
    readonly property bool panelOpen: root.editing || root.transferring || root.syncPanel
    onSyncPanelChanged: {
        if (root.syncPanel) { pageView.contentY = 0; Qt.callLater(function () { if (accountsLoader.item) accountsLoader.item.focusFirst(); }); }
        else if (!root.editing && !root.transferring && CalendarUi.layer && CalendarUi.layer.focusKeys) CalendarUi.layer.focusKeys();
    }
    onTransferringChanged: {
        if (root.transferring) { pageView.contentY = 0; Qt.callLater(function () { if (dataLoader.item) dataLoader.item.focusFirst(); }); }
        else if (!root.editing && !root.syncPanel && CalendarUi.layer && CalendarUi.layer.focusKeys) CalendarUi.layer.focusKeys();
    }
    /** Las opciones de la pregunta de borrado: Cancel primero; una serie da tres alcances. */
    readonly property var deleteOptions: CalendarEdit.deleting && CalendarEdit.deleting.recurring
        ? [{ label: "Cancel", scope: "" }, { label: "This event", scope: "occurrence" },
           { label: "This and following", scope: "following" }, { label: "All events", scope: "series" }]
        : [{ label: "Cancel", scope: "" }, { label: "Delete", scope: "series" }]
    function deleteActivate() {
        const o = root.deleteOptions[root.deleteIndex];
        if (!o || o.scope === "") CalendarEdit.cancelDelete();
        else CalendarEdit.confirmDelete(o.scope);
    }
    readonly property bool confirmingDelete: root.expanded && CalendarEdit.deleting !== null && root.detail !== null
        && root.detail.uuid === CalendarEdit.deleting.uuid
    property int deleteIndex: 0
    onConfirmingDeleteChanged: {
        root.deleteIndex = 0;
        if (root.confirmingDelete && detailView) { detailView.contentY = 0; Qt.callLater(root.revealDelete); }
    }
    /** La pregunta de borrado, entera a la vista aunque la página esté desplazada (pantalla baja). */
    function revealDelete() {
        if (!root.confirmingDelete || !deleteBox) return;
        const p = deleteBox.mapToItem(col, 0, 0);
        if (p.y < pageView.contentY) pageView.contentY = Math.max(0, p.y - 8 * root.s);
        else if (p.y + deleteBox.height > pageView.contentY + pageView.height)
            pageView.contentY = Math.min(Math.max(0, pageView.contentHeight - pageView.height), p.y + deleteBox.height + 8 * root.s - pageView.height);
    }
    onEditingChanged: {
        if (root.editing) { pageView.contentY = 0; Qt.callLater(function () { if (root.editorView) root.editorView.focusFirst(); }); }
        else if (CalendarUi.layer && CalendarUi.layer.focusKeys) CalendarUi.layer.focusKeys();
    }
    /** El evento recién guardado: se abre su detalle cuando la agenda releída ya lo trae. */
    property string pendingDetail: ""
    /** Sin binding (cambiar `pendingDetail` dentro de su propio aviso sería un bucle): al llegar datos. */
    function tryPending() {
        if (root.pendingDetail.length === 0 || !root.agendaFresh || Agenda.find(root.pendingDetail) === null) return;
        const id = root.pendingDetail;
        root.pendingDetail = "";
        root.agendaId = id;
        root.detailId = id;
        root.zone = "agenda";
    }
    Connections {
        target: Agenda
        function onItemsChanged() { Qt.callLater(root.tryPending); }
        function onFromChanged() { Qt.callLater(root.tryPending); }
    }
    function applyLanding() {
        const l = CalendarEdit.landing;
        if (!root.expanded || !root.open || !l) return;
        CalendarEdit.landing = null;
        const p = l.date.split("-");
        root.detailId = "";
        root.selectDate(new Date(Number(p[0]), Number(p[1]) - 1, Number(p[2])), true);
        root.zone = "agenda";
        root.agendaId = l.id;
        root.pendingDetail = l.id;
        Qt.callLater(root.tryPending);
    }
    Connections {
        target: CalendarEdit
        function onLandingChanged() { if (CalendarEdit.landing) Qt.callLater(root.applyLanding); }
        function onDeleted(uuid) {
            if (root.detailId.indexOf("local:" + uuid + "@") === 0) root.closeDetail();
            if (root.agendaId.indexOf("local:" + uuid + "@") === 0) root.agendaId = "";
        }
    }
    function newEvent() {
        if (!root.expanded || !Agenda.localWritable) return false;
        root.detailId = "";
        return CalendarEdit.startCreate(root.iso(root.sel), root.today, Agenda.displayTz);
    }
    function editDetail() { return root.expanded && root.detail !== null && root.detail.editable === true && CalendarEdit.startEdit(root.detail); }
    function askDeleteDetail() {
        if (!root.expanded || root.detail === null || root.detail.editable !== true) return false;
        return CalendarEdit.askDelete(root.detail, root.whenLabel(root.detail));
    }
    function whenLabel(d) {
        if (!d) return "";
        const ev = d.event;
        if (ev && ev.allDay) return ev.startDate === ev.lastDate ? root.dayLabel(ev.startDate) + " · All day"
            : root.dayLabel(ev.startDate) + " – " + root.dayLabel(ev.lastDate) + " · All day";
        return root.dayLabel(d.date) + " · " + root.timeLabel(d);
    }
    function syncLabel(st) {
        return st === "new" || st === "dirty" ? " · waiting to upload" : st === "conflict" ? " · conflict" : " · synced";
    }
    function dayLabel(iso) {
        const p = String(iso).split("-");
        return root.loc.toString(new Date(Number(p[0]), Number(p[1]) - 1, Number(p[2])), "ddd d MMM yyyy");
    }
    function expandCalendar() { return CalendarUi.show(root.screenName, root.saveContext()); }
    mTop: 12
    mBottom: 12

    implicitHeight: col.implicitHeight + footer.height + 8 * root.s
    property var selectedDayItem: null
    function revealFocus() {
        const item = root.detailId.length > 0 || root.zone === "agenda" ? agendaBox : root.selectedDayItem;
        if (!item || !root.open) return;
        const p = item.mapToItem(col, 0, 0);
        if (p.y < pageView.contentY) pageView.contentY = Math.max(0, p.y);
        else if (p.y + item.height > pageView.contentY + pageView.height)
            pageView.contentY = Math.min(Math.max(0, pageView.contentHeight - pageView.height), p.y + item.height - pageView.height);
    }
    onZoneChanged: Qt.callLater(root.revealFocus)
    onDetailIdChanged: { if (detailView) detailView.contentY = 0; Qt.callLater(root.revealFocus); }
    onHeightChanged: Qt.callLater(root.revealFocus)
    readonly property string agendaScene: root.iso(root.sel) + "|" + root.detailId
    onAgendaSceneChanged: if (root.open && !root.opening && agendaBox) agendaBox.enter(1)

    readonly property date today: Clock.now
    /** El día seleccionado (a medianoche). */
    property date sel: new Date()
    /** El mes que enseña la cuadrícula: año y mes (0-11). */
    property int viewYear: 2026
    property int viewMonth: 0
    /** "grid" o "agenda": a qué van las flechas. */
    property string zone: "grid"
    /** El evento con el cursor de la agenda, por id de ocurrencia. */
    property string agendaId: ""
    /** El detalle abierto ("" = la agenda). */
    property string detailId: ""
    property real agendaScroll: 0

    readonly property var loc: Qt.locale()
    /**
     * 0 = domingo. La rejilla empieza por el primer día de la semana local, o por el que se
     * eligió en Settings → Shell → Calendar (9C-2).
     */
    readonly property int firstDow: Settings.calendarFirstDay === "monday" ? 1
        : Settings.calendarFirstDay === "sunday" ? 0 : root.loc.firstDayOfWeek

    function midnight(d) { return new Date(d.getFullYear(), d.getMonth(), d.getDate()); }
    function pad(n) { return (n < 10 ? "0" : "") + n; }
    function iso(d) { return d.getFullYear() + "-" + root.pad(d.getMonth() + 1) + "-" + root.pad(d.getDate()); }
    function sameDay(a, b) {
        return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
    }

    /** Abrir por acceso directo: hoy, en la cuadrícula (Back/Forward restauran después). */
    property bool opening: true
    onOpenChanged: { root.opening = true; if (open) Qt.callLater(root.beginVisit); }
    function beginVisit() {
        if (!root.open) return;
        root.opening = true;   // el cambio de mes de aquí no consulta: consulta `load(true)`, una vez
        root.selectDate(root.midnight(root.today), true);
        root.zone = "grid";
        root.detailId = "";
        root.agendaId = "";
        root.agendaScroll = 0;
        if (root.expanded && root.initialContext) root.restoreContext(root.initialContext);
        else if (root.previewOfUi && CalendarUi.layer && CalendarUi.layer.contentItem())
            root.restoreContext(CalendarUi.layer.contentItem().saveContext());
        root.opening = false;
        root.load(true);   // calcurse pudo cambiar mientras estaba cerrado
        if (CalendarEdit.landing) root.applyLanding();
        Qt.callLater(root.revealFocus);
    }

    /** Selecciona `d`; con `follow`, el mes visible pasa a ser el suyo. */
    function selectDate(d, follow) {
        root.sel = root.midnight(d);
        if (follow || !root.cellsHave(root.sel)) {
            root.viewYear = root.sel.getFullYear();
            root.viewMonth = root.sel.getMonth();
        }
        root.agendaId = "";
    }

    /** Mes/año ± n: la selección va al mismo número de día (o al último que exista). */
    function shiftMonths(n) {
        const first = new Date(root.viewYear, root.viewMonth + n, 1);
        const last = new Date(first.getFullYear(), first.getMonth() + 1, 0).getDate();
        root.viewYear = first.getFullYear();
        root.viewMonth = first.getMonth();
        root.sel = new Date(first.getFullYear(), first.getMonth(), Math.min(root.sel.getDate(), last));
        root.agendaId = "";
        root.detailId = "";
    }
    function moveDays(n) {
        root.selectDate(new Date(root.sel.getFullYear(), root.sel.getMonth(), root.sel.getDate() + n), false);
        // Al cruzar el borde del mes, el mes visible sigue a la selección.
        if (root.sel.getMonth() !== root.viewMonth || root.sel.getFullYear() !== root.viewYear) {
            root.viewYear = root.sel.getFullYear();
            root.viewMonth = root.sel.getMonth();
        }
    }
    function goToday() {
        root.selectDate(root.midnight(root.today), true);
        root.detailId = "";
    }

    /** Semana ISO 8601: la que contiene el jueves. */
    function isoWeek(d) {
        const t = new Date(d.getFullYear(), d.getMonth(), d.getDate());
        t.setDate(t.getDate() + 3 - ((t.getDay() + 6) % 7));
        const week1 = new Date(t.getFullYear(), 0, 4);
        return 1 + Math.round(((t - week1) / 86400000 - 3 + ((week1.getDay() + 6) % 7)) / 7);
    }

    /** El primer día de la cuadrícula del mes visible. */
    readonly property date gridStart: {
        const first = new Date(root.viewYear, root.viewMonth, 1);
        const back = (first.getDay() - root.firstDow + 7) % 7;
        return new Date(root.viewYear, root.viewMonth, 1 - back);
    }

    /**
     * 42 celdas (6 semanas x 7 dias), que es lo que hace falta para que
     * cualquier mes quepa sin que la rejilla cambie de alto al navegar.
     */
    readonly property var cells: {
        const out = [];
        const s0 = root.gridStart;
        for (let i = 0; i < 42; i++) {
            const d = new Date(s0.getFullYear(), s0.getMonth(), s0.getDate() + i);
            out.push({
                date: d,
                key: root.iso(d),
                day: d.getDate(),
                inMonth: d.getMonth() === root.viewMonth,
                isToday: root.sameDay(d, root.today),
                week: root.isoWeek(d),
                dowReal: d.getDay()      // 0 = domingo, 4 = jueves
            });
        }
        return out;
    }
    function cellsHave(d) {
        const k = root.iso(d);
        for (let i = 0; i < root.cells.length; i++)
            if (root.cells[i].key === k) return true;
        return false;
    }

    /** Cabeceras de dia, respetando el primer dia de la semana local. */
    readonly property var dowNames: {
        const out = [];
        for (let i = 0; i < 7; i++) {
            const d = new Date(2024, 0, 7 + ((root.firstDow + i) % 7));   // 2024-01-07 fue domingo
            out.push(root.loc.toString(d, "ddd").substring(0, 2).toUpperCase());
        }
        return out;
    }

    /**
     * Numero de semana de una fila: la de su JUEVES (en un locale que empieza en
     * domingo, la del primer dia daba la anterior; contrastado con `cal` en 9.d).
     */
    function weekOfRow(r) {
        const base = r * 7;
        for (let i = 0; i < 7; i++) {
            const c = root.cells[base + i];
            if (c && c.dowReal === 4) return c.week;
        }
        const f = root.cells[base];
        return f ? f.week : "";
    }

    // ---- la agenda -----------------------------------------------------------------

    /** Consulta el rango visible (una vez por rango; `force` al abrir y en Retry). */
    function load(force) { if (!root.previewOfUi) Agenda.request(root.iso(root.gridStart), 42, force === true); }
    // 2026-11-11: el mes que entra lo hace desde el lado hacia el que se navega (en la ventana)
    property real shownGridStart: 0
    onGridStartChanged: {
        const t = +root.gridStart, dir = t >= root.shownGridStart ? 1 : -1;
        root.shownGridStart = t;
        if (root.open && !root.opening) { root.load(false); if (gridFrame) gridFrame.enter(dir); }
    }

    /** El rango cargado es el visible: si no, lo que hay en `Agenda.items` es de otro mes. */
    readonly property bool agendaFresh: Agenda.state === "ready" && Agenda.from === root.iso(root.gridStart)
    readonly property var dayItems: root.agendaFresh ? Agenda.on(root.iso(root.sel)) : []
    readonly property var detail: root.detailId.length > 0 ? Agenda.find(root.detailId) : null

    function agendaIndex() {
        for (let i = 0; i < root.dayItems.length; i++)
            if (root.dayItems[i].id === root.agendaId) return i;
        return -1;
    }
    function moveAgenda(delta) {
        const n = root.dayItems.length;
        if (n === 0) return;
        const i = Math.max(0, Math.min(n - 1, root.agendaIndex() + delta));
        root.agendaId = root.dayItems[i].id;
        agendaList.positionViewAtIndex(i, ListView.Contain);
    }
    function openDetail(id) {
        root.agendaScroll = agendaList.contentY;
        root.agendaId = id;
        root.detailId = id;
    }
    function closeDetail() {
        root.detailId = "";
        Qt.callLater(function () { agendaList.contentY = root.agendaScroll; });
    }

    function timeLabel(it) {
        if (!it) return "";
        if (it.allDay) return "All day";
        if (it.start === "..:.." && it.end === "..:..") return "All day (continues)";
        if (it.start === "..:..") return "→ " + it.end;
        if (it.end === "..:..") return it.start + " →";
        return it.start === it.end ? it.start : it.start + "–" + it.end;
    }
    function durationLabel(sec) {
        if (!sec || sec <= 0) return "";
        const h = Math.floor(sec / 3600), m = Math.round((sec % 3600) / 60);
        return h > 0 ? h + " h" + (m > 0 ? " " + m + " min" : "") : m + " min";
    }

    /**
     * Abrir o cerrar calcurse (era el `on-click` del módulo `clock` de Waybar). F2d: sin calcurse o sin
     * terminal, el botón lo dice y no hace nada. F3b: en la terminal del usuario, sin `sh -c`; el
     * conmutador vive en `Apps.toggleCalcurse` (scope de nombre fijo).
     */
    readonly property string calcurseWhy: Capabilities.whyFirst(["agenda.calcurse", "apps.terminal"])
    function toggleCalcurse() {
        if (root.calcurseWhy.length > 0) return;
        Apps.toggleCalcurse();
        root.requestClose();
    }

    function keyPressed(event) {
        const k = event.key;
        if (!root.expanded && k === Qt.Key_O) { root.expandCalendar(); event.accepted = true; return; }
        // El formulario: sus campos tienen su propio teclado; esto es lo que llega sin foco en ellos.
        if (root.editing) {
            const ctrl = (event.modifiers & Qt.ControlModifier) !== 0;
            if (CalendarEdit.editor.confirm === "scope") {
                if (k === Qt.Key_Left || k === Qt.Key_Right || k === Qt.Key_Tab || k === Qt.Key_Backtab)
                    root.editorView.scopeStep(k === Qt.Key_Right || k === Qt.Key_Tab ? 1 : -1);
                else if (k === Qt.Key_Return || k === Qt.Key_Enter) root.editorView.scopeActivate();
                else if (k === Qt.Key_Escape) CalendarEdit.keepEditing();
            } else if (CalendarEdit.editor.confirm === "discard") {
                if (k === Qt.Key_Left || k === Qt.Key_Right || k === Qt.Key_Tab || k === Qt.Key_Backtab) root.editorView.confirmIndex = 1 - root.editorView.confirmIndex;
                else if (k === Qt.Key_Return || k === Qt.Key_Enter) { if (root.editorView.confirmIndex === 1) CalendarEdit.discard(); else CalendarEdit.keepEditing(); }
                else if (k === Qt.Key_Escape) CalendarEdit.keepEditing();
            } else if (k === Qt.Key_Escape) CalendarEdit.requestClose();
            else if (ctrl && (k === Qt.Key_S || k === Qt.Key_Return || k === Qt.Key_Enter)) CalendarEdit.save();
            else if (k === Qt.Key_Tab || k === Qt.Key_Backtab) root.editorView.focusFirst();
            else return;
            event.accepted = true;
            return;
        }
        // Confirmar el borrado: Cancel primero; ← → / Tab cambian, Intro elige, Esc cancela.
        if (root.confirmingDelete) {
            const nd = root.deleteOptions.length;
            if (k === Qt.Key_Left || k === Qt.Key_Right || k === Qt.Key_Tab || k === Qt.Key_Backtab)
                root.deleteIndex = (root.deleteIndex + (k === Qt.Key_Right || k === Qt.Key_Tab ? 1 : nd - 1)) % nd;
            else if (k === Qt.Key_Return || k === Qt.Key_Enter) root.deleteActivate();
            else if (k === Qt.Key_Escape || k === Qt.Key_Backspace) CalendarEdit.cancelDelete();
            event.accepted = true;
            return;
        }
        if (root.syncPanel) {
            if (k === Qt.Key_Escape || k === Qt.Key_Backspace) CalendarSync.close();
            else if (k === Qt.Key_R && !CalendarSync.syncing) CalendarSync.sync("");
            else if (k === Qt.Key_Tab || k === Qt.Key_Backtab) { if (accountsLoader.item) accountsLoader.item.focusFirst(); }
            else return;
            event.accepted = true;
            return;
        }
        if (root.transferring) {
            if (k === Qt.Key_Escape || k === Qt.Key_Backspace) CalendarTransfer.close();
            else if (k === Qt.Key_Tab || k === Qt.Key_Backtab) { if (dataLoader.item) dataLoader.item.focusFirst(); }
            else return;
            event.accepted = true;
            return;
        }
        if (root.expanded && k === Qt.Key_N && root.detailId.length === 0) { root.newEvent(); event.accepted = true; return; }
        if (root.detailId.length > 0) {
            if (k === Qt.Key_E && root.detail !== null && root.detail.editable === true) { root.editDetail(); event.accepted = true; }
            else if (k === Qt.Key_Delete && root.detail !== null && root.detail.editable === true) { root.askDeleteDetail(); event.accepted = true; }
            else if (k === Qt.Key_Escape || k === Qt.Key_Backspace) { root.closeDetail(); event.accepted = true; }
            else {
                const max = Math.max(0, detailView.contentHeight - detailView.height);
                if (k === Qt.Key_Down || k === Qt.Key_Up)
                    detailView.contentY = Math.max(0, Math.min(max, detailView.contentY + (k === Qt.Key_Down ? 36 : -36) * root.s));
                else if (k === Qt.Key_PageDown || k === Qt.Key_PageUp)
                    detailView.contentY = Math.max(0, Math.min(max, detailView.contentY + (k === Qt.Key_PageDown ? 1 : -1) * detailView.height * 0.8));
                else if (k === Qt.Key_Home || k === Qt.Key_End) detailView.contentY = k === Qt.Key_Home ? 0 : max;
                else return;
                event.accepted = true;
            }
            return;
        }
        if (k === Qt.Key_Tab || k === Qt.Key_Backtab) {
            root.zone = root.zone === "grid" && root.dayItems.length > 0 ? "agenda" : "grid";
            if (root.zone === "agenda" && root.agendaIndex() < 0) root.agendaId = root.dayItems[0].id;
            event.accepted = true;
        } else if (k === Qt.Key_PageUp)   { root.shiftMonths(-1); event.accepted = true; }
        else if (k === Qt.Key_PageDown)   { root.shiftMonths(1); event.accepted = true; }
        else if (k === Qt.Key_Home)       { root.goToday(); root.zone = "grid"; event.accepted = true; }
        else if (root.zone === "agenda") {
            if (k === Qt.Key_Up)        { root.moveAgenda(-1); event.accepted = true; }
            else if (k === Qt.Key_Down) { root.moveAgenda(1); event.accepted = true; }
            else if (k === Qt.Key_Return || k === Qt.Key_Enter) {
                if (root.agendaIndex() >= 0) root.openDetail(root.agendaId);
                event.accepted = true;
            } else if (k === Qt.Key_Left || k === Qt.Key_Right) { root.zone = "grid"; event.accepted = true; }
        } else {
            if (k === Qt.Key_Left)       { root.moveDays(-1); event.accepted = true; }
            else if (k === Qt.Key_Right) { root.moveDays(1); event.accepted = true; }
            else if (k === Qt.Key_Up)    { root.moveDays(-7); event.accepted = true; }
            else if (k === Qt.Key_Down)  { root.moveDays(7); event.accepted = true; }
        }
    }

    // ---- historial (fase 4): fecha, evento y scroll; nunca relanza nada ----
    function saveContext() {
        return { sel: root.iso(root.sel), view: root.viewYear + "-" + root.pad(root.viewMonth + 1),
                 agendaId: root.agendaId, detailId: root.detailId, zone: root.zone, pageScroll: pageView.contentY, noteScroll: detailView.contentY,
                 scroll: root.detailId.length > 0 ? root.agendaScroll : agendaList.contentY };
    }
    function restoreContext(ctx) {
        if (!ctx || !ctx.sel) return true;
        const p = ctx.sel.split("-"), v = String(ctx.view || ctx.sel).split("-");
        root.sel = new Date(Number(p[0]), Number(p[1]) - 1, Number(p[2]));
        root.viewYear = Number(v[0]);
        root.viewMonth = Number(v[1]) - 1;
        root.agendaId = ctx.agendaId || "";
        root.agendaScroll = ctx.scroll || 0;
        root.detailId = ctx.detailId || "";
        root.zone = ctx.zone === "agenda" ? "agenda" : "grid";
        Qt.callLater(function () { pageView.contentY = Math.max(0, Math.min(ctx.pageScroll || 0, pageView.contentHeight - pageView.height)); });
        if (root.detailId.length === 0) Qt.callLater(function () { agendaList.contentY = root.agendaScroll; });
        else Qt.callLater(function () { detailView.contentY = Math.max(0, Math.min(ctx.noteScroll || 0, detailView.contentHeight - detailView.height)); });
        return true;
    }

    /** Para las pruebas (IPC `calendarState`): lo que enseña, sin tocar nada. */
    function stateJson() {
        return JSON.stringify({ sel: root.iso(root.sel), view: root.viewYear + "-" + root.pad(root.viewMonth + 1),
                                gridStart: root.iso(root.gridStart), zone: root.zone, agendaId: root.agendaId,
                                detailId: root.detailId, detailFound: root.detail !== null,
                                fresh: root.agendaFresh, day: root.dayItems.map(function (it) {
                                    return root.timeLabel(it) + " " + it.message + (it.recurring ? " (r)" : "");
                                }), agenda: Agenda.summary(), editing: root.editing, confirmingDelete: root.confirmingDelete,
                                deleteIndex: root.deleteIndex, deleteOptions: root.deleteOptions.map(o => o.label), pendingDetail: root.pendingDetail,
                                transferring: root.transferring, transfer: CalendarTransfer.summary(), reminders: CalendarReminders.summary(),
                                syncPanel: root.syncPanel, sync: CalendarSync.summary(),
                                confirmIndex: root.editorView ? root.editorView.confirmIndex : 0, edit: CalendarEdit.summary(),
                                weather: { shown: root.weatherShown, forecast: root.dayForecast, state: Weather.state } });
    }

    // ---- clima -------------------------------------------------------------------------

    Claim { target: Weather; method: "claim"; key: (root.expanded ? "calendar-ui@" : "calendar@") + root.screenName; value: root.active && !root.previewOfUi }
    readonly property bool weatherShown: Weather.configured && Weather.hasData
    readonly property var weatherNow: root.weatherShown ? Weather.data.current : null
    readonly property var dayForecast: { void Weather.data; return Weather.forecast(root.iso(root.sel)); }

    Flickable {
        id: pageView
        anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right
        anchors.bottom: footer.top; anchors.bottomMargin: 8 * root.s
        contentWidth: width; contentHeight: col.implicitHeight
        clip: true; boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height + 1
        onHeightChanged: Qt.callLater(root.revealFocus)

    Item {
        id: col
        width: pageView.width
        implicitHeight: root.splitLayout ? Math.max(monthColumn.implicitHeight, agendaBox.height)
            : root.panelOpen ? agendaBox.height
            : monthColumn.implicitHeight + 17 * root.s + agendaBox.height
        height: implicitHeight

        Column {
            id: monthColumn
            width: root.splitLayout ? Math.min(390 * root.s, (col.width - 24 * root.s) * 0.46) : col.width
            visible: root.splitLayout || !root.panelOpen
            spacing: 8 * root.s

        // ---- reloj y fecha (el reloj compartido) ----
        Column {
            width: parent.width
            spacing: 0
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: Clock.time
                color: Theme.fg
                font.family: Typography.ui
                font.pixelSize: 1.6 * Typography.display * root.s
                font.weight: Font.DemiBold
                font.features: ({ "tnum": 1 })
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                width: parent.width; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
                text: root.loc.toString(root.today, "dddd · d MMM yyyy")
                color: Theme.fgVariant
                font.family: Typography.ui
                font.pixelSize: Typography.body * root.s
            }
            // El clima de ahora: sin dato válido nunca, no ocupa sitio (spec).
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                width: parent.width
                visible: root.weatherShown
                spacing: 5 * root.s
                topPadding: 2 * root.s
                readonly property var cond: Weather.condition(root.weatherNow ? root.weatherNow.code : null,
                                                              root.today.getHours() < 6 || root.today.getHours() >= 20)
                Icon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: parent.cond.icon
                    size: 13 * root.s
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - 22 * root.s; wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight
                    text: (root.weatherNow ? Weather.temp(root.weatherNow.temp) : "") + "  " + parent.cond.text
                          + "  ·  " + (Weather.location ? Weather.location.name : "")
                          + (Weather.state === "stale" ? "  ·  " + Weather.ageText() : "")
                    color: Weather.state === "stale" ? Theme.outlineText : Theme.fgVariant
                    font.family: Typography.ui
                    font.pixelSize: Typography.caption * root.s
                }
            }
        }

        Rectangle { width: parent.width; height: 1; color: Theme.hair }

        // ---- el mes y su navegación ----
        Item {
            width: parent.width
            height: 34 * root.s
            MouseArea { anchors.fill: parent; acceptedButtons: Qt.NoButton; onWheel: wheel => root.shiftMonths(wheel.angleDelta.y > 0 ? -1 : 1) }

            Row {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                Nav { glyph: "«"; label: "Previous year"; onActivated: root.shiftMonths(-12) }
                Nav { glyph: "‹"; label: "Previous month"; onActivated: root.shiftMonths(-1) }
            }
            Text {
                anchors.centerIn: parent
                width: parent.width - 136 * root.s; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
                text: root.loc.toString(new Date(root.viewYear, root.viewMonth, 1), "MMMM yyyy")
                color: Theme.fg
                font.family: Typography.ui
                font.pixelSize: Typography.title * root.s
                font.weight: Font.DemiBold
            }
            Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                Nav { glyph: "›"; label: "Next month"; onActivated: root.shiftMonths(1) }
                Nav { glyph: "»"; label: "Next year"; onActivated: root.shiftMonths(12) }
            }
        }

        Item {
            id: gridFrame
            width: parent.width; height: gridCol.implicitHeight
            property real enterOpacity: 1
            property real enterOffset: 0
            opacity: enterOpacity
            transform: Translate { x: gridFrame.enterOffset }
            function enter(dir) {
                const interrupted = gridFrameEnter.running;
                gridFrameEnter.stop();
                // En la ventana (2026-11-11): según la dirección y con los números del estilo; en el island, como siempre.
                const styled = root.expanded && !Motion.still;
                const fade = styled ? Motion.pageFadeFrom : 0.75;
                const shift = (styled ? Motion.pageShift : 8) * root.s;
                enterOpacity = Motion.off ? 1 : interrupted ? Math.max(fade, enterOpacity) : fade;
                enterOffset = Motion.still ? 0 : interrupted ? Math.max(-shift, Math.min(shift, enterOffset))
                    : (root.expanded ? (dir || 1) : 1) * shift;
                gridFrameEnter.start();
            }
            Connections { target: Motion; function onModeChanged() { gridFrameEnter.stop(); gridFrame.enterOpacity = 1; gridFrame.enterOffset = 0; } }
            ParallelAnimation {
                id: gridFrameEnter
                NumberAnimation { target: gridFrame; property: "enterOpacity"; to: 1; duration: root.expanded && !Motion.still ? Motion.pageMs : Motion.page; easing.type: Easing.OutCubic }
                NumberAnimation { target: gridFrame; property: "enterOffset"; to: 0; duration: Motion.still ? 0 : (root.expanded ? Motion.pageMs : Motion.page); easing.type: Easing.OutCubic }
            }
            Column {
                id: gridCol
                width: parent.width; spacing: 6 * root.s
        /** Cabecera de dias + columna de semana. */
        Row {
            width: parent.width
            Repeater {
                model: root.dowNames
                Text {
                    required property var modelData
                    width: (monthColumn.width - root.weekColW) / 7
                    horizontalAlignment: Text.AlignHCenter
                    text: modelData
                    color: Theme.fgVariant
                    opacity: 0.7
                    font.family: Typography.ui
                    font.pixelSize: Typography.caption * root.s
                    font.weight: Font.DemiBold
                    font.letterSpacing: 0.6 * root.s
                }
            }
            Text {
                width: root.weekColW
                horizontalAlignment: Text.AlignHCenter
                text: "WK"
                // 2026-10-01: antes fgVariant al 45 % (≈2:1 en claro, ilegible); `outlineText` ya es
                // secundario y llega a 4,5:1
                color: Theme.outlineText
                font.family: Typography.ui
                font.pixelSize: Typography.caption * root.s
            }
        }

        /** Seis semanas. La columna de numeros va a la DERECHA, como en Waybar. */
        Repeater {
            model: 6

            Item {
                id: weekRow
                required property int index
                width: monthColumn.width
                // 30: el punto de «tiene algo» queda bajo el contorno de selección, no tapado.
                height: 40 * root.s
                readonly property bool thisWeek: {
                    for (let i = 0; i < 7; i++) {
                        const c = root.cells[weekRow.index * 7 + i];
                        if (c && c.isToday) return true;
                    }
                    return false;
                }

                // La semana de hoy: un fondo tenue que no compite con hoy ni con la selección.
                Rectangle {
                    visible: weekRow.thisWeek
                    width: parent.width - root.weekColW
                    height: parent.height
                    radius: Metrics.rSm * root.s
                    color: Qt.alpha(Theme.primary, 0.07)
                }

                Row {
                    Repeater {
                        model: 7

                        Item {
                            id: dayCell
                            required property int index
                            // Por id, NO por cadena de padres (9.d: `parent.parent.index` era undefined).
                            readonly property var cell: root.cells[weekRow.index * 7 + dayCell.index]
                            readonly property bool isSel: dayCell.cell !== undefined && root.sameDay(dayCell.cell.date, root.sel)
                            function followSelection() { if (dayCell.isSel) { root.selectedDayItem = dayCell; Qt.callLater(root.revealFocus); } }
                            onIsSelChanged: followSelection()
                            Component.onCompleted: followSelection()
                            readonly property int count: (root.agendaFresh && dayCell.cell) ? (Agenda.counts[dayCell.cell.key] || 0) : 0
                            // 16A-2
                            Accessible.role: Accessible.Cell
                            Accessible.name: dayCell.cell ? Qt.formatDate(dayCell.cell.date, "dddd d MMMM yyyy") : ""
                            Accessible.description: dayCell.count > 0 ? dayCell.count + (dayCell.count === 1 ? " event" : " events") : ""
                            Accessible.selected: dayCell.isSel
                            Accessible.onPressAction: if (dayCell.cell) { root.zone = "grid"; root.detailId = ""; root.selectDate(dayCell.cell.date, false); }
                            width: (monthColumn.width - root.weekColW) / 7
                            height: weekRow.height

                            // Hoy: marca sólida.
                            Rectangle {
                                visible: dayCell.cell !== undefined && dayCell.cell.isToday
                                anchors.centerIn: parent
                                anchors.verticalCenterOffset: -6 * root.s
                                width: 30 * root.s
                                height: 26 * root.s
                                radius: Metrics.r(7) * root.s
                                color: Theme.primary
                                // hoy seleccionado: el contorno va EN la marca, no en otra caja alrededor
                                // (2026-10-01: semana, marca y contorno eran tres cajas una dentro de otra)
                                border.width: dayCell.isSel ? Metrics.focusWidth * (root.zone === "grid" ? 1.4 : 1) * root.s : 0
                                border.color: root.zone === "grid" ? Theme.fg : Qt.alpha(Theme.fg, 0.55)
                            }
                            // Seleccionado: contorno (sobre hoy lo lleva la marca).
                            Rectangle {
                                visible: dayCell.isSel && !(dayCell.cell !== undefined && dayCell.cell.isToday)
                                anchors.centerIn: parent
                                anchors.verticalCenterOffset: -6 * root.s
                                width: 30 * root.s
                                height: 26 * root.s
                                radius: Metrics.r(9) * root.s
                                color: "transparent"
                                border.width: Metrics.focusWidth * (root.zone === "grid" ? 1.4 : 1)
                                border.color: root.zone === "grid" ? Theme.primary : Qt.alpha(Theme.primary, 0.55)
                            }

                            Text {
                                anchors.centerIn: parent
                                anchors.verticalCenterOffset: -6 * root.s
                                text: dayCell.cell ? dayCell.cell.day : ""
                                color: (dayCell.cell && dayCell.cell.isToday) ? Theme.fgOnPrimary
                                     : ((dayCell.cell && dayCell.cell.inMonth) ? Theme.fg : Theme.fgVariant)
                                opacity: (dayCell.cell && dayCell.cell.inMonth) || dayCell.isSel ? 1 : 0.4
                                font.family: Typography.ui
                                font.pixelSize: Typography.body * root.s
                                font.weight: (dayCell.cell && dayCell.cell.isToday) ? Font.DemiBold : Font.Normal
                                font.features: ({ "tnum": 1 })
                            }

                            // Tiene algo: un punto; dos o más, el número (forma y texto, no sólo color).
                            Rectangle {
                                visible: dayCell.count === 1
                                anchors.horizontalCenter: parent.horizontalCenter
                                anchors.bottom: parent.bottom
                                anchors.bottomMargin: 0
                                width: 4 * root.s
                                height: width
                                radius: Metrics.pill(width)
                                color: Theme.fgVariant
                            }
                            Text {
                                visible: dayCell.count > 1
                                anchors.horizontalCenter: parent.horizontalCenter
                                anchors.bottom: parent.bottom
                                anchors.bottomMargin: 0
                                text: dayCell.count
                                color: Theme.fgVariant
                                font.family: Typography.ui
                                font.pixelSize: Typography.caption * root.s
                                font.weight: Font.DemiBold
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onWheel: wheel => root.shiftMonths(wheel.angleDelta.y > 0 ? -1 : 1)
                                onClicked: {
                                    root.zone = "grid";
                                    root.detailId = "";
                                    root.selectDate(dayCell.cell.date, false);
                                }
                            }
                        }
                    }

                    Text {
                        width: root.weekColW
                        height: weekRow.height
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        text: root.weekOfRow(weekRow.index)
                        color: Theme.outlineText   // ver «WK»
                        font.family: Typography.ui
                        font.pixelSize: Typography.caption * root.s
                        font.features: ({ "tnum": 1 })
                    }
                }
            }
        }

            }
        }

        }
        Rectangle {
            visible: root.splitLayout || !root.panelOpen
            x: root.splitLayout ? monthColumn.width + 12 * root.s : 0
            y: root.splitLayout ? 0 : monthColumn.height + 8 * root.s
            width: root.splitLayout ? 1 : col.width
            height: root.splitLayout ? col.height : 1
            color: Theme.hair
        }

        // ---- la agenda del día (o el detalle): altura FIJA, scroll por dentro ----
        Item {
            id: agendaBox
            x: root.splitLayout ? monthColumn.width + 24 * root.s : 0
            y: root.splitLayout || root.panelOpen ? 0 : monthColumn.height + 17 * root.s
            width: col.width - x
            // Editando, el formulario mide lo visible: su pie (Save) nunca queda bajo el borde.
            height: root.splitLayout && !root.panelOpen ? Math.max(monthColumn.implicitHeight, pageView.height)
                : root.panelOpen ? pageView.height
                : root.expanded ? Math.max(160 * root.s, Math.min(340 * root.s, pageView.height)) : 220 * root.s
            property real enterOpacity: 1
            property real enterOffset: 0
            opacity: enterOpacity
            transform: Translate { y: agendaBox.enterOffset }
            function enter(dir) {
                const interrupted = agendaBoxEnter.running;
                agendaBoxEnter.stop();
                // En la ventana (2026-11-11): según la dirección y con los números del estilo; en el island, como siempre.
                const styled = root.expanded && !Motion.still;
                const fade = styled ? Motion.pageFadeFrom : 0.75;
                const shift = (styled ? Motion.pageShift : 8) * root.s;
                enterOpacity = Motion.off ? 1 : interrupted ? Math.max(fade, enterOpacity) : fade;
                enterOffset = Motion.still ? 0 : interrupted ? Math.max(-shift, Math.min(shift, enterOffset))
                    : (root.expanded ? (dir || 1) : 1) * shift;
                agendaBoxEnter.start();
            }
            Connections { target: Motion; function onModeChanged() { agendaBoxEnter.stop(); agendaBox.enterOpacity = 1; agendaBox.enterOffset = 0; } }
            ParallelAnimation {
                id: agendaBoxEnter
                NumberAnimation { target: agendaBox; property: "enterOpacity"; to: 1; duration: root.expanded && !Motion.still ? Motion.pageMs : Motion.page; easing.type: Easing.OutCubic }
                NumberAnimation { target: agendaBox; property: "enterOffset"; to: 0; duration: Motion.still ? 0 : (root.expanded ? Motion.pageMs : Motion.page); easing.type: Easing.OutCubic }
            }


            // Cabecera: el día y cuántos.
            Item {
                id: agendaHead
                width: parent.width
                height: 34 * root.s
                visible: root.detailId.length === 0 && !root.panelOpen

                Text {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.right: todayLink.visible ? todayLink.left : newButton.visible ? newButton.left : parent.right
                    anchors.rightMargin: todayLink.visible || newButton.visible ? 10 * root.s : 0
                    elide: Text.ElideRight
                    text: root.loc.toString(root.sel, "dddd d")
                          + (root.agendaFresh ? "  ·  " + root.dayItems.length + (root.dayItems.length === 1 ? " event" : " events") : "")
                    color: Theme.fgVariant
                    font.family: Typography.ui
                    font.pixelSize: Typography.body * root.s
                    font.weight: Font.DemiBold
                }
                ActionButton {
                    id: newButton
                    visible: root.expanded
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    s: root.s; glyph: "plus"; accent: true
                    label: "New event"
                    enabled: Agenda.localWritable
                    onTriggered: root.newEvent()
                }
                Text {
                    anchors.right: newButton.visible ? newButton.left : parent.right
                    anchors.rightMargin: newButton.visible ? 10 * root.s : 0
                    anchors.verticalCenter: parent.verticalCenter
                    id: todayLink
                    visible: !root.sameDay(root.sel, root.today)
                    text: "Today"
                    color: todayArea.containsMouse ? Theme.fg : Theme.primary
                    font.family: Typography.ui
                    font.pixelSize: Typography.caption * root.s
                    MouseArea {
                        id: todayArea
                        Accessible.role: Accessible.Button
                        Accessible.name: "Today"
                        Accessible.onPressAction: root.goToday()
                        anchors.fill: parent
                        anchors.margins: -4 * root.s
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.goToday()
                    }
                }
            }

            // Los estados sin lista: cada uno con su texto (spec: nunca «No events» por un fallo).
            Column {
                anchors.centerIn: agendaList
                width: parent.width - 20 * root.s
                spacing: 6 * root.s
                visible: root.detailId.length === 0 && !root.panelOpen && !(root.agendaFresh && root.dayItems.length > 0)

                Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                    text: Agenda.state === "missing" ? "calcurse is not installed"
                        : Agenda.state === "error" ? "Could not load agenda"
                        : root.agendaFresh ? (Agenda.issues.length > 0 ? "Some events could not be loaded" : "No events")
                        : "Loading agenda…"
                    color: Agenda.state === "error" ? Theme.errorColor : Theme.fgVariant
                    font.family: Typography.ui
                    font.pixelSize: Typography.label * root.s
                }
                Text {
                    width: parent.width
                    visible: Agenda.state === "error" || Agenda.state === "missing"
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                    text: Agenda.state === "missing" ? "The month still works; install calcurse to see your events here."
                                                     : Agenda.error
                    color: Theme.outlineText
                    font.family: Typography.ui
                    font.pixelSize: Typography.caption * root.s
                }
                Text {
                    width: parent.width
                    visible: root.expanded && root.agendaFresh && Agenda.issues.length === 0 && Agenda.localWritable
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                    text: "New event (N) adds one to this day"
                    color: Theme.outlineText
                    font.family: Typography.ui
                    font.pixelSize: Typography.caption * root.s
                }
                ActionButton {
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: Agenda.state === "error" || Agenda.state === "missing"
                    s: root.s
                    label: "Retry"
                    onTriggered: root.load(true)
                }
            }

            // Avisos: una fuente que falló (con Retry) y la confirmación breve de guardar/borrar.
            Column {
                id: statusCol
                anchors.top: agendaHead.bottom
                width: parent.width
                visible: root.expanded && root.detailId.length === 0 && !root.panelOpen
                height: visible ? implicitHeight : 0
                spacing: 6 * root.s
                Repeater {
                    model: Agenda.state === "ready" ? Agenda.issues : []
                    Item {
                        id: issueRow
                        required property var modelData
                        width: statusCol.width
                        height: issueNotice.height
                        Notice {
                            id: issueNotice
                            anchors.left: parent.left
                            anchors.right: issueRetry.left; anchors.rightMargin: 6 * root.s
                            s: root.s; tone: "danger"
                            text: (issueRow.modelData.source === "local" ? "Local events: " : "calcurse: ") + issueRow.modelData.message
                        }
                        ActionButton {
                            id: issueRetry
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            s: root.s; label: "Retry"
                            onTriggered: root.load(true)
                        }
                    }
                }
                Notice {
                    width: parent.width
                    visible: CalendarEdit.notice.length > 0
                    s: root.s; tone: "ok"
                    text: CalendarEdit.notice
                }
            }

            // El pronóstico del día seleccionado, sólo si lo hay para esa fecha.
            Row {
                id: forecastRow
                anchors.top: statusCol.bottom
                anchors.topMargin: statusCol.height > 0 ? 6 * root.s : 0
                visible: root.detailId.length === 0 && !root.panelOpen && root.dayForecast !== null
                width: parent.width
                height: visible ? Math.max(24 * root.s, forecastText.implicitHeight) : 0
                spacing: 5 * root.s
                Icon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: Weather.condition(root.dayForecast ? root.dayForecast.code : null, false).icon
                    size: 12 * root.s
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    id: forecastText
                    width: parent.width - 20 * root.s; wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight
                    text: root.dayForecast
                        ? Weather.condition(root.dayForecast.code, false).text + "  ·  "
                          + Weather.temp(root.dayForecast.max) + " / " + Weather.temp(root.dayForecast.min)
                          + (root.dayForecast.rain !== null ? "  ·  " + root.dayForecast.rain + "% rain" : "")
                        : ""
                    color: Weather.state === "stale" ? Theme.outlineText : Theme.fgVariant
                    font.family: Typography.ui
                    font.pixelSize: Typography.caption * root.s
                }
            }

            ListView {
                id: agendaList
                anchors.top: forecastRow.bottom
                anchors.topMargin: 2 * root.s
                anchors.bottom: parent.bottom
                width: parent.width
                visible: root.detailId.length === 0 && !root.panelOpen && root.agendaFresh && root.dayItems.length > 0
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                spacing: 6 * root.s
                model: root.dayItems

                delegate: Item {
                    id: ev
                    required property var modelData
                    required property int index
                    readonly property bool cur: root.zone === "agenda" && root.agendaId === ev.modelData.id
                    // 16A-2
                    Accessible.role: Accessible.ListItem
                    Accessible.name: String(ev.modelData.message || "")
                    Accessible.description: root.timeLabel(ev.modelData)
                    Accessible.selected: ev.cur
                    Accessible.onPressAction: { root.zone = "agenda"; root.openDetail(ev.modelData.id); }
                    width: ListView.view ? ListView.view.width : 0
                    height: 76 * root.s

                    Rectangle {
                        anchors.fill: parent
                        radius: Metrics.rSm * root.s
                        color: Theme.controlBg(Theme.tileBg, evArea.containsMouse, evArea.pressed && evArea.containsMouse, ev.cur)
                        border.width: ev.cur ? Metrics.focusWidth : 0
                        border.color: Theme.focusRing
                        Behavior on color { ColorAnimation { duration: Motion.fast } }
                    }
                    Rectangle {
                        visible: ev.modelData.calendarKind === "caldav"
                        x: 3 * root.s; y: 8 * root.s
                        width: 3 * root.s; height: parent.height - 16 * root.s
                        radius: Metrics.pill(width)
                        color: ev.modelData.calendarColor && ev.modelData.calendarColor.length > 0 ? ev.modelData.calendarColor : Theme.primary
                    }
                    Text {
                        id: evTime
                        x: 10 * root.s; y: 8 * root.s
                        width: parent.width - 70 * root.s
                        text: root.timeLabel(ev.modelData)
                        elide: Text.ElideRight
                        color: Theme.fgVariant
                        font.family: Typography.ui
                        font.pixelSize: Typography.caption * root.s
                        font.features: ({ "tnum": 1 })
                    }
                    Text {
                        anchors.left: parent.left; anchors.leftMargin: 10 * root.s
                        anchors.right: parent.right
                        anchors.rightMargin: 6 * root.s
                        anchors.top: evTime.bottom; anchors.topMargin: 4 * root.s
                        wrapMode: Text.Wrap; maximumLineCount: 2
                        text: ev.modelData.message
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        color: Theme.fg
                        font.family: Typography.ui
                        font.pixelSize: Typography.body * root.s
                    }
                    Row {
                        id: evMarks
                        anchors.right: parent.right
                        anchors.rightMargin: 8 * root.s
                        anchors.verticalCenter: evTime.verticalCenter
                        spacing: 4 * root.s
                        // Repite / tiene nota: iconos, con su texto en el detalle.
                        Text {
                            visible: root.expanded && ["new", "dirty", "conflict"].indexOf(ev.modelData.syncState) >= 0
                            text: ev.modelData.syncState === "conflict" ? "conflict" : "to upload"
                            color: ev.modelData.syncState === "conflict" ? Theme.warn : Theme.outlineText
                            font.family: Typography.ui
                            font.pixelSize: Typography.caption * root.s
                        }
                        Text {
                            visible: root.expanded && ev.modelData.source === "calcurse"
                            text: "calcurse"
                            color: Theme.outlineText
                            font.family: Typography.ui
                            font.pixelSize: Typography.caption * root.s
                        }
                        Icon { visible: ev.modelData.recurring; name: "reload"; size: 10 * root.s; color: Theme.fgVariant }
                        Icon { visible: ev.modelData.hasNote; name: "file"; size: 10 * root.s; color: Theme.fgVariant }
                    }
                    MouseArea {
                        id: evArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { root.zone = "agenda"; root.openDetail(ev.modelData.id); }
                    }
                }
            }
            ScrollHint { view: agendaList; s: root.s; visible: agendaList.visible && overflowing }

            // ---- detalle de sólo lectura ----
            ActionButton {
                id: detailBack
                visible: root.detailId.length > 0 && !root.panelOpen
                s: root.s; height: 36 * root.s
                glyph: "chevron-left"; label: "Back"
                onTriggered: root.closeDetail()
            }
            Row {
                id: detailActions
                visible: detailBack.visible && root.expanded && root.detail !== null && root.detail.editable === true
                anchors.right: parent.right
                anchors.verticalCenter: detailBack.verticalCenter
                spacing: 6 * root.s
                ActionButton {
                    s: root.s; glyph: "edit"; label: "Edit"
                    enabled: !root.confirmingDelete && Agenda.localWritable
                    onTriggered: root.editDetail()
                }
                ActionButton {
                    s: root.s; glyph: "delete"; label: "Delete"; danger: true
                    enabled: !root.confirmingDelete && Agenda.localWritable
                    onTriggered: root.askDeleteDetail()
                }
            }
            ScrollHint { view: detailView; s: root.s; visible: detailView.visible && overflowing }
            Loader {
                id: accountsLoader
                anchors.fill: parent
                active: root.syncPanel
                sourceComponent: CalendarAccounts { s: root.s }
            }
            Loader {
                id: dataLoader
                anchors.fill: parent
                active: root.transferring
                sourceComponent: CalendarData { s: root.s }
            }
            Loader {
                id: editorLoader
                anchors.fill: parent
                active: root.editing
                sourceComponent: CalendarEditor { s: root.s }
            }
            Flickable {
                id: detailView
                anchors.top: detailBack.bottom; anchors.bottom: parent.bottom
                width: parent.width
                visible: root.detailId.length > 0 && !root.panelOpen
                clip: true
                contentHeight: detailCol.implicitHeight
                boundsBehavior: Flickable.StopAtBounds

                Column {
                    id: detailCol
                    width: detailView.width - 8 * root.s
                    spacing: 10 * root.s

                    // Confirmar el borrado: nombra la cita y su fecha; Cancel tiene el foco.
                    Rectangle {
                        id: deleteBox
                        width: parent.width
                        visible: root.confirmingDelete
                        height: visible ? deleteCol.implicitHeight + 20 * root.s : 0
                        radius: Metrics.rSm * root.s
                        color: Qt.alpha(Theme.danger, 0.08)
                        border.width: 1
                        border.color: Qt.alpha(Theme.danger, 0.45)
                        Column {
                            id: deleteCol
                            x: 12 * root.s; y: 10 * root.s
                            width: parent.width - 24 * root.s
                            spacing: 8 * root.s
                            Text {
                                width: parent.width
                                text: !CalendarEdit.deleting ? "" : CalendarEdit.deleting.recurring
                                    ? "Delete “" + CalendarEdit.deleting.title + "”, which repeats?"
                                    : "Delete “" + CalendarEdit.deleting.title + "”?"
                                textFormat: Text.PlainText
                                wrapMode: Text.Wrap
                                maximumLineCount: 3
                                elide: Text.ElideRight
                                color: Theme.fg
                                font.family: Typography.ui
                                font.pixelSize: Typography.body * root.s
                                font.weight: Font.DemiBold
                            }
                            Text {
                                width: parent.width
                                text: CalendarEdit.deleting ? CalendarEdit.deleting.when + "
It is removed from the local calendar. This cannot be undone." : ""
                                wrapMode: Text.Wrap
                                color: Theme.fgVariant
                                font.family: Typography.ui
                                font.pixelSize: Typography.caption * root.s
                            }
                            Text {
                                width: parent.width
                                visible: CalendarEdit.deleting !== null && CalendarEdit.deleting.error !== null
                                text: CalendarEdit.deleting && CalendarEdit.deleting.error ? CalendarEdit.deleting.error.message : ""
                                wrapMode: Text.Wrap
                                color: Theme.errorColor
                                font.family: Typography.ui
                                font.pixelSize: Typography.caption * root.s
                            }
                            Flow {
                                width: parent.width
                                spacing: 8 * root.s
                                Repeater {
                                    model: root.deleteOptions
                                    ActionButton {
                                        required property var modelData
                                        required property int index
                                        s: root.s
                                        glyph: modelData.scope === "" ? "" : "delete"
                                        accent: modelData.scope === ""
                                        danger: modelData.scope !== ""
                                        focused: root.deleteIndex === index
                                        label: CalendarEdit.deleting && CalendarEdit.deleting.busy && modelData.scope !== "" ? "Deleting…" : modelData.label
                                        enabled: !(CalendarEdit.deleting && CalendarEdit.deleting.busy)
                                        onTriggered: { root.deleteIndex = index; root.deleteActivate(); }
                                    }
                                }
                            }
                        }
                    }
                    Text {
                        width: parent.width
                        visible: root.detail === null
                        text: "Event no longer available"
                        color: Theme.fgVariant
                        font.family: Typography.ui
                        font.pixelSize: Typography.label * root.s
                    }
                    Text {
                        width: parent.width
                        visible: root.detail !== null
                        text: root.detail ? root.detail.message : ""
                        textFormat: Text.PlainText
                        wrapMode: Text.Wrap
                        color: Theme.fg
                        font.family: Typography.ui
                        font.pixelSize: Typography.title * root.s
                        font.weight: Font.DemiBold
                    }
                    Text {
                        width: parent.width
                        visible: root.detail !== null
                        wrapMode: Text.Wrap
                        text: {
                            const d = root.detail;
                            if (!d) return "";
                            const p = d.date.split("-");
                            const day = root.loc.toString(new Date(Number(p[0]), Number(p[1]) - 1, Number(p[2])), "dddd d MMMM yyyy");
                            const dur = root.durationLabel(d.duration);
                            const ev = d.event;
                            const oc = d.occurrence || ev;
                            const zone = oc && !oc.allDay && Agenda.displayTz.length > 0 && oc.tz !== Agenda.displayTz
                                ? "\n" + oc.startTime + "–" + oc.endTime + " in " + oc.tz : "";
                            const span = oc && oc.allDay && oc.startDate !== oc.lastDate
                                ? "\n" + root.dayLabel(oc.startDate) + " – " + root.dayLabel(oc.lastDate) : "";
                            const rep = d.source === "local" && ev && ev.repeat ? "\n" + CalendarEdit.repeatText(ev.repeat) + (d.modified ? "\nThis occurrence was changed" : "") : (d.recurring ? "\nRepeats" : "");
                            const rem = d.source === "local" && d.reminders && d.reminders.length > 0 ? "\n" + CalendarEdit.reminderText(d.reminders, d.allDay) : "";
                            return day + "\n" + root.timeLabel(d) + (dur.length > 0 && !d.allDay ? "  ·  " + dur : "")
                                + zone + span + rep + rem
                                + (root.expanded ? (d.source !== "local" ? "\nFrom calcurse · read-only here"
                                    : d.calendarKind === "caldav" ? "\nCalendar: " + d.calendarName + root.syncLabel(d.syncState)
                                    : "\nOn this computer") : "")
                                + (d.readOnly ? "\nRead-only here: " + d.readOnly : "")
                                + (d.syncState === "conflict" ? "\nChanged here and elsewhere: resolve it in Accounts" : "");
                        }
                        color: Theme.fgVariant
                        font.family: Typography.ui
                        font.pixelSize: Typography.label * root.s
                    }
                    Text {
                        width: parent.width
                        visible: root.detail !== null && root.detail.hasNote
                        topPadding: 4 * root.s
                        text: root.detail ? root.detail.note : ""
                        textFormat: Text.PlainText
                        wrapMode: Text.Wrap
                        color: Theme.fg
                        font.family: Typography.ui
                        font.pixelSize: Typography.label * root.s
                    }
                }
            }
        }

    }
    }
    ScrollHint { view: pageView; s: root.s }

        /** La accion que tenia el reloj de Waybar. */
        Item {
            id: footer
            anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
            height: 36 * root.s
            Rectangle { width: parent.width; height: 1; color: Theme.hair }

            ActionButton {
                id: dataAction
                visible: root.expanded
                s: root.s; label: "Import / Export"; glyph: "file"
                anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                width: Math.min(implicitWidth, parent.width * 0.45)
                enabled: !root.editing
                onTriggered: { root.detailId = ""; CalendarSync.close(); CalendarTransfer.show(); }
            }
            ActionButton {
                id: accountsAction
                visible: root.expanded
                s: root.s; glyph: "reload"
                anchors.left: dataAction.right; anchors.leftMargin: 4 * root.s; anchors.verticalCenter: parent.verticalCenter
                width: Math.max(0, Math.min(implicitWidth, parent.width - dataAction.width - calcurseRow.width - 16 * root.s))
                // Un conflicto se ve desde el pie, sin abrir nada.
                label: CalendarSync.conflicts.length > 0 ? "Accounts · " + CalendarSync.conflicts.length + (CalendarSync.conflicts.length === 1 ? " conflict" : " conflicts")
                    : CalendarSync.syncing ? "Accounts · syncing…" : "Accounts"
                danger: CalendarSync.conflicts.length > 0
                enabled: !root.editing
                onTriggered: { root.detailId = ""; CalendarTransfer.close(); CalendarSync.show(); }
            }
            ActionButton {
                id: expandAction
                visible: !root.expanded
                s: root.s; label: "Open calendar"; glyph: "calendar"; accent: true
                anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                width: Math.min(implicitWidth, parent.width * 0.50)
                onTriggered: root.expandCalendar()
            }
            Row {
                id: calcurseRow
                width: root.expanded ? Math.min(parent.width * 0.5, 240 * root.s) : parent.width - expandAction.width - 12 * root.s
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 6 * root.s

                Icon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: "calendar"
                    size: 12 * root.s
                    color: calArea.containsMouse ? Theme.fg : Theme.fgVariant
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - 20 * root.s; elide: Text.ElideRight
                    text: root.calcurseWhy.length > 0 ? root.calcurseWhy : "Open calcurse"
                    color: root.calcurseWhy.length > 0 ? Theme.outlineText : calArea.containsMouse ? Theme.fg : Theme.fgVariant
                    font.family: Typography.ui
                    font.pixelSize: Typography.caption * root.s
                }
            }

            MouseArea {
                id: calArea
                Accessible.role: Accessible.Button
                Accessible.name: "Open calcurse"
                Accessible.onPressAction: root.toggleCalcurse()
                anchors.fill: calcurseRow
                hoverEnabled: true
                enabled: root.calcurseWhy.length === 0
                cursorShape: Qt.PointingHandCursor
                onClicked: root.toggleCalcurse()
            }
        }

    readonly property real weekColW: 26 * root.s
    readonly property var editorView: editorLoader.item

    /** Botoncito de navegacion del mes. */
    component Nav: Item {
        property string glyph: ""
        /** 16A-2: el nombre accesible (el glifo no dice nada a un lector). */
        property string label: ""
        Accessible.role: Accessible.Button
        Accessible.name: label
        Accessible.onPressAction: activated()
        signal activated()

        width: 30 * root.s
        height: 32 * root.s
        Rectangle {
            anchors.fill: parent; radius: Metrics.rSm * root.s
            color: navArea.containsMouse ? Theme.hoverBg : "transparent"
            Behavior on color { ColorAnimation { duration: Motion.fast } }
        }

        Text {
            anchors.centerIn: parent
            text: parent.glyph
            color: navArea.containsMouse ? Theme.fg : Theme.fgVariant
            font.family: Typography.ui
            font.pixelSize: Typography.body * root.s
        }

        MouseArea {
            id: navArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: parent.activated()
        }
    }
}
