"""T4b′ · GTK 4: SÓLO `gtk-font-name` de gtk-4.0/settings.ini (opcional, apagado por defecto).

Medido (2026-11-05, banco anidado con portal privado): GTK 4.24 sin sandbox toma la fuente de este archivo, no de
GSettings ni del portal. Decisión del usuario: «un adaptador opcional que toque sólo gtk-font-name».

  · Se cambia sólo el VALOR de esa línea de [Settings], y de él sólo la familia (tamaño y estilo por Pango, como en
    GTK 3); el resto del archivo, byte a byte igual. Sin la clave no se inventa un tamaño: se pide fijarla una vez.
  · nwg-look reescribe este archivo al pulsar Apply en él: lo que escriba después es un cambio tuyo (el registro lo
    respeta y el plan lo avisa).
  · Las apps GTK 4 lo leen al arrancar (el banco mide si una abierta cambia).
"""
import ctypes.util
import os
import re
import shutil

import font_sync_core as core
import font_sync_gtk as gtk3

SLOTS = {"gtk4.interface": {"key": "gtk-font-name", "cls": "interface", "label": "GTK 4 interface font (settings.ini)"}}
FORBID = gtk3.FORBID + "\n"


def find(text, key="gtk-font-name"):
    """(línea, prefijo, valor, comillas) de `key` en [Settings]; Refused si aparece más de una vez."""
    lines, sec, hits = text.split("\n"), None, []
    for i, line in enumerate(lines):
        s = line.strip()
        if s.startswith("[") and s.endswith("]"):
            sec = s[1:-1]
            continue
        if sec != "Settings":
            continue
        m = re.match(r"^(\s*%s\s*=\s*)(.*?)\s*$" % re.escape(key), line)
        if m:
            v = m.group(2)
            q = len(v) >= 2 and v[0] == v[-1] == '"'
            hits.append((i, m.group(1), v[1:-1] if q else v, q, line[m.end(2):]))
    if len(hits) > 1:
        raise core.Refused("gtk-4.0/settings.ini sets gtk-font-name more than once")
    return hits[0] if hits else None


def edit(text, value):
    i, pre, _, quoted, post = find(text)
    lines = text.split("\n")
    lines[i] = pre + ('"%s"' % value if quoted else value) + post
    return "\n".join(lines)


