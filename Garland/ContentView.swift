import SwiftUI

struct ContentView: View {
    @Environment(BluetoothManager.self) private var bt
    @Environment(PhoneEffectEngine.self) private var engine
    @Environment(SavedColorsStore.self) private var store
    @Environment(WLEDClient.self) private var wled

    /// Гирлянда на ESP32/WLED в сети — управляем по Wi‑Fi; иначе по Bluetooth родной платой.
    private var viaWLED: Bool { wled.isReady }
    private var isReady: Bool { viaWLED || bt.isReady }
    @State private var wledOn = true

    @State private var hue: Double = 0.08
    @State private var saturation: Double = 0.85
    @State private var brightness: Double = 100
    @State private var showDevices = false
    @State private var showDiagnostics = false
    @State private var showPixelLab = false
    @State private var showWLED = false
    @State private var showSaveSheet = false
    @State private var newSceneName = ""

    private var currentColor: RGB { RGB(hue: hue, saturation: saturation) }
    private var isOn: Bool { viaWLED ? wledOn : bt.requested.isOn }
    /// Встроенный эффект контроллера.
    private var isControllerEffect: Bool { bt.requested.mode.effectIndex != nil }
    /// Цвет для подсветки интерфейса: живой цвет эффекта телефона, иначе — выбранный на колесе.
    private var previewColor: Color {
        (engine.currentColor ?? currentColor.scaled(by: max(0.08, brightness / 100))).swiftUIColor
    }

