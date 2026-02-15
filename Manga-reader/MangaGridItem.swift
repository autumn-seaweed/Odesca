//
//  MangaGridItem.swift
//  Manga-reader
//
//  Created by Aki Toyoshima on 2026/02/09.
//

import SwiftUI
import SwiftData

struct MangaGridItem: View, Equatable {
    let item: MangaDisplayItem
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    
    static func == (lhs: MangaGridItem, rhs: MangaGridItem) -> Bool {
        return lhs.item == rhs.item && lhs.isSelected == rhs.isSelected
    }
    
    var body: some View {
        VStack(spacing: 8) {
            // FIXED: Just provide the Frame, GeometryReader in Cover does the rest
            AsyncMangaCover(item: item)
                .frame(height: 230)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 2)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isSelected ? Color.accentColor : Color.white.opacity(0.1), lineWidth: isSelected ? 3 : 1)
                )
                .contentShape(Rectangle())
            
            // INFO TEXT
            VStack(spacing: 2) {
                HStack(spacing: 4) {
                    if item.isFavorite {
                        Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption2)
                    }
                    if item.hasToReadTag {
                        Image(systemName: "eyeglasses").foregroundStyle(.blue).font(.caption2)
                    }
                    Text(item.title)
                        .font(.caption).bold()
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .background(isSelected ? Color.accentColor.opacity(0.3) : Color.clear)
                        .cornerRadius(4)
                }
                
                Text("\(item.readCount) / \(item.volumeCount) vols")
                    .font(.caption2)
                    .foregroundStyle(item.isFinished ? .green : .secondary)
            }
        }
        .onTapGesture(count: 2) { onOpen() }
        .simultaneousGesture(TapGesture().onEnded { onSelect() })
    }
}
