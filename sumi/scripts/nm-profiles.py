#!/usr/bin/env python3
"""Perfiles guardados de NetworkManager (Settings → System → Network; lectura 14A, edición 14D).

    nm-profiles.py read
    nm-profiles.py apply <uuid> <props JSON>     guardar un cambio que NO puede cortar la conexión

Lee con libnm (gi) lo editable —autoconnect, prioridad, metered, IPv4 (método, direcciones,
gateway, DNS, ignore-auto-dns)— y el método IPv6, y dónde está activo cada perfil.

`apply` (14D): valida con scripts/nm_edit.py, escribe con `nmcli connection modify` (conserva los
secretos: medido) y relee. Se niega a lo que puede cortar una conexión ACTIVA (DNS e IPv4): eso va
por sumi-guard (checkpoint y cuenta regresiva). Devuelve lo de antes para *Undo*. En un perfil
activo lo guardado vale la próxima vez que conecte (no se reaplica: no se toca lo que está en uso). **Nunca pide secretos**: libnm no los trae si no se llama a get_secrets, y aquí no se
llama. Tampoco se imprime ningún campo de seguridad.

Además, la capacidad de checkpoints (API de rollback de NetworkManager) y lo que polkit
respondería por ella y por modificar perfiles del sistema: «yes» (sin preguntar), «auth» (con
contraseña) o «no». Medido el 2026-09-28: checkpoint-rollback = auth_admin_keep aunque se esté en
wheel; settings.modify.system = yes (regla de CachyOS para wheel en consola local).

Salida: JSON en stdout; error → {"error": …} y código 1.
"""
import sys
sys.dont_write_bytecode = True   # 2026-11-07: sin __pycache__ en el árbol de la shell (desinstalar lo dejaba a medias)
import json
import sys

try:
    import gi
    gi.require_version("NM", "1.0")
    from gi.repository import Gio, NM
except (ImportError, ValueError) as e:  # sin libnm no hay nada que leer
    json.dump({"error": "libnm is not available: %s" % e}, sys.stdout)
    sys.exit(1)

# los tipos que se pueden editar (14D); el resto se enseña, sin edición
EDITABLE = ("802-3-ethernet", "802-11-wireless", "dummy")
SKIP = ("loopback",)


def permissions():
    """GetPermissions de NetworkManager por D-Bus: {acción: yes|auth|no}. libnm los carga de forma
    asíncrona y con el cliente síncrono salen «unknown» (medido), así que se piden aquí."""
    try:
        bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
        r = bus.call_sync("org.freedesktop.NetworkManager", "/org/freedesktop/NetworkManager",
                          "org.freedesktop.NetworkManager", "GetPermissions", None, None,
                          Gio.DBusCallFlags.NONE, 3000, None)
        return dict(r.unpack()[0])
    except Exception:  # noqa: BLE001 — sin respuesta: desconocido
        return {}


def perm(perms, action):
    return perms.get("org.freedesktop.NetworkManager." + action, "unknown")


def ip4(conn):
    s = conn.get_setting_ip4_config()
    if s is None:
        return None
    return {
        "method": s.get_method() or "",
        "addresses": ["%s/%d" % (a.get_address(), a.get_prefix()) for a in
                      (s.get_address(i) for i in range(s.get_num_addresses()))],
        "gateway": s.get_gateway() or "",
        "dns": [s.get_dns(i) for i in range(s.get_num_dns())],
        "ignoreAutoDns": bool(s.get_ignore_auto_dns()),
    }


