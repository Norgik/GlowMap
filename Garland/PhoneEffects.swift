import Foundation
import Observation
import UIKit

/// Эффекты, которые рассчитывает телефон и отправляет гирлянде потоком обычных команд цвета.
/// В отличие от встроенных эффектов контроллера они работают только пока приложение открыто
/// и есть связь: iOS приостанавливает приложение в фоне и при блокировке экрана.
enum PhoneEffect: String, CaseIterable, Codable, Identifiable {
    case rainbow
    case breathing
    case candle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rainbow: "Перелив"
        case .breathing: "Дыхание"
        case .candle: "Свеча"
        }
    }

    var subtitle: String {
        switch self {
        case .rainbow: "плавная смена всех цветов"
        case .breathing: "цвет плавно гаснет и разгорается"
        case .candle: "тёплое живое мерцание"
        }
    }

    var systemImage: String {
        switch self {
        case .rainbow: "rainbow"
        case .breathing: "wind"
        case .candle: "flame"
        }
    }

    /// Использует ли эффект цвет с колеса как основу.
    var usesBaseColor: Bool {
        switch self {
        case .rainbow: false
        case .breathing, .candle: true
        }
    }

    /// Цвет по умолчанию, если эффект запущен без выбранного цвета.
    var defaultBase: RGB {
        switch self {
        case .candle: RGB(red: 255, green: 140, blue: 30)
        default: RGB(red: 255, green: 160, blue: 60)
        }
    }

    // MARK: - Математика (чистые функции, покрыты тестами)

    /// Перелив: оттенок делает полный круг за `12 / speed` секунд.
    static func rainbowColor(t: TimeInterval, speed: Double) -> RGB {
        let hue = (t * speed / 12).truncatingRemainder(dividingBy: 1)
        return RGB(hue: hue < 0 ? hue + 1 : hue, saturation: 1)
    }

    /// Дыхание: период `5 / speed` секунд, яркость 0.08…1 по сглаженной синусоиде.
    static func breathingFactor(t: TimeInterval, speed: Double) -> Double {
        let period = 5.0 / max(0.05, speed)
        let phase = (t / period).truncatingRemainder(dividingBy: 1)
        let raw = (1 - cos(phase * 2 * .pi)) / 2          // 0…1…0
        let eased = raw * raw * (3 - 2 * raw)              // smoothstep — мягче в крайних точках
        return 0.08 + 0.92 * eased
    }

    /// Свеча: медленный случайный дрейф яркости плюс редкие короткие «вздрагивания».
    /// Состояние хранится в `CandleState`, чтобы мерцание было непрерывным между тиками.
    struct CandleState {
        var level: Double = 0.8
        var target: Double = 0.8
        var nextTargetAt: TimeInterval = 0
        var flickerUntil: TimeInterval = 0
        var rng = SystemRandomNumberGenerator()

        mutating func step(t: TimeInterval, dt: TimeInterval, speed: Double) -> (factor: Double, warmth: Double) {
            if t >= nextTargetAt {
                target = Double.random(in: 0.55...1.0, using: &rng)
                nextTargetAt = t + Double.random(in: 0.12...0.45, using: &rng) / max(0.2, speed)
                // Изредка — резкий провал, как от сквозняка.
                if Double.random(in: 0...1, using: &rng) < 0.08 {
                    flickerUntil = t + 0.08
                }
            }
            let goal = t < flickerUntil ? 0.3 : target
            let rate = min(1, dt * 10 * max(0.2, speed))
            level += (goal - level) * rate
            // Чем тусклее, тем краснее пламя: сдвигаем зелёный канал вниз.
            let warmth = 0.75 + 0.25 * level
            return (level, warmth)
        }
    }

    static func candleColor(base: RGB, factor: Double, warmth: Double) -> RGB {
        RGB(red: UInt8((Double(base.red) * factor).rounded()),
            green: UInt8((Double(base.green) * factor * warmth).rounded()),
            blue: UInt8((Double(base.blue) * factor * warmth * warmth).rounded()))
    }
}

/// Цикл расчёта и отправки. Частоту отправки ограничивает `BluetoothManager` (~10 Гц),
/// здесь считаем чуть чаще, чтобы в поток всегда попадало свежее значение.
@Observable
@MainActor
final class PhoneEffectEngine {
    private(set) var running: PhoneEffect?
    private(set) var currentColor: RGB?
    var speed: Double = 1.0 {
        didSet { speed = max(0.25, min(3, speed)) }
    }
    var baseColor: RGB = RGB(red: 255, green: 160, blue: 60)

    private let bluetooth: BluetoothManager
    /// Если задан и готов — кадры идут в WLED по Wi‑Fi (вся лента одним цветом), иначе по Bluetooth.
    var wled: WLEDClient?
    private var task: Task<Void, Never>?
    private let tickInterval: TimeInterval = 1.0 / 20

    init(bluetooth: BluetoothManager) {
        self.bluetooth = bluetooth
    }

    func start(_ effect: PhoneEffect, base: RGB? = nil, speed: Double? = nil) {
        if let base { baseColor = base }
        if let speed { self.speed = speed }
        if running == effect { return }
        stop()
        running = effect
        UIApplication.shared.isIdleTimerDisabled = true   // иначе экран погаснет и iOS остановит эффект
        task = Task { [weak self] in
            await self?.loop(effect)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        running = nil
        currentColor = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func toggle(_ effect: PhoneEffect, base: RGB? = nil) {
        if running == effect { stop() } else { start(effect, base: base) }
    }

    private func loop(_ effect: PhoneEffect) async {
        let start = Date.now
        var last = start
        var candle = PhoneEffect.CandleState()
        while !Task.isCancelled {
            let now = Date.now
            let t = now.timeIntervalSince(start)
            let dt = now.timeIntervalSince(last)
            last = now

            let color: RGB
            switch effect {
            case .rainbow:
                color = PhoneEffect.rainbowColor(t: t, speed: speed)
            case .breathing:
                color = baseColor.scaled(by: PhoneEffect.breathingFactor(t: t, speed: speed))
            case .candle:
                let s = candle.step(t: t, dt: dt, speed: speed)
                color = PhoneEffect.candleColor(base: baseColor, factor: s.factor, warmth: s.warmth)
            }
            currentColor = color
            if let wled, wled.isReady {
                wled.sendFrame(LEDFrame(count: wled.ledCount, fill: color))
            } else if bluetooth.isReady {
                bluetooth.requestColor(color, immediate: false)
            }
            try? await Task.sleep(for: .seconds(tickInterval))
        }
    }
}
