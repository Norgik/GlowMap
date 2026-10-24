import Foundation

/// Формирование байтов команд для контроллера LEDDMX-00.
/// Здесь нет ни BLE, ни UI — только чистые функции «параметры → Data».
///
/// Все команды ниже проверены на реальной гирлянде LEDDMX-00-698A (22.10.2026):
/// цвет, включение, выключение, яркость, эффекты. Назначение фиксированных байтов
/// (`7B FF … BF`) не исследовано и здесь не интерпретируется.
enum GarlandProtocol {

    /// Статический цвет: `7B FF 07 RR GG BB 00 FF BF`, порядок каналов — RGB.
    static func color(red: UInt8, green: UInt8, blue: UInt8) -> Data {
        Data([
            0x7B, 0xFF, 0x07,
            red, green, blue,
            0x00, 0xFF, 0xBF
        ])
    }

    static func color(_ rgb: RGB) -> Data {
        color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    /// Включение: `7B FF 04 03 FF FF FF FF BF`
    static func powerOn() -> Data {
        Data([0x7B, 0xFF, 0x04, 0x03, 0xFF, 0xFF, 0xFF, 0xFF, 0xBF])
    }

    /// Выключение: `7B FF 04 02 FF FF FF FF BF`
    static func powerOff() -> Data {
        Data([0x7B, 0xFF, 0x04, 0x02, 0xFF, 0xFF, 0xFF, 0xFF, 0xBF])
    }

    static func power(_ on: Bool) -> Data { on ? powerOn() : powerOff() }

    /// Яркость: `7B FF 01 AA PP 00 FF FF BF`, PP — процент 0...100, AA = PP × 32 / 100.
    static func brightness(percent: Int) -> Data {
        let pp = UInt8(clamping: max(0, min(100, percent)))
        let aa = UInt8(clamping: Int(pp) * 32 / 100)
        return Data([0x7B, 0xFF, 0x01, aa, pp, 0x00, 0xFF, 0xFF, 0xBF])
    }

    /// Встроенный эффект: `7B FF 03 II FF FF FF FF BF`, II — индекс 0...210.
    /// Соответствие индексов конкретным анимациям контроллер не сообщает — пользователь
    /// подписывает их сам в приложении.
    static let effectRange = 0...210

    static func effect(index: Int) -> Data {
        let ii = UInt8(clamping: max(effectRange.lowerBound, min(effectRange.upperBound, index)))
        return Data([0x7B, 0xFF, 0x03, ii, 0xFF, 0xFF, 0xFF, 0xFF, 0xBF])
    }

    /// Пауза встроенного эффекта: `7B FF 06 01 …` замораживает кадр, `7B FF 06 00 …` продолжает.
    /// Проверено 24.10.2026 (из LED LAMP `pauseSPI`).
    static func effectPaused(_ paused: Bool) -> Data {
        Data([0x7B, 0xFF, 0x06, paused ? 0x01 : 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xBF])
    }
}

// MARK: - Экспериментальные команды (НЕ проверены на нашей гирлянде)

extension GarlandProtocol {
    /// Команды семейства LEDDMX-00/01/03 из декомпилированного приложения LED LAMP 4.3.5
    /// (репозитории LED_UNION, user154lt/LEDDMX-00, bt_light_control). На LEDDMX-00-698A
    /// не проверены; запускаются только вручную из «Лаборатории пикселей».
    ///
    /// Важно: ни в одной открытой реализации нет команды «цвет светодиода №N» или передачи
    /// кадра. Ниже — то, что даёт хоть какой-то доступ к геометрии ленты.
    enum Experimental {

        /// Порядок каналов для команды конфигурации (таблица `rgb_order.tsv` LED LAMP).
        enum ChannelOrder: Int, CaseIterable, Identifiable {
            case rgb = 1, rbg, grb, gbr, brg, bgr, rgbw, rbgw, grbw, gbrw, brgw, bgrw
            var id: Int { rawValue }
            var title: String { String(describing: self).uppercased() }
        }

