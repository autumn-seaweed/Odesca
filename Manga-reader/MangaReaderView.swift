//
//  MangaReaderView.swift
//  Manga-reader
//
//  Created by Aki Toyoshima on 2026/02/09.
//

import Foundation
import SwiftUI
import AppKit
import ImageIO
import IOSurface
import Combine

// Page orientation (wide vs tall) keyed by path — populated during decode so the
// two-page layout never has to read image headers on the main thread.
final class OrientationCache {
    static let shared: NSCache<NSString, NSNumber> = {
        let c = NSCache<NSString, NSNumber>(); c.countLimit = 4000; return c
    }()
}

// Global Cache for the Reader. Pages are held as IOSurfaces: a CALayer can show
// one directly (`layer.contents = surface`) with no copy at commit time, so a
// page turn costs a pointer swap instead of a multi-MB bitmap upload.
class ReaderCache {
    static let shared = NSCache<NSURL, IOSurface>()

    /// Longest-edge pixel size we decode pages at — matched to the display so we
    /// never hold (or upload to the GPU) a bitmap larger than what can be shown.
    /// In two-page mode each page only gets half the width, so a generous cap here
    /// is wasteful: it bloats memory and makes each turn a big main-thread texture
    /// upload. Cap at ~2000px, which is plenty for fit-to-height reading.
    static let targetPixelSize: CGFloat = {
        let screen = NSScreen.main
        let heightPoints = screen?.frame.height ?? 1200
        let scale = screen?.backingScaleFactor ?? 2
        return min(heightPoints * scale, 2000)
    }()

    static func configure() {
        // Each page is ~10 MB of pixels; keep a bounded sliding window.
        shared.totalCostLimit = 512 * 1024 * 1024
        shared.countLimit = 30
        PageDiskCache.shared.trim()  // keep the on-disk render cache bounded
        ArchiveExtractor.trim()      // keep extracted archives bounded
    }

    /// Loads a page into the in-memory cache if it isn't already there.
    /// Returns true only when this call decoded it (i.e. it just became available).
    @discardableResult
    static func cachePage(_ url: URL) -> Bool {
        if shared.object(forKey: url as NSURL) != nil { return false }
        guard let cg = decode(url), let surface = makeSurface(cg) else { return false }
        shared.setObject(surface, forKey: url as NSURL, cost: surface.allocationSize)
        return true
    }

    /// Returns a downsampled image. Checks the persistent on-disk render cache
    /// first so an expensive AVIF/WebP page is only ever decoded from source
    /// once; thereafter it loads a small fast JPEG.
    static func decode(_ url: URL) -> CGImage? {
        if let cached = PageDiskCache.shared.load(for: url) { return cached }
        guard let cg = downsample(url) else { return nil }
        OrientationCache.shared.setObject(NSNumber(value: cg.width > cg.height), forKey: url.path as NSString)
        PageDiskCache.shared.store(cg, for: url) // async write for next time
        return cg
    }

    /// Renders `cg` into a BGRA IOSurface — the format the window server
    /// composites from directly — so nothing is converted on the main thread.
    private static func makeSurface(_ cg: CGImage) -> IOSurface? {
        let w = cg.width, h = cg.height
        guard let surface = IOSurface(properties: [
            .width: w, .height: h, .bytesPerElement: 4,
            .pixelFormat: 0x42475241 // 'BGRA'
        ]) else { return nil }
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        surface.lock(options: [], seed: nil)
        defer { surface.unlock(options: [], seed: nil) }
        guard let ctx = CGContext(data: surface.baseAddress, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: surface.bytesPerRow, space: srgb,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        if let plist = srgb.copyPropertyList() { IOSurfaceSetValue(surface, kIOSurfaceColorSpace, plist) }
        return surface
    }

    /// Decodes `url` downsampled to `targetPixelSize` on its longest edge via
    /// ImageIO. `ShouldCacheImmediately` forces the (CPU-bound, for AVIF/WebP)
    /// decode to happen now, on whatever background thread we're called from.
    private static func downsample(_ url: URL) -> CGImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: targetPixelSize
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return cg
    }
}

// --- PERSISTENT ON-DISK PAGE RENDER CACHE ---
// Decoding AVIF/WebP from source is CPU-only and slow. We pay that cost once,
// then store a downsampled JPEG keyed by the source's path + size + mtime (+ the
// display's target size). Subsequent reads decode a tiny JPEG in a few ms.
final class PageDiskCache {
    static let shared = PageDiskCache()
    private let fm = FileManager.default
    private let dir: URL?
    private let byteBudget = 1_500 * 1024 * 1024 // ~1.5 GB ceiling

