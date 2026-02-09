//
//  MangaGrid.swift
//  Manga-reader
//
//  Created by Aki Toyoshima on 2026/02/09.
//

import Foundation
import SwiftUI
import SwiftData
import AppKit

// --- 1. GLOBAL CACHE (Optimized) ---
class ThumbnailCache {
    static let shared: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 200 // Limit to 200 images to prevent memory bloat
        return cache
    }()
}

// Filter Enum
enum LibraryFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case favorites = "Favorites"
    case toRead = "To Read"
    case unread = "Unread"
    var id: String { self.rawValue }
}

struct MangaGrid: View {
    @Environment(\.modelContext) var modelContext
    @Query var library: [MangaSeries]
    @Binding var navPath: NavigationPath
    
    // SELECTION STATE
    @State private var selectedIds = Set<PersistentIdentifier>()
    
    // RENAME STATE
    @State private var renamingManga: MangaSeries?
    @State private var newName: String = ""
    @State private var showRenameAlert = false
    
    // DELETE STATE
    @State private var showDeleteAlert = false
    @State private var itemsToDelete: [MangaSeries] = []
    
    let searchString: String
    let filter: LibraryFilter
    let columns = [GridItem(.adaptive(minimum: 160, maximum: 200))]
    
    init(sort: SortDescriptor<MangaSeries>, searchString: String, filter: LibraryFilter, navPath: Binding<NavigationPath>) {
        self.searchString = searchString
        self.filter = filter
        self._navPath = navPath
        _library = Query(sort: [sort])
    }

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

    var body: some View {
        Group {
            if library.isEmpty {
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
            } else if filteredLibrary.isEmpty {
                ContentUnavailableView.search(text: searchString)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(filteredLibrary) { manga in
                            // --- OPTIMIZED ITEM VIEW ---
                            MangaGridItem(
                                manga: manga,
                                isSelected: selectedIds.contains(manga.id),
                                onSelect: { handleSelection(of: manga) },
                                onOpen: { openManga(manga) }
                            )
                            .contextMenu { contextMenuButtons(for: manga) }
                        }
                    }
                    .padding()
                }
                .focusable()
                .onKeyPress(.delete) {
                    let targets = library.filter { selectedIds.contains($0.id) }
                    if !targets.isEmpty { confirmDelete(targets: targets) }
                    return .handled
                }
                .onKeyPress(.return) {
                    if let firstId = selectedIds.first, let manga = library.first(where: { $0.id == firstId }) {
                        openManga(manga)
                        return .handled
                    }
                    return .ignored
                }
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
    
    // --- HELPERS ---
    
    func openManga(_ manga: MangaSeries) {
        selectedIds = [manga.id]
        navPath.append(manga.persistentModelID)
    }
    
    func handleSelection(of manga: MangaSeries) {
        if NSEvent.modifierFlags.contains(.command) {
            if selectedIds.contains(manga.id) { selectedIds.remove(manga.id) }
            else { selectedIds.insert(manga.id) }
        } else {
            selectedIds = [manga.id]
        }
    }
    
    func contextMenuButtons(for manga: MangaSeries) -> some View {
        let targets = selectedIds.contains(manga.id) ? library.filter { selectedIds.contains($0.id) } : [manga]
        
        let allToRead = targets.allSatisfy { $0.tags.contains("To Read") }
        let allFavorites = targets.allSatisfy { $0.isFavorite }
        
        return Group {
            Text("\(targets.count) Selected")
            if allToRead {
                Button { batchSetTag("To Read", targets: targets, active: false) } label: { Label("Remove from 'To Read'", systemImage: "eyeglasses") }
            } else {
                Button { batchSetTag("To Read", targets: targets, active: true) } label: { Label("Add to 'To Read'", systemImage: "eyeglasses") }
            }
            if allFavorites {
                Button { batchSetFavorite(targets: targets, active: false) } label: { Label("Remove from Favorites", systemImage: "star.slash") }
            } else {
                Button { batchSetFavorite(targets: targets, active: true) } label: { Label("Add to Favorites", systemImage: "star") }
            }
            Divider()
            Button { batchMarkRead(targets: targets, read: true) } label: { Label("Mark as Read", systemImage: "checkmark.circle") }
            Button { batchMarkRead(targets: targets, read: false) } label: { Label("Mark as Unread", systemImage: "circle") }
            Divider()
            Button { NSWorkspace.shared.activateFileViewerSelecting([manga.folderURL]) } label: { Label("Reveal in Finder", systemImage: "folder") }
            if targets.count == 1, let single = targets.first {
                Button { renamingManga = single; newName = single.title; showRenameAlert = true } label: { Label("Rename...", systemImage: "pencil") }
            }
            Button(role: .destructive) { confirmDelete(targets: targets) } label: { Label("Delete", systemImage: "trash") }
        }
    }
    
    // --- ACTIONS ---
    
    func batchSetTag(_ tag: String, targets: [MangaSeries], active: Bool) {
        for m in targets {
            if active { if !m.tags.contains(tag) { m.tags.append(tag) } }
            else { m.tags.removeAll { $0 == tag } }
        }
    }
    
    func batchSetFavorite(targets: [MangaSeries], active: Bool) {
        for m in targets { m.isFavorite = active }
    }
    
    // --- THREAD-SAFE BATCH MARK READ ---
    func batchMarkRead(targets: [MangaSeries], read: Bool) {
        // 1. Optimistic UI Update (Instant)
        for manga in targets {
            if !read {
                manga.readVolumes = []
                manga.isFinished = false
            }
        }
        
        if !read { return } // If unmarking, we are done.
        
        // 2. Extract Data for Background (Don't pass Model Objects to background!)
        let itemsToScan = targets.map { (id: $0.persistentModelID, url: $0.folderURL) }
        
        // 3. Background Work
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var updates: [PersistentIdentifier: [String]] = [:]
            
            for (id, url) in itemsToScan {
                let accessGranted = url.startAccessingSecurityScopedResource()
                defer { if accessGranted { url.stopAccessingSecurityScopedResource() } }
                
                if let contents = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey]) {
                    let volumes = contents
                        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                        .map { $0.lastPathComponent }
                    updates[id] = volumes
                }
            }
            
