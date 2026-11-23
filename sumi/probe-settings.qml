import QtQuick
import Quickshell
import Quickshell.Io
import "services"

/**
 * SONDA DEL CONFIGSTORE (rediseño, fase 3). Sólo instancia `Settings`: nada más del shell.
 * Se lanza SIEMPRE con XDG_CONFIG_HOME y XDG_STATE_HOME temporales — sin ellos
 * migraría y escribiría la configuración real. Se niega si apuntan a la del usuario.
 *
 *   XDG_CONFIG_HOME=$(mktemp -d) XDG_STATE_HOME=$(mktemp -d) qs -p <árbol>/probe-settings.qml
 *
 * IPC `sumi-settings-probe`: `summary`, `values`, `set <prop> <json>`, `act <acción>`.
 */
ShellRoot {
    readonly property bool safe: (Quickshell.env("XDG_CONFIG_HOME") || "").length > 0
        && (Quickshell.env("XDG_STATE_HOME") || "").length > 0
        && Quickshell.env("XDG_CONFIG_HOME") !== Quickshell.env("HOME") + "/.config"
    Component.onCompleted: {
        if (!safe) { console.error("probe-settings: temp XDG dirs required"); return; }
        console.log("PROBE loaded=" + Settings.loaded + " status=" + Settings.status);
    }
    IpcHandler {
        target: "sumi-settings-probe"
        function summary(): string { return JSON.stringify(Settings.summary()); }
        function values(): string { return JSON.stringify(Settings.values()); }
        function set(prop: string, json: string): bool {
            let v; try { v = JSON.parse(json); } catch (e) { return false; }
            Settings[prop] = v; return true;
        }
        function act(name: string): string {
            if (name === "retry") Settings.retry();
            else if (name === "lastGood") Settings.restoreLastGood();
            else if (name === "previous") Settings.restorePrevious();
            else if (name === "defaults") Settings.restoreDefaults();
            else if (name === "useFile") Settings.useFile();
            else if (name === "keepMine") Settings.keepMine();
            else return "unknown";
            return Settings.status;
        }
    }
}
