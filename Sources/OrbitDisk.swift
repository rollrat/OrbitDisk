import SwiftUI
import AppKit

// OrbitDisk scans a selected folder without modifying its contents.
final class DiskNode: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let isDirectory: Bool
    weak var parent: DiskNode?
    var bytes: Int64 = 0
    var fileCount = 0
    var skipped = 0
    var children: [DiskNode] = []

    func isRelated(to other: DiskNode) -> Bool {
        func contains(_ node: DiskNode, ancestor: DiskNode) -> Bool {
            var current: DiskNode? = node
            while let candidate = current {
                if candidate === ancestor { return true }
                current = candidate.parent
            }
            return false
        }
        return contains(self, ancestor: other) || contains(other, ancestor: self)
    }

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.name = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        self.isDirectory = isDirectory
    }
}

final class ScanHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
}

private final class ScanCounter {
    var files = 0
    var bytes: Int64 = 0
    var lastUpdate = Date.distantPast
}

private enum FolderScanner {
    static func scan(_ url: URL, handle: ScanHandle,
                     progress: @escaping (String, Int, Int64) -> Void) -> DiskNode? {
        let counter = ScanCounter()
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
            .fileAllocatedSizeKey, .totalFileAllocatedSizeKey
        ]

        func visit(_ url: URL) -> DiskNode? {
            if handle.isCancelled { return nil }
            let values = try? url.resourceValues(forKeys: keys)
            let isLink = values?.isSymbolicLink == true
            let isDirectory = values?.isDirectory == true && !isLink
            let node = DiskNode(url: url, isDirectory: isDirectory)

            if isDirectory {
                do {
                    let urls = try FileManager.default.contentsOfDirectory(
                        at: url, includingPropertiesForKeys: Array(keys), options: [])
                    for childURL in urls {
                        if handle.isCancelled { return nil }
                        if let child = visit(childURL) {
                            child.parent = node
                            node.children.append(child)
                            node.bytes += child.bytes
                            node.fileCount += child.fileCount
                            node.skipped += child.skipped
                        }
                    }
                    node.children.sort { $0.bytes > $1.bytes }
                } catch {
                    node.skipped += 1
                }
            } else {
                let size = values?.totalFileAllocatedSize
                    ?? values?.fileAllocatedSize
                    ?? values?.fileSize ?? 0
                node.bytes = Int64(max(0, size))
                node.fileCount = 1
                counter.files += 1
                counter.bytes += node.bytes
                if Date().timeIntervalSince(counter.lastUpdate) > 0.16 {
                    counter.lastUpdate = Date()
                    progress(url.path, counter.files, counter.bytes)
                }
            }
            return node
        }
        return visit(url)
    }
}

private let byteFormatter: ByteCountFormatter = {
    let f = ByteCountFormatter()
    f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
    f.countStyle = .file
    return f
}()
private func formattedSize(_ bytes: Int64) -> String { byteFormatter.string(fromByteCount: bytes) }
private func sizeParts(_ bytes: Int64) -> (String, String) {
    let text = formattedSize(bytes)
    let split = text.firstIndex { !$0.isNumber && $0 != "." && $0 != "," } ?? text.endIndex
    return (String(text[..<split]), String(text[split...]).trimmingCharacters(in: .whitespaces))
}

private enum Theme {
    static let background = Color(red: 0.125, green: 0.154, blue: 0.225)
    static let toolbar = Color(red: 0.107, green: 0.133, blue: 0.197)
    static let muted = Color(red: 0.57, green: 0.63, blue: 0.74)
    static let accent = Color(red: 0.43, green: 0.89, blue: 0.75)
    static let line = Color.white.opacity(0.075)
}

private struct RingSlice: Identifiable {
    let id: String
    let node: DiskNode?
    let parent: DiskNode
    let smallItems: [DiskNode]
    let bytes: Int64
    let depth: Int
    let start: Double
    let end: Double
    var name: String { node?.name ?? "작은 항목 \(smallItems.count.formatted())개" }
    var color: Color {
        guard let node else { return Color(red: 0.50, green: 0.57, blue: 0.69).opacity(0.42) }
        let hue = 0.07 + ((start + end) / 2 / (2 * .pi)) * 0.79
        return Color(hue: hue, saturation: node.isDirectory ? max(0.32, 0.58 - Double(depth) * 0.035) : 0.22,
                     brightness: node.isDirectory ? 0.96 : 0.81)
    }
}

private enum RingLayout {
    static let boundaries: [CGFloat] = [0.145, 0.325, 0.485, 0.625, 0.745, 0.835, 0.905, 0.967]
    static let compactBoundaries: [CGFloat] = [0.30, 0.50, 0.69, 0.84, 0.97]
    static func make(_ focus: DiskNode) -> [RingSlice] {
        var slices: [RingSlice] = []
        func walk(_ parent: DiskNode, depth: Int, start: Double, end: Double) {
            guard depth < 7, parent.bytes > 0 else { return }
            let children = parent.children.filter { $0.bytes > 0 }
            var cursor = start
            for (index, child) in children.enumerated() {
                let next = min(end, cursor + (end - start) * Double(child.bytes) / Double(parent.bytes))
                // Coalesce a sorted tail rather than dropping its angle or painting invisible hit targets.
                if next - cursor < 0.0025 || index >= 100 || slices.count >= 2200 {
                    let tail = Array(children[index...])
                    slices.append(RingSlice(id: parent.id.uuidString + "-small", node: nil, parent: parent,
                                            smallItems: tail, bytes: tail.reduce(0) { $0 + $1.bytes },
                                            depth: depth, start: cursor, end: end))
                    break
                }
                slices.append(RingSlice(id: child.id.uuidString, node: child, parent: parent,
                                        smallItems: [], bytes: child.bytes,
                                        depth: depth, start: cursor, end: next))
                walk(child, depth: depth + 1, start: cursor, end: next)
                cursor = next
            }
        }
        walk(focus, depth: 0, start: 0, end: 2 * .pi)
        return slices
    }
    static func hit(_ point: CGPoint, size: CGSize, slices: [RingSlice], boundaries: [CGFloat] = boundaries) -> RingSlice? {
        let radius = min(size.width, size.height) / 2
        let dx = point.x - size.width / 2, dy = point.y - size.height / 2
        let distance = hypot(dx, dy) / radius
        guard let depth = (0..<(boundaries.count - 1)).first(where: { distance >= boundaries[$0] && distance < boundaries[$0 + 1] }) else { return nil }
        let raw = atan2(dy, dx)
        let angle = raw < 0 ? raw + 2 * .pi : raw
        return slices.first { $0.depth == depth && angle >= $0.start && angle < $0.end }
    }
    static func path(_ slice: RingSlice, size: CGSize, boundaries: [CGFloat] = boundaries) -> Path {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) / 2
        let inner = radius * boundaries[slice.depth]
        let outer = radius * boundaries[slice.depth + 1]
        var path = Path()
        path.addArc(center: center, radius: outer, startAngle: .radians(slice.start), endAngle: .radians(slice.end), clockwise: false)
        path.addArc(center: center, radius: inner, startAngle: .radians(slice.end), endAngle: .radians(slice.start), clockwise: true)
        path.closeSubpath()
        return path
    }
}

