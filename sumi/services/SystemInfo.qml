pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

/**
 * Los datos de la columna del fetch de la pantalla de bloqueo, SIN fastfetch
 * (decisión del usuario, docs/lock/ENTREVISTA.md pregunta 11; SERVICIOS.md §3).
 *
 * PEREZOSO: nada se lee hasta que alguien llama a `load()` (el lock al bloquear, la
 * vista previa al arrancar). Y casi todo es una vez por proceso: el sistema, el
 * kernel, la CPU o la GPU no cambian mientras el shell vive. Sólo la memoria se
 * vuelve a leer, con `refreshMemory()`, al bloquear y con cada minuto del reloj.
 *
 * Procesos, dos y una vez cada uno, por argv (SECURITY.md regla 3):
 *   · `hyprctl -j version`, para la versión del WM (opcional: `wmVersion`);
 *   · `lspci -mm -nn -d <vendor>:<device>` para el nombre de la GPU. Medido en S7
 *     (INVESTIGACION §9): leer `pci.ids` desde QML tardaba 3 ms pero dejaba un pico
 *     de +7,8 MB de RSS que tardaba ~30 s en bajar; `lspci` cuesta 8–19 ms y nada
 *     al shell. Lo eligió el usuario.
 *
 * Un campo que no se puede leer se queda VACÍO y su fila no se dibuja: nunca
 * «unknown».
 */
