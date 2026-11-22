// Draws Artelico's icon: a chip with "a." on it (placeholder until there is a real logo). Original artwork, generated with CoreGraphics.
// Run: swift Artelico/tools/make_icon.swift Artelico/App/Assets.xcassets/AppIcon.appiconset/icon-1024.png
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

// Background: deep violet to plum, corner to corner. iOS rounds the corners itself.
let background = CGGradient(colorsSpace: space, colors: [color(0.16, 0.08, 0.30), color(0.42, 0.16, 0.48)] as CFArray, locations: [0, 1])!
context.drawLinearGradient(background, start: CGPoint(x: 0, y: CGFloat(size)), end: CGPoint(x: CGFloat(size), y: 0), options: [])

// Pins on all four sides of the chip.
let body = CGRect(x: 232, y: 232, width: 560, height: 560)
let pinLength: CGFloat = 92, pinWidth: CGFloat = 44, pinCount = 5
context.setFillColor(color(0.98, 0.72, 0.55))
for i in 0..<pinCount {
    let offset = body.minX + 70 + CGFloat(i) * (body.width - 140) / CGFloat(pinCount - 1) - pinWidth / 2
    for rect in [CGRect(x: offset, y: body.maxY - 10, width: pinWidth, height: pinLength),
                 CGRect(x: offset, y: body.minY - pinLength + 10, width: pinWidth, height: pinLength),
                 CGRect(x: body.minX - pinLength + 10, y: offset, width: pinLength, height: pinWidth),
                 CGRect(x: body.maxX - 10, y: offset, width: pinLength, height: pinWidth)] {
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 18, cornerHeight: 18, transform: nil))
    }
}
context.fillPath()

// Chip body with a soft shadow and a lighter rim.
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -18), blur: 50, color: color(0, 0, 0, 0.45))
context.addPath(CGPath(roundedRect: body, cornerWidth: 96, cornerHeight: 96, transform: nil))
context.setFillColor(color(0.18, 0.09, 0.28))
context.fillPath()
context.restoreGState()
context.addPath(CGPath(roundedRect: body.insetBy(dx: 9, dy: 9), cornerWidth: 88, cornerHeight: 88, transform: nil))
context.setStrokeColor(color(0.98, 0.72, 0.55, 0.55))
context.setLineWidth(10)
context.strokePath()

// "a" in white with a peach full stop.
let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, 400, nil)
func line(_ text: String, _ fill: CGColor) -> CTLine {
    CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): fill,
    ]))
}
let letter = line("a", color(1, 1, 1))
let dot = line(".", color(0.98, 0.62, 0.42))
let letterBounds = CTLineGetBoundsWithOptions(letter, .useGlyphPathBounds)
let dotBounds = CTLineGetBoundsWithOptions(dot, .useGlyphPathBounds)
let gap: CGFloat = 22
let totalWidth = letterBounds.width + gap + dotBounds.width
let startX = body.midX - totalWidth / 2 - letterBounds.minX
let baseline = body.midY - letterBounds.height / 2 - letterBounds.minY
context.textPosition = CGPoint(x: startX, y: baseline)
CTLineDraw(letter, context)
context.textPosition = CGPoint(x: startX + letterBounds.maxX + gap - dotBounds.minX, y: baseline)
CTLineDraw(dot, context)

let image = context.makeImage()!
let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: output) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("could not write \(output)") }
print("wrote \(output)")
