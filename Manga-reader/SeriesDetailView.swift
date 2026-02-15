//
//  SeriesDetailView.swift
//  Manga-reader
//
//  Created by Aki Toyoshima on 2026/02/09.
//

import Foundation
import SwiftUI
import SwiftData

// --- CACHE FOR PAGE COUNTS ---
class PageCountCache {
    static let shared = NSCache<NSString, NSNumber>()
}

struct SeriesDetailView: View {
    @Bindable var manga: MangaSeries
    @Binding var navPath: NavigationPath
    
    @Environment(\.dismiss) var dismiss
    @Environment(\.modelContext) var modelContext
    
    @State private var volumes: [URL] = []
    @State private var selectedVolume: URL?
    @State private var renamingVolume: URL?
    @State private var newName: String = ""
    @State private var showRenameAlert = false
    
    // Alert state for the cleanup feature
    @State private var showCleanupConfirm = false
    @State private var cleanupPreview = ""
    @State private var cleanupCount = 0

    var body: some View {
        ScrollView {
            Color.clear.contentShape(Rectangle())
                .frame(height: 1)
                .onTapGesture { selectedVolume = nil }
            
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 20) {
                ForEach(volumes, id: \.self) { volumeURL in
                    let isRead = manga.readVolumes.contains(volumeURL.lastPathComponent)
                    
                    VStack {
                        VolumeCover(
                            folderURL: volumeURL,
                            progress: manga.readingProgress[volumeURL.lastPathComponent]
                        )
                        .opacity(isRead ? 0.5 : 1.0)
                        
                        // Green Check Mark
                        .overlay(alignment: .topTrailing) {
                            if isRead {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.title)
                                    .foregroundStyle(.green)
                                    .background(Circle().fill(.white))
                                    .padding(8)
                                    .shadow(radius: 3)
                            }
                        }
                        // Selection Border
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.accentColor, lineWidth: selectedVolume == volumeURL ? 3 : 0)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { openVolume(volumeURL) }
                        .onTapGesture(count: 1) { selectedVolume = volumeURL }
                        .contextMenu {
                            Button { openVolume(volumeURL) } label: { Label("Open (Auto)", systemImage: "book") }
                            
                            // 👇 NEW: Manual Override Options
                            if ["epub"].contains(volumeURL.pathExtension.lowercased()) {
                                Divider()
                                Button { openVolume(volumeURL, forceMode: .novel) } label: { Label("Open as Text Book", systemImage: "text.justify.left") }
                                Button { openVolume(volumeURL, forceMode: .manga) } label: { Label("Open as Comic", systemImage: "photo.on.rectangle") }
                            }
                            
                            Divider()
                            Button { toggleReadStatus(for: volumeURL, setRead: true) } label: { Label("Mark as Read", systemImage: "checkmark.circle") }
                            Button { toggleReadStatus(for: volumeURL, setRead: false) } label: { Label("Mark as Unread", systemImage: "circle") }
                            Divider()
                            Button {
                                renamingVolume = volumeURL
                                newName = volumeURL.deletingPathExtension().lastPathComponent
                                showRenameAlert = true
                            } label: {
                                Label("Rename...", systemImage: "pencil")
                            }
                            Button { NSWorkspace.shared.activateFileViewerSelecting([volumeURL]) } label: { Label("Reveal in Finder", systemImage: "folder") }
                        }

                        HStack {
                            Text(volumeURL.lastPathComponent)
                                .font(.headline).lineLimit(1)
                                .background(selectedVolume == volumeURL ? Color.accentColor.opacity(0.3) : Color.clear)
                                .cornerRadius(4)
                                .foregroundStyle(isRead ? .secondary : .primary)
                            
                            Spacer()
                            
                            Button {
                                toggleReadStatus(for: volumeURL, setRead: !isRead)
                            } label: {
                                Image(systemName: isRead ? "eye.slash" : "eye")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .frame(width: 150)
                    }
                }
            }
            .padding()
        }
        .onAppear { loadVolumes() }
        .navigationTitle(manga.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { manga.isFavorite.toggle() }) {
                    Label("Favorite", systemImage: manga.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(manga.isFavorite ? .yellow : .primary)
                }
                .help(manga.isFavorite ? "Remove from Favorites" : "Add to Favorites")
            }
            
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(action: prepareCleanup) {
                        Label("Clean Up Filenames...", systemImage: "wand.and.stars")
                    }
                } label: {
                    Label("Options", systemImage: "gear")
                }
            }
        }
        .alert("Rename Volume", isPresented: $showRenameAlert) {
            TextField("New Name", text: $newName)
            Button("Rename") { if let v = renamingVolume { performRename(v, to: newName) } }
            Button("Cancel", role: .cancel) { }
        }
        .alert("Rename \(cleanupCount) Items?", isPresented: $showCleanupConfirm) {
            Button("Rename All", role: .destructive) { performCleanup() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(cleanupPreview)
        }
        .background(Button("") { dismiss() }.keyboardShortcut(.cancelAction).opacity(0))
    }
    
    // --- ACTIONS ---
    
    func loadVolumes() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: manga.folderURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
        
        let archiveExts = ["epub", "zip", "cbz"]
        
        self.volumes = items.filter { item in
            let name = item.lastPathComponent
            if name.hasPrefix(".") { return false }
            
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let isArchive = archiveExts.contains(item.pathExtension.lowercased())
            
            return isDir || isArchive
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
    
    enum OpenMode {
        case auto, novel, manga
    }
    
    func openVolume(_ url: URL, forceMode: OpenMode = .auto) {
        let ext = url.pathExtension.lowercased()
        
        if forceMode == .novel {
            navPath.append(NovelDestination(url: url, mangaID: manga.persistentModelID))
            return
        }
        
        if forceMode == .manga {
            navPath.append(VolumeDestination(volumeURL: url, mangaID: manga.persistentModelID))
            return
        }
        
        if ext == "epub" {
            // 🕵️ IMPROVED SMART DETECTION
            checkEpubType(url: url) { isNovel in
                if isNovel {
                    navPath.append(NovelDestination(url: url, mangaID: manga.persistentModelID))
                } else {
                    navPath.append(VolumeDestination(volumeURL: url, mangaID: manga.persistentModelID))
                }
            }
        } else {
            // Zip/CBZ/Folders are always Manga
            navPath.append(VolumeDestination(volumeURL: url, mangaID: manga.persistentModelID))
        }
    }
    
    func checkEpubType(url: URL, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-l", url.path] // List contents with sizes
            
            let pipe = Pipe()
            process.standardOutput = pipe
            
            try? process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                let lines = output.components(separatedBy: .newlines)
                
                var imageCount = 0
                var totalTextSize: Int64 = 0
                
                for line in lines {
                    let l = line.lowercased()
                    
                    // Count Images
                    if l.contains(".jpg") || l.contains(".png") || l.contains(".webp") {
                        imageCount += 1
                    }
                    
                    // Sum Text Size
                    if l.contains(".html") || l.contains(".xhtml") || l.contains(".xml") {
                        // Extract size from "unzip -l" output (usually the first number)
                        let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces)
                        if let first = parts.first, let size = Int64(first) {
                            totalTextSize += size
                        }
                    }
                }
                
                // DECISION LOGIC:
                // 1. If text size > 40KB, it's almost certainly a Novel (Manga wrapper HTMLs are tiny).
                // 2. Otherwise, fall back to image count.
                let isNovel = totalTextSize > 40_000 || imageCount < 15
                
                DispatchQueue.main.async { completion(isNovel) }
                
            } else {
                DispatchQueue.main.async { completion(false) }
            }
        }
    }
    
    func toggleReadStatus(for url: URL, setRead: Bool) {
        let name = url.lastPathComponent
        if setRead {
            if !manga.readVolumes.contains(name) { manga.readVolumes.append(name) }
            manga.readingProgress.removeValue(forKey: name)
        } else {
            manga.readVolumes.removeAll { $0 == name }
        }
    }
    
    func performRename(_ url: URL, to name: String) {
        let fm = FileManager.default
        let originalExtension = url.pathExtension
        var finalName = name
        
        if !originalExtension.isEmpty && !finalName.lowercased().hasSuffix("." + originalExtension.lowercased()) {
            finalName += "." + originalExtension
        }
        
        let newURL = url.deletingLastPathComponent().appendingPathComponent(finalName)
        let oldName = url.lastPathComponent
        
        do {
            try fm.moveItem(at: url, to: newURL)
            if manga.readVolumes.contains(oldName) {
                manga.readVolumes.removeAll { $0 == oldName }
                manga.readVolumes.append(newURL.lastPathComponent)
            }
            if let progress = manga.readingProgress[oldName] {
                manga.readingProgress.removeValue(forKey: oldName)
                manga.readingProgress[newURL.lastPathComponent] = progress
            }
            loadVolumes()
        } catch { print("Rename failed: \(error)") }
    }
    
    // --- CLEANUP LOGIC ---
    func prepareCleanup() {
        var changes: [(from: String, to: String)] = []
        for url in volumes {
            let oldName = url.lastPathComponent
            let ext = url.pathExtension
            let nameNoExt = url.deletingPathExtension().lastPathComponent
            let baseName = extractNumber(from: nameNoExt)
            if baseName.isEmpty || baseName == nameNoExt { continue }
            let newName = ext.isEmpty ? baseName : "\(baseName).\(ext)"
            if oldName != newName { changes.append((oldName, newName)) }
        }
        cleanupCount = changes.count
        if changes.isEmpty {
            cleanupPreview = "All filenames are already clean!"
            cleanupCount = 0
            showCleanupConfirm = true
        } else {
            var message = "This will rename \(cleanupCount) files to shorten their names.\n\nExamples:\n"
            let previewLimit = 5
            for change in changes.prefix(previewLimit) {
                message += "• \"\(change.from)\"\n   → \"\(change.to)\"\n"
            }
            if changes.count > previewLimit { message += "\n...and \(changes.count - previewLimit) others." }
            message += "\n\nThis action cannot be undone."
            cleanupPreview = message
            showCleanupConfirm = true
        }
    }
    
    func performCleanup() {
        let fm = FileManager.default
        for url in volumes {
            let oldName = url.lastPathComponent
            let ext = url.pathExtension
            let nameNoExt = url.deletingPathExtension().lastPathComponent
            let baseName = extractNumber(from: nameNoExt)
            if baseName.isEmpty || baseName == nameNoExt { continue }
            let newName = ext.isEmpty ? baseName : "\(baseName).\(ext)"
            if oldName == newName { continue }
            let newURL = url.deletingLastPathComponent().appendingPathComponent(newName)
            do {
                try fm.moveItem(at: url, to: newURL)
                if manga.readVolumes.contains(oldName) {
                    manga.readVolumes.removeAll { $0 == oldName }
                    manga.readVolumes.append(newName)
                }
                if let progress = manga.readingProgress[oldName] {
                    manga.readingProgress.removeValue(forKey: oldName)
                    manga.readingProgress[newName] = progress
                }
            } catch { print("Failed to rename \(oldName): \(error)") }
        }
        try? modelContext.save()
        loadVolumes()
    }
    
    func extractNumber(from filename: String) -> String {
        if let range = filename.range(of: "第(\\d+)巻", options: .regularExpression),
           let match = filename[range].range(of: "\\d+", options: .regularExpression) {
            return String(filename[match])
        }
        if let range = filename.range(of: "(?:v|vol\\.?) ?(\\d+)", options: [.regularExpression, .caseInsensitive]),
           let match = filename[range].range(of: "\\d+", options: .regularExpression) {
            return String(filename[match])
        }
        if let range = filename.range(of: "\\d+", options: [.regularExpression, .backwards]) {
            return String(filename[range])
        }
        return filename
    }
}

