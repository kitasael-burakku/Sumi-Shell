# Installing Sumi Shell in your home

```sh
./install.sh check                          # read-only: what this machine has and what would get in the way
./install.sh install --dry-run              # what install would do; nothing is written
./install.sh install [--no-units] [--enable]
./install.sh status
./install.sh uninstall [--keep-modified] [--purge [--yes]] [--dry-run]
./install.sh recover [--apply [--reload | --restart]]   # after an interrupted run
./install.sh update                         # preview: what an update to this version would do; nothing is written
./install.sh update --apply [--reload | --restart] [--accept-api N] [--accept-settings-migration]
                            [--downgrade] [--replace-modified]
./install.sh update --finish (--reload | --restart) | --verify | --rollback [--reload | --restart]
./install.sh migrate [ID [--apply | --revert]]
./install.sh hyprland [--apply --reload | --revert --reload | --verify]
./install.sh hypridle [--apply [--replace-lock-cmd] [--replace-before-sleep-cmd] [--inhibit-sleep 3] [--restart]
                       | --revert [--restart]]
```

Exit status: `0` done (or nothing to do) · `1` refused, or finished with items left for you · `2` the installer
itself failed or was called wrongly · `3` interrupted: run `recover`.

## What install does

- Copies the shell into `$XDG_CONFIG_HOME/quickshell/sumi` (normally `~/.config/quickshell/sumi`), leaving out
  the development files listed in `packaging/runtime-excludes.txt`.
- Unless you pass `--no-units`, writes `sumi-shell.service` and `sumi-lock-rescue.service` into
  `$XDG_CONFIG_HOME/systemd/user` and runs `systemctl --user daemon-reload`. This needs a reachable
  user manager and both units must resolve to the newly written files. The installer binds the units
  to the absolute `qs` it found on PATH. An existing managed installation keeps its current units.
- With `--enable`, it also enables `sumi-shell.service` (the link in `graphical-session.target.wants`). It never
  starts or restarts anything.
- Records what it created in `$XDG_STATE_HOME/sumi-shell/install/manifest.json`, together with a checksum of every
  file and a marker (`.sumi-install`) inside the tree.

It does **not** touch your Hyprland or hypridle configuration, system files, packages or other users. Start the shell
with `systemctl --user start sumi-shell`, or with `exec-once = qs -c sumi --no-duplicate` in Hyprland if you
installed with `--no-units`.

For a session without a user service manager, follow [the no-systemd guide](NO-SYSTEMD.md):
it covers session-bus environment, direct notification activation, offline updates and the Lock rescue limit.

## Ownership: what the installer will and won't touch

The installer only treats as its own what it created **and can prove**: the manifest's checksums, the marker and the
recorded targets of the links it made. A path or a file name proves nothing. When in doubt it stops and tells you what
to do; it never guesses.

- **Nothing is replaced.** If `~/.config/quickshell/sumi`, one of the units or the enable link already exists and
  wasn't created by this installer, `install` refuses. The tree is moved into place with `renameat2(RENAME_NOREPLACE)`
  and files are created exclusively; on a filesystem that can't guarantee this (for example some network
  filesystems), it refuses instead of falling back to something weaker.
- **Your home only.** Config, state and cache bases must resolve inside HOME. An existing base symlink
  that resolves there is supported. Paths below those bases are opened without following symlinks.
  The installer creates missing config/state bases under an owned, writable ancestor, with mode 0700.
  The bases are user infrastructure and survive recovery and uninstall. The owned Sumi subdirectories
  are tracked in the manifest. An explicit relative or out-of-HOME base is refused by the installer.
  The shell uses XDG defaults for relative variables in its settings and theme paths.
- **Preview the same profile.** Use `check --install --no-units` for direct startup or
  `check --install --enable` for managed startup. Use the matching flags for the dry-run and install.
  The preflight checks known missing modules and required CLI features without starting Quickshell.
  Actual RHI, ABI and Wayland surface loading still need a compositor test.
- **It refuses** if Sumi Shell is already running from another copy (`qs -c sumi` commands would stop reaching
  it), if a system-wide copy or a "default" Quickshell config would get in the way, or if a previous run was
  interrupted and not recovered.
- Another version replaces the installed one with `install.sh update` (below). Adding units or `--enable` later is not
  done in place: uninstall and install again.

## Uninstall

