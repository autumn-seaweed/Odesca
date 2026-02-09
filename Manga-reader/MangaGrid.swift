//
//  MangaGrid.swift
//  Manga-reader
//
//  Created by Aki Toyoshima on 2026/02/01.
//

import SwiftUI
import SwiftData
import AppKit

// --- 1. THE SNAPSHOT (Lightweight Data) ---
struct MangaDisplayItem: Identifiable, Equatable {
    let id: PersistentIdentifier
    let title: String
    let folderURL: URL
    let isFavorite: Bool
    let isFinished: Bool
    let hasToReadTag: Bool
    let volumeCount: Int
    let readCount: Int
    
    // image caching for NAS
    var cacheID: String {
        return String(id.hashValue)
    }
    
    init(manga: MangaSeries) {
        self.id = manga.persistentModelID
        self.title = manga.title
        self.folderURL = manga.folderURL
        self.isFavorite = manga.isFavorite
        self.isFinished = manga.isFinished
        self.hasToReadTag = manga.tags.contains("To Read")
        self.volumeCount = manga.volumeCount
        self.readCount = manga.readVolumes.count
    }
}

// --- 2. GLOBAL CACHE ---
class ThumbnailCache {
    static let shared: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 200
        return cache
    }()
}

// --- 3. THE GRID VIEW ---
struct MangaGrid: View {
    @Environment(\.modelContext) var modelContext
    @Query var library: [MangaSeries]
    @Binding var navPath: NavigationPath
    
    // NAS state
    @State private var refreshID = UUID()
    
    // States
    @State private var selectedIds = Set<PersistentIdentifier>()
    @State private var renamingManga: MangaSeries?
    @State private var newName: String = ""
    @State private var showRenameAlert = false
    @State private var showDeleteAlert = false
    @State private var itemsToDelete: [MangaSeries] = []
    
    let searchString: String
    let filter: LibraryFilter
    let columns = [GridItem(.adaptive(minimum: 160, maximum: 200))]
    
    init(sort: SortDescriptor<MangaSeries>, searchString: String, filter: LibraryFilter, navPath: Binding<NavigationPath>) {
        self.searchString = searchString
        self.filter = filter
        self._navPath = navPath
        _library = Query(sort: [sort], animation: .default)
    }

    // Filter Logic
    var filteredLibrary: [MangaSeries] {
        library.filter { manga in
            let matchesFilter: Bool
            switch filter {
            case .all: matchesFilter = true
            case .favorites: matchesFilter = manga.isFavorite
            case .unread: matchesFilter = !manga.isFinished
            case .toRead: matchesFilter = manga.tags.contains("To Read")
            }
            let matchesSearch = searchString.isEmpty || manga.title.localizedStandardContains(searchString)
            return matchesFilter && matchesSearch
        }
    }
    
    // THE OPTIMIZATION: Convert Heavy DB Objects -> Lightweight Snapshots
    var displayItems: [MangaDisplayItem] {
        filteredLibrary.map { MangaDisplayItem(manga: $0) }
    }

