# User installation without a systemd service manager

This path is for Hyprland sessions with a working session bus and login1
(for example elogind). It does not install a supervisor or a rescue unit. Run
`./install.sh check` first; the report distinguishes a confirmed absent user
manager from an unreachable bus. Python's `dbus` module is needed for the
login1 inhibitor helper. Keep `hyprlock` and its PAM service working before
using Sumi Shell's Lock.

## Install and start

```sh
./install.sh install --no-units --dry-run
./install.sh install --no-units
./install.sh status
```

The installer records its tree in manifest format 3 and creates no systemd
unit or enable link. Add one line to your existing Hyprland startup config:

```ini
exec-once = qs -c sumi --no-duplicate
```

For D-Bus activation after login, export the compositor's environment to the
session bus at startup, before the first notification. Use the values from that
session; do not paste a socket name from another login:

```ini
exec-once = dbus-update-activation-environment WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE XDG_CURRENT_DESKTOP XDG_SESSION_TYPE
```

The shell's own `--no-duplicate` guard prevents a second bar when D-Bus also
starts it. Neither line is written by the installer. Check what is loaded in
Hyprland, not just what is on disk.

## Notifications (opt-in)

Start the shell once so it writes `settings.json`, then stop it **while
unlocked**. Make sure no other process owns `org.freedesktop.Notifications`.
From the installed tree:

```sh
scripts/notif-server direct-shell
scripts/notif-server direct-status
notify-send 'Sumi Shell activation check'
```

`direct-shell` writes the setting before it creates an `Exec=...qs -c sumi
--no-duplicate` D-Bus activation and reloads the bus. A notification with the
shell stopped should start it. The script refuses an existing activation from
another service, an unknown bus, or a running shell. It does not take over
another server. The activation file stays in the user's XDG data directory;
the installer does not own it and will refuse uninstall until it is removed:

```sh
# Stop the shell while unlocked first.
scripts/notif-server direct-off
```

`direct-off` removes only the exact activation that `direct-shell` created,
then disables the setting. With no other notification server, senders get an
error. The original `notif-server shell|off` commands are for a managed
systemd installation; they restart its unit.

## Lock and recovery

The initial lock request still uses `sumi-lock`: if shell IPC fails, it
starts `hyprlock`. With `--no-units`, **a shell that dies after it has already
acquired the session lock has no automatic `OnFailure=` rescue**. Set up
hypridle's `lock_cmd` and `before_sleep_cmd` only after `install.sh hypridle`
shows a safe plan; it will not replace another lock command without your
explicit option. Keep `hyprlock` available and test its PAM authentication.

If a dead shell leaves Hyprland on its lock-dead screen, switch to a TTY and
log in as the same user. Determine the Wayland socket and Hyprland instance
for **that** graphical session under `$XDG_RUNTIME_DIR`, then run
`sumi-lock rescue` from the installed tree with `WAYLAND_DISPLAY` and
`HYPRLAND_INSTANCE_SIGNATURE` exported. This checks whether Hyprland is still
locked and starts `hyprlock` only when no locker holds it. Authenticate in
hyprlock, then inspect why the shell died before starting it again. If the
session or socket cannot be identified unambiguously, do not guess another
user's instance. The manual tty2 rescue, hyprlock and PAM unlock passed in an
isolated Arch/KVM guest with the shell running outside its unit. Artix with
elogind is still a separate acceptance step.

## Update and remove

Stop the exec-once shell while unlocked. Preview and apply an offline update:

```sh
./install.sh update
./install.sh update --apply
# Start qs -c sumi --no-duplicate manually, or at the next login.
./install.sh update --verify
```

Without a managed unit, an update of a running shell and `--reload`/`--restart`
are refused. The offline swap is recorded as `installed-unverified` until the
new instance passes verification. Use `update --rollback` while the shell is
stopped if the new build cannot run. Follow `recover` if an operation is
interrupted; the manifest records its transaction.

Before `uninstall`, remove notification activation with `direct-off`, undo any
installed Hyprland/hypridle integration, remove your `exec-once` line, and
stop the shell while unlocked. `uninstall --dry-run` reports what it can prove
and what still blocks removal. The installer preserves foreign files and
modified user data.
