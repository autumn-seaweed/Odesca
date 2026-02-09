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

    var body: some View {
        ScrollView {
            Color.clear.contentShape(Rectangle())
                .frame(height: 1)
                .onTapGesture { selectedVolume = nil }
            
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 20) {
                ForEach(volumes, id: \.self) { volumeURL in
                    VStack {
                        VolumeCover(
                            folderURL: volumeURL,
                            progress: manga.readingProgress[volumeURL.lastPathComponent]
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.accentColor, lineWidth: selectedVolume == volumeURL ? 3 : 0)
                        )
                        .overlay(alignment: .topTrailing) {
                            if manga.readVolumes.contains(volumeURL.lastPathComponent) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .background(Circle().fill(.white))
                                    .font(.title2)
                                    .padding(5)
                                    .shadow(radius: 2)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { openVolume(volumeURL) }
                        .onTapGesture(count: 1) { selectedVolume = volumeURL }
                        .contextMenu {
                            Button { openVolume(volumeURL) } label: { Label("Open", systemImage: "book") }
                            Divider()
                            Button { toggleReadStatus(for: volumeURL, setRead: true) } label: { Label("Mark as Read", systemImage: "checkmark.circle") }
                            Button { toggleReadStatus(for: volumeURL, setRead: false) } label: { Label("Mark as Unread", systemImage: "circle") }
                            Divider()
                            Button { renamingVolume = volumeURL; newName = volumeURL.lastPathComponent; showRenameAlert = true } label: { Label("Rename...", systemImage: "pencil") }
                            Button { NSWorkspace.shared.activateFileViewerSelecting([volumeURL]) } label: { Label("Reveal in Finder", systemImage: "folder") }
                        }

                        HStack {
                            Text(volumeURL.lastPathComponent)
                                .font(.headline).lineLimit(1)
                                .background(selectedVolume == volumeURL ? Color.accentColor.opacity(0.3) : Color.clear)
                                .cornerRadius(4)
                            Spacer()
                            Button {
                                let isRead = manga.readVolumes.contains(volumeURL.lastPathComponent)
                                toggleReadStatus(for: volumeURL, setRead: !isRead)
                            } label: {
                                Image(systemName: manga.readVolumes.contains(volumeURL.lastPathComponent) ? "eye.slash" : "eye")
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
        // --- NEW: TOOLBAR FAVORITE BUTTON ---
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { manga.isFavorite.toggle() }) {
                    Label("Favorite", systemImage: manga.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(manga.isFavorite ? .yellow : .primary)
                }
                .help(manga.isFavorite ? "Remove from Favorites" : "Add to Favorites")
            }
        }
        // ------------------------------------
        .alert("Rename Volume", isPresented: $showRenameAlert) {
            TextField("New Name", text: $newName)
            Button("Rename") { if let v = renamingVolume { performRename(v, to: newName) } }
            Button("Cancel", role: .cancel) { }
        }
        .background(Button("") { dismiss() }.keyboardShortcut(.cancelAction).opacity(0))
    }
    
    // --- ACTIONS ---
    
    func loadVolumes() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: manga.folderURL, includingPropertiesForKeys: nil) else { return }
        self.volumes = items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
    
    func openVolume(_ url: URL) {
        navPath.append(VolumeDestination(volumeURL: url, mangaID: manga.persistentModelID))
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
        let newURL = url.deletingLastPathComponent().appendingPathComponent(name)
        let oldName = url.lastPathComponent
        do {
            try fm.moveItem(at: url, to: newURL)
            if manga.readVolumes.contains(oldName) {
                manga.readVolumes.removeAll { $0 == oldName }
                manga.readVolumes.append(name)
            }
            if let progress = manga.readingProgress[oldName] {
                manga.readingProgress.removeValue(forKey: oldName)
                manga.readingProgress[name] = progress
            }
            loadVolumes()
        } catch { print("Rename failed: \(error)") }
    }
}

// --- FULLY OPTIMIZED VOLUME COVER ---
struct VolumeCover: View {
    let folderURL: URL
    let progress: Int?
    
    @State private var image: NSImage?
    @State private var loadFailed = false
    @State private var totalPages: Int = 0
    
    var body: some View {
        ZStack(alignment: .bottom) {
            if let img = image {
                Image(nsImage: img)
                    .resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 150, height: 220).clipped().cornerRadius(8).shadow(radius: 2)
            } else if loadFailed {
                RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.3)).frame(width: 150, height: 220)
                    .overlay(VStack {
                        Image(systemName: "photo.badge.exclamationmark").font(.largeTitle).foregroundStyle(.secondary.opacity(0.5))
                        Text("No Cover").font(.caption2).foregroundStyle(.secondary)
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
    
    func loadCover() {
        let cacheKey = folderURL.path as NSString
        
        // 1. CHECK BOTH CACHES
        let cachedImage = ThumbnailCache.shared.object(forKey: cacheKey)
        let cachedCount = PageCountCache.shared.object(forKey: cacheKey)
        
        if let img = cachedImage, let count = cachedCount {
            self.image = img
            self.totalPages = count.intValue
            return
        }
        
        // 2. MISS
        if let img = cachedImage { self.image = img }
        
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let validExts = ["jpg", "jpeg", "png", "avif", "webp"]
            
            guard let items = try? fm.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil) else {
                DispatchQueue.main.async { self.loadFailed = true }
                return
            }
            
            let images = items.filter { validExts.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            
            DispatchQueue.main.async {
                self.totalPages = images.count
                PageCountCache.shared.setObject(NSNumber(value: images.count), forKey: cacheKey)
                
                if self.image == nil {
                    if let first = images.first,
                       let source = CGImageSourceCreateWithURL(first as CFURL, nil),
                       let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 400] as CFDictionary) {
                        
                        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
                        ThumbnailCache.shared.setObject(nsImage, forKey: cacheKey)
                        self.image = nsImage
                    } else {
                        self.loadFailed = true
                    }
                }
            }
        }
    }
}
