#!/usr/bin/env python3
"""T4 · llevar la tipografía de la shell a otras apps, opcional y por destino. Salida: UNA línea JSON.

  font-sync.py detect                         qué hay instalado y qué usa cada app (sólo lectura)
  font-sync.py plan [--targets A,B]           qué cambiaría; `token` resume el plan (sólo lectura)
  font-sync.py apply --expect TOKEN [--targets A,B] [--reload-kitty]
                                              aplica SÓLO si el plan sigue siendo el que se enseñó
  font-sync.py status                         lo gestionado y si sigue en vigor
  font-sync.py rollback (--tx ID | --targets A,B | --all) [--reload-kitty]
  font-sync.py forget --targets A,B           dejar de gestionar sin escribir (lo actual pasa a ser tuyo)
  font-sync.py recover                        terminar una aplicación cortada (diario en el registro)
  font-sync.py uninstall                      deshacer todo lo gestionado y borrar el estado propio

Destinos: gtk.interface gtk.monospace (GTK 3, GSettings) gtk4.interface (gtk-4.0/settings.ini) kitty.terminal
qt6.interface qt6.fixed vscodium.editor.
Zen y Firefox salen en `detect`/`plan` como información; nunca se escriben.

Transacciones POR DESTINO: lo que falla se compensa y lo demás se conserva; cada destino verifica algo más que
la escritura (GSettings releído desde otro proceso, el cargador de kitty, el archivo releído). Volver atrás
nunca pisa un cambio tuyo posterior: si el valor ya no es el sincronizado, se informa como conflicto.
"""
import argparse
import json
import os
import sys
import time
import tomllib

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import font_sync_core as core              # noqa: E402
import font_sync_catalog as catalog        # noqa: E402
import font_sync_browsers as browsers      # noqa: E402

ORDER = ["gtk.interface", "gtk.monospace", "gtk4.interface", "kitty.terminal", "qt6.interface", "qt6.fixed", "vscodium.editor", "qt5.interface", "qt5.fixed"]
SETTING = {"gtk.interface": "gtkInterface", "gtk.monospace": "gtkMonospace", "gtk4.interface": "gtk4Interface",
           "kitty.terminal": "kitty",
           "qt6.interface": "qt6Interface", "qt6.fixed": "qt6Fixed", "vscodium.editor": "vscodium", "qt5.interface": "qt5Interface", "qt5.fixed": "qt5Fixed"}
TREE = os.path.dirname(HERE)


def adapter_classes():
    import font_sync_gtk, font_sync_gtk4, font_sync_kitty, font_sync_qt6ct, font_sync_vscodium, font_sync_qt5ct
    return {"gtk": font_sync_gtk.Adapter, "gtk4": font_sync_gtk4.Adapter, "kitty": font_sync_kitty.Adapter,
            "qt6": font_sync_qt6ct.Adapter, "qt5": font_sync_qt5ct.Adapter,
            "vscodium": font_sync_vscodium.Adapter}


