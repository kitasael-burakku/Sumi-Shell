pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Widgets
import "../theme"
import "../services"
import "../components"
import "../lib/text-wrap.js" as TextWrap

/**
 * Visual Profiles: carrusel de perfiles con muestras (rediseño 12B, 2026-09-28).
 *
 * rediseno/docs/futurevisual-profilesurface.md. Sustituye a la lista vertical de la 10.c.4, que
 * APLICABA al pulsar Enter. Ahora:
 *
 *   - mover el foco (← →, rueda, clic en una lateral) sólo SELECCIONA: tarjeta y muestras;
 *   - **Preview** es la única entrada a la prueba global (`services/ThemePreview`, 12A);
 *   - **Keep changes** confirma exactamente lo que terminó de previsualizarse;
 *   - **Revert**, `Esc` o cerrar sin confirmar vuelven a lo confirmado — salvo cuando el control
 *     pasa a otra pantalla (`Operations.claim`): eso es un traslado, no un cierre.
 *
 * Selected (borde), Previewing y Applied son marcas distintas. Las muestras las calcula
 * `ThemeSamples` sin aplicar nada; una pendiente dice «Generating samples», nunca inventa colores.
 * La tira sigue el patrón de Wallpaper List: persecución exponencial de `pos` (`Motion.chaseTau`),
 * también con Reduced — decisión del usuario (2026-09-28), que cambia la spec («con Reduce motion,
 * el foco cambiará sin recorrido»): las dos tiras se mueven igual. Con Off, salta.
 */
