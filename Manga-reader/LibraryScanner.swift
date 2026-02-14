//
//  LibraryScanner.swift
//  Manga-reader
//
//  Created by Aki Toyoshima on 2026/02/09.
//

import Foundation
import SwiftUI
import SwiftData
import Combine

@MainActor
class LibraryScanner: ObservableObject {
    private let bookmarkKey = "MangaLibraryBookmark"
    
    @Published var openedRootURL: URL?
    
    init() {
        if let url = getRootFolder() {
            if url.startAccessingSecurityScopedResource() {
                self.openedRootURL = url
                print("📖 Restored access to: \(url.path)")
            } else {
                print("⚠️ Failed to restore access to bookmark.")
            }
        }
    }
    
    func setRootFolder(url: URL) {
        do {
            let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: bookmarkKey)
            
            if url.startAccessingSecurityScopedResource() {
                self.openedRootURL = url
                print("✅ Access granted to: \(url.path)")
            }
        } catch {
            print("❌ Failed to save bookmark: \(error)")
        }
    }
    
    func getRootFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var isStale = false
        return try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
    }
    
    func syncLibrary(context: ModelContext, existingManga: [MangaSeries]) {
        guard let rootURL = openedRootURL else { return }
        print("🔍 Scanning folder: \(rootURL.path)")
        
        let fm = FileManager.default
        do {
            // Options: Skips Hidden Files automatically handles .DS_Store, etc.
            let items = try fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            let subfolders = items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            
            let existingMap = Dictionary(uniqueKeysWithValues: existingManga.map { ($0.folderURL.path, $0) })
            
            for folder in subfolders {
                let folderPath = folder.path
                let folderName = folder.lastPathComponent
                
                // Extra safety check for hidden folders that might slip through
                if folderName.hasPrefix(".") { continue }
                
                let attr = try? fm.attributesOfItem(atPath: folderPath)
                let modDate = attr?[.modificationDate] as? Date ?? Date()
                
                // Get contents of the Series folder
                let volItems = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                
                // 1. Identify Valid Volumes (Filter out .Panels, etc)
                let validVolumes = volItems.filter { item in
                    let name = item.lastPathComponent
                    if name.hasPrefix(".") { return false } // Explicitly ignore .Panels, .DS_Store
                    
                    let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    let isEpub = item.pathExtension.lowercased() == "epub"
                    
                    return isDir || isEpub
                }
                
                let volCount = validVolumes.count
                // Create a set of valid names for cleanup
                let validNamesSet = Set(validVolumes.map { $0.lastPathComponent })
                
                if let existing = existingMap[folderPath] {
                    // Update Metadata
                    if existing.volumeCount != volCount || existing.dateModified != modDate {
                        existing.volumeCount = volCount
                        existing.dateModified = modDate
                        print("🔄 Updated: \(folderName)")
                    }
                    
                    // 👇 NEW: Sanitize Read History
                    // Removes "Ghost" volumes (like .Panels) that were previously marked read but are now ignored
                    let cleanedReadVolumes = existing.readVolumes.filter { validNamesSet.contains($0) }
                    if cleanedReadVolumes.count != existing.readVolumes.count {
                        existing.readVolumes = cleanedReadVolumes
                        print("🧹 Cleaned up read history for \(folderName)")
                    }
                    
                } else {
                    let newManga = MangaSeries(title: folderName, folderURL: folder)
                    newManga.dateModified = modDate
                    newManga.volumeCount = volCount
                    context.insert(newManga)
                    print("✨ Added: \(folderName)")
                }
            }
            
            // Cleanup Deleted Items
            if !subfolders.isEmpty {
                let diskPaths = Set(subfolders.map { $0.path })
                for manga in existingManga {
                    if !diskPaths.contains(manga.folderURL.path) {
                        context.delete(manga)
                    }
                }
            }
            try? context.save()
            print("💾 Sync Complete.")
        } catch {
            print("❌ Failed to scan directory: \(error.localizedDescription)")
        }
    }
}
