pragma ComponentBehavior: Bound

import QtQuick
import "../theme"
import "../services"
import "../components"

/**
 * Ficha de un servicio systemd --user (Fase 10.c).
 *
 * La isla salta aquí desde la lista al elegir una unidad, como la ficha de wifi
 * (9.f.2b): una superficie de verdad, no un panel que crece. Aquí viven:
 *  - la descripción y el estado de la unidad,
 *  - las acciones Start / Stop / Restart, en fila y con icono (como `power`),
 *  - una vista previa del journal, con su propia superficie para verlo entero.
 *
 * 11F-1: la ficha es de una CLAVE (ámbito + unidad): `user:foo.service`, `system:sshd.service`,
 * y de cualquier tipo. Enseña el ámbito y el tipo, los datos que tienen sentido para ese tipo
 * (próxima y última ejecución de un timer, escucha de un socket, origen y destino de un montaje,
 * la unidad que activa o que la activa, que se abre desde aquí) y el journal de ESE ámbito. Las
 * acciones siguen siendo sólo de `.service` de usuario; las de sistema son de la 11F-2. Una unidad
 * que ya no existe dice «Unit not found», no una ficha vacía.
 *
 * ALTURA DIRIGIDA POR EL CONTENIDO contra un ancho **constante** (`innerW`), no
 * el animado: el alto se calcula una vez y sólo cambia cuando el contenido
 * cambia de verdad (aparece un aviso). No reabre el bucle de 9.f.2 — no hay
 * `ListView` y el ancho no sale del layout.
 */
