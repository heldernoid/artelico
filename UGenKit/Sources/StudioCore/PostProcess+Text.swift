import CoreGraphics
import Foundation

extension PostProcess {
    /// The recogniser's character set after the CTC blank (class 0), from `CHARACTERS` in hailo-apps'
    /// paddle_ocr_utils.py: ASCII '0'...'~', then '!'...'/', then two classes that both decode to a space.
    /// Class `n` (n >= 1) is the character at offset `n - 1`.
    static let textCharacters: [Character] = Array(
        ##"0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\]^_`abcdefghijklmnopqrstuvwxyz{|}~!"#$%&'()*+,-./  "##
    )

    /// Text regions from the detector's probability map (ocr_det), after PaddleOCR's DB post-process
    /// (hailo-apps' db_postprocess.py, `boxes_from_bitmap` with the "fast" score).
    ///
    /// The map is thresholded, split into 8-connected regions, and each region gets its minimum-area
    /// rotated rectangle. A region is kept when the mean probability inside that rectangle reaches
    /// `boxThreshold`; the rectangle is then grown on every side by area * `unclipRatio` / perimeter.
    /// Corners are returned top-left, top-right, bottom-right, bottom-left; regions are ordered in
    /// reading order (lines top to bottom, left to right within a line).
    public static func textRegions(_ tensor: Tensor, frame: PreparedFrame, threshold: Float = 0.3, boxThreshold: Float = 0.6,
                                   unclipRatio: Float = 1.5, maxCandidates: Int = 1000) -> [TextRegion] {
        let width = tensor.width, height = tensor.height
        let probability = tensor.floats()
        guard width > 0, height > 0, probability.count >= width * height else { return [] }
        let minimumSide: Double = 3

        var visited = [Bool](repeating: false, count: width * height)
        var stack: [Int] = []
        var rowMin = [Int](repeating: 0, count: height)
        var rowMax = [Int](repeating: 0, count: height)
        var found: [(corners: [CGPoint], score: Float, center: CGPoint, height: CGFloat)] = []
        var candidates = 0

        for start in 0..<(width * height) where !visited[start] && probability[start] > threshold {
            // Flood-fill one 8-connected region, keeping the leftmost and rightmost pixel of each row:
            // those are enough to build the region's convex hull.
            visited[start] = true
            stack.append(start)
            var top = start / width, bottom = top
            rowMin[top] = start % width
            rowMax[top] = start % width
            while let pixel = stack.popLast() {
                let x = pixel % width, y = pixel / width
                for ny in max(y - 1, 0)...min(y + 1, height - 1) {
                    for nx in max(x - 1, 0)...min(x + 1, width - 1) {
                        let neighbour = ny * width + nx
                        guard !visited[neighbour], probability[neighbour] > threshold else { continue }
                        visited[neighbour] = true
                        stack.append(neighbour)
                        if ny < top { top = ny; rowMin[ny] = nx; rowMax[ny] = nx }
                        else if ny > bottom { bottom = ny; rowMin[ny] = nx; rowMax[ny] = nx }
                        else { rowMin[ny] = min(rowMin[ny], nx); rowMax[ny] = max(rowMax[ny], nx) }
                    }
                }
            }
            candidates += 1
            if candidates > maxCandidates { break }

            var outline: [(x: Double, y: Double)] = []
            outline.reserveCapacity(2 * (bottom - top + 1))
            for y in top...bottom {
                outline.append((Double(rowMin[y]), Double(y)))
                if rowMax[y] != rowMin[y] { outline.append((Double(rowMax[y]), Double(y))) }
            }
            guard let box = minimumAreaRectangle(outline), min(box.halfWidth, box.halfHeight) * 2 >= minimumSide else { continue }

            // Mean probability of the pixels inside the rectangle.
            let extentX = abs(box.axis.x) * box.halfWidth + abs(box.axis.y) * box.halfHeight
            let extentY = abs(box.axis.y) * box.halfWidth + abs(box.axis.x) * box.halfHeight
            let x0 = min(max(Int((box.center.x - extentX).rounded(.down)), 0), width - 1)
            let x1 = min(max(Int((box.center.x + extentX).rounded(.up)), 0), width - 1)
            let y0 = min(max(Int((box.center.y - extentY).rounded(.down)), 0), height - 1)
            let y1 = min(max(Int((box.center.y + extentY).rounded(.up)), 0), height - 1)
            var sum: Float = 0, count = 0
            for y in y0...y1 {
                for x in x0...x1 {
                    let dx = Double(x) - box.center.x, dy = Double(y) - box.center.y
                    guard abs(dx * box.axis.x + dy * box.axis.y) <= box.halfWidth + 0.5,
                          abs(dy * box.axis.x - dx * box.axis.y) <= box.halfHeight + 0.5 else { continue }
                    sum += probability[y * width + x]
                    count += 1
                }
            }
            let score = count > 0 ? sum / Float(count) : 0
            guard score >= boxThreshold else { continue }

            // "Unclip": offsetting a rectangle outward by a distance and boxing the result again
            // is the same rectangle with that distance added on every side.
            let boxWidth = 2 * box.halfWidth, boxHeight = 2 * box.halfHeight
            let grow = boxWidth * boxHeight * Double(unclipRatio) / (2 * (boxWidth + boxHeight))
            let halfWidth = box.halfWidth + grow, halfHeight = box.halfHeight + grow
            guard min(halfWidth, halfHeight) * 2 >= minimumSide + 2 else { continue }

            var corners: [(x: Double, y: Double)] = []
            for (sx, sy) in [(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)] {
                let x = box.center.x + sx * halfWidth * box.axis.x - sy * halfHeight * box.axis.y
                let y = box.center.y + sx * halfWidth * box.axis.y + sy * halfHeight * box.axis.x
                corners.append((min(max(x, 0), Double(width)), min(max(y, 0), Double(height))))
            }
            // The reference's corner order: of the two leftmost corners the upper one is top-left,
            // of the two rightmost the upper one is top-right.
            corners.sort { $0.x < $1.x }
            let leftUpper = corners[0].y <= corners[1].y ? 0 : 1
            let rightUpper = corners[2].y <= corners[3].y ? 2 : 3
            let ordered = [corners[leftUpper], corners[rightUpper], corners[5 - rightUpper], corners[1 - leftUpper]]
            let mapped = ordered.map { frame.toSource(x: CGFloat($0.x), y: CGFloat($0.y)) }
            let center = CGPoint(x: mapped.reduce(0) { $0 + $1.x } / 4, y: mapped.reduce(0) { $0 + $1.y } / 4)
            let regionHeight = ((mapped[3].y - mapped[0].y) + (mapped[2].y - mapped[1].y)) / 2
            found.append((mapped, score, center, max(regionHeight, 0)))
        }

        // Reading order: walk down by centre, start a new line when a region's centre lies more than
        // half its height below the current line, and order each line from left to right.
        found.sort { $0.center.y < $1.center.y }
        var regions: [TextRegion] = []
        var line: [(corners: [CGPoint], score: Float, center: CGPoint, height: CGFloat)] = []
        func flush() {
            for item in line.sorted(by: { $0.center.x < $1.center.x }) {
                regions.append(TextRegion(corners: item.corners, confidence: item.score))
            }
            line.removeAll()
        }
        var lineY: CGFloat = 0
        for item in found {
            if !line.isEmpty, item.center.y - lineY > 0.5 * min(item.height, line[0].height) { flush() }
            if line.isEmpty { lineY = item.center.y }
            line.append(item)
        }
        flush()
        return regions
    }

