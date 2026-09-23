@main
struct Checks {
    @MainActor static func main() async throws {
        func node(_ name: String, size: Int64 = 0, children: [DiskNode] = []) -> DiskNode {
            let n = DiskNode(url: URL(fileURLWithPath: "/tmp/" + name), isDirectory: !children.isEmpty)
            n.children = children.sorted { $0.bytes > $1.bytes }
            for c in n.children { c.parent = n }
            n.bytes = children.isEmpty ? size : children.reduce(0) { $0 + $1.bytes }
            return n
        }
        let leaves = (0..<700).map { node("small\($0)", size: 1) }
        let folder = node("folder", children: [node("large", size: 1_000_000)] + leaves)
        let root = node("root", children: [folder, node("second", size: 500_000)])
        let slices = RingLayout.make(root)
        let top = slices.filter { $0.depth == 0 }
        precondition(abs(top.reduce(0) { $0 + $1.end - $1.start } - 2 * .pi) < 0.000001)
        precondition(top.reduce(0) { $0 + $1.bytes } == root.bytes)
        let tail = slices.first { !$0.smallItems.isEmpty }!
        precondition(tail.smallItems.count == 700 && tail.bytes == 700)
        let size = CGSize(width: 600, height: 600)
        for slice in slices where slice.end - slice.start > 0.000001 {
            let a = (slice.start + slice.end) / 2
            let r = 300 * (RingLayout.boundaries[slice.depth] + RingLayout.boundaries[slice.depth + 1]) / 2
            let p = CGPoint(x: 300 + r * cos(a), y: 300 + r * sin(a))
            precondition(RingLayout.hit(p, size: size, slices: slices)?.id == slice.id)
            precondition(RingLayout.path(slice, size: size).contains(p))
        }
        precondition(RingLayout.hit(CGPoint(x: 300, y: 300), size: size, slices: slices) == nil)
        // Zoom keeps the pointer's map coordinate fixed; inverse mapping preserves hit targets after pan.
        var viewport = MapViewport()
        let anchor = CGPoint(x: 410, y: 245)
        let originalPoint = viewport.mapPoint(anchor, size: size)
        viewport.zoom(by: 2.5, at: anchor, size: size)
        let anchoredPoint = viewport.mapPoint(anchor, size: size)
        precondition(hypot(originalPoint.x - anchoredPoint.x, originalPoint.y - anchoredPoint.y) < 0.000001)
        viewport.pan(by: CGSize(width: 75, height: -30), size: size)
        for slice in slices where slice.end - slice.start > 0.000001 {
            let angle = (slice.start + slice.end) / 2
            let radius = 300 * (RingLayout.boundaries[slice.depth] + RingLayout.boundaries[slice.depth + 1]) / 2
            let screenPoint = CGPoint(x: 300 + radius * cos(angle) * viewport.scale + viewport.offset.width,
                                      y: 300 + radius * sin(angle) * viewport.scale + viewport.offset.height)
            precondition(RingLayout.hit(viewport.mapPoint(screenPoint, size: size), size: size, slices: slices)?.id == slice.id)
        }
        viewport.zoom(by: 100, at: anchor, size: size)
        precondition(viewport.scale == MapViewport.limits.upperBound)
        viewport.zoom(by: 0.0001, at: anchor, size: size)
        precondition(viewport.scale == MapViewport.limits.lowerBound)
        viewport.pan(by: CGSize(width: 1e6, height: -1e6), size: size)
        precondition(abs(viewport.offset.width) <= 402 && abs(viewport.offset.height) <= 402)
        precondition(hypot(max(0, abs(viewport.offset.width) - 300), max(0, abs(viewport.offset.height) - 300)) <= 150 * RingLayout.boundaries.last! - 48 + 0.000001)
        let constrained = viewport
        viewport.zoom(by: .infinity, at: anchor, size: size)
        precondition(viewport.scale == constrained.scale && viewport.offset == constrained.offset)
        viewport = MapViewport()
        precondition(viewport.scale == 1 && viewport.offset == .zero)
        let compactSize = CGSize(width: 264, height: 264)
        let compactSlices = slices.filter { $0.depth < RingLayout.compactBoundaries.count - 1 }
        for slice in compactSlices {
            let angle = (slice.start + slice.end) / 2
            let radius = 132 * (RingLayout.compactBoundaries[slice.depth] + RingLayout.compactBoundaries[slice.depth + 1]) / 2
            let point = CGPoint(x: 132 + radius * cos(angle), y: 132 + radius * sin(angle))
            precondition(RingLayout.hit(point, size: compactSize, slices: compactSlices, boundaries: RingLayout.compactBoundaries)?.id == slice.id)
            precondition(RingLayout.path(slice, size: compactSize, boundaries: RingLayout.compactBoundaries).contains(point))
        }
        precondition(RingLayout.hit(CGPoint(x: 132, y: 132), size: compactSize, slices: compactSlices, boundaries: RingLayout.compactBoundaries) == nil)
        var chain = node("end", size: 100)
        for i in 0..<10 { chain = node("depth\(i)", children: [chain]) }
        precondition(RingLayout.make(chain).count == 7)
        let namedFolder = node("Downloads-and-프로젝트-자료", children: [node("contents", size: 100)])
        var labelCount = 0
        for compact in [false, true] {
            let bounds = compact ? RingLayout.compactBoundaries : RingLayout.boundaries
            let canvasSize = CGSize(width: compact ? 236 : 600, height: compact ? 236 : 600)
            let labelFolder = compact ? node("Library", children: [node("contents", size: 100)]) : namedFolder
            var surfaceLabels = 0
            for depth in 0..<(bounds.count - 1) {
                for span in [0.015, 0.12, 0.5, 1.2, 4.0, 2 * Double.pi] {
                    for start in stride(from: 0.0, through: 2 * .pi - span, by: 0.4) {
                        let slice = RingSlice(id: "label", node: labelFolder, parent: root, smallItems: [], bytes: 100,
                                              depth: depth, start: start, end: start + span)
                        guard let label = RingLabels.place(slice, size: canvasSize, boundaries: bounds, compact: compact) else { continue }
                        precondition(abs(label.rotation) <= .pi / 2 + 0.000001)
                        let path = RingLayout.path(slice, size: canvasSize, boundaries: bounds)
                        for x in [-label.measuredSize.width / 2, label.measuredSize.width / 2] {
                            for y in [-label.measuredSize.height / 2, label.measuredSize.height / 2] {
                                let point = CGPoint(x: label.center.x + x * cos(label.rotation) - y * sin(label.rotation),
                                                    y: label.center.y + x * sin(label.rotation) + y * cos(label.rotation))
                                precondition(path.contains(point), "Label crosses slice boundary")
                            }
                        }
                        surfaceLabels += 1
                    }
                }
            }
            precondition(surfaceLabels > 0)
            labelCount += surfaceLabels
        }
        let tiny = RingSlice(id: "tiny", node: namedFolder, parent: root, smallItems: [], bytes: 1, depth: 0, start: 0, end: 0.01)
        precondition(RingLabels.place(tiny, size: size, boundaries: RingLayout.boundaries, compact: false) == nil)
        // A previously hidden name must appear once zoom creates enough room, without enlarging the font.
        let zoomFolder = node("Library", children: [node("item", size: 100)])
        let zoomSlice = RingSlice(id: "zoom-label", node: zoomFolder, parent: root, smallItems: [], bytes: 100,
                                  depth: 4, start: 0.2, end: 0.32)
        precondition(RingLabels.place(zoomSlice, size: CGSize(width: 900, height: 600), boundaries: RingLayout.boundaries, compact: false) == nil)
        let zoomLabel = RingLabels.place(zoomSlice, size: CGSize(width: 2700, height: 1800), boundaries: RingLayout.boundaries, compact: false)!
        precondition(zoomLabel.text == "Library" && zoomLabel.fontSize < 13)
        let fullName = RingLabels.place(RingSlice(id: "full-name", node: namedFolder, parent: root, smallItems: [], bytes: 100,
                                                 depth: 1, start: 0.2, end: 0.7),
                                       size: CGSize(width: 3600, height: 2400), boundaries: RingLayout.boundaries, compact: false)!
        precondition(fullName.text == namedFolder.name)
        let wideSize = CGSize(width: 950, height: 600)
        var wideViewport = MapViewport()
        let wideAnchor = CGPoint(x: 750, y: 210)
        wideViewport.zoom(by: 3, at: wideAnchor, size: wideSize)
        precondition(hypot(wideViewport.mapPoint(wideAnchor, size: wideSize).x - wideAnchor.x,
                           wideViewport.mapPoint(wideAnchor, size: wideSize).y - wideAnchor.y) < 0.000001)
        // The floating canvas covers the full window, while initial framing leaves room for the sidebar.
        let surface = MapSurface(size: CGSize(width: 1380, height: 876), floating: true)
        let canvasCenter = CGPoint(x: surface.mapFrame.midX, y: surface.mapFrame.midY)
        let framedCenter = MapViewport().mapPoint(surface.localPoint(canvasCenter), size: surface.mapFrame.size)
        precondition(abs(framedCenter.x - surface.mapFrame.width / 2) < 0.000001)
        precondition(abs(framedCenter.y - surface.mapFrame.height / 2) < 0.000001)
        let outsideOldFrame = CGPoint(x: 5, y: 350)
        precondition(!surface.mapFrame.contains(outsideOldFrame))
        precondition(!surface.blockedRects.contains { $0.contains(outsideOldFrame) })
        precondition(surface.blockedRects.contains { $0.contains(CGPoint(x: 1200, y: 400)) })
        let compactSurface = MapSurface(size: compactSize, floating: false)
        precondition(compactSurface.mapFrame == CGRect(origin: .zero, size: compactSize) && compactSurface.blockedRects.isEmpty)
        let model = DiskViewModel()
        model.root = root
        model.open(root)
        model.open(folder)
        precondition(model.canBack && model.breadcrumbs.count == 2)
        model.back()
        precondition(model.focus === root && model.canForward)
        model.forward()
        precondition(model.focus === folder)
        model.up()
        precondition(model.focus === root)
        model.activate(tail)
        precondition(model.focus === folder && model.listedItems.count == 700)
        model.query = "small123"
        precondition(model.listedItems.count == 1)
        let fixture = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/scan-check-fixture")
        try FileManager.default.createDirectory(at: fixture.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try Data(repeating: 0x55, count: 8192).write(to: fixture.appendingPathComponent("nested/data.bin"))
        if !FileManager.default.fileExists(atPath: fixture.appendingPathComponent("loop").path) {
            try FileManager.default.createSymbolicLink(at: fixture.appendingPathComponent("loop"), withDestinationURL: fixture)
        }
        let scan = FolderScanner.scan(fixture, handle: ScanHandle()) { _,_,_ in }!
        precondition(scan.fileCount == 2)
        precondition(scan.children.allSatisfy { $0.parent === scan })
        precondition(scan.bytes == scan.children.reduce(0) { $0 + $1.bytes })
        let cancelled = ScanHandle(); cancelled.cancel()
        precondition(FolderScanner.scan(fixture, handle: cancelled) { _,_,_ in } == nil)
        let menuModel = DiskViewModel()
        let scannedAt = Date()
        menuModel.showSnapshot(root, focus: folder, elapsed: 5, scannedAt: scannedAt)
        model.start(fixture)
        model.showSnapshot(root, focus: folder, elapsed: menuModel.elapsed, scannedAt: menuModel.lastScannedAt)
        precondition(model.root === root && model.focus === folder && model.canBack)
        model.up()
        precondition(menuModel.focus === folder && model.focus === root)
        try await Task.sleep(nanoseconds: 300_000_000)
        precondition(!model.scanning && model.root === root && model.lastScannedAt == scannedAt)
        precondition(model.scanURL == root.url)
        print("PASS: angular coverage, aggregation, full/compact hit testing, zoom anchor and transformed hit testing, adaptive zoom labels, floating canvas framing, \(labelCount) label bounds and orientations, history, scanner, cancellation, shared snapshots")
    }
}
