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
    private let legacyBookmarkKey = "MangaLibraryBookmark"

    // Resolved, security-scoped roots for the current session, keyed by Library id.
    private var roots: [UUID: URL] = [:]

    private let archiveExts = ["epub", "zip", "cbz"]

    // MARK: - Library management

    func addLibrary(url: URL, context: ModelContext) {
        do {
            let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            let lib = Library(name: url.lastPathComponent, bookmark: data)
            context.insert(lib)
            if url.startAccessingSecurityScopedResource() {
                roots[lib.id] = url
            }
            try? context.save()
            scanLibrary(lib, root: url, context: context)
            print("✅ Added library: \(lib.name)")
        } catch {
            print("❌ Failed to add library: \(error)")
        }
    }

    func removeLibrary(_ library: Library, context: ModelContext) {
        // Explicit removal: drop the series (and their history) for this library.
        let id = library.id
        if let url = roots[id] { url.stopAccessingSecurityScopedResource(); roots[id] = nil }
        let descriptor = FetchDescriptor<MangaSeries>(predicate: #Predicate { $0.libraryID == id })
        if let series = try? context.fetch(descriptor) {
            for s in series { context.delete(s) }
        }
        context.delete(library)
        try? context.save()
    }

    /// Resolve every library's bookmark and start security-scoped access. Returns
    /// the set of library ids that are currently reachable.
    @discardableResult
    func resolveAll(_ libraries: [Library]) -> Set<UUID> {
        var available: Set<UUID> = []
        for lib in libraries {
            if let url = roots[lib.id] { available.insert(lib.id); _ = url; continue }
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: lib.bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) else { continue }
            if url.startAccessingSecurityScopedResource() {
                roots[lib.id] = url
                available.insert(lib.id)
            }
        }
        return available
    }

    // MARK: - Sync

    func syncAll(context: ModelContext, libraries: [Library], existingManga: [MangaSeries]) {
        migrateLegacyIfNeeded(context: context, libraries: libraries, existingManga: existingManga)

        // Re-fetch in case migration created a library.
        let libs = (try? context.fetch(FetchDescriptor<Library>())) ?? libraries
        let available = resolveAll(libs)

        for lib in libs {
            if available.contains(lib.id), let root = roots[lib.id] {
                scanLibrary(lib, root: root, context: context)
            } else {
                // Ejected / unreachable — keep the series and their history, just
                // flag them so the UI can show they're offline.
                markAvailability(false, libraryID: lib.id, context: context)
            }
        }
        try? context.save()
    }

    private func scanLibrary(_ library: Library, root: URL, context: ModelContext) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
        let subfolders = items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && !$0.lastPathComponent.hasPrefix(".") }

        let libID = library.id
        let existing = (try? context.fetch(FetchDescriptor<MangaSeries>(predicate: #Predicate { $0.libraryID == libID }))) ?? []
        let existingByPath = Dictionary(existing.map { ($0.relativePath, $0) }, uniquingKeysWith: { a, _ in a })

        var seenPaths = Set<String>()

        for folder in subfolders {
            let name = folder.lastPathComponent
            let rel = name // series sit directly under the library root
            seenPaths.insert(rel)

            let attr = try? fm.attributesOfItem(atPath: folder.path)
            let modDate = attr?[.modificationDate] as? Date ?? Date()

            let volItems = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            let validVolumes = volItems.filter { item in
                if item.lastPathComponent.hasPrefix(".") { return false }
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                return isDir || archiveExts.contains(item.pathExtension.lowercased())
            }
            let volCount = validVolumes.count
            let validNames = Set(validVolumes.map { $0.lastPathComponent })

            if let series = existingByPath[rel] {
                series.folderURL = folder            // refresh in case the mount path changed
                series.isAvailable = true
                if series.volumeCount != volCount { series.volumeCount = volCount }
                if series.dateModified != modDate { series.dateModified = modDate }
                // Only prune top-level read entries; nested sub-series keys contain "/".
                let cleaned = series.readVolumes.filter { $0.contains("/") || validNames.contains($0) }
                if cleaned.count != series.readVolumes.count { series.readVolumes = cleaned }
            } else {
                let newManga = MangaSeries(title: name, folderURL: folder)
                newManga.libraryID = libID
                newManga.relativePath = rel
                newManga.dateModified = modDate
                newManga.volumeCount = volCount
                newManga.isAvailable = true
                context.insert(newManga)
                print("✨ Added: \(name)")
            }
        }

        // Library is reachable, so a series folder that's gone was genuinely removed.
        for series in existing where !seenPaths.contains(series.relativePath) {
            context.delete(series)
        }
    }

    private func markAvailability(_ value: Bool, libraryID: UUID, context: ModelContext) {
        let descriptor = FetchDescriptor<MangaSeries>(predicate: #Predicate { $0.libraryID == libraryID })
        guard let series = try? context.fetch(descriptor) else { return }
        for s in series where s.isAvailable != value { s.isAvailable = value }
    }

    // MARK: - Legacy migration

    /// On first launch of the multi-library build, adopt the user's old single
    /// folder (and re-home their existing series into it) so nothing is lost.
    private func migrateLegacyIfNeeded(context: ModelContext, libraries: [Library], existingManga: [MangaSeries]) {
        guard libraries.isEmpty,
              let data = UserDefaults.standard.data(forKey: legacyBookmarkKey) else { return }

        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) else { return }

        let lib = Library(name: url.lastPathComponent, bookmark: data)
        context.insert(lib)
        if url.startAccessingSecurityScopedResource() { roots[lib.id] = url }

        let rootComponents = url.pathComponents
        for series in existingManga where series.libraryID == nil {
            series.libraryID = lib.id
            let comps = series.folderURL.pathComponents
            if comps.count > rootComponents.count, Array(comps.prefix(rootComponents.count)) == rootComponents {
                series.relativePath = comps.dropFirst(rootComponents.count).joined(separator: "/")
            } else {
                series.relativePath = series.folderURL.lastPathComponent
            }
        }
        UserDefaults.standard.removeObject(forKey: legacyBookmarkKey)
        try? context.save()
        print("🔀 Migrated legacy library: \(lib.name)")
    }
}
