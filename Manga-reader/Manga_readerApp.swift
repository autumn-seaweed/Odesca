//
//  Manga_readerApp.swift
//  Manga-reader
//
//  Created by Aki Toyoshima on 2026/02/09.
//

import SwiftUI
import SwiftData

@main
struct Manga_readerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [MangaSeries.self, Library.self])
        .commands {
            ShortcutCommands()
        }
    }
}

// --- Context actions published by whichever view is focused ---
struct ReaderActions {
    var gallery: () -> Void
    var bookmark: () -> Void
    var bookmarksPanel: () -> Void
    var offset: () -> Void
    var favorite: () -> Void
    var markRead: () -> Void
}

struct LibraryActions {
    var open: () -> Void
    var favorite: () -> Void
    var markRead: () -> Void
    var delete: () -> Void
}

extension FocusedValues {
    private struct ReaderActionsKey: FocusedValueKey { typealias Value = ReaderActions }
    private struct LibraryActionsKey: FocusedValueKey { typealias Value = LibraryActions }
    var readerActions: ReaderActions? {
        get { self[ReaderActionsKey.self] }
        set { self[ReaderActionsKey.self] = newValue }
    }
    var libraryActions: LibraryActions? {
        get { self[LibraryActionsKey.self] }
        set { self[LibraryActionsKey.self] = newValue }
    }
}

// --- Menu-bar "Shortcuts" menu — items act on the focused context ---
struct ShortcutCommands: Commands {
    @FocusedValue(\.readerActions) private var reader: ReaderActions?
    @FocusedValue(\.libraryActions) private var library: LibraryActions?

    var body: some Commands {
        CommandMenu("Shortcuts") {
            Section("Reader") {
                Button("Page gallery  (G)") { reader?.gallery() }.disabled(reader == nil)
                Button("Bookmark this page  (B)") { reader?.bookmark() }.disabled(reader == nil)
                Button("Bookmarks panel  (L)") { reader?.bookmarksPanel() }.disabled(reader == nil)
                Button("Offset by one page  (O)") { reader?.offset() }.disabled(reader == nil)
                Button("Toggle favorite  (F)") { reader?.favorite() }.disabled(reader == nil)
                Button("Mark volume read  (R)") { reader?.markRead() }.disabled(reader == nil)
            }
            Section("Library & series") {
                Button("Open selection  (Return)") { library?.open() }.disabled(library == nil)
                Button("Toggle favorite  (F)") { library?.favorite() }.disabled(library == nil)
                Button("Mark read / unread  (R)") { library?.markRead() }.disabled(library == nil)
                Button("Delete  (⌫)") { library?.delete() }.disabled(library == nil)
            }
        }
    }
}
