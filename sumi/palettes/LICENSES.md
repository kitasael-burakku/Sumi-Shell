# Static palettes: sources and licences

Each `<family>-<variant>.json` here freezes the colour values of a published palette, mapped once to the Material 3
roles that the shell's matugen templates read. Every file records the exact source URLs, their SHA-256 at download
time, the mapping and which roles were derived (and how). They were built with `tools/palettes/build-presets.py`
in the Quickshell project; the shell never derives colours at run time.

## Catppuccin (catppuccin-mocha, catppuccin-latte)

Palette: https://github.com/catppuccin/palette (palette.json 1.8.0). Terminal colours: https://github.com/catppuccin/kitty.

    MIT License
    
    Copyright (c) 2021 Catppuccin
    
    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:
    
    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.
    
    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.

## Gruvbox (gruvbox-dark, gruvbox-light)

Palette: https://github.com/morhetz/gruvbox (`colors/gruvbox.vim`), by Pavel Pertsev. The README states the licence
as MIT/X11 and `package.json` says `"license": "MIT"`; the repository has no LICENSE file with a copyright line.
Terminal colours: https://github.com/morhetz/gruvbox-contrib (`xresources/`), which defines no cursor or selection
colours: those are derived and marked in `terminalDerived`.
