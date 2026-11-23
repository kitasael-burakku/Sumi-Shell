# Optional GTK 3 / X11 theme transport

This adapter publishes the effective GTK theme to an explicitly enabled, Minimal-Shell-owned xsettingsd. It does not change the working Wayland path, start a manager during a theme transition, adopt another manager, or modify personal xsettingsd configuration. It requires patch 03 (desktop synchronization diagnostics) before patch 04.

## Enable deliberately

1. Make xsettingsd available using the distribution's normal packaging, if desired. The shell never installs it. Check that the display does not already have an XSettings manager; the adapter checks again at acquisition.
2. Build the optional guard next to the helper, in the reviewed installation tree:

   ```sh
   cc -shared -fPIC -O2 -Wall -Wextra \
     -o scripts/xsettings-no-replace.so scripts/xsettings-no-replace.c -ldl -lX11
   ```

   This needs a C compiler and Xlib development headers at build time, not on every theme change. Do not install the test binary blindly on another architecture.
3. Add only `theme.xsettingsConfig` to the existing theme provider in providers.json, pointing to a **new, dedicated** file, for example `~/.config/sumi-shell/xsettings-managed.conf`. Preserve all other provider fields. The file must not be a symlink or an existing personal configuration. The helper creates it exclusively, marks ownership, and publishes only Net/ThemeName.
4. With `desktopSync=full`, explicitly invoke `theme-preview.py xsettings-start`, passing the same absolute `KT_XSETTINGS_CONFIG` path. The CLI does not itself load providers.json. DISPLAY and XAUTHORITY, if needed, must be those of the intended graphical session. A later session startup entry may invoke this command once after the display is ready; enabling such an entry is a separate installation choice. Do not run xsettingsd directly with the managed file: that would omit the guard and ownership registration.

The daemon is not tied to a Quickshell reload. It exits when its X display closes or another manager takes its selection. There is no Python daemon, new Quickshell service, polling timer, automatic restart loop, or global LD_PRELOAD/GTK_THEME setting. The guard is passed only to the managed xsettingsd process.

## Ownership and capabilities

`xsettings-start` checks the current selection owner. A foreign owner is left alone. xsettingsd upstream can replace an existing manager, so a preflight alone is insufficient: the optional guard interposes its selection acquisition, checks under XGrabServer, and refuses replacement atomically. No guard means no managed start.

The current implementation supports local X11/XWayland displays, dynamic ELF64 little-endian xsettingsd, libX11, and Linux pidfd support. Other formats, remote displays, unavailable displays, missing dependencies and missing/invalid guards produce a limited-capability result. They do not disable the shell. No executable with setuid/setgid or file capabilities is started. The shell does not use qt5ct/qt6ct or require a particular portal for this transport.

Subsequent reload/stop signals require the recorded PID, process start time, UID, executable and argv to match. pidfd pins the process identity. Publication also requires the registered X owner window/PID. No pkill, killall, personal service restart, or PID obtained from an unknown owner is used as a signal target.

## Theme changes and preferences

ThemePreview passes the optional path to the existing helper. The helper serializes desktop operations with preview transactions, updates only Net/ThemeName, sends HUP to its verified process, and checks the published XSettings value. An unchanged setting causes no rewrite or reload.

`full` enables this transport. `colorScheme` and `off` do not update or start it; an already enabled manager retains its last setting until explicitly stopped or re-enabled. Removing/changing the provider path does not silently stop a process or migrate configuration: stop the old owned manager explicitly before enabling a new path.

The value comes from the GTK theme actually read after GSettings application, not from a hardcoded XSettings mapping. Patch 03 preserves custom GTK themes; this adapter publishes that preserved name. It does not invent a light/dark partner for arbitrary themes. Applications can retain their own explicit variant preferences.

An output collision declared in the Matugen configuration is diagnosed. Arbitrary hooks cannot be statically interpreted; a changed ownership marker, duplicate key, or manually changed Net/ThemeName prevents automatic replacement. Other lines are preserved byte for byte. Cooperating helper operations share a lock; an unrelated program that ignores the lock and edits the managed file simultaneously is not a supported writer. Do not target this dedicated file from a template or another manager.

## Recovery and rollback

`xsettings-status` inspects without starting anything. If a manager disappears, the next synchronization reports limited coverage; `xsettings-start` explicitly recovers it if the display remains free. The daemon's own log and record are under `$XDG_STATE_HOME/sumi-shell/theme/xsettings/<display-hash>/`.

Snapshot/install/restore/recover track the owned theme and the theme installed by the preview. Restore does not overwrite a later user theme or a later publication. A failed restore retains its snapshot. Keep preserves the publication and removes only the completed preview snapshot. The desktop ledger includes an XSettings entry, so the existing Restore desktop settings action can restore the pre-synchronization theme, including after opt-out.

`xsettings-stop` stops only a verified owned process. It removes the dedicated configuration only if it still consists exactly of the generated ownership marker and last owned theme; otherwise it preserves the file. It retires its process record and retains the diagnostic log. It never restores or stops a pre-existing foreign manager, because it never replaced one.

Before removing the adapter code, restore any pending preview/preferences and stop its manager using the still-installed helper. Then remove the provider opt-in and reverse the reviewed code patch. Preserve later user edits; do not restore entire configuration directories.

## GTK limits

The separate GTK 3 preference cleanup must be in effect before starting affected GTK 3 processes. Editing settings.ini does not reset the preference already held by a running process. After that initial clean start, the tested GTK 3 portal follows both theme transitions without restarting the portal or Quickshell.

XSettings changes the theme preference, not arbitrary application CSS. GTK 3 in the audit retained its user CSS across changes; GTK 4/libadwaita Zenity reloaded the generated CSS in the tested versions. Do not promise universal hot palette reload or force applications to restart to simulate it.
