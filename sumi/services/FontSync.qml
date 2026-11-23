pragma Singleton
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io

/**
 * T4 · la tipografía de la shell en otras apps (GTK 3, GTK 4, Qt 5/qt5ct, Qt 6/qt6ct, kitty, VSCodium), opcional y por destino.
 *
 * Todo lo hace `scripts/font-sync.py` en su propio proceso; aquí sólo se pide y se enseña:
 *   preview()  plan de los destinos ENCENDIDOS (sólo lectura): qué cambia, qué ya es equivalente y por qué no
 *   apply()    «Sync selected»: aplica SÓLO si el plan sigue siendo el enseñado (token); si no, se niega
 *   undoLast() deshace la última sincronización · undoAll() todo lo gestionado
 * Nada se sincroniza al elegir una fuente: el Apply del editor sigue siendo sólo de la shell.
 * Una orden a la vez; las que llegan mientras otra corre se guardan (la última de cada tipo).
 */
Singleton {
    id: root

    readonly property var order: [
        { slot: "gtk.interface", prop: "fontSyncGtkInterface", label: "GTK 3 interface font" },
        { slot: "gtk.monospace", prop: "fontSyncGtkMonospace", label: "GTK 3 monospace font" },
        { slot: "gtk4.interface", prop: "fontSyncGtk4Interface", label: "GTK 4 interface font (settings.ini)" },
        { slot: "qt6.interface", prop: "fontSyncQt6Interface", label: "Qt 6 interface font (qt6ct)" },
        { slot: "qt6.fixed", prop: "fontSyncQt6Fixed", label: "Qt 6 fixed font (qt6ct)" },
        { slot: "kitty.terminal", prop: "fontSyncKitty", label: "kitty" },
        { slot: "vscodium.editor", prop: "fontSyncVscodium", label: "VSCodium editor" },
        { slot: "qt5.interface", prop: "fontSyncQt5Interface", label: "Qt 5 interface font (qt5ct)" },
        { slot: "qt5.fixed", prop: "fontSyncQt5Fixed", label: "Qt 5 fixed font (qt5ct)" }
    ]
    property bool editingTargets: false
    property var draftTargets: ({})
    property string draftBase: ""
    readonly property bool draftValid: !root.editingTargets || root.draftBase === Settings.fontSyncSignature
    readonly property bool draftDirty: root.editingTargets && JSON.stringify(root.draftTargets) !== root.draftBase
    function selected(prop) { return (root.editingTargets ? root.draftTargets[prop] : Settings[prop]) === true; }
    function beginDraft() {
        root.draftTargets = Object.assign({}, Settings.fontSyncSelection);
        root.draftBase = Settings.fontSyncSignature;
        root.editingTargets = true;
        root.plan = null; root.planKey = ""; root.last = null;
    }
    function discardDraft() {
        root.editingTargets = false; root.draftTargets = ({});
        root.plan = null; root.planKey = "";
    }
    function toggle(prop) {
        if (!root.editingTargets || !Settings.writable || root.busy) return;
        const next = Object.assign({}, root.draftTargets);
        next[prop] = !next[prop];
        root.draftTargets = next;
    }
    readonly property string targets: root.order.filter(o => root.selected(o.prop)).map(o => o.slot).join(",")
    readonly property bool reloadKitty: root.selected("fontSyncKittyReload")
    // lo que se enseña tiene que ser lo que se aplica: mismos destinos, misma recarga, misma elección de fuente
    readonly property string wantKey: root.targets + "|" + root.reloadKitty + "|" + Settings.typographySignature

    property var plan: null
    property string planKey: ""
    property var status: null
    property var last: null              // resultado de la última orden que escribe
    property string error: ""
    property bool busy: proc.running
    readonly property bool fresh: root.plan !== null && root.planKey === root.wantKey && !root.busy
    readonly property int changes: root.plan ? root.plan.changes : 0
    readonly property bool canSync: root.fresh && root.draftValid && Settings.writable
        && (root.changes > 0 || root.draftDirty) && root.plan.ok === true
    readonly property bool canUndo: !root.busy && root.status !== null && (root.status.managed || []).length > 0

    function slotPlan(slot) {
        return root.plan ? (root.plan.slots || []).find(s => s.slot === slot) || null : null;
    }
    function slotStatus(slot) {
        return root.status ? (root.status.managed || []).find(m => m.slot === slot) || null : null;
    }
    /** Una línea por destino: lo que va a pasar, o por qué no. */
    function describe(slot) {
        const p = root.slotPlan(slot);
        const m = root.slotStatus(slot);
        const managed = m ? " · configured" + (m.state === "changed-by-you" ? ", changed by you since"
                                            : m.state === "overridden" ? ", overridden by your config"
                                            : m.state === "incomplete" ? ", incomplete: undo it"
                                            : "; effective font pending in apps") : "";
        if (!p) return root.busy ? "Checking…" : "";
        switch (p.action) {
        case "off": return managed.length ? "Off" + managed : "";
        case "change": return (p.current || "Default") + " → " + p.proposed + managed;
        case "restore": return "Back to your " + p.proposed + managed;
        case "unchanged": return (p.reason || "Already the same") + managed;
        default: return (p.action === "blocked" ? "Can't: " : "Not available: ") + (p.reason || "") + managed;
        }
    }
    /** Una línea con el resultado de la última orden que escribió (o su error); vacía si no hubo. */
    readonly property string lastLine: {
        const l = root.last;
        if (!l) return "";
        if (l.preferencesOnly) return "Selection saved · no external configuration changed";
        if (l.error === "plan-changed") return "Not synced: something changed since the preview · Preview again";
        if (!l.results) return l.reason ? "Not done: " + l.reason : "";
        const by = k => l.results.filter(r => k.indexOf(r.result) >= 0).map(r => r.label);
        const parts = [];
        const ok = by(["applied"]), back = by(["restored", "before"]), kept = by(["conflict"]);
        const bad = l.results.filter(r => ["applied", "restored", "before", "conflict"].indexOf(r.result) < 0);
        if (ok.length) parts.push("Configured: " + ok.join(", ") + " · verify the effective font in apps");
        if (back.length) parts.push("Undone: " + back.join(", "));
        if (kept.length) parts.push("Left as you changed it: " + kept.join(", "));
        if (bad.length) parts.push("Failed: " + bad.map(r => r.label + (r.reason ? " (" + r.reason + ")" : "")).join(", "));
        return parts.join(" · ");
    }
    readonly property bool lastBad: root.last !== null && (root.last.ok !== true)
    readonly property string summary: !root.draftValid ? "Saved targets changed: cancel and reopen this panel"
        : !root.plan ? (root.busy ? "Checking…" : "Off · nothing is synced")
        : root.targets.length === 0 ? "Off · nothing is synced" + ((root.status && (root.status.managed || []).length)
                                                                    ? " · " + root.status.managed.length + " still synced" : "")
        : root.changes > 0 ? root.changes + " to sync · review and press Sync selected"
        : "Nothing to change"

    function _run(kind, args, key) {
        if (proc.running) { root._queued[kind] = {args: args, key: key || ""}; return; }
        root.error = "";
        proc.kind = kind;
        proc.planKey = key || "";
        proc.command = ["python3", "-B", Quickshell.shellPath("scripts/font-sync.py")].concat(args);
        proc.running = true;
    }
    property var _queued: ({})
    /** `fresh`: la pidió el usuario (Preview, un interruptor): lo último que pasó ya no es lo que se enseña. */
    function preview(fresh) {
        if (fresh === true) root.last = null;
        root._run("plan", ["plan", "--targets", root.targets.length ? root.targets : "-"]
            .concat(root.reloadKitty ? ["--reload-kitty"] : []), root.wantKey);
    }
    function refreshStatus() { root._run("status", ["status"]); }
    function apply() {
        if (!root.canSync) return false;
        if (root.editingTargets) {
            if (!Settings.applyFontSync(root.draftBase, root.draftTargets)) return false;
            root.draftBase = Settings.fontSyncSignature;
        }
        if (root.changes === 0) {
            root.last = {ok: true, preferencesOnly: true, results: []};
            return true;
        }
        root._run("apply", ["apply", "--expect", root.plan.token, "--targets", root.targets]
            .concat(root.reloadKitty ? ["--reload-kitty"] : []));
        return true;
    }
    function undoLast() {
        if (!root.canUndo || !root.status.last) return false;
        root._run("rollback", ["rollback", "--tx", root.status.last].concat(root.reloadKitty ? ["--reload-kitty"] : []));
        return true;
    }
    function undoAll() {
        if (!root.canUndo) return false;
        root._run("rollback", ["rollback", "--all"].concat(root.reloadKitty ? ["--reload-kitty"] : []));
        return true;
    }

    Process {
        id: proc
        property string kind: ""
        property string planKey: ""
        stdout: StdioCollector {
            onStreamFinished: {
                let doc = null;
                try { doc = JSON.parse(text.trim().split("\n").pop()); } catch (e) { doc = null; }
                const kind = proc.kind;
                if (!doc) { root.error = "The font sync helper didn't answer"; return; }
                if (kind === "plan") { root.plan = doc; root.planKey = proc.planKey; }
                else if (kind === "status") root.status = doc;
                else root.last = doc;
                if (doc.ok !== true && kind !== "plan") root.error = doc.reason || doc.error || "";
                if (doc.ok !== true && kind === "plan" && doc.error) root.error = doc.reason || doc.error;
            }
        }
        onExited: {
            const k = proc.kind;
            // lo que escribe deja el plan y el estado viejos: se piden de nuevo
            if (k === "apply" || k === "rollback") { root.plan = null; root._queued.status = {args: ["status"], key: ""};
                root._queued.plan = null; Qt.callLater(root.preview); }
            const q = root._queued;
            for (const kind of ["apply", "rollback", "status", "plan"]) {
                if (q[kind]) { const item = q[kind]; delete q[kind]; root._run(kind, item.args, item.key); return; }
            }
        }
    }
}
