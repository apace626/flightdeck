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

// --- Bright background squircle (blue → mauve) ---
let margin = size * 0.085
let bg = CGRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: bg, cornerWidth: bg.width * 0.2237, cornerHeight: bg.width * 0.2237, transform: nil))
ctx.clip()
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [c(137, 180, 250).cgColor, c(203, 166, 247).cgColor] as CFArray,
                      locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: margin, y: size - margin),
                       end: CGPoint(x: size - margin, y: margin), options: [])
ctx.restoreGState()

// --- White jet silhouette, centered, pointing up ---
let r = size * 0.30
let cx = size / 2, cy = size / 2
func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: cx + x * r, y: cy + y * r) }

// right-half outline (nose → wing → tail → center); left side mirrored.
let pts: [(CGFloat, CGFloat)] = [
    (0,    1.05),   // nose
    (0.12, 0.28),   // fuselage shoulder
    (0.95, -0.32),  // wing tip
    (0.20, -0.44),  // wing root trailing
    (0.14, -0.80),  // aft fuselage
    (0.52, -1.05),  // tailplane tip
    (0.10, -0.94),  // tail root
    (0,   -0.86),   // tail center
]

let path = CGMutablePath()
path.move(to: p(pts[0].0, pts[0].1))
for i in 1..<pts.count { path.addLine(to: p(pts[i].0, pts[i].1)) }
for i in stride(from: pts.count - 2, through: 1, by: -1) {
    path.addLine(to: p(-pts[i].0, pts[i].1))   // mirror
}
path.closeSubpath()

ctx.addPath(path)
ctx.setFillColor(NSColor.white.cgColor)
ctx.fillPath()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { fatalError("png encode failed") }
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/flightdeck-icon.png"
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
