#!/usr/bin/env python3
"""Sumi Shell — `install.sh migrate identity-v1` en HOMEs temporales (cambio de nombre, 2026-11-07).

Uso: python3 -B tests/install/identity-test.py [nombre…]      (desde la raíz del repo; sin nombres, todos)

Reutiliza el banco de installer-test.py (HOME bajo /tmp, runtime propio, `qs`/`systemctl`/`hyprctl` falsos, /proc falso,
SUMI_INSTALL_TEST=1). El estado «de antes» es SINTÉTICO, con la forma del real (config/state/data, secretos 0600,
calendario SQLite con WAL, registro de fuentes con rutas absolutas, providers.json con ~). Cada escenario comprueba los
EFECTOS: el origen idéntico por sha antes/después, la copia, los modos, las rutas reescritas, lo que NO se escribe.
"""
import hashlib
import importlib.util
import json
import os
import sqlite3
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("installer_test", os.path.join(HERE, "installer-test.py"))
IT = importlib.util.module_from_spec(spec)
spec.loader.exec_module(IT)
Bench, expect = IT.Bench, IT.expect


def tree_sha(root):
    """{rel: (modo, sha)} de un árbol (archivos y directorios), sin seguir enlaces."""
    out = {}
    for d, dirs, files in os.walk(root):
        for n in dirs + files:
            p = os.path.join(d, n)
            st = os.lstat(p)
            rel = os.path.relpath(p, root)
            if os.path.islink(p):
                out[rel] = ("link", os.readlink(p))
            elif os.path.isdir(p):
                out[rel] = (oct(st.st_mode & 0o7777), None)
            else:
                out[rel] = (oct(st.st_mode & 0o7777), hashlib.sha256(open(p, "rb").read()).hexdigest())
    return out


def seed(b):
    """El estado del nombre viejo: config, state y data."""
    cfg, st, data = b.cfg, b.state, os.path.join(b.h, ".local", "share")
    old_cfg, old_st, old_data = (os.path.join(x, "kitasan-shell") for x in (cfg, st, data))
    b.write(".config/kitasan-shell/settings.json", json.dumps({
        "schemaVersion": 4, "theme": {"appearance": {"material": "satin"}},
        "migratedFrom": {"file": "XDG_STATE_HOME/kitasan-shell/settings.json"}}, indent=2) + "\n", 0o600)
    b.write(".config/kitasan-shell/providers.json", json.dumps({
        "version": 1, "theme": {"xsettingsConfig": "~/.config/kitasan-shell/xsettings-managed.conf",
                                "other": "~/.config/kitasan-shell/does-not-exist.conf"}}, indent=2) + "\n")
    b.write(".config/kitasan-shell/xsettings-managed.conf", "Net/ThemeName \"x\"\n", 0o600)
    b.write(".local/state/kitasan-shell/secrets/wallhaven.key", "secret-key\n", 0o600)
    os.chmod(os.path.join(old_st, "secrets"), 0o700)
    tx = ".local/state/kitasan-shell/typography-sync/tx/20261105-210004-d28c/kitty.conf"
    b.write(tx, "font_family Iosevka\n", 0o600)
    b.write(".local/state/kitasan-shell/typography-sync/ledger.json", json.dumps({
        "version": 1, "entries": {"kitty.terminal": {"fragment": os.path.join(cfg, "kitty", "kitasan-shell-fonts.conf"),
                                                     "copy": os.path.join(b.h, tx)}}}, indent=1) + "\n", 0o600)
    b.write(".local/state/kitasan-shell/theme/preset", "gruvbox-dark\n")
    os.makedirs(os.path.join(old_data, "calendar"))
    db = os.path.join(old_data, "calendar", "events.sqlite3")
    c = sqlite3.connect(db)
    c.execute("PRAGMA journal_mode=WAL")
    c.execute("PRAGMA wal_autocheckpoint=0")
    c.execute("CREATE TABLE events (id TEXT PRIMARY KEY, title TEXT)")
    c.executemany("INSERT INTO events VALUES (?, ?)", [("e%d" % i, "event %d" % i) for i in range(50)])
    c.commit()
    # la conexión se queda ABIERTA (sin checkpoint): el -wal tiene los 50 eventos, como lo dejaría un helper que murió
    b.keep_db = c
    snap_wal = os.path.getsize(db + "-wal") > 0
    return {"cfg": old_cfg, "state": old_st, "data": old_data, "wal": snap_wal}


def originals(o):
    return {k: tree_sha(o[k]) for k in ("cfg", "state", "data")}


def new_dirs(b):
    return {"cfg": os.path.join(b.cfg, "sumi-shell"), "state": os.path.join(b.state, "sumi-shell"),
            "data": os.path.join(b.h, ".local", "share", "sumi-shell")}


def s_preview_writes_nothing(b, probs):
    o = seed(b)
    before = b.snap()
    rc, out = b.run("migrate", "identity-v1")
    expect(rc == 0 and "pending" in out, "preview says pending (rc %d): %s" % (rc, out[-300:]), probs)
    expect(b.snap() == before, "preview wrote nothing", probs)
    rc, out = b.run("migrate")
    expect(rc == 0 and "identity-v1" in out and "pending" in out, "the listing shows identity-v1 pending: " + out[-300:],
           probs)


