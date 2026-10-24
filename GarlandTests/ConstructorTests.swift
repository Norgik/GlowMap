import Testing
import Foundation
@testable import Garland

struct ConstructorTests {

    @Test func paletteIsCyclicAndHitsStops() {
        let cols: [RGB] = [.red, .green, .blue]
        #expect(ConstructorMath.palette(cols, 0) == .red)
        #expect(ConstructorMath.palette(cols, 1.0 / 3) == .green)
        #expect(ConstructorMath.palette(cols, 2.0 / 3) == .blue)
        #expect(ConstructorMath.palette(cols, 1) == .red)              // период 1
        #expect(ConstructorMath.palette(cols, -1.0 / 3) == .blue)      // отрицательные тоже
        let mid = ConstructorMath.palette([.black, .white], 0.25)
        #expect(mid == RGB(red: 128, green: 128, blue: 128))
    }

    @Test func stripesAreHardWithoutSoftness() {
        let cols: [RGB] = [.red, .white]
        #expect(ConstructorMath.stripes(cols, phase: 0.1, softness: 0) == .red)
        #expect(ConstructorMath.stripes(cols, phase: 0.6, softness: 0) == .white)
        #expect(ConstructorMath.stripes(cols, phase: 1.1, softness: 0) == .red)
        // с мягкостью у границы — смесь
        let edge = ConstructorMath.stripes(cols, phase: 0.49, softness: 0.3)
        #expect(edge != .red && edge != .white)
    }

    @Test func gradientMovesWithTimeAndAngle() {
        var s = ConstructorSpec(base: .gradient, colors: [.black, .white], angle: 0, speed: 1, zoom: 1, sparkles: false)
        let a = ConstructorMath.baseColor(s, x: 0.2, y: 0.5, aspect: 1, t: 0)
        let b = ConstructorMath.baseColor(s, x: 0.2, y: 0.5, aspect: 1, t: 0.25)
        #expect(a != b)
        // поворот на 90°: зависимость только от y
        s.angle = .pi / 2
        let c1 = ConstructorMath.baseColor(s, x: 0.1, y: 0.3, aspect: 1, t: 0)
        let c2 = ConstructorMath.baseColor(s, x: 0.9, y: 0.3, aspect: 1, t: 0)
        #expect(c1 == c2)
    }

    @Test func ringsAreRadiallySymmetric() {
        let s = ConstructorSpec(base: .rings, colors: [.red, .blue], zoom: 2, sparkles: false)
        let a = ConstructorMath.baseColor(s, x: 0.5 + 0.2, y: 0.5, aspect: 1, t: 0)
        let b = ConstructorMath.baseColor(s, x: 0.5, y: 0.5 + 0.2, aspect: 1, t: 0)
        #expect(a == b)
    }

    @Test func colorBlendIgnoresPosition() {
        let s = ConstructorSpec(base: .colorBlend, colors: [.red, .green], speed: 0.5, sparkles: false)
        let a = ConstructorMath.baseColor(s, x: 0.1, y: 0.1, aspect: 1, t: 0.4)
        let b = ConstructorMath.baseColor(s, x: 0.9, y: 0.9, aspect: 1, t: 0.4)
        #expect(a == b)
    }

    @Test func specRoundTripsThroughJSON() throws {
        let s = ConstructorSpec.presets[0].spec
        let d = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(ConstructorSpec.self, from: d)
        #expect(back == s)
    }
}
