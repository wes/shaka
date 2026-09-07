import Cocoa

class HotkeyManager {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    let windowManager: WindowManager
    let bindings: [ParsedBinding]

    /// Only compare the four main modifiers when matching key events
    private let modifierMask: CGEventFlags = [
        .maskControl, .maskShift, .maskCommand, .maskAlternate,
    ]

    init(config: ShakaConfig) {
        self.bindings = config.parseBindings()
        self.windowManager = WindowManager(config: config)
    }

    func start() {
        guard eventTap == nil else { return }

        // Mouse events come through the same tap: Reef's drag gestures have to
        // be able to swallow them before the app underneath reacts.
        let eventMask: CGEventMask = Self.watchedEvents.reduce(0) { $0 | (1 << $1.rawValue) }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: selfPtr
        )

        if eventTap == nil {
            eventTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: eventMask,
                callback: eventTapCallback,
                userInfo: selfPtr
            )
        }

        guard let eventTap else {
            print("[shaka] failed to create event tap — check Accessibility permissions")
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    func reenableTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
    }

    private static let watchedEvents: [CGEventType] = [
        .keyDown,
        .leftMouseDown, .leftMouseDragged, .leftMouseUp,
        .rightMouseDown, .rightMouseDragged, .rightMouseUp,
    ]

    // MARK: - Mouse Handling

    /// Returns true when Reef claimed the event and the app should not see it.
    ///
    /// Unlike key actions this runs inline rather than hopping to the next main
    /// loop turn, because the answer decides whether the event is delivered.
    func handleMouse(_ type: CGEventType, _ event: CGEvent) -> Bool {
        windowManager.handleMouse(
            type: type,
            at: event.location,
            flags: event.flags.intersection(modifierMask)
        )
    }

    // MARK: - Key Handling

    func handleKeyDown(_ event: CGEvent) -> Bool {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags.intersection(modifierMask)

        // Escape closes the cheat sheet. Only while it is up, and only when it
        // is a bare Escape, so nothing else ever loses the key.
        if keyCode == 53, flags.isEmpty, ShortcutOverlay.shared.isVisible {
            DispatchQueue.main.async { ShortcutOverlay.shared.hide() }
            return true
        }

        guard let binding = bindings.first(where: {
            $0.keyCode == keyCode && $0.modifiers == flags
        }) else {
            return false
        }

        let wm = windowManager
        let action = binding.action

        // Reef-only actions stay out of the way in Flow mode: pass the
        // keystroke through to the focused app instead of swallowing it.
        if action.isReefOnly && wm.mode == .flow { return false }

        DispatchQueue.main.async {
            if action == .showShortcuts {
                NotificationCenter.default.post(name: .shakaToggleShortcuts, object: nil)
                return
            }
            wm.perform(action)
        }

        return true
    }
}

// MARK: - C callback

private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }

    let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        manager.reenableTap()
        return Unmanaged.passUnretained(event)
    }

    switch type {
    case .keyDown:
        return manager.handleKeyDown(event) ? nil : Unmanaged.passUnretained(event)
    case .leftMouseDown, .leftMouseDragged, .leftMouseUp,
         .rightMouseDown, .rightMouseDragged, .rightMouseUp:
        return manager.handleMouse(type, event) ? nil : Unmanaged.passUnretained(event)
    default:
        return Unmanaged.passUnretained(event)
    }
}