    init() {
        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let d = appSupport.appendingPathComponent("PageCache", isDirectory: true)
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
            self.dir = d
        } else {
            self.dir = nil
        }
    }

    // Deterministic (FNV-1a) hash — Swift's Hasher is per-process seeded, so it
    // can't be used for a key that must survive across launches.
    private func stableHash(_ s: String) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in s.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return String(hash, radix: 16)
    }

    private func fileURL(for url: URL) -> URL? {
        let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = vals?.fileSize ?? 0
        let mtime = Int(vals?.contentModificationDate?.timeIntervalSince1970 ?? 0)
        let target = Int(ReaderCache.targetPixelSize)
        let key = stableHash("\(url.path)|\(size)|\(mtime)|\(target)")
        return dir?.appendingPathComponent(key).appendingPathExtension("jpg")
    }

    func exists(for url: URL) -> Bool {
        guard let f = fileURL(for: url) else { return false }
        return fm.fileExists(atPath: f.path)
    }

    func load(for url: URL) -> CGImage? {
        guard let f = fileURL(for: url), fm.fileExists(atPath: f.path),
              let src = CGImageSourceCreateWithURL(f as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        return cg
    }

    func store(_ cg: CGImage, for url: URL) {
        guard let f = fileURL(for: url) else { return }
        Task.detached(priority: .background) {
            let rep = NSBitmapImageRep(cgImage: cg)
            guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else { return }
            try? data.write(to: f)
        }
    }

    /// Evict oldest renders when the cache outgrows its budget.
    func trim() {
        guard let dir else { return }
        Task.detached(priority: .background) {
            let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
            guard let files = try? self.fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(keys)) else { return }
            var infos = files.compactMap { url -> (URL, Int, Date)? in
                guard let v = try? url.resourceValues(forKeys: keys) else { return nil }
                return (url, v.fileSize ?? 0, v.contentModificationDate ?? .distantPast)
            }
            var total = infos.reduce(0) { $0 + $1.1 }
            guard total > self.byteBudget else { return }
            infos.sort { $0.2 < $1.2 } // oldest first
            for (url, size, _) in infos {
                if total <= self.byteBudget { break }
                try? self.fm.removeItem(at: url)
                total -= size
            }
        }
    }
}

// Extracts archives (epub/zip/cbz) once to a stable, reused location keyed by the
// archive's path + size + mtime. Stable page paths mean the persistent page cache
// actually hits across sessions, and reopening skips the unzip entirely.
enum ArchiveExtractor {
    private static let imageExts: Set<String> = ["jpg", "jpeg", "png", "avif", "webp"]