    // --- MAIN BODY (Refactored for Compiler Performance) ---
    var body: some View {
        Group {
            if library.isEmpty {
                emptyLibraryView
            } else if displayItems.isEmpty {
                ContentUnavailableView.search(text: searchString)
            } else {
                mangaLibraryGrid
            }
        }
        .onTapGesture { selectedIds.removeAll() }
        .alert("Rename Series", isPresented: $showRenameAlert) {
            TextField("New Name", text: $newName)
            Button("Rename") { if let m = renamingManga { performRename(m, to: newName) } }
            Button("Cancel", role: .cancel) { }
        }
        .alert("Delete \(itemsToDelete.count) Items?", isPresented: $showDeleteAlert) {
            Button("Delete", role: .destructive) { batchDelete(targets: itemsToDelete) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will delete the files from your disk. This action cannot be undone.")
        }
    }
    
    // --- SUBVIEWS (Extracted) ---
    
    var emptyLibraryView: some View {
        ContentUnavailableView {
            Label("No Manga Found", systemImage: "books.vertical")
        } description: {
            Text("Add a folder containing your manga collection to get started.")
        } actions: {
            Button("Add Folder") {
                NSApp.sendAction(#selector(NSDocumentController.openDocument(_:)), to: nil, from: nil)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
    
    var mangaLibraryGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                // Loop over Snapshots, NOT database objects
                ForEach(displayItems) { item in
                    MangaGridItem(
                        item: item,
                        isSelected: selectedIds.contains(item.id),
                        onSelect: { handleSelection(id: item.id) },
                        onOpen: { openManga(id: item.id) }
                    )
                    .equatable()
                    // FIX: Unique ID per item + Refresh Signal
                    .id(item.cacheID + "-" + refreshID.uuidString)
                    .contextMenu {
                        if let realManga = library.first(where: { $0.persistentModelID == item.id }) {
                            contextMenuButtons(for: realManga, item: item)
                        }
                    }
                }
            }
            .padding()
        }
        .focusable()
        .onKeyPress(.delete) {
            let targets = library.filter { selectedIds.contains($0.persistentModelID) }
            if !targets.isEmpty { confirmDelete(targets: targets) }
            return .handled
        }
        .onKeyPress(.return) {
            if let firstId = selectedIds.first { openManga(id: firstId); return .handled }
            return .ignored
        }
    }
    
    // --- ACTIONS ---
    
    func openManga(id: PersistentIdentifier) {
        selectedIds = [id]
        navPath.append(id)
    }
    
    func handleSelection(id: PersistentIdentifier) {
        if NSEvent.modifierFlags.contains(.command) {
            if selectedIds.contains(id) { selectedIds.remove(id) }
            else { selectedIds.insert(id) }
        } else {
            selectedIds = [id]
        }
    }
    
    func contextMenuButtons(for manga: MangaSeries, item: MangaDisplayItem) -> some View {
        let targets = selectedIds.contains(manga.persistentModelID) ? library.filter { selectedIds.contains($0.persistentModelID) } : [manga]
        
        let allToRead = targets.allSatisfy { $0.tags.contains("To Read") }
        let allFavorites = targets.allSatisfy { $0.isFavorite }
        
        return Group {
            Text("\(targets.count) Selected")
            
            // Toggle "To Read"
            if allToRead {
                Button { batchSetTag("To Read", targets: targets, active: false) } label: { Label("Remove 'To Read'", systemImage: "eyeglasses") }
            } else {
                Button { batchSetTag("To Read", targets: targets, active: true) } label: { Label("Add 'To Read'", systemImage: "eyeglasses") }
            }
            
            // Toggle Favorites
            if allFavorites {
                Button { batchSetFavorite(targets: targets, active: false) } label: { Label("Unfavorite", systemImage: "star.slash") }
            } else {
                Button { batchSetFavorite(targets: targets, active: true) } label: { Label("Favorite", systemImage: "star") }
            }
            
            // Refresh Button for refreshing covers
            Divider()
            Button {
                forceRefreshCover(for: item)
            } label: {
                Label("Refresh Cover", systemImage: "arrow.clockwise")
            }
            
            Divider()
            Button { batchMarkRead(targets: targets, read: true) } label: { Label("Mark Read", systemImage: "checkmark.circle") }
            Button { batchMarkRead(targets: targets, read: false) } label: { Label("Mark Unread", systemImage: "circle") }
            Divider()
            Button { NSWorkspace.shared.activateFileViewerSelecting([manga.folderURL]) } label: { Label("Reveal in Finder", systemImage: "folder") }
            if targets.count == 1, let single = targets.first {
                Button { renamingManga = single; newName = single.title; showRenameAlert = true } label: { Label("Rename...", systemImage: "pencil") }
            }
            Button(role: .destructive) { confirmDelete(targets: targets) } label: { Label("Delete", systemImage: "trash") }
        }
    }
    
    func batchSetTag(_ tag: String, targets: [MangaSeries], active: Bool) {
        for m in targets {
            if active { if !m.tags.contains(tag) { m.tags.append(tag) } }
            else { m.tags.removeAll { $0 == tag } }
        }
    }
    
    func batchSetFavorite(targets: [MangaSeries], active: Bool) {
        for m in targets { m.isFavorite = active }
    }
    
    func batchMarkRead(targets: [MangaSeries], read: Bool) {
        for manga in targets {
            if !read {
                manga.readVolumes = []
                manga.isFinished = false
            }
        }
        if !read { return }
        
        let itemsToScan = targets.map { (id: $0.persistentModelID, url: $0.folderURL) }
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var updates: [PersistentIdentifier: [String]] = [:]
            
            for (id, url) in itemsToScan {
                let accessGranted = url.startAccessingSecurityScopedResource()
                defer { if accessGranted { url.stopAccessingSecurityScopedResource() } }
                if let contents = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey]) {
                    let volumes = contents.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.map { $0.lastPathComponent }
                    updates[id] = volumes
                }
            }
            await MainActor.run {
                for manga in targets {
                    if let volumes = updates[manga.persistentModelID] {
                        manga.readVolumes = volumes
                        manga.isFinished = true
                    }
                }
            }
        }
    }
    
    // force cover refresh
    func forceRefreshCover(for item: MangaDisplayItem) {
        // 1. Delete from RAM so the app forgets the old image
        ThumbnailCache.shared.removeObject(forKey: item.folderURL.path as NSString)
        
        // 2. Delete from Disk so the app doesn't just reload the old one on restart
        CoverCache.shared.delete(for: item.cacheID)
        
        // 3. Trigger View Update so the grid actually visually refreshes
        refreshID = UUID()
    }
    
    func confirmDelete(targets: [MangaSeries]) {
        itemsToDelete = targets
        showDeleteAlert = true
    }
    
    func batchDelete(targets: [MangaSeries]) {
        for m in targets {
            try? FileManager.default.removeItem(at: m.folderURL)
            modelContext.delete(m)
        }
        selectedIds.removeAll()
        itemsToDelete.removeAll()
    }
    
    func performRename(_ manga: MangaSeries, to name: String) {
        let fm = FileManager.default
        let oldURL = manga.folderURL
        let newURL = oldURL.deletingLastPathComponent().appendingPathComponent(name)
        do {
            try fm.moveItem(at: oldURL, to: newURL)
            manga.title = name
            manga.folderURL = newURL
        } catch { print("Rename failed: \(error)") }
    }
}

