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

// Global Cache for the Reader
class ReaderCache {
    static let shared = NSCache<NSURL, NSImage>()

    /// Longest-edge pixel size we decode pages at — matched to the display so we
    /// never hold (or draw) a bitmap larger than what can actually be shown.
    static let targetPixelSize: CGFloat = {
        let screen = NSScreen.main
        let heightPoints = screen?.frame.height ?? 1200
        let scale = screen?.backingScaleFactor ?? 2
        // A little headroom above the screen height keeps pages crisp at fit-to-height.
        return min(heightPoints * scale * 1.1, 3200)
    }()

    /// The most recently displayed page, shared across all page views. Used as a
    /// backstop so a freshly-built (or not-yet-decoded) page view shows the last
    /// real page instead of flashing to black during a fast scrub.
    static var lastDisplayed: NSImage?

    static func configure() {
        // Downsampled pages are only a few MB each; keep a bounded sliding window.
        shared.totalCostLimit = 512 * 1024 * 1024
        shared.countLimit = 40
        PageDiskCache.shared.trim() // keep the on-disk render cache bounded
    }

    static func cost(for image: NSImage) -> Int {
        Int(image.size.width * image.size.height * 4)
    }

    /// Loads a page into the in-memory cache if it isn't already there.
    static func cachePage(_ url: URL) {
        if shared.object(forKey: url as NSURL) != nil { return }
        if let image = decode(url) {
            shared.setObject(image, forKey: url as NSURL, cost: cost(for: image))
        }
    }

