import Foundation
import CoreBluetooth
import Observation

/// Поиск, подключение, обнаружение FFE0/FFE1, очередь записи, уведомления и ошибки.
/// Байты команд формирует `GarlandProtocol`; здесь только транспорт.
@Observable
@MainActor
final class BluetoothManager: NSObject {

    // MARK: - Наблюдаемое состояние

    private(set) var phase: ConnectionPhase = .idle
    private(set) var discovered: [DiscoveredDevice] = []
    private(set) var connectedName: String?
    private(set) var requested = RequestedState()
    private(set) var log: [LogEntry] = []
    /// Последнее значение, прочитанное или полученное уведомлением из FFE1. Формат неизвестен — только показываем.
    private(set) var lastReceived: Data?
    private(set) var writeMode: String = "—"
    private(set) var queuedCount = 0

    var isReady: Bool { phase == .ready }

    // MARK: - Внутреннее

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var characteristic: CBCharacteristic?
    private var writeType: CBCharacteristicWriteType = .withoutResponse

    /// Дискретные команды (питание, эффект, диагностика) — честная FIFO-очередь.
    private var commandQueue: [(data: Data, label: String)] = []
    /// Потоки от ползунков: храним только последнее значение, устаревшие не копим.
    private var pendingColor: RGB?
    private var pendingBrightness: Int?
    private var streamTask: Task<Void, Never>?
    private var sequenceTask: Task<Void, Never>?
    private var lastStreamSentAt: Date = .distantPast
    /// Стартовый интервал ~10 отправок/с. Не измеренный предел контроллера, а параметр приложения.
    private let streamInterval: TimeInterval = 0.1

