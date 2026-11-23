pragma ComponentBehavior: Bound

import QtQuick
import "../theme"
import "../services"

/**
 * Una clave de Sumi SDDM en Settings → Login screen (2026-11-22). El control sale del tipo del esquema que da
 * `sumi-sddm config schema` y el valor es de `SddmTheme` (nunca de settings.json):
 *
 *   bool → Toggle · enum → Choice · number/integer → Slider + valor · color → muestra + campo hex
 *   string → campo de texto · path (el fondo) → campo de ruta; Esc dentro del campo cancela, «Remove» lo quita
 *   avatar (no es del tema: AccountsService) → el PathField redondo de Settings, como el avatar del Lock
 *
 * Aquí no se valida nada en serio: la CLI valida con su lectura estricta y, si rechaza, SddmTheme lo dice y
 * vuelve a enseñar lo guardado. Este archivo sólo evita enviar lo que a todas luces no vale (un hex mal escrito).
 */
Item {
    id: root

    property real s: 1
    property string key: ""
    property bool focused: false
    property real availableWidth: 0
    /** Lo más que debe medir el control para quedarse en la línea del nombre (la ventana Login screen, 2026-11-23);
     *  0 = el tamaño de siempre (Settings). Sólo encoge el deslizador, entre 96 y 180 px. */
    property real fitWidth: 0
    /** Terminó la edición de un campo de texto: Settings recupera el teclado. */
    signal finished()

    readonly property var entry: SddmTheme.keys[root.key] || ({ type: "", label: root.key === "avatar" ? "Avatar" : "" })
    readonly property var value: SddmTheme.valueOf(root.key)
    readonly property string type: root.key === "avatar" ? "avatar" : String(root.entry.type || "")
    readonly property bool textual: root.type === "string" || root.type === "color" || root.type === "path"
                                    || root.type === "avatar"

    /** Enter / ←/→ desde la fila (Settings.adjust). */
    function activate(dir) {
        if (root.textual) { if (dir === 0 && loader.item && loader.item.startEdit) loader.item.startEdit(); }
        else SddmTheme.step(root.key, dir);
    }
    function startEdit() { root.activate(0); }

    implicitWidth: loader.item ? loader.item.implicitWidth : 0
    implicitHeight: loader.item ? loader.item.implicitHeight : 28 * root.s

    Loader {
        id: loader
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        sourceComponent: root.type === "bool" ? boolC
            : root.type === "enum" ? enumC
            : root.type === "number" || root.type === "integer" ? numberC
            : root.type === "color" ? colorC
            : root.type === "path" ? pathC
            : root.type === "string" ? textC
            : root.type === "avatar" ? avatarC : null
    }

    Component {
        id: boolC
        Toggle {
            s: root.s
            label: String(root.entry.label)
            on: root.value === true
            focused: root.focused
            onToggled: SddmTheme.set(root.key, !(root.value === true))
        }
    }
    Component {
        id: enumC
        Choice {
            s: root.s
            name: String(root.entry.label)
            spacious: true
            availableWidth: root.availableWidth
            focused: root.focused
            options: (root.entry.values || []).map(v => ({ label: SddmTheme.enumLabel(v), value: v }))
            value: root.value
            onPicked: (v) => SddmTheme.set(root.key, v)
        }
    }
    Component {
        id: numberC
        Row {
            id: num
            readonly property var e: root.entry
            // allowZero (p. ej. «Collapse after»: 0 = nunca): la pista empieza en 0
            readonly property real lo: num.e.allowZero ? 0 : Number(num.e.min)
            readonly property real hi: Number(num.e.max)
            readonly property real span: Math.max(1e-9, num.hi - num.lo)
            readonly property real stepv: Number(num.e.step || (root.type === "integer" ? 1 : 0.05))
            spacing: 10 * root.s
            Slider {
                anchors.verticalCenter: parent.verticalCenter
                width: root.fitWidth > 0
                    ? Math.max(96 * root.s, Math.min(180 * root.s, root.fitWidth - num.spacing - numText.width))
                    : 180 * root.s
                s: root.s
                value: (Number(root.value) - num.lo) / num.span
                step: num.stepv / num.span
                focused: root.focused
                ring: false
                label: String(num.e.label)
                Accessible.description: numText.text
                onMoved: (v) => {
                    let n = num.lo + Math.round(v * num.span / num.stepv) * num.stepv;
                    if (num.e.allowZero && n > 0 && n < num.e.min) n = n < num.e.min / 2 ? 0 : num.e.min;
                    n = Math.max(num.lo, Math.min(num.hi, Math.round(n * 1000) / 1000));
                    if (n !== Number(root.value)) SddmTheme.set(root.key, n);
                }
            }
            Text {
                id: numText
                anchors.verticalCenter: parent.verticalCenter
                width: Math.max(Math.ceil(implicitWidth), Math.ceil(numMetrics.advanceWidth("600 s") * 1.1))
                text: num.e.allowZero && Number(root.value) === 0 ? "Never"
                    : (root.type === "integer" ? String(Math.round(Number(root.value)))
                       : String(Math.round(Number(root.value) * 100) / 100)) + (num.e.unit ? " " + num.e.unit : "")
                color: Theme.fg
                font.family: Typography.ui
                font.pixelSize: Typography.body * root.s
                font.features: { "tnum": 1 }
                FontMetrics { id: numMetrics; font: numText.font }
            }
        }
    }
    Component {
        id: colorC
        Row {
            spacing: 8 * root.s
            function startEdit() { hex.startEdit(); }
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 16 * root.s
                height: width
                radius: Metrics.pill(width)
                color: String(root.value || "#000000")
                border.width: 1
                border.color: Qt.alpha(Theme.outline, 0.5)
            }
            FolderField {
                id: hex
                anchors.verticalCenter: parent.verticalCenter
                s: root.s
                glyph: "palette"
                placeholder: String(root.entry["default"] || "#000000")
                idleText: "Type a colour"
                accessibleName: String(root.entry.label) + " colour"
                note: String(root.value || "")
                onCommitted: (text) => {
                    const t = text.trim().replace(/^([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/, "#$1");
                    if (/^#([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/.test(t)) SddmTheme.set(root.key, t.toLowerCase());
                    else SddmTheme.error = "“" + text.trim() + "” is not a colour · use #rrggbb";
                }
                onFinished: root.finished()
            }
        }
    }
    Component {
        id: textC
        FolderField {
            s: root.s
            glyph: "edit"
            placeholder: String(root.entry["default"] || "")
            idleText: root.key === "fontFamily" ? "Bundled Inter" : "Default"
            accessibleName: String(root.entry.label)
            note: String(root.value || "")
            // vacío = volver al valor por defecto (FolderField no envía un texto vacío: Esc + el botón de la fila)
            onCommitted: (text) => SddmTheme.set(root.key, text.trim())
            onFinished: root.finished()
        }
    }
    Component {
        id: pathC
        Row {
            spacing: 8 * root.s
            function startEdit() { wall.startEdit(); }
            FolderField {
                id: wall
                anchors.verticalCenter: parent.verticalCenter
                s: root.s
                glyph: "image"
                placeholder: "~/Pictures/wallpaper.jpg"
                idleText: "Built-in background"
                accessibleName: "Wallpaper image"
                note: String(root.value || "").length > 0 ? String(root.value).replace(/^backgrounds\//, "") : ""
                onCommitted: (text) => SddmTheme.setWallpaper(text)
                onFinished: root.finished()
            }
            ActionButton {
                anchors.verticalCenter: parent.verticalCenter
                visible: String(root.value || "").length > 0
                s: root.s
                label: "Remove"
                onTriggered: SddmTheme.clearWallpaper()
            }
        }
    }
    Component {
        id: avatarC
        Row {
            spacing: 8 * root.s
            function startEdit() { face.startEdit(); }
            PathField {
                id: face
                anchors.verticalCenter: parent.verticalCenter
                s: root.s
                round: true
                value: String(root.value || "")
                placeholder: ""
                fallbackNote: "the login screen shows your initials"
                // vacío = quitar; el mismo archivo = nada que hacer
                onCommitted: (text) => {
                    const t = String(text || "").trim();
                    if (t.length === 0) SddmTheme.clearAvatar();
                    else if (t !== String(root.value || "")) SddmTheme.setAvatar(t);
                    root.finished();
                }
            }
            ActionButton {
                anchors.verticalCenter: parent.verticalCenter
                visible: SddmTheme.isSet("avatar")
                s: root.s
                label: "Remove"
                onTriggered: SddmTheme.clearAvatar()
            }
        }
    }
}
