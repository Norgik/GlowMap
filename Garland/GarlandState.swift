import Foundation

/// Фаза соединения. «Готово» наступает только после обнаружения FFE1 с правом записи,
/// а не сразу после didConnect.
enum ConnectionPhase: Equatable {
    case bluetoothOff
    case unauthorized
    case unsupported
    case idle
    case scanning
    case connecting
    case discovering
    case ready
    case disconnected
    case error(String)

    var title: String {
        switch self {
        case .bluetoothOff: "Bluetooth выключен"
        case .unauthorized: "Нет разрешения Bluetooth"
        case .unsupported: "Bluetooth LE недоступен"
        case .idle: "Не подключено"
        case .scanning: "Поиск…"
        case .connecting: "Подключение…"
        case .discovering: "Обнаружение сервисов…"
        case .ready: "Готово к управлению"
        case .disconnected: "Отключено"
        case .error(let message): "Ошибка: \(message)"
        }
    }

    var isBusy: Bool {
        switch self {
        case .scanning, .connecting, .discovering: true
        default: false
        }
    }
}

/// Режим вывода: статический цвет или встроенный эффект контроллера.
enum OutputMode: Equatable, Codable {
    case color
    case effect(Int)

    var effectIndex: Int? {
        if case .effect(let i) = self { return i }
        return nil
    }
}

/// Что приложение в последний раз *запросило* у гирлянды.
/// Контроллер не подтверждает применение команд, поэтому это не «состояние устройства»,
/// а последняя отправленная команда. Интерфейс обязан помечать это честно.
struct RequestedState: Equatable {
    var isOn: Bool = true
    var mode: OutputMode = .color
    /// Встроенный эффект поставлен на паузу командой `06`.
    var effectPaused: Bool = false
    var color: RGB = RGB(red: 255, green: 160, blue: 60)
    /// Аппаратная яркость контроллера, 0...100.
    var brightness: Int = 100
    var lastSentAt: Date?
}

/// Запись журнала диагностики.
struct LogEntry: Identifiable, Equatable {
    enum Direction: String {
        case tx = "TX"
        case rx = "RX"
        case info = "INFO"
        case error = "ERR"
    }

    let id = UUID()
    let date: Date
    let direction: Direction
    let message: String
    let hex: String?

    init(_ direction: Direction, _ message: String, hex: String? = nil, date: Date = .now) {
        self.direction = direction
        self.message = message
        self.hex = hex
        self.date = date
    }
}
