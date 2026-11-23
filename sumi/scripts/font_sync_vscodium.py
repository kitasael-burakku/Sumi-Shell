"""T4e · VSCodium: sólo `editor.fontFamily` del settings.json de usuario (perfil por defecto).

  · settings.json es JSONC (comentarios, comas finales): se localiza el tramo exacto del valor con un
    analizador propio y se sustituye SÓLO ese tramo; comentarios, orden, sangrado y el resto no cambian.
  · Del valor (una lista CSS) cambia sólo la PRIMERA familia; las siguientes (fallbacks) se conservan.
  · No se tocan ligaduras, tamaños, `terminal.integrated.fontFamily`, perfiles, workspaces ni overrides
    por lenguaje (`"[python]": {...}`): se detectan y se avisa si van a mandar sobre lo sincronizado.
  · VSCodium vigila settings.json; si está abierto, lo aplica sin reiniciar (no verificado en banco: UNKNOWN).
"""
import json
import os
import re
import shutil

import font_sync_core as core

KEY = "editor.fontFamily"
SLOTS = {"vscodium.editor": {"cls": "code", "label": "VSCodium editor"}}
FORBID = "'\"\\,;{}"


class JsoncError(core.Refused):
    pass


def tokens(text):
    """[(tipo, ini, fin)] sin comentarios ni espacios. tipo: { } [ ] : , str lit."""
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if c in " \t\r\n﻿":
            i += 1
        elif text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j + 1
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            if j < 0:
                raise JsoncError("unterminated comment in settings.json")
            i = j + 2
        elif c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                if text[j] == "\\":
                    j += 1
                elif text[j] == "\n":
                    raise JsoncError("line break inside a string in settings.json")
                j += 1
            if j >= n:
                raise JsoncError("unterminated string in settings.json")
            out.append(("str", i, j + 1))
            i = j + 1
        elif c in "{}[]:,":
            out.append((c, i, i + 1))
            i += 1
        else:
            m = re.compile(r"[-+0-9A-Za-z.]+").match(text, i)
            if not m:
                raise JsoncError("unexpected character %r in settings.json" % c)
            out.append(("lit", i, m.end()))
            i = m.end()
    return out


def members(text):
    """Miembros del objeto de primer nivel: [{key, kStart, vStart, vEnd, comma (índice o None), tok}]."""
    tk = tokens(text)
    if not tk or tk[0][0] != "{":
        raise JsoncError("settings.json isn't a JSON object")
    res, i, depth = [], 1, 0
    while i < len(tk):
        t = tk[i]
        if t[0] == "}":
            if i != len(tk) - 1:
                raise JsoncError("text after the end of settings.json")
            return res, tk[i][1]
        if t[0] == ",":
            i += 1
            continue
        if t[0] != "str" or i + 2 >= len(tk) or tk[i + 1][0] != ":":
            raise JsoncError("settings.json isn't valid JSON(C)")
        key = json.loads(text[t[1]:t[2]])
        j = i + 2
        v0 = tk[j][1]
        depth = 0
        while j < len(tk):
            if tk[j][0] in "{[":
                depth += 1
            elif tk[j][0] in "}]":
                depth -= 1
                if depth < 0:
                    break
            if depth == 0 and (j + 1 >= len(tk) or tk[j + 1][0] in ",}"):
                break
            j += 1
        if depth != 0 or j >= len(tk):
            raise JsoncError("settings.json isn't valid JSON(C)")
        v1 = tk[j][2]
        comma = tk[j + 1][1] if j + 1 < len(tk) and tk[j + 1][0] == "," else None
        res.append({"key": key, "kStart": t[1], "vStart": v0, "vEnd": v1, "comma": comma, "type": tk[i + 2][0]})
        i = j + 1
    raise JsoncError("settings.json isn't closed")


def strict(text):
    """El documento como JSON estricto (sin comentarios ni comas finales), para comprobar que sigue siendo válido."""
    tk = tokens(text)
    parts = []
    for k, (typ, a, b) in enumerate(tk):
        if typ == "," and k + 1 < len(tk) and tk[k + 1][0] in "}]":
            continue
        parts.append(text[a:b])
    return json.loads(" ".join(parts))


def css_first(value):
    """(primera familia sin comillas, resto tal cual desde la primera coma) de una lista CSS."""
    m = re.match(r"^\s*(?:'([^']*)'|\"([^\"]*)\"|([^,]*?))\s*(,.*)?$", value, re.S)
    if not m:
        return value.strip(), ""
    fam = m.group(1) if m.group(1) is not None else m.group(2) if m.group(2) is not None else m.group(3)
    return fam.strip(), m.group(4) or ""


def find_key(text, key=KEY):
    ms, close = members(text)
    hits = [m for m in ms if m["key"] == key]
    if len(hits) > 1:
        raise JsoncError("settings.json sets %s more than once" % key)
    return (hits[0] if hits else None), ms, close


