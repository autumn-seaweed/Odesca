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
    
    // NEW: Navigation Path for programmatic navigation
    @State private var navPath = NavigationPath()
    
    @State private var sortOrder = SortDescriptor(\MangaSeries.dateModified, order: .reverse)
    @State private var searchText = ""
    @State private var currentFilter: LibraryFilter = .all
    
    var body: some View {
        NavigationStack(path: $navPath) {
            VStack(spacing: 0) {
                // --- CUSTOM HEADER ---
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
                ScrollView {
                    // Pass the NavPath Binding to the grid so it can "Push" views
                    MangaGrid(sort: sortOrder, searchString: searchText, filter: currentFilter, navPath: $navPath)
                        .padding(.top, 10)
                }
            }
            .navigationTitle("Library")
            // ... inside NavigationStack ...

                // 1. Handle opening a Series (receives ID)
                .navigationDestination(for: PersistentIdentifier.self) { id in
                    if let manga = modelContext.model(for: id) as? MangaSeries {
                        SeriesDetailView(manga: manga, navPath: $navPath)
                    }
                }
                
                // 2. Handle opening a Volume (receives struct with ID)
                .navigationDestination(for: VolumeDestination.self) { dest in
                    if let manga = modelContext.model(for: dest.mangaID) as? MangaSeries {
                        MangaReaderView(volumeURL: dest.volumeURL, manga: manga)
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
