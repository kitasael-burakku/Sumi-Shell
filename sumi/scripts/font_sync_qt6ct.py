"""QFont text adapter: Qt 6 by qt6ct; reused by the separate optional Qt 5 adapter.

  · Sólo el PRIMER campo de la cadena QFont (la familia). Tamaño, peso, estilo y los demás campos se conservan
    byte a byte; la línea se edita en su sitio, el resto del archivo no cambia.
  · Sólo si las apps Qt 6 de esta sesión usan qt6ct (QT_QPA_PLATFORMTHEME=qt6ct). Qt 5 usa el adaptador opcional font_sync_qt5ct.
  · No se inventa un valor: si qt6ct aún no tiene esa fuente, se pide elegirla una vez en qt6ct.
  · qt6ct vigila su archivo y aplica el cambio a las apps Qt 6 abiertas; la propia shell también usa qt6ct, pero
    su texto lleva familia propia (Typography): sólo lo que no la fija sigue a qt6ct.
  · matugen/theme-apps tocan [Appearance] (paleta); aquí sólo [Fonts]: no se cruzan.
"""
import os
import re

import font_sync_core as core

SLOTS = {
    "qt6.interface": {"key": "general", "cls": "interface", "label": "Qt 6 interface font (qt6ct)"},
    "qt6.fixed": {"key": "fixed", "cls": "code", "label": "Qt 6 fixed font (qt6ct)"},
}
FORBID = ",\"\\@"
QFONT_REST = re.compile(r"^-?[0-9.]+,-?[0-9]+,[0-9]+,[0-9]+(,.*)?$")


def find(text, key):
    """(índice de línea, prefijo, valor crudo, final) de `key` en [Fonts], o None. Varias = ambiguo (Refused)."""
    lines = text.split("\n")
    sec, hits = None, []
    for i, line in enumerate(lines):
        s = line.strip()
        if s.startswith("[") and s.endswith("]"):
            sec = s[1:-1]
            continue
        if sec != "Fonts":
            continue
        m = re.match(r"^(\s*%s\s*=\s*)(.*?)(\s*)$" % re.escape(key), line)
        if m:
            hits.append((i, m.group(1), m.group(2), m.group(3)))
    if len(hits) > 1:
        raise core.Refused("Qt font config sets [Fonts] %s more than once" % key)
    return hits[0] if hits else None


def split_value(raw):
    """(familia, resto) de un valor QFont entre comillas; Refused si el formato no es el conocido."""
    if raw.startswith("@"):
        raise core.Refused("Qt stores this font in a binary format this version doesn't edit")
    if not (len(raw) >= 2 and raw[0] == raw[-1] == '"'):
        raise core.Refused("Qt's font value isn't in the expected quoted form")
    inner = raw[1:-1]
    if "\\" in inner or '"' in inner:
        raise core.Refused("Qt's font value has escapes this version doesn't edit")
    fam, sep, rest = inner.partition(",")
    if not sep or not fam or not QFONT_REST.match(rest):
        raise core.Refused("Qt's font value isn't a QFont description")
    return fam, rest


