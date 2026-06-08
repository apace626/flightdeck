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

// --- Army-green camouflage background squircle ---
let margin = size * 0.085
let bg = CGRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: bg, cornerWidth: bg.width * 0.2237, cornerHeight: bg.width * 0.2237, transform: nil))
ctx.clip()

// olive base
ctx.setFillColor(c(74, 86, 46).cgColor)
ctx.fill(bg)

// soft camo patches (radial blobs in varied military greens)
let patches: [(CGFloat, CGFloat, CGFloat, NSColor)] = [
    (0.28, 0.72, 0.40, c(54, 66, 30)),    // dark olive
    (0.74, 0.58, 0.46, c(108, 120, 66)),  // light olive
    (0.58, 0.26, 0.34, c(43, 52, 24)),    // deep green
    (0.18, 0.34, 0.32, c(125, 122, 78)),  // khaki
    (0.82, 0.86, 0.30, c(92, 104, 54)),
    (0.40, 0.48, 0.26, c(60, 74, 36)),
]
for (x, y, rad, col) in patches {
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: [col.withAlphaComponent(0.9).cgColor, col.withAlphaComponent(0).cgColor] as CFArray,
                       locations: [0, 1])!
    let center = CGPoint(x: size * x, y: size * y)
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0,
                           endCenter: center, endRadius: size * rad, options: [])
}
ctx.restoreGState()

// --- Big bold white "FD", centered ---
let letter = "FD"
let font = NSFont.systemFont(ofSize: size * 0.40, weight: .heavy)
let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
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
