import Cocoa

// MARK: - Window Reference

/// Hashable wrapper around `AXUIElement` so window handles can key dictionaries
/// and sets. AX element references for the same window compare equal via
/// `CFEqual` even when obtained from separate queries, so identity survives
/// re-scanning the window list.
struct WindowRef: Hashable {
    let element: AXUIElement

    init(_ element: AXUIElement) { self.element = element }

    static func == (lhs: WindowRef, rhs: WindowRef) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }

    var frame: CGRect {
        get { AX.frame(of: element) }
        nonmutating set { AX.setFrame(element, newValue) }
    }
}

// MARK: - Accessibility Helpers

enum AX {

    /// Cap how long any Accessibility request may block.
    ///
    /// Reef mode queries every running app, so one unresponsive process would
    /// otherwise stall the main thread — and with it the event tap — indefinitely.
    /// Setting this on the system-wide element makes it the default everywhere.
    static func configureMessagingTimeout() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
    }

    // MARK: Attributes

    static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success else {
            return nil
        }
        return ref
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    static func bool(_ element: AXUIElement, _ name: String) -> Bool {
        (attribute(element, name) as? Bool) ?? false
    }

    static func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success else {
            return false
        }
        return settable.boolValue
    }

    // MARK: Geometry

    static func frame(of window: AXUIElement) -> CGRect {
        var position = CGPoint.zero
        var size     = CGSize.zero

        if let val = attribute(window, kAXPositionAttribute as String) {
            AXValueGetValue(val as! AXValue, .cgPoint, &position)
        }
        if let val = attribute(window, kAXSizeAttribute as String) {
            AXValueGetValue(val as! AXValue, .cgSize, &size)
        }

        return CGRect(origin: position, size: size)
    }

    static func setFrame(_ window: AXUIElement, _ frame: CGRect) {
        var pos  = frame.origin
        var size = frame.size

        if let v = AXValueCreate(.cgPoint, &pos) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, v)
        }
        if let v = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, v)
        }
    }

    /// Position → size → position. Apps that clamp their size (terminals snapping to
    /// a character grid, windows with a minimum width) can shift after a resize, so
    /// re-asserting the origin lands them where the layout actually wants them.
    /// Costs an extra IPC round trip, so it is only worth doing once a move settles.
    static func setFrameSettled(_ window: AXUIElement, _ frame: CGRect) {
        var pos  = frame.origin
        var size = frame.size

        if let v = AXValueCreate(.cgPoint, &pos) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, v)
        }
        if let v = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, v)
        }
        if let v = AXValueCreate(.cgPoint, &pos) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, v)
        }
    }

    // MARK: Windows

    /// The frontmost app's focused window.
    ///
    /// Uses `NSWorkspace` to find the app rather than the AX system-wide element,
    /// which fails for some apps (e.g. Chrome).
    static func focusedWindow() -> AXUIElement? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)

        // 1. Focused window (works for most apps)
        if let win = attribute(appElement, kAXFocusedWindowAttribute as String) {
            return (win as! AXUIElement)
        }
        // 2. Main window (Chrome often only exposes this)
        if let win = attribute(appElement, kAXMainWindowAttribute as String) {
            return (win as! AXUIElement)
        }
        // 3. First from the windows list
        if let windows = attribute(appElement, kAXWindowsAttribute as String) as? [AXUIElement] {
            return windows.first
        }
        return nil
    }

    static func windows(ofPID pid: pid_t) -> [AXUIElement] {
        let appElement = AXUIElementCreateApplication(pid)
        return attribute(appElement, kAXWindowsAttribute as String) as? [AXUIElement] ?? []
    }

    static func focus(_ window: AXUIElement) {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)

        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success,
              let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.activate()
    }

    /// The frame of a real, tileable window, or nil if Shaka should leave it
    /// alone: a standard window that is on screen, big enough to matter, and
    /// whose geometry we are allowed to change. Filters out sheets, palettes,
    /// popovers and fixed-size dialogs.
    ///
    /// Returns the frame rather than a Bool because reading it costs an
    /// Accessibility round trip that every caller needs anyway.
    static func manageableFrame(_ window: AXUIElement) -> CGRect? {
        guard string(window, kAXRoleAttribute as String) == kAXWindowRole as String,
              string(window, kAXSubroleAttribute as String) == kAXStandardWindowSubrole as String,
              !bool(window, kAXMinimizedAttribute as String),
              isSettable(window, kAXPositionAttribute as String),
              isSettable(window, kAXSizeAttribute as String)
        else { return nil }

        let f = frame(of: window)
        return (f.width >= 80 && f.height >= 80) ? f : nil
    }
}

// MARK: - Screen Geometry

extension NSScreen {
    /// This screen's visible frame in Accessibility coordinates: origin at the
    /// top-left of the primary display with y growing downward, versus Cocoa's
    /// bottom-left origin.
    var axVisibleFrame: CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? frame.height
        let vf = visibleFrame
        return CGRect(
            x:      vf.origin.x,
            y:      primaryHeight - vf.origin.y - vf.height,
            width:  vf.width,
            height: vf.height
        )
    }

    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) } ?? 0
    }

    /// The screen containing a point given in Accessibility coordinates.
    static func containing(axPoint point: CGPoint) -> NSScreen? {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cocoaPoint = CGPoint(x: point.x, y: primaryHeight - point.y)
        return NSScreen.screens.first { $0.frame.contains(cocoaPoint) } ?? NSScreen.main
    }

    static func containing(axWindow window: AXUIElement) -> NSScreen? {
        let f = AX.frame(of: window)
        return containing(axPoint: CGPoint(x: f.midX, y: f.midY))
    }
}
