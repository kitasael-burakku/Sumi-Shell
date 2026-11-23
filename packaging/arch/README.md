# Arch package candidates (F6g)

These recipes are for local builds. The stable recipe takes its source from a
local archive. The checked-in Git recipe has an upstream URL, and the local
builder generates a Git recipe that reads the supplied checkout. There is no
release tag or AUR installation path for these candidates.

Generate complete build directories (including the tarball and shared recipe
files), then build both packages without installing dependencies or packages:

```sh
python3 packaging/arch/build-local.py "$PWD" "$PWD" ../sumi-arch-build
```

The output directory must be new. The repository argument must be the extracted
distribution (`sumi/`, `packaging/`, `API.md`, `LICENSE`). Stable takes an
archive of its HEAD with a SHA-256 checksum; `-git` clones its local git source
and derives `version.r<count>.g<hash>` from `version.json` and git history.
The builder creates no commits or tags. It uses `makepkg --nodeps`. The stable
0.4.0 candidate's dependency resolution and pacman lifecycle were exercised
separately in a clean Arch VM. See the [acceptance report](../../docs/PORTABILITY-ACCEPTANCE.md)
for the result and its limits.

`package.py` uses the user installer's runtime filter and build identity. There
is no second exclusion list. Runtime bytes and modes are unchanged; units and
examples installed outside the runtime are rendered with system paths. License
directories use each actual package name. No `backup=()` entries are declared:
the QML under `/etc/xdg` is code discovered by Quickshell, not personal settings.
The two package variants conflict and `-git` provides `sumi-shell`.

`ARCH.md` is the installed usage and lifecycle guide. Updates require the shell
to be stopped while unlocked **before** the package transaction. This is a user
precondition, not an automatic guard or an operation performed by a hook.
Installing packages must not enable services or edit any user's home.

Before publishing: the upstream URL is <https://github.com/kitasael-burakku/Sumi-Shell>; choose the release tag, verify its
version and checksum, replace the local sources, regenerate `.SRCINFO`, and run
the payload and namcap checks again. The current source is `0.4.0`; this directory
does not declare a release merely by containing a stable PKGBUILD.
