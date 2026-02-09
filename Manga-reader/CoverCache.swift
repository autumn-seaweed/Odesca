//
//  CoverCache.swift
//  Manga-reader
//
//  Created by Aki Toyoshima on 2026/02/09.
//

import SwiftUI

class CoverCache {
    static let shared = CoverCache()
    private let fileManager = FileManager.default
    private var cacheFolderURL: URL?
    
    init() {
        // Create a hidden folder in Application Support to store covers
        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let cacheDir = appSupport.appendingPathComponent("CoverCache", isDirectory: true)
            try? fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            self.cacheFolderURL = cacheDir
        }
    }
    
    func fileURL(for id: String) -> URL? {
        return cacheFolderURL?.appendingPathComponent(id).appendingPathExtension("jpg")
    }
    
    // SAVE to Disk
    func save(image: NSImage, for id: String) {
        guard let url = fileURL(for: id),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) // Compress slightly
        else { return }
        
        try? data.write(to: url)
    }
    
    // LOAD from Disk
    func load(for id: String) -> NSImage? {
        guard let url = fileURL(for: id),
              let data = try? Data(contentsOf: url)
        else { return nil }
        
        return NSImage(data: data)
    }
    
    // DELETE (For "Refresh Cover")
    func delete(for id: String) {
        guard let url = fileURL(for: id) else { return }
        try? fileManager.removeItem(at: url)
    }
}
