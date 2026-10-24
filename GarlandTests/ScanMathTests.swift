import Testing
import Foundation
@testable import Garland

struct ScanMathTests {

    private func synthetic(w: Int = 64, h: Int = 48, spot: (Int, Int, Float)?, noise: Float = 3) -> GrayImage {
        var img = GrayImage.zero(w, h)
        var seed: UInt32 = 12345
        for i in 0..<img.pixels.count {
            seed = seed &* 1664525 &+ 1013904223
            img.pixels[i] = 20 + Float(seed % 1000) / 1000 * noise
        }
        if let (sx, sy, amp) = spot {
            for dy in -2...2 { for dx in -2...2 {
                let x = sx + dx, y = sy + dy
                if x >= 0, y >= 0, x < w, y < h {
                    img.pixels[y * w + x] += amp * exp(-Float(dx * dx + dy * dy) / 2)
                }
            } }
        }
        return img
    }

    @Test func locatesSingleSpotWithSubpixelCentroid() {
        let base = synthetic(spot: nil)
        let frame = synthetic(spot: (40, 20, 150))
        let diff = ScanMath.difference(frame, base)
        let blob = ScanMath.locate(diff)
        #expect(blob != nil)
        #expect(abs(blob!.x - 40.0 / 63) < 0.02)
        #expect(abs(blob!.y - 20.0 / 47) < 0.02)
        #expect(blob!.confidence > 4)
        #expect(blob!.secondPeakRatio < 0.3)
    }

    @Test func returnsNilWhenNothingLit() {
        let base = synthetic(spot: nil)
        let frame = synthetic(spot: nil, noise: 3)
        #expect(ScanMath.locate(ScanMath.difference(frame, base)) == nil)
    }

    @Test func flagsAmbiguousWhenTwoFarSpots() {
        let base = synthetic(spot: nil)
        var frame = synthetic(spot: (10, 10, 150))
        let second = synthetic(spot: (55, 40, 120))
        for i in 0..<frame.pixels.count { frame.pixels[i] = max(frame.pixels[i], second.pixels[i]) }
        let blob = ScanMath.locate(ScanMath.difference(frame, base))
        #expect(blob != nil)
        #expect(blob!.secondPeakRatio > 0.6)
    }

    @Test func mapNearestRespectsAspectAndDistance() {
        let map = LEDMap(ledCount: 3, points: [
            0: LEDMapPoint(x: 0.1, y: 0.1, confidence: 9),
            1: LEDMapPoint(x: 0.5, y: 0.5, confidence: 9),
            2: LEDMapPoint(x: 0.9, y: 0.9, confidence: 9, ambiguous: true),
        ], createdAt: .now, cameraAspect: 1)
        #expect(map.nearest(to: 0.52, 0.5) == 1)
        #expect(map.nearest(to: 0.9, 0.9) == nil)      // неоднозначные не участвуют
        #expect(map.nearest(to: 0.3, 0.3) == nil)      // слишком далеко от всех
        #expect(map.foundCount == 2 && map.ambiguousCount == 1 && map.missingIndices.isEmpty)
    }
}
