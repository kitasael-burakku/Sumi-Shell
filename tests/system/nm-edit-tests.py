#!/usr/bin/env python3
"""Pruebas de scripts/nm_edit.py y de `nm-profiles.py apply` (fase 14D) con un nmcli FALSO.

No toca NetworkManager: SUMI_NMCLI apunta a un script que responde desde un JSON y apunta
cada `modify` que recibe. Lo que depende de polkit y del checkpoint real se probó en vivo
(rediseno/PREPARACION.md §14D). Uso: python3 nm-edit-tests.py
"""
import json
import os
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
# F5f: SUMI_SCRIPTS prueba otra carpeta de scripts sin desplegar
SCRIPTS = os.environ.get("SUMI_SCRIPTS") or os.path.join(HERE, "..", "..", "sumi", "scripts")
sys.path.insert(0, SCRIPTS)
import nm_edit as ne  # noqa: E402

fails = 0


def check(name, cond, detail=""):
    global fails
    print(("OK   " if cond else "FAIL ") + name + ("" if cond else "  →  " + str(detail)))
    if not cond:
        fails += 1


AUTO = {"name": "Casa", "type": "802-11-wireless", "autoconnect": True, "priority": 0, "metered": "auto",
        "ipv4Method": "auto", "addresses": [], "gateway": "", "dns": [], "ignoreAutoDns": False}
MANUAL = dict(AUTO, ipv4Method="manual", addresses=["192.168.1.20/24"], gateway="192.168.1.1")


def rejects(props, current, text=""):
    try:
        ne.validate(props, current)
        return False
    except ne.Invalid as e:
        return text in str(e)


# ---- validar -------------------------------------------------------------------------------
check("sin cambios → vacío", ne.validate({"priority": 0}, AUTO) == {})
check("sólo lo que cambia", ne.validate({"priority": 5, "autoconnect": True}, AUTO) == {"priority": 5})
check("normaliza IP y CIDR", ne.validate({"ipv4Method": "manual", "addresses": [" 10.0.0.5/24 "]}, AUTO)
      == {"ipv4Method": "manual", "addresses": ["10.0.0.5/24"]})
check("pasar a automático vacía direcciones y gateway",
      ne.validate({"ipv4Method": "auto"}, MANUAL) == {"ipv4Method": "auto", "addresses": [], "gateway": ""})
check("manual sin dirección", rejects({"ipv4Method": "manual"}, AUTO, "needs at least one address"))
check("dirección en automático", rejects({"addresses": ["10.0.0.5/24"]}, AUTO, "only for manual"))
check("dirección de red", rejects({"addresses": ["192.168.1.0/24"]}, MANUAL, "network or broadcast"))
check("broadcast", rejects({"addresses": ["192.168.1.255/24"]}, MANUAL, "network or broadcast"))
check("prefijo /4", rejects({"addresses": ["10.0.0.5/4"]}, MANUAL, "prefix"))
check("sin prefijo pasa como /32", ne.validate({"addresses": ["10.0.0.5"]}, dict(MANUAL, gateway=""))
      == {"addresses": ["10.0.0.5/32"]})
check("gateway fuera de la red", rejects({"gateway": "10.9.9.1"}, MANUAL, "outside"))
check("gateway vacío vale", ne.validate({"gateway": ""}, MANUAL) == {"gateway": ""})
check("DNS inválido", rejects({"dns": ["1.1.1"]}, AUTO, "not an IPv4"))
check("DNS con inyección", rejects({"dns": ["1.1.1.1;reboot"]}, AUTO))
check("DNS multicast", rejects({"dns": ["224.0.0.1"]}, AUTO, "can't be"))
check("cuatro DNS", rejects({"dns": ["1.1.1.1", "1.0.0.1", "9.9.9.9", "8.8.8.8"]}, AUTO, "three"))
check("sólo mis DNS sin DNS", rejects({"ignoreAutoDns": True}, AUTO, "at least one"))
check("prioridad fuera de rango", rejects({"priority": 1000}, AUTO, "-999"))
check("prioridad booleana", rejects({"priority": True}, AUTO))
check("metered raro", rejects({"metered": "maybe"}, AUTO))
check("campo no admitido (SSID)", rejects({"ssid": "x"}, AUTO, "can't be edited"))
check("campo no admitido (MTU)", rejects({"mtu": 1400}, AUTO, "can't be edited"))
check("nada", rejects({}, AUTO, "Nothing"))

# ---- argumentos de nmcli ----------------------------------------------------------------------
args = ne.nmcli_args({"dns": ["1.1.1.1", "9.9.9.9"], "ignoreAutoDns": True, "metered": "auto", "autoconnect": False,
                      "priority": -10})
check("argumentos en orden y con los valores de nmcli", args == [
    "connection.autoconnect", "no", "connection.autoconnect-priority", "-10", "connection.metered", "unknown",
    "ipv4.dns", "1.1.1.1,9.9.9.9", "ipv4.ignore-auto-dns", "yes"], args)
check("describe", ne.describe({"dns": ["1.1.1.1"], "ignoreAutoDns": True}) == "DNS 1.1.1.1 · only these DNS")

