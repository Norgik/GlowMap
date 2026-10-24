import Foundation
import Observation
import UIKit

/// Эффекты, использующие карту `LED → x,y`. Считаются телефоном, уходят в WLED по DDP ~30 fps.
enum MapEffect: String, CaseIterable, Identifiable {
    case verify, gradient, wave, paint
    var id: String { rawValue }
    var title: String {
        switch self {
        case .verify: "Проверка"
        case .gradient: "Градиент"
        case .wave: "Волна"
        case .paint: "Рисование"
        }
    }
    var systemImage: String {
        switch self {
        case .verify: "hand.tap"
        case .gradient: "square.lefthalf.filled"
        case .wave: "water.waves"
        case .paint: "paintbrush.pointed"
        }
    }
}

/// Чистые функции расчёта (покрываемы тестами).
enum MapEffectMath {
    /// Проекция точки на ось под углом `angle` (радианы), 0…1 по диагонали карты.
    static func projection(x: Double, y: Double, aspect: Double, angle: Double) -> Double {
        let px = x * aspect, py = y
        let p = px * cos(angle) + py * sin(angle)
        let lo = min(0, aspect * cos(angle)) + min(0, sin(angle))
        let hi = max(0, aspect * cos(angle)) + max(0, sin(angle))
        return hi > lo ? (p - lo) / (hi - lo) : 0
    }

    static func lerp(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
        let k = max(0, min(1, t))
        func m(_ x: UInt8, _ y: UInt8) -> UInt8 { UInt8((Double(x) + (Double(y) - Double(x)) * k).rounded()) }
        return RGB(red: m(a.red, b.red), green: m(a.green, b.green), blue: m(a.blue, b.blue))
    }

    /// Яркость волны 0…1 в точке с проекцией `u`, временем `t`, пространственным периодом `wavelength`.
    static func wave(u: Double, t: Double, speed: Double, wavelength: Double) -> Double {
        let phase = (u / max(0.05, wavelength) - t * speed) * 2 * .pi
        let s = (sin(phase) + 1) / 2
        return s * s   // поострее гребни
    }
}

@Observable
@MainActor
final class MapEffectEngine {
    private(set) var running: MapEffect?
    private(set) var frame: LEDFrame
    private(set) var highlighted: Int?

    var colorA: RGB = RGB(red: 255, green: 80, blue: 0)
    var colorB: RGB = RGB(red: 0, green: 80, blue: 255)
    var angle: Double = 0            // радианы
    var speed: Double = 0.5          // волн/с
    var wavelength: Double = 0.35    // доля диагонали
    var brushRadius: Double = 0.08
    var brushColor: RGB = .white
    var brightness: Double = 0.8
    var unmappedDim: Double = 0.0    // яркость неразмеченных LED (0 — выключены)

    private let wled: WLEDClient
    private var map: LEDMap
    private var task: Task<Void, Never>?
    private var paintLayer: [Int: RGB] = [:]

    init(wled: WLEDClient, map: LEDMap) {
        self.wled = wled
        self.map = map
        self.frame = LEDFrame(count: map.ledCount)
    }

    func update(map: LEDMap) {
        self.map = map
        frame = LEDFrame(count: map.ledCount)
    }

    func start(_ effect: MapEffect) {
        stop()
        running = effect
        UIApplication.shared.isIdleTimerDisabled = true
        task = Task { [weak self] in await self?.loop(effect) }
    }

    func stop() {
        task?.cancel(); task = nil
        running = nil
        highlighted = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// Проверка карты: касание → подсветить ближайший LED.
    func highlight(x: Double, y: Double) {
        highlighted = map.nearest(to: x, y)
    }

    func clearPaint() { paintLayer = [:] }

    /// Мазок кистью: все надёжные LED в радиусе получают цвет.
    func paint(x: Double, y: Double) {
        for (i, p) in map.reliable {
            let d = hypot((p.x - x) * map.cameraAspect, p.y - y)
            if d <= brushRadius { paintLayer[i] = brushColor }
        }
    }

    private func loop(_ effect: MapEffect) async {
        let start = Date.now
        while !Task.isCancelled {
            let t = Date.now.timeIntervalSince(start)
            var f = LEDFrame(count: map.ledCount, fill: RGB.white.scaled(by: unmappedDim))
            switch effect {
            case .verify:
                f = LEDFrame(count: map.ledCount)
                for (i, _) in map.reliable { f[i] = RGB(red: 6, green: 6, blue: 6) }  // еле видимый фон у размеченных
                if let h = highlighted { f[h] = .white }
            case .gradient:
                for (i, p) in map.reliable {
                    let u = MapEffectMath.projection(x: p.x, y: p.y, aspect: map.cameraAspect, angle: angle)
                    f[i] = MapEffectMath.lerp(colorA, colorB, u).scaled(by: brightness)
                }
            case .wave:
                for (i, p) in map.reliable {
                    let u = MapEffectMath.projection(x: p.x, y: p.y, aspect: map.cameraAspect, angle: angle)
                    let v = MapEffectMath.wave(u: u, t: t, speed: speed, wavelength: wavelength)
                    f[i] = MapEffectMath.lerp(colorB, colorA, v).scaled(by: brightness * (0.15 + 0.85 * v))
                }
            case .paint:
                f = LEDFrame(count: map.ledCount)
                for (i, c) in paintLayer { f[i] = c.scaled(by: brightness) }
            }
            frame = f
            if wled.isReady { wled.sendFrame(f) }
            try? await Task.sleep(for: .milliseconds(33))
        }
    }
}