class Adapter:
    id = "qt6"
    label = "Qt 6 (qt6ct)"
    tool = "qt6ct"
    slots = SLOTS

    def __init__(self, ctx):
        self.ctx = ctx
        self.path = os.path.join(ctx.paths.config, self.tool, self.tool + ".conf")

    def in_use(self):
        pt = os.environ.get("QT_QPA_PLATFORMTHEME", "")
        return pt == "qt6ct", pt

    def detect(self):
        ok, pt = self.in_use()
        if not ok:
            return {"id": self.id, "state": "unavailable",
                    "reason": "%s is not confirmed here (QT_QPA_PLATFORMTHEME: «%s»)" % (self.label, pt)}
        why = core.file_problems(self.ctx.paths, self.path)
        if why:
            return {"id": self.id, "state": "unavailable", "reason": why[0]}
        st, data = core.read_file(self.ctx.paths, self.path)
        vals = {}
        for slot, s in self.slots.items():
            h = find(data.decode(), s["key"])
            vals[slot] = h[2] if h else None
        return {"id": self.id, "state": "available", "config": self.path, "values": vals,
                "notes": ["Open Qt 6 apps that use qt6ct follow it after a few seconds",
                          "The shell itself uses qt6ct, but its text sets its own fonts",
                          "Apps with their own fonts can override this configuration"]}

    def plan(self, slot, choice):
        s = self.slots[slot]
        base = {"slot": slot, "target": self.id, "label": s["label"], "restart": "live", "notes": []}
        ok, pt = self.in_use()
        if not ok:
            return dict(base, action="unavailable",
                        reason="%s is not confirmed here (QT_QPA_PLATFORMTHEME: «%s»)" % (self.label, pt))
        why = core.file_problems(self.ctx.paths, self.path)
        if why:
            return dict(base, action="blocked" if "doesn't exist" not in why[0] else "unavailable",
                        reason=why[0] + (" (open %s once and press OK)" % self.tool if "doesn't exist" in why[0] else ""))
        if self.ctx.matugen_owns(self.path):
            return dict(base, action="blocked", reason="a matugen template writes Qt font config")
        st, data = core.read_file(self.ctx.paths, self.path)
        try:
            hit = find(data.decode(), s["key"])
            if not hit:
                return dict(base, action="blocked", reason="%s has no %s font yet: choose one once in %s"
                            % (self.tool, s["key"], self.tool))
            fam, rest = split_value(hit[2])
        except core.Refused as e:
            return dict(base, action="blocked", reason=str(e))
        base.update(current=fam, currentRaw=hit[2], fingerprint={"sha": core.sha(data), "ino": st.st_ino,
                                                                 "raw": hit[2]})
        if choice.is_equivalent(fam, self.ctx.inv):
            return dict(base, action="unchanged", reason="Already %s" % fam)
        if not choice.family:
            return dict(base, action="unavailable", reason=choice.reason)
        if not core.family_ok(choice.family, FORBID):
            return dict(base, action="blocked", reason="«%s» can't be written safely for Qt" % choice.family)
        return dict(base, action="change", proposed=choice.family, proposedRaw='"%s,%s"' % (choice.family, rest),
                    reason=choice.reason or "", notes=["Size, weight and the other font fields kept"])

    @staticmethod
    def edit(text, key, raw):
        hit = find(text, key)
        lines = text.split("\n")
        i, pre, _, post = hit
        lines[i] = pre + raw + post
        return "\n".join(lines)

    def apply(self, plans, tx, txdir):
        """Las dos claves del mismo archivo en UNA sustitución atómica."""
        if not plans:
            return []
        st, data = core.read_file(self.ctx.paths, self.path)
        if data is None or any(core.sha(data) != p["fingerprint"]["sha"] for p in plans):
            return [(p, {"result": "changed", "reason": "Qt font config changed since the preview"}, None) for p in plans]
        core.keep_copy(txdir, self.tool + ".conf", st, data)
        text = data.decode()
        entries = []
        for p in plans:
            text = self.edit(text, self.slots[p["slot"]]["key"], p["proposedRaw"])
            prev = self.ctx.ledger.entries.get(p["slot"])
            e = {"kind": self.tool, "path": self.path, "key": self.slots[p["slot"]]["key"], "tx": tx,
                 "before": prev["before"] if prev else p["currentRaw"], "set": p["proposedRaw"], "family": p["proposed"]}
            self.ctx.pending(p["slot"], e)
            entries.append(e)
        core.race(self.tool + "-before-replace")
        r = core.replace(self.ctx.paths, self.path, st.st_ino, core.sha(data), text.encode())
        if r != "done":
            return [(p, {"result": "changed" if r == "changed" else "failed",
                         "reason": "Qt font config changed while syncing: nothing kept"}, None) for p in plans]
        _, back = core.read_file(self.ctx.paths, self.path)
        out = []
        for p, e in zip(plans, entries):
            h = find(back.decode(), e["key"])
            ok = h is not None and h[2] == p["proposedRaw"]
            out.append((p, {"result": "applied", "verified": "file"} if ok else
                        {"result": "failed", "reason": "Qt font config doesn't read back as written"}, e if ok else None))
        return out

    def original(self, entry):
        try:
            return split_value(entry["before"])[0]
        except core.Refused:
            return None

    def classify(self, slot, entry):
        st, data = core.read_file(self.ctx.paths, self.path)
        if data is None:
            return "other"
        try:
            h = find(data.decode(), entry["key"])
        except core.Refused:
            return "other"
        if h and h[2] == entry["set"]:
            return "set"
        if h and h[2] == entry["before"]:
            return "before"
        return "other"

    def rollback(self, slot, entry):
        c = self.classify(slot, entry)
        if c != "set":
            return c
        st, data = core.read_file(self.ctx.paths, self.path)
        # Classify and read can observe different versions. Verify the key in the exact CAS snapshot.
        hit = find(data.decode(), entry["key"]) if data is not None else None
        if not hit or hit[2] != entry["set"]:
            return "other"
        new = self.edit(data.decode(), entry["key"], entry["before"]).encode()
        r = core.replace(self.ctx.paths, self.path, st.st_ino, core.sha(data), new)
        return "restored" if r == "done" else "other"
