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
    @State private var selectedLibraryID: UUID? = nil

    @Query(sort: \Library.dateAdded) private var libraries: [Library]

    @Query(sort: \MangaSeries.lastReadDate, order: .reverse)
    private var recentlyReadManga: [MangaSeries]

    var body: some View {
        NavigationSplitView {
            // --- LIBRARY SIDEBAR ---
            List(selection: $selectedLibraryID) {
                Label("All Libraries", systemImage: "books.vertical").tag(UUID?.none)

                Section("Libraries") {
                    ForEach(libraries) { lib in
                        Label(lib.name, systemImage: "folder")
                            .tag(Optional(lib.id))
                            .contextMenu {
                                Button(role: .destructive) {
                                    if selectedLibraryID == lib.id { selectedLibraryID = nil }
                                    scanner.removeLibrary(lib, context: modelContext)
                                } label: { Label("Remove Library", systemImage: "trash") }
                            }
                    }
                }
            }
            .navigationTitle("Library")
            .safeAreaInset(edge: .bottom) {
                Button(action: addLibrary) {
                    Label("Add Library", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
        } detail: {
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

                    let recents = recentlyReadManga.filter { $0.lastReadDate > Date.distantPast }
                    let showRecents = searchText.isEmpty && currentFilter == .all && selectedLibraryID == nil

                    MangaGrid(
                        sort: sortOrder,
                        searchString: searchText,
                        filter: currentFilter,
                        libraryID: selectedLibraryID,
                        navPath: $navPath,
                        recents: showRecents ? Array(recents.prefix(10)) : [],
                        onAddLibrary: addLibrary
                    )
                }
                .navigationTitle(libraryTitle)
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
                .navigationDestination(for: SubSeriesDestination.self) { dest in
                    if let manga = modelContext.model(for: dest.mangaID) as? MangaSeries {
                        SeriesDetailView(manga: manga, folderOverride: dest.folderURL, navPath: $navPath)
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
                        Button(action: addLibrary) { Label("Add Library", systemImage: "folder.badge.plus") }
                    }
                }
            }
        }
        .onAppear { sync() }
    }

    private var libraryTitle: String {
        if let id = selectedLibraryID, let lib = libraries.first(where: { $0.id == id }) { return lib.name }
        return "All Libraries"
    }

    func sync() {
        let existing = (try? modelContext.fetch(FetchDescriptor<MangaSeries>())) ?? []
        scanner.syncAll(context: modelContext, libraries: libraries, existingManga: existing)
    }

    func addLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            scanner.addLibrary(url: url, context: modelContext)
        }
    }
}
