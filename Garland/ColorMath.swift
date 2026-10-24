import SwiftUI

/// Преобразования HSV ⇄ RGB для колеса цвета. Яркость (V) в приложении — это программное
/// масштабирование RGB, поэтому колесо работает при V = 1, а V задаётся отдельным ползунком.
extension RGB {
    init(hue: Double, saturation: Double, value: Double = 1) {
        let h = (hue.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6
        let s = max(0, min(1, saturation))
        let v = max(0, min(1, value))
        let i = Int(h.rounded(.down)) % 6
        let f = h - h.rounded(.down)
        let p = v * (1 - s)
        let q = v * (1 - s * f)
        let t = v * (1 - s * (1 - f))
        let (r, g, b): (Double, Double, Double) = switch i {
        case 0: (v, t, p)
        case 1: (q, v, p)
        case 2: (p, v, t)
        case 3: (p, q, v)
        case 4: (t, p, v)
        default: (v, p, q)
        }
        self.init(red: UInt8((r * 255).rounded()),
                  green: UInt8((g * 255).rounded()),
                  blue: UInt8((b * 255).rounded()))
    }

    /// (hue 0...1, saturation 0...1, value 0...1)
    var hsv: (hue: Double, saturation: Double, value: Double) {
        let r = Double(red) / 255, g = Double(green) / 255, b = Double(blue) / 255
        let maxC = max(r, g, b), minC = min(r, g, b)
        let delta = maxC - minC
        var h = 0.0
        if delta > 0 {
            if maxC == r { h = (g - b) / delta }
            else if maxC == g { h = 2 + (b - r) / delta }
            else { h = 4 + (r - g) / delta }
            h /= 6
            if h < 0 { h += 1 }
        }
        let s = maxC == 0 ? 0 : delta / maxC
        return (h, s, maxC)
    }

    var swiftUIColor: Color {
        Color(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
    }
}

/// Колесо «оттенок × насыщенность». Угол — оттенок, радиус — насыщенность.
struct HueSaturationWheel: View {
    @Binding var hue: Double
    @Binding var saturation: Double
    var onChanged: () -> Void
    var onEnded: () -> Void

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let radius = size / 2
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ZStack {
                Circle()
                    .fill(AngularGradient(
                        colors: [.red, .yellow, .green, .cyan, .blue, Color(red: 1, green: 0, blue: 1), .red],
                        center: .center))
                Circle()
                    .fill(RadialGradient(colors: [.white, .white.opacity(0)],
                                         center: .center, startRadius: 0, endRadius: radius))
                Circle()
                    .strokeBorder(.white.opacity(0.15), lineWidth: 1)

                let angle = hue * 2 * .pi
                let knob = CGPoint(x: center.x + cos(angle) * radius * saturation,
                                   y: center.y + sin(angle) * radius * saturation)
                Circle()
                    .fill(RGB(hue: hue, saturation: saturation).swiftUIColor)
                    .frame(width: 30, height: 30)
                    .overlay(Circle().stroke(.white, lineWidth: 3))
                    .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                    .position(knob)
            }
            .frame(width: size, height: size)
            .position(center)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        update(value.location, center: center, radius: radius)
                        onChanged()
                    }
                    .onEnded { value in
                        update(value.location, center: center, radius: radius)
                        onEnded()
                    }
            )
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("Колесо цвета")
    }

    private func update(_ p: CGPoint, center: CGPoint, radius: CGFloat) {
        let dx = p.x - center.x, dy = p.y - center.y
        var a = atan2(dy, dx) / (2 * .pi)
        if a < 0 { a += 1 }
        hue = a
        saturation = min(1, hypot(dx, dy) / radius)
    }
}
