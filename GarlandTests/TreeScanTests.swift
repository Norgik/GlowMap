import Testing
import Foundation
@testable import Garland

struct TreeScanTests {

    /// Синтетическая ёлка: LED i на азимуте φ_i, высоте h_i; камера на азимуте θ видит
    /// только переднюю половину (cos(φ−θ) > 0.1).
    private func view(theta: Double, leds: [(phi: Double, h: Double)], aspect: Double) -> TreeScan.View {
        let cx = 0.5, top = 0.1, bottom = 0.9, rBase = 0.3   // в единицах x·aspect
        var pts: [Int: LEDMapPoint] = [:]
        for (i, l) in leds.enumerated() {
            let rel = l.phi - theta
            guard cos(rel) > 0.1 else { continue }
            let r = rBase * (1 - l.h * 0.9)
            let x = (cx * aspect + sin(rel) * r) / aspect
            let y = bottom - l.h * (bottom - top)
            pts[i] = LEDMapPoint(x: x, y: y, confidence: 8 + 4 * cos(rel))
        }
        return TreeScan.View(angleDeg: theta * 180 / .pi, points: pts)
    }

    @Test func fourViewsRecoverAzimuthAndHeight() {
        var leds: [(phi: Double, h: Double)] = []
        for i in 0..<120 {
            let t = Double(i) / 120
            leds.append((phi: (t * 6).truncatingRemainder(dividingBy: 1) * 2 * .pi, h: t * 0.85))   // спираль по конусу
        }
        let aspect = 0.75
        let views = [0.0, 90, 180, 270].map { view(theta: $0 * .pi / 180, leds: leds, aspect: aspect) }
        let map = TreeScan.merge(views, ledCount: 120, aspect: aspect)
        #expect(map.cylindrical == true)
        #expect(map.missingIndices.count <= 3)      // почти все видны хотя бы с одного ракурса
        var phiErr = 0.0, hErr = 0.0, n = 0.0
        for (i, p) in map.points {
            let truePhi = leds[i].phi / (2 * .pi)
            var d = abs(p.x - truePhi); d = min(d, 1 - d)   // по кругу
            // Высота нормируется по освещённому диапазону (гирлянда доходит до h = 0.85), а не по всей ёлке
            phiErr += d; hErr += abs((1 - p.y) - leds[i].h / 0.85); n += 1
        }
        #expect(phiErr / n < 0.05)   // средняя ошибка азимута < 18°
        #expect(hErr / n < 0.05)
    }

    @Test func singleViewOnlyMapsVisibleHalf() {
        var leds: [(phi: Double, h: Double)] = []
        for i in 0..<40 { leds.append((phi: Double(i) / 40 * 2 * .pi, h: 0.5)) }
        let map = TreeScan.merge([view(theta: 0, leds: leds, aspect: 1)], ledCount: 40, aspect: 1)
        #expect(map.points.count < 40 && map.points.count > 10)
        for (i, _) in map.points { #expect(cos(leds[i].phi) > 0) }   // только передняя половина
    }

    @Test func fitFindsTrunkAndExtent() {
        var pts: [Int: LEDMapPoint] = [:]
        for i in 0..<50 {
            let h = Double(i) / 49
            let x = 0.5 + (i % 2 == 0 ? 1 : -1) * 0.3 * (1 - h)
            pts[i] = LEDMapPoint(x: x, y: 0.9 - 0.8 * h, confidence: 9)
        }
        let f = TreeScan.fit(pts, aspect: 1)!
        #expect(abs(f.centerX - 0.5) < 0.05)
        #expect(f.topY < 0.15 && f.bottomY > 0.85)
        #expect(f.baseRadius > 0.2 && f.baseRadius < 0.4)
    }
}