Surface {
    id: root

    mTop: 12
    mLeft: 14
    mRight: 14
    mBottom: 12

    signal requestSurface(string name)
    /** Saltar a una ficha diciendo QUE mirar (core/SurfaceHost §`sel`). */
    signal requestDetail(string name, string key)

    readonly property real innerW: Metrics.serviceDetailW * root.s
        - (root.mLeft + root.mRight) * root.s

    implicitHeight: col.implicitHeight

    /**
     * Que unidad mira ESTA pantalla. Lo fija su `SurfaceHost` (§`sel`), no un
     * singleton: hasta el 2026-09-22 esto era `Units.detailUnit` y con dos
     * monitores abrir una ficha en una pantalla cambiaba la otra sin avisar,
     * botones de Start/Stop incluidos.
     */
    property string sel: ""
    readonly property var parsed: Units.parseKey(root.sel)
    readonly property string scope: root.parsed.scope
    readonly property string unit: root.parsed.unit
    /** La clave canónica (con prefijo): la de la caché, el journal y el historial. */
    readonly property string ukey: root.unit.length > 0 ? Units.key(root.scope, root.unit) : ""
    readonly property string utype: Units.typeOf(root.unit)
    readonly property var info: Units.infoFor(root.ukey)
    /** Start/Stop/Restart: servicios de los dos ámbitos (los de sistema, con autorización: 11F-2). */
    readonly property bool hasActions: root.utype === "service" && !root.notFound
    /** La política de `Units` (capacidades, protegidos, aviso de red) con la ficha más reciente. */
    readonly property var pol: { void Units.infoByUnit; void Units.rev; return Units.policy(root.ukey); }
    readonly property bool notFound: root.info.notFound === true
    /**
     * `journalctl -f` es UNO para todo el shell y lo posee quien abrio el
     * ultimo (decision del usuario, 2026-09-22). Si esta ficha no es la duena,
     * lo DICE en vez de pintar las lineas de otra unidad como si fueran suyas
     * -- que es lo que hacia al probarlo con dos pantallas.
     */
    readonly property bool ownsJournal: Units.journalKey === root.ukey
    /** Datos de la lista mientras `systemctl show` aún no vuelve. */
    readonly property var lrow: { void Units.rev; return Units.listRow(root.ukey); }

    readonly property string activeState: (root.info.active && root.info.active.length > 0)
        ? root.info.active : (root.lrow ? root.lrow.active : "")
    readonly property string subState: (root.info.sub && root.info.sub.length > 0)
        ? root.info.sub : (root.lrow ? root.lrow.sub : "")
    readonly property string description: (root.info.description && root.info.description.length > 0)
        ? root.info.description : (root.lrow ? root.lrow.desc : "")
    readonly property bool isActive: root.activeState === "active"
    readonly property bool isFailed: root.activeState === "failed"

    /**
     * La ficha reclama dos cosas mientras está abierta (QS-FUNC-007): la
     * relectura cada 5 s (así su cabecera no enseña un estado viejo) y el
     * journal en vivo de la vista previa. Clave con el monitor; vacía mientras
     * se construye, y entonces no se reclama (QS-FUNC-003).
     */
    readonly property string claimKey: root.screenName.length > 0 ? "serviceDetail@" + root.screenName : ""
    // El journal, después de `loadJournal` (ver ServiceJournal): sigue a `following`.
    property bool following: false
    Claim { target: Units; key: root.claimKey; value: root.active ? root.scope : false }
    Claim { target: Units; method: "claimJournal"; key: root.claimKey; value: root.following }

    onActiveChanged: {
        if (!root.active) root.confirmVerb = "";   // una confirmación se cancela al salir (DESIGN §2)
        if (root.active) {
            root.syncActions();
            if (root.unit.length > 0) {
                Units.loadDetail(root.ukey);
                Units.loadJournal(root.ukey);   // para la vista previa; antes que la reclamación
            }
        }
        root.following = root.active;
    }

    /** Enfoca la primera acción habilitada (Start está deshabilitada si ya activa). */
    function syncActions() {
        // `onActiveChanged` puede dispararse mientras se construye la superficie,
        // antes de que existan `acts` o el binding de `actionList` (el orden de
        // los bindings al construir no está garantizado). Si aún no están,
        // `onDetailInfoChanged` / `Component.onCompleted` vuelven a llamar aquí
        // en cuanto llega `systemctl show`.
        const list = root.actionList;
        if (!acts || !list || !root.hasActions)
            return;
        acts.reset();
        for (let i = 0; i < list.length; i++)
            if (list[i].enabled !== false) { acts.current = i; break; }
    }
    onActiveStateChanged: if (root.active) root.syncActions()
    // 11F-1: saltar a otra unidad sin cerrar la ficha (timer → su servicio) cambia la clave, no
    // `active`: se vuelven a pedir su ficha y su journal (si no, el journal seguía el de antes).
    onUkeyChanged: if (root.active && root.ukey.length > 0) {
        root.confirmVerb = "";   // una confirmación a medias no pasa a otra unidad
        Units.loadDetail(root.ukey);
        Units.loadJournal(root.ukey);
        root.syncActions();
    }
    Component.onCompleted: {
        root.syncActions();
        if (root.active && root.unit.length > 0) {
            Units.loadDetail(root.ukey);
            Units.loadJournal(root.ukey);
        }
        root.following = root.active;
    }
    // `systemctl show` vuelve después de construir la superficie: al traer el
    // estado real se re-enfoca (Start suele quedar deshabilitada).
    //
    // Pero SÓLO si el cursor ha quedado sobre una acción muerta. Desde
    // QS-FUNC-007 `show` vuelve cada 5 s con la ficha abierta, y re-enfocar
    // siempre devolvía el cursor a la primera acción y —vía `acts.reset()`—
    // cancelaba una confirmación a medias. Un cambio de estado real sigue
    // re-enfocando por `onActiveStateChanged`.
    Connections {
        target: Units
        // `infoByUnit` en vez de la vieja `detailInfo`: la cache es por unidad
        // desde que la seleccion es de cada pantalla (2026-09-22).
        function onInfoByUnitChanged() {
            if (!root.active || !acts || !root.actionList || !root.hasActions)
                return;
            const cur = root.actionList.find(function (a) { return a.id === acts.currentId; });
            if (!cur || cur.enabled === false)
                root.syncActions();
        }
    }

    /** 11F-2: los botones salen de la política; en una caída, Start es «Retry start». */
    readonly property var actionList: [
        { id: "start",   label: root.pol.start ? root.pol.start.label : "Start", glyph: "play",
          enabled: !!(root.pol.start && root.pol.start.ok) && !Units.busy },
        { id: "stop",    label: "Stop",    glyph: "stop",    enabled: !!(root.pol.stop && root.pol.stop.ok) && !Units.busy },
        { id: "restart", label: "Restart", glyph: "restart", enabled: !!(root.pol.restart && root.pol.restart.ok) && !Units.busy }
    ]
    /** El motivo del botón con el foco, si no se puede usar (junto al botón, antes de pedir nada). */
    readonly property string focusReason: {
        const a = acts ? root.actionList.find(x => x.id === acts.currentId) : null;
        if (!a || a.enabled) return "";
        if (Units.busy) return "Another action is running";
        const p = root.pol[a.id];
        return p && !p.ok ? a.label + ": " + p.reason : "";
    }

    /**
     * La acción pedida en una unidad de SISTEMA se confirma primero, aquí mismo: la unidad exacta, el
     * ámbito y el efecto; «Cancel» es lo elegido por defecto. Las de usuario van directas, como antes.
     */
    property string confirmVerb: ""
    property int confirmSel: 0          // 0 Cancel · 1 Confirm
    readonly property string confirmText: {
        if (root.confirmVerb.length === 0) return "";
        const eff = root.confirmVerb === "stop" ? "This stops the service; anything that depends on it stops too."
            : root.confirmVerb === "restart" ? "This interrupts the service while it restarts."
            : "This starts the service.";
        const verb = root.confirmVerb === "start" && root.pol.start ? root.pol.start.label : root.confirmVerb.charAt(0).toUpperCase() + root.confirmVerb.slice(1);
        return verb + " " + root.unit + " in System? " + eff
            + (root.pol.warn ? " " + root.pol.warn : "") + " Your password will be asked.";
    }

    function run(id) {
        if (root.scope === "system") {
            root.confirmVerb = id;
            root.confirmSel = 0;
            return;
        }
        Units.act(id, root.ukey, root.screenName);
        // Tras la acción el estado se invierte y la mitad de la fila se
        // deshabilita; se ancla el foco en Restart para que un ⏎ de seguimiento
        // no caiga sobre un botón muerto mientras `show` vuelve.
        acts.current = 2;
    }
    function answerConfirm(yes) {
        const v = root.confirmVerb;
        root.confirmVerb = "";
        if (yes && v.length > 0) Units.act(v, root.ukey, root.screenName);
    }

    /**
     * Lo que se dice del resultado: nada «recuperado» ni «parado» hasta RELEER la unidad
     * (`Units.lastVerified`, tras la segunda relectura). Denegado o cancelado: nada cambió.
     */
    readonly property bool resultHere: Units.lastKey === root.ukey && (Units.busy || Units.lastResult.length > 0)
    readonly property string resultText: {
        if (!root.resultHere) return "";
        const v = Units.lastVerb;
        if (Units.busy) return root.scope === "system" ? v + ": waiting for authorization and systemd…" : v + "…";
        if (Units.lastResult === "denied") return "Authorization cancelled or denied · nothing changed";
        if (Units.lastResult !== "ok")
            return v + " failed" + (Units.lastError ? ": " + Units.lastError : " (" + Units.lastResult + ")");
        if (!Units.lastVerified) return v + " accepted · checking the unit…";
        const a = root.activeState;
        if (v === "stop") return a === "inactive" || a === "failed" ? "Stopped · " + a : "Still " + a + " after stop";
        if (a === "active") return (v === "restart" ? "Restarted" : "Started") + " · running";
        if (a === "activating") return "Still starting · check again in a moment";
        // un servicio de un solo disparo que corrió DESPUÉS de la acción y acabó bien también queda
        // inactivo: la prueba es que escribió en su journal desde entonces
        if (a === "inactive" && root.info.result === "success" && Units.lastRanLines > 0)
            return "Ran and finished · result success (" + Units.lastRanLines + " journal lines since)";
        return "Did not come up · " + a + (root.info.result && root.info.result !== "success" ? " (" + root.info.result + ")" : "");
    }
    readonly property bool resultBad: root.resultHere && !Units.busy
        && (Units.lastResult.indexOf("exit") === 0 || (Units.lastVerified && root.resultText.indexOf("Did not") === 0))

    /** Volver a donde se vino (la pila del host, QS-FUNC-004). */
    function back() {
        root.requestBack();
    }

    function openJournal() {
        // La unidad viaja con el salto: el journal de esta pantalla es el de la
        // ficha que lo abrio, no el del ultimo que tocara el singleton.
        if (root.notFound) return;
        Units.loadJournal(root.ukey);
        root.requestDetail("serviceJournal", root.ukey);
    }

    /** 11F-1: la unidad que esta activa (timer → servicio, socket → servicio), en su mismo ámbito. */
    readonly property string linkUnit: {
        const t = String(root.info.triggers || "").split(/\s+/)[0] || "";
        return Units.looksLikeUnit(t) ? t : "";
    }
    function openLink() {
        if (root.linkUnit.length === 0) return;
        const k = Units.key(root.scope, root.linkUnit);
        Units.loadDetail(k);
        root.requestDetail("serviceDetail", k);
    }
    /** Un montaje: su espacio y su actividad están en System Monitor. */
    readonly property bool isMount: root.utype === "mount" || root.utype === "automount"
    function openMonitor() { root.requestSurface("system"); }

    /** Para el IPC (`unitDetailState`). */
    function stateInfo() {
        return { key: root.ukey, scope: root.scope, type: root.utype, notFound: root.notFound,
                 active: root.activeState, sub: root.subState, hasActions: root.hasActions,
                 actions: root.actionList.map(a => a.id + (a.enabled ? "" : "-off") + ":" + a.label),
                 focused: acts ? acts.currentId : "", reason: root.focusReason, protected: !!root.pol.protected,
                 warn: root.pol.warn || "", confirm: root.confirmVerb, confirmSel: root.confirmSel,
                 confirmText: root.confirmText, result: root.resultText,
                 link: root.linkUnit, isMount: root.isMount, info: root.info,
                 journal: { owns: root.ownsJournal, permission: Units.journalPermission, busy: Units.journalBusy,
                            lines: Units.journalLines.length } };
    }

    function keyPressed(event) {
        // la confirmación de sistema primero: ← → eligen, ⏎ responde, Esc cancela (sin salir)
        if (root.confirmVerb.length > 0) {
            if (event.key === Qt.Key_Left || event.key === Qt.Key_Right || event.key === Qt.Key_Tab)
                root.confirmSel = root.confirmSel === 0 ? 1 : 0;
            else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                root.answerConfirm(root.confirmSel === 1);
            else if (event.key === Qt.Key_Escape)
                root.answerConfirm(false);
            event.accepted = true;
            return;
        }
        if (event.key === Qt.Key_Escape) { root.back(); event.accepted = true; return; }
        if (event.key === Qt.Key_J || event.key === Qt.Key_Down) {
            root.openJournal(); event.accepted = true; return;
        }
        if (event.key === Qt.Key_T && root.linkUnit.length > 0) { root.openLink(); event.accepted = true; return; }
        if (event.key === Qt.Key_M && root.isMount) { root.openMonitor(); event.accepted = true; return; }
        if (root.hasActions && acts.handleKey(event)) event.accepted = true;
    }

    function ago(iso) {
        if (!iso || iso.length === 0) return "";
        const t = Date.parse(iso.replace(/^[A-Za-z]{3} /, ""));
        if (isNaN(t)) return "";
        if (t > Date.now()) return "";
        return Clock.ago(t, "long");
    }
    function jColor(l) {
        const s = l.toLowerCase();
        if (s.indexOf("error") >= 0 || s.indexOf("failed") >= 0 || s.indexOf("fatal") >= 0)
            return Theme.errorColor;
        if (s.indexOf("warn") >= 0) return Theme.secondary;
        return Theme.fgVariant;
    }

    /** La fila de ficha común, en su variante densa (`components/FactRow`, fase 3B, ADR-42); sin valor, no se ve. */
    component Fact: FactRow { s: root.s; width: col.width; dense: true; hideEmpty: true }

    Column {
        id: col
        anchors.top: parent.top
        anchors.left: parent.left
        width: root.innerW
        spacing: 8 * root.s

        // ---- cabecera --------------------------------------------------
        Item {
            width: col.width
            height: 22 * root.s

            Icon {
                id: backIcon
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                name: "chevron-left"
                size: 14 * root.s
                color: backArea.containsMouse ? Theme.fg : Theme.fgVariant
                Behavior on color { ColorAnimation { duration: Motion.fast } }
                MouseArea {
                    id: backArea
                    anchors.fill: parent
                    anchors.margins: -6 * root.s
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.back()
                }
            }
            Text {
                id: scopeTag
                anchors.left: backIcon.right
                anchors.leftMargin: 8 * root.s
                anchors.verticalCenter: parent.verticalCenter
                text: (root.scope === "system" ? "System" : "User") + " · " + root.utype
                color: root.scope === "system" ? Theme.secondary : Theme.outlineText
                font.family: Typography.ui
                font.pixelSize: Typography.micro * root.s
                font.weight: Typography.wStrong
            }
            Text {
                anchors.left: scopeTag.right
                anchors.leftMargin: 8 * root.s
                anchors.right: stateTag.left
                anchors.rightMargin: 8 * root.s
                anchors.verticalCenter: parent.verticalCenter
                text: root.unit
                elide: Text.ElideMiddle
                color: Theme.fg
                font.family: Typography.ui
                font.pixelSize: Typography.body * root.s
                font.weight: Font.DemiBold
            }
            Text {
                id: stateTag
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.notFound ? "not found" : root.activeState + (root.subState.length > 0 ? " · " + root.subState : "")
                color: root.isFailed ? Theme.errorColor
                     : root.isActive ? Theme.primary : Theme.outline
                font.family: Typography.ui
                font.pixelSize: Typography.caption * root.s
            }
        }

        // ---- descripción --------------------------------------------
        Text {
            width: col.width
            text: root.notFound ? "Unit not found in " + root.scope + " units · Item no longer available"
                : root.info.error ? "Could not read this unit: " + root.info.error
                : root.description.length > 0 ? root.description : "—"
            wrapMode: Text.WordWrap
            color: root.notFound || root.info.error ? Theme.warn : root.description.length > 0 ? Theme.fgVariant : Theme.outlineText
            font.family: Typography.ui
            font.pixelSize: Typography.label * root.s
        }

        // ---- ficha ------------------------------------------------
        Column {
            width: col.width
            spacing: 1 * root.s
            visible: !root.notFound
            Fact { label: "Load";       value: root.info.load || (root.lrow ? root.lrow.load : "") }
            Fact { label: "File state"; value: root.info.fileState || "" }
            Fact { label: "Since";      value: root.ago(root.info.since) }
            Fact { label: "Result";     value: (root.info.result && root.info.result !== "success") ? root.info.result
                                               : (root.utype === "timer" && root.info.result === "success" ? "success" : "") }
            // por tipo (11F-1)
            Fact { label: "Next run";   value: root.utype === "timer" ? (root.info.nextRun || "not scheduled") : "" }
            Fact { label: "Last run";   value: root.utype === "timer" ? (root.info.lastRun || "never") : "" }
            Fact { label: "Listen";     value: root.utype === "socket" ? String(root.info.listen || "").replace(/ \(.*$/, "") : "" }
            Fact { label: "What";       value: root.isMount ? (root.info.what || "") : "" }
            Fact { label: "Where";      value: root.isMount ? (root.info.where || "") : "" }
            Fact { label: "Started by"; value: root.info.triggeredBy || "" }
        }

        // ---- enlaces (11F-1): la unidad que activa, el monitor de un montaje ----
        Row {
            visible: !root.notFound && (root.linkUnit.length > 0 || root.isMount)
            spacing: 8 * root.s
            ActionButton {
                visible: root.linkUnit.length > 0
                s: root.s
                label: (root.utype === "timer" ? "Runs " : "Starts ") + root.linkUnit + "  ·  T"
                onTriggered: root.openLink()
            }
            ActionButton {
                visible: root.isMount
                s: root.s
                label: "Space and activity in System Monitor  ·  M"
                onTriggered: root.openMonitor()
            }
        }

        // sin acciones: por qué (tipo de sólo lectura, o ámbito de sistema hasta que llegue su autorización)
        Text {
            width: col.width
            visible: !root.hasActions && !root.notFound
            wrapMode: Text.WordWrap
            text: "Read only · starting or stopping a " + root.utype + " changes more than this unit, so it has no buttons here"
            color: Theme.outlineText
            font.family: Typography.ui
            font.pixelSize: Typography.caption * root.s
        }

        // ---- resultado de la última acción --------------------------
        Text {
            width: col.width
            visible: root.resultHere
            wrapMode: Text.WordWrap
            text: root.resultText
            color: root.resultBad ? Theme.errorColor
                 : Units.lastResult === "denied" ? Theme.warn
                 : Units.lastVerified ? Theme.primary : Theme.fgVariant
            font.family: Typography.ui
            font.pixelSize: Typography.caption * root.s
        }

        // ---- acciones (fila, con icono) -----------------------------
        ActionGroup {
            id: acts
            visible: root.hasActions
            width: col.width
            s: root.s
            orientation: "horizontal"
            stacked: true
            spacing: 6 * root.s
            actions: root.actionList
            onTriggered: (id) => root.run(id)
        }

        // el porqué del botón con el foco, junto a él, antes de pedir autorización
        Text {
            width: col.width
            visible: root.hasActions && root.confirmVerb.length === 0
                && (root.focusReason.length > 0 || root.pol.protected || (root.scope === "system" && !Units.busy))
            wrapMode: Text.WordWrap
            text: [root.focusReason,
                   root.pol.protected ? "Protected session service · Stop and Restart are blocked here" : "",
                   root.scope === "system" && !root.pol.protected ? "System service · asks for confirmation and your password" : ""]
                .filter(t => t.length > 0).join("  ·  ")
            color: root.pol.protected || root.focusReason.length > 0 ? Theme.warn : Theme.outlineText
            font.family: Typography.ui
            font.pixelSize: Typography.caption * root.s
        }

        // la confirmación de una acción de sistema (Cancel por defecto)
        Rectangle {
            width: col.width
            visible: root.confirmVerb.length > 0
            height: visible ? confCol.implicitHeight + 16 * root.s : 0
            radius: Metrics.r(8) * root.s
            color: Qt.alpha(Theme.warn, 0.12)
            border.width: 1
            border.color: Qt.alpha(Theme.warn, 0.5)
            Accessible.role: Accessible.AlertMessage
            Accessible.name: root.confirmText
            Column {
                id: confCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 8 * root.s
                spacing: 6 * root.s
                Text {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: root.confirmText
                    color: Theme.fg
                    font.family: Typography.ui
                    font.pixelSize: Typography.caption * root.s
                }
                Row {
                    spacing: 8 * root.s
                    ActionButton {
                        s: root.s
                        label: "Cancel"
                        focused: root.confirmSel === 0
                        onTriggered: root.answerConfirm(false)
                    }
                    ActionButton {
                        s: root.s
                        label: root.confirmVerb === "start" && root.pol.start ? root.pol.start.label
                            : root.confirmVerb.charAt(0).toUpperCase() + root.confirmVerb.slice(1)
                        danger: root.confirmVerb !== "start"
                        focused: root.confirmSel === 1
                        onTriggered: root.answerConfirm(true)
                    }
                }
            }
        }

        Rectangle { width: col.width; height: 1; color: Theme.hair }

        // ---- vista previa del journal -----------------------------
        Item {
            width: col.width
            height: 14 * root.s
            Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "JOURNAL"
                color: Theme.fgVariant
                font.family: Typography.ui
                font.pixelSize: Typography.label * root.s
                font.weight: Typography.wStrong
                font.letterSpacing: Typography.tracking * root.s
            }
            Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 4 * root.s
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "view full  ·  J"
                    color: jArea.containsMouse ? Theme.fg : Theme.outlineText
                    font.family: Typography.ui
                    font.pixelSize: Typography.caption * root.s
                }
                Icon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: "chevron-right"
                    size: 11 * root.s
                    color: jArea.containsMouse ? Theme.fg : Theme.outline
                }
            }
            MouseArea {
                id: jArea
                anchors.fill: parent
                anchors.margins: -4 * root.s
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openJournal()
            }
        }

        Rectangle {
            width: col.width
            height: 78 * root.s
            radius: Metrics.r(8) * root.s
            color: Theme.tileBg
            clip: true

            Empty {
                anchors.centerIn: parent
                visible: root.notFound || !root.ownsJournal || Units.journalBusy || Units.journalPermission
                    || Units.journalLines.length === 0
                s: root.s
                maxWidth: parent.width - 16 * root.s
                loading: root.ownsJournal && Units.journalBusy && !root.notFound
                glyph: Units.journalPermission && root.ownsJournal ? "lock" : "history"
                text: root.notFound ? "No journal: the unit is not there"
                    : !root.ownsJournal ? "Journal is following " + Units.journalKey
                    : Units.journalBusy ? "Reading journal…"
                    : Units.journalPermission ? "Permission required"
                    : "No recent entries"
                hint: root.notFound ? ""
                    : !root.ownsJournal ? "Only one live log at a time: the last card opened has it"
                    : Units.journalBusy ? ""
                    : Units.journalPermission ? "Can't read the system journal (needs wheel, adm or systemd-journal)"
                    : "This unit has not logged anything lately"
            }

            Column {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.margins: 7 * root.s
                spacing: 0
                visible: !root.notFound && root.ownsJournal && !Units.journalBusy && !Units.journalPermission
                    && Units.journalLines.length > 0

                Repeater {
                    model: Units.journalTail(4)
                    delegate: Text {
                        required property var modelData
                        width: parent.width
                        text: modelData
                        elide: Text.ElideRight
                        wrapMode: Text.NoWrap
                        color: root.jColor(modelData)
                        font.family: Typography.mono
                        font.pixelSize: Typography.micro * root.s
                    }
                }
            }
        }
    }
}
