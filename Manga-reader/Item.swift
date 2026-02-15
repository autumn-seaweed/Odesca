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
    var title: String
    var folderURL: URL
    var lastPageRead: Int
    var isFinished: Bool
    var readVolumes: [String] = []
    var tags: [String] = []
    var dateAdded: Date
    
    // Tracks file system changes (Scanner)
    var dateModified: Date = Date()
    
    // 👇 NEW: Tracks when YOU last opened the series
    var lastReadDate: Date = Date.distantPast
    
    var volumeCount: Int = 0
    var isFavorite: Bool = false
    var readingProgress: [String: Int] = [:]
    
    init(title: String, folderURL: URL) {
        self.title = title
        self.folderURL = folderURL
        self.lastPageRead = 0
        self.isFinished = false
        self.readVolumes = []
        self.tags = []
        self.dateAdded = Date()
        self.dateModified = Date()
        self.lastReadDate = Date.distantPast
        self.volumeCount = 0
        self.isFavorite = false
        self.readingProgress = [:]
    }
}

// --- HELPER LOGIC ---
extension MangaSeries {
    var coverImage: NSImage? {
        _ = folderURL.startAccessingSecurityScopedResource()
        defer { folderURL.stopAccessingSecurityScopedResource() }
        
        let fm = FileManager.default
        let validExts = ["jpg", "jpeg", "png", "avif", "webp"]
        
        if let img = findImage(in: folderURL, fm: fm, exts: validExts) { return img }
        
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
