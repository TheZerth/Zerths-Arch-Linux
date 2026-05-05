# Lapis Obscura Wallpapers

This directory contains wallpaper assets for the Zerth Arch / Hyprland setup.

## Directories

- `references/` — optional local inspiration/reference downloads; ignored by git.
- `ancient-megaliths/` — tracked imported megalith/temple wallpaper set used by the installer for the default live wallpaper deployment.
- `lapis-obscura/` — custom generated wallpapers for the Lapis Obscura theme, kept in-repo as additional themed assets.
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

`ZerthArchInstall.sh` copies `wallpapers/ancient-megaliths/` into:

```text
~/Pictures/Wallpapers/AncientMegaliths/
```

Then it writes `~/.config/hypr/hyprpaper.conf` using `wallpaper { ... }` blocks with `fit_mode = cover` so the images crop/fill the screen.

Default assignments:

- `DP-3` → `lapis-obscura-ancient-megalith-world-01.png`
- `DP-2` → `lapis-obscura-ancient-megalith-temple-01.png`
- fallback → `lapis-obscura-ancient-megalith-world-01.png`

Optional monitor-specific overrides:

```bash
ZERTH_HYPRPAPER_ULTRAWIDE_OUTPUT=DP-3
ZERTH_HYPRPAPER_PORTRAIT_OUTPUT=DP-2
```

By default, the installer assigns `lapis-obscura-ancient-megalith-world-01.png` to `DP-3` and `lapis-obscura-ancient-megalith-temple-01.png` to `DP-2`; both are displayed with `fit_mode = cover` so they crop/fill the monitor.

You can also override individual wallpaper paths:

```bash
ZERTH_HYPRPAPER_WALLPAPER=/path/to/default.png
ZERTH_HYPRPAPER_ULTRAWIDE_WALLPAPER=/path/to/ultrawide.png
ZERTH_HYPRPAPER_PORTRAIT_WALLPAPER=/path/to/portrait.png
```