        /// Конфигурация ленты: сколько пикселей контроллер должен выводить и в каком порядке
        /// каналы. `7B FF 05 04 <pixHi> <pixLo> <order> FF BF`. Байт 04 («bannerType») в LED LAMP
        /// жёстко зашит. Предположительно сохраняется в контроллере — после опытов вернуть 200/RGB.
        static func stripConfig(pixels: Int, order: ChannelOrder) -> Data {
            let p = UInt16(clamping: max(1, min(65535, pixels)))
            return Data([0x7B, 0xFF, 0x05, 0x04, UInt8(p >> 8), UInt8(p & 0xFF), UInt8(order.rawValue), 0xFF, 0xBF])
        }

        /// Скорость встроенного эффекта: `7B FF 02 <0…100> FF 00 FF FF BF`.
        static func speed(percent: Int) -> Data {
            Data([0x7B, 0xFF, 0x02, UInt8(clamping: max(0, min(100, percent))), 0xFF, 0x00, 0xFF, 0xFF, 0xBF])
        }

        /// Направление эффекта: `7B FF 0D <d> FF FF FF FF BF` (в LED LAMP 1 = вперёд, 0 = назад;
        /// у user154lt наоборот — проверять на устройстве).
        static func direction(forward: Bool) -> Data {
            Data([0x7B, 0xFF, 0x0D, forward ? 0x01 : 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xBF])
        }

        /// Цвет №`position` (с 1) в списке DIY-палитры из `total` цветов:
        /// `7B <pos> 0E <mode> RR GG BB <total> BF`, mode FD — скачком, FE — плавно.
        /// Это позиция в ПАЛИТРЕ анимации, а не номер светодиода.
        static func diyColor(position: Int, total: Int, color: RGB, fade: Bool) -> Data {
            Data([0x7B, UInt8(clamping: position), 0x0E, fade ? 0xFE : 0xFD,
                  color.red, color.green, color.blue, UInt8(clamping: total), 0xBF])
        }

        /// Запуск DIY-цикла после загрузки палитры (LED_UNION): `7B FF 0F 01 FF FF FF FF BF`.
        static func diyStart() -> Data {
            Data([0x7B, 0xFF, 0x0F, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xBF])
        }

        /// Режим DIY-анимации 0…7 (user154lt: GD, FD, FW, FS, AC, PU, FL, HO): `7B FF 13 <m> …`.
        static func diyMode(_ mode: Int) -> Data {
            Data([0x7B, 0xFF, 0x13, UInt8(clamping: max(0, min(7, mode))), 0xFF, 0xFF, 0xFF, 0xFF, 0xBF])
        }

        static let diyModeNames = ["GD", "FD", "FW", "FS", "AC", "PU", "FL", "HO"]

        /// Запрос статуса пароля `2A 05 FF FF FF FF FF FF AF` — единственный кадр, на который
        /// LED LAMP ожидает уведомление. Полезен, чтобы вообще увидеть ответ в FFE1.
        static func passwordStatusQuery() -> Data {
            Data([0x2A, 0x05, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xAF])
        }

        // MARK: Из декомпилированного LED LAMP 4.3.7 (com.ledlamp, NetConnectBle.java)

        /// Режимы graffiti-кадра (CutomFragmentDmx02Dmx04): 0 кисть, 1 ластик, 2 очистить всё,
        /// 3 и 4 — кнопки без подписи в коде (предположительно «залить» и «сохранить/показать»).
        enum GraffitiMode: Int, CaseIterable, Identifiable {
            case paint = 0, erase, clear, mode3, mode4
            var id: Int { rawValue }
            var title: String {
                switch self {
                case .paint: "кисть (00)"
                case .erase: "ластик (01)"
                case .clear: "очистить (02)"
                case .mode3: "режим 03"
                case .mode4: "режим 04"
                }
            }
        }