    private static let root: URL? = {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = appSupport.appendingPathComponent("ExtractedArchives", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func dir(for archive: URL) -> URL? {
        let vals = try? archive.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = vals?.fileSize ?? 0
        let mtime = Int(vals?.contentModificationDate?.timeIntervalSince1970 ?? 0)
        return root?.appendingPathComponent(stableCacheID("\(archive.path)|\(size)|\(mtime)"), isDirectory: true)
    }

    private static func images(in directory: URL) -> [URL] {
        let fm = FileManager.default
        var found: [URL] = []
        if let e = fm.enumerator(at: directory, includingPropertiesForKeys: nil) {
            for case let f as URL in e where imageExts.contains(f.pathExtension.lowercased())
                && !f.lastPathComponent.hasPrefix(".") && !f.path.contains("__MACOSX") {
                found.append(f)
            }
        }
        return found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Returns the archive's image pages, extracting only if not already cached.
    static func pages(for archive: URL) -> [URL] {
        let fm = FileManager.default
        guard let dir = dir(for: archive) else { return [] }

        if fm.fileExists(atPath: dir.path) {
            let existing = images(in: dir)
            if !existing.isEmpty {
                try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: dir.path) // mark recently used
                return existing
            }
        }

        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", "-o", archive.path, "-d", dir.path]
        try? process.run()
        process.waitUntilExit()
        return images(in: dir)
    }

    /// Keep only the most-recently-used extracted archives.
    static func trim(keep: Int = 12) {
        guard let root else { return }
        DispatchQueue.global(qos: .background).async {
            let fm = FileManager.default
            guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
            let sorted = dirs.sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
            for dir in sorted.dropFirst(keep) { try? fm.removeItem(at: dir) }
        }
    }
}

struct MangaReaderView: View {
    let volumeURL: URL
    @Bindable var manga: MangaSeries

    // Needed for ESC key to work
    @Environment(\.dismiss) var dismiss

    // --- STATE ---
    // Page position lives in the controller, not in @State: a page turn never
    // invalidates this view, so SwiftUI (toolbar, focused values, overlays) does
    // no work at all — the controller swaps layer contents directly.
    @State private var controller = ReaderController()
    @FocusState private var isFocused: Bool // Restore Focus for Arrow Keys

    // Page gallery + bookmarks UI
    @State private var showGallery = false
    @State private var showBookmarks = false

    // --- VIEW OPTIONS ---
    @AppStorage("readingDirection") private var readingDirection: ReadingDirection = .rightToLeft
    @AppStorage("isTwoPageMode") private var isTwoPageMode = false
    @AppStorage("useCoverOffset") private var useCoverOffset = true

    // --- BODY ---
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // --- LAYER 1: PAGES + PROGRESS BAR + PAGE COUNTER (one CALayer tree) ---
            ReaderCanvas(controller: controller)

            // --- LAYER 2: NAVIGATION ZONES ---
            HStack(spacing: 0) {
                Color.clear.contentShape(Rectangle()).frame(width: 80)
                    .onTapGesture { controller.turnLeft() }
                Spacer()
                Color.clear.contentShape(Rectangle()).frame(width: 80)
                    .onTapGesture { controller.turnRight() }
            }

            // --- LAYER 3: BOOKMARKS SIDE PANEL ---
            if showBookmarks {
                HStack(spacing: 0) {
                    Spacer()
                    BookmarksPanel(
                        pages: controller.pages,
                        bookmarks: bookmarkedPages,
                        position: controller.position,
                        onPick: { i in controller.go(to: i) },
                        onRemove: { i in toggleBookmark(i) },
                        onClose: { showBookmarks = false }
                    )
                    .frame(width: 250)
                    .transition(.move(edge: .trailing))
                }
            }

            // --- LAYER 4: PAGE GALLERY (full-screen) ---
            if showGallery {
                PageGalleryView(
                    pages: controller.pages,
                    current: controller.index,
                    bookmarked: Set(bookmarkedPages),
                    onPick: { i in controller.go(to: i); showGallery = false },
                    onClose: { showGallery = false }
                )
                .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true } // Re-focus on click
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .focusedValue(\.readerActions, ReaderActions(
            token: volumeURL.path,
            gallery: { showGallery.toggle() },
            bookmark: { toggleBookmark(controller.index) },
            bookmarksPanel: { showBookmarks.toggle() },
            offset: { controller.offset() },
            favorite: { manga.isFavorite.toggle() },
            markRead: { markAsRead() }
        ))
        .onAppear {
            ReaderCache.configure()
            controller.isTwoPage = isTwoPageMode
            controller.rightToLeft = readingDirection == .rightToLeft
            controller.coverOffset = useCoverOffset
            controller.bookmarks = Set(bookmarkedPages)
            controller.onSettle = { page in persistProgress(page: page) } // debounced: never write to SwiftData mid-flip
            let pages = loadPages()
            controller.open(pages, at: restoreProgress(pageCount: pages.count))
            isFocused = true
            manga.lastReadDate = Date()
        }
        .onDisappear {
            controller.close()
            persistProgress(page: controller.index) // Flush the final position
            ReaderCache.shared.removeAllObjects()   // Clear RAM when leaving
        }
        .onChange(of: isTwoPageMode) { _, v in controller.isTwoPage = v }
        .onChange(of: readingDirection) { _, v in controller.rightToLeft = v == .rightToLeft }
        .onChange(of: useCoverOffset) { _, v in controller.coverOffset = v }
        // Keyboard Handlers
        .onKeyPress(.escape) {
            if showGallery { showGallery = false; return .handled }
            if showBookmarks { showBookmarks = false; return .handled }
            dismiss()
            return .handled
        }
        // Shortcuts: gallery, bookmark, bookmarks panel, offset, favorite, mark read
        .onKeyPress("g") { showGallery.toggle(); return .handled }
        .onKeyPress("b") { toggleBookmark(controller.index); return .handled }
        .onKeyPress("l") { showBookmarks.toggle(); return .handled }
        .onKeyPress("o") { controller.offset(); return .handled }
        .onKeyPress("f") { manga.isFavorite.toggle(); return .handled }
        .onKeyPress("r") { markAsRead(); return .handled }
        .onKeyPress(.downArrow) { controller.next(); return .handled }
        .onKeyPress(.upArrow) { controller.previous(); return .handled }
        .onKeyPress(.leftArrow) { controller.turnLeft(); return .handled }
        .onKeyPress(.rightArrow) { controller.turnRight(); return .handled }
        .navigationTitle(currentTitle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: { showGallery.toggle() }) {
                    Label("All Pages", systemImage: "square.grid.2x2")
                }
                .help("Page gallery (G)")
            }
            ToolbarItem(placement: .primaryAction) {
                Picker("View Mode", selection: $isTwoPageMode) {
                    Image(systemName: "rectangle").tag(false).help("Single Page View")
                    Image(systemName: "book").tag(true).help("Two Page View")
                }
                .pickerStyle(.segmented).frame(width: 100)
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: { toggleBookmark(controller.index) }) {
                    Label("Bookmark", systemImage: "bookmark")
                }
                .help("Bookmark this page (B)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: { showBookmarks.toggle() }) {
                    Label("Bookmarks", systemImage: "bookmark.circle")
                }
                .help("Show bookmarks (L)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: { controller.offset() }) {
                    Label("Offset +1", systemImage: "arrow.forward.square")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Toggle("Show Cover Alone", isOn: $useCoverOffset)
                    Divider()
                    Picker("Direction", selection: $readingDirection) {
                        Text("Right to Left (Manga)").tag(ReadingDirection.rightToLeft)
                        Text("Left to Right (Comic)").tag(ReadingDirection.leftToRight)
                    }
                } label: { Label("Options", systemImage: "gear") }
            }
            ToolbarItem {
                Button(action: markAsRead) {
                    Label("Mark Read", systemImage: isVolumeRead ? "checkmark.circle.fill" : "circle")
                }
            }
        }
    }

    // --- HELPER PROPERTIES ---

    private var currentTitle: String { "\(manga.title)  ›  \(volumeURL.lastPathComponent)" }

    // --- BOOKMARKS ---
    private var volKey: String { manga.volumeKey(for: volumeURL) }
    private var bookmarkedPages: [Int] { manga.bookmarks[volKey] ?? [] }
    private func toggleBookmark(_ i: Int) {
        guard controller.pages.indices.contains(i) else { return }
        var b = manga.bookmarks[volKey] ?? []
        if let idx = b.firstIndex(of: i) { b.remove(at: idx) } else { b.append(i); b.sort() }
        if b.isEmpty { manga.bookmarks[volKey] = nil } else { manga.bookmarks[volKey] = b }
        controller.bookmarks = Set(b)
    }

    // --- LOADING ---

    func loadPages() -> [URL] {
        let ext = volumeURL.pathExtension.lowercased()
        if ["epub", "zip", "cbz"].contains(ext) {
            // Extracted once to a stable, reused location (no per-open temp dir),
            // so the persistent page cache hits and reopening skips the unzip.
            return ArchiveExtractor.pages(for: volumeURL)
        }
        return loadDirectory(volumeURL)
    }

    func loadDirectory(_ dir: URL) -> [URL] {
        let fm = FileManager.default
        let exts: Set<String> = ["jpg", "jpeg", "png", "avif", "webp"]

        // Fast path: loose images directly in the folder (the common case).
        let top = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let looseImages = top.filter { exts.contains($0.pathExtension.lowercased()) }
        if !looseImages.isEmpty {
            return looseImages.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
        }

        // Otherwise recurse: a volume whose pages live in chapter subfolders.
        // Sorting by full path keeps chapters — and pages within them — in order.
        var found: [URL] = []
        if let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator {
                guard exts.contains(fileURL.pathExtension.lowercased()),
                      !fileURL.lastPathComponent.hasPrefix("."),
                      !fileURL.path.contains("__MACOSX") else { continue }
                found.append(fileURL)
            }
        }
        return found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    // --- PROGRESS LOGIC ---

    func persistProgress(page: Int) {
        let volName = manga.volumeKey(for: volumeURL)
        let totalPages = controller.pages.count
        guard totalPages > 0 else { return }

        manga.lastReadDate = Date()

        if page >= totalPages - 1 {
            if !manga.readVolumes.contains(volName) { manga.readVolumes.append(volName) }
            manga.readingProgress.removeValue(forKey: volName)
            // One-shot (reading the series folder itself): the whole series is done.
            if volumeURL == manga.folderURL { manga.isFinished = true }
            return
        }

        if page > 0 { manga.readingProgress[volName] = page }
        else { manga.readingProgress.removeValue(forKey: volName) }
    }

    /// The page to open at: the saved position, unless the volume was basically finished.
    func restoreProgress(pageCount totalPages: Int) -> Int {
        let volName = manga.volumeKey(for: volumeURL)
        guard let savedPage = manga.readingProgress[volName], totalPages > 0 else { return 0 }

        let percentage = Double(savedPage) / Double(totalPages)

        if percentage < 0.95 {
            return savedPage < totalPages ? savedPage : 0
        }
        manga.readingProgress.removeValue(forKey: volName)
        return 0
    }

    var isVolumeRead: Bool { manga.readVolumes.contains(manga.volumeKey(for: volumeURL)) }

    func markAsRead() {
        let name = manga.volumeKey(for: volumeURL)
        if isVolumeRead { manga.readVolumes.removeAll { $0 == name } }
        else { manga.readVolumes.append(name) }
    }
}

