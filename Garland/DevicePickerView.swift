import SwiftUI

struct DevicePickerView: View {
    @Environment(BluetoothManager.self) private var bt
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text(bt.phase.title)
                        Spacer()
                        if bt.phase.isBusy { ProgressView() }
                    }
                    if bt.connectedName != nil {
                        Button("Отключиться", role: .destructive) { bt.disconnect() }
                    }
                } header: {
                    Text("Состояние")
                } footer: {
                    switch bt.phase {
                    case .bluetoothOff:
                        Text("Включите Bluetooth в Пункте управления или Настройках.")
                    case .unauthorized:
                        Text("Разрешите доступ к Bluetooth: Настройки → Гирлянда → Bluetooth.")
                    default:
                        Text("Перед проверкой закройте LED LAMP и отключитесь в nRF Connect — контроллер держит одно соединение.")
                    }
                }

                Section {
                    if bt.discovered.isEmpty {
                        Text(bt.phase == .scanning ? "Ищем LEDDMX-00…" : "Нажмите «Искать»")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(bt.discovered.sorted { $0.rssi > $1.rssi }) { device in
                        Button {
                            bt.connect(to: device)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(device.name).font(.body)
                                    Text(device.id.uuidString).font(.caption2).foregroundStyle(.tertiary)
                                }
                                Spacer()
                                rssiView(device.rssi)
                            }
                        }
                        .tint(.primary)
                    }
                } header: {
                    HStack {
                        Text("Найденные гирлянды")
                        Spacer()
                        if bt.phase == .scanning {
                            Button("Стоп") { bt.stopScan() }
                        } else {
                            Button("Искать") { bt.startScan() }
                        }
                    }
                    .textCase(nil)
                }

                if bt.hasRememberedDevice {
                    Section {
                        Button("Переподключить сохранённую") { bt.reconnectRemembered(); dismiss() }
                        Button("Забыть сохранённую", role: .destructive) { bt.forgetRemembered() }
                    } footer: {
                        Text("Сохраняется идентификатор CBPeripheral этого iPhone, не MAC-адрес.")
                    }
                }
            }
            .navigationTitle("Устройства")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } }
            }
            .onAppear { if bt.phase == .idle || bt.phase == .disconnected { bt.startScan() } }
            .onDisappear { if bt.phase == .scanning { bt.stopScan() } }
        }
    }

    private func rssiView(_ rssi: Int) -> some View {
        let bars = rssi > -60 ? 3 : rssi > -75 ? 2 : 1
        return HStack(spacing: 2) {
            ForEach(0..<3) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < bars ? Color.green : Color.secondary.opacity(0.3))
                    .frame(width: 4, height: CGFloat(6 + i * 4))
            }
            Text("\(rssi)").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}