// --- 4. ASYNC COVER (Disk + RAM + Network/NAS Optimized) ---
struct AsyncMangaCover: View {
    let item: MangaDisplayItem
    
    @State private var image: NSImage? = nil
    @State private var loadFailed: Bool = false
    
    var body: some View {
        Group {
            if let img = image {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 160, height: 220).clipped().cornerRadius(10).shadow(radius: 3)
            } else if loadFailed {
                // Failure placeholder
                RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.3)).frame(width: 160, height: 220)
                    .overlay(Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary))
            } else {
                // Loading placeholder
                RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.2)).frame(width: 160, height: 220)
            }
        }
        .task(id: item.id) { await loadCover() }
    }
    
    func loadCover() async {
        // 1. RAM CACHE (Fastest - Instant)
        let ramKey = item.folderURL.path as NSString
        if let cached = ThumbnailCache.shared.object(forKey: ramKey) {
            self.image = cached
            return
        }
        
        // 2. DISK CACHE (Fast - Survives Restart)
        if let diskImage = await Task.detached(priority: .userInitiated, operation: {
            CoverCache.shared.load(for: item.cacheID)
        }).value {
            ThumbnailCache.shared.setObject(diskImage, forKey: ramKey)
            self.image = diskImage
            return
        }
        
        // 3. GENERATE (Slow - Network/NAS Access)
        let loadedImage = await Task.detached(priority: .background) { () -> NSImage? in
            if Task.isCancelled { return nil }
            let fm = FileManager.default
            
            // Recursive Finder: Looks for the first image it can find
            func findImage(in dir: URL, depth: Int) -> NSImage? {
                if depth > 2 { return nil }
                guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
                
                // Images (Naturally Sorted)
                let images = items.filter { ["jpg", "png", "jpeg", "webp", "avif"].contains($0.pathExtension.lowercased()) }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                
                if let first = images.first, let source = CGImageSourceCreateWithURL(first as CFURL, nil) {
                    let opts = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 400] as CFDictionary
                    if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts) { return NSImage(cgImage: cg, size: .zero) }
                }
                
                // Subfolders
                let folders = items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                
                for folder in folders {
                    if let img = findImage(in: folder, depth: depth + 1) { return img }
                }
                return nil
            }
            return findImage(in: item.folderURL, depth: 0)
        }.value
        
        // 4. SAVE RESULT
        if let img = loadedImage {
            ThumbnailCache.shared.setObject(img, forKey: ramKey)     // RAM
            CoverCache.shared.save(image: img, for: item.cacheID)    // Disk
            self.image = img
        } else {
            self.loadFailed = true
        }
    }
}