def s_apply_copies_and_keeps_originals(b, probs):
    o = seed(b)
    before = originals(o)
    rc, out = b.run("migrate", "identity-v1", "--apply")
    expect(rc == 0, "apply rc 0: " + out[-400:], probs)
    expect(originals(o) == before, "originals byte- and mode-identical after the copy", probs)
    n = new_dirs(b)
    expect(tree_sha(n["data"]) == before["data"], "data copied exactly (files, modes, content)", probs)
    cfg_new = {k: v for k, v in tree_sha(n["cfg"]).items() if k != "providers.json"}
    expect(cfg_new == {k: v for k, v in before["cfg"].items() if k != "providers.json"},
           "config copied exactly except the rewritten providers.json", probs)
    expect(not any(os.path.exists(os.path.join(p, ".sumi-identity-partial")) for p in n.values()),
           "no partial mark left in the published copies", probs)
    got = tree_sha(n["state"])
    rec = got.pop("identity-migration-v1.json", None)
    expect(rec is not None and rec[0] == "0o600", "record written last, 0600", probs)
    led = "typography-sync/ledger.json"
    ledger_new = json.load(open(os.path.join(n["state"], led)))
    expect(ledger_new["entries"]["kitty.terminal"]["copy"] == os.path.join(
        n["state"], "typography-sync/tx/20261105-210004-d28c/kitty.conf"), "ledger copy path now names sumi-shell", probs)
    expect(ledger_new["entries"]["kitty.terminal"]["fragment"].endswith("kitty/kitasan-shell-fonts.conf"),
           "ledger keeps the kitty fragment name (outside these directories)", probs)
    expect(got.get(led, ("", ""))[0] == "0o600", "rewritten ledger keeps 0600", probs)
    rest = {k: v for k, v in got.items() if k != led}
    want = {k: v for k, v in before["state"].items() if k != led}
    expect(rest == want, "the rest of state copied exactly", probs)
    pj = json.load(open(os.path.join(n["cfg"], "providers.json")))
    expect(pj["theme"]["xsettingsConfig"] == "~/.config/sumi-shell/xsettings-managed.conf",
           "providers.json xsettingsConfig rewritten (target identical in the copy)", probs)
    expect(pj["theme"]["other"] == "~/.config/kitasan-shell/does-not-exist.conf",
           "a path with nothing at either place is left as it is", probs)
    sj = json.load(open(os.path.join(n["cfg"], "settings.json")))
    expect(sj["migratedFrom"]["file"] == "XDG_STATE_HOME/kitasan-shell/settings.json",
           "historical (non-path) strings untouched", probs)
    expect("left ~/.config/kitasan-shell/does-not-exist.conf" in out, "the left path is reported", probs)
    expect(o["wal"], "the seeded calendar really had a non-empty -wal", probs)
    db = os.path.join(n["data"], "calendar", "events.sqlite3")
    import shutil, tempfile
    with tempfile.TemporaryDirectory() as tdir:          # leer una copia: la copia migrada no se abre con SQLite
        for ext in ("", "-wal"):
            if os.path.exists(db + ext):
                shutil.copy2(db + ext, os.path.join(tdir, "e.sqlite3" + ext))
        c = sqlite3.connect(os.path.join(tdir, "e.sqlite3"))
        rows = c.execute("SELECT COUNT(*) FROM events").fetchone()[0]
        c.close()
    expect(rows == 50, "calendar copy has the 50 events (got %s)" % rows, probs)
    rc, out = b.run("migrate", "identity-v1", "--apply")
    expect(rc == 0 and "nothing to do" in out, "second apply: nothing to do: " + out[-200:], probs)


def s_refuses_with_shells_or_helpers(b, probs):
    o = seed(b)
    before = b.snap()
    for what, inst in (("legacy shell", "kitasan"), ("new shell", "sumi")):
        b.spec["instances"] = [{"config_path": os.path.join(b.cfg, "quickshell", inst, "shell.qml"), "pid": 777,
                                "shell_id": "x", "id": "x"}]
        b.save_spec()
        rc, out = b.run("migrate", "identity-v1", "--apply")
        expect(rc != 0 and "a shell is running" in out, "%s running → refused: %s" % (what, out[-200:]), probs)
    b.spec["instances"] = []
    b.save_spec()
    d = os.path.join(b.proc, "31337")
    os.makedirs(d)
    open(os.path.join(d, "cmdline"), "wb").write(
        b"python3\0-B\0" + os.path.join(b.cfg, "quickshell/kitasan/scripts/screen-recorder.py").encode() + b"\0supervise\0")
    rc, out = b.run("migrate", "identity-v1", "--apply")
    expect(rc != 0 and "helper of the shell is still running" in out, "recorder helper alive → refused: " + out[-200:],
           probs)
    expect(b.snap() == before, "nothing written by any refusal", probs)