            // 4. Update UI on Main Thread
            await MainActor.run {
                // We re-match the data to the targets (which are on the main thread)
                for manga in targets {
                    if let volumes = updates[manga.persistentModelID] {
                        manga.readVolumes = volumes
                        manga.isFinished = true
                    }
                }
            }
        }
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

// --- HIGH PERFORMANCE IMAGE LOADER (Uses .task for cancellation) ---
struct AsyncMangaCover: View {
    let manga: MangaSeries
    @State private var image: NSImage? = nil
    @State private var loadFailed: Bool = false
    
    var body: some View {
        Group {
            if let img = image {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 160, height: 220)
                    .clipped()
                    .cornerRadius(10)
                    .shadow(radius: 3)
            } else if loadFailed {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 160, height: 220)
                    .overlay(
                        VStack(spacing: 8) {
                            Image(systemName: "photo.badge.exclamationmark")
                                .font(.largeTitle).foregroundStyle(.secondary.opacity(0.5))
                            Text("No Cover").font(.caption2).foregroundStyle(.secondary)
                        }
                    )
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 160, height: 220)
            }
        }
        .task(id: manga.folderURL) {
            await loadCover()
        }
    }
    
    func loadCover() async {
        let cacheKey = manga.folderURL.path as NSString
        
        if let cached = ThumbnailCache.shared.object(forKey: cacheKey) {
            self.image = cached
            return
        }
        
        let loadedImage = await Task.detached(priority: .background) { () -> NSImage? in
            if Task.isCancelled { return nil }
            let fm = FileManager.default
            let validExts = ["jpg", "jpeg", "png", "avif", "webp"]
            
            func loadThumbnail(from url: URL) -> NSImage? {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 400,
                    kCGImageSourceCreateThumbnailWithTransform: true
                ]
                if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                    return NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
                }
                return nil
            }

            func findFirstImageRecursively(in url: URL, currentDepth: Int, maxDepth: Int) -> NSImage? {
                if currentDepth > maxDepth { return nil }
                guard let items = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else { return nil }
                
                let images = items.filter { validExts.contains($0.pathExtension.lowercased()) }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                
                if let first = images.first { return loadThumbnail(from: first) }
                
                let folders = items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                
                for folder in folders {
                    if Task.isCancelled { return nil }
                    if let img = findFirstImageRecursively(in: folder, currentDepth: currentDepth + 1, maxDepth: maxDepth) {
                        return img
                    }
                }
                return nil
            }

            return findFirstImageRecursively(in: manga.folderURL, currentDepth: 0, maxDepth: 3)
        }.value
        
        if !Task.isCancelled {
            if let img = loadedImage {
                ThumbnailCache.shared.setObject(img, forKey: cacheKey)
                self.image = img
            } else {
                self.loadFailed = true
            }
        }
    }
}
