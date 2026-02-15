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
    
    // Multi-Select Support
    @State private var selectedVolumes: Set<URL> = []
    
    @State private var renamingVolume: URL?
    @State private var newName: String = ""
    @State private var showRenameAlert = false
    
    @State private var showCleanupConfirm = false
    @State private var cleanupPreview = ""
    @State private var cleanupCount = 0

    var body: some View {
        ScrollView {
            // Click background to deselect all
            Color.clear.contentShape(Rectangle())
                .frame(height: 1)
                .onTapGesture { selectedVolumes.removeAll() }
            
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 20) {
                ForEach(volumes, id: \.self) { volumeURL in
                    let isRead = manga.readVolumes.contains(volumeURL.lastPathComponent)
                    let isSelected = selectedVolumes.contains(volumeURL)
                    
                    VStack {
                        VolumeCover(
                            folderURL: volumeURL,
                            progress: manga.readingProgress[volumeURL.lastPathComponent],
                            isRead: isRead
                        )
                        .frame(height: 220)
                        
                        // Selection Border
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
                        )
                        .contentShape(Rectangle())
                        
                        // GESTURES
                        .onTapGesture(count: 2) {
                            openVolume(volumeURL)
                        }
                        .onTapGesture {
                            handleSelection(volumeURL)
                        }
                        
                        // CONTEXT MENU
                        .contextMenu {
                            Button("Open") { openVolume(volumeURL) }
                            
                            Divider()
                            
                            Button("Mark as Read") { batchToggleRead(read: true, clicked: volumeURL) }
                            Button("Mark as Unread") { batchToggleRead(read: false, clicked: volumeURL) }
                            
                            Divider()
                            
                            if selectedVolumes.count <= 1 {
                                Button("Rename...") {
                                    renamingVolume = volumeURL
                                    newName = volumeURL.lastPathComponent
                                    showRenameAlert = true
                                }
                            }
                            
                            Button("Reveal in Finder") {
                                let targets = getTargets(clicked: volumeURL)
                                NSWorkspace.shared.activateFileViewerSelecting(targets)
                            }
                        }
                        
                        Text(volumeURL.lastPathComponent)
                            .font(.caption)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(isRead ? .secondary : .primary)
                    }
                }
            }
            .padding()
        }
        .navigationTitle(manga.title)
        // 👇 NEW: Focusable enables key presses
        .focusable()
        .focusEffectDisabled()
        // 👇 NEW: ESC to Go Back
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { scanVolumes() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
            ToolbarItem(placement: .destructiveAction) {
                Button { analyzeCleanup() } label: { Label("Clean Names", systemImage: "wand.and.stars") }
            }
        }
        .onAppear { scanVolumes() }
        .alert("Rename Volume", isPresented: $showRenameAlert) {
            TextField("New Name", text: $newName)
            Button("Rename") { if let v = renamingVolume { renameVolume(v, to: newName) } }
            Button("Cancel", role: .cancel) { }
        }
        .alert("Clean Up File Names?", isPresented: $showCleanupConfirm) {
            Button("Rename \(cleanupCount) Files", role: .destructive) { performCleanup() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(cleanupPreview)
        }
    }
    
    // MARK: - Logic
    
    func handleSelection(_ url: URL) {
        if NSEvent.modifierFlags.contains(.command) {
            if selectedVolumes.contains(url) {
                selectedVolumes.remove(url)
            } else {
                selectedVolumes.insert(url)
            }
        } else {
            selectedVolumes = [url]
        }
    }
    
    func getTargets(clicked: URL) -> [URL] {
        if selectedVolumes.contains(clicked) {
            return Array(selectedVolumes)
        } else {
            return [clicked]
        }
    }
    
    func batchToggleRead(read: Bool, clicked: URL) {
        let targets = getTargets(clicked: clicked)
        
        for url in targets {
            let name = url.lastPathComponent
            if read {
                if !manga.readVolumes.contains(name) { manga.readVolumes.append(name) }
                manga.readingProgress.removeValue(forKey: name)
            } else {
                manga.readVolumes.removeAll { $0 == name }
            }
        }
        checkIfFinished()
    }
    
    func scanVolumes() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: manga.folderURL, includingPropertiesForKeys: nil) else { return }
        
        let validExtensions = ["cbz", "zip", "epub"]
        
        self.volumes = items.filter { url in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let isArchive = validExtensions.contains(url.pathExtension.lowercased())
            let isHidden = url.lastPathComponent.hasPrefix(".")
            return !isHidden && (isDir || isArchive)
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        
        if manga.volumeCount != volumes.count {
            manga.volumeCount = volumes.count
        }
    }
    
    func openVolume(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        
        if ["zip", "cbz"].contains(ext) || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            navPath.append(VolumeDestination(volumeURL: url, mangaID: manga.persistentModelID))
            return
        }
        
        if ext == "epub" {
            if isVisualEpub(url) {
                navPath.append(VolumeDestination(volumeURL: url, mangaID: manga.persistentModelID))
            } else {
                navPath.append(NovelDestination(url: url, mangaID: manga.persistentModelID))
            }
        }
    }
    
    func isVisualEpub(_ url: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-l", url.path]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return false }
            
            let lines = output.components(separatedBy: .newlines)
            var imageCount = 0
            for line in lines {
                let lower = line.lowercased()
                if lower.contains(".jpg") || lower.contains(".jpeg") || lower.contains(".png") || lower.contains(".webp") {
                    imageCount += 1
                }
            }
            return imageCount > 30
        } catch {
            return false
        }
    }
    
    func toggleRead(_ url: URL) {
        let name = url.lastPathComponent
        if manga.readVolumes.contains(name) {
            manga.readVolumes.removeAll { $0 == name }
            manga.isFinished = false
        } else {
            manga.readVolumes.append(name)
            checkIfFinished()
        }
    }
    
    func markPreviousAsRead(from url: URL) {
        guard let index = volumes.firstIndex(of: url) else { return }
        let previousVolumes = volumes.prefix(upTo: index + 1)
        
        for vol in previousVolumes {
            let name = vol.lastPathComponent
            if !manga.readVolumes.contains(name) {
                manga.readVolumes.append(name)
            }
        }
        checkIfFinished()
    }
    
    func checkIfFinished() {
        let allNames = Set(volumes.map { $0.lastPathComponent })
        let readNames = Set(manga.readVolumes)
        if readNames.isSuperset(of: allNames) {
            manga.isFinished = true
        } else {
            manga.isFinished = false
        }
    }
    
    func renameVolume(_ url: URL, to name: String) {
        let newURL = url.deletingLastPathComponent().appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: url, to: newURL)
            scanVolumes()
        } catch {
            print("Rename failed: \(error)")
        }
    }
    
    func analyzeCleanup() {
        let cleaner = NameCleaner()
        let actions = cleaner.analyze(volumes: volumes)
        
        if actions.isEmpty {
            cleanupPreview = "Filenames already look clean!"
            cleanupCount = 0
        } else {
            cleanupCount = actions.count
            let sample = actions.prefix(3).map { "\($0.original.lastPathComponent) → \($0.newName)" }.joined(separator: "\n")
            cleanupPreview = "Found \(actions.count) files to rename.\n\nExamples:\n\(sample)\n\n..."
        }
        showCleanupConfirm = true
    }
    
    func performCleanup() {
        let cleaner = NameCleaner()
        let actions = cleaner.analyze(volumes: volumes)
        
        for action in actions {
            let newURL = action.original.deletingLastPathComponent().appendingPathComponent(action.newName)
            try? FileManager.default.moveItem(at: action.original, to: newURL)
        }
        scanVolumes()
    }
}

