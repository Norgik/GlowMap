import SwiftUI

/// Расписание и плейлист — живут в самом WLED (NTP-время, таймеры, пресеты), телефон не нужен.
struct ScheduleView: View {
    @Environment(WLEDClient.self) private var wled
    @Environment(LightSceneStore.self) private var scenes
    @Environment(\.dismiss) private var dismiss

    @State private var onTime = Calendar.current.date(from: DateComponents(hour: 17, minute: 0)) ?? .now
    @State private var offTime = Calendar.current.date(from: DateComponents(hour: 23, minute: 30)) ?? .now
    @State private var onEnabled = true
    @State private var offEnabled = true
    @State private var onScene: UUID?
    @State private var playlistSelection: Set<UUID> = []
    @State private var playlistSeconds = 120.0
    @State private var status: String?
    @State private var deviceTime: String?
    @State private var busy = false

    /// Пресеты WLED, которые занимает приложение: 1…40 — сцены по порядку, 200 — плейлист, 201 — «выключить».
    private let playlistPresetID = 200
    private let offPresetID = 201

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack { Text("Время контроллера"); Spacer(); Text(deviceTime ?? "—").foregroundStyle(.secondary).font(.caption) }
                    if let t = deviceTime, t.hasPrefix("1970") {
                        Button("Включить синхронизацию времени (NTP)") { Task { _ = await wled.enableNTP(); await refresh() } }
                    }
                } footer: { Text("Таймеры работают по часам контроллера; он берёт время из интернета (NTP).") }

                Section("Включать вечером") {
                    Toggle("Включено", isOn: $onEnabled)
                    DatePicker("Время", selection: $onTime, displayedComponents: .hourAndMinute)
                    Picker("Сцена", selection: $onScene) {
                        Text("Последнее состояние").tag(UUID?.none)
                        ForEach(scenes.scenes.filter { $0.constructor == nil }) { s in Text(s.name).tag(UUID?.some(s.id)) }
                    }
                }
                Section("Выключать ночью") {
                    Toggle("Включено", isOn: $offEnabled)
                    DatePicker("Время", selection: $offTime, displayedComponents: .hourAndMinute)
                }
                Section {
                    Button {
                        Task { await saveTimers() }
                    } label: { HStack { Label("Записать расписание в WLED", systemImage: "clock.badge.checkmark"); Spacer(); if busy { ProgressView() } } }
                    .disabled(!wled.isReady || busy)
                } footer: { Text("Сцены конструктора в расписании не участвуют — их считает телефон.") }

                Section {
                    ForEach(scenes.scenes.filter { $0.constructor == nil }) { s in
                        Button {
                            if playlistSelection.contains(s.id) { playlistSelection.remove(s.id) } else { playlistSelection.insert(s.id) }
                        } label: {
                            HStack {
                                Image(systemName: playlistSelection.contains(s.id) ? "checkmark.circle.fill" : "circle")
                                Text(s.name)
                                Spacer()
                            }
                        }
                        .tint(.primary)
                    }
                    HStack {
                        Text("По \(Int(playlistSeconds)) с каждая")
                        Slider(value: $playlistSeconds, in: 10...900, step: 10)
                    }
                    HStack {
                        Button("Запустить сейчас") { Task { await runPlaylist(save: false) } }
                        Spacer()
                        Button("Сохранить как плейлист") { Task { await runPlaylist(save: true) } }
                    }
                    .disabled(playlistSelection.isEmpty || !wled.isReady || busy)
                } header: { Text("Плейлист") } footer: {
                    Text("Выбранные сцены будут сменять друг друга по кругу. Сохранённый плейлист доступен в WLED как пресет №\(playlistPresetID) и может быть сценой для вечернего включения.")
                }

                if let status { Section { Text(status).font(.caption) } }
            }
            .navigationTitle("Расписание")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
            .task { await refresh() }
        }
    }

    private func refresh() async {
        deviceTime = await wled.readTime()
        let timers = await wled.readTimers()
        if timers.count >= 2 {
            onEnabled = timers[0].enabled; offEnabled = timers[1].enabled
            onTime = Calendar.current.date(from: DateComponents(hour: timers[0].hour, minute: timers[0].minute)) ?? onTime
            offTime = Calendar.current.date(from: DateComponents(hour: timers[1].hour, minute: timers[1].minute)) ?? offTime
        }
    }

    /// Пресеты сцен в WLED: сцена с индексом k в списке → пресет k+1.
    private func presetID(for scene: LightScene) -> Int? {
        guard let k = scenes.scenes.filter({ $0.constructor == nil }).firstIndex(where: { $0.id == scene.id }) else { return nil }
        return k + 1
    }

    /// Применить сцену к WLED и сохранить как пресет.
    private func storePreset(_ s: LightScene) async -> Int? {
        guard let id = presetID(for: s) else { return nil }
        if let c = s.color { await wled.setSolid(c, brightness: s.brightness) }
        else if let e = s.effect { await wled.setEffect(e, speed: s.speed, intensity: s.intensity, palette: s.palette, brightness: s.brightness) }
        _ = await wled.savePreset(id: id, name: s.name)
        return id
    }

    private func saveTimers() async {
        busy = true; defer { busy = false }
        _ = await wled.enableNTP()
        // пресет «выключить»
        await wled.setPower(false)
        _ = await wled.savePreset(id: offPresetID, name: "Выключить")
        await wled.setPower(true)
        var onPreset = 0
        if let sid = onScene, let s = scenes.scenes.first(where: { $0.id == sid }), let id = await storePreset(s) { onPreset = id }
        let onC = Calendar.current.dateComponents([.hour, .minute], from: onTime)
        let offC = Calendar.current.dateComponents([.hour, .minute], from: offTime)
        let ok = await wled.writeTimers([
            .init(enabled: onEnabled, hour: onC.hour ?? 17, minute: onC.minute ?? 0, presetID: onPreset),
            .init(enabled: offEnabled, hour: offC.hour ?? 23, minute: offC.minute ?? 30, presetID: offPresetID),
        ])
        status = ok ? "Расписание записано в WLED" : (wled.lastError ?? "Не удалось записать")
        await refresh()
    }

    private func runPlaylist(save: Bool) async {
        busy = true; defer { busy = false }
        var ids: [Int] = []
        for s in scenes.scenes where playlistSelection.contains(s.id) {
            if let id = await storePreset(s) { ids.append(id) }
        }
        guard !ids.isEmpty else { status = "Нет сцен"; return }
        let secs = Array(repeating: Int(playlistSeconds), count: ids.count)
        let ok: Bool
        if save {
            ok = await wled.savePlaylist(id: playlistPresetID, name: "Плейлист", presetIDs: ids, seconds: secs)
            if ok { _ = await wled.applyPreset(id: playlistPresetID) }
        } else {
            ok = await wled.startPlaylist(presetIDs: ids, seconds: secs)
        }
        status = ok ? "Плейлист \(save ? "сохранён и " : "")запущен: \(ids.count) сцен" : (wled.lastError ?? "Ошибка")
    }
}