    var body: some View {
        NavigationStack {
            ZStack {
                background
                ScrollView {
                    VStack(spacing: 20) {
                        deviceCard
                        strandPreview
                        HueSaturationWheel(hue: $hue, saturation: $saturation,
                                           onChanged: { pushColor(immediate: false) },
                                           onEnded: { pushColor(immediate: true) })
                            .frame(maxWidth: 300)
                            .padding(.horizontal, 24)
                            .opacity(isControllerEffect || engine.running == .rainbow ? 0.55 : 1)
                        brightnessSlider
                        quickColors
                        liveEffectsSection
                        if viaWLED {
                            wledEffectsHint
                        } else {
                            EffectsSection()
                        }
                        scenesSection
                        sentStatus
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("Гирлянда")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showWLED = true } label: {
                        Image(systemName: "wifi")
                    }
                    .accessibilityLabel("WLED по Wi‑Fi")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showPixelLab = true } label: {
                        Image(systemName: "flask")
                    }
                    .accessibilityLabel("Лаборатория пикселей")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showDiagnostics = true } label: {
                        Image(systemName: "waveform.path.ecg")
                    }
                    .accessibilityLabel("Диагностика")
                }
            }
            .sheet(isPresented: $showDevices) { DevicePickerView() }
            .sheet(isPresented: $showDiagnostics) { DiagnosticsView() }
            .sheet(isPresented: $showPixelLab) { PixelLabView() }
            .sheet(isPresented: $showWLED) { WLEDView() }
            .alert("Сохранить сцену", isPresented: $showSaveSheet) {
                TextField("Название", text: $newSceneName)
                Button("Сохранить") { saveScene() }
                Button("Отмена", role: .cancel) { newSceneName = "" }
            } message: {
                Text(currentDescription)
            }
        }
        .onAppear {
            let hsv = bt.requested.color.hsv
            hue = hsv.hue; saturation = hsv.saturation
            brightness = Double(bt.requested.brightness)
            if wled.phase == .idle { wled.start() }
        }
    }

    // MARK: - Блоки

    private var background: some View {
        ZStack {
            Color(red: 0.05, green: 0.05, blue: 0.08).ignoresSafeArea()
            RadialGradient(colors: [previewColor.opacity(isReady && isOn ? 0.45 : 0.12), .clear],
                           center: .top, startRadius: 0, endRadius: 500)
                .ignoresSafeArea()
                .animation(.easeOut(duration: 0.3), value: previewColor)
        }
    }

    private var deviceCard: some View {
        HStack(spacing: 12) {
            Button { if viaWLED { showWLED = true } else { showDevices = true } } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(.white.opacity(0.08)).frame(width: 44, height: 44)
                        Image(systemName: isReady ? "lightbulb.led.fill" : "lightbulb.led")
                            .font(.title3)
                            .foregroundStyle(isReady && isOn ? previewColor : .secondary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(viaWLED ? (wled.info?.name == "WLED" ? "Гирлянда · WLED" : (wled.info?.name ?? "WLED"))
                                     : (bt.connectedName ?? "Гирлянда не выбрана"))
                            .font(.headline)
                        HStack(spacing: 6) {
                            Circle().fill(viaWLED ? .green : statusColor).frame(width: 8, height: 8)
                            Text(viaWLED ? "Wi‑Fi · \(wled.info?.ip ?? "") · \(wled.ledCount) LED" : bt.phase.title)
                                .font(.subheadline).foregroundStyle(.secondary)
                            if !viaWLED, bt.phase.isBusy { ProgressView().controlSize(.mini) }
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)

            Button {
                if isOn { engine.stop() }
                if viaWLED {
                    wledOn.toggle()
                    Task { await wled.setPower(wledOn) }
                } else {
                    bt.setPower(!isOn)
                }
            } label: {
                Image(systemName: "power")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(isOn ? Color.white : .secondary)
                    .frame(width: 48, height: 48)
                    .background(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.white.opacity(0.1)), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!isReady)
            .accessibilityLabel(isOn ? "Выключить" : "Включить")
        }
        .padding(14)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var statusColor: Color {
        switch bt.phase {
        case .ready: .green
        case .scanning, .connecting, .discovering: .yellow
        case .error, .bluetoothOff, .unauthorized, .unsupported: .red
        default: .gray
        }
    }

    /// Имитация отрезка гирлянды: показывает запрошенный режим, а не состояние устройства.
    /// Для эффекта контроллера — условная «бегущая» анимация телефона, не копия реального эффекта;
    /// для эффекта телефона — тот самый цвет, который сейчас уходит в гирлянду.
    private var strandPreview: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !isControllerEffect || !isOn)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 10) {
                ForEach(0..<12, id: \.self) { i in
                    let phase = isControllerEffect ? (sin((t * 3) - Double(i) * 0.7) + 1) / 2 : 1
                    let c = isControllerEffect
                        ? Color(hue: (t * 0.08 + Double(i) / 12).truncatingRemainder(dividingBy: 1),
                                saturation: 0.9, brightness: 0.4 + 0.6 * phase)
                        : previewColor
                    Circle()
                        .fill(isOn ? c : Color.white.opacity(0.08))
                        .frame(width: 14, height: 14)
                        .shadow(color: isOn ? c.opacity(0.9) : .clear, radius: isReady ? 8 : 2)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 12)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .opacity(isReady ? 1 : 0.5)
        .overlay(alignment: .topTrailing) {
            if let label = modeLabel {
                Text(label)
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.white.opacity(0.08), in: Capsule())
                    .padding(8)
            }
        }
    }

    private var modeLabel: String? {
        if let e = engine.running { return "\(e.title) · телефон" }
        if let e = bt.requested.mode.effectIndex { return store.effectName(e) }
        return nil
    }

    private var brightnessSlider: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Яркость", systemImage: "sun.max")
                Spacer()
                Text("\(Int(brightness))%").monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.subheadline)
            Slider(value: $brightness, in: 0...100, step: 1) { editing in
                if !editing {
                    if viaWLED { Task { await wled.setBrightness(Int(brightness * 2.55)) } }
                    else { bt.requestBrightness(Int(brightness), immediate: true) }
                }
            }
            .onChange(of: brightness) { _, new in if !viaWLED { bt.requestBrightness(Int(new), immediate: false) } }
            .tint(isControllerEffect ? .white : previewColor)
        }
        .padding(14)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var quickColors: some View {
        HStack(spacing: 12) {
            quickButton("Красный", .red)
            quickButton("Зелёный", .green)
            quickButton("Синий", .blue)
            quickButton("Белый", .white)
            quickButton("Тёплый", RGB(red: 255, green: 160, blue: 60))
        }
    }

    private func quickButton(_ title: String, _ rgb: RGB) -> some View {
        Button {
            setWheel(to: rgb)
            pushColor(immediate: true)
        } label: {
            Circle()
                .fill(rgb.swiftUIColor)
                .frame(width: 44, height: 44)
                .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
                .shadow(color: rgb.swiftUIColor.opacity(0.5), radius: 6)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    /// Эффекты, которые считает телефон. Честно: работают только пока приложение открыто.
    private var liveEffectsSection: some View {
        @Bindable var engine = engine
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Живые эффекты").font(.headline)
                Spacer()
                if engine.running != nil {
                    Button("Стоп") { engine.stop(); pushColor(immediate: true) }
                        .font(.subheadline)
                }
            }
            HStack(spacing: 10) {
                ForEach(PhoneEffect.allCases) { effect in
                    let active = engine.running == effect
                    Button {
                        if active {
                            engine.stop()
                            pushColor(immediate: true)
                        } else {
                            engine.start(effect, base: effect == .candle ? effect.defaultBase : currentColor)
                            if effect == .candle { setWheel(to: effect.defaultBase) }
                        }
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: effect.systemImage)
                                .font(.title3)
                                .symbolEffect(.pulse, isActive: active)
                            Text(effect.title).font(.subheadline.weight(.medium))
                            Text(effect.subtitle)
                                .font(.caption2).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, minHeight: 96)
                        .padding(8)
                        .background(active ? AnyShapeStyle(.tint.opacity(0.35)) : AnyShapeStyle(.white.opacity(0.06)),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(active ? Color.accentColor : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .disabled(!isReady)
                }
            }
            if engine.running != nil {
                HStack {
                    Image(systemName: "tortoise")
                    Slider(value: $engine.speed, in: 0.25...3)
                    Image(systemName: "hare")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            }
            Text(engine.running == nil
                 ? "Считаются телефоном и работают, пока приложение открыто. Для автономной работы используйте эффекты контроллера ниже."
                 : "Экран не погаснет, пока эффект работает. Сворачивание приложения остановит его.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var wledEffectsHint: some View {
        Button { showWLED = true } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Эффекты WLED").font(.headline)
                    Text("Карта камерой, 2D-эффекты без телефона, загрузка карты в контроллер")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var scenesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Сцены").font(.headline)
                Spacer()
                Button { showSaveSheet = true } label: {
                    Label("Сохранить текущую", systemImage: "plus")
                        .font(.subheadline)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(store.scenes) { scene in
                    Button { applyScene(scene) } label: {
                        HStack(spacing: 10) {
                            sceneSwatch(scene)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(scene.name).font(.subheadline).lineLimit(1)
                                Text(sceneSubtitle(scene))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) { store.remove(scene) } label: {
                            Label("Удалить", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    private func sceneSwatch(_ scene: SavedScene) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return Group {
            if scene.effect != nil {
                shape.fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                    .overlay(Image(systemName: "sparkles").font(.caption).foregroundStyle(.white))
            } else if let p = scene.phoneEffect {
                shape.fill(p == .rainbow
                           ? AnyShapeStyle(LinearGradient(colors: [.red, .yellow, .green, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                           : AnyShapeStyle(scene.color.scaled(by: max(0.15, Double(scene.brightness) / 100)).swiftUIColor))
                    .overlay(Image(systemName: p.systemImage).font(.caption).foregroundStyle(.white))
            } else {
                shape.fill(scene.color.scaled(by: max(0.15, Double(scene.brightness) / 100)).swiftUIColor)
            }
        }
        .frame(width: 32, height: 32)
    }

    private func sceneSubtitle(_ scene: SavedScene) -> String {
        if let e = scene.effect { return "эффект №\(e) · \(scene.brightness)%" }
        if let p = scene.phoneEffect { return "\(p.title.lowercased()) · \(scene.brightness)%" }
        return "\(scene.brightness)%"
    }

    private var sentStatus: some View {
        Group {
            if let sent = bt.requested.lastSentAt {
                Text("Отправлено \(sent.formatted(date: .omitted, time: .standard)) · применение не подтверждается контроллером")
            } else {
                Text("Команды ещё не отправлялись")
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Действия

    private var currentDescription: String {
        if let p = engine.running { return "\(p.title), яркость \(Int(brightness))%" }
        if let e = bt.requested.mode.effectIndex { return "\(store.effectName(e)), яркость \(Int(brightness))%" }
        return "Цвет #\(currentColor.hexString), яркость \(Int(brightness))%"
    }

    private func saveScene() {
        let name = newSceneName.trimmingCharacters(in: .whitespaces)
        let effect = engine.running == nil ? bt.requested.mode.effectIndex : nil
        let fallback = engine.running?.title ?? effect.map { store.effectName($0) } ?? "#\(currentColor.hexString)"
        store.add(name: name.isEmpty ? fallback : name,
                  color: engine.running != nil ? engine.baseColor : currentColor,
                  brightness: Int(brightness),
                  effect: effect,
                  phoneEffect: engine.running,
                  speed: engine.running != nil ? engine.speed : nil)
        newSceneName = ""
    }

    private func setWheel(to color: RGB) {
        let hsv = color.hsv
        hue = hsv.hue
        saturation = hsv.saturation
    }

    private func applyScene(_ scene: SavedScene) {
        engine.stop()
        setWheel(to: scene.color)
        brightness = Double(scene.brightness)
        if let p = scene.phoneEffect {
            if viaWLED { Task { await wled.setBrightness(Int(Double(scene.brightness) * 2.55)) } }
            else { bt.requestBrightness(scene.brightness, immediate: true) }
            engine.start(p, base: scene.color, speed: scene.speed)
        } else if viaWLED {
            if scene.effect != nil { showWLED = true; return }   // эффекты родной платы для WLED не существуют
            Task { await wled.setSolid(scene.color, brightness: Int(Double(scene.brightness) * 2.55)) }
            wledOn = true
        } else {
            bt.apply(scene)
        }
    }

    /// Цвет с колеса: при «дыхании» и «свече» он становится базовым цветом эффекта,
    /// в остальных случаях останавливает эффект телефона и уходит в гирлянду напрямую.
    /// Через WLED: во время движения — поток DDP, при отпускании — сохраняемый цвет по JSON.
    private func pushColor(immediate: Bool) {
        if let running = engine.running, running.usesBaseColor {
            engine.baseColor = currentColor
            return
        }
        engine.stop()
        if viaWLED {
            wledOn = true
            if immediate {
                Task { await wled.setSolid(currentColor) }
            } else {
                wled.sendFrame(LEDFrame(count: wled.ledCount, fill: currentColor))
            }
        } else {
            bt.requestColor(currentColor, immediate: immediate)
        }
    }
}

#Preview {
    let bt = BluetoothManager()
    return ContentView()
        .environment(bt)
        .environment(PhoneEffectEngine(bluetooth: bt))
        .environment(SavedColorsStore())
        .environment(WLEDClient())
        .environment(LEDMapStore())
        .preferredColorScheme(.dark)
}
