import Cocoa

/// How a window on an inactive workspace is put out of sight.
enum ParkStyle: String {
    /// Slide it below every display. Instant and reversible, and it keeps the
    /// window's shape, so returning to the workspace springs it back up into
    /// its tile instead of teleporting it there.
    case offscreen
    /// Minimise it to the Dock. Slower and noisier, but it survives apps that
    /// refuse to be positioned outside the visible frame.
    case minimize
}

extension Notification.Name {
    static let shakaWorkspaceChanged = Notification.Name("shakaWorkspaceChanged")
}

/// One display's stack of workspaces. Each workspace is a full dwindle tree, so
/// switching is just a matter of which one gets the screen.
final class ReefDisplay {
    let displayID: CGDirectDisplayID
    let workspaces: [ReefLayout]

    private(set) var active   = 0
    /// The workspace before this one, so a single key can bounce between two.
    private(set) var previous = 0

    init(displayID: CGDirectDisplayID, count: Int, configure: (ReefLayout) -> Void) {
        self.displayID  = displayID
        self.workspaces = (0..<max(1, count)).map { _ in
            let layout = ReefLayout()
            configure(layout)
            return layout
        }
    }

    /// The workspace currently on screen.
    var layout: ReefLayout { workspaces[active] }

    func activate(_ index: Int) {
        guard workspaces.indices.contains(index), index != active else { return }
        previous = active
        active   = index
    }

    func step(_ delta: Int) -> Int {
        (active + delta + workspaces.count) % workspaces.count
    }
}

/// A workspace as the menu bar sees it.
struct WorkspaceSummary {
    let number: Int
    let windows: Int
    let isActive: Bool
}

/// Reef mode: a Hyprland-style dwindle tiler laid over macOS.
///
/// Entering takes every tileable window on every screen, records where it was,
/// and packs it into a binary tree that fills the screen with no overlap.
/// Leaving puts every window back exactly where it was found.
final class ReefEngine {

    private let animator: Animator
    private let tracker = WindowTracker()

    private var displays: [CGDirectDisplayID: ReefDisplay] = [:]

    /// Where each window sat before Reef mode claimed it, so exiting is lossless.
    private var savedFrames: [WindowRef: CGRect] = [:]

    /// Geometry for windows floated out of the tiling. Unlike tiles, nothing
    /// recomputes their frames, so parking one has to remember where it was.
    private var floatFrames: [WindowRef: CGRect] = [:]

    /// Windows currently hidden because their workspace is not on screen.
    private var parked: Set<WindowRef> = []

    /// The window under a live mouse drag. It keeps whatever frame the user's
    /// hand gives it; every layout pass leaves it alone until they let go.
    private var mouseHeld: WindowRef?

    /// Set for the whole of a mouse gesture, so nothing re-tiles mid-drag.
    private var gestureActive = false

    /// Focus as it stood when a workspace switch moved the screen out from under
    /// it, so following focus across workspaces cannot bounce straight back.
    private var focusAtSwitch: WindowRef?

    private let gapsIn:  CGFloat
    private let gapsOut: CGFloat
    private let minTile: CGFloat
    private let resizeStep: CGFloat
    private let workspaceCount: Int
    private let parkStyle: ParkStyle

    private(set) lazy var mouse = ReefMouse(engine: self, config: mouseConfig)
    private let mouseConfig: ReefMouse.Settings

    private(set) var isActive = false

    init(config: ShakaConfig, animator: Animator) {
        self.animator       = animator
        self.gapsIn         = CGFloat(config.gapsIn)
        self.gapsOut        = CGFloat(config.gapsOut)
        self.minTile        = CGFloat(config.minTileSize)
        self.resizeStep     = CGFloat(config.resizeStep)
        self.workspaceCount = config.workspaceCount
        self.parkStyle      = config.parkStyle
        self.mouseConfig    = ReefMouse.Settings(
            modifiers: config.mouseModifiers,
            edgeDrag:  config.mouseEdgeDrag
        )

        tracker.onChange = { [weak self] in self?.reconcile() }
    }

    deinit { tracker.stop() }