class Ctx:
    def __init__(self, reload_kitty=False):
        self.paths = core.Paths()
        self.ledger = core.Ledger(self.paths).load()
        self.catalog = catalog.Catalog(TREE, self.paths)
        self._inv = None
        self.reload_kitty = reload_kitty
        self.adapters = {k: cls(self) for k, cls in adapter_classes().items()}
        self._matugen = None
        self.dirty = False

    @property
    def inv(self):
        """Inventario de Fontconfig, sólo cuando hace falta (volver atrás no lo necesita)."""
        if self._inv is None:
            self._inv = core.inventory()
        return self._inv

    def adapter(self, slot):
        return self.adapters[slot.split(".")[0]]

    def pending(self, slot, entry):
        """Diario: lo que se va a escribir queda anotado ANTES de escribirlo (recover lo resuelve)."""
        self.ledger.doc.setdefault("pending", {})[slot] = entry
        self.ledger.save()

    def settle(self, slot, entry):
        self.ledger.doc.setdefault("pending", {}).pop(slot, None)
        if entry is None:
            return
        same = entry.get("set") == entry.get("before") and (
            entry.get("kind") in ("qt6ct", "qt5ct", "jsonc") or (entry.get("kind") == "gsettings" and entry.get("beforeUserSet")))
        if same or self.adapter(slot).classify(slot, entry) == "before":
            self.ledger.entries.pop(slot, None)          # vuelve a lo de antes: nada que gestionar
        else:
            self.ledger.entries[slot] = entry

    def gio_sync(self):
        try:
            from gi.repository import Gio
            Gio.Settings.sync()
        except ImportError:
            pass

    def matugen_owns(self, path):
        """¿Alguna plantilla de matugen (la del usuario, la de theme-apps o la propia) escribe en `path`?"""
        if self._matugen is None:
            outs = set()
            cfgs = [os.path.join(TREE, "templates", "matugen-config.toml"),
                    os.path.join(self.paths.config, "sumi-shell", "matugen-apps.toml"),
                    os.path.join(self.paths.config, "matugen", "config.toml")]
            try:
                pj = json.load(open(os.path.join(self.paths.config, "sumi-shell", "providers.json")))
                mc = (pj.get("theme") or {}).get("matugenConfig")
                if isinstance(mc, str):
                    cfgs.append(os.path.expanduser(mc))
            except (OSError, ValueError, AttributeError):
                pass
            for c in cfgs:
                try:
                    doc = tomllib.load(open(c, "rb"))
                except (OSError, tomllib.TOMLDecodeError):
                    continue
                for t in (doc.get("templates") or {}).values():
                    op = t.get("output_path") if isinstance(t, dict) else None
                    if isinstance(op, str):
                        p = op.replace("~", self.paths.home, 1) if op.startswith("~") else op
                        outs.add(os.path.realpath(p))
            self._matugen = outs
        return os.path.realpath(path) in self._matugen


def out(ok, **kw):
    print(json.dumps(dict(kw, ok=ok), ensure_ascii=False, separators=(",", ":")))
    sys.stdout.flush()


def wanted(arg, sync=None):
    """Destinos pedidos: lista explícita, «-» = ninguno (la shell lo pasa con todo apagado), vacío = los
    activados en settings.json."""
    if arg == "-":
        return []
    if arg:
        ts = [t for t in arg.split(",") if t]
        bad = [t for t in ts if t not in ORDER]
        if bad:
            raise core.Refused("unknown target: %s" % ", ".join(bad))
        return [t for t in ORDER if t in ts]
    return [t for t in ORDER if (sync or {}).get(SETTING[t]) is True]


def make_plan(ctx, targets):
    sel, sync, _ = ctx.catalog.selection()
    targets = wanted(targets, sync)
    choices = {c: ctx.catalog.choose(sel, c, ctx.inv) for c in catalog.CLASSES}
    slots = []
    for slot in ORDER:
        # Keep the original seven-slot response for clients unless a new Qt 5 target is requested.
        if slot.startswith("qt5.") and slot not in targets:
            continue
        a = ctx.adapter(slot)
        if slot not in targets:
            slots.append({"slot": slot, "target": a.id, "label": a.slots[slot]["label"], "action": "off",
                          "managed": slot in ctx.ledger.entries})
            continue
        choice = choices[a.slots[slot]["cls"]]
        prev = ctx.ledger.entries.get(slot)
        try:
            # volver a un preset que ya era el tuyo devuelve TUS bytes de antes, no la primera de la lista
            if prev and choice.is_equivalent(a.original(prev) or "", ctx.inv) and a.classify(slot, prev) == "set":
                p = {"slot": slot, "target": a.id, "label": a.slots[slot]["label"], "action": "restore",
                     "current": prev.get("family") or prev.get("set"), "proposed": a.original(prev),
                     "fingerprint": {"entry": core.sha(json.dumps(prev, sort_keys=True).encode())},
                     "reason": "Back to your value from before the sync", "restart": None, "notes": []}
            else:
                p = a.plan(slot, choice)
                if prev and a.classify(slot, prev) == "other":
                    p.setdefault("notes", []).append("You changed it after the last sync")
        except core.Refused as e:
            p = {"slot": slot, "target": a.id, "label": a.slots[slot]["label"], "action": "blocked", "reason": str(e)}
        p["managed"] = slot in ctx.ledger.entries
        if ctx.ledger.doc.get("pending", {}).get(slot):
            p.update(action="blocked", reason="An earlier sync was interrupted: run recover first")
        slots.append(p)
    changes = [s for s in slots if s["action"] in ("change", "restore")]
    token = core.sha(json.dumps([[s["slot"], s.get("current"), s.get("proposed"), s.get("fingerprint"),
                                  s.get("proposedRaw")] for s in changes] + [sel, targets, ctx.reload_kitty],
                                sort_keys=True).encode())[:24]
    info = browsers.detect(ctx, choices)
    return {"selection": sel, "choices": {k: v.as_dict() for k, v in choices.items()}, "slots": slots,
            "token": token, "changes": len(changes), "browsers": info,
            "counts": {k: sum(1 for s in slots if s["action"] == k)
                       for k in ("change", "restore", "unchanged", "unavailable", "blocked", "off")}}


