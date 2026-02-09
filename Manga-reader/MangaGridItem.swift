//
//  MangaGridItem.swift
//  Manga-reader
//
//  Created by Aki Toyoshima on 2026/02/09.
//

import SwiftUI
import SwiftData

struct MangaGridItem: View {
    @Bindable var manga: MangaSeries
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    
    var body: some View {
        VStack {
            // --- COVER IMAGE ---
            // Note: AsyncMangaCover must be available (defined in MangaGrid or its own file)
            AsyncMangaCover(manga: manga)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
                )
            
            // --- TEXT METADATA ---
            VStack(spacing: 2) {
                HStack(spacing: 4) {
                    if manga.isFavorite {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                            .font(.caption2)
                            .transition(.scale)
                    }
                    if manga.tags.contains("To Read") {
                        Image(systemName: "eyeglasses")
                            .foregroundStyle(.blue)
                            .font(.caption2)
                    }
                    Text(manga.title)
                        .font(.caption).bold()
                        .lineLimit(1)
                        .background(isSelected ? Color.accentColor.opacity(0.3) : Color.clear)
                        .cornerRadius(4)
                }
                
                Text("\(manga.readVolumes.count) / \(manga.volumeCount) vols")
                    .font(.caption2)
                    .foregroundStyle(manga.isFinished ? .green : .secondary)
            }
        }
        .contentShape(Rectangle()) // Makes the whole area clickable
        .onTapGesture(count: 2) { onOpen() }
        .simultaneousGesture(TapGesture().onEnded { onSelect() })
    }
}
