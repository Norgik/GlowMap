import SwiftUI

@main
struct GarlandApp: App {
    @State private var bluetooth: BluetoothManager
    @State private var engine: PhoneEffectEngine
    @State private var store = SavedColorsStore()
    @State private var wled: WLEDClient
    @State private var mapStore = LEDMapStore()
    @State private var lightScenes = LightSceneStore()
    @State private var constructor: ConstructorEngine

    init() {
        let bt = BluetoothManager()
        let w = WLEDClient()
        let e = PhoneEffectEngine(bluetooth: bt)
        e.wled = w
        _bluetooth = State(initialValue: bt)
        _wled = State(initialValue: w)
        _engine = State(initialValue: e)
        _constructor = State(initialValue: ConstructorEngine(wled: w, map: LEDMapStore().map))
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(bluetooth)
                .environment(engine)
                .environment(store)
                .environment(wled)
                .environment(mapStore)
                .environment(lightScenes)
                .environment(constructor)
                .preferredColorScheme(.dark)
        }
    }
}