// --- CURRENT PAGE, FOR THE FEW VIEWS THAT SHOW IT ---
// Only views that opt in (the bookmarks panel) observe this, so publishing on
// every turn costs nothing while they're closed.
final class ReaderPosition: ObservableObject {
    @Published var index = 0
}

// --- PAGE-TURN ENGINE ---
// Owns the page list and position outside SwiftUI. A turn computes the spread,
// hands cached IOSurfaces to the canvas, and kicks off prefetch — no view
// invalidation, no layout pass, no bitmap copies.
final class ReaderController {
    private(set) var pages: [URL] = []
    private(set) var index = 0

    var isTwoPage = false { didSet { if isTwoPage != oldValue { render() } } }
    var rightToLeft = true { didSet { if rightToLeft != oldValue { render() } } }
    var coverOffset = true { didSet { if coverOffset != oldValue { render() } } }
    var bookmarks: Set<Int> = [] { didSet { renderStatus() } }

    let position = ReaderPosition()
    /// Called with the page the reader settles on, after a pause in flipping.
    var onSettle: ((Int) -> Void)?

    private weak var canvas: ReaderCanvasView?
    private var shown: Set<URL> = []   // pages in the current spread
    private var prefetchTask: Task<Void, Never>? = nil
    private var warmTask: Task<Void, Never>? = nil
    private var settleTask: Task<Void, Never>? = nil

