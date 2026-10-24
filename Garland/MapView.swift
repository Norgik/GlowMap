import SwiftUI

/// Карта светодиодов: проверка касанием и эффекты по форме.
struct MapView: View {
    @Environment(WLEDClient.self) private var wled
    @Environment(LEDMapStore.self) private var mapStore
    @Environment(\.dismiss) private var dismiss
    @State private var engine: MapEffectEngine?
    @State private var mode: MapEffect = .verify
    @State private var tappedIndex: Int?
    @AppStorage("map.fillUnmapped") private var fillUnmapped = false

    private var effectiveMap: LEDMap? {
        guard let m = mapStore.map else { return nil }
        return fillUnmapped ? m.fillingUnmapped() : m
    }

    var body: some View {
        NavigationStack {
            Group {
                if let map = effectiveMap, let engine {
                    content(map: map, engine: engine)
                } else {
                    ContentUnavailableView("Карты нет", systemImage: "map", description: Text("Сначала сканирование камерой"))
                }
            }
            .navigationTitle("Карта")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if let map = effectiveMap {
                let e = MapEffectEngine(wled: wled, map: map)
                engine = e
                e.start(.verify)
            }
        }
        .onDisappear {
            engine?.stop()
            if let map = mapStore.map { wled.sendFrame(LEDFrame(count: map.ledCount)) }
            Task { await wled.unfreeze() }   // WLED вернётся к последнему сплошному цвету, а не к тестовым точкам
        }
    }

    @ViewBuilder
    private func content(map: LEDMap, engine: MapEffectEngine) -> some View {
        @Bindable var engine = engine
        VStack(spacing: 12) {
            canvas(map: map, engine: engine)
                .aspectRatio(map.cameraAspect, contentMode: .fit)
                .background(Color(white: 0.06), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 12)

            Picker("Режим", selection: $mode) {
                ForEach(MapEffect.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .onChange(of: mode) { _, m in engine.start(m) }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch mode {
                    case .verify:
                        Text(tappedIndex.map { "Подсвечен LED №\($0 + 1)" } ?? "Коснитесь точки — соответствующий светодиод загорится белым.")
                            .font(.footnote)
                        Toggle("Дорисовать ненайденные по соседям", isOn: $fillUnmapped)
                            .font(.footnote)
                            .onChange(of: fillUnmapped) { _, _ in
                                if let m = effectiveMap { engine.update(map: m); engine.start(mode) }
                            }
                        HStack(spacing: 8) {
                            Text("Раскладка").font(.footnote)
                            Spacer()
                            layoutButton("rotate.left", .rotateCCW)
                            layoutButton("rotate.right", .rotateCW)
                            layoutButton("arrow.left.and.right", .flipH)
                            layoutButton("arrow.up.and.down", .flipV)
                        }
                        Text("Если камера снимала под углом или карта «вверх ногами» — поверните/отразите; после этого заново загрузите карту в WLED.")
                            .font(.caption2).foregroundStyle(.tertiary)
                        Text("Найдено \(map.foundCount) из \(map.ledCount)" +
                             (map.estimatedCount > 0 ? " · достроено \(map.estimatedCount) (серые)" : "") +
                             (map.ambiguousCount > 0 ? " · сомнительных \(map.ambiguousCount) (оранжевые, в эффектах не участвуют)" : "") +
                             (map.missingIndices.isEmpty ? "" : " · не найдено \(map.missingIndices.count)"))
                            .font(.caption).foregroundStyle(.secondary)
                    case .gradient, .wave:
                        colorRow("Цвет A", $engine.colorA)
                        colorRow("Цвет B", $engine.colorB)
                        slider("Направление", $engine.angle, 0...(2 * .pi), format: { "\(Int($0 * 180 / .pi))°" })
                        if mode == .wave {
                            slider("Скорость", $engine.speed, 0.05...2, format: { String(format: "%.2f", $0) })
                            slider("Длина волны", $engine.wavelength, 0.1...1, format: { String(format: "%.2f", $0) })
                        }
                        slider("Яркость", $engine.brightness, 0.05...1, format: { "\(Int($0 * 100))%" })
                    case .paint:
                        Text("Рисуйте пальцем по карте. Светодиоды в радиусе кисти получают цвет.").font(.footnote)
                        colorRow("Кисть", $engine.brushColor)
                        slider("Размер кисти", $engine.brushRadius, 0.02...0.25, format: { String(format: "%.2f", $0) })
                        slider("Яркость", $engine.brightness, 0.05...1, format: { "\(Int($0 * 100))%" })
                        Button("Очистить", role: .destructive) { engine.clearPaint() }.buttonStyle(.bordered)
                    }
                    Text("Кадры считает телефон и шлёт по Wi‑Fi (DDP, ~30 fps). Работает, пока экран открыт.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func canvas(map: LEDMap, engine: MapEffectEngine) -> some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                Canvas { ctx, size in
                    for (i, p) in map.points {
                        let pt = CGPoint(x: p.x * size.width, y: p.y * size.height)
                        let c: Color
                        if p.ambiguous { c = .orange.opacity(0.7) }
                        else if engine.running == .verify { c = (engine.highlighted == i) ? .white : (p.estimated ? .gray.opacity(0.7) : .green.opacity(0.6)) }
                        else { c = engine.frame.pixels.indices.contains(i) ? engine.frame[i].swiftUIColor : .gray }
                        let r: CGFloat = (engine.highlighted == i) ? 7 : 4
                        ctx.fill(Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: 2 * r, height: 2 * r)), with: .color(c))
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            let x = Double(v.location.x / w), y = Double(v.location.y / h)
                            switch mode {
                            case .verify:
                                engine.highlight(x: x, y: y)
                                tappedIndex = engine.highlighted
                            case .paint:
                                engine.paint(x: x, y: y)
                            default: break
                            }
                        }
                )
            }
        }
    }

    private func layoutButton(_ icon: String, _ t: LEDMap.Transform) -> some View {
        Button {
            guard let m = mapStore.map else { return }
            let nm = m.transformed(t)
            mapStore.save(nm)
            if let eff = effectiveMap { engine?.update(map: eff); engine?.start(mode) }
        } label: { Image(systemName: icon).frame(width: 32, height: 28) }
        .buttonStyle(.bordered)
    }

    private func colorRow(_ title: String, _ binding: Binding<RGB>) -> some View {
        HStack {
            Text(title).font(.footnote)
            Spacer()
            ForEach([RGB.red, RGB(red: 255, green: 80, blue: 0), RGB(red: 255, green: 200, blue: 0), .green,
                     RGB(red: 0, green: 200, blue: 255), .blue, RGB(red: 180, green: 0, blue: 255), .white], id: \.self) { c in
                Button { binding.wrappedValue = c } label: {
                    Circle().fill(c.swiftUIColor).frame(width: 22, height: 22)
                        .overlay(Circle().stroke(.white, lineWidth: binding.wrappedValue == c ? 2 : 0))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>,
                        format: @escaping (Double) -> String) -> some View {
        HStack {
            Text(title).font(.footnote).frame(width: 110, alignment: .leading)
            Slider(value: value, in: range)
            Text(format(value.wrappedValue)).font(.caption.monospacedDigit()).frame(width: 48, alignment: .trailing)
        }
    }
}
