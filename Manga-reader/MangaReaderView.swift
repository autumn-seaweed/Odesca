//
//  MangaReaderView.swift
//  Manga-reader
//
//  Created by Aki Toyoshima on 2026/02/09.
//

import Foundation
import SwiftUI
import AppKit

enum ReadingDirection: String, CaseIterable, Identifiable {
    case rightToLeft = "Right to Left (Manga)"
    case leftToRight = "Left to Right (Comic)"
    case vertical = "Vertical (Webtoon)"
    var id: String { self.rawValue }
}

struct MangaReaderView: View {
    let volumeURL: URL
    @Bindable var manga: MangaSeries
    
    @State private var currentIndex = 0
    @FocusState private var isFocused: Bool
    @State private var pages: [URL] = []
    @State private var tempArchiveFolder: URL? = nil
    
    @AppStorage("readingDirection") private var readingDirection: ReadingDirection = .rightToLeft
    @AppStorage("isTwoPageMode") private var isTwoPageMode = false
    @AppStorage("useCoverOffset") private var useCoverOffset = true

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                let layout = calculateLayout(for: currentIndex, in: pages)
                
                // PAGES LAYER
                ZStack {
                    if isTwoPageMode {
                        if let centerPage = layout.center {
                            PageView(url: centerPage, size: geo.size, alignment: .center)
                        } else {
                            HStack(spacing: 0) {
                                let leftPage = readingDirection == .rightToLeft ? layout.left : layout.right
                                let rightPage = readingDirection == .rightToLeft ? layout.right : layout.left
                                
                                if let page = leftPage {
                                    PageView(url: page,
                                             size: CGSize(width: geo.size.width / 2, height: geo.size.height),
                                             alignment: .trailing)
                                } else { Spacer().frame(width: geo.size.width / 2) }
                                
                                if let page = rightPage {
                                    PageView(url: page,
                                             size: CGSize(width: geo.size.width / 2, height: geo.size.height),
                                             alignment: .leading)
                                } else { Spacer().frame(width: geo.size.width / 2) }
                            }
                        }
                    } else {
                        if pages.indices.contains(currentIndex) {
                            PageView(url: pages[currentIndex], size: geo.size, alignment: .center)
                        }
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                
                // TAP ZONES
                HStack(spacing: 0) {
                    Color.clear.contentShape(Rectangle()).frame(width: 80)
                        .onTapGesture {
                            if readingDirection == .rightToLeft { navigateNext(step: isTwoPageMode ? layout.step : 1) }
                            else { navigatePrevious() }
                        }
                    Spacer()
                    Color.clear.contentShape(Rectangle()).frame(width: 80)
                        .onTapGesture {
                            if readingDirection == .rightToLeft { navigatePrevious() }
                            else { navigateNext(step: isTwoPageMode ? layout.step : 1) }
                        }
                }
                
                // PROGRESS BAR
                VStack {
                    Spacer()
                    GeometryReader { barGeo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Color.white.opacity(0.3))
                            Rectangle().fill(Color.accentColor)
                                .frame(width: barGeo.size.width * (CGFloat(currentIndex + 1) / CGFloat(max(1, pages.count))))
                        }
                    }
                    .frame(height: 3)
                }
                .padding(.bottom, 0)
            }
        }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onAppear {
            loadPages()
            restoreProgress()
            isFocused = true
            
            // 👇 UPDATE LAST READ DATE
            manga.lastReadDate = Date()
        }
        .onDisappear {
            if let tmp = tempArchiveFolder { try? FileManager.default.removeItem(at: tmp) }
        }
        .onChange(of: currentIndex) { _, newIndex in saveProgress(page: newIndex) }
        .onKeyPress(.leftArrow) {
            let layout = calculateLayout(for: currentIndex, in: pages)
            if readingDirection == .rightToLeft { navigateNext(step: isTwoPageMode ? layout.step : 1) }
            else { navigatePrevious() }
            return .handled
        }
        .onKeyPress(.rightArrow) {
            let layout = calculateLayout(for: currentIndex, in: pages)
            if readingDirection == .rightToLeft { navigatePrevious() }
            else { navigateNext(step: isTwoPageMode ? layout.step : 1) }
            return .handled
        }
        .navigationTitle(currentTitle)
        .navigationSubtitle(currentSubtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("View Mode", selection: $isTwoPageMode) {
                    Image(systemName: "rectangle").tag(false).help("Single Page View")
                    Image(systemName: "book").tag(true).help("Two Page View")
                }
                .pickerStyle(.segmented).frame(width: 100)
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: { if currentIndex < pages.count - 1 { currentIndex += 1 } }) {
                    Label("Offset +1", systemImage: "arrow.forward.square")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Toggle("Show Cover Alone", isOn: $useCoverOffset)
                    Divider()
                    Picker("Direction", selection: $readingDirection) {
                        Text("Right to Left (Manga)").tag(ReadingDirection.rightToLeft)
                        Text("Left to Right (Comic)").tag(ReadingDirection.leftToRight)
                    }
                } label: { Label("Options", systemImage: "gear") }
            }
            ToolbarItem {
                Button(action: markAsRead) {
                    Label("Mark Read", systemImage: isVolumeRead ? "checkmark.circle.fill" : "circle")
                }
            }
        }
    }
    
    private var currentTitle: String { "\(manga.title)  ›  \(volumeURL.lastPathComponent)" }
    private var currentSubtitle: String {
        guard pages.indices.contains(currentIndex) else { return "" }
        return "\(pages[currentIndex].lastPathComponent)   (\(currentIndex + 1) / \(pages.count))"
    }
    
    struct PageLayout {
        var right: URL? = nil
        var left: URL? = nil
        var center: URL? = nil
        var step: Int = 2
    }
    
    func calculateLayout(for index: Int, in pages: [URL]) -> PageLayout {
        guard index < pages.count else { return PageLayout(step: 0) }
        let currentURL = pages[index]
        if useCoverOffset && index == 0 { return PageLayout(center: currentURL, step: 1) }
        if isWide(currentURL) { return PageLayout(center: currentURL, step: 1) }
        
        let nextIndex = index + 1
        var leftURL: URL? = nil
        var step = 1
        
        if nextIndex < pages.count {
            let nextURL = pages[nextIndex]
            if isWide(nextURL) { leftURL = nil; step = 1 }
            else { leftURL = nextURL; step = 2 }
        }
        return PageLayout(right: currentURL, left: leftURL, step: step)
    }
    
    func isWide(_ url: URL) -> Bool {
        guard let imageRep = NSImageRep(contentsOf: url) else { return false }
        return imageRep.pixelsWide > imageRep.pixelsHigh
    }

    func loadPages() {
        let ext = volumeURL.pathExtension.lowercased()
        if ["epub", "zip", "cbz"].contains(ext) { loadArchive() } else { loadDirectory(volumeURL) }
    }
    
    func loadDirectory(_ dir: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        self.pages = items
            .filter { ["jpg", "jpeg", "png", "avif", "webp"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
    
    func loadArchive() {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        self.tempArchiveFolder = tempDir
        
        do {
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-q", volumeURL.path, "-d", tempDir.path]
            try process.run(); process.waitUntilExit()
            
            if let enumerator = fm.enumerator(at: tempDir, includingPropertiesForKeys: nil) {
                var foundImages: [URL] = []
                for case let fileURL as URL in enumerator {
                    if ["jpg", "jpeg", "png", "avif", "webp"].contains(fileURL.pathExtension.lowercased()) {
                        if !fileURL.path.contains("__MACOSX") && !fileURL.lastPathComponent.hasPrefix(".") {
                            foundImages.append(fileURL)
                        }
                    }
                }
                self.pages = foundImages.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            }
        } catch { print("Failed to unzip archive: \(error)") }
    }
    
    func navigateNext(step: Int) {
        if currentIndex + step < pages.count { currentIndex += step }
        else { currentIndex = pages.count - 1 }
    }
    
    func navigatePrevious() {
        if currentIndex == 0 { return }
        if !isTwoPageMode { currentIndex -= 1; return }
        if useCoverOffset && currentIndex == 1 { currentIndex = 0; return }
        let prevIndex1 = currentIndex - 1
        if prevIndex1 >= 0 && isWide(pages[prevIndex1]) { currentIndex -= 1; return }
        currentIndex = max(0, currentIndex - 2)
    }
    
    func saveProgress(page: Int) {
        let volName = volumeURL.lastPathComponent
        let totalPages = pages.count
        guard totalPages > 0 else { return }
        
        // Also update timestamp on progress change
        manga.lastReadDate = Date()
        
        if page >= totalPages - 1 {
            if !manga.readVolumes.contains(volName) { manga.readVolumes.append(volName) }
            manga.readingProgress.removeValue(forKey: volName)
            return
        }
        if page > 0 { manga.readingProgress[volName] = page }
        else { manga.readingProgress.removeValue(forKey: volName) }
    }
    
    func restoreProgress() {
        let volName = volumeURL.lastPathComponent
        guard let savedPage = manga.readingProgress[volName] else { return }
        let totalPages = pages.count
        guard totalPages > 0 else { return }
        
        let percentage = Double(savedPage) / Double(totalPages)
        if percentage < 0.95 {
            if savedPage < totalPages { currentIndex = savedPage }
        } else {
            manga.readingProgress.removeValue(forKey: volName)
            currentIndex = 0
        }
    }
    
    var isVolumeRead: Bool { manga.readVolumes.contains(volumeURL.lastPathComponent) }
    
    func markAsRead() {
        let name = volumeURL.lastPathComponent
        if isVolumeRead { manga.readVolumes.removeAll { $0 == name } }
        else { manga.readVolumes.append(name) }
    }
}

struct PageView: View {
    let url: URL
    let size: CGSize
    let alignment: Alignment
    var body: some View {
        AsyncImage(url: url)
            .aspectRatio(contentMode: .fit)
            .frame(width: size.width, height: size.height, alignment: alignment)
            .clipped()
    }
}

struct AsyncImage: View {
    let url: URL
    var body: some View {
        if let nsImage = NSImage(contentsOf: url) {
            Image(nsImage: nsImage).resizable()
        } else {
            Color.gray.opacity(0.1)
        }
    }
}
