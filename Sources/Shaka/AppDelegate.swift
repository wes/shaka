import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotkeyManager: HotkeyManager?
    private var permissionTimer: Timer?
    private var config = ShakaConfig()

    func applicationDidFinishLaunching(_ notification: Notification) {
        config = ShakaConfig.load()
        setupStatusBar()
        printWelcome()
        requestAccessibility()
    }

    // MARK: - Status Bar

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.title = "🤙"
        }

        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let L = config.leaderSymbol

        let titleItem = NSMenuItem(title: "Shaka", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        menu.addItem(NSMenuItem.separator())

        let shortcutsItem = NSMenuItem(title: "Shortcuts", action: nil, keyEquivalent: "")
        let shortcutsMenu = NSMenu()
        for line in [
            "\(L) ←→↑↓       Focus window",
            "\(L)⌥ ←→↑↓      Move window",
            "\(L)⇧ ←→↑↓      Resize window",
            "\(L) Return      Center window",
            "\(L)⇧ Return     Fill screen",
        ] {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            shortcutsMenu.addItem(item)
        }
        shortcutsItem.submenu = shortcutsMenu
        menu.addItem(shortcutsItem)

        menu.addItem(NSMenuItem.separator())

        let enableItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled(_:)), keyEquivalent: "e")
        enableItem.state = .on
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

    // MARK: - Accessibility

    private func requestAccessibility() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary

        if AXIsProcessTrustedWithOptions(options) {
            startHotkeyManager()
        } else {
            print("Waiting for Accessibility permission...")
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
                if AXIsProcessTrusted() {
                    timer.invalidate()
                    self?.permissionTimer = nil
                    self?.startHotkeyManager()
                }
            }
        }
    }

    private func startHotkeyManager() {
        hotkeyManager = HotkeyManager(config: config)
        hotkeyManager?.start()
        print("Shaka is ready 🤙")
    }

    // MARK: - Actions

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        if sender.state == .on {
            sender.state = .off
            hotkeyManager?.stop()
            print("Shaka paused")
        } else {
            sender.state = .on
            hotkeyManager?.start()
            print("Shaka resumed")
        }
    }

    @objc private func editConfig() {
        NSWorkspace.shared.open(
            [ShakaConfig.configPath],
            withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    @objc private func reloadConfig() {
        hotkeyManager?.stop()
        config = ShakaConfig.load()
        hotkeyManager = HotkeyManager(config: config)
        hotkeyManager?.start()
        rebuildMenu()
        print("Config reloaded 🤙")
    }

    @objc private func quit() {
        hotkeyManager?.stop()
        NSApp.terminate(nil)
    }

    // MARK: - Welcome

    private func printWelcome() {
        let L = config.leader
        print("""

        🤙 Shaka Window Manager
        ─────────────────────────
        \(L) + arrows           focus
        \(L) + opt + arrows     move
        \(L) + shift + arrows   resize
        \(L) + return           center
        \(L) + shift + return   fill

        config: ~/.config/shaka/config.toml

        """)
    }
}
