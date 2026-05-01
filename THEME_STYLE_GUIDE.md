# Zerth Arch Theme Style Guide

Working name: **Lapis Obscura**

A dark-stone, low-dependency Hyprland/TUI visual system inspired by Hermes TUI, btop, Gruvbox, cyberpunk sorcery, lo-fi wizardry, sacred geometry, alchemy, Daoist/Buddhist non-dualism, megalithic minimalism, Devine Lu Linvega's restrained computing-art sensibility, 90s vaporwave tech futurism, and old-school dithered graphics.

This document is the visual reference for future configuration work in this repo: Hyprland, foot, eww, dunst, fuzzel, btop, hyprlock, hyprpaper, shell prompts, generated wallpapers, and any project that should feel native to this system.

---

## 1. Core feeling

The theme should feel like:

- A terminal carved into black basalt.
- Old stone warmed by a few occult accent lights.
- Moss, rust, amber, and violet magic occasionally wisping from cracks.
- Minimal TUI geometry, not glossy desktop decoration.
- Quiet power: robust, legible, efficient, ritualistic.
- Dark and light held together, but with darkness as the ground.
- A forgotten 90s workstation found inside a stone temple: minimal, strange, luminous, and precise.
- Dithered gradients and limited-color artifacts used intentionally, like digital patina.

Avoid:

- Bright neon everywhere.
- Rounded, bubbly, soft SaaS design.
- Heavy gradients, glassmorphism, blur-heavy effects, or dependency-heavy visual stacks.
- Decorative complexity that reduces legibility.
- Pure black/white contrast except for rare emphasis.
- Smooth glossy vaporwave excess. Keep the vaporwave influence restrained and mineralized.

Design mantra:

> Dark stone first. Gruvbox as mineral accent. Magic only where it matters.

---

## 2. Philosophical direction

### Non-dualism

The palette should not split cleanly into good/light and bad/dark. Light emerges from dark. Color emerges from stone. Accents should feel like latent energy inside matter.

Use:

- Dark base surfaces.
- Muted light text.
- Warm gold/amber for wisdom, focus, and active states.
- Moss green for growth, success, life, and groundedness.
- Violet/magenta for magic, selection, portals, rare emphasis.
- Rust/red for danger, blood, heat, and destructive actions.
- Cyan/blue sparingly for information, water, signal, and machine intelligence.

### Lo-fi wizardry

The system should feel handmade, old, and functional. Use pixel/bitmap-friendly fonts, sharp edges, sparse lines, glyphs, and simple sacred shapes.

### Megalithic minimalism

Most UI elements should feel like slabs, cuts, grooves, runes, and carved outlines.

Use:

- 1px borders.
- Low/no rounding.
- Minimal shadows.
- Thin separators.
- Strong negative space.
- Rectangles, triangles, circles, dots, and hexagonal motifs.

---

## Retro computing and dither influence

Add a quiet 90s vaporwave / old-machine layer to the stone system. The influence should come from constrained computing art, fantasy consoles, limited palettes, and Devine Lu Linvega-like restraint: symbolic, handmade, sparse, and deeply intentional.

Use:

- Dithered gradients instead of smooth gradients where images or generated assets are involved.
- Limited palettes that feel like old hardware, not modern RGB abundance.
- Pixel-grid precision, bitmap texture, and crisp monochrome glyphs.
- Thin-line diagrams, old workstation UI, fantasy-console austerity, and small symbolic marks.
- Vaporwave colors as rare spectral light: violet, dusty pink, cyan, and amber reflecting off black stone.

Avoid:

- Full synthwave neon backgrounds.
- Palm-tree/outrun cliches unless heavily abstracted into glyphs or shadows.
- Smooth 3D chrome, glossy gradients, and modern gamer RGB.
- Copying any artist directly; treat this as a shared sensibility of restrained handmade computing art.

Dithering guidance:

```text
Best use:      wallpapers, lockscreen backgrounds, small icons, generated art, subtle panel texture
Avoid use:     body text, dense terminal regions, code backgrounds, critical UI contrast
Pattern feel:  1-bit, 2-bit, ordered Bayer, error diffusion, halftone dust
Opacity:       very low; texture should be felt before it is seen
```

Retro-futurist accent rule:

> Vaporwave is the ghost-light. Stone is still the body.

---

## 3. Geometry language

Preferred shapes:

