import SwiftUI

/// Второй транспорт: ESP32 с WLED по Wi‑Fi. Отсюда — сканирование камерой и карта.
struct WLEDView: View {
    @Environment(WLEDClient.self) private var wled
    @Environment(LEDMapStore.self) private var mapStore
    @Environment(\.dismiss) private var dismiss

    @State private var hostField = ""
    @State private var showScan = false
    @State private var showMap = false
    @State private var uploading = false
    @State private var customCount = 150
    @State private var changingCount = false

    private func changeCount(_ n: Int) async {
        changingCount = true
        _ = await wled.setLEDCount(n)
        changingCount = false
    }
    @State private var uploadOK: Bool?
    @State private var activeFx: Int?
    @State private var fxSpeed: Double = 128
    @State private var fxIntensity: Double = 128
    @State private var fxBrightness: Double = 140
    @State private var fxPalette = 11
    @AppStorage("map.fillUnmapped") private var fillUnmapped = false

    private func resend() {
        guard let fx = activeFx else { return }
        Task { await wled.setEffect(fx, speed: Int(fxSpeed), intensity: Int(fxIntensity), palette: fxPalette, brightness: Int(fxBrightness)) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Circle().fill(wled.isReady ? .green : .gray).frame(width: 8, height: 8)
                        Text(wled.phase.title)
                        Spacer()
                        if wled.phase == .searching || wled.phase == .connecting { ProgressView() }
                    }
                    if let i = wled.info {
                        row("Устройство", "\(i.name) · WLED \(i.version)")
                        row("Адрес", i.ip)
                        row("Светодиодов в WLED", "\(i.ledCount)")
                        row("Кадров отправлено", "\(wled.framesSent)")
                        HStack {
                            Text("Адресация")
                            Spacer()
                            Text(wled.addressingMode.title).foregroundStyle(.secondary)
                            if wled.switchingMode { ProgressView().controlSize(.mini) }
                        }
                        if case .map2D = wled.addressingMode {
                            Button("Снять карту (прямой режим, ~15 с)") { Task { _ = await wled.setDirectMode() } }
                                .disabled(wled.switchingMode)
                        }
                    }
                    if let e = wled.lastError {
                        Text(e).font(.caption).foregroundStyle(.red)
                        Button("Переоткрыть канал кадров (DDP)") { wled.reopenDDP() }
                    }
                } header: { Text("Соединение") }

