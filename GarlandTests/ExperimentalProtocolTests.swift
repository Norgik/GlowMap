import Testing
import Foundation
@testable import Garland

/// Проверяем только раскладку байтов относительно открытых реализаций.
/// Работу команд на гирлянде эти тесты НЕ подтверждают.
struct ExperimentalProtocolTests {
    typealias X = GarlandProtocol.Experimental

    @Test func stripConfigMatchesLedUnionLayout() {
        // spiConfigFrame: 7B FF 05 04 hi lo order FF BF; 200 = 0x00C8, RGB = 1
        #expect(X.stripConfig(pixels: 200, order: .rgb).hexString == "7BFF050400C801FFBF")
        #expect(X.stripConfig(pixels: 1, order: .rgb).hexString == "7BFF0504000101FFBF")
        #expect(X.stripConfig(pixels: 300, order: .grb).hexString == "7BFF0504012C03FFBF")
        #expect(X.stripConfig(pixels: 0, order: .rgb)[5] == 1) // минимум 1 пиксель
    }

    @Test func speedAndDirection() {
        #expect(X.speed(percent: 50).hexString == "7BFF0232FF00FFFFBF")
        #expect(X.speed(percent: 500)[3] == 100)
        #expect(X.direction(forward: true).hexString == "7BFF0D01FFFFFFFFBF")
        #expect(X.direction(forward: false).hexString == "7BFF0D00FFFFFFFFBF")
    }

    @Test func diyPaletteMatchesBothReferences() {
        // user154lt: 7B pos 0E FD R G B total BF; LED_UNION (dmx): 7B idx 0E mode R G B total BF
        #expect(X.diyColor(position: 1, total: 3, color: .red, fade: false).hexString == "7B010EFDFF000003BF")
        #expect(X.diyColor(position: 2, total: 3, color: .green, fade: true).hexString == "7B020EFE00FF0003BF")
        #expect(X.diyStart().hexString == "7BFF0F01FFFFFFFFBF")
        #expect(X.diyMode(3).hexString == "7BFF1303FFFFFFFFBF")
        #expect(X.diyMode(99)[3] == 7)
        #expect(X.diyModeNames.count == 8)
    }

    @Test func passwordQueryFrame() {
        #expect(X.passwordStatusQuery().hexString == "2A05FFFFFFFFFFFFAF")
    }

    @Test func graffitiMatchesLedLamp437() {
        // setDmx0204Graffiti → {124, mode, r, g, b, hi, lo, 255, 207}; пиксель 0-based, big-endian
        #expect(X.graffiti(mode: .paint, color: .red, pixel: 0).hexString == "7C00FF00000000FFCF")
        #expect(X.graffiti(mode: .paint, color: .blue, pixel: 5).hexString == "7C000000FF0005FFCF")
        #expect(X.graffiti(mode: .erase, color: .black, pixel: 199).hexString == "7C0100000000C7FFCF")
        #expect(X.graffiti(mode: .clear, color: .black, pixel: 200).hexString == "7C0200000000C8FFCF")
        #expect(X.graffiti(mode: .paint, color: .white, pixel: 300)[5] == 0x01 && X.graffiti(mode: .paint, color: .white, pixel: 300)[6] == 0x2C)
        #expect(X.dmx0204ClearColor().hexString == "7B0E0000000000FFBF")
    }

    @Test func dmx00OnlyFramesFromLedLamp() {
        #expect(X.subarea(2).hexString == "7BFF1402FFFFFFFFBF")
        #expect(X.subarea(9)[3] == 2)
        #expect(X.auxiliary(3).hexString == "7BFF1103FFFFFFFFBF")
    }

    @Test func allExperimentalFramesAreNineBytes() {
        let frames: [Data] = [
            X.stripConfig(pixels: 200, order: .rgb), X.speed(percent: 10), X.direction(forward: true),
            X.diyColor(position: 1, total: 1, color: .white, fade: false), X.diyStart(), X.diyMode(0),
            X.passwordStatusQuery(), X.graffiti(mode: .paint, color: .red, pixel: 1), X.dmx0204ClearColor(),
            X.subarea(0), X.auxiliary(0),
        ]
        for f in frames { #expect(f.count == 9) }
    }
}
