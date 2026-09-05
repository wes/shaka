import Cocoa

/// Watches every running app for windows appearing, disappearing or being
/// minimised, and reports "something changed" so Reef mode can reconcile its
/// tree against reality.
///
/// The signal is deliberately coarse. Individual Accessibility notifications are
/// unreliable across apps, so rather than trusting a create/destroy event to be
/// exact, any event triggers a full re-scan and diff. A slow safety-net timer
/// covers apps that post nothing at all.
final class WindowTracker {

    /// Called on the main queue, coalesced, whenever the window set may have changed.
    var onChange: (() -> Void)?

    private var observers: [pid_t: AXObserver] = [:]
    private var registeredWindows: Set<WindowRef> = []
    private var pendingReconcile: DispatchWorkItem?
    private var safetyTimer: Timer?
    private var running = false

    private let ownPID = ProcessInfo.processInfo.processIdentifier

    private static let appNotifications = [
        kAXWindowCreatedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
        kAXApplicationHiddenNotification,
        kAXApplicationShownNotification,
    ]

    // MARK: - Lifecycle

    func start() {
        guard !running else { return }
        running = true

        for app in NSWorkspace.shared.runningApplications {
            attach(to: app)
        }

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(appLaunched(_:)),
                           name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(appTerminated(_:)),
                           name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(appActivated(_:)),
                           name: NSWorkspace.didActivateApplicationNotification, object: nil)

        // Backstop for apps whose Accessibility notifications are unreliable.
        safetyTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.scheduleReconcile()
        }
    }

    func stop() {
        guard running else { return }
        running = false

        NSWorkspace.shared.notificationCenter.removeObserver(self)

        safetyTimer?.invalidate()
        safetyTimer = nil

        pendingReconcile?.cancel()
        pendingReconcile = nil

        for (_, observer) in observers {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observers.removeAll()
        registeredWindows.removeAll()
    }

    deinit { stop() }

    // MARK: - Window Enumeration

    /// Every tileable window across all apps, ordered left-to-right then
    /// top-to-bottom so a fresh tiling pass follows the on-screen arrangement.
    ///
    /// Frames are captured during the scan rather than read inside the sort:
    /// each one is an Accessibility round trip, and a comparator would make that
    /// O(n log n) instead of O(n).
    func manageableWindows() -> [WindowRef] {
        var scanned: [(window: WindowRef, frame: CGRect)] = []

        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != ownPID {
            for element in AX.windows(ofPID: app.processIdentifier) {
                guard let frame = AX.manageableFrame(element) else { continue }
                let ref = WindowRef(element)
                scanned.append((ref, frame))
                registerDestruction(of: ref, pid: app.processIdentifier)
            }
        }

        // Drop registrations for windows that have since closed, so a long
        // session does not accumulate references to dead elements.
        registeredWindows.formIntersection(scanned.map(\.window))

        return scanned
            .sorted { $0.frame.minX == $1.frame.minX
                        ? $0.frame.minY < $1.frame.minY
                        : $0.frame.minX < $1.frame.minX }
            .map(\.window)
    }

    // MARK: - Observers

    private func attach(to app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard app.activationPolicy == .regular,
              pid != ownPID,
              observers[pid] == nil
        else { return }

        var observer: AXObserver?
        guard AXObserverCreate(pid, trackerCallback, &observer) == .success,
              let observer else { return }

        let element = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        for name in Self.appNotifications {
            AXObserverAddNotification(observer, element, name as CFString, refcon)
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    /// A destroyed notification only fires for the element it was registered on,
    /// so each window has to be subscribed individually as it is discovered.
    private func registerDestruction(of window: WindowRef, pid: pid_t) {
        guard !registeredWindows.contains(window), let observer = observers[pid] else { return }
        registeredWindows.insert(window)
        AXObserverAddNotification(
            observer,
            window.element,
            kAXUIElementDestroyedNotification as CFString,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    @objc private func appLaunched(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        attach(to: app)
        scheduleReconcile()
    }

    @objc private func appTerminated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        if let observer = observers.removeValue(forKey: app.processIdentifier) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        scheduleReconcile()
    }

    @objc private func appActivated(_ note: Notification) {
        if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            attach(to: app)
        }
        scheduleReconcile()
    }

    /// Coalesce bursts — opening a window can fire several notifications at once.
    fileprivate func scheduleReconcile() {
        guard running else { return }
        pendingReconcile?.cancel()

        let work = DispatchWorkItem { [weak self] in
            self?.pendingReconcile = nil
            self?.onChange?()
        }
        pendingReconcile = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }
}

// MARK: - C callback

private func trackerCallback(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString,
    refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    Unmanaged<WindowTracker>.fromOpaque(refcon).takeUnretainedValue().scheduleReconcile()
}