    func attach(_ canvas: ReaderCanvasView) {
        self.canvas = canvas
        render()
    }

    func open(_ pages: [URL], at start: Int) {
        self.pages = pages
        index = pages.indices.contains(start) ? start : 0
        position.index = index
        render()
        prefetchWindow()
        warmVolume()
    }

    func close() {
        prefetchTask?.cancel()
        warmTask?.cancel()
        settleTask?.cancel()
        onSettle = nil
    }

    // --- NAVIGATION ---

    func next() {
        guard !pages.isEmpty else { return }
        go(to: min(index + spread(at: index).step, pages.count - 1))
    }

    func previous() {
        if index == 0 { return }
        if !isTwoPage { go(to: index - 1); return }
        if coverOffset && index == 1 { go(to: 0); return }
        if isWide(pages[index - 1]) { go(to: index - 1); return }
        go(to: max(0, index - 2))
    }

    /// Arrow keys and tap zones are physical sides; which way that turns depends on reading direction.
    func turnLeft() { rightToLeft ? next() : previous() }
    func turnRight() { rightToLeft ? previous() : next() }

    func offset() { if index < pages.count - 1 { go(to: index + 1) } }

    func go(to i: Int) {
        guard pages.indices.contains(i), i != index else { return }
        index = i
        render()
        CATransaction.flush() // commit now rather than at the end of the run loop: the page appears a frame sooner
        position.index = i
        prefetchWindow()
        scheduleSettle()
    }

    // --- LAYOUT ---

    struct Spread {
        var center: URL? = nil
        var first: URL? = nil   // the current page
        var second: URL? = nil  // its facing page, if any
        var step: Int = 1
    }

    func spread(at i: Int) -> Spread {
        guard pages.indices.contains(i) else { return Spread(step: 0) }
        let current = pages[i]
        if !isTwoPage || (coverOffset && i == 0) || isWide(current) { return Spread(center: current) }
        let n = i + 1
        if n < pages.count, !isWide(pages[n]) { return Spread(first: current, second: pages[n], step: 2) }
        return Spread(first: current)
    }

    func isWide(_ url: URL) -> Bool {
        if let s = ReaderCache.shared.object(forKey: url as NSURL) { return s.width > s.height }
        if let o = OrientationCache.shared.object(forKey: url.path as NSString) { return o.boolValue }
        return Self.readOrientation(url)
    }

    /// Reads just the header dimensions — no decode — and caches the answer.
    @discardableResult
    static func readOrientation(_ url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let h = props[kCGImagePropertyPixelHeight] as? CGFloat else { return false }
        let wide = w > h
        OrientationCache.shared.setObject(NSNumber(value: wide), forKey: url.path as NSString)
        return wide
    }

    // --- RENDERING ---