- Dot: seed, point of awareness, process, idle state.
- Circle: wholeness, cycle, breath, clock, focus ring.
- Triangle: fire, transformation, direction, warning, invocation.
- Hexagon: structure, crystal, honeycomb, network, system node.
- Diamond: selection, gem, focus, cursor, active workspace.
- Line: path, command, channel, meridian.
- Square/rectangle: stone slab, terminal cell, grounded container.

Rules:

- Use mostly rectangles and lines for functional UI.
- Use dots/circles for status indicators.
- Use triangles for warnings, expansion indicators, arrows, and ritual markers.
- Use hexagons/diamonds sparingly for identity marks, launchers, workspace icons, and active states.
- Use sacred geometry as quiet structure, not wallpaper clutter.

Suggested glyph vocabulary:

```text
·  •  ◦  ○  ●  ◌
△  ▲  ▴  ▵  ▸  ◂
◇  ◆  ✦  ✧  ✶
⬡  ⬢  ⌬
☉  ☽  ☾  ☿  ♄
🜁  🜂  🜃  🜄
```

Use emoji symbols cautiously in terminal contexts; prefer monochrome Unicode glyphs where possible.

---

## 4. Ratio and spacing system

Use sacred and aesthetically stable ratios, but keep implementation simple.

Primary ratios:

- Golden ratio: `1.618`
- Silver ratio: `1.414`
- Minor third: `1.2`
- Perfect fourth: `1.333`
- Perfect fifth: `1.5`

Practical scale:

```text
1   2   3   5   8   13   21   34   55
```

Use this Fibonacci-like scale for:

- Gaps
- Margins
- Padding
- Border emphasis
- Overlay sizes
- Animation durations, if animations are enabled

Recommended defaults:

```text
Micro gap:       2px
Small gap:       5px
Medium gap:      8px
Large gap:       13px
Panel padding:   13px
Major padding:   21px
Overlay margin:  34px
```

Hyprland direction:

```text
gaps_in = 2
gaps_out = 5
border_size = 1
rounding = 0 or 2
```

Rounding guidance:

- Default: `0px` for cut stone.
- Optional soft stone: `2px` maximum.
- Avoid large rounded corners.

---

## 5. Palette: dark stone plus Gruvbox mineral accents

### Base stone colors

These are the dominant colors. Most UI should use these.

| Token | Hex | Use |
|---|---:|---|
| `stone_void` | `#050408` | Deepest background, lockscreen, terminal base |
| `stone_black` | `#090812` | Main background |
| `stone_obsidian` | `#0d0b18` | Secondary panels |
| `stone_basalt` | `#111016` | Elevated panel / input field |
| `stone_slate` | `#171522` | Selection base / inactive slab |
| `stone_iron` | `#24212c` | Borders, separators, muted blocks |
| `stone_ash` | `#55515d` | Disabled text / inactive border |
| `stone_mist` | `#918999` | Comments, placeholders, secondary text |
| `stone_moon` | `#c8c8d0` | Primary text |
| `stone_bone` | `#e4e0e8` | Strong text / rare highlight |

### Warm alchemical colors

Inspired by Gruvbox warmth, but treated as metals, embers, rust, and candlelight.

| Token | Hex | Use |
|---|---:|---|
| `gold_sigil` | `#d8a657` | Focus, active border, primary highlight |
| `amber_lantern` | `#fabd2f` | Warnings, active command, selected icon |
| `copper_rune` | `#d65d0e` | Secondary accent, hotkey markers |
| `rust_blood` | `#cc241d` | Errors, destructive actions |
| `ember_red` | `#fb4934` | Urgent warning only |

### Moss and earth colors

Use as living accents against stone.

| Token | Hex | Use |
|---|---:|---|
| `moss_deep` | `#3c4f2f` | Muted success background |
| `moss_glyph` | `#98971a` | Success, growth, OK state |
| `lichen_light` | `#b8bb26` | Bright success / rare highlight |
| `earth_clay` | `#a89984` | Warm neutral text, old parchment |

### Magic colors

Use sparingly. These should feel like wisps coming off stone, not the whole surface.

| Token | Hex | Use |
|---|---:|---|
| `violet_arcane` | `#8f7dff` | Active workspace, magic accent, selected widget |
| `amethyst_dim` | `#5d4b8c` | Muted violet border/background |
| `fuchsia_portal` | `#d3869b` | Rare magical emphasis |
| `cyan_spirit` | `#83a598` | Info, network, signal |
| `aqua_ritual` | `#8ec07c` | Calm positive info |

### Minimal semantic palette