`uninstall` stops the units it installed (`systemctl --user stop`, never `disable`), removes only the enable links it
recorded, then removes each installed file whose checksum still matches, and finally the directories it created if
they are empty. Your settings, state and caches are kept.

It refuses, without removing anything, when:

- the session is locked, or the lock state can't be read while the shell runs (run it from inside Hyprland, unlocked);
- your locker would stop working: hypridle, a wrapper script or your Hyprland config points at the shell's lock
  helper. A wrapper is accepted only when it is a known version that falls back to `hyprlock`, that fallback is
  simulated, and `hyprlock` has its libraries and its PAM service. Otherwise point your lock command at `hyprlock`
  first. These checks lower the risk of being left without a locker; they don't prove that `hyprlock` will work in
  every graphical session (it is never run to test it);
- D-Bus would start Sumi Shell for notifications. Remove that activation first with
  `<tree>/scripts/notif-server off` for a managed install or `<tree>/scripts/notif-server direct-off` for a direct
  install. The installer leaves D-Bus activation files to those helpers;
- an enable link it didn't create points at its unit (for example one made with `systemctl --user enable`): remove
  it yourself first;
- the shell is running outside its unit (for example from `exec-once`): quit it first.

Files you changed after installing are **kept**. `uninstall` then reports them and stays unfinished until you move
them away or restore them and run it again. With `--keep-modified` it finishes instead: those files become yours, the
marker is removed, and the installer no longer manages them. A later `install` will refuse to replace them.

If the session gets locked while it runs, it stops before removing the lock helper, the rescue unit or the tree.

### Files changed while uninstall runs

Each file is checked, then moved aside (`.sumi-rm.<name>`, in the same directory, without replacing anything), checked
again through the same open file, and only then deleted. If it changed in between, it goes back to its name.
What is guaranteed: a change made **through the file's path** before uninstall moves it aside (editing it, saving a new
version over it, deleting it, replacing it with a link) is detected and your version is kept; a new file created at
that name afterwards is never touched. What is not: a program that **already had the file open** and writes to it
after the last check loses that write, as it would with any deletion. Don't uninstall while something is editing the
shell's files. If uninstall is interrupted with a file set aside, `recover --apply` deletes it only if it is still
the installed version, and otherwise puts it back (or leaves it set aside if the name is taken).

### --purge

`uninstall --purge` also deletes exactly these, after asking (or with `--yes`):
`~/.config/sumi-shell`, `~/.local/state/sumi-shell`, `~/.cache/sumi-shell`, `~/.cache/sumi-weather.json`
and `~/.cache/sumi-theme-samples`. They hold your settings, history and secrets. `~/.cache/sumi-wallpapers` and
`~/.cache/sumi-desktop-mode` are shared with the Minimaru rice and are only reported. A symbolic link in that list
makes it refuse.

## Interruptions and recover

Every step is recorded before it is done. If a run is killed, the session ends or the machine shuts down, the next
`install`/`uninstall` refuses and `status` shows what is pending. `recover` describes it; `recover --apply` undoes an
interrupted install or finishes an interrupted uninstall, again removing only what carries this installation's
evidence. Anything it can't prove is kept and listed for you.

A Hyprland run interrupted while writing needs `recover --apply --reload` (finishing it changes your Hyprland file).
A copy of each version the installer set aside is kept in `$XDG_STATE_HOME/sumi-shell/install/backups/` (0700); the
ones your current file already contains are removed after a successful `--revert`, and each removal is printed.

The record lives in `$XDG_STATE_HOME/sumi-shell/install/manifest.json`, format 3 since `update` (format 2 added the
Hyprland/hypridle integrations). An older record is read and converted the next time it is written, and the conversion
is noted in it; what the older format didn't know (the build of the installed tree) is recorded as unknown, never
guessed. Earlier installers refuse a newer record instead of acting on what they can't see. A record edited by hand is
refused as damaged: nothing is changed.

An interrupted `update` or `rollback` is recovered by the identity (inode) of the trees it was swapping: `recover
--apply` keeps the version from before in place and loads it if the shell runs (pass `--reload` or `--restart`), unless
the new version is already on disk **and** running and passes the checks, in which case it finishes the update.

If the interruption happens while moving the earlier tree into `previous/`, recovery completes that recorded move
using its inode, including when the move happened before its completion was recorded. With no running shell it leaves
the update `installed-unverified`; a running build that fails verification leaves `verify-failed` and keeps the earlier
tree for an explicit rollback.