private enum RingLabels {
    struct Placement {
        let text: String
        let fontSize: CGFloat
        let center: CGPoint
        let rotation: Double
        let measuredSize: CGSize
    }

    static func place(_ slice: RingSlice, size: CGSize, boundaries: [CGFloat], compact: Bool) -> Placement? {
        guard let node = slice.node, node.isDirectory, slice.depth < boundaries.count - 1 else { return nil }
        let radius = min(size.width, size.height) / 2
        let inner = radius * boundaries[slice.depth]
        let outer = radius * boundaries[slice.depth + 1]
        let middle = (inner + outer) / 2
        let padding: CGFloat = compact ? 3 : 4
        let fontSize: CGFloat = compact ? 9 : max(9, 12 - CGFloat(slice.depth) * 0.7)
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let textHeight = ceil(font.ascender - font.descender + font.leading)
        guard outer - inner >= textHeight + 2 * padding else { return nil }

        // Fit a straight, tangential label inside both circular edges and both
        // angular edges. Arc length alone would let long labels cross rings.
        let halfHeight = textHeight / 2
        let radialWidth = 2 * sqrt(max(0, pow(outer - padding, 2) - pow(middle + halfHeight, 2)))
        let halfAngle = min((slice.end - slice.start) / 2, .pi / 2 - 0.001)
        let angularWidth = 2 * (middle - halfHeight) * tan(halfAngle) - 2 * padding
        let availableWidth = min(radialWidth, angularWidth)
        guard availableWidth >= 22 else { return nil }
        var text = node.name
        var width = ceil((text as NSString).size(withAttributes: attributes).width)
        if width > availableWidth {
            // Keep short names intact; only abbreviate if a useful prefix fits.
            guard availableWidth >= 48 else { return nil }
            let characters = Array(text)
            var count = min(characters.count - 1, 48)
            while count >= 5 {
                text = String(characters.prefix(count)) + "…"
                width = ceil((text as NSString).size(withAttributes: attributes).width)
                if width <= availableWidth { break }
                count -= 1
            }
            guard count >= 5, width <= availableWidth else { return nil }
        }
        let angle = (slice.start + slice.end) / 2
        var rotation = (angle + .pi / 2).truncatingRemainder(dividingBy: 2 * .pi)
        if rotation > .pi { rotation -= 2 * .pi }
        if rotation > .pi / 2 { rotation -= .pi }
        if rotation < -.pi / 2 { rotation += .pi }
        return Placement(text: text, fontSize: fontSize,
                         center: CGPoint(x: size.width / 2 + middle * cos(angle),
                                         y: size.height / 2 + middle * sin(angle)),
                         rotation: rotation, measuredSize: CGSize(width: width, height: textHeight))
    }
}

private struct DiskVolume: Identifiable {
    let url: URL
    let scanURL: URL
    let name: String
    let total: Int64
    let available: Int64
    var id: String { url.path }
    var used: Int64 { max(0, total - available) }
    var gaugeColor: Color { Double(used) / Double(max(total, 1)) > 0.85 ? Color(red: 0.97, green: 0.72, blue: 0.43) : Theme.accent }
    static func load() -> [DiskVolume] {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeIsLocalKey]
        let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []
        var urls = [URL(fileURLWithPath: "/")] + mounted.filter { $0.path != "/" && $0.path.hasPrefix("/Volumes/") }
        var seen = Set<String>()
        urls = urls.filter { seen.insert($0.path).inserted }
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys), let total = values.volumeTotalCapacity, total > 0 else { return nil }
            let scanURL = url.path == "/" ? URL(fileURLWithPath: "/System/Volumes/Data") : url
            return DiskVolume(url: url, scanURL: scanURL, name: values.volumeName ?? url.lastPathComponent,
                              total: Int64(total), available: Int64(values.volumeAvailableCapacity ?? 0))
        }
    }
}

@MainActor
final class DiskViewModel: ObservableObject {
    @Published var root: DiskNode?
    @Published var focus: DiskNode?
    @Published var selected: DiskNode?
    @Published var hovered: DiskNode?
    @Published fileprivate private(set) var hoveredSlice: RingSlice?
    @Published fileprivate private(set) var slices: [RingSlice] = []
    @Published var smallItems: [DiskNode]?
    @Published var query = ""
    @Published var scanning = false
    @Published var overview = true
    @Published var status = ""
    @Published var scanURL: URL?
    @Published var scannedFiles = 0
    @Published var scannedBytes: Int64 = 0
    @Published var elapsed: TimeInterval = 0
    @Published private(set) var lastScannedAt: Date?
    @Published fileprivate private(set) var volumes = DiskVolume.load()
    @Published private var history: [DiskNode] = []
    @Published private var historyIndex = -1
    private var handle: ScanHandle?
    var activeNode: DiskNode? { hovered ?? selected }
    var canBack: Bool { historyIndex > 0 }
    var canForward: Bool { historyIndex >= 0 && historyIndex < history.count - 1 }
    var breadcrumbs: [DiskNode] {
        guard let focus else { return [] }
        var path: [DiskNode] = [focus]
        var cursor = focus.parent
        while let node = cursor { path.append(node); cursor = node.parent }
        return path.reversed()
    }
    var listedItems: [DiskNode] {
        let items = smallItems ?? focus?.children ?? []
        return query.isEmpty ? items : items.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "스캔"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.start(url) }
        }
    }
    func start(_ url: URL) {
        handle?.cancel()
        let current = ScanHandle()
        handle = current
        scanURL = url
        scanning = true
        status = url.path
        scannedFiles = 0
        scannedBytes = 0
        elapsed = 0
        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = FolderScanner.scan(url, handle: current) { path, files, bytes in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.handle === current else { return }
                    self.status = path
                    self.scannedFiles = files
                    self.scannedBytes = bytes
                    self.elapsed = Date().timeIntervalSince(started)
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.handle === current else { return }
                self.scanning = false
                if let result, !current.isCancelled {
                    self.showSnapshot(result, elapsed: Date().timeIntervalSince(started), scannedAt: Date())
                    self.volumes = DiskVolume.load()
                    self.status = "스캔 완료"
                } else { self.status = "스캔 취소됨" }
            }
        }
    }
    func cancel() { handle?.cancel() }
    // Share the completed, immutable scan tree with another view without scanning again.
    func showSnapshot(_ root: DiskNode, focus: DiskNode? = nil, elapsed: TimeInterval, scannedAt: Date?) {
        handle?.cancel()
        handle = nil
        scanning = false
        self.root = root
        scanURL = root.url
        self.elapsed = elapsed
        lastScannedAt = scannedAt
        history = []
        historyIndex = -1
        open(root)
        if let focus, focus !== root { open(focus) }
    }
    func open(_ node: DiskNode, record: Bool = true) {
        guard node.isDirectory else { selected = node; return }
        if record {
            if historyIndex >= 0 { history = Array(history.prefix(historyIndex + 1)) }
            if history.last !== node { history.append(node) }
            historyIndex = history.count - 1
        }
        focus = node
        slices = RingLayout.make(node)
        selected = nil
        hovered = nil
        hoveredSlice = nil
        smallItems = nil
        query = ""
        overview = false
    }
    func back() { guard canBack else { return }; historyIndex -= 1; open(history[historyIndex], record: false) }
    func forward() { guard canForward else { return }; historyIndex += 1; open(history[historyIndex], record: false) }
    func up() { if let parent = focus?.parent { open(parent) } }
    fileprivate func activate(_ slice: RingSlice) {
        if let node = slice.node { open(node) }
        else { open(slice.parent); smallItems = slice.smallItems }
    }
    fileprivate func hover(_ slice: RingSlice?) {
        if hoveredSlice?.id == slice?.id { return }
        hoveredSlice = slice
        hovered = slice?.node
    }
    func hoverRow(_ node: DiskNode?) {
        hoveredSlice = nil
        if hovered !== node { hovered = node }
    }
    func reveal(_ node: DiskNode) { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
    func copyPath(_ node: DiskNode) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.url.path, forType: .string)
    }
    func color(for node: DiskNode) -> Color { slices.first { $0.node === node }?.color ?? Theme.muted }
    func resetSelection() { selected = nil; hovered = nil; hoveredSlice = nil }
}