# ---- la interfaz refleja lo pedido ------------------------------------------------------------
dev = {"state": "100 (connected)", "addresses": ["192.168.1.20/24"], "gateway": "192.168.1.1", "dns": ["1.1.1.1"], "path": ""}
check("manual casa", ne.matches_device(dict(MANUAL, dns=["1.1.1.1"]), dev) == [])
check("falta la dirección", ne.matches_device(dict(MANUAL, addresses=["192.168.1.21/24"]), dev) != [])
check("gateway distinto", ne.matches_device(dict(MANUAL, gateway="192.168.1.254"), dev) != [])
check("sólo mis DNS exige los mismos", ne.matches_device(dict(AUTO, dns=["9.9.9.9"], ignoreAutoDns=True), dev) != [])
check("automático sin dirección aún", ne.matches_device(AUTO, dict(dev, addresses=[])) == ["no address from DHCP yet"])
check("interfaz ausente", ne.matches_device(AUTO, None) == ["the interface is gone"])

# ---- lectura y apply con un nmcli falso ---------------------------------------------------------
FAKE = r'''#!/usr/bin/env python3
import json, os, sys
st = json.load(open(os.environ["KT_NM"]))
a = sys.argv[1:]
log = open(os.environ["KT_NM"] + ".log", "a")
if a[:2] == ["connection", "modify"]:
    log.write(json.dumps(a) + "\n")
    i = a.index("uuid") + 2
    p = st["profiles"][a[a.index("uuid") + 1]]
    for f, v in zip(a[i::2], a[i + 1::2]):
        p[f] = v
    json.dump(st, open(os.environ["KT_NM"], "w"))
    sys.exit(0)
if a[0] == "-g" and a[2:4] == ["connection", "show"]:
    p = st["profiles"].get(a[5])
    if p is None:
        sys.exit(10)
    print("\n".join(p.get(f, "") for f in a[1].split(",")))
    sys.exit(0)
if a[:3] == ["-t", "-f", "UUID,DEVICE"]:
    for u, d in st["active"].items():
        print("%s:%s" % (u, d))
    sys.exit(0)
sys.exit(2)
'''
U_ACT = "11111111-2222-3333-4444-555555555555"
U_OFF = "66666666-7777-8888-9999-000000000000"


def prof(name, typ):
    return {"connection.id": name, "connection.type": typ, "connection.autoconnect": "yes",
            "connection.autoconnect-priority": "0", "connection.metered": "unknown", "ipv4.method": "auto",
            "ipv4.addresses": "", "ipv4.gateway": "", "ipv4.dns": "", "ipv4.ignore-auto-dns": "no",
            "GENERAL.CON-PATH": ""}


with tempfile.TemporaryDirectory() as tmp:
    state = os.path.join(tmp, "nm.json")
    json.dump({"profiles": {U_ACT: prof("Cable\\: casa", "802-3-ethernet"), U_OFF: prof("Otra", "802-11-wireless")},
               "active": {U_ACT: "enp1s0"}}, open(state, "w"))
    fake = os.path.join(tmp, "nmcli")
    open(fake, "w").write(FAKE)
    os.chmod(fake, 0o755)
    env = dict(os.environ, SUMI_NMCLI=fake, KT_NM=state, PYTHONDONTWRITEBYTECODE="1")

    def apply(uuid, props):
        p = subprocess.run([sys.executable, os.path.join(SCRIPTS, "nm-profiles.py"), "apply", uuid, json.dumps(props)],
                           capture_output=True, text=True, env=env)
        return json.loads(p.stdout)

    os.environ.update(SUMI_NMCLI=fake, KT_NM=state)
    ne.NMCLI = fake
    p = ne.read_profile(U_ACT)
    check("lectura: nombre con «:» escapado", p and p["name"] == "Cable: casa", p)
    check("lectura: metered unknown → auto", p and p["metered"] == "auto")
    check("dispositivos activos", ne.active_devices(U_ACT) == ["enp1s0"] and ne.active_devices(U_OFF) == [])
    r = apply(U_ACT, {"dns": ["1.1.1.1"]})
    check("apply: DNS de un perfil ACTIVO pide prueba", r.get("needsTest") is True, r)
    r = apply(U_ACT, {"priority": 5, "metered": "yes"})
    check("apply: prioridad y metered de uno activo, directo", r.get("ok") and r["undo"] == {"priority": 0, "metered": "auto"}
          and r["active"], r)
    r = apply(U_OFF, {"ipv4Method": "manual", "addresses": ["10.1.1.5/24"], "gateway": "10.1.1.1", "dns": ["9.9.9.9"]})
    check("apply: IPv4 de uno INACTIVO, directo", r.get("ok") and r["undo"]["ipv4Method"] == "auto", r)
    log = open(state + ".log").read().splitlines()
    check("modify sin --temporary y con argumentos separados", all("--temporary" not in json.loads(l) for l in log)
          and json.loads(log[-1])[-2:] == ["ipv4.dns", "9.9.9.9"], log[-1])
    r = apply(U_OFF, {"ssid": "x"})
    check("apply: campo no admitido", "can't be edited" in r.get("error", ""), r)
    r = apply("x; rm -rf /", {"priority": 1})
    check("apply: id raro", r.get("error") == "bad profile id", r)

print("\n%d fallo(s)" % fails)
sys.exit(1 if fails else 0)
