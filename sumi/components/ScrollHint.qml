import QtQuick
import "../theme"

/**
 * La barra de desplazamiento que el shell no tenía.
 *
 * Contadas el 2026-09-15: **trece listas con scroll y cero indicadores**. Ni
 * barra, ni degradado en los bordes, ni sombra — nada que dijera que debajo hay
 * más cosas. En el lanzador, en los servicios, en el portapapeles, en las
 * notificaciones.
 *
 * Se descartó el degradado de desvanecido en los extremos (que es lo bonito)
 * porque sobre un fondo translúcido hay que enmascarar la lista entera con un
 * `MultiEffect`, y eso es un FBO por lista y por fotograma para un adorno. Esto
 * cuesta dos rectángulos: está siempre que haya de más, tenue, y se enciende
 * mientras el contenido se mueve.
 *
 * **Separación** (2026-11-12, pedido del usuario: en Settings tocaba la fila elegida y en el
 * lanzador pisaba su marca). Una regla para todas: la barra queda a `gap` (6·s) del borde
 * del contenido. Por defecto va FUERA de la vista, a `gap` de su borde; si fuera no hay
 * aire (la vista llega al borde de su tarjeta), `inside: true` la pone dentro, pegada al
 * borde de la vista, y la vista aparta su contenido `reserve` (ancho + `gap`, sólo cuando
 * hay de más, para no dejar un hueco vacío en las listas cortas).
 */
Item {
    id: hint

    property Flickable view: null
    property real s: 1
    /**
     * A la izquierda de la lista en vez de a la derecha (el Launcher, rediseño
     * ARR-05).
     */
    property bool leftSide: false
    /** Aire entre el borde del contenido y la barra. */
    property real gap: 6 * hint.s
    /** Dentro de la vista (la vista reserva `reserve` para su contenido) en vez de fuera. */
    property bool inside: false
    /** Con `inside`: aire entre el borde de la vista y la barra (la vista llega al filo de su tarjeta). */
    property real inset: 0
    /**
     * Ajuste fino hacia fuera, sumado a `gap` (2026-10-01: pegada al borde pisaba lo que llega
     * hasta él). Con la regla de `gap` casi nadie lo necesita: sólo donde el borde de la vista
     * no es el del contenido.
     */
    property real outset: 0

    readonly property real span: hint.view ? hint.view.contentHeight : 0
    readonly property real port: hint.view ? hint.view.height : 1
    readonly property bool overflowing: hint.span > hint.port + 1
    /** Lo que la vista debe apartar su contenido con `inside` (0 si no hay de más). */
    readonly property real reserve: hint.inside && hint.overflowing ? hint.gutter : 0
    /** El hueco completo de una barra interior, haya o no de más (contenido que se reparte al ancho). */
    readonly property real gutter: hint.inset + hint.width + hint.gap

    readonly property real shift: hint.inside ? hint.inset : -(hint.gap + hint.width + hint.outset)
    anchors.right: hint.view && !hint.leftSide ? hint.view.right : undefined
    anchors.left: hint.view && hint.leftSide ? hint.view.left : undefined
    anchors.leftMargin: hint.leftSide ? hint.shift : 0
    anchors.rightMargin: hint.leftSide ? 0 : hint.shift
    anchors.top: hint.view ? hint.view.top : undefined
    anchors.bottom: hint.view ? hint.view.bottom : undefined
    width: 3 * hint.s
    visible: hint.overflowing

    /** Para el banco: la barra, la vista y el contenedor con aire a ese lado, en coordenadas de ventana. */
    function scrollHintGeometry() {
        if (!hint.view) return null;
        const b = hint.mapToItem(null, 0, 0);
        const v = hint.view.mapToItem(null, 0, 0);
        const r = (x, y, w, h) => ({ x: Math.round(x * 10) / 10, y: Math.round(y * 10) / 10,
                                      w: Math.round(w * 10) / 10, h: Math.round(h * 10) / 10 });
        let box = null, clipBox = null;
        for (let a = hint.view.parent; a; a = a.parent) {
            const p = a.mapToItem(null, 0, 0);
            const room = hint.leftSide ? v.x - p.x : (p.x + a.width) - (v.x + hint.view.width);
            if (!box && room > 0.5) box = { item: a, x: p.x, w: a.width, room: room };
            if (!clipBox && a.clip) clipBox = { x: p.x, w: a.width };
            if (box && clipBox) break;
        }
        const barOut = hint.leftSide ? b.x : b.x + hint.width;
        let shown = v.y + hint.view.height > 0 && hint.view.width > 0;
        for (let a = hint.view; a && shown; a = a.parent)
            if (!a.visible || a.opacity < 0.02) shown = false;
        return { bar: r(b.x, b.y, hint.width, hint.height), view: r(v.x, v.y, hint.view.width, hint.view.height),
                 visible: hint.visible, shown: shown, inside: hint.inside, left: hint.leftSide, s: hint.s,
                 toContent: hint.inside ? hint.gap : (hint.leftSide ? v.x - (b.x + hint.width) : b.x - (v.x + hint.view.width)),
                 toBox: box ? Math.round((hint.leftSide ? b.x - box.x : box.x + box.w - barOut) * 10) / 10 : null,
                 clipped: clipBox ? (b.x < clipBox.x - 0.5 || b.x + hint.width > clipBox.x + clipBox.w + 0.5) : false,
                 where: String(hint.view).split("(")[0] + "@" + String(hint.parent).split("(")[0] };
    }

    Rectangle {
        id: rail
        anchors.fill: parent
        radius: Metrics.pill(width)
        color: Qt.alpha(Theme.fg, 0.06)
    }

    Rectangle {
        width: parent.width
        radius: Metrics.pill(width)
        color: Theme.outline
        /** Mínimo de 24 px: por debajo deja de leerse como un pulgar. */
        height: Math.max(24 * hint.s, hint.port * (hint.port / Math.max(1, hint.span)))
        y: hint.view
            ? (hint.port - height) * Math.max(0, Math.min(1,
                hint.view.contentY / Math.max(1, hint.span - hint.port)))
            : 0
        opacity: (hint.view && hint.view.moving) ? 0.9 : 0.45
        Behavior on opacity { NumberAnimation { duration: Motion.standard } }
    }
}
