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
- **Workspaces** — nine per display, `⌃` + `1`–`9`, each with its own tiling
- **Mouse resizing** — drag a tile's border and the whole column reflows around it
- **Cheat sheet** — `⌃` + `k` puts every shortcut for the mode you are in on screen
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

#### Resizing

Every edge of a tile that isn't the screen border is the split line of exactly
one node in the tree, so resizing is never approximate: drag an edge and that one
split moves, the tiles on both sides of it reflow, and everything else stays put.

Three ways to do it, all hitting the same machinery:

- `⌃` + `⇧` + arrows grows or shrinks the focused tile. It moves the trailing
  edge by preference, so a tile already flush against the right of the screen
  grows leftward instead — grow always grows, wherever the tile sits.
- `⌃` + `⌘` + right-drag inside a tile resizes it from whichever corner the
  cursor started nearest, Hyprland's `bindm` gesture.
- **Grabbing the window's own border** works too. Shaka doesn't intercept that
  drag — the app resizes itself as usual, and Shaka reads the frame it lands on
  and folds the difference back into the split ratios. The window keeps the size
  you gave it because the layout changed to agree with it.

`⌃` + `⌘` + left-drag throws a tile around the layout: tiles trade places as the
cursor crosses them, so the arrangement is a valid tiling at every moment of the
drag. Dragging a window by its title bar and dropping it on another tile does the
same thing.

No tile can be squeezed below `min_tile_size` points, whichever way you resize.

#### Workspaces

