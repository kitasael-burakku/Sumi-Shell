import QtQuick
import "../theme"
import "../lib/icon-catalog.js" as Catalog

/**
 * A Nerd Font glyph by name. The rice ships a Nerd Font (`Typography.icons`, por defecto
 * IosevkaTerm Nerd Font Propo) and Waybar already draws its bar with these
 * codepoints, so the shell borrows the
 * same font instead of carrying its own SVG path data: one text node per icon
 * against a `Shape` with a curve renderer, and no icon set to keep in sync.
 *
 * Every codepoint below was checked against the installed font before use.
 * Comprobar un glifo nuevo: `fontTools` → `getBestCmap()[codepoint]`.
 *
 * ── LA REGLA DEL TRAZO, 2026-09-16 ─────────────────────────────────────────
 *
 * Material Design Icons trae casi todo por duplicado, relleno y `_outline`, y
 * la tabla mezclaba los dos sin criterio. En la cara hover se veía de golpe:
 * la lupa y el portapapeles son trazo fino, y a su lado la nota de música, el
 * altavoz, el servidor, el café y el engranaje eran manchas sólidas. Veinte
 * iconos del mismo tamaño y de dos pesos distintos no se leen como una fila.
 *
 * El corte NO es «todo outline». Es por lo que el icono *hace*:
 *
 *   BOTONES, lo que se pulsa (las cuatro agrupaciones de la cara hover, las
 *   acciones de las superficies) → **trazo fino**, variante `_outline` cuando
 *   existe. Son afordancias: invitan, no gritan.
 *
 *   ESTADO Y ALARMAS (wifi, bluetooth, batería, campana, micrófono, pantalla
 *   compartida, aviso) → **relleno**. Tienen que saltar a la vista por encima
 *   del resto, y entre ellos ya forman una familia coherente: las escaleras de
 *   señal de MDI son macizas por diseño.
 *
 *   TRANSPORTE (play/pause/next/prev) y DISPOSITIVOS (auriculares, teclado,
 *   ratón, mando, portátil, impresora…) → **relleno**, cada uno como familia.
 *   Partirlas por la mitad sería el mismo error al revés.
 *
 * Sin `_outline` en el font hubo que elegir vecino, y queda anotado:
 *   `terminal` md-console (caja rellena) → md-console_line, el `>_` a secas.
 *   `server`   md-server (tres barras macizas) → md-cube_outline: en systemd la
 *              cosa se llama «unit», y una lista habría chocado con el
 *              portapapeles.
 *   `hibernate` md-harddisk (un disco macizo, la única mancha que quedaba en la
 *              fila de Power) → md-snowflake_variant: un copo radial de trazo
 *              fino. Y de paso dice mejor lo que hace — congelar a disco — junto
 *              a la luna de `suspend`, que es congelar a RAM.
 *   `mixer`    clave NUEVA, md-tune_vertical: el botón del island abría el
 *              mezclador con un altavoz relleno, que además repetía el glifo del
 *              OSD de volumen. Los deslizadores dicen «mesa de mezclas»; el
 *              altavoz se queda para el NIVEL (OSD, filas del mezclador) y para
 *              el mute, que sí es alarma.
 *
 * Antes de esto, dos que directamente no eran lo que decían (fontTools,
 * 2026-09-15): `wallpaper` era md-octagon_outline y `terminal` md-compass.
 */
Text {
    id: root

    property string name: ""
    property real size: 14

    readonly property var glyphs: Catalog.glyphs
    readonly property var tints: Catalog.tints

    /** El tinte del glifo. Sin entrada en la tabla, el neutro de siempre. */
    readonly property color tint: {
        switch (root.tints[root.name]) {
        case "p":  return Theme.tintPrimary;
        case "ps": return Theme.tintPrimarySoft;
        case "s":  return Theme.tintSecondary;
        case "ss": return Theme.tintSecondarySoft;
        case "t":  return Theme.tintTertiary;
        case "ts": return Theme.tintTertiarySoft;
        case "d":  return Theme.tintDanger;
        default:   return Theme.tintNeutral;
        }
    }

    Accessible.name: root.name
    text: !Typography.iconsMissing && root.glyphs[root.name] !== undefined ? root.glyphs[root.name] : "?"
    font.family: Typography.icons
    font.pixelSize: root.size
    color: root.tint
    verticalAlignment: Text.AlignVCenter
    horizontalAlignment: Text.AlignHCenter
}
