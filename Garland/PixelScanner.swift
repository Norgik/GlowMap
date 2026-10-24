import Foundation
@preconcurrency import AVFoundation
import CoreVideo
import Observation

/// Уменьшенное полутоновое изображение кадра камеры.
struct GrayImage {
    let width: Int
    let height: Int
    var pixels: [Float]   // 0…255

    static func zero(_ w: Int, _ h: Int) -> GrayImage { GrayImage(width: w, height: h, pixels: .init(repeating: 0, count: w * h)) }

    /// Яркость из BGRA-буфера с прореживанием до ширины ~`targetWidth`.
    init(pixelBuffer pb: CVPixelBuffer, targetWidth: Int = 320) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let step = max(1, w / targetWidth)
        width = w / step; height = h / step
        pixels = .init(repeating: 0, count: width * height)
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let stride = CVPixelBufferGetBytesPerRow(pb)
        let p = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            let row = p + y * step * stride
            for x in 0..<width {
                let px = row + x * step * 4   // B G R A
                let b = Float(px[0]), g = Float(px[1]), r = Float(px[2])
                pixels[y * width + x] = 0.299 * r + 0.587 * g + 0.114 * b
            }
        }
    }

    init(width: Int, height: Int, pixels: [Float]) { self.width = width; self.height = height; self.pixels = pixels }
}

/// Результат поиска одного светодиода на разностном кадре.
struct BlobResult {
    var x: Double, y: Double          // нормированные 0…1
    var peak: Float                   // яркость пика над фоном
    var noise: Float                  // оценка шума фона
    var secondPeakRatio: Float        // яркость второго далёкого пика / первого
    var secondX: Double = 0, secondY: Double = 0   // где второй кандидат (отражение или сосед)
    var confidence: Double { noise > 0 ? Double(peak / noise) : 0 }
    /// Порог, с которого второй пик считается конкурентом (отражения на глянце дают 0.4–0.9).
    static let ambiguityRatio: Float = 0.7
    var isAmbiguous: Bool { secondPeakRatio > Self.ambiguityRatio }
}

/// Чистая математика сканирования — без камеры, чтобы покрыть тестами.
enum ScanMath {
    /// Разность `frame − baseline`, отрицательное обрезается.
    static func difference(_ frame: GrayImage, _ baseline: GrayImage) -> GrayImage {
        var out = frame
        for i in 0..<out.pixels.count { out.pixels[i] = max(0, frame.pixels[i] - baseline.pixels[i]) }
        return out
    }

    /// Пик с субпиксельным центроидом в окне ±`radius`, оценка шума и второго пика.
    static func locate(_ diff: GrayImage, radius: Int = 6, minPeak: Float = 25) -> BlobResult? {
        let w = diff.width, h = diff.height, px = diff.pixels
        guard w > 0, h > 0 else { return nil }
        var maxV: Float = 0, maxI = 0
        for i in 0..<px.count where px[i] > maxV { maxV = px[i]; maxI = i }
        guard maxV >= minPeak else { return nil }
        let cx = maxI % w, cy = maxI / w

        // Центроид по окну
        var sum: Float = 0, sx: Float = 0, sy: Float = 0
        for y in max(0, cy - radius)...min(h - 1, cy + radius) {
            for x in max(0, cx - radius)...min(w - 1, cx + radius) {
                let v = px[y * w + x]
                if v > maxV * 0.3 { sum += v; sx += v * Float(x); sy += v * Float(y) }
            }
        }
        let fx = sum > 0 ? sx / sum : Float(cx), fy = sum > 0 ? sy / sum : Float(cy)

        // Шум: медиана-подобная оценка — среднее по пикселям вне окна (дёшево и достаточно)
        var nsum: Float = 0, ncount: Float = 0
        var second: Float = 0, sx2 = cx, sy2 = cy
        let far = radius * 3
        for y in 0..<h {
            for x in 0..<w {
                if abs(x - cx) > far || abs(y - cy) > far {
                    let v = px[y * w + x]
                    nsum += v; ncount += 1
                    if v > second { second = v; sx2 = x; sy2 = y }
                }
            }
        }
        let noise = max(1, ncount > 0 ? nsum / ncount : 1)
        return BlobResult(x: Double(fx) / Double(w - 1), y: Double(fy) / Double(h - 1),
                          peak: maxV, noise: noise, secondPeakRatio: second / maxV,
                          secondX: Double(sx2) / Double(w - 1), secondY: Double(sy2) / Double(h - 1))
    }
}