    // MARK: - Mode Lifecycle

    func activate() {
        guard !isActive else { return }
        isActive = true

        savedFrames.removeAll()
        floatFrames.removeAll()
        parked.removeAll()
        displays.removeAll()

        tracker.start()

        for window in tracker.manageableWindows() {
            savedFrames[window] = window.frame

            guard let screen = screen(of: window) else { continue }
            display(for: screen).layout.insert(window, splitting: nil)
        }

        apply()
        print("[shaka] reef: tiling \(savedFrames.count) window(s)")
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false

        tracker.stop()
        mouse.cancel()

        // Anything hidden has to come back before it can be handed over.
        for window in parked where parkStyle == .minimize {
            AX.setMinimized(window.element, false)
        }
        parked.removeAll()

        // Put every window back where Reef found it. Entries for windows that
        // have since closed just fail their Accessibility call harmlessly.
        for (window, frame) in savedFrames {
            animator.animate(window, to: frame)
        }

        displays.removeAll()
        floatFrames.removeAll()
        savedFrames.removeAll()
    }

    /// True when the focused window is tiled and on screen, i.e. Reef should
    /// handle the action rather than falling through to Flow.
    func handlesFocusedWindow() -> Bool {
        guard isActive, let focused = focusedWindow() else { return false }
        return visibleLayout(containing: focused) != nil
    }

    // MARK: - Actions

    func focus(_ direction: Direction) {
        guard let current = focusedWindow(), let layout = visibleLayout(containing: current) else {
            focusAnyTile()
            return
        }

        if let neighbor = layout.neighbor(of: current, direction: direction) {
            AX.focus(neighbor.element)
        } else if let target = adjacentScreen(to: screen(of: current), direction: direction),
                  let entry = displays[target.displayID]?.layout.windows.first {
            // Ran out of tiles — continue onto the next display.
            AX.focus(entry.element)
        }
    }

    /// Hyprland's `movewindow`: exchange the focused tile with its neighbour.
    func moveWindow(_ direction: Direction) {
        guard let current = focusedWindow(), let layout = visibleLayout(containing: current) else { return }

        if let neighbor = layout.neighbor(of: current, direction: direction) {
            layout.swap(current, neighbor)
            apply()
        } else {
            moveToAdjacentScreen(current, direction: direction)
        }
    }

    /// Hyprland's `resizeactive`: nudge the split this tile hangs off.
    func resize(_ direction: Direction) {
        guard let current = focusedWindow(), let layout = visibleLayout(containing: current) else { return }

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
        guard let current = focusedWindow(), let layout = visibleLayout(containing: current) else { return }
        layout.promoteToMaster(current)
        apply()
    }

    func toggleFullscreen() {
        guard let current = focusedWindow(), let layout = visibleLayout(containing: current) else { return }
        layout.fullscreen = (layout.fullscreen == current) ? nil : current
        apply()
        if layout.fullscreen != nil { AX.focus(current.element) }
    }

    func toggleSplit() {
        guard let current = focusedWindow(), let layout = visibleLayout(containing: current) else { return }
        layout.toggleSplit(current)
        apply()
    }

    func toggleFloat() {
        guard let current = focusedWindow(), let (display, index) = location(of: current) else { return }
        let layout = display.workspaces[index]

        if layout.floaters.remove(current) != nil {
            floatFrames[current] = nil
            layout.insert(current, splitting: nil)
        } else {
            layout.remove(current)
            layout.floaters.insert(current)

            // Float back to a comfortable size rather than the tile it just left.
            let area = screen(of: display)?.axVisibleFrame ?? layout.area
            let size = CGSize(width: area.width * 0.6, height: area.height * 0.6)
            floatFrames[current] = CGRect(
                x: area.midX - size.width / 2,
                y: area.midY - size.height / 2,
                width: size.width, height: size.height
            )
        }
        apply()
    }

    func cycleFocus(reverse: Bool = false) {
        let current = focusedWindow()
        let layout = current.flatMap(visibleLayout(containing:)) ?? activeDisplay()?.layout
        guard let layout, let next = layout.cycle(from: current, reverse: reverse) else { return }
        AX.focus(next.element)
    }