def cmd_detect(ctx, a):
    sel, sync, _ = ctx.catalog.selection()
    choices = {c: ctx.catalog.choose(sel, c, ctx.inv) for c in catalog.CLASSES}
    res = {}
    for k, ad in ctx.adapters.items():
        try:
            res[k] = ad.detect()
        except core.Refused as e:
            res[k] = {"id": k, "state": "unavailable", "reason": str(e)}
    out(True, adapters=res, browsers=browsers.detect(ctx, choices), selection=sel, sync=sync,
        families=len(ctx.inv))


def cmd_plan(ctx, a):
    out(True, **make_plan(ctx, a.targets))


def cmd_apply(ctx, a):
    lock = core.take_lock(ctx.paths)
    try:
        ctx.ledger.load()
        plan = make_plan(ctx, a.targets)
        if plan["token"] != a.expect:
            out(False, error="plan-changed", reason="Something changed since the preview: review it again",
                **plan)
            return
        changes = [s for s in plan["slots"] if s["action"] == "change"]
        restores = [s for s in plan["slots"] if s["action"] == "restore"]
        if not changes and not restores:
            out(True, results=[], tx=None, **plan)
            return
        tx, txdir = core.new_tx(ctx.paths)
        ctx.ledger.note("apply", tx=tx, slots=[s["slot"] for s in changes + restores])
        results = []
        for r in do_rollback(ctx, [s["slot"] for s in restores]):
            lbl = next(s["label"] for s in restores if s["slot"] == r["slot"])
            results.append(dict(r, result="applied" if r["result"] in ("restored", "before") else r["result"],
                                restored=True, label=lbl,
                                family=next(s["proposed"] for s in restores if s["slot"] == r["slot"])))
        # Un «restore» puede haber escrito el MISMO archivo que un «change» de esta transacción (qt6ct: fixed vuelve a
        # tu valor y general cambia; visto en el registro del usuario el 2026-11-05): su huella ya no vale y el change se
        # negaba solo. Se vuelve a planificar sólo esos destinos y se aplica sólo si propone exactamente lo enseñado.
        touched = {s["target"] for s in restores}
        if touched and any(s["target"] in touched for s in changes):
            sel, _sync, _doc = ctx.catalog.selection()
            choices = {c: ctx.catalog.choose(sel, c, ctx.inv) for c in catalog.CLASSES}
            fresh = []
            for s in changes:
                if s["target"] not in touched:
                    fresh.append(s)
                    continue
                ad = ctx.adapter(s["slot"])
                try:
                    p = ad.plan(s["slot"], choices[ad.slots[s["slot"]]["cls"]])
                except core.Refused:
                    p = {}
                if p.get("action") == "change" and p.get("proposed") == s.get("proposed") \
                        and p.get("proposedRaw") == s.get("proposedRaw"):
                    fresh.append(dict(s, fingerprint=p["fingerprint"], currentRaw=p.get("currentRaw"),
                                      current=p.get("current")))
                else:
                    results.append({"slot": s["slot"], "label": s["label"], "family": s.get("proposed"),
                                    "result": "changed", "reason": "Changed since the preview: review again"})
            changes = fresh
        by = {}
        for s in changes:
            by.setdefault(s["target"], []).append(s)
        for target in ["gtk", "gtk4", "kitty", "qt6", "qt5", "vscodium"]:
            if target not in by:
                continue
            ad = ctx.adapters[target]
            try:
                res = ad.apply(by[target], tx, txdir)
            except (core.Refused, OSError) as e:
                res = [(p, {"result": "failed", "reason": str(e)}, None) for p in by[target]]
            for p, r, entry in res:
                if r["result"] != "applied":
                    # el adaptador compensa; si aun así quedó algo suyo, el diario se queda para recover
                    pend = ctx.ledger.doc.get("pending", {}).get(p["slot"])
                    try:
                        left = pend is not None and ctx.adapter(p["slot"]).classify(p["slot"], pend) != "before"
                    except (core.Refused, OSError):
                        left = True
                    if left:
                        r = dict(r, reason=r.get("reason", "") + " · run recover", pending=True)
                        results.append(dict(r, slot=p["slot"], label=p["label"], family=p.get("proposed"),
                                            restart=p.get("restart")))
                        continue
                ctx.settle(p["slot"], entry if r["result"] == "applied" else None)
                results.append(dict(r, slot=p["slot"], label=p["label"], family=p.get("proposed"),
                                    restart=p.get("restart")))
            ctx.ledger.save()
        ctx.ledger.note("applied", tx=tx, results={r["slot"]: r["result"] for r in results})
        ctx.ledger.save()
        out(all(r["result"] == "applied" for r in results), tx=tx, results=results,
            counts={k: sum(1 for r in results if r["result"] == k) for k in ("applied", "failed", "changed")})
    finally:
        os.close(lock)


