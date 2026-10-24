import SwiftUI

/// Встроенные эффекты контроллера (бегущие огни, переливы и т. д.). Контроллер не сообщает,
/// что делает каждый индекс, поэтому пользователь перебирает их и подписывает сам.
struct EffectsSection: View {
    @Environment(BluetoothManager.self) private var bt
    @Environment(PhoneEffectEngine.self) private var engine
    @Environment(SavedColorsStore.self) private var store

    /// Сколько эффектов показывать плитками; остальные — через стрелки.
    private let quickCount = 24
    @State private var renaming: Int?
    @State private var renameText = ""
    @State private var showAll = false

    private var current: Int? { bt.requested.mode.effectIndex }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Эффекты контроллера").font(.headline)
                Spacer()
                Button(showAll ? "Свернуть" : "Все 211") { withAnimation { showAll.toggle() } }
                    .font(.subheadline)
            }

            browser

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 8)], spacing: 8) {
                ForEach(Array(visibleIndices), id: \.self) { index in
                    tile(index)
                }
            }
        }
        .alert("Название эффекта", isPresented: Binding(get: { renaming != nil },
                                                        set: { if !$0 { renaming = nil } })) {
            TextField("Например, бегущие огни", text: $renameText)
            Button("Сохранить") {
                if let i = renaming { store.renameEffect(i, to: renameText) }
                renaming = nil
            }
            Button("Отмена", role: .cancel) { renaming = nil }
        } message: {
            if let i = renaming { Text("Эффект №\(i). Пустое название сбросит подпись.") }
        }
    }

    private var visibleIndices: ClosedRange<Int> {
        showAll ? GarlandProtocol.effectRange : 1...quickCount
    }

    /// Строка «текущий эффект» со стрелками — так удобнее всего перебирать и подписывать.
    private var browser: some View {
        HStack(spacing: 12) {
            Button { step(-1) } label: { Image(systemName: "chevron.left").frame(width: 36, height: 36) }
                .disabled(!bt.isReady)
            VStack(spacing: 2) {
                Text(current.map { store.effectName($0) } ?? "Статический цвет")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(current.map { "№\($0) из \(GarlandProtocol.effectRange.upperBound)" + (bt.requested.effectPaused ? " · пауза" : "") } ?? "выберите эффект")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { if let c = current { beginRename(c) } }
            if current != nil {
                Button { bt.setEffectPaused(!bt.requested.effectPaused) } label: {
                    Image(systemName: bt.requested.effectPaused ? "play.fill" : "pause.fill")
                        .frame(width: 36, height: 36)
                }
                .disabled(!bt.isReady)
                .accessibilityLabel(bt.requested.effectPaused ? "Продолжить эффект" : "Пауза эффекта")
            }
            Button { step(+1) } label: { Image(systemName: "chevron.right").frame(width: 36, height: 36) }
                .disabled(!bt.isReady)
        }
        .buttonStyle(.bordered)
        .padding(8)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func tile(_ index: Int) -> some View {
        let selected = current == index
        let custom = store.effectNames[index] != nil
        return Button { select(index) } label: {
            VStack(spacing: 3) {
                Image(systemName: custom ? "sparkles" : "number")
                    .font(.caption)
                Text(custom ? store.effectName(index) : "\(index)")
                    .font(.caption2)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, 4)
            .background(selected ? AnyShapeStyle(.tint.opacity(0.35)) : AnyShapeStyle(.white.opacity(0.06)),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(selected ? Color.accentColor : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { beginRename(index) } label: { Label("Переименовать", systemImage: "pencil") }
        }
        .accessibilityLabel(store.effectName(index))
    }

    private func step(_ delta: Int) {
        let range = GarlandProtocol.effectRange
        let next = (current ?? 0) + delta
        let wrapped = next > range.upperBound ? range.lowerBound + 1
                    : next < range.lowerBound + 1 ? range.upperBound : next
        select(wrapped)
    }

    /// Встроенный эффект контроллера и эффект телефона не могут работать одновременно.
    private func select(_ index: Int) {
        engine.stop()
        bt.requestEffect(index)
    }

    private func beginRename(_ index: Int) {
        renameText = store.effectNames[index] ?? ""
        renaming = index
    }
}
