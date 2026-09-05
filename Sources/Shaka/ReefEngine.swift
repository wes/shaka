import Cocoa

/// Reef mode: a Hyprland-style dwindle tiler laid over macOS.
///
/// Entering takes every tileable window on every screen, records where it was,
/// and packs it into a binary tree that fills the screen with no overlap.
/// Leaving puts every window back exactly where it was found.
final class ReefEngine {

    private let animator: Animator
    private let tracker = WindowTracker()

    private var layouts: [CGDirectDisplayID: ReefLayout] = [:]

    /// Where each window sat before Reef mode claimed it, so exiting is lossless.
    private var savedFrames: [WindowRef: CGRect] = [:]

    /// Windows excluded from tiling by `toggle_float`. They keep Flow behaviour.
    private var floating: Set<WindowRef> = []

    private let gapsIn:  CGFloat
    private let gapsOut: CGFloat
    private let resizeStep: CGFloat

    private(set) var isActive = false

    init(config: ShakaConfig, animator: Animator) {
        self.animator   = animator
        self.gapsIn     = CGFloat(config.gapsIn)
        self.gapsOut    = CGFloat(config.gapsOut)
        self.resizeStep = CGFloat(config.resizeStep)

        tracker.onChange = { [weak self] in self?.reconcile() }
    }

    deinit { tracker.stop() }

    // MARK: - Mode Lifecycle

    func activate() {
        guard !isActive else { return }
        isActive = true

        savedFrames.removeAll()
        floating.removeAll()
        layouts.removeAll()

        tracker.start()

        for window in tracker.manageableWindows() {
            savedFrames[window] = window.frame

            guard let screen = screen(of: window) else { continue }
            layout(for: screen).insert(window, splitting: nil)
        }

        apply()
        print("[shaka] reef: tiling \(savedFrames.count) window(s)")
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false

        tracker.stop()

        // Put every window back where Reef found it. Entries for windows that
        // have since closed just fail their Accessibility call harmlessly.
        for (window, frame) in savedFrames {
            animator.animate(window, to: frame)
        }

        layouts.removeAll()
        floating.removeAll()
        savedFrames.removeAll()
    }

    /// True when the focused window is tiled, i.e. Reef should handle the action
    /// rather than falling through to Flow.
    func handlesFocusedWindow() -> Bool {
        guard isActive, let focused = focusedWindow() else { return false }
        return !floating.contains(focused) && layoutContaining(focused) != nil
    }

    // MARK: - Actions

    func focus(_ direction: Direction) {
        guard let current = focusedWindow(), let layout = layoutContaining(current) else {
            focusAnyTile()
            return
        }

        if let neighbor = layout.neighbor(of: current, direction: direction) {
            AX.focus(neighbor.element)
        } else if let target = adjacentScreen(to: screen(of: current), direction: direction),
                  let entry = layouts[target.displayID]?.windows.first {
            // Ran out of tiles — continue onto the next display.
            AX.focus(entry.element)
        }
    }

    /// Hyprland's `movewindow`: exchange the focused tile with its neighbour.
    func moveWindow(_ direction: Direction) {
        guard let current = focusedWindow(), let layout = layoutContaining(current) else { return }

        if let neighbor = layout.neighbor(of: current, direction: direction) {
            layout.swap(current, neighbor)
            apply()
        } else {
            moveToAdjacentScreen(current, direction: direction)
        }
    }

    /// Hyprland's `resizeactive`: nudge the split this tile hangs off.
    func resize(_ direction: Direction) {
        guard let current = focusedWindow(), let layout = layoutContaining(current) else { return }

        switch direction {
        case .right: layout.resize(current, orientation: .horizontal, grow: true,  step: resizeStep)
        case .left:  layout.resize(current, orientation: .horizontal, grow: false, step: resizeStep)
        case .up:    layout.resize(current, orientation: .vertical,   grow: true,  step: resizeStep)
        case .down:  layout.resize(current, orientation: .vertical,   grow: false, step: resizeStep)
        }
        apply()
    }

    /// Swap the focused tile into the master slot — the Reef reading of Flow's
    /// "center window", since a tiled window is already where it belongs.
    func promoteToMaster() {
        guard let current = focusedWindow(), let layout = layoutContaining(current) else { return }
        layout.promoteToMaster(current)
        apply()
    }

    func toggleFullscreen() {
        guard let current = focusedWindow(), let layout = layoutContaining(current) else { return }
        layout.fullscreen = (layout.fullscreen == current) ? nil : current
        apply()
        if layout.fullscreen != nil { AX.focus(current.element) }
    }

    func toggleSplit() {
        guard let current = focusedWindow(), let layout = layoutContaining(current) else { return }
        layout.toggleSplit(current)
        apply()
    }