def status_of(ctx):
    rows = []
    for slot, e in ctx.ledger.entries.items():
        try:
            c = ctx.adapter(slot).classify(slot, e)
        except core.Refused as err:
            c = "unknown:" + str(err)
        row = {"slot": slot, "family": e.get("family") or e.get("set"), "tx": e.get("tx"),
               "state": {"set": "managed", "before": "back-to-before", "other": "changed-by-you",
                         "partial": "incomplete"}.get(c, c)}
        # Configuration inspection is not a measurement of an application's rendered font.
        row["evidence"] = {"configuration": "VERIFIED" if c == "set" else "UNKNOWN",
                           "newProcess": "UNKNOWN", "openProcess": "UNKNOWN", "visual": "UNKNOWN"}
        # ¿la app lo adopta? (hoy, kitty: su cargador dice qué familia usaría de verdad)
        eff = getattr(ctx.adapter(slot), "effective_family", None)
        if c == "set" and eff:
            try:
                row["effective"] = eff()
                row["effectiveScope"] = "kitty-config-loader"
                if core.normal(row["effective"]) != core.normal(row["family"]):
                    row["state"] = "overridden"
            except core.Refused:
                row["effective"] = None
        rows.append(row)
    return rows


def cmd_status(ctx, a):
    txs = sorted({e.get("tx") for e in ctx.ledger.entries.values() if e.get("tx")})
    out(True, managed=status_of(ctx), transactions=txs, last=txs[-1] if txs else None,
        pending=list(ctx.ledger.doc.get("pending", {}).keys()))


def do_rollback(ctx, slots):
    res = []
    for slot in [s for s in ORDER if s in slots]:
        e = ctx.ledger.entries.get(slot)
        if not e:
            continue
        try:
            r = ctx.adapter(slot).rollback(slot, e)
        except (core.Refused, OSError) as err:
            r = "failed:" + str(err)
        if r in ("restored", "before"):
            ctx.ledger.entries.pop(slot, None)
        res.append({"slot": slot, "label": ctx.adapter(slot).slots[slot]["label"], "result": {"other": "conflict"}.get(r, r),
                    "reason": "You changed it after the sync: left as it is" if r == "other" else ""})
        ctx.ledger.save()
    return res