    /// Hyprland's `movewindow mon:<dir>` — hand the focused tile to the next display.
    func moveToDisplay(_ direction: Direction) {
        guard let current = focusedWindow() else { return }
        moveToAdjacentScreen(current, direction: direction)
    }

    // MARK: - Workspaces

    var activeWorkspaceNumber: Int { (activeDisplay()?.active ?? 0) + 1 }

    /// Every workspace on the focused display, for the menu bar.
    func workspaceOverview() -> [WorkspaceSummary] {
        guard let display = activeDisplay() else { return [] }
        return display.workspaces.enumerated().map { index, layout in
            WorkspaceSummary(
                number: index + 1,
                windows: layout.members.count,
                isActive: index == display.active
            )
        }
    }

    /// Bring workspace `number` (1-based) to the front of the focused display.
    func showWorkspace(_ number: Int) {
        guard isActive, let display = activeDisplay() else { return }
        switchTo(display, index: number - 1)
    }

    func stepWorkspace(_ delta: Int) {
        guard isActive, let display = activeDisplay() else { return }
        switchTo(display, index: display.step(delta))
    }

    /// Hyprland's `workspace previous`: bounce back to the one you came from.
    func showRecentWorkspace() {
        guard isActive, let display = activeDisplay() else { return }
        switchTo(display, index: display.previous)
    }

    /// Send the focused window to workspace `number` on its own display.
    ///
    /// Focus deliberately stays put: sending a window away is usually about
    /// clearing the desk, not following it out of the room.
    func sendFocusedToWorkspace(_ number: Int) {
        guard isActive,
              let window = focusedWindow(),
              let (display, from) = location(of: window) else { return }

        let to = number - 1
        guard display.workspaces.indices.contains(to), to != from else { return }

        // Focus is about to be left on a window that is no longer on screen.
        // Record it, so reconciliation does not read that as "follow me back".
        focusAtSwitch = window

        let source = display.workspaces[from]
        let wasFloating = source.floaters.contains(window)
        source.remove(window)

        let destination = display.workspaces[to]
        if wasFloating {
            destination.floaters.insert(window)
        } else {
            destination.insert(window, splitting: nil)
        }

        apply()
        focusFirstTile(on: display)
        announceWorkspace()
    }

    private func switchTo(_ display: ReefDisplay, index: Int) {
        guard display.workspaces.indices.contains(index), index != display.active else { return }

        display.activate(index)
        focusAtSwitch = focusedWindow()

        apply()
        focusFirstTile(on: display)
        announceWorkspace()

        print("[shaka] reef: workspace \(index + 1)")
    }

    private func focusFirstTile(on display: ReefDisplay) {
        let layout = display.layout
        guard let first = layout.windows.first ?? layout.floaters.first else { return }
        AX.focus(first.element)
        focusAtSwitch = nil
    }

    private func announceWorkspace() {
        NotificationCenter.default.post(name: .shakaWorkspaceChanged, object: self)
    }

    // MARK: - Parking

    /// Just below the lowest display, so a parked window is off every screen
    /// but still close enough to slide back in from.
    private var parkY: CGFloat {
        (NSScreen.screens.map { $0.axVisibleFrame.maxY }.max() ?? 900) + 120
    }

    private func park(_ window: WindowRef) {
        parked.insert(window)
        animator.cancel(window)

        switch parkStyle {
        case .minimize:
            AX.setMinimized(window.element, true)
        case .offscreen:
            let frame = window.frame
            // A floater's position is its own; remember it before it disappears.
            if floatFrames[window] != nil { floatFrames[window] = frame }
            window.frame = CGRect(x: frame.minX, y: parkY, width: frame.width, height: frame.height)
        }
    }

    private func unpark(_ window: WindowRef) {
        parked.remove(window)
        if parkStyle == .minimize { AX.setMinimized(window.element, false) }
    }

    // MARK: - Reconciliation

