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
    static func hit(_ point: CGPoint, size: CGSize, slices: [RingSlice]) -> RingSlice? {
        let radius = min(size.width, size.height) / 2
        let dx = point.x - size.width / 2, dy = point.y - size.height / 2
        let distance = hypot(dx, dy) / radius
        guard let depth = (0..<7).first(where: { distance >= boundaries[$0] && distance < boundaries[$0 + 1] }) else { return nil }
        let raw = atan2(dy, dx)
        let angle = raw < 0 ? raw + 2 * .pi : raw
        return slices.first { $0.depth == depth && angle >= $0.start && angle < $0.end }
    }
    static func path(_ slice: RingSlice, size: CGSize) -> Path {
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
                    self.root = result
                    self.history = []
                    self.historyIndex = -1
                    self.open(result)
                    self.overview = false
                    self.elapsed = Date().timeIntervalSince(started)
                    self.volumes = DiskVolume.load()
                    self.status = "스캔 완료"
                } else { self.status = "스캔 취소됨" }
            }
        }
    }
    func cancel() { handle?.cancel() }
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

private struct MapView: View {
    @ObservedObject var model: DiskViewModel
    let focus: DiskNode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var displayedBytes: Int64 { model.hoveredSlice?.bytes ?? model.activeNode?.bytes ?? focus.bytes }
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Canvas { context, size in
                    let active = model.activeNode
                    for slice in model.slices {
                        let path = RingLayout.path(slice, size: size)
                        let related = active == nil || slice.node.map { $0.isRelated(to: active!) } == true
                        var layer = context
                        layer.opacity = related || model.hoveredSlice?.id == slice.id ? 1 : 0.28
                        layer.fill(path, with: .color(slice.color))
                        layer.stroke(path, with: .color(Theme.background.opacity(0.72)), lineWidth: 0.65)
                        if (active != nil && slice.node === active) || model.hoveredSlice?.id == slice.id {
                            layer.stroke(path, with: .color(Color.white.opacity(0.85)), lineWidth: 1.35)
                        }
                    }
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location): model.hover(RingLayout.hit(location, size: geo.size, slices: model.slices))
                    case .ended: model.hover(nil)
                    }
                }
                .gesture(SpatialTapGesture().onEnded { value in
                    if let slice = RingLayout.hit(value.location, size: geo.size, slices: model.slices) {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.20)) { model.activate(slice) }
                    } else { model.resetSelection() }
                })
                .accessibilityLabel("폴더 용량 지도. 오른쪽 목록에서 각 항목을 탐색할 수 있습니다.")
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.20)) { model.up() }
                } label: {
                    VStack(spacing: 3) {
                        let parts = sizeParts(displayedBytes)
                        Text(parts.0)
                            .font(.system(size: min(23, geo.size.width * 0.038), weight: .medium, design: .rounded))
                            .minimumScaleFactor(0.65).lineLimit(1)
                        Text(parts.1).font(.system(size: 11)).foregroundStyle(Theme.muted)
                        if focus.parent != nil {
                            Image(systemName: "chevron.up").font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.muted)
                        }
                    }
                    .foregroundStyle(model.activeNode.map { model.color(for: $0) } ?? Theme.accent)
                    .frame(width: min(geo.size.width, geo.size.height) * 0.135,
                           height: min(geo.size.width, geo.size.height) * 0.135)
                    .background(Circle().fill(Theme.background))
                    .contentShape(Circle())
                }
                .buttonStyle(.plain).help(focus.parent == nil ? "현재 스캔의 시작 폴더" : "중심을 클릭하면 상위 폴더로 이동합니다")
                .accessibilityLabel(focus.parent == nil ? "현재 폴더 용량" : "상위 폴더로 이동")
            }
        }
        .aspectRatio(1, contentMode: .fit)
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
    @StateObject private var model = DiskViewModel()
    @State private var dropTarget = false
    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(Theme.line).frame(height: 1)
            if model.scanning { ScanView(model: model) }
            else if !model.overview, let focus = model.focus { workspace(focus) }
            else { overview }
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
        .background(Theme.toolbar)
    }
    private func workspace(_ focus: DiskNode) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 18) {
                VStack(spacing: 5) {
                    HStack {
                        Text("SPACE MAP").font(.system(size: 10, weight: .semibold)).tracking(2).foregroundStyle(Theme.muted.opacity(0.65))
                        Spacer()
                        Text("최대 7단계").font(.system(size: 10)).foregroundStyle(Theme.muted.opacity(0.65))
                    }.padding(.horizontal, 24).padding(.top, 8)
                    Spacer(minLength: 0)
                    if focus.bytes > 0 {
                        MapView(model: model, focus: focus)
                            .id(focus.id).transition(.opacity.combined(with: .scale(scale: 0.95)))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: focus.skipped > 0 ? "lock" : "folder").font(.system(size: 35, weight: .light))
                            Text(focus.skipped > 0 ? "이 폴더에 접근할 수 없습니다" : "표시할 파일이 없습니다").font(.subheadline)
                        }.foregroundStyle(Theme.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 18) {
                        Label("조각을 눌러 폴더 열기", systemImage: "cursorarrow")
                        Label("중심을 눌러 위로", systemImage: "arrow.up")
                    }.font(.system(size: 10)).foregroundStyle(Theme.muted.opacity(0.75)).padding(.bottom, 12)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                sidebar(focus).frame(width: 316).padding(.top, 7).padding(.trailing, 12)
            }.padding(.horizontal, 22).padding(.top, 21).padding(.bottom, 12)
            footer(focus)
        }
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
            .background(Theme.toolbar.opacity(0.65))
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

#if !TESTING
@main
struct OrbitDiskApp: App {
    var body: some Scene {
        WindowGroup("OrbitDisk") { ContentView() }
            .windowStyle(.hiddenTitleBar)
            .defaultSize(width: 1100, height: 740)
    }
}
#endif
