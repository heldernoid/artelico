import CoreGraphics
import SwiftUI
import StudioCore

// HandPoints and HandReader (reading hands on the stick or with Core ML) are in StudioCore/HandGames.swift.

/// The hands' skeletons over the picture.
struct HandLayer: View {
    let hands: [HandPoints]
    var color: (HandPoints) -> Color = { _ in .green }
    var showBoxes = false

    var body: some View {
        Canvas { context, size in
            func p(_ q: CGPoint) -> CGPoint { CGPoint(x: q.x * size.width, y: q.y * size.height) }
            for hand in hands {
                if showBoxes {
                    let r = CGRect(x: hand.box.minX * size.width, y: hand.box.minY * size.height, width: hand.box.width * size.width, height: hand.box.height * size.height)
                    context.stroke(Path(r), with: .color(.white.opacity(0.4)), lineWidth: 1)
                }
                var path = Path()
                for (a, b) in HandCrop.edges { path.move(to: p(hand.points[a])); path.addLine(to: p(hand.points[b])) }
                context.stroke(path, with: .color(color(hand)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                for point in hand.points {
                    let c = p(point)
                    context.fill(Path(ellipseIn: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)), with: .color(.white))
                }
            }
        }
        .allowsHitTesting(false)
    }
}
