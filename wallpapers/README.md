# Lapis Obscura Wallpapers

This directory contains wallpaper assets for the Zerth Arch / Hyprland setup.

## Directories

- `references/` — optional local inspiration/reference downloads; ignored by git.
- `lapis-obscura/` — custom generated wallpapers for the Lapis Obscura theme, tracked because the installer deploys them.
- `scripts/generate_lapis_obscura_wallpapers.py` — procedural wallpaper generator.

## Generated sizes

Each custom wallpaper variant is generated in:

- `3440x1440` — ultrawide landscape.
- `2560x1440` — standard 16:9 landscape.
- `1440x2560` — portrait monitor orientation. This is the portrait equivalent of 2560x1440.

## Variants

- `terminal-temple` — basalt terminal slabs, sacred geometry, restrained cyberpunk wirework.
- `wire-oracle` — dense cable/interface field with an abstract oracle/halo motif.
- `moon-gate` — darker mythic silhouette, moon/portal geometry, sparse terminal debris.

## Installer behavior

`ZerthArchInstall.sh` copies `wallpapers/lapis-obscura/` into:

```text
~/Pictures/Wallpapers/LapisObscura/
```

Then it writes `~/.config/hypr/hyprpaper.conf` to preload those local images and use the ultrawide `terminal-temple` wallpaper by default.

Optional monitor-specific overrides:

```bash
ZERTH_HYPRPAPER_ULTRAWIDE_OUTPUT=DP-3
ZERTH_HYPRPAPER_PORTRAIT_OUTPUT=DP-2
```

By default, the installer assigns the 3440x1440 wallpaper to `DP-3` and the 1440x2560 portrait wallpaper to `DP-2`.

You can also override individual wallpaper paths:

```bash
ZERTH_HYPRPAPER_WALLPAPER=/path/to/default.png
ZERTH_HYPRPAPER_ULTRAWIDE_WALLPAPER=/path/to/ultrawide.png
ZERTH_HYPRPAPER_PORTRAIT_WALLPAPER=/path/to/portrait.png
```
