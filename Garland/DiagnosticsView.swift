import SwiftUI

/// Журнал TX/RX и ручная отправка команд — для проверки протокола и разбора проблем.
struct DiagnosticsView: View {
    @Environment(BluetoothManager.self) private var bt
    @Environment(\.dismiss) private var dismiss

    @State private var rawHex = "7BFF07FF000000FFBF"
    @State private var brightnessPercent = 50
    @State private var effectIndex = 1

    var body: some View {
        NavigationStack {
            List {
                connectionSection
                rawSection
                protocolSection
                logSection
            }
            .navigationTitle("Диагностика")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ShareLink(item: logText) { Label("Поделиться журналом", systemImage: "square.and.arrow.up") }
                        Button(role: .destructive) { bt.clearLog() } label: { Label("Очистить", systemImage: "trash") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
    }

    // MARK: - Секции

    private var connectionSection: some View {
        Section("Соединение") {
            row("Состояние", bt.phase.title)
            row("Устройство", bt.connectedName ?? "—")
            row("Сервис / характеристика", "FFE0 / FFE1")
            row("Режим записи", bt.writeMode)
            row("В очереди", "\(bt.queuedCount)")
            row("Последнее из FFE1", bt.lastReceived?.hexString ?? "—", mono: true)
            Button("Прочитать FFE1") { bt.readCharacteristic() }.disabled(!bt.isReady)
        }
    }

    private var rawSection: some View {
        Section {
            TextField("HEX, например 7BFF07FF000000FFBF", text: $rawHex)
                .font(.system(.body, design: .monospaced))
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            HStack {
                Text(parsedRaw.map { "\($0.count) байт" } ?? "Некорректный HEX")
                    .font(.caption).foregroundStyle(parsedRaw == nil ? .red : .secondary)
                Spacer()
                Button("Отправить") {
                    if let data = parsedRaw { bt.send(raw: data, label: "ручная команда") }
                }
                .disabled(parsedRaw == nil || !bt.isReady)
            }
        } header: {
            Text("Произвольная команда")
        } footer: {
            Text("Байты уходят в FFE1 как есть. Пробелы игнорируются. Для исследования новых команд (скорость, таймер, микрофон) — меняйте байты здесь и смотрите на гирлянду.")
        }
    }

    private var protocolSection: some View {
        Section {
            Button("Включить  7BFF0403FFFFFFFFBF") { bt.setPower(true) }
            Button("Выключить  7BFF0402FFFFFFFFBF") { bt.setPower(false) }
            HStack {
                Stepper("Яркость \(brightnessPercent)%", value: $brightnessPercent, in: 0...100, step: 10)
                Button("Тест") { bt.requestBrightness(brightnessPercent, immediate: true) }
                    .buttonStyle(.bordered)
            }
            HStack {
                Stepper("Эффект №\(effectIndex)", value: $effectIndex, in: GarlandProtocol.effectRange)
                Button("Тест") { bt.requestEffect(effectIndex) }
                    .buttonStyle(.bordered)
            }
        } header: {
            Text("Команды протокола")
        } footer: {
            Text("Все проверены на LEDDMX-00-698A 22.10.2026. Отсюда удобно сверять HEX в журнале.")
        }
        .disabled(!bt.isReady)
    }

    private var logSection: some View {
        Section("Журнал (\(bt.log.count))") {
            if bt.log.isEmpty {
                Text("Пусто").foregroundStyle(.secondary)
            }
            ForEach(bt.log.reversed()) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(entry.direction.rawValue)
                            .font(.caption2.bold())
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(badgeColor(entry.direction).opacity(0.25), in: Capsule())
                            .foregroundStyle(badgeColor(entry.direction))
                        Text(entry.date.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3))))
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        Text(entry.message).font(.caption)
                    }
                    if let hex = entry.hex {
                        Text(hex).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            }
        }
    }

    // MARK: - Вспомогательное

    private var parsedRaw: Data? { Data(hexString: rawHex) }

    private var logText: String {
        bt.log.map { e in
            let t = e.date.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3)))
            return "\(t) \(e.direction.rawValue) \(e.message)" + (e.hex.map { "  \($0)" } ?? "")
        }.joined(separator: "\n")
    }

    private func row(_ title: String, _ value: String, mono: Bool = false) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .font(mono ? .system(.footnote, design: .monospaced) : .body)
                .multilineTextAlignment(.trailing)
        }
    }

    private func badgeColor(_ d: LogEntry.Direction) -> Color {
        switch d {
        case .tx: .blue
        case .rx: .green
        case .info: .gray
        case .error: .red
        }
    }
}
