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

### Added

- `install.sh migrate identity-v1`: copies the state of the former name (never moves it). Also `--recover` and
  `--revert`.
- `install.sh check` reports a Kitasan-Shell that is still installed or running, its units, its state and an old
  matugen output.
- `tests/release/version-check.py`: checks that `version.json`, the Arch recipes, the README, `API.md` and this file
  agree.

### Fixed

- Lock rescue on a system without `hyprlock.conf`: hyprlock 0.9 refuses to start without one, so the session stayed
  locked with no client. The rescue now uses the user's config, or the one hyprlock ships.
- Helpers no longer write `__pycache__` into the shell's tree, so uninstalling removes the tree completely.

## [0.4.0] - 2026-10-12

The last version under the name Kitasan-Shell. It was never published as a release; its history is in the git log.
