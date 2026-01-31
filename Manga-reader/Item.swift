//
//  Item.swift
//  Manga-reader
//
//  Created by Aki Toyoshima on 2026/01/31.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
