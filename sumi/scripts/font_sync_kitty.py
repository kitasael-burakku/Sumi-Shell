"""T4c · kitty: un archivo propio incluido al final de kitty.conf.

  · ~/.config/kitty/sumi-shell-fonts.conf (primera línea con la marca «Sumi Shell —») lleva SÓLO
    `font_family`. bold/italic/bold_italic, tamaño, ligaduras, colores, opacidad, cursor y atajos no se tocan.
  · kitty.conf recibe un bloque delimitado al final (en kitty gana la última asignación): `include` del archivo.
    Tu `font_family` sigue en su sitio, tapado mientras el bloque exista; el plan lo dice.
  · El valor efectivo se comprueba con el cargador de configuración del propio kitty (`kitty +runpy`), que
    resuelve include y el orden: escribir no basta.
  · Recargar las ventanas abiertas es opcional (SIGUSR1, como el post_hook de matugen). Medido en el código de
    kitty 0.49.2 (boss.py apply_new_options): la recarga vuelve a cargar las familias Y devuelve cada ventana a
    font_size, así que pierde el zoom de cada ventana. Sin recarga: kitty nuevos al abrirse.
  · Nunca control remoto.
"""
import json
import os
import re
import shutil
import signal
import subprocess

import font_sync_core as core

FRAGMENT = "sumi-shell-fonts.conf"
BLOCK = ("# >>> sumi-shell typography: added by the shell's font sync; undo it from Settings → Theme → "
         "Typography → Other apps\ninclude %s\n# <<< sumi-shell typography\n" % FRAGMENT)
FORBID = "\"'=\\#"
SLOTS = {"kitty.terminal": {"cls": "code", "label": "kitty"}}
# opciones de kitty que llevan valor (kitty --help, 0.49): el resto son interruptores
VALUE_OPTS = {"-c", "--config", "-o", "--override", "--class", "--name", "-T", "--title", "-d", "--directory",
              "--working-directory", "--session", "-w", "--watcher", "--instance-group", "--listen-on", "--start-as",
              "--position", "--logo", "--logo-position", "--logo-alpha", "--os-window-tag", "--grab-keyboard-mode"}
LOADER = ("import json,sys\nfrom kitty.config import load_config\n"
          "o=load_config(sys.argv[-1])\n"
          "f=o.font_family\n"
          "print(json.dumps({'font_family':getattr(f,'created_from_string',None) or str(f),"
          "'font_size':o.font_size}))")


# Sumi Shell (2026-11-07): un kitty que ya gestionaba la shell con su nombre de antes (Kitasan-Shell) se SIGUE gestionando con
# esos nombres (fragmento, bloque de kitty.conf y marca de la primera línea): el registro y «Undo all» los nombran, y
# cambiarlos dejaría un segundo bloque y un fragmento huérfano en la configuración del usuario. Lo nuevo usa los de arriba.
LEGACY_FRAGMENT = "kitasan-shell-fonts.conf"
LEGACY_BLOCK = ("# >>> kitasan-shell typography: added by the shell's font sync; undo it from Settings → Theme → "
                "Typography → Other apps\ninclude %s\n# <<< kitasan-shell typography\n" % LEGACY_FRAGMENT)
LEGACY_MARK = "KitasanShell —"


def fragment_text(family, mark=None):
    return ("# %s typography sync. Generated: changing it stops the shell from managing it.\n"
            "font_family %s\n" % (mark or core.MARK, family))


def legacy_in_use(d):
    """¿Este kitty lo gestionaba ya la shell con los nombres de antes? (el fragmento viejo, o su bloque en kitty.conf)"""
    if os.path.lexists(os.path.join(d, LEGACY_FRAGMENT)):
        return True
    try:
        with open(os.path.join(d, "kitty.conf"), encoding="utf-8", errors="replace") as f:
            return LEGACY_BLOCK in f.read()
    except OSError:
        return False


