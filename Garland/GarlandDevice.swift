import Foundation
import CoreBluetooth

/// Найденная при сканировании гирлянда. iOS даёт только `identifier` (UUID, стабильный
/// для этого телефона); MAC-адрес недоступен и не используется.
struct DiscoveredDevice: Identifiable, Equatable {
    let id: UUID
    let name: String
    var rssi: Int
    var lastSeen: Date

    static let namePrefix = "LEDDMX-00"

    static func matches(name: String?) -> Bool {
        guard let name else { return false }
        return name.hasPrefix(namePrefix)
    }
}

enum GarlandUUID {
    static let service = CBUUID(string: "FFE0")
    static let characteristic = CBUUID(string: "FFE1")
}
