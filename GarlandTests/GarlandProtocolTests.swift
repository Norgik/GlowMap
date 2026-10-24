import Testing
import Foundation
@testable import Garland

struct GarlandProtocolTests {

    // Три команды, проверенные вручную через nRF Connect на LEDDMX-00-698A.

    @Test func redMatchesVerifiedPacket() {
        #expect(GarlandProtocol.color(red: 255, green: 0, blue: 0).hexString == "7BFF07FF000000FFBF")
    }

    @Test func greenMatchesVerifiedPacket() {
        #expect(GarlandProtocol.color(red: 0, green: 255, blue: 0).hexString == "7BFF0700FF0000FFBF")
    }

    @Test func blueMatchesVerifiedPacket() {
        #expect(GarlandProtocol.color(red: 0, green: 0, blue: 255).hexString == "7BFF070000FF00FFBF")
    }

    @Test func colorPacketIsAlwaysNineBytes() {
        for r in stride(from: 0, through: 255, by: 51) {
            for g in stride(from: 0, through: 255, by: 85) {
                for b in [0, 127, 255] {
                    let packet = GarlandProtocol.color(red: UInt8(r), green: UInt8(g), blue: UInt8(b))
                    #expect(packet.count == 9)
                    #expect(packet[0] == 0x7B && packet[1] == 0xFF && packet[2] == 0x07)
                    #expect(packet[3] == UInt8(r) && packet[4] == UInt8(g) && packet[5] == UInt8(b))
                    #expect(packet[6] == 0x00 && packet[7] == 0xFF && packet[8] == 0xBF)
                }
            }
        }
    }

    @Test func channelOrderIsRGBNotGRB() {
        // Защита от «исправления» порядка каналов по чужим реализациям.
        let packet = GarlandProtocol.color(red: 1, green: 2, blue: 3)
        #expect(Array(packet[3...5]) == [1, 2, 3])
    }

    @Test func bytesAreBinaryNotUTF8Hex() {
        let packet = GarlandProtocol.color(red: 255, green: 0, blue: 0)
        #expect(packet != Data("7BFF07FF000000FFBF".utf8))
        #expect(packet.count == 9)
    }

    // Команды, проверенные на гирлянде через приложение 22.10.2026.

    @Test func powerPackets() {
        #expect(GarlandProtocol.powerOn().hexString == "7BFF0403FFFFFFFFBF")
        #expect(GarlandProtocol.powerOff().hexString == "7BFF0402FFFFFFFFBF")
        #expect(GarlandProtocol.power(true) == GarlandProtocol.powerOn())
        #expect(GarlandProtocol.power(false) == GarlandProtocol.powerOff())
    }

    @Test func brightnessFiftyPercentMatchesReference() {
        #expect(GarlandProtocol.brightness(percent: 50).hexString == "7BFF01103200FFFFBF")
    }

    @Test func brightnessClampsAndIsNineBytes() {
        #expect(GarlandProtocol.brightness(percent: 150).hexString == "7BFF01206400FFFFBF")
        #expect(GarlandProtocol.brightness(percent: -5).hexString == "7BFF01000000FFFFBF")
        for p in stride(from: 0, through: 100, by: 7) {
            let packet = GarlandProtocol.brightness(percent: p)
            #expect(packet.count == 9)
            #expect(Int(packet[3]) == p * 32 / 100)
            #expect(Int(packet[4]) == p)
        }
    }

    @Test func effectPausePackets() {
        #expect(GarlandProtocol.effectPaused(true).hexString == "7BFF0601FFFFFFFFBF")
        #expect(GarlandProtocol.effectPaused(false).hexString == "7BFF0600FFFFFFFFBF")
    }

    @Test func effectPacket() {
        #expect(GarlandProtocol.effect(index: 5).hexString == "7BFF0305FFFFFFFFBF")
        #expect(GarlandProtocol.effect(index: 999)[3] == 210)
        #expect(GarlandProtocol.effect(index: -1)[3] == 0)
        #expect(GarlandProtocol.effect(index: 1).count == 9)
    }

    // Вспомогательные функции.

    @Test func hexParsingRoundTrip() {
        let data = Data(hexString: "7B FF 07 ff 00 00 00 FF BF")
        #expect(data?.hexString == "7BFF07FF000000FFBF")
        #expect(Data(hexString: "7BF") == nil)
        #expect(Data(hexString: "ZZ") == nil)
        #expect(Data(hexString: "") == nil)
    }

    @Test func scaledBrightnessKeepsRatio() {
        let half = RGB(red: 255, green: 100, blue: 0).scaled(by: 0.5)
        #expect(half == RGB(red: 128, green: 50, blue: 0))
        #expect(RGB.white.scaled(by: 0) == .black)
        #expect(RGB.white.scaled(by: 2) == .white)
    }
}
