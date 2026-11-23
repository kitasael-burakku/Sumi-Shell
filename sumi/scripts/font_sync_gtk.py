"""T4b · GTK: org.gnome.desktop.interface font-name y monospace-font-name (GSettings).

Medido (2026-11-05): en Wayland GTK 3 lee GSettings (también en vivo), no gtk-3.0/settings.ini. GTK 4.24 sin
sandbox NO: toma gtk-4.0/settings.ini y, sin él, «Adwaita Sans 11»; ni GSettings ni el portal Settings (sólo con
GDK_DEBUG=portals), medido en el banco anidado con portal privado. Esto cubre GTK 3. settings.ini (lo reescribe
nwg-look) y gtkrc no se tocan: llevar la fuente a GTK 4 queda pendiente de decisión.

Sólo cambia la FAMILIA: tamaño y estilo de la descripción Pango se conservan (Pango.FontDescription, nunca
texto concatenado). Un valor predeterminado (sin fijar por el usuario) vuelve a ser predeterminado al deshacer.

XSettings (apps GTK por X11): NO se gestiona. El archivo de xsettingsd lo escribe theme_xsettings.py con una
sola clave (Net/ThemeName) y lo reescribe entero; añadir Gtk/FontName exige que ese dueño admita varias
claves. Queda documentado como incompatibilidad y esta capacidad se informa, sin escribir.
"""
import subprocess
import sys

import font_sync_core as core

SCHEMA = "org.gnome.desktop.interface"
SLOTS = {
    "gtk.interface": {"key": "font-name", "cls": "interface", "label": "GTK 3 interface font"},
    "gtk.monospace": {"key": "monospace-font-name", "cls": "code", "label": "GTK 3 monospace font"},
}
FORBID = ",\"\\"   # Pango separa familias con comas


def _gi():
    try:
        import gi
        gi.require_version("Gio", "2.0")
        gi.require_version("Pango", "1.0")
        from gi.repository import Gio, Pango
        return Gio, Pango
    except (ImportError, ValueError) as e:
        raise core.Refused("python-gobject (gi) with Gio and Pango isn't available: %s" % e)