def s_destination_exists(b, probs):
    seed(b)
    b.write(".config/sumi-shell/settings.json", "{}\n")
    before = b.snap()
    rc, out = b.run("migrate", "identity-v1", "--apply")
    expect(rc != 0 and "conflict" in out, "existing sumi-shell without record → conflict: " + out[-200:], probs)
    expect(b.snap() == before, "conflict wrote nothing", probs)


def s_symlink_refused(b, probs):
    o = seed(b)
    os.symlink("/etc/passwd", os.path.join(o["state"], "link"))
    before = b.snap()
    rc, out = b.run("migrate", "identity-v1", "--apply")
    expect(rc != 0 and "symbolic link" in out, "a link in the old state → refused: " + out[-200:], probs)
    expect(b.snap() == before, "nothing written", probs)


def s_old_installer_refused(b, probs):
    seed(b)
    b.write(".local/state/kitasan-shell/install/manifest.json", "{}\n")
    before = b.snap()
    rc, out = b.run("migrate", "identity-v1", "--apply")
    expect(rc != 0 and "former installer" in out, "old installer manifest → refused: " + out[-200:], probs)
    expect(b.snap() == before, "nothing written", probs)


def s_cut_and_recover(b, probs):
    o = seed(b)
    before = originals(o)
    for fault in ("identity-file:before:KILL", "identity-base-state:after:KILL", "identity-publish-data:before:KILL",
                  "identity-record:before:KILL", "identity-marks:before:KILL"):
        rc, out = b.run("migrate", "identity-v1", "--apply", extra={"SUMI_INSTALL_FAULT": fault})
        expect(rc != 0, "%s: the run was cut (rc %d)" % (fault, rc), probs)
        expect(originals(o) == before, "%s: originals intact" % fault, probs)
        rc, out = b.run("migrate", "identity-v1")
        state = out
        if "partial" in out:
            rc, out = b.run("migrate", "identity-v1", "--recover")
            expect(rc == 0 and "removed" in out, "%s: --recover removes the marked partial copy: %s" % (fault, out[-200:]),
                   probs)
        rc, out = b.run("migrate", "identity-v1")
        expect("conflict" not in out, "%s: never a conflict after a cut of its own: %s" % (fault, out[-200:]), probs)
        rc, out = b.run("migrate", "identity-v1", "--apply")
        expect(rc == 0, "%s: apply after recovery succeeds: %s" % (fault, out[-300:]), probs)
        expect(originals(o) == before, "%s: originals still intact" % fault, probs)
        expect(not any(os.path.exists(os.path.join(p, ".sumi-identity-partial")) for p in new_dirs(b).values()),
               "%s: no mark left afterwards" % fault, probs)
        expect(tree_sha(new_dirs(b)["data"]) == before["data"], "%s: final data copy exact" % fault, probs)
        for k, p in new_dirs(b).items():
            if os.path.isdir(p):
                import shutil
                shutil.rmtree(p)


def s_revert(b, probs):
    o = seed(b)
    before = originals(o)
    rc, out = b.run("migrate", "identity-v1", "--apply")
    n = new_dirs(b)
    open(os.path.join(n["cfg"], "settings.json"), "a").write("\n")
    rc, out = b.run("migrate", "identity-v1", "--revert")
    expect(rc != 0 and "changed since the migration" in out, "revert refuses after a change: " + out[-200:], probs)
    expect(os.path.isdir(n["cfg"]), "nothing removed", probs)
    with open(os.path.join(n["cfg"], "settings.json"), "rb+") as f:
        data = f.read()[:-1]
        f.seek(0)
        f.write(data)
        f.truncate()
    rc, out = b.run("migrate", "identity-v1", "--revert")
    expect(rc == 0, "revert with nothing changed: " + out[-200:], probs)
    expect(not any(os.path.exists(p) for p in n.values()), "the copy is gone", probs)
    expect(originals(o) == before, "originals intact after revert", probs)


def s_not_applicable(b, probs):
    rc, out = b.run("migrate", "identity-v1", "--apply")
    expect(rc == 0 and "no state from Kitasan-Shell" in out, "nothing to migrate: " + out[-200:], probs)


SCENARIOS = [s_preview_writes_nothing, s_apply_copies_and_keeps_originals, s_refuses_with_shells_or_helpers,
             s_destination_exists, s_symlink_refused, s_old_installer_refused, s_cut_and_recover, s_revert,
             s_not_applicable]


def main():
    want = set(sys.argv[1:])
    failed = 0
    for s in SCENARIOS:
        name = s.__name__[2:].replace("_", "-")
        if want and name not in want:
            continue
        b = Bench()
        probs = []
        try:
            s(b, probs)
        except Exception as e:
            probs.append("exception: %r" % e)
        finally:
            if getattr(b, "keep_db", None) is not None:
                b.keep_db.close()
            b.close()
        print("%-45s %s" % (name, "PASS" if not probs else "FAIL"))
        for p in probs:
            print("    · " + p)
        failed += bool(probs)
    print("failed: %d" % failed)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