def set_value(text, raw):
    """Texto con `editor.fontFamily` = raw (cadena JSON ya serializada)."""
    hit, ms, close = find_key(text)
    if hit:
        return text[:hit["vStart"]] + raw + text[hit["vEnd"]:]
    # añadir al final del objeto, con el sangrado del primer miembro
    indent = "    "
    if ms:
        line_start = text.rfind("\n", 0, ms[0]["kStart"]) + 1
        lead = text[line_start:ms[0]["kStart"]]
        if lead.strip() == "":
            indent = lead
        last = ms[-1]
        if last["comma"] is not None:          # coma final ya presente
            at = last["comma"] + 1
            return text[:at] + "\n" + indent + json.dumps(KEY) + ": " + raw + "," + text[at:]
        at = last["vEnd"]
        return text[:at] + ",\n" + indent + json.dumps(KEY) + ": " + raw + text[at:]
    return text[:close] + "\n" + indent + json.dumps(KEY) + ": " + raw + "\n" + text[close:]


def remove_key(text, expect_raw):
    """Quita el miembro si su valor es exactamente `expect_raw` (lo que añadió la sincronización)."""
    hit, ms, close = find_key(text)
    if not hit or text[hit["vStart"]:hit["vEnd"]] != expect_raw:
        return None
    idx = ms.index(hit)
    prev = ms[idx - 1] if idx > 0 else None
    # dónde acaba lo anterior: tras la coma del miembro previo, o tras la llave de apertura
    prev_end = prev["comma"] + 1 if prev and prev["comma"] is not None else (
        prev["vEnd"] if prev else tokens(text)[0][1] + 1)
    # nunca llevarse un comentario: entre lo anterior y la clave, y entre el valor y su coma, sólo espacios
    if text[prev_end:hit["kStart"]].strip() or (hit["comma"] is not None
                                                 and text[hit["vEnd"]:hit["comma"]].strip()):
        return None
    if hit["comma"] is not None:
        return text[:prev_end] + text[hit["comma"] + 1:]        # inversa de añadir tras una coma final
    if prev and prev["comma"] is not None:
        return text[:prev["comma"]] + text[hit["vEnd"]:]       # inversa de añadir «,\n  "k": v» al final
    return text[:prev_end] + text[hit["vEnd"]:]


