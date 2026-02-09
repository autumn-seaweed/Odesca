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
            // Create a security-scoped bookmark so we can access it next time
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
        guard let rootURL = openedRootURL else {
            print("❌ No root URL set, aborting sync.")
            return
        }
        
        print("🔍 Scanning folder: \(rootURL.path)")
        
        let fm = FileManager.default
        
        // 1. Get contents of the folder
        do {
            let items = try fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)
            let subfolders = items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            
            print("📂 Found \(subfolders.count) folders in root.")
            
            // 2. Map existing manga for quick lookup
            let existingMap = Dictionary(uniqueKeysWithValues: existingManga.map { ($0.folderURL.path, $0) })
            
            for folder in subfolders {
                let folderPath = folder.path
                let folderName = folder.lastPathComponent
                
                // Get Modification Date
                let attr = try? fm.attributesOfItem(atPath: folderPath)
                let modDate = attr?[.modificationDate] as? Date ?? Date()
                
                // Count Volumes (sub-folders inside the series folder)
                let volItems = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
                let volCount = volItems.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.count
                
                if let existing = existingMap[folderPath] {
                    // Update if changed
                    if existing.volumeCount != volCount || existing.dateModified != modDate {
                        existing.volumeCount = volCount
                        existing.dateModified = modDate
                        print("🔄 Updated: \(folderName)")
                    }
                } else {
                    // Create New
                    let newManga = MangaSeries(title: folderName, folderURL: folder)
                    newManga.dateModified = modDate
                    newManga.volumeCount = volCount
                    context.insert(newManga)
                    print("✨ Added: \(folderName)")
                }
            }
            
            // 3. Cleanup Deleted Items
            // (Only delete if we are SURE we scanned the folder correctly)
            if !subfolders.isEmpty {
                let diskPaths = Set(subfolders.map { $0.path })
                for manga in existingManga {
                    if !diskPaths.contains(manga.folderURL.path) {
                        context.delete(manga)
                        print("🗑️ Removed: \(manga.title)")
                    }
                }
            }
            
            // 4. Force Save
            try? context.save()
            print("💾 Sync Complete.")
            
        } catch {
            print("❌ Failed to scan directory: \(error.localizedDescription)")
        }
    }
}
