import SwiftUI

/// Бегущий текст средствами WLED (эффект Scrolling Text). Нужен 2D-режим; шрифт WLED — латиница и цифры.
struct TextEffectView: View {
    @Environment(WLEDClient.self) private var wled
    @Environment(\.dismiss) private var dismiss
    @State private var text = "HELLO"
    @State private var color: RGB = .white
    @State private var speed = 128.0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Текст (латиница, цифры)", text: $text)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    HStack {
                        Text("Цвет")
                        Spacer()
                        ForEach([RGB.white, .red, RGB(red: 255, green: 160, blue: 0), .green, RGB(red: 0, green: 180, blue: 255), RGB(red: 255, green: 60, blue: 160)], id: \.self) { c in
                            Button { color = c } label: {
                                Circle().fill(c.swiftUIColor).frame(width: 26, height: 26)
                                    .overlay(Circle().stroke(.white, lineWidth: color == c ? 2 : 0))
                            }.buttonStyle(.plain)
                        }
                    }
                    HStack { Image(systemName: "tortoise"); Slider(value: $speed, in: 20...255); Image(systemName: "hare") }
                    Button("Показать на гирлянде") {
                        Task { await wled.showText(latinOnly(text), color: color, speed: Int(speed)) }
                    }
                    .disabled(!wled.isReady || latinOnly(text).isEmpty)
                } footer: {
                    if case .map2D(let w, let h) = wled.addressingMode {
                        Text("Матрица \(w)×\(h): текст бежит по горизонтали, высота букв ~8 ячеек. На редкой гирлянде буквы читаются, если сетка не меньше 8 по высоте. Кириллица шрифтом WLED не поддерживается — заменяется латиницей.")
                    } else {
                        Text("Нужна загруженная карта (2D-режим): «⋯ → Карта → Загрузить карту в WLED».")
                    }
                }
            }
            .navigationTitle("Текст")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
        }
    }

    /// Простая транслитерация: шрифт WLED знает только ASCII.
    private func latinOnly(_ s: String) -> String {
        let map: [Character: String] = ["а":"A","б":"B","в":"V","г":"G","д":"D","е":"E","ё":"E","ж":"ZH","з":"Z","и":"I","й":"Y","к":"K","л":"L","м":"M","н":"N","о":"O","п":"P","р":"R","с":"S","т":"T","у":"U","ф":"F","х":"H","ц":"TS","ч":"CH","ш":"SH","щ":"SCH","ъ":"","ы":"Y","ь":"","э":"E","ю":"YU","я":"YA"]
        var out = ""
        for ch in s.uppercased() {
            let lower = Character(ch.lowercased())
            if let t = map[lower] { out += t }
            else if ch.isASCII { out.append(ch) }
        }
        return out
    }
}