Singleton {
    id: root

    /**
     * Mostrar «Hyprland 0.56.2» (un proceso) o «Hyprland» a secas. Decidido por el
     * usuario en L2: a secas, sin proceso.
     */
    property bool wmVersion: false

    property bool started: false

    property string os: ""
    property string kernel: ""
    property string wm: ""
    property string shell: ""
    property string cpu: ""
    property string gpu: ""
    property string userName: ""
    property string userLogin: ""
    /** Bytes. */
    property real memTotal: 0
    property real memAvailable: 0
    /** «12.4 / 31.3 GiB»: en uso sobre total, como fastfetch. */
    readonly property string memory: root.memTotal > 0
        ? (((root.memTotal - root.memAvailable) / 1073741824).toFixed(1) + " / "
           + (root.memTotal / 1073741824).toFixed(1) + " GiB")
        : ""

    function load() {
        if (root.started)
            return;
        root.started = true;
        root.userLogin = Quickshell.env("USER") || "";
        root.readOs();
        root.readKernel();
        root.readCpu();
        root.readPasswd();
        root.refreshMemory();
        root.wm = "Hyprland";
        if (root.wmVersion)
            hyprVersion.running = true;
        root.findGpu();
    }

    /** Lecturas de memoria hechas: la primera usa la carga inicial, sin `reload()`. */
    property int memReads: 0

    function refreshMemory() {
        // Un `reload()` sobre la carga inicial todavía en curso la deja caer y
        // Quickshell avisa («got operation finished from dropped operation»).
        if (root.memReads++ > 0)
            meminfo.reload();
        const t = meminfo.text();
        const total = /^MemTotal:\s+(\d+)\s+kB/m.exec(t);
        const avail = /^MemAvailable:\s+(\d+)\s+kB/m.exec(t);
        if (total && avail) {
            root.memTotal = Number(total[1]) * 1024;
            root.memAvailable = Number(avail[1]) * 1024;
        }
    }

    function readOs() {
        const m = /^PRETTY_NAME=("?)(.*)\1\s*$/m.exec(osRelease.text());
        root.os = m ? m[2].trim() : "";
    }

    function readKernel() {
        root.kernel = kernelFile.text().trim();
    }

    /** «AMD Ryzen 7 8700F 8-Core Processor» → «AMD Ryzen 7 8700F». */
    function readCpu() {
        const m = /^model name\s*:\s*(.+)$/m.exec(cpuinfo.text());
        if (!m) {
            root.cpu = "";
            return;
        }
        root.cpu = m[1]
            .replace(/\((R|TM)\)/g, "")
            .replace(/\s+\d+-Core Processor\s*$/i, "")
            .replace(/\s+CPU\s+@.*$/i, "")
            .replace(/\s{2,}/g, " ")
            .trim();
    }

    /** Nombre visible (GECOS, antes de la primera coma) y shell de login. */
    function readPasswd() {
        const login = root.userLogin;
        const lines = passwd.text().split("\n");
        let gecos = "", loginShell = "";
        for (let i = 0; i < lines.length; i++) {
            const f = lines[i].split(":");
            if (f.length >= 7 && f[0] === login) {
                gecos = f[4].split(",")[0].trim();
                loginShell = f[6].trim();
                break;
            }
        }
        root.userName = gecos.length > 0 ? gecos : login;
        const sh = Quickshell.env("SHELL") || loginShell;
        root.shell = sh.length > 0 ? sh.split("/").pop() : "";
    }

    /**
     * La GPU: la primera tarjeta DRM con `vendor` y `device` legibles. Se prueban
     * card0…card3 sin listar el directorio (no hace falta un proceso para eso).
     */
    function findGpu() {
        for (let i = 0; i < 4; i++) {
            const v = root.readSys("/sys/class/drm/card" + i + "/device/vendor");
            const d = root.readSys("/sys/class/drm/card" + i + "/device/device");
            if (/^0x[0-9a-f]{4}$/i.test(v) && /^0x[0-9a-f]{4}$/i.test(d)) {
                lspci.command = ["lspci", "-mm", "-nn", "-d", v.slice(2) + ":" + d.slice(2)];
                lspci.running = true;
                return;
            }
        }
        root.gpu = "";
    }

    /**
     * `03:00.0 "VGA compatible controller [0300]" "Advanced Micro Devices, Inc. [AMD/ATI] [1002]"
     *  "Navi 33 [Radeon RX 7600/7600 XT/7600M XT/7600S/7700S / PRO W7600] [7480]" …`
     * → el tercer campo entre comillas, sin el `[7480]` final → lo que va entre
     * corchetes → la primera alternativa: «Radeon RX 7600».
     */
    function parseLspci(text) {
        const fields = text.match(/"[^"]*"/g);
        if (!fields || fields.length < 3)
            return "";
        const dev = fields[2].slice(1, -1).replace(/\s*\[[0-9a-f]{4}\]\s*$/i, "").trim();
        const br = /\[([^\]]+)\]/.exec(dev);
        return (br ? br[1].split("/")[0] : dev).trim();
    }

    FileView { id: osRelease; path: "/etc/os-release"; blockLoading: true; printErrors: false }
    FileView { id: kernelFile; path: "/proc/sys/kernel/osrelease"; blockLoading: true; printErrors: false }
    FileView { id: cpuinfo; path: "/proc/cpuinfo"; blockLoading: true; printErrors: false }
    FileView { id: passwd; path: "/etc/passwd"; blockLoading: true; printErrors: false }
    /** `blockAllReads`: sin él, `reload()` es asíncrono y `text()` sirve lo anterior (README). */
    FileView { id: meminfo; path: "/proc/meminfo"; blockLoading: true; blockAllReads: true; printErrors: false }

    /**
     * Un solo lector para los archivos pequeños de sysfs, con lecturas bloqueantes:
     * se le cambia la ruta y se lee en el acto. (Un `FileView` por archivo leído
     * desde un enlace mientras se construía dejaba «got operation finished from
     * dropped operation» en el log, medido en L2.)
     */
    FileView { id: sysFile; blockLoading: true; blockAllReads: true; printErrors: false }

    function readSys(path) {
        sysFile.path = path;
        return sysFile.text().trim();
    }

    Process {
        id: hyprVersion
        command: ["hyprctl", "-j", "version"]
        stdout: StdioCollector { id: hyprOut }
        onExited: function (code) {
            if (code !== 0)
                return;
            try {
                const v = JSON.parse(hyprOut.text);
                const tag = String(v.version || v.tag || "").replace(/^v/, "").split("-")[0];
                if (tag.length > 0)
                    root.wm = "Hyprland " + tag;
            } catch (e) {
                // sin versión: se queda «Hyprland»
            }
        }
    }

    Process {
        id: lspci
        stdout: StdioCollector { id: lspciOut }
        onExited: function (code) {
            root.gpu = code === 0 ? root.parseLspci(lspciOut.text) : "";
        }
    }
}
