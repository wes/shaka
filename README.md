# Shaka

A macOS window manager with two personalities.

**Flow** lets windows drift — nudge, resize and snap them wherever you like, with
spring animations and no rules. **Reef** is the hard structure underneath: a
Hyprland-style tiling layout where every window is a tile and nothing overlaps.

One keystroke switches between them, and both modes use the same keys.

## Features

- **Two modes, same keys** — `⌃` + `/` toggles between Flow and Reef
- **Flow** — focus, nudge, resize, center, fill and snap windows freely
- **Reef** — dwindle/BSP tiling: every window is a tile, no overlap, real gaps
- **Lossless switching** — Reef remembers where every window was and puts it back
- **Configurable** — TOML config for keybindings, step sizes, gaps and animation feel
- **Multi-monitor** — each display gets its own layout
- **Menu bar app** — lives in the menu bar, no dock clutter

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

> **Re-granting after an update.** Shaka is ad-hoc signed, so its code signature
> changes every time the binary is rebuilt, and macOS invalidates the permission.
> The catch is that System Settings keeps showing Shaka as ticked while denying it
> — no prompt appears, and every shortcut silently stops working. After any
> `make install`, remove Shaka from the Accessibility list with `−` and add
> `/Applications/Shaka.app` back, or run:
>
> ```bash
> tccutil reset Accessibility com.wes.shaka
> ```
>
> then relaunch Shaka and accept the prompt. If shortcuts ever go dead, this is
> almost always why — the menu bar icon shows 🤙⚠ and the menu says so.

### Uninstall

```bash
rm -rf /Applications/Shaka.app ~/.config/shaka
```

Then remove Shaka from **System Settings → Privacy & Security → Accessibility**.

## Modes

Shaka starts in **Flow**. Press `⌃` + `/` (or pick from the menu bar) to switch.
The menu bar icon tells you where you are: 🤙 for Flow, 👊 for Reef.

### Flow 🤙

Windows float wherever you put them. Nothing is enforced — Shaka just moves the
focused window for you, with spring animation and edge snapping.

### Reef 👊 *(experimental)*

Entering Reef grabs every window on every display and packs it into a dwindle
tree, the way Hyprland's default layout works: each new window splits the focused
tile in half, along that tile's long axis, so the layout spirals inward.

```
┌─────────────┬─────────────┐
│             │      B      │
│      A      ├──────┬──────┤
│             │  C   │  D   │
└─────────────┴──────┴──────┘
```

Nothing overlaps, everything is reachable, and windows that open or close while
you're in Reef get tiled or reclaimed automatically. Switching back to Flow puts
every window back exactly where Reef found it — the structure is something you
drop onto your screen and lift off again, not something you commit to.

## Usage

Default shortcuts, with `ctrl` as the leader key. **The same keys do the
equivalent thing in each mode:**

| Shortcut | Flow 🤙 | Reef 👊 |
|---|---|---|
| `ctrl` + `←→↑↓` | Focus nearest window | Focus tile in direction |
| `ctrl` + `opt` + `←→↑↓` | Nudge window | Swap tile with its neighbour |
| `ctrl` + `shift` + `←→↑↓` | Grow / shrink window | Resize the split |
| `ctrl` + `cmd` + `←→↑↓` | Snap (cycles ½ → ⅓ → ⅔) | Send window to the next display |
| `ctrl` + `return` | Center window | Promote to master tile |
| `ctrl` + `shift` + `return` | Fill screen | Toggle fullscreen |
| `ctrl` + `/` | Switch to Reef | Switch to Flow |

Reef adds three actions that have no Flow equivalent:

| Shortcut | Action |
|---|---|
| `ctrl` + `shift` + `s` | Toggle split direction (Hyprland's `togglesplit`) |
| `ctrl` + `shift` + `f` | Toggle floating — the window leaves the tiling and gets Flow behaviour |
| `ctrl` + `opt` + `tab` | Cycle focus through tiles |

> **Note:** `ctrl` + arrow keys may overlap with macOS Mission Control shortcuts. Disable them in **System Settings → Keyboard → Keyboard Shortcuts → Mission Control**, or change the leader key to `"opt"` in the config.

## Configuration

Config lives at `~/.config/shaka/config.toml` — created automatically on first launch.

```toml
# Modifier key: "ctrl", "opt" / "alt", "cmd", "shift"
leader = "ctrl"

# Which mode to start in: "flow" or "reef"
default_mode = "flow"

# --- Flow mode ---
move_step = 80
resize_step = 80
edge_snap = 20
screen_padding = 10

# --- Reef mode ---
# gaps_out: space at the screen edge
# gaps_in:  space around each tile, so neighbours sit 2x this apart
gaps_in = 6
gaps_out = 12

# Spring animation parameters (both modes)
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
snap_left      = "leader+cmd+left"
snap_right     = "leader+cmd+right"
snap_up        = "leader+cmd+up"
snap_down      = "leader+cmd+down"
center         = "leader+return"
fill           = "leader+shift+return"
toggle_mode    = "leader+/"
toggle_split   = "leader+shift+s"
toggle_float   = "leader+shift+f"
cycle_next     = "leader+opt+tab"
```

Bindings you leave out fall back to the defaults, so an older config keeps working
and picks up new actions automatically.

Edit the config from the menu bar (**🤙 → Edit Config...**) and apply changes with **🤙 → Reload Config** — no restart needed.

### Key names for bindings

| Category | Keys |
|---|---|
| Arrows | `left`, `right`, `up`, `down` |
| Special | `return`, `space`, `tab`, `escape`, `delete` |
| Letters | `a`–`z` |
| Numbers | `0`–`9` |

Combine with `+`: `"leader+shift+left"`, `"ctrl+opt+a"`, etc.

## Reef mode caveats

Reef is experimental. Known rough edges:

- Dragging or resizing a tiled window with the mouse is not corrected — the tile
  keeps its assigned frame until the next layout pass.
- Apps that refuse to resize (fixed-size windows, some Electron apps and dialogs)
  will not tile cleanly. `ctrl` + `shift` + `f` floats them out of the way.
- Only the dwindle layout is implemented; Hyprland's master layout is not.
- macOS Spaces are not tracked. Each display has one layout, not one per Space.

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
