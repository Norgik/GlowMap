import Foundation
import Network
import Observation

/// Кадр для адресной ленты: по одному RGB на пиксель.
struct LEDFrame: Equatable {
    var pixels: [RGB]

    init(count: Int, fill: RGB = .black) {
        pixels = Array(repeating: fill, count: count)
    }

    var count: Int { pixels.count }

    subscript(i: Int) -> RGB {
        get { pixels[i] }
        set { pixels[i] = newValue }
    }

    /// Сырые байты R,G,B,R,G,B… для DDP.
    var rgbBytes: Data {
        var d = Data(capacity: pixels.count * 3)
        for p in pixels { d.append(contentsOf: [p.red, p.green, p.blue]) }
        return d
    }
}

/// Транспорт к ESP32 с WLED: HTTP JSON для настройки и состояния, DDP (UDP 4048) для кадров.
/// Проверено 24.10.2026 на `wled-5de7f8` (WLED 16.0.1): 200 px, GPIO18, порядок RGB, 40 fps по DDP.
@Observable
@MainActor
final class WLEDClient {

    enum Phase: Equatable {
        case idle, searching, connecting, ready, error(String)
        var title: String {
            switch self {
            case .idle: "WLED не выбран"
            case .searching: "Поиск WLED в сети…"
            case .connecting: "Подключение к WLED…"
            case .ready: "WLED готов"
            case .error(let m): "WLED: \(m)"
            }
        }
    }

    struct Info: Equatable {
        var name: String
        var version: String
        var ledCount: Int
        var ip: String
        var fps: Int
    }

    private(set) var phase: Phase = .idle
    private(set) var info: Info?
    private(set) var host: String?
    private(set) var discovered: [String: String] = [:]   // имя → host
    private(set) var framesSent = 0
    private(set) var lastError: String?

    var isReady: Bool { phase == .ready }
    /// Физическая длина ленты (из конфигурации WLED). `info.leds.count` в 2D-режиме равен числу
    /// ячеек матрицы, поэтому им пользоваться нельзя.
    private(set) var physicalLEDCount: Int?
    var ledCount: Int { physicalLEDCount ?? info?.ledCount ?? 200 }

    private var browser: NWBrowser?
    private var udp: NWConnection?
    private var ddpSequence: UInt8 = 0
    private let hostKey = "wled.host"
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 4
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    // MARK: - Подключение

    /// Пытается восстановить последний хост; иначе ищет по Bonjour (_wled._tcp).
    func start() {
        loadSavedGrid()
        if let saved = UserDefaults.standard.string(forKey: hostKey) {
            connect(host: saved)
        } else {
            startBrowsing()
        }
    }

