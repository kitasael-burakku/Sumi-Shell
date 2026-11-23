pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Networking

/**
 * Red (Fase 9.f.1): lo que Waybar tenia en el modulo `network`, como lectura.
 *
 * TODO POR BINDING, NUNCA LEIDO Y GUARDADO. Medido el 2026-09-08 con una sonda
 * a 50 ms: en `Component.onCompleted` (t=0) `Networking.devices` esta vacio y
 * `wifiEnabled` vale **false**; todo se puebla a **t = 55 ms**. Un indicador
 * que lea `wifiEnabled` literal dice "wifi apagado" durante esos 55 ms, y es
 * mentira. De ahi `settled`: hasta que no ha pasado el margen, "no hay datos"
 * no es lo mismo que "no hay hardware", y el island no dibuja nada.
 *
 * NO ENCIENDE EL ESCANER. `WifiDevice.scannerEnabled` se queda apagado: con el
 * apagado el modelo trae 3 redes (las conocidas o activas), que es cuanto hace
 * falta para el indicador. Encenderlo es cosa de la superficie de 9.f.2, que
 * ademas es quien lo apaga al cerrarse.
 *
 * `Quickshell.Networking` cubre tambien la accion (`connect`, `connectWithPsk`,
 * `connectionFailed`), asi que aqui no hay ni un proceso. El unico dato del
 * modulo original sin fuente nativa es `{ipaddr}`: `NetworkDevice.address` es
 * el MAC. Queda para 9.f.2 (MIGRATION.md, mapa de cobertura de 9.f).
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

    readonly property bool hasData: Networking.devices.values.length > 0
    /**
     * Portabilidad F2d (H-17): `settled` evita mentir, pero no explica. Sin NetworkManager en el bus
     * (iwd solo, systemd-networkd…), las vistas de red lo dicen en vez de «No Wi-Fi adapter».
     */
    readonly property string unavailableWhy: Capabilities.whyFirst(["network.manager"])
    /** Hay algo que decir: o llegaron los datos, o ya se espero de sobra. */
    readonly property bool ready: root.hasData || root.settled

    // ---- dispositivos ------------------------------------------------------

    readonly property var wifiDev: {
        const ds = Networking.devices.values;
        for (let i = 0; i < ds.length; i++)
            if (ds[i].type === DeviceType.Wifi) return ds[i];
        return null;
    }

    readonly property var wiredDev: {
        const ds = Networking.devices.values;
        for (let i = 0; i < ds.length; i++)
            if (ds[i].type === DeviceType.Wired) return ds[i];
        return null;
    }

    /** La red wifi en uso, si la hay. */
    readonly property var wifiNet: {
        if (!root.wifiDev) return null;
        const ns = root.wifiDev.networks.values;
        for (let i = 0; i < ns.length; i++)
            if (ns[i].connected) return ns[i];
        return null;
    }

    // ---- estado plano, para el island y para el IPC ------------------------

    readonly property bool wiredUp: root.wiredDev !== null && root.wiredDev.connected
    readonly property bool wifiUp: root.wifiNet !== null

    /** Quien lleva el trafico: "wired" | "wifi" | "none". El cable manda. */
    readonly property string kind: root.wiredUp ? "wired" : (root.wifiUp ? "wifi" : "none")
    readonly property bool connected: root.kind !== "none"

    readonly property string ssid: root.wifiNet ? root.wifiNet.name : ""
    readonly property string ifname: root.kind === "wired"
        ? (root.wiredDev ? root.wiredDev.name : "")
        : (root.wifiDev ? root.wifiDev.name : "")

    /** 0-100. `signalStrength` viene 0-1 (medido: 0,98 con la red conectada). */
    readonly property int signal: root.wifiNet
        ? Math.round(root.wifiNet.signalStrength * 100) : 0

    /** Mbit/s del cable, dato que el modulo de Waybar no daba. */
    readonly property int linkSpeed: (root.wiredDev && root.wiredDev.linkSpeed !== undefined)
        ? root.wiredDev.linkSpeed : 0

    // ---- el cable, para su ficha (QS-FUNC-015) -----------------------------

    /**
     * Lo que `WiredDevice` expone de verdad en 0.3.1, comprobado en el
     * `.qmltypes` instalado: `network`, `linkSpeed` y `hasLink` propios, mas lo
     * heredado de `NetworkDevice` -- `name`, `address` (MAC), `connected`,
     * `state`, y `autoconnect`/`nmManaged`, que **se escriben**.
     *
     * Antes de la ficha, de aqui solo se leian `kind`, `linkSpeed` y el glifo:
     * el shell sabia que ibas por cable y no tenia donde contartelo.
     */
    readonly property var wiredNet: root.wiredDev ? root.wiredDev.network : null
    readonly property string wiredName: root.wiredDev ? root.wiredDev.name : ""
    readonly property string wiredMac: root.wiredDev ? root.wiredDev.address : ""
    readonly property string wiredState: root.wiredDev
        ? ConnectionState.toString(root.wiredDev.state) : ""
    /** El cable esta fisicamente enchufado, aunque no haya conexion levantada. */
    readonly property bool wiredLink: (root.wiredDev && root.wiredDev.hasLink !== undefined)
        ? root.wiredDev.hasLink : false
    readonly property bool wiredAutoconnect: (root.wiredDev && root.wiredDev.autoconnect !== undefined)
        ? root.wiredDev.autoconnect : false
    readonly property bool wiredManaged: (root.wiredDev && root.wiredDev.nmManaged !== undefined)
        ? root.wiredDev.nmManaged : false

    readonly property bool wifiEnabled: Networking.wifiEnabled
    readonly property bool wifiHardware: Networking.wifiHardwareEnabled

    readonly property string connectivity:
        NetworkConnectivity.toString(Networking.connectivity)

    /**
     * Conectado pero sin salida de verdad: portal cautivo o conectividad
     * limitada. Waybar no sabia distinguirlo -- solo tenia "conectado" o "no".
     * `Unknown` no cuenta: es lo que devuelve NM cuando la comprobacion esta
     * apagada, y ahi callarse es lo honesto.
     */
    readonly property bool degraded: root.connected
        && (Networking.connectivity === NetworkConnectivity.Portal
            || Networking.connectivity === NetworkConnectivity.Limited
            || Networking.connectivity === NetworkConnectivity.None)

    // ---- glifo -------------------------------------------------------------

    /**
     * La escalera de senal. Los cuatro codepoints de `wifi-1..4` se
     * comprobaron contra JetBrainsMono Nerd Font antes de usarse, igual que
     * el resto de `components/Icon.qml`.
     */
    readonly property string icon: {
        if (!root.ready) return "";
        if (root.kind === "wired") return "ethernet";
        if (root.degraded) return "wifi-alert";
        if (root.kind === "wifi") {
            const q = root.wifiNet.signalStrength;
            if (q >= 0.75) return "wifi-4";
            if (q >= 0.50) return "wifi-3";
            if (q >= 0.25) return "wifi-2";
            return "wifi-1";
        }
        if (!root.wifiHardware && !root.wiredDev) return "net-off";
        if (!root.wifiEnabled) return "wifi-off";
        return "wifi-none";
    }

    /** Lo que se pinta al lado del glifo en la cara hover. */
    readonly property string badge: {
        if (!root.ready) return "";
        if (root.kind === "wired") return "LAN";
        if (root.kind === "wifi") return root.signal + "%";
        if (!root.wifiHardware && !root.wiredDev) return "";
        return "--";
    }

    // ---- escaneo, con puerta de observadores (9.f.2) ------------------------

    /**
     * `WifiDevice.scannerEnabled` es lo unico caro de todo esto: mantiene la
     * radio escaneando. Aqui la puerta SI ahorra algo real (a diferencia de la
     * del mezclador, 9.e): con la superficie cerrada el escaner esta apagado y
     * el modelo se queda con las 3 redes conocidas o activas, que es cuanto
     * necesita el indicador.
     *
     * Medido el 2026-09-08: al encenderlo la lista salta a 19 redes al
     * instante (cache caliente de NetworkManager) y se asienta en 17 a los
     * 6,7 s, cuando termina el escaneo real. Es el mismo patron que
     * `rofi/scripts/wifi.sh` implemento a mano -- lista inmediata del cache y
     * rescan de fondo -- pero sin el `nohup`.
     */
    /**
     * RECLAMACIONES, NO UN CONTADOR. Antes esto era `scanWatchers++/--` y se
     * desbalanceo: al saltar de la lista a la ficha, con la descarga perezosa
     * de por medio, salian mas `release` que `acquire` y el contador acababa en
     * 0 **con la ficha abierta** -- el modelo se quedaba con 2 redes y la ficha
     * ya no encontraba la suya (medido el 2026-09-09).
     *
     * Una reclamacion con nombre es **idempotente**: da igual cuantas veces se
     * declare, y una superficie que se destruye sin avisar no puede dejar el
     * contador torcido. Cada superficie dice lo que necesita y punto.
     */
    property var scanClaims: ({})

    function claimScan(who, on) {
        if (on === !!root.scanClaims[who]) return;   // ya estaba asi
        // OJO: hay que construir un objeto NUEVO. Reasignar el mismo no
        // dispara la senal de cambio -- QML compara `var` por referencia -- y
        // `scanWanted` se quedaba sin reevaluar, asi que el escaner nunca se
        // encendia aunque la superficie lo pidiera.
        const c = Object.assign({}, root.scanClaims);
        if (on) c[who] = true; else delete c[who];
        root.scanClaims = c;
        if (root.scanWanted) offGrace.stop();
        else offGrace.restart();
        root.applyScan();
    }

    readonly property bool scanWanted: Object.keys(root.scanClaims).length > 0
    /** Compatibilidad con `status()`, que ya publicaba un numero. */
    readonly property int scanWatchers: Object.keys(root.scanClaims).length

    /**
     * Al soltar, el escaner se apaga **con retardo**: al saltar de la lista a
     * la ficha hay un instante en que ninguna de las dos reclama, y sin margen
     * NetworkManager tiraria la lista justo en el relevo.
     */
    Timer {
        id: offGrace
        interval: 2000
        repeat: false
        onTriggered: root.applyScan()
    }

    /**
     * Sin nadie delante no se escanea aunque la superficie siga abierta
     * (QS-FUNC-018): mantener la radio buscando es lo que cuesta.
     */
    readonly property bool scanning: (root.scanWanted || offGrace.running)
        && Networking.wifiEnabled && !Session.idle

    function applyScan() {
        if (!root.wifiDev) return;
        root.wifiDev.scannerEnabled =
            (root.scanWanted || offGrace.running) && Networking.wifiEnabled && !Session.idle;
    }

    Connections {
        target: Session
        function onIdleChanged() { root.applyScan(); }
    }

    /** El dispositivo llega tarde (55 ms): al aparecer hay que re-aplicar. */
    onWifiDevChanged: root.applyScan()

    // ---- la lista, ya ordenada ---------------------------------------------

    /**
     * `Networking` entrega las redes **ya deduplicadas por SSID y sin las
     * ocultas** (medido: 17 entradas contra 19 BSSID / 15 SSID unicos de
     * `nmcli`), asi que las reglas R5 y R6 de `wifi.sh` no hay que reescribirlas.
     * Aqui solo queda el orden, que es R9: la conectada primero y el resto por
     * senal descendente.
     */
    readonly property var networks: {
        if (!root.wifiDev) return [];
        const xs = root.wifiDev.networks.values.slice();
        xs.sort((a, b) => {
            if (a.connected !== b.connected) return a.connected ? -1 : 1;
            return b.signalStrength - a.signalStrength;
        });
        return xs;
    }

    function netAt(i) {
        return (i >= 0 && i < root.networks.length) ? root.networks[i] : null;
    }

    function indexOfSsid(ssid) {
        for (let i = 0; i < root.networks.length; i++)
            if (root.networks[i].name === ssid) return i;
        return -1;
    }

    /**
     * La red por su ssid. Desde el 2026-09-22 es el camino normal de la ficha:
     * la seleccion vive en cada pantalla (core/SurfaceHost §`sel`) y el
     * servicio solo sabe responder por clave.
     */
    function netByName(ssid) {
        const i = root.indexOfSsid(ssid);
        return i < 0 ? null : root.networks[i];
    }

    function knowsSsid(ssid) { return root.indexOfSsid(ssid) >= 0; }

    /** `Open` y `Owe` no piden clave; el resto si. */
    function needsKey(net) {
        if (!net || net.security === undefined) return false;
        return net.security !== WifiSecurityType.Open
            && net.security !== WifiSecurityType.Owe;
    }

    /**
     * Redes a las que se les puede dar una PSK. La documentacion de Quickshell
     * es explicita: `connectWithPsk()` solo debe usarse cuando `security` es
     * **WpaPsk, Wpa2Psk o Sae**. Las demas que piden credenciales (los EAP
     * empresariales, LEAP, y los WEP) necesitan un perfil completo, no una
     * clave suelta -- ofrecerles un campo de contrasena seria mentirle al
     * usuario con un camino que no puede funcionar.
     */
    function pskCapable(net) {
        if (!net || net.security === undefined) return false;
        return net.security === WifiSecurityType.WpaPsk
            || net.security === WifiSecurityType.Wpa2Psk
            || net.security === WifiSecurityType.Sae;
    }

    /** Pide credenciales pero NO por PSK: aqui el shell no llega (ADR-18). */
    function enterprise(net) {
        return root.needsKey(net) && !root.pskCapable(net);
    }

    function secLabel(net) {
        return (net && net.security !== undefined)
            ? WifiSecurityType.toString(net.security) : "";
    }

    // ---- conectar ----------------------------------------------------------

    /**
     * Estado del intento en curso. `lastFail` y no `error`: `error` esta
     * **reservado** dentro de un `Singleton` de Quickshell (tropiezo ya pagado,
     * README).
     */
    /**
     * MAQUINA DE ESTADO DE LA CONEXION (auditoria del 2026-09-09).
     *
     * La version anterior tenia **dos salidas y ninguna de exito**: la senal
     * `connectionFailed` y el temporizador. Si la conexion iba bien, nadie
     * limpiaba `pendingSsid`, asi que la UI se quedaba en "conectando" y a los
     * 30 s saltaba **"Timed out" con la red ya conectada**. Reproducido
     * llamando a `connect()` sobre la red que ya estaba conectada:
     * `conectada=True` durante todo el intento, `busy` 30 s, y despues el
     * falso timeout. No era la duracion del plazo: **faltaba la transicion**.
     *
     * Ahora hay una fase explicita y una funcion, `reconcile()`, que es la
     * unica autoridad: siempre que llega un evento -- del backend, del reloj o
     * del modelo -- se vuelve a mirar la realidad. Si la red observada esta
     * conectada, la fase es `ok`, venga de donde venga, **incluso despues de
     * un timeout**. Asi un error viejo no puede sobrevivir a una conexion
     * valida, que era el otro sintoma.
     */
    readonly property string phaseIdle: "idle"
    property string phase: "idle"     // idle | connecting | ok | failed | timeout
    property string phaseSsid: ""
    property int failCode: -1

    /** La red que se esta observando, por nombre. Sobrevive a que el modelo la reordene. */
    readonly property var watchNet: root.phaseSsid.length > 0
        ? root.netAt(root.indexOfSsid(root.phaseSsid)) : null

    readonly property bool busy: root.phase === "connecting"

    /** Compatibilidad con lo que ya leen el IPC y las superficies. */
    readonly property string pendingSsid: root.busy ? root.phaseSsid : ""
    readonly property string lastFailSsid: (root.phase === "failed" || root.phase === "timeout")
        ? root.phaseSsid : ""
    readonly property string lastFail: {
        if (root.phase === "timeout") return "Timed out";
        if (root.phase !== "failed") return "";
        if (root.failNote.length > 0) return root.failNote;
        return root.failCode >= 0 ? ConnectionFailReason.toString(root.failCode) : "";
    }
    /** Un fallo que no viene del backend (6C-2): la radio se apagó a mitad. */
    property string failNote: ""
    readonly property int lastFailCode: root.phase === "failed" ? root.failCode : -1

    property var boundNet: null

    /**
     * La unica autoridad sobre la fase. Se la llama desde todos los eventos.
     * `force` sirve para las transiciones que si tienen que imponerse (fallo
     * declarado por el backend, o el plazo cumplido).
     */
    function reconcile(force) {
        if (root.phase === "idle") return;
        const n = root.watchNet;
        // La realidad manda: si esta conectada, esta conectada.
        if (n && n.connected) {
            root.phase = "ok";
            root.failCode = -1;
            watchdog.stop();
            return;
        }
        /**
         * DESCONEXIÓN A MITAD (6C-2). Con la radio apagada mientras conectaba, el
         * backend no declaraba nada y la fase seguía en «connecting» hasta el plazo
         * de 25 s. Ahora es un fallo en cuanto se ve.
         */
        if (root.phase === "connecting" && !Networking.wifiEnabled) {
            root.phase = "failed";
            root.failNote = "Wi-Fi was turned off";
            watchdog.stop();
            return;
        }
        if (force === "failed" || force === "timeout") {
            root.phase = force;
            watchdog.stop();
        }
    }

    Connections {
        target: Networking
        function onWifiEnabledChanged() { root.reconcile(); }
    }

    /** El backend declara un fallo. */
    function onFail(reason) {
        root.failCode = reason;
        root.reconcile("failed");
    }

    /**
     * El plazo. **No cierra el caso**: si la red acaba conectando despues,
     * `reconcile()` lo vera y la fase pasara a `ok`. Por eso el observador
     * sigue enganchado aunque la fase sea `timeout`.
     */
    Timer {
        id: watchdog
        interval: 25000
        repeat: false
        onTriggered: root.reconcile("timeout")
    }

    /**
     * Un `onXxx` dentro de `Connections` se lee como senal del *target*, que
     * aqui es justo lo que se quiere: `connectedChanged` y `stateChanged` de la
     * red observada.
     */
    Connections {
        target: root.watchNet
        ignoreUnknownSignals: true
        function onConnectedChanged() { root.reconcile(); }
        function onStateChanged() { root.reconcile(); }
    }

    /** La fase cierra la operación del intento (6D). */
    onPhaseChanged: {
        if (root.connectOpId.length === 0 || root.phase === "connecting") return;
        if (root.phase === "ok") Operations.end(root.connectOpId, "succeeded", "");
        else if (root.phase === "failed") Operations.end(root.connectOpId, "failed", root.lastFail);
        else if (root.phase === "timeout") Operations.end(root.connectOpId, "unknown", "Timed out");
        else Operations.end(root.connectOpId, "cancelled", "");
        root.connectOpId = "";
    }

    /** Tambien cuando cambia quien esta conectado por cualquier otra via. */
    onSsidChanged: root.reconcile()
    onWatchNetChanged: root.reconcile()

    function unbind() {
        if (root.boundNet) {
            try { root.boundNet.connectionFailed.disconnect(root.onFail); } catch (e) {}
            root.boundNet = null;
        }
    }

    function clearPending() {
        root.unbind();
        watchdog.stop();
        root.phase = "idle";
        root.phaseSsid = "";
        root.failCode = -1;
        root.failNote = "";
        // Una conexión en vuelo que se abandona no terminó bien.
        if (root.ops.pending("connect"))
            root.ops.resolve("connect", root.ops.latest("connect"), "error", "Cancelled");
    }

    /**
     * 6D: el intento es también una operación global (`Operations`, tipo "wifi",
     * recurso "wifi-connect", control la ficha de esa red) con el plazo del
     * `watchdog` como plazo ABSOLUTO: trasladar su ficha a otra pantalla no lo
     * reinicia. Conectar a otra red la sustituye, como aquí (gana lo último).
     */
    property string connectOpId: ""

    function beginConnect(net, owner) {
        root.connectOpId = Operations.begin("wifi", "wifi-connect", "wifiDetail", net.name, owner || "",
            { state: "running", replace: true, deadline: Date.now() + watchdog.interval }).id;
        root.unbind();
        root.phase = "connecting";
        root.phaseSsid = net.name;
        root.failCode = -1;
        root.failNote = "";
        root.expectConnect(net.name);
        root.boundNet = net;
        net.connectionFailed.connect(root.onFail);
        watchdog.restart();
        // Si ya estaba conectada, no hay nada que esperar.
        root.reconcile();
    }

    // ---- lo pedido frente a lo efectivo (fase 6C-2) ---------------------------

    /**
     * Las acciones de red como peticiones con revisión (`services/Ops`), igual que
     * el perfil y el mezclador de la 6C-1. La fase de conexión de arriba sigue
     * siendo la autoridad para las superficies; `ops` la refleja por petición:
     *   connect          ok cuando la red pedida está conectada y lo SOSTIENE 600 ms;
     *                    error si el backend falla o la radio se apaga; a los 25 s,
     *                    unknown (y una conexión tardía aún la pasa a ok). Una sola
     *                    clave: conectar a otra red sustituye a la anterior.
     *   disconnect       ok cuando la red ya no es la conectada.
     *   radio, wiredAuto `autoconnect` se escribe de forma OPTIMISTA y sin eco (medido el
     *                    2026-09-25; la radio no se midió, se trata igual): se comprueban
     *                    con `nmcli` 400 ms después.
     *   wired            el cable arriba o abajo, por el estado del dispositivo.
     *   forget:<ssid>    la red deja de estar guardada.
     */
    readonly property Ops ops: Ops { name: "net" }

    function expectConnect(ssid) {
        const r = root.ops.request("connect", ssid);
        root.ops.expect("connect", r, {
            timeout: 25000, timeoutState: "unknown", timeoutReason: "Timed out",
            check: function () {
                if (root.phaseSsid === ssid && root.phase === "failed")
                    return { fail: root.lastFail || "Connection failed", effective: root.ssid };
                const n = root.netByName(ssid);
                return { met: !!(n && n.connected), effective: root.ssid };
            }
        });
        return r;
    }

    function connectTo(ssid, owner) {
        const i = root.indexOfSsid(ssid);
        if (i < 0) { console.warn("Net.connectTo: no such network", ssid); return false; }
        const net = root.networks[i];
        root.beginConnect(net, owner);
        net.connect();
        return true;
    }

    /**
     * Conectar con contrasena. **La clave no pasa por argv en ningun momento**:
     * viaja por D-Bus dentro del proceso. `rofi/scripts/wifi.sh` no podia
     * evitarlo y su autor lo dejo escrito como riesgo aceptado en sus lineas
     * 96-102 (`nmcli ... password "$pass"` queda visible en `ps` para otros
     * procesos del mismo usuario). Aqui ese riesgo no existe -- y por eso
     * **no hay verbo IPC que acepte la clave**: reintroducirlo por la puerta de
     * atras seria deshacer justo lo que se gana.
     */
    function connectWithKey(ssid, psk, owner) {
        const i = root.indexOfSsid(ssid);
        if (i < 0) { console.warn("Net.connectWithKey: no such network", ssid); return false; }
        const net = root.networks[i];
        root.beginConnect(net, owner);
        net.connectWithPsk(psk);
        return true;
    }

    function disconnectCurrent() {
        if (!root.wifiNet) return false;
        root.clearPending();
        const was = root.ssid;
        const r = root.ops.request("disconnect", was);
        root.ops.expect("disconnect", r, {
            timeout: 10000, timeoutReason: "Still connected",
            check: () => ({ met: !root.wifiUp || root.ssid !== was, effective: root.ssid })
        });
        root.wifiNet.disconnect();
        return true;
    }

    /**
     * DESCONECTAR EL CABLE. `autoconnect` se apaga **antes**: con el encendido
     * NetworkManager vuelve a levantar el perfil al instante y la accion parece
     * no hacer nada. Es la unica de todo el servicio que puede dejar la maquina
     * sin salida, asi que la ficha la pide con confirmacion.
     *
     * Se prefiere `Network.disconnect()`, el mismo camino que usa el wifi, y se
     * cae a `NetworkDevice.requestDisconnect()` si el backend no publica la
     * `Network` del dispositivo.
     */
    function wiredDisconnect() {
        if (!root.wiredDev) return false;
        root.expectWired(false);
        root.wiredDev.autoconnect = false;
        const n = root.wiredNet;
        if (n && typeof n.disconnect === "function") n.disconnect();
        else root.wiredDev.requestDisconnect(false);
        return true;
    }

    /** Volver a levantarlo: con `autoconnect` basta, NM hace el resto. */
    function wiredConnect() {
        if (!root.wiredDev) return false;
        root.expectWired(true);
        root.wiredDev.autoconnect = true;
        const n = root.wiredNet;
        if (n && typeof n.connect === "function") n.connect();
        return true;
    }

    /** El cable arriba o abajo: lo dice el estado del dispositivo, que viene de NM. */
    function expectWired(up) {
        const r = root.ops.request("wired", up ? "up" : "down");
        const t0 = Date.now();
        let retried = false;
        root.ops.expect("wired", r, {
            timeout: up ? 20000 : 15000,
            timeoutReason: up ? "The cable did not come up" : "Still connected",
            check: function () {
                if (!root.wiredDev) return { fail: "The device went away" };
                if (up && !root.wiredLink) return { fail: "No cable plugged in", effective: "down" };
                const c = root.wiredDev.connected;
                /**
                 * GANA LO ÚLTIMO, también contra NM. Medido el 2026-09-25: bajar y
                 * subir seguidos dejó el cable ABAJO (la desconexión se aplicó después
                 * de la conexión) y la petición «up» acabó en error a los 20 s. Si pasado
                 * un momento el dispositivo está quieto en lo contrario de lo pedido, se
                 * repite la orden UNA vez.
                 */
                const st = root.wiredDev.state;
                const still = up ? st === ConnectionState.Disconnected : st === ConnectionState.Connected;
                if (!retried && still && Date.now() - t0 > 1500) {
                    retried = true;
                    console.log("net: wired " + (up ? "up" : "down") + " not applied, retrying once");
                    root.wiredDev.autoconnect = up;
                    const n = root.wiredNet;
                    if (up) { if (n && typeof n.connect === "function") n.connect(); }
                    else if (n && typeof n.disconnect === "function") n.disconnect();
                    else root.wiredDev.requestDisconnect(false);
                }
                return { met: c === up, effective: c ? "up" : "down" };
            }
        });
        return r;
    }

    function setWiredAutoconnect(on) {
        if (!root.wiredDev) return false;
        const want = !!on, iface = root.wiredName;
        const r = root.ops.request("wiredAuto", want);
        root.wiredDev.autoconnect = want;
        root.ops.verifyLater("wiredAuto", r, 400,
            ["timeout", "3", "nmcli", "-g", "GENERAL.AUTOCONNECT", "device", "show", iface],
            function (text, code) {
                if (code !== 0) return ["error", "NetworkManager is not answering"];
                const got = text.trim() === "yes";
                return got === want ? ["ok", "", got]
                                    : ["error", "NetworkManager kept autoconnect " + (got ? "on" : "off"), got];
            });
        return true;
    }

    /** R3 de `wifi.sh`: la radio apagada se enciende antes de listar. */
    function setRadio(on) {
        const want = !!on;
        const r = root.ops.request("radio", want);
        Networking.wifiEnabled = want;
        root.ops.verifyLater("radio", r, 400, ["timeout", "3", "nmcli", "radio", "wifi"],
            function (text, code) {
                if (code !== 0) return ["error", "NetworkManager is not answering"];
                const got = text.trim() === "enabled";
                if (got === want) return ["ok", "", got];
                return ["error", want && !root.wifiHardware ? "Blocked by the hardware switch"
                                                           : "NetworkManager kept the radio " + (got ? "on" : "off"), got];
            });
        return true;
    }

    /**
     * OLVIDAR UNA RED. Esto **si** existe, al reves de lo que llegue a escribir
     * el 2026-09-09: `Network.forget()` esta en el binario instalado y
     * comprobado en vivo (`typeof n.forget === "function"`). Lo que fallo fue
     * mi volcado del `.qmltypes` con una expresion regular fragil, no la API.
     * La documentacion oficial lo listaba desde el principio.
     *
     * Es DESTRUCTIVO: borra todos los perfiles de esa red, asi que quien lo
     * llame tiene que haberlo pedido explicitamente.
     */
    function forgetNetwork(ssid) {
        const i = root.indexOfSsid(ssid);
        if (i < 0) { console.warn("Net.forgetNetwork: no such network", ssid); return false; }
        const net = root.networks[i];
        if (!net.known) { console.warn("Net.forgetNetwork:", ssid, "was not saved"); return false; }
        root.clearPending();
        const r = root.ops.request("forget:" + ssid, ssid);
        root.ops.expect("forget:" + ssid, r, {
            hold: 0, timeout: 5000, timeoutReason: "Still saved",
            check: function () { const n = root.netByName(ssid); return { met: !n || !n.known }; }
        });
        net.forget();
        return true;
    }

    /**
     * Tirar las claves guardadas sin borrar el perfil. Resuelve un caso real
     * que si no deja al usuario atascado: si NetworkManager guardo una clave
     * equivocada, `connect()` seguira fallando con `NoSecrets` una y otra vez.
     * Vaciando los secretos, el siguiente intento vuelve a pedir contrasena.
     *
     * `NMSettings` no figura como tipo exportado en el `.qmltypes` de 0.3.1,
     * pero los objetos que llegan por `network.nmSettings` **si** responden a
     * `uuid`, `id`, `read()`, `write()`, `clearSecrets()` y `forget()`
     * (comprobado en vivo el 2026-09-09).
     */
    function clearSecrets(ssid) {
        const i = root.indexOfSsid(ssid);
        if (i < 0) return false;
        const st = root.networks[i].nmSettings;
        if (!st || st.length === 0) return false;
        for (let k = 0; k < st.length; k++) st[k].clearSecrets();
        return true;
    }

    /**
     * Portal cautivo. La documentacion pide llamar a esto **despues** de que el
     * usuario cierre el navegador donde se autentico; si no, `connectivity` se
     * queda diciendo `Portal` aunque ya haya salida.
     */
    function recheckConnectivity() {
        if (!Networking.canCheckConnectivity) return false;
        Networking.checkConnectivity();
        return true;
    }


    // ---- ficha de una red (9.f.2b) -----------------------------------------

    /**
     * La ficha sostiene **el objeto**, no solo el nombre. Si se guardara el
     * SSID y se buscara en la lista, bastaria con que el escaneo podara esa
     * entrada para que la ficha se quedara en blanco con el usuario mirandola
     * -- exactamente lo que pasaba. El objeto sigue vivo y notificando aunque
     * salga del modelo.
     */
    /**
     * **Ya no hay «la ficha» aqui** (2026-09-22): la seleccion bajo a cada
     * pantalla (`core/SurfaceHost` §`sel`) y el objeto lo sostiene la propia
     * ficha, por el motivo de arriba. Este servicio responde por clave
     * (`netByName`, `profileOf`, `bssidOf`, …) y lleva las operaciones en
     * vuelo, que si son unicas y van keyed por ssid (`phaseSsid`).
     */

    /**
     * Lo que el perfil guardado sabe de la red. Sale de `NMSettings.read()`,
     * que devuelve el mapa de NetworkManager tal cual: `802-11-wireless`,
     * `802-11-wireless-security`, `connection`, `ipv4`, `ipv6`, `proxy`.
     *
     * OJO CON LO QUE NO TRAE. Se midio el 2026-09-09 sobre la red conectada:
     * `ipv4.method` vale `"auto"` y `ipv4.addresses` esta **vacio**. Es logico
     * -- el perfil describe la *configuracion* (DHCP), no la direccion que el
     * servidor acabo dando. Asi que **la IP no esta aqui**, y tampoco la banda
     * ni el canal. Lo que si trae, y es util: el BSSID visto del punto de
     * acceso, el `key-mgmt` real y la marca de tiempo del ultimo uso.
     */
    function profileOf(ssid) {
        const i = root.indexOfSsid(ssid);
        if (i < 0) return null;
        const st = root.networks[i].nmSettings;
        if (!st || st.length === 0) return null;
        try { return st[0].read(); } catch (e) { return null; }
    }

    /**
     * `nmSettings` llega tarde, como todo en Quickshell: al abrir la ficha el
     * perfil puede no estar todavia y `read()` devuelve null, dejando AP,
     * cifrado y ultimo uso en blanco aunque la red si este guardada. Como
     * `read()` es una **llamada** y no una property, el binding no se entera
     * solo -- de ahi el contador, que es la dependencia explicita.
     */
    property int profileRev: 0

    /**
     * Cada ficha pregunta por SU ssid (2026-09-22): antes esto eran propiedades
     * derivadas de una unica `detailNet`, y con dos pantallas las dos fichas
     * leian el perfil de la misma red. `profileRev` sigue siendo la dependencia
     * explicita porque `read()` es una llamada, no una property.
     */
    function bssidOf(ssid) {
        void root.profileRev;
        const p = root.profileOf(ssid);
        if (!p || !p["802-11-wireless"]) return "";
        const b = p["802-11-wireless"]["seen-bssids"];
        return (b && b.length > 0) ? b[0] : "";
    }

    function keyMgmtOf(ssid) {
        void root.profileRev;
        const p = root.profileOf(ssid);
        if (!p || !p["802-11-wireless-security"]) return "";
        return p["802-11-wireless-security"]["key-mgmt"] || "";
    }

    /** Segundos epoch de la ultima conexion, 0 si nunca. */
    function lastUsedOf(ssid) {
        void root.profileRev;
        const p = root.profileOf(ssid);
        if (!p || !p["connection"]) return 0;
        return p["connection"]["timestamp"] || 0;
    }

    /** MAC del adaptador, que si es nativa (`NetworkDevice.address`). */
    readonly property string mac: root.wifiDev ? root.wifiDev.address : ""

    // ---- la IP, unica excepcion al "ni un proceso" -------------------------

    /**
     * LA IP NO TIENE FUENTE NATIVA, y esto se midio antes de decidirlo:
     * `NetworkDevice.address` es el MAC, y `NMSettings.read()` devuelve
     * `ipv4.method = "auto"` con `addresses` vacio. Waybar la sacaba de su
     * `{ipaddr}`; para no perder el dato hace falta preguntarselo al sistema.
     *
     * Por eso este es **el unico proceso de todo 9.f**, y esta acotado a
     * proposito: `ip -j -4 addr show <iface>`, argv (nunca `sh -c`, regla 3 de
     * SECURITY.md), y **solo mientras la ficha de detalle esta abierta**. No
     * hay reloj: se lanza al abrir y cuando cambia la conexion.
     */
    property string ipv4: ""
    /**
     * A QUE INTERFAZ PERTENECE `ipv4`. Sin este campo el JSON mentia por
     * omision: con `kind: "wired"` publicaba una `ipv4` que era la del wifi, y
     * no habia forma de saberlo leyendo la salida (QS-FUNC-015, 2026-09-21).
     */
    property string ipv4Iface: ""

    function clearIp() { root.ipv4 = ""; root.ipv4Iface = ""; }

    /** La interfaz que se pidio, para publicarla solo si la respuesta llega. */
    property string _ipAsked: ""

    Process {
        id: ipProc
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                let addr = "";
                try {
                    const j = JSON.parse(this.text);
                    for (let i = 0; i < j.length; i++) {
                        const ai = j[i].addr_info || [];
                        for (let k = 0; k < ai.length; k++)
                            if (ai[k].family === "inet" && ai[k].local) {
                                addr = ai[k].local + "/" + ai[k].prefixlen;
                                break;
                            }
                    }
                } catch (e) { addr = ""; }
                root.ipv4 = addr;
                root.ipv4Iface = addr.length > 0 ? root._ipAsked : "";
            }
        }
    }

    /**
     * QS-FUNC-015: esto preguntaba **siempre** por `wifiDev.name`. Con cable y
     * wifi conectados a la vez -- que es el caso normal de esta maquina desde el
     * 2026-09-21 -- la IP publicada era la del wifi aunque el trafico fuera por
     * el cable, y ninguna superficie sabia decir la del cable.
     *
     * Ahora la interfaz es el argumento y, sin argumento, se pregunta por **la
     * activa**: `ifname` ya sabe que el cable manda sobre el wifi.
     */
    function refreshIp(iface) {
        const name = (iface !== undefined && iface !== null && iface.length > 0)
            ? iface : root.ifname;
        if (name.length === 0 || !root.connected) { root.clearIp(); return false; }
        root._ipAsked = name;
        ipProc.command = ["ip", "-j", "-4", "addr", "show", name];
        ipProc.running = true;
        return true;
    }

    /**
     * La ficha de una red wifi pregunta por **su** interfaz, no por la activa:
     * dentro de esa tarjeta la IP correcta es la del wifi aunque el trafico vaya
     * por el cable. Y sigue en pie la regla vieja: solo si la ficha abierta es
     * la de la red conectada, porque una IP correcta en la tarjeta de otra red
     * es peor que no tenerla.
     */
    function refreshWifiIp(ssid) {
        if (!root.wifiDev || !root.wifiUp) { root.clearIp(); return false; }
        // Sin ficha en contexto tampoco se publica. La guarda decia
        // `detailSsid.length > 0 && ...`, o sea que con la ficha abierta por IPC
        // sin red elegida caia al camino bueno y pintaba la IP y el MAC de la
        // red conectada en una tarjeta que no era de nadie -- el mismo "dato
        // correcto en el sitio equivocado" que esta guarda existia para evitar.
        // Visto al abrir las 24 superficies seguidas el 2026-09-21.
        // Desde el 2026-09-22 la ficha pasa SU ssid (la seleccion es de cada
        // pantalla). Una ficha que no es la de la red conectada no pide IP y
        // **tampoco la borra**: con dos pantallas, borrar seria pisarle el dato
        // a la otra, que si tiene derecho a verlo.
        const who = (ssid === undefined || ssid === null) ? "" : String(ssid);
        if (who.length === 0 || who !== root.ssid) return false;
        return root.refreshIp(root.wifiDev.name);
    }

    /** La ficha del cable, por lo mismo: su interfaz, no la que mande. */
    function refreshWiredIp() {
        if (!root.wiredDev || !root.wiredDev.connected) { root.clearIp(); return false; }
        return root.refreshIp(root.wiredName);
    }


    onConnectedChanged: root.connected ? root.refreshWifiIp(root.ssid) : root.clearIp()

    // ---- resumen para el IPC ----------------------------------------------

    /**
     * Lo que publica `status().network`. Existe por la misma razon que
     * `Tray.summary()` y `Mixer.summary()`: sin raton, leer el JSON es la
     * unica forma de ejercitar las puertas P1, P2 y P3.
     */
    function summary() {
        const nets = [];
        for (let k = 0; k < root.networks.length; k++) {
            const w = root.networks[k];
            nets.push({ ssid: w.name, signal: Math.round(w.signalStrength * 100),
                        security: root.secLabel(w), needsKey: root.needsKey(w),
                        pskCapable: root.pskCapable(w), enterprise: root.enterprise(w),
                        profiles: w.nmSettings ? w.nmSettings.length : 0,
                        known: w.known, connected: w.connected,
                        state: ConnectionState.toString(w.state),
                        changing: w.stateChanging });
        }
        const devs = [];
        const ds = Networking.devices.values;
        for (let i = 0; i < ds.length; i++) {
            const d = ds[i];
            devs.push({ name: d.name, type: DeviceType.toString(d.type),
                        state: ConnectionState.toString(d.state),
                        connected: d.connected, mac: d.address,
                        networks: d.networks ? d.networks.values.length : 0 });
        }
        return {
            ready: root.ready, settled: root.settled,
            kind: root.kind, connected: root.connected,
            ssid: root.ssid, ifname: root.ifname, signal: root.signal,
            linkSpeed: root.linkSpeed,
            wifiEnabled: root.wifiEnabled, wifiHardware: root.wifiHardware,
            connectivity: root.connectivity, degraded: root.degraded,
            icon: root.icon, badge: root.badge,
            backend: NetworkBackendType.toString(Networking.backend),
            // 9.f.2: la puerta del escaner y el intento en curso. `scanning`
            // tiene que volver a false al cerrar la superficie (puerta P4).
            scanning: root.scanning, scanWatchers: root.scanWatchers,
            // QS-FUNC-003: las claves, para ver que llevan el monitor.
            scanClaims: Object.keys(root.scanClaims),
            visible: root.networks.length,
            phase: root.phase, phaseSsid: root.phaseSsid,
            pending: root.pendingSsid, busy: root.busy,
            // La ficha abierta ya no se pregunta aqui: es de cada pantalla, y
            // sale en `status().screens[].sel`.
            ipv4: root.ipv4, ipv4Iface: root.ipv4Iface, mac: root.mac,
            // QS-FUNC-015: el cable, con lo que su ficha necesita. Sin esto no
            // hay forma de ejercitar la ficha sin raton (puertas P1-P3).
            wired: root.wiredDev ? ({
                present: true, name: root.wiredName, mac: root.wiredMac,
                connected: root.wiredDev.connected, state: root.wiredState,
                hasLink: root.wiredLink, linkSpeed: root.linkSpeed,
                autoconnect: root.wiredAutoconnect, managed: root.wiredManaged,
                hasNetwork: root.wiredNet !== null
            }) : ({ present: false }),
            // 6C-2: `bssid`/`keyMgmt`/`lastUsed` salían de `detail*`, que no existen
            // desde el 2026-09-22 (la ficha es de cada pantalla): eran undefined y
            // JSON.stringify los omitía. Fuera; por red, `bssidOf(ssid)` y compañía.
            ops: root.ops.snapshot(),
            lastFail: root.lastFail, lastFailCode: root.lastFailCode,
            lastFailSsid: root.lastFailSsid,
            list: nets,
            devices: devs
        };
    }
}
