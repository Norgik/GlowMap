import Testing
import Foundation
@testable import Garland

struct LedmapExportTests {

    private func lineMap(_ n: Int) -> LEDMap {
        var pts: [Int: LEDMapPoint] = [:]
        for i in 0..<n { pts[i] = LEDMapPoint(x: 0.1 + 0.8 * Double(i) / Double(n - 1), y: 0.5, confidence: 10) }
        return LEDMap(ledCount: n, points: pts, createdAt: .now, cameraAspect: 1)
    }

    @Test func everyLedGetsItsOwnCellOnALine() {
        let g = LedmapExport.grid(from: lineMap(20))
        #expect(g.placed == 20 && g.collisions == 0)
        #expect(g.cells.filter { $0 >= 0 }.count == 20)
        #expect(Set(g.cells.filter { $0 >= 0 }) == Set(0..<20))
        #expect(g.cells.count == g.width * g.height)
    }

    @Test func ambiguousPointsAreExcluded() {
        var m = lineMap(10)
        m.points[3]?.ambiguous = true
        let g = LedmapExport.grid(from: m)
        #expect(!g.cells.contains(3))
        #expect(g.placed == 9)
    }

    @Test func jsonIsCompactAndWellFormed() throws {
        let g = LedmapExport.Grid(width: 3, height: 2, cells: [0, -1, 1, 2, 3, -1], placed: 4, collisions: 0)
        let data = LedmapExport.json(g)
        #expect(String(data: data, encoding: .utf8) == "{\"width\":3,\"height\":2,\"map\":[0,-1,1,2,3,-1]}")
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect((parsed?["map"] as? [Int])?.count == 6)
    }

    @Test func gridStaysWithinCellBudget() {
        var pts: [Int: LEDMapPoint] = [:]
        var seed: UInt32 = 7
        for i in 0..<200 {
            seed = seed &* 1664525 &+ 1013904223; let x = Double(seed % 1000) / 1000
            seed = seed &* 1664525 &+ 1013904223; let y = Double(seed % 1000) / 1000
            pts[i] = LEDMapPoint(x: x, y: y, confidence: 10)
        }
        let m = LEDMap(ledCount: 200, points: pts, createdAt: .now, cameraAspect: 0.75)
        let g = LedmapExport.grid(from: m, maxCells: 2048)
        #expect(g.width * g.height <= 2048)
        #expect(g.placed >= 190)
    }
}
