import Foundation
import Observation

/// Готовый эффект WLED с «зашитыми» палитрой и настройками — пользователю не нужно ничего выбирать.
struct CuratedEffect: Identifiable, Hashable {
    let id: Int          // fx id в WLED 16.0.1 (см. docs/ESP32.md)
    let title: String
    let icon: String
    let palette: Int
    let speed: Int
    let intensity: Int

    static let all: [CuratedEffect] = [
        CuratedEffect(id: 196, title: "Водопад", icon: "drop.fill", palette: 9, speed: 128, intensity: 170),
        CuratedEffect(id: 43,  title: "Дождь", icon: "cloud.rain.fill", palette: 9, speed: 150, intensity: 128),
        CuratedEffect(id: 80,  title: "Снежинки", icon: "snowflake", palette: 36, speed: 90, intensity: 128),
        CuratedEffect(id: 188, title: "Огонь", icon: "flame.fill", palette: 35, speed: 128, intensity: 128),
        CuratedEffect(id: 102, title: "Свечи", icon: "light.max", palette: 35, speed: 100, intensity: 110),
        CuratedEffect(id: 174, title: "Северное сияние", icon: "sparkles", palette: 50, speed: 90, intensity: 128),
        CuratedEffect(id: 165, title: "Волны", icon: "water.waves", palette: 9, speed: 110, intensity: 128),
        CuratedEffect(id: 178, title: "Плазма", icon: "circle.hexagongrid.fill", palette: 11, speed: 110, intensity: 128),
        CuratedEffect(id: 164, title: "Дрейф", icon: "tornado", palette: 11, speed: 120, intensity: 128),
        CuratedEffect(id: 42,  title: "Фейерверк", icon: "fireworks", palette: 11, speed: 128, intensity: 160),
        CuratedEffect(id: 121, title: "Капли", icon: "circle.dotted", palette: 6, speed: 128, intensity: 128),
        CuratedEffect(id: 74,  title: "Мерцание", icon: "sparkle", palette: 48, speed: 128, intensity: 128),
        CuratedEffect(id: 65,  title: "Радуга", icon: "rainbow", palette: 11, speed: 60, intensity: 128),
        CuratedEffect(id: 76,  title: "Метеоры", icon: "moon.stars.fill", palette: 11, speed: 150, intensity: 128),
        CuratedEffect(id: 217, title: "Галактика", icon: "globe", palette: 11, speed: 110, intensity: 128),
        CuratedEffect(id: 152, title: "ДНК", icon: "waveform.path", palette: 11, speed: 110, intensity: 128),
    ]
}

/// Сцена для WLED: цвет или эффект с настройками. Исполняется контроллером, телефон не нужен.
struct LightScene: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var brightness: Int           // 1…255
    var color: RGB?               // сплошной цвет
    var effect: Int?              // fx id
    var palette: Int = 0
    var speed: Int = 128
    var intensity: Int = 128
    /// Эффект конструктора (считает телефон).
    var constructor: ConstructorSpec? = nil
}

@Observable
final class LightSceneStore {
    private(set) var scenes: [LightScene] = []
    private let key = "wled.scenes.v1"

    init() {
        if let d = UserDefaults.standard.data(forKey: key),
           let s = try? JSONDecoder().decode([LightScene].self, from: d) {
            scenes = s
        } else {
            scenes = [
                LightScene(name: "Тёплый вечер", brightness: 120, color: RGB(red: 255, green: 140, blue: 40)),
                LightScene(name: "Снегопад", brightness: 140, effect: 80, palette: 36, speed: 90, intensity: 128),
                LightScene(name: "Камин", brightness: 160, effect: 188, palette: 35, speed: 128, intensity: 128),
            ]
        }
    }

    func add(_ s: LightScene) { scenes.append(s); save() }
    func remove(_ s: LightScene) { scenes.removeAll { $0.id == s.id }; save() }
    func move(from: IndexSet, to: Int) { scenes.move(fromOffsets: from, toOffset: to); save() }

    private func save() {
        if let d = try? JSONEncoder().encode(scenes) { UserDefaults.standard.set(d, forKey: key) }
    }
}
