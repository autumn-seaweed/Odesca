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

enum ReadingDirection: String, CaseIterable, Identifiable {
    case rightToLeft = "Right to Left (Manga)"
    case leftToRight = "Left to Right (Comic)"
    case vertical = "Vertical (Webtoon)"
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
    /// A stable key for a volume's read/progress state, expressed relative to the
    /// series root. For a top-level volume this is just the folder name (so it
    /// matches data saved before sub-series existed); for a volume inside a
    /// sub-series it's the path from the root, e.g. "Spin-offs/Volume 1", which
    /// keeps same-named volumes in different sub-series from colliding.
    func volumeKey(for url: URL) -> String {
        let root = folderURL.pathComponents
        let comps = url.pathComponents
        if comps.count > root.count, Array(comps.prefix(root.count)) == root {
            return comps.dropFirst(root.count).joined(separator: "/")
        }
        return url.lastPathComponent
    }

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

// Navigating into a sub-series: a folder under the series that groups further
// volumes (or further sub-series) rather than containing pages itself.
struct SubSeriesDestination: Hashable {
    let folderURL: URL
    let mangaID: PersistentIdentifier
}

// How a folder under a series should be treated when opened.
enum FolderKind {
    case volume     // contains pages — open in the reader
    case subSeries  // contains only subfolders/archives — drill in
    case empty
}

/// Auto-detect by content: a folder with images (or archives) directly inside is
/// a readable volume; a folder containing only subfolders is a sub-series to drill
/// into. (A chaptered volume — subfolders of images — reads as a sub-series of
/// chapters; use "Open as Single Volume" to merge it instead.)
func classifyFolder(_ url: URL) -> FolderKind {
    let fm = FileManager.default
    let imageExts: Set<String> = ["jpg", "jpeg", "png", "avif", "webp"]
    let archiveExts: Set<String> = ["epub", "zip", "cbz"]

    guard let items = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
        return .empty
    }

    var hasImages = false
    var hasArchives = false
    var hasSubfolders = false

    for item in items {
        if item.lastPathComponent.hasPrefix(".") { continue }
        let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        if isDir {
            hasSubfolders = true
        } else {
            let ext = item.pathExtension.lowercased()
            if imageExts.contains(ext) { hasImages = true }
            else if archiveExts.contains(ext) { hasArchives = true }
        }
    }

    if hasImages { return .volume }
    if hasArchives || hasSubfolders { return .subSeries }
    return .empty
}
