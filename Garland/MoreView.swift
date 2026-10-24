import SwiftUI

/// «Ещё»: карта и сканирование, конструктор, таймер — и раздел разработчика со старыми экранами.
struct MoreView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showWLED = false
    @State private var showScan = false
    @State private var showTreeScan = false
    @State private var showMap = false
    @State private var showLegacy = false
    @State private var showLab = false
    @State private var showDiag = false
    @State private var showSchedule = false
    @State private var showText = false
    @State private var showConstructor = false

    var body: some View {
        NavigationStack {
            List {
                Section("Без телефона") {
                    Button { showSchedule = true } label: { Label("Расписание и плейлист", systemImage: "clock") }
                    Button { showText = true } label: { Label("Бегущий текст", systemImage: "textformat") }
                }
                Section("С телефона") {
                    Button { showConstructor = true } label: { Label("Конструктор эффектов", systemImage: "slider.horizontal.3") }
                }
                Section("Карта гирлянды") {
                    Button { showTreeScan = true } label: {
                        Label { Text("ЁЛКА — сканировать с 4 сторон").bold() } icon: { Image(systemName: "tree.fill").foregroundStyle(.green) }
                    }
                    Button { showScan = true } label: { Label("Плоская — окно, стена (1 ракурс)", systemImage: "rectangle.portrait") }
                    Button { showMap = true } label: { Label("Проверка карты и рисование", systemImage: "hand.tap") }
                    Button { showWLED = true } label: { Label("Загрузить карту в WLED, подключение", systemImage: "square.and.arrow.up.on.square") }
                }
                Section {
                    Button { showLegacy = true } label: { Label("Старый Bluetooth-контроллер", systemImage: "antenna.radiowaves.left.and.right") }
                    Button { showLab = true } label: { Label("Лаборатория пикселей (BLE)", systemImage: "flask") }
                    Button { showDiag = true } label: { Label("Диагностика BLE", systemImage: "waveform.path.ecg") }
                } header: { Text("Разработчик") } footer: {
                    Text("Экраны первого этапа: родная плата LEDDMX-00 по Bluetooth. Для гирлянды на ESP32 не нужны.")
                }
            }
            .navigationTitle("Ещё")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
            .sheet(isPresented: $showWLED) { WLEDView() }
            .sheet(isPresented: $showSchedule) { ScheduleView() }
            .sheet(isPresented: $showText) { TextEffectView() }
            .sheet(isPresented: $showConstructor) { ConstructorView() }
            .fullScreenCover(isPresented: $showScan) { ScanView() }
            .fullScreenCover(isPresented: $showTreeScan) { ScanView(treeMode: true) }
            .fullScreenCover(isPresented: $showMap) { MapView() }
            .fullScreenCover(isPresented: $showLegacy) { LegacyWrapper { ContentView() } }
            .sheet(isPresented: $showLab) { PixelLabView() }
            .sheet(isPresented: $showDiag) { DiagnosticsView() }
        }
    }
}

/// Обёртка с кнопкой «Закрыть» для старых полноэкранных экранов.
struct LegacyWrapper<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    @ViewBuilder var content: () -> Content
    var body: some View {
        ZStack(alignment: .topTrailing) {
            content()
            Button("Закрыть") { dismiss() }
                .buttonStyle(.bordered)
                .padding(.top, 54).padding(.trailing, 12)
        }
    }
}
