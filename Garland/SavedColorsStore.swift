import Foundation
import Observation

/// Сцена — сохранённый режим: цвет или эффект, плюс аппаратная яркость.
struct SavedScene: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var color: RGB
    /// Аппаратная яркость 0...100.
    var brightness: Int
    /// Индекс встроенного эффекта контроллера; nil — статический цвет или эффект телефона.
    var effect: Int? = nil
    /// Эффект, рассчитываемый телефоном; `color` тогда — его базовый цвет.
    var phoneEffect: PhoneEffect? = nil
    var speed: Double? = nil

    var mode: OutputMode { effect.map { .effect($0) } ?? .color }
}

/// Локальное хранилище избранного и пользовательских названий эффектов (UserDefaults, JSON).
/// Никакой синхронизации — только этот телефон.
@Observable
final class SavedColorsStore {
    private(set) var scenes: [SavedScene] = []
    private(set) var effectNames: [Int: String] = [:]

    private let scenesKey = "garland.scenes.v2"
    private let effectNamesKey = "garland.effectNames.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - Сцены

    func add(name: String, color: RGB, brightness: Int, effect: Int?,
             phoneEffect: PhoneEffect? = nil, speed: Double? = nil) {
        scenes.append(SavedScene(name: name, color: color, brightness: brightness, effect: effect,
                                 phoneEffect: phoneEffect, speed: speed))
        save()
    }

    func remove(_ scene: SavedScene) {
        scenes.removeAll { $0.id == scene.id }
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        scenes.move(fromOffsets: source, toOffset: destination)
        save()
    }

    // MARK: - Названия эффектов

    /// Контроллер не сообщает, что делает эффект с данным индексом, — пользователь подписывает сам.
    func effectName(_ index: Int) -> String {
        effectNames[index] ?? "Эффект \(index)"
    }

    func renameEffect(_ index: Int, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { effectNames.removeValue(forKey: index) } else { effectNames[index] = trimmed }
        save()
    }

    // MARK: - Хранение

    private func load() {
        if let data = defaults.data(forKey: scenesKey),
           let decoded = try? JSONDecoder().decode([SavedScene].self, from: data) {
            scenes = decoded
        } else {
            scenes = Self.defaultScenes
        }
        if let data = defaults.data(forKey: effectNamesKey),
           let decoded = try? JSONDecoder().decode([Int: String].self, from: data) {
            effectNames = decoded
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(scenes) {
            defaults.set(data, forKey: scenesKey)
        }
        if let data = try? JSONEncoder().encode(effectNames) {
            defaults.set(data, forKey: effectNamesKey)
        }
    }

    private static let defaultScenes: [SavedScene] = [
        SavedScene(name: "Тёплый вечер", color: RGB(red: 255, green: 147, blue: 41), brightness: 80),
        SavedScene(name: "Свеча", color: RGB(red: 255, green: 110, blue: 20), brightness: 35),
        SavedScene(name: "Северное сияние", color: RGB(red: 0, green: 255, blue: 140), brightness: 70),
        SavedScene(name: "Лаванда", color: RGB(red: 150, green: 90, blue: 255), brightness: 60),
        SavedScene(name: "Океан", color: RGB(red: 0, green: 120, blue: 255), brightness: 90),
        SavedScene(name: "Розовый закат", color: RGB(red: 255, green: 60, blue: 120), brightness: 75),
        SavedScene(name: "Камин", color: RGB(red: 255, green: 140, blue: 30), brightness: 70, phoneEffect: .candle, speed: 1),
        SavedScene(name: "Медленный перелив", color: .white, brightness: 80, phoneEffect: .rainbow, speed: 0.5),
    ]
}
