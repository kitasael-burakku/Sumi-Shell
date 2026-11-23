pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower

/**
 * Perfil de energia (Fase 9.d), el equivalente del modulo
 * `power-profiles-daemon` de Waybar.
 *
 * BINDING NATIVO (QS-FUNC-006, 2026-09-14). Antes eran dos `powerprofilesctl`
 * y un regex sobre el asterisco de `list`, con la justificacion de que 0.3.1
 * no tiene D-Bus generico -- cierto, pero hay un singleton dedicado,
 * `PowerProfiles`. Lo que se gana no son los dos procesos: es que el perfil se
 * entera de los cambios AJENOS (`desktop-mode.sh` en gaming, el propio daemon
 * degradando por temperatura). Antes el shell enseñaba el viejo hasta reabrir.
 *
 * Medido con sonda `qs -p` sobre el daemon real:
 *   · escribir `PowerProfiles.profile = Performance` -> `powerprofilesctl get`
 *     = `performance`;
 *   · `powerprofilesctl set power-saver` desde fuera -> `profileChanged` llega;
 *
 * 11D-2: las opciones siguen hasPerformanceProfile del binding instalado. Mientras
 * se comprueba el daemon no se ofrecen perfiles; su señal actualiza la capacidad.
 *
 * Lo unico que el binding no dice es si el daemon esta: sin el, `profile` se
 * queda en su valor por defecto sin avisar. 9.d fijo (P5) que entonces el
 * selector SE OCULTA, y eso se conserva con una lectura de `ActiveProfile` por
 * `busctl` al abrir la superficie: un proceso al abrir, ninguno en uso.
 */