    private func render() {
        guard let canvas, pages.indices.contains(index) else { return }
        let s = spread(at: index)
        if let center = s.center {
            canvas.showSingle(.page(surface(center)))
            shown = [center]
        } else {
            let left = rightToLeft ? s.second : s.first
            let right = rightToLeft ? s.first : s.second
            canvas.showSpread(left: left.map { .page(surface($0)) } ?? .hidden,
                              right: right.map { .page(surface($0)) } ?? .hidden)
            shown = Set([s.first, s.second].compactMap { $0 })
        }
        renderStatus()
    }

    private func renderStatus() {
        canvas?.setStatus(index: index, count: pages.count,
                          bookmarked: bookmarks.contains(index), rightToLeft: rightToLeft)
    }

    private func surface(_ url: URL) -> IOSurface? { ReaderCache.shared.object(forKey: url as NSURL) }

    /// A decode finished; if it belongs on screen right now, show it.
    private func pageReady(_ url: URL) {
        if shown.contains(url) { render() }
    }

    // --- PREFETCH ---

    func prefetchWindow() {
        guard pages.indices.contains(index) else { return }

        // Cancel any in-flight prefetch so fast flipping doesn't pile up decode jobs.
        prefetchTask?.cancel()

        let lo = max(0, index - 2)
        let hi = min(pages.count - 1, index + 10)

        // Decode the visible pages first, then fan out ahead, then behind.
        var order: [URL] = [pages[index]]
        if index + 1 <= hi { order += pages[(index + 1)...hi] }
        if lo <= index - 1 { order += pages[lo...(index - 1)].reversed() }

        // AVIF/WebP decode is CPU-bound, so concurrency is what lets prefetch
        // keep up with fast flipping.
        prefetchTask = Task.detached(priority: .userInitiated) { [weak self] in
            let limit = max(2, min(6, ProcessInfo.processInfo.activeProcessorCount - 1))
            await withTaskGroup(of: URL?.self) { group in
                var next = 0
                func addNext() {
                    guard next < order.count else { return }
                    let url = order[next]; next += 1
                    group.addTask { !Task.isCancelled && ReaderCache.cachePage(url) ? url : nil }
                }
                for _ in 0..<min(limit, order.count) { addNext() }
                for await done in group {
                    // Only fresh decodes can change what's on screen (cache hits were
                    // already shown) — and even a cancelled window's may be visible now.
                    if let done { await self?.pageReady(done) }
                    if !Task.isCancelled { addNext() }
                }
            }
        }
    }

    /// Fill the persistent disk cache for every page in the volume at low priority,
    /// so after a few seconds a first read (and every later open) is served from the
    /// fast JPEG cache instead of slow source decodes. Skips pages already cached.
    /// Page orientations are read first so two-page layout never touches disk on a turn.
    func warmVolume() {
        warmTask?.cancel()
        let all = pages
        warmTask = Task.detached(priority: .utility) {
            for url in all where OrientationCache.shared.object(forKey: url.path as NSString) == nil {
                if Task.isCancelled { return }
                ReaderController.readOrientation(url)
            }
            await withTaskGroup(of: Void.self) { group in
                let limit = 2 // gentle — yields to the window prefetch and main thread
                var next = 0
                func addNext() {
                    while next < all.count {
                        let url = all[next]; next += 1
                        if PageDiskCache.shared.exists(for: url) { continue } // already warm
                        group.addTask {
                            guard !Task.isCancelled,
                                  ReaderCache.shared.object(forKey: url as NSURL) == nil else { return }
                            _ = ReaderCache.decode(url) // decodes → writes disk cache; image discarded (no RAM churn)
                        }
                        return
                    }
                }
                for _ in 0..<limit { addNext() }
                while await group.next() != nil { if Task.isCancelled { break }; addNext() }
            }
        }
    }

    /// Debounce model writes so rapid page turns don't each trigger a SwiftData
    /// mutation (which would refresh library queries mid-flip). Only the page you
    /// land on — after a brief pause — gets persisted.
    private func scheduleSettle() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            self.onSettle?(self.index)
        }
    }
}

// --- LAYER-BACKED PAGE CANVAS ---
// A layer-hosting NSView: we own the CALayer tree and AppKit never redraws it.
// Showing a page is `layer.contents = surface` inside a no-animation transaction.
// The progress bar and page counter live here too, so turns never touch SwiftUI.
struct ReaderCanvas: NSViewRepresentable {
    let controller: ReaderController

    func makeNSView(context: Context) -> ReaderCanvasView {
        let view = ReaderCanvasView()
        controller.attach(view)
        return view
    }

    func updateNSView(_ view: ReaderCanvasView, context: Context) {}
}

final class ReaderCanvasView: NSView {
    enum Slot {
        case hidden                 // empty half of a spread
        case page(IOSurface?)       // nil = not decoded yet: keep showing what's there
    }