    private let rememberedKey = "garland.peripheral.identifier"
    private var wantsReconnect = false
    private let maxLogEntries = 500

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil, options: [
            CBCentralManagerOptionShowPowerAlertKey: true
        ])
    }

    // MARK: - Публичные действия: соединение

    func startScan() {
        guard central.state == .poweredOn else {
            updatePhaseFromCentralState()
            return
        }
        discovered.removeAll()
        phase = .scanning
        // Без фильтра по FFE0: наличие этого UUID в advertising не подтверждено. Отбираем по имени.
        central.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: true
        ])
        info("Сканирование начато (фильтр по имени \(DiscoveredDevice.namePrefix)*)")
    }

    func stopScan() {
        if central.isScanning {
            central.stopScan()
            info("Сканирование остановлено")
        }
        if phase == .scanning { phase = .idle }
    }

    func connect(to device: DiscoveredDevice) {
        guard let p = central.retrievePeripherals(withIdentifiers: [device.id]).first else {
            fail("Периферия \(device.name) больше недоступна")
            return
        }
        connect(peripheral: p)
    }

    func disconnect() {
        wantsReconnect = false
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
            info("Запрошено отключение от \(peripheral.name ?? "устройства")")
        }
        clearPeripheral()
        phase = .idle
    }

    /// Попытка восстановить подключение к сохранённой гирлянде.
    func reconnectRemembered() {
        guard central.state == .poweredOn,
              let raw = UserDefaults.standard.string(forKey: rememberedKey),
              let id = UUID(uuidString: raw),
              let p = central.retrievePeripherals(withIdentifiers: [id]).first
        else { return }
        info("Восстановление подключения к \(p.name ?? id.uuidString)")
        connect(peripheral: p)
    }

    func forgetRemembered() {
        UserDefaults.standard.removeObject(forKey: rememberedKey)
        info("Сохранённое устройство забыто")
    }

    var hasRememberedDevice: Bool {
        UserDefaults.standard.string(forKey: rememberedKey) != nil
    }

    // MARK: - Публичные действия: управление

    func setPower(_ on: Bool) {
        requested.isOn = on
        enqueue(GarlandProtocol.power(on), label: on ? "включить" : "выключить")
    }

    /// Цвет от интерактивного элемента. `immediate: true` — при отпускании ползунка:
    /// отправить последнее значение обязательно и без задержки.
    func requestColor(_ color: RGB, immediate: Bool = false) {
        requested.color = color
        requested.mode = .color
        ensureOn()
        pendingColor = color
        scheduleStream(immediate: immediate)
    }

    func requestBrightness(_ percent: Int, immediate: Bool = false) {
        let clamped = max(0, min(100, percent))
        requested.brightness = clamped
        pendingBrightness = clamped
        scheduleStream(immediate: immediate)
    }

    func requestEffect(_ index: Int) {
        requested.mode = .effect(index)
        ensureOn()
        if requested.effectPaused {
            requested.effectPaused = false
            enqueue(GarlandProtocol.effectPaused(false), label: "снять паузу")
        }
        enqueue(GarlandProtocol.effect(index: index), label: "эффект \(index)")
    }

    /// Пауза/продолжение встроенного эффекта.
    func setEffectPaused(_ paused: Bool) {
        requested.effectPaused = paused
        enqueue(GarlandProtocol.effectPaused(paused), label: paused ? "пауза эффекта" : "продолжить эффект")
    }

    /// Применить сцену целиком: питание, яркость, затем цвет или эффект.
    func apply(_ scene: SavedScene) {
        ensureOn()
        requestBrightness(scene.brightness, immediate: true)
        switch scene.mode {
        case .color: requestColor(scene.color, immediate: true)
        case .effect(let i): requestEffect(i)
        }
    }

    /// Произвольная команда (диагностика). Попадает в FIFO-очередь.
    func send(raw data: Data, label: String) {
        enqueue(data, label: label)
    }

    /// Последовательность команд с паузой между ними (для опытов, где контроллеру нужно
    /// время применить предыдущий кадр). Новая последовательность отменяет незавершённую.
    func send(sequence: [(data: Data, label: String)], gap: TimeInterval) {
        guard isReady else {
            error("Последовательность не отправлена: устройство не готово")
            return
        }
        sequenceTask?.cancel()
        sequenceTask = Task { [weak self] in
            for (i, item) in sequence.enumerated() {
                guard let self, !Task.isCancelled else { return }
                self.enqueue(item.data, label: item.label)
                if i < sequence.count - 1 {
                    try? await Task.sleep(for: .seconds(gap))
                }
            }
        }
    }

    var isSequenceRunning: Bool { sequenceTask.map { !$0.isCancelled } ?? false }

    func cancelSequence() {
        sequenceTask?.cancel()
        sequenceTask = nil
    }

    func readCharacteristic() {
        guard let peripheral, let characteristic else { return }
        peripheral.readValue(for: characteristic)
        info("Запрошено чтение FFE1")
    }

    func clearLog() { log.removeAll() }

    // MARK: - Подключение

    private func connect(peripheral p: CBPeripheral) {
        stopScan()
        clearPeripheral()
        peripheral = p
        p.delegate = self
        wantsReconnect = true
        phase = .connecting
        connectedName = p.name
        info("Подключение к \(p.name ?? p.identifier.uuidString)")
        central.connect(p, options: nil)
    }

    private func clearPeripheral() {
        streamTask?.cancel()
        streamTask = nil
        sequenceTask?.cancel()
        sequenceTask = nil
        pendingColor = nil
        pendingBrightness = nil
        commandQueue.removeAll()
        queuedCount = 0
        characteristic = nil
        peripheral?.delegate = nil
        peripheral = nil
        connectedName = nil
        writeMode = "—"
    }

    private func updatePhaseFromCentralState() {
        switch central.state {
        case .poweredOn:
            if phase == .bluetoothOff || phase == .unauthorized || phase == .unsupported { phase = .idle }
        case .poweredOff: phase = .bluetoothOff
        case .unauthorized: phase = .unauthorized
        case .unsupported: phase = .unsupported
        case .resetting, .unknown: break
        @unknown default: break
        }
    }

    // MARK: - Очередь и отправка

    /// Если гирлянда выключена приложением, любое управление сначала включает её.
    private func ensureOn() {
        guard !requested.isOn else { return }
        requested.isOn = true
        enqueue(GarlandProtocol.powerOn(), label: "включить (авто)")
    }

    private func enqueue(_ data: Data, label: String) {
        guard isReady else {
            error("Команда «\(label)» не отправлена: устройство не готово")
            return
        }
        commandQueue.append((data, label))
        queuedCount = commandQueue.count
        flush()
    }

    private func scheduleStream(immediate: Bool) {
        guard isReady else { return }
        if immediate {
            streamTask?.cancel()
            streamTask = nil
            flush()
            return
        }
        guard streamTask == nil else { return } // уже ждём окна — значение просто перезапишется
        let elapsed = Date.now.timeIntervalSince(lastStreamSentAt)
        let delay = max(0, streamInterval - elapsed)
        streamTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.streamTask = nil
            self.flush()
        }
    }

    /// Выталкивает очередь, пока контроллер готов принимать запись без ответа.
    /// Приоритет: дискретные команды → яркость → цвет.
    private func flush() {
        guard let peripheral, let characteristic, isReady else { return }
        while true {
            if writeType == .withoutResponse, !peripheral.canSendWriteWithoutResponse {
                // Буфер занят — продолжим из peripheralIsReady(toSendWriteWithoutResponse:)
                return
            }
            let data: Data
            let label: String
            if !commandQueue.isEmpty {
                let item = commandQueue.removeFirst()
                queuedCount = commandQueue.count
                data = item.data
                label = item.label
            } else if let b = pendingBrightness {
                pendingBrightness = nil
                data = GarlandProtocol.brightness(percent: b)
                label = "яркость \(b)%"
                lastStreamSentAt = .now
            } else if let c = pendingColor {
                pendingColor = nil
                data = GarlandProtocol.color(c)
                label = "цвет #\(c.hexString)"
                lastStreamSentAt = .now
            } else {
                return
            }
            peripheral.writeValue(data, for: characteristic, type: writeType)
            requested.lastSentAt = .now
            tx(label, hex: data.hexString)
            if writeType == .withResponse { return } // следующий пакет — после didWriteValueFor
        }
    }

    // MARK: - Журнал

    private func append(_ entry: LogEntry) {
        log.append(entry)
        if log.count > maxLogEntries { log.removeFirst(log.count - maxLogEntries) }
    }
    private func info(_ m: String, hex: String? = nil) { append(LogEntry(.info, m, hex: hex)) }
    private func tx(_ m: String, hex: String) { append(LogEntry(.tx, m, hex: hex)) }
    private func rx(_ m: String, hex: String) { append(LogEntry(.rx, m, hex: hex)) }
    private func error(_ m: String) { append(LogEntry(.error, m)) }
    private func fail(_ m: String) { error(m); phase = .error(m) }
}

