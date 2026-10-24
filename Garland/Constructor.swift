import Foundation
import Observation
import UIKit

/// Конструктор эффектов в духе Twinkly FX Wizard: базовый узор по карте + искры сверху.
/// Считает телефон, кадры уходят по DDP (~30 fps). Все параметры — в `ConstructorSpec`,
/// который сохраняется в сценах.
struct ConstructorSpec: Codable, Hashable {
    enum Base: String, Codable, CaseIterable, Identifiable {
        case colorBlend, stripes, gradient, spiral, rings, plasma
        var id: String { rawValue }
        var title: String {
            switch self {
            case .colorBlend: "Перелив"
            case .stripes: "Полосы"
            case .gradient: "Градиент"
            case .spiral: "Спираль"
            case .rings: "Кольца"
            case .plasma: "Плазма"
            }
        }
        var icon: String {
            switch self {
            case .colorBlend: "circle.lefthalf.filled"
            case .stripes: "line.3.horizontal"
            case .gradient: "square.lefthalf.filled"
            case .spiral: "hurricane"
            case .rings: "circle.circle"
            case .plasma: "circle.hexagongrid.fill"
            }
        }
    }

    var base: Base = .stripes
    var colors: [RGB] = [RGB(red: 255, green: 30, blue: 30), .white]
    var angle: Double = .pi / 4        // радианы
    var speed: Double = 0.3            // периодов в секунду; отрицательная — назад
    var zoom: Double = 3               // сколько периодов узора укладывается в карту
    var warp: Double = 0               // 0…1 изгиб полос/градиента
    var softness: Double = 0.15        // 0…1 мягкость границ полос
    var sparkles: Bool = true
    var sparkleDensity: Double = 0.3   // 0…1
    var brightness: Double = 0.9

    static let presets: [(name: String, spec: ConstructorSpec)] = [
        ("Леденец", ConstructorSpec(base: .stripes, colors: [RGB(red: 255, green: 20, blue: 20), .white], angle: .pi / 4, speed: 0.25, zoom: 4, softness: 0.1, sparkles: false)),
        ("Радужные полосы", ConstructorSpec(base: .gradient, colors: [.red, RGB(red: 255, green: 200, blue: 0), .green, RGB(red: 0, green: 180, blue: 255), RGB(red: 160, green: 0, blue: 255)], angle: 0, speed: 0.15, zoom: 1.5, sparkles: false)),
        ("Спираль", ConstructorSpec(base: .spiral, colors: [RGB(red: 0, green: 200, blue: 255), RGB(red: 10, green: 10, blue: 60)], angle: 0, speed: 0.3, zoom: 2, sparkles: true, sparkleDensity: 0.2)),
        ("Кольца", ConstructorSpec(base: .rings, colors: [RGB(red: 255, green: 120, blue: 0), RGB(red: 40, green: 0, blue: 0)], angle: 0, speed: 0.4, zoom: 3, sparkles: false)),
        ("Плазма", ConstructorSpec(base: .plasma, colors: [RGB(red: 255, green: 0, blue: 120), RGB(red: 0, green: 60, blue: 255), RGB(red: 0, green: 255, blue: 160)], angle: 0, speed: 0.4, zoom: 1.5, sparkles: false)),
        ("Тёплый перелив с искрами", ConstructorSpec(base: .colorBlend, colors: [RGB(red: 255, green: 120, blue: 30), RGB(red: 255, green: 60, blue: 60), RGB(red: 255, green: 180, blue: 80)], speed: 0.1, sparkles: true, sparkleDensity: 0.5)),
    ]
}

/// Чистая математика конструктора (без времени выполнения и случайности) — покрыта тестами.
enum ConstructorMath {
    /// Цвет на циклической палитре в точке t (любое вещественное, период 1).
    static func palette(_ colors: [RGB], _ t: Double) -> RGB {
        guard let first = colors.first else { return .black }
        guard colors.count > 1 else { return first }
        let f = t - floor(t)
        let pos = f * Double(colors.count)
        let i = Int(pos) % colors.count
        let j = (i + 1) % colors.count
        return MapEffectMath.lerp(colors[i], colors[j], pos - Double(i))
    }

    /// Полосы: доля периода → индекс цвета; `softness` смешивает цвета у границ.
    static func stripes(_ colors: [RGB], phase: Double, softness: Double) -> RGB {
        guard colors.count > 1 else { return colors.first ?? .black }
        let f = phase - floor(phase)
        let pos = f * Double(colors.count)
        let i = Int(pos) % colors.count
        let within = pos - Double(i)                       // 0…1 внутри полосы
        let edge = max(0.001, softness * 0.5)
        if within > 1 - edge {
            let k = (within - (1 - edge)) / edge * 0.5     // 0…0.5
            return MapEffectMath.lerp(colors[i], colors[(i + 1) % colors.count], k)
        } else if within < edge {
            let k = 0.5 - within / edge * 0.5
            return MapEffectMath.lerp(colors[i], colors[(i + colors.count - 1) % colors.count], k)
        }
        return colors[i]
    }