    /// Diff the tree against the live window list. Windows that closed leave their
    /// tiles; windows that opened split whichever tile has focus, which is what
    /// makes dwindle feel predictable.
    private func reconcile() {
        guard isActive else { return }
        // Never re-tile out from under a hand that is mid-drag.
        guard !gestureActive else { return }

        let live = tracker.manageableWindows()
        let liveSet = Set(live)

        var dirty = false

        for display in displays.values {
            for layout in display.workspaces {
                for window in layout.members {
                    // Parked windows are out of the normal scan, so closing one
                    // has to be detected by asking the window itself.
                    if parked.contains(window) {
                        if AX.isAlive(window.element) { continue }
                        parked.remove(window)
                    } else if liveSet.contains(window) {
                        continue
                    }

                    layout.remove(window)
                    floatFrames[window] = nil
                    dirty = true
                }
            }
        }

        let focused = focusedWindow()
        if let focused, focused != focusAtSwitch { focusAtSwitch = nil }

        // Cmd-Tab can land on a window sitting on a workspace that is not
        // showing. Follow it, rather than leaving the screen unchanged.
        if let focused, focusAtSwitch == nil, parked.contains(focused),
           let (display, index) = location(of: focused), index != display.active {
            display.activate(index)
            dirty = true
            announceWorkspace()
        }

        // One membership set beats asking every workspace about every window.
        let known = Set(displays.values.flatMap { $0.workspaces.flatMap(\.members) })

        for window in live where !known.contains(window) {
            guard let screen = screen(of: window) else { continue }

            // Only on first sight: a minimised window comes back through here,
            // and its pre-Reef frame is the one worth restoring.
            if savedFrames[window] == nil { savedFrames[window] = window.frame }

            let layout = display(for: screen).layout
            let host = focused.flatMap { layout.contains($0) ? $0 : nil }
            layout.insert(window, splitting: host)
            dirty = true
        }

        if dirty { apply() }
    }

    // MARK: - Layout Plumbing

    private func display(for screen: NSScreen) -> ReefDisplay {
        if let existing = displays[screen.displayID] { return existing }

        let area = screen.axVisibleFrame
        let created = ReefDisplay(displayID: screen.displayID, count: workspaceCount) { layout in
            layout.gapsIn  = gapsIn
            layout.gapsOut = gapsOut
            layout.minTile = minTile
            layout.area    = area
        }
        displays[screen.displayID] = created
        return created
    }

    /// The on-screen layout holding this window, or nil if it is parked, floated
    /// or not Reef's at all.
    private func visibleLayout(containing window: WindowRef) -> ReefLayout? {
        displays.values.map(\.layout).first { $0.contains(window) }
    }

    /// Which display and workspace a window belongs to, showing or not.
    private func location(of window: WindowRef) -> (display: ReefDisplay, index: Int)? {
        for display in displays.values {
            if let index = display.workspaces.firstIndex(where: { $0.owns(window) }) {
                return (display, index)
            }
        }
        return nil
    }

    /// The display the user is working on: whichever holds focus, else the one
    /// with the menu bar.
    private func activeDisplay() -> ReefDisplay? {
        if let focused = focusedWindow(), let (display, _) = location(of: focused) { return display }
        if let screen = NSScreen.main { return display(for: screen) }
        return displays.values.first
    }

    private func screen(of display: ReefDisplay) -> NSScreen? {
        NSScreen.screens.first { $0.displayID == display.displayID }
    }

    /// Push the current tree out to the windows.
    ///
    /// One pass covers every display: the showing workspace gets tile frames,
    /// every other workspace gets parked. `live` skips the spring, for drags
    /// where the user's hand is already providing the motion.
    private func apply(live: Bool = false) {
        var targets: [WindowRef: CGRect] = [:]
        var hidden: [WindowRef] = []

        for screen in NSScreen.screens {
            guard let display = displays[screen.displayID] else { continue }
            let area = screen.axVisibleFrame

            for (index, layout) in display.workspaces.enumerated() {
                layout.area = area

                guard index == display.active else {
                    hidden.append(contentsOf: layout.members)
                    continue
                }

                for (window, frame) in layout.frames(in: area) { targets[window] = frame }
                for floater in layout.floaters {
                    if let frame = floatFrames[floater] { targets[floater] = frame }
                }
            }
        }

        for window in hidden where !parked.contains(window) { park(window) }
        for window in targets.keys where parked.contains(window) { unpark(window) }

        // The window under the user's hand keeps the frame the drag gave it;
        // only its neighbours reflow around it.
        if let mouseHeld { targets[mouseHeld] = nil }

        if live {
            animator.set(targets)
        } else {
            animator.animate(targets)
        }
    }

