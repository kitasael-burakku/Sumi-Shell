pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Services.UPower

/**
 * Rotación de fondos (rediseño 10B; futureSettingssurface §6 Rotation).
 *
 * UN solo programador: éste. `wallpaper.service` sigue sólo restaurando al iniciar sesión, y no
 * hay timer de systemd (decisión del usuario, 2026-09-26): las pausas son estado del shell. Sin
 * shell no rota.
 *
 *   · Apagada por defecto (`Settings.wallRotation`).
 *   · Toca cuando pasa el intervalo desde el ÚLTIMO CAMBIO OBSERVADO del fondo (Recent), venga de
 *     donde venga: aplicar uno a mano reinicia la cuenta. Nunca antes de un minuto tras arrancar
 *     (`wallpaper.service` puede estar restaurando) ni tras activarla (cuenta desde ese momento).
 *   · Pausas opcionales: pantalla completa en cualquier salida, batería (descargando), modos
 *     Gaming/Cinema. Siempre: con el bloqueo puesto, o con otro apply en curso. Lo que venció en
 *     pausa se hace al salir de ella.
 *   · Saca el siguiente de la bolsa (`Wallpaper.random`) con el conjunto elegido, para todas las
 *     pantallas y por el camino de siempre: repinta con matugen.
 *
 * En `services/` (y no en `core/`, junto a `Hypr`) para que Settings pueda leer su estado: las
 * surfaces no importan `core`. La pantalla completa se lee igual que `Hypr.hasFullscreen`.
 */
Singleton {
    id: root

    readonly property bool enabled: Settings.wallRotation
    readonly property string from: Settings.wallRotationFrom
    /** Pruebas (IPC `wallRotationTest`, sólo con `Wallpaper.testing`): intervalo en ms. */
    property int testIntervalMs: 0
    readonly property real intervalMs: root.testIntervalMs > 0 ? root.testIntervalMs
        : Settings.wallRotationMinutes * 60000
    readonly property real graceMs: root.testIntervalMs > 0 ? 0 : 60000

    readonly property real startedAt: Date.now()
    /** Cuándo se encendió (o el arranque): la cuenta nunca empieza antes. */
    property real armedAt: Date.now()
    onEnabledChanged: if (root.enabled) root.armedAt = Date.now()

    readonly property real lastChange: {
        const r = WallpaperMeta.recent;
        return r.length > 0 && r[0].at > 0 ? r[0].at : 0;
    }
    readonly property real dueAt: Math.max(root.lastChange + root.intervalMs, root.armedAt + root.intervalMs,
                                           root.startedAt + root.graceMs)

    readonly property bool fullscreenNow: {
        const m = Hyprland.monitors.values;
        for (let i = 0; i < m.length; i++) {
            const ws = m[i] ? m[i].activeWorkspace : null;
            if (ws && ws.hasFullscreen) return true;
        }
        return false;
    }
    /** Descargando de verdad (en un sobremesa `Battery.present` es falso: nunca pausa por esto). */
    readonly property bool onBattery: Battery.onBattery && Battery.discharging
    readonly property bool quietMode: DesktopMode.mode === "gaming" || DesktopMode.mode === "cinema"

    /** Por qué no rota ahora (texto de la UI), o "". */
    readonly property string pauseReason: {
        if (Lock.engaged) return "Paused while locked";
        // F2c: sin proveedor de fondos no hay nada que rotar (no se intenta cada vez)
        if (Wallpaper.applyWhy.length > 0) return "Paused · " + Wallpaper.applyWhy;
        // 12A: un fondo nuevo terminaría la preview de tema en curso; se espera a que se decida
        if (ThemePreview.live) return "Paused · theme preview";
        if (Settings.wallRotationPauseFullscreen && root.fullscreenNow) return "Paused · something is fullscreen";
        if (Settings.wallRotationPauseBattery && root.onBattery) return "Paused · on battery";
        if (Settings.wallRotationPauseModes && root.quietMode)
            return "Paused · " + DesktopMode.mode.charAt(0).toUpperCase() + DesktopMode.mode.substring(1) + " mode";
        return "";
    }

    property real now: Date.now()
    property int rotations: 0
    property real lastRotationAt: 0
    property string lastResult: ""

    /** Cada 30 s (o 250 ms en pruebas) se mira si toca; barato y sin deriva. */
    Timer {
        interval: root.testIntervalMs > 0 ? 250 : 30000
        repeat: true
        running: root.enabled
        triggeredOnStart: true
        onTriggered: root.check()
    }
    onPauseReasonChanged: if (root.enabled && root.pauseReason.length === 0) Qt.callLater(root.check)

    function check() {
        root.now = Date.now();
        if (!root.enabled || root.now < root.dueAt || root.pauseReason.length > 0) return false;
        if (Wallpaper.busy || Wallpaper.count === 0) return false;
        // lo que se pidió hace un momento (y aún no cambió `current`) no se repite
        if (root.lastRotationAt > 0 && root.now - root.lastRotationAt < Math.min(root.intervalMs, 60000)) return false;
        root.lastRotationAt = root.now;
        const ok = Wallpaper.random(root.from, "rotation");
        root.rotations++;
        root.lastResult = ok ? "requested" : (root.from === "favorites" ? "No favorites to rotate" : "Nothing to rotate");
        return ok;
    }

    /** Texto de estado para Settings. */
    readonly property string statusText: {
        void root.now;
        if (!root.enabled) return "Off";
        if (root.pauseReason.length > 0) return root.pauseReason;
        if (root.lastResult.length > 0 && root.lastResult !== "requested") return root.lastResult;
        const left = Math.max(0, root.dueAt - root.now);
        if (left < 60000) return "Next change in under a minute";
        const m = Math.round(left / 60000);
        return m < 90 ? "Next change in " + m + " min" : "Next change in " + Math.round(m / 60) + " h";
    }

    function summary() {
        root.now = Date.now();
        return { enabled: root.enabled, from: root.from, intervalMs: root.intervalMs,
                 dueInMs: Math.round(root.dueAt - root.now), pause: root.pauseReason,
                 fullscreen: root.fullscreenNow, onBattery: root.onBattery, mode: DesktopMode.mode,
                 rotations: root.rotations, lastResult: root.lastResult, status: root.statusText,
                 testIntervalMs: root.testIntervalMs };
    }
}
