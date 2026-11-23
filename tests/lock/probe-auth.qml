import QtQuick
import Quickshell
import Quickshell.Services.Pam
import "lock"

// Sonda 15G-1: LockAuth con un adaptador PAM FALSO (nunca la pila real) y faillock falso. Sin bloquear nada.
ShellRoot {
    id: root
    readonly property string dir: Quickshell.env("KT_DIR")
    function log(o) { console.log("PROBE " + JSON.stringify(o)); }

    // El adaptador: misma forma que PamContext. `plan` = lo que pide tras cada respuesta.
    QtObject {
        id: fake
        property bool active: false
        property string message: ""
        property bool messageIsError: false
        property bool responseRequired: false
        property bool responseVisible: false
        property int starts: 0
        property var answers: []
        property var bufferAtRespond: []
        property var plan: []          // [{ask: "Verification code:"} | {result: "ok"|"fail"}]
        signal pamMessage()
        signal completed(int result)
        signal error(int err)
        function start() { fake.starts++; fake.active = true; fake.ask("Password:"); return true; }
        function ask(text) { fake.message = text; fake.responseRequired = true; Qt.callLater(function () { fake.pamMessage(); }); }
        function respond(r) {
            fake.answers = fake.answers.concat([r.length]);           // sólo longitudes: nada tecleado al log
            fake.bufferAtRespond = fake.bufferAtRespond.concat([auth.buffer.length]);
            fake.responseRequired = false;
            const next = fake.plan.shift();
            if (next && next.ask) { fake.ask(next.ask); return; }
            fake.active = false;
            const res = next && next.result === "ok" ? PamResult.Success : PamResult.Failed;
            Qt.callLater(function () { fake.completed(res); });
        }
        function abort() { fake.active = false; }
    }

    LockAuth {
        id: auth
        pam: fake
        faillockConf: root.dir + "/faillock.conf"
        // ignora lo que se añada (--dir): el faillock de verdad lo acepta
        faillockCommand: ["sh", "-c", "cat \"$0\"", root.dir + "/faillock.out"]
        onSuccess: root.log({ ev: "success" })
    }

    property int stepNo: 0
    Timer {
        interval: 300; repeat: true; running: true
        onTriggered: {
            const n = root.stepNo++;
            if (n === 0) {                      // A: segundo factor bien contestado
                fake.plan = [{ ask: "Verification code:" }, { result: "ok" }];
                auth.setBuffer("pw-fake"); auth.submit();
            } else if (n === 2) {
                root.log({ step: "A-prompt", state: auth.auth.state, prompt: auth.auth.prompt, starts: fake.starts });
                auth.setBuffer("123456"); auth.submit();
            } else if (n === 4) {
                root.log({ step: "A-end", state: auth.auth.state, starts: fake.starts, answers: fake.answers,
                           bufferAtRespond: fake.bufferAtRespond });
                fake.starts = 0; fake.answers = []; fake.bufferAtRespond = [];
                fake.plan = [{ ask: "Verification code:" }, { result: "fail" }];   // B: código mal
                auth.setBuffer("pw-fake"); auth.submit();
            } else if (n === 6) {
                auth.setBuffer("000000"); auth.submit();
            } else if (n === 8) {
                root.log({ step: "B-end", state: auth.auth.state, starts: fake.starts, answers: fake.answers,
                           failed: auth.auth.failed, policy: auth.faillockPolicy });
            } else if (n === 9) {
                root.log({ end: true }); Qt.quit();
            }
        }
    }
}
