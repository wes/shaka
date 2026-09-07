import Cocoa

// MARK: - Actions

enum Action: String, CaseIterable {
    case focusLeft    = "focus_left"
    case focusRight   = "focus_right"
    case focusUp      = "focus_up"
    case focusDown    = "focus_down"
    case moveLeft     = "move_left"
    case moveRight    = "move_right"
    case moveUp       = "move_up"
    case moveDown     = "move_down"
    case growWidth    = "grow_width"
    case shrinkWidth  = "shrink_width"
    case growHeight   = "grow_height"
    case shrinkHeight = "shrink_height"
    case snapLeft     = "snap_left"
    case snapRight    = "snap_right"
    case snapUp       = "snap_up"
    case snapDown     = "snap_down"
    case center       = "center"
    case fill         = "fill"
    case toggleMode   = "toggle_mode"
    case toggleSplit  = "toggle_split"
    case toggleFloat  = "toggle_float"
    case cycleNext    = "cycle_next"
    case cyclePrev    = "cycle_prev"
    case showShortcuts = "show_shortcuts"

    case workspace1 = "workspace_1"
    case workspace2 = "workspace_2"
    case workspace3 = "workspace_3"
    case workspace4 = "workspace_4"
    case workspace5 = "workspace_5"
    case workspace6 = "workspace_6"
    case workspace7 = "workspace_7"
    case workspace8 = "workspace_8"
    case workspace9 = "workspace_9"

    case moveToWorkspace1 = "move_to_workspace_1"
    case moveToWorkspace2 = "move_to_workspace_2"
    case moveToWorkspace3 = "move_to_workspace_3"
    case moveToWorkspace4 = "move_to_workspace_4"
    case moveToWorkspace5 = "move_to_workspace_5"
    case moveToWorkspace6 = "move_to_workspace_6"
    case moveToWorkspace7 = "move_to_workspace_7"
    case moveToWorkspace8 = "move_to_workspace_8"
    case moveToWorkspace9 = "move_to_workspace_9"

    case workspaceNext   = "workspace_next"
    case workspacePrev   = "workspace_prev"
    case workspaceRecent = "workspace_recent"

    /// Actions with no Flow equivalent. Their keys are left unbound in Flow mode
    /// so they reach the focused app instead.
    var isReefOnly: Bool {
        switch self {
        case .toggleSplit, .toggleFloat, .cycleNext, .cyclePrev:
            return true
        case .workspaceNext, .workspacePrev, .workspaceRecent:
            return true
        default:
            return workspaceNumber != nil || moveToWorkspaceNumber != nil
        }
    }

    /// The 1-based workspace this action shows, if it is one of `workspace_N`.
    var workspaceNumber: Int? {
        guard rawValue.hasPrefix("workspace_") else { return nil }
        return Int(rawValue.dropFirst("workspace_".count))
    }

    /// The 1-based workspace this action sends the focused window to.
    var moveToWorkspaceNumber: Int? {
        guard rawValue.hasPrefix("move_to_workspace_") else { return nil }
        return Int(rawValue.dropFirst("move_to_workspace_".count))
    }
}

// MARK: - Parsed Binding

struct ParsedBinding {
    let modifiers: CGEventFlags
    let keyCode: Int64
    let action: Action
}

// MARK: - Config

struct ShakaConfig {
    var leader: String = "ctrl"
    var moveStep: Double = 80
    var resizeStep: Double = 80
    var edgeSnap: Double = 20
    var screenPadding: Double = 10
    var animationStiffness: Double = 300
    var animationDamping: Double = 28

    /// Which mode Shaka starts in: "flow" or "reef".
    var defaultMode: String = "flow"

    /// Reef mode gaps, following Hyprland's naming: `gapsOut` at the screen
    /// edge, `gapsIn` around each tile (so neighbours sit 2 × gapsIn apart).
    var gapsIn: Double = 6
    var gapsOut: Double = 12

    /// Smallest tile any resize is allowed to leave behind, in points.
    var minTileSize: Double = 120

