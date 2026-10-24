import SwiftUI

/// Экран конструктора: превью по карте, выбор узора, цвета, ползунки, сохранение в сцену.
struct ConstructorView: View {
    @Environment(WLEDClient.self) private var wled
    @Environment(LEDMapStore.self) private var mapStore
    @Environment(LightSceneStore.self) private var scenes
    @Environment(ConstructorEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss

    @State private var showSave = false
    @State private var sceneName = ""
    @State private var editingColor: Int?

    private let swatches: [RGB] = [.red, RGB(red: 255, green: 120, blue: 0), RGB(red: 255, green: 220, blue: 0), .green,
                                   RGB(red: 0, green: 200, blue: 255), .blue, RGB(red: 170, green: 0, blue: 255),
                                   RGB(red: 255, green: 60, blue: 160), .white, RGB(red: 255, green: 160, blue: 80), RGB(red: 10, green: 10, blue: 40), .black]

    var body: some View {
        @Bindable var engine = engine
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    previewCard
                    basePicker
                    presetsRow
                    colorsEditor
                    sliders
                    sparklesCard
                    Text("Считается телефоном и идёт по карте (или вдоль провода, если карты нет). Работает, пока приложение открыто; «Сохранить в сцены» — чтобы запускать одной кнопкой с главного экрана.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(16)
            }
            .background(Color(red: 0.05, green: 0.05, blue: 0.08).ignoresSafeArea())
            .navigationTitle("Конструктор")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { sceneName = ""; showSave = true } label: { Label("В сцены", systemImage: "plus.square.on.square") }
                }
            }
            .alert("Сохранить в сцены", isPresented: $showSave) {
                TextField("Название", text: $sceneName)
                Button("Сохранить") {
                    let n = sceneName.trimmingCharacters(in: .whitespaces)
                    scenes.add(LightScene(name: n.isEmpty ? engine.spec.base.title : n, brightness: Int(engine.spec.brightness * 255), constructor: engine.spec))
                }
                Button("Отмена", role: .cancel) {}
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if let m = mapStore.map { engine.update(map: m) }
            if !engine.running { engine.start() }
        }
    }

    private var previewCard: some View {
        Group {
            if let map = mapStore.map {
                LiveMapCanvas(map: map, colors: engine.frame.pixels, highlight: nil)
                    .aspectRatio(map.cameraAspect, contentMode: .fit)
                    .frame(maxHeight: 220)
            } else {
                HStack(spacing: 1) {
                    ForEach(0..<engine.frame.count, id: \.self) { i in Rectangle().fill(engine.frame[i].swiftUIColor) }
                }
                .frame(height: 20).clipShape(Capsule())
            }
        }
        .padding(10)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Button(engine.running ? "Стоп" : "Пуск") { engine.running ? engine.stop() : engine.start() }
                .buttonStyle(.bordered).controlSize(.small).padding(8)
        }
    }

    private var basePicker: some View {
        @Bindable var engine = engine
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
            ForEach(ConstructorSpec.Base.allCases) { b in
                Button { engine.spec.base = b } label: {
                    VStack(spacing: 4) {
                        Image(systemName: b.icon).font(.title3)
                        Text(b.title).font(.caption)
                    }
                    .frame(maxWidth: .infinity, minHeight: 58)
                    .background(engine.spec.base == b ? AnyShapeStyle(.tint.opacity(0.35)) : AnyShapeStyle(.white.opacity(0.06)),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var presetsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ConstructorSpec.presets, id: \.name) { p in
                    Button(p.name) { engine.start(p.spec) }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
    }

    private var colorsEditor: some View {
        @Bindable var engine = engine
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Цвета").font(.subheadline)
                Spacer()
                Button { if engine.spec.colors.count < 5 { engine.spec.colors.append(.white) } } label: { Image(systemName: "plus.circle") }
                    .disabled(engine.spec.colors.count >= 5)
                Button { if engine.spec.colors.count > 1 { engine.spec.colors.removeLast() } } label: { Image(systemName: "minus.circle") }
                    .disabled(engine.spec.colors.count <= 1)
            }
            HStack(spacing: 10) {
                ForEach(engine.spec.colors.indices, id: \.self) { i in
                    Button { editingColor = (editingColor == i) ? nil : i } label: {
                        RoundedRectangle(cornerRadius: 8).fill(engine.spec.colors[i].swiftUIColor)
                            .frame(width: 44, height: 32)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white, lineWidth: editingColor == i ? 2 : 0.5))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            if let i = editingColor, engine.spec.colors.indices.contains(i) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 36), spacing: 8)], spacing: 8) {
                    ForEach(swatches, id: \.self) { c in
                        Button { engine.spec.colors[i] = c } label: {
                            Circle().fill(c.swiftUIColor).frame(width: 32, height: 32)
                                .overlay(Circle().stroke(.white.opacity(0.4), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(12)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var sliders: some View {
        @Bindable var engine = engine
        return VStack(spacing: 10) {
            if engine.spec.base != .colorBlend && engine.spec.base != .rings && engine.spec.base != .spiral && engine.spec.base != .plasma {
                row("Направление", $engine.spec.angle, 0...(2 * .pi)) { "\(Int($0 * 180 / .pi))°" }
            }
            row("Скорость", $engine.spec.speed, -1.5...1.5) { String(format: "%.2f", $0) }
            if engine.spec.base != .colorBlend {
                row("Масштаб", $engine.spec.zoom, 0.5...8) { String(format: "%.1f", $0) }
            }
            if engine.spec.base == .stripes || engine.spec.base == .gradient {
                row("Изгиб", $engine.spec.warp, 0...1) { "\(Int($0 * 100))%" }
            }
            if engine.spec.base == .stripes {
                row("Мягкость", $engine.spec.softness, 0...1) { "\(Int($0 * 100))%" }
            }
            row("Яркость", $engine.spec.brightness, 0.05...1) { "\(Int($0 * 100))%" }
        }
        .padding(12)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var sparklesCard: some View {
        @Bindable var engine = engine
        return VStack(spacing: 8) {
            Toggle(isOn: $engine.spec.sparkles) { Label("Искры", systemImage: "sparkles") }
            if engine.spec.sparkles {
                row("Плотность", $engine.spec.sparkleDensity, 0.05...1) { "\(Int($0 * 100))%" }
            }
        }
        .padding(12)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func row(_ title: String, _ v: Binding<Double>, _ r: ClosedRange<Double>, format: @escaping (Double) -> String) -> some View {
        HStack {
            Text(title).font(.footnote).frame(width: 100, alignment: .leading)
            Slider(value: v, in: r)
            Text(format(v.wrappedValue)).font(.caption.monospacedDigit()).frame(width: 52, alignment: .trailing)
        }
    }
}