    /// The smallest rotated rectangle around `points`: its centre, the unit vector along its width
    /// (the side closest to horizontal), and half its width and height. Nil for fewer than three
    /// points or points on one line.
    static func minimumAreaRectangle(_ points: [(x: Double, y: Double)])
        -> (center: (x: Double, y: Double), axis: (x: Double, y: Double), halfWidth: Double, halfHeight: Double)? {
        // Convex hull (monotone chain).
        let sorted = points.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        guard sorted.count >= 3 else { return nil }
        func cross(_ o: (x: Double, y: Double), _ a: (x: Double, y: Double), _ b: (x: Double, y: Double)) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var hull: [(x: Double, y: Double)] = []
        for point in sorted {
            while hull.count >= 2, cross(hull[hull.count - 2], hull[hull.count - 1], point) <= 0 { hull.removeLast() }
            hull.append(point)
        }
        let lowerCount = hull.count + 1
        for point in sorted.dropLast().reversed() {
            while hull.count >= lowerCount, cross(hull[hull.count - 2], hull[hull.count - 1], point) <= 0 { hull.removeLast() }
            hull.append(point)
        }
        hull.removeLast()
        guard hull.count >= 3 else { return nil }

        // The minimum-area rectangle has a side along one of the hull's edges.
        var best: (area: Double, ux: Double, uy: Double, lowU: Double, highU: Double, lowV: Double, highV: Double)?
        for i in hull.indices {
            let a = hull[i], b = hull[(i + 1) % hull.count]
            let length = ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)).squareRoot()
            guard length > 0 else { continue }
            let ux = (b.x - a.x) / length, uy = (b.y - a.y) / length
            var lowU = Double.infinity, highU = -Double.infinity, lowV = Double.infinity, highV = -Double.infinity
            for p in hull {
                let u = p.x * ux + p.y * uy, v = p.y * ux - p.x * uy
                lowU = min(lowU, u); highU = max(highU, u)
                lowV = min(lowV, v); highV = max(highV, v)
            }
            let area = (highU - lowU) * (highV - lowV)
            if best == nil || area < best!.area { best = (area, ux, uy, lowU, highU, lowV, highV) }
        }
        guard let best else { return nil }
        let midU = (best.lowU + best.highU) / 2, midV = (best.lowV + best.highV) / 2
        let center = (x: midU * best.ux - midV * best.uy, y: midU * best.uy + midV * best.ux)
        var axis = (x: best.ux, y: best.uy)
        var halfWidth = (best.highU - best.lowU) / 2, halfHeight = (best.highV - best.lowV) / 2
        // Make the width axis the one closer to horizontal, pointing right.
        if abs(axis.x) < abs(axis.y) {
            axis = (x: -axis.y, y: axis.x)
            swap(&halfWidth, &halfHeight)
        }
        if axis.x < 0 { axis = (x: -axis.x, y: -axis.y) }
        return (center, axis, halfWidth, halfHeight)
    }

    /// Characters from the recogniser's per-step class probabilities (ocr): CTC greedy decoding as in
    /// hailo-apps' `ocr_eval_postprocess`. Take the best class at each time step, drop steps that repeat
    /// the previous step's class, drop the blank (class 0), and map the rest through `textCharacters`.
    /// The confidence is the mean probability of the kept steps (0 when nothing is kept).
    /// PaddleOCR v5's multilingual character set (18,382 characters, accents and CJK included, plus a
    /// trailing space), for the Core ML conversion of PP-OCRv5 mobile (the stick's recogniser uses
    /// `textCharacters`). Its 18,385 classes are: 0 blank, 1 ignored, then these characters - the layout
    /// Hailo's Model Zoo decodes with (text_recognition_postprocessing.py, ignored_tokens = [0, 1]).
    static let multilingualCharacters: [Character] = {
        guard let url = Bundle.module.url(forResource: "ppocrv5_characters", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["characters"] as? [String] else { return [] }
        return list.compactMap(\.first) + [" "]
    }()

    public static func recognizedText(_ tensor: Tensor) -> (text: String, confidence: Float) {
        let classes = tensor.features
        let values = tensor.floats()
        guard classes > 1 else { return ("", 0) }
        let multilingual = classes == multilingualCharacters.count + 2
        let textCharacters = multilingual ? multilingualCharacters : Self.textCharacters
        let firstCharacter = multilingual ? 2 : 1   // classes before this are the blank (and the ignored class)
        let steps = values.count / classes
        let blank = 0

        var text = ""
        var total: Float = 0, kept = 0
        var previous = -1
        for step in 0..<steps {
            let base = step * classes
            var best = 0
            var bestValue = values[base]
            for index in 1..<classes where values[base + index] > bestValue {
                best = index
                bestValue = values[base + index]
            }
            defer { previous = best }
            guard best != previous, best != blank, best >= firstCharacter, best - firstCharacter < textCharacters.count else { continue }
            text.append(textCharacters[best - firstCharacter])
            total += bestValue
            kept += 1
        }
        return (text, kept > 0 ? total / Float(kept) : 0)
    }
}
