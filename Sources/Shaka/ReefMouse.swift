import Cocoa

/// Mouse gestures for Reef, in two flavours because two habits exist.
///
/// **Modifier drag** is Hyprland's `bindm`: hold the mouse modifier and drag
/// anywhere inside a tile — left button throws the tile around the layout, right
/// button resizes it from the corner nearest the cursor. Shaka swallows those
/// events, so no app ever sees them and no window needs a visible grab handle.
///
/// **Edge drag** is the macOS habit: grab the window's own border and pull. Here
/// Shaka touches nothing and lets the app resize itself, then reads the frame it
/// landed on and folds the difference back into the tree's split ratios. The
/// window keeps its new size because the layout changed to agree with it, and
/// every neighbour reflows to match.
final class ReefMouse {

    struct Settings {
        /// Modifiers that turn a drag into a layout gesture. Empty disables them.
        let modifiers: CGEventFlags
        /// Whether dragging a window's own border reshapes the tiling.
        let edgeDrag: Bool
    }

    private enum Gesture {
        case none
        /// Modifier + right drag: two edges ride along with the cursor.
        case resize(window: WindowRef, horizontal: Edge?, vertical: Edge?, last: CGPoint)
        /// Modifier + left drag: the tile follows the cursor across the layout.
        case shuffle(window: WindowRef)
        /// The app is doing the dragging; Shaka only watches what it does.
        case watch(window: WindowRef, origin: CGRect, reference: CGRect, polled: CFAbsoluteTime)
    }

    private unowned let engine: ReefEngine
    private let settings: Settings
    private var gesture: Gesture = .none

    /// How often a watched window's frame is read mid-drag. Each poll is an
    /// Accessibility round trip, and 25 Hz is already smoother than the eye.
    private let pollInterval: CFAbsoluteTime = 0.04

    /// Ceiling on how often a drag pushes new frames out. A trackpad can emit
    /// well over a hundred events a second, and every one of them would
    /// otherwise mean an Accessibility write per neighbouring window.
    private let paintInterval: CFAbsoluteTime = 0.016
    private var lastPaint: CFAbsoluteTime = 0

    private static let modifierMask: CGEventFlags = [
        .maskControl, .maskShift, .maskCommand, .maskAlternate,
    ]

    init(engine: ReefEngine, config: Settings) {
        self.engine   = engine
        self.settings = config
    }

    // MARK: - Event Entry

    /// Returns true when the event was a layout gesture and must not reach the app.
    func handle(type: CGEventType, at point: CGPoint, flags: CGEventFlags) -> Bool {
        guard engine.isActive else {
            cancel()
            return false
        }

        switch type {
        case .leftMouseDown:
            return begin(rightButton: false, at: point, flags: flags)
        case .rightMouseDown:
            return begin(rightButton: true, at: point, flags: flags)
        case .leftMouseDragged, .rightMouseDragged:
            return drag(to: point)
        case .leftMouseUp, .rightMouseUp:
            return finish(at: point)
        default:
            return false
        }
    }

    func cancel() {
        if case .none = gesture { return }
        gesture = .none
        engine.endMouseDrag()
    }

    // MARK: - Phases

    private func begin(rightButton: Bool, at point: CGPoint, flags: CGEventFlags) -> Bool {
        gesture = .none

        let held = flags.intersection(Self.modifierMask)

        if !settings.modifiers.isEmpty, held == settings.modifiers,
           let (window, rect) = engine.tile(containing: point) {

            // Nothing else may re-tile while a hand is on the layout, but the
            // engine keeps ownership of the frames: these gestures move windows
            // through the tree rather than around it.
            engine.beginMouseDrag()

            if rightButton {
                // Resize from the corner the cursor is nearest, the way you would
                // grab a real window — falling back to the far edge for a tile
                // already flush against that side of the screen.
                gesture = .resize(
                    window:     window,
                    horizontal: engine.resolveEdge(window, point.x > rect.midX ? .right : .left),
                    vertical:   engine.resolveEdge(window, point.y > rect.midY ? .bottom : .top),
                    last:       point
                )
            } else {
                gesture = .shuffle(window: window)
            }
            return true
        }

        guard settings.edgeDrag, !rightButton,
              let (window, rect) = engine.tile(containing: point),
              Self.isGrab(point, in: rect) else { return false }

        // Watch only. The press belongs to the app: it may be a text selection,
        // a button, or the drag we are hoping for, and only the frame it leaves
        // behind can tell the difference. Narrowing it to the border and title
        // bar keeps the polling off every ordinary click inside a window.
        let frame = window.frame
        gesture = .watch(window: window, origin: frame, reference: frame, polled: 0)
        engine.beginMouseDrag()
        return false
    }

