pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Bluetooth

/**
 * Bluetooth (Fases 9.f.1 lectura y 9.f.3 accion): lo que daban
 * `waybar/scripts/bluetooth.sh` y `rofi/scripts/bluetooth.sh`, sin ninguno de
 * los dos scripts.
 *
 * Se cae el andamiaje entero del original. Ya no hay `interval: 20` ni
 * `pkill -RTMIN+9 waybar`: `Quickshell.Bluetooth` avisa por D-Bus. Y la
 * bateria por dispositivo, que al script le costaba 0-2 llamadas a
 * `bluetoothctl info` cada 20 s, aqui es `batteryAvailable` / `battery`.
 *
 * MISMA PUERTA `settled` QUE `Net`, y aqui hace mas falta todavia: sin ella no
 * se puede distinguir "el modelo aun no ha llegado" (medido: `defaultAdapter`
 * es `null` en `Component.onCompleted` y objeto a los 55 ms) de "esta maquina
 * no tiene adaptador", que es justo la distincion que el autor del script
 * arreglo a mano en su linea 54 -- sin ella decia "Bluetooth off" y te mandaba
 * a buscar un interruptor que no existe.
 *
 * NI UN PROCESO, tampoco en la parte de accion: `connect`, `disconnect`,
 * `pair`, `cancelPair`, `forget`, `trusted` y `blocked` son API de tipos, no
 * invocaciones de `bluetoothctl`.
 */
