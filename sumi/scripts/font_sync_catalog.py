"""T4 · qué familia recibe cada destino según la tipografía elegida en la shell.

Dos clases de destino:
  interface  texto de interfaz (GTK font-name, Qt general)
  code       código y terminal (GTK monospace-font-name, Qt fixed, kitty, el editor): la familia tiene que ser
             monoespaciada o dual en Fontconfig. La de código de la shell puede ser Propo (proporcional) y no se
             impone: cada preset tiene su lista en lib/font-targets.json.

Reglas:
  · Se escribe el primer nombre de la lista que Fontconfig tiene instalado (y, en `code`, monoespaciado).
  · Un valor actual que ya está en la lista del preset (instalado y válido para su clase) es EQUIVALENTE: no se toca.
  · Las familias elegidas a mano en Advanced (uiFamily/monoFamily) mandan sobre la lista; una de código
    proporcional no se lleva a destinos de código (se usa la del preset y se dice por qué).
  · Nunca se escribe un fallback en lugar de lo pedido: si nada de la lista está instalado, el destino queda
    «unavailable» y no cambia.
"""
import json
import os

import font_sync_core as core

CLASSES = ("interface", "code")


class Choice:
    def __init__(self, cls, family, state, reason, equivalents, requested, curated=()):
        self.cls, self.family, self.state, self.reason = cls, family, state, reason
        self.equivalents, self.requested = equivalents, requested
        self.curated = {core.normal(n) for n in curated}

    def is_equivalent(self, current, inv):
        """¿El valor actual del destino ya cumple el preset?"""
        n = core.normal(current)
        if not n or n not in self.equivalents:
            return False
        e = inv.get(n)
        if not e:
            return False                      # en la lista, pero no instalada: la app está usando un fallback
        return self.cls == "interface" or n in self.curated or core.monospaced(e)

    def as_dict(self):
        return {"class": self.cls, "family": self.family, "state": self.state, "reason": self.reason,
                "requested": self.requested}


class Catalog:
    def __init__(self, tree, paths):
        lib = os.path.join(tree, "lib")
        self.fonts = json.load(open(os.path.join(lib, "font-catalog.json")))
        self.targets = json.load(open(os.path.join(lib, "font-targets.json")))
        if self.targets.get("version") != 1:
            raise core.Refused("lib/font-targets.json has an unknown format")
        self.paths = paths

    def selection(self):
        """La elección CONFIRMADA de la shell (settings.json), nunca el borrador del editor."""
        p = os.path.join(self.paths.config, "sumi-shell", "settings.json")
        try:
            doc = json.load(open(p))
        except FileNotFoundError:
            doc = {}
        except (OSError, ValueError):
            raise core.Refused("the shell's settings.json can't be read: nothing is planned")
        t = ((doc.get("theme") or {}).get("typography") or {}) if isinstance(doc, dict) else {}
        sel = {"preset": t.get("preset") or "iosevka", "ui": t.get("uiFamily") or "", "mono": t.get("monoFamily") or ""}
        if not all(isinstance(v, str) for v in sel.values()):
            raise core.Refused("the font selection in settings.json is not valid")
        sync = t.get("sync") if isinstance(t.get("sync"), dict) else {}
        return sel, sync, doc

    def preset(self, pid):
        p = next((x for x in self.fonts.get("presets", []) if x.get("id") == pid), None)
        return p, (self.targets.get("presets") or {}).get(pid)

    def choose(self, sel, cls, inv):
        """Las listas `code` de font-targets.json están curadas como monoespaciadas/duales (comprobado en el
        banco midiendo avances); lo que NO está en ellas (Advanced, alias del catálogo) se comprueba aquí."""
        p, t = self.preset(sel["preset"])
        if p is None or t is None:
            return Choice(cls, None, "unavailable", "Unknown font preset «%s»: nothing is changed" % sel["preset"],
                          set(), [])
        names = list(t.get(cls) or [])
        curated = list(t.get("code") or []) if cls == "code" else []
        # equivalentes: los nombres de ESA clase (los presets como noto-sans o inter usan otra familia para código:
        # mezclar las listas haría que Iosevka contara como «ya es Noto Sans»)
        if cls == "interface":
            equivalents = {core.normal(n) for n in names + list(p.get("ui") or [])}
        else:                                   # alias del catálogo sólo si de verdad son monoespaciados
            equivalents = {core.normal(n) for n in names + list(p.get("mono") or [])}
        override = sel["ui"] if cls == "interface" else sel["mono"]
        note = ""
        if override:
            e = inv.get(core.normal(override))
            if not e:
                return Choice(cls, None, "unavailable", "Your Advanced choice «%s» isn't installed; nothing is "
                              "changed" % override, {core.normal(override)}, [override])
            kind = "mono" if cls == "interface" or core.normal(override) in {core.normal(x) for x in curated} \
                else core.monospace(e)
            if kind == "unknown":
                return Choice(cls, None, "unknown", "Can't confirm your code font «%s» is monospaced; "
                              "choose a verified code family" % override, {core.normal(override)}, [override])
            if kind != "proportional":
                return Choice(cls, e["name"], "available", "Your Advanced choice" + (
                    " (couldn't confirm it's monospaced)" if kind == "unknown" else ""), {core.normal(override)},
                    [override], curated=[override] if kind == "unknown" else ())
            note = "Your code font «%s» is proportional; using the preset's code font. " % override
        for n in names:
            e = inv.get(core.normal(n))
            if e:
                return Choice(cls, e["name"], "available", note.strip(), equivalents, names, curated)
        return Choice(cls, None, "unavailable",
                      note + "None of %s is installed: nothing is changed" % (
                          ", ".join(names[:3]) + ("…" if len(names) > 3 else "")), equivalents, names, curated)