Each display gets nine workspaces, and each one is a full dwindle tree of its
own. `⌃` + `1`–`9` brings one to the screen; `⌃` + `⇧` + `1`–`9` sends the
focused window to one without following it there. `⌃` + `` ` `` bounces back to
the workspace you were last on, and `⌃` + `⌥` + `[` / `]` step through them.

Windows on a workspace that isn't showing are slid off the bottom of the display,
so returning to it springs them back up into their tiles. Nothing is minimised
and no window is closed — and if an app refuses to be positioned off screen, set
`workspace_hide = "minimize"` in the config.

These are Shaka's own workspaces, not macOS Spaces. They live entirely inside
Reef, they leave Mission Control alone, and their keys are unbound in Flow mode —
so if you have macOS's own "Switch to Desktop N" shortcuts on `⌃` + `1`–`9`,
Flow still hands them to macOS and Reef takes them for itself.

Reaching a window from the app switcher works across workspaces: Cmd-Tab to a
window parked on another workspace and Shaka switches to it rather than leaving
you on a screen that didn't change. The menu bar shows which workspace you're on.

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
| `ctrl` + `k` | Cheat sheet for this mode | Cheat sheet for this mode |

Reef adds actions that have no Flow equivalent. Their keys stay unbound in Flow
mode, so there they reach the focused app instead:

| Shortcut | Action |
|---|---|
| `ctrl` + `shift` + `s` | Toggle split direction (Hyprland's `togglesplit`) |
| `ctrl` + `shift` + `f` | Toggle floating — the window leaves the tiling and gets Flow behaviour |
| `ctrl` + `opt` + `tab` | Cycle focus through tiles |
| `ctrl` + `opt` + `shift` + `tab` | Cycle focus backwards |
| `ctrl` + `1`–`9` | Show workspace 1–9 on this display |
| `ctrl` + `shift` + `1`–`9` | Send the focused window to a workspace, and stay put |
| `ctrl` + `opt` + `]` / `[` | Next / previous workspace |
| `ctrl` + `` ` `` | Back to the last workspace |

And the mouse, in Reef only:

| Gesture | Action |
|---|---|
| `ctrl` + `cmd` + drag | Move the tile — tiles trade places as the cursor crosses them |
| `ctrl` + `cmd` + right-drag | Resize the tile from the nearest corner |
| Drag a window's border | Resize the tile; the neighbours reflow to match |
| Drag a window onto another | The two tiles trade places |

> The mouse chord is two modifiers rather than one because a bare `ctrl` + click
> is macOS's right-click, and Reef swallowing it would cost you context menus.
> Set `mouse_modifier = "leader"` in the config if you would rather have the
> one-modifier Hyprland feel.

### The cheat sheet

`ctrl` + `k` puts the full list on screen for whichever mode you are in — built
from your own bindings, so it stays right after you rebind something. Press it
again, hit `esc`, or click it to put it away. Switching modes while it is up
swaps it for the other half.

The same list lives in the menu bar under **🤙 → Shortcuts**, and every row there
runs its action when you pick it — the menu is a way to *use* the shortcuts, not
just read them.

> **Note:** `ctrl` + `k` is a terminal's kill-to-end-of-line, so rebind
> `show_shortcuts` if you live in one.

> **Note:** `ctrl` + arrow keys may overlap with macOS Mission Control shortcuts. Disable them in **System Settings → Keyboard → Keyboard Shortcuts → Mission Control**, or change the leader key to `"opt"` in the config.

## Configuration

Config lives at `~/.config/shaka/config.toml` — created automatically on first
launch, with every option Shaka understands written out and commented.

```toml
# The modifier every "leader+..." binding below starts from.
#   "ctrl" | "opt" (= "alt" / "option") | "cmd" (= "command") | "shift"
leader = "ctrl"

# Which mode Shaka starts in: "flow" or "reef"
default_mode = "flow"

# ── Flow mode ────────────────────────────────────────────────────────────────
move_step = 80        # how far one nudge moves a window, in points
resize_step = 80      # how much one resize grows or shrinks it
edge_snap = 20        # a move landing this close to an edge sticks to it; 0 = off
screen_padding = 10   # margin kept by snapped and filled windows

# ── Reef mode ────────────────────────────────────────────────────────────────
gaps_in = 6           # space around each tile, so neighbours sit 2x this apart
gaps_out = 12         # space at the screen edge
min_tile_size = 120   # smallest tile a resize may leave behind, in points
workspaces = 9        # per display, 1-9; each keeps its own tiling

# How windows on a hidden workspace are put away:
#   "offscreen" — slid below the display, instant and reversible
#   "minimize"  — sent to the Dock, for apps that refuse to be moved off screen
workspace_hide = "offscreen"

# ── Reef mouse ───────────────────────────────────────────────────────────────
# Hold this and drag inside a tile: left button moves it, right button resizes.
# "leader" gives the one-modifier Hyprland feel; "" turns the gesture off.
mouse_modifier = "leader+cmd"
mouse_edge_drag = true   # dragging a tile's own border reshapes the tiling

# ── Animation (both modes) ───────────────────────────────────────────────────
animation_stiffness = 300   # higher = faster
animation_damping = 28      # higher = less bounce

# ── Bindings ─────────────────────────────────────────────────────────────────
# Every action Shaka has, with what it does in each mode as a comment.
[bindings]
# --- Focus ---
focus_left = "leader+left"              # Flow: Focus window left  ·  Reef: Focus tile left
focus_right = "leader+right"            # ... and right / up / down
cycle_next = "leader+opt+tab"           # Reef only: Cycle focus forward
cycle_prev = "leader+opt+shift+tab"     # Reef only: Cycle focus back

# --- Move ---
move_left = "leader+opt+left"           # Flow: Nudge window left  ·  Reef: Swap tile left
center = "leader+return"                # Flow: Center window  ·  Reef: Promote to master

# --- Resize ---
grow_width = "leader+shift+right"       # Flow: Grow width  ·  Reef: Widen split
shrink_width = "leader+shift+left"      # Flow: Shrink width  ·  Reef: Narrow split

# --- Snap & Displays ---
snap_left = "leader+cmd+left"           # Flow: Snap left ½ ⅓ ⅔  ·  Reef: Send to display left

# --- Layout ---
fill = "leader+shift+return"            # Flow: Fill screen  ·  Reef: Toggle fullscreen
toggle_split = "leader+shift+s"         # Reef only: Toggle split direction
toggle_float = "leader+shift+f"         # Reef only: Toggle floating

# --- Workspaces ---
workspace_1 = "leader+1"                # Reef only: Workspace 1        ... through 9
move_to_workspace_1 = "leader+shift+1"  # Reef only: Send to workspace 1 ... through 9
workspace_next = "leader+opt+]"         # Reef only: Next workspace
workspace_prev = "leader+opt+["         # Reef only: Previous workspace
workspace_recent = "leader+`"           # Reef only: Last workspace

# --- Shaka ---
toggle_mode = "leader+/"                # Flow: Switch to Reef  ·  Reef: Switch to Flow
show_shortcuts = "leader+k"             # Show the shortcut cheat sheet
```

The file on disk lists all four directions and all nine workspaces; the block
above collapses the repeats.

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
| Punctuation | `-` `=` `[` `]` `;` `'` `,` `.` `/` `` ` `` `\` |

Combine with `+`: `"leader+shift+left"`, `"ctrl+opt+a"`, etc.

## Reef mode caveats

Reef is experimental. Known rough edges:

- Apps that refuse to resize (fixed-size windows, some Electron apps and dialogs)
  will not tile cleanly. `ctrl` + `shift` + `f` floats them out of the way.
- Only the dwindle layout is implemented; Hyprland's master layout is not.
- Because the layout is a BSP tree, dragging the outer edge of a tile resizes the
  whole column it belongs to, not that tile alone. This is how Hyprland's dwindle
  behaves too — the split you moved is genuinely shared by everything in the
  column.
- Workspaces are Shaka's own, not macOS Spaces. A window parked on a hidden
  workspace still appears in Mission Control and the app switcher; reaching it
  from there switches you to its workspace.
- Reef mode watches mouse events to catch border drags. If you would rather it
  didn't, set `mouse_edge_drag = false`.

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