// Screen = (map point - viewport center) * scale + viewport center + offset.
private struct MapViewport {
    static let limits: ClosedRange<CGFloat> = 0.5...6
    var scale: CGFloat = 1
    var offset = CGSize.zero

    func mapPoint(_ point: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: (point.x - size.width / 2 - offset.width) / scale + size.width / 2,
                y: (point.y - size.height / 2 - offset.height) / scale + size.height / 2)
    }

    mutating func zoom(by factor: CGFloat, at point: CGPoint, size: CGSize) {
        guard factor.isFinite, factor > 0 else { return }
        let next = min(Self.limits.upperBound, max(Self.limits.lowerBound, scale * factor))
        let ratio = next / scale
        offset.width = point.x - size.width / 2 - (point.x - size.width / 2 - offset.width) * ratio
        offset.height = point.y - size.height / 2 - (point.y - size.height / 2 - offset.height) * ratio
        scale = next
        constrain(to: size)
    }

    mutating func pan(by delta: CGSize, size: CGSize) {
        offset.width += delta.width
        offset.height += delta.height
        constrain(to: size)
    }

    mutating func constrain(to size: CGSize) {
        // Keep at least a small part of the map within reach after dragging.
        let radius = min(size.width, size.height) * 0.5 * scale * RingLayout.boundaries.last!
        let reach = max(0, radius - 48)
        let outsideX = max(0, abs(offset.width) - size.width / 2)
        let outsideY = max(0, abs(offset.height) - size.height / 2)
        let distance = hypot(outsideX, outsideY)
        if distance > reach {
            let ratio = reach / distance
            if outsideX > 0 { offset.width = (offset.width < 0 ? -1 : 1) * (size.width / 2 + outsideX * ratio) }
            if outsideY > 0 { offset.height = (offset.height < 0 ? -1 : 1) * (size.height / 2 + outsideY * ratio) }
        }
    }
}

// Scoped to each chart: no global event monitor or scroll interception in surrounding lists.
private struct MapInput: NSViewRepresentable {
    var zoom: (CGFloat, CGPoint) -> Void
    var pan: (CGSize) -> Void
    var click: (CGPoint) -> Void
    var hover: (CGPoint?) -> Void
    var blockedRects: [CGRect] = []

    func makeNSView(context: Context) -> InputView { InputView() }
    func updateNSView(_ view: InputView, context: Context) {
        view.zoom = zoom; view.pan = pan; view.click = click; view.hover = hover
        view.blockedRects = blockedRects
    }

    final class InputView: NSView {
        var zoom: (CGFloat, CGPoint) -> Void = { _, _ in }
        var pan: (CGSize) -> Void = { _ in }
        var click: (CGPoint) -> Void = { _ in }
        var hover: (CGPoint?) -> Void = { _ in }
        var blockedRects: [CGRect] = []
        private var tracking: NSTrackingArea?
        private var down: CGPoint?
        private var previous: CGPoint?
        private var dragged = false
        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            guard !blockedRects.contains(where: { $0.contains(local) }) else { return nil }
            return super.hitTest(point)
        }
        private func hoverPoint(_ event: NSEvent) {
            let local = point(event)
            hover(blockedRects.contains(where: { $0.contains(local) }) ? nil : local)
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(area)
            tracking = area
        }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }
        override func scrollWheel(with event: NSEvent) {
            let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.008 : 0.10)
            guard delta != 0 else { return }
            zoom(CGFloat(exp(Double(min(0.5, max(-0.5, delta))))), point(event))
            hover(point(event))
        }
        override func magnify(with event: NSEvent) {
            zoom(max(0.1, 1 + event.magnification), point(event))
            hover(point(event))
        }
        override func mouseEntered(with event: NSEvent) { hoverPoint(event) }
        override func mouseMoved(with event: NSEvent) { hoverPoint(event) }
        override func mouseExited(with event: NSEvent) { hover(nil) }
        override func mouseDown(with event: NSEvent) {
            down = point(event); previous = down; dragged = false
        }
        override func mouseDragged(with event: NSEvent) {
            guard let down, let previous else { return }
            let current = point(event)
            if !dragged && hypot(current.x - down.x, current.y - down.y) < 4 { return }
            dragged = true
            NSCursor.closedHand.set()
            hover(nil)
            pan(CGSize(width: current.x - previous.x, height: current.y - previous.y))
            self.previous = current
        }
        override func mouseUp(with event: NSEvent) {
            guard down != nil else { return }
            let current = point(event)
            let shouldClick = !dragged
            down = nil; previous = nil; dragged = false
            NSCursor.openHand.set()
            if shouldClick { click(current) }
            else { hoverPoint(event) }
        }
    }
}

