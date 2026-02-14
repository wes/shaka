import Cocoa

enum Direction {
    case left, right, up, down
}

class WindowManager {

    // MARK: - Configuration (from ~/.config/shaka/config.json)

    private let moveStep:      CGFloat
    private let resizeStep:    CGFloat
    private let edgeSnap:      CGFloat
    private let screenPadding: CGFloat
    private let minDimension:  CGFloat = 200

    private let stiffness:     CGFloat
    private let damping:       CGFloat
    private let restThreshold: CGFloat = 0.5

    init(config: ShakaConfig) {
        moveStep      = CGFloat(config.moveStep)
        resizeStep    = CGFloat(config.resizeStep)
        edgeSnap      = CGFloat(config.edgeSnap)
        screenPadding = CGFloat(config.screenPadding)
        stiffness     = CGFloat(config.animationStiffness)
        damping       = CGFloat(config.animationDamping)
    }

    // MARK: - Animation State

    private var animationTimer: DispatchSourceTimer?
    private var animatedWindow: AXUIElement?
    private var currentFrame:   CGRect  = .zero
    private var targetFrame:    CGRect  = .zero
    private var posVelocity  = CGPoint.zero   // velocity for origin
    private var sizeVelocity = CGPoint.zero   // .x = width vel, .y = height vel
    private var isAnimating  = false

    // Snap cycle: half → third → two-thirds → half → ...
    private var lastSnapDirection: Direction?
    private var snapCycleIndex: Int = 0
    private let snapFractions: [CGFloat] = [1.0/2, 1.0/3, 2.0/3]

    deinit { stopAnimation() }

    // MARK: - Public Actions

    func move(_ direction: Direction) {
        withFocusedWindow { window, screenFrame in
            var target = self.baseFrame(for: window)

            switch direction {
            case .left:  target.origin.x -= self.moveStep
            case .right: target.origin.x += self.moveStep
            case .up:    target.origin.y -= self.moveStep
            case .down:  target.origin.y += self.moveStep
            }

            target = self.constrain(target, within: screenFrame)
            target = self.snap(target, within: screenFrame)
            self.animateTo(window: window, target: target)
        }
    }

    func resize(_ direction: Direction) {
        withFocusedWindow { window, screenFrame in
            var target = self.baseFrame(for: window)

            // Resize from center so the window stays visually anchored
            switch direction {
            case .right:
                target.size.width  += self.resizeStep
                target.origin.x    -= self.resizeStep / 2
            case .left:
                let delta = min(self.resizeStep, target.size.width - self.minDimension)
                target.size.width  -= delta
                target.origin.x    += delta / 2
            case .up:
                target.size.height += self.resizeStep
                target.origin.y    -= self.resizeStep / 2
            case .down:
                let delta = min(self.resizeStep, target.size.height - self.minDimension)
                target.size.height -= delta
                target.origin.y    += delta / 2
            }

            target = self.constrain(target, within: screenFrame)
            self.animateTo(window: window, target: target)
        }
    }

    func center() {
        withFocusedWindow { window, screenFrame in
            let base = self.baseFrame(for: window)
            var target = base
            target.origin.x = screenFrame.midX - base.width / 2
            target.origin.y = screenFrame.midY - base.height / 2
            self.animateTo(window: window, target: target)
        }
    }

    func smartFill() {
        withFocusedWindow { window, screenFrame in
            let p = self.screenPadding
            let target = CGRect(
                x: screenFrame.minX + p,
                y: screenFrame.minY + p,
                width:  screenFrame.width  - p * 2,
                height: screenFrame.height - p * 2
            )
            self.animateTo(window: window, target: target)
        }
    }

