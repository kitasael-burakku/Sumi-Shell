#!/usr/bin/env bash
# ============================================================================
#  install.sh — Sumi Shell's installer (portability F6c–F6f, 2026-10-14).
#
#    ./install.sh check [--json] [--tree DIR] [--install [--no-units | --enable]]
#    ./install.sh install [--no-units] [--enable] [--dry-run]
#    ./install.sh uninstall [--keep-modified] [--purge [--yes]] [--dry-run]
#    ./install.sh recover [--apply [--reload | --restart]]   after an interrupted run
#    ./install.sh status
#    ./install.sh update [--apply [--reload | --restart] [--accept-api N]
#                         [--accept-settings-migration] [--downgrade] [--replace-modified]
#                        | --finish (--reload|--restart) | --verify
#                        | --rollback [--reload | --restart]]                    (F6f)
#    ./install.sh migrate [ID [--apply | --revert | --recover]]                             (F6f)
#    ./install.sh hyprland [--apply --reload | --revert --reload | --verify]   (F6e)
#    ./install.sh hypridle [--apply [--replace-lock-cmd] [--replace-before-sleep-cmd]
#                           [--inhibit-sleep 3] [--restart] | --revert [--restart]]
#    ./install.sh theme-apps [APP… [--apply | --revert] | --verify]           (static palettes F-e)
#
#  install/uninstall/recover/hyprland/hypridle work in your home only (see
#  packaging/INSTALL.md). update, migrate, hyprland and hypridle without
#  --apply/--revert/--finish/--rollback only show what they would do.
#
#  `check` is READ-ONLY: it describes this machine (dependencies, versions,
#  Quickshell's QML modules, which copies of the shell exist and which one runs,
#  the systemd units, notifications, polkit, legacy state) and never installs,
#  starts, stops, enables or repairs anything.
#
#  Exit status: 0 = no errors / done · 1 = errors found, refused or partial ·
#  2 = the tool itself failed or was called wrongly · 3 = interrupted (recover).
#
#  Comentarios en español, textos en inglés (regla del proyecto). El trabajo lo
#  hace packaging/check.py; aquí sólo se comprueba lo que él necesita para
#  correr (bash y Python ≥ 3.11), porque sin Python no hay informe posible y
#  eso también es un problema que contar, no un fallo del comprobador.
# ============================================================================
set -u

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
PY_MIN_MAJOR=3
PY_MIN_MINOR=11

usage() {
    cat <<'EOF'
Usage: ./install.sh --version
       ./install.sh check [--json] [--tree DIR] [--install [--no-units | --enable]]
       ./install.sh install [--no-units] [--enable] [--dry-run]
       ./install.sh uninstall [--keep-modified] [--purge [--yes]] [--dry-run]
       ./install.sh recover [--apply [--reload | --restart]]
       ./install.sh status
       ./install.sh update [--apply [--reload | --restart] [--accept-api N]
                           [--accept-settings-migration] [--downgrade] [--replace-modified]
                           | --finish (--reload | --restart) | --verify
                           | --rollback [--reload | --restart]]
       ./install.sh migrate [ID [--apply | --revert | --recover]]
       ./install.sh hyprland [--apply --reload | --revert --reload | --verify]
       ./install.sh hypridle [--apply [--replace-lock-cmd] [--replace-before-sleep-cmd]
                             [--inhibit-sleep 3] [--restart] | --revert [--restart]]
       ./install.sh theme-apps [APP… [--apply | --revert] | --verify]
             APP: kitty gtk3 gtk4 qt5 qt6 hyprland

  check      read-only report: what Sumi Shell needs, what this machine has
             and what would get in the way. Nothing is changed.
  install    copy the shell into ~/.config/quickshell/sumi and its units into
             ~/.config/systemd/user (refuses to replace anything it didn't create)
  uninstall  remove only what install created and can prove; keeps your data
  recover    finish or undo an interrupted install/uninstall/update
  status     what is installed, what runs and whether something is pending
  update     replace the installed shell with this version, check the running
             shell and go back automatically if it doesn't pass (preview first)
  migrate    list or run the explicit conversions of older state files
  hyprland   add/remove the shortcuts and the lock options in your Hyprland config
  hypridle   make hypridle lock with the shell (only the keys you allow)
  theme-apps give other apps the shell's colours (kitty, GTK, Qt, the Hyprland
             border), kept in step with the theme; without your own matugen setup

Exit status: 0 done, 1 refused/errors/partial, 2 the tool failed, 3 interrupted.
EOF
}