    private let primary = CALayer()    // the single page, or the left half of a spread
    private let secondary = CALayer()  // the right half of a spread
    private var primarySize = CGSize.zero
    private var secondarySize = CGSize.zero
    private var isSpread = false

    private let track = CALayer()
    private let fill = CALayer()
    private let badge = CALayer()
    private let label = CATextLayer()
    private let mark = CALayer()
    private let font = NSFont.monospacedDigitSystemFont(
        ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)
    private var status = (index: 0, count: 0, bookmarked: false, rightToLeft: true)
    private var measuredLength = -1
    private var measuredSize = CGSize.zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        layer = root
        wantsLayer = true

        for page in [primary, secondary] {
            page.contentsGravity = .resize // frames are already aspect-fit
            page.isHidden = true
            root.addSublayer(page)
        }

        track.backgroundColor = NSColor.white.withAlphaComponent(0.3).cgColor
        fill.backgroundColor = (NSColor(named: "AccentColor") ?? .controlAccentColor).cgColor
        badge.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        label.font = font
        label.fontSize = font.pointSize
        label.foregroundColor = NSColor.white.withAlphaComponent(0.75).cgColor
        let symbol = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular)
            .applying(.init(paletteColors: [.systemYellow]))
        mark.contents = NSImage(systemSymbolName: "bookmark.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(symbol)
        mark.contentsGravity = .resizeAspect
        mark.isHidden = true
        root.addSublayer(track)
        root.addSublayer(fill)
        root.addSublayer(badge)
        badge.addSublayer(mark)
        badge.addSublayer(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Clicks fall through to the SwiftUI tap zones and focus handling above us.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        withoutAnimation { layoutPages(); layoutStatus() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        label.contentsScale = scale
        mark.contentsScale = scale
    }

    // --- PAGES ---

    func showSingle(_ page: Slot) {
        withoutAnimation {
            isSpread = false
            apply(page, to: primary, size: &primarySize)
            secondary.isHidden = true
            layoutPages()
        }
    }

    func showSpread(left: Slot, right: Slot) {
        withoutAnimation {
            isSpread = true
            apply(left, to: primary, size: &primarySize)
            apply(right, to: secondary, size: &secondarySize)
            layoutPages()
        }
    }

    private func apply(_ slot: Slot, to page: CALayer, size: inout CGSize) {
        switch slot {
        case .hidden:
            page.isHidden = true
        case .page(let surface?):
            if (page.contents as AnyObject?) !== surface {
                page.contents = surface
                size = CGSize(width: surface.width, height: surface.height)
            }
            page.isHidden = false
        case .page(nil):
            page.isHidden = page.contents == nil
        }
    }

    private func layoutPages() {
        let b = bounds
        if isSpread {
            let half = b.width / 2
            // Pages meet at the spine: left page hugs its right edge, right page its left.
            place(primary, primarySize, in: CGRect(x: 0, y: 0, width: half, height: b.height), align: 1)
            place(secondary, secondarySize, in: CGRect(x: half, y: 0, width: half, height: b.height), align: 0)
        } else {
            place(primary, primarySize, in: b, align: 0.5)
        }
    }

    /// Aspect-fits `size` into `rect`; `align` positions it horizontally (0 left … 1 right).
    private func place(_ page: CALayer, _ size: CGSize, in rect: CGRect, align: CGFloat) {
        guard size.width > 0, size.height > 0, rect.width > 0, rect.height > 0 else { return }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let w = size.width * scale, h = size.height * scale
        let frame = CGRect(x: rect.minX + (rect.width - w) * align, y: rect.minY + (rect.height - h) / 2,
                           width: w, height: h)
        page.frame = backingAlignedRect(frame, options: .alignAllEdgesNearest)
    }

    // --- PROGRESS BAR + PAGE COUNTER ---

    func setStatus(index: Int, count: Int, bookmarked: Bool, rightToLeft: Bool) {
        status = (index, count, bookmarked, rightToLeft)
        withoutAnimation {
            label.string = "\(index + 1) / \(count)"
            mark.isHidden = !bookmarked
            layoutStatus()
        }
    }

    private func layoutStatus() {
        let b = bounds
        // Progress bar fills from the side you read toward.
        let frac = min(1, CGFloat(status.index + 1) / CGFloat(max(1, status.count)))
        let barWidth = b.width * frac
        track.frame = CGRect(x: 0, y: 0, width: b.width, height: 3)
        fill.frame = CGRect(x: status.rightToLeft ? b.width - barWidth : 0, y: 0, width: barWidth, height: 3)

        let text = (label.string as? String) ?? ""
        // Digits are monospaced, so the label's size only changes with its length.
        if text.count != measuredLength {
            measuredSize = (text as NSString).size(withAttributes: [.font: font])
            measuredLength = text.count
        }
        let textW = ceil(measuredSize.width), textH = ceil(measuredSize.height)
        let markW: CGFloat = status.bookmarked ? textH * 0.8 : 0
        let gap: CGFloat = status.bookmarked ? 6 : 0
        let height = textH + 8
        let width = 10 + markW + gap + textW + 10
        badge.frame = CGRect(x: b.width - 14 - width, y: 14, width: width, height: height)
        badge.cornerRadius = height / 2
        mark.frame = CGRect(x: 10, y: 4, width: markW, height: textH)
        label.frame = CGRect(x: 10 + markW + gap, y: 4, width: textW, height: textH)
    }

    private func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}

// --- SMALL THUMBNAILS FOR THE PAGE GALLERY / BOOKMARKS ---
final class ReaderThumbCache {
    static let shared: NSCache<NSURL, NSImage> = {
        let c = NSCache<NSURL, NSImage>(); c.countLimit = 500; return c
    }()
    static func thumb(_ url: URL) -> NSImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 360
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
    }
}

