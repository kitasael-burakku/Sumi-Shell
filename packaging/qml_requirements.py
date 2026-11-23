"""Inspección estática de los módulos QML de la distribución."""
import os
import re
import shutil


# Imported only by components that load on demand: missing → that feature fails, the shell still starts.
OPTIONAL_MODULES = {"QtMultimedia": "video previews in the wallpaper list"}


def qml_paths(run):
    paths, how = [], []
    for var in ("QML_IMPORT_PATH", "QML2_IMPORT_PATH"):
        for p in (os.environ.get(var) or "").split(":"):
            if p and p not in paths:
                paths.append(p)
                how.append(var)
    extra = os.environ.get("KT_CHECK_QTPATHS")
    dirs = extra.split(":") if extra is not None else ["", "/usr/lib/qt6/bin", "/usr/lib64/qt6/bin",
                                                      "/usr/lib/qt6/libexec", "/usr/libexec/qt6"]
    for d in dirs:
        for tool in ("qtpaths6", "qtpaths"):
            exe = shutil.which(tool) if d == "" else os.path.join(d, tool)
            if not exe or not os.access(exe, os.X_OK):
                continue
            rc, out, err = run([exe, "--query", "QT_INSTALL_QML"])
            p = out.strip()
            if rc == 0 and p and p not in paths:
                paths.append(p)
                how.append(exe)
            if rc == 0 and p:
                return paths, how
    return paths, how

def required_modules(tree):
    """{module: [files]} from the tree's QML: shell.qml and every subdirectory (root-level files are dev probes)."""
    imp = re.compile(r"^\s*import\s+((?:Quickshell|Qt[A-Za-z0-9]*)(?:\.[A-Za-z0-9]+)*)(?=[\s;]|$)", re.M)
    mods = {}
    files = [os.path.join(tree, "shell.qml")]
    for folder, dirs, names in os.walk(tree):
        if folder == tree:
            continue
        files += [os.path.join(folder, n) for n in names if n.endswith(".qml")]
    for f in files:
        try:
            text = open(f, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        for m in imp.finditer(text):
            mods.setdefault(m.group(1), set()).add(os.path.relpath(f, tree))
    return mods

def find_qmldir(paths, mod):
    rel = mod.replace(".", "/")
    for p in paths:
        qd = os.path.join(p, rel, "qmldir")
        try:
            with open(qd) as f:
                if any(l.split()[:2] == ["module", mod] for l in f if l.strip()):
                    return qd
        except OSError:
            continue
    return None

def inspect(tree, run):
    paths, sources = qml_paths(run)
    modules = required_modules(tree)
    unseen = [module for module in ("Quickshell", "QtQuick") if not find_qmldir(paths, module)]
    if unseen:
        return paths, sources, modules, unseen, []
    missing = [module for module in sorted(modules) if not find_qmldir(paths, module)]
    return paths, sources, modules, unseen, missing
