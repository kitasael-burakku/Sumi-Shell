pragma Singleton
import QtQuick
import Quickshell

/**
 * Borradores NO sensibles, fuera de las superficies (rediseño, fase 4; DESIGN §2,
 * «Política de edición»): una respuesta a medio escribir o el mensaje del commit de
 * dotbackup sobreviven a cerrar el panel, a que el Loader se descargue y a navegar
 * con Back/Forward. Al volver, la superficie los enseña marcados como **Draft** y
 * ofrece **Discard draft**. Nunca se envían ni se aplican al salir.
 *
 * SÓLO EN MEMORIA: no se escriben a disco ni entran en settings.json ni en el
 * historial, y no sobreviven a un reinicio del shell (DESIGN: «Los borradores no
 * sobreviven por defecto a un reinicio del proceso»). Nada secreto pasa por aquí:
 * las contraseñas tienen su propio ciclo (Guarded) y se borran al descartar.
 *
 * Clave = recurso: `notif-reply:<clave de la notificación>`, `dotbackup:message`.
 */
Singleton {
    id: root

    /** { clave: { text, at } } — se reasigna entero (un var no notifica por dentro). */
    property var drafts: ({})

    function get(key) { const d = root.drafts[key]; return d ? d.text : ""; }
    function has(key) { return root.drafts[key] !== undefined; }

    function set(key, text) {
        const next = Object.assign({}, root.drafts);
        if (!text || text.length === 0) delete next[key];
        else next[key] = { text: String(text).slice(0, 8000), at: Date.now() };
        root.drafts = next;
    }

    function discard(key) {
        if (!root.has(key)) return;
        const next = Object.assign({}, root.drafts);
        delete next[key];
        root.drafts = next;
    }

    function summary() { return { count: Object.keys(root.drafts).length, keys: Object.keys(root.drafts) }; }
}