Singleton {
    id: root

    // ---- puerta de "aun no se sabe" ---------------------------------------

    property bool settled: false

    Timer {
        interval: 1500
        running: true
        repeat: false
        onTriggered: root.settled = true
    }

    readonly property var adapter: Bluetooth.defaultAdapter
    readonly property bool hasData: root.adapter !== null
    readonly property bool ready: root.hasData || root.settled

    // ---- adaptador ---------------------------------------------------------

    /** Falso de verdad: se espero el margen y no hay adaptador (W2). */
    readonly property bool present: root.adapter !== null
    readonly property string adapterName: root.adapter ? root.adapter.name : ""
    readonly property bool powered: root.adapter !== null && root.adapter.enabled
    readonly property bool discovering: root.adapter !== null && root.adapter.discovering

    readonly property string state: root.adapter
        ? BluetoothAdapterState.toString(root.adapter.state) : ""

    /**
     * rfkill. `Blocked` es un estado propio del adaptador que el script
     * original no sabia ver: para el, bloqueado y apagado eran lo mismo.
     */
    readonly property bool blocked: root.adapter !== null
        && root.adapter.state === BluetoothAdapterState.Blocked

    /**
     * Medido el 2026-09-09 y CORRIGE lo que decia la documentacion de la
     * parada tecnica ("pairable por defecto ya es true"): en este adaptador
     * vale **false**, y `bluetoothctl show` dice `Pairable: no` en la misma
     * corrida. No estorba a `pair()`, que es saliente; solo afecta a
     * peticiones entrantes. Se publica para no volver a suponerlo.
     */
    readonly property bool pairable: root.adapter !== null && root.adapter.pairable
    readonly property bool discoverable: root.adapter !== null && root.adapter.discoverable

    // ---- dispositivos ------------------------------------------------------

    readonly property var all: Bluetooth.devices.values

    readonly property var connectedDevices: {
        const out = [];
        const ds = root.all;
        for (let i = 0; i < ds.length; i++)
            if (ds[i].connected) out.push(ds[i]);
        return out;
    }

    readonly property int connectedCount: root.connectedDevices.length
    readonly property int pairedCount: {
        let n = 0;
        const ds = root.all;
        for (let i = 0; i < ds.length; i++) if (ds[i].paired) n++;
        return n;
    }

    /** El umbral del original, literal: `batt <= 20` da la clase `low-battery`. */
    readonly property bool lowBattery: {
        const ds = root.connectedDevices;
        for (let i = 0; i < ds.length; i++)
            if (ds[i].batteryAvailable && ds[i].battery * 100 <= 20) return true;
        return false;
    }

    /**
     * ORDEN: conectados, luego emparejados, luego el resto; dentro de cada
     * grupo por nombre. Es R9 de `wifi.sh` trasladado -- lo util arriba.
     */
    /**
     * Anonimos AL FINAL, tomado de ukishima. Con 6 de 8 vecinos sin nombre en
     * este entorno (medido), mezclarlos por orden alfabetico de su MAC empujaba
     * los aparatos utiles hacia abajo cada vez que un escaneo traia uno nuevo.
     */
    function rank(d) {
        if (d.connected) return 0;
        if (d.paired) return 1;
        return root.isAnonymous(d) ? 3 : 2;
    }

    function order(xs) {
        const ys = xs.slice();
        ys.sort((a, b) => {
            const ra = root.rank(a), rb = root.rank(b);
            if (ra !== rb) return ra - rb;
            return root.labelOf(a).localeCompare(root.labelOf(b));
        });
        return ys;
    }

    /** T4: lo YA emparejado, que es lo que el menu principal de rofi listaba. */
    readonly property var pairedDevices: {
        const out = [];
        const ds = root.all;
        for (let i = 0; i < ds.length; i++) if (ds[i].paired) out.push(ds[i]);
        return root.order(out);
    }

    /** T7: lo encontrado que **no** esta emparejado. */
    readonly property var foundDevices: {
        const out = [];
        const ds = root.all;
        for (let i = 0; i < ds.length; i++) if (!ds[i].paired) out.push(ds[i]);
        return root.order(out);
    }

    /**
     * Lo que la superficie pinta. Lo encontrado solo aparece **mientras se
     * busca**, y no es un capricho: bluez CACHEA lo visto (medido el
     * 2026-09-09 -- `bluetoothctl devices` seguia listando los 8 vecinos
     * despues de parar el escaneo). Sin esta puerta, una lista que dice "tus
     * dispositivos" se llenaria de televisores ajenos vistos hace horas. Es la
     * misma separacion que hacia rofi entre su menu principal y su submenu de
     * busqueda.
     */
    readonly property bool showFound: root.scanWanted || root.discovering
    readonly property var devices: root.showFound
        ? root.pairedDevices.concat(root.foundDevices)
        : root.pairedDevices

    function deviceAt(i) {
        return (i >= 0 && i < root.devices.length) ? root.devices[i] : null;
    }

    function byAddress(addr) {
        const ds = root.all;
        for (let i = 0; i < ds.length; i++) if (ds[i].address === addr) return ds[i];
        return null;
    }

    function indexOfAddress(addr) {
        for (let i = 0; i < root.devices.length; i++)
            if (root.devices[i].address === addr) return i;
        return -1;
    }

    /**
     * Un aparato que no anuncia nombre llega con el MAC en guiones como
     * `name` (medido: 6 de 8 vecinos, `5E-7F-0A-0A-6C-8F`). Saberlo importa
     * para no pintar la misma cadena dos veces en la misma fila.
     */
    function isAnonymous(d) {
        if (!d) return true;
        const a = String(d.address).toUpperCase();
        const norm = (x) => String(x).replace(/-/g, ":").toUpperCase();
        const dn = String(d.deviceName || "");
        if (dn.length > 0 && norm(dn) !== a) return false;
        const n = String(d.name || "");
        if (n.length > 0 && norm(n) !== a) return false;
        return true;
    }

    /**
     * La etiqueta que se pinta. **`deviceName` antes que `name`**, tomado de
     * ukishima: `name` es el ALIAS -- property de escritura, y una cadena vacia
     * la devuelve al nombre del aparato-- mientras que `deviceName` es el
     * nombre real que anuncia el cacharro. Si alguien dejo un alias raro puesto,
     * asi no tapa al de fabrica.
     *
     * El alias no se pierde: cuando difiere, la ficha lo ensena en su propia
     * fila (`aliasOf`), que es donde hay sitio para los dos.
     */
    function labelOf(d) {
        if (!d) return "";
        if (root.isAnonymous(d)) return String(d.address);
        const dn = String(d.deviceName || "");
        return dn.length > 0 ? dn : String(d.name || "");
    }

    /** El alias, solo si dice algo distinto del nombre del aparato. */
    function aliasOf(d) {
        if (!d) return "";
        const n = String(d.name || ""), dn = String(d.deviceName || "");
        if (n.length === 0 || dn.length === 0) return "";
        return (n !== dn) ? n : "";
    }

    /**
     * Glifo por clase de aparato. `BluetoothDevice.icon` es un nombre de icono
     * del sistema, pero llega **vacio la mayoria de las veces** (medido: 6 de
     * 8 vecinos sin icono, `audio-card` en dos), asi que hace falta reserva.
     *
     * Los codepoints se render-verificaron contra IosevkaTermNerdFontPropo el
     * 2026-09-09 -- y ahi cayo uno: `U+F0FFF` no es "devices", es un eslabon
     * tachado. Es exactamente el tropiezo de `U+F0085`, que resulto ser una
     * bateria y no un portapapeles.
     */
    function deviceGlyph(d) {
        if (!d) return "bt";
        const ic = String(d.icon || "");
        if (ic.indexOf("headset") >= 0) return "headset";
        if (ic.indexOf("headphone") >= 0) return "headphones";
        if (ic.indexOf("audio") >= 0 || ic.indexOf("multimedia") >= 0) return "speaker";
        if (ic.indexOf("keyboard") >= 0) return "keyboard";
        if (ic.indexOf("mouse") >= 0) return "mouse";
        if (ic.indexOf("gaming") >= 0 || ic.indexOf("joystick") >= 0) return "controller";
        if (ic.indexOf("phone") >= 0) return "cellphone";
        if (ic.indexOf("computer") >= 0) return "laptop";
        if (ic.indexOf("display") >= 0 || ic.indexOf("video") >= 0) return "tv";
        if (ic.indexOf("printer") >= 0) return "printer";
        if (ic.indexOf("watch") >= 0) return "watch";
        return "bt";
    }

    /** -1 cuando el perfil no la reporta. `battery` viene 0..1, no 0..100. */
    function batteryOf(d) {
        return (d && d.batteryAvailable) ? Math.round(d.battery * 100) : -1;
    }

    function stateOf(d) {
        return d ? BluetoothDeviceState.toString(d.state) : "";
    }

    // ---- glifo -------------------------------------------------------------

    /** Los tres codepoints son los mismos que usa el script del rice. */
    readonly property string icon: {
        if (!root.ready) return "";
        if (!root.present) return "bt-off";
        if (!root.powered) return "bt-off";
        return root.connectedCount > 0 ? "bt-on" : "bt";
    }

    /**
     * Si hay indicador de Bluetooth (ADR-42, uno para la cara hover y la barra): sólo con adaptador, como la batería
     * sólo con batería. Sin hardware no hay nada que pulsar; Settings → System → Environment explica la ausencia.
     */
    readonly property bool shown: root.ready && root.present

    /** Contador al lado del glifo en la cara hover, como el `󰂱 N` original. */
    readonly property string badge: (root.ready && root.powered && root.connectedCount > 0)
        ? String(root.connectedCount) : ""

    // ---- puerta de descubrimiento (9.f.3) ----------------------------------

    /**
     * T6 del script de rofi, y la parte que MENOS trabajo cuesta aqui: alli
     * `bluetoothctl scan on` como invocacion suelta no escanea nada en bluez
     * 5.87 y habia que alimentar una sesion interactiva por stdin y mantenerla
     * viva 6 s. Aqui es una property.
     *
     * Medido el 2026-09-09 con `discovering = true`: 6 aparatos a los 2 s, 7 a
     * los 4 s, 8 a los 10 s, y `bluetoothctl devices` leido en la misma corrida
     * da **los mismos 8**. O sea que el binding no solo enciende la radio: el
     * modelo se puebla de verdad con lo no emparejado.
     *
     * RECLAMACIONES CON NOMBRE, NO UN CONTADOR -- misma lection que
     * `Net.claimScan`: con la descarga perezosa de superficies, un contador
     * acaba desbalanceado y la radio se queda buscando para siempre (o deja de
     * buscar con la superficie abierta). Una reclamacion con nombre es
     * idempotente.
     */
    property var scanClaims: ({})

    function claimScan(who, on) {
        if (on === !!root.scanClaims[who]) return;   // ya estaba asi
        // Hay que construir un objeto NUEVO: reasignar el mismo no dispara la
        // senal de cambio, QML compara `var` por referencia.
        const c = Object.assign({}, root.scanClaims);
        if (on) c[who] = true; else delete c[who];
        root.scanClaims = c;
        if (root.scanWanted) offGrace.stop();
        else offGrace.restart();
        root.applyScan();
    }

    readonly property bool scanWanted: Object.keys(root.scanClaims).length > 0
    readonly property int scanWatchers: Object.keys(root.scanClaims).length

    /** Margen en el relevo lista -> ficha, igual que en `Net`. */
    Timer {
        id: offGrace
        interval: 2000
        repeat: false
        onTriggered: root.applyScan()
    }

    function applyScan() {
        if (!root.adapter) return;
        const want = (root.scanWanted || offGrace.running) && root.adapter.enabled;
        if (root.adapter.discovering !== want)
            root.adapter.discovering = want;
    }

    /** El adaptador llega tarde (55 ms): al aparecer hay que re-aplicar. */
    onAdapterChanged: root.applyScan()
    // Reconcile after this derived value updates; the adapter signal can arrive
    // while powered still contains the previous value.
    onPoweredChanged: { root.applyScan(); root.reconcile(); }

    // ---- fase de la operacion en curso (9.f.3) -----------------------------

    /**
     * MAQUINA DE ESTADO, y aqui es MAS necesaria que en `Net`, no menos.
     *
     * `Quickshell.Bluetooth` no tiene ninguna senal equivalente a
     * `connectionFailed`: `pair()` y `connect()` no avisan de que fallaron. Lo
     * unico observable es la realidad -- `paired`, `connected`, `pairing` -- asi
     * que la unica manera honesta de decir "no se pudo" es mirarla.
     *
     * El caso que hay que cazar es el del emparejamiento sin agente: el binario
     * de Quickshell **no referencia `org.bluez.AgentManager1`**, asi que un
     * aparato que pida PIN o confirmacion no tiene quien le conteste. La firma
     * esperada es `pairing` subiendo y volviendo a bajar con `paired` todavia
     * en false. Si eso pasa, la superficie tiene que **decirlo** y mandar a
     * rofi (ADR-18), no quedarse girando en "pairing...".
     */
    property string phase: "idle"      // idle | busy | ok | failed | timeout
    property string phaseKind: ""      // "pair" | "connect" | "disconnect"
    property string phaseAddr: ""

    readonly property bool busy: root.phase === "busy"

    /** El aparato observado, por direccion: sobrevive a que el modelo reordene. */
    readonly property var watchDev: root.phaseAddr.length > 0
        ? root.byAddress(root.phaseAddr) : null

    /** Se vio `pairing: true` alguna vez en este intento. */
    property bool sawPairing: false

    function goalMet(d) {
        if (!d) return false;
        if (root.phaseKind === "pair") return d.paired;
        if (root.phaseKind === "connect") return d.connected;
        if (root.phaseKind === "disconnect") return !d.connected;
        return false;
    }

    /**
     * La unica autoridad sobre la fase, como `Net.reconcile()`. `force` es para
     * las transiciones que si tienen que imponerse (el plazo cumplido, o la
     * firma de "el agente no contesto").
     */
    function reconcile(force) {
        if (root.phase === "idle") return;
        /**
         * Mientras la cadena de `bluetoothctl` corre, manda ella. Sin esto, en
         * cuanto `pair` terminara el modelo marcaria `paired` y la fase saltaria
         * a `ok` con `trust` y `connect` todavia sin ejecutar.
         */
        if (root.pairStep !== 0 && force === undefined) return;
        const d = root.watchDev;
        if (root.goalMet(d)) {
            root.failNote = "";
            if (root.phase !== "ok") {
                root.phase = "ok";
                settle.restart();
            }
            watchdog.stop();
            return;
        }
        /**
         * EL EXITO HAY QUE CONFIRMARLO, no basta con verlo un instante.
         * Medido el 2026-09-09 con el mando de PS5: al reconectar sin bond, el
         * aparato pasa por `connected: true` durante el saludo BR/EDR y se cae
         * enseguida (`br-connection-create-socket` en el journal). La version
         * anterior enganchaba `ok` en ese destello y ahi se quedaba, diciendo
         * que la conexion habia ido bien cuando no existia.
         *
         * Con el margen, perder el objetivo mientras la ventana sigue abierta
         * es lo que de verdad es: un fallo. Fuera de la ventana no se toca --
         * desconectar a proposito media hora despues no es un fallo del
         * intento.
         */
        if (root.phase === "ok" && settle.running) {
            root.phase = "failed";
            settle.stop();
            return;
        }
        /**
         * DESCONEXIÓN A MITAD (6C-2): el adaptador apagado mientras conectaba o
         * emparejaba. Antes la fase seguía «busy» hasta el plazo (40 s) y acababa en
         * «timeout»; es un fallo, y se ve en el acto. DESPUÉS de mirar el objetivo:
         * medido el 2026-09-25, el DualSense empareja (y crea bond) en menos de 1 s,
         * y un apagado justo después no deshace un emparejamiento ya hecho.
         */
        if (root.phase === "busy" && root.phaseKind !== "disconnect" && !root.powered) {
            root.phase = "failed";
            root.failNote = "Bluetooth was turned off";
            watchdog.stop();
            return;
        }
        // Firma del emparejamiento abandonado: hubo `pairing` y ya no lo hay,
        // y sigue sin estar emparejado.
        if (root.phaseKind === "pair" && root.sawPairing && d && !d.pairing && !d.paired) {
            root.phase = "failed";
            watchdog.stop();
            return;
        }
        if (force === "failed" || force === "timeout") {
            root.phase = force;
            watchdog.stop();
        }
    }

    /**
     * El plazo es largo a proposito: emparejar tarda. **No cierra el caso** --
     * si el aparato acaba emparejando despues, `reconcile()` lo vera.
     */
    Timer {
        id: watchdog
        /** La cadena tiene dos `timeout 30`, asi que su plazo tiene que caber. */
        interval: root.phaseKind === "pair" ? 75000 : 40000
        repeat: false
        onTriggered: {
            if (root.pairStep !== 0) root.pairEnd(false, "Timed out");
            else root.reconcile("timeout");
        }
    }

    /** Ventana de confirmacion del exito. Ver `reconcile()`. */
    Timer {
        id: settle
        interval: 2500
        repeat: false
    }

    Connections {
        target: root.adapter
        ignoreUnknownSignals: true
        function onEnabledChanged() { root.reconcile(); }
        function onStateChanged() { root.reconcile(); }
    }

    Connections {
        target: root.watchDev
        ignoreUnknownSignals: true
        function onPairedChanged() { root.reconcile(); }
        function onConnectedChanged() { root.reconcile(); }
        function onStateChanged() { root.reconcile(); }
        function onPairingChanged() {
            if (root.watchDev && root.watchDev.pairing) root.sawPairing = true;
            root.reconcile();
        }
    }

    function begin(kind, dev) {
        settle.stop();
        root.failNote = "";
        root.phase = "busy";
        root.phaseKind = kind;
        root.phaseAddr = dev.address;
        root.sawPairing = (kind === "pair") && dev.pairing;
        // DESPUÉS de escribir la fase: `expect` mira en el acto, y con la fase vieja
        // («ok disconnect» del mismo aparato) daba un ok inmediato (medido el 2026-09-25).
        root.expectDevice(kind, dev.address);
        watchdog.restart();
        root.reconcile();     // si ya estaba en el estado pedido, no hay que esperar
    }

    function clearPhase() {
        // Una operación en vuelo que se abandona no terminó bien.
        if (root.ops.pending("device"))
            root.ops.resolve("device", root.ops.latest("device"), "error", "Cancelled");
        root.failNote = "";
        watchdog.stop();
        settle.stop();
        root.pairStep = 0;
        root.pairAddr = "";
        root.phase = "idle";
        root.phaseKind = "";
        root.phaseAddr = "";
        root.sawPairing = false;
    }

    /** El aparato de la fase, si la fase habla de este. */
    function phaseFor(addr) {
        return (root.phaseAddr === addr) ? root.phase : "idle";
    }

    // ---- lo pedido frente a lo efectivo (fase 6C-2) ---------------------------

    /** Un fallo que no dice `bluetoothctl` (el adaptador se apagó a mitad). */
    property string failNote: ""

    /**
     * Las acciones como peticiones con revisión (`services/Ops`), igual que Net.
     * La fase de arriba sigue siendo la autoridad para las superficies; `ops` la
     * refleja por petición:
     *   device         conectar / desconectar / emparejar (una a la vez, como la
     *                  fase): ok cuando la fase es `ok` y su ventana `settle` se
     *                  cerró sin perder el objetivo; error si falla o el adaptador
     *                  se apaga; al plazo, unknown.
     *   power          por `adapter.state`, que SÍ viene de BlueZ (Enabling →
     *                  Enabled en ~560 ms; Disabling → Disabled en ~130 ms). El
     *                  `enabled` escrito es optimista y no trae eco.
     *   trust:, block: `trusted` es optimista y sin eco (medido el 2026-09-25;
     *                  `blocked` no se midió, se trata igual): se leen por `busctl` en
     *                  el objeto del aparato.
     *   forget:<addr>  el aparato deja de estar emparejado (o desaparece).
     */
    readonly property Ops ops: Ops { name: "bt" }

    function expectDevice(kind, addr) {
        const r = root.ops.request("device", kind + " " + addr);
        root.ops.expect("device", r, {
            hold: 0, timeout: (kind === "pair" ? 75000 : 40000) + 5000,
            timeoutState: "unknown", timeoutReason: "Timed out",
            check: function () {
                const mine = root.phaseAddr === addr && root.phaseKind === kind;
                if (!mine) return {};
                if (root.phase === "failed")
                    return { fail: root.failNote || root.pairFail || "Failed" };
                return { met: root.phase === "ok" && !settle.running };
            }
        });
        return r;
    }

    /** `trusted` / `blocked` leídos de BlueZ, no del binding (que dice lo pedido). */
    function verifyDeviceFlag(key, rev, d, prop, want) {
        root.ops.verifyLater(key, rev, 400,
            ["timeout", "3", "busctl", "--system", "get-property", "org.bluez", String(d.dbusPath),
             "org.bluez.Device1", prop],
            function (text, code) {
                if (code !== 0) return ["error", "The device went away"];
                const got = /\btrue\b/.test(text);
                return got === want ? ["ok", "", got]
                                    : ["error", "BlueZ kept " + prop.toLowerCase() + " " + (got ? "on" : "off"), got];
            });
    }

    // ---- acciones ----------------------------------------------------------

    /**
     * OJO CON LOS NOMBRES: nada de `connect`/`disconnect` a secas. Son metodos
     * de QObject en QML (los de las senales) y declararlos aqui los taparia.
     */

    /**
     * B4 de Waybar y T2 de rofi: el interruptor de energia del adaptador.
     *
     * DESBLOQUEA rfkill PRIMERO, tomado de ukishima. BlueZ rechaza de plano el
     * `enabled = true` mientras el controlador esta soft-blocked, asi que sin
     * esto el interruptor no hacia nada visible y habia que mandar al usuario a
     * la terminal. Ahora el shell lo resuelve.
     *
     * argv, nunca `sh -c` (SECURITY.md regla 3) -- ukishima usa shell aqui y en
     * este proyecto no vale.
     */
    function setPower(on) {
        if (!root.adapter) return false;
        const want = !!on;
        const r = root.ops.request("power", want);
        const t0 = Date.now();
        let retried = false;
        root.ops.expect("power", r, {
            hold: 300, timeout: 8000,
            check: function () {
                if (!root.adapter) return { fail: "The adapter went away" };
                const st = root.adapter.state;
                /**
                 * GANA LO ÚLTIMO, también contra BlueZ. Medido el 2026-09-25: apagar y
                 * encender seguidos → el segundo `Powered` se rechaza con
                 * `org.bluez.Error.Busy` (aún se estaba apagando) y el adaptador se
                 * queda apagado, con el binding diciendo «encendido». Si pasado un
                 * momento el adaptador está quieto en lo contrario de lo pedido, se
                 * reaplica UNA vez.
                 */
                const opposite = want ? BluetoothAdapterState.Disabled : BluetoothAdapterState.Enabled;
                if (!retried && st === opposite && Date.now() - t0 > 700 && !root.blocked) {
                    retried = true;
                    console.log("bt: power request not applied (adapter busy?), retrying once");
                    root.adapter.enabled = want;
                }
                return { met: st === (want ? BluetoothAdapterState.Enabled : BluetoothAdapterState.Disabled),
                         effective: BluetoothAdapterState.toString(st),
                         reason: "The adapter is " + BluetoothAdapterState.toString(st).toLowerCase() };
            }
        });
        if (!want) { root.adapter.enabled = false; return true; }
        if (root.blocked) {
            rfkillProc.rev = r;
            rfkillProc.command = ["rfkill", "unblock", "bluetooth"];
            rfkillProc.running = true;
            return true;
        }
        root.adapter.enabled = true;
        return true;
    }

    /** Encender detras del desbloqueo, cuando `rfkill` ya termino. */
    Process {
        id: rfkillProc
        property int rev: 0
        running: false
        stdout: StdioCollector {}
        stderr: StdioCollector {}
        onExited: (code) => {
            if (code !== 0) {
                root.ops.resolve("power", rfkillProc.rev, "error", "rfkill could not unblock Bluetooth");
                return;
            }
            // Sólo si sigue siendo lo último pedido: un «apagar» posterior manda.
            if (root.adapter && root.ops.isLatest("power", rfkillProc.rev)) root.adapter.enabled = true;
        }
    }

    function togglePower() { return root.setPower(!root.powered); }

    /** T5: conectar lo emparejado. */
    function connectTo(addr) {
        const d = root.byAddress(addr);
        if (!d) { console.warn("Bt.connectTo: no such device", addr); return false; }
        root.begin("connect", d);
        d.connect();
        return true;
    }

    /** T5: desconectar lo conectado. */
    function disconnectFrom(addr) {
        const d = root.byAddress(addr);
        if (!d) { console.warn("Bt.disconnectFrom: no such device", addr); return false; }
        root.begin("disconnect", d);
        d.disconnect();
        return true;
    }

    /**
     * T8: EMPAREJAR, y es **el unico proceso de 9.f.3**, con motivo medido.
     *
     * `BluetoothDevice.pair()` del binding empareja pero **no crea bond**:
     * medido el 2026-09-09 con un DualSense, `Paired: true` / `Bonded: false`,
     * y el emparejamiento se evaporaba al desconectar. El mismo mando por
     * `bluetoothctl` -- que SI registra agente -- daba `Bonded: true` y
     * sobrevivia. La causa salio impresa en la corrida de control:
     * `[agent] Authorize service 00001124...` (perfil HID), o sea que hasta un
     * aparato "just works" levanta una peticion de agente, y Quickshell 0.3.1
     * no registra ninguno (seis simbolos comprobados en el binario: ni
     * `AgentManager1`, ni `Agent1`, ni `RequestPinCode`, ni `RequestPasskey`,
     * ni `RequestConfirmation`, ni `RegisterAgent`).
     *
     * No es una carencia inventada: el PR #138 de upstream anadia exactamente
     * ese agente y se cerro sin fusionar el 2025-07-23, con el mantenedor
     * diciendo que tiene implementacion propia planeada. El dia que llegue,
     * esto se puede tirar entero y volver a `d.pair()`.
     *
     * ES EL MISMO CAMINO QUE UKISHIMA, con una diferencia que aqui no es
     * negociable: alli va por `sh -c` y aqui son **tres invocaciones argv
     * encadenadas** por `onExited` (SECURITY.md regla 3). `timeout` acota cada
     * paso porque `bluetoothctl pair` se cuelga si el aparato no responde.
     */
    property int pairStep: 0        // 0 parado · 1 emparejando · 2 confiando+conectando
    property string pairAddr: ""
    /** Ultima linea util de `bluetoothctl`, para poder decir POR QUE fallo. */
    property string pairFail: ""

    /**
     * LA PREGUNTA DEL AGENTE, medida el 2026-09-22 emparejando un iPhone.
     *
     * La sesion interactiva de abajo registra el agente de `bluetoothctl`, asi
     * que BlueZ SI pregunta — y la pregunta llega por el mismo stream que ya se
     * parsea aqui:
     *
     *     [agent] Confirm passkey 753437 (yes/no):
     *
     * Hasta hoy esa linea pasaba de largo: nadie contestaba, BlueZ esperaba sus
     * ~40 s y la ficha acababa ensenando «Failed to pair:
     * org.bluez.Error.AuthenticationTimeout» con el prompt crudo pegado. O sea
     * que el shell TENIA el codigo en la mano y lo ensenaba como error en vez
     * de como pregunta.
     *
     * `askKind`: "confirm" (comparacion numerica, la de los moviles) ·
     * "authorize" (autorizar un servicio) · "type" (pide teclear un PIN o un
     * passkey, que necesita un campo y hoy NO se cubre: se dice y se manda a la
     * terminal). `askCode` son los seis digitos cuando los hay.
     */
    property string askKind: ""
    property string askCode: ""
    property string askText: ""
    readonly property bool asking: root.askKind === "confirm" || root.askKind === "authorize"

    /** Contestar la pregunta del agente. `ok` escribe «yes»; si no, «no». */
    function answerPair(ok) {
        if (!root.asking) return false;
        root.pairSend(ok ? "yes" : "no");
        root.askKind = "";
        root.askCode = "";
        root.askText = "";
        return true;
    }

    function clearAsk() {
        root.askKind = "";
        root.askCode = "";
        root.askText = "";
    }

    /**
     * SESION INTERACTIVA POR STDIN, no una invocacion suelta. Y esto es una
     * leccion pagada DOS veces, la segunda hoy.
     *
     * El autor de `rofi/scripts/bluetooth.sh` ya lo dejo escrito en sus lineas
     * 85-93, pero para `scan on`: una invocacion suelta de `bluetoothctl` no
     * hace el trabajo, hay que alimentar una sesion interactiva por stdin y
     * mantenerla viva. **Lo mismo vale para `pair`**, y por el mismo motivo de
     * fondo: la sesion interactiva es la que registra el agente
     * (`agent on` + `default-agent`). Una invocacion suelta sale antes.
     *
     * Medido el 2026-09-09, mismo mando, mismo adaptador:
     *
     *   `bluetoothctl pair <addr>` suelto (lo que hace ukishima) -> Bonded: FALSE
     *   sesion interactiva con `agent on` + `default-agent`      -> Bonded: TRUE
     *
     * Sin bond el emparejamiento no sobrevive a una desconexion, y ademas el
     * kernel no llega a exponer el aparato: bluez dice `Connected: true` y
     * `/sys/class/input` esta vacio.
     *
     * argv puro (`["bluetoothctl"]`), nunca `sh -c` (SECURITY.md regla 3).
     */
    Process {
        id: pairProc
        running: false
        stdinEnabled: true
        stdout: SplitParser { onRead: (line) => root.pairLine(line) }
        stderr: SplitParser { onRead: (line) => root.pairLine(line) }
        /** Escribir en `onStarted`: antes la sesion aun no existe. */
        onStarted: {
            root.pairSend("agent on");
            root.pairSend("default-agent");
            root.pairSend("pair " + root.pairAddr);
        }
        onExited: (code) => {
            if (root.pairStep !== 0) root.pairEnd(false, "bluetoothctl exited (" + code + ")");
        }
    }

    function pairSend(cmd) {
        if (pairProc.running) pairProc.write(cmd + "\n");
    }

    /**
     * La salida de `bluetoothctl` es la senal de exito y de fallo que la API
     * del binding no da. `indexOf` sobre la linea aguanta los codigos de color
     * porque van alrededor de la frase, no dentro.
     */
    function pairLine(line) {
        if (root.pairStep === 0) return;
        const t = String(line);

        // Las preguntas del agente van antes que nada: mientras haya una en el
        // aire, el emparejamiento esta esperando a una persona, no a la radio.
        const confirm = t.match(/Confirm passkey\s+(\d+)/i);
        if (confirm) {
            root.askKind = "confirm";
            root.askCode = confirm[1];
            root.askText = "Confirm this code also shows on the device";
            return;
        }
        if (/Accept pairing\s*\(yes\/no\)/i.test(t)) {
            root.askKind = "confirm";
            root.askCode = "";
            root.askText = "The device asked to pair";
            return;
        }
        const authorize = t.match(/Authorize service\s+([0-9a-f-]+)/i);
        if (authorize) {
            root.askKind = "authorize";
            root.askCode = "";
            root.askText = "Authorize service " + authorize[1];
            return;
        }
        // Estas piden TECLEAR, que hoy no se cubre: se dice y se corta, en vez
        // de dejar a BlueZ esperando sus 40 s para acabar en un timeout.
        if (/Enter PIN code/i.test(t) || /Enter passkey/i.test(t)) {
            root.askKind = "type";
            root.askCode = "";
            root.askText = "This device needs a typed PIN: pair it with bluetoothctl";
            root.pairEnd(false, root.askText);
            return;
        }

        if (root.pairStep === 1) {
            if (t.indexOf("Pairing successful") >= 0) {
                root.pairStep = 2;
                root.pairSend("trust " + root.pairAddr);
                root.pairSend("connect " + root.pairAddr);
            } else if (t.indexOf("Failed to pair") >= 0) {
                // bluetoothctl may prefix the line with its prompt (a device alias).
                // Keep the error itself, so an unrelated long alias cannot fill the card.
                root.pairEnd(false, t.slice(t.indexOf("Failed to pair")));
            }
        } else if (root.pairStep === 2) {
            if (t.indexOf("Connection successful") >= 0) root.pairEnd(true, "");
            else if (t.indexOf("Failed to connect") >= 0)
                root.pairEnd(false, t.slice(t.indexOf("Failed to connect")));
        }
    }

    function pairEnd(ok, msg) {
        if (root.askKind !== "type")
            root.clearAsk();
        // `bluetoothctl` pinta con codigos ANSI; se limpian para poder ensenar
        // la linea tal cual en la superficie.
        root.pairFail = ok ? ""
            : String(msg).replace(/\x1b\[[0-9;?]*[A-Za-z]/g, "").replace(/\s+/g, " ").trim();
        root.pairSend("quit");
        root.pairStep = 0;
        root.pairAddr = "";
        pairQuit.restart();
        root.reconcile(ok ? undefined : "failed");
    }

    /** Si no se va solo tras `quit`, se le corta. */
    Timer {
        id: pairQuit
        interval: 3000
        repeat: false
        onTriggered: if (pairProc.running) pairProc.running = false;
    }

    function pairWith(addr) {
        const d = root.byAddress(addr);
        if (!d) { console.warn("Bt.pairWith: no such device", addr); return false; }
        if (d.paired) return root.connectTo(addr);
        if (root.pairStep !== 0) return false;     // ya hay una sesion en marcha
        root.begin("pair", d);
        root.pairAddr = addr;
        root.pairFail = "";
        root.clearAsk();
        root.pairStep = 1;
        pairProc.command = ["bluetoothctl"];
        pairProc.running = true;                    // los comandos van en `onStarted`
        return true;
    }

    function cancelPairWith(addr) {
        const d = root.byAddress(addr);
        root.pairStep = 0;
        root.pairAddr = "";
        root.clearAsk();
        if (pairProc.running) { root.pairSend("quit"); pairQuit.restart(); }
        if (d) d.cancelPair();
        root.clearPhase();
        return true;
    }

    /** Desemparejar. No existe `unpair()`: es `forget()`. Es DESTRUCTIVO. */
    function forgetDevice(addr) {
        const d = root.byAddress(addr);
        if (!d) { console.warn("Bt.forgetDevice: no such device", addr); return false; }
        if (!d.paired && !d.bonded) { console.warn("Bt.forgetDevice:", addr, "was not paired"); return false; }
        root.clearPhase();
        const r = root.ops.request("forget:" + addr, addr);
        root.ops.expect("forget:" + addr, r, {
            hold: 0, timeout: 5000, timeoutReason: "Still paired",
            check: function () { const x = root.byAddress(addr); return { met: !x || !(x.paired || x.bonded) }; }
        });
        d.forget();
        return true;
    }

    /** Capacidades que NINGUN original tenia. */
    function setTrusted(addr, on) {
        const d = root.byAddress(addr);
        if (!d) return false;
        const r = root.ops.request("trust:" + addr, !!on);
        d.trusted = !!on;
        root.verifyDeviceFlag("trust:" + addr, r, d, "Trusted", !!on);
        return true;
    }

    function setBlocked(addr, on) {
        const d = root.byAddress(addr);
        if (!d) return false;
        const r = root.ops.request("block:" + addr, !!on);
        d.blocked = !!on;
        root.verifyDeviceFlag("block:" + addr, r, d, "Blocked", !!on);
        return true;
    }

    // ---- ficha de un aparato (9.f.3) ---------------------------------------

    /**
     * La ficha sostiene **el objeto**, no solo la direccion -- misma leccion
     * que `Net.detailObj`: si se guardara la direccion y se buscara en la
     * lista, bastaria con que el aparato saliera del modelo para que la ficha
     * se quedara en blanco con el usuario mirandola.
     */
    /**
     * **Ya no hay «la ficha» aqui** (2026-09-22), igual que en `services/Net`:
     * la seleccion es de cada pantalla y el objeto lo sostiene la ficha. Este
     * servicio responde por direccion (`byAddress`) y lleva la fase de la
     * operacion, que si es unica y va keyed (`phaseAddr`).
     */

    // ---- resumen para el IPC ----------------------------------------------

    /**
     * Lo que publica `status().bluetooth`. Mismo motivo que `Net.summary()`:
     * sin raton, leer el JSON es la unica forma de ejercitar P1, P2 y P3.
     */
    function summary() {
        const devs = [];
        const ds = root.devices;
        for (let i = 0; i < ds.length; i++) {
            const d = ds[i];
            devs.push({ idx: i, name: d.name, address: d.address, icon: d.icon,
                        glyph: root.deviceGlyph(d), anonymous: root.isAnonymous(d),
                        state: BluetoothDeviceState.toString(d.state),
                        connected: d.connected, paired: d.paired, bonded: d.bonded,
                        trusted: d.trusted, blocked: d.blocked, pairing: d.pairing,
                        battery: root.batteryOf(d) });
        }
        return {
            ready: root.ready, settled: root.settled,
            present: root.present, adapter: root.adapterName,
            powered: root.powered, state: root.state, blocked: root.blocked,
            discovering: root.discovering,
            pairable: root.pairable, discoverable: root.discoverable,
            connected: root.connectedCount, paired: root.pairedCount,
            lowBattery: root.lowBattery,
            icon: root.icon, badge: root.badge,
            adapters: Bluetooth.adapters.values.length,
            // 9.f.3: la puerta del escaner y la operacion en curso.
            scanning: root.scanWanted, scanWatchers: root.scanWatchers,
            scanClaims: Object.keys(root.scanClaims),   // QS-FUNC-003
            showFound: root.showFound,
            known: root.pairedDevices.length, found: root.foundDevices.length,
            visible: root.devices.length, total: root.all.length,
            phase: root.phase, phaseKind: root.phaseKind, phaseAddr: root.phaseAddr,
            busy: root.busy, sawPairing: root.sawPairing, pairStep: root.pairStep,
            pairFail: root.pairFail, failNote: root.failNote,
            ops: root.ops.snapshot(),
            // La pregunta del agente, para poder contestarla por IPC sin raton
            // (el mismo motivo por el que existen `btPair` y compania).
            ask: { kind: root.askKind, code: root.askCode, text: root.askText },
            // La ficha abierta es de cada pantalla: `status().screens[].sel`.
            devices: devs
        };
    }
}
