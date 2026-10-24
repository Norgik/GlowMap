import Foundation

/// Сшивка нескольких ракурсов для конической ёлки.
///
/// Геометрия: камера стоит на азимуте θ_k и смотрит на ствол. Светодиод на азимуте φ виден
/// в кадре со смещением от оси ствола dx = sin(φ − θ_k) · R(h), где R(h) — радиус конуса на высоте h.
/// Отсюда φ = θ_k + asin(dx / R(h)). Высоту берём из вертикальной координаты кадра.
/// Результат — развёртка: x = φ / 2π (по кругу), y = высота (0 — верх). Светодиоды, не видимые ни с
/// одного ракурса, координат не получают.
enum TreeScan {

    struct View {
        var angleDeg: Double              // азимут камеры: 0, 90, 180, 270
        var points: [Int: LEDMapPoint]    // что нашёл плоский скан с этого ракурса
    }

    struct Fit: Equatable {
        var centerX: Double     // ось ствола в кадре (нормированная x)
        var topY: Double        // верх ёлки в кадре
        var bottomY: Double     // низ ёлки в кадре
        var baseRadius: Double  // радиус у основания в единицах x кадра (с учётом aspect)
    }

    /// Оценка оси, высоты и радиуса конуса по силуэту найденных точек одного ракурса.
    static func fit(_ pts: [Int: LEDMapPoint], aspect: Double) -> Fit? {
        let good = pts.values.filter { !$0.ambiguous }
        guard good.count >= 5 else { return nil }
        let xs = good.map { $0.x * aspect }.sorted()
        let ys = good.map(\.y).sorted()
        let cx = xs[xs.count / 2]                                 // медиана — ствол примерно в центре
        let top = ys[max(0, Int(Double(ys.count) * 0.01))]
        let bottom = ys[min(ys.count - 1, Int(Double(ys.count) * 0.99))]
        let height = max(1e-6, bottom - top)
        // Радиус основания по той же модели конуса, что и в merge: R(h) = R0 · (1 − 0.9h).
        // Для каждой точки |dx| / (1 − 0.9h), берём 90-й перцентиль — силуэт без выбросов.
        var est: [Double] = []
        for p in good {
            let h = max(0, min(1, (bottom - p.y) / height))       // 0 низ … 1 верх
            est.append(abs(p.x * aspect - cx) / (1 - 0.9 * h))
        }
        guard !est.isEmpty else { return nil }
        est.sort()
        let r = est[min(est.count - 1, Int(Double(est.count) * 0.9))]
        return Fit(centerX: cx / aspect, topY: top, bottomY: bottom, baseRadius: max(1e-3, r))
    }

    /// Сшить ракурсы в развёртку. `aspect` — пропорции кадра камеры (общие для всех ракурсов).
    static func merge(_ views: [View], ledCount: Int, aspect: Double) -> LEDMap {
        struct Cand { var phi: Double; var h: Double; var score: Double; var conf: Double }
        var best: [Int: Cand] = [:]
        var heightSum: [Int: (Double, Double)] = [:]   // взвешенная сумма высот

        // Верх/низ ёлки и радиус основания — общие для всех ракурсов (ёлка одна, камера на том же
        // расстоянии и высоте); иначе каждый ракурс видит свой набор LED и высоты «плывут».
        var union: [Int: LEDMapPoint] = [:]
        var key = 0
        for v in views { for p in v.points.values { union[key] = p; key += 1 } }
        guard let global = fit(union, aspect: aspect) else {
            return LEDMap(ledCount: ledCount, points: [:], createdAt: .now, cameraAspect: 2.0)
        }

        for v in views {
            guard let local = fit(v.points, aspect: aspect) else { continue }
            // ось ствола — своя для ракурса (камеру могли сдвинуть), габариты и радиус — общие
            let f = Fit(centerX: local.centerX, topY: global.topY, bottomY: global.bottomY, baseRadius: global.baseRadius)
            let theta = v.angleDeg * .pi / 180
            let height = max(1e-6, f.bottomY - f.topY)
            for (i, p) in v.points where !p.ambiguous {
                let h = max(0, min(1, (f.bottomY - p.y) / height))
                let radius = max(1e-3, f.baseRadius * (1 - h * 0.9))   // у вершины радиус не ноль, иначе деление взрывается
                let dx = max(-1, min(1, (p.x - f.centerX) * aspect / radius))
                let phi = theta + asin(dx)
                // Чем ближе к краю силуэта, тем хуже определён азимут
                let score = p.confidence * (1 - 0.7 * abs(dx))
                if best[i] == nil || score > best[i]!.score {
                    best[i] = Cand(phi: phi, h: h, score: score, conf: p.confidence)
                }
                let w = max(0.1, score)
                heightSum[i, default: (0, 0)].0 += h * w
                heightSum[i, default: (0, 0)].1 += w
            }
        }

        var points: [Int: LEDMapPoint] = [:]
        for (i, c) in best {
            var phi = c.phi.truncatingRemainder(dividingBy: 2 * .pi)
            if phi < 0 { phi += 2 * .pi }
            let hs = heightSum[i]!
            let h = hs.1 > 0 ? hs.0 / hs.1 : c.h
            points[i] = LEDMapPoint(x: phi / (2 * .pi), y: 1 - h, confidence: c.conf)
        }
        var map = LEDMap(ledCount: ledCount, points: points, createdAt: .now, cameraAspect: 2.0)
        map.cylindrical = true
        return map
    }
}
