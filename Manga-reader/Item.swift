//
//  Item.swift
//  Manga-reader
//
//  Created by Aki Toyoshima on 2026/01/31.
//

import SwiftUI
import SwiftData
import AppKit

// --- GLOBAL DEFINITIONS ---
enum LibraryFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case favorites = "Favorites"
    case toRead = "To Read"
    case unread = "Unread"
    var id: String { self.rawValue }
}

@Model
final class MangaSeries {
    // --------------------------------------------------------
    // ✅ SAFE RENAMING EXAMPLE
    // If you ever want to rename 'title', do it like this:
    // @Attribute(originalName: "title") var seriesName: String
    // --------------------------------------------------------
    var title: String
    
    var folderURL: URL
    var lastPageRead: Int
    var isFinished: Bool
    var readVolumes: [String] = []
    var tags: [String] = []
    var dateAdded: Date
    
    // --------------------------------------------------------
    // ✅ ROBUST ADDITIONS
    // These have default values assigned (= ...).
    // This means if you load an OLD database that doesn't have
    // these fields, SwiftData will fill them in automatically
    // instead of crashing.
    // --------------------------------------------------------
    var dateModified: Date = Date()
    var volumeCount: Int = 0
    var isFavorite: Bool = false
    var readingProgress: [String: Int] = [:]
    
    // Example: If you wanted to add a 'rating' later, you would add:
    // var rating: Int = 0
    
    init(title: String, folderURL: URL) {
        self.title = title
        self.folderURL = folderURL
        self.lastPageRead = 0
        self.isFinished = false
        self.readVolumes = []
        self.tags = []
        self.dateAdded = Date()
        
        // Always initialize new properties here too
        self.dateModified = Date()
        self.volumeCount = 0
        self.isFavorite = false
        self.readingProgress = [:]
    }
}

// --- HELPER LOGIC (Extensions) ---
extension MangaSeries {
    var coverImage: NSImage? {
        // Secure access is required for Sandbox apps
        _ = folderURL.startAccessingSecurityScopedResource()
        defer { folderURL.stopAccessingSecurityScopedResource() }
        
        let fm = FileManager.default
        let validExts = ["jpg", "jpeg", "png", "avif", "webp"]
        
        // 1. Check Root Folder
        if let img = findImage(in: folderURL, fm: fm, exts: validExts) { return img }
        
        // 2. Check Subfolders (Volume 1, etc.)
        guard let subfolders = try? fm.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)
            .filter({ (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true })
            .sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
        else { return nil }
        
        for folder in subfolders {
            if let img = findImage(in: folder, fm: fm, exts: validExts) { return img }
        }
        return nil
    }
    
    private func findImage(in url: URL, fm: FileManager, exts: [String]) -> NSImage? {
        guard let items = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else { return nil }
        let images = items.filter { exts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        
        // Attempt to load the first image found
        if let first = images.first, let data = try? Data(contentsOf: first) {
            return NSImage(data: data)
        }
        return nil
    }
}

struct VolumeDestination: Hashable {
    let volumeURL: URL
    let mangaID: PersistentIdentifier
}
