import SwiftUI

/// Главный экран финального продукта: гирлянда на ESP32/WLED.
/// Питание и яркость, живое превью по карте, готовые эффекты с зашитыми настройками, сцены.
struct HomeView: View {
    @Environment(WLEDClient.self) private var wled
    @Environment(LEDMapStore.self) private var mapStore
    @Environment(LightSceneStore.self) private var scenes
    @Environment(ConstructorEngine.self) private var constructor
    @State private var live = WLEDLiveView()
    @State private var showConstructor = false

    @State private var isOn = true
    @State private var brightness: Double = 140
    @State private var activeEffect: Int?
    @State private var activeColor: RGB?
    @State private var speed: Double = 128
    @State private var showColor = false
    @State private var showMore = false
    @State private var showConnection = false
    @State private var showSave = false
    @State private var sceneName = ""
    @State private var hue = 0.08
    @State private var saturation = 0.85

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.05, green: 0.05, blue: 0.08).ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 18) {
                        statusCard
                        if constructor.running {
                            HStack {
                                Image(systemName: "slider.horizontal.3")
                                Text("Конструктор: \(constructor.title ?? constructor.spec.base.title)").font(.subheadline)
                                Spacer()
                                Button("Стоп") { constructor.stop() }.buttonStyle(.bordered).controlSize(.small)
                            }
                            .padding(12)
                            .background(.tint.opacity(0.2), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        preview
                        brightnessCard
                        colorsRow
                        effectsGrid
                        scenesSection
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Гирлянда")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showConnection = true } label: { Image(systemName: wled.isReady ? "wifi" : "wifi.slash") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showConstructor = true } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("Конструктор")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showMore = true } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .sheet(isPresented: $showConnection) { WLEDView() }
            .sheet(isPresented: $showMore) { MoreView() }
            .sheet(isPresented: $showConstructor) { ConstructorView() }
            .sheet(isPresented: $showColor) { colorSheet }
            .alert("Сохранить сцену", isPresented: $showSave) {
                TextField("Название", text: $sceneName)
                Button("Сохранить") { saveScene() }
                Button("Отмена", role: .cancel) {}
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { if wled.phase == .idle { wled.start() } }
        .onChange(of: wled.isReady) { _, ready in
            if ready, let h = wled.host { live.start(host: h); Task { await wled.refreshMatrix() } }
            else { live.stop() }
        }
        .onDisappear { live.stop() }
        .task { if wled.isReady, let h = wled.host { live.start(host: h) } }
    }

    // MARK: - Блоки

    private var statusCard: some View {
        HStack(spacing: 12) {
            Button { showConnection = true } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(wled.isReady ? "Гирлянда онлайн" : wled.phase.title).font(.headline)
                    Text(wled.isReady
                         ? "\(wled.ledCount) светодиодов · \(wled.addressingMode.title)" + (mapStore.map == nil ? " · карты нет" : (mapStore.map?.cylindrical == true ? " · карта: ёлка" : " · карта: плоская"))
                         : "нажмите, чтобы подключить")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            Spacer()
            Button {
                isOn.toggle()
                Task { await wled.setPower(isOn) }
            } label: {
                Image(systemName: "power").font(.title3.weight(.semibold))
                    .foregroundStyle(isOn ? .white : .secondary)
                    .frame(width: 48, height: 48)
                    .background(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.white.opacity(0.1)), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!wled.isReady)
        }
        .padding(14)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// Живое превью: точки карты раскрашены тем, что сейчас горит на гирлянде.
    private var preview: some View {
        Group {
            if let map = mapStore.map {
                LiveMapCanvas(map: map, colors: liveLEDColors, highlight: nil)
                    .aspectRatio(map.cameraAspect, contentMode: .fit)
                    .frame(maxHeight: 260)
            } else {
                // Без карты — просто лента слева направо
                HStack(spacing: 2) {
                    ForEach(0..<min(60, max(1, liveLEDColors.count)), id: \.self) { i in
                        let idx = i * max(1, liveLEDColors.count / 60)
                        Rectangle().fill(liveLEDColors.indices.contains(idx) ? liveLEDColors[idx].swiftUIColor : .gray.opacity(0.2))
                    }
                }
                .frame(height: 24)
                .clipShape(Capsule())
            }
        }
        .padding(10)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if !live.connected && wled.isReady {
                Text("превью…").font(.caption2).foregroundStyle(.tertiary).padding(8)
            }
        }
    }

    /// Цвета по номерам LED: в 2D-режиме WLED отдаёт ячейки — переводим через сетку.
    private var liveLEDColors: [RGB] {
        let c = live.colors
        guard !c.isEmpty else { return [] }
        let n = wled.ledCount
        var out = Array(repeating: RGB.black, count: n)
        if live.is2D {
            for led in 0..<n {
                if let cell = wled.cellIndex(forLED: led), c.indices.contains(cell) { out[led] = c[cell] }
            }
        } else {
            for led in 0..<min(n, c.count) { out[led] = c[led] }
        }
        return out
    }

    private var brightnessCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "sun.min")
            Slider(value: $brightness, in: 5...255) { editing in
                if !editing { Task { await wled.setBrightness(Int(brightness)) } }
            }
            Image(systemName: "sun.max.fill")
            Text("\(Int(brightness * 100 / 255))%").monospacedDigit().font(.subheadline).frame(width: 44, alignment: .trailing)
        }
        .padding(14)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .disabled(!wled.isReady)
    }

    private var colorsRow: some View {
        HStack(spacing: 10) {
            ForEach([RGB(red: 255, green: 140, blue: 40), .red, RGB(red: 255, green: 60, blue: 120), .green,
                     RGB(red: 0, green: 150, blue: 255), RGB(red: 170, green: 60, blue: 255), .white], id: \.self) { c in
                Button { apply(color: c) } label: {
                    Circle().fill(c.swiftUIColor).frame(width: 38, height: 38)
                        .overlay(Circle().stroke(.white, lineWidth: activeColor == c ? 2.5 : 0))
                        .shadow(color: c.swiftUIColor.opacity(0.5), radius: 5)
                }
                .buttonStyle(.plain)
            }
            Button { showColor = true } label: {
                Circle().fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                    .frame(width: 38, height: 38)
                    .overlay(Image(systemName: "plus").font(.caption.bold()).foregroundStyle(.white))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .disabled(!wled.isReady)
    }

    private var effectsGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Эффекты").font(.headline)
                Spacer()
                if activeEffect != nil {
                    Image(systemName: "tortoise").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $speed, in: 10...255) { editing in if !editing { resendActive() } }
                        .frame(width: 120)
                    Image(systemName: "hare").font(.caption).foregroundStyle(.secondary)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 10) {
                ForEach(CuratedEffect.all) { fx in
                    Button { apply(effect: fx) } label: {
                        VStack(spacing: 6) {
                            Image(systemName: fx.icon).font(.title3)
                            Text(fx.title).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity, minHeight: 66)
                        .background(activeEffect == fx.id ? AnyShapeStyle(.tint.opacity(0.35)) : AnyShapeStyle(.white.opacity(0.06)),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(activeEffect == fx.id ? Color.accentColor : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            if mapStore.map == nil || wled.addressingMode == .direct {
                Text("Объёмные эффекты (водопад, дождь, огонь…) идут по форме гирлянды только после загрузки карты в WLED — «⋯ → Карта».")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .disabled(!wled.isReady)
    }

    private var scenesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Сцены").font(.headline)
                Spacer()
                Button { sceneName = ""; showSave = true } label: { Label("Сохранить текущую", systemImage: "plus").font(.subheadline) }
                    .disabled(activeEffect == nil && activeColor == nil)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(scenes.scenes) { s in
                    Button { apply(scene: s) } label: {
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(s.color.map { AnyShapeStyle($0.swiftUIColor) } ?? AnyShapeStyle(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center)))
                                .frame(width: 30, height: 30)
                                .overlay {
                                    if let c = s.constructor { Image(systemName: c.base.icon).font(.caption2).foregroundStyle(.white) }
                                    else if s.effect != nil { Image(systemName: CuratedEffect.all.first { $0.id == s.effect }?.icon ?? "sparkles").font(.caption2).foregroundStyle(.white) }
                                }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.name).font(.subheadline).lineLimit(1)
                                Text("\(s.brightness * 100 / 255)%").font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .contextMenu { Button(role: .destructive) { scenes.remove(s) } label: { Label("Удалить", systemImage: "trash") } }
                }
            }
        }
        .disabled(!wled.isReady)
    }

    private var colorSheet: some View {
        NavigationStack {
            VStack(spacing: 24) {
                HueSaturationWheel(hue: $hue, saturation: $saturation,
                                   onChanged: { wled.sendFrame(LEDFrame(count: wled.ledCount, fill: RGB(hue: hue, saturation: saturation))) },
                                   onEnded: { apply(color: RGB(hue: hue, saturation: saturation)) })
                    .frame(maxWidth: 300)
                Text("Отпустите — цвет сохранится в контроллере").font(.caption).foregroundStyle(.secondary)
            }
            .padding()
            .navigationTitle("Цвет")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { showColor = false } } }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Действия

    private func apply(color: RGB) {
        constructor.stop()
        activeColor = color; activeEffect = nil; isOn = true
        Task { await wled.setSolid(color, brightness: Int(brightness)) }
    }

    private func apply(effect fx: CuratedEffect) {
        constructor.stop()
        activeEffect = fx.id; activeColor = nil; isOn = true
        speed = Double(fx.speed)
        Task { await wled.setEffect(fx.id, speed: fx.speed, intensity: fx.intensity, palette: fx.palette, brightness: Int(brightness)) }
    }

    private func resendActive() {
        guard let id = activeEffect, let fx = CuratedEffect.all.first(where: { $0.id == id }) else { return }
        Task { await wled.setEffect(fx.id, speed: Int(speed), intensity: fx.intensity, palette: fx.palette, brightness: Int(brightness)) }
    }

    private func apply(scene s: LightScene) {
        brightness = Double(s.brightness); isOn = true
        if let spec = s.constructor {
            activeEffect = nil; activeColor = nil
            if let m = mapStore.map { constructor.update(map: m) }
            Task { await wled.setBrightness(s.brightness) }
            constructor.start(spec, title: s.name)
            return
        }
        if let c = s.color { apply(color: c) }
        else if let e = s.effect {
            activeEffect = e; activeColor = nil; speed = Double(s.speed)
            Task { await wled.setEffect(e, speed: s.speed, intensity: s.intensity, palette: s.palette, brightness: s.brightness) }
        }
    }

    private func saveScene() {
        let name = sceneName.trimmingCharacters(in: .whitespaces)
        if let c = activeColor {
            scenes.add(LightScene(name: name.isEmpty ? "#\(c.hexString)" : name, brightness: Int(brightness), color: c))
        } else if let id = activeEffect, let fx = CuratedEffect.all.first(where: { $0.id == id }) {
            scenes.add(LightScene(name: name.isEmpty ? fx.title : name, brightness: Int(brightness), effect: fx.id,
                                  palette: fx.palette, speed: Int(speed), intensity: fx.intensity))
        }
    }
}

/// Карта с цветами по номерам LED (живое превью или кадр эффекта).
struct LiveMapCanvas: View {
    let map: LEDMap
    let colors: [RGB]
    let highlight: Int?

    var body: some View {
        Canvas { ctx, size in
            for (i, p) in map.points where !p.ambiguous {
                let pt = CGPoint(x: p.x * size.width, y: p.y * size.height)
                let c = colors.indices.contains(i) ? colors[i] : .black
                let bright = max(c.red, max(c.green, c.blue))
                let color = bright < 8 ? Color.white.opacity(0.08) : c.swiftUIColor
                let r: CGFloat = highlight == i ? 7 : (bright < 8 ? 2.5 : 4)
                ctx.fill(Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: 2 * r, height: 2 * r)), with: .color(color))
            }
        }
    }
}
