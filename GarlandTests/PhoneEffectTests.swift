import Testing
import Foundation
@testable import Garland

struct PhoneEffectTests {

    @Test func rainbowCyclesThroughHuesAndStaysSaturated() {
        let r0 = PhoneEffect.rainbowColor(t: 0, speed: 1)
        #expect(r0 == RGB(red: 255, green: 0, blue: 0))
        // Через треть периода (12 с при speed 1) — зелёный.
        #expect(PhoneEffect.rainbowColor(t: 4, speed: 1) == RGB(red: 0, green: 255, blue: 0))
        #expect(PhoneEffect.rainbowColor(t: 8, speed: 1) == RGB(red: 0, green: 0, blue: 255))
        // Скорость 2 вдвое быстрее.
        #expect(PhoneEffect.rainbowColor(t: 2, speed: 2) == PhoneEffect.rainbowColor(t: 4, speed: 1))
        for t in stride(from: 0.0, through: 24, by: 0.37) {
            let c = PhoneEffect.rainbowColor(t: t, speed: 1)
            #expect(max(c.red, c.green, c.blue) == 255) // всегда полная насыщенность и яркость
        }
    }

    @Test func breathingStaysWithinRangeAndIsPeriodic() {
        var minF = 1.0, maxF = 0.0
        for t in stride(from: 0.0, through: 10, by: 0.01) {
            let f = PhoneEffect.breathingFactor(t: t, speed: 1)
            minF = min(minF, f); maxF = max(maxF, f)
        }
        #expect(abs(minF - 0.08) < 0.001)
        #expect(abs(maxF - 1.0) < 0.001)
        #expect(abs(PhoneEffect.breathingFactor(t: 1.3, speed: 1) - PhoneEffect.breathingFactor(t: 6.3, speed: 1)) < 1e-9)
        // Начинается с минимума — гирлянда «вдыхает», а не вспыхивает.
        #expect(PhoneEffect.breathingFactor(t: 0, speed: 1) < 0.1)
    }

    @Test func candleNeverExceedsBaseAndStaysWarm() {
        var state = PhoneEffect.CandleState()
        let base = PhoneEffect.candle.defaultBase
        var t = 0.0
        for _ in 0..<2000 {
            let s = state.step(t: t, dt: 0.05, speed: 1)
            t += 0.05
            #expect(s.factor > 0.2 && s.factor <= 1.0)
            let c = PhoneEffect.candleColor(base: base, factor: s.factor, warmth: s.warmth)
            #expect(c.red <= base.red && c.green <= base.green && c.blue <= base.blue)
            #expect(c.red >= c.green && c.green >= c.blue) // пламя остаётся тёплым
        }
    }
}
