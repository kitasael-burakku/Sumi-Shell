"""Editar un perfil guardado de NetworkManager (fase 14D): validar, escribir, leer y el checkpoint.

Lo usan `nm-profiles.py` (cambios que no pueden cortar la conexión: se aplican y se pueden
deshacer) y `sumi-guard.py` (los que sí: DNS e IPv4 de un perfil ACTIVO, con checkpoint de
NetworkManager y cuenta regresiva). Decisión del usuario (2026-09-29, recomendación 4): sólo
autoconnect, prioridad, metered, DNS + ignore-auto-dns e IPv4 automático/manual (direcciones y
gateway). Nunca SSID, seguridad, secretos, MAC ni MTU.

Medido el 2026-09-29 (NetworkManager 1.58.1):
  · `nmcli connection modify` CONSERVA los secretos guardados (un perfil Wi-Fi de prueba siguió con
    su clave); un Update2 por D-Bus con los ajustes sin secretos podría borrarlos: se escribe con nmcli.
  · `modify --temporary` cambia el perfil sólo en memoria (Unsaved = true); un `modify` normal con
    los mismos valores lo guarda (Unsaved = false). Así «persistir sólo tras confirmar».
  · `modify` no toca la interfaz: hace falta `nmcli device reapply` (sin desconectar; durante un
    instante la dirección vieja ya no está y la nueva aún no).
  · Permisos: settings.modify.system y network-control = yes; checkpoint-rollback = auth_admin_keep
    (contraseña). polkit guarda la autorización para el MISMO proceso, así que crear, ajustar,
    destruir o revertir el checkpoint se hace desde una sola conexión de D-Bus (Gio).
  · `nmcli -g` omite GENERAL.DEVICES si el perfil no está activo: ajustes y dispositivos se leen aparte.

Nada de lo recibido se concatena en un shell: nmcli se llama con argumentos separados y cada valor
se valida antes por su tipo (ipaddress para las IP).
"""
import ipaddress
import json
import os
import subprocess

NMCLI = os.environ.get("SUMI_NMCLI", "nmcli")
EDITABLE_TYPES = ("802-3-ethernet", "802-11-wireless", "dummy")

# propiedad → (campo de nmcli, tipo)
FIELDS = {
    "autoconnect": ("connection.autoconnect", "bool"),
    "priority": ("connection.autoconnect-priority", "int"),
    "metered": ("connection.metered", "metered"),
    "ipv4Method": ("ipv4.method", "method"),
    "addresses": ("ipv4.addresses", "cidrs"),
    "gateway": ("ipv4.gateway", "ip"),
    "dns": ("ipv4.dns", "ips"),
    "ignoreAutoDns": ("ipv4.ignore-auto-dns", "bool"),
}
ORDER = list(FIELDS)
# lo que puede cortar la conexión si el perfil está activo
RISKY = ("ipv4Method", "addresses", "gateway", "dns", "ignoreAutoDns")


class Invalid(ValueError):
    pass


def _ip(v, what):
    try:
        a = ipaddress.IPv4Address(str(v).strip())
    except ValueError:
        raise Invalid("%s is not an IPv4 address" % what)
    if a.is_unspecified or a.is_multicast:
        raise Invalid("%s can't be %s" % (what, a))
    return str(a)


def _cidr(v):
    try:
        i = ipaddress.IPv4Interface(str(v).strip())
    except ValueError:
        raise Invalid("%s is not an address with a prefix (like 192.168.1.20/24)" % v)
    if i.network.prefixlen < 8 or i.network.prefixlen > 32:
        raise Invalid("The prefix of %s must be from 8 to 32" % v)
    if i.network.prefixlen < 31 and i.ip in (i.network.network_address, i.network.broadcast_address):
        raise Invalid("%s is the network or broadcast address" % v)
    if i.ip.is_unspecified or i.ip.is_multicast or i.ip.is_loopback:
        raise Invalid("%s can't be used" % v)
    return "%s/%d" % (i.ip, i.network.prefixlen)