    func toggleFloat() {
        guard let current = focusedWindow() else { return }

        if floating.remove(current) != nil {
            guard let screen = screen(of: current) else { return }
            layout(for: screen).insert(current, splitting: focusedTile(on: screen))
        } else {
            guard let layout = layoutContaining(current) else { return }
            layout.remove(current)
            floating.insert(current)

            // Float back to a comfortable size rather than the tile it just left.
            if let screen = screen(of: current) {
                let area = screen.axVisibleFrame
                let size = CGSize(width: area.width * 0.6, height: area.height * 0.6)
                animator.animate(current, to: CGRect(
                    x: area.midX - size.width / 2,
                    y: area.midY - size.height / 2,
                    width: size.width, height: size.height
                ))
            }
        }
        apply()
    }

    func cycleFocus(reverse: Bool = false) {
        let current = focusedWindow()
        let layout = current.flatMap(layoutContaining) ?? activeLayout()
        guard let layout, let next = layout.cycle(from: current, reverse: reverse) else { return }
        AX.focus(next.element)
    }

    /// Hyprland's `movewindow mon:<dir>` — hand the focused tile to the next display.
    func moveToDisplay(_ direction: Direction) {
        guard let current = focusedWindow() else { return }
        moveToAdjacentScreen(current, direction: direction)
    }

    // MARK: - Reconciliation

    /// Diff the tree against the live window list. Windows that closed leave their
    /// tiles; windows that opened split whichever tile has focus, which is what
    /// makes dwindle feel predictable.
    private func reconcile() {
        guard isActive else { return }

        let live = tracker.manageableWindows()
        let liveSet = Set(live)

        var removedAny = false
        for layout in layouts.values {
            for window in layout.windows where !liveSet.contains(window) {
                layout.remove(window)
                removedAny = true
            }
        }
        floating = floating.intersection(liveSet)

        let focused = focusedWindow()
        var addedAny = false

        for window in live where !floating.contains(window) {
            guard layoutContaining(window) == nil, let screen = screen(of: window) else { continue }

            // Only on first sight: a minimised window comes back through here,
            // and its pre-Reef frame is the one worth restoring.
            if savedFrames[window] == nil { savedFrames[window] = window.frame }

            let target = layout(for: screen)
            let host = focused.flatMap { target.contains($0) ? $0 : nil }
            target.insert(window, splitting: host)
            addedAny = true
        }

        if removedAny || addedAny { apply() }
    }

    // MARK: - Layout Plumbing

    private func layout(for screen: NSScreen) -> ReefLayout {
        if let existing = layouts[screen.displayID] { return existing }

        let created = ReefLayout()
        created.gapsIn  = gapsIn
        created.gapsOut = gapsOut
        created.area    = screen.axVisibleFrame
        layouts[screen.displayID] = created
        return created
    }

    private func layoutContaining(_ window: WindowRef) -> ReefLayout? {
        layouts.values.first { $0.contains(window) }
    }

    private func activeLayout() -> ReefLayout? {
        guard let screen = NSScreen.main else { return layouts.values.first }
        return layouts[screen.displayID] ?? layouts.values.first
    }

    private func apply() {
        for screen in NSScreen.screens {
            guard let layout = layouts[screen.displayID] else { continue }
            animator.animate(layout.frames(in: screen.axVisibleFrame))
        }
    }

    private func focusedWindow() -> WindowRef? {
        AX.focusedWindow().map(WindowRef.init)
    }

    private func focusedTile(on screen: NSScreen) -> WindowRef? {
        guard let focused = focusedWindow(),
              layouts[screen.displayID]?.contains(focused) == true else { return nil }
        return focused
    }

    private func screen(of window: WindowRef) -> NSScreen? {
        // Prefer the animator's target: mid-flight a window can straddle displays.
        let frame = animator.logicalFrame(of: window)
        return NSScreen.containing(axPoint: CGPoint(x: frame.midX, y: frame.midY))
    }

    /// Focus is somewhere untiled — pull it back onto the grid.
    private func focusAnyTile() {
        guard let layout = activeLayout(), let first = layout.windows.first else { return }
        AX.focus(first.element)
    }

    // MARK: - Displays

    /// The next screen in a direction, compared in Accessibility coordinates
    /// (y grows downward, so `.up` means a smaller y).
    private func adjacentScreen(to origin: NSScreen?, direction: Direction) -> NSScreen? {
        guard let origin else { return nil }
        let from = origin.axVisibleFrame

        var best: NSScreen?
        var bestDistance = CGFloat.infinity

        for screen in NSScreen.screens where screen.displayID != origin.displayID {
            let to = screen.axVisibleFrame
            let dx = to.midX - from.midX
            let dy = to.midY - from.midY

            switch direction {
            case .left:  guard dx < -1 else { continue }
            case .right: guard dx >  1 else { continue }
            case .up:    guard dy < -1 else { continue }
            case .down:  guard dy >  1 else { continue }
            }

            let distance = dx * dx + dy * dy
            if distance < bestDistance {
                bestDistance = distance
                best = screen
            }
        }

        return best
    }

    private func moveToAdjacentScreen(_ window: WindowRef, direction: Direction) {
        guard let target = adjacentScreen(to: screen(of: window), direction: direction) else { return }

        layoutContaining(window)?.remove(window)

        let destination = layout(for: target)
        destination.insert(window, splitting: focusedTile(on: target))

        apply()
        AX.focus(window.element)
    }
}
