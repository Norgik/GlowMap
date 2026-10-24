import Testing
import Foundation
@testable import Garland

struct ChainFilterTests {
    /// Прямая цепочка из `n` точек с шагом 0.02 по x.
    private func chain(_ n: Int, skip: Set<Int> = []) -> [Int: LEDMapPoint] {
        var pts: [Int: LEDMapPoint] = [:]
        for i in 0..<n where !skip.contains(i) {
            pts[i] = LEDMapPoint(x: 0.1 + Double(i) * 0.02, y: 0.5, confidence: 10)
        }
        return pts
    }

    @Test func medianStepOfStraightChain() {
        let step = ScanMath.medianStep(chain(20), aspect: 1)
        #expect(step != nil && abs(step! - 0.02) < 1e-9)
    }

    @Test func flagsIsolatedOutlierButKeepsChain() {
        var pts = chain(20)
        pts[10] = LEDMapPoint(x: 0.9, y: 0.05, confidence: 10)   // блик далеко от провода
        let out = ScanMath.chainOutliers(pts, aspect: 1)
        #expect(out == [10])
    }

    @Test func doesNotFlagGenuineTurnOfTheWire() {
        // Змейка: после 10-го провод разворачивается — соседи остаются близко, выбросов нет
        var pts: [Int: LEDMapPoint] = [:]
        for i in 0..<10 { pts[i] = LEDMapPoint(x: 0.1 + Double(i) * 0.05, y: 0.3, confidence: 10) }
        for i in 10..<20 { pts[i] = LEDMapPoint(x: 0.55 - Double(i - 10) * 0.05, y: 0.35, confidence: 10) }
        #expect(ScanMath.chainOutliers(pts, aspect: 1).isEmpty)
    }

    @Test func flagsDetachedEndpoint() {
        var pts = chain(20)
        pts[19] = LEDMapPoint(x: 0.05, y: 0.95, confidence: 10)
        #expect(ScanMath.chainOutliers(pts, aspect: 1).contains(19))
    }

    @Test func interpolatesShortGapsOnly() {
        let pts = chain(20, skip: [5, 6, 11, 12, 13, 14, 15])   // пропуск 2 и пропуск 5
        let filled = ScanMath.interpolateGaps(pts, count: 20, maxGap: 3)
        #expect(filled[5]?.estimated == true && filled[6]?.estimated == true)
        #expect(abs(filled[5]!.x - (0.1 + 5 * 0.02)) < 1e-9)
        #expect(filled[11] == nil && filled[15] == nil)          // длинный пропуск не выдумываем
        let map = LEDMap(ledCount: 20, points: filled, createdAt: .now, cameraAspect: 1)
        #expect(map.foundCount == 13 && map.estimatedCount == 2 && map.missingIndices.count == 5)
    }

    @Test func interpolationNeverUsesAmbiguousAnchors() {
        var pts = chain(10, skip: [4])
        pts[3]?.ambiguous = true
        let filled = ScanMath.interpolateGaps(pts, count: 10)
        // якоря — 2 и 5 (3 сомнительный); 3 и 4 достраиваются между ними
        #expect(filled[4]?.estimated == true)
        #expect(filled[3]?.estimated == true && filled[3]?.ambiguous == false)
    }

    @Test func resolvesAmbiguousByNeighbours() {
        var pts = chain(10)
        // LED 5 сомнительный: кандидаты — отражение далеко и правильная точка на проводе
        pts[5] = LEDMapPoint(x: 0.8, y: 0.9, confidence: 8, ambiguous: true)
        let cands: [Int: [(x: Double, y: Double)]] = [5: [(0.8, 0.9), (0.1 + 5 * 0.02 + 0.003, 0.5)]]
        let resolved = ScanMath.resolveAmbiguous(pts, candidates: cands, aspect: 1)
        #expect(resolved[5]?.ambiguous == false)
        #expect(abs(resolved[5]!.x - 0.203) < 1e-9)
    }

    @Test func keepsAmbiguousWhenNoCandidateFitsTheWire() {
        var pts = chain(10)
        pts[5] = LEDMapPoint(x: 0.8, y: 0.9, confidence: 8, ambiguous: true)
        let cands: [Int: [(x: Double, y: Double)]] = [5: [(0.8, 0.9), (0.9, 0.1)]]
        let resolved = ScanMath.resolveAmbiguous(pts, candidates: cands, aspect: 1)
        #expect(resolved[5]?.ambiguous == true)
    }

    @Test func fillingUnmappedPlacesEveryLedWithoutTouchingMeasured() {
        var pts = chain(20, skip: [3, 4, 5, 12])          // пропуски 3 и 1
        pts[15]?.ambiguous = true                          // сомнительный тоже достраивается
        let m = LEDMap(ledCount: 20, points: pts, createdAt: .now, cameraAspect: 1)
        let f = m.fillingUnmapped()
        #expect(f.missingIndices.isEmpty && f.ambiguousCount == 0)
        #expect(f.estimatedCount == 5 && f.foundCount == 15)
        #expect(abs(f.points[4]!.x - (0.1 + 4 * 0.02)) < 1e-9)   // линейно между 2 и 6
        #expect(f.points[0] == m.points[0])                        // измеренные не изменились
        #expect(f.points[15]?.estimated == true && f.points[15]?.ambiguous == false)
    }

    @Test func fillingUnmappedExtrapolatesTails() {
        var pts = chain(10)
        for i in 7..<10 { pts[i] = nil }                   // хвост не найден
        let m = LEDMap(ledCount: 10, points: pts, createdAt: .now, cameraAspect: 1)
        let f = m.fillingUnmapped()
        #expect(f.points[9] != nil && f.points[9]!.estimated)
        #expect(f.points[9]!.x > f.points[6]!.x)           // продолжает направление провода
        #expect(f.points[9]!.x <= 1)
    }

    @Test func fillingUnmappedWithNoAnchorsIsNoop() {
        let m = LEDMap(ledCount: 5, points: [:], createdAt: .now, cameraAspect: 1)
        #expect(m.fillingUnmapped() == m)
    }

    @Test func transformsKeepIndicesAndInvert() {
        var pts: [Int: LEDMapPoint] = [:]
        pts[0] = LEDMapPoint(x: 0.2, y: 0.1, confidence: 9)
        pts[1] = LEDMapPoint(x: 0.9, y: 0.7, confidence: 9)
        let m = LEDMap(ledCount: 2, points: pts, createdAt: .now, cameraAspect: 2)
        let cw = m.transformed(.rotateCW)
        #expect(abs(cw.points[0]!.x - 0.9) < 1e-9 && abs(cw.points[0]!.y - 0.2) < 1e-9)
        #expect(abs(cw.cameraAspect - 0.5) < 1e-9)
        let back = cw.transformed(.rotateCCW)
        #expect(abs(back.points[1]!.x - 0.9) < 1e-9 && abs(back.points[1]!.y - 0.7) < 1e-9)
        #expect(abs(m.transformed(.flipH).points[0]!.x - 0.8) < 1e-9)
        #expect(abs(m.transformed(.flipV).points[1]!.y - 0.3) < 1e-9)
        let twice = m.transformed(.rotate180).transformed(.rotate180)
        #expect(abs(twice.points[0]!.x - 0.2) < 1e-9 && abs(twice.points[1]!.y - 0.7) < 1e-9)
    }
}
