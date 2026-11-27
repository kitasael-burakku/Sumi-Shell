.pragma library

/**
 * Distribución del Centro de control (rediseño del 2026-11-15, boceto del autor).
 *
 * La v1 es FIJA: nadie la edita todavía. Pero la superficie no se dibuja «a mano» en orden: lee esta tabla, que dice
 * qué pieza va en qué hueco, y de ella sale también el orden del teclado. Así, más adelante, reordenar, ocultar,
 * añadir accesos propios o elegir otra distribución será cambiar DATOS (un ajuste, un preset), no el QML.
 *
 * Lo que NO es esto: ni un editor ni un ajuste guardado (eso, cuando el autor lo pida). Una pieza desconocida o que no
 * tiene sentido en este equipo (sin batería, por ejemplo) se ignora sin romper nada: `resolve()`.
 *
 *   header      piezas de la cabecera, a la derecha del título (por orden)
 *   main.left   tarjetas apiladas a la izquierda
 *   main.right  deslizadores verticales a la derecha (columnas, por orden)
 *   secondary   una fila; `weight` es la parte del ancho de cada pieza
 *   tertiary    otra fila igual debajo (F10, 2026-11-27: perfil de energía y Keep awake); mismos pesos que la de encima
 *               para que los bordes coincidan. Una pieza que no existe en este equipo (sin perfiles) cede su sitio.
 *   notifications.max  cuántos avisos sin leer se enseñan (D4: 3)
 */

var VERSION = 1;

/** Las piezas que la superficie sabe dibujar, y dónde pueden ir. */
var PIECES = {
    battery:    { slot: "header" },
    settings:   { slot: "header" },
    network:    { slot: "main.left" },
    bluetooth:  { slot: "main.left" },
    volume:     { slot: "main.right" },
    brightness: { slot: "main.right" },
    mode:       { slot: "secondary" },
    dnd:        { slot: "secondary" },
    power:      { slot: "tertiary" },
    awake:      { slot: "tertiary" }
};

var DEFAULT = {
    version: 1,
    header: ["battery", "settings"],
    main: { left: ["network", "bluetooth"], right: ["volume", "brightness"] },
    secondary: [{ id: "mode", weight: 2 }, { id: "dnd", weight: 3 }],
    tertiary: [{ id: "power", weight: 2 }, { id: "awake", weight: 3 }],
    notifications: { show: true, max: 3 }
};

function known(id, slot) { return PIECES[id] !== undefined && PIECES[id].slot === slot; }

/**
 * La distribución que se dibuja: `layout` (o la de serie) sin piezas desconocidas, repetidas o fuera de su hueco.
 * `hidden` (lista de ids) quita piezas aunque estén; hoy nadie la usa.
 */
function resolve(layout, hidden) {
    var l = layout && layout.version === VERSION ? layout : DEFAULT;
    var off = hidden || [];
    var seen = {};
    function keep(id, slot) {
        if (!known(id, slot) || seen[id] || off.indexOf(id) >= 0) return false;
        seen[id] = true;
        return true;
    }
    var header = (l.header || []).filter(function (id) { return keep(id, "header"); });
    var left = ((l.main || {}).left || []).filter(function (id) { return keep(id, "main.left"); });
    var right = ((l.main || {}).right || []).filter(function (id) { return keep(id, "main.right"); });
    var secondary = (l.secondary || []).filter(function (x) { return x && keep(x.id, "secondary"); })
        .map(function (x) { return { id: x.id, weight: x.weight > 0 ? x.weight : 1 }; });
    var tertiary = (l.tertiary || []).filter(function (x) { return x && keep(x.id, "tertiary"); })
        .map(function (x) { return { id: x.id, weight: x.weight > 0 ? x.weight : 1 }; });
    var n = l.notifications || {};
    return { header: header, left: left, right: right, secondary: secondary, tertiary: tertiary,
             notifications: { show: n.show !== false, max: Math.max(0, Math.min(5, n.max === undefined ? 3 : n.max)) } };
}

/**
 * Las paradas del teclado, en el orden de lectura: cabecera, tarjetas (cada una: su vista y su interruptor), deslizadores,
 * filas secundaria y terciaria, avisos. `ctx` dice lo que existe ahora: { battery, brightness, power, notifs: n, more, clear }.
 */
function slots(r, ctx) {
    var out = [];
    var each = {
        battery: function () { if (ctx.battery) out.push("battery"); },
        settings: function () { out.push("settings"); },
        network: function () { out.push("netOpen", "netToggle"); },
        bluetooth: function () { out.push("btOpen", "btToggle"); },
        volume: function () { out.push("sound"); },
        brightness: function () { if (ctx.brightness) out.push("brightness"); },
        mode: function () { out.push("mode"); },
        dnd: function () { out.push("dnd"); },
        power: function () { if (ctx.power) out.push("power"); },
        awake: function () { out.push("awake"); }
    };
    r.header.forEach(function (id) { each[id](); });
    r.left.forEach(function (id) { each[id](); });
    r.right.forEach(function (id) { each[id](); });
    r.secondary.forEach(function (x) { each[x.id](); });
    (r.tertiary || []).forEach(function (x) { each[x.id](); });
    if (r.notifications.show) {
        for (var i = 0; i < ctx.notifs; i++) out.push("notif:" + i, "dismiss:" + i);
        if (ctx.more) out.push("more");
        if (ctx.clear) out.push("clearAll");
    }
    return out;
}
