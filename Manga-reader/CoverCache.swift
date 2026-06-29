//
//  CoverCache.swift
//  Manga-reader
//
//  Created by Aki Toyoshima on 2026/02/09.
//

import SwiftUI
import ImageIO

/// Deterministic (FNV-1a) cache id from a stable string (e.g. a folder path).
/// Swift's `hashValue` is seeded per process, so it can't key a disk cache that
/// must survive relaunches — this can.
func stableCacheID(_ s: String) -> String {
    var h: UInt64 = 1469598103934665603
    for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
    return String(h, radix: 16)
}

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
    
    // LOAD from Disk — fully decode now (on the caller's background thread) so we
    // don't pay a lazy decode on the main thread while scrolling.
    func load(for id: String) -> NSImage? {
        guard let url = fileURL(for: id),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
    
    // DELETE (For "Refresh Cover")
    func delete(for id: String) {
        guard let url = fileURL(for: id) else { return }
        try? fileManager.removeItem(at: url)
    }
}
