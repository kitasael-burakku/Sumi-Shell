import QtQuick
import "../theme"

/**
 * El fetch del Lock (fase 15, LOCK-D07 y LOCK-D14): la imagen configurable y OS, kernel, WM, shell,
 * CPU y GPU. La memoria NO va aquí: sólo en su medidor.
 *
 * Todo sale del contexto (`context.fetch`, `context.fetchImageSource`), nunca de `SystemInfo`
 * directo (LK-09): la preview lo finge igual que el resto. Imagen ausente o rota → el hueco se
 * queda con su glifo (decisión 3); el texto no se mueve.
 */
Rectangle {
    id: root

    property var context
    property real s: 1
    /** Columna ancha: la imagen arriba y las filas debajo; estrecha: la imagen a la izquierda. */
    property bool vertical: false
    /** Lado de la imagen en vertical (lo reparte el panel según el alto que sobra). */
    property real imageSide: 140 * root.s

    readonly property var fetch: root.context && root.context.fetch ? root.context.fetch : ({})
    readonly property string imagePath: root.context ? (root.context.fetchImageSource || "") : ""
    readonly property var rows: [
        { key: "OS",     value: root.fetch.os,     tint: Theme.tintPrimary },
        { key: "KERNEL", value: root.fetch.kernel, tint: Theme.tintPrimarySoft },
        { key: "WM",     value: root.fetch.wm,     tint: Theme.tintSecondary },
        { key: "SHELL",  value: root.fetch.shell,  tint: Theme.tintSecondarySoft },
        { key: "CPU",    value: root.fetch.cpu,    tint: Theme.tintTertiary },
        { key: "GPU",    value: root.fetch.gpu,    tint: Theme.tintTertiarySoft }
    ]

    implicitHeight: (root.vertical ? img.height + Metrics.sp3 * root.s + list.implicitHeight
                                   : Math.max(img.height, list.implicitHeight)) + Metrics.sp3 * 2 * root.s
    radius: Metrics.rMd * root.s
    color: Theme.tileBg

    LockImage {
        id: img
        x: root.vertical ? Math.round((root.width - width) / 2) : Metrics.sp3 * root.s
        y: root.vertical ? Math.round((root.height - root.implicitHeight) / 2) + Metrics.sp3 * root.s
                         : Math.round((root.height - height) / 2)
        width: root.vertical ? root.imageSide : 92 * root.s
        height: root.vertical ? root.imageSide : 108 * root.s
        s: root.s
        source: root.imagePath.length > 0 ? "file://" + root.imagePath : ""
        fillMode: Image.PreserveAspectCrop
        fallbackIcon: "image"
    }

    Column {
        id: list
        x: root.vertical ? Metrics.sp4 * root.s : img.x + img.width + Metrics.sp3 * root.s
        y: root.vertical ? img.y + img.height + Metrics.sp3 * root.s : Math.round((root.height - implicitHeight) / 2)
        width: root.width - x - (root.vertical ? Metrics.sp4 : Metrics.sp3) * root.s
        spacing: 3 * root.s

        Repeater {
            model: root.rows
            delegate: Row {
                id: row
                required property var modelData
                width: list.width
                spacing: Metrics.sp2 * root.s

                Text {
                    width: 46 * root.s
                    text: row.modelData.key
                    color: row.modelData.tint
                    font.family: Typography.uiChosen
                    font.weight: Typography.wStrong
                    font.pixelSize: Typography.micro * root.s
                    font.letterSpacing: 0.6 * root.s
                    anchors.baseline: val.baseline
                }
                Text {
                    id: val
                    width: row.width - 46 * root.s - Metrics.sp2 * root.s
                    text: row.modelData.value && row.modelData.value.length > 0 ? row.modelData.value : "—"
                    elide: Text.ElideRight
                    color: row.modelData.value ? Theme.fg : Theme.outlineText
                    font.family: Typography.uiChosen
                    font.pixelSize: Typography.caption * root.s
                }
            }
        }
    }
}
