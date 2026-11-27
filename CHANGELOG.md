# Changelog

All notable changes to Sumi Shell are documented in this file.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html). During `0.y.z` the public contract may change in
any MINOR release; every such change is listed here with what to do about it.

## [Unreleased]

### Changed

- **The shell is now called Sumi Shell** (it was Kitasan-Shell). This is a breaking change:
  - The config is `quickshell/sumi` (`qs -c sumi`), with IPC target `sumi`.
  - Global shortcuts are `sumi:<name>`, with the description prefix `Sumi Shell: `.
  - The units are `sumi-shell.service` and `sumi-lock-rescue.service`, and the layers `sumi-*`.
  - The state lives in `$XDG_{CONFIG,STATE,DATA}_HOME/sumi-shell`.
  - The package names are `sumi-shell` and `sumi-shell-git`.
  - Coming from Kitasan-Shell: see `packaging/INSTALL.md`, «Coming from Kitasan-Shell».
- The default palette is **Minimaru** (the former static palette, same colours); the glass material is shown as
  «Glass».
- Versions follow Semantic Versioning 2.0.0. `install.sh update` compares versions, including prereleases, by SemVer
  precedence.
- The four presentations have their own names in Settings, the shortcut help and the documentation: **Dynamic
  Capsule** (was Dynamic Island), **Dynamic Bar** (was Persistent bar), **Edge** (was Notch) and **Bar-Edge** (was
  Bar-notch). Only the names changed: settings keys, stored values (`island`, `bar`, `dock`, `notch…`), IPC verbs and
  values, and shortcut names stay the same, so nothing needs migrating.
- The Sumi SDDM notch is called **Login Edge** in the Login screen window's preview and in Settings. The group and
  option labels inside that window come from Sumi SDDM's own schema and change with it.
- One time contract for the whole shell (`lib/time-format.js`, exposed by `Clock`). The Monitor window, the
  Services panel, the Login screen status and the event times in Calendar now follow the 12/24-hour setting; they
  were always 24-hour. «How long ago» texts share one set of thresholds (under 90 s «now», under 90 min in minutes,
  under 48 h in hours, then days). Notification times on the lock screen use the same short form as the
  notification cards («5m»).
- The battery glyph and colour come from one place (`Battery.glyph`, `Battery.ink`), so the Dynamic Bar and the
  Control Center agree: plugged in and full shows the accent in both.
- A limited or connecting network is orange and no network is red in the hover face too, like the bar and the side
  circle (it was red for both).
- The Bluetooth indicator of the hover face appears only with an adapter, like in the Dynamic Bar. The Services
  button of the hover face appears only with systemd, like in the Dynamic Bar.
- The wheel on the Dynamic Bar's volume uses the same steps as the capsule's wheel: touchpad scrolls add up to 5 %
  steps instead of jumping on every event, and fast scrolling no longer loses steps.
- The hover face of the capsule and Edge works like the Dynamic Bar's status capsule: clicking the network or
  Bluetooth icon opens the Control Center, right-click opens Wi-Fi or Bluetooth. The hover face's time opens
  Calendar and its battery opens the battery settings, as in the bar.
- Keyboard in the hover face and the Dynamic Bar uses the same keys: → ↓ Tab move on, ← ↑ Shift+Tab move back,
  Home/End, Return or Space activate, and Shift+Return or the Menu key do what right-click does.
- Middle click plays or pauses in the Dynamic Bar and Bar-Edge too (the same «Middle click» setting as the capsule);
  the bar's play/pause button is reachable from the keyboard.
- With the weather in °F, system temperatures (Dynamic Bar, Monitor, System, lock screen and temperature alerts)
  are shown in °F as well. Readings and thresholds are unchanged.

### Added

- Global shortcut `dockToggle` (default `SUPER+CTRL+E`): turns Edge on or off on the focused monitor, like the IPC
  verb of the same name. The contract now lists 33 shortcuts.
- A speed test in progress shows in the Dynamic Bar and Bar-Edge as a segment (like recording) and in the capsule
  in the network circle; Edge keeps its ear.
- Running tasks and downloads: a count on the Dashboard button (hover face and bar) and, in Edge, a new live
  activity («Tasks and downloads», Settings → Edge).
- The clock's tooltip names the next calendar event; with the weather on, the date shows the temperature
  («FRI 27 NOV · 18°»).
- Control Center: a row with the power profile (opens Performance) and Keep awake; when a display has no brightness
  control, a note under the controls says why.
- «Copied» in Edge also after choosing an item from the clipboard history.
- Settings → System → Environment lists the audio visualizer (cava) and screen recording (wf-recorder).

- `install.sh migrate identity-v1`: copies the state of the former name (never moves it). Also `--recover` and
  `--revert`.
- `install.sh check` reports a Kitasan-Shell that is still installed or running, its units, its state and an old
  matugen output.
- `tests/release/version-check.py`: checks that `version.json`, the Arch recipes, the README, `API.md` and this file
  agree.
- Optional integration with `sysupdate` 2.0 (a separate tool, part of Sumi-Files; nothing changes
  without it):
  - The updates cache may carry a `risk` field (additive; `text`, `tooltip` and `class` are unchanged). A non-empty
    `risk` means `sysupdate check` found a package that would run against dependencies it was not rebuilt for, such
    as quickshell against a new Qt. The Dashboard («Upgrade system» and the Overview issue), the Dynamic Bar and the
    Dynamic Capsule show it in red. Upgrade still works: the shell only informs.
  - With risk and `sysupdate` installed, the Dashboard offers **Safe upgrade**: `sysupdate -i <globs>` in the
    terminal, holding back what sysupdate suggests.
  - The built-in provider (`updates-provider.py`) asks `sysupdate check --json --no-sync --no-aur` after
    `checkupdates` and writes `risk`, `risk_packages` and `risk_ignore`. `--upgrade` runs sysupdate instead of
    yay/paru or `sudo pacman -Syu`, and `--upgrade --ignore <globs>` holds packages back.
  - The built-in provider retries the AUR query (`-Qua`) once after a network error.

### Fixed

- Lock rescue on a system without `hyprlock.conf`: hyprlock 0.9 refuses to start without one, so the session stayed
  locked with no client. The rescue now uses the user's config, or the one hyprlock ships.
- Helpers no longer write `__pycache__` into the shell's tree, so uninstalling removes the tree completely.
- Middle-clicking the Dynamic Bar's notification bell asks to clear all, like the capsule's hover face. Asking while
  the notifications panel was already open (its hover preview) reported a binding loop.
- The hold buttons' drain, the Wallhaven loading sweep and the test countdown follow the animation speed and the
  Off/Reduced setting (including the temporary override).

## [0.4.0] - 2026-10-12

The last version under the name Kitasan-Shell. It was never published as a release; its history is in the git log.