// --- VOLUME COVER ---
struct VolumeCover: View {
    let folderURL: URL
    let progress: Int?
    @State private var image: NSImage?
    @State private var loadFailed = false
    @State private var totalPages: Int = 0
    
    var body: some View {
        ZStack(alignment: .bottom) {
            if let img = image {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 150, height: 220).clipped().cornerRadius(8).shadow(radius: 2)
            } else if loadFailed {
                RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.3)).frame(width: 150, height: 220)
                    .overlay(VStack {
                        Image(systemName: isArchive ? "doc.zipper" : "folder")
                            .font(.largeTitle).foregroundStyle(.secondary.opacity(0.5))
                        Text(folderURL.pathExtension.uppercased().isEmpty ? "FOLDER" : folderURL.pathExtension.uppercased())
                            .font(.caption2).foregroundStyle(.secondary)
                    })
            } else {
                RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.2)).frame(width: 150, height: 220)
                    .overlay(ProgressView())
            }
            if let current = progress, totalPages > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.black.opacity(0.6))
                        Rectangle().fill(Color.accentColor)
                            .frame(width: geo.size.width * (CGFloat(current) / CGFloat(totalPages)))
                    }
                }
                .frame(height: 4).cornerRadius(2).padding(6)
            }
        }
        .onAppear { loadCover() }
    }
    
    var isArchive: Bool { ["epub", "zip", "cbz"].contains(folderURL.pathExtension.lowercased()) }
    
    func loadCover() {
        let cacheKey = folderURL.path as NSString
        let cachedImage = ThumbnailCache.shared.object(forKey: cacheKey)
        let cachedCount = PageCountCache.shared.object(forKey: cacheKey)
        if let img = cachedImage, let count = cachedCount {
            self.image = img; self.totalPages = count.intValue; return
        }
        if let img = cachedImage { self.image = img }
        DispatchQueue.global(qos: .userInitiated).async {
            if self.isArchive { self.loadArchiveCover(key: cacheKey) } else { self.loadFolderCover(key: cacheKey) }
        }
    }
    
    func loadFolderCover(key: NSString) {
        let fm = FileManager.default
        let validExts = ["jpg", "jpeg", "png", "avif", "webp"]
        guard let items = try? fm.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil) else {
            DispatchQueue.main.async { self.loadFailed = true }; return
        }
        let images = items.filter { validExts.contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        DispatchQueue.main.async {
            self.totalPages = images.count
            PageCountCache.shared.setObject(NSNumber(value: images.count), forKey: key)
            if self.image == nil, let first = images.first, let source = CGImageSourceCreateWithURL(first as CFURL, nil), let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 400] as CFDictionary) {
                let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
                ThumbnailCache.shared.setObject(nsImage, forKey: key); self.image = nsImage
            } else if self.image == nil { self.loadFailed = true }
        }
    }
    
    func loadArchiveCover(key: NSString) {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-q", "-j", folderURL.path, "*.jpg", "*.jpeg", "*.png", "*.webp", "-d", tempDir.path]
            try process.run(); process.waitUntilExit()
            let items = (try? fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)) ?? []
            let images = items.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            DispatchQueue.main.async {
                self.totalPages = max(100, images.count)
                if let first = images.first, let img = NSImage(contentsOf: first) {
                    ThumbnailCache.shared.setObject(img, forKey: key); self.image = img
                } else { self.loadFailed = true }
                try? fm.removeItem(at: tempDir)
            }
        } catch { DispatchQueue.main.async { self.loadFailed = true } }
    }
}
