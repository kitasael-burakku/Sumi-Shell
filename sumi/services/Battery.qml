pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import "../lib/battery-alerts.js" as Alerts

/** Batería agregada de UPower y avisos globales por umbral. Sin batería de
 * laptop (incluido un escritorio con UPS) no muestra indicadores ni avisa.
 * Las simulaciones viven en tools/laptop, nunca en este proveedor real. */
Singleton {
    id: root

    readonly property var device: UPower.displayDevice
    readonly property bool present: device !== null && device.ready
        && device.isLaptopBattery && device.isPresent

    readonly property real fraction: present && isFinite(device.percentage) ? Math.max(0, Math.min(1, device.percentage)) : 0
    readonly property int percent: Math.round(fraction * 100)
    readonly property bool charging: present && device.state === UPowerDeviceState.Charging
    readonly property bool onBattery: present && UPower.onBattery
    readonly property bool externalPower: present && !UPower.onBattery
    readonly property bool full: present && device.state === UPowerDeviceState.FullyCharged
    readonly property bool discharging: present && (device.state === UPowerDeviceState.Discharging
        || device.state === UPowerDeviceState.Empty)
    readonly property var thresholds: Settings.batteryCritical < Settings.batteryVeryLow && Settings.batteryVeryLow < Settings.batteryLow
        ? [Settings.batteryLow, Settings.batteryVeryLow, Settings.batteryCritical] : [20, 10, 5]
    readonly property bool low: discharging && onBattery && fraction * 100 <= thresholds[0]
    readonly property string stateLabel: !present ? "No battery" : charging ? "Charging" : full ? "Fully charged"
        : device.state === UPowerDeviceState.Empty ? "Empty"
        : discharging ? (externalPower ? "Discharging · plugged in" : "Discharging")
        : device.state === UPowerDeviceState.PendingCharge ? "Not charging"
        : device.state === UPowerDeviceState.PendingDischarge ? "Pending discharge" : "Unknown"
    readonly property real timeSeconds: !present ? 0 : charging ? device.timeToFull : discharging ? device.timeToEmpty : 0
    readonly property string timeText: Alerts.timeText(timeSeconds)
    readonly property string description: !present ? "No battery" : percent + "% · " + stateLabel
        + (externalPower && !charging && !full && !discharging ? " · Plugged in" : "")
        + (timeText ? " · " + timeText + (charging ? " until full" : " remaining") : "")

    // Uno por shell, no por pantalla. El servidor actual decide DND, fullscreen e historial.
    // Sin servidor propio no competimos con el gestor de energía de otro escritorio.
    readonly property bool alertsEnabled: Settings.loaded && Settings.batteryAlerts && Notifs.enabled
    readonly property bool alertEligible: alertsEnabled && present && discharging && onBattery
    readonly property string alertInput: JSON.stringify([present, fraction, charging, discharging, onBattery,
        thresholds, alertsEnabled, Session.preparingForSleep])
    onAlertInputChanged: settle.restart()
    PersistentProperties {
        id: memory
        reloadableId: "sumi-battery-alerts"
        // Sólo tipos primitivos entre motores QML; un objeto JS no sobrevive a la recarga.
        property string stateJson: ""
        property int notificationId: 0
        onLoaded: settle.restart()
    }
    property var pendingAlert: null
    property int notifyFailures: 0
    Timer { id: settle; interval: 250; onTriggered: root.evaluateAlerts() }
    function evaluateAlerts() {
        if (!Settings.loaded || Session.preparingForSleep) return;
        const previous = memory.stateJson ? JSON.parse(memory.stateJson) : null;
        const result = Alerts.advance(previous,
            { present: present, percent: fraction * 100, discharging: discharging, onBattery: onBattery },
            thresholds, alertsEnabled);
        memory.stateJson = JSON.stringify(result.state);
        if (!alertEligible) root.pendingAlert = null;
        else if (result.level > 0) root.pendingAlert = { level: result.level, percent: percent };
        root.pumpAlert();
    }
    function pumpAlert() {
        if (sender.running) return;
        // El usuario pudo descartar el aviso desde el popup o el centro.
        if (memory.notificationId > 0 && !Notifs.find(memory.notificationId)) memory.notificationId = 0;
        const prefix = ["busctl", "--user", "--timeout=3", "--json=short", "call", "--", "org.freedesktop.Notifications",
            "/org/freedesktop/Notifications", "org.freedesktop.Notifications"];
        if ((!alertEligible || Session.preparingForSleep) && memory.notificationId > 0) {
            sender.closing = true;
            sender.command = prefix.concat(["CloseNotification", "u", String(memory.notificationId)]);
            memory.notificationId = 0;
        } else if (alertEligible && !Session.preparingForSleep && root.pendingAlert) {
            const a = root.pendingAlert;
            root.pendingAlert = null;
            sender.closing = false;
            sender.command = prefix.concat(["Notify", "susssasa{sv}i", "Sumi Power", String(memory.notificationId),
                "battery-caution", ["Battery low", "Battery very low", "Battery critical"][a.level - 1],
                a.percent + "% remaining. Connect the charger.", "0", "2", "urgency", "y", a.level === 3 ? "2" : "1",
                "x-canonical-private-synchronous", "s", "sumi-battery", "-1"]);
        } else return;
        sender.running = true;
    }
    Process {
        id: sender
        property bool closing: false
        stdout: StdioCollector { id: reply }
        stderr: StdioCollector { id: notifyError }
        onExited: code => {
            if (code !== 0) { root.notifyFailures++; console.warn("battery: notification delivery failed:", notifyError.text.trim()); }
            else if (!sender.closing) {
                try { memory.notificationId = Number(JSON.parse(reply.text).data[0]) || 0; } catch (e) { root.notifyFailures++; }
            }
            Qt.callLater(root.pumpAlert);
        }
    }
    Connections { target: Session; function onResumed() { settle.restart(); } }

    /**
     * BATERIAS DE PERIFERICOS (QS-FUNC-014). `displayDevice` en un sobremesa es
     * siempre «no presente»; los aparatos con bateria estan en `UPower.devices`.
     * Es donde aparece un mando: el DualSense no publica `org.bluez.Battery1`,
     * su carga vive en `/sys/class/power_supply/ps-controller-battery-<mac>`
     * (README, 9.f.3) y `Bt.battery` no la ve.
     *
     * Sin repetir: si el `nativePath` lleva una MAC que `Bt` ya reporta con
     * bateria, ese aparato se queda en la ficha de bluetooth.
     *
     * [{ name, percent, charging, kind, path }]. Vacio hoy en esta maquina
     * (`upower -e` solo da el DisplayDevice): la rama positiva no esta probada.
     */
    readonly property var peripherals: {
        const out = [];
        const ds = UPower.devices ? UPower.devices.values : [];
        for (let i = 0; i < ds.length; i++) {
            const d = ds[i];
            if (!d || !d.ready || !d.isPresent || d.powerSupply || d.isLaptopBattery)
                continue;
            const mac = root.macOf(d.nativePath);
            if (mac.length > 0 && root.btReports(mac))
                continue;
            out.push({
                name: String(d.model).length > 0 ? String(d.model) : UPowerDeviceType.toString(d.type),
                percent: Math.round(Math.max(0, Math.min(1, d.percentage)) * 100),
                charging: d.state === UPowerDeviceState.Charging,
                kind: UPowerDeviceType.toString(d.type),
                path: String(d.nativePath)
            });
        }
        return out;
    }

    /** "…dev_AA_BB_CC_DD_EE_FF" o "…-aa:bb:cc:dd:ee:ff" -> "aabbccddeeff"; "" si no hay. */
    function macOf(path) {
        const m = /([0-9a-f]{2}[:_-]){5}[0-9a-f]{2}/i.exec(String(path || ""));
        return m ? m[0].replace(/[:_-]/g, "").toLowerCase() : "";
    }

    function btReports(mac) {
        const ds = Bt.all;
        for (let i = 0; i < ds.length; i++) {
            const d = ds[i];
            if (d && d.batteryAvailable && String(d.address).replace(/[:_-]/g, "").toLowerCase() === mac)
                return true;
        }
        return false;
    }
}