Surface {
    id: root

    mTop: 12
    mLeft: 18
    mRight: 18
    mBottom: 12

    /** La operación global que controla esta vista (el marco la reclama al abrir de forma explícita). */
    opId: ThemePreview.opId

    readonly property var profiles: ThemePreview.profiles
    readonly property int count: root.profiles.length
    function nameOf(p) { return ThemePreview.nameOf(p); }

    property int sel: 0
    property real pos: 0
    readonly property string selected: root.profiles[root.sel] || ""

    /** "strip" | "actions": dónde está el teclado; las flechas actúan dentro. */
    property string zone: "strip"
    property int actIndex: 0

    readonly property string phase: ThemePreview.phase
    readonly property bool live: ThemePreview.live
    readonly property bool busy: root.phase === "restoring" || root.phase === "keeping"
        || root.phase === "recovering"
    readonly property string confirmed: ThemePreview.confirmed
    readonly property string previewing: ThemePreview.previewing
    /** Lo último pedido: lo que la prueba va a mostrar (puede estar preparándose). */
    readonly property string target: ThemePreview.requested
    readonly property bool noWall: ThemePreview.baseWall.length === 0
    /** Esta vista no lleva la prueba: la lleva otra pantalla (sólo informa). */
    readonly property bool elsewhere: root.opElsewhere

    // ---- acciones --------------------------------------------------------

    /** F2c: por qué el perfil seleccionado no se puede probar en esta máquina ("" = sí). */
    readonly property string capWhy: ThemePreview.whyNot(root.selected)
    readonly property bool canPreview: root.capWhy.length === 0 && !root.busy && !root.elsewhere && root.selected.length > 0
        && !(root.noWall && !ThemePreview.isStatic(root.selected))
        && (root.live ? root.selected !== root.target : root.selected !== root.confirmed)
    readonly property bool canKeep: !root.elsewhere && root.phase === "active"
        && ThemePreview.requestedKey === ThemePreview.previewingKey
    readonly property bool canRevert: !root.elsewhere && root.live && !root.busy
    readonly property bool canUseLater: root.capWhy.length === 0 && root.noWall && !ThemePreview.isStatic(root.selected) && !root.live
        && root.selected !== root.confirmed

    readonly property var actions: {
        const a = [];
        if (root.phase === "failed")
            a.push({ id: "retry", label: "Retry", on: true });
        if (root.canUseLater)
            a.push({ id: "later", label: "Use when wallpaper is available", on: true });
        a.push({ id: "preview", label: "Preview", on: root.canPreview });
        a.push({ id: "keep", label: "Keep changes", on: root.canKeep });
        a.push({ id: "revert", label: "Revert", on: root.canRevert });
        return a;
    }

    /** Tras Preview con el teclado, el foco va a Keep changes en cuanto exista (no a Revert). */
    property string wantFocus: ""
    function act(id) {
        if (id === "preview" && root.canPreview) {
            if (ThemePreview.preview(root.selected, root.screenName) && root.zone === "actions") root.wantFocus = "keep";
        }
        else if (id === "keep" && root.canKeep) ThemePreview.keep();
        else if (id === "revert" && root.canRevert) ThemePreview.revert("Reverted");
        else if (id === "retry") ThemePreview.retry();
        else if (id === "later" && root.canUseLater) ThemePreview.saveForLater(root.selected);
    }

    // ---- selección -------------------------------------------------------

    function indexOf(p) { return Math.max(0, root.profiles.indexOf(p)); }

    function move(delta) {
        root.sel = Math.max(0, Math.min(root.count - 1, root.sel + delta));
    }
    onSelChanged: {
        if (Motion.off) root.pos = root.sel;             // Off: sin recorrido
        root.requestSamples();
    }

    /** Las muestras que falten, la seleccionada primero y después hacia fuera. */
    function requestSamples() {
        if (!root.open) return;
        const order = [];
        for (let d = 0; d < root.count; d++)
            for (const i of d === 0 ? [root.sel] : [root.sel - d, root.sel + d])
                if (i >= 0 && i < root.count) order.push(root.profiles[i]);
        ThemeSamples.ensure(order);
    }

    FrameAnimation {
        running: root.open && root.pos !== root.sel
        onTriggered: {
            if (Motion.off) { root.pos = root.sel; return; }
            const k = 1 - Math.exp(-frameTime / Motion.chaseTau);
            const next = root.pos + (root.sel - root.pos) * k;
            root.pos = Math.abs(next - root.sel) < 0.001 ? root.sel : next;
        }
    }

    onOpenChanged: {
        if (root.open) {
            // al abrir, el foco en lo que se ve: la prueba en curso o el confirmado
            root.sel = root.indexOf(root.live && root.target.length > 0 ? root.target : root.confirmed);
            root.pos = root.sel;
            root.zone = "strip";
            root.requestSamples();
            ThemePreview.viewOpened(root.screenName, "theme");
        } else {
            // cerrar sin confirmar (Esc, clic fuera, otra surface) vuelve a lo confirmado si no
            // queda otro control abierto aquí (12C: Settings → Colors lo es). Un traslado a otra
            // pantalla llega con el propietario YA cambiado: no revierte.
            ThemePreview.viewClosed(root.screenName, "theme");
        }
    }
    Connections {
        target: ThemeSamples
        function onContextChanged() { Qt.callLater(root.requestSamples); }
    }

    /** Back/Forward: la selección por id. Nunca relanza una preview. */
    function saveContext() { return { profile: root.selected }; }
    function restoreContext(ctx) {
        if (ctx && typeof ctx.profile === "string") {
            root.sel = root.indexOf(ctx.profile);
            root.pos = root.sel;
        }
    }

    function goActions() {
        // sin ninguna acción disponible (lo seleccionado ya está aplicado) el foco no se va a una
        // fila de botones apagados donde no se vería
        const i = root.actions.findIndex(a => a.on);
        if (i < 0) return;
        root.zone = "actions";
        root.actIndex = i;
    }
    function stepAction(dir) {
        const n = root.actions.length;
        for (let k = 1; k <= n; k++) {
            const i = root.actIndex + dir * k;
            if (i < 0 || i >= n) break;
            if (root.actions[i].on) { root.actIndex = i; return true; }
        }
        return false;
    }

    function keyPressed(event) {
        const k = event.key;
        const shift = (event.modifiers & Qt.ShiftModifier) !== 0;
        if (k === Qt.Key_S && root.zone === "strip") {
            if (!event.isAutoRepeat && root.host) root.host.openSettingsAt("theme/colors");
            event.accepted = true;
            return;
        }
        if (root.zone === "strip") {
            if (k === Qt.Key_Left) root.move(-1);
            else if (k === Qt.Key_Right) root.move(1);
            else if (k === Qt.Key_Home) root.sel = 0;
            else if (k === Qt.Key_End) root.sel = root.count - 1;
            else if (k === Qt.Key_Tab || k === Qt.Key_Down) root.goActions();
            else if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space) {
                // Enter/Space seleccionan (el foco ya es la selección); una muestra fallida se reintenta
                const sm = ThemeSamples.sampleOf(root.selected);
                if (sm.state === "error") ThemeSamples.retry(root.selected);
            }
            else return;                                    // Esc cae: cierra (y revierte)
            event.accepted = true;
            return;
        }
        // actions
        if (k === Qt.Key_Left || (k === Qt.Key_Tab && shift) || k === Qt.Key_Backtab) {
            if (!root.stepAction(-1) && (k === Qt.Key_Tab || k === Qt.Key_Backtab)) root.zone = "strip";
        } else if (k === Qt.Key_Right || k === Qt.Key_Tab) {
            if (!root.stepAction(1) && k === Qt.Key_Tab) root.zone = "strip";
        } else if (k === Qt.Key_Up) {
            root.zone = "strip";
        } else if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space) {
            const a = root.actions[root.actIndex];
            if (a && a.on) root.act(a.id);
        } else return;
        event.accepted = true;
    }
    /** Si la acción enfocada se apaga (Preview tras pedirla), el foco pasa a la siguiente viva. */
    onActionsChanged: {
        if (root.zone !== "actions") return;
        const want = root.wantFocus.length > 0 ? root.actions.findIndex(a => a.id === root.wantFocus && a.on) : -1;
        if (want >= 0) { root.actIndex = want; root.wantFocus = ""; return; }
        if (!(root.actions[root.actIndex] || {}).on && !root.stepAction(1) && !root.stepAction(-1))
            root.zone = "strip";
    }
    onPhaseChanged: if (root.phase !== "preparing" && root.phase !== "active") root.wantFocus = ""

    // ---- estado en palabras ------------------------------------------------

    readonly property string statusText: {
        if (root.elsewhere)
            return "Preview active on " + root.opOwner + " · open Visual profiles there, or click here to take it over";
        if (root.phase === "failed")
            return ThemePreview.error + (ThemePreview.errorDetail.length > 0 ? " · " + ThemePreview.errorDetail : "");
        if (root.phase === "restoring") return "Restoring your theme…";
        if (root.phase === "keeping") return "Keeping " + root.nameOf(root.previewing) + "…";
        if (root.phase === "recovering") return "Restoring a preview left open before…";
        if (root.phase === "preparing")
            return "Preparing preview of " + root.nameOf(ThemePreview.preparing) + "…";
        if (root.phase === "active") {
            if (ThemePreview.error.length > 0) return ThemePreview.error;
            const hooks = ThemePreview.hookFailures.length > 0
                ? " · reload did not answer: " + ThemePreview.hookFailures.join(", ") : "";
            const desktop = ThemePreview.desktopWarning ? " · " + ThemePreview.desktopWarning : "";
            if (root.selected !== root.previewing)
                return "Previewing " + root.nameOf(root.previewing) + " · selected " + root.nameOf(root.selected)
                    + ": press Preview to try it" + hooks + desktop;
            // F-d: qué apps abiertas no se recolorean solas (o el aviso genérico si ninguna conocida)
            return "Preview active · " + (ThemePreview.reopenNow.length > 0
                                          ? ThemePreview.reopenText(ThemePreview.reopenNow, ThemePreview.lightnessFrom !== ThemePreview.lightnessTo)
                                          : "external apps follow your provider and may need reopening") + hooks + desktop;
        }
        // F2c: antes de pulsar, por qué no (navegar por los perfiles sigue)
        if (!root.live && root.capWhy.length > 0)
            return root.nameOf(root.selected) + " can't be previewed here · " + root.capWhy;
        if (root.noWall && !ThemePreview.isStatic(root.selected))
            return "No wallpaper: dynamic colours need one to preview";
        const r = ThemePreview.lastResult;
        if (r && r.kind === "kept") return "Kept " + root.nameOf(r.profile)
            + (r.reopen && r.reopen.length > 0 ? " · " + ThemePreview.reopenText(r.reopen, r.modeChanged) : "");
        if (r && r.kind === "external") return "Preview stopped: the theme or wallpaper changed outside it";
        if (r && r.kind === "reverted" && r.reason === "Reverted") return "Restored your theme";
        return "← →  choose    ⇥  actions    Preview tries it on the whole desktop    S  settings    Esc  close";
    }
    readonly property string statusTone: root.phase === "failed" || (root.phase === "active" && ThemePreview.error.length > 0)
        ? "danger" : root.phase === "active" && (ThemePreview.hookFailures.length > 0 || ThemePreview.desktopWarning.length > 0) ? "warn"
        : !root.live && root.capWhy.length > 0 ? "warn" : ""

    // ---- cabecera ----------------------------------------------------------

    Item {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 20 * root.s

        Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: 7 * root.s
            Icon {
                anchors.verticalCenter: parent.verticalCenter
                name: "palette"
                size: 13 * root.s
                color: Theme.primary
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.nameOf(root.selected)
                color: Theme.fg
                font.family: Typography.ui
                font.pixelSize: Typography.body * root.s
                font.weight: Font.DemiBold
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: (root.sel + 1) + " / " + root.count
                    + (root.selected === "static" ? "  ·  static palette"
                       : ThemePreview.isPreset(root.selected) ? "  ·  static palette, "
                         + (ThemePreview.normOpts(root.selected).lightness === "light" ? "light" : "dark")
                       : "  ·  " + (ThemePreview.sampleOpts.lightness === "light" ? "light, " : "")
                         + (ThemePreview.sampleOpts.source === "wallpaper" ? "from the wallpaper" : "from " + ThemePreview.sampleOpts.source))
                color: Theme.outlineText
                font.family: Typography.ui
                font.pixelSize: Typography.caption * root.s
            }
        }

        Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8 * root.s

            /** Preview active / Applied: qué se está viendo en el escritorio. */
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                height: 18 * root.s
                width: stateText.implicitWidth + 14 * root.s
                radius: Metrics.pill(height)
                color: root.live ? Theme.selBg : "transparent"
                border.width: root.live ? 0 : 1
                border.color: Theme.outline
                Text {
                    id: stateText
                    anchors.centerIn: parent
                    text: root.live ? "Preview active" : "Applied: " + ThemePreview.describe(root.confirmed, ThemePreview.confirmedOpts)
                    color: root.live ? Theme.primary : Theme.fgVariant
                    font.family: Typography.ui
                    font.pixelSize: Typography.caption * root.s
                    font.weight: root.live ? Font.DemiBold : Font.Normal
                }
            }

            Item {
                id: cfgBtn
                anchors.verticalCenter: parent.verticalCenter
                width: 18 * root.s
                height: 18 * root.s
                Accessible.role: Accessible.Button
                Accessible.name: "Colour settings (S)"
                Accessible.onPressAction: if (root.host) root.host.openSettingsAt("theme/colors")
                Icon {
                    anchors.centerIn: parent
                    name: "cog"
                    size: 12 * root.s
                    color: cfgArea.containsMouse ? Theme.fg : Theme.fgVariant
                }
                MouseArea {
                    id: cfgArea
                    anchors.fill: parent
                    anchors.margins: -6 * root.s
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: if (root.host) root.host.openSettingsAt("theme/colors")
                }
            }
        }
    }

    // ---- la tira -------------------------------------------------------------

    /** Tamaño base de una tarjeta; las laterales son la misma tarjeta escalada. */
    readonly property real cardW: 232
    readonly property real cardH: 150
    /*
     * Ancho y centro de cada hueco. Antes [232,146,116,92,76] en [0,168,282,366,430]: cada tarjeta
     * se montaba ~20 px sobre la siguiente y tapaba su título y sus colores (2026-10-01, pedido del
     * usuario: «mega superposiciones de cajas»). Ahora 10 px de aire entre bordes; la tira recorta
     * la que no cabe, que asoma por el borde.
     */
    readonly property var slotW: [232, 132, 104, 84, 70]
    readonly property var slotCX: [0, 192, 320, 424, 511]
    readonly property var slotBright: [1, 0.84, 0.68, 0.52, 0.38]
    function slotLerp(arr, ao) {
        if (ao >= 4) return arr[4];
        const i = Math.floor(ao);
        return arr[i] + (arr[i + 1] - arr[i]) * (ao - i);
    }

    Item {
        id: strip
        anchors.top: header.bottom
        anchors.topMargin: 8 * root.s
        anchors.left: parent.left
        anchors.right: parent.right
        height: (root.cardH + 8) * root.s
        clip: true

        Repeater {
            model: root.profiles

            delegate: Item {
                id: tile
                required property int index
                required property string modelData

                readonly property real off: tile.index - root.pos
                readonly property real ao: Math.abs(tile.off)
                readonly property bool isSel: tile.index === root.sel
                readonly property bool isApplied: tile.modelData === root.confirmed
                readonly property bool isPreviewing: tile.modelData === root.previewing && root.live
                readonly property bool isPreparing: tile.modelData === ThemePreview.preparing
                    && root.phase === "preparing"
                readonly property var sample: { void ThemeSamples.samples; void Colors.sta; return ThemeSamples.sampleOf(tile.modelData); }
                readonly property bool ready: tile.sample.state === "ready" && tile.sample.roles !== null
                function role(k, fallback) {
                    const v = tile.ready ? tile.sample.roles[k] : undefined;
                    return typeof v === "string" && /^#[0-9a-fA-F]{6}$/.test(v) ? v : fallback;
                }
                /** 1 en el centro → 0 en las laterales: qué composición se ve. */
                readonly property real detail: Math.max(0, Math.min(1, 1 - tile.ao * 1.6))

                width: root.cardW * root.s
                height: root.cardH * root.s
                scale: root.slotLerp(root.slotW, tile.ao) / root.cardW
                x: strip.width / 2 + (tile.off < 0 ? -1 : 1) * root.slotLerp(root.slotCX, tile.ao) * root.s - width / 2
                y: (strip.height - height) / 2
                z: 10 - tile.ao
                visible: tile.ao <= 4.5

                Accessible.role: Accessible.ListItem
                Accessible.name: root.nameOf(tile.modelData)
                    + (ThemePreview.isStatic(tile.modelData) ? ", static" : "")
                    + (tile.isApplied ? ", applied" : "") + (tile.isPreviewing ? ", previewing" : "")
                    + (tile.isSel ? ", selected" : "")
                Accessible.selected: tile.isSel

                ClippingRectangle {
                    id: card
                    anchors.fill: parent
                    radius: Metrics.r(14) * root.s
                    color: tile.role("surface", Theme.surfaceContainerLowest)

                    layer.enabled: tile.isSel
                    layer.effect: MultiEffect {
                        shadowEnabled: true
                        shadowColor: Theme.shadow
                        shadowBlur: 0.7
                        shadowVerticalOffset: 4 * root.s
                    }

                    // -- composición completa (la central) --------------------------
                    Item {
                        anchors.fill: parent
                        anchors.margins: 11 * root.s
                        visible: tile.ready && tile.detail > 0.01
                        opacity: tile.detail

                        Text {
                            id: cardName
                            anchors.left: parent.left
                            anchors.top: parent.top
                            // F-c: los nombres de los presets son largos: sin pisar las marcas de la esquina
                            width: Math.max(0, parent.width - marks.width - 6 * root.s)
                            elide: Text.ElideRight
                            text: root.nameOf(tile.modelData)
                            color: tile.role("on_surface", Theme.fg)
                            font.family: Typography.ui
                            font.pixelSize: 14 * root.s
                            font.weight: Font.DemiBold
                        }

                        /** Una ventana en miniatura: contenedor, texto, secundario y un botón de acento. */
                        Rectangle {
                            id: mini
                            anchors.top: cardName.bottom
                            anchors.topMargin: 7 * root.s
                            anchors.left: parent.left
                            anchors.right: parent.right
                            height: 58 * root.s
                            radius: Metrics.r(9) * root.s
                            color: tile.role("surface_container", Theme.surfaceContainer)
                            border.width: 1
                            border.color: tile.role("outline", Theme.outline)

                            Text {
                                x: 9 * root.s
                                y: 7 * root.s
                                text: "Aa  Readable text"
                                color: tile.role("on_surface", Theme.fg)
                                font.family: Typography.ui
                                font.pixelSize: 12 * root.s
                            }
                            Text {
                                x: 9 * root.s
                                y: 24 * root.s
                                text: "Secondary line"
                                color: tile.role("on_surface_variant", Theme.fgVariant)
                                font.family: Typography.ui
                                font.pixelSize: 10 * root.s
                            }
                            Row {
                                x: 9 * root.s
                                anchors.bottom: parent.bottom
                                anchors.bottomMargin: 7 * root.s
                                spacing: 5 * root.s
                                Rectangle {
                                    width: 7 * root.s; height: 7 * root.s; radius: Metrics.pill(width)
                                    anchors.verticalCenter: parent.verticalCenter
                                    color: tile.role("tertiary", Colors.tertiary)
                                }
                                Rectangle {
                                    width: secText.implicitWidth + 10 * root.s; height: 13 * root.s; radius: Metrics.pill(height)
                                    color: "transparent"
                                    border.width: 1
                                    border.color: tile.role("secondary", Colors.secondaryRole)
                                    Text {
                                        id: secText
                                        anchors.centerIn: parent
                                        text: "tag"
                                        color: tile.role("secondary", Colors.secondaryRole)
                                        font.family: Typography.ui
                                        font.pixelSize: 8.5 * root.s
                                    }
                                }
                            }
                            Rectangle {
                                anchors.right: parent.right
                                anchors.rightMargin: 9 * root.s
                                anchors.bottom: parent.bottom
                                anchors.bottomMargin: 7 * root.s
                                width: btnText.implicitWidth + 16 * root.s
                                height: 18 * root.s
                                radius: Metrics.pill(height)
                                color: tile.role("primary", Theme.primary)
                                Text {
                                    id: btnText
                                    anchors.centerIn: parent
                                    text: "Button"
                                    color: tile.role("on_primary", Theme.fgOnPrimary)
                                    font.family: Typography.ui
                                    font.pixelSize: 9.5 * root.s
                                    font.weight: Font.DemiBold
                                }
                            }
                        }

                        /** La franja: cinco colores para juzgar tono y contraste de un vistazo. */
                        Row {
                            id: swatches
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            height: 22 * root.s
                            spacing: 5 * root.s
                            Repeater {
                                model: ["primary", "secondary", "tertiary", "surface_container_high", "outline"]
                                delegate: Rectangle {
                                    required property string modelData
                                    width: (swatches.width - 4 * 5 * root.s) / 5
                                    height: swatches.height
                                    radius: Metrics.r(6) * root.s
                                    color: tile.role(modelData, Theme.outline)
                                    border.width: modelData === "surface_container_high" ? 1 : 0
                                    border.color: tile.role("outline", Theme.outline)
                                }
                            }
                        }
                    }

                    // -- composición lateral: nombre y acentos principales --------------
                    Item {
                        anchors.fill: parent
                        anchors.margins: 14 * root.s
                        visible: tile.ready && tile.detail < 0.99
                        opacity: 1 - tile.detail
                        Text {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.top: parent.top
                            text: root.nameOf(tile.modelData)
                            color: tile.role("on_surface", Theme.fg)
                            // en las de la derecha, el borde izquierdo lo tapa la central
                            horizontalAlignment: tile.off > 0 ? Text.AlignRight : Text.AlignLeft
                            elide: tile.off > 0 ? Text.ElideLeft : Text.ElideRight
                            font.family: Typography.ui
                            font.pixelSize: 22 * root.s
                            font.weight: Font.DemiBold
                        }
                        Row {
                            id: accents
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            height: 40 * root.s
                            spacing: 8 * root.s
                            Repeater {
                                model: ["primary", "secondary", "tertiary"]
                                delegate: Rectangle {
                                    required property string modelData
                                    width: (accents.width - 2 * 8 * root.s) / 3
                                    height: accents.height
                                    radius: Metrics.r(9) * root.s
                                    color: tile.role(modelData, Theme.outline)
                                }
                            }
                        }
                    }

                    // -- sin muestra: pendiente, fallida o sin fondo (nunca una paleta inventada) --
                    Column {
                        anchors.centerIn: parent
                        width: parent.width - 24 * root.s
                        visible: !tile.ready
                        spacing: 6 * root.s
                        Text {
                            width: parent.width
                            horizontalAlignment: Text.AlignHCenter
                            text: root.nameOf(tile.modelData)
                            color: Theme.fg
                            elide: Text.ElideRight
                            font.family: Typography.ui
                            font.pixelSize: (tile.detail > 0.5 ? 14 : 22) * root.s
                            font.weight: Font.DemiBold
                        }
                        Text {
                            width: parent.width
                            horizontalAlignment: Text.AlignHCenter
                            wrapMode: Text.WordWrap
                            // F2c (visto en pantalla): sin proveedor no hay muestra ni tiene sentido reintentar;
                            // el motivo largo ya está en la línea de estado
                            readonly property bool blocked: ThemePreview.whyNot(tile.modelData).length > 0
                            text: tile.sample.state === "nowall" ? "No sample: wallpaper unavailable"
                                : tile.sample.state === "error" && blocked ? "No sample on this computer"
                                : tile.sample.state === "error" ? "Sample unavailable" + (tile.isSel ? " · ⏎ retry" : "")
                                : "Generating samples…"
                            color: tile.sample.state === "error" && !blocked ? Theme.errorColor : Theme.fgVariant
                            font.family: Typography.ui
                            font.pixelSize: (tile.detail > 0.5 ? 11 : 16) * root.s
                        }
                    }

                    /** Profundidad por atenuación (suave: las muestras tienen que seguir juzgándose). */
                    Rectangle {
                        anchors.fill: parent
                        color: "black"
                        opacity: 1 - root.slotLerp(root.slotBright, tile.ao)
                    }
                }

                /** Marcas: Static · Applied · Previewing · Preparing (la del foco es el borde). */
                Row {
                    id: marks
                    // central: arriba a la derecha; laterales: bajo el nombre (su borde interior
                    // queda tapado por la central)
                    x: tile.detail > 0.5 || tile.off > 0 ? tile.width - width - (tile.detail > 0.5 ? 8 : 14) * root.s
                        : 14 * root.s
                    y: (tile.detail > 0.5 ? 8 : tile.ready ? 50 : 14) * root.s
                    spacing: 4 * root.s
                    // en las laterales también (Applied se ve aunque el foco esté en otra): la
                    // tarjeta va escalada, así que allí la marca se dibuja más grande
                    readonly property real big: tile.detail > 0.5 ? 1 : 1.55
                    Repeater {
                        model: {
                            const m = [];
                            if (ThemePreview.isStatic(tile.modelData)) m.push({ t: "Static", strong: false });
                            if (tile.isPreparing) m.push({ t: "Preparing preview", strong: true });
                            else if (tile.isPreviewing) m.push({ t: "Previewing", strong: true });
                            if (tile.isApplied) m.push({ t: "Applied", strong: !root.live });
                            return m;
                        }
                        delegate: Rectangle {
                            id: badge
                            required property var modelData
                            height: Typography.box(16 * marks.big, Typography.micro * marks.big, root.s)
                            width: badgeText.implicitWidth + 12 * marks.big * root.s
                            radius: Metrics.pill(height)
                            color: badge.modelData.strong ? Theme.primary : Qt.alpha(Theme.surface, 0.85)
                            border.width: badge.modelData.strong ? 0 : 1
                            border.color: Theme.outline
                            Text {
                                id: badgeText
                                anchors.centerIn: parent
                                text: badge.modelData.t
                                color: badge.modelData.strong ? Theme.fgOnPrimary : Theme.fg
                                font.family: Typography.ui
                                font.pixelSize: Typography.micro * marks.big * root.s
                                font.weight: Font.DemiBold
                            }
                        }
                    }
                }

                /** Selected: el borde. Más fino cuando el teclado está en las acciones. */
                Rectangle {
                    anchors.fill: parent
                    anchors.margins: -3 * root.s
                    radius: Metrics.r(16) * root.s
                    color: "transparent"
                    visible: tile.isSel
                    border.width: (root.zone === "strip" ? 2 : 1) * Metrics.focusWidth * root.s
                    border.color: root.zone === "strip" ? Theme.primary : Theme.selBorder
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        root.zone = "strip";
                        if (!tile.isSel) root.sel = tile.index;
                        else if (tile.sample.state === "error") ThemeSamples.retry(tile.modelData);
                    }
                }
            }
        }

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.NoButton
            property real acc: 0
            onWheel: (event) => {
                acc += (event.angleDelta.y !== 0 ? event.angleDelta.y : -event.angleDelta.x) / 120;
                const notches = Math.trunc(acc);
                if (notches !== 0) {
                    root.move(-notches);
                    acc -= notches;
                }
                event.accepted = true;
            }
        }
    }

    // ---- pie: estado y acciones ----------------------------------------------

    /** El estado en los renglones que pida (hasta tres), medido con un Text oculto como el pie de Wallpaper (2026-11-18). */
    Text { id: statusFit; visible: false; width: (Metrics.themeW - root.mLeft - root.mRight) * root.s
           text: statusLine.text; font: statusLine.font; wrapMode: Text.WordWrap; maximumLineCount: 3 }
    readonly property int statusLines: Math.max(1, statusFit.lineCount)
    /** Lo que crece el estado con el segundo renglón (SurfaceHost lo suma al alto del panel). */
    readonly property real statusExtra: Math.max(0, statusRow.height - 20 * root.s)

    Item {
        id: statusRow
        anchors.top: strip.bottom
        anchors.topMargin: 4 * root.s
        anchors.left: parent.left
        anchors.right: parent.right
        height: Math.max(20 * root.s, statusLine.visible ? statusFit.implicitHeight : 0)

        Text {
            id: statusLine
            anchors.fill: parent
            visible: root.statusTone.length === 0
            verticalAlignment: Text.AlignVCenter
            horizontalAlignment: Text.AlignHCenter
            text: TextWrap.keepHints(root.statusText)
            color: root.live ? Theme.fg : Theme.outlineText
            wrapMode: Text.WordWrap
            maximumLineCount: root.statusLines
            elide: Text.ElideRight
            font.family: Typography.ui
            font.pixelSize: Typography.caption * root.s
        }
        Notice {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            visible: root.statusTone.length > 0
            s: root.s
            tone: root.statusTone
            text: root.statusText
        }
    }

    Row {
        id: actionRow
        anchors.top: statusRow.bottom
        anchors.topMargin: 8 * root.s
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: 8 * root.s

        Repeater {
            model: root.actions
            delegate: ActionButton {
                id: btn
                required property var modelData
                required property int index
                s: root.s
                label: btn.modelData.label
                enabled: btn.modelData.on
                primary: btn.modelData.on && ((btn.modelData.id === "keep" && root.canKeep)
                    || (btn.modelData.id === "preview" && !root.canKeep))
                focused: root.zone === "actions" && root.actIndex === btn.index
                Accessible.name: btn.modelData.label
                onTriggered: {
                    root.zone = "actions";
                    root.actIndex = btn.index;
                    root.act(btn.modelData.id);
                }
            }
        }
    }
}