Singleton {
    id: root

    /** Nombres de `powerprofilesctl`, en el orden del enum de Quickshell. */
    readonly property var names: ["power-saver", "balanced", "performance"]

    readonly property string current: root.present ? root.names[PowerProfiles.profile] || "" : ""
    readonly property var available: root.present ? (PowerProfiles.hasPerformanceProfile ? ["performance", "balanced", "power-saver"] : ["balanced", "power-saver"]) : []
    readonly property bool ok: root.available.length > 0

    /** El daemon respondio a la ultima comprobacion. */
    property bool present: false
    /** 9D-2: ya se comprobó una vez (antes, `present` false no significa «ausente»). */
    property bool checked: false

    /**
     * Por que el daemon rebaja el perfil, o "" si no lo hace. Solo los dos
     * motivos del enum: con el daemon sin degradar la sonda leyo un valor que
     * `toString` llama «Invalid», no «None».
     */
    readonly property string degradation: {
        const d = PowerProfiles.degradationReason;
        if (d === PerformanceDegradationReason.HighTemperature) return "high temperature";
        if (d === PerformanceDegradationReason.LapDetected) return "lap detected";
        return "";
    }

    /** Quien retiene un perfil ahora mismo: [{ app, profile, reason }]. */
    readonly property var holds: {
        const out = [];
        const hs = PowerProfiles.holds;
        for (let i = 0; i < hs.length; i++)
            out.push({ app: String(hs[i].applicationId), profile: root.names[hs[i].profile] || "",
                       reason: String(hs[i].reason) });
        return out;
    }

    /** Iconos con los mismos codepoints que usaba Waybar. */
    readonly property var glyphs: ({
        "performance": "󰓅",
        "balanced":    "󰗑",
        "power-saver": "󰌪"
    })

    /** Al abrir la superficie: ¿esta el daemon? El perfil ya es un binding. */
    function refresh() { if (!presenceProc.running) presenceProc.running = true; }
    Connections { target: Session; function onResumed() { root.refresh(); } }

    // ---- pedir y comprobar (fase 6C) ---------------------------------------

    /**
     * LO PEDIDO NO ES LO QUE HAY. Medido el 2026-09-25 con `qs -p`: escribir
     * `PowerProfiles.profile` cambia el valor LOCAL al instante (optimista), y el
     * daemon contesta después con un eco por petición, en orden. Dos cambios
     * seguidos hacían pasar el binding por el perfil viejo; y con UNA petición
     * no llega eco ninguno, así que el binding no puede confirmar nada.
     *
     * Por eso: la petición lleva revisión (`ops`), el selector pinta lo pedido
     * mientras está en vuelo (`shownProfile`), y 300 ms después de la ÚLTIMA
     * petición se lee `ActiveProfile` por D-Bus, por otro camino. Si coincide,
     * éxito observado; si no, error con el motivo (un hold de otra app, o el
     * daemon que no contesta). Una lectura lanzada para una revisión vieja se
     * descarta al volver.
     */
    readonly property Ops ops: Ops { name: "profile" }

    /** El perfil a pintar: lo pedido en vuelo; si no, lo que hay. */
    readonly property string shownProfile: { void root.ops.table; return root.ops.shown("", root.current); }
    readonly property string opState: { void root.ops.table; return root.ops.stateOf(""); }
    readonly property string opReason: { void root.ops.table; return root.ops.get("").reason; }
    readonly property bool applying: root.opState === "pending"
    property string pendingProfile: ""

    function setProfile(name) {
        const i = root.names.indexOf(String(name));
        if (i < 0 || (root.checked && root.available.indexOf(String(name)) < 0)) return -1;
        // Lo mismo que ya está pedido (o que ya hay, sin nada en vuelo): nada que hacer.
        if (name === root.shownProfile && (root.applying || root.opState !== "error")) return 0;
        const r = root.ops.request("", String(name));
        if (!root.checked) {
            // Modes puede pedir un perfil antes de abrir ninguna UI. Comprobar antes de escribir,
            // conservando la revisión y el contrato asíncrono que ya usa Modes.
            root.pendingProfile = String(name);
            root.refresh();
        } else root.submitProfile(String(name));
        return r;
    }
    function submitProfile(name) {
        if (root.available.indexOf(name) < 0) {
            root.ops.resolve("", root.ops.latest(""), "error", "The requested power profile is unavailable");
            return;
        }
        PowerProfiles.profile = root.names.indexOf(name);
        verifyDelay.restart();
    }

    Timer {
        id: verifyDelay
        interval: 300
        repeat: false
        onTriggered: root.verify()
    }

    function verify() {
        if (!root.ops.pending("")) return;
        // Una lectura en vuelo es de una revisión anterior: se relanza al volver.
        if (verifyProc.running) { verifyProc.again = true; return; }
        verifyProc.rev = root.ops.latest("");
        verifyProc.again = false;
        verifyProc.running = true;
    }

    Process {
        id: verifyProc
        property int rev: 0
        property bool again: false
        command: ["timeout", "3", "busctl", "--system", "--json=short", "get-property",
                  "org.freedesktop.UPower.PowerProfiles", "/org/freedesktop/UPower/PowerProfiles",
                  "org.freedesktop.UPower.PowerProfiles", "ActiveProfile"]
        stdout: StdioCollector { id: verifyOut }
        onExited: (code) => {
            const asked = String(root.ops.get("").requested || "");
            if (code !== 0) {
                root.present = false;
                root.ops.resolve("", verifyProc.rev, "error", "The power daemon is not answering");
            } else {
                root.present = true;
                let got = "";
                try { got = String(JSON.parse(verifyOut.text).data); } catch (e) {}
                if (got === asked)
                    root.ops.resolve("", verifyProc.rev, "ok", "", got);
                else
                    root.ops.resolve("", verifyProc.rev, "error", root.whyNot(got), got);
            }
            if (verifyProc.again) root.verify();
        }
    }

    /** Por qué el daemon dejó otro perfil. Los holds son el caso conocido. */
    function whyNot(got) {
        const hs = root.holds;
        if (hs.length > 0)
            return "Held on " + (got || "?") + " by " + hs.map(h => h.app).join(", ");
        return "The daemon kept " + (got || "an unknown profile");
    }

    Process {
        id: presenceProc
        command: ["busctl", "--system", "--timeout=3", "--json=short", "get-property",
                  "org.freedesktop.UPower.PowerProfiles", "/org/freedesktop/UPower/PowerProfiles",
                  "org.freedesktop.UPower.PowerProfiles", "ActiveProfile"]
        onExited: (code) => {
            root.present = code === 0; root.checked = true;
            if (root.pendingProfile) {
                const name = root.pendingProfile; root.pendingProfile = "";
                root.submitProfile(name);
            }
        }
    }
}