private struct MapSurface {
    static let sidebarWidth: CGFloat = 352
    static let menuSize = CGSize(width: 400, height: 680)
    static let menuPanelHeight: CGFloat = 272
    let size: CGSize
    let floating: Bool
    var compact = false
    var menuNavigationFrame: CGRect { CGRect(x: 12, y: 70, width: size.width - 24, height: 34) }
    var menuPanelFrame: CGRect { CGRect(x: 12, y: size.height - Self.menuPanelHeight - 12,
                                       width: size.width - 24, height: Self.menuPanelHeight) }
    var mapFrame: CGRect {
        if floating && compact {
            return CGRect(x: 16, y: 88, width: max(1, size.width - 32), height: max(1, menuPanelFrame.minY - 76))
        }
        return floating ? CGRect(x: 16, y: 76, width: max(1, size.width - 416), height: max(1, size.height - 144))
                 : CGRect(origin: .zero, size: size)
    }
    var blockedRects: [CGRect] {
        guard floating else { return [] }
        if compact {
            return [CGRect(x: 0, y: 0, width: size.width, height: 60), menuNavigationFrame, menuPanelFrame]
        }
        return [CGRect(x: 0, y: 0, width: size.width, height: 52),
                CGRect(x: 0, y: size.height - 44, width: size.width, height: 44),
                CGRect(x: size.width - Self.sidebarWidth - 16, y: 68,
                       width: Self.sidebarWidth, height: max(0, size.height - 128))]
    }
    func localPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - mapFrame.minX, y: point.y - mapFrame.minY)
    }
}

private struct WindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .withinWindow
        view.material = .hudWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private struct GlassPanel: View {
    var radius: CGFloat = 16
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        ZStack {
            if reduceTransparency { Theme.background }
            else {
                WindowBlur()
                Theme.background.opacity(0.24)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Color.white.opacity(0.09), lineWidth: 0.7))
        .allowsHitTesting(false)
    }
}

private struct MapView: View {
    @ObservedObject var model: DiskViewModel
    let focus: DiskNode
    var compact = false
    var floating = false
    @Binding var viewport: MapViewport
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    init(model: DiskViewModel, focus: DiskNode, compact: Bool = false, floating: Bool = false,
         viewport: Binding<MapViewport>) {
        self.model = model
        self.focus = focus
        self.compact = compact
        self.floating = floating
        self._viewport = viewport
    }
    private var displayedBytes: Int64 { model.hoveredSlice?.bytes ?? model.activeNode?.bytes ?? focus.bytes }
    private var boundaries: [CGFloat] { compact ? RingLayout.compactBoundaries : RingLayout.boundaries }
    private var visibleSlices: [RingSlice] { model.slices.filter { $0.depth < boundaries.count - 1 } }
    var body: some View {
        Group {
            if compact && !floating { chart.aspectRatio(1, contentMode: .fit) }
            else { chart.frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
    }

    private var chart: some View {
        GeometryReader { geo in
            let surface = MapSurface(size: geo.size, floating: floating, compact: compact)
            let mapSize = surface.mapFrame.size
            ZStack {
                Canvas { context, size in
                    // Rebuild paths and fit labels using actual on-screen geometry at every zoom level.
                    // Text/strokes stay at readable point sizes as more labels become eligible.
                    let drawingSize = CGSize(width: mapSize.width * viewport.scale, height: mapSize.height * viewport.scale)
                    context.translateBy(x: surface.mapFrame.midX - drawingSize.width / 2 + viewport.offset.width,
                                        y: surface.mapFrame.midY - drawingSize.height / 2 + viewport.offset.height)
                    let active = model.activeNode
                    for slice in visibleSlices {
                        let path = RingLayout.path(slice, size: drawingSize, boundaries: boundaries)
                        let related = active == nil || slice.node.map { $0.isRelated(to: active!) } == true
                        var layer = context
                        layer.opacity = related || model.hoveredSlice?.id == slice.id ? 1 : 0.28
                        layer.fill(path, with: .color(slice.color))
                        layer.stroke(path, with: .color(Theme.background.opacity(0.72)), lineWidth: 0.65)
                        if (active != nil && slice.node === active) || model.hoveredSlice?.id == slice.id {
                            layer.stroke(path, with: .color(Color.white.opacity(0.85)), lineWidth: 1.35)
                        }
                        if let label = RingLabels.place(slice, size: drawingSize, boundaries: boundaries, compact: compact) {
                            layer.clip(to: path)
                            layer.translateBy(x: label.center.x, y: label.center.y)
                            layer.rotate(by: .radians(label.rotation))
                            layer.draw(Text(label.text).font(.system(size: label.fontSize, weight: .medium))
                                .foregroundColor(Theme.background.opacity(0.95)), at: .zero, anchor: .center)
                        }
                    }
                }
                .allowsHitTesting(false)
                .accessibilityLabel("폴더 용량 지도. 목록에서도 각 항목을 탐색할 수 있습니다.")
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.20)) { model.up() }
                } label: {
                    VStack(spacing: 3) {
                        let parts = sizeParts(displayedBytes)
                        Text(parts.0)
                            .font(.system(size: (compact ? 21 : min(23, geo.size.width * 0.038)), weight: .medium, design: .rounded))
                            .minimumScaleFactor(0.65).lineLimit(1)
                        Text(parts.1).font(.system(size: 11)).foregroundStyle(Theme.muted)
                        if focus.parent != nil {
                            Image(systemName: "chevron.up").font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.muted)
                        }
                    }
                    .foregroundStyle(model.activeNode.map { model.color(for: $0) } ?? Theme.accent)
                    .frame(width: min(mapSize.width, mapSize.height) * (compact ? 0.28 : 0.135) * viewport.scale,
                           height: min(mapSize.width, mapSize.height) * (compact ? 0.28 : 0.135) * viewport.scale)
                    .background(Circle().fill(Theme.background))
                    .contentShape(Circle())
                }
                .buttonStyle(.plain).help(focus.parent == nil ? "현재 스캔의 시작 폴더" : "중심을 클릭하면 상위 폴더로 이동합니다")
                .accessibilityLabel(focus.parent == nil ? "현재 폴더 용량" : "상위 폴더로 이동")
                .allowsHitTesting(false)
                .offset(x: viewport.offset.width + surface.mapFrame.midX - geo.size.width / 2,
                        y: viewport.offset.height + surface.mapFrame.midY - geo.size.height / 2)

                MapInput(
                    zoom: { factor, point in viewport.zoom(by: factor, at: surface.localPoint(point), size: mapSize) },
                    pan: { delta in viewport.pan(by: delta, size: mapSize) },
                    click: { point in activate(at: surface.localPoint(point), size: mapSize) },
                    hover: { point in
                        model.hover(point.flatMap {
                            RingLayout.hit(viewport.mapPoint(surface.localPoint($0), size: mapSize), size: mapSize,
                                           slices: visibleSlices, boundaries: boundaries)
                        })
                    },
                    blockedRects: surface.blockedRects
                ).accessibilityHidden(true)
            }
            .clipped()
            .overlay(alignment: .topTrailing) {
                if !compact {
                    HStack(spacing: 1) {
                        SmallIconButton(symbol: "minus", help: "지도 축소", disabled: viewport.scale <= MapViewport.limits.lowerBound) {
                            zoom(by: 1 / 1.25, size: mapSize)
                        }
                        Button {
                            viewport = MapViewport()
                            model.hover(nil)
                        } label: {
                            Text("\(Int((viewport.scale * 100).rounded()))%")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .frame(width: 42, height: 27).contentShape(Rectangle())
                        }.buttonStyle(.plain).foregroundStyle(Theme.muted)
                            .help("원래 크기와 위치로 · 100%")
                            .accessibilityLabel("지도 원래 크기와 위치로 복원")
                            .accessibilityValue("\(Int((viewport.scale * 100).rounded()))%")
                        SmallIconButton(symbol: "plus", help: "지도 확대", disabled: viewport.scale >= MapViewport.limits.upperBound) {
                            zoom(by: 1.25, size: mapSize)
                        }
                    }
                    .padding(3).background { GlassPanel(radius: 10) }
                    .padding(.trailing, floating ? MapSurface.sidebarWidth + 48 : 8)
                    .padding(.top, floating ? 70 : 8)
                }
            }
            .onChange(of: geo.size) { size in viewport.constrain(to: MapSurface(size: size, floating: floating, compact: compact).mapFrame.size) }
        }
    }

    private func zoom(by factor: CGFloat, size: CGSize) {
        viewport.zoom(by: factor, at: CGPoint(x: size.width / 2, y: size.height / 2), size: size)
        model.hover(nil)
    }

    private func activate(at point: CGPoint, size: CGSize) {
        let mapped = viewport.mapPoint(point, size: size)
        let distance = hypot(mapped.x - size.width / 2, mapped.y - size.height / 2)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.20)) {
            if distance < min(size.width, size.height) / 2 * boundaries[0] { model.up() }
            else if let slice = RingLayout.hit(mapped, size: size, slices: visibleSlices, boundaries: boundaries) {
                model.activate(slice)
            } else { model.resetSelection() }
        }
    }
}

