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
        print("PASS: angular coverage, aggregation, full/compact hit testing, \(labelCount) label bounds and orientations, history, scanner, cancellation, shared snapshots")
    }
}