class Adapter:
    id = "gtk4"
    label = "GTK 4"
    slots = SLOTS

    def __init__(self, ctx):
        self.ctx = ctx
        self.path = os.path.join(ctx.paths.config, "gtk-4.0", "settings.ini")

    def installed(self):
        return bool(ctypes.util.find_library("gtk-4"))

    def notes(self):
        n = ["GTK 4 apps read it when they start: reopen open ones"]
        if shutil.which("nwg-look") or os.path.isdir(os.path.join(self.ctx.paths.config, "nwg-look")):
            n.append("nwg-look rewrites this file when you press Apply there")
        return n

    def read(self):
        st, data = core.read_file(self.ctx.paths, self.path)
        if data is None:
            raise core.Refused("%s doesn't exist" % self.path)
        hit = find(data.decode())
        return st, data, hit

    def detect(self):
        if not self.installed():
            return {"id": self.id, "state": "unavailable", "reason": "GTK 4 isn't installed"}
        why = core.file_problems(self.ctx.paths, self.path)
        if why:
            return {"id": self.id, "state": "unavailable", "reason": why[0]}
        try:
            _, _, hit = self.read()
        except core.Refused as e:
            return {"id": self.id, "state": "unavailable", "reason": str(e)}
        return {"id": self.id, "state": "available", "config": self.path, "value": hit[2] if hit else None,
                "notes": self.notes()}

    def plan(self, slot, choice):
        base = {"slot": slot, "target": self.id, "label": SLOTS[slot]["label"], "restart": "restart", "notes": []}
        if not self.installed():
            return dict(base, action="unavailable", reason="GTK 4 isn't installed")
        why = core.file_problems(self.ctx.paths, self.path)
        if why:
            missing = "doesn't exist" in why[0]
            return dict(base, action="unavailable" if missing else "blocked", reason=why[0])
        if self.ctx.matugen_owns(self.path):
            return dict(base, action="blocked", reason="a matugen template writes gtk-4.0/settings.ini")
        try:
            st, data, hit = self.read()
        except core.Refused as e:
            return dict(base, action="blocked", reason=str(e))
        if not hit:
            return dict(base, action="blocked", reason="gtk-4.0/settings.ini has no gtk-font-name: choose a font once "
                        "(nwg-look or your GTK settings)")
        cur = hit[2]
        fam = gtk3.Adapter.family_of(cur)
        base.update(current=fam, currentRaw=cur, fingerprint={"sha": core.sha(data), "ino": st.st_ino, "raw": cur},
                    notes=self.notes())
        if choice.is_equivalent(fam, self.ctx.inv):
            return dict(base, action="unchanged", reason="Already %s" % fam)
        if not choice.family:
            return dict(base, action="unavailable", reason=choice.reason)
        if not core.family_ok(choice.family, FORBID + '"'):
            return dict(base, action="blocked", reason="«%s» can't be written safely for GTK 4" % choice.family)
        try:
            new = gtk3.Adapter.with_family(cur, choice.family)
        except core.Refused as e:
            return dict(base, action="blocked", reason=str(e))
        return dict(base, action="change", proposed=choice.family, proposedRaw=new, reason=choice.reason or "",
                    notes=["Size and style kept: %s → %s" % (cur, new)] + self.notes())

    def apply(self, plans, tx, txdir):
        out = []
        for p in plans:
            st, data = core.read_file(self.ctx.paths, self.path)
            if data is None or core.sha(data) != p["fingerprint"]["sha"]:
                out.append((p, {"result": "changed", "reason": "gtk-4.0/settings.ini changed since the preview"}, None))
                continue
            core.keep_copy(txdir, "gtk-4.0-settings.ini", st, data)
            new = edit(data.decode(), p["proposedRaw"])
            prev = self.ctx.ledger.entries.get(p["slot"])
            e = {"kind": "gtk4-ini", "path": self.path, "key": "gtk-font-name", "tx": tx,
                 "before": prev["before"] if prev else p["currentRaw"], "set": p["proposedRaw"], "family": p["proposed"]}
            self.ctx.pending(p["slot"], e)
            core.race("gtk4-before-replace")
            r = core.replace(self.ctx.paths, self.path, st.st_ino, core.sha(data), new.encode())
            if r != "done":
                out.append((p, {"result": "changed" if r == "changed" else "failed",
                                "reason": "gtk-4.0/settings.ini changed while syncing: nothing kept"}, None))
                continue
            _, back = core.read_file(self.ctx.paths, self.path)
            hit = find(back.decode())
            ok = hit is not None and hit[2] == p["proposedRaw"]
            out.append((p, {"result": "applied", "verified": "file"} if ok else
                        {"result": "failed", "reason": "gtk-4.0/settings.ini doesn't read back as written"},
                        e if ok else None))
        return out

    def original(self, entry):
        return gtk3.Adapter.family_of(entry["before"])

    def classify(self, slot, entry):
        try:
            _, _, hit = self.read()
        except core.Refused:
            return "other"
        if hit and hit[2] == entry["set"]:
            return "set"
        if hit and hit[2] == entry["before"]:
            return "before"
        return "other"

    def rollback(self, slot, entry):
        c = self.classify(slot, entry)
        if c != "set":
            return c
        st, data = core.read_file(self.ctx.paths, self.path)
        hit = find(data.decode()) if data is not None else None
        if not hit or hit[2] != entry["set"]:
            return "other"
        r = core.replace(self.ctx.paths, self.path, st.st_ino, core.sha(data), edit(data.decode(), entry["before"]).encode())
        return "restored" if r == "done" else "other"
