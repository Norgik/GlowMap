import Foundation
import Observation

/// Положение одного светодиода в кадре камеры, нормированное 0…1 (x вправо, y вниз).
struct LEDMapPoint: Codable, Equatable {
    var x: Double
    var y: Double
    /// Отношение яркости пика к шуму фона; чем выше, тем надёжнее. < 1 — не найден.
    var confidence: Double
    /// Пик был не единственным — второй кандидат сравнимой яркости далеко от первого.
    var ambiguous: Bool = false
    /// Координата не измерена, а достроена между надёжными соседями по проводу.
    var estimated: Bool = false
}

/// Карта `индекс LED → x,y`. Невидимые / неоднозначные светодиоды координат не получают —
/// их просто нет в `points` (или они помечены `ambiguous`).
struct LEDMap: Codable, Equatable {
    var ledCount: Int
    var points: [Int: LEDMapPoint]
    var createdAt: Date
    var cameraAspect: Double   // ширина/высота кадра, чтобы рисовать без искажений
    /// Развёртка конуса/цилиндра (ёлка): x — азимут по кругу, y — высота. Optional ради старых файлов.
    var cylindrical: Bool? = nil

    /// Измерены камерой и не вызывают сомнений.
    var foundCount: Int { points.values.filter { !$0.ambiguous && !$0.estimated }.count }
    var ambiguousCount: Int { points.values.filter(\.ambiguous).count }
    var estimatedCount: Int { points.values.filter { $0.estimated && !$0.ambiguous }.count }
    var missingIndices: [Int] { (0..<ledCount).filter { points[$0] == nil } }
    /// Не найденные и сомнительные — кандидаты на повторный проход.
    var problemIndices: [Int] { (0..<ledCount).filter { points[$0] == nil || points[$0]!.ambiguous } }

    /// Точки, пригодные для эффектов: измеренные и достроенные, без неоднозначных.
    var reliable: [(index: Int, point: LEDMapPoint)] {
        points.filter { !$0.value.ambiguous }.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
    }

    /// Приблизительная карта для кучно висящей гирлянды: каждый ненайденный или сомнительный LED
    /// ставится между ближайшими надёжными соседями по проводу (пропорционально номеру), а при
    /// соседе только с одной стороны — рядом с ним. Все такие точки помечены `estimated`.
    /// Это оценка, а не измерение; включается пользователем явно.
    func fillingUnmapped() -> LEDMap {
        let anchors = points.filter { !$0.value.ambiguous && !$0.value.estimated }.keys.sorted()
        guard !anchors.isEmpty else { return self }
        var result = self
        for i in 0..<ledCount {
            if let p = points[i], !p.ambiguous { continue }   // измеренные и уже достроенные не трогаем
            // ближайший якорь слева и справа
            var lo: Int?, hi: Int?
            var l = 0, r = anchors.count - 1
            while l <= r {   // бинарный поиск первого якоря > i
                let m = (l + r) / 2
                if anchors[m] < i { l = m + 1 } else { r = m - 1 }
            }
            if l < anchors.count { hi = anchors[l] }
            if l - 1 >= 0 { lo = anchors[l - 1] }
            let pt: LEDMapPoint
            switch (lo, hi) {
            case let (a?, b?):
                let pa = points[a]!, pb = points[b]!
                let t = Double(i - a) / Double(b - a)
                pt = LEDMapPoint(x: pa.x + (pb.x - pa.x) * t, y: pa.y + (pb.y - pa.y) * t, confidence: 0, estimated: true)
            case let (a?, nil):
                let pa = points[a]!
                // продолжаем направление от предыдущего якоря, если он есть, иначе чуть в сторону
                let prevIdx = anchors.firstIndex(of: a).flatMap { $0 > 0 ? anchors[$0 - 1] : nil }
                let dir = prevIdx.map { (pa.x - points[$0]!.x, pa.y - points[$0]!.y) } ?? (0.004, 0)
                let k = Double(i - a) * 0.5
                pt = LEDMapPoint(x: min(1, max(0, pa.x + dir.0 * k)), y: min(1, max(0, pa.y + dir.1 * k)), confidence: 0, estimated: true)
            case let (nil, b?):
                let pb = points[b]!
                let nextIdx = anchors.firstIndex(of: b).flatMap { $0 + 1 < anchors.count ? anchors[$0 + 1] : nil }
                let dir = nextIdx.map { (pb.x - points[$0]!.x, pb.y - points[$0]!.y) } ?? (-0.004, 0)
                let k = Double(b - i) * 0.5
                pt = LEDMapPoint(x: min(1, max(0, pb.x + dir.0 * k)), y: min(1, max(0, pb.y + dir.1 * k)), confidence: 0, estimated: true)
            default:
                continue
            }
            result.points[i] = pt
        }
        return result
    }

    /// Повороты и отражения раскладки (для редактора карты). Повороты на 90° меняют пропорции.
    enum Transform { case rotateCW, rotateCCW, rotate180, flipH, flipV }

    func transformed(_ t: Transform) -> LEDMap {
        var out = self
        for (i, p) in points {
            var q = p
            switch t {
            case .flipH: q.x = 1 - p.x
            case .flipV: q.y = 1 - p.y
            case .rotate180: q.x = 1 - p.x; q.y = 1 - p.y
            case .rotateCW: q.x = 1 - p.y; q.y = p.x
            case .rotateCCW: q.x = p.y; q.y = 1 - p.x
            }
            out.points[i] = q
        }
        if t == .rotateCW || t == .rotateCCW { out.cameraAspect = 1 / cameraAspect }
        return out
    }

    /// Ближайший надёжный LED к точке (в нормированных координатах), если он не дальше `maxDistance`.
    func nearest(to x: Double, _ y: Double, maxDistance: Double = 0.08) -> Int? {
        var best: (Int, Double)?
        for (i, p) in points where !p.ambiguous {
            let d = hypot((p.x - x) * cameraAspect, p.y - y)
            if d <= maxDistance, best == nil || d < best!.1 { best = (i, d) }
        }
        return best?.0
    }
}

/// Хранение карты в Documents/ledmap.json.
@Observable
final class LEDMapStore {
    private(set) var map: LEDMap?

    private var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ledmap.json")
    }

    init() { load() }

    func save(_ m: LEDMap) {
        map = m
        if let data = try? JSONEncoder().encode(m) { try? data.write(to: url, options: .atomic) }
    }

    func clear() {
        map = nil
        try? FileManager.default.removeItem(at: url)
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        map = try? JSONDecoder().decode(LEDMap.self, from: data)
    }
}