class Adapter:
    id = "gtk"
    label = "GTK 3 and 4"
    slots = SLOTS

    def __init__(self, ctx):
        self.ctx = ctx
        self._settings = None

    # -- acceso --
    def settings(self):
        if self._settings is None:
            Gio, _ = _gi()
            src = Gio.SettingsSchemaSource.get_default()
            schema = src.lookup(SCHEMA, True) if src else None
            if schema is None:
                raise core.Refused("the GSettings schema %s isn't installed (gsettings-desktop-schemas)" % SCHEMA)
            for s in SLOTS.values():
                if not schema.has_key(s["key"]):
                    raise core.Refused("%s has no key %s" % (SCHEMA, s["key"]))
            backend = type(Gio.SettingsBackend.get_default()).__name__
            if "Memory" in backend or "Null" in backend:
                raise core.Refused("GSettings has no persistent storage here (%s backend): changes wouldn't be kept"
                                   % backend)
            self.backend = backend
            self._settings = Gio.Settings.new(SCHEMA)
        return self._settings

    def read(self, key):
        """(valor, ¿fijado por el usuario?) leído de nuevo del almacén."""
        s = self.settings()
        return s.get_string(key), s.get_user_value(key) is not None

    def readback(self, key):
        """Lectura desde OTRO proceso (Gio nuevo), para no fiarse de la caché de este. No depende del CLI gsettings."""
        code = ("import sys,gi\ngi.require_version('Gio','2.0')\nfrom gi.repository import Gio\n"
                "print(Gio.Settings.new(sys.argv[1]).get_string(sys.argv[2]))")
        try:
            r = subprocess.run([sys.executable, "-I", "-c", code, SCHEMA, key], capture_output=True, text=True,
                               timeout=15)
        except (OSError, subprocess.TimeoutExpired):
            return None
        return r.stdout.rstrip("\n") if r.returncode == 0 else None

    @staticmethod
    def family_of(value):
        _, Pango = _gi()
        d = Pango.FontDescription.from_string(value or "")
        fam = d.get_family() or ""
        return fam.split(",")[0].strip()

    @staticmethod
    def with_family(value, family):
        """La misma descripción con otra familia; Refused si el resultado no conserva tamaño y estilo."""
        _, Pango = _gi()
        d = Pango.FontDescription.from_string(value)
        size, absolute = d.get_size(), d.get_size_is_absolute()
        if not d.get_family() or size <= 0:
            raise core.Refused("«%s» has no family or size to keep" % value)
        style, weight, stretch, variant = d.get_style(), d.get_weight(), d.get_stretch(), d.get_variant()
        d.set_family(family)
        out = d.to_string()
        back = Pango.FontDescription.from_string(out)
        if (back.get_family() != family or back.get_size() != size or back.get_size_is_absolute() != absolute
                or back.get_style() != style or back.get_weight() != weight or back.get_stretch() != stretch
                or back.get_variant() != variant):
            raise core.Refused("Pango can't express «%s» with the family «%s» unchanged" % (value, family))
        return out

    # -- interfaz común --
    def detect(self):
        try:
            self.settings()
        except core.Refused as e:
            return {"id": self.id, "state": "unavailable", "reason": str(e)}
        info = {"id": self.id, "state": "available", "backend": self.backend,
                "values": {k: self.read(s["key"])[0] for k, s in SLOTS.items()},
                "xsettings": "not-managed",
                "notes": ["GTK 3 apps follow it, also the ones already open",
                          "GTK 4 apps read gtk-4.0/settings.ini instead: that's the separate GTK 4 switch",
                          "Apps with their own font setting (or a GTK theme that sets one) keep theirs",
                          "X11 (XWayland) GTK apps read XSettings, which the shell doesn't manage for fonts"]}
        return info

    def plan(self, slot, choice):
        s = SLOTS[slot]
        base = {"slot": slot, "target": self.id, "label": s["label"], "restart": "live", "notes": []}
        try:
            cur, user_set = self.read(s["key"])
        except core.Refused as e:
            return dict(base, action="unavailable", reason=str(e))
        fam = self.family_of(cur)
        base.update(current=fam, currentRaw=cur, fingerprint={"value": cur, "userSet": user_set})
        if choice.is_equivalent(fam, self.ctx.inv):
            return dict(base, action="unchanged", reason="Already %s" % fam)
        if not choice.family:
            return dict(base, action="unavailable", reason=choice.reason)
        if not core.family_ok(choice.family, FORBID):
            return dict(base, action="blocked", reason="«%s» can't be written safely for GTK" % choice.family)
        try:
            new = self.with_family(cur, choice.family)
        except core.Refused as e:
            return dict(base, action="blocked", reason=str(e))
        return dict(base, action="change", proposed=choice.family, proposedRaw=new,
                    reason=choice.reason or "", notes=["Size and style kept: %s → %s" % (cur, new),
                                                       "GTK 3 apps only: GTK 4 has its own switch (settings.ini)"])

    def apply(self, plans, tx, txdir):
        out = []
        for p in plans:
            key = SLOTS[p["slot"]]["key"]
            cur, user_set = self.read(key)
            if cur != p["fingerprint"]["value"]:
                out.append((p, {"result": "changed", "reason": "Changed since the preview: review again"}, None))
                continue
            prev = self.ctx.ledger.entries.get(p["slot"])
            entry = {"kind": "gsettings", "schema": SCHEMA, "key": key, "tx": tx,
                     "before": prev["before"] if prev else cur,
                     "beforeUserSet": prev["beforeUserSet"] if prev else user_set,
                     "set": p["proposedRaw"], "family": p["proposed"]}
            self.ctx.pending(p["slot"], entry)
            s = self.settings()
            core.race("gsettings-before-set")
            ok = s.set_string(key, p["proposedRaw"])
            self.ctx.gio_sync()
            core.race("gsettings-after-set")
            back = self.readback(key)
            if ok and back == p["proposedRaw"]:
                out.append((p, {"result": "applied", "verified": "stored", "readback": back}, entry))
            else:
                # compensar: sólo si sigue siendo lo nuestro
                if self.read(key)[0] == p["proposedRaw"]:
                    if user_set:
                        s.set_string(key, cur)
                    else:
                        s.reset(key)
                    self.ctx.gio_sync()
                out.append((p, {"result": "failed", "reason": "GSettings didn't keep the value (read back %r)" % back},
                            None))
        return out

    def original(self, entry):
        return self.family_of(entry["before"])

    def classify(self, slot, entry):
        """'set' (sigue lo nuestro) · 'before' (ya es lo de antes) · 'other' (cambio ajeno)."""
        cur, user_set = self.read(entry["key"])
        if cur == entry["set"]:
            return "set"
        if cur == entry["before"] and user_set == entry["beforeUserSet"]:
            return "before"
        if cur == entry["before"] and not entry["beforeUserSet"]:
            return "before"
        return "other"

    def rollback(self, slot, entry):
        c = self.classify(slot, entry)
        if c != "set":
            return c
        s = self.settings()
        if entry["beforeUserSet"]:
            s.set_string(entry["key"], entry["before"])
        else:
            s.reset(entry["key"])
        self.ctx.gio_sync()
        cur, user_set = self.read(entry["key"])
        return "restored" if cur == entry["before"] and (user_set or not entry["beforeUserSet"]) else "failed"