    func snap(_ direction: Direction) {
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
            let target: CGRect

            switch direction {
            case .left:
                let w = self.snapDimension(screenFrame.width, fraction: fraction)
                target = CGRect(
                    x: screenFrame.minX + p,
                    y: screenFrame.minY + p,
                    width: w,
                    height: screenFrame.height - p * 2
                )
            case .right:
                let w = self.snapDimension(screenFrame.width, fraction: fraction)
                target = CGRect(
                    x: screenFrame.maxX - p - w,
                    y: screenFrame.minY + p,
                    width: w,
                    height: screenFrame.height - p * 2
                )
            case .up:
                let h = self.snapDimension(screenFrame.height, fraction: fraction)
                target = CGRect(
                    x: screenFrame.minX + p,
                    y: screenFrame.minY + p,
                    width: screenFrame.width - p * 2,
                    height: h
                )
            case .down:
                let h = self.snapDimension(screenFrame.height, fraction: fraction)
                target = CGRect(
                    x: screenFrame.minX + p,
                    y: screenFrame.maxY - p - h,
                    width: screenFrame.width - p * 2,
                    height: h
                )
            }

            self.animateTo(window: window, target: target)
        }
    }

    /// Calculate a snap dimension (width or height) for a given fraction,
    /// accounting for uniform padding between sections.
    private func snapDimension(_ total: CGFloat, fraction: CGFloat) -> CGFloat {
        return fraction * (total - screenPadding) - screenPadding
    }

    func focusWindow(_ direction: Direction) {
        guard let currentWindow = getFocusedWindow() else { return }
        let currentFrame = getWindowFrame(currentWindow)
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

        // Activate the owning app
        if let app = NSRunningApplication(processIdentifier: bestPID) {
            app.activate()
        }

        // Find the matching AX window and raise it
        let appElement = AXUIElementCreateApplication(bestPID)
        var windowsRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXWindowsAttribute as CFString, &windowsRef
        ) == .success, let windows = windowsRef as? [AXUIElement] else { return }

        for window in windows {
            let frame = getWindowFrame(window)
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

    // MARK: - Animation Engine

    /// Returns the "logical" frame to calculate the next action from.
    /// If we're mid-animation on the same window, use the in-flight target
    /// so rapid key presses accumulate correctly.
    private func baseFrame(for window: AXUIElement) -> CGRect {
        if isAnimating, let aw = animatedWindow, CFEqual(aw, window) {
            return targetFrame
        }
        return getWindowFrame(window)
    }

    private func animateTo(window: AXUIElement, target: CGRect) {
        let isSameWindow = isAnimating
            && animatedWindow.map { CFEqual($0, window) } ?? false

        if isSameWindow {
            // Retarget — spring naturally adjusts from current position
            targetFrame = target
            return
        }

        stopAnimation()

        animatedWindow = window
        currentFrame   = getWindowFrame(window)
        targetFrame    = target
        posVelocity    = .zero
        sizeVelocity   = .zero
        isAnimating    = true

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(8)) // ~120 fps
        timer.setEventHandler { [weak self] in self?.tick() }
        animationTimer = timer
        timer.resume()
    }

    private func tick() {
        guard let window = animatedWindow else { stopAnimation(); return }

        let dt: CGFloat = 1.0 / 120.0

        // Damped spring: a = k·(target − current) − c·velocity
        @inline(__always)
        func spring(_ cur: CGFloat, _ tgt: CGFloat, _ vel: inout CGFloat) -> CGFloat {
            vel += (stiffness * (tgt - cur) - damping * vel) * dt
            return cur + vel * dt
        }

        currentFrame.origin.x    = spring(currentFrame.origin.x,    targetFrame.origin.x,    &posVelocity.x)
        currentFrame.origin.y    = spring(currentFrame.origin.y,    targetFrame.origin.y,    &posVelocity.y)
        currentFrame.size.width  = spring(currentFrame.size.width,  targetFrame.size.width,  &sizeVelocity.x)
        currentFrame.size.height = spring(currentFrame.size.height, targetFrame.size.height, &sizeVelocity.y)

        setWindowFrame(window, frame: currentFrame)

        // Settled?
        let posDelta  = abs(targetFrame.origin.x - currentFrame.origin.x)
                      + abs(targetFrame.origin.y - currentFrame.origin.y)
        let sizeDelta = abs(targetFrame.size.width  - currentFrame.size.width)
                      + abs(targetFrame.size.height - currentFrame.size.height)
        let vel       = abs(posVelocity.x) + abs(posVelocity.y)
                      + abs(sizeVelocity.x) + abs(sizeVelocity.y)

        if posDelta + sizeDelta < restThreshold && vel < restThreshold {
            setWindowFrame(window, frame: targetFrame)
            stopAnimation()
        }
    }

    private func stopAnimation() {
        animationTimer?.cancel()
        animationTimer = nil
        animatedWindow = nil
        isAnimating    = false
    }

    // MARK: - Screen Geometry

    /// Converts NSScreen's Cocoa coordinate frame (origin bottom-left) to
    /// Accessibility API coordinates (origin top-left of primary display).
    private func axScreenFrame(_ screen: NSScreen) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let vf = screen.visibleFrame
        return CGRect(
            x:      vf.origin.x,
            y:      primaryHeight - vf.origin.y - vf.height,
            width:  vf.width,
            height: vf.height
        )
    }

    private func constrain(_ frame: CGRect, within screen: CGRect) -> CGRect {
        var f = frame
        f.size.width  = min(f.size.width,  screen.width)
        f.size.height = min(f.size.height, screen.height)
        f.origin.x = max(screen.minX, min(f.origin.x, screen.maxX - f.width))
        f.origin.y = max(screen.minY, min(f.origin.y, screen.maxY - f.height))
        return f
    }

    private func snap(_ frame: CGRect, within screen: CGRect) -> CGRect {
        var f = frame
        let p = screenPadding
        let s = edgeSnap

        if abs(f.minX - screen.minX) < s { f.origin.x = screen.minX + p }
        if abs(f.maxX - screen.maxX) < s { f.origin.x = screen.maxX - f.width - p }
        if abs(f.minY - screen.minY) < s { f.origin.y = screen.minY + p }
        if abs(f.maxY - screen.maxY) < s { f.origin.y = screen.maxY - f.height - p }

        return f
    }

    // MARK: - Accessibility Helpers

    private func withFocusedWindow(_ action: (AXUIElement, CGRect) -> Void) {
        guard let window = getFocusedWindow(),
              let screen = screenForWindow(window) else { return }
        let screenFrame = axScreenFrame(screen)
        action(window, screenFrame)
    }

    private func getFocusedWindow() -> AXUIElement? {
        // Use NSWorkspace to find the frontmost app — more reliable than the
        // AX system-wide element, which fails with some apps (e.g. Chrome).
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }

        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)

        // 1. Try focused window (works for most apps)
        var winRef: AnyObject?
        if AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &winRef
        ) == .success, let win = winRef {
            return (win as! AXUIElement)
        }

        // 2. Fallback: main window (Chrome often only exposes this)
        if AXUIElementCopyAttributeValue(
            appElement, kAXMainWindowAttribute as CFString, &winRef
        ) == .success, let win = winRef {
            return (win as! AXUIElement)
        }

        // 3. Fallback: first from the windows list
        var windowsRef: AnyObject?
        if AXUIElementCopyAttributeValue(
            appElement, kAXWindowsAttribute as CFString, &windowsRef
        ) == .success,
           let windows = windowsRef as? [AXUIElement],
           let first = windows.first {
            return first
        }

        return nil
    }

    private func getWindowFrame(_ window: AXUIElement) -> CGRect {
        var position = CGPoint.zero
        var size     = CGSize.zero

        var posRef: AnyObject?
        if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
           let val = posRef {
            AXValueGetValue(val as! AXValue, .cgPoint, &position)
        }

        var sizeRef: AnyObject?
        if AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
           let val = sizeRef {
            AXValueGetValue(val as! AXValue, .cgSize, &size)
        }

        return CGRect(origin: position, size: size)
    }

    private func setWindowFrame(_ window: AXUIElement, frame: CGRect) {
        var pos  = frame.origin
        var size = frame.size

        if let v = AXValueCreate(.cgPoint, &pos) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, v)
        }
        if let v = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, v)
        }
    }

    private func screenForWindow(_ window: AXUIElement) -> NSScreen? {
        let frame = getWindowFrame(window)
        let center = CGPoint(x: frame.midX, y: frame.midY)

        // Convert AX coordinates (top-left origin) → Cocoa (bottom-left origin)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cocoaCenter = CGPoint(x: center.x, y: primaryHeight - center.y)

        return NSScreen.screens.first { $0.frame.contains(cocoaCenter) } ?? NSScreen.main
    }
}