    /// How many workspaces each display gets.
    var workspaceCount: Int = 9

    /// How windows on a hidden workspace are put away: "offscreen" or "minimize".
    var workspaceHide: String = "offscreen"

    /// Modifiers that turn a mouse drag into a layout gesture. Empty disables it.
    ///
    /// Two modifiers by default, not one: with the default `ctrl` leader, a bare
    /// leader-click is macOS's own right-click, and Reef swallowing it would
    /// take context menus away from every tiled window.
    var mouseModifier: String = "leader+cmd"

    /// Whether dragging a tiled window's own border reshapes the tiling.
    var mouseEdgeDrag: Bool = true

    var parkStyle: ParkStyle {
        ParkStyle(rawValue: workspaceHide.lowercased()) ?? .offscreen
    }

    /// `mouseModifier` resolved to event flags. An unparsable value disables the
    /// gesture rather than binding it to something surprising.
    var mouseModifiers: CGEventFlags {
        let parts = mouseModifier.lowercased()
            .components(separatedBy: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !parts.isEmpty else { return [] }

        var flags: CGEventFlags = []
        for part in parts {
            let resolved = (part == "leader") ? leader.lowercased() : part
            guard let mod = modifierMap[resolved] else {
                print("[shaka] mouse_modifier: unknown modifier \"\(resolved)\"")
                return []
            }
            flags.insert(mod)
        }
        return flags
    }

    var bindings: [String: String] = defaultBindings

    static let defaultBindings: [String: String] = [
        "focus_left":    "leader+left",
        "focus_right":   "leader+right",
        "focus_up":      "leader+up",
        "focus_down":    "leader+down",
        "move_left":     "leader+opt+left",
        "move_right":    "leader+opt+right",
        "move_up":       "leader+opt+up",
        "move_down":     "leader+opt+down",
        "grow_width":    "leader+shift+right",
        "shrink_width":  "leader+shift+left",
        "grow_height":   "leader+shift+up",
        "shrink_height": "leader+shift+down",
        "snap_left":     "leader+cmd+left",
        "snap_right":    "leader+cmd+right",
        "snap_up":       "leader+cmd+up",
        "snap_down":     "leader+cmd+down",
        "center":        "leader+return",
        "fill":          "leader+shift+return",
        "toggle_mode":   "leader+/",
        "toggle_split":  "leader+shift+s",
        "toggle_float":  "leader+shift+f",
        "cycle_next":    "leader+opt+tab",
        "cycle_prev":    "leader+opt+shift+tab",
        "workspace_1":   "leader+1",
        "workspace_2":   "leader+2",
        "workspace_3":   "leader+3",
        "workspace_4":   "leader+4",
        "workspace_5":   "leader+5",
        "workspace_6":   "leader+6",
        "workspace_7":   "leader+7",
        "workspace_8":   "leader+8",
        "workspace_9":   "leader+9",
        "move_to_workspace_1": "leader+shift+1",
        "move_to_workspace_2": "leader+shift+2",
        "move_to_workspace_3": "leader+shift+3",
        "move_to_workspace_4": "leader+shift+4",
        "move_to_workspace_5": "leader+shift+5",
        "move_to_workspace_6": "leader+shift+6",
        "move_to_workspace_7": "leader+shift+7",
        "move_to_workspace_8": "leader+shift+8",
        "move_to_workspace_9": "leader+shift+9",
        // Not a bare leader+[ : with the default ctrl leader that is ESC in
        // every terminal, and taking it would break vim for anyone in Reef.
        "workspace_next":   "leader+opt+]",
        "workspace_prev":   "leader+opt+[",
        "workspace_recent": "leader+`",
        "show_shortcuts":   "leader+k",
    ]

    // MARK: - Parse Bindings

    func parseBindings() -> [ParsedBinding] {
        var result: [ParsedBinding] = []
        for (actionStr, comboStr) in bindings {
            guard let action = Action(rawValue: actionStr) else {
                print("[shaka] unknown action in config: \"\(actionStr)\"")
                continue
            }
            guard let (mods, keyCode) = parseCombo(comboStr) else {
                print("[shaka] invalid key combo: \"\(comboStr)\" for \(actionStr)")
                continue
            }
            result.append(ParsedBinding(modifiers: mods, keyCode: keyCode, action: action))
        }
        return result
    }

    private func parseCombo(_ combo: String) -> (CGEventFlags, Int64)? {
        let parts = combo.lowercased()
            .components(separatedBy: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        var flags: CGEventFlags = []
        var keyCode: Int64 = -1

        for part in parts {
            let resolved = (part == "leader") ? leader.lowercased() : part

            if let mod = modifierMap[resolved] {
                flags.insert(mod)
            } else if let code = keyCodeMap[resolved] {
                keyCode = code
            } else {
                print("[shaka] unknown key: \"\(resolved)\"")
                return nil
            }
        }

        return keyCode >= 0 ? (flags, keyCode) : nil
    }

    /// Human-readable label for the leader key (for menus)
    var leaderSymbol: String {
        switch leader.lowercased() {
        case "ctrl", "control":      return "⌃"
        case "cmd", "command":       return "⌘"
        case "opt", "option", "alt": return "⌥"
        case "shift":                return "⇧"
        default:                     return leader
        }
    }

    var startMode: WindowMode {
        WindowMode(rawValue: defaultMode.lowercased()) ?? .flow
    }

    /// Render a binding like "leader+shift+left" as "⌃⇧←" for menus.
    func displayString(for combo: String) -> String {
        var modifiers = ""
        var key = ""

        for part in combo.lowercased().components(separatedBy: "+")
            .map({ $0.trimmingCharacters(in: .whitespaces) }) {
            let resolved = (part == "leader") ? leader.lowercased() : part

            switch resolved {
            case "ctrl", "control":      modifiers += "⌃"
            case "opt", "option", "alt": modifiers += "⌥"
            case "shift":                modifiers += "⇧"
            case "cmd", "command":       modifiers += "⌘"
            default:                     key = keySymbols[resolved] ?? resolved.uppercased()
            }
        }

        return modifiers + key
    }

    /// The same binding as an AppKit menu key equivalent, so a menu row draws
    /// its shortcut in the native right-aligned style instead of a hand-padded
    /// column that only lines up in a monospaced font.
    func menuKey(for combo: String) -> (key: String, modifiers: NSEvent.ModifierFlags)? {
        var modifiers: NSEvent.ModifierFlags = []
        var key: String?

        for part in combo.lowercased().components(separatedBy: "+")
            .map({ $0.trimmingCharacters(in: .whitespaces) }) {
            let resolved = (part == "leader") ? leader.lowercased() : part

            switch resolved {
            case "ctrl", "control":      modifiers.insert(.control)
            case "opt", "option", "alt": modifiers.insert(.option)
            case "shift":                modifiers.insert(.shift)
            case "cmd", "command":       modifiers.insert(.command)
            default:
                key = keyEquivalents[resolved] ?? (resolved.count == 1 ? resolved : nil)
            }
        }

        guard let key else { return nil }
        return (key, modifiers)
    }

    // MARK: - Load / Save

    static let configDir  = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/shaka")
    static let configPath = configDir.appendingPathComponent("config.toml")

    static func load() -> ShakaConfig {
        let fm = FileManager.default

        if !fm.fileExists(atPath: configDir.path) {
            try? fm.createDirectory(at: configDir, withIntermediateDirectories: true)
        }

        if !fm.fileExists(atPath: configPath.path) {
            let config = ShakaConfig()
            config.save()
            print("[shaka] created config at \(configPath.path)")
            return config
        }

        do {
            let raw = try String(contentsOf: configPath, encoding: .utf8)
            let toml = TOML.parse(raw)
            var config = ShakaConfig()

            if let v = toml["leader"]               as? String { config.leader = v }
            if let v = toml["move_step"]            as? Double { config.moveStep = v }
            if let v = toml["resize_step"]          as? Double { config.resizeStep = v }
            if let v = toml["edge_snap"]            as? Double { config.edgeSnap = v }
            if let v = toml["screen_padding"]       as? Double { config.screenPadding = v }
            if let v = toml["animation_stiffness"]  as? Double { config.animationStiffness = v }
            if let v = toml["animation_damping"]    as? Double { config.animationDamping = v }
            if let v = toml["default_mode"]         as? String { config.defaultMode = v }
            if let v = toml["gaps_in"]              as? Double { config.gapsIn = v }
            if let v = toml["gaps_out"]             as? Double { config.gapsOut = v }
            if let v = toml["min_tile_size"]        as? Double { config.minTileSize = v }
            if let v = toml["workspaces"]           as? Double { config.workspaceCount = max(1, min(9, Int(v))) }
            if let v = toml["workspace_hide"]       as? String { config.workspaceHide = v }
            if let v = toml["mouse_modifier"]       as? String { config.mouseModifier = v }
            if let v = toml["mouse_edge_drag"]      as? Bool   { config.mouseEdgeDrag = v }

            if let section = toml["bindings"] as? [String: Any] {
                // Start from the defaults so a config written before a binding
                // existed still picks it up instead of silently losing the action.
                var b = defaultBindings
                for (k, v) in section {
                    if let s = v as? String { b[k] = s }
                }
                config.bindings = b
            }

            print("[shaka] loaded config from \(configPath.path)")
            return config
        } catch {
            print("[shaka] config error: \(error.localizedDescription), using defaults")
            return ShakaConfig()
        }
    }

    func save() {
        let toml = """
# ─────────────────────────────────────────────────────────────────────────────
#  Shaka Window Manager — configuration
#
#  Every option Shaka understands is listed here with its default. Delete a
#  line to go back to that default; anything you leave out keeps working.
#  Apply changes with 🤙 → Reload Config, no restart needed.
# ─────────────────────────────────────────────────────────────────────────────

# The modifier every "leader+..." binding below starts from.
#   "ctrl" | "opt" (= "alt" / "option") | "cmd" (= "command") | "shift"
leader = "\(leader)"

# Which mode Shaka starts in.
#   "flow" — free-floating: nudge, resize and snap windows wherever you like
#   "reef" — Hyprland-style dwindle tiling: every window is a tile
default_mode = "\(defaultMode)"


# ── Flow mode ────────────────────────────────────────────────────────────────

# How far one nudge moves a window, in points.
move_step = \(Int(moveStep))

# How much one resize grows or shrinks a window, in points.
resize_step = \(Int(resizeStep))

# A move that lands within this many points of a screen edge sticks to it.
# Set to 0 to turn edge snapping off.
edge_snap = \(Int(edgeSnap))

# Margin kept between a snapped or filled window and the screen edge.
screen_padding = \(Int(screenPadding))


# ── Reef mode ────────────────────────────────────────────────────────────────

# gaps_in:  space around each tile, so neighbours sit 2x this apart
# gaps_out: space at the screen edge
gaps_in = \(Int(gapsIn))
gaps_out = \(Int(gapsOut))

# Smallest tile a resize may leave behind, in points.
min_tile_size = \(Int(minTileSize))

# Workspaces per display, 1-9. Each one keeps its own tiling.
workspaces = \(workspaceCount)

# How windows on a hidden workspace are put away:
#   "offscreen" — slid below the display, instant and reversible
#   "minimize"  — sent to the Dock, for apps that refuse to be moved off screen
workspace_hide = "\(workspaceHide)"


# ── Reef mouse ───────────────────────────────────────────────────────────────

# Hold this and drag inside a tile: left button moves it, right button resizes.
# Two modifiers by default, because a bare ctrl+click is macOS's right-click —
# set it to "leader" for the one-modifier Hyprland feel, or "" to turn the
# gesture off entirely.
mouse_modifier = "\(mouseModifier)"

# Dragging a tiled window's own border reshapes the tiling around it.
#   true | false
mouse_edge_drag = \(mouseEdgeDrag)


# ── Animation (both modes) ───────────────────────────────────────────────────

# Spring the windows travel on. Higher stiffness is snappier; lower damping
# overshoots and bounces. 300 / 28 lands quickly without wobbling.
animation_stiffness = \(Int(animationStiffness))
animation_damping = \(Int(animationDamping))


# ── Bindings ─────────────────────────────────────────────────────────────────
#
#  Write a combo as modifiers and one key joined by "+", e.g.
#  "leader+shift+left" or "ctrl+opt+a". "leader" stands in for the leader key
#  set above, so rebinding the leader moves every shortcut at once.
#
#  Modifiers: leader, ctrl, opt (alt), cmd, shift
#  Keys:      left right up down · return space tab escape delete
#             a-z · 0-9 · - = [ ] ; ' , . / ` \\
#
#  The comment after each line says what it does in Flow, then in Reef. Actions
#  marked "Reef only" have no Flow equivalent: in Flow their keys are left
#  alone, so they reach the focused app instead.
#
#  Watch for combos your apps already use: with a ctrl leader, show_shortcuts
#  (ctrl+k) is a terminal's kill-to-end-of-line, and ctrl + arrows are Mission
#  Control's. Rebind either side, or move the leader to "opt".

[bindings]
\(bindingsToTOML())
"""

        try? toml.data(using: .utf8)?.write(to: Self.configPath)
    }

    /// The bindings table, grouped and annotated the same way the Shortcuts
    /// menu is, so the config file reads as the full list of what Shaka can do.
    private func bindingsToTOML() -> String {
        var lines: [String] = []
        var written: Set<String> = []

        // One column width for the whole table, so every trailing comment
        // starts in the same place.
        let width = Shortcuts.specs.reduce(0) { widest, spec in
            guard let value = bindings[spec.action.rawValue] else { return widest }
            return max(widest, pair(spec.action.rawValue, value).count)
        }

        func pair(_ name: String, _ value: String) -> String {
            "\(name) = \"\(value)\""
        }

        func assignment(_ name: String, _ value: String) -> String {
            let text = pair(name, value)
            return text.padding(toLength: max(text.count + 2, width + 2),
                                withPad: " ", startingAt: 0)
        }

        for group in ShortcutGroup.allCases {
            let specs = Shortcuts.specs.filter { $0.group == group }
            guard specs.contains(where: { bindings[$0.action.rawValue] != nil }) else { continue }

            if !lines.isEmpty { lines.append("") }
            lines.append("# --- \(group.rawValue) ---")

            for spec in specs {
                guard let value = bindings[spec.action.rawValue] else { continue }
                written.insert(spec.action.rawValue)

                let note: String
                switch (spec.flow, spec.reef) {
                case let (flow?, reef?) where flow == reef: note = flow
                case let (flow?, reef?):                    note = "Flow: \(flow)  ·  Reef: \(reef)"
                case let (flow?, nil):                      note = "Flow only: \(flow)"
                case let (nil, reef?):                      note = "Reef only: \(reef)"
                default:                                    note = ""
                }

                lines.append("\(assignment(spec.action.rawValue, value))# \(note)")
            }
        }

        // Anything bound that the catalogue does not know about — a hand-added
        // action, or one from a newer Shaka — is kept rather than dropped.
        let extras = bindings.keys.filter { !written.contains($0) }.sorted()
        if !extras.isEmpty {
            lines.append("")
            for key in extras {
                lines.append(assignment(key, bindings[key]!).trimmingCharacters(in: .whitespaces))
            }
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - Minimal TOML Parser

/// Parses a subset of TOML: key = value pairs, [sections], # comments.
/// Supports string, integer, float, and boolean values.
enum TOML {
    static func parse(_ text: String) -> [String: Any] {
        var root: [String: Any] = [:]
        var currentSection: String?

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // Skip empty lines and comments
            if line.isEmpty || line.hasPrefix("#") { continue }

            // Section header: [name]
            if line.hasPrefix("[") && line.hasSuffix("]") {
                currentSection = String(line.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespaces)
                if root[currentSection!] == nil {
                    root[currentSection!] = [String: Any]()
                }
                continue
            }

            // Key = value
            guard let eqIdx = line.firstIndex(of: "=") else { continue }

            let key = String(line[line.startIndex..<eqIdx])
                .trimmingCharacters(in: .whitespaces)
            let rawValue = String(line[line.index(after: eqIdx)...])
                .trimmingCharacters(in: .whitespaces)
            let value = parseValue(stripInlineComment(rawValue))

            if let section = currentSection {
                var dict = root[section] as? [String: Any] ?? [:]
                dict[key] = value
                root[section] = dict
            } else {
                root[key] = value
            }
        }

        return root
    }

    private static func parseValue(_ raw: String) -> Any {
        // Quoted string
        if raw.hasPrefix("\"") && raw.hasSuffix("\"") && raw.count >= 2 {
            return String(raw.dropFirst().dropLast())
        }
        // Boolean
        if raw == "true"  { return true }
        if raw == "false" { return false }
        // Number — try Int first, then Double
        if let i = Int(raw)    { return Double(i) }
        if let d = Double(raw) { return d }
        return raw
    }

    /// Strip an inline # comment, but not if the # is inside a quoted string.
    private static func stripInlineComment(_ s: String) -> String {
        var inString = false
        for (i, c) in s.enumerated() {
            if c == "\"" { inString = !inString }
            if c == "#" && !inString {
                return String(s.prefix(i)).trimmingCharacters(in: .whitespaces)
            }
        }
        return s
    }
}

// MARK: - Key Maps

private let keySymbols: [String: String] = [
    "left": "←", "right": "→", "up": "↑", "down": "↓",
    "return": "↩", "enter": "↩", "tab": "⇥", "space": "␣",
    "delete": "⌫", "escape": "⎋", "esc": "⎋",
]

/// Menu key equivalents. AppKit draws arrows and friends from these private-use
/// scalars; everything else is just the character itself.
private let keyEquivalents: [String: String] = [
    "left":   String(UnicodeScalar(UInt32(NSLeftArrowFunctionKey))!),
    "right":  String(UnicodeScalar(UInt32(NSRightArrowFunctionKey))!),
    "up":     String(UnicodeScalar(UInt32(NSUpArrowFunctionKey))!),
    "down":   String(UnicodeScalar(UInt32(NSDownArrowFunctionKey))!),
    "return": "\r", "enter": "\r",
    "tab":    "\t",
    "space":  " ",
    "delete": String(UnicodeScalar(UInt8(NSDeleteCharacter))),
    "escape": "\u{1b}", "esc": "\u{1b}",
]

private let modifierMap: [String: CGEventFlags] = [
    "ctrl": .maskControl,    "control": .maskControl,
    "shift": .maskShift,
    "cmd": .maskCommand,     "command": .maskCommand,
    "opt": .maskAlternate,   "option": .maskAlternate,  "alt": .maskAlternate,
]

private let keyCodeMap: [String: Int64] = [
    "left": 123, "right": 124, "down": 125, "up": 126,
    "return": 36, "enter": 36, "tab": 48, "space": 49,
    "delete": 51, "escape": 53, "esc": 53,
    "a": 0,  "b": 11, "c": 8,  "d": 2,  "e": 14, "f": 3,
    "g": 5,  "h": 4,  "i": 34, "j": 38, "k": 40, "l": 37,
    "m": 46, "n": 45, "o": 31, "p": 35, "q": 12, "r": 15,
    "s": 1,  "t": 17, "u": 32, "v": 9,  "w": 13, "x": 7,
    "y": 16, "z": 6,
    "0": 29, "1": 18, "2": 19, "3": 20, "4": 21,
    "5": 23, "6": 22, "7": 26, "8": 28, "9": 25,
    "-": 27, "=": 24, "[": 33, "]": 30, ";": 41,
    "'": 39, ",": 43, ".": 47, "/": 44, "\\": 42, "`": 50,
]