// MARK: - CBCentralManagerDelegate

extension BluetoothManager: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        Task { @MainActor in
            self.info("Состояние Bluetooth: \(Self.describe(state))")
            self.updatePhaseFromCentralState()
            if state == .poweredOn, self.peripheral == nil {
                self.reconnectRemembered()
            } else if state != .poweredOn {
                self.clearPeripheral()
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advName ?? peripheral.name
        guard DiscoveredDevice.matches(name: name), let name else { return }
        let id = peripheral.identifier
        let rssi = RSSI.intValue
        let mfg = (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data)?.hexString
        Task { @MainActor in
            if let i = self.discovered.firstIndex(where: { $0.id == id }) {
                self.discovered[i].rssi = rssi
                self.discovered[i].lastSeen = .now
            } else {
                self.discovered.append(DiscoveredDevice(id: id, name: name, rssi: rssi, lastSeen: .now))
                self.info("Найдено \(name), RSSI \(rssi)", hex: mfg.map { "MFG " + $0 })
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            guard peripheral == self.peripheral else { return }
            // Не «готово»: характеристика ещё не найдена.
            self.phase = .discovering
            self.info("Соединение установлено, ищем сервис FFE0")
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: self.rememberedKey)
            peripheral.discoverServices([GarlandUUID.service])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        let message = error?.localizedDescription ?? "неизвестная причина"
        Task { @MainActor in
            guard peripheral == self.peripheral else { return }
            self.fail("Не удалось подключиться: \(message)")
            self.clearPeripheral()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        let message = error?.localizedDescription
        Task { @MainActor in
            guard peripheral == self.peripheral else { return }
            self.characteristic = nil
            self.phase = .disconnected
            self.info("Отключено" + (message.map { ": \($0)" } ?? ""))
            if self.wantsReconnect {
                // CoreBluetooth держит запрос, пока устройство не появится снова (например, после включения питания).
                self.phase = .connecting
                self.info("Ожидание повторного подключения…")
                central.connect(peripheral, options: nil)
            }
        }
    }

    private static func describe(_ s: CBManagerState) -> String {
        switch s {
        case .poweredOn: "включён"
        case .poweredOff: "выключен"
        case .unauthorized: "нет разрешения"
        case .unsupported: "не поддерживается"
        case .resetting: "сброс"
        case .unknown: "неизвестно"
        @unknown default: "неизвестно"
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BluetoothManager: CBPeripheralDelegate {

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        let message = error?.localizedDescription
        let services = peripheral.services ?? []
        Task { @MainActor in
            if let message { self.fail("Ошибка обнаружения сервисов: \(message)"); return }
            guard let service = services.first(where: { $0.uuid == GarlandUUID.service }) else {
                self.fail("Сервис FFE0 не найден")
                return
            }
            self.info("Сервис FFE0 найден, ищем FFE1")
            peripheral.discoverCharacteristics([GarlandUUID.characteristic], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        let message = error?.localizedDescription
        let chars = service.characteristics ?? []
        Task { @MainActor in
            if let message { self.fail("Ошибка обнаружения характеристик: \(message)"); return }
            guard let ch = chars.first(where: { $0.uuid == GarlandUUID.characteristic }) else {
                self.fail("Характеристика FFE1 не найдена")
                return
            }
            let props = ch.properties
            var list: [String] = []
            if props.contains(.read) { list.append("Read") }
            if props.contains(.write) { list.append("Write") }
            if props.contains(.writeWithoutResponse) { list.append("WriteWithoutResponse") }
            if props.contains(.notify) { list.append("Notify") }
            self.info("FFE1: " + list.joined(separator: ", "))

            if props.contains(.writeWithoutResponse) {
                self.writeType = .withoutResponse
                self.writeMode = "без ответа"
            } else if props.contains(.write) {
                self.writeType = .withResponse
                self.writeMode = "с ответом"
            } else {
                self.fail("FFE1 не поддерживает запись")
                return
            }
            self.characteristic = ch
            if props.contains(.notify) {
                peripheral.setNotifyValue(true, for: ch)
            }
            if props.contains(.read) {
                peripheral.readValue(for: ch)
            }
            self.phase = .ready
            self.info("Готово к управлению (запись \(self.writeMode))")
            self.flush()
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        let message = error?.localizedDescription
        let value = characteristic.value
        Task { @MainActor in
            if let message { self.error("Ошибка чтения FFE1: \(message)"); return }
            guard let value else { return }
            self.lastReceived = value
            // Формат не задокументирован — только журналируем, не декодируем.
            self.rx("FFE1 → \(value.count) байт", hex: value.hexString)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateNotificationStateFor characteristic: CBCharacteristic, error: (any Error)?) {
        let message = error?.localizedDescription
        let on = characteristic.isNotifying
        Task { @MainActor in
            if let message { self.error("Подписка на уведомления: \(message)") }
            else { self.info("Уведомления FFE1 \(on ? "включены" : "выключены")") }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didWriteValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        let message = error?.localizedDescription
        Task { @MainActor in
            if let message { self.error("Ошибка записи: \(message)") }
            else { self.info("Запись подтверждена контроллером (ATT)") }
            self.flush()
        }
    }

    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        Task { @MainActor in self.flush() }
    }

    nonisolated func peripheralDidUpdateName(_ peripheral: CBPeripheral) {
        let name = peripheral.name
        Task { @MainActor in self.connectedName = name }
    }
}