private struct SmallIconButton: View {
    let symbol: String
    let help: String
    var disabled = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                .frame(width: 27, height: 27).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(disabled ? Theme.muted.opacity(0.3) : Theme.muted)
        .disabled(disabled).help(help).accessibilityLabel(help)
    }
}

private struct FileRow: View {
    @ObservedObject var model: DiskViewModel
    let node: DiskNode
    var body: some View {
        let active = model.activeNode.map { node.isRelated(to: $0) } ?? false
        Button { withAnimation(.easeInOut(duration: 0.20)) { model.open(node) } } label: {
            HStack(spacing: 9) {
                Circle().fill(model.color(for: node)).frame(width: 7, height: 7)
                Text(node.name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 5)
                Text(formattedSize(node.bytes)).font(.system(size: 12, design: .rounded)).monospacedDigit()
                    .foregroundStyle(active ? Color.white : Theme.muted)
                Image(systemName: node.isDirectory ? "chevron.right" : "doc")
                    .font(.system(size: 9)).foregroundStyle(Theme.muted.opacity(active ? 1 : 0.4))
                    .frame(width: 10)
            }
            .padding(.horizontal, 9).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(active ? 0.085 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { model.hoverRow($0 ? node : nil) }
        .accessibilityLabel("\(node.name), \(formattedSize(node.bytes))")
        .contextMenu {
            Button("Finder에서 보기") { model.reveal(node) }
            Button("경로 복사") { model.copyPath(node) }
        }
    }
}

private struct ScanView: View {
    @ObservedObject var model: DiskViewModel
    @State private var rotating = false
    var body: some View {
        VStack(spacing: 19) {
            ZStack {
                Circle().stroke(Theme.accent.opacity(0.08), lineWidth: 20)
                Circle().trim(from: 0, to: 0.28).stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(rotating ? 360 : 0))
                    .animation(.linear(duration: 2.5).repeatForever(autoreverses: false), value: rotating)
                Image(systemName: "internaldrive").font(.system(size: 28, weight: .light)).foregroundStyle(Theme.accent)
            }.frame(width: 110, height: 110).padding(.bottom, 15)
            Text("공간을 살펴보는 중").font(.system(size: 25, weight: .medium))
            Text(model.scanURL?.lastPathComponent ?? "").foregroundStyle(Theme.muted)
            HStack(spacing: 28) {
                metric(model.scannedFiles.formatted(), label: "확인한 파일")
                metric(formattedSize(model.scannedBytes), label: "찾은 용량")
                metric("\(Int(model.elapsed))초", label: "경과 시간")
            }.padding(.vertical, 15)
            Text(model.status).font(.system(size: 11)).foregroundStyle(Theme.muted)
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 460)
            Button("스캔 취소") { model.cancel() }.buttonStyle(.bordered).padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { rotating = true }
    }
    private func metric(_ value: String, label: String) -> some View {
        VStack(spacing: 6) {
            Text(value).font(.system(size: 21, weight: .medium, design: .rounded)).monospacedDigit()
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.muted)
        }.frame(minWidth: 100)
    }
}

