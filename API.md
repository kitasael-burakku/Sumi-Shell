# Sumi Shell public API

**API version 1** · shell version **0.4.0** (both come from `sumi/version.json`, the single source of truth).

This is the part of Sumi Shell that other programs may rely on: a small set of IPC verbs, the global shortcut names
and two configuration file formats. Everything else the shell exposes over IPC (about 320 more verbs, listed in
[api/IPC-INVENTORY.md](api/IPC-INVENTORY.md)) is **internal or diagnostic and may change in any release**.

The machine-readable contract is [api/contract-v1.json](api/contract-v1.json); `tests/api/api-check.py` verifies that
the code still implements it (`python3 tests/api/api-check.py sumi api/contract-v1.json`, and `--live` to also query
the running shell with read-only verbs).

## Compatibility policy

- The shell version follows `MAJOR.MINOR.PATCH`. `apiVersion` is a single integer that only changes when the public
  contract changes **incompatibly** (a public verb, argument type, return type, guaranteed field or value, shortcut name
  or file format version is removed or changed).
- Additions do not change `apiVersion`: a new public verb, a new field in a JSON reply, a new accepted value.
- Before an incompatible change, the old name keeps working as an alias for **at least one minor release** and is listed
  under [Deprecated](#deprecated) with the release that removes it.
- JSON replies may contain more fields than the ones guaranteed here. Rely only on the guaranteed fields.
- Internal and diagnostic verbs have no compatibility promise. Do not build integrations on them; if you need one,
  ask for it to become public.

Check compatibility before using other verbs:

```sh
qs -c sumi ipc call sumi api        # {"apiVersion":1,"version":"0.4.0"}
```

## Calling the IPC

```sh
qs -c sumi ipc call sumi <verb> [args…]
```

- Arguments are positional strings on the command line; booleans are `true`/`false`. A verb that cannot do what was
  asked returns `false` (and usually leaves a warning in the shell's log). `qs` exits with 0 even when the verb returns
  `false`: **read the output, not the exit code**.
- `mon` arguments take a monitor name (`DP-1`) or `""` for the focused monitor (falling back to the first one).
- **The running shell is found by the path of its config, not by its name.** `qs -c sumi` looks for
  `quickshell/sumi/shell.qml` in `$XDG_CONFIG_HOME` (usually `~/.config`) and then in each `$XDG_CONFIG_DIRS`
  (default `/etc/xdg`); a `quickshell/shell.qml` in one of those directories (a "default" config) hides the named configs
  in that directory. A client only reaches the running shell if, **from its own environment**, it resolves the same copy
  the shell was started from. If a user copy is added or removed while a system copy is running (or the other way round),
  clients answer `No running instances` until the shell is restarted. `qs ipc --pid <pid> call …` always reaches a given
  instance. Settings → System → Environment → *Shell installation* (and `capabilities.py report`) says which copy runs,
  which copies exist and whether commands from that environment reach it.
- Never pass secrets as arguments: any process can read another's command line.

## Public verbs

### `api` → string (JSON)

The shell version and the API version. Guaranteed fields: `apiVersion` (number), `version` (string), `build`
(string). A broken installation (no readable `version.json`) answers `"version":"unknown","apiVersion":0`. Read-only.

`build` identifies the exact distributed content the running shell **loaded** (`sha256:` of its files, written as
`build.json` by the installer or the package; `""` for a development tree). Two revisions with the same `version` have
different builds. It is read once when the configuration loads, so after files change on disk it still names the code
that is running. Added in 0.4.0 without changing `apiVersion` (a new field).

### `status` → string (JSON)

Whether a shell is running, and a snapshot of its state. Guaranteed fields: `version` (string), `apiVersion` (number),
`pid` (number). The other fields (screens, open surfaces, audio, media, notifications…) are informational and may change.
Read-only. Note that the snapshot includes the current media title and artist.

### `reload` → void

Reloads the shell's QML in place (the same process). **Refused while the screen is locked** (the shell logs
`lock: reload refused while the screen is locked` and does nothing), so check `lockStatus` first. No reply either way:
to confirm, watch the log for `Configuration Loaded` or compare `status` before and after. A reload does not pick up
changes that need a restart (see [Reload or restart](#reload-or-restart)). The systemd unit uses it as `ExecReload`.

### `lockStatus` → string (JSON)

The lock screen state. Guaranteed fields: `phase` (string: `unlocked`, `entering`, `locked`, `leaving`) and `secure`
(boolean: the compositor has confirmed the session lock, so every output is covered). Read-only. Useful before automating
anything visible (screenshots, synthetic input).

To **request** a lock, do not use the IPC: use `loginctl lock-session` (it goes through whoever handles lock requests,
normally hypridle with the shell's helper) or run the helper directly, `sumi/scripts/sumi-lock` (it falls back to
hyprlock if the shell cannot lock).

### `open name mon` → bool

Opens a surface on a monitor. Guaranteed names: `launcher`, `wallpaper`, `settings`, `system`, `controlCenter`,
`calendar`, `mixer`, `media` (alias of `mixer`), `web`, `power`, `clipboard`, `emoji`, `wifi`, `bluetooth`, `dashboard`,
`performance` (Dashboard tab), `tasks` (the floating Tasks window since 2026-11-10, no longer a Dashboard
tab), `minimizer`, `services`, `theme`, `cli`, `notifications`, `login` (the floating Login screen window for Sumi
SDDM, since 2026-11-23). Returns `false` for
an unknown name or when no monitor matches `mon`. Since 2026-11-07 `settings` (and `settingsTheme`, `settingsSystem`)
opens Settings as its own floating window instead of a capsule panel; the name, its arguments and `close settings` work
as before.

### `peek mon` → bool

Holds the capsule or Edge expanded on that monitor without the pointer (what a "peek" key does). `false` if no monitor matches.

### `mode profile` → bool

Switches the desktop profile: `normal`, `focus`, `gaming` or `cinema`. Returns `true` when the request is accepted and
`false` for an unknown profile or while another change is running. The change happens asynchronously; read `modes` for
the result. What a profile actually changes depends on what the machine has (Hyprland options, the glass and cursor
plugins, power profiles, a video wallpaper); missing pieces are skipped and reported.

### `modes` → string (JSON)

The desktop profile state. Guaranteed fields: `activeMode` (string) and `busy` (boolean). Read-only.

### `themeSet name` → bool

Changes the colour scheme: `static` (the built-in palette) or a dynamic scheme generated from the wallpaper with matugen:
`content`, `expressive`, `fidelity`, `fruit-salad`, `monochrome`, `neutral`, `rainbow`, `tonal-spot`, `vibrant`. Returns
`false` for an unknown name or when the theme provider can't do it here (no matugen, no Python, theme set to off); the
reason is shown in Settings → System → Environment.

### `themePreset name` → bool

Applies a static palette at once, without a preview: `catppuccin-mocha`, `catppuccin-latte`, `gruvbox-dark` and
`gruvbox-light` are guaranteed (more may be installed in `sumi/palettes/`). It replaces the dynamic colours and
`themeSet static` goes back to Minimaru. A new wallpaper does not change a palette. Everything the matugen
configuration of the theme provider reaches is recoloured in one transaction (all or nothing), with the terminal
colours of the palette for kitty; without matugen, only the shell. Returns `false` for an unknown name or when the
theme provider can't do it here; the change itself happens in the background. Added with the static palettes
(2026-11) without changing `apiVersion` (a new verb).

### `notifDnd on` → bool

Turns Do not disturb on (`true`) or off (`false`), marked as set by a desktop profile. Returns the **resulting** Do not
disturb state (so `notifDnd false` returns `false` on success). Only meaningful when the shell is the notification
server.

## Global shortcuts

The shell registers 32 global shortcuts with the app id `sumi`. Bind them in Hyprland as `sumi:<name>`; the
example configs `sumi/examples/hyprland/sumi.lua` and `sumi.conf` bind all of them except `media`. Since 2026-11-10
`media` is an alias of `mixer` (the Mixer shows the player and the mix side by side): it still works when bound, but it
has no default key and no row of its own in the in-shell help. `tasks` (added 2026-11-10) toggles the floating Tasks
window. `emoji` (added 2026-11-17) is the emoji, kaomoji, symbol and Nerd Font glyph picker. `loginScreen` (added
2026-11-23) toggles the floating Login screen window (Sumi SDDM: look, preview and system).

`launcher`, `wallpaper`, `wallhaven`, `monitor`, `audio`, `media`, `settings`, `system`, `controlCenter`, `calendar`,
`calendarUi`, `mixer`, `web`, `power`, `clipboard`, `emoji`, `wifi`, `bluetooth`, `dashboard`, `tasks`, `minimizer`, `services`, `theme`, `cli`,
`notifications`, `peek`, `barToggle`, `wallRandom`, `keepAwake`, `recorder`, `keybinds`, `loginScreen`.

Renaming or removing one is an incompatible change.

### Default keys

Not part of the contract (you choose your own keys), but the shell's single list of defaults: they live in
`sumi/lib/shortcuts.json`, which also feeds the in-shell help, `install.sh hyprland --apply` and both example
configurations (`tests/api/api-check.py` keeps them in step).

| Name | Title | Category | Default key |
|---|---|---|---|
| `launcher` | App launcher | Launch and search | `SUPER+space` |
| `cli` | Command palette | Launch and search | `SUPER+CTRL+X` |
| `web` | Web hub | Launch and search | `SUPER+SHIFT+slash` |
| `clipboard` | Clipboard history | Launch and search | `SUPER+SHIFT+V` |
| `emoji` | Emoji and symbols | Launch and search | `SUPER+period` |
| `controlCenter` | Control center | Shell and windows | `SUPER+CTRL+N` |
| `notifications` | Notification center | Shell and windows | `SUPER+CTRL+A` |
| `dashboard` | Dashboard | Shell and windows | `SUPER+CTRL+D` |
| `tasks` | Tasks | Shell and windows | `SUPER+CTRL+T` |
| `minimizer` | Window minimizer | Shell and windows | `ALT+Tab` |
| `peek` | Peek | Shell and windows | `SUPER+CTRL+space` |
| `barToggle` | Dynamic Bar | Shell and windows | `SUPER+CTRL+P` |
| `keybinds` | Keyboard shortcuts | Shell and windows | `SUPER+F1` |
| `wallpaper` | Wallpapers | Wallpaper and theme | `SUPER+W` |
| `wallRandom` | Random wallpaper | Wallpaper and theme | `SUPER+CTRL+R` |
| `wallhaven` | Wallhaven | Wallpaper and theme | `SUPER+CTRL+W` |
| `theme` | Visual profiles | Wallpaper and theme | `SUPER+T` |
| `mixer` | Mixer | Sound and recording | `SUPER+A` |
| `audio` | Audio settings | Sound and recording | `SUPER+SHIFT+A` |
| `recorder` | Screen recorder | Sound and recording | `SUPER+R` |
| `wifi` | Wi-Fi | Network | `SUPER+N` |
| `bluetooth` | Bluetooth | Network | `SUPER+CTRL+B` |
| `calendar` | Today | Date and time | `SUPER+C` |
| `calendarUi` | Calendar | Date and time | `SUPER+CTRL+C` |
| `settings` | Settings | System | `SUPER+CTRL+S` |
| `system` | System monitor | System | `SUPER+Y` |
| `monitor` | System monitor inspection | System | `SUPER+CTRL+Y` |
| `services` | Systemd units | System | `SUPER+U` |
| `power` | Session power | Session | `SUPER+Escape` |
| `keepAwake` | Keep awake | Session | `SUPER+CTRL+K` |
| `loginScreen` | Login screen | Session | `SUPER+CTRL+L` |

### Recognising your keys

The in-shell help (Settings → Shell → Interaction → Keyboard shortcuts) reads `hyprctl -j binds` and shows
each action's effective key. With `hyprland.conf` (Hyprland 0.56 and older) a binding names its shortcut. With Lua
(0.57 and later) it does not (the dispatcher is reported as `HL.Dispatcher(global)` with an internal number), so a
key is recognised only when its binding has the description `Sumi Shell: <name>`. A Lua function that dispatches
the shortcut cannot be inspected even with that description. When a key can't be determined the help says so; it
never shows a default key as if it were yours.

## Configuration file formats

Both live in `$XDG_CONFIG_HOME/sumi-shell/`, carry their own `"version"` field and are never written by the shell.
Commented examples are in `sumi/examples/`.

| File | Version | Validated by |
|---|---|---|
| `tasks.json` (maintenance tasks) | 1 | `sumi/lib/tasks-schema.js` |
| `providers.json` (commands for wallpaper, theme, thumbnails and updates providers) | 1 | `sumi/lib/providers-schema.js` |

## Stable names

Not checked by the tool, but other configurations refer to them: the config name `sumi` (`qs -c sumi`), the
systemd user units `sumi-shell.service` and `sumi-lock-rescue.service`, the lock helper
`scripts/sumi-lock [session|instant]` (for hypridle's `lock_cmd` and `before_sleep_cmd`), and the layer namespace
`sumi-shell` (for a Hyprland `layerrule`).

## Reload or restart

- **Reload** (`reload`, or `systemctl --user reload sumi-shell`) re-reads the QML in the same process. It is enough
  after editing the shell's files in place. It is refused while the screen is locked.
- **Restart** (`systemctl --user restart sumi-shell`) is needed when: a copy of the shell is added or removed in
  another config directory (clients would no longer reach it); a new inline component (`component X:`) was added to a file that is already loaded;
  the notification server or the polkit agent setting is changed (they are read at start); the unit file changed (after
  `systemctl --user daemon-reload`). Restart only after checking the new code loads, and preferably unlocked: with the
  units, a restart while locked re-locks in about a second and the rescue unit covers a shell that does not come back.

## Deprecated

Nothing yet.