extension ScanMath {
    /// Расстояние между точками с учётом пропорций кадра.
    static func dist(_ a: LEDMapPoint, _ b: LEDMapPoint, aspect: Double) -> Double {
        hypot((a.x - b.x) * aspect, a.y - b.y)
    }

    /// Типичный шаг между соседними по номеру найденными LED (медиана).
    static func medianStep(_ pts: [Int: LEDMapPoint], aspect: Double) -> Double? {
        let keys = pts.keys.sorted()
        var steps: [Double] = []
        for (a, b) in zip(keys, keys.dropFirst()) where b - a == 1 {
            steps.append(dist(pts[a]!, pts[b]!, aspect: aspect))
        }
        guard !steps.isEmpty else { return nil }
        steps.sort()
        return steps[steps.count / 2]
    }

    /// Выбросы по непрерывности провода: точка, которая далеко и от предыдущего, и от следующего
    /// найденного соседа (дальше `factor` × медианный шаг × число пропущенных номеров), хотя те
    /// соседи друг с другом согласны. Возвращает индексы, которые надо пометить сомнительными.
    static func chainOutliers(_ pts: [Int: LEDMapPoint], aspect: Double, factor: Double = 3) -> Set<Int> {
        guard let step = medianStep(pts, aspect: aspect), step > 0 else { return [] }
        let keys = pts.keys.sorted()
        var out = Set<Int>()
        for (k, i) in keys.enumerated() {
            let prev = k > 0 ? keys[k - 1] : nil
            let next = k + 1 < keys.count ? keys[k + 1] : nil
            func far(_ j: Int?) -> Bool? {
                guard let j else { return nil }
                return dist(pts[i]!, pts[j]!, aspect: aspect) > factor * step * Double(abs(i - j))
            }
            let fp = far(prev), fn = far(next)
            switch (fp, fn) {
            case (true, true):
                // оба соседа далеко; если соседи близки между собой — виноват именно i
                if let p = prev, let n = next,
                   dist(pts[p]!, pts[n]!, aspect: aspect) <= factor * step * Double(n - p) {
                    out.insert(i)
                }
            case (true, nil), (nil, true):
                out.insert(i)   // крайняя точка, оторванная от единственного соседа
            default: break
            }
        }
        return out
    }

    /// Ожидаемое положение LED `i` по надёжным соседям в пределах ±`reach` номеров.
    static func expectedPosition(_ i: Int, in pts: [Int: LEDMapPoint], reach: Int = 3) -> (x: Double, y: Double, gap: Int)? {
        func reliable(_ j: Int) -> LEDMapPoint? {
            guard let p = pts[j], !p.ambiguous, !p.estimated else { return nil }
            return p
        }
        var prev: (Int, LEDMapPoint)?, next: (Int, LEDMapPoint)?
        for d in 1...reach {
            if prev == nil, let p = reliable(i - d) { prev = (i - d, p) }
            if next == nil, let n = reliable(i + d) { next = (i + d, n) }
        }
        switch (prev, next) {
        case let (p?, n?):
            let t = Double(i - p.0) / Double(n.0 - p.0)
            return (p.1.x + (n.1.x - p.1.x) * t, p.1.y + (n.1.y - p.1.y) * t, max(i - p.0, n.0 - i))
        case let (p?, nil): return (p.1.x, p.1.y, i - p.0)
        case let (nil, n?): return (n.1.x, n.1.y, n.0 - i)
        default: return nil
        }
    }

