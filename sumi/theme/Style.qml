pragma Singleton
import QtQuick
import Quickshell
import "../services"

/**
 * Estilo de interfaz (Interface style, 2026-11-14; ADR-34). Es el eje de la **forma**: geometría, marco, decoraciones
 * y presentación de los controles. No decide color (Theme/Colors, matugen), ni material (relleno y opacidad: Theme),
 * ni familias o tamaños de letra (Typography, salvo pedirle su `mono`), ni tiempos (Motion).
 *
 * Mismo patrón que `Motion.windowStyles`: una tabla declarativa por nombre, `params(name)` para quien tenga que dibujar
 * un estilo que no es el activo (las miniaturas de Settings) y `now` para todos los demás. Los tokens de `Metrics`
 * (radios y uniones de la forma) se enlazan a `now`; Glass y los controles con presentación propia leen `name`.
 *
 * Reglas (ADR-34):
 *  - Este singleton no lee Metrics ni Theme: así ningún enlace puede volver sobre sí mismo.
 *  - Nada se asigna imperativamente al cambiar de estilo: todo es binding o un Loader cuyo `active` depende de aquí.
 *    Volver a `soft` deja exactamente los mismos valores que antes de existir este archivo.
 *  - `override` (sólo pruebas: IPC `style`) manda sobre el ajuste y no se guarda; una recarga lo borra.
 */
Singleton {
    id: style

    /**
     * soft      la forma de siempre: radios, cápsulas, filetes en las uniones, velo de acento.
     * terminal  Terminal Interface: esquina 0, uniones rectas, sin velo, marco técnico, texto monoespaciado.
     *
     * Cada clave de geometría es la cifra de `Metrics` en px lógicos a escala 1. `pill` dice si las cápsulas de control
     * son cápsulas (`Metrics.pill(h)` = h/2) o toman `pillR`. `frame`/`decor`/`monoText` de terminal son los valores por
     * defecto: los del usuario se mezclan en `now`. `cornerScale` multiplica los radios que aún son cifras sueltas
     * (`Metrics.r(n)`): 1 los deja como estaban. `label`/`note`: el nombre y la línea del selector de Settings (texto de
     * la UI, en inglés).
     */
    readonly property var styles: ({
        soft: {
            rXs: 5, rSm: 8, rMd: 12, rLg: 16,
            restCorner: 18, notchCorner: 18, openCorner: 22,
            notchShoulder: 8, notchFlareW: 24, notchFlareH: 15, barShoulder: 22,
            pill: true, pillR: 0, cornerScale: 1,
            veil: true, frame: "none", decor: "none", monoText: false, effects: false,
            label: "Soft", note: "Rounded panels and capsules, with the accent veil"
        },
        terminal: {
            rXs: style.squareR, rSm: style.squareR, rMd: style.squareR, rLg: style.squareR,
            restCorner: style.squareR, notchCorner: style.squareR, openCorner: style.squareR,
            notchShoulder: 0, notchFlareW: 0, notchFlareH: 0, barShoulder: 0,
            pill: false, pillR: style.squareR, cornerScale: 0,
            veil: false, frame: "single", decor: "minimal", monoText: true, effects: true,
            label: "Terminal", note: "Square frames, monospace text and text-mode controls"
        }
    })
    readonly property var names: ["soft", "terminal"]
    /**
     * La esquina «recta» de terminal: 0,01 px, no 0. Medido el 2026-11-14 (banco tools/interface-style): un Rectangle
     * que pasa EN CALIENTE de radio > 0 a radio 0 (soft → terminal) deja su zona sin lo que hay debajo —se ve el fondo de
     * escritorio a través del vidrio: la columna de Monitor, la pista del Slider—; arrancando ya en terminal no pasa, y
     * con 0,01 tampoco. Hipótesis: con radio 0 Qt apaga el suavizado por defecto y el nodo cambia de material dentro de un
     * lote ya montado. Con 0,01 el camino de dibujo es el mismo que en soft y a la vista la esquina es recta.
     * Las Shape (uniones de la muesca y de la barra) sí van a 0: no son Rectangles.
     */
    readonly property real squareR: 0.01

    property string override: ""
    readonly property string name: {
        const n = style.override !== "" ? style.override : Settings.interfaceStyle;
        return style.styles[n] ? n : "soft";
    }
    readonly property bool terminal: style.name === "terminal"

    function params(n) { return style.styles[n] || style.styles.soft; }

    /**
     * Los efectos que de verdad están vivos (F5; ADR-34 y ADR-23): el ajuste del usuario, si el estilo los admite
     * (`effects`) y, para lo animado, sólo con movimiento Normal: Reduced y Off los quitan, y con ellos los modos Focus y
     * Gaming (lib/modes.js bajan el movimiento). El encendido (Power-on) dejó de ser un efecto el 2026-11-17 (ADR-36): es
     * un estilo de ventana, para Soft y Terminal (theme/Reveal). Cada efecto vive en un Loader cuyo `active` sale de aquí:
     * apagado = objeto destruido. Glass añade lo suyo (nunca en el bloqueo ni en lo pequeño; nunca en lo que pide calma).
     *   scanlines  líneas finas estáticas detrás del contenido;
     *   glow       la sombra del panel, del color del acento;
     *   glitch     "off" | "subtle" | "strong": un tirón breve de las marcas del marco al aparecer un panel.
     */
    readonly property var fx: {
        const on = style.params(style.name).effects === true;
        const moving = Motion.mode === "normal";
        return {
            scanlines: on && Settings.fxScanlines,
            glow: on && Settings.fxGlow,
            glitch: on && moving ? Settings.fxGlitch : "off"
        };
    }

    /**
     * Hace sonar la interferencia (components/Interference) más cercana a `item`: sube por sus ancestros y en cada uno
     * busca un hijo `interferenceHost` (la de la ventana o la del island). Para lo que cambia de vista por dentro de una
     * superficie (Settings, las pestañas del Dashboard). false si no hay ninguna o no sonó.
     */
    function interfere(item) {
        let o = item;
        for (let d = 0; o && d < 40; d++, o = o.parent) {
            const ch = o.children || [];
            for (let i = 0; i < ch.length; i++)
                if (ch[i] !== item && ch[i].objectName === "interferenceHost") return ch[i].ping();
        }
        return false;
    }

    /** El estilo activo con las preferencias del usuario encima (sólo las que ese estilo admite). */
    readonly property var now: {
        const base = style.params(style.name);
        if (style.name !== "terminal") return base;
        const o = Object.assign({}, base);
        o.frame = Settings.termFrame;
        o.decor = Settings.termDecor;
        o.monoText = Settings.termMono;
        return o;
    }
}