    func startBrowsing() {
        phase = .searching
        browser?.cancel()
        let params = NWParameters()
        params.includePeerToPeer = true
        let b = NWBrowser(for: .bonjour(type: "_wled._tcp", domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self else { return }
                var found: [String: String] = [:]
                for r in results {
                    if case let .service(name, _, _, _) = r.endpoint {
                        // Хост WLED совпадает с именем сервиса + .local
                        found[name] = name.lowercased() + ".local"
                    }
                }
                self.discovered = found
                if self.host == nil, let first = found.values.sorted().first {
                    self.connect(host: first)
                }
            }
        }
        b.stateUpdateHandler = { [weak self] state in
            if case .failed(let e) = state {
                Task { @MainActor in self?.phase = .error("поиск: \(e.localizedDescription)") }
            }
        }
        browser = b
        b.start(queue: .main)
        // Bonjour на iOS часто молчит без разрешения на локальную сеть — не висим вечно.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, self.phase == .searching else { return }
            self.browser?.cancel()
            self.phase = .error("по Bonjour не найден — введите IP вручную")
        }
    }

    /// Адрес, который стоит предложить, если ничего не сохранено (последний известный IP платы).
    static let suggestedHost = "192.168.1.166"

    func connect(host newHost: String) {
        let h = newHost.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return }
        host = h
        browser?.cancel()
        phase = .connecting
        openUDP()
        Task { await refreshInfo() }
    }

    func forget() {
        UserDefaults.standard.removeObject(forKey: hostKey)
        udp?.cancel(); udp = nil
        host = nil; info = nil
        phase = .idle
    }

    /// Читает /json/info; успех переводит в `.ready` и запоминает хост.
    func refreshInfo() async {
        guard let host else { return }
        do {
            let (data, _) = try await session.data(from: URL(string: "http://\(host)/json/info")!)
            guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw URLError(.cannotParseResponse)
            }
            let leds = j["leds"] as? [String: Any]
            info = Info(name: j["name"] as? String ?? "WLED",
                        version: j["ver"] as? String ?? "?",
                        ledCount: leds?["count"] as? Int ?? 0,
                        ip: j["ip"] as? String ?? host,
                        fps: leds?["fps"] as? Int ?? 0)
            UserDefaults.standard.set(host, forKey: hostKey)
            await refreshLEDConfig()
            phase = .ready
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            phase = .error(error.localizedDescription)
        }
    }

    /// Длина ленты и параметры выхода из /json/cfg.
    private(set) var outputConfig: (pin: Int, type: Int, order: Int)?

    func refreshLEDConfig() async {
        guard let host,
              let (data, _) = try? await session.data(from: URL(string: "http://\(host)/json/cfg")!),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let led = (j["hw"] as? [String: Any])?["led"] as? [String: Any] else { return }
        let ins = led["ins"] as? [[String: Any]] ?? []
        let total = ins.reduce(0) { $0 + (($1["len"] as? Int) ?? 0) }
        if total > 0 { physicalLEDCount = total }
        if let first = ins.first {
            outputConfig = ((first["pin"] as? [Int])?.first ?? 18, first["type"] as? Int ?? 22, first["order"] as? Int ?? 1)
        }
    }

    /// Сменить длину ленты (другая гирлянда). Переписывает выход WLED, снимает карту и
    /// переводит контроллер в прямой режим на новую длину.
    func setLEDCount(_ n: Int) async -> Bool {
        let n = max(1, min(1000, n))
        let cfg = outputConfig ?? (18, 22, 1)
        let ok = await post(path: "/json/cfg", body: ["hw": ["led": ["total": n, "ins": [
            ["start": 0, "len": n, "pin": [cfg.pin], "order": cfg.order, "type": cfg.type, "rev": false, "skip": 0, "ref": false, "rgbwm": 0, "freq": 0]]]]])
        guard ok else { return false }
        try? await Task.sleep(for: .seconds(2))
        physicalLEDCount = n
        currentGrid = nil
        // карта 2D от старой ленты больше не имеет смысла
        _ = await setDirectMode(force: true)
        await refreshInfo()
        return true
    }

    // MARK: - JSON API

    /// POST /json/state. Возвращает true при {"success":true}.
    @discardableResult
    func postState(_ body: [String: Any]) async -> Bool {
        await post(path: "/json/state", body: body)
    }

    func setPower(_ on: Bool) async { await postState(["on": on, "transition": 0]) }

    /// Снять заморозку сегмента (после попиксельных команд) — иначе цвета и эффекты не применяются.
    func unfreeze() async { await postState(["seg": ["id": 0, "frz": false]]) }

    func setBrightness(_ bri: Int) async { await postState(["bri": max(0, min(255, bri)), "transition": 0]) }

    /// Сплошной цвет на всю ленту через сегмент 0.
    func setSolid(_ c: RGB, brightness: Int? = nil) async {
        // frz:false — после попиксельной команды WLED «замораживает» сегмент и игнорирует цвет
        var seg = fullSegment
        seg["fx"] = 0; seg["frz"] = false
        seg["col"] = [[Int(c.red), Int(c.green), Int(c.blue)], [0, 0, 0], [0, 0, 0]]
        var body: [String: Any] = ["on": true, "transition": 0, "live": false, "seg": [seg]]
        if let brightness { body["bri"] = brightness }
        await postState(body)
    }

    /// Номер ячейки WLED для физического LED в текущем режиме (в прямом режиме — сам номер).
    func cellIndex(forLED i: Int) -> Int? {
        guard let g = activeGrid else { return i }
        return g.cells.firstIndex(of: i)
    }

    /// Отдельные пиксели через JSON (медленно, но без UDP): [LED: colour]. В 2D-режиме переводится в ячейки.
    func setPixels(_ map: [Int: RGB]) async {
        var arr: [Any] = []
        for (i, c) in map.sorted(by: { $0.key < $1.key }) {
            guard let cell = cellIndex(forLED: i) else { continue }
            arr.append(cell); arr.append([Int(c.red), Int(c.green), Int(c.blue)])
        }
        guard !arr.isEmpty else { return }
        await postState(["seg": ["id": 0, "i": arr]])
    }

    private func post(path: String, body: [String: Any]) async -> Bool {
        guard let host else { return false }
        var req = URLRequest(url: URL(string: "http://\(host)\(path)")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, _) = try await session.data(for: req)
            let ok = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["success"] as? Bool ?? false
            if !ok { lastError = "WLED отклонил команду" }
            return ok
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    // MARK: - Карта в WLED (ledmap.json) и автономные эффекты

    struct UploadResult: Equatable { var width: Int; var height: Int; var placed: Int; var collisions: Int }
    private(set) var lastUpload: UploadResult?
    private(set) var matrix: (w: Int, h: Int)?

    /// Сетка, которая сейчас записана в WLED (ячейка → LED). Нужна, чтобы в 2D-режиме слать кадры
    /// и пиксели в координатах ячеек: после загрузки карты WLED адресует именно их.
    private(set) var currentGrid: LedmapExport.Grid? {
        didSet {
            if let g = currentGrid, let d = try? JSONEncoder().encode(GridRecord(w: g.width, h: g.height, cells: g.cells)) {
                UserDefaults.standard.set(d, forKey: "wled.grid")
            } else { UserDefaults.standard.removeObject(forKey: "wled.grid") }
        }
    }
    private struct GridRecord: Codable { var w: Int; var h: Int; var cells: [Int] }

    private func loadSavedGrid() {
        guard let d = UserDefaults.standard.data(forKey: "wled.grid"),
              let r = try? JSONDecoder().decode(GridRecord.self, from: d) else { return }
        currentGrid = LedmapExport.Grid(width: r.w, height: r.h, cells: r.cells,
                                        placed: r.cells.filter { $0 >= 0 }.count, collisions: 0)
    }

    /// Сетка действует, если WLED сейчас в 2D с тем же размером.
    private var activeGrid: LedmapExport.Grid? {
        guard case .map2D(let w, let h) = addressingMode, let g = currentGrid, g.width == w, g.height == h else { return nil }
        return g
    }

    /// Геометрия сегмента 0 на всю ленту/матрицу для текущего режима.
    private var fullSegment: [String: Any] {
        if case .map2D(let w, let h) = addressingMode {
            return ["id": 0, "start": 0, "stop": w, "startY": 0, "stopY": h, "grp": 1, "spc": 0, "of": 0]
        }
        return ["id": 0, "start": 0, "stop": ledCount, "grp": 1, "spc": 0, "of": 0]
    }

    /// Загружает 2D-карту во флеш WLED, активирует её и закрепляет размер матрицы в конфиге.
    /// После этого встроенные 2D-эффекты идут по форме гирлянды без телефона.
    func uploadLedmap(_ grid: LedmapExport.Grid) async -> Bool {
        guard await uploadFile(name: "/ledmap.json", data: LedmapExport.json(grid)) else { return false }
        // Активировать карту и закрепить матрицу в cfg (чтобы пережила перезагрузку)
        _ = await postState(["ledmap": 0])
        _ = await post(path: "/json/cfg", body: ["hw": ["led": ["matrix": ["mpc": 1, "panels": [
            ["b": false, "r": false, "v": false, "s": false, "x": 0, "y": 0, "h": grid.height, "w": grid.width]]]]]])
        try? await Task.sleep(for: .seconds(1))
        currentGrid = grid
        await refreshMatrix()
        // Сегмент 0 остаётся одномерным 0…N — в 2D его надо растянуть на весь прямоугольник,
        // иначе эффекты рисуют в обрезанной области.
        var seg = fullSegment
        seg["frz"] = false
        _ = await postState(["seg": [seg]])
        lastUpload = UploadResult(width: grid.width, height: grid.height, placed: grid.placed, collisions: grid.collisions)
        return true
    }

    /// Режим адресации в WLED: прямой (номер = физический LED) или карта 2D (номера идут через сетку).
    enum AddressingMode: Equatable {
        case direct, map2D(w: Int, h: Int), unknown
        var title: String {
            switch self {
            case .direct: "прямой (1:1)"
            case .map2D(let w, let h): "карта 2D \(w)×\(h)"
            case .unknown: "неизвестно"
            }
        }
    }

    var addressingMode: AddressingMode {
        guard let matrix else { return info == nil ? .unknown : .direct }
        // Матрица шириной во всю ленту и высотой 1 — это прямой режим после перезагрузки
        return (matrix.h == 1 && matrix.w == ledCount) ? .direct : .map2D(w: matrix.w, h: matrix.h)
    }

    private(set) var switchingMode = false

    /// Прямой режим: карта 1:1, матрица выключена, перезагрузка (иначе WLED держит старый размер).
    /// Нужен для сканирования и попиксельных тестов. Занимает ~15 с.
    func setDirectMode(force: Bool = false) async -> Bool {
        guard host != nil, force || addressingMode != .direct else { return true }
        switchingMode = true
        defer { switchingMode = false }
        let identity = LedmapExport.Grid(width: ledCount, height: 1, cells: Array(0..<ledCount), placed: ledCount, collisions: 0)
        guard await uploadFile(name: "/ledmap.json", data: Data(("{\"map\":[" + (0..<ledCount).map(String.init).joined(separator: ",") + "]}").utf8)) else { return false }
        _ = identity
        _ = await post(path: "/json/cfg", body: ["hw": ["led": ["matrix": ["mpc": 0, "panels": []]]]])
        _ = await postState(["rb": true])
        try? await Task.sleep(for: .seconds(10))
        for _ in 0..<10 {
            await refreshMatrix()
            if info != nil, addressingMode == .direct {
                currentGrid = nil
                var seg = fullSegment; seg["frz"] = false
                _ = await postState(["seg": [seg]])
                return true
            }
            try? await Task.sleep(for: .seconds(2))
        }
        lastError = "WLED не вернулся в прямой режим"
        return false
    }

    private func uploadFile(name: String, data: Data) async -> Bool {
        guard let host else { return false }
        let boundary = "garland-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"data\"; filename=\"\(name)\"\r\nContent-Type: application/json\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        var req = URLRequest(url: URL(string: "http://\(host)/upload")!)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        do {
            let (resp, http) = try await session.data(for: req)
            let text = String(data: resp, encoding: .utf8) ?? ""
            guard (http as? HTTPURLResponse)?.statusCode == 200, text.contains("Uploaded") else {
                lastError = "WLED не принял файл: \(text.prefix(80))"; return false
            }
            return true
        } catch {
            lastError = "upload: \(error.localizedDescription)"; return false
        }
    }

    func refreshMatrix() async {
        guard let host,
              let (data, _) = try? await session.data(from: URL(string: "http://\(host)/json/info")!),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let leds = j["leds"] as? [String: Any] else { return }
        if let m = leds["matrix"] as? [String: Any], let w = m["w"] as? Int, let h = m["h"] as? Int {
            matrix = (w, h)
        } else {
            matrix = nil
        }
    }

    /// Встроенный эффект WLED (работает автономно). `speed`/`intensity` 0…255, `palette` — id палитры.
    func setEffect(_ id: Int, speed: Int = 128, intensity: Int = 128, palette: Int = 0, brightness: Int? = nil) async {
        var seg = fullSegment
        seg["frz"] = false; seg["fx"] = id; seg["sx"] = speed; seg["ix"] = intensity; seg["pal"] = palette
        // Цвета сегмента: многие эффекты берут их вместо палитры, если палитра «своя» (0)
        seg["col"] = [[255, 120, 0], [0, 80, 255], [0, 0, 0]]
        var body: [String: Any] = ["on": true, "live": false, "transition": 3, "seg": [seg]]
        if let brightness { body["bri"] = brightness }
        await postState(body)
    }

    /// Подборка 2D-эффектов WLED 16 (id из /json/eff этой прошивки), которые хорошо смотрятся на гирлянде.
    static let curated2DEffects: [(id: Int, title: String)] = [
        (164, "Дрейф"), (165, "Волны"), (178, "Плазма"), (174, "Северное сияние"), (42, "Фейерверк"),
        (43, "Дождь"), (146, "Шум 2D"), (152, "ДНК"), (188, "Огонь"), (196, "Водопад"),
        (121, "Капли"), (176, "Лиссажу"), (172, "Жизнь"), (166, "Солнце"), (183, "Чёрная дыра"),
    ]

    // MARK: - Пресеты, плейлист, таймеры (всё хранится и исполняется в WLED)

    /// Сохранить текущее состояние WLED как пресет `id` (1…250).
    func savePreset(id: Int, name: String) async -> Bool {
        await postState(["psave": id, "n": name, "ib": true, "sb": true])
    }

    func applyPreset(id: Int) async -> Bool { await postState(["ps": id]) }

    func deletePreset(id: Int) async -> Bool { await postState(["pdel": id]) }

    /// Пресет-плейлист: по кругу переключает пресеты `ids` с длительностью `seconds` каждый.
    func savePlaylist(id: Int, name: String, presetIDs: [Int], seconds: [Int], transitionSeconds: Double = 1) async -> Bool {
        guard !presetIDs.isEmpty, presetIDs.count == seconds.count else { return false }
        let pl: [String: Any] = [
            "ps": presetIDs, "dur": seconds.map { $0 * 10 },
            "transition": Array(repeating: Int(transitionSeconds * 10), count: presetIDs.count),
            "repeat": 0, "end": 0, "r": false
        ]
        return await postState(["playlist": pl, "psave": id, "n": name])
    }

    /// Запустить плейлист сразу (без сохранения).
    func startPlaylist(presetIDs: [Int], seconds: [Int]) async -> Bool {
        let pl: [String: Any] = ["ps": presetIDs, "dur": seconds.map { $0 * 10 },
                                 "transition": Array(repeating: 10, count: presetIDs.count), "repeat": 0, "end": 0]
        return await postState(["on": true, "playlist": pl])
    }

    struct Timer: Codable, Equatable {
        var enabled: Bool
        var hour: Int
        var minute: Int
        var presetID: Int      // 0 — ничего; пресет, который применится
        var days: Int = 127    // битовая маска дней, 127 = ежедневно
    }

    /// Включить NTP и часовой пояс (иначе таймеры по часам не работают). tz — индекс WLED (2 = Центральная Европа).
    func enableNTP(timezone: Int = 2) async -> Bool {
        await post(path: "/json/cfg", body: ["if": ["ntp": ["en": true, "host": "pool.ntp.org", "tz": timezone, "offset": 0, "ln": false]]])
    }

    func readTimers() async -> [Timer] {
        guard let host,
              let (data, _) = try? await session.data(from: URL(string: "http://\(host)/json/cfg")!),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ins = (j["timers"] as? [String: Any])?["ins"] as? [[String: Any]] else { return [] }
        return ins.map { t in
            Timer(enabled: ((t["en"] as? Int) ?? 0) != 0, hour: t["hour"] as? Int ?? 0, minute: t["min"] as? Int ?? 0,
                  presetID: t["macro"] as? Int ?? 0, days: t["dow"] as? Int ?? 127)
        }
    }

    /// Записать таймеры (до 8). Пустые слоты выключаются.
    func writeTimers(_ timers: [Timer]) async -> Bool {
        var ins: [[String: Any]] = timers.prefix(8).map {
            ["en": $0.enabled ? 1 : 0, "hour": $0.hour, "min": $0.minute, "macro": $0.presetID, "dow": $0.days,
             "start": ["mon": 1, "day": 1], "end": ["mon": 12, "day": 31]]
        }
        while ins.count < 8 { ins.append(["en": 0, "hour": 0, "min": 0, "macro": 0, "dow": 127]) }
        return await post(path: "/json/cfg", body: ["timers": ["ins": ins]])
    }

    /// Время контроллера по его мнению (строка из /json/info, "1970-…" значит NTP не синхронизирован).
    func readTime() async -> String? {
        guard let host,
              let (data, _) = try? await session.data(from: URL(string: "http://\(host)/json/info")!),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return j["time"] as? String
    }

    /// Бегущий текст (эффект Scrolling Text, только латиница/цифры, нужен 2D-режим).
    func showText(_ text: String, color: RGB, background: RGB = .black, speed: Int = 128, brightness: Int? = nil) async {
        var seg = fullSegment
        seg["fx"] = 122; seg["frz"] = false; seg["sx"] = speed; seg["ix"] = 128; seg["pal"] = 0
        seg["n"] = text
        seg["col"] = [[Int(color.red), Int(color.green), Int(color.blue)],
                      [Int(background.red), Int(background.green), Int(background.blue)], [0, 0, 0]]
        var body: [String: Any] = ["on": true, "live": false, "transition": 0, "seg": [seg]]
        if let brightness { body["bri"] = brightness }
        await postState(body)
    }

    // MARK: - DDP (UDP 4048)

    private var udpReady = false
    private var udpRetries = 0

    private func openUDP() {
        udp?.cancel()
        udpReady = false
        guard let host else { return }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: 4048, using: .udp)
        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, conn === self.udp else { return }
                switch state {
                case .ready:
                    self.udpReady = true
                    self.udpRetries = 0
                    if self.lastError?.hasPrefix("DDP") == true { self.lastError = nil }
                case .failed(let e), .waiting(let e):
                    // Первый запуск: сокет открывается, пока iOS ещё спрашивает про локальную сеть.
                    self.udpReady = false
                    self.lastError = "DDP: \(e.localizedDescription)"
                    if self.udpRetries < 5 {
                        self.udpRetries += 1
                        let delay = Double(self.udpRetries)
                        Task { [weak self] in
                            try? await Task.sleep(for: .seconds(delay))
                            guard let self, !self.udpReady else { return }
                            self.openUDP()
                        }
                    }
                default: break
                }
            }
        }
        conn.start(queue: .global(qos: .userInteractive))
        udp = conn
    }

    /// Переоткрыть UDP вручную (кнопка на экране).
    func reopenDDP() {
        udpRetries = 0
        openUDP()
    }

    /// Один кадр целиком. Заголовок DDP: 0x41 (v1 | push), seq, type, id=1, offset(4, BE), length(2, BE).
    /// WLED держит realtime-режим ~2,5 с после последнего пакета, затем возвращает своё состояние.
    func sendFrame(_ frame: LEDFrame) {
        guard let udp, udpReady else {
            if udp == nil || !udpReady, udpRetries == 0 { openUDP() }
            return
        }
        // В 2D-режиме WLED адресует ячейки сетки, а не LED: перекладываем кадр по карте
        var out = frame
        if let g = activeGrid {
            var cells = LEDFrame(count: g.cells.count)
            for (c, led) in g.cells.enumerated() where led >= 0 && led < frame.count { cells[c] = frame[led] }
            out = cells
        }
        let payload = out.rgbBytes
        var pkt = Data(capacity: 10 + payload.count)
        ddpSequence = (ddpSequence &+ 1) & 0x0F
        pkt.append(contentsOf: [0x41, ddpSequence, 0x01, 0x01, 0, 0, 0, 0,
                                UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)])
        pkt.append(payload)
        udp.send(content: pkt, completion: .contentProcessed { _ in })
        framesSent += 1
    }

    /// Выход из realtime: WLED сам вернётся к состоянию через ~2,5 с; этот вызов ускоряет.
    func endRealtime() async {
        await postState(["live": false])
    }
}
