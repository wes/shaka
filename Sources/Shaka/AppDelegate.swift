import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var hotkeyManager: HotkeyManager?
    private var permissionTimer: Timer?
    private var config = ShakaConfig()
    private var isEnabled = true
    private var isTrusted = false

    /// The last app that was in front, Shaka aside.
    ///
    /// Opening the status menu can make Shaka the frontmost app, and every
    /// window action starts from the frontmost app's focused window — so a
    /// shortcut run from the menu has to hand focus back before it acts.
    private var lastActiveApp: NSRunningApplication?

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

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(workspaceDidChange),
            name: .shakaWorkspaceChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(toggleShortcutOverlay),
            name: .shakaToggleShortcuts,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        lastActiveApp = NSWorkspace.shared.frontmostApplication
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
        // Switching modes with the cheat sheet up swaps it for the other half.
        ShortcutOverlay.shared.refresh(config: config, mode: currentMode)
    }

    @objc private func workspaceDidChange() {
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
        guard isTrusted else {
            statusItem.button?.title = "🤙⚠"
            return
        }

        // Reef shows which workspace is on screen — the one thing about the
        // layout you cannot tell by looking at the windows in front of you.
        let workspace = windowManager?.workspaceNumber ?? 0
        statusItem.button?.title = workspace > 0
            ? "\(currentMode.symbol) \(workspace)"
            : currentMode.symbol
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

        if mode == .reef, let workspaces = windowManager?.workspaceOverview(), !workspaces.isEmpty {
            let item = NSMenuItem(title: "Workspaces", action: nil, keyEquivalent: "")
            item.submenu = workspacesMenu(workspaces)
            menu.addItem(item)
        }

        let sheetItem = NSMenuItem(
            title: "Cheat Sheet", action: #selector(toggleShortcutOverlay), keyEquivalent: ""
        )
        sheetItem.target = self
        if let combo = config.bindings["show_shortcuts"],
           let key = config.menuKey(for: combo) {
            sheetItem.keyEquivalent = key.key
            sheetItem.keyEquivalentModifierMask = key.modifiers
        }
        menu.addItem(sheetItem)

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

        menu.delegate = self
        statusItem.menu = menu
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        // Last chance to note who to hand focus back to. Opening the menu may
        // already have made Shaka frontmost, in which case the app tracked from
        // the activation notifications is still the right answer.
        if let front = NSWorkspace.shared.frontmostApplication,
           front != NSRunningApplication.current {
            lastActiveApp = front
        }
    }

    @objc private func appDidActivate(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app != NSRunningApplication.current else { return }
        lastActiveApp = app
    }

    /// Workspaces on the focused display, with how full each one is. Picking one
    /// switches to it, the same as its shortcut would.
    private func workspacesMenu(_ workspaces: [WorkspaceSummary]) -> NSMenu {
        let submenu = NSMenu()

        for workspace in workspaces {
            let count = workspace.windows
            let detail = count == 0 ? "empty" : (count == 1 ? "1 window" : "\(count) windows")

            let item = NSMenuItem(
                title: "\(workspace.number)   \(detail)",
                action: #selector(selectWorkspace(_:)),
                keyEquivalent: ""
            )
            item.state = workspace.isActive ? .on : .off
            item.representedObject = workspace.number
            item.target = self
            submenu.addItem(item)
        }

        return submenu
    }

    /// Shortcut list for the active mode, built from the live bindings so a
    /// rebound key shows up here too. Every row runs its action when picked —
    /// the same one the keystroke would.
    private func shortcutsMenu(for mode: WindowMode) -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        for (index, entry) in Shortcuts.groupedRows(mode: mode, config: config).enumerated() {
            if index > 0 { submenu.addItem(.separator()) }
            submenu.addItem(Self.sectionHeader(entry.group.rawValue))

            for row in entry.rows {
                // The cheat sheet has its own entry a level up.
                guard row.action != .showShortcuts else { continue }
                submenu.addItem(shortcutItem(row))
            }
        }

        return submenu
    }

    /// One shortcut row. The combo becomes a real key equivalent rather than
    /// padded text, so AppKit draws it right-aligned in the usual style — and a
    /// numbered family (workspaces 1-9) becomes a submenu of its members.
    private func shortcutItem(_ row: ShortcutRow) -> NSMenuItem {
        let item = NSMenuItem(title: row.detail, action: nil, keyEquivalent: "")

        guard row.members.isEmpty else {
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for member in row.members { submenu.addItem(shortcutItem(member)) }
            item.submenu = submenu
            item.isEnabled = isEnabled
            return item
        }

        item.action = #selector(runShortcut(_:))
        item.target = self
        item.representedObject = row.action?.rawValue
        item.isEnabled = isEnabled

        if let action = row.action,
           let combo = config.bindings[action.rawValue],
           let key = config.menuKey(for: combo) {
            item.keyEquivalent = key.key
            item.keyEquivalentModifierMask = key.modifiers
        }

        return item
    }

    /// A group heading inside the Shortcuts submenu.
    private static func sectionHeader(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: text.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        return item
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

    @objc private func selectWorkspace(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? Int else { return }
        windowManager?.showWorkspace(number)
    }

    /// Runs a shortcut picked from the menu.
    @objc private func runShortcut(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let action = Action(rawValue: raw),
              let wm = windowManager, isEnabled else { return }

        if action == .showShortcuts { toggleShortcutOverlay(); return }

        // Hand focus back first, and give the activation a moment to land —
        // otherwise the action would look at Shaka's own (windowless) app.
        guard let app = lastActiveApp, !app.isActive else {
            wm.perform(action)
            return
        }

        app.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { wm.perform(action) }
    }

    @objc private func toggleShortcutOverlay() {
        guard isTrusted else { return }
        ShortcutOverlay.shared.toggle(config: config, mode: currentMode)
    }

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        isEnabled.toggle()

        if isEnabled {
            hotkeyManager?.start()
            print("Shaka resumed")
        } else {
            // Hand tiled windows back before going quiet.
            ShortcutOverlay.shared.hide()
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
        ShortcutOverlay.shared.hide()
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
        ShortcutOverlay.shared.hide(animated: false)
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
        \(L) + 1-9              —         show workspace
        \(L) + shift + 1-9      —         send window to workspace
        \(L) + cmd + drag       —         move tile (right button resizes)

        \(L) + k  puts the full list for the mode you are in on screen.

        starting in: \(config.startMode.label)
        config: ~/.config/shaka/config.toml

        """)
    }
}
