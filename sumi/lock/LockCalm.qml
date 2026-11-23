import QtQuick
import "../theme"

/**
 * La calma del Lock (fase 15, entrega 15E; LOCK-D10, futurelocksurface §9 «Calma, despertar y lectura»).
 * Lógica pura, sin nada visual: la monta quien sostiene el contrato (la preview hoy, `LockSession` en la
 * 15G-1), una por sesión, así que todas las pantallas se calman y despiertan a la vez.
 *
 *   · La espera de 10 s mide la ACTIVIDAD DEL USUARIO (teclas, movimiento real del puntero, clic, scroll,
 *     expandir): quien la vea llama a `activity()`. Sensores, canciones y notificaciones no cuentan.
 *   · Empieza al entrar en `locked` (LK-06: antes sólo arrancaba con una tecla o un cambio de `auth`, y
 *     tras una entrada animada sin tocar nada la calma no llegaba nunca).
 *   · Se SUSPENDE mientras se comprueba una contraseña o se sostiene un hold; al terminar, la espera vuelve
 *     a contar entera (para leer el resultado). `holdMessage()` hace lo mismo con un fallo de energía.
 *   · `calm` es visual: no toca la caducidad de 30 s del texto ni los plazos de hypridle.
 */
Item {
    id: root

    property string phase: "unlocked"
    property bool checking: false
    property bool holding: false
    property int calmMs: Motion.lockCalmMs

    /** Sólo hora y fecha. Lo escribe este objeto; los demás lo leen. */
    property bool calm: false
    /** Salió de la calma (para devolver la composición sin repetir la entrada). */
    signal woke()

    readonly property bool armed: root.phase === "locked" && !root.checking && !root.holding

    function activity() {
        if (root.calm) {
            root.calm = false;
            root.woke();
        }
        if (root.armed)
            timer.restart();
    }
    /** Un mensaje que hay que poder leer (fallo de energía): espera entera desde ahora. */
    function holdMessage() { root.activity(); }
    /** Sólo pruebas y escenarios de la preview. */
    function forceCalm() { if (root.phase === "locked") { timer.stop(); root.calm = true; } }

    onArmedChanged: {
        if (root.armed)
            timer.restart();          // al entrar en locked, o al acabar la comprobación o el hold
        else
            timer.stop();             // comprobando o sosteniendo: nunca se calma a mitad
    }
    onPhaseChanged: if (root.phase !== "locked") root.calm = false
    /** Nace ya en `locked` (entrada instantánea, recarga): la espera empieza igual. */
    Component.onCompleted: if (root.armed) timer.start()

    Timer {
        id: timer
        interval: root.calmMs
        onTriggered: if (root.armed) root.calm = true
    }
}
