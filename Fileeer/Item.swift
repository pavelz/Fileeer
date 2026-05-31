//
//  Item.swift
//  Fileeer
//
//  Created by Pavel Zaitsev on 2026-05-31.
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
