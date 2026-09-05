import Cocoa

enum Direction {
    case left, right, up, down
}

enum WindowMode: String {
    /// Free-floating: nudge, resize and snap windows wherever you like.
    case flow
    /// Hyprland-style dwindle tiling: every window is a tile, nothing overlaps.
    case reef

    var label: String {
        switch self {
        case .flow:  return "Flow"
        case .reef: return "Reef"
        }
    }

    /// Menu bar glyph. Same gesture family, opposite tension: Flow is the loose
    /// open hand, Reef the closed one.
    var symbol: String {
        switch self {
        case .flow: return "🤙"
        case .reef: return "👊"
        }
    }
}

extension Notification.Name {
    static let shakaModeChanged = Notification.Name("shakaModeChanged")
}

/// Routes every action to whichever mode is active.
///
/// Flow keeps the original free-floating behaviour; Reef hands the same
/// keystrokes to the tiler. Both share one spring animator, so switching modes
/// animates rather than teleporting.
class WindowManager {

    // MARK: - Configuration

    private let moveStep:      CGFloat
    private let resizeStep:    CGFloat
    private let edgeSnap:      CGFloat
    private let screenPadding: CGFloat
    private let minDimension:  CGFloat = 200

    private let animator: Animator
    private let reef: ReefEngine

    private(set) var mode: WindowMode

    init(config: ShakaConfig) {
        moveStep      = CGFloat(config.moveStep)
        resizeStep    = CGFloat(config.resizeStep)
        edgeSnap      = CGFloat(config.edgeSnap)
        screenPadding = CGFloat(config.screenPadding)

        animator = Animator(
            stiffness: CGFloat(config.animationStiffness),
            damping:   CGFloat(config.animationDamping)
        )
        reef = ReefEngine(config: config, animator: animator)
        mode  = config.startMode

        if mode == .reef { reef.activate() }
    }

    // Snap cycle: half → third → two-thirds → half → ...
    private var lastSnapDirection: Direction?
    private var snapCycleIndex: Int = 0
    private let snapFractions: [CGFloat] = [1.0 / 2, 1.0 / 3, 2.0 / 3]

    // MARK: - Mode

    func toggleMode() {
        setMode(mode == .flow ? .reef : .flow)
    }

    func setMode(_ newMode: WindowMode) {
        guard newMode != mode else { return }
        mode = newMode

        switch mode {
        case .reef: reef.activate()
        case .flow:  reef.deactivate()
        }

        print("[shaka] mode: \(mode.label)")
        NotificationCenter.default.post(name: .shakaModeChanged, object: self)
    }

    /// Called when Shaka is disabled or quits so Reef hands windows back.
    func shutdown() {
        reef.deactivate()
        animator.cancelAll()
    }

    /// Reef owns the focused window unless it is floating or untracked, in
    /// which case the action falls through to Flow.
    private var reefHasFocus: Bool {
        mode == .reef && reef.handlesFocusedWindow()
    }

    // MARK: - Actions

    func move(_ direction: Direction) {
        if reefHasFocus { reef.moveWindow(direction); return }
        flowMove(direction)
    }

    func resize(_ direction: Direction) {
        if reefHasFocus { reef.resize(direction); return }
        flowResize(direction)
    }

    func center() {
        if reefHasFocus { reef.promoteToMaster(); return }
        flowCenter()
    }

    func smartFill() {
        if reefHasFocus { reef.toggleFullscreen(); return }
        flowFill()
    }

    func snap(_ direction: Direction) {
        if reefHasFocus { reef.moveToDisplay(direction); return }
        flowSnap(direction)
    }

    func focusWindow(_ direction: Direction) {
        if reefHasFocus { reef.focus(direction); return }
        flowFocus(direction)
    }

    // Reef-only: HotkeyManager does not dispatch these while in Flow mode.

    func toggleSplit() {
        guard mode == .reef else { return }
        reef.toggleSplit()
    }

    func toggleFloat() {
        guard mode == .reef else { return }
        reef.toggleFloat()
    }

    func cycleNext() {
        guard mode == .reef else { return }
        reef.cycleFocus()
    }

    // MARK: - Flow: Move / Resize

    private func flowMove(_ direction: Direction) {
        withFocusedWindow { window, screenFrame in
            var target = self.animator.logicalFrame(of: window)

            switch direction {
            case .left:  target.origin.x -= self.moveStep
            case .right: target.origin.x += self.moveStep
            case .up:    target.origin.y -= self.moveStep
            case .down:  target.origin.y += self.moveStep
            }

            target = self.constrain(target, within: screenFrame)
            target = self.snapToEdges(target, within: screenFrame)
            self.animator.animate(window, to: target)
        }
    }

    private func flowResize(_ direction: Direction) {
        withFocusedWindow { window, screenFrame in
            var target = self.animator.logicalFrame(of: window)
            let step = self.resizeStep

            // Resize from center so the window stays visually anchored
            switch direction {
            case .right:
                target.size.width  += step
                target.origin.x    -= step / 2
            case .left:
                let delta = min(step, target.size.width - self.minDimension)
                target.size.width  -= delta
                target.origin.x    += delta / 2
            case .up:
                target.size.height += step
                target.origin.y    -= step / 2
            case .down:
                let delta = min(step, target.size.height - self.minDimension)
                target.size.height -= delta
                target.origin.y    += delta / 2
            }

            self.animator.animate(window, to: self.constrain(target, within: screenFrame))
        }
    }

    private func flowCenter() {
        withFocusedWindow { window, screenFrame in
            var target = self.animator.logicalFrame(of: window)
            target.origin.x = screenFrame.midX - target.width / 2
            target.origin.y = screenFrame.midY - target.height / 2
            self.animator.animate(window, to: target)
        }
    }