class Adapter:
    id = "kitty"
    label = "kitty"
    slots = SLOTS

    def __init__(self, ctx):
        self.ctx = ctx
        fake = os.environ.get("KT_FONT_SYNC_KITTY") if core.testing() else None
        self.bin = (fake if os.access(fake, os.X_OK) else None) if fake else shutil.which("kitty")
        # banco: los procesos «kitty» a los que se manda la recarga son un ejecutable falso, nunca el real
        self.match = (os.environ.get("KT_FONT_SYNC_KITTY_MATCH") if core.testing() else None) or self.bin
        d = os.environ.get("KITTY_CONFIG_DIRECTORY") or os.path.join(ctx.paths.config, "kitty")
        self.dir = os.path.abspath(d)
        self.main = os.path.join(self.dir, "kitty.conf")
        legacy = legacy_in_use(self.dir)
        self.fragment, self.block, self.mark = (LEGACY_FRAGMENT, LEGACY_BLOCK, LEGACY_MARK) if legacy else \
            (FRAGMENT, BLOCK, core.MARK)
        self.frag = os.path.join(self.dir, self.fragment)

    def effective(self):
        """font_family efectivo según kitty, o Refused."""
        if not self.bin:
            raise core.Refused("kitty isn't installed")
        env = {k: v for k, v in os.environ.items() if k in ("HOME", "PATH", "LANG", "XDG_CONFIG_HOME",
                                                              "XDG_CACHE_HOME", "XDG_RUNTIME_DIR")}
        try:
            r = subprocess.run([self.bin, "+runpy", LOADER, self.main], capture_output=True, text=True,
                               timeout=20, env=env)
            doc = json.loads(r.stdout.strip().splitlines()[-1])
        except (OSError, subprocess.TimeoutExpired, ValueError, IndexError):
            raise core.Refused("kitty couldn't read its configuration")
        return doc

    def effective_family(self):
        return self.effective()["font_family"]

    def user_lines(self, text):
        """Líneas `font_family` tuyas en kitty.conf, fuera del bloque."""
        body = text.replace(self.block, "")
        return [i + 1 for i, l in enumerate(body.split("\n")) if re.match(r"^\s*font_family\s", l)]

    def detect(self):
        if not self.bin:
            return {"id": self.id, "state": "unavailable", "reason": "kitty isn't installed"}
        why = core.file_problems(self.ctx.paths, self.main)
        if why:
            return {"id": self.id, "state": "unavailable", "reason": why[0]}
        try:
            eff = self.effective()
        except core.Refused as e:
            return {"id": self.id, "state": "unavailable", "reason": str(e)}
        why = []
        return {"id": self.id, "state": "available", "config": self.main, "family": eff["font_family"],
                "fontSize": eff["font_size"], "processes": self.processes(why), "skipped": why,
                "notes": ["New kitty windows use it; open ones only after a reload",
                          "A reload resets every window's zoom to font_size",
                          "Remote control is never enabled"]}

    def plan(self, slot, choice):
        base = {"slot": slot, "target": self.id, "label": "kitty", "restart": "reload", "notes": []}
        if not self.bin:
            return dict(base, action="unavailable", reason="kitty isn't installed")
        why = core.file_problems(self.ctx.paths, self.main) + core.file_problems(self.ctx.paths, self.frag,
                                                                                 must_exist=False)
        if why:
            return dict(base, action="blocked", reason=why[0])
        if self.ctx.matugen_owns(self.frag) or self.ctx.matugen_owns(self.main):
            return dict(base, action="blocked", reason="a matugen template writes this kitty file")
        try:
            eff = self.effective()
            st, main = core.read_file(self.ctx.paths, self.main)
            fst, frag = core.read_file(self.ctx.paths, self.frag)
        except core.Refused as e:
            return dict(base, action="blocked", reason=str(e))
        text = main.decode()
        managed = self.ctx.ledger.entries.get(slot)
        if frag is not None and not managed:
            return dict(base, action="blocked", reason="%s exists without a record of the shell: remove it or keep "
                        "managing kitty by hand" % self.frag)
        if frag is not None and self.mark.encode() not in frag.split(b"\n", 1)[0]:
            return dict(base, action="blocked", reason="%s isn't written by the shell" % self.frag)
        if managed and frag is not None and core.sha(frag) != managed.get("fragmentSha"):
            return dict(base, action="blocked", reason="you changed %s after the last sync" % self.frag)
        if text.count(self.block) > 1:
            return dict(base, action="blocked", reason="kitty.conf has the shell's block more than once")
        cur = eff["font_family"]
        base.update(current=cur, fingerprint={"mainSha": core.sha(main), "mainIno": st.st_ino,
                                              "fragSha": core.sha(frag) if frag is not None else None})
        if choice.is_equivalent(cur, self.ctx.inv):
            return dict(base, action="unchanged", reason="Already %s" % cur)
        if not choice.family:
            return dict(base, action="unavailable", reason=choice.reason)
        if not core.family_ok(choice.family, FORBID) or choice.family.lower() in ("auto", "monospace"):
            return dict(base, action="blocked", reason="«%s» can't be written safely for kitty" % choice.family)
        notes = []
        lines = self.user_lines(text)
        if lines and self.block not in text:
            notes.append("Your font_family (kitty.conf line %s) stays, overridden while the shell manages kitty"
                         % ", ".join(map(str, lines)))
        if self.block in text:
            after = text.split(self.block, 1)[1]
            if re.search(r"(?m)^\s*(font_family|include|globinclude|envinclude)\s", after):
                notes.append("Something after the shell's block in kitty.conf may override it")
        notes.append("Open kitty windows: %s" % ("reloaded (each window's zoom resets to font_size)"
                                                   if self.ctx.reload_kitty else "unchanged until kitty reloads"))
        return dict(base, action="change", proposed=choice.family, reason=choice.reason or "", notes=notes)

    def _restore(self, st, main, frag_state):
        """Compensación: devolver kitty.conf y el fragmento a lo de antes, si siguen siendo lo nuestro."""
        cur_st, cur = core.read_file(self.ctx.paths, self.main)
        if cur is not None and cur != main:
            core.replace(self.ctx.paths, self.main, cur_st.st_ino, core.sha(cur), main)
        fst, frag = core.read_file(self.ctx.paths, self.frag)
        if frag_state is None and frag is not None:
            core.remove(self.ctx.paths, self.frag, core.sha(frag))
        elif frag_state is not None and frag is not None and frag != frag_state:
            core.replace(self.ctx.paths, self.frag, fst.st_ino, core.sha(frag), frag_state)

    def apply(self, plans, tx, txdir):
        out = []
        for p in plans:
            st, main = core.read_file(self.ctx.paths, self.main)
            fst, frag = core.read_file(self.ctx.paths, self.frag)
            fp = p["fingerprint"]
            if core.sha(main) != fp["mainSha"] or (core.sha(frag) if frag is not None else None) != fp["fragSha"]:
                out.append((p, {"result": "changed", "reason": "kitty's files changed since the preview"}, None))
                continue
            core.keep_copy(txdir, "kitty.conf", st, main)
            if frag is not None:
                core.keep_copy(txdir, self.fragment, fst, frag)
            prev = self.ctx.ledger.entries.get(p["slot"])
            new_frag = fragment_text(p["proposed"], self.mark).encode()
            text = main.decode()
            added_nl = False
            if self.block in text:
                new_main = main
            else:
                added_nl = bool(text) and not text.endswith("\n")
                new_main = (text + ("\n" if added_nl else "") + self.block).encode()
            entry = {"kind": "kitty", "main": self.main, "fragment": self.frag, "tx": tx,
                     "before": prev["before"] if prev else p["current"],
                     # el bloque puede venir ya en tu kitty.conf (p. ej. restaurado desde dotfiles): deshacer lo deja
                     "beforeHadBlock": prev["beforeHadBlock"] if prev else self.block in text,
                     "addedNewline": prev["addedNewline"] if prev else added_nl,
                     "set": p["proposed"], "fragmentSha": core.sha(new_frag)}
            self.ctx.pending(p["slot"], entry)
            r1 = core.create(self.ctx.paths, self.frag, new_frag) if frag is None else \
                core.replace(self.ctx.paths, self.frag, fst.st_ino, core.sha(frag), new_frag)
            r2 = "done"
            if r1 == "done" and new_main != main:
                core.race("kitty-before-main")
                r2 = core.replace(self.ctx.paths, self.main, st.st_ino, core.sha(main), new_main)
            if r1 != "done" or r2 != "done":
                self._restore(st, main, frag)
                out.append((p, {"result": "changed" if "changed" in (r1, r2) else "failed",
                                "reason": "kitty's files changed while syncing: nothing kept"}, None))
                continue
            try:
                eff = self.effective()["font_family"]
            except core.Refused as e:
                eff = None
            if eff != p["proposed"]:
                self._restore(st, main, frag)
                out.append((p, {"result": "failed", "reason": "kitty would still use %r: something in your "
                                "configuration overrides the shell's file; nothing kept" % eff}, None))
                continue
            res = {"result": "applied", "verified": "kitty-config", "effective": eff}
            if self.ctx.reload_kitty:
                res["reloaded"] = self.reload()
                res["note"] = "Each reloaded window's zoom went back to font_size"
            out.append((p, res, entry))
        return out

    def original(self, entry):
        return entry["before"]

    def classify(self, slot, entry):
        """'set' fragmento nuestro + bloque · 'partial' fragmento sin bloque (corte a mitad) · 'before' · 'other'."""
        fst, frag = core.read_file(self.ctx.paths, self.frag)
        st, main = core.read_file(self.ctx.paths, self.main)
        has_block = main is not None and self.block.encode() in main
        if frag is not None and core.sha(frag) == entry["fragmentSha"]:
            return "set" if has_block else "partial"
        if frag is None and (not has_block or entry.get("beforeHadBlock")):
            return "before"
        return "other"

    def rollback(self, slot, entry):
        c = self.classify(slot, entry)
        if c not in ("set", "partial"):
            return c
        st, main = core.read_file(self.ctx.paths, self.main)
        if main is not None and not entry.get("beforeHadBlock"):
            text = main.decode()
            if text.count(self.block) == 1:
                full = ("\n" + self.block) if entry.get("addedNewline") and ("\n" + self.block) in text else self.block
                if core.replace(self.ctx.paths, self.main, st.st_ino, core.sha(main),
                                text.replace(full, "", 1).encode()) != "done":
                    return "other"
        r = core.remove(self.ctx.paths, self.frag, entry["fragmentSha"])
        if r not in ("done", "absent"):
            return "other"
        if self.ctx.reload_kitty:
            self.reload()
        return "restored"

    # -- recarga opcional --
    def reads_this_config(self, pid, argv):
        """¿Ese kitty lee ESTE kitty.conf? Por su entorno (KITTY_CONFIG_DIRECTORY, XDG_CONFIG_HOME, HOME) y su
        --config. Un kitty de otro HOME o con otra config no se recarga: no leería el fragmento (y en un banco
        sería el kitty REAL del usuario)."""
        try:
            raw = open("/proc/%d/environ" % pid, "rb").read().split(b"\0")
        except OSError:
            return False
        env = {}
        for kv in raw:
            k, _, v = kv.partition(b"=")
            env[k.decode("utf-8", "replace")] = v.decode("utf-8", "replace")
        args = [x.decode("utf-8", "replace") for x in argv[1:] if x]
        # sólo las opciones de KITTY: acaban en el primer argumento posicional (el programa, p. ej. `sh -c …`)
        i = 0
        while i < len(args):
            x = args[i]
            if x == "--" or not x.startswith("-"):
                break
            name, eq, val = x.partition("=")
            if name in ("-c", "--config"):
                if not eq:
                    if i + 1 >= len(args):
                        return False
                    val = args[i + 1]
                return os.path.realpath(os.path.expanduser(val)) == os.path.realpath(self.main)
            i += 1 if eq or name not in VALUE_OPTS else 2
        home = env.get("HOME") or ""
        d = env.get("KITTY_CONFIG_DIRECTORY") or os.path.join(env.get("XDG_CONFIG_HOME") or
                                                             os.path.join(home, ".config"), "kitty")
        return bool(home or env.get("KITTY_CONFIG_DIRECTORY")) and os.path.realpath(d) == os.path.realpath(self.dir)

    def processes(self, why=None):
        """kitty de este usuario con interfaz (no `kitty +…`/`kitty @…`), por su ejecutable real, que leen ESTA
        configuración. `why` (lista) recoge por qué se descartó cada candidato con el mismo nombre."""
        if not self.match:
            return []
        want = os.path.realpath(self.match)
        allow = None
        spec = os.environ.get("KT_FONT_SYNC_KITTY_ALLOW") if core.testing() else None
        if spec:                                  # banco: además, sólo los PID de esta lista
            try:
                allow = {int(x) for x in open(spec).read().split() if x.isdigit()}
            except OSError:
                allow = set()
        out = []
        for pid in filter(str.isdigit, os.listdir("/proc")):
            try:
                if os.stat("/proc/" + pid).st_uid != os.getuid():
                    continue
                exe = os.path.realpath("/proc/%s/exe" % pid)
                argv = open("/proc/%s/cmdline" % pid, "rb").read().split(b"\0")
            except OSError:
                continue
            named = os.path.basename(exe) == os.path.basename(want)
            if exe != want:
                if named and why is not None:
                    why.append({"pid": int(pid), "why": "other executable " + exe})
                continue
            a1 = argv[1].decode("utf-8", "replace") if len(argv) > 1 else ""
            if a1[:1] in ("+", "@") and a1 not in ("+open",):
                continue
            if allow is not None and int(pid) not in allow:
                if why is not None:
                    why.append({"pid": int(pid), "why": "not in the bank's list"})
                continue
            if not self.reads_this_config(int(pid), argv):
                if why is not None:
                    why.append({"pid": int(pid), "why": "reads another configuration"})
                continue
            out.append(int(pid))
        return out

    def reload(self):
        n = 0
        for pid in self.processes():
            try:
                fd = os.pidfd_open(pid)
            except OSError:
                continue
            try:
                if os.path.realpath("/proc/%d/exe" % pid) == os.path.realpath(self.match):
                    signal.pidfd_send_signal(fd, signal.SIGUSR1)
                    n += 1
            except OSError:
                pass
            finally:
                os.close(fd)
        return n