The lock is checked again before reloading or restarting during rollback. If the session became locked, the transaction
stays pending: unlock, then run `recover --apply --reload` (or `--restart`). Restoring pre-migration settings also waits
for proof that the earlier code loaded. If it did not load, settings stay unchanged and recovery remains pending.

Only one run at a time: a lock in `$XDG_RUNTIME_DIR/sumi-install.lock`. If unset or empty, the installer uses
`/run/user/<uid>` for a conventional logind session. The directory must already exist with mode 0700 and
be yours. Symlinks and untrusted ancestors are refused. The lock file must be a single-link regular file
owned by you, mode 0600. It persists for the runtime's lifetime. Run every command managing the same
installation with the same runtime, including recovery. A second run
doesn't wait: it refuses and says whether the other run is still alive.

## Updating

`./install.sh update` (from the new version's directory) only shows what would happen: the installed and the new version
and **build**, the files that change, whether a reload is enough, what `settings.json` would go through and anything that
stops it. `--apply` does it:

1. **Checks before touching anything.** The installed tree must be exactly what was installed (a changed or removed file
   refuses unless you pass `--replace-modified`: a copy of each is kept, and the version kept from before is exactly
   what you had; a file the installer didn't install always refuses). The new tree is checked without running it: QML
   syntax with a `qmllint` that supports `--bare` (skipping Qt 5 tools that may precede Qt 6 in PATH),
   shell scripts with `bash -n`, Python compiled in memory, JSON parsed,
   and what the lock helper, the units and the clients need from it (its IPC verbs, the helper's modes, the public
   shortcuts). A change of the public API needs `--accept-api N`; an older version needs `--downgrade`; a version that
   can't update from yours (`minUpdateFrom`) says which release to go through first.
2. **Swaps the trees atomically** (`renameat2(RENAME_EXCHANGE)`), after checking by inode that the tree in place is the
   one it checked. The record says what is on disk in the same step.
3. **Loads it, only as you asked.** `--reload` asks the running shell to reload; it is refused unless a reload can be
   argued: the new version declares that a reload is enough (`restart.required: false` in its `version.json`), it adds no
   inline QML components and no `qmldir` changes (those don't load on a reload: measured), and the running shell is known
   to be the installed build. Otherwise `--restart` restarts `sumi-shell.service` (never without being asked), only
   while the session is unlocked, with `sumi-lock-rescue.service` loaded and when the unit's start limit, read from
   systemd, leaves room for a failed start and the way back. For a `--no-units` installation, stop the shell while unlocked,
   apply the update offline, start the new copy manually and run `update --verify`. See [the direct update procedure](NO-SYSTEMD.md#update-and-remove).
4. **Checks the running shell**, five ways: the instance (a reload must keep the same process; a restart must bring a
   *new* process, the unit's, started after the request), the version, API and **build** it reports (`api` → `build`: the
   identity of the exact content that was installed, not the public version), the critical IPC verbs and the
   shortcuts registered in Hyprland, that the settings store is ready and the lock answers, and no load error from this
   load in its log.
5. **If any check fails, goes back by itself**: the previous tree is swapped back, loaded the same way and checked again.
   If even that fails, the state is `broken` and nothing else is done.

While it runs, idle is inhibited through `org.freedesktop.ScreenSaver` on hypridle's bus (only if exactly one hypridle
runs and it owns that name); the inhibition ends when the update ends or dies. It is a complement: if the session gets
locked anyway, the update stops before swapping, or — if it already swapped — leaves the state **swapped-not-loaded**:
the new files are on disk and the running shell is still the old version. Finish with `update --finish --reload` (or
`--restart`) once unlocked, or undo with `update --rollback`. After a new login the shell already runs the new version:
`--finish` then only checks it.

Disk, process and configuration can end up in different states, and `install.sh status` says which — never "success"
unless the running shell was checked:

| state | on disk | running | what to do |
|---|---|---|---|
| `verified` | new | new, checked | nothing |
| `installed-unverified` | new | no shell was running | `update --verify` once it runs (or `--rollback`) |
| `verify-failed` | new | doesn't match | `update --rollback` |
| `swapped-not-loaded` | new | old | `update --finish …` or `update --rollback …` |
| `rolled-back` | old | old, checked | nothing; the failed version was removed |
| `settings-conflict` | as written | as written | settings.json needs your decision (below) |
| `broken` | old | doesn't pass | see the shell's log |

One previous version is kept in `$XDG_STATE_HOME/sumi-shell/install/previous/` for `update --rollback`; the one
before it is removed only after the new one is checked. `uninstall` removes it like the tree (by checksum).

### settings.json

A new version may convert `settings.json` to a newer schema when it loads (the shell keeps its own copy in
`backups/settings/`). `update` refuses to load such a version unless you pass `--accept-settings-migration`, and keeps
its own verified copy (0600) in `install/backups/<id>/`. The copy is put back — when the update fails, or with
`--rollback` — **only while `settings.json` is exactly the converted file** (its checksum is taken as soon as the
conversion is seen); what it replaces is kept next to the copy. If you changed a setting after the conversion, nothing is
put back and the shell isn't taken back to a version that can't read the file: the state becomes `settings-conflict` and
waits for you. A version older than your `settings.json` is refused: it would run read-only.

## Migrating legacy state

A v2/v3 `settings.json` is backed up and converted on first load. Existing tasks,
providers and bookmarks retain their contents. The conversion does not inspect the old Hyprland scripts
or import a terminal, browser, task list or provider from a rice. Bring a complete old Kitasan profile
with `identity-v1`. For other profiles, copy the files you choose into `$XDG_CONFIG_HOME/sumi-shell/`
while unlocked and with Sumi stopped. The [examples](../sumi/examples/) document the formats. If you
use custom providers, select them in Settings after reviewing their commands.

`./install.sh migrate` lists the explicit imports and their state. An update never runs these three
file imports or the separate `identity-v1` profile import:

- `wallpaper-state-v1`: `~/.config/hypr/.current-wallpaper{,-outputs}` → `$XDG_STATE_HOME/sumi-shell/`;
- `theme-state-v1`: `~/.config/matugen/{enabled,scheme,mode,contrast,source}` → `$XDG_STATE_HOME/sumi-shell/theme/`.
- `websites-v1`: `$XDG_CONFIG_HOME/hypr/websites.conf` → `$XDG_CONFIG_HOME/sumi-shell/websites.conf`.
  A pre-existing destination remains yours, even when its bytes match the legacy file.

`migrate <id> --apply` imports one, with the shell stopped: the legacy files are never touched, nothing is replaced, and
a record (`*-migration-v1.json`) written last says it is done. `pending` means there is something to import; `partial`,
that an import was cut before it was recorded and what was published is byte-for-byte the legacy file (it can be
completed); `conflict`, that new state exists that doesn't come from the legacy files (it isn't touched: review it).
`--revert` removes an import only if nothing changed since.

## Hyprland: the shortcuts and the lock options

`./install.sh hyprland` only shows what it would do: which file Hyprland loaded (it asks the running Hyprland), the
dialect (Lua or `hyprland.conf`), Hyprland's version, the exact lines and any key that is already taken. It writes and
reloads nothing.

**Hyprland 0.57 and later read only Lua configuration** ("starting with this version, .conf configs are no longer
supported", Hyprland 0.57 release notes). The version is read from Hyprland itself — the running one (`hyprctl -j
version`) and the installed binary (`Hyprland --version-json`); the newer of the two decides, because after an update
the next login uses the installed one. With 0.57 or later only the Lua fragment is integrated. If your configuration is
still `hyprland.conf` — or Hyprland wrote its default `hyprland.lua` (it contains `hl.config({ autogenerated = true })`)
next to your `hyprland.conf` — nothing is written: the preview explains why and how to move your configuration to Lua by
hand (Sumi Shell doesn't convert it), and `--apply` refuses. If the version can't be read, a `hyprland.conf` is refused
too. With Hyprland 0.56 or older everything below works as before for both dialects; `hyprland.conf` support is kept
frozen for them. An integration applied to `hyprland.conf` on 0.56 can still be reverted after updating to 0.57.

`--apply --reload` creates `sumi-shell.lua` (or `sumi-shell.conf`) next to the file Hyprland loads — the public
shortcuts, each with a description, `allow_session_lock_restore`, `session_lock_xray` and the blur layer rules — and adds a
small block at the end of that file:

```lua
-- >>> sumi-shell (install <id>): added by `install.sh hyprland --apply`; remove it with `install.sh hyprland --revert`
require("sumi-shell")
-- <<< sumi-shell (install <id>)
```

- **`--reload` is required** while Hyprland's automatic reload is on, because writing the file reloads your whole
  configuration: your Lua code and your `exec` lines run again. With automatic reload off, `--apply` alone writes the
  change and reports it as **written, not confirmed as loaded**; loading it is up to you (`hyprctl reload`, then
  `install.sh hyprland --verify`, which records it as loaded only if all the shortcuts it wrote are there with their action).
- A reload that Hyprland doesn't confirm (`hyprctl reload` doesn't answer `ok`) never counts as loaded: the written
  files stay as they are (they are the evidence to finish later) and the state stays `written`.
- Before writing, the fragment is checked with `Hyprland --verify-config` (only the fragment: that command *runs* the
  configuration it checks, so it is never used on yours) and your file with the new block is checked without running it
  (`luac -p` from the same Lua version Hyprland uses; for `hyprland.conf`, balanced braces). After reloading, every
  shortcut it wrote is checked in `hyprctl binds` by key combination and action; if that fails, the change is undone — but only
  if your file is still exactly what was written.
- **It won't take over what is already there:** if your files already bind `sumi:` shortcuts, it says so and does
  nothing. With Lua, a shortcut whose key you already use is **left out** (your binding stays): the preview lists
  them, the fragment shows the line to bind each one to another key, and the checks after reloading don't expect them.
  Hyprland's own default configuration takes `SUPER+C` and `SUPER+R`, so there `calendar` and `recorder` are left
  out. With `hyprland.conf` (Hyprland 0.56 and older) a taken key still refuses the whole change, with the list.
- **Manual steps instead of guessing** when the file is a symbolic link (Stow and other dotfiles managers), has other
  hard links, extended attributes or an ACL, lives outside your configuration directory, comes from `HYPRLAND_CONFIG`,
  doesn't pass the syntax check, or when no running Hyprland answers. The preview prints where to add the lines and how to
  check them.
- **Blur behind the shell (optional look).** The Lua fragment asks Hyprland to blur what is behind the shell's main
  layer (`sumi-shell`: Dynamic Bar, Dynamic Capsule or Edge, panels…) and behind its floating UIs (`sumi-audio`, `-calendar`,
  `-keybinds`, `-monitor`, `-notifications`, `-settings`, `-wallhaven`), with `ignore_alpha = 0.40` so fully transparent areas and
  most of the shadow stay out. It only shows with **Glass opacity** below 100 %, and it needs `decoration:blur` on;
  `ignore_alpha` must stay below your opacity, or the blur disappears again. Hyprland applies a layer rule's blur when
  the layer is *created*: the floating UIs get it the next time they open, but the main layer, already open, gets it only
  after **restarting the shell once** (log out and back in, or restart its service) — the installer says so. The blur
  is Hyprland's and its cost depends on the GPU and resolution; remove the two lines from the fragment (the installer
  then stops managing it) or revert if it doesn't suit you. A fragment written by an earlier version has only the
  main-layer rule; to get the second one, `--revert --reload` and `--apply --reload` again. Since Settings became its
  own floating window (`sumi-settings`, 2026-11-07), a fragment written before that leaves Settings without blur until
  it is written again the same way; if you wrote the rule by hand, add `settings` to the list of names. The frozen `hyprland.conf`
  fragment (Hyprland ≤ 0.56) keeps only the main-layer rule.
- `--revert --reload` removes only its block (only if it is still exactly as written) and its fragment (only if
  unchanged). Changes you made elsewhere in your file stay. Without a confirmed reload it is `reverted on disk` until
  `install.sh hyprland --verify` sees none of the shortcuts.

What the check proves, and what it doesn't:

| | hyprland.conf | Lua |
|---|---|---|
| Registered at its key combination (`hyprctl binds`) | yes, all of them | yes, all of them |
| Action identified | from Hyprland's own data: `global sumi:<name>` (Hyprland ≤ 0.56) | partly: `hyprctl binds` shows `__lua` (≤ 0.56) or `HL.Dispatcher(global)` (0.57) without the shortcut name, which is taken from the fragment (checked by its checksum) and the binding's description |
| Pressed and observed | no | no |

Pressing the shortcuts isn't tested: simulated key presses didn't trigger Hyprland bindings in the test compositor, and
the installer never presses keys in your session.

## hypridle: locking with the shell

`./install.sh hypridle` shows the configuration hypridle actually loaded (from the running process), what it runs to
lock now, and what would change. hypridle's idle timeouts and your power preferences stay yours: only `general` keys are
added, in `sumi-shell-hypridle.conf` included at the end of your file.

- Nothing is replaced silently. `lock_cmd` (what locks) is replaced only with `--replace-lock-cmd`; `before_sleep_cmd`
  only with `--replace-before-sleep-cmd`. If `before_sleep_cmd` is `loginctl lock-session` (it just asks for a lock),
  it is kept: it ends in the new `lock_cmd`. Your own lines stay in your file, without effect, and are back after
  `--revert`.
- `inhibit_sleep` is yours unless you pass `--inhibit-sleep 3`. Measured with hypridle 0.1.8: only `3` makes suspend
  wait until the session is locked; the automatic mode waits only when `lock_cmd` mentions hyprlock and
  `before_sleep_cmd` is `loginctl lock-session`. If your setup has that guarantee today and the new `lock_cmd` would lose
  it, `--apply` refuses until you pass `--inhibit-sleep 3`.
- **Written is not loaded:** hypridle reads its configuration only when it starts. `--restart` restarts it only when a
  systemd user unit runs exactly that hypridle; otherwise log out and back in. `install.sh status` says `written, not
  loaded yet` / `applied and loaded`, and after `--revert`, `reverted on disk` until the running hypridle has restarted.
- Without a `hypridle.conf`, nothing is created: the preview prints the lines to add.

## theme-apps: the shell's colours in other apps

Without your own matugen configuration the shell only colours itself. `install.sh theme-apps` gives the same colours
(the wallpaper's, or a static palette such as Catppuccin or Gruvbox) to other apps, and the shell's theme provider then
keeps them in step with every theme change:

```sh
./install.sh theme-apps                       # preview: what is possible here and what would change
./install.sh theme-apps kitty gtk3 gtk4 --apply
./install.sh theme-apps qt6 --apply           # only if your Qt apps use qt6ct
./install.sh theme-apps hyprland --apply      # the window border; needs `install.sh hyprland` (Lua) first
./install.sh theme-apps --verify
./install.sh theme-apps [APP…] --revert
```

| App | Colours in | What changes in your configuration | Takes effect |
|---|---|---|---|
| kitty | `kitty/sumi-shell-colors.conf` | a delimited `include` block at the end of `kitty/kitty.conf` (created if missing) | at once, in every kitty |
| GTK 3 / GTK 4 | `gtk-3.0/` and `gtk-4.0/sumi-shell-colors.css` | a delimited `@import` block at the start of each `gtk.css` (created if missing; your rules after it win) | in apps opened afterwards; open GTK 4 apps follow light/dark |
| Qt 5 / Qt 6 | `qt5ct/` or `qt6ct/colors/sumi-shell.conf` | `color_scheme_path` and `custom_palette` in `[Appearance]` of `qt5ct.conf`/`qt6ct.conf`; the old values are kept | about 3 seconds |
| Hyprland | `sumi-shell-colors.lua` next to the Hyprland fragment | nothing: the fragment of `install.sh hyprland` already loads it | at once, and after every reload |

- **What it needs:** matugen, the shell's own theme provider (Settings → Shell → Apps: Automatic, Matugen or Static
  only), and no `theme.matugenConfig` of your own in `providers.json` (your configuration already decides which apps
  get colours). Qt only when `QT_QPA_PLATFORMTHEME` names qt5ct/qt6ct and `qt5ct.conf`/`qt6ct.conf` exists (open
  qt5ct/qt6ct once). The border only on Lua configurations (Hyprland 0.57+, or a 0.56 one already in Lua); an older
  `install.sh hyprland` setup is revert-and-apply once.
- **Your files:** the same rules as above — a symbolic link (Stow) is refused, existing files are swapped atomically and
  the previous version is kept in the installer's state, lines you edited are left alone, and `--revert` removes only
  what it recognises (a `color_scheme_path` you changed afterwards stays yours). The colour files start with
  «Sumi Shell —»: an existing file without that line is never overwritten.
- **The shell's configuration:** `~/.config/sumi-shell/matugen-apps.toml` (the shell's palette plus the apps you
  chose). The shell uses it only while it is yours and not writable by others; Settings → Theme → Colors → «Applied to»
  says which apps get the colours.
- `uninstall` refuses while theme-apps is applied: run `install.sh theme-apps --revert` first.

## Uninstall while Hyprland or hypridle depend on the shell

`uninstall` refuses while an integration is active (also `reverted on disk`): run `install.sh hypridle --revert
--restart`, `install.sh hyprland --revert --reload` and `install.sh theme-apps --revert` first. It also refuses when it can't establish that nothing that
locks the session still needs the shell, including what running programs loaded, not just what is on disk:

- a running hypridle that started before its configuration last changed (it may still run the old command; restart it);
- the configuration a hypridle would load at its next start (its unit's `-c`, a Hyprland `exec` line, the default path);
- lock scripts in your home that call the shell, directly or through another script, or that compute what they run;
- Hyprland key bindings that run the helper, and — with automatic reload off — Lua bindings changed since Hyprland
  started (their actions can't be read).

`uninstall --dry-run` prints what is known about each piece: on disk, probably loaded, checked in the running process,
or unknown.

## Limits

- One user, one machine: a home shared between machines over the network is not supported.
- `--no-units` supports an exec-once session, with the limitations in [the no-systemd guide](NO-SYSTEMD.md).
- `update` doesn't update the installed systemd units: a version that changes them asks you to uninstall and install.
- The checks before swapping only see syntax and what critical consumers need; whether the new version works is only
  known once it runs, which is why it is checked and rolled back automatically.
- It doesn't install dependencies; `./install.sh check` lists them.
- If you already run your own copy at `~/.config/quickshell/sumi` (a development tree, dotfiles), the installer
  won't take it over. Keep managing it as you do.

## Coming from Kitasan-Shell

Sumi Shell was called Kitasan-Shell before its first public release. The names changed everywhere the shell is reachable:
the config is `quickshell/sumi` (`qs -c sumi ipc call sumi …`), the global shortcuts are `sumi:<name>`, the units are
`sumi-shell.service` and `sumi-lock-rescue.service`, the layers are `sumi-*` and the state lives in `…/sumi-shell`.

- **Stop the old shell first, unlocked.** Two shells at once mean two sets of shortcuts, notification servers and polkit
  agents; `install`, `migrate` and `update` refuse while the old one runs, and `check` reports it (`former.running`).
- **An installation made by the former installer is not taken over** (other manifest and names): uninstall it with that
  installer, then install this one. `check` says so (`former.installer`).
- **State:** `./install.sh migrate identity-v1` previews; `--apply` (every shell stopped) **copies**
  `$XDG_{CONFIG,STATE,DATA}_HOME/kitasan-shell` into `…/sumi-shell`, verifies the copy (and the calendar database), and
  rewrites only paths that named the old directories when the same file is at the new place. The originals are never
  touched; `--revert` removes the copy while nothing changed in it; `--recover` clears an interrupted copy.
- **CalDAV passwords** saved under the old name are still read (`application kitasan-shell`); new ones are saved under
  `application sumi-shell`. Old keyring entries are never removed for you.
- **Kept on purpose:** the equalizer's PipeWire names (`kitasan-eq.conf`, `kitasan_eq.*`, `kitasan.equalizer`), and the
  font-sync names of a kitty it already managed (`kitasan-shell-fonts.conf` and its block in `kitty.conf`), so your EQ
  profile, your audio routes and «Undo all» keep working.
- **Your Hyprland config:** bind `sumi:<name>` (the shortcut help notes keys still on `kitasan:<name>`), use the
  description prefix `Sumi Shell: `, and rename the layer rules' namespaces. A matugen config that writes
  `kitasan-shell/colors.json` doesn't reach this shell: `check` says so (`former.matugen`).
- **Versions:** Sumi Shell follows Semantic Versioning 2.0.0 and continues the numbering after Kitasan-Shell 0.4.0.
  The rename is a breaking change of `0.y.z` (see `CHANGELOG.md`). `install.sh update` does not update a Kitasan-Shell
  installation; it compares Sumi Shell versions, prereleases included, by SemVer precedence. `apiVersion` stays 1, and
  `install.sh --version` and `minimaru --version` print the version.
- **The lock wrapper:** a `lock.sh` that calls `quickshell/sumi/scripts/sumi-lock` and falls back to hyprlock; the one of
  the former name keeps locking (with hyprlock) and is still recognised as safe.
