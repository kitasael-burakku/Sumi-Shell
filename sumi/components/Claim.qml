import QtQuick

/**
 * Una reclamación con nombre, declarada (fase 6A, 2026-09-25).
 *
 * Antes cada superficie repetía lo mismo a mano: `claim(true)` en
 * `onActiveChanged`, OTRA VEZ en `Component.onCompleted` (el host crea la
 * superficie ya abierta y no hay cambio que observar), `claim(false)` en
 * `onDestruction`, y la guarda de clave vacía (QS-FUNC-003). Doce copias con
 * variaciones; en tres servicios eran contadores (`acquire/release`,
 * `subscribe/unsubscribe`), que es justo lo que `Net.claimScan` ya había
 * demostrado que se desincroniza.
 *
 *     Claim { target: Net; method: "claimScan"; key: root.scanKey; value: root.active }
 *
 * Contrato del servicio: `target[method](who, value)`, donde un valor falso
 * suelta y cualquier otro reclama (un nivel, como en Sysmon, o `true`). La
 * llamada tiene que ser idempotente por `who`.
 *
 * El objeto recuerda lo que TIENE reclamado (clave y valor), no lo que debería:
 * si la clave cambia, suelta la vieja antes de coger la nueva, y al destruirse
 * suelta lo que tenga. Mientras la clave está vacía no reclama nada.
 */
QtObject {
    id: root

    property var target: null
    property string method: "claim"
    property string key: ""
    property var value: false

    /** Lo reclamado ahora mismo (para `ipc subscriptions` y para soltar bien). */
    property string heldKey: ""
    property var heldValue: false
    property bool ready: false

    function apply() {
        if (!root.ready || !root.target) return;
        const k = root.key;
        const v = k.length > 0 && root.value ? root.value : false;
        if (root.heldKey.length > 0 && (root.heldKey !== k || !v)) {
            root.target[root.method](root.heldKey, false);
            root.heldKey = "";
            root.heldValue = false;
        }
        if (v && (root.heldKey !== k || root.heldValue !== v)) {
            root.target[root.method](k, v);
            root.heldKey = k;
            root.heldValue = v;
        }
    }

    onKeyChanged: root.apply()
    onValueChanged: root.apply()
    onTargetChanged: root.apply()
    // Los bindings de la superficie se evalúan en cualquier orden al construir:
    // se espera a que estén todos, y sólo entonces se reclama.
    Component.onCompleted: { root.ready = true; root.apply(); }
    Component.onDestruction: {
        if (root.target && root.heldKey.length > 0)
            root.target[root.method](root.heldKey, false);
    }
}