    private func flowFill() {
        withFocusedWindow { window, screenFrame in
            let p = self.screenPadding
            self.animator.animate(window, to: CGRect(
                x: screenFrame.minX + p,
                y: screenFrame.minY + p,
                width:  screenFrame.width  - p * 2,
                height: screenFrame.height - p * 2
            ))
        }
    }

    // MARK: - Flow: Snap

    private func flowSnap(_ direction: Direction) {
        // Cycle through sizes on repeated presses of the same direction
        if direction == lastSnapDirection {
            snapCycleIndex = (snapCycleIndex + 1) % snapFractions.count
        } else {
            snapCycleIndex = 0
            lastSnapDirection = direction
        }

        let fraction = snapFractions[snapCycleIndex]

        withFocusedWindow { window, screenFrame in
            let p = self.screenPadding
            var target: CGRect

            switch direction {
            case .left:
                let w = self.snapDimension(screenFrame.width, fraction: fraction)
                target = CGRect(x: screenFrame.minX + p, y: screenFrame.minY + p,
                                width: w, height: screenFrame.height - p * 2)
            case .right:
                let w = self.snapDimension(screenFrame.width, fraction: fraction)
                target = CGRect(x: screenFrame.maxX - p - w, y: screenFrame.minY + p,
                                width: w, height: screenFrame.height - p * 2)
            case .up:
                let h = self.snapDimension(screenFrame.height, fraction: fraction)
                target = CGRect(x: screenFrame.minX + p, y: screenFrame.minY + p,
                                width: screenFrame.width - p * 2, height: h)
            case .down:
                let h = self.snapDimension(screenFrame.height, fraction: fraction)
                target = CGRect(x: screenFrame.minX + p, y: screenFrame.maxY - p - h,
                                width: screenFrame.width - p * 2, height: h)
            }

            self.animator.animate(window, to: target)
        }
    }

    /// Calculate a snap dimension (width or height) for a given fraction,
    /// accounting for uniform padding between sections.
    private func snapDimension(_ total: CGFloat, fraction: CGFloat) -> CGFloat {
        return fraction * (total - screenPadding) - screenPadding
    }

    // MARK: - Flow: Focus

    private func flowFocus(_ direction: Direction) {
        guard let currentWindow = AX.focusedWindow() else { return }
        let currentFrame = AX.frame(of: currentWindow)
        let cx = Double(currentFrame.midX)
        let cy = Double(currentFrame.midY)

        // Get all visible windows via CGWindowList (fast, single system call)
        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return }

        var bestPID: pid_t = 0
        var bestBounds = CGRect.zero
        var bestScore = Double.infinity

        for info in infoList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsRef = info[kCGWindowBounds as String]
            else { continue }

            var bounds = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsRef as! CFDictionary, &bounds) else { continue }
            guard bounds.width > 50, bounds.height > 50 else { continue }

            // Skip current window (approximate match)
            if abs(bounds.origin.x - currentFrame.origin.x) < 2 &&
               abs(bounds.origin.y - currentFrame.origin.y) < 2 &&
               abs(bounds.width - currentFrame.width) < 2 &&
               abs(bounds.height - currentFrame.height) < 2 { continue }

            let dx = Double(bounds.midX) - cx
            let dy = Double(bounds.midY) - cy

            // Must be in the requested direction
            switch direction {
            case .left:  guard dx < -10 else { continue }
            case .right: guard dx >  10 else { continue }
            case .up:    guard dy < -10 else { continue }
            case .down:  guard dy >  10 else { continue }
            }

            // Score: penalize perpendicular offset so we prefer
            // windows directly in the requested direction
            let score: Double
            switch direction {
            case .left, .right: score = dx * dx + dy * dy * 4
            case .up, .down:    score = dx * dx * 4 + dy * dy
            }

            if score < bestScore {
                bestScore = score
                bestPID = pid
                bestBounds = bounds
            }
        }

        guard bestPID != 0 else { return }

        if let app = NSRunningApplication(processIdentifier: bestPID) {
            app.activate()
        }

        // Find the matching AX window and raise it
        for window in AX.windows(ofPID: bestPID) {
            let frame = AX.frame(of: window)
            if abs(frame.origin.x - bestBounds.origin.x) < 5 &&
               abs(frame.origin.y - bestBounds.origin.y) < 5 &&
               abs(frame.width - bestBounds.width) < 5 &&
               abs(frame.height - bestBounds.height) < 5 {
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                break
            }
        }
    }

    // MARK: - Geometry

    private func constrain(_ frame: CGRect, within screen: CGRect) -> CGRect {
        var f = frame
        f.size.width  = min(f.size.width,  screen.width)
        f.size.height = min(f.size.height, screen.height)
        f.origin.x = max(screen.minX, min(f.origin.x, screen.maxX - f.width))
        f.origin.y = max(screen.minY, min(f.origin.y, screen.maxY - f.height))
        return f
    }

    private func snapToEdges(_ frame: CGRect, within screen: CGRect) -> CGRect {
        var f = frame
        let p = screenPadding
        let s = edgeSnap

        if abs(f.minX - screen.minX) < s { f.origin.x = screen.minX + p }
        if abs(f.maxX - screen.maxX) < s { f.origin.x = screen.maxX - f.width - p }
        if abs(f.minY - screen.minY) < s { f.origin.y = screen.minY + p }
        if abs(f.maxY - screen.maxY) < s { f.origin.y = screen.maxY - f.height - p }

        return f
    }

    private func withFocusedWindow(_ action: (WindowRef, CGRect) -> Void) {
        guard let element = AX.focusedWindow(),
              let screen = NSScreen.containing(axWindow: element) else { return }
        action(WindowRef(element), screen.axVisibleFrame)
    }
}