struct ContentView: View {
    @ObservedObject var model: DiskViewModel
    @State private var dropTarget = false
    // Keep navigation camera state even while the chart is hidden (empty folders or rescans).
    @State private var mapViewport = MapViewport()
    var body: some View {
        ZStack {
            if !model.scanning, !model.overview, let focus = model.focus { workspace(focus) }
            else {
                VStack(spacing: 0) {
                    toolbar
                    if model.scanning { ScanView(model: model) }
                    else { overview }
                }
            }
        }
        .background(Theme.background)
        .ignoresSafeArea(.container, edges: .top)
        .overlay { if dropTarget { RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.accent, lineWidth: 3).padding(5).allowsHitTesting(false) } }
        .frame(minWidth: 960, minHeight: 660)
        .preferredColorScheme(.dark)
        .onDrop(of: ["public.file-url"], isTargeted: $dropTarget) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return }
                Task { @MainActor in model.start(url) }
            }
            return true
        }
        .background {
            Group {
                Button("") { model.back() }.keyboardShortcut("[", modifiers: .command)
                Button("") { model.forward() }.keyboardShortcut("]", modifiers: .command)
                Button("") { model.up() }.keyboardShortcut(.upArrow, modifiers: .command)
                Button("") { if let url = model.focus?.url { model.start(url) } }.keyboardShortcut("r", modifiers: .command)
                Button("") { model.chooseFolder() }.keyboardShortcut("o", modifiers: .command)
                Button("") { model.resetSelection() }.keyboardShortcut(.escape, modifiers: [])
            }.hidden().accessibilityHidden(true)
        }
    }
    private var toolbar: some View {
        HStack(spacing: 3) {
            SmallIconButton(symbol: "chevron.left", help: "뒤로 · ⌘[", disabled: !model.canBack || model.scanning) { model.back() }
            SmallIconButton(symbol: "chevron.right", help: "앞으로 · ⌘]", disabled: !model.canForward || model.scanning) { model.forward() }
            Button { model.overview = true; model.resetSelection() } label: {
                HStack(spacing: 5) { Image(systemName: "internaldrive"); Text("디스크와 폴더") }
                    .font(.system(size: 11, weight: .medium)).padding(.horizontal, 9).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 5).fill(model.overview ? Color.white.opacity(0.1) : Color.clear))
            }.buttonStyle(.plain).foregroundStyle(model.overview ? Color.white : Theme.muted)
            if !model.overview && !model.scanning {
                ForEach(Array(model.breadcrumbs.suffix(4))) { node in
                    Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(Theme.muted.opacity(0.5)).padding(.horizontal, 3)
                    Button { withAnimation(.easeInOut(duration: 0.2)) { model.open(node) } } label: {
                        Text(node.name).font(.system(size: 11)).lineLimit(1).truncationMode(.middle).frame(maxWidth: 140)
                    }.buttonStyle(.plain).foregroundStyle(node === model.focus ? .white : Theme.muted)
                }
            }
            Spacer(minLength: 15)
            if !model.overview && !model.scanning {
                SmallIconButton(symbol: "arrow.clockwise", help: "다시 스캔 · ⌘R") {
                    if let url = model.focus?.url { model.start(url) }
                }
            }
            Button { model.chooseFolder() } label: {
                Label("폴더 선택", systemImage: "folder.badge.plus").font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.09)))
            }.buttonStyle(.plain).help("폴더 선택 · ⌘O")
        }
        .padding(.leading, 78).padding(.trailing, 18).frame(height: 51)
        .background { GlassPanel(radius: 0) }
    }
    private func workspace(_ focus: DiskNode) -> some View {
        ZStack {
            if focus.bytes > 0 {
                MapView(model: model, focus: focus, floating: true, viewport: $mapViewport)
                    .transition(.opacity)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: focus.skipped > 0 ? "lock" : "folder").font(.system(size: 35, weight: .light))
                    Text(focus.skipped > 0 ? "이 폴더에 접근할 수 없습니다" : "표시할 파일이 없습니다").font(.subheadline)
                }.foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.trailing, MapSurface.sidebarWidth + 32)
            }
        }
        .overlay(alignment: .topLeading) {
            HStack(spacing: 12) {
                Text("SPACE MAP").font(.system(size: 10, weight: .semibold)).tracking(2)
                Text("최대 7단계").font(.system(size: 10))
            }.foregroundStyle(Theme.muted)
                .padding(.horizontal, 13).padding(.vertical, 10)
                .background { GlassPanel(radius: 10) }
                .padding(.leading, 24).padding(.top, 70)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 16) {
                Label("조각을 눌러 폴더 열기", systemImage: "cursorarrow")
                Label("스크롤로 확대 · 드래그로 이동", systemImage: "hand.draw")
            }.font(.system(size: 10)).foregroundStyle(Theme.muted)
                .padding(.horizontal, 13).padding(.vertical, 10)
                .background { GlassPanel(radius: 10) }
                .padding(.leading, 24).padding(.bottom, 56)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .trailing) {
            sidebar(focus).padding(18)
                .frame(width: MapSurface.sidebarWidth)
                .background { GlassPanel(radius: 18) }
                .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
                .padding(.top, 68).padding(.bottom, 60).padding(.trailing, 16)
        }
        .overlay(alignment: .top) { toolbar }
        .overlay(alignment: .bottom) { footer(focus) }
        .clipped()
    }
    private func sidebar(_ focus: DiskNode) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(focus.name).font(.system(size: 20, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 7)
                Text(formattedSize(focus.bytes)).font(.system(size: 17, weight: .regular, design: .rounded)).foregroundStyle(Theme.accent)
            }.padding(.bottom, 9)
            Text("\(focus.fileCount.formatted())개 파일 · \(focus.children.count.formatted())개 항목")
                .font(.system(size: 11)).foregroundStyle(Theme.muted).padding(.bottom, 21)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.muted)
                TextField("이 폴더에서 찾기", text: $model.query).font(.system(size: 11)).textFieldStyle(.plain)
                if !model.query.isEmpty { Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.muted) }.buttonStyle(.plain) }
            }.padding(.horizontal, 10).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.10))).padding(.bottom, 12)
            HStack {
                Text(model.smallItems == nil ? "이름" : "작은 항목 \(model.smallItems!.count.formatted())개")
                Spacer()
                if model.smallItems != nil {
                    Button("전체 보기") { model.smallItems = nil }.buttonStyle(.plain).foregroundStyle(Theme.accent)
                } else { Text("크기 ↓") }
            }.font(.system(size: 10)).foregroundStyle(Theme.muted.opacity(0.75)).padding(.horizontal, 9).padding(.bottom, 6)
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(model.listedItems) { node in FileRow(model: model, node: node) }
                    if model.listedItems.isEmpty {
                        Text(model.query.isEmpty ? "항목이 없습니다" : "일치하는 항목이 없습니다")
                            .font(.system(size: 12)).foregroundStyle(Theme.muted).padding(.vertical, 28)
                    }
                }
            }
            .id(focus.id.uuidString + model.query + String(model.smallItems?.count ?? -1))
            .padding(.horizontal, -3)
            Rectangle().fill(Theme.line).frame(height: 1).padding(.top, 14).padding(.bottom, 14)
            inspector(focus).frame(height: 94, alignment: .top)
        }.frame(maxHeight: .infinity)
    }
    private func inspector(_ focus: DiskNode) -> some View {
        let node = model.activeNode ?? focus
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: node.isDirectory ? "folder" : "doc").font(.system(size: 15)).foregroundStyle(model.color(for: node))
                Text(node.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            HStack(spacing: 7) {
                Text(formattedSize(node.bytes))
                Text("·")
                Text(String(format: "이 폴더의 %.1f%%", 100 * Double(node.bytes) / Double(max(focus.bytes, 1))))
            }.font(.system(size: 11)).foregroundStyle(Theme.muted)
            HStack(spacing: 15) {
                Button { model.reveal(node) } label: { Label("Finder에서 보기", systemImage: "arrow.up.forward.square") }
                Button { model.copyPath(node) } label: { Image(systemName: "doc.on.doc") }.help("경로 복사")
            }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.accent).padding(.top, 2)
        }
    }
    private func footer(_ focus: DiskNode) -> some View {
        HStack(spacing: 12) {
            Image(systemName: model.activeNode?.isDirectory == false ? "doc" : "folder").foregroundStyle(Theme.muted)
            Text(model.activeNode?.url.path ?? focus.url.path)
                .font(.system(size: 11)).lineLimit(1).truncationMode(.middle).foregroundStyle(Theme.muted)
            Spacer(minLength: 12)
            if focus.skipped > 0 {
                Label("접근 제한 \(focus.skipped.formatted())개", systemImage: "lock")
                    .foregroundStyle(Color(red: 0.81, green: 0.66, blue: 0.88))
                    .help("macOS 권한 때문에 읽지 못한 항목입니다. 스캔 합계에서 제외됩니다.")
            }
            Text("스캔 완료 · \(Int(model.elapsed))초").foregroundStyle(Theme.muted.opacity(0.65))
        }.font(.system(size: 10)).padding(.horizontal, 26).frame(height: 44)
            .background { GlassPanel(radius: 0) }
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("OrbitDisk").font(.system(size: 30, weight: .light))
                    Text("어디에 공간을 쓰고 있는지 살펴보세요.").font(.system(size: 13)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Image(systemName: "circle.hexagongrid").font(.system(size: 37, weight: .ultraLight)).foregroundStyle(Theme.accent)
            }.padding(.bottom, 34)
            Text("디스크").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.muted).padding(.bottom, 11)
            ForEach(model.volumes) { volume in
                HStack(spacing: 17) {
                    Image(systemName: volume.url.path == "/" ? "internaldrive.fill" : "externaldrive.fill")
                        .font(.system(size: 29, weight: .light)).foregroundStyle(Theme.muted)
                    VStack(alignment: .leading, spacing: 7) {
                        HStack { Text(volume.name).font(.system(size: 14, weight: .medium)); Spacer(); Text("\(formattedSize(volume.available)) 사용 가능").font(.system(size: 11)).foregroundStyle(volume.gaugeColor) }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.07))
                                Capsule().fill(volume.gaugeColor).frame(width: geo.size.width * CGFloat(Double(volume.used) / Double(max(volume.total, 1))))
                            }
                        }.frame(height: 3)
                        Text("전체 \(formattedSize(volume.total)) · \(formattedSize(volume.used)) 사용 중").font(.system(size: 10)).foregroundStyle(Theme.muted)
                    }
                    Button("스캔") { model.start(volume.scanURL) }.buttonStyle(.bordered).controlSize(.small).padding(.leading, 12)
                }.padding(18).background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.035))).padding(.bottom, 10)
            }
            Text("자주 쓰는 폴더").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.muted).padding(.top, 24).padding(.bottom, 11)
            HStack(spacing: 12) {
                shortcut("홈 폴더", icon: "house", url: FileManager.default.homeDirectoryForCurrentUser)
                shortcut("다운로드", icon: "arrow.down.circle", url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"))
                Button { model.chooseFolder() } label: {
                    Label("폴더 선택…", systemImage: "folder.badge.plus").font(.system(size: 12))
                        .frame(maxWidth: .infinity).padding(.vertical, 17)
                        .background(RoundedRectangle(cornerRadius: 9).stroke(Theme.line, lineWidth: 1))
                }.buttonStyle(.plain).foregroundStyle(Theme.muted)
            }
            if let root = model.root {
                Button { model.overview = false } label: {
                    HStack { Image(systemName: "clock.arrow.circlepath"); Text("마지막 결과: \(root.name)"); Spacer(); Text(formattedSize(root.bytes)); Image(systemName: "chevron.right") }
                        .font(.system(size: 12)).foregroundStyle(Theme.muted).padding(.vertical, 24)
                }.buttonStyle(.plain)
            }
            Spacer(minLength: 25)
            HStack { Image(systemName: "arrow.down.doc"); Text("Finder에서 폴더를 이 창으로 끌어 놓아도 됩니다") }
                .font(.system(size: 11)).foregroundStyle(Theme.muted.opacity(0.6))
        }
        .frame(maxWidth: 750).padding(.horizontal, 48).padding(.top, 43).padding(.bottom, 33)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func shortcut(_ title: String, icon: String, url: URL) -> some View {
        Button { model.start(url) } label: {
            Label(title, systemImage: icon).font(.system(size: 12))
                .frame(maxWidth: .infinity).padding(.vertical, 17)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.045)))
        }.buttonStyle(.plain).foregroundStyle(Theme.accent)
    }
}