    /// Returns a display-ready, downsampled image. Checks the persistent on-disk
    /// render cache first so an expensive AVIF/WebP page is only ever decoded from
    /// source once; thereafter it loads a small fast JPEG.
    static func decode(_ url: URL) -> NSImage? {
        if let cached = PageDiskCache.shared.load(for: url) { return cached }
        guard let cg = downsample(url) else { return nil }
        let image = NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
        PageDiskCache.shared.store(cg, for: url) // async write for next time
        return image
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

    func load(for url: URL) -> NSImage? {
        guard let f = fileURL(for: url), fm.fileExists(atPath: f.path),
              let src = CGImageSourceCreateWithURL(f as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
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

struct MangaReaderView: View {
    let volumeURL: URL
    @Bindable var manga: MangaSeries
    
    // Needed for ESC key to work
    @Environment(\.dismiss) var dismiss
    
    // --- STATE ---
    @State private var currentIndex = 0
    @FocusState private var isFocused: Bool // Restore Focus for Arrow Keys
    @State private var pages: [URL] = []
    
    // Track if we need to cleanup a temp folder later
    @State private var tempArchiveFolder: URL? = nil

    // The in-flight prefetch job, cancelled & rescheduled as the window slides
    @State private var prefetchTask: Task<Void, Never>? = nil

    // Debounced progress save — we never write to SwiftData mid-flip
    @State private var saveTask: Task<Void, Never>? = nil

    // Page gallery + bookmarks UI
    @State private var showGallery = false
    @State private var showBookmarks = false

    // --- VIEW OPTIONS ---
    @AppStorage("readingDirection") private var readingDirection: ReadingDirection = .rightToLeft
    @AppStorage("isTwoPageMode") private var isTwoPageMode = false
    @AppStorage("useCoverOffset") private var useCoverOffset = true

    // --- BODY ---
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                
                // 1. CALCULATE LAYOUT
                let layout = calculateLayout(for: currentIndex, in: pages)
                
                // --- LAYER 1: THE PAGES ---
                ZStack {
                    if isTwoPageMode {
                        // --- DOUBLE PAGE MODE ---
                        if let centerPage = layout.center {
                            CachedPageView(url: centerPage, size: geo.size, alignment: .center)
                        } else {
                            HStack(spacing: 0) {
                                let leftPage = readingDirection == .rightToLeft ? layout.left : layout.right
                                let rightPage = readingDirection == .rightToLeft ? layout.right : layout.left
                                
                                if let page = leftPage {
                                    CachedPageView(url: page,
                                             size: CGSize(width: geo.size.width / 2, height: geo.size.height),
                                             alignment: .trailing)
                                } else {
                                    Spacer().frame(width: geo.size.width / 2)
                                }

                                if let page = rightPage {
                                    CachedPageView(url: page,
                                             size: CGSize(width: geo.size.width / 2, height: geo.size.height),
                                             alignment: .leading)
                                } else {
                                    Spacer().frame(width: geo.size.width / 2)
                                }
                            }
                        }
                    } else {
                        // --- SINGLE PAGE MODE ---
                        if pages.indices.contains(currentIndex) {
                            let page = pages[currentIndex]
                            CachedPageView(url: page, size: geo.size, alignment: .center)
                        }
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                
                // --- LAYER 2: NAVIGATION ZONES ---
                HStack(spacing: 0) {
                    Color.clear.contentShape(Rectangle()).frame(width: 80)
                        .onTapGesture {
                            if readingDirection == .rightToLeft { navigateNext(step: isTwoPageMode ? layout.step : 1) }
                            else { navigatePrevious() }
                        }
                    Spacer()
                    Color.clear.contentShape(Rectangle()).frame(width: 80)
                        .onTapGesture {
                            if readingDirection == .rightToLeft { navigatePrevious() }
                            else { navigateNext(step: isTwoPageMode ? layout.step : 1) }
                        }
                }
                
                // --- LAYER 3: PROGRESS BAR (fills from the side you read toward) ---
                VStack {
                    Spacer()
                    GeometryReader { barGeo in
                        let frac = CGFloat(currentIndex + 1) / CGFloat(max(1, pages.count))
                        ZStack(alignment: readingDirection == .rightToLeft ? .trailing : .leading) {
                            Rectangle().fill(Color.white.opacity(0.3))
                            Rectangle().fill(Color.accentColor)
                                .frame(width: barGeo.size.width * frac)
                        }
                    }
                    .frame(height: 3)
                }
                .padding(.bottom, 0)

                // --- LAYER 4: BOOKMARKS SIDE PANEL ---
                if showBookmarks {
                    HStack(spacing: 0) {
                        Spacer()
                        BookmarksPanel(
                            pages: pages,
                            bookmarks: bookmarkedPages,
                            current: currentIndex,
                            onPick: { i in currentIndex = i },
                            onRemove: { i in toggleBookmark(i) },
                            onClose: { showBookmarks = false }
                        )
                        .frame(width: 250)
                        .transition(.move(edge: .trailing))
                    }
                }

                // --- LAYER 5: PAGE GALLERY (full-screen) ---
                if showGallery {
                    PageGalleryView(
                        pages: pages,
                        current: currentIndex,
                        bookmarked: Set(bookmarkedPages),
                        onPick: { i in currentIndex = i; showGallery = false },
                        onClose: { showGallery = false }
                    )
                    .transition(.opacity)
                }
            }
            .onTapGesture { isFocused = true } // Re-focus on click
        }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .focusedValue(\.readerActions, ReaderActions(
            gallery: { showGallery.toggle() },
            bookmark: { toggleBookmark(currentIndex) },
            bookmarksPanel: { showBookmarks.toggle() },
            offset: { if currentIndex < pages.count - 1 { currentIndex += 1 } },
            favorite: { manga.isFavorite.toggle() },
            markRead: { markAsRead() }
        ))
        .onAppear {
            ReaderCache.configure()
            loadPages()
            restoreProgress()
            isFocused = true
            manga.lastReadDate = Date()
            prefetchWindow()
        }
        .onDisappear {
            prefetchTask?.cancel()
            saveTask?.cancel()
            persistProgress(page: currentIndex) // Flush the final position
            ReaderCache.shared.removeAllObjects() // Clear RAM when leaving
            ReaderCache.lastDisplayed = nil       // Don't flash a stale page in the next volume
            if let tmp = tempArchiveFolder {
                try? FileManager.default.removeItem(at: tmp)
            }
        }
        .onChange(of: currentIndex) { _, _ in
            prefetchWindow() // Immediate: keep the next pages warm
            scheduleSave()   // Debounced: never write to SwiftData mid-flip
        }
        // Keyboard Handlers
        .onKeyPress(.escape) {
            if showGallery { showGallery = false; return .handled }
            if showBookmarks { showBookmarks = false; return .handled }
            dismiss()
            return .handled
        }
        // Shortcuts: gallery, bookmark, bookmarks panel, offset, favorite, mark read
        .onKeyPress("g") { showGallery.toggle(); return .handled }
        .onKeyPress("b") { toggleBookmark(currentIndex); return .handled }
        .onKeyPress("l") { showBookmarks.toggle(); return .handled }
        .onKeyPress("o") {
            if currentIndex < pages.count - 1 { currentIndex += 1 }
            return .handled
        }
        .onKeyPress("f") { manga.isFavorite.toggle(); return .handled }
        .onKeyPress("r") { markAsRead(); return .handled }
        .onKeyPress(.downArrow) {
            let layout = calculateLayout(for: currentIndex, in: pages)
            navigateNext(step: isTwoPageMode ? layout.step : 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            navigatePrevious()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            let layout = calculateLayout(for: currentIndex, in: pages)
            if readingDirection == .rightToLeft { navigateNext(step: isTwoPageMode ? layout.step : 1) }
            else { navigatePrevious() }
            return .handled
        }
        .onKeyPress(.rightArrow) {
            let layout = calculateLayout(for: currentIndex, in: pages)
            if readingDirection == .rightToLeft { navigatePrevious() }
            else { navigateNext(step: isTwoPageMode ? layout.step : 1) }
            return .handled
        }
        .navigationTitle(currentTitle)
        .navigationSubtitle(currentSubtitle)
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
                Button(action: { toggleBookmark(currentIndex) }) {
                    Label("Bookmark", systemImage: isBookmarked(currentIndex) ? "bookmark.fill" : "bookmark")
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
                Button(action: { if currentIndex < pages.count - 1 { currentIndex += 1 } }) {
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
    private var currentSubtitle: String {
        guard pages.indices.contains(currentIndex) else { return "" }
        return "\(pages[currentIndex].lastPathComponent)   (\(currentIndex + 1) / \(pages.count))"
    }

    // --- BOOKMARKS ---
    private var volKey: String { manga.volumeKey(for: volumeURL) }
    private var bookmarkedPages: [Int] { manga.bookmarks[volKey] ?? [] }
    private func isBookmarked(_ i: Int) -> Bool { bookmarkedPages.contains(i) }
    private func toggleBookmark(_ i: Int) {
        guard pages.indices.contains(i) else { return }
        var b = manga.bookmarks[volKey] ?? []
        if let idx = b.firstIndex(of: i) { b.remove(at: idx) } else { b.append(i); b.sort() }
        if b.isEmpty { manga.bookmarks[volKey] = nil } else { manga.bookmarks[volKey] = b }
    }
    
    // --- LOGIC ---

    func prefetchWindow() {
        guard pages.indices.contains(currentIndex) else { return }

        // Cancel any in-flight prefetch so fast flipping doesn't pile up decode jobs.
        prefetchTask?.cancel()

        let lo = max(0, currentIndex - 2)
        let hi = min(pages.count - 1, currentIndex + 8)

        // Decode the visible page first, then fan out ahead, then behind.
        var order: [URL] = [pages[currentIndex]]
        if currentIndex + 1 <= hi { order += pages[(currentIndex + 1)...hi] }
        if lo <= currentIndex - 1 { order += pages[lo...(currentIndex - 1)].reversed() }

        prefetchTask = Task.detached(priority: .userInitiated) {
            // Land the visible page ASAP…
            guard let visible = order.first else { return }
            ReaderCache.cachePage(visible)
            guard !Task.isCancelled else { return }

            // …then fill the rest of the window across multiple cores. AVIF/WebP
            // decode is CPU-bound, so concurrency is what lets prefetch keep up
            // with fast flipping.
            let rest = Array(order.dropFirst())
            let limit = max(2, min(6, ProcessInfo.processInfo.activeProcessorCount - 1))
            await withTaskGroup(of: Void.self) { group in
                var next = 0
                func addNext() {
                    guard next < rest.count else { return }
                    let url = rest[next]; next += 1
                    group.addTask { if !Task.isCancelled { ReaderCache.cachePage(url) } }
                }
                for _ in 0..<min(limit, rest.count) { addNext() }
                while await group.next() != nil {
                    if Task.isCancelled { break }
                    addNext()
                }
            }
        }
    }
    
    struct PageLayout {
        var right: URL? = nil
        var left: URL? = nil
        var center: URL? = nil
        var step: Int = 2
    }
    
    func calculateLayout(for index: Int, in pages: [URL]) -> PageLayout {
        guard index < pages.count else { return PageLayout(step: 0) }
        let currentURL = pages[index]
        if useCoverOffset && index == 0 { return PageLayout(center: currentURL, step: 1) }
        if isWide(currentURL) { return PageLayout(center: currentURL, step: 1) }
        
        let nextIndex = index + 1
        var leftURL: URL? = nil
        var step = 1
        
        if nextIndex < pages.count {
            let nextURL = pages[nextIndex]
            if isWide(nextURL) { leftURL = nil; step = 1 }
            else { leftURL = nextURL; step = 2 }
        }
        return PageLayout(right: currentURL, left: leftURL, step: step)
    }
    
    func isWide(_ url: URL) -> Bool {
        if let cached = ReaderCache.shared.object(forKey: url as NSURL) {
            return cached.size.width > cached.size.height
        }
        // Read just the header dimensions — no full-resolution decode.
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let h = props[kCGImagePropertyPixelHeight] as? CGFloat else { return false }
        return w > h
    }

    func loadPages() {
        let ext = volumeURL.pathExtension.lowercased()
        if ["epub", "zip", "cbz"].contains(ext) {
            loadArchive()
        } else {
            loadDirectory(volumeURL)
        }
    }
    
    func loadDirectory(_ dir: URL) {
        let fm = FileManager.default
        let exts: Set<String> = ["jpg", "jpeg", "png", "avif", "webp"]

        // Fast path: loose images directly in the folder (the common case).
        let top = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let looseImages = top.filter { exts.contains($0.pathExtension.lowercased()) }
        if !looseImages.isEmpty {
            self.pages = looseImages.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
            return
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
        self.pages = found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
    
    func loadArchive() {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        self.tempArchiveFolder = tempDir
        
        do {
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-q", volumeURL.path, "-d", tempDir.path]
            try process.run()
            process.waitUntilExit()
            
            if let enumerator = fm.enumerator(at: tempDir, includingPropertiesForKeys: nil) {
                var foundImages: [URL] = []
                for case let fileURL as URL in enumerator {
                    if ["jpg", "jpeg", "png", "avif", "webp"].contains(fileURL.pathExtension.lowercased()) {
                        if !fileURL.path.contains("__MACOSX") && !fileURL.lastPathComponent.hasPrefix(".") {
                            foundImages.append(fileURL)
                        }
                    }
                }
                self.pages = foundImages.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            }
        } catch {
            print("Failed to unzip archive: \(error)")
        }
    }
    
    func navigateNext(step: Int) {
        if currentIndex + step < pages.count { currentIndex += step }
        else { currentIndex = pages.count - 1 }
    }
    
    func navigatePrevious() {
        if currentIndex == 0 { return }
        if !isTwoPageMode { currentIndex -= 1; return }
        if useCoverOffset && currentIndex == 1 { currentIndex = 0; return }
        let prevIndex1 = currentIndex - 1
        if prevIndex1 >= 0 && isWide(pages[prevIndex1]) { currentIndex -= 1; return }
        currentIndex = max(0, currentIndex - 2)
    }
    
    // --- PROGRESS LOGIC ---
    
    /// Debounce model writes so rapid page turns don't each trigger a SwiftData
    /// mutation (which would invalidate this view and stutter the flip). Only the
    /// page you land on — after a brief pause — gets persisted.
    func scheduleSave() {
        saveTask?.cancel()
        let page = currentIndex
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            persistProgress(page: page)
        }
    }

    func persistProgress(page: Int) {
        let volName = manga.volumeKey(for: volumeURL)
        let totalPages = pages.count
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
    
    func restoreProgress() {
        let volName = manga.volumeKey(for: volumeURL)
        guard let savedPage = manga.readingProgress[volName] else { return }
        
        let totalPages = pages.count
        guard totalPages > 0 else { return }
        
        let percentage = Double(savedPage) / Double(totalPages)
        
        if percentage < 0.95 {
            if savedPage < totalPages { currentIndex = savedPage }
        } else {
            manga.readingProgress.removeValue(forKey: volName)
            currentIndex = 0
        }
    }
    
    var isVolumeRead: Bool { manga.readVolumes.contains(manga.volumeKey(for: volumeURL)) }

    func markAsRead() {
        let name = manga.volumeKey(for: volumeURL)
        if isVolumeRead { manga.readVolumes.removeAll { $0 == name } }
        else { manga.readVolumes.append(name) }
    }
}

// --- SYNCHRONOUS CACHED PAGE VIEW ---
struct CachedPageView: View {
    let url: URL
    let size: CGSize
    let alignment: Alignment
    @State private var asyncImage: NSImage?
    
    var body: some View {
        Group {
            if let img = displayImage {
                render(img: img)
            } else {
                Color.black // only the very first page, before anything has decoded
            }
        }
        .task(id: url) {
            // Already decoded (e.g. prefetch beat us to it)? Still publish it to
            // state — NSCache isn't observable, so without this the freshly cached
            // page wouldn't trigger a re-render and the view would stay black.
            if let cached = ReaderCache.shared.object(forKey: url as NSURL) {
                if asyncImage !== cached { asyncImage = cached }
                return
            }
            let target = url
            let img = await Task.detached(priority: .userInitiated) {
                ReaderCache.decode(target)
            }.value
            guard !Task.isCancelled, let img else { return }
            ReaderCache.shared.setObject(img, forKey: target as NSURL, cost: ReaderCache.cost(for: img))
            self.asyncImage = img
        }
    }

    /// Resolves the image to draw, preferring (in order): the exact page from the
    /// cache, this view's own last decode, then the global last-displayed page as a
    /// backstop so we never flash to black mid-scrub.
    private var displayImage: NSImage? {
        if let cached = ReaderCache.shared.object(forKey: url as NSURL) {
            ReaderCache.lastDisplayed = cached
            return cached
        }
        if let loaded = asyncImage {
            ReaderCache.lastDisplayed = loaded
            return loaded
        }
        return ReaderCache.lastDisplayed
    }
    
    func render(img: NSImage) -> some View {
        // Layer-backed NSImageView: scaling happens on the GPU and the decoded
        // bitmap is cached as a texture, so a page turn is just a texture swap.
        PageImageView(image: img, alignment: alignment)
            .frame(width: size.width, height: size.height)
            .clipped()
    }
}

// --- GPU-BACKED PAGE RENDERER ---
// SwiftUI's `Image` re-rasterizes large bitmaps on the CPU during layout. An
// NSImageView is layer-backed, so AppKit hands the bitmap to Core Animation once
// and subsequent draws/scales are hardware-accelerated — the key to instant turns.
struct PageImageView: NSViewRepresentable {
    let image: NSImage
    let alignment: Alignment

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.wantsLayer = true
        view.animates = false
        view.imageScaling = .scaleProportionallyUpOrDown
        view.imageAlignment = nsAlignment
        view.image = image
        // Let the SwiftUI frame drive the size rather than the image's intrinsic size.
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        if view.image !== image { view.image = image }
        view.imageAlignment = nsAlignment
    }

    private var nsAlignment: NSImageAlignment {
        switch alignment {
        case .leading:  return .alignLeft
        case .trailing: return .alignRight
        default:        return .alignCenter
        }
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
    let current: Int
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
                                    .foregroundStyle(i == current ? Color.accentColor : .white)
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