```text
Background:       stone_void / stone_black
Panel:            stone_obsidian / stone_basalt
Border inactive:  stone_iron / stone_ash
Border active:    gold_sigil -> stone_moon gradient, or violet_arcane sparingly
Text primary:     stone_moon
Text strong:      stone_bone
Text muted:       stone_mist
Success:          moss_glyph
Warning:          amber_lantern
Error:            rust_blood
Info:             cyan_spirit
Magic:            violet_arcane
```

---

## 6. Color proportion rule

Use a 70/20/8/2 balance:

```text
70% dark stone base
20% muted stone text and structure
 8% warm/moss/cyan functional accents
 2% arcane glow or sacred emphasis
```

If the UI starts feeling neon, reduce accent use by half.

If the UI starts feeling monochrome and dead, add moss/gold/violet only to active, selected, or status elements.

---

## 7. Borders, shadows, and glow

### Borders

Preferred:

```text
Inactive border: 1px stone_iron or stone_ash at reduced opacity
Active border:   1px gold_sigil, stone_moon, or subtle angled gradient
```

Hyprland active border concept:

```text
col.active_border = rgba(d8a657ff) rgba(c8c8d0ff) rgba(8f7dffff) 45deg
col.inactive_border = rgba(55515dcc) rgba(0d0b18cc) rgba(24212ccc) 45deg
```

Use gradients only where the compositor already supports them cheaply.

### Shadows

Default: off.

If used, shadows should be shallow and ritualistic, not soft/glassy:

```text
shadow color: rgba(0, 0, 0, 0.35)
magic glow:   rgba(143, 125, 255, 0.20) only on active/selected elements
```

### Blur

Default: off.

Blur is not core to this identity. The theme should work in crisp terminal environments.

---

## 8. Typography

Preferred terminal fonts:

- ProggyClean
- Terminus
- Berkeley Mono, if available
- JetBrains Mono, if a modern fallback is needed
- Iosevka, if narrow density is preferred

Current repo direction:

```text
Foot: ProggyClean, 16px
Console: Terminus
```

Typography rules:

- Prioritize legibility and density.
- Avoid huge UI text.
- Use uppercase sparingly for ritual labels, panel headers, and buttons.
- Prefer terse labels: `TERM`, `MENU`, `LOCK`, `NET`, `VOL`, `SYS`.
- Use glyphs as markers, not replacements for critical text.

Suggested sizes:

```text
Terminal text:  14-16px
Panel text:     13-16px
Header text:    16-21px
Tiny labels:    10-13px
```

---

## 9. UI component guidance

### Terminal / foot

Foot should feel like the root altar: plain, fast, readable.

```ini
[colors]
background=050408
foreground=c8c8d0
regular0=090812
regular1=cc241d
regular2=98971a
regular3=d8a657
regular4=83a598
regular5=d3869b
regular6=8ec07c
regular7=c8c8d0
bright0=55515d
bright1=fb4934
bright2=b8bb26
bright3=fabd2f
bright4=83a598
bright5=8f7dff
bright6=8ec07c
bright7=e4e0e8
```

### Hyprland

Hyprland should stay sharp and minimal:

```text
animations = false
blur = false
shadow = false
rounding = 0 or 2
gaps_in = 2
gaps_out = 5
border_size = 1
```

Use active borders as the main visual flourish.

### Eww overlay

Eww should feel like a summoned control glyph or stone tablet.

Use:

- Dark translucent stone base.
- 1px inner border.
- Sparse violet/gold glow only around active widgets.
- Rectangular buttons.
- Dot/diamond status markers.
- Short all-caps labels.

Suggested panel colors:

```scss
$bg: #050408;
$panel: #090812;
$panel2: #0d0b18;
$border: #24212c;
$text: #c8c8d0;
$muted: #918999;
$gold: #d8a657;
$violet: #8f7dff;
$moss: #98971a;
$red: #cc241d;
```

### Fuzzel

Fuzzel should be a command portal, not an app-store card.

```ini
[colors]
background=050408ee
text=c8c8d0ff
match=d8a657ff
selection=171522ff
selection-text=e4e0e8ff
selection-match=fabd2fff
border=55515dcc
```

Use a small width, tight padding, and crisp border.

### Dunst

Notifications should look like stone message tablets.

```ini
[urgency_low]
background = "#090812"
foreground = "#918999"
frame_color = "#24212c"

[urgency_normal]
background = "#0d0b18"
foreground = "#c8c8d0"
frame_color = "#55515d"

[urgency_critical]
background = "#111016"
foreground = "#e4e0e8"
frame_color = "#cc241d"
```

### Btop

Btop should be one of the main references: dark, dense, readable, colorful only as signal.

Direction:

