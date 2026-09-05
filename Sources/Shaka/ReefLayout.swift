import Cocoa

enum Orientation {
    case horizontal   // children sit side by side
    case vertical     // children stack top to bottom

    var flipped: Orientation { self == .horizontal ? .vertical : .horizontal }
}

/// A node in the dwindle tree. A leaf holds a window; an internal node splits
/// its rect between two children at `ratio`.
final class TileNode {
    var window: WindowRef?
    var orientation: Orientation = .horizontal
    var ratio: CGFloat = 0.5
    var first:  TileNode?
    var second: TileNode?
    weak var parent: TileNode?

    /// Filled in by the most recent layout pass. Split resizing and directional
    /// neighbour lookups both read it, so it is cached rather than recomputed.
    var rect: CGRect = .zero

    var isLeaf: Bool { window != nil }

    init(window: WindowRef) {
        self.window = window
    }

    init(orientation: Orientation, first: TileNode, second: TileNode) {
        self.orientation = orientation
        self.first  = first
        self.second = second
        first.parent  = self
        second.parent = self
    }
}

/// Hyprland's dwindle layout for a single screen.
///
/// Every window is a leaf of a binary tree that exactly fills the screen. A new
/// window splits the focused tile in half, choosing the split direction from
/// that tile's aspect ratio, so the layout spirals inward the way dwindle does.
final class ReefLayout {

    private(set) var root: TileNode?

    var gapsIn:  CGFloat = 6
    var gapsOut: CGFloat = 12

    /// The screen this layout fills, in Accessibility coordinates. Kept current
    /// by the engine so an insert can measure tiles before deciding a split axis.
    var area: CGRect = .zero

    /// Focused window promoted to cover the whole screen, if any.
    var fullscreen: WindowRef?

    private let minRatio: CGFloat = 0.1
    private let maxRatio: CGFloat = 0.9

    // MARK: - Contents

    var isEmpty: Bool { root == nil }

    var windows: [WindowRef] { leaves().compactMap(\.window) }

    func contains(_ window: WindowRef) -> Bool { leaf(for: window) != nil }

    /// Leaves in tree order — left/top subtree first. The first leaf is the
    /// "master" tile that `promoteToMaster` swaps into.
    func leaves() -> [TileNode] {
        var result: [TileNode] = []
        func walk(_ node: TileNode?) {
            guard let node else { return }
            if node.isLeaf { result.append(node); return }
            walk(node.first)
            walk(node.second)
        }
        walk(root)
        return result
    }

    func leaf(for window: WindowRef) -> TileNode? {
        leaves().first { $0.window == window }
    }

    // MARK: - Insert / Remove

    /// Split `target`'s tile and put `window` in the new half. Falls back to the
    /// last leaf when nothing is focused, and seeds the tree when it is empty.
    func insert(_ window: WindowRef, splitting target: WindowRef?) {
        guard let root else {
            self.root = TileNode(window: window)
            return
        }

        // Measure the tree first: the split axis is chosen from the host tile's
        // aspect ratio, which is meaningless if its rect is stale or unset.
        refreshRects()

        let host = target.flatMap(leaf(for:)) ?? leaves().last ?? root
        guard let hosted = host.window else { return }

        // Dwindle: split along the tile's long axis so halves stay near-square.
        let orientation: Orientation = host.rect.width >= host.rect.height ? .horizontal : .vertical

        let existing = TileNode(window: hosted)
        let added    = TileNode(window: window)

        // Re-use the host node as the new split so the parent link stays intact.
        host.window      = nil
        host.orientation = orientation
        host.ratio       = 0.5
        host.first       = existing
        host.second      = added
        existing.parent  = host
        added.parent     = host

        // Children inherit the host's rect until the next layout pass, which
        // keeps a follow-up insert's aspect-ratio check sane.
        layout(host, in: host.rect)
    }

    /// Remove a window; its sibling takes over the parent's space.
    func remove(_ window: WindowRef) {
        if fullscreen == window { fullscreen = nil }

        guard let node = leaf(for: window) else { return }

        guard let parent = node.parent else {
            root = nil
            return
        }

        let sibling = (parent.first === node) ? parent.second : parent.first
        guard let sibling else { root = nil; return }

        // Collapse the parent into the surviving sibling.
        parent.window      = sibling.window
        parent.orientation = sibling.orientation
        parent.ratio       = sibling.ratio
        parent.first       = sibling.first
        parent.second      = sibling.second
        parent.first?.parent  = parent
        parent.second?.parent = parent
    }

    // MARK: - Geometry

    /// Tile frames for `screen`, in Accessibility coordinates.
    ///
    /// Gaps follow Hyprland: `gapsOut` at the screen edge, `2 × gapsIn` between
    /// neighbours. Insetting the screen by `gapsOut - gapsIn` before splitting
    /// and each leaf by `gapsIn` afterwards produces exactly that.
    func frames(in screen: CGRect) -> [WindowRef: CGRect] {
        guard let root else { return [:] }

        area = screen
        let outer = gapsOut - gapsIn
        layout(root, in: screen.insetBy(dx: outer, dy: outer))

        var result: [WindowRef: CGRect] = [:]
        for leaf in leaves() {
            guard let window = leaf.window else { continue }
            result[window] = leaf.rect.insetBy(dx: gapsIn, dy: gapsIn)
        }

        if let fullscreen, result[fullscreen] != nil {
            result[fullscreen] = screen
        }

        return result
    }