struct ReaderThumb: View {
    let url: URL
    @State private var img: NSImage?
    var body: some View {
        ZStack {
            if let img {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
            } else {
                Color.white.opacity(0.06)
            }
        }
        .task(id: url) {
            if let c = ReaderThumbCache.shared.object(forKey: url as NSURL) { img = c; return }
            let t = await Task.detached(priority: .userInitiated) { ReaderThumbCache.thumb(url) }.value
            if let t {
                ReaderThumbCache.shared.setObject(t, forKey: url as NSURL)
                img = t
            }
        }
    }
}

// --- FULL-SCREEN PAGE GALLERY ---
struct PageGalleryView: View {
    let pages: [URL]
    let current: Int
    let bookmarked: Set<Int>
    let onPick: (Int) -> Void
    let onClose: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 130, maximum: 180), spacing: 16)]

    var body: some View {
        ZStack {
            Color.black.opacity(0.97).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Text("All Pages").font(.headline).foregroundStyle(.white)
                    Spacer()
                    Text("\(pages.count) pages").foregroundStyle(.white.opacity(0.6)).font(.subheadline)
                    Button(action: onClose) { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.8)).font(.title2)
                }
                .padding()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(pages.indices, id: \.self) { i in
                                VStack(spacing: 4) {
                                    ReaderThumb(url: pages[i])
                                        .frame(height: 200)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(i == current ? Color.accentColor : Color.white.opacity(0.12),
                                                        lineWidth: i == current ? 3 : 1)
                                        )
                                        .overlay(alignment: .topTrailing) {
                                            if bookmarked.contains(i) {
                                                Image(systemName: "bookmark.fill")
                                                    .foregroundStyle(.yellow).font(.caption).padding(6)
                                            }
                                        }
                                    Text("\(i + 1)").font(.caption2)
                                        .foregroundStyle(i == current ? Color.accentColor : .white.opacity(0.6))
                                }
                                .id(i)
                                .contentShape(Rectangle())
                                .onTapGesture { onPick(i) }
                            }
                        }
                        .padding()
                    }
                    .onAppear { proxy.scrollTo(current, anchor: .center) }
                }
            }
        }
    }
}

// --- BOOKMARKS SIDE PANEL ---
struct BookmarksPanel: View {
    let pages: [URL]
    let bookmarks: [Int]
    @ObservedObject var position: ReaderPosition
    let onPick: (Int) -> Void
    let onRemove: (Int) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Bookmarks").font(.headline).foregroundStyle(.white)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7))
            }
            .padding(12)
            Divider().overlay(Color.white.opacity(0.1))
            if bookmarks.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "bookmark").font(.largeTitle).foregroundStyle(.white.opacity(0.3))
                    Text("No bookmarks yet").foregroundStyle(.white.opacity(0.5)).font(.callout)
                    Text("Press B to bookmark a page").foregroundStyle(.white.opacity(0.3)).font(.caption)
                }
                .multilineTextAlignment(.center).padding()
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(bookmarks, id: \.self) { i in
                            HStack(spacing: 10) {
                                if pages.indices.contains(i) {
                                    ReaderThumb(url: pages[i])
                                        .frame(width: 44, height: 62)
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                }
                                Text("Page \(i + 1)")
                                    .foregroundStyle(i == position.index ? Color.accentColor : .white)
                                    .font(.callout)
                                Spacer()
                                Button(action: { onRemove(i) }) { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.4))
                            }
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .contentShape(Rectangle())
                            .onTapGesture { onPick(i) }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .background(Color(white: 0.12))
    }
}