def read():
    try:
        client = NM.Client.new(None)
    except Exception as e:  # noqa: BLE001 — NM caído o sin bus
        return {"error": "NetworkManager is not answering: %s" % e}
    active = {}
    for ac in client.get_active_connections() or []:
        devs = [d.get_iface() for d in (ac.get_devices() or [])]
        active[ac.get_uuid()] = {"devices": devs, "state": int(ac.get_state())}
    profiles = []
    for c in client.get_connections() or []:
        sc = c.get_setting_connection()
        if sc is None or sc.get_connection_type() in SKIP:
            continue
        t = sc.get_connection_type()
        s6 = c.get_setting_ip6_config()
        a = active.get(sc.get_uuid())
        profiles.append({
            "name": sc.get_id(),
            "uuid": sc.get_uuid(),
            "type": t,
            "iface": sc.get_interface_name() or "",
            "editable": t in EDITABLE,
            # perfil de un usuario (permissions) frente a uno del sistema: pide otra acción de polkit
            "owned": sc.get_num_permissions() > 0,
            "autoconnect": bool(sc.get_autoconnect()),
            "priority": int(sc.get_autoconnect_priority()),
            # el ajuste del perfil: sí, no, o que lo decida NetworkManager (unknown → auto)
            "metered": {NM.Metered.YES: "yes", NM.Metered.NO: "no"}.get(sc.get_metered(), "auto"),
            "ipv4": ip4(c),
            "ipv6Method": s6.get_method() if s6 is not None else "",
            "active": a is not None,
            "devices": a["devices"] if a else [],
        })
    profiles.sort(key=lambda p: (not p["active"], p["type"], p["name"].lower()))
    perms = permissions()
    ver = client.get_version() or ""
    try:
        checkpoints = [cp.get_path() for cp in (client.get_checkpoints() or [])]
    except Exception:  # noqa: BLE001
        checkpoints = None
    return {
        "version": ver,
        "running": bool(client.get_nm_running()),
        "profiles": profiles,
        "checkpoints": {
            "supported": checkpoints is not None and hasattr(client, "checkpoint_create"),
            "live": checkpoints or [],
            "permission": perm(perms, "checkpoint-rollback"),
        },
        "modifySystem": perm(perms, "settings.modify.system"),
        "modifyOwn": perm(perms, "settings.modify.own"),
    }


def apply(uuid, props_text):
    sys.path.insert(0, __import__("os").path.dirname(__import__("os").path.abspath(__file__)))
    import nm_edit as ne
    import re
    if not re.match(r"^[0-9a-fA-F-]{36}$", uuid):
        return {"error": "bad profile id"}
    before = ne.read_profile(uuid)
    if before is None:
        return {"error": "That network profile does not exist"}
    if before["type"] not in ne.EDITABLE_TYPES:
        return {"error": "This kind of connection can't be edited here"}
    try:
        props = ne.validate(json.loads(props_text), before)
    except ValueError as e:
        return {"error": str(e) if isinstance(e, ne.Invalid) else "bad request"}
    if not props:
        return {"error": "Nothing to change"}
    devs = ne.active_devices(uuid)
    if devs and any(k in ne.RISKY for k in props):
        return {"error": "This change can cut the connection · it needs a test", "needsTest": True}
    ok, err = ne.modify(uuid, props, temporary=False)
    after = ne.read_profile(uuid)
    wrong = [k for k in props if after is None or after.get(k) != props[k]]
    if not ok or wrong:
        return {"error": "NetworkManager did not keep it: " + (err or ", ".join(wrong))[:160]}
    return {"ok": True, "uuid": uuid, "name": before["name"], "props": props,
            # lo de antes, SÓLO de lo cambiado: es lo que aplica Undo
            "undo": {k: before[k] for k in props}, "active": bool(devs),
            "detail": ne.describe(props)}


def main(argv):
    if len(argv) == 4 and argv[1] == "apply":
        res = apply(argv[2], argv[3])
        json.dump(res, sys.stdout, ensure_ascii=False)
        sys.stdout.write("\n")
        return 1 if "error" in res else 0
    if len(argv) != 2 or argv[1] != "read":
        print("usage: nm-profiles.py read | apply <uuid> <props JSON>", file=sys.stderr)
        return 2
    res = read()
    json.dump(res, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return 1 if "error" in res else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
