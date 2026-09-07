import Cocoa

/// Everything Shaka can do, in the order it should be presented.
///
/// One catalogue feeds three places — the Shortcuts menu, the `leader + k`
/// overlay, and the generated config file — so a new action shows up in all of
/// them by being added here once.
enum ShortcutGroup: String, CaseIterable {
    case focus      = "Focus"
    case move       = "Move"
    case resize     = "Resize"
    case place      = "Snap & Displays"
    case layout     = "Layout"
    case workspaces = "Workspaces"
    case shaka      = "Shaka"
}

/// A numbered run of bindings — workspaces 1-9 — shown as one row rather than
/// nine near-identical ones.
enum ShortcutFamily: Hashable {
    case showWorkspace
    case sendToWorkspace

    func label(count: Int) -> String {
        switch self {
        case .showWorkspace:   return "Show workspace 1–\(count)"
        case .sendToWorkspace: return "Send window to workspace 1–\(count)"
        }
    }

    func memberLabel(_ number: Int) -> String {
        switch self {
        case .showWorkspace:   return "Workspace \(number)"
        case .sendToWorkspace: return "Send to workspace \(number)"
        }
    }
}

/// One action, and what it does in each mode. A `nil` label means the action
/// does not exist in that mode and is left out of the list.
struct ShortcutSpec {
    let action: Action
    let group: ShortcutGroup
    let flow: String?
    let reef: String?
    var family: ShortcutFamily? = nil

    func label(for mode: WindowMode) -> String? {
        mode == .flow ? flow : reef
    }
}

/// A line as it is drawn: a key, what it does, and what to run when clicked.
/// Family rows carry their members instead of an action of their own.
struct ShortcutRow {
    let key: String
    let detail: String
    let action: Action?
    var members: [ShortcutRow] = []
}

enum Shortcuts {

    private static let core: [ShortcutSpec] = [
        // Focus
        .init(action: .focusLeft,     group: .focus,  flow: "Focus window left",  reef: "Focus tile left"),
        .init(action: .focusRight,    group: .focus,  flow: "Focus window right", reef: "Focus tile right"),
        .init(action: .focusUp,       group: .focus,  flow: "Focus window up",    reef: "Focus tile up"),
        .init(action: .focusDown,     group: .focus,  flow: "Focus window down",  reef: "Focus tile down"),
        .init(action: .cycleNext,     group: .focus,  flow: nil,                  reef: "Cycle focus forward"),
        .init(action: .cyclePrev,     group: .focus,  flow: nil,                  reef: "Cycle focus back"),

        // Move
        .init(action: .moveLeft,      group: .move,   flow: "Nudge window left",  reef: "Swap tile left"),
        .init(action: .moveRight,     group: .move,   flow: "Nudge window right", reef: "Swap tile right"),
        .init(action: .moveUp,        group: .move,   flow: "Nudge window up",    reef: "Swap tile up"),
        .init(action: .moveDown,      group: .move,   flow: "Nudge window down",  reef: "Swap tile down"),
        .init(action: .center,        group: .move,   flow: "Center window",      reef: "Promote to master"),

        // Resize
        .init(action: .growWidth,     group: .resize, flow: "Grow width",         reef: "Widen split"),
        .init(action: .shrinkWidth,   group: .resize, flow: "Shrink width",       reef: "Narrow split"),
        .init(action: .growHeight,    group: .resize, flow: "Grow height",        reef: "Heighten split"),
        .init(action: .shrinkHeight,  group: .resize, flow: "Shrink height",      reef: "Shorten split"),

        // Snap & displays
        .init(action: .snapLeft,      group: .place,  flow: "Snap left ½ ⅓ ⅔",    reef: "Send to display left"),
        .init(action: .snapRight,     group: .place,  flow: "Snap right ½ ⅓ ⅔",   reef: "Send to display right"),
        .init(action: .snapUp,        group: .place,  flow: "Snap top ½ ⅓ ⅔",     reef: "Send to display up"),
        .init(action: .snapDown,      group: .place,  flow: "Snap bottom ½ ⅓ ⅔",  reef: "Send to display down"),

        // Layout
        .init(action: .fill,          group: .layout, flow: "Fill screen",        reef: "Toggle fullscreen"),
        .init(action: .toggleSplit,   group: .layout, flow: nil,                  reef: "Toggle split direction"),
        .init(action: .toggleFloat,   group: .layout, flow: nil,                  reef: "Toggle floating"),
    ]

