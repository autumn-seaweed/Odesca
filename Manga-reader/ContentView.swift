//
//  ContentView.swift
//  Manga-reader
//
//  Created by Aki Toyoshima on 2026/02/09.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) var modelContext
    @StateObject private var scanner = LibraryScanner()
    
    @State private var navPath = NavigationPath()
    @State private var sortOrder = SortDescriptor(\MangaSeries.dateModified, order: .reverse)
    @State private var searchText = ""
    @State private var currentFilter: LibraryFilter = .all
    
    // 👇 NEW QUERY: Sort by lastReadDate so we get the most recently opened items first
    @Query(sort: \MangaSeries.lastReadDate, order: .reverse)
    private var recentlyReadManga: [MangaSeries]
    
    var body: some View {
        NavigationStack(path: $navPath) {
            VStack(spacing: 0) {
                // --- HEADER ---
                VStack(spacing: 12) {
                    HStack {
                        Picker("Filter", selection: $currentFilter) {
                            Text("All").tag(LibraryFilter.all)
                            Text("Unread").tag(LibraryFilter.unread)
                            Text("To Read").tag(LibraryFilter.toRead)
                            Text("Favorites").tag(LibraryFilter.favorites)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 400)
                        
                        Spacer()
                        
                        Picker("Sort", selection: $sortOrder) {
                            Text("Date Modified").tag(SortDescriptor(\MangaSeries.dateModified, order: .reverse))
                            Text("Date Added").tag(SortDescriptor(\MangaSeries.dateAdded, order: .reverse))
                            Text("Title A-Z").tag(SortDescriptor(\MangaSeries.title, order: .forward))
                        }
                        .frame(width: 140)
                    }
                    .padding(.horizontal)
                    .padding(.top, 10)
                    
                    Divider()
                }
                .background(.ultraThinMaterial)
                
                // --- MAIN CONTENT ---
                // Filter: Only show items that have a valid lastReadDate
                let recents = recentlyReadManga.filter { $0.lastReadDate > Date.distantPast }
                
                MangaGrid(
                    sort: sortOrder,
                    searchString: searchText,
                    filter: currentFilter,
                    navPath: $navPath,
                    // Pass the list sorted by "Last Opened"
                    recents: (searchText.isEmpty && currentFilter == .all) ? Array(recents.prefix(10)) : []
                )
            }
            .navigationTitle("Library")
            .navigationDestination(for: PersistentIdentifier.self) { id in
                if let manga = modelContext.model(for: id) as? MangaSeries {
                    SeriesDetailView(manga: manga, navPath: $navPath)
                }
            }
            .navigationDestination(for: VolumeDestination.self) { dest in
                if let manga = modelContext.model(for: dest.mangaID) as? MangaSeries {
                    MangaReaderView(volumeURL: dest.volumeURL, manga: manga)
                }
            }
            .navigationDestination(for: NovelDestination.self) { dest in
                if let manga = modelContext.model(for: dest.mangaID) as? MangaSeries {
                    NovelReaderView(volumeURL: dest.url, manga: manga)
                }
            }
            .searchable(text: $searchText, prompt: "Search manga...")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: sync) { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: selectRootFolder) { Label("Folder", systemImage: "folder.badge.gear") }
                }
            }
            .onAppear { sync() }
        }
    }
    
    func sync() {
        let descriptor = FetchDescriptor<MangaSeries>()
        if let existing = try? modelContext.fetch(descriptor) {
            scanner.syncLibrary(context: modelContext, existingManga: existing)
        }
    }
    
    func selectRootFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK {
            if let url = panel.url {
                scanner.setRootFolder(url: url)
                sync()
            }
        }
    }
}
