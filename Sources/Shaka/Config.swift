import Cocoa

// MARK: - Actions

enum Action: String, CaseIterable {
    case focusLeft   = "focus_left"
    case focusRight  = "focus_right"
    case focusUp     = "focus_up"
    case focusDown   = "focus_down"
    case moveLeft    = "move_left"
    case moveRight   = "move_right"
    case moveUp      = "move_up"
    case moveDown    = "move_down"
    case growWidth   = "grow_width"
    case shrinkWidth = "shrink_width"
    case growHeight  = "grow_height"
    case shrinkHeight = "shrink_height"
    case snapLeft    = "snap_left"
    case snapRight   = "snap_right"
    case snapUp      = "snap_up"
    case snapDown    = "snap_down"
    case center      = "center"
    case fill        = "fill"
    case toggleMode  = "toggle_mode"
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
    var gridColumns: Int = 12
    var gridRows: Int = 8
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
            if let v = toml["grid_columns"]         as? Double { config.gridColumns = Int(v) }
            if let v = toml["grid_rows"]            as? Double { config.gridRows = Int(v) }

            if let section = toml["bindings"] as? [String: Any] {
                var b: [String: String] = [:]
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
        # Shaka Window Manager Configuration
        # Restart Shaka or click "Reload Config" after editing.
        #
        # Leader key options: "ctrl", "opt" / "alt", "cmd", "shift"
        #
        # Key names for bindings:
        #   Arrows:  left, right, up, down
        #   Special: return, space, tab, escape, delete
        #   Letters: a-z
        #   Numbers: 0-9
        #   Combo example: "leader+shift+left"

        leader = "\(leader)"

        move_step = \(Int(moveStep))
        resize_step = \(Int(resizeStep))
        edge_snap = \(Int(edgeSnap))
        screen_padding = \(Int(screenPadding))

        animation_stiffness = \(Int(animationStiffness))
        animation_damping = \(Int(animationDamping))

        grid_columns = \(gridColumns)
        grid_rows = \(gridRows)

        [bindings]
        \(bindingsToTOML())
        """

        let lines = toml.components(separatedBy: .newlines)
            .map { $0.hasPrefix("        ") ? String($0.dropFirst(8)) : $0 }
            .joined(separator: "\n")

        try? lines.data(using: .utf8)?.write(to: Self.configPath)
    }

    private func bindingsToTOML() -> String {
        // Ordered list so the config file has a logical layout
        let order: [String] = [
            "focus_left", "focus_right", "focus_up", "focus_down",
            "move_left", "move_right", "move_up", "move_down",
            "grow_width", "shrink_width", "grow_height", "shrink_height",
            "snap_left", "snap_right", "snap_up", "snap_down",
            "center", "fill",
            "toggle_mode",
        ]

        var lines: [String] = []
        let padTo = order.map(\.count).max() ?? 0

        for key in order {
            if let value = bindings[key] {
                let padded = key.padding(toLength: padTo, withPad: " ", startingAt: 0)
                lines.append("\(padded) = \"\(value)\"")
            }
        }

        // Any extra bindings not in the standard order
        for (key, value) in bindings where !order.contains(key) {
            lines.append("\(key) = \"\(value)\"")
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