    /// Цвет базового узора в точке карты (x, y нормированы, aspect — ширина/высота).
    static func baseColor(_ s: ConstructorSpec, x: Double, y: Double, aspect: Double, t: Double) -> RGB {
        let u = MapEffectMath.projection(x: x, y: y, aspect: aspect, angle: s.angle)
        let v = MapEffectMath.projection(x: x, y: y, aspect: aspect, angle: s.angle + .pi / 2)
        let warped = u + s.warp * 0.25 * sin(v * 2 * .pi)
        let cx = 0.5 * aspect, cy = 0.5
        let dx = x * aspect - cx, dy = y - cy
        let r = hypot(dx, dy) / hypot(cx, cy)
        let phi = atan2(dy, dx) / (2 * .pi)
        switch s.base {
        case .colorBlend:
            return palette(s.colors, t * s.speed)
        case .stripes:
            return stripes(s.colors, phase: warped * s.zoom - t * s.speed, softness: s.softness)
        case .gradient:
            return palette(s.colors, warped * s.zoom - t * s.speed)
        case .spiral:
            return palette(s.colors, phi + r * s.zoom - t * s.speed)
        case .rings:
            return palette(s.colors, r * s.zoom - t * s.speed)
        case .plasma:
            let k = s.zoom * 2 * .pi
            let px = x * aspect, py = y
            let val = (sin(px * k + t * s.speed * 3) + sin(py * k * 1.3 - t * s.speed * 2.2)
                       + sin((px + py) * k * 0.7 + t * s.speed * 1.7)) / 3   // −1…1
            return palette(s.colors, (val + 1) / 2 * 0.999)
        }
    }
}

@Observable
@MainActor
final class ConstructorEngine {
    var spec = ConstructorSpec()
    private(set) var running = false
    private(set) var frame: LEDFrame
    private(set) var title: String?

    private let wled: WLEDClient
    private var map: LEDMap
    private var task: Task<Void, Never>?
    private var sparkleEnergy: [Double]

    init(wled: WLEDClient, map: LEDMap?) {
        let m = map ?? LEDMap(ledCount: wled.ledCount, points: [:], createdAt: .now, cameraAspect: 1)
        self.wled = wled
        self.map = m
        frame = LEDFrame(count: m.ledCount)
        sparkleEnergy = Array(repeating: 0, count: m.ledCount)
    }

    func update(map: LEDMap) {
        self.map = map
        frame = LEDFrame(count: map.ledCount)
        sparkleEnergy = Array(repeating: 0, count: map.ledCount)
    }

    func start(_ spec: ConstructorSpec? = nil, title: String? = nil) {
        if let spec { self.spec = spec }
        self.title = title
        stop()
        running = true
        UIApplication.shared.isIdleTimerDisabled = true
        task = Task { [weak self] in await self?.loop() }
    }

    func stop() {
        task?.cancel(); task = nil
        running = false
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func loop() async {
        let start = Date.now
        var rng = SystemRandomNumberGenerator()
        // Без карты узор идёт вдоль провода: x = i / n
        let points: [(Int, Double, Double)] = map.points.isEmpty
            ? (0..<map.ledCount).map { ($0, Double($0) / Double(max(1, map.ledCount - 1)), 0.5) }
            : map.reliable.map { ($0.index, $0.point.x, $0.point.y) }
        let aspect = map.points.isEmpty ? 4.0 : map.cameraAspect
        while !Task.isCancelled {
            let t = Date.now.timeIntervalSince(start)
            var f = LEDFrame(count: map.ledCount)
            let s = spec
            for (i, x, y) in points {
                var c = ConstructorMath.baseColor(s, x: x, y: y, aspect: aspect, t: t).scaled(by: s.brightness)
                if s.sparkles {
                    if Double.random(in: 0...1, using: &rng) < s.sparkleDensity * 0.03 { sparkleEnergy[i] = 1 }
                    let e = sparkleEnergy[i]
                    if e > 0.02 {
                        c = MapEffectMath.lerp(c, .white, e)
                        sparkleEnergy[i] = e * 0.82
                    } else { sparkleEnergy[i] = 0 }
                }
                f[i] = c
            }
            frame = f
            if wled.isReady { wled.sendFrame(f) }
            try? await Task.sleep(for: .milliseconds(33))
        }
    }
}
