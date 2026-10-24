import Foundation
import Observation

/// Живое превью: WLED по WebSocket (`/ws`, запрос `{"lv":true}`) шлёт бинарные кадры
/// `'L', 1, RGB…` (1D) или `'L', 2, w, h, RGB…` (2D). Так телефон показывает, что прямо сейчас
/// горит на гирлянде, какой бы источник ни рисовал — эффект WLED, DDP или цвет.
@Observable
@MainActor
final class WLEDLiveView {
    private(set) var colors: [RGB] = []
    private(set) var is2D = false
    private(set) var width = 0
    private(set) var height = 0
    private(set) var connected = false

    private var task: URLSessionWebSocketTask?
    private var host: String?
    private var keepAlive: Task<Void, Never>?

    func start(host: String) {
        if self.host == host, task != nil { return }
        stop()
        self.host = host
        guard let url = URL(string: "ws://\(host)/ws") else { return }
        let t = URLSession.shared.webSocketTask(with: url)
        task = t
        t.resume()
        t.send(.string("{\"lv\":true}")) { _ in }
        receive()
        keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                self?.task?.send(.string("{\"lv\":true}")) { _ in }
            }
        }
    }

    func stop() {
        keepAlive?.cancel(); keepAlive = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        connected = false
    }

    private func receive() {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let msg):
                    self.connected = true
                    if case .data(let d) = msg { self.parse(d) }
                    self.receive()
                case .failure:
                    self.connected = false
                    // переподключимся через секунду, если хост ещё нужен
                    let h = self.host
                    self.task = nil
                    try? await Task.sleep(for: .seconds(1))
                    if let h, self.host == h, self.task == nil { self.start(host: h) }
                }
            }
        }
    }

    private func parse(_ d: Data) {
        guard d.count > 2, d[0] == 0x4C else { return }
        let bytes = [UInt8](d)
        var offset = 2
        if bytes[1] == 2, bytes.count > 4 {
            is2D = true; width = Int(bytes[2]); height = Int(bytes[3]); offset = 4
        } else {
            is2D = false
        }
        var out: [RGB] = []
        out.reserveCapacity((bytes.count - offset) / 3)
        var i = offset
        while i + 2 < bytes.count {
            out.append(RGB(red: bytes[i], green: bytes[i + 1], blue: bytes[i + 2]))
            i += 3
        }
        colors = out
    }
}