    private func focusedWindow() -> WindowRef? {
        AX.focusedWindow().map(WindowRef.init)
    }

    private func screen(of window: WindowRef) -> NSScreen? {
        // Prefer the animator's target: mid-flight a window can straddle displays.
        let frame = animator.logicalFrame(of: window)
        return NSScreen.containing(axPoint: CGPoint(x: frame.midX, y: frame.midY))
    }

    /// Focus is somewhere untiled — pull it back onto the grid.
    private func focusAnyTile() {
        guard let layout = activeDisplay()?.layout, let first = layout.windows.first else { return }
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

        location(of: window)?.display.workspaces.forEach { $0.remove(window) }
        floatFrames[window] = nil

        let destination = display(for: target).layout
        destination.insert(window, splitting: nil)

        apply()
        AX.focus(window.element)
    }
}

// MARK: - Mouse Support

/// The narrow surface `ReefMouse` drives. Everything here works in
/// Accessibility coordinates, which is what a `CGEvent` location already is.
extension ReefEngine {

    /// The tile under a point, or the nearest one when the point lands in a gap.
    /// Used to pick a drop target, where "closest" is the useful answer.
    func tile(at point: CGPoint) -> WindowRef? {
        guard isActive,
              let screen = NSScreen.containing(axPoint: point),
              let display = displays[screen.displayID] else { return nil }
        return display.layout.window(at: point)
    }

    /// The tile a point actually falls inside. Used to start a gesture, where
    /// grabbing the nearest tile to an empty patch of desktop would be wrong.
    func tile(containing point: CGPoint) -> (window: WindowRef, rect: CGRect)? {
        guard let window = tile(at: point), let rect = tileRect(of: window),
              rect.contains(point) else { return nil }
        return (window, rect)
    }

    /// The tile rect a window is assigned right now, gaps included.
    func tileRect(of window: WindowRef) -> CGRect? {
        visibleLayout(containing: window)?.rect(of: window)
    }

    func isTiled(_ window: WindowRef) -> Bool {
        visibleLayout(containing: window) != nil
    }

    /// Mark a gesture as running, so reconciliation holds off until it ends.
    ///
    /// Passing a window additionally hands that window over: layout passes stop
    /// moving it and its spring is dropped, so nothing fights a drag the app
    /// itself is performing.
    func beginMouseDrag(holding window: WindowRef? = nil) {
        gestureActive = true
        if let window {
            mouseHeld = window
            animator.cancel(window)
        }
    }

    func endMouseDrag() {
        gestureActive = false
        mouseHeld = nil
    }

    /// The edge a resize should actually act on: the one asked for, or its
    /// opposite when the tile is already flush against that side of the screen.
    func resolveEdge(_ window: WindowRef, _ edge: Edge) -> Edge? {
        guard let layout = visibleLayout(containing: window) else { return nil }
        if layout.hasBoundary(window, on: edge) { return edge }
        if layout.hasBoundary(window, on: edge.opposite) { return edge.opposite }
        return nil
    }

    /// Drag one edge of a tile, reflowing everything that shares that split.
    @discardableResult
    func dragEdge(_ window: WindowRef, _ edge: Edge, by delta: CGFloat) -> Bool {
        guard let layout = visibleLayout(containing: window) else { return false }
        return layout.resizeEdge(window, edge, by: delta)
    }

    func swapTiles(_ a: WindowRef, _ b: WindowRef) {
        guard let layout = visibleLayout(containing: a), layout.contains(b) else { return }
        layout.swap(a, b)
    }

    /// Push the layout back out to the windows after a mouse gesture changed it.
    func refresh(live: Bool = false) {
        apply(live: live)
    }
}
