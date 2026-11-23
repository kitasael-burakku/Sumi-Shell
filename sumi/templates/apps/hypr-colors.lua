-- Sumi Shell — colours of the Hyprland window border. Written by the shell's theme provider (set up with
-- `install.sh theme-apps --apply hyprland`). Do not edit: it is rewritten on every theme change. The fragment that
-- `install.sh hyprland --apply` writes (sumi-shell.lua) reads it on every (re)load; the theme provider applies it
-- right away too.
return {
  active_border   = { colors = { "rgba({{colors.primary.default.hex_stripped}}cc)", "rgba({{colors.secondary.default.hex_stripped}}99)" }, angle = 45 },
  inactive_border = "rgba({{colors.outline_variant.default.hex_stripped}}aa)",
}