    /// Для сомнительных LED с двумя кандидатами выбирает тот, что согласуется с соседями по
    /// проводу. Кандидат принимается, если он не дальше `factor` × медианный шаг × разрыв.
    static func resolveAmbiguous(_ pts: [Int: LEDMapPoint],
                                 candidates: [Int: [(x: Double, y: Double)]],
                                 aspect: Double, factor: Double = 3) -> [Int: LEDMapPoint] {
        guard let step = medianStep(pts.filter { !$0.value.ambiguous }, aspect: aspect) ?? medianStep(pts, aspect: aspect),
              step > 0 else { return pts }
        var result = pts
        for (i, p) in pts where p.ambiguous {
            guard let cands = candidates[i], !cands.isEmpty,
                  let exp = expectedPosition(i, in: result) else { continue }
            let limit = factor * step * Double(exp.gap)
            var best: (Double, (x: Double, y: Double))?
            for c in cands {
                let d = hypot((c.x - exp.x) * aspect, c.y - exp.y)
                if best == nil || d < best!.0 { best = (d, c) }
            }
            if let b = best, b.0 <= limit {
                result[i] = LEDMapPoint(x: b.1.x, y: b.1.y, confidence: p.confidence, ambiguous: false, estimated: false)
            }
        }
        return result
    }

    /// Достраивает пропуски длиной ≤ `maxGap` линейно между двумя надёжными соседями.
    /// Результат помечается `estimated` — это не измерение.
    static func interpolateGaps(_ pts: [Int: LEDMapPoint], count: Int, maxGap: Int = 3) -> [Int: LEDMapPoint] {
        var result = pts
        let reliable = pts.filter { !$0.value.ambiguous && !$0.value.estimated }.keys.sorted()
        for (a, b) in zip(reliable, reliable.dropFirst()) {
            let gap = b - a - 1
            guard gap >= 1, gap <= maxGap else { continue }
            let pa = pts[a]!, pb = pts[b]!
            for i in (a + 1)..<b where result[i] == nil || result[i]!.ambiguous {
                let t = Double(i - a) / Double(b - a)
                result[i] = LEDMapPoint(x: pa.x + (pb.x - pa.x) * t, y: pa.y + (pb.y - pa.y) * t,
                                        confidence: 0, ambiguous: false, estimated: true)
            }
        }
        return result
    }
}

/// Камера + последовательность кадров на ленту → карта. Работает только с WLED (DDP).
@Observable
@MainActor
final class PixelScanner: NSObject {

    enum State: Equatable { case idle, preparing, baseline, scanning(Int), done, failed(String) }

    private(set) var state: State = .idle
    private(set) var progress: Double = 0
    private(set) var found: [Int: LEDMapPoint] = [:]
    private(set) var lastBlob: BlobResult?
    private(set) var cameraReady = false
    private(set) var cameraAspect: Double = 4.0 / 3.0

