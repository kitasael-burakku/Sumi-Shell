pragma ComponentBehavior: Bound

import QtQuick
import "../theme"
import "../services"

/**
 * Settings UI independiente (2026-11-07): el panel contextual, a la derecha de la página
 * cuando la ventana es ancha (`Metrics.settingsContextW`). Por debajo de ese ancho no se
 * muestra y nada de lo suyo se pierde: las vistas previas vuelven a su sitio en la página.
 *
 * Sólo lee de Settings (`ctl`, la superficie) y nunca guarda nada propio:
 *   - una vista previa de la página cuando la tiene (material, tipografía, paleta, fondo);
 *   - la fila con el foco: valor, por qué no se puede usar, si es personalizada y su ruta
 *     (la que acepta `settingsOpen`);
 *   - «On this page»: las secciones de la página; un clic lleva el foco a su primera fila.
 */
Item {
    id: aside

    property real s: 1
    /** La superficie Settings (sus funciones de lectura). */
    property var ctl: null

    readonly property string pageKey: aside.ctl ? aside.ctl.shownKey : ""
    readonly property var focused: {
        if (!aside.ctl) return null;
        const f = aside.ctl.flat[aside.ctl.kbIndex];
        return f && f.row ? f : null;
    }
    readonly property string previewKind: aside.pageKey === "theme/material" ? "material"
        : aside.pageKey === "theme/typography" ? "typography"
        : aside.pageKey === "theme/colors" ? "palette"
        : (aside.pageKey === "theme/wallpaper" || aside.pageKey === "theme/overview") ? "wallpaper" : ""
    readonly property string wallThumb: aside.previewKind === "wallpaper" && aside.ctl ? aside.ctl.thumbOf(Wallpaper.current) : ""

    function layoutInfo() {
        return { w: Math.round(aside.width), h: Math.round(aside.height), preview: aside.previewKind,
                 focusedRow: aside.focused ? aside.focused.row.id : "", sections: toc.count,
                 contentH: Math.round(flick.contentHeight) };
    }

    component Caption: Text {
        width: parent ? parent.width : 0
        color: Theme.outlineText
        font.family: Typography.ui
        font.pixelSize: Typography.micro * aside.s
        font.weight: Typography.wStrong
        font.capitalization: Font.AllUppercase
        font.letterSpacing: Typography.tracking * aside.s
        topPadding: 4 * aside.s
        bottomPadding: 6 * aside.s
        Accessible.role: Accessible.Heading
        Accessible.name: text
    }
    component Card: Rectangle {
        width: parent ? parent.width : 0
        radius: Metrics.r(10) * aside.s
        color: Qt.alpha(Theme.tileBg, 0.7)
        border.width: 1
        border.color: Qt.alpha(Theme.outline, 0.18)
    }

    Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: col.implicitHeight
        clip: true
        interactive: contentHeight > height + 1
        boundsBehavior: Flickable.StopAtBounds

        Column {
            id: col
            // hueco fijo para la barra (el texto se reparte al ancho: uno que dependiera de si hay de
            // más podría oscilar justo en el límite)
            width: flick.width - asideHint.gutter
            spacing: 10 * aside.s

            // ---- vista previa de la página ---------------------------------------------
            Column {
                width: parent.width
                visible: aside.previewKind.length > 0
                Caption { text: "Preview" }

                MaterialPreview {
                    visible: aside.previewKind === "material"
                    width: parent.width
                    s: aside.s
                }
                MaterialPreview {
                    visible: aside.previewKind === "material" && aside.ctl !== null
                        && aside.ctl.isExpanded("theme/material", "advanced")
                    width: parent.width
                    s: aside.s
                    surface: aside.ctl ? aside.ctl.matSurface : ""
                    title: aside.ctl ? aside.ctl.surfaceTitle() : ""
                }

                Card {
                    visible: aside.previewKind === "typography"
                    height: typo.implicitHeight + 24 * aside.s
                    Column {
                        id: typo
                        x: 12 * aside.s; y: 12 * aside.s
                        width: parent.width - 24 * aside.s
                        spacing: 6 * aside.s
                        Text {
                            width: parent.width; elide: Text.ElideRight
                            text: "Settings"
                            color: Theme.fg; font.family: Typography.ui
                            font.pixelSize: Typography.display * aside.s; font.weight: Typography.wStrong
                        }
                        Text {
                            width: parent.width; wrapMode: Text.WordWrap
                            text: "The quick brown fox jumps over the lazy dog."
                            color: Theme.fg; font.family: Typography.ui; font.pixelSize: Typography.body * aside.s
                        }
                        Text {
                            width: parent.width; wrapMode: Text.WordWrap
                            text: "Secondary text and captions · 0123456789"
                            color: Theme.fgVariant; font.family: Typography.ui; font.pixelSize: Typography.caption * aside.s
                        }
                        Text {
                            width: parent.width; elide: Text.ElideRight
                            text: "0O 1lI {} => != // ~/.config"
                            color: Theme.fg; font.family: Typography.mono; font.pixelSize: Typography.body * aside.s
                        }
                        Row {
                            spacing: 10 * aside.s
                            Repeater {
                                model: ["cog", "palette", "monitor", "terminal", "search", "info"]
                                delegate: Icon { required property string modelData; name: modelData; size: 16 * aside.s; color: Theme.fgVariant }
                            }
                        }
                        Text {
                            width: parent.width; elide: Text.ElideRight
                            text: Typography.uiChosen + " · " + Typography.mono
                            color: Theme.outlineText; font.family: Typography.ui; font.pixelSize: Typography.micro * aside.s
                        }
                    }
                }

                Card {
                    visible: aside.previewKind === "palette"
                    height: pal.implicitHeight + 24 * aside.s
                    Column {
                        id: pal
                        x: 12 * aside.s; y: 12 * aside.s
                        width: parent.width - 24 * aside.s
                        spacing: 8 * aside.s
                        // 2026-11-12: lo que pide el nombre más largo (sin pintar; Column no coloca lo invisible)
                        Column {
                            id: chipMeasure
                            visible: false
                            Repeater {
                                model: aside.ctl ? aside.ctl.swatches : []
                                delegate: Text {
                                    required property var modelData
                                    text: modelData.name
                                    font.family: Typography.ui; font.pixelSize: Typography.micro * aside.s
                                }
                            }
                        }
                        Grid {
                            id: chips
                            // 4 columnas si el nombre más largo cabe; si no 3, y si tampoco 2 (Text size, familias anchas)
                            readonly property real need: Math.ceil(chipMeasure.implicitWidth) + 6 * aside.s   // el margen interior del texto
                            readonly property int cols: need <= (pal.width - 18 * aside.s) / 4 ? 4
                                : need <= (pal.width - 12 * aside.s) / 3 ? 3 : 2
                            columns: chips.cols
                            spacing: 6 * aside.s
                            Repeater {
                                model: aside.ctl ? aside.ctl.swatches : []
                                delegate: Rectangle {
                                    required property var modelData
                                    width: (pal.width - (chips.cols - 1) * 6 * aside.s) / chips.cols
                                    height: 34 * aside.s
                                    radius: Metrics.r(7) * aside.s
                                    color: modelData.color
                                    border.width: 1
                                    border.color: Qt.alpha(Theme.outline, 0.25)
                                    Text {
                                        anchors.centerIn: parent
                                        width: parent.width - 6 * aside.s
                                        horizontalAlignment: Text.AlignHCenter
                                        elide: Text.ElideRight
                                        text: modelData.name
                                        color: modelData.on
                                        font.family: Typography.ui; font.pixelSize: Typography.micro * aside.s
                                    }
                                }
                            }
                        }
                        Text {
                            width: parent.width; wrapMode: Text.WordWrap
                            text: aside.ctl ? aside.ctl.themeStatus || aside.ctl.paletteText : ""
                            color: Theme.fgVariant; font.family: Typography.ui; font.pixelSize: Typography.caption * aside.s
                        }
                    }
                }

                Card {
                    visible: aside.previewKind === "wallpaper"
                    height: wallCol.implicitHeight + 24 * aside.s
                    Column {
                        id: wallCol
                        x: 12 * aside.s; y: 12 * aside.s
                        width: parent.width - 24 * aside.s
                        spacing: 8 * aside.s
                        Rectangle {
                            width: parent.width
                            height: width * 9 / 16
                            radius: Metrics.r(8) * aside.s
                            color: Theme.tileBg
                            clip: true
                            Image {
                                anchors.fill: parent
                                visible: aside.wallThumb.length > 0
                                source: aside.wallThumb
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                sourceSize.width: 480
                            }
                            Text {
                                anchors.centerIn: parent
                                visible: aside.wallThumb.length === 0
                                text: Wallpaper.isVideo(Wallpaper.current) ? "Video wallpaper" : "No preview"
                                color: Theme.outlineText; font.family: Typography.ui; font.pixelSize: Typography.caption * aside.s
                            }
                        }
                        Text {
                            width: parent.width; elide: Text.ElideMiddle
                            text: aside.ctl ? aside.ctl.baseName(Wallpaper.current) : ""
                            color: Theme.fgVariant; font.family: Typography.ui; font.pixelSize: Typography.caption * aside.s
                        }
                    }
                }
            }

            // ---- la fila con el foco -----------------------------------------------------
            Column {
                width: parent.width
                visible: aside.focused !== null
                Caption { text: "Selected" }
                Card {
                    height: sel.implicitHeight + 24 * aside.s
                    Column {
                        id: sel
                        x: 12 * aside.s; y: 12 * aside.s
                        width: parent.width - 24 * aside.s
                        spacing: 4 * aside.s
                        readonly property var r: aside.focused ? aside.focused.row : null
                        readonly property string value: sel.r && aside.ctl ? aside.ctl.valueOf({ kind: "row", id: sel.r.id, row: sel.r }) : ""
                        readonly property string why: sel.r && aside.ctl ? aside.ctl.rowReason(sel.r) : ""
                        readonly property string cap: sel.r && aside.ctl ? aside.ctl.captionOf(sel.r) : ""
                        readonly property bool custom: sel.r !== null && sel.r.prop.length > 0 && Settings.isCustom(sel.r.prop)
                        Text {
                            width: parent.width; wrapMode: Text.WordWrap
                            text: sel.r ? sel.r.name : ""
                            color: Theme.fg; font.family: Typography.ui; font.pixelSize: Typography.body * aside.s
                            font.weight: Typography.wStrong
                        }
                        Text {
                            width: parent.width; wrapMode: Text.WordWrap
                            visible: sel.value.length > 0
                            text: sel.value
                            color: Theme.primary; font.family: Typography.ui; font.pixelSize: Typography.caption * aside.s
                        }
                        Text {
                            width: parent.width; wrapMode: Text.WordWrap
                            visible: sel.cap.length > 0
                            text: sel.cap
                            color: Theme.fgVariant; font.family: Typography.ui; font.pixelSize: Typography.caption * aside.s
                        }
                        Text {
                            width: parent.width; wrapMode: Text.WordWrap
                            visible: sel.why.length > 0
                            text: "Unavailable: " + sel.why
                            color: Theme.warn; font.family: Typography.ui; font.pixelSize: Typography.caption * aside.s
                        }
                        Text {
                            width: parent.width; wrapMode: Text.WordWrap
                            visible: sel.r !== null && sel.r.prop.length > 0
                            text: sel.custom ? "Custom value · Del restores the default" : "Default value"
                            color: Theme.outlineText; font.family: Typography.ui; font.pixelSize: Typography.micro * aside.s
                        }
                        Text {
                            width: parent.width; elide: Text.ElideMiddle
                            topPadding: 2 * aside.s
                            text: sel.r ? aside.pageKey + "/" + sel.r.id : ""
                            color: Theme.outlineText; font.family: Typography.mono; font.pixelSize: Typography.micro * aside.s
                            Accessible.name: "Path " + text
                        }
                    }
                }
            }

            // ---- secciones de la página ----------------------------------------------------
            Column {
                width: parent.width
                visible: toc.count > 1
                Caption { text: "On this page" }
                Repeater {
                    id: toc
                    model: aside.ctl ? aside.ctl.sectionList() : []
                    delegate: Item {
                        id: tocRow
                        required property var modelData
                        width: parent.width
                        height: 26 * aside.s
                        readonly property bool here: aside.focused !== null && aside.focused.section === tocRow.modelData.key
                            && aside.focused.sectionTitle === tocRow.modelData.title
                        Accessible.role: Accessible.Link
                        Accessible.name: "Go to " + tocRow.modelData.title
                        Accessible.onPressAction: if (aside.ctl) aside.ctl.jumpToSection(tocRow.modelData.index)
                        Rectangle {
                            anchors.fill: parent
                            radius: Metrics.r(6) * aside.s
                            color: tocArea.containsMouse ? Theme.hoverBg : "transparent"
                        }
                        Rectangle {
                            visible: tocRow.here
                            x: 2 * aside.s
                            anchors.verticalCenter: parent.verticalCenter
                            width: 3 * aside.s; height: parent.height * 0.5; radius: Metrics.pill(width)
                            color: Theme.primary
                        }
                        Text {
                            anchors.left: parent.left; anchors.leftMargin: 12 * aside.s
                            anchors.right: parent.right; anchors.rightMargin: 6 * aside.s
                            anchors.verticalCenter: parent.verticalCenter
                            elide: Text.ElideRight
                            text: tocRow.modelData.title + (tocRow.modelData.level.length > 0 ? "  · " + tocRow.modelData.level : "")
                            color: tocRow.here ? Theme.fg : Theme.fgVariant
                            font.family: Typography.ui; font.pixelSize: Typography.caption * aside.s
                        }
                        MouseArea {
                            id: tocArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: if (aside.ctl) aside.ctl.jumpToSection(tocRow.modelData.index)
                        }
                    }
                }
            }
        }
    }
    ScrollHint { id: asideHint; view: flick; s: aside.s; inside: true; inset: 4 * aside.s }
}