def validate(props, current):
    """Normaliza `props` (sólo las claves de FIELDS) y comprueba el conjunto resultante contra
    `current` (el perfil como está). Devuelve el dict normalizado o lanza Invalid (texto en inglés)."""
    if not isinstance(props, dict) or not props:
        raise Invalid("Nothing to change")
    out = {}
    for k, v in props.items():
        if k not in FIELDS:
            raise Invalid("%s can't be edited here" % k)
        kind = FIELDS[k][1]
        if kind == "bool":
            if not isinstance(v, bool):
                raise Invalid("%s must be on or off" % k)
            out[k] = v
        elif kind == "int":
            if isinstance(v, bool) or not isinstance(v, int) or not -999 <= v <= 999:
                raise Invalid("Priority must be a whole number from -999 to 999")
            out[k] = v
        elif kind == "metered":
            if v not in ("auto", "yes", "no"):
                raise Invalid("Metered must be auto, yes or no")
            out[k] = v
        elif kind == "method":
            if v not in ("auto", "manual"):
                raise Invalid("IPv4 must be automatic or manual")
            out[k] = v
        elif kind == "ip":
            out[k] = "" if v in ("", None) else _ip(v, "The gateway")
        elif kind == "ips":
            if not isinstance(v, list) or len(v) > 3:
                raise Invalid("Up to three DNS servers")
            out[k] = [_ip(x, "DNS server %s" % x) for x in v]
        elif kind == "cidrs":
            if not isinstance(v, list) or len(v) > 4:
                raise Invalid("Up to four addresses")
            out[k] = [_cidr(x) for x in v]
    merged = dict(current, **out)
    if merged.get("ipv4Method") == "auto":
        # automático: sin direcciones ni gateway fijos (NM los sumaría a los de DHCP)
        if out.get("addresses") or out.get("gateway"):
            raise Invalid("Addresses and gateway are only for manual IPv4")
        if out.get("ipv4Method") == "auto":
            if current.get("addresses"):
                out["addresses"] = []
            if current.get("gateway"):
                out["gateway"] = ""
    elif merged.get("ipv4Method") == "manual":
        if not merged.get("addresses"):
            raise Invalid("Manual IPv4 needs at least one address")
        gw = merged.get("gateway") or ""
        if gw and not any(ipaddress.IPv4Address(gw) in ipaddress.IPv4Interface(a).network
                          for a in merged["addresses"]):
            raise Invalid("The gateway %s is outside the addresses' networks" % gw)
    if merged.get("ignoreAutoDns") and not merged.get("dns"):
        raise Invalid("Using only your DNS servers needs at least one")
    # quitar lo que no cambia
    return {k: v for k, v in out.items() if current.get(k) != v}


def nmcli_args(props):
    """[campo, valor, …] para `nmcli connection modify`, en un orden estable."""
    args = []
    for k in ORDER:
        if k not in props:
            continue
        field, kind = FIELDS[k]
        v = props[k]
        if kind == "bool":
            s = "yes" if v else "no"
        elif kind == "metered":
            s = {"auto": "unknown", "yes": "yes", "no": "no"}[v]
        elif kind in ("ips", "cidrs"):
            s = ",".join(v)
        else:
            s = str(v)
        args += [field, s]
    return args


