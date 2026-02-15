//
//  NovelReader.swift
//  Manga-reader
//
//  Created by Aki Toyoshima on 2026/02/15.
//

import SwiftUI
import WebKit
import SwiftData

// --- NAVIGATION DATA ---
// Definition stays here as the single source of truth for the app
struct NovelDestination: Hashable {
    let url: URL
    let mangaID: PersistentIdentifier
}

enum NovelTheme: String, CaseIterable, Identifiable {
    case dark = "Dark", light = "Light", sepia = "Sepia"
    var id: String { self.rawValue }
    
    var colors: (bg: String, text: String) {
        switch self {
        case .dark:  return ("#1a1a1a", "#e0e0e0")
        case .light: return ("#ffffff", "#000000")
        case .sepia: return ("#f4ecd8", "#5b4636")
        }
    }
}

enum TextDirection: String, CaseIterable, Identifiable {
    case vertical = "Vertical (RTL)", horizontal = "Horizontal (LTR)"
    var id: String { self.rawValue }
}

// --- PARSER ENGINE ---
class EpubEngine {
    static func resolveChapters(in root: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        
        let opfURL = enumerator.compactMap { $0 as? URL }.first { $0.pathExtension.lowercased() == "opf" }
        guard let opf = opfURL, let content = try? String(contentsOf: opf) else { return [] }
        let baseDir = opf.deletingLastPathComponent()
        
        var manifest: [String: String] = [:]
        let itemRegex = try? NSRegularExpression(pattern: #"<item\s+[^>]*id=["']([^"']+)["'][^>]*href=["']([^"']+)["'][^>]*>"#, options: .caseInsensitive)
        itemRegex?.enumerateMatches(in: content, range: NSRange(content.startIndex..., in: content)) { m, _, _ in
            if let idR = m?.range(at: 1), let hrefR = m?.range(at: 2),
               let id = Range(idR, in: content), let href = Range(hrefR, in: content) {
                manifest[String(content[id])] = String(content[href]).removingPercentEncoding
            }
        }
        
        var spine: [String] = []
        let spineRegex = try? NSRegularExpression(pattern: #"<itemref\s+[^>]*idref=["']([^"']+)["'][^>]*/>"#, options: .caseInsensitive)
        spineRegex?.enumerateMatches(in: content, range: NSRange(content.startIndex..., in: content)) { m, _, _ in
            if let idR = m?.range(at: 1), let id = Range(idR, in: content) {
                spine.append(String(content[id]))
            }
        }
        
        return spine.compactMap { manifest[$0] }.map { baseDir.appendingPathComponent($0) }
    }
}

// --- MAIN READER VIEW ---
struct NovelReaderView: View {
    let volumeURL: URL
    @Bindable var manga: MangaSeries
    
    @State private var chapters: [URL] = []
    @State private var currentChapterIndex = 0
    @State private var bookCacheDir: URL?
    @State private var isLoading = true
    @State private var currentSafeURL: URL?
    @State private var webViewID = UUID()
    
    @AppStorage("novelFontSize") private var fontSize: Double = 22
    @AppStorage("novelTheme") private var theme: NovelTheme = .dark
    @AppStorage("novelDirection") private var direction: TextDirection = .vertical

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                ProgressView("Building reader...").controlSize(.large)
            } else {
                NovelWebView(fileURL: currentSafeURL, readAccessDir: bookCacheDir)
                    .id(webViewID)
                    .background(Color(hex: theme.colors.bg))
                
                HStack {
                    Button { changeChapter(by: -1) } label: { Image(systemName: "chevron.left") }
                        .disabled(currentChapterIndex == 0)
                    Spacer()
                    Text("Chapter \(currentChapterIndex + 1) / \(chapters.count)")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Spacer()
                    Button { changeChapter(by: 1) } label: { Image(systemName: "chevron.right") }
                        .disabled(currentChapterIndex >= chapters.count - 1)
                }
                .padding().background(.ultraThinMaterial)
            }
        }
        .navigationTitle(volumeURL.lastPathComponent)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ControlGroup {
                        Button { fontSize = max(12, fontSize - 2) } label: { Label("Smaller", systemImage: "textformat.size.smaller") }
                        Button { fontSize = min(40, fontSize + 2) } label: { Label("Larger", systemImage: "textformat.size.larger") }
                    }
                    Divider()
                    Picker("Direction", selection: $direction) {
                        ForEach(TextDirection.allCases) { dir in
                            Label(dir.rawValue, systemImage: dir == .vertical ? "text.alignright" : "text.alignleft").tag(dir)
                        }
                    }
                    Divider()
                    Picker("Theme", selection: $theme) {
                        ForEach(NovelTheme.allCases) { t in
                            Text(t.rawValue).tag(t)
                        }
                    }
                } label: { Label("Text Settings", systemImage: "textformat") }
            }
        }
        .onAppear { setupBook() }
        .onDisappear { if let dir = bookCacheDir { try? FileManager.default.removeItem(at: dir) } }
        .onChange(of: fontSize) { _, _ in renderCurrentChapter() }
        .onChange(of: theme) { _, _ in renderCurrentChapter() }
        .onChange(of: direction) { _, _ in renderCurrentChapter() }
    }

    private func setupBook() {
        let fm = FileManager.default
        let cache = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Novels/\(UUID().uuidString)")
        self.bookCacheDir = cache
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try fm.createDirectory(at: cache, withIntermediateDirectories: true)
                let unzip = Process()
                unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                unzip.arguments = ["-q", volumeURL.path, "-d", cache.path]
                try unzip.run(); unzip.waitUntilExit()
                
                let resolved = EpubEngine.resolveChapters(in: cache)
                DispatchQueue.main.async {
                    self.chapters = resolved
                    if let savedIndex = manga.readingProgress[volumeURL.lastPathComponent], resolved.indices.contains(savedIndex) {
                        self.currentChapterIndex = savedIndex
                    }
                    self.renderCurrentChapter()
                    self.isLoading = false
                }
            } catch { print("Failed: \(error)") }
        }
    }

    private func changeChapter(by delta: Int) {
        currentChapterIndex += delta
        manga.readingProgress[volumeURL.lastPathComponent] = currentChapterIndex
        renderCurrentChapter()
    }

    private func renderCurrentChapter() {
        guard chapters.indices.contains(currentChapterIndex) else { return }
        let sourceURL = chapters[currentChapterIndex]
        
        do {
            let content = (try? String(contentsOf: sourceURL, encoding: .utf8)) ?? ""
            var body = content
            if let start = content.range(of: "<body", options: .caseInsensitive),
               let end = content.range(of: "</body>", options: .caseInsensitive) {
                body = String(content[start.lowerBound..<end.upperBound]) + "</body>"
            }
            
            let writingMode = direction == .vertical ? "vertical-rl" : "horizontal-tb"
            
            let html = """
            <!DOCTYPE html>
            <html>
            <head>
                <meta charset="UTF-8">
                <style>
                    /* 1. Global Reset */
                    html, body, div, span, p {
                        writing-mode: \(writingMode) !important;
                        -webkit-writing-mode: \(writingMode) !important;
                        color: inherit !important;
                        background-color: transparent !important;
                    }
                    
                    /* 2. Layout Core */
                    :root { --bg: \(theme.colors.bg); --text: \(theme.colors.text); }
                    html, body { 
                        background-color: var(--bg) !important; 
                        color: var(--text) !important; 
                        margin: 0; padding: 0; height: 100vh;
                        \(direction == .vertical ? "overflow-x: scroll; overflow-y: hidden;" : "overflow-y: scroll;") 
                    }
                    
                    body {
                        font-family: "Hiragino Mincho ProN", serif; 
                        font-size: \(Int(fontSize))px; 
                        line-height: 2.0; 
                        padding: 60px; 
                        box-sizing: border-box;
                        \(direction == .horizontal ? "max-width: 800px; margin: 0 auto;" : "")
                    }
                    
                    img { max-height: 85vh; width: auto; display: block; margin: 2em auto; }
                </style>
            </head>
            \(body)
            <script>
                function forceAlign() {
                    const isVertical = "\(direction.rawValue)" === "Vertical (RTL)";
                    if (isVertical) {
                        window.scrollTo({ left: document.body.scrollWidth, behavior: 'instant' });
                    } else {
                        window.scrollTo({ left: 0, behavior: 'instant' });
                    }
                }

                // Initial Load
                window.onload = forceAlign;

                // ⚡️ Link-Click/Jump Fix
                window.onhashchange = function() {
                    forceAlign();
                    // Double-check after a tiny delay for slow rendering
                    setTimeout(forceAlign, 50);
                };
            </script>
            </html>
            """
            
            let safeURL = sourceURL.deletingPathExtension().appendingPathExtension("rendered.html")
            try html.write(to: safeURL, atomically: true, encoding: .utf8)
            
            DispatchQueue.main.async {
                self.currentSafeURL = safeURL
                self.webViewID = UUID()
            }
        } catch { print("Render failed: \(error)") }
    }
}

// --- WEBVIEW ---
struct NovelWebView: NSViewRepresentable {
    let fileURL: URL?
    let readAccessDir: URL?
    
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }
    
    func updateNSView(_ webView: WKWebView, context: Context) {
        guard let url = fileURL else { return }
        let access = readAccessDir ?? url.deletingLastPathComponent()
        if webView.url != url {
            webView.loadFileURL(url, allowingReadAccessTo: access)
        }
    }
}

// --- COLOR HELPER ---
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 6: (r, g, b) = (int >> 16, int >> 8 & 0xFF, int & 0xFF)
        default: (r, g, b) = (1, 1, 0)
        }
        self.init(.sRGB, red: Double(r)/255, green: Double(g)/255, blue: Double(b)/255, opacity: 1)
    }
}
