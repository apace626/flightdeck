import AppKit

// Flightdeck app icon: flat & simple — a bright gradient squircle with a single
// clean white jet silhouette. App-icon basic.

func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
}

let size = CGFloat(1024)
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// --- Navy-blue background squircle (Blue Angels) ---
let margin = size * 0.085
let bg = CGRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: bg, cornerWidth: bg.width * 0.2237, cornerHeight: bg.width * 0.2237, transform: nil))
ctx.clip()
let navy = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [c(0, 24, 84).cgColor, c(10, 46, 130).cgColor] as CFArray,
                      locations: [0, 1])!
ctx.drawLinearGradient(navy, start: CGPoint(x: margin, y: size - margin),
                       end: CGPoint(x: size - margin, y: margin), options: [])
ctx.restoreGState()

// --- Big bold white "FD", centered ---
let letter = "FD"
let font = NSFont.systemFont(ofSize: size * 0.40, weight: .heavy)
let gold = c(255, 199, 44)   // Blue Angels gold
let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: gold]
let str = NSAttributedString(string: letter, attributes: attrs)
let textSize = str.size()
str.draw(at: NSPoint(x: (size - textSize.width) / 2,
                     y: (size - textSize.height) / 2))

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { fatalError("png encode failed") }
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/flightdeck-icon.png"
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