def cmd_rollback(ctx, a):
    lock = core.take_lock(ctx.paths)
    try:
        ctx.ledger.load()
        if a.all:
            slots = list(ctx.ledger.entries)
        elif a.tx:
            slots = [s for s, e in ctx.ledger.entries.items() if e.get("tx") == a.tx]
        else:
            slots = wanted(a.targets) if a.targets else []
        if not slots:
            out(True, results=[], reason="Nothing managed to undo")
            return
        res = do_rollback(ctx, slots)
        ctx.ledger.note("rollback", results={r["slot"]: r["result"] for r in res})
        ctx.ledger.save()
        out(all(r["result"] in ("restored", "before") for r in res), results=res)
    finally:
        os.close(lock)


def cmd_forget(ctx, a):
    lock = core.take_lock(ctx.paths)
    try:
        ctx.ledger.load()
        gone = [s for s in wanted(a.targets) if ctx.ledger.entries.pop(s, None) is not None]
        ctx.ledger.note("forget", slots=gone)
        ctx.ledger.save()
        out(True, forgotten=gone)
    finally:
        os.close(lock)


def cmd_recover(ctx, a):
    lock = core.take_lock(ctx.paths)
    try:
        ctx.ledger.load()
        res = {}
        for slot, e in list(ctx.ledger.doc.get("pending", {}).items()):
            c = ctx.adapter(slot).classify(slot, e)
            if c == "set":
                ctx.ledger.entries[slot] = e
                res[slot] = "kept"
            elif c == "before":
                res[slot] = "nothing-written"
            elif c == "partial":                 # a medias: se deshace lo escrito, no se adopta
                r = ctx.adapter(slot).rollback(slot, e)
                if r not in ("restored", "before"):
                    res[slot] = "conflict"
                    continue
                res[slot] = "undone"
            else:
                res[slot] = "conflict"
                continue
            ctx.ledger.doc["pending"].pop(slot)
        ctx.ledger.note("recover", results=res)
        ctx.ledger.save()
        out("conflict" not in res.values(), results=res)
    finally:
        os.close(lock)


def cmd_uninstall(ctx, a):
    lock = core.take_lock(ctx.paths)
    try:
        ctx.ledger.load()
        if ctx.ledger.doc.get("pending"):
            out(False, error="pending", reason="An interrupted sync must be recovered first")
            return
        res = do_rollback(ctx, list(ctx.ledger.entries))
        left = list(ctx.ledger.entries)
        if left:
            ctx.ledger.note("uninstall-incomplete", left=left)
            ctx.ledger.save()
            out(False, results=res, left=left,
                reason="Some values were changed by you after the sync; they stay and stay recorded")
            return
        # sin nada gestionado: el estado propio (registro y copias) se va
        import shutil
        st = ctx.paths.sync_state
        if os.path.isdir(st) and not os.path.islink(st):
            shutil.rmtree(st)
        out(True, results=res, removed=st)
    finally:
        os.close(lock)


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("detect")
    p = sub.add_parser("plan")
    p.add_argument("--targets", default="")
    p.add_argument("--reload-kitty", action="store_true")
    p = sub.add_parser("apply")
    p.add_argument("--expect", required=True)
    p.add_argument("--targets", default="")
    p.add_argument("--reload-kitty", action="store_true")
    sub.add_parser("status")
    p = sub.add_parser("rollback")
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--tx")
    g.add_argument("--targets")
    g.add_argument("--all", action="store_true")
    p.add_argument("--reload-kitty", action="store_true")
    p = sub.add_parser("forget")
    p.add_argument("--targets", required=True)
    sub.add_parser("recover")
    sub.add_parser("uninstall")
    a = ap.parse_args(argv)
    try:
        ctx = Ctx(reload_kitty=getattr(a, "reload_kitty", False))
        {"detect": cmd_detect, "plan": cmd_plan, "apply": cmd_apply, "status": cmd_status,
         "rollback": cmd_rollback, "forget": cmd_forget, "recover": cmd_recover,
         "uninstall": cmd_uninstall}[a.cmd](ctx, a)
    except core.Refused as e:
        out(False, error="refused", reason=str(e))
    except Exception as e:                       # la shell lee una línea JSON pase lo que pase
        out(False, error="internal", reason="%s: %s" % (type(e).__name__, e))
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