    /// Параметры съёмки, подбираются пользователем на экране.
    var exposureBias: Float = -3   // EV, чем ниже, тем темнее фон
    var settleMs: Int = 140        // пауза после смены кадра на ленте
    var testColor: RGB = .white
    var minConfidence: Double = 4

    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "garland.scanner.camera")
    private var device: AVCaptureDevice?
    private var latest: (image: GrayImage, time: TimeInterval)?
    private var scanTask: Task<Void, Never>?
    private var baseline: GrayImage?
    private var candidates: [Int: [(x: Double, y: Double)]] = [:]
    private(set) var passCount = 0

    /// Режим «Ёлка»: ракурсы, снятые с четырёх сторон.
    private(set) var treeViews: [TreeScan.View] = []
    var treeSideCount: Int { treeViews.count }

    /// Запомнить текущий результат как ракурс с азимутом `angleDeg` и подготовиться к следующему.
    func commitTreeSide(angleDeg: Double) {
        treeViews.append(TreeScan.View(angleDeg: angleDeg, points: found))
        found = [:]; candidates = [:]
        baseline = nil            // новая позиция камеры — новая база
        state = .idle
    }

    func resetTree() { treeViews = []; found = [:]; candidates = [:]; baseline = nil; state = .idle }

    func treeResult(count: Int) -> LEDMap {
        TreeScan.merge(treeViews, ledCount: count, aspect: cameraAspect)
    }

    // MARK: - Камера

    func startCamera() {
        guard !session.isRunning else { return }
        Task {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard granted else { state = .failed("нет доступа к камере"); return }
            configureSession()
        }
    }

    func stopCamera() {
        scanTask?.cancel()
        queue.async { [session] in session.stopRunning() }
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .vga640x480
        guard let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: cam), session.canAddInput(input) else {
            session.commitConfiguration()
            state = .failed("камера недоступна")
            return
        }
        session.addInput(input)
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        if let conn = output.connection(with: .video) {
            if #available(iOS 17, *) { if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 } }
        }
        session.commitConfiguration()
        device = cam
        applyExposure()
        queue.async { [session] in session.startRunning() }
        cameraReady = true
    }

    /// Тёмный фон: отрицательная экспокоррекция, автофокус и баланс белого замораживаем на время скана.
    func applyExposure() {
        guard let d = device, (try? d.lockForConfiguration()) != nil else { return }
        if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
        let bias = max(d.minExposureTargetBias, min(d.maxExposureTargetBias, exposureBias))
        d.setExposureTargetBias(bias)
        d.unlockForConfiguration()
    }

    private func lockCamera(_ lock: Bool) {
        guard let d = device, (try? d.lockForConfiguration()) != nil else { return }
        if lock {
            if d.isExposureModeSupported(.locked) { d.exposureMode = .locked }
            if d.isWhiteBalanceModeSupported(.locked) { d.whiteBalanceMode = .locked }
            if d.isFocusModeSupported(.locked) { d.focusMode = .locked }
        } else {
            if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
            if d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { d.whiteBalanceMode = .continuousAutoWhiteBalance }
            if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
        }
        d.unlockForConfiguration()
    }

    /// Свежий кадр, снятый не раньше `after`.
    private func grabFrame(after: TimeInterval) async -> GrayImage? {
        for _ in 0..<60 {
            if let l = latest, l.time > after { return l.image }
            try? await Task.sleep(for: .milliseconds(15))
        }
        return nil
    }

    private func average(_ a: GrayImage, _ b: GrayImage) -> GrayImage {
        var out = a
        for i in 0..<out.pixels.count { out.pixels[i] = (a.pixels[i] + b.pixels[i]) / 2 }
        return out
    }

    // MARK: - Сканирование

    func cancel() {
        scanTask?.cancel()
        scanTask = nil
        lockCamera(false)
        if case .scanning = state { state = .idle }
    }

    /// Полный проход: базовый кадр при погашенной ленте, по одному LED, затем автоматический
    /// повторный проход по проблемным, фильтр выбросов и достройка коротких пропусков.
    func scan(using wled: WLEDClient, count: Int) {
        scanTask?.cancel()
        found = [:]
        candidates = [:]
        progress = 0
        passCount = 0
        scanTask = Task { [weak self] in
            guard let self else { return }
            guard await self.prepareBaseline(wled: wled, count: count) else { return }
            await self.pass(indices: Array(0..<count), wled: wled, count: count, framesPerLED: 1, settleScale: 1)
            if Task.isCancelled { return }
            await self.refine(wled: wled, count: count)
        }
    }

    /// Повторный проход только по ненайденным и сомнительным (камера не должна была сдвинуться).
    func rescanProblems(using wled: WLEDClient, count: Int) {
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            guard let self else { return }
            if self.baseline == nil { guard await self.prepareBaseline(wled: wled, count: count) else { return } }
            lockCamera(true)
            await self.refine(wled: wled, count: count)
        }
    }

    private func refine(wled: WLEDClient, count: Int) async {
        // Сначала снимаем явные выбросы, чтобы они пошли на повторный замер
        for i in ScanMath.chainOutliers(found, aspect: cameraAspect) { found[i]?.ambiguous = true }
        let problems = (0..<count).filter { found[$0] == nil || found[$0]!.ambiguous }
        if !problems.isEmpty {
            await pass(indices: problems, wled: wled, count: count, framesPerLED: 3, settleScale: 1.6)
        }
        if Task.isCancelled { return }
        for i in ScanMath.chainOutliers(found, aspect: cameraAspect) { found[i]?.ambiguous = true }
        // Два кандидата (светодиод и его отражение / сосед) — выбираем согласующийся с проводом
        found = ScanMath.resolveAmbiguous(found, candidates: candidates, aspect: cameraAspect)
        for i in ScanMath.chainOutliers(found, aspect: cameraAspect) { found[i]?.ambiguous = true }
        found = ScanMath.interpolateGaps(found, count: count, maxGap: 3)
        wled.sendFrame(LEDFrame(count: count))
        lockCamera(false)
        progress = 1
        state = .done
    }

    private func prepareBaseline(wled: WLEDClient, count: Int) async -> Bool {
        state = .preparing
        let off = LEDFrame(count: count)
        wled.sendFrame(off)
        try? await Task.sleep(for: .milliseconds(400))
        lockCamera(true)
        try? await Task.sleep(for: .milliseconds(300))
        state = .baseline
        wled.sendFrame(off)
        guard let b1 = await grabFrame(after: now()), let b2 = await grabFrame(after: now()) else {
            state = .failed("нет кадров с камеры"); lockCamera(false); return false
        }
        baseline = average(b1, b2)
        return true
    }

    /// Один проход по заданным индексам. `framesPerLED` > 1 — берём лучший из нескольких кадров.
    private func pass(indices: [Int], wled: WLEDClient, count: Int, framesPerLED: Int, settleScale: Double) async {
        guard var base = baseline else { return }
        passCount += 1
        let settle = Double(settleMs) / 1000 * settleScale
        for (k, i) in indices.enumerated() {
            if Task.isCancelled { lockCamera(false); return }
            state = .scanning(i)
            progress = Double(k) / Double(max(1, indices.count))

            var frame = LEDFrame(count: count)
            frame[i] = testColor
            wled.sendFrame(frame)
            let sentAt = now()
            try? await Task.sleep(for: .seconds(settle))

            var best: BlobResult?
            for f in 0..<framesPerLED {
                if f > 0 { wled.sendFrame(frame); try? await Task.sleep(for: .milliseconds(60)) }
                guard let img = await grabFrame(after: sentAt + settle * 0.8) else { continue }
                if let blob = ScanMath.locate(ScanMath.difference(img, base)),
                   best == nil || blob.confidence > best!.confidence { best = blob }
            }
            lastBlob = best
            if let blob = best, blob.confidence >= minConfidence {
                let candidate = LEDMapPoint(x: blob.x, y: blob.y, confidence: blob.confidence,
                                            ambiguous: blob.isAmbiguous)
                candidates[i] = blob.isAmbiguous ? [(blob.x, blob.y), (blob.secondX, blob.secondY)] : [(blob.x, blob.y)]
                // не затираем хорошее измерение худшим
                if let old = found[i], !old.ambiguous, !old.estimated, old.confidence > candidate.confidence { } else {
                    found[i] = candidate
                }
            }

            // Каждые 20 LED освежаем базу: свет в комнате и автогейн могут плыть
            if k % 20 == 19 {
                wled.sendFrame(LEDFrame(count: count))
                try? await Task.sleep(for: .seconds(settle))
                if let b = await grabFrame(after: now()) { base = average(base, b); baseline = base }
            }
        }
    }

    func result(count: Int) -> LEDMap {
        LEDMap(ledCount: count, points: found, createdAt: .now, cameraAspect: cameraAspect)
    }

    private func now() -> TimeInterval { CACurrentMediaTime() }
}

extension PixelScanner: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let img = GrayImage(pixelBuffer: pb, targetWidth: 320)
        let t = CACurrentMediaTime()
        Task { @MainActor in
            self.latest = (img, t)
            self.cameraAspect = Double(img.width) / Double(img.height)
        }
    }
}