    /// Re-run the layout pass without producing frames, so cached node rects
    /// reflect the current tree.
    private func refreshRects() {
        guard let root, !area.isEmpty else { return }
        let outer = gapsOut - gapsIn
        layout(root, in: area.insetBy(dx: outer, dy: outer))
    }

    private func layout(_ node: TileNode, in rect: CGRect) {
        node.rect = rect

        guard !node.isLeaf, let first = node.first, let second = node.second else { return }

        switch node.orientation {
        case .horizontal:
            let w = (rect.width * node.ratio).rounded()
            layout(first,  in: CGRect(x: rect.minX,     y: rect.minY, width: w,                 height: rect.height))
            layout(second, in: CGRect(x: rect.minX + w, y: rect.minY, width: rect.width - w,    height: rect.height))
        case .vertical:
            let h = (rect.height * node.ratio).rounded()
            layout(first,  in: CGRect(x: rect.minX, y: rect.minY,     width: rect.width, height: h))
            layout(second, in: CGRect(x: rect.minX, y: rect.minY + h, width: rect.width, height: rect.height - h))
        }
    }

    // MARK: - Manipulation

    /// Hyprland's `togglesplit`: flip the split that created this tile, turning a
    /// side-by-side pair into a stacked one and back.
    func toggleSplit(_ window: WindowRef) {
        guard let parent = leaf(for: window)?.parent else { return }
        parent.orientation = parent.orientation.flipped
    }

    /// Exchange two tiles in place, leaving the tree shape untouched.
    func swap(_ a: WindowRef, _ b: WindowRef) {
        guard let nodeA = leaf(for: a), let nodeB = leaf(for: b), nodeA !== nodeB else { return }
        let tmp = nodeA.window
        nodeA.window = nodeB.window
        nodeB.window = tmp
    }

    /// Swap a tile with the first leaf in the tree — dwm-style zoom.
    func promoteToMaster(_ window: WindowRef) {
        guard let master = leaves().first?.window, master != window else { return }
        swap(window, master)
    }

    /// Hyprland's `resizeactive`: grow or shrink a tile by `step` points along one
    /// axis by nudging the nearest enclosing split of that orientation. The
    /// neighbours sharing that split absorb the change.
    func resize(_ window: WindowRef, orientation: Orientation, grow: Bool, step: CGFloat) {
        guard var node = leaf(for: window) else { return }
        refreshRects()

        // Walk up to the nearest ancestor that splits along the wanted axis,
        // keeping `node` as that ancestor's direct child.
        var candidate = node.parent
        while let parent = candidate, parent.orientation != orientation {
            node = parent
            candidate = parent.parent
        }
        guard let parent = candidate else { return }

        let extent = orientation == .horizontal ? parent.rect.width : parent.rect.height
        guard extent > 0 else { return }

        // Growing the first child means a bigger ratio; growing the second means
        // a smaller one.
        let isFirst = parent.first === node
        let delta   = (step / extent) * ((isFirst == grow) ? 1 : -1)

        parent.ratio = min(maxRatio, max(minRatio, parent.ratio + delta))
    }

    /// The tile nearest `window` in a direction, chosen geometrically from the
    /// laid-out rects. Perpendicular offset is penalised so a tile directly in
    /// line wins over a closer one off to the side.
    func neighbor(of window: WindowRef, direction: Direction) -> WindowRef? {
        guard let origin = leaf(for: window) else { return nil }

        let cx = origin.rect.midX
        let cy = origin.rect.midY

        var best: WindowRef?
        var bestScore = CGFloat.infinity

        for leaf in leaves() {
            guard let candidate = leaf.window, candidate != window else { continue }

            let dx = leaf.rect.midX - cx
            let dy = leaf.rect.midY - cy

            switch direction {
            case .left:  guard dx < -1 else { continue }
            case .right: guard dx >  1 else { continue }
            case .up:    guard dy < -1 else { continue }
            case .down:  guard dy >  1 else { continue }
            }

            let score: CGFloat
            switch direction {
            case .left, .right: score = dx * dx + dy * dy * 4
            case .up, .down:    score = dx * dx * 4 + dy * dy
            }

            if score < bestScore {
                bestScore = score
                best = candidate
            }
        }

        return best
    }

    /// Next tile in tree order, wrapping around.
    func cycle(from window: WindowRef?, reverse: Bool = false) -> WindowRef? {
        let all = windows
        guard !all.isEmpty else { return nil }
        guard let window, let index = all.firstIndex(of: window) else { return all.first }

        let step = reverse ? -1 : 1
        return all[(index + step + all.count) % all.count]
    }
}
