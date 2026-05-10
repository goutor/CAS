import AppKit

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let size = CGSize(width: 1024, height: 1024)
let image = NSImage(size: size)

image.lockFocus()

let rect = CGRect(origin: .zero, size: size)
let background = NSBezierPath(roundedRect: rect.insetBy(dx: 64, dy: 64), xRadius: 220, yRadius: 220)
NSColor(calibratedRed: 0.05, green: 0.09, blue: 0.12, alpha: 1).setFill()
background.fill()

let inner = NSBezierPath(roundedRect: rect.insetBy(dx: 116, dy: 116), xRadius: 170, yRadius: 170)
NSColor(calibratedRed: 0.00, green: 0.38, blue: 0.95, alpha: 1).setFill()
inner.fill()

let glow = NSGradient(colors: [
    NSColor(calibratedRed: 0.10, green: 0.75, blue: 1.00, alpha: 0.95),
    NSColor(calibratedRed: 0.00, green: 0.26, blue: 0.82, alpha: 1.00)
])
glow?.draw(in: inner, angle: 135)

let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 300, weight: .black),
    .foregroundColor: NSColor.white,
    .kern: -8
]
let text = NSString(string: "CAS")
let textSize = text.size(withAttributes: attrs)
let textRect = CGRect(
    x: (size.width - textSize.width) / 2,
    y: (size.height - textSize.height) / 2 + 18,
    width: textSize.width,
    height: textSize.height
)
text.draw(in: textRect, withAttributes: attrs)

let arrowAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 118, weight: .bold),
    .foregroundColor: NSColor(calibratedRed: 0.55, green: 1.00, blue: 0.58, alpha: 1)
]
let arrow = NSString(string: "↻")
let arrowSize = arrow.size(withAttributes: arrowAttrs)
arrow.draw(
    in: CGRect(x: 716, y: 676, width: arrowSize.width, height: arrowSize.height),
    withAttributes: arrowAttrs
)

image.unlockFocus()

guard
    let tiff = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiff),
    let data = bitmap.representation(using: .png, properties: [:])
else {
    fatalError("Could not render icon")
}

try data.write(to: outputURL)
