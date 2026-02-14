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

        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
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

    // MARK: - Key Handling

    func handleKeyDown(_ event: CGEvent) -> Bool {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags.intersection(modifierMask)

        guard let binding = bindings.first(where: {
            $0.keyCode == keyCode && $0.modifiers == flags
        }) else {
            return false
        }

        let wm = windowManager
        let action = binding.action

        DispatchQueue.main.async {
            switch action {
            case .focusLeft:    wm.focusWindow(.left)
            case .focusRight:   wm.focusWindow(.right)
            case .focusUp:      wm.focusWindow(.up)
            case .focusDown:    wm.focusWindow(.down)
            case .moveLeft:     wm.move(.left)
            case .moveRight:    wm.move(.right)
            case .moveUp:       wm.move(.up)
            case .moveDown:     wm.move(.down)
            case .growWidth:    wm.resize(.right)
            case .shrinkWidth:  wm.resize(.left)
            case .growHeight:   wm.resize(.up)
            case .shrinkHeight: wm.resize(.down)
            case .snapLeft:     wm.snap(.left)
            case .snapRight:    wm.snap(.right)
            case .snapUp:       wm.snap(.up)
            case .snapDown:     wm.snap(.down)
            case .center:       wm.center()
            case .fill:         wm.smartFill()
            }
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

    guard type == .keyDown else {
        return Unmanaged.passUnretained(event)
    }

    if manager.handleKeyDown(event) {
        return nil
    }

    return Unmanaged.passUnretained(event)
}