    /// Whether a press landed somewhere a window drag plausibly starts: on the
    /// frame, or in the title bar strip along the top.
    private static func isGrab(_ point: CGPoint, in rect: CGRect) -> Bool {
        let border   : CGFloat = 12
        let titleBar : CGFloat = 32

        if !rect.insetBy(dx: border, dy: border).contains(point) { return true }
        return point.y - rect.minY <= titleBar
    }

    private func drag(to point: CGPoint) -> Bool {
        switch gesture {
        case .none:
            return false

        case .resize(let window, let horizontal, let vertical, let last):
            let dx = point.x - last.x
            let dy = point.y - last.y

            if let horizontal { engine.dragEdge(window, horizontal, by: dx) }
            if let vertical   { engine.dragEdge(window, vertical,   by: dy) }

            gesture = .resize(window: window, horizontal: horizontal, vertical: vertical, last: point)
            paint()
            return true

        case .shuffle(let window):
            // Tiles trade places as the cursor crosses them, so the layout is
            // always a valid tiling and the drag needs no drop preview.
            if let other = engine.tile(at: point), other != window {
                engine.swapTiles(window, other)
                engine.refresh()
            }
            return true

        case .watch(let window, let origin, let reference, let polled):
            let now = CFAbsoluteTimeGetCurrent()
            guard now - polled >= pollInterval else { return false }

            let current = window.frame

            // A resize is followed live so the neighbours move with the border.
            // A move is left alone until the button comes up: half-dragged
            // windows are meant to overlap.
            if abs(current.width - reference.width) > 1 || abs(current.height - reference.height) > 1 {
                engine.beginMouseDrag(holding: window)
                fold(window, from: reference, to: current)
                paint()
            }

            gesture = .watch(window: window, origin: origin, reference: current, polled: now)
            return false
        }
    }

    private func finish(at point: CGPoint) -> Bool {
        let ending = gesture
        gesture = .none

        switch ending {
        case .none:
            return false

        case .resize, .shuffle:
            engine.endMouseDrag()
            engine.refresh()
            return true

        case .watch(let window, let origin, let reference, _):
            let current = window.frame
            let resized = abs(current.width  - origin.width)  > 2
                       || abs(current.height - origin.height) > 2
            let moved   = abs(current.minX - origin.minX) > 4
                       || abs(current.minY - origin.minY) > 4

            if resized {
                fold(window, from: reference, to: current)
            } else if moved, let target = engine.tile(at: point), target != window {
                // Dropped onto another tile — the two trade places.
                engine.swapTiles(window, target)
            }

            engine.endMouseDrag()

            // Either way the window goes back to an exact tile frame, so a drag
            // that changed nothing simply snaps home.
            if resized || moved { engine.refresh() }
            return false
        }
    }

    /// Push the layout out to the windows, no more often than the paint ceiling.
    /// Ratios always update; only the Accessibility traffic is rationed, and the
    /// release does one final unthrottled pass.
    private func paint() {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastPaint >= paintInterval else { return }
        lastPaint = now
        engine.refresh(live: true)
    }

    // MARK: - Folding

    /// Translate a frame the app has been dragged into back onto the tree: every
    /// edge that moved moves the split it lies along by the same amount.
    private func fold(_ window: WindowRef, from old: CGRect, to new: CGRect) {
        let deltas: [(Edge, CGFloat)] = [
            (.left,   new.minX - old.minX),
            (.right,  new.maxX - old.maxX),
            (.top,    new.minY - old.minY),
            (.bottom, new.maxY - old.maxY),
        ]

        for (edge, delta) in deltas where abs(delta) > 1 {
            engine.dragEdge(window, edge, by: delta)
        }
    }
}
