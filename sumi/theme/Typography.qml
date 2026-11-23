pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../lib/typography.js" as Fonts
import "../services"

/**
 * La escala tipográfica. **Cinco tamaños con nombre**, no dos con offsets.
 *
 * Antes había `body 12.5` y `caption 9`, y el shell se apañaba con sumas a mano
 * (`body - 2`, `body - 1.5`, `body - 1`, `body - 0.5`, `body + 0.5`, `body + 1`,
 * `body + 3`): ocho tamaños de facto, ninguno declarado. Contado el 2026-09-15:
 * **125 de los 189 textos del shell (66 %) eran `caption`**, que con `uiScale`
 * 0.9 son 8,1 px reales. Es decir, dos tercios del escritorio estaban escritos
 * al tamaño más pequeño y en gris: sin jerarquía, el ojo no sabe dónde aterrizar
 * al abrir un panel.
 *
 * Regla de uso:
 *
 *   display  cifras que son el contenido (la hora, un porcentaje grande)
 *   title    la cabecera de una superficie, y nada más
 *   body     filas de lista, el texto que se lee de verdad
 *   label    etiquetas, badges, unidades, el segundo renglón de una fila
 *   caption  pies y apoyos — **no** el tamaño por defecto
 *   micro    lo verdaderamente accesorio (marcas de tiempo, contadores)
 *
 * `caption` sube de 9 a 10,5 para que el texto que hoy lo usa deje de ser
 * ilegible mientras se reasigna superficie por superficie.
 *
 * ── REDISEÑO, FASE 1 (2026-09-24) ────────────────────────────────────────
 *
 * **Iosevka en toda la shell** (`rediseno/DESIGN.md` §1): `ui` deja Inter y pasa a
 * la misma familia que `mono`, la única Iosevka instalada (IosevkaTerm Nerd Font,
 * variante Propo). `mono` se conserva como nombre para lo que es código o log.
 *
 * Medido con fontTools antes de cambiar nada: al mismo tamaño en px, IosevkaTerm
 * Propo ocupa lo mismo que Inter (±3 % en cinco frases reales del shell), su
 * altura de x es menor (0,520 em frente a 0,546) y la línea un 3 % más alta. Así
 * que el cambio de familia no mueve anchos, pero **lo pequeño se lee más pequeño**:
 * por eso suben `label`, `caption` y `micro` (+1 px cada uno) y `title` (+1 px)
 * para que la cabecera siga destacando. `body` se queda: es el que más filas mide
 * a alto fijo. Son valores de prototipo; los de DESIGN §5 (14 / 13 / 18 / 24) se
 * alcanzan cuando las superficies tengan sus familias de tamaño (fase 4).
 */