def run(argv, timeout=10):
    try:
        p = subprocess.run([NMCLI] + argv, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr.strip()
    except (OSError, subprocess.TimeoutExpired) as e:
        return 127, "", str(e)


def read_profile(uuid):
    """El perfil con las claves de FIELDS (más id y tipo), o None."""
    fields = ["connection.id", "connection.type"] + [FIELDS[k][0] for k in ORDER]
    rc, out, _ = run(["-g", ",".join(fields), "connection", "show", "uuid", uuid])
    if rc != 0:
        return None
    lines = out.split("\n")
    if len(lines) < len(fields):
        return None
    vals = dict(zip(fields, lines))
    p = {"name": vals["connection.id"].replace("\\:", ":"), "type": vals["connection.type"]}
    for k in ORDER:
        field, kind = FIELDS[k]
        s = vals[field].strip()
        if kind == "bool":
            p[k] = s == "yes"
        elif kind == "int":
            try:
                p[k] = int(s)
            except ValueError:
                p[k] = 0
        elif kind == "metered":
            p[k] = {"yes": "yes", "no": "no"}.get(s, "auto")
        elif kind in ("ips", "cidrs"):
            p[k] = [x.strip() for x in s.split(",") if x.strip()]
        else:
            p[k] = s
    return p


def active_devices(uuid):
    """Las interfaces donde el perfil está activo ahora."""
    rc, out, _ = run(["-t", "-f", "UUID,DEVICE", "connection", "show", "--active"])
    if rc != 0:
        return []
    devs = []
    for line in out.splitlines():
        u, _, d = line.partition(":")
        if u == uuid and d:
            devs.append(d.replace("\\:", ":"))
    return devs


def device_state(iface):
    """Lo que la interfaz tiene de verdad: direcciones, gateway y DNS de IPv4, y su estado."""
    rc, out, _ = run(["-g", "GENERAL.STATE,IP4.ADDRESS,IP4.GATEWAY,IP4.DNS,GENERAL.DBUS-PATH", "device", "show", iface])
    if rc != 0:
        return None
    lines = out.split("\n")
    # los campos multivalor salen con « | »
    get = lambda i: lines[i].strip() if i < len(lines) else ""  # noqa: E731
    return {"state": get(0), "addresses": [x.strip() for x in get(1).split("|") if x.strip()],
            "gateway": get(2), "dns": [x.strip() for x in get(3).split("|") if x.strip()], "path": get(4)}


def modify(uuid, props, temporary):
    argv = ["connection", "modify"] + (["--temporary"] if temporary else []) + ["uuid", uuid] + nmcli_args(props)
    rc, _, err = run(argv)
    return rc == 0, err


def reapply(iface):
    rc, _, err = run(["device", "reapply", iface], timeout=15)
    return rc == 0, err


def matches_device(want, dev):
    """¿La interfaz refleja `want` (el perfil ya fusionado)? Devuelve [lo que no casa]."""
    bad = []
    if dev is None:
        return ["the interface is gone"]
    if want.get("ipv4Method") == "manual":
        have = set(dev["addresses"])
        for a in want.get("addresses", []):
            if a not in have:
                bad.append("address %s missing" % a)
        have_gw = dev["gateway"] if dev["gateway"] not in ("", "--") else ""
        if (want.get("gateway") or "") != have_gw:
            bad.append("gateway is %s" % (have_gw or "none"))
    elif want.get("ipv4Method") == "auto":
        if not dev["addresses"]:
            bad.append("no address from DHCP yet")
    dns = want.get("dns", [])
    if want.get("ignoreAutoDns"):
        if dev["dns"] != dns:
            bad.append("DNS is %s" % (", ".join(dev["dns"]) or "none"))
    else:
        for d in dns:
            if d not in dev["dns"]:
                bad.append("DNS %s missing" % d)
    return bad


def unsaved(uuid):
    """¿El perfil tiene cambios sólo en memoria? (propiedad Unsaved por D-Bus; None si no se sabe)."""
    rc, out, _ = run(["-g", "GENERAL.CON-PATH", "connection", "show", "uuid", uuid])
    path = out.strip()
    if rc != 0 or not path:
        return None
    try:
        p = subprocess.run(["busctl", "get-property", "org.freedesktop.NetworkManager", path,
                            "org.freedesktop.NetworkManager.Settings.Connection", "Unsaved"],
                           capture_output=True, text=True, timeout=5)
        return p.stdout.strip() == "b true"
    except (OSError, subprocess.TimeoutExpired):
        return None


def describe(props):
    """Lo que se cambia, en una línea (inglés: lo enseña la cuenta regresiva)."""
    parts = []
    for k in ORDER:
        if k not in props:
            continue
        v = props[k]
        if k == "autoconnect":
            parts.append("connects automatically" if v else "manual connection")
        elif k == "priority":
            parts.append("priority %d" % v)
        elif k == "metered":
            parts.append({"auto": "metered: automatic", "yes": "metered", "no": "not metered"}[v])
        elif k == "ipv4Method":
            parts.append("IPv4 " + ("automatic" if v == "auto" else "manual"))
        elif k == "addresses":
            parts.append(", ".join(v) if v else "no fixed address")
        elif k == "gateway":
            parts.append("gateway " + (v or "none"))
        elif k == "dns":
            parts.append("DNS " + (", ".join(v) if v else "automatic"))
        elif k == "ignoreAutoDns":
            parts.append("only these DNS" if v else "plus DHCP's DNS")
    return " · ".join(parts)


# ---- el checkpoint, por una sola conexión de D-Bus ---------------------------------------------

class Checkpoint:
    """CheckpointCreate / AdjustRollbackTimeout / Destroy / Rollback desde UNA conexión: polkit
    guarda la autorización (auth_admin_keep) para este proceso, así que sólo se pide una vez."""

    NM = "org.freedesktop.NetworkManager"
    PATH = "/org/freedesktop/NetworkManager"

    def __init__(self):
        import gi
        gi.require_version("Gio", "2.0")
        from gi.repository import Gio, GLib
        self.Gio, self.GLib = Gio, GLib
        self.bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
        self.path = ""

    def _call(self, method, sig, args, timeout_ms=10000):
        v = self.GLib.Variant(sig, args) if sig else None
        flags = self.Gio.DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION
        return self.bus.call_sync(self.NM, self.PATH, self.NM, method, v, None, flags, timeout_ms, None)

    def device_path(self, iface):
        r = self._call("GetDeviceByIpIface", "(s)", (iface,))
        return r.unpack()[0]

    def create(self, dev_paths, timeout_s):
        if not dev_paths:
            # una lista vacía abarca TODOS los dispositivos: nunca
            raise RuntimeError("no devices for the checkpoint")
        # la contraseña la escribe el usuario: hasta 2 min
        r = self._call("CheckpointCreate", "(aouu)", (dev_paths, int(timeout_s), 0), timeout_ms=120000)
        self.path = r.unpack()[0]
        return self.path

    def adjust(self, timeout_s):
        self._call("CheckpointAdjustRollbackTimeout", "(ou)", (self.path, int(timeout_s)))

    def destroy(self):
        self._call("CheckpointDestroy", "(o)", (self.path,))

    def rollback(self):
        r = self._call("CheckpointRollback", "(o)", (self.path,), timeout_ms=30000)
        return {k: int(v) for k, v in r.unpack()[0].items()}


def live_checkpoints():
    """Los checkpoints vivos (leerlos no pide permiso)."""
    try:
        p = subprocess.run(["busctl", "get-property", "--json=short", "org.freedesktop.NetworkManager",
                            "/org/freedesktop/NetworkManager", "org.freedesktop.NetworkManager", "Checkpoints"],
                           capture_output=True, text=True, timeout=5)
        return json.loads(p.stdout).get("data", [])
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None
