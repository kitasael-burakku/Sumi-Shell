# Sumi Shell on Arch Linux — local F6g candidate

This package is a local test build, not a published release. Its source URL and
release tag are pending. `sumi/version.json` is the application version.

Pacman owns `/etc/xdg/quickshell/sumi`, the two units under
`/usr/lib/systemd/user`, and the documentation and licenses. The package never
edits a home directory, enables a unit, starts a process, or creates a D-Bus
activation file. No installation hooks restart your shell.

## Before starting

A user copy in `$XDG_CONFIG_HOME/quickshell/sumi` hides the system copy.
User units can also hide the packaged units. Do not install both ways at once.
Use the original user installer's `uninstall` to remove an installation it owns,
after checking the lock chain; keep your settings and state. A manually copied
tree requires a manual, reviewed transition while the shell is stopped.

Start with `qs -c sumi` in an existing Hyprland session. Inspect Settings →
System → Environment. Quickshell needs all imported modules; a version number
alone does not prove that a custom build has them.

For service startup, ensure the user manager has the current Wayland and
Hyprland environment, then explicitly enable `sumi-shell.service`.
The packaged rescue unit requires a working hyprlock configuration.
Read the examples in this directory before adding them to Hyprland/hypridle;
the package does not include them automatically. The hypridle example's DPMS
commands must match your Hyprland configuration dialect.

## Updates and removal

Stop Sumi Shell while unlocked before updating or removing its package.
Pacman replaces individual files; it does not provide the user installer's
atomic update, load verification, settings rollback or lock protection.
Do not treat a package upgrade as a verified live update. A settings migration
happens when the new shell loads; downgrading the package does not undo it.
Keep a backup of your settings before changing versions.

After an update, start the shell while unlocked and verify its load and
Settings → System → Environment. Use pacman to update/remove system files;
`install.sh update` and `uninstall` manage only recorded user installations.

Before removal, check hypridle's lock commands and remove or replace explicit
includes pointing to this package. Arrange another notification server and
polkit agent if needed. Disable the service explicitly. Pacman preserves your
settings, state and caches; it also leaves user-created includes and links.