Singleton {
    id: root
    readonly property var catalog: JSON.parse(catalogFile.text())
    property var installed: []
    property bool inventoryKnown: false
    property string inventoryError: ""
    property var iconReport: ({state:"unknown",eligible:[]})
    readonly property var selection: Settings.typographySelection
    readonly property var uiResolution: Fonts.resolve(catalog,selection,"ui",installed,inventoryKnown)
    readonly property var monoResolution: Fonts.resolve(catalog,selection,"mono",installed,inventoryKnown)
    /** La familia de interfaz que eligió el usuario (Settings → Typography), sin la sustitución del estilo. */
    readonly property string uiChosen: uiInfo.family || uiResolution.selected
    /**
     * La que se dibuja. Terminal Interface (theme/Style, ADR-34) pide la `mono` del propio usuario para el texto de
     * interfaz; nunca se escribe en `fontUi`/`fontMono` (FontSync lee settings.json, así que las apps no se enteran).
     */
    readonly property string ui: Style.now.monoText ? mono : uiChosen
    readonly property string mono: monoInfo.family || monoResolution.selected
    readonly property string icons: iconReport.eligible.length ? iconReport.eligible[0] : catalog.legacy
    // Qt already knows this family is absent even while the coverage process is pending.
    // Keep the legacy glyph path unchanged when its family is listed by Qt.
    readonly property bool iconsMissing: iconReport.state === "unavailable"
        || (inventoryKnown && Fonts.listed([root.icons], root.installed).length === 0)
    readonly property var diagnostics: ({ inventory:inventoryKnown ? "available" : "unknown",
        error:inventoryError, requested:selection,
        ui:{requested:uiResolution.requested,selected:uiResolution.selected,effective:ui,reason:uiResolution.reason},
        mono:{requested:monoResolution.requested,selected:monoResolution.selected,effective:mono,reason:monoResolution.reason},
        icons:{effective:icons,state:iconReport.state,coverage:iconReport.coverage || []} })

    function resolve(draft, role) { return Fonts.resolve(catalog,draft,role,installed,inventoryKnown); }
    function canApply(draft) { return Fonts.canApply(catalog,draft,installed,inventoryKnown); }
    function refresh() {
        try {
            const names = Qt.fontFamilies();
            if (!names.length) throw new Error("Qt returned no font families");
            installed = names;
            inventoryKnown = true;
            inventoryError = "";
        } catch (e) { inventoryKnown = false; inventoryError = String(e); }
        if (!iconProbe.running) iconProbe.running = true;
    }
    FileView { id: catalogFile; path: Qt.resolvedUrl("../lib/font-catalog.json"); blockLoading: true }
    FontInfo { id: uiInfo; font.family: root.uiResolution.selected }
    FontInfo { id: monoInfo; font.family: root.monoResolution.selected }
    Process {
        id: iconProbe
        command: ["python3", Quickshell.shellPath("scripts/font_diagnostics.py")]
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.iconReport = JSON.parse(text); }
                catch (e) { root.iconReport = {state:"unknown",eligible:[]}; }
            }
        }
        onExited: (code, status) => {
            if (code !== 0) root.iconReport = {state:"unknown",eligible:[]};
        }
    }
    Component.onCompleted: { root.refresh(); Qt.callLater(root.measureLines); }

    /**
     * 9D-1: Theme → Typography → Text size (1 · 1,08 · 1,15). Sólo los tamaños de texto de
     * abajo; el reloj del reposo y los del Lock quedan fuera, como de la escala.
     */
    readonly property real textScale: Math.max(1, Math.min(1.15, Settings.textScale || 1))

    /**
     * Métricas MEDIDAS de la familia que se dibuja (auditoría tipográfica, 2026-11-18). El diseño se dibujó con
     * Iosevka (`catalog.legacy`); las otras familias del catálogo corren hasta un 23 % más anchas (las monoespaciadas
     * de 0,6 em) y su renglón es hasta un 9 % más alto (Noto Sans). Todo se mide con FontMetrics/TextMetrics, una vez
     * por cambio de familia, sin condiciones por familia. Sin la referencia instalada el diseño queda como antes
     * (factor de ancho 1, holgura sin tocar).
     *
     *   widthRatio ancho de un texto de muestra frente a Iosevka (a 100 px), nunca menos de 1: con una familia más
     *              estrecha el diseño se queda como está (no encoge)
     *   grow       cuánto más ancho corre el texto que en el diseño: Text size × widthRatio. Para los anchos que
     *              alojan texto (columnas, etiquetas, tarjetas); nunca para tamaños de letra (eso ya lo hace textScale)
     *   lineH(px)  alto de un renglón de `px` (ya escalado) tal como lo maqueta un Text: `font.pixelSize` es ENTERO
     *              (Qt redondea, 10,5 → 11) y el renglón sale de las métricas con el hinting de ESE tamaño, que no es
     *              proporcional. Por eso no se extrapola desde 100 px: se mide un FontMetrics por tamaño entero
     *              (`lineMin`…`lineMax`) y `ceil(height)` es exactamente el renglón de un Text (comprobado con Qt
     *              fuera de pantalla: 9 familias × 35 tamaños, 0 diferencias; el modelo `ceil(asc) + ceil(desc)` a
     *              partir de 100 px fallaba en 16–19 tamaños por familia y dejaba el estado de Theme 1 px corto)
     *   designLineH(px)  lo mismo con la familia del diseño
     *   box(h, px, s)
     *              alto YA ESCALADO de una caja de DISEÑO `h` (sin escalar, como las cifras de Metrics) que aloja
     *              renglones de los tamaños `px` (sin escalar, ya con Text size): un número para un renglón o una lista
     *              con uno por renglón (`[caption, caption, label]`). Suma lo que cada renglón crece frente al diseño,
     *              así que conserva la holgura que dejó el diseño y nunca baja de `h · s`. Con Iosevka a Text size 1
     *              devuelve exactamente `h · s`
     *
     * Las tablas se rehacen UNA vez por cambio (Qt.callLater): como enlace se reevaluaban una vez por cada uno de
     * los 43 FontMetrics y arrastraban a todas las cajas. Hasta la primera medida, `lineH` usa la proporción a 100 px.
     */
    readonly property string widthSample: "Settings Wallpaper Notifications Bluetooth 12:45 Wi-Fi connected"
    FontMetrics { id: uiMetrics; font.family: root.ui; font.pixelSize: 100 }
    FontMetrics { id: refMetrics; font.family: root.catalog.legacy; font.pixelSize: 100 }
    TextMetrics { id: uiSample; font.family: root.ui; font.pixelSize: 100; text: root.widthSample }
    TextMetrics { id: refSample; font.family: root.catalog.legacy; font.pixelSize: 100; text: root.widthSample }
    readonly property bool refInstalled: inventoryKnown && Fonts.listed([catalog.legacy], installed).length > 0
    readonly property real widthRatio: refInstalled && refSample.advanceWidth > 0 && uiSample.advanceWidth > 0
        ? Math.max(1, Math.min(1.3, uiSample.advanceWidth / refSample.advanceWidth)) : 1
    readonly property real grow: textScale * widthRatio

    readonly property string designFamily: refInstalled ? catalog.legacy : ui
    readonly property real lineRatio: uiMetrics.height > 0 ? Math.max(1, uiMetrics.height / 100) : 1.25
    readonly property real designLineRatio: refInstalled && refMetrics.height > 0 ? refMetrics.height / 100 : lineRatio
    readonly property int lineMin: 6
    readonly property int lineMax: 48
    property var uiLines: []
    property var designLines: []
    Instantiator {
        id: uiLineMetrics
        model: root.lineMax - root.lineMin + 1
        delegate: FontMetrics { required property int index; font.family: root.ui; font.pixelSize: root.lineMin + index }
    }
    Instantiator {
        id: designLineMetrics
        model: root.lineMax - root.lineMin + 1
        delegate: FontMetrics { required property int index; font.family: root.designFamily; font.pixelSize: root.lineMin + index }
    }
    function lineTable(inst) {
        const t = [];
        for (let i = 0; i < inst.count; i++) {
            const m = inst.objectAt(i);
            t.push(m && m.height > 0 ? Math.ceil(m.height - 0.001) : 0);
        }
        return t;
    }
    function measureLines() {
        const u = root.lineTable(uiLineMetrics), d = root.lineTable(designLineMetrics);
        if (JSON.stringify(u) !== JSON.stringify(root.uiLines)) root.uiLines = u;
        if (JSON.stringify(d) !== JSON.stringify(root.designLines)) root.designLines = d;
    }
    onUiChanged: Qt.callLater(root.measureLines)
    onDesignFamilyChanged: Qt.callLater(root.measureLines)
    function lineH(px) {
        const q = Math.round(px), v = root.uiLines[q - root.lineMin];
        return v > 0 ? v : Math.ceil(q * root.lineRatio - 0.001);
    }
    function designLineH(px) {
        const q = Math.round(px), v = root.designLines[q - root.lineMin];
        return v > 0 ? v : Math.ceil(q * root.designLineRatio - 0.001);
    }
    function box(h, px, s) {
        const sizes = Array.isArray(px) ? px : [px];
        let extra = 0;
        for (let i = 0; i < sizes.length; i++)
            extra += root.lineH(sizes[i] * s) - root.designLineH(sizes[i] * s / root.textScale);
        return Math.max(h * s, h * s + extra);
    }

    readonly property real display: 20 * textScale
    readonly property real title:   16 * textScale
    readonly property real body:    13 * textScale
    readonly property real label:   12 * textScale
    readonly property real caption: 11.5 * textScale
    readonly property real micro:   10 * textScale

    /** El reloj. Fuera de la escala a propósito: es la identidad del reposo. */
    readonly property real restTime:  16
    readonly property real hoverTime: 18

    /**
     * La pantalla de bloqueo (ADR-30, docs/lock/INTERFAZ.md §7). La hora es la del
     * reposo del island, crecida: misma familia, peso y cifras tabulares, porque es
     * el mismo objeto que baja al centro. La fecha va en versales con `tracking`.
     */
    readonly property real lockDate: 15
    /** La hora dentro del panel (fase 15): más pequeña que la de pantalla completa. */
    readonly property real lockBoardTime: 76
    readonly property real lockNarrowTime: 48

    /** Pesos con nombre, para dejar de escribir `Font.DemiBold` en 46 sitios. */
    readonly property int wNormal: Font.Normal
    readonly property int wMedium: Font.Medium
    readonly property int wStrong: Font.DemiBold

    /** Interletraje de las cabeceras en versales. */
    readonly property real tracking: 1.4
}
