import SwiftUI
import AVFoundation

/// Превью камеры.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspect
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

/// Сканирование камерой: подбор экспозиции, затем проход по всем LED.
struct ScanView: View {
    @Environment(WLEDClient.self) private var wled
    @Environment(LEDMapStore.self) private var mapStore
    @Environment(\.dismiss) private var dismiss
    @State private var scanner = PixelScanner()
    @State private var testLEDOn = false
    @State private var testIndex = 0
    @State private var modeOK: Bool?
    @State private var treeMode: Bool
    init(treeMode: Bool = false) { _treeMode = State(initialValue: treeMode) }
    private let sideAngles: [Double] = [0, 90, 180, 270]

    private var count: Int { wled.ledCount }

    var body: some View {
        @Bindable var scanner = scanner
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                ZStack {
                    CameraPreview(session: scanner.session)
                    foundOverlay
                    VStack {
                        HStack {
                            Label(treeMode ? "РЕЖИМ: ЁЛКА" : "РЕЖИМ: ПЛОСКАЯ", systemImage: treeMode ? "tree.fill" : "rectangle.portrait")
                                .font(.caption.bold())
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(treeMode ? Color.green.opacity(0.75) : Color.blue.opacity(0.7), in: Capsule())
                            Spacer()
                        }
                        .padding(8)
                        Spacer()
                    }
                    if case .scanning(let i) = scanner.state {
                        VStack {
                            Spacer()
                            Text("LED \(i + 1) из \(count) · найдено \(scanner.found.count)")
                                .font(.caption).padding(6).background(.black.opacity(0.6), in: Capsule())
                            ProgressView(value: scanner.progress).padding(.horizontal, 40)
                        }
                        .padding(.bottom, 8)
                    }
                }
                .aspectRatio(3 / 4, contentMode: .fit)
                .clipped()

                controls
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            scanner.startCamera()
            if wled.addressingMode != .direct {
                Task { modeOK = await wled.setDirectMode() }
            } else { modeOK = true }
        }
        .onDisappear {
            scanner.cancel()
            scanner.stopCamera()
            wled.sendFrame(LEDFrame(count: count))
            Task { await wled.unfreeze() }   // вернуть WLED к его собственному состоянию, а не к тестовым точкам
        }
    }

    private var foundOverlay: some View {
        GeometryReader { geo in
            ForEach(Array(scanner.found.keys), id: \.self) { i in
                if let p = scanner.found[i] {
                    Circle()
                        .stroke(p.ambiguous ? Color.orange : (p.estimated ? Color.gray : Color.green), lineWidth: 1.5)
                        .frame(width: 10, height: 10)
                        .position(x: p.x * geo.size.width, y: p.y * geo.size.height)
                }
            }
            if let b = scanner.lastBlob {
                Circle().stroke(.yellow, lineWidth: 2).frame(width: 18, height: 18)
                    .position(x: b.x * geo.size.width, y: b.y * geo.size.height)
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        @Bindable var scanner = scanner
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch scanner.state {
                case .idle, .failed:
                    if case .failed(let m) = scanner.state {
                        Label(m, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                    Picker("Форма", selection: $treeMode) {
                        Label("Плоская (окно, стена)", systemImage: "rectangle.portrait").tag(false)
                        Label("ЁЛКА (4 стороны)", systemImage: "tree.fill").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .disabled(scanner.treeSideCount > 0)
                    if treeMode {
                        let k = scanner.treeSideCount
                        if k < 4 {
                            Text("Сторона \(k + 1) из 4 · камера на \(Int(sideAngles[k]))°").font(.headline)
                            Text(k == 0
                                 ? "Встаньте перед ёлкой на 2–3 м так, чтобы она целиком была в кадре, ствол по центру. Телефон неподвижно."
                                 : "Перейдите на четверть круга ВПРАВО (если смотреть на ёлку), то же расстояние и высота, ствол снова по центру кадра.")
                                .font(.footnote)
                        }
                        if k > 0 {
                            HStack {
                                Button("Собрать ёлку из \(k) \(k == 1 ? "стороны" : "сторон")") {
                                    let map = scanner.treeResult(count: count)
                                    mapStore.save(map)
                                    scanner.resetTree()
                                    dismiss()
                                }
                                .buttonStyle(.borderedProminent)
                                Button("Сброс", role: .destructive) { scanner.resetTree() }.buttonStyle(.bordered)
                            }
                        }
                    }
                    if wled.switchingMode || modeOK == nil {
                        HStack { ProgressView(); Text("Перевожу WLED в прямой режим (снимаю карту, перезагрузка ~15 с)…").font(.footnote) }
                    } else if modeOK == false {
                        Label(wled.lastError ?? "WLED не в прямом режиме", systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote)
                    }
                    Text("1. Поставьте телефон неподвижно так, чтобы вся гирлянда была в кадре. Выключите яркий свет.")
                        .font(.footnote)
                    HStack {
                        Text("Экспозиция").font(.footnote)
                        Slider(value: $scanner.exposureBias, in: -8...0, step: 0.5) { _ in scanner.applyExposure() }
                        Text(String(format: "%.1f EV", scanner.exposureBias)).font(.caption).monospacedDigit()
                    }
                    Text("2. Включите тестовый LED и добейтесь: фон почти чёрный, точка яркая, но не «размазанная».")
                        .font(.footnote)
                    HStack {
                        Toggle("Тестовый LED №\(testIndex + 1)", isOn: $testLEDOn)
                            .onChange(of: testLEDOn) { _, on in sendTest(on) }
                        Stepper("", value: $testIndex, in: 0...max(0, count - 1))
                            .labelsHidden()
                            .onChange(of: testIndex) { _, _ in if testLEDOn { sendTest(true) } }
                    }
                    HStack {
                        Text("Пауза на LED").font(.footnote)
                        Slider(value: Binding(get: { Double(scanner.settleMs) }, set: { scanner.settleMs = Int($0) }), in: 80...400, step: 20)
                        Text("\(scanner.settleMs) мс").font(.caption).monospacedDigit()
                    }
                    Text("Весь проход ≈ \(Int(Double(count) * (Double(scanner.settleMs) + 60) / 1000)) с. Не двигайте телефон.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button {
                        testLEDOn = false
                        scanner.scan(using: wled, count: count)
                    } label: {
                        Label("Начать сканирование", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!scanner.cameraReady || !wled.isReady || modeOK != true)

                case .preparing, .baseline:
                    ProgressView("Базовый кадр при погашенной ленте…")
                case .scanning:
                    Button("Остановить", role: .destructive) { scanner.cancel() }
                        .buttonStyle(.bordered)
                    if let b = scanner.lastBlob {
                        Text(String(format: "пик %.0f · шум %.1f · уверенность %.1f · второй пик %.0f%%",
                                    b.peak, b.noise, b.confidence, b.secondPeakRatio * 100))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                case .done where treeMode:
                    let k = scanner.treeSideCount
                    Text("Сторона \(k + 1): найдено \(scanner.found.count) из \(count)").font(.headline)
                    Text("С одного ракурса видна только обращённая к камере половина — это нормально.").font(.caption).foregroundStyle(.secondary)
                    Button {
                        scanner.commitTreeSide(angleDeg: sideAngles[min(k, 3)])
                    } label: { Label(k >= 3 ? "Сохранить сторону и собрать" : "Сохранить сторону → следующая", systemImage: "arrow.right").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    Button("Переснять эту сторону") { scanner.scan(using: wled, count: count) }.buttonStyle(.bordered)
                case .done:
                    let map = scanner.result(count: count)
                    Text("Найдено \(map.foundCount) из \(count)").font(.headline)
                    Text("достроено между соседями: \(map.estimatedCount) · сомнительных: \(map.ambiguousCount) · не найдено: \(map.missingIndices.count) · проходов: \(scanner.passCount)")
                        .font(.caption).foregroundStyle(.secondary)
                    if !map.missingIndices.isEmpty {
                        Text("Не найдены: " + map.missingIndices.prefix(30).map { "\($0 + 1)" }.joined(separator: ", ") +
                             (map.missingIndices.count > 30 ? "…" : ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button {
                        mapStore.save(map)
                        dismiss()
                    } label: { Label("Сохранить карту", systemImage: "checkmark").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    HStack {
                        Button("Дополнить проблемные") { scanner.rescanProblems(using: wled, count: count) }
                            .buttonStyle(.bordered)
                            .disabled(map.problemIndices.isEmpty)
                        Button("Сканировать заново") { scanner.scan(using: wled, count: count) }
                            .buttonStyle(.bordered)
                    }
                    Text("«Дополнить» повторяет только ненайденные и сомнительные с более длинной выдержкой — телефон не должен был сдвинуться.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Button("Закрыть") { dismiss() }.padding(.top, 4)
            }
            .padding(16)
        }
    }

    private func sendTest(_ on: Bool) {
        var f = LEDFrame(count: count)
        if on { f[testIndex] = scanner.testColor }
        wled.sendFrame(f)
        // realtime в WLED гаснет через ~2,5 с, повторяем пока включено
        if on {
            Task {
                while testLEDOn {
                    try? await Task.sleep(for: .seconds(1))
                    var ff = LEDFrame(count: count); ff[testIndex] = scanner.testColor
                    if testLEDOn { wled.sendFrame(ff) }
                }
            }
        }
    }
}
