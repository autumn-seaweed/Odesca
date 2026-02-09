//
//  Item.swift
//  Manga-reader
//
//  Created by Aki Toyoshima on 2026/02/09.
//

import SwiftUI
import SwiftData
import AppKit

@Model
final class MangaSeries {
    var title: String
    var folderURL: URL
    var lastPageRead: Int
    var isFinished: Bool
    var readVolumes: [String] = []
    var tags: [String] = []
    var dateAdded: Date
    
    // NEW FIELDS
    var dateModified: Date     // Tracks file system changes
    var volumeCount: Int       // Tracks total volumes (for "2 of 5")
    var isFavorite: Bool       // For the Favorites filter
    var readingProgress: [String: Int] = [:]
    
    init(title: String, folderURL: URL) {
        self.title = title
        self.folderURL = folderURL
        self.lastPageRead = 0
        self.isFinished = false
        self.readVolumes = []
        self.tags = []
        self.dateAdded = Date()
        
        // Defaults
        self.dateModified = Date()
        self.volumeCount = 0
        self.isFavorite = false
        self.readingProgress = [:]
    }
}

// Keep your existing 'extension MangaSeries' for coverImage logic here
extension MangaSeries {
    var coverImage: NSImage? {
        // ... (Paste your recursive cover finder logic from the previous step here) ...
        // I will omit it here to save space, but make sure you keep the robust version!
        _ = folderURL.startAccessingSecurityScopedResource()
        defer { folderURL.stopAccessingSecurityScopedResource() }
        
        let fm = FileManager.default
        let validExts = ["jpg", "jpeg", "png", "avif", "webp"]
        
        func findImage(in url: URL) -> NSImage? {
            guard let items = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else { return nil }
            let images = items.filter { validExts.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            if let first = images.first, let data = try? Data(contentsOf: first) { return NSImage(data: data) }
            return nil
        }
        
        if let img = findImage(in: folderURL) { return img }
        
        guard let subfolders = try? fm.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)
            .filter({ (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true })
            .sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
        else { return nil }
        
        for folder in subfolders {
            if let img = findImage(in: folder) { return img }
        }
        return nil
    }
}

// Update this struct to use ID instead of the object
struct VolumeDestination: Hashable {
    let volumeURL: URL
    let mangaID: PersistentIdentifier // <--- Store ID (Safe), not MangaSeries (Unsafe)
}