    /// workspace_1…9 and move_to_workspace_1…9, generated rather than spelled out.
    private static let workspaceNumbers: [ShortcutSpec] =
        (1...9).compactMap { n in
            Action(rawValue: "workspace_\(n)").map {
                .init(action: $0, group: .workspaces, flow: nil,
                      reef: ShortcutFamily.showWorkspace.memberLabel(n), family: .showWorkspace)
            }
        } + (1...9).compactMap { n in
            Action(rawValue: "move_to_workspace_\(n)").map {
                .init(action: $0, group: .workspaces, flow: nil,
                      reef: ShortcutFamily.sendToWorkspace.memberLabel(n), family: .sendToWorkspace)
            }
        }

    private static let rest: [ShortcutSpec] = [
        .init(action: .workspaceNext,   group: .workspaces, flow: nil, reef: "Next workspace"),
        .init(action: .workspacePrev,   group: .workspaces, flow: nil, reef: "Previous workspace"),
        .init(action: .workspaceRecent, group: .workspaces, flow: nil, reef: "Last workspace"),

        .init(action: .toggleMode,      group: .shaka, flow: "Switch to Reef 👊", reef: "Switch to Flow 🤙"),
        .init(action: .showShortcuts,   group: .shaka, flow: "Show the shortcut cheat sheet",
                                                       reef: "Show the shortcut cheat sheet"),
    ]

    static let specs: [ShortcutSpec] = core + workspaceNumbers + rest

    /// Grouped rows for a mode, using the live bindings so a rebound key shows
    /// up here too. Groups with nothing in them are dropped.
    static func groupedRows(mode: WindowMode, config: ShakaConfig) -> [(group: ShortcutGroup, rows: [ShortcutRow])] {
        var result: [(ShortcutGroup, [ShortcutRow])] = []

        for group in ShortcutGroup.allCases {
            var rows: [ShortcutRow] = []
            var seenFamilies: Set<ShortcutFamily> = []

            for spec in specs where spec.group == group {
                guard let detail = spec.label(for: mode) else { continue }

                if let family = spec.family {
                    guard seenFamilies.insert(family).inserted else { continue }
                    if let row = familyRow(family, mode: mode, config: config) { rows.append(row) }
                    continue
                }

                guard let combo = config.bindings[spec.action.rawValue] else { continue }
                rows.append(ShortcutRow(
                    key: config.displayString(for: combo),
                    detail: detail,
                    action: spec.action
                ))
            }

            if !rows.isEmpty { result.append((group, rows)) }
        }

        return result
    }

    /// Collapse a numbered family to `⌃1 … ⌃9`, keeping the individual bindings
    /// as members so a menu can still offer them one by one.
    private static func familyRow(
        _ family: ShortcutFamily, mode: WindowMode, config: ShakaConfig
    ) -> ShortcutRow? {
        let members: [ShortcutRow] = specs.compactMap { spec in
            guard spec.family == family,
                  let number = spec.action.workspaceNumber ?? spec.action.moveToWorkspaceNumber,
                  number <= config.workspaceCount,
                  let detail = spec.label(for: mode),
                  let combo = config.bindings[spec.action.rawValue] else { return nil }
            return ShortcutRow(
                key: config.displayString(for: combo),
                detail: detail,
                action: spec.action
            )
        }

        guard let first = members.first, let last = members.last else { return nil }
        let key = members.count == 1 ? first.key : "\(first.key) … \(last.key)"

        return ShortcutRow(
            key: key,
            detail: family.label(count: members.count),
            action: nil,
            members: members
        )
    }
}
