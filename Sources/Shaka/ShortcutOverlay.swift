import Cocoa

extension Notification.Name {
    /// Posted by the `show_shortcuts` hotkey; AppDelegate owns the panel.
    static let shakaToggleShortcuts = Notification.Name("shakaToggleShortcuts")
}

/// The `leader + k` cheat sheet: a HUD listing every shortcut that does
/// something in the mode you are actually in, built from the live bindings.
///
/// It is a non-activating panel, so it never steals focus from the window you
/// are about to rearrange. Escape, another `leader + k`, or a click dismisses it.
final class ShortcutOverlay {
    static let shared = ShortcutOverlay()
    private init() {}

    private var panel: NSPanel?

    var isVisible: Bool { panel != nil }

    func toggle(config: ShakaConfig, mode: WindowMode) {
        isVisible ? hide() : show(config: config, mode: mode)
    }

    func show(config: ShakaConfig, mode: WindowMode) {
        hide(animated: false)

        let content = Self.makeContent(config: config, mode: mode)
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = content
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // A HUD reads the same on any desktop, and keeps the blur legible over
        // whatever windows happen to be underneath it.
        panel.appearance = NSAppearance(named: .vibrantDark)

        let screen = Self.screenUnderCursor()
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2
        ))

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }

        self.panel = panel
    }

    func hide(animated: Bool = true) {
        guard let panel else { return }
        self.panel = nil

        guard animated else { panel.orderOut(nil); return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }

    /// Rebuild in place — used when the mode changes while the sheet is up, so
    /// switching modes with the cheat sheet open shows you the other half.
    func refresh(config: ShakaConfig, mode: WindowMode) {
        guard isVisible else { return }
        show(config: config, mode: mode)
    }

    private static func screenUnderCursor() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    // MARK: - Content

    private static func makeContent(config: ShakaConfig, mode: WindowMode) -> NSView {
        let root = OverlayBackgroundView()
        root.material = .hudWindow
        root.blendingMode = .behindWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 18
        root.layer?.masksToBounds = true

        let groups = Shortcuts.groupedRows(mode: mode, config: config)

        let title = label(
            "\(mode.symbol)  \(mode.label) mode",
            font: .systemFont(ofSize: 17, weight: .semibold),
            color: .labelColor
        )

        let toggleKey = config.bindings["toggle_mode"].map { config.displayString(for: $0) } ?? ""
        let closeKey  = config.bindings["show_shortcuts"].map { config.displayString(for: $0) } ?? ""
        let subtitle = label(
            "\(toggleKey) switches modes   ·   \(closeKey) or esc closes",
            font: .systemFont(ofSize: 11),
            color: .tertiaryLabelColor
        )

        let columns = NSStackView(views: distribute(groups).map(column))
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.spacing = 36
        columns.setHuggingPriority(.required, for: .vertical)

        let stack = NSStackView(views: [title, subtitle, columns])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(20, after: subtitle)
        stack.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 26),
            root.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: 26),
            root.bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: 22),
        ])

        return root
    }

    /// Split the groups over two columns at the halfway point, keeping their
    /// order so the sheet still reads top-down, then left-to-right.
    private static func distribute(
        _ groups: [(group: ShortcutGroup, rows: [ShortcutRow])]
    ) -> [[(group: ShortcutGroup, rows: [ShortcutRow])]] {
        // A header costs about as much vertical space as a row.
        let weights = groups.map { $0.rows.count + 1 }
        let target = weights.reduce(0, +) / 2

        var first: [(group: ShortcutGroup, rows: [ShortcutRow])] = []
        var second = first
        var used = 0

        for (index, entry) in groups.enumerated() {
            if first.isEmpty || used + weights[index] / 2 <= target {
                first.append(entry)
                used += weights[index]
            } else {
                second.append(entry)
            }
        }

        return second.isEmpty ? [first] : [first, second]
    }

    /// A column is one grid rather than a stack of them, so every key cap and
    /// description in it lines up whatever group they belong to.
    private static func column(_ groups: [(group: ShortcutGroup, rows: [ShortcutRow])]) -> NSView {
        var cells: [[NSView]] = []
        var headings: [Int] = []

        for entry in groups {
            headings.append(cells.count)
            cells.append([
                label(entry.group.rawValue.uppercased(),
                      font: .systemFont(ofSize: 10, weight: .bold),
                      color: .tertiaryLabelColor),
                NSGridCell.emptyContentView,
            ])

            for row in entry.rows {
                cells.append([
                    Keycap(row.key),
                    label(row.detail, font: .systemFont(ofSize: 12.5), color: .labelColor),
                ])
            }
        }

        let grid = NSGridView(views: cells)
        grid.rowSpacing = 6
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing

        // Centre each row on itself: a key cap is taller than its label, and
        // baseline alignment leaves the first row of a group sitting low.
        grid.rowAlignment = .none
        for index in 0..<grid.numberOfRows { grid.row(at: index).yPlacement = .center }

        for (position, index) in headings.enumerated() {
            let row = grid.row(at: index)
            row.mergeCells(in: NSRange(location: 0, length: 2))
            grid.cell(atColumnIndex: 0, rowIndex: index).xPlacement = .leading
            row.bottomPadding = 3
            if position > 0 { row.topPadding = 14 }
        }

        return grid
    }

    private static func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        return field
    }
}

// MARK: - Views

/// The blurred backdrop. Clicking anywhere on the sheet puts it away.
private final class OverlayBackgroundView: NSVisualEffectView {
    override func mouseDown(with event: NSEvent) {
        ShortcutOverlay.shared.hide()
    }
}

/// A key combo drawn as a key cap, so the eye can find it in the column.
private final class Keycap: NSView {
    private let field: NSTextField

    init(_ text: String) {
        field = NSTextField(labelWithString: text)
        field.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        field.textColor = .labelColor
        field.translatesAutoresizingMaskIntoConstraints = false

        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 1
        applyColors()

        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            trailingAnchor.constraint(equalTo: field.trailingAnchor, constant: 7),
            field.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            bottomAnchor.constraint(equalTo: field.bottomAnchor, constant: 2),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    /// The baseline the grid aligns rows on is the label's, not the cap's.
    override var firstBaselineOffsetFromTop: CGFloat {
        2 + field.firstBaselineOffsetFromTop
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.10).cgColor
        }
    }
}
