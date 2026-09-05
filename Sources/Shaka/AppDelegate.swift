import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotkeyManager: HotkeyManager?
    private var permissionTimer: Timer?
    private var config = ShakaConfig()
    private var isEnabled = true
    private var isTrusted = false

    /// Actions listed in the Shortcuts menu, with what each one does per mode.
    /// Reef reuses Flow's keys, so the same binding gets two descriptions.
    private static let shortcutRows: [(action: String, flow: String, reef: String)] = [
        ("focus_left",   "Focus window left",   "Focus tile left"),
        ("focus_right",  "Focus window right",  "Focus tile right"),
        ("focus_up",     "Focus window up",     "Focus tile up"),
        ("focus_down",   "Focus window down",   "Focus tile down"),
        ("move_left",    "Nudge window left",   "Swap tile left"),
        ("move_right",   "Nudge window right",  "Swap tile right"),
        ("move_up",      "Nudge window up",     "Swap tile up"),
        ("move_down",    "Nudge window down",   "Swap tile down"),
        ("grow_width",   "Grow width",          "Widen split"),
        ("shrink_width", "Shrink width",        "Narrow split"),
        ("grow_height",  "Grow height",         "Heighten split"),
        ("shrink_height","Shrink height",       "Shorten split"),
        ("snap_left",    "Snap left ½ ⅓ ⅔",     "Send to display left"),
        ("snap_right",   "Snap right ½ ⅓ ⅔",    "Send to display right"),
        ("snap_up",      "Snap top ½ ⅓ ⅔",      "Send to display up"),
        ("snap_down",    "Snap bottom ½ ⅓ ⅔",   "Send to display down"),
        ("center",       "Center window",       "Promote to master"),
        ("fill",         "Fill screen",         "Toggle fullscreen"),
        ("toggle_split", "—",                   "Toggle split direction"),
        ("toggle_float", "—",                   "Toggle floating"),
        ("cycle_next",   "—",                   "Cycle focus"),
        ("toggle_mode",  "Switch to Reef",     "Switch to Flow"),
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        config = ShakaConfig.load()
        setupStatusBar()
        printWelcome()
        requestAccessibility()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(modeDidChange(_:)),
            name: .shakaModeChanged,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager?.windowManager.shutdown()
    }

    private var windowManager: WindowManager? { hotkeyManager?.windowManager }

    private var currentMode: WindowMode { windowManager?.mode ?? config.startMode }

    @objc private func modeDidChange(_ note: Notification) {
        guard note.object is WindowManager else { return }
        refreshStatusTitle()
        rebuildMenu()
    }

    // MARK: - Status Bar

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        refreshStatusTitle()
        rebuildMenu()
    }

    private func refreshStatusTitle() {
        statusItem.button?.title = isTrusted ? currentMode.symbol : "🤙⚠"
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let mode = currentMode

        let titleItem = NSMenuItem(
            title: isTrusted ? "Shaka — \(mode.label) mode" : "Shaka — not running",
            action: nil, keyEquivalent: ""
        )
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        menu.addItem(NSMenuItem.separator())

        if !isTrusted {
            // Without Accessibility every hotkey and the mode picker are inert.
            // Say so, rather than letting the menu look functional.
            for line in [
                "⚠︎  Accessibility permission needed",
                "    Shortcuts and mode switching are disabled.",
                "    Re-granting is required after every reinstall,",
                "    because Shaka is ad-hoc signed.",
            ] {
                let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }

            let fix = NSMenuItem(
                title: "Open Accessibility Settings...",
                action: #selector(openAccessibilitySettings), keyEquivalent: ""
            )
            fix.target = self
            menu.addItem(fix)

            menu.addItem(NSMenuItem.separator())

            let quitItem = NSMenuItem(title: "Quit Shaka", action: #selector(quit), keyEquivalent: "q")
            quitItem.target = self
            menu.addItem(quitItem)

            statusItem.menu = menu
            return
        }

        // Mode picker
        for candidate in [WindowMode.flow, .reef] {
            let item = NSMenuItem(
                title: "\(candidate.symbol)  \(candidate.label)",
                action: #selector(selectMode(_:)),
                keyEquivalent: ""
            )
            item.state = (candidate == mode) ? .on : .off
            item.representedObject = candidate.rawValue
            item.target = self
            menu.addItem(item)
        }

        let hint = NSMenuItem(
            title: "    \(config.displayString(for: config.bindings["toggle_mode"] ?? "")) to switch",
            action: nil, keyEquivalent: ""
        )
        hint.isEnabled = false
        menu.addItem(hint)

        menu.addItem(NSMenuItem.separator())

        let shortcutsItem = NSMenuItem(title: "Shortcuts", action: nil, keyEquivalent: "")
        shortcutsItem.submenu = shortcutsMenu(for: mode)
        menu.addItem(shortcutsItem)

        menu.addItem(NSMenuItem.separator())

        let enableItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled(_:)), keyEquivalent: "e")
        enableItem.state = isEnabled ? .on : .off
        enableItem.target = self
        menu.addItem(enableItem)

        let editItem = NSMenuItem(title: "Edit Config...", action: #selector(editConfig), keyEquivalent: ",")
        editItem.target = self
        menu.addItem(editItem)

        let reloadItem = NSMenuItem(title: "Reload Config", action: #selector(reloadConfig), keyEquivalent: "r")
        reloadItem.target = self
        menu.addItem(reloadItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit Shaka", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    /// Shortcut list for the active mode, built from the live bindings so a
    /// rebound key shows up here too.
    private func shortcutsMenu(for mode: WindowMode) -> NSMenu {
        let submenu = NSMenu()

        let widest = Self.shortcutRows
            .compactMap { config.bindings[$0.action] }
            .map { config.displayString(for: $0).count }
            .max() ?? 0

        for row in Self.shortcutRows {
            guard let combo = config.bindings[row.action] else { continue }
            let description = (mode == .flow) ? row.flow : row.reef
            guard description != "—" else { continue }

            let key = config.displayString(for: combo)
                .padding(toLength: widest, withPad: " ", startingAt: 0)

            let item = NSMenuItem(title: "\(key)   \(description)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.attributedTitle = NSAttributedString(
                string: item.title,
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]
            )
            submenu.addItem(item)
        }

        return submenu
    }

    // MARK: - Accessibility

    private func requestAccessibility() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary

        if AXIsProcessTrustedWithOptions(options) {
            isTrusted = true
            startHotkeyManager()
            return
        }

        // A stale grant denies silently: System Settings still shows Shaka
        // ticked, but the ad-hoc signature no longer matches what was approved,
        // so macOS never even prompts. Spell out the fix.
        print("""

        ⚠️  Shaka has no Accessibility permission — every shortcut is disabled.

        If Shaka already appears ticked in System Settings, the grant is stale:
        replacing the binary changes its ad-hoc signature. Remove Shaka with the
        \u{2212} button, then add /Applications/Shaka.app again.

        System Settings → Privacy & Security → Accessibility

        """)

        refreshStatusTitle()
        rebuildMenu()

        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted() else { return }
            timer.invalidate()
            self?.permissionTimer = nil
            self?.isTrusted = true
            self?.startHotkeyManager()
        }
    }

    private func startHotkeyManager() {
        AX.configureMessagingTimeout()
        hotkeyManager = HotkeyManager(config: config)
        hotkeyManager?.start()
        refreshStatusTitle()
        rebuildMenu()
        print("Shaka is ready 🤙")
    }

    // MARK: - Actions

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = WindowMode(rawValue: raw) else { return }
        windowManager?.setMode(mode)
    }

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        isEnabled.toggle()

        if isEnabled {
            hotkeyManager?.start()
            print("Shaka resumed")
        } else {
            // Hand tiled windows back before going quiet.
            windowManager?.shutdown()
            hotkeyManager?.stop()
            print("Shaka paused")
        }
        rebuildMenu()
    }

    @objc private func openAccessibilitySettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func editConfig() {
        NSWorkspace.shared.open(
            [ShakaConfig.configPath],
            withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    @objc private func reloadConfig() {
        // Restore windows under the old config before swapping engines out.
        windowManager?.shutdown()
        hotkeyManager?.stop()

        config = ShakaConfig.load()
        hotkeyManager = HotkeyManager(config: config)
        hotkeyManager?.start()
        isEnabled = true

        refreshStatusTitle()
        rebuildMenu()
        print("Config reloaded 🤙")
    }

    @objc private func quit() {
        windowManager?.shutdown()
        hotkeyManager?.stop()
        NSApp.terminate(nil)
    }

    // MARK: - Welcome

    private func printWelcome() {
        let L = config.leader
        print("""

        🤙 Shaka Window Manager
        ─────────────────────────
        Two modes, same keys — \(L) + /  switches between them.

        Flow (free-floating)          Reef (Hyprland-style tiling)
        \(L) + arrows           focus     focus tile
        \(L) + opt + arrows     move      swap tile
        \(L) + shift + arrows   resize    resize split
        \(L) + cmd + arrows     snap      send to display
        \(L) + return           center    promote to master
        \(L) + shift + return   fill      toggle fullscreen
        \(L) + shift + s        —         toggle split direction
        \(L) + shift + f        —         toggle floating
        \(L) + opt + tab        —         cycle focus

        starting in: \(config.startMode.label)
        config: ~/.config/shaka/config.toml

        """)
    }
}
