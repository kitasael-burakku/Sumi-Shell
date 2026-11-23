pragma Singleton
import QtQuick
import Quickshell
import "../services"
import "../lib/surface-materials.js" as SurfaceMaterials

/**
 * Roles de presentación compartidos. Colors lee la paleta de Matugen o la
 * estática; aquí se derivan el relieve, los realces y la tinta de la shell.
 * Los roles originales siguen disponibles para muestras y usos específicos.
 */
Singleton {
    id: theme

    readonly property color surface:                 Colors.surface
    readonly property color surfaceContainerLowest:  Colors.surfaceContainerLowest
    readonly property color surfaceContainerLow:     Colors.surfaceContainerLow
    readonly property color surfaceContainer:        Colors.surfaceContainer
    readonly property color surfaceContainerHigh:    Colors.surfaceContainerHigh
    readonly property color fg:                      readableText(Colors.fg)
    readonly property color fgVariant:               readableText(Colors.fgVariant)
    readonly property color outline:                 Colors.outline
    readonly property color outlineText:             readableText(Colors.outline)
    readonly property color primary:                 Colors.primary
    readonly property color fgOnPrimary:             legibleOn(Colors.fgOnPrimary, primary, 4.6)
    /** OJO: `secondary` aquí es el AMARILLO DE AVISO del shell (10 usos), no el
     *  rol `secondary` de Material — ese es `tintSecondary`, más abajo. */
    readonly property color secondary:               Colors.tertiary
    readonly property color errorColor:              Colors.errorColor

    // ---- tintes de iconografía -----------------------------------------

    /**
     * **Un color por glifo** (2026-09-16, a petición del usuario). No son
     * colores nuevos: son roles de Material que matugen ya generaba y que el
     * shell no leía. En oscuro los cuatro primeros salen a la misma luminancia
     * (0,77 medido), así que separan por TONO sin que unos pesen más que otros;
     * los tres `…Soft` son la banda clara (0,88) y sirven para dar un segundo
     * color dentro del mismo bloque sin cambiar de familia.
     *
     * Quién manda: el mapa vive en `components/Icon` (`tint`), un sitio, y
     * cualquiera que ponga `color:` a mano sigue ganando — por eso los iconos de
     * estado (wifi, bluetooth, batería) conservan su color por estado.
     */
    /*
     * GUARDA DE CONTRASTE (2026-10-01, captura del usuario: en claro con contraste standard los iconos
     * del portapapeles, ventanas y la CLI no se veían). Los `…Soft` son roles *Fixed* de Material:
     * el MISMO pastel en claro y en oscuro, pensado para fondos oscuros; sobre el vidrio claro quedaban
     * en ~1,3:1. Con `higher` matugen los oscurece y se leían; con standard o lower, no.
     *
     * `legible(c)` deja el color como está si ya llega a 3:1 contra `surface` (WCAG 1.4.11, mínimo para
     * un glifo) y, si no, lo acerca a `fg` lo justo para llegar: el tono se conserva todo lo posible.
     * Vale para cualquier modo, contraste o esquema, no sólo para el caso visto.
     */
    // 3:1 es el mínimo de WCAG; 3,5 da margen porque el fondo real es vidrio translúcido sobre el wallpaper
    readonly property real glyphContrast: 3.5
    function luminance(c) {
        const ch = (v) => v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
        return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
    }
    function contrast(a, b) {
        const la = luminance(a), lb = luminance(b);
        return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
    }
    function legibleOn(c, bg, ratio) {
        const want = ratio === undefined ? glyphContrast : ratio;
        if (contrast(c, bg) >= want) return c;
        let ink = foregroundFor(bg);
        if (contrast(ink, bg) < want)
            ink = luminance(bg) > 0.179 ? Qt.rgba(0, 0, 0, 1) : Qt.rgba(1, 1, 1, 1);
        for (let t = 0.1; t < 1.0; t += 0.1) {
            const m = mix(c, ink, t);
            if (contrast(m, bg) >= want) return m;
        }
        return ink;
    }
    function legible(c, ratio) { return legibleOn(c, Colors.surface, ratio); }

    readonly property color tintPrimary:     legible(Colors.primary)
    readonly property color tintSecondary:   legible(Colors.secondaryRole)
    readonly property color tintTertiary:    legible(Colors.tertiary)
    readonly property color tintDanger:      legible(Colors.errorColor)
    readonly property color tintPrimarySoft:   legible(Colors.primaryFixed)
    readonly property color tintSecondarySoft: legible(Colors.secondaryFixed)
    readonly property color tintTertiarySoft:  legible(Colors.tertiaryFixed)
    readonly property color tintNeutral:     legible(Colors.fgVariant)

    // Último recurso para paletas de contraste bajo; las mezclas conservan
    // el matiz original siempre que alcanza el contraste del texto.
    readonly property color textPole: light ? "#000000" : "#ffffff"
    readonly property color textAnchor: fitsText(Colors.fg) ? Colors.fg : textPole
    function fitsText(ink) {
        for (const bg of textBackgrounds) if (contrast(ink, bg) < 4.6) return false;
        return true;
    }
    /** Como `readableText`, pero contra una lista de fondos concreta. */
    function readableAgainst(c, grounds, ratio) {
        const fits = (ink) => grounds.every(bg => contrast(ink, bg) >= ratio);
        if (fits(c)) return c;
        for (let t = 0.1; t < 1.0; t += 0.1) {
            const ink = mix(c, textAnchor, t);
            if (fits(ink)) return ink;
        }
        return textAnchor;
    }
    function readableText(c) {
        if (fitsText(c)) return c;
        for (let t = 0.1; t < 1.0; t += 0.1) {
            const ink = mix(c, textAnchor, t);
            if (fitsText(ink)) return ink;
        }
        return textAnchor;
    }

    // Una paleta clara oscurece los planos al elevarlos; una oscura los aclara.
    // Conserva el token si ya se separa del plano anterior en esa dirección.
    function elevate(token, lower, separation) {
        const y = luminance(lower);
        const direction = light ? -1 : 1;
        let tone = (luminance(token) - y) * direction >= 0 ? token : lower;
        for (let step = 0; step < 6 && contrast(tone, lower) < separation; step++)
            tone = mix(tone, Colors.fg, 0.035);
        return tone;
    }

    readonly property color insetBg: surfaceContainerLowest
    readonly property color cardBg: elevate(surfaceContainer, surfaceContainerLow, 1.11)
    readonly property color raisedBg: elevate(surfaceContainerHigh, cardBg, 1.13)
    readonly property color cardBorder: Qt.alpha(fg, light ? 0.18 : 0.14)

    readonly property color primaryText: readableText(primary)
    readonly property color successText: readableText(Colors.secondaryRole)
    readonly property color warningText: readableText(Colors.tertiary)
    readonly property color dangerText: readableText(errorColor)
    function mix(a, b, t) {
        return Qt.rgba(a.r + (b.r-a.r)*t, a.g + (b.g-a.g)*t, a.b + (b.b-a.b)*t, 1);
    }
    /** Compone la capa de estado conservando la cobertura del fondo. */
    function overlay(base, layer) {
        if (base.a === 0) return layer;
        const alpha = layer.a + base.a * (1 - layer.a);
        return Qt.alpha(mix(base, layer, layer.a / alpha), alpha);
    }
    /** Texto de un botón relleno: elegir entre los dos neutros de la paleta. */
    function foregroundFor(bg) { return contrast(fg, bg) >= contrast(surface, bg) ? fg : surface; }

    // ---- vidrio ---------------------------------------------------------

    /**
     * El material de todo lo que flota. --subido de 0.82 a 0.90 (usuario, 2026-09-24)
     * y a 0,95 en el rediseño (DESIGN §5: «vidrio discreto, casi opaco», 0,94–0,98):
     * a 0,90 el texto de una terminal detrás se leía a través del panel (galería
     * de componentes, `review/referencia-2026-09-24/componentes-antes-*`).
     */
    readonly property color glassBg:     Qt.alpha(surface, Settings.glassOpacity)
    /** El satinado cambia el tono, no el alfa elegido por el usuario. */
    readonly property color satinBg:     Qt.alpha(surfaceContainerLow, Settings.glassOpacity)
    readonly property color satinDeep:   Qt.alpha(surfaceContainerLowest, Settings.glassOpacity)
    readonly property color materialBg:   Settings.material === "satin" ? satinBg : glassBg
    readonly property color materialDeep: Settings.material === "satin" ? satinDeep : glassDeep
    /**
     * Para lo que aparece sobre cualquier cosa y hay que leer ya: notificaciones. Un punto
     * más opaco que el vidrio (12D: sigue al ajuste; era 0,96 con el vidrio a 0,95).
     */
    readonly property color glassDeep:   Qt.alpha(surfaceContainerLowest, Math.min(1, Settings.glassOpacity + 0.01))
    /** Contorno neutro: define el canto sin competir con el acento. */
    readonly property color glassBorder: Qt.alpha(fg, 0.13)
    readonly property color materialBorder: Settings.material !== "satin" ? glassBorder
        : Settings.materialEdge === "none" ? "transparent"
        : Qt.alpha(fg, Settings.materialEdge === "defined" ? 0.26 : 0.16)

    /**
     * MATERIAL POR SUPERFICIE (2026-10-28, Theme → Material → Surfaces). El ÚNICO sitio que
     * resuelve el valor efectivo: material y opacidad por separado, lo guardado de la superficie o
     * el global (`lib/surface-materials.js`). `key` es la clave de la tabla ("" = el global, lo de
     * siempre); `Glass` la recibe en `surface` y nadie más repite la regla. La opacidad es sólo la
     * del FONDO: texto, iconos y miniaturas se pintan encima a opacidad completa. El blur es de
     * Hyprland y no cambia con esto.
     */
    function materialFor(key) { return SurfaceMaterials.material(Settings.surfaceMaterials, key, Settings.material); }
    function opacityFor(key) { return SurfaceMaterials.opacity(Settings.surfaceMaterials, key, Settings.glassOpacity); }
    /** El fondo efectivo; `deep` es la variante «un punto más opaca» de lo que hay que leer ya. */
    function bgFor(key, deep) {
        const a = theme.opacityFor(key);
        if (theme.materialFor(key) === "satin")
            return Qt.alpha(deep ? surfaceContainerLowest : surfaceContainerLow, a);
        return deep ? Qt.alpha(surfaceContainerLowest, Math.min(1, a + 0.01)) : Qt.alpha(surface, a);
    }
    function borderFor(key) {
        return theme.materialFor(key) !== "satin" ? glassBorder
            : Settings.materialEdge === "none" ? "transparent"
            : Qt.alpha(fg, Settings.materialEdge === "defined" ? 0.26 : 0.16);
    }
    /**
     * EL MARCO DE TERMINAL (2026-11-14, ADR-34). Con el estilo terminal el canto es estructura, no sólo canto: un trazo
     * del acento de la paleta (cualquiera, también la de matugen). `materialEdge` sigue mandando en la intensidad, pero
     * `none` no lo borra: sin marco, los módulos de terminal no se distinguen entre sí. `frameMark` es la de las marcas
     * (corchetes de esquina), un punto más fuerte. Sólo color: la forma es de `Style`.
     */
    function frameFor(key) {
        return Qt.alpha(primary, Settings.materialEdge === "defined" ? 0.70 : Settings.materialEdge === "none" ? 0.30 : 0.45);
    }
    readonly property color frameMark: Qt.alpha(primary, 0.85)
    /**
     * Puntos de privacidad (pantalla, cámara, micro): colores fijos, no de la paleta (los de iOS; su significado no puede
     * depender del fondo). Eran hex sueltos en Island y Bar; aquí con nombre (F2 del estilo, 2026-11-14), mismos valores.
     */
    readonly property color privacyScreen: "#ff453a"
    readonly property color privacyCamera: "#30d158"
    readonly property color privacyMic:    "#ff9f0a"
    /** La clave de un nombre del host (`settingsTheme` → `settings`); "" si no tiene propia. */
    function surfaceKey(name) { return SurfaceMaterials.keyOf(name); }
    /** Borde y sombra del satinado importan si alguna superficie lo usa, aunque el global sea Glass. */
    readonly property bool satinInUse: SurfaceMaterials.anyUses(Settings.surfaceMaterials, Settings.material, "satin")

    /** Velo de acento del vidrio, más tenue sobre fondos claros.*/
    readonly property color accentVeil:  Qt.alpha(primary, light ? 0.04 : 0.08)
    /** Reglas y separadores dentro de un panel. */
    readonly property color hair:        Qt.alpha(fg, light ? 0.22 : 0.18)
    /** Fondo de una celda dentro del vidrio (carriles, consolas, tiles). */
    readonly property color tileBg:      cardBg
    /**
     * El carril vacío de un deslizador (2026-10-01). Antes `tileBg`: en oscuro es casi el color del
     * vidrio y el carril del balance de la Audio UI no se veía. Un velo de `fg` se lee igual en los
     * dos modos y con cualquier esquema.
     */
    readonly property color trackBg:     Qt.alpha(fg, light ? 0.22 : 0.20)
    readonly property color shadow:      Qt.rgba(0, 0, 0, 0.5)

    // ---- estados --------------------------------------------------------

    /**
     * Los que el shell ya usaba a mano en cada superficie, ahora con nombre y en
     * un solo sitio. Se **derivan** de la paleta, no se inventan: ADR-1 dice que
     * el shell no genera color, y un verde fijo para «correcto» sería justo eso.
     * Si algún día se quiere un verde/ámbar independientes del wallpaper, es
     * aquí y sólo aquí.
     */
    readonly property color ok:     primary
    readonly property color warn:   warningText
    /** Red conectando o limitada (8B-1): naranja fijo, no depende del fondo. Era ámbar
     *  #ffd60a y con un `primary` amarillo (#cccb6c, medido) no se distinguía de «conectado». */
    readonly property color netWarn: "#ff9f0a"
    /** Cuerpo del dock (8F-1): opaco, el tono más hondo de la paleta. */
    /** Settings → Notch → Color (2026-11-17): Black = negro puro, para fundirse con el bisel (OLED). */
    readonly property color notchBg: Settings.notchColor === "black" ? "#000000" : surfaceContainerLowest
    /** La paleta es clara (modo light de matugen): para lo que no se recolorea solo (iconos ajenos). */
    readonly property bool light: surface.hslLightness > 0.5
    readonly property color danger: errorColor
    readonly property color info:   secondary

    // El foco dibuja un contorno; el hover y la pulsación modulan el fondo.
    // La selección persiste al pasar el puntero o pulsar sobre el control.
    readonly property color selBg:          Qt.alpha(primary, 0.17)
    readonly property color selHoverBg:     Qt.alpha(primary, 0.22)
    readonly property color selPressedBg:   Qt.alpha(primary, 0.26)
    readonly property color hoverBg:        Qt.alpha(Colors.fg, light ? 0.07 : 0.09)
    readonly property color pressedBg:      Qt.alpha(Colors.fg, light ? 0.14 : 0.16)
    readonly property color selBorder:      Qt.alpha(primaryText, 0.64)
    readonly property color focusRing:      primaryText

    /** `fam` (opcional): la familia de la zona (`fam(palette.accent)`); sin ella, primary. Todos los parámetros
     *  llevan tipo: con uno sin anotar, `base` llegaba como texto («transparent», sin `.a`) y la capa de
     *  selección salía con alfa NaN (medido en el banco, 2026-11-21). */
    function controlBg(base: color, hovered: bool, pressed: bool, selected: bool, fam: var): color {
        const f = fam || famPrimary;
        if (selected) return overlay(base, pressed ? f.selPressed : hovered ? f.selHover : f.sel);
        if (pressed || hovered) return overlay(base, pressed ? pressedBg : hoverBg);
        return base;
    }

    // Los interruptores en ON y la selección invertida de Terminal usan acento sólido.
    function activeBg(hovered, pressed, fam) {
        const f = fam || famPrimary;
        return pressed ? f.fillPressed : hovered ? f.fillHover : f.fill;
    }

    function activeText(bg, fam) { return legibleOn((fam || famPrimary).onFill, bg, 4.6); }

    // ---- familias de acento: el reparto del color por zonas (2026-11-21) ----------------

    /**
     * La paleta trae TRES colores con nombre (primary, secondary, tertiary; en Matugen y en las estáticas) y la shell
     * pintaba casi todo con el primero (266 usos frente a 2 de cada uno de los otros): neutros más un acento, monótono.
     * Una FAMILIA es uno de esos roles con todo lo que un control necesita, con las mismas guardas de contraste que
     * primary: glifo (`accent`, 3,5:1), texto (`text`, 4,6:1), relleno sólido y su tinta (`fill`/`onFill`), capas de
     * selección, contorno, anillo de foco, la tarjeta tintada sobre el vidrio (`card`), el contenedor opaco (`container`)
     * y el marco de Terminal. No se inventa ningún color (ADR-1): sólo se reparte el que la paleta ya trae.
     *
     * ZONAS. Una zona se declara en cualquier Item con `palette.accent: Theme.zone("secondary")` y la heredan todos sus
     * hijos (Item.palette de Qt, que se propaga y notifica). Un control la lee con `Theme.fam(palette.accent)`. La clave
     * es un color centinela, no el color real: no depende de la paleta y no choca con el acento del sistema (lo que un
     * Item hereda sin zona), que cae en primary: sin zona, todo sigue como antes. El mapa de qué zona va dónde vive en
     * `lib/accent-zones.js`. Ningún modo (Normal/Focus/Gaming/Cinema) ni estilo cambia la paleta: el reparto es el mismo.
     */
    readonly property var zoneKeys: ({ primary: "#5a0001", secondary: "#5a0002", tertiary: "#5a0003" })
    function zone(name) { return zoneKeys[name] || zoneKeys.primary; }
    function fam(key) {
        if (key !== undefined && key !== null) {
            if (Qt.colorEqual(key, zoneKeys.secondary)) return famSecondary;
            if (Qt.colorEqual(key, zoneKeys.tertiary)) return famTertiary;
        }
        return famPrimary;
    }
    /** La familia por nombre (para quien elige el color sin heredarlo: tarjetas de un modelo, gráficas). */
    function famNamed(name) { return name === "secondary" ? famSecondary : name === "tertiary" ? famTertiary : famPrimary; }

    // El tinte de las tarjetas: un punto sobre el vidrio (translúcido) o sobre una tarjeta opaca.
    readonly property real tintCard: light ? 0.12 : 0.13
    readonly property real tintContainer: light ? 0.15 : 0.17
    function containerOf(base) { return mix(cardBg, base, tintContainer); }
    readonly property color containerPrimary: containerOf(Colors.primary)
    readonly property color containerSecondary: containerOf(Colors.secondaryRole)
    readonly property color containerTertiary: containerOf(Colors.tertiary)

    function makeFamily(name, base, container) {
        const to = contrast(base, textPole) < 1.3 ? surface : textPole;
        const ink = name === "primary" ? Colors.fgOnPrimary : foregroundFor(base);
        // La tinta de acento se mide contra los fondos donde de verdad va (el panel, las tarjetas, su contenedor y su
        // selección), no contra el plano más claro de la paleta: así el color se conserva en vez de lavarse a blanco.
        const card = Qt.alpha(base, tintCard);
        const grounds = [surface, insetBg, surfaceContainerLow, cardBg, container, overlay(surface, card),
                         overlay(surface, Qt.alpha(base, 0.26)), overlay(cardBg, Qt.alpha(base, 0.26)),
                         overlay(container, Qt.alpha(base, 0.26))];
        const text = readableAgainst(base, grounds, 4.5);
        const edge = Settings.materialEdge;
        return {
            name: name, key: zoneKeys[name], base: base,
            accent: legible(base), text: text,
            fill: base, fillHover: mix(base, to, 0.12), fillPressed: mix(base, to, 0.22),
            onFill: legibleOn(ink, base, 4.6),
            sel: Qt.alpha(base, 0.17), selHover: Qt.alpha(base, 0.22), selPressed: Qt.alpha(base, 0.26),
            selBorder: Qt.alpha(text, 0.64), ring: text,
            card: card, cardBorder: Qt.alpha(base, light ? 0.30 : 0.24),
            container: container, veil: Qt.alpha(base, light ? 0.04 : 0.08),
            track: Qt.alpha(base, light ? 0.26 : 0.24),
            frame: Qt.alpha(base, edge === "defined" ? 0.70 : edge === "none" ? 0.30 : 0.45),
            frameMark: Qt.alpha(base, 0.85)
        };
    }
    readonly property var famPrimary: makeFamily("primary", Colors.primary, containerPrimary)
    readonly property var famSecondary: makeFamily("secondary", Colors.secondaryRole, containerSecondary)
    readonly property var famTertiary: makeFamily("tertiary", Colors.tertiary, containerTertiary)

    readonly property color disabledFg: Qt.alpha(fg, 0.42)
    readonly property real disabledOpacity: 0.45
    readonly property color errorBg: Qt.alpha(errorColor, 0.16)

    readonly property var textBackgrounds: {
        const bases = [surface, insetBg, surfaceContainerLow, surfaceContainer, surfaceContainerHigh, cardBg, raisedBg,
                       containerPrimary, containerSecondary, containerTertiary];
        // las capas de selección y de tarjeta de las tres familias (el texto se lee sobre cualquiera de ellas)
        const layers = [Colors.primary, Colors.secondaryRole, Colors.tertiary];
        const backgrounds = [];
        for (const base of bases) {
            backgrounds.push(base, overlay(base, pressedBg), overlay(base, errorBg));
            for (const c of layers)
                backgrounds.push(overlay(base, Qt.alpha(c, 0.26)));
        }
        for (const c of layers) backgrounds.push(overlay(surface, Qt.alpha(c, tintCard)));
        return backgrounds;
    }
}