cmd=${1:-}
[ $# -gt 0 ] && shift
case "$cmd" in
    check) ;;
    -h|--help|help) usage; exit 0 ;;
    -V|--version)
        # La versión de ESTA distribución, de su única fuente (sumi/version.json); sin python, para que funcione siempre
        vj="$HERE/sumi/version.json"
        v=$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$vj" 2>/dev/null | head -n 1)
        a=$(sed -n 's/^[[:space:]]*"apiVersion"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$vj" 2>/dev/null | head -n 1)
        [ -n "$v" ] || { echo "install.sh: can't read the version from $vj" >&2; exit 2; }
        echo "Sumi Shell $v (API ${a:-?})"
        exit 0 ;;
    install|uninstall|recover|status|hyprland|hypridle|update|migrate|theme-apps) ;;
    *) usage >&2; exit 2 ;;
esac

tree="$HERE/sumi"
json=0
args=()
# Las opciones de `check` se leen aquí; las del instalador las lee installer.py (le llegan intactas).
while [ "$cmd" = check ] && [ $# -gt 0 ]; do
    case "$1" in
        --json) json=1; args+=("--json") ;;
        --install|--no-units|--enable) args+=("$1") ;;
        --tree) [ $# -ge 2 ] || { echo "install.sh: --tree needs a directory" >&2; exit 2; }
                tree=$2; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "install.sh: unknown option '$1'" >&2; usage >&2; exit 2 ;;
    esac
    shift
done
[ -f "$tree/shell.qml" ] || { echo "install.sh: not a Sumi Shell tree: $tree" >&2; exit 2; }
[ -f "$HERE/packaging/check.py" ] || { echo "install.sh: packaging/check.py is missing next to install.sh" >&2; exit 2; }
[ -f "$HERE/packaging/installer.py" ] || { echo "install.sh: packaging/installer.py is missing next to install.sh" >&2; exit 2; }

# Sin Python adecuado, el informe lo da bash: un error contado, con su arreglo.
python_problem() {   # python_problem <título> <causa>
    if [ "$json" = 1 ]; then
        printf '{"format":"sumi-check","version":1,"tree":"%s","counts":{"error":1,"warning":0,"info":0},"exit":1,' "$tree"
        printf '"findings":[{"level":"error","id":"python.missing","title":"%s","cause":"%s",' "$1" "$2"
        printf '"fix":"Install Python %s.%s or newer.","evidence":""}]}\n' "$PY_MIN_MAJOR" "$PY_MIN_MINOR"
    else
        printf 'Errors\n  ERROR python.missing — %s\n        why: %s\n        fix: Install Python %s.%s or newer.\n\n' \
            "$1" "$2" "$PY_MIN_MAJOR" "$PY_MIN_MINOR"
        printf 'Summary: 1 error (the other checks need Python and were not run)\n'
    fi
    exit 1
}

if ! command -v python3 >/dev/null 2>&1; then
    python_problem "Python 3 is not installed" \
        "The shell's helpers (system monitor, settings, theme, capabilities) and this check are Python."
fi
if ! python3 -c "import sys; sys.exit(0 if sys.version_info >= ($PY_MIN_MAJOR, $PY_MIN_MINOR) else 1)" 2>/dev/null; then
    found=$(python3 -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null || echo unknown)
    python_problem "Python $found is older than $PY_MIN_MAJOR.$PY_MIN_MINOR" \
        "The shell needs tomllib (Python $PY_MIN_MAJOR.$PY_MIN_MINOR) for its theme helpers."
fi

if [ "$cmd" != check ]; then
    exec python3 -B "$HERE/packaging/installer.py" "$cmd" "$@"
fi

# -B: no escribir bytecode (el árbol puede ser de sólo lectura y el informe no escribe nada)
exec python3 -B "$HERE/packaging/check.py" --tree "$tree" "${args[@]}"
