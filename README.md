# Shaka

A friendly macOS window manager that works with your natural workflow. No rigid tiling grids — just smooth, intuitive window nudging with spring-based animations.

## Features

- **Focus** — Switch focus to the nearest window in any direction
- **Move** — Nudge windows around with smooth spring animations
- **Resize** — Grow or shrink windows from center
- **Center & Fill** — Quick-center or maximize with padding
- **Edge Snapping** — Windows snap to screen edges for tidy alignment
- **Configurable** — TOML config for keybindings, step sizes, and animation feel
- **Multi-monitor** — Aware of all connected displays
- **Menu bar app** — Lives in the menu bar as 🤙, no dock clutter

## Install

Requires macOS 13+ and Xcode Command Line Tools (`xcode-select --install`).

```bash
curl -fsSL https://raw.githubusercontent.com/wes/shaka/main/install.sh | bash
```

Or clone and build manually:

```bash
git clone https://github.com/wes/shaka.git
cd shaka
make install
```

Either way, `Shaka.app` gets installed to `/Applications`. Launch it from Spotlight or `/Applications`.

### Grant Accessibility Permission

Shaka needs Accessibility access to manage windows. On first launch, macOS will prompt you — or grant it manually:

**System Settings → Privacy & Security → Accessibility → Shaka ✓**

### Uninstall

```bash
rm -rf /Applications/Shaka.app ~/.config/shaka
```

Then remove Shaka from **System Settings → Privacy & Security → Accessibility**.

## Usage

Default shortcuts (with `ctrl` as the leader key):

| Shortcut | Action |
|---|---|
| `ctrl` + `←→↑↓` | Focus nearest window in direction |
| `ctrl` + `opt` + `←→↑↓` | Move window |
| `ctrl` + `shift` + `←→↑↓` | Resize window |
| `ctrl` + `return` | Center window on screen |
| `ctrl` + `shift` + `return` | Fill screen (with padding) |

> **Note:** `ctrl` + arrow keys may overlap with macOS Mission Control shortcuts. Disable them in **System Settings → Keyboard → Keyboard Shortcuts → Mission Control**, or change the leader key to `"opt"` in the config.

## Configuration

Config lives at `~/.config/shaka/config.toml` — created automatically on first launch.

```toml
# Modifier key: "ctrl", "opt" / "alt", "cmd", "shift"
leader = "ctrl"

move_step = 80
resize_step = 80
edge_snap = 20
screen_padding = 10

# Spring animation parameters
animation_stiffness = 300   # higher = faster
animation_damping = 28      # higher = less bounce

[bindings]
focus_left     = "leader+left"
focus_right    = "leader+right"
focus_up       = "leader+up"
focus_down     = "leader+down"
move_left      = "leader+opt+left"
move_right     = "leader+opt+right"
move_up        = "leader+opt+up"
move_down      = "leader+opt+down"
grow_width     = "leader+shift+right"
shrink_width   = "leader+shift+left"
grow_height    = "leader+shift+up"
shrink_height  = "leader+shift+down"
center         = "leader+return"
fill           = "leader+shift+return"
```

Edit the config from the menu bar (**🤙 → Edit Config...**) and apply changes with **🤙 → Reload Config** — no restart needed.

### Key names for bindings

| Category | Keys |
|---|---|
| Arrows | `left`, `right`, `up`, `down` |
| Special | `return`, `space`, `tab`, `escape`, `delete` |
| Letters | `a`–`z` |
| Numbers | `0`–`9` |

Combine with `+`: `"leader+shift+left"`, `"ctrl+opt+a"`, etc.

## Building from source

```bash
# Run in development mode
make run

# Build release binary only
make build

# Build .app bundle without installing
make bundle
```

## License

[MIT](LICENSE)
