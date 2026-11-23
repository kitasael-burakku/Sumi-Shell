import QtQuick
import Quickshell
import "core"
import "services"
import "lock"

/**
 * Sumi Shell — entry point.
 *
 * One Screen per monitor (Variants over Quickshell.screens). Each Screen owns
 * its own island, its own open surface and its own hold state (ADR-5); the
 * only global objects are the singletons (services/, theme/, core/Screens,
 * core/Hypr) and the IPC handler.
 *
 * Nothing here calls Hyprland.refresh*(): the Quickshell models populate on
 * their own within ~0.5 s and calling refresh before the socket is connected
 * leaves them empty until the next compositor event (ADR-6, BUG-1 in
 * docs/REVERSE_ENGINEERING.md).
 */
ShellRoot {
    id: root

    // Reconciliar el modo al cargar, sin esperar a que se abra Performance.
    readonly property bool modesReady: Modes.loaded
    // Portabilidad F2a: la detección de capacidades arranca sola (diferida) al cargar.
    readonly property bool capsReady: Capabilities.ready
    // 2026-10-28: los avisos del calendario local viven desde el arranque (no sólo con la UI abierta).
    readonly property bool remindersReady: CalendarReminders.ready
    // CalDAV: la sincronización arranca con la sesión y vuelve con la red.
    readonly property bool calendarSyncReady: CalendarSync.ready
    // Apariencia (2026-11-13): devuelve a Hyprland el cursor aplicado desde Settings (diferido, una vez por sesión).
    readonly property bool appearanceReady: Appearance.ready

    Variants {
        model: Quickshell.screens
        Screen {}
    }

    Ipc {}

    /** Atajos globales (Fase 9.a): sin spawn de cliente por pulsacion. */
    Shortcuts {}

    /**
     * ADR-30, docs/lock/ROADMAP.md L4: el núcleo del lock. Nadie lo dispara
     * solo — sólo `lockNow` a mano (L4) o la cadena del rice (L5, aún no
     * conectada). Vuelta atrás: quitar esta línea.
     */
    LockSession {}

    /**
     * Polkit pide credenciales: la superficie `auth` en el monitor enfocado
     * (QS-FUNC-017). Solo ocurre con `Settings.polkitAgent` encendido.
     *
     * ISLAND.md §3.4: con la sesión bloqueada nada se abre; una petición nueva
     * se cancela en el acto y queda en el journal, no en pantalla.
     */
    Connections {
        target: Polkit
        function onRequestStarted() {
            if (Lock.engaged) {
                console.warn("polkit: request cancelled, the screen is locked");
                if (Polkit.flow)
                    Polkit.flow.cancelAuthenticationRequest();
                return;
            }
            // 6D: la petición es una operación global; su propietario, la pantalla que
            // la presenta: la enfocada, o una sin una clave a medio escribir.
            const sc = Screens.pickForRequest();
            Polkit.beginOp(sc ? sc.name : "");
            if (!sc) { console.warn("polkit: no screen to show the authentication request on"); return; }
            // Todas tenían una edición sensible: pregunta antes. Que el island lo diga,
            // para que «Keep editing» no deje la petición esperando sin que se sepa.
            if (!sc.openSurface("auth"))
                sc.announce("Authentication requested", "lock", "warn");
        }
    }

    /**
     * 11F-2: una acción de sistema en Systemd Units pide autorización, y la surface `auth` sustituye
     * a la ficha en esa pantalla. Al terminar (autorizada, cancelada o denegada) la ficha vuelve con
     * su resultado, SÓLO si esa pantalla se quedó sin nada abierto: si abriste otra cosa, no se toca.
     */
    Connections {
        target: Units
        function onActionFinished(key, screen) {
            if (!key || Units.parseKey(key).scope !== "system") return;
            const sc = Screens.resolve(screen);
            // 16G: también si lo que queda es la `auth` ya terminada de esta misma acción (con el
            // usuario real la ficha no volvía); la línea del journal dice qué había en la pantalla.
            const authDone = sc && sc.open === "auth" && (!Polkit.flow || Polkit.flow.isCompleted);
            console.info("units: action finished on", screen || "(focused)", "— open:", sc ? JSON.stringify(sc.open) : "no screen");
            if (sc && (sc.open === "" || authDone)) sc.openSurfaceWith("serviceDetail", key);
        }
    }

    /**
     * ISLAND.md §6: lo que el lock no puede decir sobre sí mismo lo dice el
     * island al volver. `denied` es el único motivo que emite L4 hoy (bloqueo
     * denegado o protocolo ausente); el resto (rebloqueo tras caída) llega en
     * L5 con el rescate.
     */
    Connections {
        target: Lock
        function onFailed(reason) {
            const sc = Screens.resolve("");
            if (!sc)
                return;
            if (reason === "denied")
                sc.announce("Couldn't lock the screen", "alert", "danger");
        }
    }

    /**
     * «Reply» en un popup de notificacion: el centro en el monitor enfocado, con
     * la entrada marcada en `NotifHistory.replyTarget` (ADR-29, Fase 2).
     */
    Connections {
        target: Notifs
        function onReplyRequested(key) {
            const sc = Screens.resolve("");
            if (sc) sc.openSurface("notifications");
            else console.warn("notifs: no screen to open the notification center on");
        }
    }

    /**
     * Singletons are lazy: nothing exists until something reads it. Touching
     * Wallpaper here means its scan and its read of `.current-wallpaper` have
     * happened by the time the first IPC call arrives, instead of the first
     * `status` reporting an empty library it is only now loading.
     */
    Component.onCompleted: {
        void Wallpaper.count;
        // 10B: el programador de la rotación (apagado por defecto) existe desde el arranque
        void WallpaperRotation.enabled;
        // 10D-1: las descargas se reconcilian al arrancar aunque nadie abra Wallpaper List
        void Downloads.loaded;
        // 10E-1b: el índice privado leído antes de que una descarga quiera anotar algo
        void WallhavenIndex.loaded;
        // El agente de polkit tiene que registrarse al arrancar, no cuando
        // alguien lea el singleton por primera vez.
        void Polkit.enabled;
        // ADR-29: igual con el servidor de notificaciones (si el ajuste esta
        // encendido). Apagado, esto solo crea el singleton: ni servidor ni nombre.
        void Notifs.enabled;
        // 14B: una prueba de sistema viva al recargar o reiniciar se recupera enseguida (el guard
        // sigue contando fuera del shell: aquí sólo vuelve la cuenta regresiva)
        void SystemTest.live;
    }
}