- Background: `stone_void`
- Main text: `stone_moon`
- CPU: `gold_sigil`
- Memory: `violet_arcane`
- Disk: `moss_glyph`
- Network receive: `cyan_spirit`
- Network send: `copper_rune`
- Warning/error: `amber_lantern` / `rust_blood`

### Hyprlock

Hyprlock should feel like a sealed gate.

Use:

- Void background.
- One centered circle/ring or diamond.
- Muted placeholder text.
- Gold or moon color for verified state.
- Rust for failure.
- Optional sigil glyph above input: `◇`, `☉`, `△`, or `⬡`.

---

## 10. Wallpaper direction

Wallpapers should be minimal and mostly dark.

Good subjects:

- Basalt monoliths.
- Black stone slabs.
- Moss growing in cracks.
- Gold inlay lines.
- Dim violet mist.
- Sacred geometry etched into stone.
- Lunar circles, triangular gates, hexagonal crystals.
- Alchemical diagrams treated as carved marks.

Composition:

- Large dark negative space.
- One focal shape or sigil.
- Low contrast stone texture.
- Accent light should occupy less than 5% of the image.
- Dithered or limited-palette shading is preferred over smooth airbrushed gradients.
- 90s workstation / vaporwave futurism may appear as ghostly gridlines, horizon bands, spectral cyan-pink light, or pixel artifacts, but should remain subordinate to the stone-temple mood.
- Avoid busy fantasy illustration.

Prompt seed:

```text
minimal dark basalt stone monolith, sacred geometric circle and triangle etched in faint gold, sparse moss in cracks, subtle violet magical wisp, restrained 90s vaporwave workstation futurism, old-school dithered limited-palette texture, lo-fi cyberpunk sorcery, megalithic minimalism, high contrast but mostly black, no characters, no glossy surfaces, no clutter
```

---

## 11. Naming system

Use names that feel geological, alchemical, and contemplative.

Good token names:

```text
stone_void
stone_basalt
obsidian_panel
gold_sigil
amber_lantern
moss_glyph
violet_arcane
fuchsia_portal
cyan_spirit
rust_blood
moon_text
bone_text
```

Good component names:

```text
altar
sigil
tablet
monolith
rune
gate
circle
hex
wisp
```

Avoid overly generic names where possible:

```text
primary
secondary
blue1
background2
```

Generic names are acceptable only when required by a config format.

---

## 12. Accessibility and legibility

Legibility beats symbolism.

Rules:

- Primary text on base background should be high contrast.
- Muted text must still be readable in a terminal.
- Do not encode critical state by color alone; use glyphs or labels too.
- Keep error red distinct from amber warning.
- Avoid dark red text on dark stone unless it has a border/icon.
- Avoid violet text for long paragraphs.

Suggested contrast pairs:

```text
stone_void + stone_moon
stone_black + stone_moon
stone_obsidian + stone_bone
stone_basalt + gold_sigil
stone_basalt + moss_glyph
stone_basalt + cyan_spirit
```

---

## 13. Implementation priorities for this repo

Suggested order:

1. Define shared palette comments in the install script near theme-related config functions.
2. Update foot colors.
3. Update fuzzel colors and sizing.
4. Update dunst notification colors.
5. Refine eww overlay around the stone/glyph language.
6. Refine hyprlock as a sealed-gate lockscreen.
7. Add btop theme file if btop supports direct theme deployment cleanly.
8. Optionally generate or document a wallpaper path using the wallpaper prompt direction.

Keep dependencies minimal. Prefer native config files over adding theme frameworks.

---

## 14. Quick reference

```text
Theme name:       Lapis Obscura
Core material:    black basalt / obsidian
Core mood:        lo-fi cyberpunk wizard TUI, restrained 90s workstation futurism
Geometry:         rectangle, dot, circle, triangle, hexagon, diamond
Texture:          old-school dithering, limited palettes, pixel-grid precision
Ratios:           1, 2, 3, 5, 8, 13, 21, 34
Base colors:      #050408 #090812 #0d0b18 #111016 #24212c
Text colors:      #918999 #c8c8d0 #e4e0e8
Main accents:     #d8a657 #98971a #8f7dff #83a598 #cc241d
Default shape:    sharp 1px stone slab
Default effect:   no blur, no shadow, minimal glow
Accent rule:      color is magic escaping stone, not paint on everything
```

---

## 15. One-line style test

A new UI element belongs in this theme if it can be described as:

> A carved dark-stone TUI control with one quiet sign of living moss, warm metal, arcane light, or dithered old-machine ghostlight.