// --- VOLUME COVER ---
struct VolumeCover: View {
    let folderURL: URL
    let progress: Int?
    let isRead: Bool
    
    @State private var image: NSImage?
    @State private var loadFailed = false
    @State private var totalPages: Int = 0
    
    var body: some View {
        ZStack(alignment: .bottom) {
            if let img = image {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 150, height: 220)
                    .clipped()
                    .cornerRadius(8)
                    .shadow(radius: 2)
            } else if loadFailed {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 150, height: 220)
                    .overlay(VStack {
                        Image(systemName: isArchive ? "doc.zipper" : "folder")
                            .font(.largeTitle).foregroundStyle(.secondary.opacity(0.5))
                        Text(folderURL.pathExtension.uppercased().isEmpty ? "FOLDER" : folderURL.pathExtension.uppercased())
                            .font(.caption2).foregroundStyle(.secondary)
                    })
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 150, height: 220)
                    .overlay(ProgressView())
            }
            
            // 2. THE PLEX BADGE
            if isRead {
                VStack {
                    HStack {
                        Spacer()
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                            .padding(8)
                            .background(Color.black.opacity(0.8))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.white, lineWidth: 1.5)
                            )
                            .padding(6)
                    }
                    Spacer()
                }
            }
            // 3. THE PROGRESS BAR
            else if let prog = progress, totalPages > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.black.opacity(0.7))
                        Rectangle().fill(Color.accentColor)
                            .frame(width: geo.size.width * (CGFloat(prog) / CGFloat(totalPages)))
                    }
                }
                .frame(height: 6)
                .cornerRadius(3)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
        .contentShape(Rectangle())
        .onAppear { loadCover() }
    }
    
    var isArchive: Bool { ["epub", "zip", "cbz"].contains(folderURL.pathExtension.lowercased()) }
    
    func loadCover() {
        let cacheKey = folderURL.path as NSString
        let cachedImage = ThumbnailCache.shared.object(forKey: cacheKey)
        let cachedCount = PageCountCache.shared.object(forKey: cacheKey)
        
        if let count = cachedCount { self.totalPages = count.intValue }
        
        if let img = cachedImage {
            self.image = img
            if self.totalPages > 0 { return }
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            if self.isArchive { self.loadArchiveCover(key: cacheKey) } else { self.loadFolderCover(key: cacheKey) }
        }
    }
    
    func downsample(url: URL) -> NSImage? {
        let opts = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 300] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts) else { return nil }
        return NSImage(cgImage: cg, size: .zero)
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
            
            if self.image == nil, let first = images.first {
                if let thumb = self.downsample(url: first) {
                    ThumbnailCache.shared.setObject(thumb, forKey: key)
                    self.image = thumb
                } else { self.loadFailed = true }
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
            process.arguments = ["-q", "-j", folderURL.path,
                                 "*.jpg", "*.jpeg", "*.png", "*.webp",
                                 "*.JPG", "*.JPEG", "*.PNG", "*.WEBP",
                                 "-d", tempDir.path]
            try process.run(); process.waitUntilExit()
            
            let items = (try? fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)) ?? []
            let images = items.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            
            DispatchQueue.main.async {
                self.totalPages = images.isEmpty ? 100 : max(100, images.count)
                PageCountCache.shared.setObject(NSNumber(value: self.totalPages), forKey: key)
                
                if let first = images.first, let thumb = self.downsample(url: first) {
                    ThumbnailCache.shared.setObject(thumb, forKey: key)
                    self.image = thumb
                } else {
                    self.loadFailed = true
                }
                try? fm.removeItem(at: tempDir)
            }
        } catch {
            DispatchQueue.main.async {
                self.loadFailed = true
                self.totalPages = 100
            }
        }
    }
}

// --- HELPER: NAME CLEANER ---
class NameCleaner {
    struct RenameAction { let original: URL; let newName: String }
    
    func analyze(volumes: [URL]) -> [RenameAction] {
        let names = volumes.map { $0.deletingPathExtension().lastPathComponent }
        guard let first = names.first else { return [] }
        
        var prefix = first
        for name in names {
            while !name.hasPrefix(prefix) && !prefix.isEmpty {
                prefix.removeLast()
            }
        }
        
        if !prefix.hasSuffix(" ") && !prefix.hasSuffix("]") && !prefix.hasSuffix("-") {
            return []
        }
        
        var actions: [RenameAction] = []
        for url in volumes {
            let oldName = url.lastPathComponent
            let ext = url.pathExtension
            let nameBody = url.deletingPathExtension().lastPathComponent
            
            if nameBody.hasPrefix(prefix) {
                var newBody = String(nameBody.dropFirst(prefix.count))
                while newBody.hasPrefix(" ") || newBody.hasPrefix("-") { newBody.removeFirst() }
                
                let finalName = newBody + "." + ext
                if finalName != oldName && !newBody.isEmpty {
                    actions.append(RenameAction(original: url, newName: finalName))
                }
            }
        }
        return actions
    }
}
