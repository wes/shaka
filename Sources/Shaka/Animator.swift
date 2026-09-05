import Cocoa

/// Damped-spring animator driving any number of windows at once.
///
/// Flow moves one window at a time, but a Reef re-layout retargets every tile
/// on the screen simultaneously, so each window carries its own spring state and
/// a single shared timer advances them all.
final class Animator {

    private struct Spring {
        var current: CGRect
        var target:  CGRect
        var posVelocity  = CGPoint.zero   // velocity of the origin
        var sizeVelocity = CGPoint.zero   // .x = width velocity, .y = height velocity
    }

    private let stiffness: CGFloat
    private let damping:   CGFloat
    private let restThreshold: CGFloat = 0.5

    private var springs: [WindowRef: Spring] = [:]
    private var timer: DispatchSourceTimer?
    private var tickInterval: Int = 8
    private var lastTick: CFAbsoluteTime = 0

    init(stiffness: CGFloat, damping: CGFloat) {
        self.stiffness = stiffness
        self.damping   = damping
    }

    deinit { stop() }

    // MARK: - Public API

    /// Animate a window toward `target`. Retargets in flight, so rapid key
    /// presses accumulate without restarting the spring.
    func animate(_ window: WindowRef, to target: CGRect) {
        if springs[window] != nil {
            springs[window]!.target = target
        } else {
            springs[window] = Spring(current: window.frame, target: target)
        }
        start()
    }

    /// Retarget an entire layout in one pass. Windows already in flight keep
    /// their velocity; windows no longer in `frames` are left where they are.
    func animate(_ frames: [WindowRef: CGRect]) {
        for (window, target) in frames {
            animate(window, to: target)
        }
    }

    /// The frame an action should be calculated from: the in-flight target if
    /// the window is mid-animation, otherwise its live frame. Keeps repeated
    /// nudges additive instead of snapping back to wherever the spring is now.
    func logicalFrame(of window: WindowRef) -> CGRect {
        springs[window]?.target ?? window.frame
    }

    func cancelAll() {
        springs.removeAll()
        stop()
    }

    // MARK: - Timer

    private func start() {
        // Many windows in flight means many Accessibility round trips per tick,
        // so halve the rate once a re-layout is moving more than a couple.
        let wanted = springs.count > 2 ? 16 : 8

        if timer != nil && wanted == tickInterval { return }

        tickInterval = wanted
        timer?.cancel()

        lastTick = CFAbsoluteTimeGetCurrent()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: .milliseconds(wanted))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    private func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        guard !springs.isEmpty else { stop(); return }

        // Real elapsed time keeps the spring stable when the timer is starved by
        // a slow Accessibility call; the clamp stops a long stall from exploding it.
        let now = CFAbsoluteTimeGetCurrent()
        let dt  = min(CGFloat(now - lastTick), 1.0 / 30.0)
        lastTick = now

        @inline(__always)
        func advance(_ cur: CGFloat, _ tgt: CGFloat, _ vel: inout CGFloat) -> CGFloat {
            vel += (stiffness * (tgt - cur) - damping * vel) * dt
            return cur + vel * dt
        }

        var settled: [WindowRef] = []

        for (window, var spring) in springs {
            spring.current.origin.x    = advance(spring.current.origin.x,    spring.target.origin.x,    &spring.posVelocity.x)
            spring.current.origin.y    = advance(spring.current.origin.y,    spring.target.origin.y,    &spring.posVelocity.y)
            spring.current.size.width  = advance(spring.current.size.width,  spring.target.size.width,  &spring.sizeVelocity.x)
            spring.current.size.height = advance(spring.current.size.height, spring.target.size.height, &spring.sizeVelocity.y)

            let posDelta  = abs(spring.target.origin.x - spring.current.origin.x)
                          + abs(spring.target.origin.y - spring.current.origin.y)
            let sizeDelta = abs(spring.target.size.width  - spring.current.size.width)
                          + abs(spring.target.size.height - spring.current.size.height)
            let velocity  = abs(spring.posVelocity.x)  + abs(spring.posVelocity.y)
                          + abs(spring.sizeVelocity.x) + abs(spring.sizeVelocity.y)

            if posDelta + sizeDelta < restThreshold && velocity < restThreshold {
                AX.setFrameSettled(window.element, spring.target)
                settled.append(window)
            } else {
                window.frame = spring.current
                springs[window] = spring
            }
        }

        for window in settled { springs.removeValue(forKey: window) }

        if springs.isEmpty {
            stop()
        } else if (springs.count > 2 ? 16 : 8) != tickInterval {
            start()   // window count crossed the rate threshold — reschedule
        }
    }
}