private enum MenuBarBadge {
    // A template image keeps the small two-line readout crisp and lets macOS
    // supply the correct foreground color for every menu bar appearance.
    static func image(bytes: Int64?, capacity: Int64, scanning: Bool) -> NSImage {
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("KB", 1e3)]
        let unit = units.first { Double(bytes ?? 0) >= $0.1 } ?? ("B", 1)
        let number = bytes.map { (Double($0) / unit.1).formatted(.number.precision(.fractionLength(unit.0 == "B" ? 0 : 1))) } ?? "—"
        let caption = bytes == nil ? (scanning ? "SCANNING" : "HOME") : "\(unit.0) · HOME"
        let numberAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: NSColor.black
        ]
        let captionAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 6.5, weight: .medium),
            .foregroundColor: NSColor.black.withAlphaComponent(0.8),
            .kern: 0.35
        ]
        let textWidth = ceil(max((number as NSString).size(withAttributes: numberAttributes).width,
                                 (caption as NSString).size(withAttributes: captionAttributes).width))
        let image = NSImage(size: NSSize(width: 20 + textWidth, height: 18), flipped: false) { _ in
            let ring = NSBezierPath(ovalIn: NSRect(x: 1, y: 2, width: 14, height: 14))
            ring.lineWidth = 1.25
            NSColor.black.withAlphaComponent(0.30).setStroke()
            ring.stroke()
            let fraction = bytes.map { min(1, max(0, Double($0) / Double(max(capacity, 1)))) } ?? 0.22
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: 8, y: 9), radius: 7, startAngle: 90,
                          endAngle: CGFloat(90 - 360 * max(fraction, 0.015)), clockwise: true)
            arc.lineWidth = 1.7
            arc.lineCapStyle = .round
            NSColor.black.setStroke()
            arc.stroke()
            NSColor.black.withAlphaComponent(scanning ? 0.4 : 0.9).setFill()
            NSBezierPath(ovalIn: NSRect(x: 6.5, y: 7.5, width: 3, height: 3)).fill()
            (number as NSString).draw(at: NSPoint(x: 20, y: 6), withAttributes: numberAttributes)
            (caption as NSString).draw(at: NSPoint(x: 20, y: -0.5), withAttributes: captionAttributes)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = bytes.map { "홈 폴더 \(formattedSize($0))" } ?? (scanning ? "홈 폴더 스캔 중" : "홈 폴더 스캔 필요")
        return image
    }
}

private struct HomeMenuView: View {
    @ObservedObject var model: DiskViewModel
    @ObservedObject var windowModel: DiskViewModel
    @Environment(\.openWindow) private var openWindow
    private let home = FileManager.default.homeDirectoryForCurrentUser
    @State private var mapViewport = MapViewport()

