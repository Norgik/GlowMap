import Foundation

/// Превращает камерную карту в 2D-сетку для WLED (`ledmap.json` с width/height и −1 в пустых
/// ячейках). После загрузки встроенные 2D-эффекты WLED идут по реальной форме гирлянды
/// автономно, без телефона.
enum LedmapExport {

    struct Grid: Equatable {
        var width: Int
        var height: Int
        /// width*height значений: индекс LED или −1.
        var cells: [Int]
        var placed: Int        // сколько LED получили ячейку
        var collisions: Int    // сколько LED не поместились (ячейка занята)
    }

    /// Подбирает сетку: минимальная высота, при которой почти каждый пригодный LED получает свою
    /// ячейку. Ширина следует пропорциям кадра. Ограничение по размеру — память ESP32.
    static func grid(from map: LEDMap, maxCells: Int = 2048, maxCollisionShare: Double = 0.03) -> Grid {
        let pts = map.reliable
        guard !pts.isEmpty else { return Grid(width: 1, height: 1, cells: [-1], placed: 0, collisions: 0) }
        // Обрезаем пустые поля: сетка строится по габаритам найденных точек с небольшим запасом
        let xs = pts.map(\.point.x), ys = pts.map(\.point.y)
        let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
        let spanX = max(0.02, maxX - minX) * map.cameraAspect, spanY = max(0.02, maxY - minY)
        var best: Grid?
        for h in 4...96 {
            let w = max(1, Int((Double(h) * spanX / spanY).rounded()))
            if w * h > maxCells { break }
            let g = layout(pts, w: w, h: h, minX: minX, maxX: maxX, minY: minY, maxY: maxY)
            best = g
            if Double(g.collisions) <= Double(pts.count) * maxCollisionShare { break }
        }
        return best!
    }

    static func layout(_ pts: [(index: Int, point: LEDMapPoint)], w: Int, h: Int,
                       minX: Double, maxX: Double, minY: Double, maxY: Double) -> Grid {
        var cells = Array(repeating: -1, count: w * h)
        var placed = 0, collisions = 0
        func cell(_ p: LEDMapPoint) -> Int {
            let fx = (p.x - minX) / max(1e-9, maxX - minX), fy = (p.y - minY) / max(1e-9, maxY - minY)
            let cx = min(w - 1, max(0, Int(fx * Double(w - 1) + 0.5)))
            let cy = min(h - 1, max(0, Int(fy * Double(h - 1) + 0.5)))
            return cy * w + cx
        }
        // Сначала измеренные, затем достроенные — у измеренных приоритет на ячейку
        let ordered = pts.sorted { ($0.point.estimated ? 1 : 0, $0.index) < ($1.point.estimated ? 1 : 0, $1.index) }
        for (i, p) in ordered {
            let c = cell(p)
            if cells[c] == -1 { cells[c] = i; placed += 1; continue }
            // ячейка занята — пробуем 8 соседей
            let cx = c % w, cy = c / w
            var done = false
            for dy in -1...1 where !done { for dx in -1...1 where !done {
                let nx = cx + dx, ny = cy + dy
                if nx >= 0, ny >= 0, nx < w, ny < h, cells[ny * w + nx] == -1 {
                    cells[ny * w + nx] = i; placed += 1; done = true
                }
            } }
            if !done { collisions += 1 }
        }
        return Grid(width: w, height: h, cells: cells, placed: placed, collisions: collisions)
    }

    /// JSON без лишних пробелов — парсер WLED к ним чувствителен.
    static func json(_ g: Grid) -> Data {
        let body = "{\"width\":\(g.width),\"height\":\(g.height),\"map\":[" +
            g.cells.map(String.init).joined(separator: ",") + "]}"
        return Data(body.utf8)
    }
}