                Section {
                    HStack {
                        Text("Сейчас: \(wled.ledCount) LED")
                        Spacer()
                        Button("100") { Task { await changeCount(100) } }
                        Button("200") { Task { await changeCount(200) } }
                    }
                    .buttonStyle(.bordered)
                    HStack {
                        Stepper("Другое: \(customCount)", value: $customCount, in: 10...1000, step: 10)
                        Button("Применить") { Task { await changeCount(customCount) } }.buttonStyle(.bordered)
                    }
                    if let m = mapStore.map, m.ledCount != wled.ledCount {
                        Label("Карта снята для \(m.ledCount) LED, а лента сейчас \(wled.ledCount) — пересканируйте.", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if changingCount { ProgressView("Перенастраиваю ленту (~20 с)…") }
                } header: { Text("Длина ленты") } footer: {
                    Text("Для другой гирлянды: число светодиодов записывается в WLED, карта 2D снимается, контроллер переходит в прямой режим. Карту для новой гирлянды нужно снять заново.")
                }
                .disabled(!wled.isReady || changingCount)

                Section {
                    ForEach(wled.discovered.sorted(by: { $0.key < $1.key }), id: \.key) { name, host in
                        Button { wled.connect(host: host) } label: {
                            HStack { Text(name); Spacer(); Text(host).foregroundStyle(.secondary).font(.caption) }
                        }
                    }
                    HStack {
                        TextField("IP или имя, напр. 192.168.1.50 или wled.local", text: $hostField)
                            .keyboardType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                        Button("Подключить") { wled.connect(host: hostField) }
                            .buttonStyle(.borderedProminent)
                            .disabled(hostField.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    HStack {
                        Button("Искать в сети") { wled.startBrowsing() }
                        Spacer()
                        Button("Забыть", role: .destructive) { wled.forget() }.disabled(wled.host == nil)
                    }
                } header: { Text("Устройства") } footer: {
                    Text("Поиск идёт по Bonjour (_wled._tcp). iOS спросит разрешение на локальную сеть — без него ни поиск, ни DDP не работают.")
                }

                Section {
                    HStack(spacing: 12) {
                        ForEach([RGB.red, .green, .blue, .white, .black], id: \.self) { c in
                            Button {
                                Task { await wled.setSolid(c, brightness: 128) }
                            } label: {
                                Circle().fill(c == .black ? Color.gray.opacity(0.3) : c.swiftUIColor)
                                    .frame(width: 36, height: 36)
                                    .overlay(Circle().stroke(.white.opacity(0.3)))
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                        Button("Тест 1·6·11") {
                            Task {
                                await wled.setSolid(.black)
                                await wled.setPixels([0: .red, 5: .blue, 10: .green])
                                // пиксели замораживают сегмент; через 5 с вернём WLED обычное состояние
                                try? await Task.sleep(for: .seconds(5))
                                await wled.unfreeze()
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                } header: { Text("Быстрая проверка") } footer: {
                    if case .map2D = wled.addressingMode {
                        Text("Сейчас активна карта 2D: номера пикселей идут через сетку, поэтому «Тест 1·6·11» зажжёт другие светодиоды, а не попавшие в карту останутся тёмными. Для проверки по номерам снимите карту.")
                    } else {
                        Text("Сплошной цвет и три отдельных пикселя через JSON API — то, что уже подтверждено на гирлянде.")
                    }
                }
                .disabled(!wled.isReady)

                Section {
                    Button {
                        showScan = true
                    } label: {
                        Label("Сканировать камерой", systemImage: "camera.viewfinder")
                    }
                    .disabled(!wled.isReady)

                    if let m = mapStore.map {
                        Button { showMap = true } label: {
                            Label("Карта и эффекты по форме (с телефона)", systemImage: "map")
                        }
                        .disabled(!wled.isReady)
                        row("Найдено", "\(m.foundCount) из \(m.ledCount)" +
                            (m.estimatedCount > 0 ? " · достроено \(m.estimatedCount)" : "") +
                            (m.ambiguousCount > 0 ? " · сомнительных \(m.ambiguousCount)" : ""))
                        row("Снята", m.createdAt.formatted(date: .abbreviated, time: .shortened))
                        Button("Удалить карту", role: .destructive) { mapStore.clear() }
                    } else {
                        Text("Карты пока нет — сначала сканирование.").foregroundStyle(.secondary)
                    }
                } header: { Text("Карта светодиодов") }

                if let m0 = mapStore.map {
                    let m = fillUnmapped ? m0.fillingUnmapped() : m0
                    Section {
                        let grid = LedmapExport.grid(from: m)
                        Toggle("Дорисовать ненайденные по соседям", isOn: $fillUnmapped)
                        if fillUnmapped {
                            Text("Приблизительно: \(m.estimatedCount) LED поставлены между найденными соседями по проводу. Подходит для кучно висящей гирлянды — тёмных дыр не будет, но точность у этих точек условная.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button {
                            uploading = true
                            Task { uploadOK = await wled.uploadLedmap(grid); uploading = false }
                        } label: {
                            HStack {
                                Label("Загрузить карту в WLED", systemImage: "square.and.arrow.up.on.square")
                                Spacer()
                                if uploading { ProgressView() }
                            }
                        }
                        .disabled(!wled.isReady || uploading)
                        row("Сетка", "\(grid.width)×\(grid.height) · в ячейках \(grid.placed)" + (grid.collisions > 0 ? " · не поместилось \(grid.collisions)" : ""))
                        if let mx = wled.matrix { row("В WLED сейчас", "матрица \(mx.w)×\(mx.h)") }
                        if let ok = uploadOK { Text(ok ? "Карта записана во флеш WLED" : (wled.lastError ?? "Ошибка")).font(.caption).foregroundStyle(ok ? .green : .red) }
                    } header: { Text("Эффекты без телефона") } footer: {
                        Text("Карта записывается во флеш WLED один раз и переживает перезагрузки. После загрузки встроенные 2D-эффекты WLED идут по форме гирлянды сами — приложение можно закрыть. Перевесили гирлянду — новый скан и снова эта кнопка.")
                    }

                    Section {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                            ForEach(WLEDClient.curated2DEffects, id: \.id) { fx in
                                Button {
                                    activeFx = fx.id
                                    Task { await wled.setEffect(fx.id, speed: Int(fxSpeed), intensity: Int(fxIntensity), palette: fxPalette, brightness: Int(fxBrightness)) }
                                } label: {
                                    Text(fx.title).font(.subheadline)
                                        .frame(maxWidth: .infinity, minHeight: 40)
                                        .background(activeFx == fx.id ? AnyShapeStyle(.tint.opacity(0.35)) : AnyShapeStyle(.white.opacity(0.08)),
                                                    in: RoundedRectangle(cornerRadius: 10))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        HStack { Text("Скорость").font(.footnote).frame(width: 90, alignment: .leading); Slider(value: $fxSpeed, in: 0...255) { if !$0 { resend() } } }
                        HStack { Text("Детали").font(.footnote).frame(width: 90, alignment: .leading); Slider(value: $fxIntensity, in: 0...255) { if !$0 { resend() } } }
                        HStack { Text("Яркость").font(.footnote).frame(width: 90, alignment: .leading); Slider(value: $fxBrightness, in: 10...255) { if !$0 { resend() } } }
                        Picker("Палитра", selection: $fxPalette) {
                            Text("Своя").tag(0); Text("Радуга").tag(11); Text("Огонь").tag(35); Text("Океан").tag(9)
                            Text("Лес").tag(10); Text("Лава").tag(8); Text("Закат").tag(12); Text("Сияние").tag(50)
                        }
                        .onChange(of: fxPalette) { _, _ in resend() }
                        Button("Выключить гирлянду") { Task { await wled.setPower(false) } }
                    } header: { Text("2D-эффекты WLED") } footer: {
                        Text("Работают в самом контроллере, пока он включён в розетку. Полный список — в веб-интерфейсе WLED.")
                    }
                    .disabled(!wled.isReady || wled.matrix == nil)
                }
            }
            .navigationTitle("WLED по Wi‑Fi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
            .onAppear {
                if wled.phase == .idle { wled.start() }
                hostField = wled.host ?? WLEDClient.suggestedHost
                Task { await wled.refreshMatrix() }
            }
            .onChange(of: wled.isReady) { _, ready in if ready { Task { await wled.refreshMatrix() } } }
            .fullScreenCover(isPresented: $showScan) { ScanView() }
            .fullScreenCover(isPresented: $showMap) { MapView() }
        }
    }

    private func row(_ t: String, _ v: String) -> some View {
        HStack { Text(t); Spacer(); Text(v).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
    }
}