    var body: some View {
        ZStack {
            if let focus = model.focus {
                MapView(model: model, focus: focus, compact: true, floating: true, viewport: $mapViewport)
                    .opacity(model.scanning ? 0.3 : 1)
                    .allowsHitTesting(!model.scanning)
                    .overlay { if model.scanning { ProgressView().controlSize(.small) } }
            } else {
                emptyState.padding(.bottom, MapSurface.menuPanelHeight / 2)
            }
        }
        .frame(width: MapSurface.menuSize.width, height: MapSurface.menuSize.height)
        .background(Theme.background)
        .overlay(alignment: .top) {
            header.frame(height: 60).background { GlassPanel(radius: 0) }
        }
        .overlay(alignment: .top) {
            breadcrumbs.padding(.horizontal, 12).frame(height: 34)
                .background { GlassPanel(radius: 10) }
                .padding(.horizontal, 12).padding(.top, 70)
        }
        .overlay(alignment: .bottom) {
            details.padding(12).frame(height: MapSurface.menuPanelHeight)
                .background { GlassPanel(radius: 16) }
                .shadow(color: .black.opacity(0.2), radius: 12, y: 5)
                .padding(12)
        }
        .clipped().preferredColorScheme(.dark)
        .onAppear {
            if model.root == nil && !model.scanning { model.start(home) }
            else if let root = model.root, !model.scanning { model.open(root) }
        }
        .onDisappear { model.resetSelection() }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "chart.pie.fill").foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("OrbitDisk").font(.system(size: 14, weight: .semibold))
                Text("홈 폴더 · \(home.lastPathComponent)").font(.system(size: 10)).foregroundStyle(Theme.muted)
            }
            Spacer()
            if model.scanning {
                SmallIconButton(symbol: "xmark", help: "홈 폴더 스캔 취소") { model.cancel() }
            } else {
                SmallIconButton(symbol: "arrow.clockwise", help: "홈 폴더 다시 스캔") { model.start(home) }
            }
            Menu {
                Button("Finder에서 홈 폴더 열기") { NSWorkspace.shared.open(home) }
                Divider()
                Button("OrbitDisk 종료") { NSApp.terminate(nil) }
            } label: { Image(systemName: "ellipsis").frame(width: 20, height: 24) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("OrbitDisk 메뉴")
        }.padding(.horizontal, 18)
    }

    private var breadcrumbs: some View {
        HStack(spacing: 7) {
            Button {
                if let root = model.root { model.open(root) }
            } label: { Label("홈", systemImage: "house") }
            .buttonStyle(.plain).foregroundStyle(Theme.accent)
            .disabled(model.root == nil || model.scanning)
            if let focus = model.focus, focus !== model.root {
                Image(systemName: "chevron.right").foregroundStyle(Theme.muted)
                Text(focus.name).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                SmallIconButton(symbol: "arrow.up", help: "상위 폴더") { model.up() }.disabled(model.scanning)
            } else { Spacer() }
            Text("읽힌 파일 합계").foregroundStyle(Theme.muted)
        }.font(.system(size: 11))
    }

    private var details: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text(model.hoveredSlice?.name ?? model.activeNode?.name ?? model.focus.map { $0 === model.root ? "홈 폴더" : $0.name } ?? "홈 폴더")
                    .font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Button {
                    mapViewport = MapViewport()
                    model.hover(nil)
                } label: {
                    Text("\(Int((mapViewport.scale * 100).rounded()))%")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 7).frame(height: 22)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.065)))
                }.buttonStyle(.plain).foregroundStyle(Theme.muted)
                    .help("스크롤로 확대·축소, 드래그로 이동 · 클릭하면 원래 크기와 위치로")
                    .accessibilityLabel("미니 지도 원래 크기와 위치로 복원")
                    .accessibilityValue("\(Int((mapViewport.scale * 100).rounded()))%")
                    .disabled(model.scanning)
            }.frame(height: 22)
            HStack {
                Text(model.smallItems == nil ? "용량이 큰 항목" : "작은 항목")
                Spacer()
                Text("\(model.listedItems.count.formatted())개")
            }.font(.system(size: 10)).foregroundStyle(Theme.muted)
            VStack(spacing: 1) {
                ForEach(model.listedItems.prefix(4)) { FileRow(model: model, node: $0) }
                if model.listedItems.isEmpty {
                    Text(model.scanning ? "스캔 결과를 기다리는 중" : (model.focus?.skipped ?? 0) > 0 ? "접근 권한이 필요한 폴더입니다" : "표시할 파일이 없습니다")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted).padding(.vertical, 24)
                }
            }.frame(height: 131, alignment: .top).disabled(model.scanning)
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                if model.scanning { Text("스캔 중 · \(model.scannedFiles.formatted())개 파일") }
                else if let date = model.lastScannedAt { Text("업데이트"); Text(date, style: .time) }
                else { Text("홈 폴더만 스캔합니다") }
                Spacer(minLength: 0)
                if let root = model.root, root.skipped > 0 {
                    Label("제한 \(root.skipped)개", systemImage: "lock")
                        .help("읽지 못한 항목은 합계에서 제외됩니다. 전체 디스크 사용량과 다릅니다.")
                }
            }.font(.system(size: 10)).foregroundStyle(Theme.muted)
            Rectangle().fill(Theme.line).frame(height: 1)
            Button(action: showMainWindow) {
                HStack {
                    Text("큰 창에서 보기")
                    Spacer()
                    Image(systemName: "arrow.up.forward.square")
                }.font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accent)
                    .frame(height: 32).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            if model.scanning {
                ProgressView().controlSize(.small)
                Text("홈 폴더를 살펴보는 중").font(.system(size: 15, weight: .medium))
                Text("\(model.scannedFiles.formatted())개 파일 · \(formattedSize(model.scannedBytes))")
                    .font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.accent)
                Text("메뉴를 닫아도 스캔은 계속됩니다").font(.system(size: 11)).foregroundStyle(Theme.muted)
            } else {
                Image(systemName: "house.circle").font(.system(size: 48, weight: .ultraLight)).foregroundStyle(Theme.accent)
                Text("홈 폴더의 공간을 한눈에").font(.system(size: 15, weight: .medium))
                Button("홈 폴더 스캔") { model.start(home) }.buttonStyle(.bordered)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func showMainWindow() {
        if let root = model.root {
            windowModel.showSnapshot(root, focus: model.focus, elapsed: model.elapsed, scannedAt: model.lastScannedAt)
        }
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

#if !TESTING
@MainActor
final class OrbitDiskAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set the running app's Dock image as well as its bundle icon. This
        // refreshes icons cached from earlier locally built app bundles.
        NSApp.setActivationPolicy(.regular)
        if let url = Bundle.main.url(forResource: "OrbitDisk", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
            NSApp.dockTile.display()
        }
    }
}

@main
struct OrbitDiskApp: App {
    @NSApplicationDelegateAdaptor(OrbitDiskAppDelegate.self) private var appDelegate
    @StateObject private var windowModel = DiskViewModel()
    @StateObject private var homeModel = DiskViewModel()

    var body: some Scene {
        Window("OrbitDisk", id: "main") { ContentView(model: windowModel) }
            .windowStyle(.hiddenTitleBar)
            .defaultSize(width: 1100, height: 740)
        MenuBarExtra {
            HomeMenuView(model: homeModel, windowModel: windowModel)
        } label: {
            Image(nsImage: MenuBarBadge.image(bytes: homeModel.root?.bytes,
                                             capacity: homeModel.volumes.first?.total ?? 1,
                                             scanning: homeModel.scanning))
            .help("홈 폴더에서 읽힌 파일 합계 · 원형 게이지는 디스크 전체 용량 대비 비율 · 클릭해서 자세히 보기")
            .task {
                if homeModel.root == nil && !homeModel.scanning {
                    homeModel.start(FileManager.default.homeDirectoryForCurrentUser)
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}
#endif