class Adapter:
    id = "vscodium"
    label = "VSCodium"
    slots = SLOTS

    def __init__(self, ctx):
        self.ctx = ctx
        fake = os.environ.get("KT_FONT_SYNC_CODIUM") if core.testing() else None
        self.bin = (fake if fake and os.access(fake, os.X_OK) else None) if fake else shutil.which("codium")
        self.user = os.path.join(ctx.paths.config, "VSCodium", "User")
        self.path = os.path.join(self.user, "settings.json")

    def overrides(self, text):
        """Lo que mandaría sobre el valor sincronizado: perfiles y overrides por lenguaje."""
        notes = []
        try:
            ms, _ = members(text)
        except JsoncError:
            return notes
        for m in ms:
            if m["key"].startswith("[") and m["type"] == "{" and '"%s"' % KEY in text[m["vStart"]:m["vEnd"]]:
                notes.append("The %s override sets its own editor font" % m["key"])
        prof = os.path.join(self.user, "profiles")
        try:
            for d in sorted(os.listdir(prof)):
                p = os.path.join(prof, d, "settings.json")
                try:
                    t = open(p).read()
                    h, _, _ = find_key(t)
                except (OSError, core.Refused):
                    continue
                if h:
                    notes.append("Profile %s sets its own editor.fontFamily (not changed)" % d)
        except OSError:
            pass
        notes.append("Workspace settings (.vscode/settings.json) can override it; they're never changed")
        return notes

    def detect(self):
        if not self.bin:
            return {"id": self.id, "state": "unavailable", "reason": "VSCodium isn't installed"}
        why = core.file_problems(self.ctx.paths, self.path)
        if why:
            return {"id": self.id, "state": "unavailable", "reason": why[0] + (" (open VSCodium once)"
                                                                               if "doesn't exist" in why[0] else "")}
        _, data = core.read_file(self.ctx.paths, self.path)
        try:
            hit, _, _ = find_key(data.decode())
        except core.Refused as e:
            return {"id": self.id, "state": "unavailable", "reason": str(e)}
        cur = json.loads(data.decode()[hit["vStart"]:hit["vEnd"]]) if hit and hit["type"] == "str" else None
        return {"id": self.id, "state": "available", "config": self.path, "value": cur,
                "notes": self.overrides(data.decode())}

    def plan(self, slot, choice):
        base = {"slot": slot, "target": self.id, "label": "VSCodium editor", "restart": "live", "notes": []}
        if not self.bin:
            return dict(base, action="unavailable", reason="VSCodium isn't installed")
        why = core.file_problems(self.ctx.paths, self.path)
        if why:
            return dict(base, action="unavailable" if "doesn't exist" in why[0] else "blocked",
                        reason=why[0] + (" (open VSCodium once)" if "doesn't exist" in why[0] else ""))
        if self.ctx.matugen_owns(self.path):
            return dict(base, action="blocked", reason="a matugen template writes VSCodium's settings.json")
        st, data = core.read_file(self.ctx.paths, self.path)
        text = data.decode()
        try:
            hit, _, _ = find_key(text)
            strict(text)
        except (core.Refused, ValueError) as e:
            return dict(base, action="blocked", reason=str(e) if isinstance(e, core.Refused)
                        else "settings.json isn't valid JSON(C)")
        if hit and hit["type"] != "str":
            return dict(base, action="blocked", reason="editor.fontFamily isn't text in settings.json")
        raw = text[hit["vStart"]:hit["vEnd"]] if hit else None
        value = json.loads(raw) if raw else None
        fam, rest = css_first(value) if value else ("", "")
        base.update(current=fam or None, currentRaw=raw,
                    fingerprint={"sha": core.sha(data), "ino": st.st_ino, "raw": raw},
                    notes=self.overrides(text))
        if fam and choice.is_equivalent(fam, self.ctx.inv):
            return dict(base, action="unchanged", reason="Already %s" % fam)
        if not choice.family:
            return dict(base, action="unavailable", reason=choice.reason)
        if not core.family_ok(choice.family, FORBID):
            return dict(base, action="blocked", reason="«%s» can't be written safely for VSCodium" % choice.family)
        new = "'%s'%s" % (choice.family, rest)
        return dict(base, action="change", proposed=choice.family, proposedRaw=json.dumps(new, ensure_ascii=False),
                    reason=choice.reason or "")

    def apply(self, plans, tx, txdir):
        out = []
        for p in plans:
            st, data = core.read_file(self.ctx.paths, self.path)
            if data is None or core.sha(data) != p["fingerprint"]["sha"]:
                out.append((p, {"result": "changed", "reason": "settings.json changed since the preview"}, None))
                continue
            kept = core.keep_copy(txdir, "VSCodium-settings.json", st, data)
            new = set_value(data.decode(), p["proposedRaw"])
            try:
                strict(new)
            except ValueError:
                out.append((p, {"result": "failed", "reason": "the edit wouldn't be valid JSON(C): nothing written"},
                            None))
                continue
            prev = self.ctx.ledger.entries.get(p["slot"])
            e = {"kind": "jsonc", "path": self.path, "key": KEY, "tx": tx,
                 "beforePresent": prev["beforePresent"] if prev else p["currentRaw"] is not None,
                 "before": prev["before"] if prev else p["currentRaw"], "set": p["proposedRaw"],
                 "family": p["proposed"], "shaAfter": core.sha(new.encode()),
                 # copia exacta de antes: sólo vale mientras el archivo siga siendo lo que escribimos
                 "exact": prev.get("exact") if prev else {"copy": os.path.join(txdir, kept), "sha": core.sha(data)}}
            self.ctx.pending(p["slot"], e)
            core.race("vscodium-before-replace")
            r = core.replace(self.ctx.paths, self.path, st.st_ino, core.sha(data), new.encode())
            if r != "done":
                out.append((p, {"result": "changed" if r == "changed" else "failed",
                                "reason": "settings.json changed while syncing: nothing kept"}, None))
                continue
            _, back = core.read_file(self.ctx.paths, self.path)
            hit, _, _ = find_key(back.decode())
            ok = hit is not None and back.decode()[hit["vStart"]:hit["vEnd"]] == p["proposedRaw"]
            out.append((p, {"result": "applied", "verified": "file"} if ok else
                        {"result": "failed", "reason": "settings.json doesn't read back as written"}, e if ok else None))
        return out

    def original(self, entry):
        return css_first(json.loads(entry["before"]))[0] if entry.get("before") else None

    def classify(self, slot, entry):
        st, data = core.read_file(self.ctx.paths, self.path)
        if data is None:
            return "other"
        try:
            hit, _, _ = find_key(data.decode())
        except core.Refused:
            return "other"
        raw = data.decode()[hit["vStart"]:hit["vEnd"]] if hit else None
        if raw == entry["set"]:
            return "set"
        if raw == entry["before"]:
            return "before"
        return "other"

    def rollback(self, slot, entry):
        c = self.classify(slot, entry)
        if c != "set":
            return c
        st, data = core.read_file(self.ctx.paths, self.path)
        if data is None:
            return "other"
        text = data.decode()
        hit, _, _ = find_key(text)
        if not hit or text[hit["vStart"]:hit["vEnd"]] != entry["set"]:
            return "other"
        ex = entry.get("exact") or {}
        if core.sha(data) == entry.get("shaAfter") and ex.get("copy"):
            try:
                old = open(ex["copy"], "rb").read()
            except OSError:
                old = None
            if old is not None and core.sha(old) == ex.get("sha"):
                r = core.replace(self.ctx.paths, self.path, st.st_ino, core.sha(data), old)
                return "restored" if r == "done" else "other"
        new = set_value(text, entry["before"]) if entry["beforePresent"] else remove_key(text, entry["set"])
        if new is None:
            return "other"
        try:
            strict(new)
        except ValueError:
            return "failed"
        r = core.replace(self.ctx.paths, self.path, st.st_ino, core.sha(data), new.encode())
        return "restored" if r == "done" else "other"
