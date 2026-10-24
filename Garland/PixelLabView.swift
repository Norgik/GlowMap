import SwiftUI

/// Лаборатория пикселей: ручная проверка команд, которые могут дать доступ к отдельным
/// светодиодам. Все команды здесь — из чужих реализаций и на нашей гирлянде не проверены.
/// Никакого автоперебора: каждая кнопка — одно осознанное действие, результат смотрим глазами.
struct PixelLabView: View {
    @Environment(BluetoothManager.self) private var bt
    @Environment(PhoneEffectEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss

    typealias X = GarlandProtocol.Experimental

    // Конфигурация ленты
    @State private var pixelCount = 200
    @State private var order: X.ChannelOrder = .rgb

    // Опыт с одиночным светодиодом
    @State private var ledIndex = 1
    @State private var secondLedIndex = 10
    @State private var testColor: RGB = .red
    @State private var secondColor: RGB = .blue
    /// Пауза между кадрами последовательности. LED LAMP держит ≥100 мс между «списочными» кадрами.
    @State private var gapMs = 150.0

    // DIY-палитра

    // Скорость/направление
    @State private var speed = 50.0

    // Graffiti (LED LAMP 4.3.7, семейство DMX-02/04)
    @State private var graffitiPixel = 0
    @State private var graffitiColor: RGB = .red

    private let palette: [RGB] = [.red, .green, .blue, .white, RGB(red: 255, green: 160, blue: 0), RGB(red: 255, green: 0, blue: 255)]

    var body: some View {
        NavigationStack {
            List {
                introSection
                restoreSection
                graffitiSection
                dmx00ExtrasSection
                configSection
                singleLedSection
                diySection
                speedSection
                notifySection
                logSection
            }
            .navigationTitle("Лаборатория пикселей")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } }
            }
            .onAppear { engine.stop() }
            .disabled(false)
        }
    }

    // MARK: - Секции

    private var introSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label("Ни одна открытая реализация LEDDMX-00 не содержит команды «цвет светодиода №N». Здесь проверяем обходные пути.", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                Text("Статус: \(bt.phase.title)" + (bt.isSequenceRunning ? " · идёт последовательность" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var restoreSection: some View {
        Section {
            Button {
                bt.cancelSequence()
                bt.send(sequence: [
                    (X.stripConfig(pixels: 200, order: .rgb), "конфиг 200 px RGB"),
                    (GarlandProtocol.color(.white), "цвет белый"),
                ], gap: gapMs / 1000)
            } label: {
                Label("Вернуть проверенное: 200 px, RGB, белый", systemImage: "arrow.uturn.backward")
            }
            Button {
                bt.cancelSequence()
                bt.send(raw: GarlandProtocol.color(testColor), label: "цвет всей гирлянды")
            } label: {
                Label("Только проверенная команда цвета", systemImage: "checkmark.seal")
            }
        } header: {
            Text("Откат")
        } footer: {
            Text("Если после опыта гирлянда ведёт себя странно — сначала эта кнопка, затем выключить и включить питание гирлянды.")
        }
        .disabled(!bt.isReady)
    }

    private var configSection: some View {
        Section {
            Stepper("Пикселей: \(pixelCount)", value: $pixelCount, in: 1...600, step: pixelCount >= 20 ? 10 : 1)
            HStack {
                Button("1") { pixelCount = 1 }
                Button("10") { pixelCount = 10 }
                Button("100") { pixelCount = 100 }
                Button("200") { pixelCount = 200 }
                Button("300") { pixelCount = 300 }
            }
            .buttonStyle(.bordered)
            Picker("Порядок каналов", selection: $order) {
                ForEach(X.ChannelOrder.allCases) { Text($0.title).tag($0) }
            }
            Button {
                bt.send(raw: X.stripConfig(pixels: pixelCount, order: order),
                        label: "конфиг \(pixelCount) px \(order.title)")
            } label: {
                Label("Отправить конфигурацию", systemImage: "slider.horizontal.3")
            }
            Text(X.stripConfig(pixels: pixelCount, order: order).hexString)
                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
        } header: {
            Text("1. Конфигурация ленты")
        } footer: {
            Text("Источник: LED LAMP 4.3.5 → ChipSelectActivity (LED_UNION/ffe0.ts). Что смотреть: после «Пикселей: 10» + любой цвет — горят ли только первые 10 LED? Если да, остальные либо гаснут, либо сохраняют прошлый цвет — это ключ к следующему опыту. Предположительно настройка сохраняется в контроллере.")
        }
        .disabled(!bt.isReady)
    }

    private var singleLedSection: some View {
        Section {
            Stepper("LED №\(ledIndex)", value: $ledIndex, in: 1...600)
            colorRow("Цвет", $testColor)
            Button {
                bt.send(sequence: [
                    (X.stripConfig(pixels: 200, order: .rgb), "конфиг 200 px"),
                    (GarlandProtocol.color(.black), "всё чёрное"),
                ], gap: gapMs / 1000)
            } label: { Label("Шаг A: погасить всё (200 px, чёрный)", systemImage: "moon") }

            Button {
                bt.send(sequence: lightOnly(ledIndex, color: testColor), gap: gapMs / 1000)
            } label: { Label("Шаг B: зажечь только LED №\(ledIndex)", systemImage: "1.circle") }

            Stepper("Второй LED №\(secondLedIndex)", value: $secondLedIndex, in: 1...600)
            colorRow("Цвет второго", $secondColor)
            Button {
                bt.send(sequence: lightOnly(secondLedIndex, color: secondColor), gap: gapMs / 1000)
            } label: { Label("Шаг C: добавить LED №\(secondLedIndex) другим цветом", systemImage: "2.circle") }

            HStack {
                Text("Пауза между кадрами")
                Slider(value: $gapMs, in: 30...600, step: 10)
                Text("\(Int(gapMs)) мс").monospacedDigit().frame(width: 60, alignment: .trailing)
            }
            .font(.footnote)
        } header: {
            Text("2. Один светодиод через «защёлку»")
        } footer: {
            Text("Гипотеза: контроллер выводит только первые N пикселей, а WS281x-светодиоды дальше по ленте хранят последнее значение. Шаг B = «N пикселей, цвет» → «N−1 пикселей, чёрный»: если гипотеза верна, останется гореть ровно LED №N. Шаг C делает то же для второго номера, не трогая первый. Критерий успеха: два разных LED горят разными цветами одновременно. Если при N=1 горят 3 или больше LED — это размер группы на одной микросхеме.")
        }
        .disabled(!bt.isReady)
    }

    private var diySection: some View {
        Section {
            Button {
                bt.send(sequence: [
                    (X.stripConfig(pixels: 6, order: .rgb), "конфиг 6 px"),
                    (X.diyColor(position: 1, total: 2, color: .red, fade: false), "DIY цвет 1/2 красный"),
                    (X.diyColor(position: 2, total: 2, color: .blue, fade: false), "DIY цвет 2/2 синий"),
                    (X.diyStart(), "DIY старт (0F)"),
                    (X.speed(percent: 0), "скорость 0"),
                ], gap: max(0.1, gapMs / 1000))
            } label: { Label("Подготовить: 6 px, палитра красный·синий, скорость 0", systemImage: "paintpalette") }

            ForEach(0..<8, id: \.self) { mode in
                Button {
                    bt.send(raw: X.diyMode(mode), label: "DIY режим \(mode) \(X.diyModeNames[mode])")
                } label: {
                    HStack {
                        Text("Режим \(mode)").monospacedDigit()
                        Text(X.diyModeNames[mode]).foregroundStyle(.secondary)
                        Spacer()
                        Text(X.diyMode(mode).hexString)
                            .font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
                    }
                }
            }
            HStack {
                Button("Скорость 0") { bt.send(raw: X.speed(percent: 0), label: "скорость 0") }
                Spacer()
                Button("Скорость 100") { bt.send(raw: X.speed(percent: 100), label: "скорость 100") }
            }
            .buttonStyle(.bordered)
        } header: {
            Text("3. DIY-палитра: два цвета одновременно?")
        } footer: {
            Text("Нажмите «Подготовить», затем режимы по одному. Смотрите только на первые 6 светодиодов и отвечайте на один вопрос: видны ли КРАСНЫЙ и СИНИЙ в один и тот же момент на разных светодиодах? Варианты: «стоят на месте» / «есть, но бегут» / «нет, все 6 всегда одного цвета». Позиция цвета в палитре — не номер светодиода; нас интересует только, раскладывает ли режим палитру по ленте.")
        }
        .disabled(!bt.isReady)
    }

    private var graffitiSection: some View {
        Section {
            Button {
                bt.send(sequence: [
                    (X.stripConfig(pixels: 200, order: .rgb), "конфиг 200 px"),
                    (GarlandProtocol.color(.black), "всё чёрное"),
                    (X.graffiti(mode: .paint, color: .red, pixel: 0), "graffiti пиксель 0 красный"),
                    (X.graffiti(mode: .paint, color: .blue, pixel: 5), "graffiti пиксель 5 синий"),
                    (X.graffiti(mode: .paint, color: .green, pixel: 10), "graffiti пиксель 10 зелёный"),
                ], gap: max(0.1, gapMs / 1000))
            } label: { Label("Главный тест: пиксели 0, 5, 10 тремя цветами", systemImage: "scope") }

            Stepper("Пиксель №\(graffitiPixel) (с нуля)", value: $graffitiPixel, in: 0...599)
            colorRow("Цвет", $graffitiColor)
            ForEach(X.GraffitiMode.allCases) { mode in
                Button {
                    let pixel = mode == .clear ? 200 : graffitiPixel
                    bt.send(raw: X.graffiti(mode: mode, color: graffitiColor, pixel: pixel),
                            label: "graffiti \(mode.title) px \(pixel)")
                } label: {
                    HStack {
                        Text(mode.title)
                        Spacer()
                        Text(X.graffiti(mode: mode, color: graffitiColor, pixel: mode == .clear ? 200 : graffitiPixel).hexString)
                            .font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
                    }
                }
            }
            Button {
                bt.send(raw: X.dmx0204ClearColor(), label: "DMX-02/04 clear (7B 0E)")
            } label: { Label("Очистка в раскладке DMX-02/04  7B0E0000000000FFBF", systemImage: "eraser") }
        } header: {
            Label("0. Graffiti 7C — попиксельный кадр из LED LAMP 4.3.7", systemImage: "star")
        } footer: {
            Text("Источник: NetConnectBle.setDmx0204Graffiti → 7C <режим> R G B idxHi idxLo FF CF. В LED LAMP он есть только для LEDDMX-02/04/06; принимает ли его прошивка LEDDMX-00 — неизвестно. Если после главного теста горят ровно пиксели 1, 6 и 11 (счёт с нуля) тремя цветами на тёмной ленте — попиксельное управление найдено. Если ничего не изменилось — прошивка кадр игнорирует.")
        }
        .disabled(!bt.isReady)
    }

    private var dmx00ExtrasSection: some View {
        Section {
            HStack {
                Text("Подзона 14")
                Spacer()
                ForEach(0..<3, id: \.self) { z in
                    Button(["центр", "лево", "право"][z]) { bt.send(raw: X.subarea(z), label: "подзона \(z)") }
                }
            }
            .buttonStyle(.bordered)
            HStack {
                Text("Канал 11")
                Spacer()
                ForEach(0..<4, id: \.self) { c in
                    Button("\(c)") { bt.send(raw: X.auxiliary(c), label: "канал \(c)") }
                }
            }
            .buttonStyle(.bordered)
            HStack {
                Text("Пауза 06")
                Spacer()
                Button("▶") { bt.setEffectPaused(false) }
                Button("⏸") { bt.setEffectPaused(true) }
            }
            .buttonStyle(.bordered)
        } header: {
            Text("0b. Команды, которые LED LAMP шлёт именно DMX-00")
        } footer: {
            Text("«Подзона» (центр/лево/право) в LED LAMP показывается только для LEDDMX-00/01 — похоже на выбор части ленты. Проверить: после «лево» + красный с главного экрана красной становится вся лента или только часть? «Пауза» подтверждена 24.10.2026 (01 — замереть, 00 — продолжить) и вынесена на главный экран.")
        }
        .disabled(!bt.isReady)
    }

    private var speedSection: some View {
        Section {
            HStack {
                Image(systemName: "tortoise")
                Slider(value: $speed, in: 0...100, step: 5) { editing in
                    if !editing { bt.send(raw: X.speed(percent: Int(speed)), label: "скорость \(Int(speed))%") }
                }
                Image(systemName: "hare")
            }
            HStack {
                Button("Направление: вперёд") { bt.send(raw: X.direction(forward: true), label: "направление 01") }
                Spacer()
                Button("назад") { bt.send(raw: X.direction(forward: false), label: "направление 00") }
            }
            .buttonStyle(.bordered)
        } header: {
            Text("4. Скорость и направление эффекта")
        } footer: {
            Text("Сначала включите любой встроенный эффект на главном экране, затем двигайте ползунок. Если скорость подтвердится — перенесём её в раздел эффектов.")
        }
        .disabled(!bt.isReady)
    }

    private var notifySection: some View {
        Section {
            Button {
                bt.send(raw: X.passwordStatusQuery(), label: "запрос статуса пароля (2A 05)")
            } label: { Label("Запрос 2A 05 — ждём ответ в FFE1", systemImage: "arrow.down.message") }
            HStack {
                Text("Последний RX")
                Spacer()
                Text(bt.lastReceived?.hexString ?? "—").font(.system(.footnote, design: .monospaced)).foregroundStyle(.secondary)
            }
        } header: {
            Text("5. Обратная связь")
        } footer: {
            Text("Единственный кадр, на который LED LAMP ожидает уведомление. Если RX появится — у контроллера есть канал ответов, и можно искать запрос состояния.")
        }
        .disabled(!bt.isReady)
    }

    private var logSection: some View {
        Section("Последние кадры") {
            ForEach(bt.log.suffix(12).reversed()) { entry in
                HStack(alignment: .top, spacing: 8) {
                    Text(entry.direction.rawValue).font(.caption2.bold())
                        .foregroundStyle(entry.direction == .tx ? .blue : entry.direction == .rx ? .green : entry.direction == .error ? .red : .secondary)
                        .frame(width: 32, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.message).font(.caption)
                        if let hex = entry.hex {
                            Text(hex).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Вспомогательное

    /// Последовательность «защёлки»: вывести N пикселей цветом, затем N−1 пикселей чёрным.
    private func lightOnly(_ n: Int, color: RGB) -> [(data: Data, label: String)] {
        var seq: [(data: Data, label: String)] = [
            (X.stripConfig(pixels: n, order: .rgb), "конфиг \(n) px"),
            (GarlandProtocol.color(color), "цвет #\(color.hexString)"),
        ]
        if n > 1 {
            seq.append((X.stripConfig(pixels: n - 1, order: .rgb), "конфиг \(n - 1) px"))
            seq.append((GarlandProtocol.color(.black), "чёрный"))
        }
        return seq
    }

    private func colorRow(_ title: String, _ binding: Binding<RGB>) -> some View {
        HStack {
            Text(title)
            Spacer()
            ForEach(Array(palette.enumerated()), id: \.offset) { _, c in
                Button { binding.wrappedValue = c } label: {
                    Circle().fill(c.swiftUIColor).frame(width: 24, height: 24)
                        .overlay(Circle().stroke(.white, lineWidth: binding.wrappedValue == c ? 2 : 0))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