        /// Попиксельный graffiti-кадр семейств LEDDMX-02/04/06 и LEDCAR-02:
        /// `7C <mode> R G B idxHi idxLo FF CF`, индекс пикселя 0-based (в LED LAMP до 200).
        /// `setDmx0204Graffiti(bright, r, g, b, mode, hi, lo)` → `{124, mode, r, g, b, hi, lo, 255, 207}`.
        /// Для режима «очистить» приложение передаёт в поле индекса общее число пикселей.
        /// На LEDDMX-00 приложение этот экран не показывает — принимает ли прошивка кадр, неизвестно.
        static func graffiti(mode: GraffitiMode, color: RGB, pixel: Int) -> Data {
            let p = UInt16(clamping: max(0, pixel))
            return Data([0x7C, UInt8(mode.rawValue), color.red, color.green, color.blue,
                         UInt8(p >> 8), UInt8(p & 0xFF), 0xFF, 0xCF])
        }

        /// Очистка DIY/graffiti для DMX-02/04 (`setClearColor`): `7B 0E 00 00 00 00 00 FF BF`.
        /// Сдвинутая раскладка семейства 02/04 — на DMX-00 может не распознаться.
        static func dmx0204ClearColor() -> Data {
            Data([0x7B, 0x0E, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xBF])
        }

        /// «Подзона» — кнопки, которые LED LAMP показывает ТОЛЬКО для LEDDMX-00/01
        /// (`setDmx0001Subarea`): `7B FF 14 <0 центр | 1 лево | 2 право> FF FF FF FF BF`.
        static func subarea(_ zone: Int) -> Data {
            Data([0x7B, 0xFF, 0x14, UInt8(clamping: max(0, min(2, zone))), 0xFF, 0xFF, 0xFF, 0xFF, 0xBF])
        }

        /// «Вспомогательный канал» (`setAuxiliary`, кнопки tv_dmx_btn1…4 для LEDDMX):
        /// `7B FF 11 <0…3> FF FF FF FF BF`.
        static func auxiliary(_ channel: Int) -> Data {
            Data([0x7B, 0xFF, 0x11, UInt8(clamping: max(0, min(3, channel))), 0xFF, 0xFF, 0xFF, 0xFF, 0xBF])
        }
    }
}

/// Цвет в виде трёх байтов, как его принимает контроллер.
struct RGB: Hashable, Codable, Sendable {
    var red: UInt8
    var green: UInt8
    var blue: UInt8

    static let black = RGB(red: 0, green: 0, blue: 0)
    static let red = RGB(red: 255, green: 0, blue: 0)
    static let green = RGB(red: 0, green: 255, blue: 0)
    static let blue = RGB(red: 0, green: 0, blue: 255)
    static let white = RGB(red: 255, green: 255, blue: 255)

    /// Масштабирование каналов (используется для превью в интерфейсе).
    func scaled(by factor: Double) -> RGB {
        let f = max(0, min(1, factor))
        func s(_ v: UInt8) -> UInt8 { UInt8((Double(v) * f).rounded()) }
        return RGB(red: s(red), green: s(green), blue: s(blue))
    }

    var hexString: String {
        String(format: "%02X%02X%02X", red, green, blue)
    }
}

extension Data {
    /// HEX без пробелов, в том виде, в каком команда вводится в nRF Connect.
    var hexString: String {
        map { String(format: "%02X", $0) }.joined()
    }

    /// Разбор HEX-строки (пробелы и префикс 0x игнорируются). Возвращает nil при нечётной длине или мусоре.
    init?(hexString: String) {
        var cleaned = hexString
            .replacingOccurrences(of: "0x", with: "")
            .replacingOccurrences(of: "0X", with: "")
        cleaned.removeAll { $0.isWhitespace || $0 == "," || $0 == "-" || $0 == ":" }
        guard cleaned.count % 2 == 0, !cleaned.isEmpty else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
